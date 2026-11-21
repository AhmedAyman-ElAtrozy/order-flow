# OrderFlow

Four services process customer orders end to end: **api-identity** (NestJS gateway), **order-orchestrator** (Go: order lifecycle, saga, outbox), **inventory** (Spring Boot) and **payment-adapter** (Node, simulated provider). Kafka carries order and inventory events. Payment goes over HTTP with signed callbacks. Each service owns its own PostgreSQL schema.

Rules and contracts: [CLAUDE.md](CLAUDE.md). Decisions: [docs/decisions.md](docs/decisions.md).

## Quick start (Windows, PowerShell)

Prerequisites: Docker Desktop (running) and Node.js 20 or newer (used for key generation).

```powershell
Copy-Item .env.example .env          # dev defaults; dev.ps1 up does this if .env is missing
.\scripts\dev.ps1 up                 # start Kafka, Postgres, Redis; wait until healthy; create topics
.\scripts\dev.ps1 verify             # PASS/FAIL per check
```

If script execution is blocked:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\dev.ps1 up
```

### Commands

| Command | What it does |
|---|---|
| `.\scripts\dev.ps1 up` | Creates `.env` and dev keys if missing, starts the platform with dev ports, waits for healthchecks, creates topics (idempotent) |
| `.\scripts\dev.ps1 verify` | Checks schemas, roles, schema isolation, topics (3 partitions), Kafka round trip on a temporary topic, Redis |
| `.\scripts\dev.ps1 logs [service]` | Follows logs (`kafka`, `postgres`, `redis`, or all) |
| `.\scripts\dev.ps1 down` | Stops the containers and **keeps** the data |
| `.\scripts\dev.ps1 reset` | **Deletes** all volumes and starts fresh (asks first; `-Force` skips the prompt). Needed after changing DB passwords or `KAFKA_CLUSTER_ID` |
| `node scripts/gen-keys.mjs [--force]` | Dev RS256 key pair in `./keys/` (git-ignored) |

### Connecting from the host (dev only)

`dev.ps1 up` applies `docker-compose.dev.yml`, which publishes ports on **127.0.0.1 only**. A plain `docker compose up` publishes nothing.

| | From the host | From containers |
|---|---|---|
| PostgreSQL | `127.0.0.1:5433` (`POSTGRES_HOST_PORT`), db `orderflow` | `postgres:5432` |
| Kafka | `localhost:9092` | `kafka:19092` |
| Redis | `127.0.0.1:6379` (password `REDIS_PASSWORD`) | `redis:6379` |

DB users, one per service, each limited to its own schema: `identity_svc`/`identity`, `orders_svc`/`orders`, `inventory_svc`/`inventory`, `payments_svc`/`payments`.

Topics: `orderflow.orders.v1`, `orderflow.inventory.v1`, `orderflow.orders.v1.dlq`, `orderflow.inventory.v1.dlq`. Each has 3 partitions and RF 1, and is keyed by `orderId`.

## Layout

```
docker-compose.yml        platform, no published ports (rule 17)
docker-compose.dev.yml    dev-only loopback ports
db/init.sql               schemas + per-service roles (passwords from env)
scripts/                  dev.ps1, create-topics.ps1, verify-platform.ps1, gen-keys.mjs
services/                 (later tasks)
contracts/                (later tasks) event and HTTP contracts
docs/decisions.md         ADRs
```
