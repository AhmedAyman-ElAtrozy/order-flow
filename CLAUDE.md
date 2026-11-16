# OrderFlow: Agent Instructions

## What this system does

Four services process customer orders end to end:

- **api-identity** (NestJS): public gateway. Login, JWT, rate limit, validation, forwards to the Order Orchestrator. Owns only the `users` table.
- **order-orchestrator** (Go): owns the order lifecycle. Idempotent intake, order state machine, saga, outbox, payment calls, reservation expiry.
- **inventory** (Spring Boot): consumes `orderflow.orders.v1`, reserves/commits/releases stock, publishes to `orderflow.inventory.v1`.
- **payment-adapter** (Node.js): simulated payment provider. Creates payments, decides outcomes by scenario, sends HMAC-signed callbacks.

Kafka carries order and inventory events only. Payment is HTTP + signed callback, NOT Kafka. Redis is optional and never authoritative.
Each service owns its own PostgreSQL schema and DB user. No service reads another service's tables.

## Non-negotiable rules

1. The Order Orchestrator is the ONLY owner of order state. Inventory and Payment never decide an order's lifecycle; they report facts.
2. State changes + the event that announces them are written in ONE database transaction (transactional outbox). Never publish to Kafka from inside a request or consumer handler directly.
3. Every consumer is idempotent: insert `eventId` into `processed_events` FIRST, in the same transaction as the effect. A duplicate insert means skip.
4. Kafka offsets commit ONLY after the database transaction commits (manual commit). Never auto-commit.
5. Order state transitions are guarded compare-and-set: `UPDATE orders SET status=$new WHERE id=$id AND status=$expected`. Zero rows updated means someone else moved it; do not retry blindly, re-read.
6. The transition decision (`order.Transition(order, event)`) is a PURE function: no DB, no Kafka, no HTTP, no clock. This is what makes it table-testable.
7. Outbox relay: exactly one active leader (`pg_try_advisory_lock`), publishes in `seq` order, synchronous send, marks `published_at` only after the broker ack. Never parallelize the relay.
8. Events are keyed by `orderId`. Never change the key: it guarantees per-order ordering.
9. Inventory reservation is ONE conditional statement: `UPDATE stock SET available = available - $qty WHERE sku=$sku AND available >= $qty`. Never read-then-write stock. `reservations` has `UNIQUE(order_id)`. Release runs `WHERE status='RESERVED' RETURNING` so it happens exactly once.
10. Idempotent intake: `UNIQUE(customer_id, idem_key)` plus a request hash. Same key + same payload returns the ORIGINAL order (same status code and body). Same key + different payload returns 409. Never create a second order.
11. Payment calls: write the `payment_attempts` row (status INITIATING) BEFORE calling the adapter, with a stable `attemptId` reused on every retry. A timeout (3s) means UNKNOWN, never FAILED. Resolve unknowns only through `GET /payments/{attemptId}`, which never charges.
12. Callbacks are verified with HMAC-SHA256 over `timestamp + "." + rawBody`, headers `X-OF-Timestamp` and `X-OF-Signature`, 5-minute skew. Verify against the RAW body bytes, before JSON parsing. Deduplicate by `providerEventId` in `callback_inbox`. Compare signatures in constant time.
13. Cancelling an order while its payment is UNKNOWN is deferred, not executed. Never cancel and release stock while a charge may have succeeded.
14. A reservation lives until the order reaches an end state. A PENDING order with no inventory answer after 15 minutes becomes CANCELLED (reason EXPIRED). PAYMENT_PENDING and PAYMENT_UNKNOWN orders never expire automatically.
15. Redis may only be used for rate limiting (fail OPEN if Redis is down) and a 2-second order-status cache that re-checks `ownerId`. Never use Redis as a lock, counter, or idempotency source.
16. Identity: the Go service re-verifies the JWT itself (RS256), it does not trust the gateway's word. Queries are identity-scoped: another customer's order returns 404, not 403. Roles: `customer`, `support`, `ops_admin`; role comes from the token, never from the request body.
17. Only the gateway port is published in docker-compose. Internal services are reachable only on the compose network.
18. Do NOT add: shipment/fulfilment service, extra Kafka topics, Kubernetes/Helm, schema registry, distributed tracing, or payment events on Kafka. They are explicitly out of scope. Ask first.

## Repository layout (do not restructure)

