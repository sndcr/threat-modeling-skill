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
