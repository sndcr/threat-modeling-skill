#!/usr/bin/env python3
"""Tests for evals/harness/truth.py and judge.py. The judge's `claude -p` call is replaced by
a fake, so nothing here calls a model.

Run: python3 tests/test_judge.py
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "evals" / "harness"))
import judge  # noqa: E402
import truth  # noqa: E402

TRUTH = """# Ground truth: demo

Change: adds a thing.

## Must find
- leaky-thing: the thing leaks. (min: Medium)
- quiet-thing: the thing is quiet, and the Hardening note is the right place.

## Must not claim
- wrong-claim: saying the thing is on fire is wrong.
"""
MODEL = "docs/threat-modelling/demo/THREAT-MODEL.md"


def case_dir(root):
    case = root / "evals" / "demo"
    (case / "graders").mkdir(parents=True)
    (case / "ground-truth.md").write_text(TRUTH, encoding="utf-8")
    (case / "graders" / "model-written.md").write_text(
        f"---\ntype: file_exists\npath: {MODEL}\n---\n", encoding="utf-8")
    return case


def run_dir(root, arm, model_text="# Threat model\n"):
    run = root / "results" / "stamp" / "full" / "runs" / "demo" / arm / "1"
    if model_text is not None:
        (run / "workspace" / MODEL).parent.mkdir(parents=True)
        (run / "workspace" / MODEL).write_text(model_text, encoding="utf-8")
    else:
        (run / "workspace").mkdir(parents=True)
    return run


class Truth(unittest.TestCase):
    def test_parse_strips_minimum_severity(self):
        items = truth.parse(TRUTH)
        self.assertEqual(items["Must find"][0], ("leaky-thing", "the thing leaks.", "Medium"))
        self.assertEqual(items["Must find"][1][2], None)
        self.assertEqual(items["Must not claim"][0][0], "wrong-claim")

    def test_criterion_names_the_minimum_only_when_set(self):
        self.assertIn("rated Medium or higher", truth.criterion("Must find", "x", "Medium"))
        self.assertNotIn("rated", truth.criterion("Must find", "x", None))
        self.assertIn("WRONG", truth.criterion("Must not claim", "x", None))

    def test_duplicate_slug_is_an_error(self):
        with tempfile.TemporaryDirectory() as d:
            case = case_dir(Path(d))
            (case / "ground-truth.md").write_text(TRUTH + "- leaky-thing: again.\n")
            with self.assertRaises(ValueError):
                truth.items(case)


class Verdict(unittest.TestCase):
    def test_formats(self):
        self.assertEqual(judge.verdict("VERDICT: PASS\nEVIDENCE: …"), "PASS")
        self.assertEqual(judge.verdict("**VERDICT:** FAIL\n"), "FAIL")
        self.assertEqual(judge.verdict("Some preamble.\nverdict: pass\n"), "PASS")
        self.assertIsNone(judge.verdict("I think it passes."))


class JudgeRun(unittest.TestCase):
    def fake(self, prompt):
        # PASS the leaky-thing item, FAIL everything else.
        return "VERDICT: PASS\nREASON: ok" if "the thing leaks." in prompt else "VERDICT: FAIL\n"

    def test_verdicts_and_saved_answers(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            case_dir(root)
            run = run_dir(root, "with")
            out = judge.judge_run(run, self.fake, cases=root / "evals")
            self.assertEqual(list(out), ["leaky-thing", "quiet-thing", "wrong-claim"])
            self.assertTrue(out["leaky-thing"]["passed"])
            self.assertFalse(out["wrong-claim"]["passed"])
            self.assertIn("REASON: ok", (run / "judge" / "leaky-thing.md").read_text())

    def test_prompt_carries_criterion_and_model(self):
        seen = []
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            case_dir(root)
            judge.judge_run(run_dir(root, "with", "UC1:3-S row text"),
                            lambda p: seen.append(p) or "VERDICT: FAIL", cases=root / "evals")
        self.assertTrue(all("UC1:3-S row text" in p for p in seen))
        self.assertTrue(any("the thing leaks." in p and "rated Medium or higher" in p for p in seen))

    def test_majority_of_votes(self):
        answers = iter(["VERDICT: PASS", "VERDICT: FAIL", "VERDICT: PASS"] * 3)
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            case_dir(root)
            out = judge.judge_run(run_dir(root, "with"), lambda p: next(answers),
                                  cases=root / "evals", votes=3, jobs=1)
        self.assertEqual(out["leaky-thing"]["votes"], ["PASS", "FAIL", "PASS"])
        self.assertTrue(out["leaky-thing"]["passed"])

    def test_missing_model_fails_every_item_without_asking(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            case_dir(root)
            out = judge.judge_run(run_dir(root, "without", None), lambda p: self.fail("asked"),
                                  cases=root / "evals")
        self.assertTrue(all(not v["passed"] and v["note"] == "model file missing"
                            for v in out.values()))

    def test_runs_under_finds_both_arms(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            runs = {run_dir(root, "with"), run_dir(root, "without")}
            self.assertEqual(set(judge.runs_under(root / "results" / "stamp")), runs)

    def test_report_skips_cases_without_ground_truth(self):
        summary = {"full": {"pilot": {"with/1": {}}, "demo": {"with/1": {
            "leaky-thing": {"passed": True, "votes": ["PASS"]}}}}}
        out = judge.report(summary)
        self.assertNotIn("pilot", out)
        self.assertIn("1/1", out)

    def test_agent_model_comes_from_the_trace_init_event(self):
        with tempfile.TemporaryDirectory() as d:
            run = run_dir(Path(d), "with")
            self.assertIsNone(judge.agent_model(run))
            (run / "trace.jsonl").write_text(
                '{"type":"system","subtype":"init","model":"claude-opus-5-5"}\n'
                '{"type":"assistant","message":{"model":"claude-sonnet-5"}}\n', encoding="utf-8")
            self.assertEqual(judge.agent_model(run), "claude-opus-5-5")
            with (run / "trace.jsonl").open("a", encoding="utf-8") as f:
                f.write('{"type":"result","result":"You\'ve hit your session limit"}\n')
            self.assertEqual(judge.agent_model(run), "claude-opus-5-5 (LIMIT)")

    def test_report_names_each_run_model(self):
        summary = {"full": {"demo": {"with/1": {
            "leaky-thing": {"passed": True, "votes": ["PASS"]}}}}}
        out = judge.report(summary, {"full": {"demo": {"with/1": "claude-opus-5-5"}}})
        self.assertIn("claude-opus-5-5", out)

    def test_settings_line_reads_meta_json(self):
        with tempfile.TemporaryDirectory() as d:
            stamp = Path(d)
            self.assertEqual(judge.settings_line(stamp), "agent runs: model and effort not recorded")
            (stamp / "meta.json").write_text('{"model": "claude-opus-5-5", "effort": "xhigh"}')
            self.assertEqual(judge.settings_line(stamp),
                             "agent runs: model claude-opus-5-5, effort xhigh")

    def test_main_writes_summary(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            case_dir(root)
            run_dir(root, "with")
            run_dir(root, "without")
            stamp = root / "results" / "stamp"
            judge.judge_target(stamp, self.fake, cases=root / "evals")
            summary = json.loads((stamp / "judge.json").read_text())
            self.assertEqual(summary["full"]["demo"]["with/1"]["leaky-thing"]["passed"], True)


if __name__ == "__main__":
    unittest.main(verbosity=1)