```
services/
  api-identity/          NestJS / TypeScript
    src/middleware/        correlationId, request log
    src/guards/            RateLimitGuard, JwtAuthGuard, RolesGuard
    src/auth/ users/       login (argon2id, RS256), seeded synthetic users
    src/orders/ admin/     controllers + services, thin
    src/clients/order-service/   OrderServiceClient (undici, 3s timeout)
    src/common/            AllExceptionsFilter, DTOs
  order-orchestrator/    Go
    cmd/orchestrator/main.go     wiring only, no business logic
    internal/httpapi/            routes, JWT verify, error mapping
    internal/intake/             CreateOrder use case
    internal/order/              domain: states + pure Transition
    internal/saga/               OnInventoryReserved/Rejected, OnPaymentOutcome, OnExpired
    internal/store/              pgx, one transaction per event
    internal/relay/              outbox relay (leader, ordered by seq)
    internal/consumer/           inventory topic consumer, inbox, DLQ
    internal/paymentclient/      HTTP client to the adapter
    internal/callback/           HMAC verify + callback_inbox dedupe
    internal/workers/            payment initiator, reconciler, expiry
    internal/config/             env var loading only
  inventory/             Java 21 / Spring Boot
    messaging.in/                OrdersEventListener, EventRouter
    domain/                      ReservationService, Reserve/Commit/Release handlers
    persistence/                 JdbcClient repositories, plain SQL
    messaging.out/               OutboxRelay
    web/                         StockAdminController (test profile only)
  payment-adapter/       Node.js
    src/routes/ middleware/      payments routes, serviceAuth (X-Service-Token)
    src/paymentService.js        idempotent create by attempt_id
    src/scenarios/               ScenarioEngine
    src/webhooks/                dispatcher + signer
contracts/               event envelope, topics, HTTP contracts. Source of truth
docs/                    decisions.md (ADRs), architecture notes
docker-compose.yml  Makefile
```

## Contracts (exact names: do not deviate)

JSON field names are camelCase. Database columns are snake_case. Never rename a field without updating `contracts/` and every producer and consumer in the same change.

**Envelope (every Kafka event):** eventId, type, version, occurredAt, orderId, correlationId, causationId, producer, data

**Topics:** `orderflow.orders.v1`, `orderflow.inventory.v1`, plus `orderflow.orders.v1.dlq`, `orderflow.inventory.v1.dlq`. Key = orderId.

**Events and `data` (proposed, confirm in contracts/ before coding):**
- OrderCreated: customerId, items[{sku, quantity}], totalMinor, currency
- OrderConfirmed: (empty beyond envelope)
- OrderCancelled: reason (CUSTOMER | EXPIRED | PAYMENT_FAILED | OUT_OF_STOCK | OPS)
- InventoryReserved: items[{sku, quantity}]
- InventoryRejected: reason, sku
- InventoryReleased: (empty beyond envelope)

**Order states:** PENDING, STOCK_RESERVED, REJECTED_OUT_OF_STOCK, PAYMENT_PENDING, PAYMENT_UNKNOWN, CONFIRMED, CANCELLED

**HTTP, public (gateway):** POST /auth/login; POST /orders (header `Idempotency-Key` required); GET /orders/{id}; GET /orders/{id}/history; POST /orders/{id}/cancel; admin: GET /admin/exceptions, POST /admin/orders/{id}/reconcile

**HTTP, Orchestrator to Payment Adapter:**
- POST /payments: attemptId, orderId, amountMinor, currency, callbackUrl. Idempotent by attemptId. Returns attemptId, status (PENDING | CONFIRMED | FAILED)
- GET /payments/{attemptId}: never charges, returns current status

**Payment callback (Adapter to Orchestrator `/internal/payment-callbacks`):** providerEventId, attemptId, orderId, status (CONFIRMED | FAILED), occurredAt

**Error responses:** 400, 401, 403, 404, 409, 429, 503 only. Never leak upstream messages or stack traces.

## Before writing code in any file

- Check that the change belongs in that file/package per the layout above.
- Check the Contracts section for exact field names and states.
- Check the Non-negotiable rules above; if the task conflicts with one, stop and say so.
- Build and test after any change: `go build ./... && go test ./...` (Go), `./mvnw test` (Java), `npm test` (Node). Run `go mod tidy` after adding an import.

## Tests that must exist

- Orchestrator: table-driven tests for `Transition` (every state x event); duplicate intake with same and different payload; the same event delivered twice.
- Inventory: 50 concurrent reservations on limited stock never oversell; double release restores stock once.
- Payment: timeout then reconcile; duplicate callbacks; forged signature rejected; delayed success.
- End to end: happy path, out of stock, payment failure, cancel after reserve, broker restart mid-flow.

## Style

- Go: standard idioms, wrap errors with `%w`, no panics outside `main()` startup, `context.Context` as first param on any function that does I/O, structured logs with `log/slog`.
- Java: constructor injection, plain SQL via `JdbcClient`, one `@Transactional` method per event handler, no business logic in listeners.
- TypeScript: strict mode, DTO classes with `class-validator`, `ValidationPipe` with `whitelist` and `forbidNonWhitelisted`, JSON logs with `pino`.
- Every log line touching an order includes `orderId` and `correlationId`. `correlationId` is generated at the gateway and propagated through HTTP headers and the Kafka envelope.
- Config comes from env vars with documented defaults. No secrets in git. Seed data is synthetic only.
- Commits: small, one concern each, format `type(scope): summary`.

## Working with Ahmed

- Ahmed is a junior backend developer building this to learn and to explain it in interviews. After code, explain WHY at code level: the SQL, the transaction boundary, and which failure it prevents.
- Build in plan order: platform (Day 1), Orchestrator intake + outbox (Day 2), then Inventory, Payment, gateway.
- Values marked "proposed" or "assumption" (partition count 3, timeouts, Kafka client libraries, event `data` fields) may change. Record any change in `docs/decisions.md`.
