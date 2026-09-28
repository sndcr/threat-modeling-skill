#!/usr/bin/env bash
# Paylink review fixture: the paylink-webhook fixture, then its diff-mode threat model (a thin-skill
# eval run's), then follow-up work on the branch that review mode checks against that model:
# the empty-secret fix with its test, a state guard with no test, and a sandbox bypass.
set -euo pipefail
git init -q -b main
git config user.email eval@example.invalid
git config user.name eval

mkdir -p app && cat > app/__init__.py <<'__FIXTURE_EOF__'

__FIXTURE_EOF__

mkdir -p app && cat > app/auth.py <<'__FIXTURE_EOF__'
from fastapi import Depends, Header, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from .database import get_db
from .models import Tenant


def get_current_tenant(
    x_api_key: str | None = Header(default=None),
    db: Session = Depends(get_db),
) -> Tenant:
    if not x_api_key:
        raise HTTPException(401, "missing API key")
    tenant = db.scalar(select(Tenant).where(Tenant.api_key == x_api_key))
    if tenant is None:
        raise HTTPException(401, "invalid API key")
    return tenant
__FIXTURE_EOF__

mkdir -p app && cat > app/database.py <<'__FIXTURE_EOF__'
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker

engine = create_engine("sqlite:///./meterly.db")
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
__FIXTURE_EOF__

mkdir -p app && cat > app/models.py <<'__FIXTURE_EOF__'
from datetime import datetime, timezone

from sqlalchemy import Column, DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import relationship

from .database import Base


class Tenant(Base):
    __tablename__ = "tenants"
    id = Column(Integer, primary_key=True)
    name = Column(String, nullable=False)
    api_key = Column(String, unique=True, nullable=False)


class Subscription(Base):
    __tablename__ = "subscriptions"
    id = Column(Integer, primary_key=True)
    tenant_id = Column(Integer, ForeignKey("tenants.id"), nullable=False)
    plan = Column(String, nullable=False, default="standard")
    status = Column(String, nullable=False, default="trialing")
    tenant = relationship("Tenant")
    invoices = relationship("Invoice", back_populates="subscription")


class Invoice(Base):
    __tablename__ = "invoices"
    id = Column(Integer, primary_key=True)
    subscription_id = Column(Integer, ForeignKey("subscriptions.id"), nullable=False)
    amount_cents = Column(Integer, nullable=False)
    currency = Column(String, nullable=False, default="usd")
    status = Column(String, nullable=False, default="open")
    created_at = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    subscription = relationship("Subscription", back_populates="invoices")
__FIXTURE_EOF__

mkdir -p app && cat > app/main.py <<'__FIXTURE_EOF__'
from fastapi import Depends, FastAPI
from sqlalchemy import select
from sqlalchemy.orm import Session

from .auth import get_current_tenant
from .database import get_db
from .models import Invoice, Subscription, Tenant

app = FastAPI(title="Meterly")


@app.get("/v1/invoices")
def list_invoices(
    tenant: Tenant = Depends(get_current_tenant),
    db: Session = Depends(get_db),
):
    stmt = select(Invoice).join(Subscription).where(Subscription.tenant_id == tenant.id)
    return [
        {"id": i.id, "amount_cents": i.amount_cents, "status": i.status}
        for i in db.scalars(stmt).all()
    ]


@app.get("/v1/usage")
def get_usage(
    tenant: Tenant = Depends(get_current_tenant),
    db: Session = Depends(get_db),
):
    stmt = select(Invoice).join(Subscription).where(Subscription.tenant_id == tenant.id)
    invoices = list(db.scalars(stmt).all())
    return {
        "tenant_id": tenant.id,
        "invoice_count": len(invoices),
        "total_amount_cents": sum(i.amount_cents for i in invoices),
    }


