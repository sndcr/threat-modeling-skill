#!/usr/bin/env python3
"""Structural checks on harvested eval runs. Stdlib only.

    python3 evals/harness/check.py evals/results/<stamp>      # every run under it
    python3 evals/harness/check.py <run dir>                  # one run

A run dir holds trace.jsonl and workspace/ (the run's working directory, minus .git).
Checks read the risk matrix and personas from references/scoring.md, so they follow the
skill. Each check returns a list of problems; empty means it passed.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCORING = ROOT / "skills" / "threat-model" / "references" / "scoring.md"
LEVELS = ["Low", "Medium", "High", "Critical"]
AGENTS = ["skeptic", "pruner", "reconciler", "redteam"]
SECTIONS = ["## Scope", "## Use Cases", "## Use-Case Analysis", "## Findings Summary",
            "## Cross-Cutting Analysis"]
ID_RE = re.compile(r"UC(\d+):(\d+[a-z]?)(?:-([A-Z])[a-z]?)?")
STATUS_RE = re.compile(r"^`?(\[DONE\]|\[OPEN\]|\[ACCEPTED: [^\]]+\]|\[PLAN: [^\]]+\]|\[[A-Z]+-\d+\]\([^)]+\)"
                       r"|\[#\d+\]\([^)]+\))`?$")


# --- scoring.md -------------------------------------------------------------------------

def cells(line):
    """A markdown table row's cells; `\\|` is a pipe inside a cell, not a separator."""
    return [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]


def table_rows(text, header_start):
    """Rows (as cell lists) of the markdown table whose header line starts with header_start."""
    lines = text.splitlines()
    start = next(i for i, l in enumerate(lines) if l.startswith(header_start))
    rows = []
    for line in lines[start + 2:]:
        if not line.startswith("|"):
            break
        rows.append(cells(line))
    return rows


def load_scoring():
    text = SCORING.read_text(encoding="utf-8")
    matrix = {}
    for row in table_rows(text, "| Exposure"):
        exposure = row[0].strip("*")
        matrix[exposure] = dict(zip(LEVELS, row[1:]))
    personas = []
    for row in table_rows(text, "| Persona"):
        name, exposure = row[0], row[1].strip("*")
        # Match on the persona's first two words, e.g. "anonymous internet".
        key = " ".join(re.split(r"[/(]", name)[0].lower().split()[:2])
        personas.append((key, exposure))
    return matrix, personas


# --- THREAT-MODEL.md parsing -------------------------------------------------------------

def heading_at(text, heading):
    """Offset of `heading` as a line of its own (not a mention in prose); -1 if absent."""
    m = re.search(rf"^{re.escape(heading)}[ \t]*$", text, re.M)
    return m.start() if m else -1


def mermaid_blocks(text):
    return re.findall(r"```mermaid\n(.*?)```", text, re.S)


def dfd_edges(block):
    """Edge numbers in a use-case DFD, from its labels (`1: …`, `<- 2: …`, `removed: 3: …`)."""
    edges, removed = set(), set()
    for label in re.findall(r'\|"(.*?)"\|', block):
        for part in label.split("<br/>"):
            m = re.match(r"\s*(?:<-\s*)?(removed:\s*)?(?:<-\s*)?(\d+[a-z]?):", part)
            if m:
                (removed if m.group(1) else edges).add(m.group(2))
    return edges, removed


def dfd_nodes(block):
    nodes = set(re.findall(r"^\s*([A-Za-z_][\w]*)\s*(?:\[\(|\(|\[)", block, re.M))
    classed = set()
    for names in re.findall(r"^\s*class\s+([\w,\s]+?)\s+(?:scope|neighbor)\s*;?$", block, re.M):
        classed |= {n.strip() for n in names.split(",")}
    subgraphs = set(re.findall(r"^\s*subgraph\s+(\w+)", block, re.M))
    return nodes - subgraphs, classed


def is_cross_reference(row):
    """A deduped finding's pointer row in another use case's table (`—`, "see UC1")."""
    return len(row) > 1 and row[1] in ("—", "-", "") and "see UC" in " ".join(row)


