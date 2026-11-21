# Architecture Decision Records

Short ADRs. Each: context, decision, consequences. Newest at the bottom.
Values CLAUDE.md marks "proposed" or "assumption" are recorded here when they are fixed or changed.

---

## ADR-001: PowerShell scripts instead of a Makefile

- **Date:** 2026-11-21 (Task 01)
- **Context:** The primary dev machine is Windows + PowerShell 5.1 + Docker Desktop. There is no `make`. CLAUDE.md's layout listed a `Makefile`.
- **Decision:** `scripts/dev.ps1` is the single entry point (`up`, `down`, `logs`, `reset`, `verify`). Helper scripts sit beside it: `create-topics.ps1`, `verify-platform.ps1`, and `gen-keys.mjs` (Node, cross-platform). Scripts target Windows PowerShell 5.1: ASCII only, no `&&`/`??`, and native exit codes checked through `$LASTEXITCODE`. CLAUDE.md's layout now says `scripts/ (dev.ps1)`.
- **Consequences:** No extra tool to install. If execution policy blocks scripts, run `powershell -ExecutionPolicy Bypass -File .\scripts\dev.ps1 up`. A POSIX user can run the same `docker compose` commands directly.

## ADR-002: Kafka in KRaft mode, single broker

- **Context:** We need Kafka locally with minimal moving parts.
- **Decision:** `apache/kafka:3.9.1`, one node acting as both broker and controller (KRaft). No ZooKeeper. A fixed `KAFKA_CLUSTER_ID` in `.env`, generated with `kafka-storage.sh random-uuid` (22 chars, base64url of a UUID). Internal topic replication factor 1. `auto.create.topics.enable=false`.
- **Why 3.9.1:** KRaft is production-ready there. It is the last 3.x release, which gives the widest client compatibility before 4.0 drops old protocol versions.
- **Listeners:**
  - `INTERNAL://kafka:19092` for containers on the compose network.
  - `EXTERNAL://localhost:9092` for processes on the host. It is reachable only when the dev override publishes it.
- **Consequences:** One container instead of two. A typo in a topic name fails instead of creating a stray topic. Changing `KAFKA_CLUSTER_ID` on an existing volume stops the broker from starting; run `dev.ps1 reset`.

## ADR-003: Pinned image versions

- **Decision:** `apache/kafka:3.9.1`, `postgres:16.10-alpine`, `redis:7.4.5-alpine`. Each tag was checked with `docker manifest inspect` before commit. No `latest`, no floating major tag.
- **Consequences:** Every machine runs identical versions. Upgrades are explicit commits.

## ADR-004: One database, one schema and one role per service

- **Context:** Each service must own its data. No service reads another service's tables.
- **Decision:**
  - One database, `orderflow`, with schemas `identity`, `orders`, `inventory`, `payments`.
  - Each schema is owned (`AUTHORIZATION`) by its role: `identity_svc`, `orders_svc`, `inventory_svc`, `payments_svc`.
  - `PUBLIC` loses CONNECT/TEMP on `orderflow` and `postgres`, and all rights on schema `public`.
  - Each role has `search_path` set to its own schema, and has no USAGE on any other schema.
- **Passwords:** read by `db/init.sql` through psql `\getenv` from env vars that compose passes in from `.env`. They are never in the repository. The script raises an error if one is missing.
- **Consequences:** The database enforces the ownership rule, not just convention. A cross-schema query fails with `permission denied for schema`. `init.sql` runs only on an empty volume, so a password change needs `dev.ps1 reset`.
- **Note:** The official postgres image trusts loopback connections *inside its own container*. A check run with `docker compose exec postgres psql -h 127.0.0.1` therefore accepts any password. `verify-platform.ps1` connects from a separate container on `orderflow-net`, as real services do, and also asserts that a wrong password is rejected.

## ADR-005: Dev ports on loopback only, through an opt-in override

- **Context:** Rule 17 says only the gateway port is published. During development, services run from the IDE on the host and need Kafka, Postgres and Redis.
- **Decision:** `docker-compose.yml` publishes no ports. When the gateway is added, its port will be the only one there. `docker-compose.dev.yml` publishes `127.0.0.1:9092` (Kafka), `127.0.0.1:${POSTGRES_HOST_PORT:-5433}` (Postgres) and `127.0.0.1:6379` (Redis). Only `dev.ps1 up` applies it.
- **Why loopback:** `"5432:5432"` binds `0.0.0.0`, which exposes dev databases with dev passwords to the whole LAN or Wi-Fi.
- **Why 5433:** A native Windows PostgreSQL install usually holds 5432, and on the first run the container bind failed for exactly that reason. Inside the network the address is always `postgres:5432`. Kafka stays on 9092 because its advertised EXTERNAL listener is `localhost:9092`.
- **Consequences:** Rule 17 holds for the base file. The dev exception is explicit, opt-in and local only.

## ADR-006: Platform round trip uses a temporary probe topic

- **Context:** We need proof that produce and consume work. Writing a test message to `orderflow.orders.v1` would put a non-contract message in front of every future consumer.
- **Decision:** `verify-platform.ps1` creates `orderflow.platform-probe-<random>`, produces one keyed message, consumes it back, compares key and payload, then deletes the topic. The consumer does not commit offsets. The four real topics are only checked for existence, 3 partitions and RF 1. The real round trip on `orderflow.orders.v1` is proven in Task 06 with `OrderCreated`.
- **Rule 18 ("no extra topics"):** The probe topic lives for seconds, is not part of `contracts/`, and no service ever uses it.

## ADR-007: Topic creation is idempotent and never alters partitions

- **Decision:** `create-topics.ps1` uses `--create --if-not-exists` and then checks each topic's partition count (3 is still the "proposed" value). If an existing topic has a different count, the script **fails and leaves it alone**.
- **Why:** Adding partitions changes `hash(orderId) % partitions`. In-flight orders would then move to a different partition, which breaks per-order ordering (rule 8). In dev, use `dev.ps1 reset` instead.

## ADR-008: Redis requires a password

- **Decision:** `redis-server --requirepass $REDIS_PASSWORD`. The value comes from `.env`. The healthcheck authenticates through `REDISCLI_AUTH`, so the password never appears in argv.
- **Consequences:** Defense in depth, even though Redis is only reachable on the compose network or loopback. Clients must send the password. Rule 15 still applies: Redis is for rate limiting and the status cache only.
