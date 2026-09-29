# Eval results

Measurements behind 2.0, September 2026. Agent runs on Claude Opus 5.5 at medium effort
unless noted; recall judged by Claude Sonnet 5 (`judge.py`), precision graded blind by Opus
agents. Raw traces and per-claim grades are kept out of the repo.

## Setup

- **Cases:** `jobline-async` (design mode: a spec and a plan, 9 must-finds including a planted
  spec–plan gap, 17 judge items), `paylink-webhook` (diff mode: a small webhook, 7 must-finds,
  8 must-not-claims, 16 judge items), `paylink-review` (review mode, 6 judge items).
- **Prompts** are neutral: the agent identifies the use cases itself and asks nothing. The
  baseline gets the same request with no plugin installed.
- **Arms:**
  - *full*: the 1.x-style skill (Passes 0–7, five agents: worker, skeptic, pruner, reconciler,
    red team).
  - *thin*: the deliverable and its checks only, no agents.
  - *thin + skeptic*: thin plus one read-only skeptic in Pass 4. This is 2.0.
  - *baseline*: Opus with no skill.
- **Recall** (`judge.py`): one PASS/FAIL verdict per ground-truth item.
- **Precision** (blind grader): every open claim (Critical and High always, up to 12
  Medium/Low), graded real / real but weak / not real against the pristine inputs, severity
  re-derived from `scoring.md`. For design runs, a closure check too: does each `[PLAN]` row
  citing an existing plan step, and each `[ACCEPTED]` row, actually stop the attack as stated?

## Jobline (design mode)

| Arm | Runs | Time | Recall /17 | Open claims | Not real | Severity right | Must-finds /9 | Planted gap |
|---|---|---|---|---|---|---|---|---|
| Full | 2 | 36, 55 min | 17, 16 | 33, 78 | 0, 4 | 49/59 | 8, 8 | 2/2 |
| Thin | 2 | 21, 27 min | 16, 11 | 14, 4 | 0, 0 | 16/18 | 8, 3 | 1/2 |
| Baseline | 2 | 5, 6 min | 16, 14 | 16, 22 | 1, 1 | 22/33 | 8, 7 | 0/2 (0/7 over all baseline runs) |
| **Thin + skeptic** | 5 | 24–32 min | 16, 17, 17, 17, 17 | 17–27 | 0, 1, 1, 0, 1 | 100/106 | 8, 9, 9, 9, 9 | 5/5 |

Thin + skeptic closure check: 0 false closures in 122 checked `[PLAN]` and `[ACCEPTED]` rows.
In three of its five runs one false Critical or High claim got through (a tenant-set
`tenant_id` the spec takes from the token). The skeptic's independent walk of every open Critical was added after
these runs; in the two runs since, that claim did not appear (recall 14, 17; not yet graded).

Thin alone shows why the skeptic is there: one run in two over-credited the plan (23 of 30
rows closed as `[PLAN]`), accepted risks it should have analysed, and pushed two must-finds
into out-of-change leads.

## Paylink (diff mode)

| Arm | Runs | Time | Recall /16 | Open claims | Real / weak / not real | Severity right | Must-finds /7 |
|---|---|---|---|---|---|---|---|
| Full | 2 | – | 15*, 16 | 12, 15 | 7/5/0, 8/7/0 | 23/26 | 7, 7 |
| Thin | 2 | – | 16, 16 | 7, 8 | 7/0/0, 7/1/0 | 14/15 | 7, 7 |
| Baseline | 2 | – | 16, 15 | 10, 8 | 6/4/0, 6/2/0 | 9/18 | 7, 7 |
| **Thin + skeptic** | 2 | 5, 5 min | 15*, 16 | 9, 9 | 8/1/0, 6/3/0 | 16/18 | 7, 7 |

\* judge error: some must-not-claim items are worded as the true fact, and the judge failed a
model that stated that fact. No run asserted a must-not-claim.

Every arm finds paylink's must-finds; the difference is severity accuracy and noise.

## Review mode

`paylink-review`: the paylink change, its diff-mode model, and a later commit that fixes one
finding (with a test), half-fixes another (no test), and adds a header-controlled signature
bypass. Four runs:

| Runs | Recall /6 | Notes |
|---|---|---|
| Before the Scope rule, 2 | 6, 4 | one merged the bypass into the fixed row and left it open; one described the old code in `## Scope` |
| After, 2 | 6, 6 | fixed row `[DONE]` citing its test by name; bypass found as a new Critical; untested state guard and replay kept open |

## Weaker models

Recall only, not precision-graded.

| Arm | Main / subagents | Jobline /17 | Paylink /16 | Time (jobline, paylink) |
|---|---|---|---|---|
| Full | Haiku 4.5 / Haiku | 8, 8 | – | – |
| Thin + skeptic | Haiku 4.5 / Haiku | 8, 11, one failed run | – | – |
| Full, every pass fanned out | Opus 5.5 / Haiku 4.5 | 17, 17 | 16, 16 | 49 min and a 60-min timeout; 31, 23 min |

- A Haiku main agent halves jobline recall with either skill; the full skill's detailed
  procedure doesn't rescue it. One Haiku run read the spec from the wrong path and stopped.
- Opus orchestrating Haiku workers matches Opus-only recall but is the slowest setup: the
  main agent still writes and edits the whole model, and adds prompting, reading back, and
  merging the workers' output.
- With Opus workers, the fanned-out run ended its turn before its background workers
  reported in four of five runs (headless), so no model was written. 2.0 has no fan-out; its
  one agent runs in sequence.

Earlier, Sonnet 5 on the full skill had recall close to Opus.

## Caveats

Two runs per cell (five for thin + skeptic on jobline), one grader per model, and graders
differ in strictness: treat differences of one or two claims as noise. Paylink's must-finds
are salient, so it separates the arms on precision only.