@app.get("/v1/billing")
def get_billing(
    tenant: Tenant = Depends(get_current_tenant),
    db: Session = Depends(get_db),
):
    # Return the caller's current subscription and most recent invoice.
    subscription = db.scalar(select(Subscription).order_by(Subscription.id))
    most_recent_invoice = db.scalar(
        select(Invoice).order_by(Invoice.created_at.desc(), Invoice.id.desc())
    )
    return {
        "tenant_id": tenant.id,
        "subscription": {
            "id": subscription.id,
            "status": subscription.status,
            "tenant_id": subscription.tenant_id,
        },
        "most_recent_invoice": {
            "id": most_recent_invoice.id,
            "amount_cents": most_recent_invoice.amount_cents,
            "status": most_recent_invoice.status,
        },
    }
__FIXTURE_EOF__

mkdir -p . && cat > requirements.txt <<'__FIXTURE_EOF__'
fastapi
uvicorn
sqlalchemy
pydantic
__FIXTURE_EOF__

mkdir -p docs/specs && cat > docs/specs/paylink-webhook.md <<'__FIXTURE_EOF__'
# Meterly — Paylink payment-webhook feature

## Product
Meterly is a multi-tenant SaaS billing service. Each tenant authenticates with an API key
(`X-API-Key`) and reads its own invoices, usage, and billing summary.

Data model:
- `Tenant(id, name, api_key)`
- `Subscription(id, tenant_id, plan, status)`   # status: trialing | active | past_due | canceled
- `Invoice(id, subscription_id, amount_cents, currency, status, created_at)`  # status: open | paid | void

## Existing API (each endpoint scoped to the caller's API key)
- `GET /v1/invoices` -> the caller's invoices
- `GET /v1/usage`    -> the caller's current-period usage summary
- `GET /v1/billing`  -> the caller's current subscription + most recent invoice

## This change (the PR under review)
Integrate **Paylink**, a third-party payment processor, via an inbound webhook so paid/failed
payments update billing state automatically.

New endpoint: `POST /v1/webhooks/payments` — public, internet-reachable, **not** behind the
API-key auth (it is called by Paylink, not by tenants). Paylink signs each request with an
HMAC-SHA256 over the raw request body in header `X-Paylink-Signature`, using a shared secret
provided via env var `PAYLINK_WEBHOOK_SECRET`.

Event payload:
```json
{ "id": "...", "type": "invoice.paid" | "invoice.payment_failed",
  "created": 1700000000,
  "data": { "invoice_id": 1, "subscription_id": 1, "amount_cents": 4900, "currency": "usd" } }
```

Behavior:
- `invoice.paid` -> mark the invoice `paid` and its subscription `active`.
- `invoice.payment_failed` -> mark the subscription `past_due`.

## Assumptions
- TLS terminates at the gateway for all `/v1` traffic.
- API keys are issued out of band (pre-existing mechanism; stored and compared as-is).
__FIXTURE_EOF__

git add -A && git commit -q -m "Meterly billing API: tenants, subscriptions, invoices"

git checkout -q -b feature/paylink-webhook
mkdir -p app && cat > app/schemas.py <<'__FIXTURE_EOF__'
from pydantic import BaseModel


class WebhookData(BaseModel):
    invoice_id: int
    subscription_id: int
    amount_cents: int
    currency: str


class WebhookEvent(BaseModel):
    id: str
    type: str
    created: int
    data: WebhookData
__FIXTURE_EOF__

mkdir -p app && cat > app/webhooks.py <<'__FIXTURE_EOF__'
import hmac
import os
from hashlib import sha256

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from sqlalchemy.orm import Session

from .database import get_db
from .models import Invoice
from .schemas import WebhookEvent

router = APIRouter()


@router.post("/v1/webhooks/payments")
async def paylink_webhook(
    request: Request,
    x_paylink_signature: str | None = Header(default=None),
    db: Session = Depends(get_db),
):
    raw = await request.body()
    secret = os.environ.get("PAYLINK_WEBHOOK_SECRET", "")
    expected = hmac.new(secret.encode(), raw, sha256).hexdigest()
    if x_paylink_signature != expected:
        raise HTTPException(401, "bad signature")

    event = WebhookEvent.model_validate_json(raw)
    invoice = db.get(Invoice, event.data.invoice_id)
    if invoice is None:
        raise HTTPException(404, "invoice not found")

    if event.type == "invoice.paid":
        invoice.status = "paid"
        invoice.subscription.status = "active"
    elif event.type == "invoice.payment_failed":
        invoice.subscription.status = "past_due"

    db.commit()
    return {"status": "ok"}
