#!/usr/bin/env bash
# Jobline fixture: the spec and draft plan for async job execution, before any code.
# Design-mode case; documents written by clean agents (see the case design).
set -euo pipefail
git init -q -b main
git config user.email eval@example.invalid
git config user.name eval

mkdir -p docs/specs && cat > docs/specs/async-job-execution.md <<'__FIXTURE_EOF__'
# Spec: Asynchronous job execution

**Status:** Draft for review · **Date:** 2026-09-23 · **Reviewers:** job-orders, data service, auth, platform, security

## 1. Existing system

Jobline runs in one Kubernetes cluster. Services are Python 3.12 / FastAPI, backed by Postgres and S3-compatible object storage.

| Component | Role today |
|---|---|
| gateway | The only internet-facing component. Terminates TLS and routes to internal services over plain HTTP. |
| auth service | Issues PASETO tokens to users. The tenant is a claim in the token. |
| job-orders service | Accepts and lists job orders. Executes each job **synchronously inside the submit request**. |
| data service | Holds tenant data. |
| results store | Object-storage bucket for rendered reports. |

**Submit flow today.** User → gateway → job-orders. Within that one request job-orders reads the input (from the data service, or by fetching the tenant-supplied URL from its own pod), renders the report, writes it to the results store, records the run for metering, and responds. Status, listing, cancel and download are served by job-orders through the gateway.

Properties that matter for this change:

- Internal traffic is plain HTTP. There is no service mesh and none is planned.
- There is no service-to-service authentication; internal services trust callers because of where they sit on the network.
- Tenant-URL fetches already originate inside the cluster (from the job-orders pod).
- Large reports run past the request timeout. The client gets an error, it's unclear what happened to the run, and long requests tie up job-orders capacity.

## 2. Change overview

Execution moves out of the request. job-orders saves the order and puts a message on a RabbitMQ queue. A new **worker** service picks up the message, runs the job and reports back to job-orders. job-orders stays the system of record for order state, metering and downloads. Services authenticate to each other with short-lived PASETO **service tokens** issued by the auth service (§8).

1. The user submits through the gateway. job-orders validates the order and writes the order, a run (`queued`) and an outbox row in one transaction, then returns `202`.
2. The outbox relay in job-orders publishes a `job.execute.v1` message (§5).
3. A worker consumes the message and calls `claim` on job-orders (§7). job-orders atomically moves the run to `running`, grants a lease, gets a **job ticket** from auth and returns the input plus the ticket.
4. The worker acks the message, reads the input (data service with the ticket, or the tenant URL through the egress proxy), renders the report, uploads the result and renews its lease every 30 s (heartbeat).
5. The worker calls `complete` or `fail`. job-orders moves the run to its terminal state and writes the usage record in the same transaction (§10).
6. The user polls status and downloads through gateway → job-orders.

**Non-goals:** cancelling a running job; mTLS or a mesh; changing the user token format; changing report rendering.

## 3. Job lifecycle and data model

| Run state | Public order status | Meaning |
|---|---|---|
| `queued` | `pending` | Waiting for a worker (first attempt or waiting to retry) |
| `running` | `running` | Claimed; a worker holds a lease |
| `succeeded` | `succeeded` | Result stored |
| `failed` | `failed` | Permanent failure, attempts used up, or timeout |
| `cancelled` | `cancelled` | Cancelled by the tenant while pending |

Transitions. Each one is a single conditional `UPDATE … WHERE state = … RETURNING`, so concurrent callers can't both succeed:

- `queued → running` (claim): requires `not_before <= now()`. Increments `attempt`, sets `lease_id`, `lease_expires_at = now() + 120 s`, and sets `started_at` if it is null.
- `queued → cancelled` (tenant cancel). If cancel and claim race, the first to commit wins and the other gets `409`.
- `running → succeeded | failed` (worker `complete` or `fail`): requires a matching `lease_id`.
- `running → queued` (retryable failure or lease expiry) when `attempt < 3`. Sets `not_before` with 30 s / 2 min backoff and writes an outbox row that is due at `not_before`.
- `running → failed`: permanent failure, attempts used up, or `started_at + max_duration + 5 min` exceeded.

A **sweeper** in job-orders runs every 30 s using `FOR UPDATE SKIP LOCKED`. It:
- (a) treats `running` runs whose lease has expired as a retryable `worker_lost` failure;
- (b) fails runs that are past their maximum duration;
- (c) re-publishes `queued` runs that have been due for more than 10 min without a claim. This covers lost or dead-lettered messages.

**Tables (new or changed):**
- `job_runs`: `id, order_id, tenant_id, state, attempt, lease_id, lease_expires_at, not_before, started_at, finished_at, result_key, result_sha256, result_size, failure_code`. There is one run per order in this change.
- `outbox`: `id, topic, payload, not_before, published_at`.
- Usage records: add a unique constraint on `run_id`.

## 4. Public API (via gateway)

User authentication is unchanged: the user's PASETO token, with the tenant taken from its claim. Every lookup is scoped to that tenant. Another tenant's order returns `404`, not `403`.

| Endpoint | Behaviour |
|---|---|
| `POST /v1/job-orders` | **Changed.** Validates and enqueues, then returns `202 Accepted` with a `Location` header. It no longer waits for execution. Accepts an optional `Idempotency-Key` header (kept 24 h, per tenant). |
| `GET /v1/job-orders/{id}` | Returns the order (below). |
| `GET /v1/job-orders?status=` | Lists orders, optionally filtered by status. |
| `POST /v1/job-orders/{id}/cancel` | `200` with `status: cancelled` if the order is pending (also when it is already cancelled). Otherwise `409 order_not_cancellable` with the current status. |
| `GET /v1/job-orders/{id}/result` | Streams the result from the results store through job-orders. Returns `409 result_not_ready` unless the order has `succeeded`. |

```json
{
  "id": "jo_01J8ZQ...", "report_type": "sales_summary", "status": "failed",
  "created_at": "2026-09-23T10:15:02Z", "started_at": "2026-09-23T10:15:04Z",
  "finished_at": "2026-09-23T10:19:40Z", "attempts": 1,
  "failure": { "code": "input_fetch_failed", "message": "Input URL returned HTTP 403." },
  "result": null
}
```

When the order has succeeded, `result` is `{"content_type", "size_bytes", "url": "/v1/job-orders/{id}/result"}`. `failure.message` is safe to show the tenant: it never contains internal hostnames, stack traces or proxy details.

URL inputs are checked at submission: the URL must parse, the scheme must be `https` (see §14 Q1), it must have no userinfo, and the host must not be an IP literal. Failures return `422 input_url_invalid`. The checks that depend on DNS happen at fetch time (§9).

## 5. Queue and message format

- Exchange `jobline.jobs` (direct, durable), routing key `job.execute`.
- Queue `jobs.execute` (quorum), `x-delivery-limit: 5`, dead-lettered to `jobs.execute.dlq`. An alert fires if the DLQ is non-empty.
- **Publisher:** the job-orders outbox relay, with publisher confirms and persistent delivery. An outbox row is marked published only after the confirm arrives, so delivery is at-least-once.
- **Consumer:** worker, manual ack, `prefetch = 1`.
- **Access:** vhost `jobline`. Each service has its own RabbitMQ user with credentials in a Kubernetes Secret. `job-orders` may write only to `jobline.jobs`; `worker` may read only from `jobs.execute`. Neither can configure. AMQP is unencrypted inside the cluster, like HTTP.

