#!/usr/bin/env python3
"""Fail-closed gates for manually dispatched delivery workflows (trusted main only)."""
import json
import os
import re
import subprocess
import sys

REPO = "Eudes-app/Eudes"

def require(value, message):
    if not value:
        raise ValueError(message)

def api(path, method="GET", data=None):
    command = ["gh", "api", f"repos/{REPO}/{path}", "--method", method]
    if data is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            capture_output=True, text=True, check=True)
    return json.loads(result.stdout) if result.stdout.strip() else None

def pages(path, key=None):
    result = []
    for page in range(1, 101):
        data = api(path + ("&" if "?" in path else "?") + f"per_page=100&page={page}")
        values = data[key] if key else data
        result.extend(values)
        if len(values) < 100:
            return result
    raise ValueError("Pagination limit reached; refusing incomplete evidence")

def validate_pr(pr, sha):
    require(re.fullmatch(r"[0-9a-f]{40}", sha), "Enter the full 40-character commit SHA")
    require(pr["state"] == "open" and not pr["draft"], "PR must be open and ready")
    require(pr["head"]["repo"]["full_name"] == REPO and pr["base"]["ref"] == "main", "Only same-repository PRs into main are eligible")
    require(pr["head"]["sha"] == sha, "Commit changed: manual validation must be repeated")
    require("review-validée" in {x["name"] for x in pr["labels"]}, "Review is not validated")

def check_ci(number, sha, validated_at=None):
    # Ignore no-op runs caused by unrelated labels; never accept an older successful test attempt.
    runs = pages(f"actions/workflows/ios.yml/runs?head_sha={sha}&event=pull_request", "workflow_runs")
    for run in sorted(runs, key=lambda x: x["id"], reverse=True):
        if validated_at and run["created_at"] < validated_at:
            continue
        if not any(p["number"] == number for p in run["pull_requests"]):
            continue
        jobs = pages(f"actions/runs/{run['id']}/jobs", "jobs")
        tests = [j for j in jobs if j["name"] == "XCTest · iPhone simulator" and j.get("conclusion") != "skipped"]
        if not jobs and run["status"] != "completed":
            raise ValueError("New CI execution is still queued")
        if tests:
            require(run["status"] == "completed" and run["conclusion"] == "success"
                    and all(j["conclusion"] == "success" for j in tests), "Latest CI has not succeeded")
            return run["id"]
    raise ValueError("No successful CI for this PR and exact commit")

def check_iphone(pr, sha, decision):
    """No USB device in CI: the proof of a real-device test is a human approval on this exact commit."""
    labels = {x["name"] for x in pr["labels"]}
    if decision == "Non nécessaire":
        require("iphone-requis" not in labels, "An iPhone test was requested; test the build then approve the pull request")
        return
    require(decision == "Tests iPhone validés", "Choose whether an iPhone test was required")
    approvals = [r for r in pages(f"pulls/{pr['number']}/reviews")
                 if r["state"] == "APPROVED" and r.get("commit_id") == sha]
    require(approvals, "Install the build on a device, test it, then approve the pull request at this commit")
    for review in approvals:
        user = api(f"collaborators/{review['user']['login']}/permission")
        if user["user"]["type"] == "User" and user["permission"] in ("admin", "maintain", "write"):
            return
    raise ValueError("The device test must be approved by a human with write access")

def guard(mode):
    require(os.environ["GITHUB_REPOSITORY"] == REPO and os.environ["GITHUB_REF"] == "refs/heads/main", "Run this workflow from main")
    actor = os.environ["GITHUB_ACTOR"]
    require(os.environ.get("GITHUB_TRIGGERING_ACTOR", actor) == actor, "A different actor cannot reuse this manual approval")
    user = api(f"collaborators/{actor}/permission")
    require(user["user"]["type"] == "User" and user["permission"] in ("admin", "maintain", "write"), "A human with write access must validate")
    number = os.environ["PR_NUMBER"]
    require(re.fullmatch(r"[1-9][0-9]*", number), "Invalid PR number")
    sha = os.environ["REVIEWED_SHA"]
    pr = api(f"pulls/{number}")
    validate_pr(pr, sha)
    # No active changes-requested review on the current head.
    latest = {}
    for review in pages(f"pulls/{number}/reviews"):
        if review["state"] in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            latest[review["user"]["login"]] = review
    require(not any(v["state"] == "CHANGES_REQUESTED" for v in latest.values()), "Resolve changes-requested reviews first")
    if mode == "corrections":
        return pr
    validation_events = [e for e in pages(f"issues/{number}/events")
                         if e.get("event") == "labeled" and e.get("label", {}).get("name") == "review-validée"]
    require(validation_events, "Review validation event is missing")
    validated_at = max(e["created_at"] for e in validation_events)
    ci = check_ci(int(number), sha, validated_at)
    if mode == "final":
        require(os.environ.get("CONFIRM_FINAL") == "true", "Manual final approval is required")
        check_iphone(pr, sha, os.environ["IPHONE_DECISION"])
        # A tested branch must include current main; new base changes require rebase/merge + review + CI.
        comparison = api(f"compare/{pr['base']['sha']}...{sha}")
        require(comparison["status"] in ("ahead", "identical"), "Update the PR with current main and repeat review/CI")
        expected_base = os.environ.get("APPROVED_BASE")
        require(not expected_base or expected_base == pr["base"]["sha"], "main changed during compilation; validate again")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"sha={sha}\nbase={pr['base']['sha']}\nci_run={ci}\n")
    return pr

def main():
    command = sys.argv[1]
    pr = guard("final" if command in ("final", "merge") else "corrections" if command == "corrections" else "iphone")
    if command == "merge":
        result = api(f"pulls/{pr['number']}/merge", "PUT", {"sha": os.environ["REVIEWED_SHA"], "merge_method": "merge"})
        require(result.get("merged"), "GitHub refused the merge")
        print("Merge confirmed:", result["sha"])
    elif command == "corrections":
        from urllib.parse import quote
        api(f"issues/{pr['number']}/labels/{quote('review-validée')}", "DELETE")
    elif command == "iphone":
        api(f"issues/{pr['number']}/labels", "POST", {"labels": ["iphone-requis"]})
    print("Current commit and prerequisites verified")

if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Delivery blocked: {error}", file=sys.stderr)
        sys.exit(1)
