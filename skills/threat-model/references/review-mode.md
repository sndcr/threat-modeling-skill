# Review mode

Review built code **against an existing threat model**: check that planned countermeasures
landed with their checks, hunt implementation bugs edge by edge, and model only what's new.
Read after `SKILL.md`; where this file differs from it, this file wins.

**Input:** the model directory, the code, and, for a design-mode model, the plan (its path is
in `## Scope`; if the file is gone, ask). The **delta** runs from the last review's head
(recorded in `## Review`) to `HEAD`. On the first review it starts at the commit `## Scope`
records: diff mode's base ref, or design mode's `HEAD` SHA. Resolve a branch name with
`git merge-base <branch> HEAD`. If that gives `HEAD`, or the start commit is not an ancestor
of `HEAD` (after a rebase or squash), ask. If `## Scope` records no base, ask. An empty delta:
say there's nothing to review, and stop.

**IDs never change.** Existing edge and finding IDs keep pointing where they did: the plan and
filed issues link by them.

## Pass overrides

| Pass | Override |
|---|---|
| 0 | See *Pass 0: edge map* below. |
| 1 | Reuse the signed-off use cases. Ask only about a new actor or lifecycle phase the code adds; a new use case numbers its edges from 1. |
| 2 | Update the DFDs in place. A new edge in an existing DFD takes a suffix ID (`2a`). An edge is **changed** when its label changes. Draw a removed edge per `dfd-format.md`, "Removed edges"; its rows leave the table and are listed in `## Review` as retired. |
| 3 | See *Pass 3: rows* below. |
| 4 | The skeptic reviews the whole model against the code, is given the edge map, and may `REOPEN` a row the code no longer backs; an accepted `REOPEN` returns the row to its earlier open token (else `[OPEN]`), with `missing: …`; the reason is `regressed` only for a row that was `[DONE]` before this review. The pruner covers the rows this review added or changed, flips to `[DONE]` included, and is given their IDs. Scope is the model's edges, not the delta. |
| 5 | Over everything; the reconciler is given the status changes. Afterwards, a `[PLAN: …]` row whose plan task is done → `[OPEN]`. |
| 6 | 6a–6c on the delta; 6d only if rows were added or raised, and the redteam is given their IDs. |

### Pass 0: edge map

1. Read the model. Map every edge, except those drawn as removed, to its code (`file:line`):
   the **edge map**.
2. **Drift guard:** list the delta's trust-relevant surfaces (`SKILL.md`, Pass 0). If more than
   half match no edge, stop and recommend a fresh diff-mode run. A dependency matches the edge
   whose code uses it. Unbuilt edges never trip it.
3. An unmapped edge is *removed* if the previous `## Review` mapped it and the delta deletes
   that code. In a diff-mode model, whose code existed when it was modelled, every other
   unmapped edge is a removal candidate, never *not built*. Otherwise it is *not built*, unless
   the user says removed (step 4).
4. Ask once: "removed, or not built?" for unmapped edges step 3 didn't settle, and "removed?"
   for diff-mode removal candidates; if not, map it again (it moved).
5. Changed code that matches no edge is a candidate new edge (Pass 2).

### Pass 3: rows

- **New and changed edges** get full STRIDE\*. A changed edge keeps its rows (checked below);
  add rows only for weaknesses they don't cover. A new row takes its category letter, plus
  the next free suffix if that ID is taken (`UC1:4-Tb` beside `UC1:4-T`).
- **Plan lookup first** (design-mode models): find each `[PLAN: …]` row's plan step by any of
  its finding IDs. A step under a different task refreshes the token; no step → `[OPEN]`
  (plan link stale).
- **Open rows** (`[PLAN: …]`, `[OPEN]`, issue): cite the countermeasure's code in the
  Countermeasure cell and its check in the Verification cell (`exists: file:line`). Both, and
  no bug below defeats it → `[DONE]`. Otherwise the row stays open: its Verification keeps its
  `add: …` and gains `missing: <what>`. A `[PLAN: …]` row whose plan task is done (all its
  steps checked) but that isn't `[DONE]` → `[OPEN]`.
- **`[DONE]` rows:** re-check both citations, updating moved line numbers. A countermeasure or
  check that is gone or no longer covers the countermeasure → `[OPEN]` (regressed), with
  `missing: <what>`.
- **`[ACCEPTED]` rows** stay unless their edge changed; then re-assess.
- **Every mapped edge:** hunt implementation bugs in the actual code (fail-open defaults,
  unsafe comparisons, error paths). A bug that defeats a row's countermeasure keeps that row
  open or regresses it (`missing: …`); any other bug is a new row.

## Output

Update `THREAT-MODEL.md` in place (`## Scope` stays the design-time record), with a
`## Review` section at the top that replaces any earlier one:

- the date, and `base..head` as commit SHAs;
- this review's counts: closed, still open, regressed, new, retired;
- a status-change table: ID, from → to (`new` for an added row, `—` for a retired one),
  reason (e.g. built, regressed, bug found, plan link stale, token refreshed, task done but
  missing, re-assessed, retired);
- the edge map (`UC1:1 → app/webhooks.py:15-25`), which the next review's removal test reads;
- the edges not built.