Message properties: `message_id = <outbox id>`, `type = job.execute.v1`, `content_type = application/json`.

```json
{ "schema": "job.execute.v1", "run_id": "run_01J8ZQ...", "order_id": "jo_01J8ZQ...", "enqueued_at": "2026-09-23T10:15:02Z" }
```

The message deliberately carries **no tenant ID, input, URL or credentials**. It only tells a worker to go and claim the run; job-orders decides. A duplicate or forged message can at most start a claim that job-orders rejects, or run a run that is already legitimately queued and due.

## 6. Worker behaviour

1. **Validate** the message schema. If it is invalid, ack it and log an error; poison messages are not requeued.
2. **Claim** the run with `POST /internal/v1/runs/{run_id}/claim`.
   - `200`: ack the message and continue.
   - `409` or `404`: ack and drop.
   - `5xx` or network error: nack with requeue after a local backoff (1 s doubling to 30 s). After 5 deliveries the message goes to the DLQ; the sweeper (§3c) re-publishes the run later.
3. **Heartbeat** every 30 s for the whole run. If a heartbeat returns `409 lease_lost`, or the lease can't be renewed before it expires, the worker aborts the run, throws away its output and does **not** call `complete`.
4. **Read input.** `dataset` inputs come from the data service using the service token and job ticket (§8.3). `url` inputs are fetched through the egress proxy (§9).
5. **Render**, then upload to `results/{tenant_id}/{order_id}/{run_id}/attempt-{n}/{filename}`. `tenant_id` comes from the claim response.
6. **Report** with `complete` (retried on `5xx`; the call is idempotent) or `fail` with a `code` and a `retryable` flag (§11).
7. **Enforce the maximum duration**, `max_duration_s` from the claim (default 3600). When it is exceeded, the worker reports `fail(code=timeout, retryable=false)`.
8. **On SIGTERM**, stop consuming and finish the current run within `terminationGracePeriodSeconds` (15 min). If the run can't finish in time, report `fail(code=worker_shutdown, retryable=true)`.

## 7. Internal APIs

Internal endpoints listen on a separate port (`:8081`) that the gateway does not route. A CI check asserts that no gateway route targets `:8081` or `/internal`. All calls need a service token (§8).

**job-orders** (callers: `sub = svc:worker`, `aud = svc:job-orders`; NetworkPolicy allows only worker pods):

