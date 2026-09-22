# Scoring

Severity is a **risk-matrix lookup**: attacker exposure × impact. Pick the persona, adjust for
capability, pick the impact, read the cell. A reviewer can then argue with the inputs, not
the arithmetic.

## Attacker personas (exposure weight)

Exposure is how reachable and how numerous the attackers are. Pick the **weakest
precondition** attacker who can reach the edge **directly** and perform the attack, assuming
the other edges' controls hold ("Score at the edge", below).

| Persona | Exposure | Rationale |
|---|---|---|
| Anonymous internet / unauthenticated remote | **Critical** | Anyone, no barrier, huge population |
| Authenticated external user (any customer/tenant) | **High** | Low barrier (just sign up), large population |
| Low-privilege / restricted authenticated user | **High** | Reachable, intended to be contained |
| Adjacent service / network foothold / other tenant | **Medium** | Requires a prior position |
| Privileged internal user (CI/CD, operator, support) | **Medium** | Trusted but not fully; insider risk |
| Administrator / root / infra owner | **Low** | Few, highly trusted, high barrier |
| Compromised trusted service / dependency | **Low** | Requires a prior compromise of a component we trust — strong precondition, but operates *inside* the trust relationship |
| Physical-access / hardware insider | **Low** | Strong precondition |

If several personas can reach the edge directly, score with the **highest-exposure** one. An
upstream open finding that lets a stronger persona through is composition, not reach: it
belongs to Pass 6d, not to the row.

**Compromised trusted service / dependency** is the legitimate, authenticated source *on
this edge*, owned and turned hostile: the identity check passes and the trust is real. That
differs from a *network foothold* (an attacker on a neighbouring service probing across a
boundary) and from Spoofing (a forged identity). A source is never out of scope because it's
trusted; it scores here, at Low. The matrix raises it to High only when the impact is
Critical (Low × Critical = High): a trusted dependency on an edge into a crown-jewel asset
with no secondary control. That escalation is signal, not noise.

## Capability (who can perform it)

Exposure counts the attackers who can **reach** the edge *and* **perform** the attack. Reach
is the persona; capability narrows it. This is not probability: it is decided on evidence,
the way reach is decided on the DFD.

| Tier | Evidence test | Examples | Effect |
|---|---|---|---|
| **Commodity** | A public tool or PoC exists, or it's simple request manipulation | sqlmap, replaying a request, editing an id | Persona exposure unchanged |
| **Specialist** | Published attack, but it needs expertise, significant resources or volume, or a precise position | 3DES via Sweet32 (hundreds of GB of captured traffic), a LAN timing oracle, a narrow race window | One exposure step down (Critical → High → Medium → Low; Low stays Low) |
| **Beyond practical** | No known practical attack | Brute-forcing AES-256, guessing a 128-bit secret, a remote nanosecond timing oracle through internet jitter | Not a finding. If the fix is trivial, list it in the **Hardening** note in `## Findings Summary` |

Commodity is the default. A specialist or beyond-practical tier names its evidence (the
paper, the precondition) in the Attack cell, so it can be challenged. Keep to three coarse
steps: finer grading turns back into probability guessing. A specialist attack with Critical
impact still scores at least High, by design.

## Impact weight

The consequence **if the attack succeeds**, nothing else. How hard the attack is belongs to
capability: a forged signature is a Critical impact even when forging it is beyond practical.

| Impact | Examples |
|---|---|
| **Critical** | RCE/code execution, auth bypass to admin, tenant-isolation break, mass data breach, full integrity loss of system-of-record |
| **High** | Sensitive data disclosure (PII/secrets/tokens), privilege escalation, integrity loss of important data, durable repudiation of security events |
| **Medium** | Limited/low-sensitivity disclosure, DoS of a single component/tenant, tampering with non-critical data |
| **Low** | Minor info leak (versions, timing), self-inflicted DoS, low-value repudiation |

## Risk matrix

| Exposure ↓ \ Impact → | Low | Medium | High | Critical |
|---|---|---|---|---|
| **Critical** | Medium | High | Critical | Critical |
| **High** | Low | Medium | High | Critical |
| **Medium** | Low | Medium | Medium | High |
| **Low** | Low | Low | Medium | High |

Between two levels, round **up** and note the assumption in the Attack or Impact cell.

## Score at the edge; compose in Pass 6d

Score each finding with the attacker intrinsic to **its own edge**, assuming the other edges'
controls hold. Behind an authn/authz step, that is the principal that legitimately passes
it: on a webhook's DB-write edge, a *compromised trusted dependency* (Low), not the anonymous
internet.

Don't carry an upstream finding's bypass into a downstream row: a DB write is not "anonymous
/ Critical" because a separate signature finding is open. That escalation is real, but it is
composition, and Pass 6d prices it. Scoring it in both places double-counts, fills the table
with inherited Criticals, and hides the escalation 6d exists to show.

**Relayed fields keep their original author.** For a value that arrives through a trusted
relay (a processor's signed webhook, an IdP token, a queue), the intrinsic attacker is
whoever originally supplied it (`dfd-format.md`, "Data provenance"). A tenant that can set
the invoice id on its own payment at the processor is an *authenticated external user*
(High) on the webhook's DB-write edge, not a *compromised trusted service* (Low). This is not
a bypass: the tenant legitimately passes the relay's controls. When neither the code nor the
relay's documentation settles it, record it under Assumptions.

## Recording in the findings table

- **Attacker:** the persona, with the tier when not commodity and optionally the exposure:
  "Anonymous internet, specialist (High exposure)".
- **Impact:** the consequence and its weight: "Reads any user's avatar bytes — sensitive
  data disclosure (High)".
- **Severity:** the matrix cell.
