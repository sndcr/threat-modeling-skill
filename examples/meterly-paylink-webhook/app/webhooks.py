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
