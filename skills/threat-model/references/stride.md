# STRIDE\* per edge

Ask each prompt below against *this edge's* data and direction. Raise a finding only for a
plausible attack, but check every category: Repudiation and Elevation are the easiest to
skip. Boundary edges get the most scrutiny; in-context edges usually surface only
Tampering/Elevation via in-process bugs. `*` comes last, on every edge. Record findings per
`SKILL.md`, Pass 3.

## Per-category prompts

**S — Spoofing.** Is the identity on this edge authenticated, and is the authenticator
(session, token, mTLS, signature) verified on receipt? Can it be replayed or forged? Look
hardest at edges entering a boundary with an identity claim.

> **Compromised-source lens.** On inbound boundary edges from an internal or trusted source,
> also ask: if this legitimate upstream were compromised, what could its data do here
> (T / I / E)? Spoofing is "can the identity be forged?"; this is "the identity is real, but
> the source is owned". Score it with the *Compromised trusted service / dependency* persona
> (`scoring.md`). A compromised *library* is the supply-chain note below plus Pass 6b.

**T — Tampering.** Can the data be modified in transit or at rest by someone who shouldn't?
Is integrity protected (TLS, signature, MAC, checksum)? Can a parameter, path, key, or stored
value be altered to change behaviour (path traversal, mass assignment, parameter pollution,
a poisoned cache or store)?

**R — Repudiation.** If this action is abused, is there a trustworthy record of who did it:
logged with an attributable identity, on a tamper-resistant trail?

**I — Information disclosure.** Does the edge expose data to a party that shouldn't see it?
Over-fetching, verbose errors, sensitive data in URLs or logs, missing encryption, IDOR, side
channels (timing, response size).

**D — Denial of service.** Can the edge exhaust a resource? Unbounded input, expensive
parsing (zip/image/regex bombs, deserialization), unthrottled requests, amplification,
lock or connection exhaustion, one failure taking down a shared component.

**E — Elevation of privilege.** Can crossing the edge gain capabilities the actor shouldn't
have? Missing authz after authn, confused deputy, SSRF, injection (SQL/command/template),
unsafe deserialization, privilege not dropped, an in-process bug reachable with
attacker-controlled data.

**Supply chain (spans T and E).** A *new or changed* parser, deserializer, crypto, or auth
library on a boundary edge is an attack vector in its own right. Flag it for Pass 6b.

**\* — what else?** What could go wrong on this edge that no letter names? The letters are a
checklist, and checklists cap thinking. Look for:

- **Business-logic abuse** — individually valid, collectively wrong (refund then re-claim,
  a discount applied twice, a state machine moved backwards).
- **Ordering / race / TOCTOU** — interleaved requests, check-then-use gaps, idempotency
  holes, replay of a one-time action.
- **Economic abuse** beyond classic DoS — making someone else pay (egress, per-call
  billing), quota or rate-limit gaming, free-tier farming.
- **Privacy / correlation** — joining benign fields to deanonymize, enumeration that leaks
  existence, aggregation across a tenant line.
- **Intended-but-dangerous** — the edge works as designed, and the design is the risk.

Suffix a `*` finding `-X` (`UC1:4-X`); it scores through the same matrix. If an edge has
nothing beyond the six, say so: the value is in having asked.

## Worked finding (avatar upload)

Edge `UC1:1`: Browser (anonymous) → `/upload` handler, carrying a multipart file and a
session cookie, across a boundary.

| ID | Attacker | Attack | Impact | Severity | Status | Countermeasure | Verification |
|---|---|---|---|---|---|---|---|
| UC1:1-D | Anonymous internet (Critical exp.) | Upload a multi-GB file / decompression-bomb image to exhaust memory/disk during decode (edge 2) | Service-wide DoS for all users (High) | Critical | `[OPEN]` | Enforce max upload size at the handler before buffering; cap decoder output dimensions/pixels; stream to store | add: test posting an oversized + bomb image; assert 413/400 and bounded memory; request-size metric/alert |
| UC1:1-E | Anonymous internet (Critical exp.) | Upload a file whose bytes exploit the image decoder (edge 2, in-proc) for code execution | RCE in avatar-service (Critical) | Critical | `[OPEN]` | Validate content-type/magic bytes; use a memory-safe/sandboxed decoder; keep decoder lib patched | add: fuzz the decode path; pin + scan the decoder dependency; assert non-image inputs rejected |
