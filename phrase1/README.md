# phrase1: API + Redis queue + worker (Go)

This phrase demonstrates a minimal Kubernetes-style architecture that we can also run locally with Docker Compose.

Components:
- **api**: HTTP API that accepts requests and pushes messages to a queue
- **redis**: Redis used as a simple message queue (Redis List)
- **worker**: background consumer that pulls from Redis and processes messages

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

## Source layout

- `cmd/api/main.go`: HTTP server (`/enqueue`, `/healthz`)
- `cmd/worker/main.go`: worker loop + file append
- `internal/queue/redis_queue.go`: Redis queue wrapper
- `docker-compose.yml`: runs `api`, `redis`, and `worker`
- `Dockerfile.api`, `Dockerfile.worker`: container builds

## Learning note: What breaks across multiple machines?

Docker Compose works great on one machine because everything shares:
- one network namespace per compose network
- one Redis instance reachable as `redis:6379`
- local volumes for persistence

If we needed to run this across 10 machines, these are the main things that would break or become manual toil:

- **Service discovery / networking:** `redis:6379` only exists inside a single Compose network. Across machines, we need a stable way for API and workers to find Redis (DNS/service discovery, routing rules, firewall openings).
- **Load balancing:** multiple API instances need a single entrypoint (L4/L7 load balancer) and health-based routing.
- **Shared state & storage:** the worker writes to a local volume (`worker-data`). Across machines, “the file” is no longer shared. We’d need shared storage (NFS/S3/etc.) or change the worker to write to a database/object store.
- **Queue topology:** a single Redis instance becomes a bottleneck and single point of failure; we may need Redis HA (replication/sentinel/cluster) and proper persistence/backup.
- **Rolling updates & self-healing:** Compose doesn’t orchestrate across nodes. If a machine dies, we want workloads rescheduled automatically and updated gradually without downtime.
- **Configuration management:** env vars are easy locally, but at scale we need consistent distribution (and separation of config vs secrets).
- **Security boundaries:** exposing ports across machines increases blast radius. We need network policies, TLS, auth, and least-privilege runtime settings.
- **Observability:** distributed logs/metrics/traces become necessary; “docker compose logs” stops being enough.

This is exactly the kind of gap Kubernetes is designed to fill: service discovery, scheduling, scaling, self-healing, rolling updates, and standardized config/secret management.