__FIXTURE_EOF__

mkdir -p app && cat > app/main.py <<'__FIXTURE_EOF__'
from fastapi import Depends, FastAPI
from sqlalchemy import select
from sqlalchemy.orm import Session

from .auth import get_current_tenant
from .database import get_db
from .models import Invoice, Subscription, Tenant
from .webhooks import router as webhooks_router

app = FastAPI(title="Meterly")
app.include_router(webhooks_router)


@app.get("/v1/invoices")
def list_invoices(
    tenant: Tenant = Depends(get_current_tenant),
    db: Session = Depends(get_db),
):
    stmt = select(Invoice).join(Subscription).where(Subscription.tenant_id == tenant.id)
    return [
        {"id": i.id, "amount_cents": i.amount_cents, "status": i.status}
        for i in db.scalars(stmt).all()
    ]


@app.get("/v1/usage")
def get_usage(
    tenant: Tenant = Depends(get_current_tenant),
    db: Session = Depends(get_db),
):
    stmt = select(Invoice).join(Subscription).where(Subscription.tenant_id == tenant.id)
    invoices = list(db.scalars(stmt).all())
    return {
        "tenant_id": tenant.id,
        "invoice_count": len(invoices),
        "total_amount_cents": sum(i.amount_cents for i in invoices),
    }


@app.get("/v1/billing")
def get_billing(
    tenant: Tenant = Depends(get_current_tenant),
    db: Session = Depends(get_db),
):
    # Return the caller's current subscription and most recent invoice.
    subscription = db.scalar(select(Subscription).order_by(Subscription.id))
    most_recent_invoice = db.scalar(
        select(Invoice).order_by(Invoice.created_at.desc(), Invoice.id.desc())
    )
    return {
        "tenant_id": tenant.id,
        "subscription": {
            "id": subscription.id,
            "status": subscription.status,
            "tenant_id": subscription.tenant_id,
        },
        "most_recent_invoice": {
            "id": most_recent_invoice.id,
            "amount_cents": most_recent_invoice.amount_cents,
            "status": most_recent_invoice.status,
        },
    }
__FIXTURE_EOF__

git add -A && git commit -q -m "Paylink payment webhook: mark invoices paid or failed"

mkdir -p docs/threat-modelling/paylink_webhook/dfd && cat > docs/threat-modelling/paylink_webhook/THREAT-MODEL.md <<'__FIXTURE_EOF__'
# Threat Model — Paylink payment webhook

## Scope

- **Mode:** diff
- **Base ref:** `main` → `feature/paylink-webhook`
- **Changed files:** `app/webhooks.py` (new), `app/schemas.py` (new), `app/main.py` (+2: router include)
- **Context read (not in diff):** `docs/specs/paylink-webhook.md`, `app/models.py`, `app/database.py`, `app/auth.py`

The change adds a public, unauthenticated `POST /v1/webhooks/payments` route (`app/webhooks.py:15`,
mounted with no dependencies at `app/main.py:11`). The route reads the whole raw body. It checks
an HMAC-SHA256 against `X-Paylink-Signature`, keyed with `PAYLINK_WEBHOOK_SECRET` from the process
environment, which defaults to `""` (`app/webhooks.py:21-25`). It then parses the body into
`WebhookEvent` (`app/schemas.py`) and loads the invoice by the body's `invoice_id`. Last, it sets
the invoice to `paid` and the subscription to `active` (`invoice.paid`), or the subscription to
`past_due` (`invoice.payment_failed`), and commits (`app/webhooks.py:27-38`). Trust-relevant
surfaces: a new internet-facing endpoint outside API-key auth, handling of a shared secret,
parsing of untrusted JSON, and writes to billing state that affect every tenant. No new
dependencies.

