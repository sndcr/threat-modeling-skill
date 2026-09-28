"""A case's ground truth, as judge criteria. Stdlib only.

Each `- slug: description` line under `## Must find`, `## Must close`, `## Out-of-change leads`, or
`## Must not claim` in evals/<case>/ground-truth.md is one item; a trailing
`(min: Low|Medium|High|Critical)` on a must-find sets its minimum severity. judge.py judges
each item against the case's model (the path in graders/model-written.md).
"""
import re

CRITERIA = {
    "Must find": (
        "PASS if the threat model reports this weakness as open (`[OPEN]` or `[PLAN: …]`), or as "
        "`[ACCEPTED: …]` citing a documented acceptance that covers it, in a findings row or, "
        "where the description allows it, the Hardening note{severity}:\n\n"
        "{desc}\n\nFAIL if it is missing{below}."
    ),
    "Must close": (
        "Review mode. PASS if the threat model now marks this weakness closed (`[DONE]`) and its "
        "Verification cites the check named here:\n\n{desc}\n\nFAIL if the row is still open, "
        "or `[DONE]` without citing that check."
    ),
    "Out-of-change leads": (
        "PASS if the threat model mentions this pre-existing weakness as an out-of-change lead "
        "(a variants, leads, or follow-up list), without making it a finding row of this "
        "change:\n\n{desc}\n\nFAIL if it is not mentioned at all, or if it appears as a finding "
        "row scored against this change."
    ),
    "Must not claim": (
        "This describes a claim that would be WRONG for this change, and why:\n\n{desc}\n\n"
        "FAIL if the threat model makes that wrong claim (as a finding, a severity, or a "
        "statement of fact). PASS if it doesn't, including when it correctly says the opposite. "
        "A row that names the threat but records the control that stops it, already built "
        "(`[DONE]`) or already in the plan (`[PLAN: …]`, or a countermeasure citing the plan), "
        "is correct and is not the claim."
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


def criterion(section, desc, sev):
    """The item as the judge reads it."""
    severity = f", rated {sev} or higher" if sev else ""
    below = (", closed (`[DONE]`), accepted without a citation that covers it, or rated "
             "below the minimum severity" if sev else
             ", closed (`[DONE]`), or accepted without a citation that covers it")
    return CRITERIA[section].format(desc=desc, severity=severity, below=below)


def items(case):
    """[(slug, criterion)] from case/ground-truth.md, in file order; [] if it has none."""
    path = case / "ground-truth.md"
    if not path.exists():
        return []
    out, seen = [], set()
    for section, entries in parse(path.read_text(encoding="utf-8")).items():
        for slug, desc, sev in entries:
            if slug in seen:
                raise ValueError(f"{case.name}: duplicate slug {slug}")
            seen.add(slug)
            out.append((slug, criterion(section, desc, sev)))
    return out


def model_path(case):
    """The model file a run should write, from the case's model-written grader."""
    grader = (case / "graders" / "model-written.md").read_text(encoding="utf-8")
    m = re.search(r"^path:\s*(\S+)", grader, re.M)
    if not m:
        raise ValueError(f"{case.name}: graders/model-written.md has no path")
    return m.group(1)
