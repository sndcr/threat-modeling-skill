# threat-model

A Claude Code skill for building a **threat model scoped to a specific code change**.
It runs a sequence of numbered passes (Pass 0 → 5) that produce use cases, numbered
data-flow diagrams (DFDs) in Mermaid, and a STRIDE\*-per-edge findings table with attacker
personas, risk-matrix severities, countermeasures, and verification steps.

The core value is **scope discipline**: the model covers only what the change touches, so a
reviewer can read it in about the time it takes to review the PR.

## Layout

```
skills/threat-model/
├── SKILL.md                     # the workflow (Pass 0 → 5)
└── references/
    ├── dfd-format.md            # Mermaid DFD conventions, edge numbering, boundary test
    ├── scoring.md               # attacker personas, impact rubric, risk matrix
    ├── design-mode.md           # design mode: spec + plan, requirement map, Fold step
    ├── review-mode.md           # review mode: built code against an existing model
    └── issue-tracker.md         # Pass 5: filing findings into any issue tracker
agents/
└── threat-model-skeptic.md      # Pass 4: checks closures, leads, and Criticals
```

## Install

**As a plugin** — one command, skill and agent together:

```
/plugin marketplace add sndcr/threat-modeling-skill
/plugin install threat-model@sndcr
```

This also works while the repo is private, as long as your git can authenticate to it
(SSH key in the agent, or `gh auth login`). Installed this way, plugin namespacing
applies: the command is `/threat-model:threat-model`.

**Copy install, global** — available in every repo, invoked as plain `/threat-model`:

```bash
cp -R skills/threat-model ~/.claude/skills/
cp agents/*.md ~/.claude/agents/
```

**Copy install, per-project** — version-controlled alongside the code it covers:

```bash
cp -R skills/threat-model <repo>/.claude/skills/
cp agents/*.md <repo>/.claude/agents/
```

The skill and agent are repo-agnostic; they adapt to whatever the diff and codebase
contain. The agent is optional: without it, its Pass 4 checks run inline on the main agent.

## Use

In Claude Code, from the target repo: `/threat-model <what to model>`, e.g.
`/threat-model the diff on this branch` or `/threat-model update foo/THREAT-MODEL.md`
(plugin install: `/threat-model:threat-model ...`).
The skill establishes scope from the diff/PR, pauses for use-case sign-off (Pass 1), then
builds the DFDs and findings, checks them, and writes the model to
`docs/threat-modelling/<feature-slug>/`.

### Recommended workflow

Two runs per feature:

1. **Before implementation:** run the skill on the spec and plan
   (`/threat-model design SPEC.md PLAN.md`). It folds the countermeasures into the plan as
   test-first steps.
2. **After implementation:** run it again on the result
   (`/threat-model review docs/threat-modelling/<feature-slug>/`). This pass verifies instead of re-deriving: it confirms each countermeasure
   holds (a finding is only `[DONE]` when a real, passing test backs it) and sweeps for
   code-level issues the design pass could not see.

The first run gets the countermeasures built in from the start. The second reuses the
model's DFDs and severities, so it spends its budget on verification rather than
re-derivation, which also makes it usable as a CI gate.

**Recommended runtime:** this is a reasoning-bound security task, so run the session on
`/model best` (the strongest model you have access to, with automatic Opus fallback) and a
high `/effort`. The bundled agent uses `model: inherit`, so it follows the session.

## Contributing

Improvements via PR are welcome, not required.

## License

MIT. See [LICENSE](LICENSE).