def use_cases(text):
    """{uc number: (mermaid block, table rows)} from `## Use-Case Analysis`."""
    start = heading_at(text, "## Use-Case Analysis")
    analysis = text[start:].split("\n", 1)[-1].split("\n## ", 1)[0] if start >= 0 else ""
    out = {}
    for m in re.finditer(r"^### UC(\d+)\b(.*?)(?=^### UC\d+\b|\Z)", analysis, re.S | re.M):
        body = m.group(2)
        blocks = mermaid_blocks(body)
        rows = [cells(l) for l in body.splitlines() if l.startswith("| UC")]
        rows = [r for r in rows if not is_cross_reference(r)]
        out[m.group(1)] = (blocks[0] if blocks else "", rows)
    return out


def exposure_of(attacker, personas):
    m = re.search(r"\((Critical|High|Medium|Low)\s+exp", attacker)
    if m:
        return m.group(1)
    low = attacker.lower()
    for key, exposure in personas:
        if low.startswith(key) or key in low:
            if "specialist" in low:
                return LEVELS[max(0, LEVELS.index(exposure) - 1)]
            return exposure
    # A paraphrased persona with its exposure in brackets: "Authenticated tenant (High)",
    # "(Medium → Low)" after a capability step-down. The last level named wins.
    for group in reversed(re.findall(r"\(([^)]*)\)", attacker)):
        found = re.findall(r"\b(Critical|High|Medium|Low)\b", group)
        if found:
            return found[-1]
    return None


def impact_of(impact):
    """The weight: the first level in the last bracket that names one ("(High; rounded up from
    Medium)" is High), else the last level in the cell."""
    for group in reversed(re.findall(r"\(([^)]*)\)", impact)):
        found = re.findall(r"\b(Critical|High|Medium|Low)\b", group)
        if found:
            return found[0]
    found = re.findall(r"\b(Critical|High|Medium|Low)\b", impact)
    return found[-1] if found else None


# --- checks ------------------------------------------------------------------------------

def check_sections(text, _ws):
    positions = [heading_at(text, s) for s in SECTIONS]
    problems = [f"missing section {s}" for s, p in zip(SECTIONS, positions) if p < 0]
    present = [p for p in positions if p >= 0]
    if present != sorted(present):
        problems.append("sections out of order")
    return problems


def check_dfds(text, _ws):
    problems = []
    for uc, (block, _rows) in use_cases(text).items():
        if not block:
            problems.append(f"UC{uc}: no DFD")
            continue
        nodes, classed = dfd_nodes(block)
        for node in sorted(nodes - classed):
            problems.append(f"UC{uc}: node {node} has no scope class")
        if not dfd_edges(block)[0]:
            problems.append(f"UC{uc}: no numbered edges")
    return problems


def check_ids(text, _ws):
    """Every finding ID names an edge that exists (and isn't removed) in its use case's DFD."""
    ucs = use_cases(text)
    edges = {uc: dfd_edges(block) for uc, (block, _rows) in ucs.items()}
    problems = []
    for uc, (_block, rows) in ucs.items():
        for row in rows:
            for m in ID_RE.finditer(row[0]):
                live, removed = edges.get(m.group(1), (set(), set()))
                ref = f"UC{m.group(1)}:{m.group(2)}"
                if m.group(2) in removed:
                    problems.append(f"{row[0]}: {ref} is a removed edge")
                elif m.group(2) not in live:
                    problems.append(f"{row[0]}: {ref} is not an edge in UC{m.group(1)}'s DFD")
    return problems


def check_severity(text, _ws, scoring=None):
    matrix, personas = scoring or load_scoring()
    problems = []
    for _uc, (_block, rows) in use_cases(text).items():
        for row in rows:
            if len(row) < 8:
                problems.append(f"{row[0]}: {len(row)} cells, expected 8")
                continue
            exposure, impact = exposure_of(row[1], personas), impact_of(row[3])
            if not exposure or not impact:
                problems.append(f"{row[0]}: can't read exposure/impact from "
                                f"{row[1][:40]!r} / {row[3][-40:]!r}")
                continue
            want, got = matrix[exposure][impact], row[4].strip("*` ")
            if got != want:
                problems.append(f"{row[0]}: severity {got}, matrix says {want} "
                                f"({exposure} exposure x {impact} impact)")
    return problems


