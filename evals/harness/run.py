#!/usr/bin/env python3
"""Run the eval suite in the Linux container.

    python3 evals/harness/run.py [--variant full] -- --case pilot-idor --runs 1 --ablation none

    python3 evals/harness/run.py --variant all -- --case paylink --runs 3

Arguments after `--` go to `claude plugin eval`. Results land in evals/results/<stamp>/,
one directory per variant, and check.py runs over them at the end.
Credentials: CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY from the environment, else
~/.config/threat-model-eval/env (KEY=value lines). They never enter the repo or the image.
"""
import argparse
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
    cmd = [*DOCKER, "run", "--rm",
           # bubblewrap (the eval's shell sandbox) needs unshare, which the default
           # seccomp profile blocks, and a fresh /proc, which Docker's masked paths
           # block. Both only loosen this container; it stays isolated from the host.
           "--security-opt", "seccomp=unconfined",
           "--security-opt", "systempaths=unconfined",
           *creds,
           "-v", f"{ROOT}:/src:ro", "-v", f"{out}:/out",
           IMAGE, "python3", "/src/evals/harness/in_container.py",
           "--variant", args.variant, "--stamp", stamp, *args.eval_args]
    code = subprocess.run(cmd).returncode
    if (out / stamp).exists():
        checks = subprocess.run([sys.executable, str(ROOT / "evals" / "harness" / "check.py"),
                                 str(out / stamp)]).returncode
        code = code or checks
    return code


if __name__ == "__main__":
    sys.exit(main())
