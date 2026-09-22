# Parallelizing with sub-agents (optional, Claude Code only)

Read this only when you've decided to fan out — i.e. sub-agents are available **and**
there are roughly **4+ use cases**. Below that, the orchestration overhead outweighs the
gain: run Passes 2–3 inline on the main agent and ignore this file.

Passes 2 and 3 are independent per use case, which is what makes the fan-out safe. The
roster and the launch contract (skill directory, inputs by path, the data rule) are in
`SKILL.md`, *Launching the bundled subagents*; every launch below follows it.

Flow:

- **Keep Pass 0, Pass 1, and Pass 7 on the main agent.** They're interactive (use-case
  sign-off, issue-tracker filing) and cannot be delegated.
- **Fan out by use case (Passes 2–3).** After sign-off, spawn one `threat-model-worker`
  per use case, passing the use case, its number, and the relevant slice of the diff by
  path. Workers return text, not files: a DFD, findings, signal notes, variant leads, and
  assumptions.
- **Verify (Pass 4).** Hand the collected draft to `threat-model-skeptic`, then hand the
  draft plus the skeptic's output to `threat-model-pruner`. Run them in sequence, not in
  parallel, so the skeptic's additions are pruned too. Fold the result in as `SKILL.md`
  Pass 4 describes.
- **Reconcile (Pass 5).** Hand the verified rows, variant leads, and assumptions to
  `threat-model-reconciler` (or do it inline). Mandatory: re-deriving severity centrally
  from `scoring.md` is what keeps the model internally consistent.
- **Cross-cutting (Pass 6) and write.** The main agent runs 6a–6c over the reconciled
  set; for 6d, hand the reconciled findings + DFDs to `threat-model-redteam` (prefer it
  over inline self-review), then update the Findings Summary's top fixes with its
  break-points. The main agent then writes the result to
  `docs/threat-modelling/<feature-slug>/THREAT-MODEL.md` and the per-UC `dfd/*.mmd` files.

If your Claude Code version ignores subagent frontmatter `model`, pass the session's model
explicitly on the Agent tool call so the subagents run on the model you chose.
