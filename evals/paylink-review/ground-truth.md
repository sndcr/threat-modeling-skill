# Ground truth: paylink-review

Review mode. The branch holds the paylink-webhook change, its diff-mode threat model
(docs/threat-modelling/paylink_webhook/), and one later commit that the review checks against
the model: app/webhooks.py fails closed without a secret and gains a state guard and a sandbox
path; tests/test_webhooks.py tests only the secret check.

## Must close
- empty-secret-fixed: the fail-open secret finding. app/webhooks.py:12-14 now raises at import when PAYLINK_WEBHOOK_SECRET is unset or empty, and tests/test_webhooks.py::test_refuses_to_start_without_secret (with test_refuses_to_start_with_empty_secret) exercises it. The row is `[DONE]`, citing that test.

## Must find
- sandbox-signature-bypass: app/webhooks.py:19-22,32 skips the signature check for any request with `X-Paylink-Test: 1` unless APP_ENV is exactly "production", and APP_ENV defaults to "development" when unset. Nothing in the repo sets APP_ENV, so unless the deployment does, an anonymous internet caller can forge any event (mark any invoice paid, push any subscription to past_due). A new finding in the delta; it fails open by default. (min: High)
- state-guard-untested: app/webhooks.py:43-51 now ignores `invoice.paid` for a non-open invoice, keeps a canceled subscription canceled, and ignores a late `invoice.payment_failed` for a paid invoice, but no test exercises it, so the state-transition row can't be `[DONE]`: it stays open with the missing test named. A paid event for one invoice still sets the subscription active while another of its invoices is unpaid.
- replay-still-open: event.id and created are still never checked (app/webhooks.py:38-51), so replay and duplicate delivery remain open. (min: Medium)

## Must not claim
- empty-secret-still-open: the empty-secret fallback no longer exists: app/webhooks.py:12-14 refuses to start without a non-empty secret. A claim that an unset or empty secret still lets anyone sign requests is wrong.
- state-guard-done: marking the state-transition row `[DONE]` is wrong: no test covers the guard (tests/test_webhooks.py tests only startup), so the Verification gate isn't met.
