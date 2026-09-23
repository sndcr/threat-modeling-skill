#!/usr/bin/env python3
"""Generate a case's LLM graders from its ground-truth.md.

    python3 evals/harness/graders.py evals/<case>

Each `- slug: description` line under `## Must find`, `## Out-of-change leads`, or
`## Must not claim` becomes graders/gt-<slug>.md, judged against the case's THREAT-MODEL.md
(the path in the case's model-written grader). Earlier gt-*.md files are replaced, so
ground-truth.md stays the only file to edit.
"""
import re
import sys
from pathlib import Path

CRITERIA = {
    "Must find": (
        "PASS if the threat model reports this weakness as open (not closed or `[DONE]`), in a "
        "findings row or, where the description allows it, the Hardening note{severity}:\n\n"
        "{desc}\n\nFAIL if it is missing, reported only as already mitigated, or rated below "
        "the minimum severity."
    ),
    "Out-of-change leads": (
        "PASS if the threat model mentions this pre-existing weakness as an out-of-change lead "
        "(a variants, leads, or follow-up list), without making it a finding row of this "
        "change:\n\n{desc}\n\nFAIL if it is not mentioned at all, or if it appears as a finding "
        "row scored against this change."
    ),
    "Must not claim": (
        "This describes a claim that would be WRONG for this code, and why:\n\n{desc}\n\n"
        "FAIL if the threat model makes that wrong claim (as a finding, a severity, or a "
        "statement of fact). PASS if it doesn't, including when it correctly says the opposite."
    ),
}


def parse(text):
    """{section: [(slug, description, min severity or None)]}"""
    out, section = {}, None
    for line in text.splitlines():
        heading = re.match(r"^## (.+?)\s*$", line)
        if heading:
            section = heading.group(1) if heading.group(1) in CRITERIA else None
            continue
        item = re.match(r"^- ([a-z0-9-]+): (.+)$", line)
        if section and item:
            desc = item.group(2)
            sev = re.search(r"\(min: (Low|Medium|High|Critical)\)\s*$", desc)
            if sev:
                desc = desc[:sev.start()].rstrip()
            out.setdefault(section, []).append((item.group(1), desc, sev and sev.group(1)))
    return out


def model_path(case):
    grader = (case / "graders" / "model-written.md").read_text(encoding="utf-8")
    return re.search(r"^path:\s*(\S+)", grader, re.M).group(1)


def main(argv):
    case = Path(argv[1]) if len(argv) > 1 else sys.exit(__doc__)
    truth = case / "ground-truth.md"
    if not truth.exists():
        print(f"{case.name}: no ground-truth.md, graders left as they are")
        return
    items = parse(truth.read_text(encoding="utf-8"))
    path = model_path(case)
    graders = case / "graders"
    for old in graders.glob("gt-*.md"):
        old.unlink()
    slugs = set()
    for section, entries in items.items():
        for slug, desc, sev in entries:
            if slug in slugs:
                sys.exit(f"duplicate slug {slug}")
            slugs.add(slug)
            severity = f", rated {sev} or higher" if sev else ""
            body = CRITERIA[section].format(desc=desc, severity=severity)
            (graders / f"gt-{slug}.md").write_text(
                f"---\ntype: llm\nfocus: {{ source: file, path: {path} }}\n---\n\n{body}\n",
                encoding="utf-8")
    counts = ", ".join(f"{len(v)} {k.lower()}" for k, v in items.items())
    print(f"{case.name}: wrote {len(slugs)} graders ({counts})")


if __name__ == "__main__":
    main(sys.argv)
