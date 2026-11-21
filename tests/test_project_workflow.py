import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("project_workflow", pathlib.Path(__file__).parents[1] / "tools/update-project-workflow.py")
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)


class ProjectWorkflowTests(unittest.TestCase):
    def run_project_event(self, event, event_name, arguments, values, current_sha="a" * 40):
        current = {"state": "OPEN", "headRefOid": current_sha,
                   "closingIssuesReferences": {"nodes": [
                       {"id": "issue-12", "repository": {"nameWithOwner": "Eudes-app/Eudes"}}
                   ]}}
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "event.json"
            path.write_text(json.dumps({"repository": {"full_name": "Eudes-app/Eudes"}, **event}))
            env = {"GH_TOKEN": "test-token", "GITHUB_EVENT_PATH": str(path),
                   "GITHUB_EVENT_NAME": event_name, "PR_NUMBER": "12", "REVIEWED_SHA": "a" * 40}

            def update(issue_id, stage, field=workflow.DEFAULT_FIELD):
                self.assertEqual(issue_id, "issue-12")
                values[field] = stage

            with patch.dict(os.environ, env, clear=True), patch("sys.argv", arguments), \
                    patch.object(workflow, "linked_issues", return_value=current), \
                    patch.object(workflow, "update", side_effect=update):
                workflow.main()

    def test_final_workflow_replaces_stale_iphone_status_for_both_decisions(self):
        # Execute the actual workflow shell block, then feed its calls to the real
        # project entrypoint. Only GitHub reads/writes are mocked.
        source = (pathlib.Path(__file__).parents[1] / ".github/workflows/final-validation.yml").read_text()
        step = source.split("      - name: Record manual validation\n", 1)[1].split("      - name:", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        capture = "python3() { printf '%s\\0' \"$@\"; printf '\\n'; }\n"
        for decision, expected in [("Non nécessaire", "Non nécessaire"),
                                   ("Tests iPhone validés", "Validé manuellement")]:
            with self.subTest(decision=decision):
                values = {"Validation iPhone": "À refaire", "Livraison finale": "À valider"}
                result = subprocess.run(["bash", "-e", "-c", capture + script], check=True,
                                        text=True, capture_output=True,
                                        env={"PATH": os.defpath, "IPHONE_DECISION": decision})
                for command in result.stdout.splitlines():
                    self.run_project_event({}, "workflow_dispatch", command.rstrip("\0").split("\0"), values)
                self.assertEqual(values, {"Validation iPhone": expected, "Livraison finale": "Validation manuelle"})

    def test_new_commit_or_changes_requested_invalidates_non_required_decision(self):
        pr = {"number": 12, "head": {"sha": "a" * 40}}
        for event_name, event, expected in [
            ("pull_request_target", {"action": "synchronize"}, "Review"),
            ("pull_request_review", {"action": "submitted", "review": {"state": "changes_requested"}}, "Corrections"),
        ]:
            with self.subTest(event=event_name):
                values = {"Validation iPhone": "Non nécessaire", "Livraison finale": "Validation manuelle"}
                self.run_project_event({"pull_request": pr, **event}, event_name, ["script"], values)
                self.assertEqual(values, {"Validation iPhone": "À refaire", "Livraison finale": "À valider",
                                          "Workflow développement": expected})

    def test_stale_non_required_decision_does_not_update_project(self):
        values = {"Validation iPhone": "À refaire"}
        self.run_project_event({}, "workflow_dispatch", ["script", "Non nécessaire", "--field", "Validation iPhone"],
                               values, current_sha="b" * 40)
        self.assertEqual(values, {"Validation iPhone": "À refaire"})

    def test_failed_dispatch_never_claims_manual_validation(self):
        run = {"display_title": "Validation finale PR #12 · " + "a" * 40,
               "path": ".github/workflows/final-validation.yml", "event": "workflow_dispatch",
               "head_branch": "main", "conclusion": "failure"}
        self.assertEqual(workflow.run_transition(run), (12, "a" * 40, "Échec", "Livraison finale"))
        for conclusion in ("success", "skipped"):
            run["conclusion"] = conclusion
            self.assertIsNone(workflow.run_transition(run))
        run.update(conclusion="failure", head_branch="other")
        self.assertIsNone(workflow.run_transition(run))

    def test_issue_events(self):
        self.assertEqual(workflow.event_stage("issues", {"action": "opened"}), "Issue")
        self.assertEqual(workflow.event_stage("issues", {"action": "assigned"}), "Development")

    def test_pr_events(self):
        for action, stage in {"opened": "Pull request", "ready_for_review": "Review", "synchronize": "Review", "review_requested": "Review"}.items():
            self.assertEqual(workflow.event_stage("pull_request_target", {"action": action}), stage)
        self.assertEqual(workflow.event_stage("pull_request_target", {"action": "closed", "pull_request": {"merged": True}}), "Fusionné")
        self.assertIsNone(workflow.event_stage("pull_request_target", {"action": "closed", "pull_request": {"merged": False}}))

    def test_review_label_requires_ready_pr_from_same_repository(self):
        event = {"action": "labeled", "label": {"name": "review-validée"}, "repository": {"full_name": "Eudes-app/Eudes"}, "pull_request": {"draft": False, "head": {"repo": {"full_name": "Eudes-app/Eudes"}}}}
        self.assertEqual(workflow.event_stage("pull_request_target", event), "CI checks")
        event["pull_request"]["draft"] = True
        self.assertIsNone(workflow.event_stage("pull_request_target", event))
        event["pull_request"]["draft"] = False
        event["pull_request"]["head"]["repo"]["full_name"] = "someone/fork"
        self.assertIsNone(workflow.event_stage("pull_request_target", event))
        event["label"]["name"] = "unrelated"
        self.assertIsNone(workflow.event_stage("pull_request_target", event))

    def test_changes_requested_and_approval(self):
        self.assertEqual(workflow.event_stage("pull_request_review", {"action": "submitted", "review": {"state": "changes_requested"}}), "Corrections")
        self.assertIsNone(workflow.event_stage("pull_request_review", {"action": "submitted", "review": {"state": "approved"}}))

    def test_graphql_failure_reports_the_gh_diagnostic(self):
        failure = subprocess.CompletedProcess(args=[], returncode=1, stdout="",
                                             stderr="gh: Resource not accessible by personal access token\n")
        with patch.object(workflow.subprocess, "run", return_value=failure):
            with self.assertRaises(RuntimeError) as raised:
                workflow.graphql("query { viewer { login } }")
        self.assertIn("Resource not accessible by personal access token", str(raised.exception))

    def test_graphql_errors_are_reported_with_their_message(self):
        answer = subprocess.CompletedProcess(args=[], returncode=0, stderr="",
                                             stdout=json.dumps({"errors": [{"message": "Could not resolve to a node with the global id"}]}))
        with patch.object(workflow.subprocess, "run", return_value=answer):
            with self.assertRaises(RuntimeError) as raised:
                workflow.graphql("query { viewer { login } }")
        self.assertIn("Could not resolve to a node", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
