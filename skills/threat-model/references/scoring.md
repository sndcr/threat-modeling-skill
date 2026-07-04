# Scoring

Severity is a **risk-matrix lookup**: attacker *exposure weight* × *impact weight*.
Pick the attacker persona, pick the impact level, read the cell. This keeps scores
defensible — a reviewer can argue with the inputs, not the arithmetic.

## Attacker personas (exposure weight)

Exposure reflects how reachable and how numerous the attacker is — i.e. how easy it is
for *someone* to be in a position to attempt the attack. Pick the **weakest precondition**
attacker who can perform the attack on that edge.

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

If several personas can run the attack, score with the **highest-exposure** one that
realistically can.

**Compromised trusted service / dependency** is distinct from *adjacent service /
network foothold*: the foothold persona is an attacker on a *neighbouring* service
probing across a boundary, whereas this persona is the legitimate, authenticated source
*on this very edge* being owned and turned hostile. It is also distinct from Spoofing
(forging the identity) — here the identity check passes and the trust is real; the
*source* is what's compromised. We never treat a source as out-of-scope because it's
trusted — instead it scores here, at **Low** exposure. The strong precondition keeps it
Low on most edges (the "usually low severity" defence-in-depth case), and the matrix lets
it escalate to High *only* when the blast radius is Critical (Low × Critical = High) —
i.e. a trusted dependency sitting on an edge into a crown-jewel asset with no secondary
control behind it. That escalation is the signal worth surfacing, not noise to suppress.

## Impact weight

Impact reflects the consequence if the attack succeeds. Use the STRIDE outcome on the
edge to judge it.

| Impact | Examples |
|---|---|
| **Critical** | RCE/code execution, auth bypass to admin, tenant-isolation break, mass data breach, full integrity loss of system-of-record |
| **High** | Sensitive data disclosure (PII/secrets/tokens), privilege escalation, integrity loss of important data, durable repudiation of security events |
| **Medium** | Limited/low-sensitivity disclosure, DoS of a single component/tenant, tampering with non-critical data |
| **Low** | Minor info leak (versions, timing), self-inflicted DoS, low-value repudiation, requires implausible conditions |

## Risk matrix

Read severity at the intersection of attacker exposure (rows) and impact (columns).

| Exposure ↓ \ Impact → | Low | Medium | High | Critical |
|---|---|---|---|---|
| **Critical** | Medium | High | Critical | Critical |
| **High** | Low | Medium | High | Critical |
| **Medium** | Low | Medium | Medium | High |
| **Low** | Low | Low | Medium | High |

Notes:

- The matrix is intentionally conservative at the top-left-to-bottom-right diagonal:
  high exposure + high impact dominates.
- A boundary-crossing edge reachable by an anonymous attacker with Critical impact is
  always Critical. An admin-only action with Low impact is always Low.
- If exposure and impact genuinely sit between two levels, round **up** and note the
  assumption in the Attack or Impact cell.

## Score at the edge; compose in Pass 6d

Score each finding by the attacker intrinsic to **its own edge**: the weakest-precondition
attacker who can reach that edge **assuming the other edges' controls hold**. When an edge
sits behind an authn/authz step, the intrinsic attacker is the principal that legitimately
passes it — e.g. a *compromised trusted dependency* on a webhook's DB-write edge (Low
exposure, see the persona note above), not the anonymous internet.

Do **not** propagate an upstream finding's *bypassed* exposure into a downstream finding's
score — don't rate a DB-write "anonymous / Critical" merely because a *separate*
signature-verification finding is open. That elevation is real, but it is **composition**
(one open finding removing another's precondition), and it is **Pass 6d**'s job. Scoring it
both per-edge and in the chain double-counts, floods the table with inherited Criticals, and
hides the very escalation 6d exists to surface. Keep per-edge severities isolated; 6d raises a
chain's *effective* severity and names the break-point that severs it.

## Recording in the findings table

- **Attacker** cell: persona name (exposure weight is implied by the persona; you may
  append it, e.g. "Anonymous internet (Critical exposure)").
- **Impact** cell: the consequence in words + the impact weight, e.g. "Reads any user's
  avatar bytes — sensitive data disclosure (High)".
- **Severity** cell: the matrix result (Low/Medium/High/Critical).
