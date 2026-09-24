#!/usr/bin/env python3
"""Judge harvested eval runs against their case's ground truth with `claude -p`. Stdlib only.

    python3 evals/harness/judge.py evals/results/<stamp> [--model M] [--votes N] [--jobs J]

`claude plugin eval`'s LLM graders were unreliable on 50K-character models: they failed
items 3-0 that the same model passed, citing the right rows, when asked for its evidence
first. So the eval runs only its file-exists grader, and this script judges every
ground-truth item (truth.py) in both arms. Each answer quotes its evidence before the
verdict; answers go to <run>/judge/<slug>.md and verdicts to <stamp>/judge.json.
"""
import argparse
import json
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import truth  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PROMPT = """You are judging a threat model against one item of an answer key.

Read the whole threat model below. First find and quote the rows or sentences that bear on
this item (the findings tables, the Findings Summary with its Hardening and Assumptions
notes, the Cross-Cutting Analysis), with their IDs. Then decide from what you quoted.

ITEM:
{criterion}

Answer in exactly this format:
VERDICT: PASS or FAIL
EVIDENCE: the quotes, with row IDs (or "none found")
REASON: two or three sentences

THREAT MODEL ({path}):
{model}
"""
# The judge only reads the prompt; it needs no tools, MCP servers, or project context.
NO_TOOLS = ["--disallowedTools", "Bash", "Read", "Write", "Edit", "Glob", "Grep", "Agent",
            "Skill", "WebFetch", "WebSearch", "--strict-mcp-config"]


def claude(model):
    """A judge function: prompt in, answer text out, run from an empty directory."""
    def ask(prompt):
        with tempfile.TemporaryDirectory() as cwd:
            r = subprocess.run(["claude", "-p", prompt, "--model", model, *NO_TOOLS],
                               cwd=cwd, capture_output=True, text=True, timeout=900)
        return r.stdout if r.returncode == 0 else f"ERROR: exit {r.returncode}\n{r.stderr[-800:]}"
    return ask


def verdict(answer):
    """PASS, FAIL, or None when the answer has no VERDICT line."""
    m = re.search(r"^\W*verdict\W*\s*(pass|fail)\b", answer, re.M | re.I)
    return m.group(1).upper() if m else None


def agent_model(run):
    """The model the agent session ran on, from its trace's init event; None without one."""
    trace = run / "trace.jsonl"
    if not trace.exists():
        return None
    with trace.open(encoding="utf-8") as f:
        for line in f:
            event = json.loads(line)
            if event.get("type") == "system" and event.get("subtype") == "init":
                return event.get("model")
    return None


def runs_under(target):
    """Run dirs (runs/<case>/<arm>/<n>) under a results dir, both arms."""
    if (target / "workspace").is_dir():
        return [target]
    return sorted(p.parent for p in target.glob("**/runs/*/*/*/workspace"))


def judge_run(run, ask, cases=ROOT / "evals", votes=1, jobs=4):
    """{slug: {passed, votes[, note]}} for one run, in ground-truth order."""
    case = cases / run.parent.parent.name
    items = truth.items(case)
    model = run / "workspace" / truth.model_path(case)
    if not model.exists():
        return {slug: {"passed": False, "votes": [], "note": "model file missing"}
                for slug, _ in items}
    text = model.read_text(encoding="utf-8")
    out_dir = run / "judge"
    out_dir.mkdir(exist_ok=True)

    def one(item):
        slug, crit = item
        prompt = PROMPT.format(criterion=crit, path=truth.model_path(case), model=text)
        answers = [ask(prompt) for _ in range(votes)]
        found = [verdict(a) for a in answers]
        (out_dir / f"{slug}.md").write_text("\n\n---\n\n".join(answers), encoding="utf-8")
        return slug, {"passed": found.count("PASS") * 2 > len(found), "votes": found}

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        return dict(pool.map(one, items))


def judge_target(target, ask, cases=ROOT / "evals", votes=1, jobs=4):
    """Judge every run under target; write target/judge.json; return the summary.

    Summary shape: {variant: {case: {"<arm>/<n>": {slug: verdict}}}}."""
    summary = {}
    for run in runs_under(target):
        variant, case, arm, n = run.parts[-5], run.parts[-3], run.parts[-2], run.parts[-1]
        verdicts = judge_run(run, ask, cases, votes, jobs)
        summary.setdefault(variant, {}).setdefault(case, {})[f"{arm}/{n}"] = verdicts
    if target.is_dir():
        (target / "judge.json").write_text(json.dumps(summary, indent=1), encoding="utf-8")
    return summary


def report(summary, models=None):
    """One table per variant and case: an item per row, a run per column. models, shaped like
    summary with a model name per run, adds a model row."""
    lines = []
    for variant, cases in summary.items():
        for case, runs in cases.items():
            cols = sorted(runs)
            slugs = list(next(iter(runs.values())))
            if not slugs:  # no ground truth for this case
                continue
            width = max(len(s) for s in slugs) + 2
            ran = (models or {}).get(variant, {}).get(case, {})
            colw = max([12, *(len(str(m)) + 2 for m in ran.values())])
            lines.append(f"\n{case} ({variant})")
            lines.append("".ljust(width) + "".join(c.ljust(colw) for c in cols))
            for slug in slugs:
                cells = []
                for c in cols:
                    v = runs[c][slug]
                    mark = "PASS" if v["passed"] else ("FAIL" if all(v["votes"]) else "FAIL?")
                    cells.append(mark.ljust(colw))
                lines.append(slug.ljust(width) + "".join(cells))
            scores = [f"{sum(v['passed'] for v in runs[c].values())}/{len(slugs)}".ljust(colw)
                      for c in cols]
            lines.append("score".ljust(width) + "".join(scores))
            if ran:
                lines.append("model".ljust(width)
                             + "".join(str(ran.get(c)).ljust(colw) for c in cols))
    return "\n".join(lines)


def main(argv):
    ap = argparse.ArgumentParser(description="Judge harvested eval runs against ground truth.")
    ap.add_argument("target", type=Path)
    ap.add_argument("--model", default="claude-sonnet-5")
    ap.add_argument("--votes", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=4)
    args = ap.parse_args(argv[1:])
    summary = judge_target(args.target, claude(args.model), votes=args.votes, jobs=args.jobs)
    models = {}
    for run in runs_under(args.target):
        variant, case, arm, n = run.parts[-5], run.parts[-3], run.parts[-2], run.parts[-1]
        models.setdefault(variant, {}).setdefault(case, {})[f"{arm}/{n}"] = agent_model(run)
    print(report(summary, models))
    print("\n(FAIL? = a judge answer had no VERDICT line; see <run>/judge/<slug>.md)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
