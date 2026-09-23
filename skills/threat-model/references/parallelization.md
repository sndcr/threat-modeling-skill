# Parallelizing with sub-agents (optional, Claude Code only)

Only when subagents are available **and** there are roughly **4+ use cases**; below that,
the overhead outweighs the gain, so run Passes 2–3 inline. Every launch follows
`SKILL.md`, *Launching the bundled subagents*.

1. **Passes 0, 1, and 7 stay on the main agent**: they're interactive.
2. **Passes 2–3:** after sign-off, spawn one `threat-model-worker` per use case with the use
   case, its number, and its slice of the diff by path (design mode: the spec and plan by
   path, naming its sections; review mode: its slice of the delta, the plan if the model has
   one, and the Pass 0 edge map with its removed and not-built edges). With an existing model,
   add the use case's `.mmd` and `### UC<n>` table by path. Workers return text: a DFD,
   findings, signal notes, variant leads, assumptions, and in review mode each status change
   with its reason.
3. **Pass 4:** `threat-model-skeptic` over the collected draft (review mode: plus the edge
   map), then `threat-model-pruner` over the draft plus the skeptic's output (review mode:
   plus the IDs of added or edited rows, from the workers' status changes). In sequence, not
   parallel. Fold in per `SKILL.md` Pass 4.
4. **Pass 5:** `threat-model-reconciler` over the verified rows, variant leads, and
   assumptions (review mode: and the status changes).
5. **Pass 6:** 6a–6c on the main agent; 6d via `threat-model-redteam` (review mode: only if
   rows were added, raised, or reopened, with their IDs), then add its break-points to the top
   fixes. The main agent writes `THREAT-MODEL.md` and the `dfd/*.mmd` files.

If your Claude Code version ignores subagent frontmatter `model`, pass the session's model
on the Agent call.
