# Example: Meterly "Paylink" payment webhook

A worked example for the `threat-model` skill: a small multi-tenant FastAPI billing service
("Meterly") plus a feature change that adds an inbound payment webhook from a third-party
processor ("Paylink").

> ⚠️ **Intentionally imperfect.** This implementation ships realistic security gaps: a
> fail-open webhook secret, a cross-tenant IDOR, no replay/binding protection, plaintext API
> keys. They exist to give the threat model something to find. **Not a reference implementation.**

## Files

- [`SPEC.md`](SPEC.md): the feature spec (the input you'd hand the skill).
- [`app/`](app): the implementation under review.
- [`THREAT-MODEL.md`](THREAT-MODEL.md): the deliverable, i.e. what `/threat-model` produces for this change.
- [`dfd/`](dfd): the per-use-case Mermaid DFDs (canonical source, also embedded in THREAT-MODEL.md).

## How this threat model was produced

By running the skill's process on the spec + `app/`: a blind per-edge STRIDE pass (Pass 3), the
adversarial `threat-model-redteam` agent for the attack-chain synthesis (Pass 6d), and
reconciliation against the risk matrix (Pass 5). In a real repo the skill writes the deliverable
under `docs/threat-modelling/<feature-slug>/`; here it sits beside the spec for easy reading.

## Try it yourself

From this directory in Claude Code, run `/threat-model the Paylink webhook added in app/webhooks.py`,
then compare your output with [`THREAT-MODEL.md`](THREAT-MODEL.md). Run the session on `/model best`
for best results.
