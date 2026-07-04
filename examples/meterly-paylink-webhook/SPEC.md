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
