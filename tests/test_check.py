#!/usr/bin/env python3
"""Tests for evals/harness/check.py: each plants one defect in a known-good model.

Run: python3 tests/test_check.py
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "evals" / "harness"))
import check  # noqa: E402

GOOD = (ROOT / "tests" / "fixtures" / "pilot-model.md").read_text(encoding="utf-8")
ROW = "| UC1:5-E | Authenticated external user, commodity (High exp.) |"


def run(check_fn, text, ws=None):
    return check_fn(text, ws)


class GoodModel(unittest.TestCase):
    def test_every_model_check_passes(self):
        for fn in check.MODEL_CHECKS:
            self.assertEqual(run(fn, GOOD), [], fn.__name__)


class PlantedDefects(unittest.TestCase):
    def test_wrong_severity(self):
        bad = GOOD.replace("mass cross-tenant data breach (Critical) | Critical |",
                           "mass cross-tenant data breach (Critical) | Medium |")
        self.assertIn("matrix says Critical", " ".join(run(check.check_severity, bad)))

    def test_specialist_steps_exposure_down(self):
        bad = GOOD.replace(ROW, "| UC1:5-E | Authenticated external user, specialist |")
        # High exposure stepped to Medium; Medium x Critical = High, but the row says Critical.
        self.assertIn("matrix says High", " ".join(run(check.check_severity, bad)))

    def test_id_on_missing_edge(self):
        bad = GOOD.replace(ROW, ROW.replace("UC1:5-E", "UC1:9-E"))
        self.assertIn("UC1:9 is not an edge", " ".join(run(check.check_ids, bad)))

    def test_deduped_ids_are_each_checked(self):
        bad = GOOD.replace(ROW, ROW.replace("UC1:5-E", "UC1:5-E, UC2:1-E"))
        self.assertIn("UC2:1 is not an edge", " ".join(run(check.check_ids, bad)))

    def test_done_without_citation(self):
        bad = GOOD.replace("| Critical | `[OPEN]` | Scope the query",
                           "| Critical | `[DONE]` | Scope the query")
        self.assertIn("without an `exists:", " ".join(run(check.check_status, bad)))

    def test_done_needs_a_named_check_not_a_line(self):
        bad = GOOD.replace("| Critical | `[OPEN]` | Scope the query",
                           "| Critical | `[DONE]` | Scope the query").replace(
            "add: request another user's", "exists: tests/test_notes.py:12 request another user's")
        self.assertIn("without an `exists: file::name`", " ".join(run(check.check_status, bad)))

    def test_done_name_must_be_in_the_cited_file(self):
        done = GOOD.replace("| Critical | `[OPEN]` | Scope the query",
                            "| Critical | `[DONE]` | Scope the query").replace(
            "add: request another user's",
            "exists: tests/test_notes.py::test_other_users_note_404:12 request another user's")
        with tempfile.TemporaryDirectory() as ws:
            (Path(ws) / "tests").mkdir()
            (Path(ws) / "tests" / "test_notes.py").write_text("def test_something_else(): pass\n")
            self.assertIn("doesn't contain test_other_users_note_404",
                          " ".join(run(check.check_status, done, Path(ws))))
            (Path(ws) / "tests" / "test_notes.py").write_text("def test_other_users_note_404(): pass\n")
            self.assertEqual(run(check.check_status, done, Path(ws)), [])

    def test_done_citing_missing_file(self):
        bad = GOOD.replace("| Critical | `[OPEN]` | Scope the query",
                           "| Critical | `[DONE]` | Scope the query").replace(
            "add: request another user's", "exists: tests/test_notes.py::test_x request another user's")
        with tempfile.TemporaryDirectory() as ws:
            self.assertIn("cites missing file", " ".join(run(check.check_status, bad, Path(ws))))

    def test_manual_review_is_not_a_verification(self):
        bad = GOOD.replace("add: request another user's", "review: request another user's") \
                  .replace("; add: sweep", "; sweep")
        self.assertIn("no `exists:` or `add:`", " ".join(run(check.check_status, bad)))

    def test_accepted_row_needs_no_exists_or_add(self):
        ok = GOOD.replace("| Critical | `[OPEN]` | Scope the query",
                          "| Critical | `[ACCEPTED: SPEC.md §12]` | Scope the query").replace(
            "add: request another user's", "n/a (accepted). Detection: request another user's") \
            .replace("; add: sweep", "; sweep")
        self.assertEqual(run(check.check_status, ok), [])

    def test_exposure_read_from_a_bracketed_level(self):
        _matrix, personas = check.load_scoring()
        self.assertEqual(check.exposure_of("Authenticated tenant (High)", personas), "High")
        self.assertEqual(check.exposure_of("Network foothold, specialist (Medium → Low)",
                                           personas), "Low")

    def test_impact_weight_is_the_first_level_in_its_bracket(self):
        self.assertEqual(check.impact_of("all-tenant stall (High; rounded up from Medium)"), "High")
        self.assertEqual(check.impact_of("mass breach (Critical)"), "Critical")

    def test_escaped_pipe_stays_in_its_cell(self):
        row = "| UC1:5-E | a | b `x\\|y` c | d | e | `[OPEN]` | f | add: g |"
        self.assertEqual(len(check.cells(row)), 8)

    def test_cross_reference_rows_are_skipped(self):
        xref = "| UC1:5-E | — | see UC1 | — | — | — | — | — |"
        self.assertEqual(check.is_cross_reference([c.strip() for c in xref.strip("|").split("|")]),
                         True)

    def test_bad_status_token(self):
        bad = GOOD.replace("| Critical | `[OPEN]` | Scope the query",
                           "| Critical | `[FIXED]` | Scope the query")
        self.assertIn("bad status", " ".join(run(check.check_status, bad)))

    def test_status_needs_brackets_and_acceptance_citation(self):
        for token in ("`OPEN`", "`[ACCEPTED]`"):
            bad = GOOD.replace("| Critical | `[OPEN]` | Scope the query",
                               f"| Critical | {token} | Scope the query")
            self.assertIn("bad status", " ".join(run(check.check_status, bad)), token)

    def test_unclassed_node(self):
        bad = GOOD.replace("    class Client,Auth,DB neighbor", "    class Client,DB neighbor")
        self.assertIn("node Auth has no scope class", " ".join(run(check.check_dfds, bad)))

    def test_mmd_comment_lines_are_ignored(self):
        block = check.mermaid_blocks(GOOD)[0]
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "dfd").mkdir()
            (Path(d) / "dfd" / "UC1-x.mmd").write_text("%% UC1: a title comment\n" + block)
            self.assertEqual(check.check_mmd_files(GOOD, Path(d)), [])

    def test_prose_mention_of_a_heading_is_not_the_section(self):
        mention = "See `## Use-Case Analysis` below and the `## Findings Summary` at the end.\n\n"
        text = GOOD.replace("## Use Cases\n", mention + "## Use Cases\n", 1)
        self.assertEqual(check.check_sections(text, None), [])
        self.assertEqual(check.use_cases(text).keys(), check.use_cases(GOOD).keys())

    def test_missing_section(self):
        bad = GOOD.replace("## Findings Summary\n", "## Summary\n")
        self.assertIn("missing section ## Findings Summary", run(check.check_sections, bad))


DESIGN = """## Scope

