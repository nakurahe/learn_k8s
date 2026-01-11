# phrase1: API + Redis queue + worker (Go)

This phrase demonstrates a minimal Kubernetes-style architecture that you can also run locally with Docker Compose.

Components:
- **api**: HTTP API that accepts requests and pushes messages to a queue
- **redis**: Redis used as a simple message queue (Redis List)
- **worker**: background consumer that pulls from Redis and processes messages

## Message flow

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

## Source layout

- `cmd/api/main.go`: HTTP server (`/enqueue`, `/healthz`)
- `cmd/worker/main.go`: worker loop + file append
- `internal/queue/redis_queue.go`: Redis queue wrapper
- `docker-compose.yml`: runs `api`, `redis`, and `worker`
- `Dockerfile.api`, `Dockerfile.worker`: container builds