| Endpoint | Body | Success | Errors |
|---|---|---|---|
| `POST /internal/v1/runs/{run_id}/claim` | `{"worker_id"}` | `200` claim response | `409 run_not_claimable` (`reason`: `cancelled` / `terminal` / `running` / `not_due`), `404`, `503 ticket_unavailable` |
| `POST …/heartbeat` | `{"lease_id"}` | `200 {"lease_expires_at"}` | `409 lease_lost` |
| `POST …/complete` | `{"lease_id", "result": {"key", "content_type", "size_bytes", "sha256"}}` | `200` (repeat calls with the same lease and key return `200`) | `409 lease_lost`, `422 result_key_invalid` (the key is not under this run's attempt prefix) |
| `POST …/fail` | `{"lease_id", "code", "retryable", "detail"}` | `200 {"outcome": "retry_scheduled" \| "failed"}` | `409 lease_lost` |

Claim response:

```json
{
  "run_id": "run_01J8ZQ...", "order_id": "jo_01J8ZQ...", "tenant_id": "t_4821", "attempt": 1,
  "lease_id": "ls_01J8ZR...", "lease_expires_at": "2026-09-23T10:17:04Z", "max_duration_s": 3600,
  "report_type": "sales_summary", "params": { "period": "2026-Q3" },
  "input": { "kind": "url", "url": "https://exports.example.com/q3.csv" },
  "job_ticket": "v4.public.eyJ..."
}
```

job-orders gets the ticket from auth *before* it commits the claim. If auth is unavailable, the claim returns `503`, the run stays `queued` and no attempt is used up. `fail.detail` is internal only: it is logged but never shown to the tenant.

**auth service** (`:8081`):
- `POST /internal/v1/service-tokens`: the caller authenticates with its Kubernetes projected ServiceAccount token (§8.1). Body `{"audience": "svc:data"}`, response `{"token", "expires_at"}`.
- `POST /internal/v1/job-tickets`: the caller must present a service token with `sub = svc:job-orders` and `aud = svc:auth`. Body `{"tenant_id", "order_id", "run_id", "dataset_ids", "ttl_s"}`, response `{"ticket", "expires_at"}`.

## 8. Service-to-service authentication

### 8.1 Service identity and bootstrap

Each service runs under its own Kubernetes ServiceAccount, with `automountServiceAccountToken: false`. Instead, each pod mounts a projected SA token with audience `jobline-auth` and a 10-minute expiry; the kubelet rotates it. The service sends this token to `POST /internal/v1/service-tokens`. Auth validates it with the Kubernetes TokenReview API, which checks the audience and that the token is bound to a live pod. Auth then maps the SA to a service identity and checks the requested audience against this static policy:

| ServiceAccount | Identity | May request `aud` |
|---|---|---|
| `jobline/job-orders` | `svc:job-orders` | `svc:auth` |
| `jobline/worker` | `svc:worker` | `svc:job-orders`, `svc:data` |

Clients cache service tokens until 60 s before they expire.

### 8.2 Token formats

All new tokens are **`v4.public`** (Ed25519). Only auth holds the private keys, so a compromised service that can verify tokens still can't create them. Each token purpose has its **own key** and its own PASETO **implicit assertion**. As a result, a user token can't pass as a service token or ticket, or the other way round.

| | Service token | Job ticket |
|---|---|---|
| Implicit assertion | `jobline:service-token:v1` | `jobline:job-ticket:v1` |
| Footer | `{"kid": "svc-2026-09"}` | `{"kid": "tkt-2026-09"}` |
| `iss` | `jobline-auth` | `jobline-auth` |
| `sub` | caller identity, e.g. `svc:worker` | `run:{run_id}` |
| `aud` | exactly one target, e.g. `svc:data` | `svc:data` |
| `exp` | `iat` + 5 min | claim time + `max_duration_s` + 5 min |
| Other claims | `jti` | `jti`, `tid`, `order_id`, `run_id`, `dataset_ids`, `holder: svc:worker` |

Every verifier checks the signature using the `kid` from its key set for that purpose, the implicit assertion, `iss`, that `aud` is its own identity, and `exp` / `nbf` / `iat` with 60 s leeway. It also checks `sub` against the endpoint's allow-list. Tokens and tickets are never logged; logs record `jti`, `sub` and `run_id` instead.

**Key distribution.** Public keys go out in a ConfigMap (`jobline-token-keys`, PASERK `k4.public` with `kid`, purpose and `not_after`) mounted into verifying pods, **not over HTTP**. An unauthenticated HTTP key endpoint on the plain-text pod network would let an on-path attacker swap in their own key. Private keys are in a Secret mounted only into auth pods. To rotate a key: publish the new public key, wait at least 10 min for it to reach all pods, switch signing to it, and remove the old key once the longest token lifetime (about 70 min) has passed.

### 8.3 Data service access for jobs

The worker sends both credentials:

```
Authorization: Bearer <service token: sub=svc:worker, aud=svc:data>
X-Jobline-Job-Ticket: <job ticket>
```

For `svc:worker` callers the data service requires both. The ticket's `holder` must equal the service token's `sub`. Tenant scope comes **only** from the ticket's `tid`, and reads are limited to the ticket's `dataset_ids`. A request that names a different tenant or dataset gets `403`; a missing ticket gets `401`. Existing callers that use user tokens are unaffected. The worker therefore never asserts a tenant itself: it can only act for runs job-orders has leased to it.

### 8.4 Network policy

Token checks are backed by default-deny NetworkPolicies in the `jobline` namespace. Only these paths are allowed:
- gateway → job-orders `:8080`, auth `:8080`
- job-orders → auth `:8081`, RabbitMQ, Postgres, object storage
- worker → job-orders `:8081`, data `:8080`, auth `:8081`, RabbitMQ, object storage, egress proxy

The worker has **no direct internet egress**.

Object storage and RabbitMQ use their own per-service credentials, not PASETO. The worker's object-storage key can only `PutObject` under `results/`; job-orders' key can only read.

## 9. Tenant URL inputs (SSRF controls)

Moving URL fetching into the worker puts it in a process that holds credentials for job-orders, the data service, RabbitMQ and object storage, on a network where internal calls are plain HTTP. Controls:

1. The worker fetches only through the **egress proxy** (e.g. Smokescreen), using a dedicated HTTP client with no default headers, cookies or auth. Jobline credentials are never attached.
2. The proxy resolves DNS itself and connects to the IP it resolved, which defeats DNS rebinding. It denies loopback, RFC 1918, link-local (including `169.254.169.254`), `100.64.0.0/10`, IPv6 ULA and link-local, the cluster pod and service CIDRs, and the node network. Only port 443 is allowed.
3. The proxy's own NetworkPolicy allows egress to the internet only, so blocking doesn't depend on the proxy's code alone.
4. At most 3 redirects are followed. Each hop is re-checked (it must stay `https`) and goes through the proxy.
5. Limits: 10 s connect timeout, 10 min total, 500 MB body, streamed to local disk.
6. A blocked URL fails with `input_url_blocked` (permanent). The tenant-facing message doesn't reveal what the proxy saw.
7. URLs are logged with the query string redacted, because tenant export URLs often embed signed credentials.

## 10. Metering

- A run is **executed** once it has been claimed (`started_at` is set). Runs cancelled before any claim are not metered.
- Each executed run gets **exactly one** usage record. job-orders writes it in the same transaction as the run's terminal transition: `succeeded`, `failed`, or `cancelled` after an earlier attempt. It uses `INSERT … ON CONFLICT (run_id) DO NOTHING`.
- Fields: `tenant_id, order_id, run_id, report_type, outcome, attempts, started_at, finished_at, duration_ms, input_bytes, output_bytes`.
- Retries, redeliveries and duplicate executions of one run (e.g. a worker cut off by a network partition) still produce one record. The worker never writes usage.
- Every outcome is recorded. Whether failed runs are billed is a pricing decision (§14 Q2).

## 11. Error cases

| Case | Result |
|---|---|
| Invalid order or URL syntax | `422` at submit |
| RabbitMQ down at submit | Submit still returns `202` (outbox). Publishing is delayed; alert when the oldest unpublished row is older than 5 min |
| Auth down at claim | `503`; the worker requeues; the run stays `queued` and no attempt is used |
| Cancel/claim race | The first commit wins; the other side gets `409` |
| Cancel while running | `409 order_not_cancellable` |
| Duplicate message | Claim returns `409`; the worker acks and drops it |
| Message lost or dead-lettered | Sweeper re-publishes after 10 min |
| Worker crash mid-run | Lease expires within 120 s; the sweeper retries (`worker_lost`) or fails the run after 3 attempts |
| Worker partitioned but still running | The worker aborts when its lease is lost. A late `complete` gets `409 lease_lost`. Its object sits under its own attempt prefix and is deleted by a 7-day lifecycle rule |
| `complete` fails after upload | The worker retries (idempotent). If the lease expires first, the next attempt re-renders |
| Data service `5xx` or timeout | `data_unavailable`, retryable |
| Data service `401`/`403` | `internal_error`, permanent. Alerts, since it points to misconfiguration or tampering |
| URL blocked / fetch `4xx` / fetch `5xx` or timeout | `input_url_blocked` (permanent) / `input_fetch_failed` (permanent) / `input_fetch_failed` (retryable) |
| Input over 500 MB | `input_too_large`, permanent |
| Renderer rejects the input | `render_failed`, permanent |
| Maximum duration exceeded | `timeout`, permanent |
| Object store upload fails | `result_store_unavailable`, retryable |
| Service token expired or rejected | `401`. The client fetches a new token and retries once; a second `401` raises an error and alert |
| Download before success / another tenant's order | `409 result_not_ready` / `404` |

## 12. Security considerations and residual risk

- **Plain HTTP.** Service tokens and tickets are bearer credentials sent in cleartext on the pod network. Anyone who can observe pod traffic (a compromised node or CNI, or a privileged pod) can replay a service token for up to 5 min against its one audience, or a ticket plus a token for one run's datasets within the run's lifetime. They could also tamper with responses. Mitigations are short TTLs, single audiences, holder binding, separate keys per purpose, default-deny NetworkPolicies, and key distribution through a ConfigMap. Under the no-mesh constraint **we accept this residual risk**; user tokens already have the same exposure. It should be reviewed again if the constraint changes.
- **Blast radius.** A compromised worker can read data only for runs it holds or claims from the queue. It can't mint tokens or tickets, or pick a tenant or dataset. A compromised job-orders can request tickets for any tenant, which is no worse than today, where it runs every tenant's jobs directly.
- **Result integrity.** job-orders rejects result keys outside the run's `results/{tenant_id}/{order_id}/{run_id}/attempt-{n}/` prefix. Downloads read only the `result_key` stored on the tenant's own order.
- **Untrusted input.** The worker renders tenant-supplied files. It runs as non-root with a read-only root filesystem, and its only mounted credential is the audience-scoped projected token.

## 13. Rollout

1. Ship the auth internal endpoints, the key ConfigMap, and the job-orders internal API.
2. Deploy RabbitMQ, the worker, the egress proxy and NetworkPolicies. Where the CNI supports it, run the policies in audit mode first.
3. Add a per-tenant flag `async_execution`. With the flag off, the current synchronous path is used. `POST` returning `202` is a **breaking change for API integrations**, so tenants with API clients are notified before we enable it for them.
4. Enable for the internal tenant, then roll out gradually. Remove the synchronous path once every tenant is migrated.
5. Make the data service reject internal callers that don't present a service token (log-only for one week first).

## 14. Open questions

1. Should `http://` tenant URLs be allowed? Recommendation: no. We need data on current usage before deciding.
2. How are failed runs, and runs cancelled after an attempt, priced? Metering records them either way.
3. What maximum duration should each report type get? The default is 60 min.
4. Should tenants be able to cancel running jobs? This could later be done with a `cancel_requested` flag in the heartbeat response.
__FIXTURE_EOF__

mkdir -p docs/plans && cat > docs/plans/async-job-execution.md <<'__FIXTURE_EOF__'
# Plan: Asynchronous job execution

**Spec:** `docs/specs/async-job-execution.md` (draft, 2026-09-23) · **Status:** Draft plan · **Date:** 2026-09-23

## Assumptions

- This draft was written from the spec alone. The repo wasn't inspected, so every file path below is a proposal. Map the paths to the real layout before starting.
- Assumed layout: `services/<name>/app/…`, a new `services/worker/`, shared packages in `libs/`, manifests in `deploy/`, CI scripts in `ci/`.
- Proposed libraries: `pyseto` (PASETO v4.public, implicit assertions, PASERK), `aio-pika` (RabbitMQ), `httpx` (every HTTP client), `pydantic` / `pydantic-settings` (schemas, config), the existing job-orders DB stack (assumed to be SQLAlchemy async, Alembic and asyncpg; confirm), `aioboto3` (object storage), Smokescreen (egress proxy), `prometheus_client` (metrics), and `pytest`, `respx` and `testcontainers` (tests).
- Open questions in spec §14: the plan assumes `https` only (Q1) and a 3600 s default max duration from a per-report-type config (Q3). Metering records every outcome either way (Q2).

## Spec gaps to resolve

Tasks refer to these by number. Each gap has a proposed default, which the plan uses until the spec author decides otherwise.

- **G1. Max-duration clock.** The sweeper deadline is based on `started_at`, which is set at the first claim and never reset. The worker's timer and the ticket `exp` start again at each claim. So the sweeper can kill attempts 2–3 early, and backoff time counts against the limit. Also, `max_duration_s` isn't stored on `job_runs`, so the sweeper can't compute a deadline. *Default:* add `job_runs.max_duration_s` and `attempt_started_at`, and base the sweeper deadline on `attempt_started_at`.
- **G2. Sweeper re-publish marker.** Nothing records that §3(c) has re-published a run. Once a run is 10 min overdue, every 30 s sweep publishes it again. *Default:* add `job_runs.last_enqueued_at` and `outbox.run_id`. (c) skips runs that were enqueued in the last 10 min or still have an unpublished outbox row.
- **G3. Missing columns.** The API returns `result.content_type`, but `job_runs` has no column for it. The example `failure.message` ("…HTTP 403") needs data that `failure_code` alone doesn't hold, and `fail.detail` is internal only. *Default:* add `result_content_type` and `failure_message`. job-orders renders the message from a per-code template plus an allow-listed `public_params` object in the `fail` body (for now only `http_status`).
- **G4. Metering inputs.** Nothing supplies `input_bytes`: neither `complete` nor `fail` carries it. `duration_ms` isn't defined for runs with retries. *Default:* add `input_bytes` to both bodies, and set `duration_ms = finished_at − started_at` (includes backoff). Confirm with pricing.
- **G5. Orphan cleanup deletes real results.** A 7-day lifecycle rule on `results/` can't tell orphaned attempt objects from delivered reports. *Default:* the worker uploads with the tag `jobline-state=unconfirmed`, the lifecycle rule expires tagged objects only, and job-orders removes the tag during `complete`. job-orders then needs tagging permission, not just read.
- **G6. Result overwrite.** The worker's key can `PutObject` anywhere under `results/`, so a compromised worker could overwrite another tenant's delivered report. §12's blast-radius claim doesn't cover this. *Default:* turn on bucket versioning. `complete` records the object's `version_id`, and downloads fetch that exact version.
- **G7. NetworkPolicy omissions (§8.4).** The allow-list leaves out: DNS for every pod; auth → kube-apiserver (TokenReview); the data service's own egress; metrics scraping; existing data-service callers. It also leaves out job-orders → data `:8080` and job-orders → internet, which the synchronous path needs for flag-off tenants. Applying §8.4 as written at rollout step 2 breaks the synchronous path. *Default:* keep those job-orders paths, or send sync fetches through the egress proxy, until the sync path is removed.
- **G8. Dataset not found.** Dataset IDs aren't checked at submit. A wrong or deleted ID gets a data-service `403`, which §11 turns into `internal_error` plus a tampering alert. *Default:* the data service returns `404` when a dataset is in the ticket but doesn't exist under `tid`. The worker maps that to a new permanent code `input_not_found`. `403` stays reserved for scope violations.
- **G9. §12 corrections (no design change).**
  - (a) §12 says the worker's only mounted credential is the projected token, but it also mounts RabbitMQ and object-storage secrets.
  - (b) The projected SA token also crosses the plain-HTTP network. Anyone who captures it can mint service tokens for all of that SA's audiences for up to 10 min.
  - (c) Tickets aren't bound to a lease, so a worker that has lost its lease can keep reading data until the ticket expires.
- **G10. Idempotency-Key semantics.** The spec doesn't define where keys are stored, how requests are fingerprinted, what happens when the same key arrives with a different body, or whether keys apply to the sync path. *Default:* table `idempotency_keys`. Same key and same body replays the original response; a different body returns `422 idempotency_key_reused`. Keys apply to both paths.
- **G11. Deploys use up attempts.** The 15-min grace period is shorter than the 60-min default max duration. Every rolling deploy during a long job uses one of the 3 attempts through `worker_shutdown`. **Decision needed.** The plan implements the spec as written and adds a metric.
- **G12. Orders without runs.** Sync-path and historical orders have no `job_runs` row, but status, list, cancel and download now read runs. *Default:* the sync path writes a terminal `job_runs` row, and a migration backfills existing orders.
- **G13. `fail` isn't idempotent.** If a `fail` retry follows a first call that did commit a retry, it gets `409 lease_lost`. *Default:* a repeat `fail` with the same `lease_id` returns the original outcome.

---

### Task 1: Shared token library

- [ ] Create `libs/jobline-tokens/jobline_tokens/` with `pyseto`. It holds verification and client code only; signing stays in auth.
- [ ] `keys.py` loads the PASERK `k4.public` entries (`kid`, `purpose`, `not_after`) from the mounted `jobline-token-keys` ConfigMap directory.
  - Keep one key set per purpose and drop keys past `not_after`.
  - Poll the mtime every 30 s and reload on change. The ConfigMap must be mounted as a directory without `subPath`, or updates never arrive.
- [ ] `verify.py`: `verify_service_token(token, expected_aud, allowed_subs)` and `verify_job_ticket(ticket, expected_aud)`. Checks, in this order, inside each function:
  - Look up the footer `kid` in *that purpose's* key set only. An unknown `kid` is rejected.
  - Verify the signature with the purpose's implicit assertion.
  - `iss == jobline-auth`.
  - `aud` is a single string equal to the verifier's own identity.
  - `exp` / `nbf` / `iat` with 60 s leeway.
  - `sub` is in the allow-list.
  - Tickets also need `sub == run:{run_id}` and `holder`, `tid`, `order_id`, `dataset_ids` to be present.
- [ ] `fastapi.py`: dependency `require_service_token(aud, allowed_subs)`. It reads `Authorization: Bearer`, returns `401` with no reason on any failure, and stores `sub` and `jti` on request state for logging.
- [ ] `client.py`: `ServiceTokenClient` (`httpx`).
  - Re-reads the projected SA token file on each fetch, because the kubelet rotates it.
  - Calls auth `POST /internal/v1/service-tokens`.
  - Caches one token per audience until `expires_at − 60 s`, and lets only one refresh run at a time.
  - Helper `call_with_service_token`: on a `401`, drop the cached token, fetch a new one and retry once. A second `401` raises `ServiceAuthError` and increments `service_token_auth_failures_total`.
- [ ] `logging.py`: a log filter that strips `Authorization`, `X-Jobline-Job-Ticket` and any `v4.public.` string. Only `jti`, `sub` and `run_id` are logged.
- [ ] Tests (`libs/jobline-tokens/tests/`):
  - Cross-purpose rejection: user token used as a service token, ticket used as a service token, service token used as a ticket, correct key with the wrong implicit assertion.
  - Wrong `aud`; `aud` given as a list; expiry beyond the leeway; unknown `kid`; key past `not_after`.
  - A key reload takes effect without a restart.

### Task 2: Auth: signing keys and key distribution

- [ ] `tools/token-keys/generate.py` (`pyseto`) creates one Ed25519 pair per purpose. It outputs `k4.secret` for the auth Secret and a `k4.public` entry for the ConfigMap.
- [ ] Mount `deploy/k8s/auth/token-signing-keys.secret.yaml` into auth pods only. Mount `deploy/k8s/jobline/token-keys.configmap.yaml` (`jobline-token-keys`) into the verifying pods: auth, job-orders and data. The worker verifies nothing and doesn't get it.
- [ ] `services/auth/app/tokens/signer.py` signs with the purpose's active `kid`, implicit assertion and `{"kid"}` footer.
  - The active kid comes from config `ACTIVE_KIDS`, kept separate from the key material, so the "switch signing" rotation step is a config change.
  - Startup check: every active signing key's public half must be in the mounted ConfigMap. Otherwise auth refuses to sign.
- [ ] `docs/runbooks/token-key-rotation.md`: publish the new key, wait ≥ 10 min, switch, then remove the old key after the longest token lifetime. Give that lifetime as `max(max_duration_s) + 5 min + 60 s`, because §14 Q3 can raise it above 70 min.
- [ ] Tests:
  - The signer refuses to start when its public key isn't published.
  - Tokens signed with the old `kid` still verify during the overlap.

### Task 3: Auth: internal API on `:8081`

- [ ] `services/auth/app/internal/app.py` is a separate FastAPI app, served by a second uvicorn server on `:8081` (port declared in `deploy/k8s/auth/deployment.yaml`). Test that `/internal/*` returns `404` on `:8080`.
- [ ] `services/auth/app/internal/service_tokens.py`: `POST /internal/v1/service-tokens`. Checks, in order:
  - A bearer token is present.
  - `services/auth/app/k8s/tokenreview.py` sends it to TokenReview (`httpx` to kube-apiserver, `audiences: ["jobline-auth"]`). The result must be authenticated, carry the `jobline-auth` audience and be bound to a pod (`authentication.kubernetes.io/pod-name` in `extra`).
  - `services/auth/app/tokens/policy.py` maps the SA to an identity using the static §8.1 table. An unknown SA gets `403`.
  - The requested `audience` must be on that identity's allow-list, or `403`.
  - Sign the token with `exp = iat + 5 min` and a fresh `jti`.
- [ ] Cache positive TokenReview results by token hash for ≤ 60 s.
- [ ] Auth's own credential for the API server: a projected token for the API audience, plus `deploy/k8s/auth/rbac-tokenreview.yaml` binding `system:auth-delegator`. It's needed because automount is off.
- [ ] `services/auth/app/internal/job_tickets.py`: `POST /internal/v1/job-tickets`. Checks, in order:
  - `require_service_token(aud="svc:auth", allowed_subs={"svc:job-orders"})`.
  - pydantic body validation: ID formats; `dataset_ids` may be empty for URL inputs; `ttl_s` between 60 and a configured cap (longest report-type max duration + 5 min).
  - Sign the ticket with `sub = run:{run_id}`, `aud = svc:data`, `holder = svc:worker`.
- [ ] Audit log for every issued token or ticket: `jti`, `sub`, `aud`, `run_id`.
- [ ] Tests: unknown SA; disallowed audience; legacy non-pod-bound SA token; wrong TokenReview audience; ticket requested by `svc:worker`; `ttl_s` above the cap.

### Task 4: job-orders: schema migration

- [ ] `services/job-orders/migrations/versions/<rev>_async_execution.py` creates `job_runs`.
  - Columns: the spec columns plus `max_duration_s` and `attempt_started_at` (G1), `last_enqueued_at` (G2), `result_content_type` and `failure_message` (G3), `input_bytes` (G4), `result_version_id` (G6).
  - CHECKs on `state` and on `attempt BETWEEN 0 AND 3`; unique `order_id`.
  - Partial indexes on `(lease_expires_at) WHERE state='running'` and `(not_before) WHERE state='queued'`.
- [ ] `outbox` with the spec columns plus `run_id` (G2), and a partial index on `not_before WHERE published_at IS NULL`.
- [ ] `idempotency_keys` (G10): PK `(tenant_id, key)`, plus `request_sha256`, `order_id`, `expires_at`.
- [ ] Usage records:
  - Add `run_id` if the column doesn't exist.
  - Build the unique index with `CREATE UNIQUE INDEX CONCURRENTLY` in its own non-transactional migration, then attach it as the constraint.
  - Legacy rows keep `run_id NULL`, which Postgres treats as distinct.
- [ ] A separate batched data migration backfills terminal `job_runs` rows for existing orders (G12).
- [ ] Test: migrate up and down on a `testcontainers` Postgres with seed data.

### Task 5: job-orders: run state machine and metering

- [ ] `services/job-orders/app/runs/states.py` holds:
  - the state enum and the run state → public status map (§3);
  - `MAX_ATTEMPTS = 3` and backoff `[30 s, 2 min]`;
  - the failure-code catalogue, marking each code retryable or permanent.
- [ ] `services/job-orders/app/runs/repository.py` has one function per transition. Each one is a single `UPDATE … WHERE id AND state AND <guard> RETURNING`, and guards use DB `now()`.
  - claim: `state='queued' AND not_before <= now()`.
    - Increments `attempt` and sets `attempt_started_at` and `started_at = coalesce(started_at, now())`.
    - Sets `lease_expires_at = now() + 120 s`.
    - Generates `lease_id` with `secrets.token_urlsafe`, not a monotonic ULID, because the lease ID is the capability for heartbeat, complete and fail.
  - cancel: `state='queued'`.
  - heartbeat: `state='running' AND lease_id AND lease_expires_at > now()`.
  - complete / fail: `state='running' AND lease_id`.
  - requeue: `attempt < 3`. Sets `not_before` and `last_enqueued_at`, and inserts the outbox row in the same transaction.
  - `lease_id` isn't cleared when a run leaves `running`, so repeat calls can be recognized (G13). Every lease-guarded UPDATE still requires `state='running'`.
  - When no row matches, the caller re-reads the run to choose between `404`, `409` and an idempotent `200`.
- [ ] `services/job-orders/app/metering/usage.py`: `record_usage` runs `INSERT … ON CONFLICT (run_id) DO NOTHING`.
  - It's called only from terminal transitions, in the same transaction: succeeded, failed, and cancelled when `started_at` is set.
  - The worker never calls it.
- [ ] Tests (`testcontainers`), each concurrent pair must produce exactly one winner:
  - claim vs claim, claim vs cancel, heartbeat vs sweeper, complete vs sweeper.
  - Each run has at most one usage row, and `attempt` never goes above 3.

### Task 6: job-orders: internal API on `:8081`

- [ ] `services/job-orders/app/internal/app.py` is a separate FastAPI app on `:8081`.
  - Router-level dependency: `require_service_token(aud="svc:job-orders", allowed_subs={"svc:worker"})`.
  - A test asserts that every route has it.
- [ ] `services/job-orders/app/internal/runs.py`, claim:
  - Validate the body.
  - Begin a transaction and run the repository claim; the row stays locked.
  - `services/job-orders/app/clients/auth.py` requests a ticket (`ServiceTokenClient` for `svc:auth`, `httpx` timeout about 2 s, `ttl_s = max_duration_s + 300`).
  - Commit and return the claim response.
  - If auth fails, roll back and return `503 ticket_unavailable`. The attempt isn't used.
  - A concurrent cancel waits on the row lock and then gets `409`, so the first commit wins.
  - If no row matched, re-read and return `404` or `409 run_not_claimable` with `reason`.
- [ ] heartbeat: repository heartbeat, then `200 {lease_expires_at}` or `409 lease_lost`.
- [ ] complete. Checks, in order:
  - Body schema.
  - Read the row. It must be `running` with a matching `lease_id`; otherwise go to the idempotency re-check below.
  - `services/job-orders/app/internal/result_keys.py` checks the key against the prefix `results/{tenant_id}/{order_id}/{run_id}/attempt-{attempt}/`, built from the DB row.
    - Reject `..`, `//`, `\`, percent-encoded separators, control characters and empty or overlong filenames with `422 result_key_invalid`.
  - `HeadObject` on the key and `version_id` (`aioboto3`): the object must exist and its size must match (G6).
  - Remove the `jobline-state` tag (G5). If that fails, return `503`.
  - Conditional UPDATE plus usage in one transaction.
  - Idempotency re-check: a `succeeded` run with the same `lease_id` and key returns `200`. Anything else returns `409 lease_lost`.
- [ ] fail:
  - Body schema. `code` must be one of the worker codes; `worker_lost` is sweeper-only and gets `422`.
  - `retryable` is honored only for codes classed as retryable in `states.py`.
  - Then: `attempt < 3` → requeue (`retry_scheduled`); otherwise → `failed` plus usage.
  - `failure_message` comes from `services/job-orders/app/failures.py` templates and `public_params` (G3).
  - `detail` is truncated to 4 KB and only logged.
  - A repeat with the same lease returns the original outcome (G13).
- [ ] Never log the ticket, the claim response body, or input URLs with query strings.
- [ ] Tests:
  - Every error row in the §7 table.
  - Auth down returns `503` and leaves `attempt` unchanged.
  - Result keys with `..`, a wrong attempt number or another run's prefix get `422`.
  - A repeated complete gets `200`; a late complete after requeue gets `409`.

### Task 7: job-orders: public API changes

- [ ] `services/job-orders/app/api/orders.py`, `POST /v1/job-orders`:
  - User-token auth is unchanged.
  - Order: validation (below), then the idempotency check, then the flag check (Task 22).
  - Flag on: in one transaction, insert the order, a `job_runs` row (`queued`, `not_before = now()`, `max_duration_s` from `services/job-orders/app/config/report_types.py`) and an outbox row. Return `202` with `Location: /v1/job-orders/{id}`.
  - Flag off: the existing synchronous path.
- [ ] URL validation lives in a shared `libs/jobline-urls/` so the worker can reuse it for redirects (Task 14). It runs before any DB write.
  - The URL must parse, use `https`, and have no userinfo.
  - The host must not be an IP literal. Reject anything `ipaddress` can parse, bracketed IPv6, and all-numeric, hex or octal hosts such as `2130706433` or `0x7f.1`.
  - Normalize IDNA and strip a trailing dot before checking.
  - Any failure returns `422 input_url_invalid`.
- [ ] `services/job-orders/app/api/idempotency.py` (G10): `INSERT … ON CONFLICT` on `(tenant_id, key)` inside the submit transaction, comparing `request_sha256`. A cleanup job deletes expired rows.
- [ ] GET, list, cancel and result all filter on the token's `tenant_id` inside the repository query, not after the fetch. Another tenant's ID returns `404`.
  - `?status=` accepts only public statuses and maps them to run states through `states.py`.
- [ ] cancel: repository cancel returns `200` with `status: cancelled`. If no row matched: already `cancelled` → `200`; anything else → `409 order_not_cancellable` with the current status.
- [ ] result:
  - `409 result_not_ready` unless the order has `succeeded`.
  - Stream `GetObject(result_key, VersionId=result_version_id)` through a `StreamingResponse`, with the stored content type, `Content-Disposition: attachment` and `X-Content-Type-Options: nosniff`.
  - The key always comes from the DB row.
- [ ] Tests:
  - Cross-tenant `404` on all four endpoints.
  - URL-validator table: every IP-literal encoding, userinfo, `http`, IDN.
  - Idempotent replay and mismatch.
  - `failure.message` never contains `detail`.

### Task 8: job-orders: outbox relay

- [ ] `services/job-orders/app/outbox/relay.py` is a lifespan background task in every replica. Loop:
  - Select due rows: `published_at IS NULL AND not_before <= now()`, `FOR UPDATE SKIP LOCKED`, batched.
  - Publish them and wait for confirms.
  - Set `published_at` and commit.
  - A crash or missing confirm leaves the row unpublished, so it's retried.
- [ ] `aio-pika` settings: publisher confirms on; passive declare of `jobline.jobs`; `mandatory=True`, and an unroutable message counts as a failure; persistent delivery; `message_id`, `type` and `content_type` set per §5.
- [ ] Payload model `JobExecuteV1` lives in `libs/jobline-messages/` and is shared with the worker. A test asserts it carries only `schema`, `run_id`, `order_id` and `enqueued_at`.
- [ ] Reconnect with backoff when the broker is down.
- [ ] Export `outbox_oldest_unpublished_age_seconds`, and delete published rows after 7 days.
- [ ] Tests (`testcontainers` RabbitMQ):
  - Rows are marked published only after the confirm.
  - A broker restart mid-batch loses nothing.
  - Rows with a future `not_before` aren't published early.

### Task 9: job-orders: sweeper

- [ ] `services/job-orders/app/sweeper.py` runs every 30 s in every replica. It selects candidate batches with `FOR UPDATE SKIP LOCKED`, then applies the Task 5 transitions, which re-check their guards.
  - (a) `running` with an expired lease → retryable failure with `worker_lost`: requeue if `attempt < 3`, otherwise `failed` plus usage.
  - (b) `running` past `attempt_started_at + max_duration_s + 5 min` (G1) → `failed(timeout)` plus usage.
  - (c) `queued` runs that have been due for more than 10 min, weren't enqueued in the last 10 min, and have no unpublished outbox row (G2) → new outbox row and `last_enqueued_at`.
- [ ] Metrics: `sweeper_actions_total{action}` and pass duration.
- [ ] Tests:
  - Each branch.
  - Two concurrent sweepers never act twice on a run.
  - A heartbeat landing mid-pass beats (a).
  - (c) doesn't re-publish on back-to-back passes.

### Task 10: RabbitMQ topology and access

- [ ] Deploy a 3-node RabbitMQ cluster (quorum queues need it) from `deploy/rabbitmq/cluster.yaml`. The plan assumes the Cluster Operator; confirm with platform.
- [ ] `deploy/rabbitmq/definitions.json` is applied by ops, never declared by the services:
  - vhost `jobline`;
  - exchange `jobline.jobs` (direct, durable) bound to quorum queue `jobs.execute` with routing key `job.execute`;
  - a policy for `x-delivery-limit: 5` and dead-lettering to `jobs.execute.dlq`.
- [ ] Give the DLQ a message TTL of 7 days (not in the spec). Otherwise nothing drains it and the "non-empty" alert never clears after the sweeper re-publishes.
- [ ] Permissions:
  - `job-orders`: configure none, write `^jobline\.jobs$`, read none.
  - `worker`: configure none, write none, read `^jobs\.execute$`.
  - Credentials live in the Secrets `rabbitmq-job-orders` and `rabbitmq-worker`, mounted as files.
- [ ] Integration test:
  - The job-orders user can't consume or declare.
  - The worker user can't publish.
  - Passive declare works under these permissions.

### Task 11: Extract the renderer

- [ ] Move rendering from job-orders into `libs/jobline-render/` with no behavior change; rendering changes are a non-goal. The sync path and the worker both import it.
  - The library raises a typed `RenderInputError` when it rejects input.
- [ ] Golden-file tests for every report type must match byte-for-byte before and after the move.

### Task 12: Worker: service, consumer, claim

- [ ] New `services/worker/`: `pyproject.toml` and a `Dockerfile` with a non-root UID.
  - `worker/config.py` (`pydantic-settings`) holds URLs and credential file paths.
  - Only port: health/metrics.
- [ ] `worker/consumer.py` (`aio-pika`): manual ack, `prefetch_count=1`, passive declare of `jobs.execute`.
- [ ] Message check (first step of the handler): `JobExecuteV1` validation, the `type` property, and the ID formats. If anything fails, ack and log an error with the `message_id` only. The message isn't requeued.
- [ ] `worker/clients/job_orders.py` (`httpx` plus `ServiceTokenClient` for `svc:job-orders`) claims with `worker_id` set to the pod name.
  - `200`: ack, then run.
  - `409` / `404`: ack and drop.
  - `5xx` (including `503`) or a network error: back off locally (1 s doubling to 30 s, based on `x-delivery-count`), then `nack(requeue=True)`.
  - The claim response is validated with pydantic and never logged.
- [ ] Tests (`respx` fake job-orders):
  - Every claim outcome maps to the right ack or nack.
  - A poison message is acked.

### Task 13: Worker: lease, max duration, shutdown

- [ ] `worker/lease.py` is an asyncio task that heartbeats every 30 s from claim to report.
  - It aborts on `409 lease_lost`, or when the last `lease_expires_at` minus a margin passes without a successful renewal.
  - Abort means: cancel the run, kill the render subprocess, wipe the scratch directory, and never call `complete`.
- [ ] Rendering runs in a subprocess (Task 15) so CPU-bound work can't starve the event loop and stall heartbeats.
- [ ] `worker/run.py`: the deadline is a monotonic clock started at claim plus `max_duration_s` (G1). When it's reached, abort and send `fail(timeout, retryable=false)`.
- [ ] `worker/main.py`, on SIGTERM:
  - `basic.cancel` the consumer and keep running the current job.
  - At `terminationGracePeriodSeconds − 60 s`, abort and send `fail(worker_shutdown, retryable=true)`.
  - Increment `worker_shutdown_total` (G11).
- [ ] Tests:
  - Lease lost mid-render: no complete, and scratch is wiped.
  - Heartbeat outage longer than the lease: abort.
  - SIGTERM: a short run completes; a long run reports `worker_shutdown`.

### Task 14: Worker: input readers

- [ ] `worker/inputs/dataset.py` (`httpx` to data `:8080`) sends the service token (`aud=svc:data`) and the ticket.
  - It sends no tenant parameter and requests only the datasets in `dataset_ids`.
  - Downloads stream to scratch, capped at 500 MB.
- [ ] Error mapping for dataset reads lives in `worker/errors.py`:
  - `5xx` or timeout → `data_unavailable` (retryable).
  - `404` → `input_not_found` (G8).
  - `403`, or a `401` after the single retry → `internal_error` plus the alert metric.
- [ ] `worker/inputs/url_fetch.py` uses a dedicated `httpx.AsyncClient`:
  - `proxy=` set to the egress proxy, and `trust_env=False` so environment proxies and `.netrc` are ignored.
  - No default headers, cookies or auth.
  - `follow_redirects=False`.
  - `Accept-Encoding: identity`, so the size cap counts the actual bytes received.
  - 10 s connect timeout and a 10 min overall `asyncio.timeout`.
- [ ] Redirects are followed manually, up to 3. Each `Location` goes back through the `libs/jobline-urls/` validator, must stay `https`, and is requested through the proxy.
- [ ] Size checks: reject when `Content-Length` is over 500 MB, and stop the stream at 500 MB. Both give `input_too_large`.
- [ ] Error mapping for URL fetches:
  - Proxy deny (Smokescreen error header; confirm the exact signal) → `input_url_blocked`.
  - Upstream `4xx` → `input_fetch_failed` (permanent), with `public_params.http_status`.
  - `5xx` or timeout → `input_fetch_failed` (retryable).
- [ ] URLs are logged only through `redact_url()` (`libs/jobline-urls/`), which drops the query and fragment.
- [ ] Tests:
  - Redirects to `http`, to an IP literal, and a 4th redirect.
  - Oversize bodies with and without `Content-Length`.
  - A gzip bomb isn't decoded.
  - A capture server sees no `Authorization` or cookie headers.

### Task 15: Worker: render, upload, report

- [ ] `worker/render.py` runs `libs/jobline-render` through `asyncio.create_subprocess_exec`, with CPU and memory rlimits and a working directory inside scratch. `RenderInputError` maps to `render_failed`.
- [ ] `worker/upload.py` (`aioboto3`):
  - The key is built only from claim-response values.
  - Check that the lease is still held before uploading.
  - Upload with the tag `jobline-state=unconfirmed` (G5) and a SHA-256 checksum, and keep the returned `VersionId` (G6).
  - A failed upload maps to `result_store_unavailable`.
- [ ] `complete` sends `result {key, content_type, size_bytes, sha256, version_id}` and `input_bytes` (G4).
  - Retry `5xx` with backoff until the lease deadline.
  - On `409`, stop.
  - On `422`, log an internal error and alert.
- [ ] `fail` sends `code`, `retryable`, `public_params`, `input_bytes`, and a redacted `detail` with no tokens and query-stripped URLs.
- [ ] Tests:
  - `complete` returning `503` and then `200`.
  - `422` handling.

### Task 16: Data service: worker access

- [ ] `services/data/app/auth/worker_access.py` is a FastAPI dependency on the dataset read routes.
  - If the request carries a service token: `verify_service_token(aud="svc:data", allowed_subs={"svc:worker"})`. Then the ticket must be present (`401` if not) and pass `verify_job_ticket(aud="svc:data")`, and `holder` must equal the token's `sub` (`403` if not).
  - Store `tid` and `dataset_ids` on request state.
  - User-token requests keep today's path.
- [ ] Scope checks go in the repository query (`tenant_id = :tid AND id = ANY(:dataset_ids)`), not after the fetch.
  - A different tenant in the request, or a dataset outside the ticket → `403`.
  - A dataset in the ticket that doesn't exist under `tid` → `404` (G8).
- [ ] Config `INTERNAL_CALLER_AUTH = off | log | enforce` covers rollout step 5. `log` records unauthenticated internal callers (pod IP, route); `enforce` returns `401`.
- [ ] Mount `jobline-token-keys`.
- [ ] Tests: missing ticket; holder mismatch; ticket for another tenant; dataset outside the ticket; ticket paired with a user token; expired ticket.

### Task 17: Egress proxy

- [ ] Smokescreen lives in `deploy/egress-proxy/`: `deployment.yaml` (2 replicas, non-root, read-only filesystem), `service.yaml` and the ACL/config.
- [ ] Deny ranges: loopback, RFC 1918, link-local including `169.254.169.254`, `100.64.0.0/10`, `fc00::/7`, `fe80::/10`, and per-environment values for the pod, service and node CIDRs.
- [ ] Allow port 443 only. If Smokescreen has no port option, enforce it in the proxy's NetworkPolicy (Task 19). Confirm which.
- [ ] Smokescreen resolves DNS and dials the resolved IP itself, which covers DNS rebinding. Its DNS egress goes to kube-dns only.
- [ ] Log denials at the proxy with the full destination; this log is internal only.
- [ ] In-cluster staging tests: `127.0.0.1`, `169.254.169.254`, a pod IP, a ClusterIP, `kubernetes.default.svc`, a public name that resolves to RFC 1918, a DNS-rebinding domain and port 8443 are all blocked. A public `https` host is allowed.

### Task 18: Kubernetes identity, worker deployment, object storage

- [ ] `deploy/k8s/jobline/serviceaccounts.yaml` defines `job-orders`, `worker`, `auth` and `data`, all with `automountServiceAccountToken: false`. job-orders and worker get a projected token volume (audience `jobline-auth`, `expirationSeconds: 600`).
- [ ] `deploy/k8s/worker/deployment.yaml`:
  - An `emptyDir` scratch volume with `sizeLimit` of about 2 Gi and matching `ephemeral-storage` requests, for streamed inputs and render output.
  - `terminationGracePeriodSeconds: 900`.
  - Mounts only the projected token and the RabbitMQ and object-storage Secrets (G9a).
- [ ] Object storage policies and bucket config in `deploy/object-storage/`:
  - `worker-policy.json`: `PutObject`, `PutObjectTagging` and `AbortMultipartUpload` on `results/*` only.
  - `job-orders-policy.json`: `GetObject`, `GetObjectVersion` and version-tagging permissions on `results/*`.
  - Versioning turned on (G6).
  - `lifecycle.json`: expire objects tagged `unconfirmed` after 7 days (G5), and keep noncurrent versions for at least the result retention period.
- [ ] Confirm the S3-compatible store supports versioning, tagging on PUT and tag-based lifecycle rules. If it doesn't, go back to G5 and G6.

### Task 19: NetworkPolicies

- [ ] `deploy/k8s/jobline/networkpolicies/default-deny.yaml` denies ingress and egress for every pod in `jobline`. Add one allow policy per component for the §8.4 paths, with matching ingress rules:
  - job-orders `:8081` accepts the worker only.
  - auth `:8081` accepts job-orders and the worker.
- [ ] The egress proxy's policy allows internet `ipBlock`s (`0.0.0.0/0` and `::/0`, excluding every range from Task 17) on TCP 443, plus kube-dns.
- [ ] The G7 additions:
  - DNS for every pod.
  - auth → kube-apiserver.
  - data → its datastore.
  - Monitoring → metrics ports.
  - Existing data-service callers, taken from an inventory made first.
  - job-orders → data `:8080` and job-orders → internet (or the proxy) until the sync path is removed.
- [ ] Postgres, RabbitMQ and object storage are selected by pod label if they run in the cluster, or by `ipBlock` if they don't.
- [ ] Run the policies in audit mode for a week where the CNI supports it, and review denied flows before enforcing.
- [ ] Staging connectivity-matrix job:
  - Every allowed path works and a sample of forbidden paths fails.
  - A direct connection from the worker to `1.1.1.1:443` fails.

### Task 20: Gateway route guard

- [ ] `ci/check_gateway_routes.py` runs in CI against the gateway config and service manifests. It fails if any route targets port `8081`, has a path containing `/internal`, or exposes `8081`. Its unit tests use one violating fixture per rule.
- [ ] The gateway strips inbound `X-Jobline-Job-Ticket` headers as defense in depth. Where that config lives is to be confirmed.

### Task 21: Observability and alerts

- [ ] Metrics:
  - `outbox_oldest_unpublished_age_seconds`, `sweeper_actions_total`, `run_transitions_total{from,to,code}`, `claim_results_total`.
  - `service_token_auth_failures_total`, `worker_input_auth_errors_total`, `worker_shutdown_total`.
  - Queue and DLQ depth from the RabbitMQ Prometheus plugin, and Smokescreen deny counts.
- [ ] `deploy/alerts/async-execution.rules.yaml` alerts on:
  - DLQ non-empty.
  - Oldest unpublished outbox row older than 5 min.
  - Worker data `401`/`403`.
  - A second consecutive service-token `401`.
  - Any `result_key_invalid`.
  - A spike in `worker_lost`.
  - Oldest queued run older than a threshold.
- [ ] All four services install the Task 1 log filter. The Task 23 suite scans captured logs for `v4.public.` and for URL query strings.

### Task 22: Rollout and sync-path compatibility

- [ ] `services/job-orders/app/flags.py` holds the per-tenant flag `async_execution`, backed by existing tenant settings (store to be confirmed). Only the submit handler reads it, and it defaults to off.
- [ ] The sync path also writes a terminal `job_runs` row and a usage record with `run_id` (G12).
- [ ] Rollout order:
  1. Tasks 1–3 and 6; the internal API stays idle.
  2. Tasks 10 and 12–19, with policies in audit mode.
  3. Enable the internal tenant. Notify API-integration tenants of the `202` change before enabling each of them.
  4. Gradual rollout. Then remove the sync path, its G7 NetworkPolicy exceptions and job-orders' direct URL fetch.
  5. Data service `INTERNAL_CALLER_AUTH=log` for one week, then `enforce`.
- [ ] Rollback is per tenant: turning the flag off restores the sync path, and runs already queued keep draining.
- [ ] Gate before each enforcement step: audit logs show zero unexpected denials.

### Task 23: End-to-end and security tests

- [ ] Scenarios in `tests/e2e/`, run on a kind or staging cluster:
  - submit → `202` → poll → download;
  - URL input through the proxy; dataset input with a ticket;
  - cancel while pending; cancel while running gets `409`;
  - kill a worker mid-run → `worker_lost` retry → success;
  - partition a worker → its late complete gets `409` and only one usage row exists;
  - RabbitMQ down at submit;
  - auth down at claim, with no attempt used;
  - a dropped message is re-published by the sweeper (with time-scaled config).
- [ ] Security:
  - A forged message for an unknown run is dropped.
  - A worker token calling `job-tickets` gets `403`.
  - A user token on the internal endpoints gets `401`.
  - A ticket for another tenant gets `403`.
  - The SSRF matrix from Task 17, run end to end through the worker.
  - Log scan for secrets.
- [ ] Load:
  - A report that ran past the old request timeout now completes.
  - Claim throughput with N workers.
  - Sweeper pass time with 100k queued runs.
__FIXTURE_EOF__

git add -A && git commit -q -m "Spec and draft plan: async job execution"
