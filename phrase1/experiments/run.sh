#!/usr/bin/env bash
set -euo pipefail

# Tiny experiment runner for phrase1.
# Requires: docker, docker compose, curl, awk, grep, sed

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

API_URL_DEFAULT="http://localhost:8080"
QUEUE_DEFAULT="messages"
REPORT_DIR_DEFAULT="$ROOT_DIR/experiments/reports"

usage() {
  cat <<'EOF'
Usage:
  ./experiments/run.sh <command> [args]

Commands:
  kill-inflight        Kill worker mid-processing and report lost messages
  scale-workers        Scale worker=3 and show load distribution
  slam-api             Send 1000 requests quickly; summarize HTTP codes
  restart-persistence  Restart stack; show what persisted
  clean                Stop stack and remove volumes

Common env vars:
  API_URL              Base URL (default: http://localhost:8080)
  QUEUE_NAME           Redis list name (default: messages)
  REPORT_DIR           Where to write JSON reports (default: experiments/reports)

kill-inflight env vars:
  PROCESSING_DELAY_MS  Worker delay to widen the window (default: 500)
  N                    Number of messages to enqueue (default: 200)
  P                    Curl parallelism (default: 50)
  KILL_AFTER           Kill after this many dequeues observed (default: 10)

scale-workers env vars:
  N                    Messages to enqueue (default: 300)
  P                    Curl parallelism (default: 80)

slam-api env vars:
  N                    Requests (default: 1000)
  P                    Parallelism (default: 100)

Tip:
  PROCESSING_DELAY_MS=800 ./experiments/run.sh kill-inflight
EOF
}

json_escape() {
  # Minimal JSON string escape (no newlines expected).
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r/\\r/g' -e 's/\t/\\t/g'
}

report_path_for() {
  local cmd="$1"
  local report_dir="${REPORT_DIR:-$REPORT_DIR_DEFAULT}"
  mkdir -p "$report_dir"
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  echo "$report_dir/${cmd}-${ts}.json"
}

maybe_git_sha() {
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git rev-parse --short HEAD 2>/dev/null || true
  else
    true
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

compose() {
  docker compose "$@"
}

docker_container_ids_for_service() {
  # Prints container IDs for a compose service (one per line)
  compose ps -q "$1" | sed '/^$/d'
}

first_container_id_for_service() {
  docker_container_ids_for_service "$1" | head -n 1
}

redis_llen() {
  local queue="$1"
  compose exec -T redis redis-cli LLEN "$queue" | tr -d '\r'
}

processed_count() {
  # Grep the shared processed log from any one worker container.
  local prefix="$1"
  local worker_id
  worker_id="$(first_container_id_for_service worker)"
  if [[ -z "$worker_id" ]]; then
    echo 0
    return
  fi
  docker exec -i "$worker_id" sh -lc "test -f /data/processed.log && grep -c '$prefix' /data/processed.log || true" | tr -d '\r'
}

dequeued_count_from_logs() {
  local worker_id="$1"
  local prefix="$2"
  # Count dequeued log lines for this prefix.
  docker logs "$worker_id" 2>/dev/null | grep -c "dequeued message: \"${prefix}" || true
}

wait_for_dequeued() {
  local worker_id="$1"
  local prefix="$2"
  local target="$3"
  local timeout_s="$4"

  local start
  start="$(date +%s)"
  while true; do
    local n
    n="$(dequeued_count_from_logs "$worker_id" "$prefix")"
    if [[ "$n" -ge "$target" ]]; then
      echo "$n"
      return 0
    fi
    local now
    now="$(date +%s)"
    if [[ $((now - start)) -ge "$timeout_s" ]]; then
      echo "$n"
      return 1
    fi
    sleep 0.2
  done
}

enqueue_batch() {
  local api_url="$1"
  local prefix="$2"
  local n="$3"
  local p="$4"

  # Use xargs to avoid external load tools.
  seq 1 "$n" | xargs -I{} -P "$p" curl -sS -o /dev/null -X POST "$api_url/enqueue" -d "${prefix}{}"
}

cmd_clean() {
  compose down -v
}

cmd_kill_inflight() {
  need_cmd docker
  need_cmd curl
  need_cmd awk
  need_cmd grep
  need_cmd sed

  local api_url="${API_URL:-$API_URL_DEFAULT}"
  local queue="${QUEUE_NAME:-$QUEUE_DEFAULT}"
  local delay_ms="${PROCESSING_DELAY_MS:-500}"
  local n="${N:-200}"
  local p="${P:-50}"
  local kill_after="${KILL_AFTER:-10}"
  local started_at
  started_at="$(date +%s)"

  local prefix
  prefix="kill-$(date +%s)-"

  echo "[kill-inflight] bringing stack up (PROCESSING_DELAY_MS=$delay_ms)"
  PROCESSING_DELAY_MS="$delay_ms" compose up -d --build --scale worker=1

  local worker_id
  worker_id="$(first_container_id_for_service worker)"
  if [[ -z "$worker_id" ]]; then
    echo "worker container not found" >&2
    exit 1
  fi

  echo "[kill-inflight] enqueueing N=$n (P=$p) prefix=$prefix"
  enqueue_batch "$api_url" "$prefix" "$n" "$p" &
  local enqueue_pid=$!

  echo "[kill-inflight] waiting until worker dequeues >= $kill_after (timeout 20s)"
  if wait_for_dequeued "$worker_id" "$prefix" "$kill_after" 20 >/dev/null; then
    echo "[kill-inflight] killing worker container $worker_id"
    docker kill -s SIGKILL "$worker_id" >/dev/null
  else
    echo "[kill-inflight] warning: did not observe enough dequeues before timeout; still killing"
    docker kill -s SIGKILL "$worker_id" >/dev/null || true
  fi

  wait "$enqueue_pid" || true

  echo "[kill-inflight] restarting worker"
  PROCESSING_DELAY_MS="$delay_ms" compose up -d --build worker

  echo "[kill-inflight] waiting 3s for recovery"
  sleep 3

  local processed
  processed="$(processed_count "$prefix")"
  local remaining
  remaining="$(redis_llen "$queue")"
  local lost=$(( n - processed - remaining ))
  if [[ "$lost" -lt 0 ]]; then
    lost=0
  fi

  cat <<EOF
[kill-inflight] results
  enqueued:   $n
  processed:  $processed
  in-redis:   $remaining
  lost(est):  $lost

Notes:
- 'lost' is the classic BRPOP window: dequeued but not fully processed.
- If you have old messages in Redis, 'in-redis' may include them; run './experiments/run.sh clean' first for a pristine run.
EOF

  local ended_at
  ended_at="$(date +%s)"
  local report
  report="$(report_path_for kill-inflight)"
  local sha
  sha="$(maybe_git_sha)"
  cat >"$report" <<JSON
{
  "command": "kill-inflight",
  "git_sha": "$(json_escape "$sha")",
  "started_at_epoch": $started_at,
  "ended_at_epoch": $ended_at,
  "duration_s": $((ended_at - started_at)),
  "settings": {
    "api_url": "$(json_escape "$api_url")",
    "queue_name": "$(json_escape "$queue")",
    "processing_delay_ms": $delay_ms,
    "n": $n,
    "p": $p,
    "kill_after": $kill_after,
    "prefix": "$(json_escape "$prefix")"
  },
  "results": {
    "enqueued": $n,
    "processed": $processed,
    "in_redis": $remaining,
    "lost_est": $lost
  }
}
JSON
  echo "[kill-inflight] wrote report: $report"
}

cmd_scale_workers() {
  need_cmd docker
  need_cmd curl
  need_cmd awk
  need_cmd grep

  local api_url="${API_URL:-$API_URL_DEFAULT}"
  local n="${N:-300}"
  local p="${P:-80}"
  local started_at
  started_at="$(date +%s)"
  local prefix
  prefix="scale-$(date +%s)-"

  echo "[scale-workers] starting stack with 3 workers"
  compose up -d --build --scale worker=3

  local ids
  ids="$(docker_container_ids_for_service worker)"
  if [[ -z "$ids" ]]; then
    echo "no worker containers found" >&2
    exit 1
  fi

  echo "[scale-workers] enqueueing N=$n (P=$p) prefix=$prefix"
  enqueue_batch "$api_url" "$prefix" "$n" "$p"

  echo "[scale-workers] waiting 2s"
  sleep 2

  echo "[scale-workers] per-worker processed counts (from logs)"
  local workers_json=""
  local first=1
  while IFS= read -r id; do
    # Count 'processed message' lines for this prefix.
    local c
    c="$(docker logs "$id" 2>/dev/null | grep -c "processed message: \"${prefix}" || true)"
    echo "  $id  processed=$c"
    if [[ $first -eq 1 ]]; then
      first=0
    else
      workers_json+=" ,"
    fi
    workers_json+="{\"container_id\":\"$(json_escape "$id")\",\"processed\":$c}"
  done <<< "$ids"

  echo "[scale-workers] note: output file is shared; order may look mixed"

  local ended_at
  ended_at="$(date +%s)"
  local report
  report="$(report_path_for scale-workers)"
  local sha
  sha="$(maybe_git_sha)"
  cat >"$report" <<JSON
{
  "command": "scale-workers",
  "git_sha": "$(json_escape "$sha")",
  "started_at_epoch": $started_at,
  "ended_at_epoch": $ended_at,
  "duration_s": $((ended_at - started_at)),
  "settings": {
    "api_url": "$(json_escape "$api_url")",
    "n": $n,
    "p": $p,
    "scaled_workers": 3,
    "prefix": "$(json_escape "$prefix")"
  },
  "results": {
    "workers": [ $workers_json ]
  }
}
JSON
  echo "[scale-workers] wrote report: $report"
}

cmd_slam_api() {
  need_cmd curl
  need_cmd awk
  need_cmd sort
  need_cmd uniq

  local api_url="${API_URL:-$API_URL_DEFAULT}"
  local n="${N:-1000}"
  local p="${P:-100}"
  local prefix
  prefix="load-$(date +%s)-"

  echo "[slam-api] sending N=$n requests (P=$p)"
  local started_at
  started_at="$(date +%s)"

  local counts
  counts="$(seq 1 "$n" | xargs -I{} -P "$p" curl -sS -o /dev/null -w "%{http_code}\n" -X POST "$api_url/enqueue" -d "${prefix}{}" | sort | uniq -c)"
  echo "$counts"

  local ended_at
  ended_at="$(date +%s)"
  echo "[slam-api] elapsed: $((ended_at - started_at))s"

  # Convert the "uniq -c" output to a JSON object: {"200": 999, "503": 1}
  local codes_json=""
  local first=1
  while read -r count code; do
    [[ -z "${code:-}" ]] && continue
    if [[ $first -eq 1 ]]; then
      first=0
    else
      codes_json+=","
    fi
    codes_json+="\"$(json_escape "$code")\": $count"
  done <<< "$counts"

  local report
  report="$(report_path_for slam-api)"
  local sha
  sha="$(maybe_git_sha)"
  cat >"$report" <<JSON
{
  "command": "slam-api",
  "git_sha": "$(json_escape "$sha")",
  "started_at_epoch": $started_at,
  "ended_at_epoch": $ended_at,
  "duration_s": $((ended_at - started_at)),
  "settings": {
    "api_url": "$(json_escape "$api_url")",
    "n": $n,
    "p": $p,
    "prefix": "$(json_escape "$prefix")"
  },
  "results": {
    "status_codes": { $codes_json }
  }
}
JSON
  echo "[slam-api] wrote report: $report"
}

cmd_restart_persistence() {
  need_cmd docker
  need_cmd curl

  local api_url="${API_URL:-$API_URL_DEFAULT}"
  local queue="${QUEUE_NAME:-$QUEUE_DEFAULT}"
  local started_at
  started_at="$(date +%s)"
  local prefix
  prefix="persist-$(date +%s)-"

  echo "[restart-persistence] up"
  compose up -d --build

  echo "[restart-persistence] enqueueing 20"
  enqueue_batch "$api_url" "$prefix" 20 10

  echo "[restart-persistence] restart"
  compose restart

  echo "[restart-persistence] wait 2s"
  sleep 2

  local worker_id
  worker_id="$(first_container_id_for_service worker)"
  echo "[restart-persistence] last lines in processed.log (from $worker_id)"
  docker exec -i "$worker_id" sh -lc "tail -n 20 /data/processed.log || true"

  echo "[restart-persistence] redis LLEN $queue: $(redis_llen "$queue")"

  local ended_at
  ended_at="$(date +%s)"
  local report
  report="$(report_path_for restart-persistence)"
  local sha
  sha="$(maybe_git_sha)"
  local remaining
  remaining="$(redis_llen "$queue")"
  local processed
  processed="$(processed_count "$prefix")"
  cat >"$report" <<JSON
{
  "command": "restart-persistence",
  "git_sha": "$(json_escape "$sha")",
  "started_at_epoch": $started_at,
  "ended_at_epoch": $ended_at,
  "duration_s": $((ended_at - started_at)),
  "settings": {
    "api_url": "$(json_escape "$api_url")",
    "queue_name": "$(json_escape "$queue")",
    "prefix": "$(json_escape "$prefix")"
  },
  "results": {
    "processed_with_prefix": $processed,
    "redis_llen": $remaining
  }
}
JSON
  echo "[restart-persistence] wrote report: $report"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    help|-h|--help|"") usage ;;
    clean) cmd_clean ;;
    kill-inflight) cmd_kill_inflight ;;
    scale-workers) cmd_scale_workers ;;
    slam-api) cmd_slam_api ;;
    restart-persistence) cmd_restart_persistence ;;
    *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
  esac
}

main "$@"
