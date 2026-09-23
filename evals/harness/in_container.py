#!/usr/bin/env python3
"""Runs inside the eval container: assemble a clean plugin, run `claude plugin eval`, and
harvest each run's outputs before the container (and its kept temp dirs) disappears.

/src is the repo, read-only. /out is the results directory, writable.
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

SRC = Path("/src")
OUT = Path("/out")
WORK = Path("/home/eval/work")
# Only what ships. examples/, article/, and internal/ would leak answers to the agent.
PLUGIN_PARTS = [".claude-plugin", "skills", "agents"]
CASE_SKIP = {"results", "docker", "harness"}
# Ablations remove one role entirely: the agent file goes, and SKILL.md says to skip the role
# rather than run it inline. check.py confirms from the trace that it never ran.
ROLES = {
    "skeptic": "Pass 4's hunt for missed rows, `RAISE`s, and `DFD-GAP`s",
    "pruner": "Pass 4's challenge of every row (`DROP`, `DOWNGRADE`, `RESCOPE`, `MERGE`, `FIX`)",
    "reconciler": "Pass 5's reconciliation (re-deriving severities, checking `[DONE]` "
                  "citations, deduping); still assemble `## Findings Summary`",
    "redteam": "Pass 6d's attack-path synthesis; write \"skipped\" under 6d",
}
VARIANTS = ["full", *(f"no-{role}" for role in ROLES)]


def assemble(variant):
    plugin = WORK / variant
    shutil.rmtree(plugin, ignore_errors=True)
    for part in PLUGIN_PARTS:
        shutil.copytree(SRC / part, plugin / part)
    if variant != "full":
        role = variant.removeprefix("no-")
        (plugin / "agents" / f"threat-model-{role}.md").unlink()
        skill = plugin / "skills" / "threat-model" / "SKILL.md"
        text = skill.read_text(encoding="utf-8")
        note = (f"> **Eval variant `{variant}`:** skip {ROLES[role]}. Don't launch "
                f"`threat-model-{role}` and don't do its job inline; everything else is "
                "unchanged.\n\n")
        head, sep, body = text.partition("\n# Threat Model\n\n")
        skill.write_text(head + sep + note + body, encoding="utf-8")
    for case in (SRC / "evals").iterdir():
        if case.is_dir() and case.name not in CASE_SKIP:
            shutil.copytree(case, plugin / "evals" / case.name)
    return plugin


def harvest(result_json, dest):
    """Copy each run's trace and workspace (minus .git) out of its kept temp dir."""
    data = json.loads(result_json.read_text())
    for case in data["cases"]:
        for arm, runs in case["arms"].items():
            for n, run in enumerate(runs, 1):
                target = dest / "runs" / case["name"] / arm / str(n)
                target.mkdir(parents=True, exist_ok=True)
                trace = Path(run["tracePath"]) if run.get("tracePath") else None
                if not trace or not trace.exists():
                    (target / "MISSING").write_text(str(run.get("error")))
                    continue
                kept = trace.parent.parent
                subprocess.run(["chmod", "700", kept, kept / "sealed"], check=False)
                shutil.copy(trace, target / "trace.jsonl")
                cwd = kept / "sealed" / "home" / "cwd"
                if cwd.exists():
                    shutil.copytree(cwd, target / "workspace", symlinks=True,
                                    ignore=shutil.ignore_patterns(".git"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="full",
                    help="a variant, a comma list, or `all`: " + ", ".join(VARIANTS))
    ap.add_argument("--stamp", required=True)
    ap.add_argument("eval_args", nargs=argparse.REMAINDER,
                    help="passed to `claude plugin eval` after --")
    args = ap.parse_args()
    extra = [a for a in args.eval_args if a != "--"]

    # A broken sandbox makes every Bash call fail and the run improvise; fail fast instead.
    probe = ["bwrap", "--unshare-all", "--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev",
             "true"]
    if subprocess.run(probe, capture_output=True).returncode != 0:
        sys.exit("bubblewrap cannot run here; see the docker options in run.py")

    variants = VARIANTS if args.variant == "all" else args.variant.split(",")
    unknown = set(variants) - set(VARIANTS)
    if unknown:
        sys.exit(f"unknown variant(s): {', '.join(sorted(unknown))}")
    worst = 0
    for variant in variants:
        plugin = assemble(variant)
        dest = OUT / args.stamp / variant
        dest.mkdir(parents=True, exist_ok=True)
        result = dest / "aggregate-result.json"
        # Only the full plugin gets the no-plugin baseline; variants compare against full.
        arms = [] if variant == "full" or "--ablation" in extra else ["--ablation", "none"]
        cmd = ["claude", "plugin", "eval", str(plugin), "--scaffold", "--keep-temp",
               "--trust-plugin", "--no-publish", "--allow-tools", "Bash", "Write", "Edit",
               "--json", str(result), "--report", str(dest / "report.html"), *arms, *extra]
        with open(dest / "eval.log", "w") as log:
            code = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
        if result.exists():
            harvest(result, dest)
        print(f"{variant}: exit {code}, results in {dest}", flush=True)
        worst = max(worst, code)
    return worst


if __name__ == "__main__":
    sys.exit(main())