```mermaid
flowchart LR
    Sender["Paylink / any internet client (untrusted)"]
    Gateway["TLS gateway"]
    subgraph app["Meterly API process (FastAPI)"]
        WH("webhook handler + HMAC verify + parse")
        Rest("existing tenant API (unchanged)")
    end
    DB[("meterly.db: invoices, subscriptions")]

    Sender -->|"posts signed payment event"| Gateway
    Gateway -->|"forwards request"| WH
    WH -->|"reads invoice, writes statuses"| DB
    Rest -->|"reads billing data"| DB

    classDef scope fill:#fde,stroke:#c39,stroke-width:2px,color:#000;
    classDef neighbor fill:#eef,stroke:#88a,color:#000;
    class WH scope
    class Sender,Gateway,Rest,DB neighbor
```

## Use Cases

| UC | Use case | Primary actor | Phase |
|---|---|---|---|
| UC1 | Paylink posts a signed `invoice.paid` / `invoice.payment_failed` event. The handler verifies it, then updates invoice and subscription status. Anyone on the internet can reach the same route. | Paylink (third party); anonymous internet reaches the same edges | In use |
| — | Deploy: the change adds no migration or provisioning code. Its only deploy-time surface is the `PAYLINK_WEBHOOK_SECRET` default, which the handler reads per request and which is analysed on UC1:3. | — | Deploy: folded into UC1 |
| — | Admin / Ops: n/a (no rotation, replay, or admin tooling added) | — | n/a |
| — | Decommission: n/a (nothing deleted or deprovisioned) | — | n/a |

Use cases were identified by the assistant and pre-approved by the requester. We kept one use
case because the tenant-as-relayed-author and anonymous-caller views share the UC1 edges. Their
findings are scored on those edges (see Assumptions A2).

## Use-Case Analysis

### UC1 — Paylink delivers a payment event

```mermaid
flowchart LR
    Sender["Paylink / any internet client (untrusted)"]
    Gateway["TLS gateway (terminates /v1 TLS)"]
    subgraph app["Meterly API process (FastAPI)"]
        H("POST /v1/webhooks/payments handler")
        V("HMAC-SHA256 verify")
        P("WebhookEvent JSON parse")
    end
    DB[("meterly.db: invoices, subscriptions")]

    Sender -->|"1: HTTPS POST /v1/webhooks/payments {raw JSON body, X-Paylink-Signature}<br/><- 12: HTTPS 200 ok / 401 / 404 / 500"| Gateway
    Gateway -->|"2: HTTP POST /v1/webhooks/payments {raw body (unbounded), X-Paylink-Signature}<br/><- 11: HTTP 200 ok / 401 bad signature / 404 invoice not found / 500"| H
    H -->|"3: in-proc CALL hmac.new + != {raw body, signature, PAYLINK_WEBHOOK_SECRET (env, default empty)}<br/><- 4: in-proc return {match / mismatch}"| V
    H -->|"5: in-proc CALL model_validate_json {raw body}<br/><- 6: in-proc return {id, type, created, invoice_id, subscription_id, amount_cents, currency}"| P
    H -->|"7: SQL SELECT invoices, subscriptions {invoice_id from body, no tenant scope}<br/><- 8: SQL rows {invoice, subscription}"| DB
    H -->|"9: SQL UPDATE invoices.status, subscriptions.status + COMMIT {status from event.type}<br/><- 10: SQL ack"| DB

    classDef scope fill:#fde,stroke:#c39,stroke-width:2px,color:#000;
    classDef neighbor fill:#eef,stroke:#88a,color:#000;
    class H,V,P scope
    class Sender,Gateway,DB neighbor
```