def check_status(text, ws):
    problems = []
    for _uc, (_block, rows) in use_cases(text).items():
        for row in rows:
            if len(row) < 8:
                continue
            status, verification = row[5], row[7]
            if not STATUS_RE.match(status):
                problems.append(f"{row[0]}: bad status {status!r}")
            # An accepted row's Verification is a detection or `n/a (accepted)` (SKILL.md, Status).
            if not status.strip("` ").startswith("[ACCEPTED:") \
                    and not re.search(r"\b(exists|add):", verification):
                problems.append(f"{row[0]}: Verification has no `exists:` or `add:` check "
                                f"({verification[:40]!r})")
            if "[DONE]" in status:
                # `exists: <file>::<name>[:<line>]`: the name identifies the check, lines move.
                cite = re.search(r"exists:\s*`?([\w./-]+\.\w+)::([\w.\[\]-]+?)(?::\d+)?(?=[`\s;,]|$)",
                                 verification)
                if not cite:
                    problems.append(f"{row[0]}: [DONE] without an `exists: file::name` citation")
                elif ws and not (ws / cite.group(1)).exists():
                    problems.append(f"{row[0]}: [DONE] cites missing file {cite.group(1)}")
                elif ws and cite.group(2).split(".")[-1] not in (ws / cite.group(1)).read_text(
                        encoding="utf-8", errors="replace"):
                    problems.append(f"{row[0]}: [DONE] cites {cite.group(1)}, which doesn't "
                                    f"contain {cite.group(2)}")
    return problems


def diagram(source):
    """Mermaid source compared as a diagram: `%%` comment lines dropped, whitespace collapsed."""
    lines = (l for l in source.splitlines() if not l.strip().startswith("%%"))
    return re.sub(r"\s+", " ", "\n".join(lines)).strip()


def check_mmd_files(text, model_dir):
    """Each dfd/*.mmd is canonical and must match an inline diagram (comments and whitespace
    aside)."""
    inline = {diagram(b) for b in mermaid_blocks(text)}
    problems = []
    files = sorted((model_dir / "dfd").glob("*.mmd")) if model_dir else []
    if model_dir and not files:
        problems.append("no dfd/*.mmd files")
    for f in files:
        if diagram(f.read_text(encoding="utf-8")) not in inline:
            problems.append(f"{f.name} differs from its inline diagram")
    return problems


def case_tags(case):
    """Tags on the `tags: [...]` line of evals/<case>/case.yaml; empty if it has none."""
    path = ROOT / "evals" / case / "case.yaml"
    m = re.search(r"^tags:\s*\[(.*?)\]", path.read_text(encoding="utf-8"), re.M) \
        if path.exists() else None
    return {t.strip() for t in m.group(1).split(",") if t.strip()} if m else set()


def section_after(text, heading_re):
    """Body under the first heading matching heading_re, up to the next heading at its level
    or above; None if there is no such heading."""
    m = re.search(rf"^(#+)[^\n]*{heading_re}[^\n]*\n", text, re.M | re.I)
    if not m:
        return None
    rest = text[m.end():]
    end = re.search(rf"^#{{1,{len(m.group(1))}}} ", rest, re.M)
    return rest[:end.start()] if end else rest


def check_fold(text, ws):
    """Design mode: the Fold ran (no row left `[OPEN]`), and each folded row's IDs are in the
    plan and in the spec's security requirements. Spec and plan are the files named before
    `## Use-Case Analysis` (runs put them in a header line or in `## Scope`)."""
    end = heading_at(text, "## Use-Case Analysis")
    scope = text[:end] if end >= 0 else text
    named = re.findall(r"[\w./-]+\.md", scope)
    # Match by suffix: Scope may give workspace-relative or absolute paths.
    docs = [rel for rel in (f.relative_to(ws).as_posix() for f in sorted(ws.rglob("*.md")))
            if not rel.startswith("docs/threat-modelling/")
            and any(n == rel or n.endswith("/" + rel) for n in named)]
    plan = next((p for p in docs if "plan" in p.lower()), None)
    spec = next((p for p in docs if "spec" in p.lower()), None)
    if not plan or not spec:
        return [f"can't find the spec and plan in ## Scope (found: {', '.join(docs) or 'none'})"]
    rows = [r for _block, rs in use_cases(text).values() for r in rs if len(r) >= 8]
    problems = [f"{r[0]}: still [OPEN] after the Fold" for r in rows if "[OPEN]" in r[5]]
    folded = [r for r in rows if r[5].strip("` ").startswith("[PLAN:")]
    if not folded:
        problems.append("no row has a [PLAN: …] status: the Fold didn't run")
    plan_text = (ws / plan).read_text(encoding="utf-8")
    reqs = section_after((ws / spec).read_text(encoding="utf-8"), "security requirements")
    if reqs is None:
        problems.append(f"{spec} has no Security requirements section")
    for row in folded:
        for m in ID_RE.finditer(row[0]):
            if m.group(0) not in plan_text:
                problems.append(f"{m.group(0)}: folded but not in {plan}")
            if reqs is not None and m.group(0) not in reqs:
                problems.append(f"{m.group(0)}: folded but missing from the security "
                                f"requirements in {spec}")
    return problems


