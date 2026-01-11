# phrase1: API + Redis queue + worker (Go)

This phrase demonstrates a minimal Kubernetes-style architecture that we can also run locally with Docker Compose.

Components:
- **api**: HTTP API that accepts requests and pushes messages to a queue
- **redis**: Redis used as a simple message queue (Redis List)
- **worker**: background consumer that pulls from Redis and processes messages

## Learning note: Running this across multiple machines

This repo is intentionally “single-machine friendly” (Compose network, one Redis, local volumes). If we wanted this to run reliably across multiple machines, these are the answers to the common ops questions:

- **What would we need to run this reliably across multiple machines?**
  - A real orchestrator (Kubernetes/Nomad/Swarm) for scheduling, health checks, rescheduling on node failure, and safe rollouts.
  - Service discovery + networking so `api`/`worker` can find Redis and the API can be reached consistently.
  - Highly available state: Redis HA (sentinel/cluster or a managed Redis) plus backups.
  - Durable output handling: replace the local `worker-data` file sink with shared storage (object store/DB) or a log pipeline.
  - Centralized config/secrets and observability (logs/metrics) so failures are visible and automation can react.

- **How would we automatically restart a crashed worker?**
  - In Kubernetes: run `worker` as a Deployment/ReplicaSet with `restartPolicy: Always` and a liveness probe; it will restart/reschedule automatically.
  - In Docker/Compose: add a restart policy (e.g. `restart: unless-stopped`) or run the worker under `systemd` with `Restart=always`.

- **How would we update the API to a new version without downtime?**
  - Run multiple API replicas behind a load balancer and do a rolling update (new instances become ready before old ones are drained).
  - Use readiness checks (don’t receive traffic until Redis is reachable) and graceful shutdown to finish in-flight requests.

- **How would external traffic find our API if it's running on 3 different servers?**
  - Put a stable “front door” in place: DNS name or one L4/L7 load balancer/ingress, routing to healthy API instances.
  - DNS round-robin alone can work for demos, but typically lacks health-based routing and smooth draining during deploys.

## Architecture diagram

```text
                 +-------------------+
                 |  Client (curl)    |
                 +-------------------+
                   |             |
                   | HTTP POST   | HTTP GET
                   | /enqueue    | /healthz
                   v             v
             +---------------------------+
             |        api (:8080)        |
             +---------------------------+
                      |
                      | LPUSH messages <payload>
                      v
             +---------------------------+
             |   redis (list "messages") |
             +---------------------------+
                      ^
                      | BRPOP messages (blocks up to 5s)
                      |
             +---------------------------+
             |          worker           |
             +---------------------------+
                      |
                      | append lines
                      v
             +---------------------------+
             | worker-data volume        |
             | /data/processed.log       |
             +---------------------------+

Note: api, redis, and worker share a Docker Compose network.
```

## Message workflow (sequence)

```text
1) Client -----HTTP POST /enqueue ("hello")-----> API
2) API    -----LPUSH messages "hello"-----------> Redis
3) Redis  ----------------OK--------------------> API
4) API    -----200 {enqueued:true}--------------> Client

Worker side:
5) Worker -----BRPOP messages (up to 5s)--------> Redis
     - If list has an item, Redis replies immediately.
     - If list is empty, Redis holds the connection open (blocks) until:
         a) a message arrives, OR
         b) 5 seconds passes (timeout), OR
         c) the worker cancels its context.
6) Redis  -----["messages", "hello"]------------> Worker
7) Worker -----process + append-----------------> /data/processed.log
```

- API enqueues messages using Redis List: `LPUSH messages <payload>`
- Worker consumes messages using: `BRPOP messages`

The queue name is configurable via `QUEUE_NAME` (default: `messages`).

## Run (Docker Compose)

From this folder:

```bash
docker compose up --build
```

API endpoints:
- Health: `GET http://localhost:8080/healthz`
- Enqueue: `POST http://localhost:8080/enqueue`

## Security note

This is a learning/demo setup:
- The API has no authentication/authorization and will accept arbitrary messages.
- It logs message contents.
- Redis is used as a simple queue (no acks/retries).

Do not deploy this as-is to an untrusted network.

### Enqueue examples

Plain text body:

```bash
curl -sS -X POST localhost:8080/enqueue -d 'hello from curl'
```

JSON body:

```bash
curl -sS -X POST localhost:8080/enqueue \
  -H 'Content-Type: application/json' \
  -d '{"message":"hello json"}'
```

### Observe worker processing

Watch logs:

```bash
docker compose logs -f worker
```

The worker also appends a line per message to `/data/processed.log` inside the worker container (backed by the `worker-data` volume).

View it:

```bash
docker compose exec worker tail -n 50 /data/processed.log
```

