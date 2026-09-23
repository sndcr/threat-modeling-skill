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

    def test_done_citing_missing_file(self):
        bad = GOOD.replace("| Critical | `[OPEN]` | Scope the query",
                           "| Critical | `[DONE]` | Scope the query").replace(
            "add: request another user's", "exists: tests/test_notes.py:12 request another user's")
        with tempfile.TemporaryDirectory() as ws:
            self.assertIn("cites missing file", " ".join(run(check.check_status, bad, Path(ws))))

    def test_manual_review_is_not_a_verification(self):
        bad = GOOD.replace("add: request another user's", "review: request another user's") \
                  .replace("; add: sweep", "; sweep")
        self.assertIn("no `exists:` or `add:`", " ".join(run(check.check_status, bad)))

    def test_cross_reference_rows_are_skipped(self):
        xref = "| UC1:5-E | — | see UC1 | — | — | — | — | — |"
        self.assertEqual(check.is_cross_reference([c.strip() for c in xref.strip("|").split("|")]),
                         True)

    def test_bad_status_token(self):
        bad = GOOD.replace("| Critical | `[OPEN]` | Scope the query",
                           "| Critical | `[FIXED]` | Scope the query")
        self.assertIn("bad status", " ".join(run(check.check_status, bad)))

    def test_unclassed_node(self):
        bad = GOOD.replace("    class Client,Auth,DB neighbor", "    class Client,DB neighbor")
        self.assertIn("node Auth has no scope class", " ".join(run(check.check_dfds, bad)))

    def test_missing_section(self):
        bad = GOOD.replace("## Findings Summary\n", "## Summary\n")
        self.assertIn("missing section ## Findings Summary", run(check.check_sections, bad))


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
