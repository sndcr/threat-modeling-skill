# STRIDE\* per edge

Apply STRIDE\* to **each numbered edge**. For each category, ask the prompt below against
*this edge's* data and direction. Raise a finding only when there's a plausible attack —
but check every category, because the easy-to-skip ones (Repudiation, Elevation) are
where real gaps hide. Boundary-crossing edges deserve the most scrutiny; in-context
edges usually only surface Tampering/Elevation via in-process bugs.

The model is **STRIDE\***: the six classic letters plus a first-class `*` — the
open-ended "what else?" category. The letters are a checklist (coverage, defensibility);
the `*` is the antidote to the checklist's blind spot, where threats that don't fit any
letter get named. Walk it on every edge, last.

Each category maps to a violated property:

| Letter | Threat | Property violated |
|---|---|---|
| S | Spoofing | Authentication |
| T | Tampering | Integrity |
| R | Repudiation | Non-repudiation |
| I | Information disclosure | Confidentiality |
| D | Denial of service | Availability |
| E | Elevation of privilege | Authorization |
| \* | Anything the six don't name | (open — business logic, ordering, economics, abuse) |

## Per-category prompts

**S — Spoofing.** Can the source of this edge be impersonated? Is the identity on this
edge authenticated, and is the authenticator (session, token, mTLS, signature) verified
on receipt? Can an attacker replay or forge it? Look hard at edges entering a trust
boundary that carry an identity claim.

> **Compromised-source lens (defence in depth).** On inbound boundary edges from an
> *internal or trusted* source, ask a second question beyond Spoofing: if this legitimate
> upstream were itself compromised, what does the data it sends get to do here (T / I / E)?
> Spoofing is "can the identity be forged?"; this is "the identity is real and the trust is
> genuine, but the source is owned." Score it with the **Compromised trusted service /
> dependency** persona (Low exposure) in `scoring.md` — we never drop a finding because the
> source is trusted; we weight it down and let the matrix escalate it only where the blast
> radius is Critical. The in-process counterpart (a compromised *library* rather than a
> *service*) is the Supply-chain note below + the 6b dependency-currency pass.

**T — Tampering.** Can the data on this edge be modified in transit or at rest by someone
who shouldn't? Is integrity protected (TLS, signatures, MAC, checksums)? Can a parameter,
path, key, or stored value be altered to change behavior (path traversal, mass
assignment, parameter pollution, poisoned cache/store)?

**R — Repudiation.** If this action is abused, is there a trustworthy record of who did
it? Are security-relevant events on this edge logged with an attributable identity, and
are those logs tamper-resistant? Can the actor deny the action credibly?

**I — Information disclosure.** Does this edge expose data to a party that shouldn't see
it? Over-fetching, verbose errors/stack traces, sensitive data in URLs/logs, missing
encryption, IDOR returning another principal's data, side channels (timing, response
size).

**D — Denial of service.** Can this edge be made to exhaust a resource? Unbounded
input size, expensive parsing (zip/image/regex bombs, deserialization), unthrottled
requests, amplification, lock/connection exhaustion, a single failure taking down a
shared component.

**E — Elevation of privilege.** Can crossing this edge gain capabilities the actor
shouldn't have? Missing/incorrect authorization check after authentication, confused
deputy, SSRF turning a process into a proxy, injection (SQL/command/template) granting
execution, unsafe deserialization, privilege not dropped, in-process bug reachable with
attacker-controlled data.

**Supply chain (spans T and E).** If a *new or changed* dependency processes this edge's
data — a parser, deserializer, crypto, or auth library on a boundary-crossing edge — note
it here. A vulnerable or unpatched dependency on the path is a Tampering/Elevation vector
in its own right. Flag the dependency so the cross-cutting dependency-currency pass (6b)
can attach a pinning + patching control.

**\* — the open question (always last, always asked).** Having walked the six letters,
ask: **what else could go wrong on this edge that none of S/T/R/I/D/E names?** The six
are a checklist, and checklists cap thinking — the `*` is where you escape the grid.
Look specifically for the threat shapes STRIDE has no letter for:

- **Business-logic abuse** — a sequence that's individually valid but collectively wrong
  (refund then re-claim, apply a discount twice, transition a state machine backwards).
- **Ordering / race / TOCTOU** — two requests interleaving, check-then-use gaps,
  idempotency holes, replay of a one-time action.
- **Economic / resource abuse** that isn't classic DoS — making *someone else* pay
  (egress, per-call billing), quota or rate-limit gaming, free-tier farming.
- **Privacy / correlation** — joining benign fields to deanonymize, enumeration that
  leaks existence, aggregation crossing a tenant line.
- **Intended-but-dangerous** — the edge works exactly as designed, and the design is the
  risk.

Score a `*` finding through the same persona × impact matrix as any other; suffix its ID
`-X` (e.g. `UC1:4-X`). If the edge genuinely has nothing beyond the six, say so — the
value is in having *asked*, on every edge. The Pass 4 skeptic is the backstop, not a
substitute: catch it here first.

## Mapping threats to the table

For each threat raised on edge `UC<n>:<k>`:

1. Name the **attacker persona** that can reach this edge (lowest precondition that
   works) — drives exposure weight.
2. Write the **attack** concretely against this edge's data/direction.
3. State the **impact** and its weight.
4. **Severity** = matrix(exposure, impact) — see `scoring.md`.
5. Give a specific **countermeasure** (control + where it goes in the changed code).
6. Give a **verification** — a test, check, or observable that proves the control works
   and catches regression, ideally by triggering the attack and asserting it fails; cite
   where it exists today (`file:line`), or mark it `add: …`.
7. Set **Status**: `[DONE]` only if a verification exists today and is cited by location;
   else `[OPEN]`, `[<issue-id>]` (filed), or `[ACCEPTED]` (documented accepted risk). A fix
   with no proof is not `[DONE]`.

When one edge has multiple findings, suffix the ID with the letter, e.g. `UC1:1-S`,
`UC1:1-I`. Two findings under the same letter on one edge take lowercase disambiguators:
`UC1:1-Sa`, `UC1:1-Sb`.

## Worked finding (from the avatar-upload example)

Edge `UC1:1` — Browser(anon) → /upload handler, data = multipart file + session cookie,
crosses boundary.

| ID | Attacker | Attack | Impact | Severity | Status | Countermeasure | Verification |
|---|---|---|---|---|---|---|---|
| UC1:1-D | Anonymous internet (Critical exp.) | Upload a multi-GB file / decompression-bomb image to exhaust memory/disk during decode (edge 2) | Service-wide DoS for all users (High) | Critical | `[OPEN]` | Enforce max upload size at the handler before buffering; cap decoder output dimensions/pixels; stream to store | add: test posting an oversized + bomb image; assert 413/400 and bounded memory; request-size metric/alert |
| UC1:1-E | Anonymous internet (Critical exp.) | Upload a file whose bytes exploit the image decoder (edge 2, in-proc) for code execution | RCE in avatar-service (Critical) | Critical | `[OPEN]` | Validate content-type/magic bytes; use a memory-safe/sandboxed decoder; keep decoder lib patched | add: fuzz the decode path; pin + scan the decoder dependency; assert non-image inputs rejected |
