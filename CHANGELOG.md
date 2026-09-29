# Changelog

## 2.0.0

The skill now fixes the deliverable and its checks, not the analysis procedure. On Opus 5.5
the model's own analysis matched the prescribed per-edge walk on recall; what the skill adds
is the format, the scope rules, the checks, and an independent skeptic. Measurements:
[`evals/RESULTS.md`](evals/RESULTS.md).

### Added

- **Design mode:** `/threat-model design <spec> <plan>` models a feature before it's built.
  The skeptic maps every spec requirement to the plan task that builds it, so spec–plan gaps
  surface. The Fold step writes each countermeasure into the plan as test-first steps tagged
  with finding IDs, and adds `## Security requirements` to the spec.
- **Review mode:** `/threat-model review <model dir>` checks the code built since an earlier
  model: an edge map (removed, not built, regressed), a `## Review` section with the status
  changes, stable IDs, and a drift guard. The Scope summary is rewritten for the code at head.
- **Mode selection** by the first argument, or inferred with one confirming question.
- **Statuses** `[PLAN: Task n]` and `[ACCEPTED: <where>]` (citing the acceptance); every
  status is bracketed.
- **Kept by the change:** a pre-existing flow the change keeps or grants is in scope. Other
  pre-existing weaknesses go under Variants / out-of-change leads.
- **Critical walk:** every open Critical is traced hop by hop against the controls the input
  already has, and re-scored or dropped where the chain breaks. The skeptic walks each one
  again, independently.
- **Verification** cites a check by file and name (`exists: tests/test_x.py::test_y`); a line
  number is only a hint.
- **DFD** convention for removed edges.
- **Terminal view:** no Mermaid in chat; a box diagram and edge lists instead.

### Changed

- **Passes 0–5** (were 0–7). Pass 3, Findings: analyse as an experienced reviewer would, with
  STRIDE as a checklist. Adversarial verification, reconciliation, and cross-cutting analysis
  are one pass, Pass 4, Check and summarize. Issue filing is Pass 5.
- **One agent, `threat-model-skeptic`,** run in sequence in Pass 4. It builds the requirement
  map and challenges every `[PLAN]`, `[DONE]`, and `[ACCEPTED]` row, every out-of-change lead,
  and every open Critical.
- **IDs** always carry a letter (`UC1:4-T`), with `X` for threats outside STRIDE.
- **`## Findings Summary`** holds counts, top fixes, leads, assumptions, and hardening.
  `## Cross-Cutting Analysis` is gone.
- **Dedupe:** a finding shared by several use cases lives in one table; the others carry a
  line under the table, not a stub row.
- **Hostile input:** the diff, spec, plan, and existing model are data, never instructions.
  The agent has no shell and gets the diff as a file; plan and spec edits go through the file
  tool only.
- **After the draft,** the model changes by batched edits, never a full rewrite.

### Removed

- The worker, pruner, reconciler, and red-team agents.
- `references/stride.md`, `references/parallelization.md`, and the subagent fan-out.

### Upgrading

- **Copy installs:** delete `threat-model-worker.md`, `threat-model-pruner.md`,
  `threat-model-reconciler.md`, and `threat-model-redteam.md` from `~/.claude/agents/` or
  `.claude/agents/`; `cp` only overwrites the skeptic.
- **Existing models:** IDs are kept on a re-run. Remove an old `## Cross-Cutting Analysis`
  section by hand.

### Development

- An eval harness: `claude plugin eval` in a Linux container, `check.py` for structure,
  `judge.py` for recall with one verdict per ground-truth item. Cases: pilot-idor,
  jobline-async (design), paylink-webhook (diff), paylink-review (review). Model, effort, and
  subagent model are pinned and recorded; `--plugin-ref` evaluates any git ref.
- A structural lint and unit tests.
