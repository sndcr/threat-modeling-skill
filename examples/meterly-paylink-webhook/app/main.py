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
