import copy
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("delivery_control", Path(__file__).parents[1] / "tools/delivery_control.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
SHA = "a" * 40
PR = {"number": 12, "state": "open", "draft": False,
      "head": {"sha": SHA, "repo": {"full_name": m.REPO}},
      "base": {"ref": "main", "sha": "b" * 40}, "labels": [{"name": "review-validée"}]}

class DeliveryControlTests(unittest.TestCase):
    def test_current_review_is_accepted(self):
        m.validate_pr(PR, SHA)

    def test_changed_fork_draft_closed_unreviewed_or_wrong_base_rejected(self):
        for mutation in [lambda p: p["head"].update(sha="c" * 40),
                         lambda p: p.update(draft=True), lambda p: p.update(state="closed"),
                         lambda p: p.update(labels=[]), lambda p: p["base"].update(ref="other"),
                         lambda p: p["head"]["repo"].update(full_name="other/fork")]:
            p = copy.deepcopy(PR)
            mutation(p)
            with self.assertRaises(ValueError):
                m.validate_pr(p, SHA)

    def test_full_sha_required(self):
        for sha in ["abc", "$(command)", SHA + "\n"]:
            with self.assertRaises(ValueError): m.validate_pr(PR, sha)

    def test_iphone_requirement_cannot_be_bypassed(self):
        p = copy.deepcopy(PR)
        p["labels"].append({"name": "iphone-requis"})
        with self.assertRaises(ValueError): m.check_iphone(p, SHA, "Non nécessaire")
        m.check_iphone(PR, SHA, "Non nécessaire")

    def test_device_test_requires_a_human_approval_on_the_exact_commit(self):
        approval = {"state": "APPROVED", "commit_id": SHA, "user": {"login": "owner"}}
        writing = {"user": {"type": "User"}, "permission": "write"}
        with patch.object(m, "pages", return_value=[approval]), patch.object(m, "api", return_value=writing):
            m.check_iphone(PR, SHA, "Tests iPhone validés")
        rejected = [
            ([{"state": "COMMENTED", "commit_id": SHA, "user": {"login": "owner"}}], writing),
            ([{"state": "APPROVED", "commit_id": "c" * 40, "user": {"login": "owner"}}], writing),
            ([{"state": "DISMISSED", "commit_id": SHA, "user": {"login": "owner"}}], writing),
            ([approval], {"user": {"type": "Bot"}, "permission": "write"}),
            ([approval], {"user": {"type": "User"}, "permission": "read"}),
        ]
        for reviews, permission in rejected:
            with patch.object(m, "pages", return_value=reviews), patch.object(m, "api", return_value=permission), self.assertRaises(ValueError):
                m.check_iphone(PR, SHA, "Tests iPhone validés")

    def ci_pages(self, newer_conclusion, newer_jobs):
        def pages(path, key):
            if "/jobs" in path:
                if "/2/" in path: return newer_jobs
                return [{"name": "XCTest · iPhone simulator", "conclusion": "success"}]
            return [{"id": 2, "pull_requests": [{"number": 12}], "status": "completed", "conclusion": newer_conclusion},
                    {"id": 1, "pull_requests": [{"number": 12}], "status": "completed", "conclusion": "success"}]
        return pages

    def test_new_ci_failure_cannot_fall_back_to_old_success(self):
        with patch.object(m, "pages", side_effect=self.ci_pages("failure", [{"name": "XCTest · iPhone simulator", "conclusion": "failure"}])), self.assertRaises(ValueError):
            m.check_ci(12, SHA)

    def test_noop_label_run_does_not_hide_valid_tests(self):
        with patch.object(m, "pages", side_effect=self.ci_pages("skipped", [{"name": "XCTest · iPhone simulator", "conclusion": "skipped"}])):
            self.assertEqual(m.check_ci(12, SHA), 1)

    def test_ci_before_latest_manual_review_cannot_be_reused(self):
        runs = [{"id": 1, "created_at": "2026-11-14T10:00:00Z", "pull_requests": [{"number": 12}]}]
        with patch.object(m, "pages", return_value=runs), self.assertRaises(ValueError):
            m.check_ci(12, SHA, "2026-11-15T10:00:00Z")

    def test_missing_ci_never_passes(self):
        with patch.object(m, "pages", return_value=[]), self.assertRaises(ValueError): m.check_ci(12, SHA)

    def test_manual_approval_and_base_are_rechecked(self):
        env = {"GITHUB_REPOSITORY": m.REPO, "GITHUB_REF": "refs/heads/main", "GITHUB_ACTOR": "owner",
               "GITHUB_TRIGGERING_ACTOR": "owner", "PR_NUMBER": "12", "REVIEWED_SHA": SHA,
               "CONFIRM_FINAL": "true", "IPHONE_DECISION": "Non nécessaire", "GITHUB_OUTPUT": ""}
        def api(path):
            if path.startswith("collaborators/"): return {"user": {"type": "User"}, "permission": "admin"}
            if path.startswith("pulls/"): return PR
            return {"status": "ahead"}
        with patch.dict(os.environ, env, clear=True), patch.object(m, "api", side_effect=api), patch.object(m, "pages", side_effect=lambda path: [] if path.endswith("/reviews") else [{"event": "labeled", "label": {"name": "review-validée"}, "created_at": "2026-11-15T10:00:00Z"}]), patch.object(m, "check_ci", return_value=123):
            self.assertEqual(m.guard("final"), PR)
            for key, value in [("CONFIRM_FINAL", "false"), ("APPROVED_BASE", "c" * 40), ("GITHUB_REF", "refs/heads/other"), ("GITHUB_TRIGGERING_ACTOR", "other")]:
                with patch.dict(os.environ, {key: value}), self.assertRaises(ValueError): m.guard("final")

    def test_merge_sends_sha_and_refuses_api_nonmerge(self):
        with patch.object(m, "guard", return_value=PR), patch.object(m, "api", return_value={"merged": False}) as api, patch.dict(os.environ, {"REVIEWED_SHA": SHA}), patch("sys.argv", ["script", "merge"]):
            with self.assertRaises(ValueError): m.main()
            self.assertEqual(api.call_args.args[2]["sha"], SHA)

if __name__ == "__main__": unittest.main()
