#!/usr/bin/env bash
# Paylink webhook fixture: a multi-tenant FastAPI billing service (base), then the change
# that adds the inbound Paylink payment webhook. Generated from examples/meterly-paylink-webhook.
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
