#!/usr/bin/env python3
"""Run the eval suite in the Linux container.

    python3 evals/harness/run.py [--variant full] -- --case pilot-idor --runs 1 --ablation none

    python3 evals/harness/run.py --variant all -- --case paylink --runs 3

`--model` and `--effort` pin the agent runs (the judge has its own `--judge` model) and are
recorded in evals/results/<stamp>/meta.json; effort reaches the runs as
CLAUDE_CODE_EFFORT_LEVEL, which `plugin eval` passes through. Arguments after `--` go to
`claude plugin eval`.
`--plugin-ref <git ref>` evaluates the plugin (.claude-plugin, skills, agents) at that ref,
e.g. origin/main, with today's harness and cases; the default is the working tree. Results land in evals/results/<stamp>/,
one directory per variant; check.py and then judge.py (`--judge` model) run over them at the
end.
Credentials: CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY from the environment, else
~/.config/threat-model-eval/env (KEY=value lines). They never enter the repo or the image.
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IMAGE = "threat-model-eval"
ENV_FILE = Path.home() / ".config" / "threat-model-eval" / "env"
DOCKER = ["docker", "--context", "orbstack"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", default="full", help="full, no-<role>, a comma list, or all")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--judge", default="claude-sonnet-5", help="model for judge.py")
    ap.add_argument("--model", default="claude-opus-5-5", help="model for the agent runs")
    ap.add_argument("--plugin-ref", help="git ref whose plugin to evaluate (default: working tree)")
    ap.add_argument("--effort", default="medium", help="effort level for the agent runs; `default` leaves it unset")
    ap.add_argument("eval_args", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    # `-e NAME` passes the value from this environment without putting it in argv.
    creds = [a for name in ("CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY")
             if os.environ.get(name) for a in ("-e", name)]
    if not creds:
        if not ENV_FILE.exists():
            sys.exit(f"no credentials: set CLAUDE_CODE_OAUTH_TOKEN or create {ENV_FILE}")
        creds = ["--env-file", str(ENV_FILE)]

    if not args.no_build:
        subprocess.run([*DOCKER, "build", "-q", "-t", IMAGE, str(ROOT / "evals" / "docker")],
                       check=True, stdout=subprocess.DEVNULL)
    out = ROOT / "evals" / "results"
    out.mkdir(exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    (out / stamp).mkdir()
    git = lambda *a: subprocess.run(["git", "-C", str(ROOT), *a], check=True,
                                    capture_output=True, text=True).stdout.strip()
    plugin_mount = []
    if args.plugin_ref:
        src = out / stamp / "plugin-src"
        src.mkdir()
        archive = subprocess.run(["git", "-C", str(ROOT), "archive", args.plugin_ref,
                                  ".claude-plugin", "skills", "agents"],
                                 check=True, capture_output=True).stdout
        subprocess.run(["tar", "-x", "-C", str(src)], input=archive, check=True)
        plugin_mount = ["-v", f"{src}:/plugin-src:ro"]
        commit = git("rev-parse", args.plugin_ref)
    else:
        dirty = git("status", "--porcelain", "--", ".claude-plugin", "skills", "agents")
        commit = git("rev-parse", "HEAD") + (" + uncommitted changes" if dirty else "")
    meta = {"model": args.model, "effort": args.effort, "variant": args.variant,
            "plugin_ref": args.plugin_ref or "working tree", "plugin_commit": commit,
            "eval_args": [a for a in args.eval_args if a != "--"]}
    (out / stamp / "meta.json").write_text(json.dumps(meta, indent=1) + "\n", encoding="utf-8")
    effort = [] if args.effort == "default" else ["-e", f"CLAUDE_CODE_EFFORT_LEVEL={args.effort}"]
    cmd = [*DOCKER, "run", "--rm",
           # bubblewrap (the eval's shell sandbox) needs unshare, which the default
           # seccomp profile blocks, and a fresh /proc, which Docker's masked paths
           # block. Both only loosen this container; it stays isolated from the host.
           "--security-opt", "seccomp=unconfined",
           "--security-opt", "systempaths=unconfined",
           *creds, *effort,
           "-v", f"{ROOT}:/src:ro", "-v", f"{out}:/out", *plugin_mount,
           IMAGE, "python3", "/src/evals/harness/in_container.py",
           "--variant", args.variant, "--stamp", stamp, *args.eval_args, "--model", args.model]
    code = subprocess.run(cmd).returncode
    if any(p.is_dir() for p in (out / stamp).iterdir()):
        checks = subprocess.run([sys.executable, str(ROOT / "evals" / "harness" / "check.py"),
                                 str(out / stamp)]).returncode
        subprocess.run([sys.executable, str(ROOT / "evals" / "harness" / "judge.py"),
                        str(out / stamp), "--model", args.judge])
        code = code or checks
    return code


if __name__ == "__main__":
    sys.exit(main())