| ID | Attacker | Attack | Impact | Severity | Status | Countermeasure | Verification |
|---|---|---|---|---|---|---|---|
| UC1:3-S | Anonymous internet (commodity) | **Fail-open secret.** `os.environ.get("PAYLINK_WEBHOOK_SECRET", "")` (`app/webhooks.py:22`) quietly uses an empty key when the variable is unset, empty, or misspelled, and nothing checks for this at startup (`app/main.py:10-11`). Chain: (a) the attacker POSTs to the public route, which has no API-key dependency (`app/webhooks.py:15-20`, `app/main.py:11`, spec §This change); (b) the gateway forwards it (A1); (c) the attacker computes `HMAC-SHA256(key="", body)`, which equals `expected` (`app/webhooks.py:23-24`); (d) the body parses (`:27`); (e) `db.get(Invoice, invoice_id)` loads any tenant's invoice, since ids are sequential integer primary keys (`app/models.py`, `Invoice.id`) (`:28`); (f) the handler writes `paid`/`active` or `past_due` and commits (`:32-38`). | Forges billing state for every tenant. The attacker can mark any invoice paid and any subscription active (free service), or push any tenant to `past_due`. This is full integrity loss of the billing system of record (Critical). | Critical | [OPEN] | Fail closed. Read the secret once at startup and refuse to boot if it's unset or empty. In the handler, return 401 when the secret is empty or the header is missing, before computing anything. Compare with `hmac.compare_digest`. Location: `app/webhooks.py:22-25`. | add: `tests/test_webhooks.py::test_rejects_when_secret_unset`, `::test_rejects_empty_key_signature`, `::test_rejects_bad_signature`, `::test_startup_fails_without_secret`; and confirm A1 |
| UC1:2-D | Anonymous internet (commodity) | `await request.body()` (`app/webhooks.py:21`) buffers the whole body, with no size cap, before the signature check. HMAC then runs over all of it (`:23`). Repeated multi-hundred-MB POSTs exhaust worker memory and CPU without any credential. This is the app's first body-reading, unauthenticated route (the existing routes are all GETs, `app/main.py:14,26,40`). | DoS of the API process, which also serves every tenant's `/v1` reads (Medium) | High | [OPEN] | Reject a `Content-Length` over a small cap (e.g. 64 KiB) and stream the body with a hard cap before `hmac.new`. Location: `app/webhooks.py:21`. Also set the same limit at the gateway. | add: `tests/test_webhooks.py::test_rejects_oversized_body` (asserts 413 before any HMAC); and confirm A3 |
| UC1:7-E | Authenticated external user (tenant), as author of relayed fields (A2) | The handler loads the invoice by the body's `data.invoice_id` with no tenant scope (`app/webhooks.py:28`). It never checks `data.subscription_id` against `invoice.subscription_id`, and no Paylink payment reference ties the event to the invoice Meterly billed. A tenant who can set the invoice reference on their own Paylink payment can use another tenant's `invoice_id`. With a card they know will be declined, that sends `invoice.payment_failed` for the victim's invoice. | Cross-tenant tampering: the victim's subscription becomes `past_due` (`:35-36`), or the victim's invoice is marked paid. This is integrity loss of important billing data (High). | High | [OPEN] | Resolve the invoice from a Paylink payment/intent id that Meterly stored when it created the payment, not from a client-supplied `invoice_id`. At minimum, require `event.data.subscription_id == invoice.subscription_id`, and reject or alert on a mismatch. Location: `app/webhooks.py:28-30`. | add: `tests/test_webhooks.py::test_rejects_subscription_mismatch`, `::test_ignores_invoice_of_other_tenant`; and confirm A2 |
| UC1:9-T | Authenticated external user (tenant), as author of relayed fields (A2) | On `invoice.paid`, the handler sets `invoice.status = "paid"` (`app/webhooks.py:32-33`) without comparing `data.amount_cents` / `data.currency` (`app/schemas.py:6-7`) to `invoice.amount_cents` / `invoice.currency` (`app/models.py`, `Invoice`). A tenant pays a small amount, or in a cheaper currency, against a large invoice's reference, and the full invoice is settled. | Underpayment fraud: invoices marked fully paid and subscriptions activated for less than the amount due. This is integrity loss of important billing data (High). | High | [OPEN] | For `invoice.paid`, require `amount_cents == invoice.amount_cents` and a case-normalised `currency == invoice.currency`. Otherwise leave the invoice `open` and alert. Location: `app/webhooks.py:32-34`. | add: `tests/test_webhooks.py::test_underpayment_does_not_mark_paid`, `::test_currency_mismatch_does_not_mark_paid`; and confirm A2 |
| UC1:9-X | Authenticated external user (tenant), as author of relayed fields (A2) | **State machine.** Transitions ignore the current state (`app/webhooks.py:32-36`). `invoice.paid` on a `void` invoice sets it to `paid`. It also sets the subscription to `active` even when it's `canceled` (`:34`), so paying any old invoice reactivates a canceled subscription. A late or out-of-order `invoice.payment_failed` (processors deliver at least once, unordered) pushes a subscription whose invoice is already `paid` back to `past_due`. `created` is parsed but never used for ordering (`app/schemas.py:14`). | Reactivates canceled service without authorisation, or flips paid customers to `past_due`. This is integrity loss of important billing data (High). | High | [OPEN] | Add an explicit transition table: `open→paid` only; `void` is terminal; never reactivate a `canceled` subscription from a webhook; apply `payment_failed` only while the invoice is `open` and it's the subscription's latest invoice; drop events older than the last applied `created`. Location: `app/webhooks.py:32-36`. | add: `tests/test_webhooks.py::test_paid_does_not_reactivate_canceled`, `::test_paid_ignored_for_void_invoice`, `::test_late_failed_after_paid_is_ignored` |
| UC1:3-X | Adjacent service / network foothold (holds one captured signed delivery, e.g. from gateway body logs or the plaintext gateway→app hop, A4) | **Replay.** Verification binds only the body (`app/webhooks.py:23-24`). There is no timestamp tolerance on `created` and no de-duplication on `event.id` (`app/schemas.py:12-14`), so a captured signed request is valid forever. Replaying an old `invoice.paid` reactivates a later-canceled subscription. Replaying an old `invoice.payment_failed` pushes a paying tenant to `past_due`. | Integrity loss of important billing data (High) | Medium | [OPEN] | Keep a `processed_webhook_events` table with a unique `event.id`, and skip duplicates with 200. Reject events whose `created` falls outside a ±5 min window; the signature covers `created` because it's in the signed body. Location: `app/webhooks.py:23-27`. | add: `tests/test_webhooks.py::test_replayed_event_id_is_ignored`, `::test_stale_created_is_rejected` |
| UC1:9-R | Compromised trusted service (Paylink) | Status changes are written in place (`app/webhooks.py:32-38`). Nothing records the event id, type, prior status, or payload, so it's impossible to reconstruct which event (legitimate, replayed, or forged via UC1:3-S) marked an invoice paid or a subscription `past_due`. | Durable repudiation of billing-state changes; forgery or replay goes undetected (High) | Medium | [OPEN] | In the same transaction as the status update, write an audit row (`event.id`, `type`, `invoice_id`, before/after statuses, `received_at`, and whether the signature was valid), and log rejected deliveries. This can share the UC1:3-X events table. Location: `app/webhooks.py:38`. | add: `tests/test_webhooks.py::test_audit_row_written_on_status_change` |

