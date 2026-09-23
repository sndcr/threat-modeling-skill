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


def assemble(variant):
    plugin = WORK / variant
    shutil.rmtree(plugin, ignore_errors=True)
    for part in PLUGIN_PARTS:
        shutil.copytree(SRC / part, plugin / part)
    for case in (SRC / "evals").iterdir():
        if case.is_dir() and case.name not in CASE_SKIP:
            shutil.copytree(case, plugin / "evals" / case.name)
    return plugin


def harvest(result_json, dest):
    """Copy each run's workspace docs/ and trace out of its kept temp dir."""
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
                docs = kept / "sealed" / "home" / "cwd" / "docs"
                if docs.exists():
                    shutil.copytree(docs, target / "docs")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="full")
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

    plugin = assemble(args.variant)
    dest = OUT / args.stamp / args.variant
    dest.mkdir(parents=True, exist_ok=True)
    result = dest / "aggregate-result.json"
    cmd = ["claude", "plugin", "eval", str(plugin), "--scaffold", "--keep-temp",
           "--trust-plugin", "--no-publish", "--allow-tools", "Bash", "Write", "Edit",
           "--json", str(result), "--report", str(dest / "report.html"), *extra]
    with open(dest / "eval.log", "w") as log:
        code = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT).returncode
    if result.exists():
        harvest(result, dest)
    print(f"{args.variant}: exit {code}, results in {dest}")
    return code


if __name__ == "__main__":
    sys.exit(main())
