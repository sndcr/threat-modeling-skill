# Review mode

Review built code **against an existing threat model**: check that planned countermeasures
landed with their tests, hunt implementation bugs edge by edge, and model only what's new.
Read after `SKILL.md`; where this file overrides a pass, it wins.

**Input:** the model directory and the code. The **delta** runs from the last review's head
(recorded in `## Review`) to `HEAD`; on the first review, from the `## Scope` base or the
plan's start commit, resolved to a commit SHA. If neither is recorded, ask. An empty delta:
say there's nothing to review, and stop.

## Pass overrides

| Pass | Override |
|---|---|
| 0 | Read the model. Map every edge (except those drawn as removed) to its code, `file:line`: the **edge map**. An unmapped edge is *not built*, unless it is *removed*: it was mapped in the previous `## Review` and the delta deletes that code, or the user confirms the removal. Ask once, listing the unmapped edges; for a diff-mode model, whose code existed at its base, every unmapped edge is a removal candidate. Changed code that matches no edge is a candidate new edge. **Drift guard:** if most of the changed security-relevant code matches no edge, stop and recommend a fresh diff-mode run. Unbuilt edges never trip it. |
| 1 | Reuse the signed-off use cases. Ask only about a new actor or lifecycle phase the code adds. |
| 2 | Update the DFDs in place. New edges take suffix IDs (`2a`). Draw a removed edge per `dfd-format.md`, "Removed edges"; its rows leave the table and are listed in `## Review` as retired. Never renumber. |
| 3 | **New and changed edges** (label, data, or PROTO changed in Pass 2) get full STRIDE\*; new rows on an existing edge take the next free letter. **Open rows** (`[PLAN: …]`, `[OPEN]`, issue): cite the countermeasure's code in the Countermeasure cell and its test in the Verification cell (`exists: file:line`); both → `[DONE]`, otherwise the row stays open with `missing: …` in its Verification cell. A `[PLAN: …]` row whose plan task is marked done but that isn't `[DONE]` → `[OPEN]`. Find a row's plan step by any of its finding IDs: a step under a renamed task refreshes the token; no step → `[OPEN]` (plan link stale). **`[ACCEPTED]` rows** stay unless their edge changed; then re-assess. **`[DONE]` rows:** re-check; a missing or no-longer-covering check → `[OPEN]` (regressed). **Every mapped edge:** hunt implementation bugs in the actual code (fail-open defaults, unsafe comparisons, error paths). |
| 4 | The skeptic reviews the whole model against the code; the pruner covers new and changed rows only. |
| 5 | Over everything. |
| 6 | 6a–6c on the delta; 6d only if rows were added or raised. |

## Output

Update `THREAT-MODEL.md` in place (`## Scope` stays the design-time record), with a
`## Review` section at the top that replaces any earlier one:

- the date, and `base..head` as commit SHAs;
- counts: closed, still open, regressed, new, retired;
- a status-change table: ID, from → to, reason (built, regressed, plan link stale, task done
  but missing, retired);
- the edge map (`UC1:1 → app/webhooks.py:15-25`);
- the edges not built.