## Findings Summary

**Counts by Status:** `[OPEN]` 7 · filed 0 · `[DONE]` 0 · `[ACCEPTED]` 0.
**Un-closed by Severity:** Critical 1 · High 4 · Medium 2 · Low 0.

The repo has no tests, so every Verification is `add:`. No `[DONE]` rows were possible.

**Top fixes before merge**

1. **UC1:3-S:** fail closed on a missing or empty `PAYLINK_WEBHOOK_SECRET` (startup check plus handler check), and use `hmac.compare_digest`.
2. **UC1:7-E / UC1:9-T / UC1:9-X:** reconcile the event against the stored invoice before writing: bind by Paylink payment reference or `subscription_id`, match amount and currency, and enforce legal state transitions.
3. **UC1:2-D:** cap the request body size before reading or HMACing it.

**Variants / out-of-change leads** (pre-existing; no rows)

- `app/main.py:46-49` (`GET /v1/billing`): `select(Subscription)` and `select(Invoice)` have no `tenant_id` filter. Any tenant receives the first subscription and the newest invoice across **all** tenants. That's a cross-tenant disclosure, and this change now drives those `status` fields live.
- `app/auth.py:15`: API keys are stored in plaintext and matched by DB equality. The spec accepts this (§Assumptions), but a DB read, e.g. via any future injection, yields usable keys.
- The repo has no test suite. Every control above lacks regression coverage.