def trace_facts(trace):
    facts = {"agents": [], "tool_errors": [], "asks": 0, "result_error": None}
    names = {}
    for line in trace.read_text(encoding="utf-8").splitlines():
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("type") == "result" and msg.get("is_error"):
            facts["result_error"] = msg.get("result") or msg.get("subtype")
        content = (msg.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for part in content:
            if part.get("type") == "tool_use":
                names[part["id"]] = part["name"]
                if part["name"] == "Agent":
                    facts["agents"].append(str(part["input"].get("subagent_type", "")))
                if part["name"] == "AskUserQuestion":
                    facts["asks"] += 1
            if part.get("type") == "tool_result" and part.get("is_error"):
                body = part.get("content")
                body = body if isinstance(body, str) else json.dumps(body)
                facts["tool_errors"].append(f"{names.get(part.get('tool_use_id'), '?')}: "
                                            f"{body[:120]}")
    return facts


def check_health(trace, removed=()):
    """The run behaved: no questions, the expected agents ran, Bash worked."""
    facts = trace_facts(trace)
    problems = []
    if facts["asks"]:
        problems.append(f"asked the user {facts['asks']} time(s) in a headless run")
    if facts["result_error"]:
        problems.append(f"run ended in error: {facts['result_error']}")
    for agent in AGENTS:
        ran = any(a.endswith(f"threat-model-{agent}") for a in facts["agents"])
        if agent in removed and ran:
            problems.append(f"{agent} ran but this variant removes it")
        if agent not in removed and not ran:
            problems.append(f"{agent} never ran")
    sandbox = [e for e in facts["tool_errors"] if e.startswith("Bash") and "bwrap" in e]
    if sandbox:
        problems.append(f"Bash sandbox broken: {sandbox[0]}")
    return problems


MODEL_CHECKS = [check_sections, check_dfds, check_ids, check_severity, check_status]


def check_run(run_dir, removed=()):
    ws = run_dir / "workspace"
    models = sorted(ws.glob("docs/threat-modelling/*/THREAT-MODEL.md")) if ws.exists() else []
    report = {"run": str(run_dir), "checks": {}}
    trace = run_dir / "trace.jsonl"
    report["checks"]["health"] = check_health(trace, removed) if trace.exists() else ["no trace"]
    if not models:
        report["checks"]["model"] = ["no THREAT-MODEL.md written"]
        return report
    text = models[0].read_text(encoding="utf-8")
    for check in MODEL_CHECKS:
        report["checks"][check.__name__.removeprefix("check_")] = check(text, ws)
    report["checks"]["mmd_files"] = check_mmd_files(text, models[0].parent)
    # runs/<case>/with/<n>: the case name is case.yaml's `name`, which matches its directory.
    if "design" in case_tags(run_dir.parent.parent.name):
        report["checks"]["fold"] = check_fold(text, ws)
    return report


def removed_for(run_dir):
    """The variant is the directory above runs/: `full`, or `no-<agent>`."""
    for part in run_dir.parts:
        if part.startswith("no-"):
            return (part.removeprefix("no-"),)
    return ()


def main(argv):
    target = Path(argv[1]) if len(argv) > 1 else sys.exit(__doc__)
    runs = [target] if (target / "trace.jsonl").exists() else \
        sorted(p.parent for p in target.glob("**/runs/*/with/*/trace.jsonl"))
    reports = [check_run(r, removed_for(r)) for r in runs]
    failed = 0
    for rep in reports:
        bad = {k: v for k, v in rep["checks"].items() if v}
        failed += bool(bad)
        print(f"{'FAIL' if bad else 'OK  '} {rep['run']}")
        for name, problems in bad.items():
            for p in problems:
                print(f"     {name}: {p}")
    (target / "checks.json").write_text(json.dumps(reports, indent=1)) if target.is_dir() else None
    print(f"{len(reports) - failed}/{len(reports)} runs passed every check")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