**Scope record:** spec `docs/specs/feature.md`, plan `docs/plans/feature.md`, `HEAD` @ `abc1234`.

## Use-Case Analysis

### UC1 — Submit a job

| ID | Attacker | Attack | Impact | Severity | Status | Countermeasure | Verification |
|---|---|---|---|---|---|---|---|
| UC1:2-T | Adjacent service (Medium exp.) | forge a message | cross-tenant read (Critical) | High | `[PLAN: Task 3]` | sign messages | add: reject an unsigned message |

## Findings Summary
"""
SPEC = "# Feature\n\n## 7. Security requirements\n\n- Messages are signed. UC1:2-T\n\n## Out of scope\n"
PLAN = "### Task 3: Worker\n\n- [ ] Failing test: reject an unsigned message [UC1:2-T]\n"


class Fold(unittest.TestCase):
    def fold(self, text=DESIGN, spec=SPEC, plan=PLAN):
        with tempfile.TemporaryDirectory() as d:
            ws = Path(d)
            for rel, body in (("docs/specs/feature.md", spec), ("docs/plans/feature.md", plan)):
                (ws / rel).parent.mkdir(parents=True, exist_ok=True)
                (ws / rel).write_text(body, encoding="utf-8")
            return " ".join(check.check_fold(text, ws))

    def test_folded_model_passes(self):
        # Also covers a numbered heading ("## 7. Security requirements").
        self.assertEqual(self.fold(), "")

    def test_fold_never_ran(self):
        out = self.fold(DESIGN.replace("`[PLAN: Task 3]`", "`[OPEN]`"))
        self.assertIn("still [OPEN]", out)
        self.assertIn("the Fold didn't run", out)

    def test_id_missing_from_plan(self):
        self.assertIn("not in docs/plans/feature.md", self.fold(plan="### Task 3: Worker\n"))

    def test_id_outside_security_requirements(self):
        spec = "# Feature\n\n## Security requirements\n\n- Messages are signed.\n\n## Notes\n\nUC1:2-T\n"
        self.assertIn("missing from the security requirements", self.fold(spec=spec))

    def test_no_security_requirements_section(self):
        self.assertIn("no Security requirements section", self.fold(spec="# Feature\n"))

    def test_scope_names_no_docs(self):
        text = DESIGN.replace("spec `docs/specs/feature.md`, plan `docs/plans/feature.md`, ", "")
        self.assertIn("can't find the spec and plan", self.fold(text))

    def test_scope_with_absolute_paths(self):
        text = DESIGN.replace("`docs/specs/", "`/home/eval/cwd/docs/specs/").replace(
            "`docs/plans/", "`/home/eval/cwd/docs/plans/")
        self.assertEqual(self.fold(text), "")

    def test_scope_paths_in_header_above_scope(self):
        # Runs put the spec and plan in a header line before `## Scope`.
        text = DESIGN.replace(
            "## Scope\n\n**Scope record:** spec `docs/specs/feature.md`, plan `docs/plans/feature.md`, ",
            "**Spec:** `docs/specs/feature.md` · **Plan:** `docs/plans/feature.md`\n\n## Scope\n\n"
            "**Scope record:** ")
        self.assertNotIn("docs/specs/feature.md`, plan", text)
        self.assertEqual(self.fold(text), "")

    def test_check_run_folds_design_cases(self):
        with tempfile.TemporaryDirectory() as d:
            run = Path(d) / "runs" / "some-case" / "with" / "1"
            model = run / "workspace" / "docs" / "threat-modelling" / "x" / "THREAT-MODEL.md"
            model.parent.mkdir(parents=True)
            model.write_text(DESIGN, encoding="utf-8")
            saved = check.case_tags
            check.case_tags = lambda case: {"design"} if case == "some-case" else set()
            try:
                self.assertIn("fold", check.check_run(run)["checks"])
            finally:
                check.case_tags = saved

    def test_case_tags(self):
        self.assertEqual(check.case_tags("pilot-idor"), {"pilot"})
        self.assertEqual(check.case_tags("no-such-case"), set())


def trace(*parts):
    lines = [{"type": "assistant", "message": {"content": [p]}} for p in parts]
    return "\n".join(json.dumps(l) for l in lines)


def agent(name, i):
    return {"type": "tool_use", "id": f"a{i}", "name": "Agent",
            "input": {"subagent_type": f"threat-model:threat-model-{name}"}}


class Health(unittest.TestCase):
    def health(self, text, removed=()):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "trace.jsonl"
            p.write_text(text)
            return check.check_health(p, removed)

    def test_all_agents_ran(self):
        self.assertEqual(self.health(trace(*(agent(a, i) for i, a in enumerate(check.AGENTS)))), [])

    def test_missing_agent(self):
        self.assertIn("redteam never ran", self.health(trace(*(agent(a, i) for i, a in
                                                              enumerate(check.AGENTS[:3])))))

    def test_removed_agent_ran(self):
        out = self.health(trace(*(agent(a, i) for i, a in enumerate(check.AGENTS))), ("pruner",))
        self.assertIn("pruner ran but this variant removes it", out)

    def test_question_in_headless_run(self):
        ask = {"type": "tool_use", "id": "q", "name": "AskUserQuestion", "input": {}}
        self.assertIn("asked the user", " ".join(self.health(trace(ask))))

    def test_broken_sandbox(self):
        call = {"type": "tool_use", "id": "b", "name": "Bash", "input": {"command": "true"}}
        err = {"type": "tool_result", "tool_use_id": "b", "is_error": True,
               "content": "bwrap: Can't mount proc on /newroot/proc"}
        self.assertIn("Bash sandbox broken", " ".join(self.health(trace(call, err))))


if __name__ == "__main__":
    unittest.main(verbosity=1)