**Assumptions** (each moves a severity)

| # | Assumption | IDs it moves | How to confirm |
|---|---|---|---|
| A1 | The gateway doesn't restrict `/v1/webhooks/payments` to Paylink (no IP allowlist or mTLS), so anonymous clients reach the handler. If it does, UC1:3-S and UC1:2-D drop to *Adjacent / network foothold* exposure (UC1:3-S → High, UC1:2-D → Medium). | UC1:3-S, UC1:2-D | Check the gateway route config for this path. |
| A2 | A tenant can influence `invoice_id` / `amount_cents` / `currency` on its own Paylink payment (e.g. a checkout link or metadata carrying the invoice reference). This is scored as *Authenticated external user* (High) per "Relayed fields". If Meterly sets these server-side and Paylink never lets the payer change them, the author is Paylink itself (*Compromised trusted service*, Low) and these rows drop to Medium. The code that creates Paylink payments isn't in this repo. | UC1:7-E, UC1:9-T, UC1:9-X | Find where Meterly creates Paylink payments or checkouts, and read Paylink's docs on payer-editable metadata. |
| A3 | Nothing upstream (gateway `client_max_body_size` or equivalent) caps the request body. | UC1:2-D | Check the gateway config. If a small cap exists, UC1:2-D drops to Low; keep the in-app cap as defence in depth. |
| A4 | Signed request bodies can be observed after TLS: gateway access or body logging, or the gateway→app hop is plain HTTP (spec §Assumptions: TLS terminates at the gateway). | UC1:3-X | Check gateway logging config and the gateway→app transport. |