## Configuration

All config is via environment variables.

API:
- `HTTP_ADDR` (default `:8080`)
- `REDIS_ADDR` (default `redis:6379` in compose)
- `QUEUE_NAME` (default `messages`)

Worker:
- `REDIS_ADDR` (default `redis:6379` in compose)
- `QUEUE_NAME` (default `messages`)
- `OUTPUT_PATH` (default `/data/processed.log`)
- `PROCESSING_DELAY_MS` (default `0`) simulate slow work

## Source layout

- `cmd/api/main.go`: HTTP server (`/enqueue`, `/healthz`)
- `cmd/worker/main.go`: worker loop + file append
- `internal/queue/redis_queue.go`: Redis queue wrapper
- `docker-compose.yml`: runs `api`, `redis`, and `worker`
- `Dockerfile.api`, `Dockerfile.worker`: container builds

## Experiments

Important: run these commands from this folder:

```bash
cd phrase1
```

### Automated runner

A simple script to run each experiment and collect results:

```bash
chmod +x experiments/run.sh
./experiments/run.sh help
```

Examples:

```bash
PROCESSING_DELAY_MS=800 ./experiments/run.sh kill-inflight
./experiments/run.sh scale-workers
./experiments/run.sh slam-api
./experiments/run.sh restart-persistence
./experiments/run.sh clean
```

Each run writes a JSON report to `experiments/reports/` (override with `REPORT_DIR=...`).

#### 1) Kill the worker mid-processing (in-flight loss)

Goal: see what happens when the worker is terminated after it dequeues but before it finishes “processing”.

Manual steps:

1) Start the stack and slow down processing:

```bash
docker compose up -d --build
docker compose stop worker
PROCESSING_DELAY_MS=500 docker compose up -d --build worker
```

2) In another terminal, follow worker logs:

```bash
docker compose logs -f worker
```

3) Enqueue a batch quickly:

```bash
seq 1 200 | xargs -I{} -P 50 curl -sS -o /dev/null -X POST http://localhost:8080/enqueue -d "kill-test-{}"
```

4) While logs show lines like `dequeued message: ...` (but before `processed message: ...`), kill the worker abruptly:

```bash
docker compose kill -s SIGKILL worker
docker compose up -d worker
```

Expected result:
- Messages that were *still in Redis* will be processed after restart.
- Messages that were *already dequeued* (popped) but not yet written are typically **lost**.

Why: the worker uses Redis `BRPOP` which removes the item when dequeued.

#### 2) Scale to 3 workers (competing consumers)

Goal: see how multiple workers share the queue.

Manual steps:

1) Scale workers:

```bash
docker compose up -d --scale worker=3 --build
```

2) Enqueue a batch:

```bash
seq 1 300 | xargs -I{} -P 80 curl -sS -o /dev/null -X POST http://localhost:8080/enqueue -d "scale-worker-{}"
```

3) Watch logs and confirm multiple containers are processing:

```bash
docker compose logs -f worker
```

Notes / gotchas:
- All workers do `BRPOP` on the same list, so they naturally load-balance (each message goes to one worker).
- All workers share the same `worker-data` volume, so they append into the same `/data/processed.log`.

#### 3) Slam the API (1000 fast requests)

Goal: see if the API or Redis falls over under bursty client load.

Run a simple concurrent load burst and summarize status codes mannually:

```bash
seq 1 1000 | xargs -I{} -P 100 curl -sS -o /dev/null -w "%{http_code}\n" \
  -X POST http://localhost:8080/enqueue -d "load-{}" | sort | uniq -c
```

Expected result:
- Mostly (or all) `200`.
- If you see `503`, that usually means the API couldn’t talk to Redis within its timeout.

Can you scale the API with `--scale api=3`?
- Not directly with the current Compose file because `api` publishes a fixed host port (`8080:8080`).
- To scale it properly, add a reverse proxy/LB service (nginx/traefik) that owns port 8080 and load-balances to multiple `api` containers.

#### 4) Restart everything (persistence)

Goal: see what data persists across restarts.

Manual steps:

1) Enqueue a few messages:

```bash
seq 1 20 | xargs -I{} -P 10 curl -sS -o /dev/null -X POST http://localhost:8080/enqueue -d "persist-{}"
```

2) Restart:

```bash
docker compose restart
```

3) Check processed output:

```bash
docker compose exec worker tail -n 50 /data/processed.log
```

4) (Optional) check queue depth:

```bash
docker compose exec redis redis-cli LLEN messages
```

Expected result:
- `worker-data` volume keeps `/data/processed.log` across restarts.
- `redis-data` volume keeps Redis state (AOF enabled). 
- In-flight messages can still be lost if a worker dies after dequeue and before processing completes.
