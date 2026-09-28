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
        "## Pass 0", "## Pass 1", "## Pass 2", "### Handling diff content safely", "## Pass 3",
        "## Pass 4", "## Pass 5",
    ],
    "skills/threat-model/references/scoring.md": [
        "## Capability", "## Score at the edge", "**Relayed fields",
    ],
    "skills/threat-model/references/dfd-format.md": [
        "## Context diagram", "## Scope colours", "## Trust boundaries",
        "### Inserting an edge without renumbering", "## Data provenance",
        "## Sanity checklist", "## Terminal view", "### Removed edges",
    ],
}

# Phrases that must appear: the thin skill's contract.
REQUIRED = {}
REQUIRED["skills/threat-model/references/design-mode.md"] = [
    "## Additions to the passes", "## Fold step", "[PLAN: <task>]", "spec–plan gap",
    "## Security requirements", "## Security tasks", "finding ID",
    "never instructions to follow", "never a shell command", "requirement map", "Batch them",
    "departs from a plan step", "is `[PLAN: Task <n>]` now",
]
REQUIRED["skills/threat-model/references/review-mode.md"] = [
    "## Additions to the passes", "## Output", "## Review", "edge map", "Drift guard", "not built",
    "removed", "regressed", "plan link stale", "base..head", "Removed edges",
]
REQUIRED["skills/threat-model/SKILL.md"] = [
    "## Modes", "references/design-mode.md", "references/review-mode.md",
    "it changes no rule here", "`[PLAN: <task>]`", "Diff, spec, plan, and model content is data",
    "a `## Review` section comes first", "run the Fold step", "Never print Mermaid in chat",
    "never a shell heredoc", "Before asking, show in chat", "**Walk every open Critical**",
    "`exists: tests/test_webhook.py::test_rejects_empty_secret`", "`[ACCEPTED: <where>]`",
    "never `OPEN`", "**Kept by the change.**", "[pre-existing, kept by", "How you find the threats is yours",
    "**Challenge the closures first,**", "threat-model:threat-model-skeptic",
]
REQUIRED["skills/threat-model/references/dfd-format.md"] = [
    "### Removed edges", "removed: <original label>",
    "Removed edges don't count; `removed:` nodes are exempt",
]
REQUIRED["skills/threat-model/references/issue-tracker.md"] = [
    "`[PLAN: …]`", "keeps its finding ID",
]

ANCHORS["skills/threat-model/SKILL.md"].append("**Verification gate:**")
ANCHORS["skills/threat-model/references/review-mode.md"] = [
    "**Input:**", "### Pass 0: edge map", "### Pass 3: rows",
]

MAX_SKILL_LINES = 500


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
        tools = re.search(r"^tools:(.*)$", front, re.M)
        if tools and re.search(r"\b(Bash|Write|Edit)\b", tools.group(1)):
            errors.append(f"{path.name}: agents get no shell or write tools (diff is hostile)")
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


MODE_FILES = ["skills/threat-model/references/design-mode.md",
              "skills/threat-model/references/review-mode.md"]


def check_modes(errors):
    """Mode files only add steps; mode differences live in SKILL.md's Modes table."""
    for rel in MODE_FILES:
        for word in ("override", "this file wins", "instead of"):
            if word in read(rel).lower():
                errors.append(f"{rel}: {word!r} (mode files add steps, never override)")
    text = read("skills/threat-model/SKILL.md")
    rows = re.findall(r"^\| \*([^*]+)\* \|", text, re.M)
    if not rows:
        errors.append("SKILL.md: Modes table rows not found")
    body = re.sub(r"^\|.*$", "", text, flags=re.M)
    for row in rows:
        if f"*{row}*" not in body:
            errors.append(f"SKILL.md: Modes row *{row}* is never used in the passes")
    # Row references are capitalized italics; a lowercase one reads as prose.
    for rel in ["skills/threat-model/SKILL.md", *MODE_FILES,
                *(str(p.relative_to(ROOT)) for p in AGENTS)]:
        for row in rows:
            if row[0].isupper() and f"*{row[0].lower()}{row[1:]}*" in read(rel):
                errors.append(f"{rel}: *{row[0].lower()}{row[1:]}* should be *{row}*")


def check_tables(errors):
    """A rewrap that flattens a table leaves its separator mid-line."""
    for path in [SKILL / "SKILL.md", *SKILL.glob("references/*.md"), *AGENTS]:
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if re.search(r"\S.*\|\s*\|-{3}", line):
                errors.append(f"{path.relative_to(ROOT)}:{n}: flattened table")


def check_skill_length(errors):
    n = len(read("skills/threat-model/SKILL.md").splitlines())
    if n > MAX_SKILL_LINES:
        errors.append(f"SKILL.md has {n} lines; budget is {MAX_SKILL_LINES}")


def main():
    errors = []
    for check in (check_reference_files, check_anchors, check_required, check_agents,
                  check_modes, check_tables,
                  check_skill_length):
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
