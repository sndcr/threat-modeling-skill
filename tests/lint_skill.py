#!/usr/bin/env python3
"""Structural lint for the threat-model skill.

Checks the cross-file invariants that keep SKILL.md, references/, and agents/ from
drifting apart: cited files and anchors exist, required phrases are present, agents keep
their guards, and the Status vocabulary matches the reconciler's. Stdlib only.

Run: python3 tests/lint_skill.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKILL = ROOT / "skills" / "threat-model"
AGENTS = sorted((ROOT / "agents").glob("threat-model-*.md"))

# Headings and phrases other files cite by name. Update when a heading is renamed.
ANCHORS = {
    "skills/threat-model/SKILL.md": [
        "## Launching the bundled subagents", "## Pass 0", "## Pass 1", "## Pass 2",
        "### Handling diff content safely", "## Pass 3", "### Variant scan",
        "### Assumptions", "## Pass 4", "## Pass 5", "## Pass 6", "**6d —", "## Pass 7",
    ],
    "skills/threat-model/references/scoring.md": [
        "## Capability", "## Score at the edge", "**Relayed fields",
    ],
    "skills/threat-model/references/dfd-format.md": [
        "## Context diagram", "## Scope colours", "## Trust boundaries",
        "### Inserting an edge without renumbering", "## Data provenance",
        "## Sanity checklist",
    ],
}

# Phrases that must appear: the spec's invariants. Later tasks add entries.
# New file: REQUIRED[rel] = [...]; file already listed: REQUIRED[rel] += [...]
REQUIRED = {}

MAX_SKILL_LINES = 400


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def check_reference_files(errors):
    names = set()
    for path in [SKILL / "SKILL.md", *SKILL.glob("references/*.md"), *AGENTS]:
        names.update(re.findall(r"references/([\w.-]+\.md)", path.read_text(encoding="utf-8")))
    for name in sorted(names):
        if not (SKILL / "references" / name).exists():
            errors.append(f"references/{name} is cited but does not exist")


def check_anchors(errors):
    for rel, anchors in ANCHORS.items():
        text = read(rel)
        for anchor in anchors:
            if anchor not in text:
                errors.append(f"{rel}: missing anchor {anchor!r}")


def check_required(errors):
    for rel, phrases in REQUIRED.items():
        path = ROOT / rel
        if not path.exists():
            errors.append(f"{rel}: file missing")
            continue
        text = " ".join(path.read_text(encoding="utf-8").split())  # line wraps don't break phrases
        for phrase in phrases:
            if " ".join(phrase.split()) not in text:
                errors.append(f"{rel}: missing {phrase!r}")


def check_agents(errors):
    for path in AGENTS:
        text = path.read_text(encoding="utf-8")
        m = re.match(r"---\n(.*?)\n---\n", text, re.S)
        if not m:
            errors.append(f"{path.name}: no frontmatter")
            continue
        front = m.group(1)
        if re.search(r"^skills:", front, re.M):
            errors.append(f"{path.name}: remove 'skills:' (preload is skipped for this skill)")
        if "model: inherit" not in front:
            errors.append(f"{path.name}: missing 'model: inherit'")
        if "MISSING SKILL DIRECTORY" not in text:
            errors.append(f"{path.name}: missing the MISSING SKILL DIRECTORY guard")


def status_tokens_skill():
    text = read("skills/threat-model/SKILL.md")
    block = text.split("- **Status** — one token:")[1].split("- **Countermeasure**")[0]
    return set(re.findall(r"^\s+- `\[([^\]]+)\]", block, re.M))


def status_tokens_reconciler():
    text = read("agents/threat-model-reconciler.md")
    m = re.search(r"Tokens:((?:\s*`\[[^\]]+\]`\s*/?)+)", text)
    if not m:
        raise ValueError("reconciler: 'Tokens:' line not found")
    tokens = m.group(1)
    return set(re.findall(r"`\[([^\]]+)\]", tokens))


def check_status_vocabulary(errors):
    skill, rec = status_tokens_skill(), status_tokens_reconciler()
    if skill != rec:
        errors.append(f"Status tokens differ: SKILL.md {sorted(skill)} vs reconciler {sorted(rec)}")


def check_skill_length(errors):
    n = len(read("skills/threat-model/SKILL.md").splitlines())
    if n > MAX_SKILL_LINES:
        errors.append(f"SKILL.md has {n} lines; budget is {MAX_SKILL_LINES}")


def main():
    errors = []
    for check in (check_reference_files, check_anchors, check_required, check_agents,
                  check_status_vocabulary, check_skill_length):
        try:
            check(errors)
        except (AttributeError, IndexError, OSError, ValueError) as e:
            errors.append(f"{check.__name__}: cannot parse ({type(e).__name__}: {e})")
    for error in errors:
        print(f"FAIL {error}")
    print(f"{'FAIL' if errors else 'OK'}: {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