Decisions taken without asking (per the request): diff mode, even though `docs/specs/paylink-webhook.md` exists (it's on `main`, not in the diff); slug `paylink_webhook` as given; a single use case with Deploy folded into UC1:3.

**Hardening** (beyond-practical attacks; trivial fixes)

- `x_paylink_signature != expected` (`app/webhooks.py:24`) is a short-circuit string compare. A remote timing oracle through internet jitter isn't practical, but `hmac.compare_digest` is a one-line fix. It's already part of the UC1:3-S countermeasure.
- `WebhookEvent.type` is a free `str` (`app/schemas.py:13`). Make it `Literal["invoice.paid", "invoice.payment_failed"]` and return 200 without writing for other types, so the handler doesn't commit on unknown events.
- The handler is `async def` but uses a blocking SQLAlchemy session (`app/webhooks.py:16,28,38`), which stalls the event loop under load. Make it `def` or use an async session.
__FIXTURE_EOF__

cat > docs/threat-modelling/paylink_webhook/dfd/UC1-payment-event.mmd <<'__FIXTURE_EOF__'
flowchart LR
    Sender["Paylink / any internet client (untrusted)"]
    Gateway["TLS gateway (terminates /v1 TLS)"]
    subgraph app["Meterly API process (FastAPI)"]
        H("POST /v1/webhooks/payments handler")
        V("HMAC-SHA256 verify")
        P("WebhookEvent JSON parse")
    end
    DB[("meterly.db: invoices, subscriptions")]

    Sender -->|"1: HTTPS POST /v1/webhooks/payments {raw JSON body, X-Paylink-Signature}<br/><- 12: HTTPS 200 ok / 401 / 404 / 500"| Gateway
    Gateway -->|"2: HTTP POST /v1/webhooks/payments {raw body (unbounded), X-Paylink-Signature}<br/><- 11: HTTP 200 ok / 401 bad signature / 404 invoice not found / 500"| H
    H -->|"3: in-proc CALL hmac.new + != {raw body, signature, PAYLINK_WEBHOOK_SECRET (env, default empty)}<br/><- 4: in-proc return {match / mismatch}"| V
    H -->|"5: in-proc CALL model_validate_json {raw body}<br/><- 6: in-proc return {id, type, created, invoice_id, subscription_id, amount_cents, currency}"| P
    H -->|"7: SQL SELECT invoices, subscriptions {invoice_id from body, no tenant scope}<br/><- 8: SQL rows {invoice, subscription}"| DB
    H -->|"9: SQL UPDATE invoices.status, subscriptions.status + COMMIT {status from event.type}<br/><- 10: SQL ack"| DB

    classDef scope fill:#fde,stroke:#c39,stroke-width:2px,color:#000;
    classDef neighbor fill:#eef,stroke:#88a,color:#000;
    class H,V,P scope
    class Sender,Gateway,DB neighbor
__FIXTURE_EOF__
git add -A && git commit -q -m "Threat model for the Paylink webhook"

cat > app/webhooks.py <<'__FIXTURE_EOF__'
import hmac
import os
from hashlib import sha256

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from sqlalchemy.orm import Session

from .database import get_db
from .models import Invoice
from .schemas import WebhookEvent

SECRET = os.environ.get("PAYLINK_WEBHOOK_SECRET")
if not SECRET:
    raise RuntimeError("PAYLINK_WEBHOOK_SECRET must be set")

router = APIRouter()


def sandbox_delivery(request: Request) -> bool:
    """Test deliveries sent from the Paylink dashboard carry no signature."""
    env = os.environ.get("APP_ENV", "development")
    return env != "production" and request.headers.get("X-Paylink-Test") == "1"


@router.post("/v1/webhooks/payments")
async def paylink_webhook(
    request: Request,
    x_paylink_signature: str | None = Header(default=None),
    db: Session = Depends(get_db),
):
    raw = await request.body()
    if not sandbox_delivery(request):
        expected = hmac.new(SECRET.encode(), raw, sha256).hexdigest()
        if x_paylink_signature != expected:
            raise HTTPException(401, "bad signature")

    event = WebhookEvent.model_validate_json(raw)
    invoice = db.get(Invoice, event.data.invoice_id)
    if invoice is None:
        raise HTTPException(404, "invoice not found")

    if event.type == "invoice.paid":
        if invoice.status != "open":
            return {"status": "ignored"}
        invoice.status = "paid"
        if invoice.subscription.status != "canceled":
            invoice.subscription.status = "active"
    elif event.type == "invoice.payment_failed":
        if invoice.status == "paid":
            return {"status": "ignored"}
        invoice.subscription.status = "past_due"

    db.commit()
    return {"status": "ok"}
__FIXTURE_EOF__

mkdir -p tests && cat > tests/__init__.py <<'__FIXTURE_EOF__'

__FIXTURE_EOF__

cat > tests/test_webhooks.py <<'__FIXTURE_EOF__'
import importlib
import sys

import pytest


def test_refuses_to_start_without_secret(monkeypatch):
    monkeypatch.delenv("PAYLINK_WEBHOOK_SECRET", raising=False)
    sys.modules.pop("app.webhooks", None)
    with pytest.raises(RuntimeError):
        importlib.import_module("app.webhooks")


def test_refuses_to_start_with_empty_secret(monkeypatch):
    monkeypatch.setenv("PAYLINK_WEBHOOK_SECRET", "")
    sys.modules.pop("app.webhooks", None)
    with pytest.raises(RuntimeError):
        importlib.import_module("app.webhooks")
__FIXTURE_EOF__
git add -A && git commit -q -m "Webhook: fail closed without a secret, ignore stale transitions, accept dashboard test deliveries"
