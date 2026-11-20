#!/usr/bin/env python3
"""Update the Eudes Project workflow field from trusted GitHub event data.

GH_TOKEN must have access to the organization-owned project. Never print the token.
"""
import argparse
import json
import re
import os
import subprocess
import sys

PROJECT = "PVT_kwDOFWrSTM4BsjqX"
FIELDS = {
    "Workflow développement": ["Issue", "Development", "Pull request", "Review", "Corrections", "CI checks"],
    "Validation iPhone": ["À demander", "Compilation signée", "Installation", "Tests sur iPhone", "Validé manuellement", "Non nécessaire", "À refaire", "Échec"],
    "Livraison finale": ["À valider", "Validation manuelle", "Compilation", "Fusionné", "Échec"],
}
DEFAULT_FIELD = "Workflow développement"


def graphql(query, **variables):
    command = ["gh", "api", "graphql", "-f", "query=" + query]
    for key, value in variables.items():
        command += ["-F", f"{key}={value}"]
    output = subprocess.run(command, check=True, text=True, capture_output=True)
    data = json.loads(output.stdout)
    if data.get("errors"):
        raise RuntimeError("GraphQL request failed")
    return data["data"]


def linked_issues(owner, repo, number):
    result = graphql('''query($owner:String!,$repo:String!,$number:Int!) {
      repository(owner:$owner,name:$repo) { pullRequest(number:$number) {
        state headRefOid closingIssuesReferences(first:100) { nodes { id number repository { nameWithOwner } } }
      } }
    }''', owner=owner, repo=repo, number=number)
    pr = result["repository"]["pullRequest"]
    if pr is None:
        raise RuntimeError("Pull request not found")
    return pr


def field_options(name):
    data = graphql('''query($project:ID!) { node(id:$project) { ... on ProjectV2 {
      fields(first:100) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } }
    } } }''', project=PROJECT)
    field = next(f for f in data["node"]["fields"]["nodes"] if f.get("name") == name)
    return field["id"], {o["name"]: o["id"] for o in field["options"]}


def update(issue_id, stage, field=DEFAULT_FIELD):
    field_id, options = field_options(field)
    added = graphql('''mutation($project:ID!,$content:ID!) {
      addProjectV2ItemById(input:{projectId:$project,contentId:$content}) { item { id } }
    }''', project=PROJECT, content=issue_id)
    item = added["addProjectV2ItemById"]["item"]["id"]
    if field == DEFAULT_FIELD and stage in ("Issue", "Development", "Pull request"):
        data = graphql('''query($item:ID!,$name:String!) { node(id:$item) { ... on ProjectV2Item {
          fieldValueByName(name:$name) { ... on ProjectV2ItemFieldSingleSelectValue { name } }
        } } }''', item=item, name=field)
        value = data["node"]["fieldValueByName"]
        current = value["name"] if value else None
        if current and FIELDS[field].index(current) > FIELDS[field].index(stage):
            return
    graphql('''mutation($project:ID!,$item:ID!,$field:ID!,$option:String!) {
      updateProjectV2ItemFieldValue(input:{projectId:$project,itemId:$item,fieldId:$field,value:{singleSelectOptionId:$option}}) { projectV2Item { id } }
    }''', project=PROJECT, item=item, field=field_id, option=options[stage])
    print(f"Project updated: {field} = {stage}")


def event_stage(event_name, event):
    action = event.get("action")
    if event_name == "issues":
        return {"opened": "Issue", "assigned": "Development"}.get(action)
    if event_name == "pull_request_target":
        if action == "closed":
            return "Fusionné" if event["pull_request"].get("merged") else None
        if action == "labeled" and event.get("label", {}).get("name") == "review-validée":
            pr = event["pull_request"]
            if not pr.get("draft") and pr["head"]["repo"]["full_name"] == event["repository"]["full_name"]:
                return "CI checks"
            return None
        return {"opened": "Pull request", "ready_for_review": "Review", "review_requested": "Review", "synchronize": "Review", "converted_to_draft": "Corrections", "reopened": "Pull request"}.get(action)
    if event_name == "pull_request_review" and action == "submitted":
        state = event["review"]["state"].lower()
        if state == "changes_requested":
            return "Corrections"
    return None


def run_transition(run):
    """A failed final validation is reported; a skipped dispatch never claims a validation."""
    title = run.get("display_title", "")
    match = re.fullmatch(r"Validation finale PR #([1-9][0-9]*) · ([0-9a-f]{40})", title)
    if (run.get("event") == "workflow_dispatch" and run.get("head_branch") == "main" and match
            and run.get("path") == ".github/workflows/final-validation.yml"
            and run.get("conclusion") in ("failure", "timed_out", "cancelled")):
        return int(match[1]), match[2], "Échec", "Livraison finale"
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", nargs="?")
    parser.add_argument("--field", default=DEFAULT_FIELD, choices=FIELDS)
    args = parser.parse_args()
    if not os.environ.get("GH_TOKEN"):
        raise RuntimeError("PROJECT_AUTOMATION_TOKEN is not configured")
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as stream:
        event = json.load(stream)
    event_name = os.environ["GITHUB_EVENT_NAME"]
    repository = event["repository"]["full_name"]
    if repository != "Eudes-app/Eudes":
        raise RuntimeError("Unexpected repository")
    stage, field = args.stage or event_stage(event_name, event), args.field
    pr = event.get("pull_request")
    number, sha = (pr["number"], pr["head"]["sha"]) if pr else (None, None)
    if event_name == "workflow_dispatch":
        number, sha = int(os.environ["PR_NUMBER"]), os.environ["REVIEWED_SHA"]
    if event_name == "workflow_run":
        run = event["workflow_run"]
        transition = run_transition(run)
        if transition:
            from delivery_control import pages
            path = run["path"].split("/")[-1]
            newer = pages(f"actions/workflows/{path}/runs?event=workflow_dispatch", "workflow_runs")
            if any(r["id"] > run["id"] and r.get("display_title") == run.get("display_title") for r in newer):
                return
            number, sha, stage, field = transition
        elif run.get("path") == ".github/workflows/ios.yml" and run.get("event") == "pull_request" and run["pull_requests"]:
            from delivery_control import pages
            jobs = pages(f"actions/runs/{run['id']}/jobs", "jobs")
            tests = [j for j in jobs if j["name"] == "XCTest · iPhone simulator" and j.get("conclusion") != "skipped"]
            if tests and run["conclusion"] in ("success", "failure", "timed_out"):
                number, sha = run["pull_requests"][0]["number"], run["head_sha"]
                # Do not let a delayed older CI result override a newer test execution.
                from delivery_control import pages as all_pages
                newer = all_pages(f"actions/workflows/ios.yml/runs?head_sha={sha}&event=pull_request", "workflow_runs")
                for newer_run in newer:
                    if newer_run["id"] > run["id"] and any(p["number"] == number for p in newer_run["pull_requests"]):
                        newer_jobs = all_pages(f"actions/runs/{newer_run['id']}/jobs", "jobs")
                        if not newer_jobs or any(j["name"] == "XCTest · iPhone simulator" and j.get("conclusion") != "skipped" for j in newer_jobs):
                            return
                stage = "CI checks" if run["conclusion"] == "success" else "Corrections"
    if stage is None:
        print("No project transition for this event")
        return
    if stage == "Fusionné":
        field = "Livraison finale"
    if stage not in FIELDS[field]:
        raise RuntimeError("Unknown project stage")
    if event_name == "issues":
        issue_ids = [event["issue"]["node_id"]]
    else:
        if number is None:
            raise RuntimeError("Expected PR number")
        owner, repo = repository.split("/", 1)
        current = linked_issues(owner, repo, number)
        if stage == "Fusionné":
            if current["state"] != "MERGED" or current["headRefOid"] != sha:
                return
        elif current["state"] != "OPEN" or current["headRefOid"] != sha:
            print("Ignoring outdated or closed PR")
            return
        issue_ids = [issue["id"] for issue in current["closingIssuesReferences"]["nodes"]
                     if issue["repository"]["nameWithOwner"] == repository]
    for issue_id in issue_ids:
        update(issue_id, stage, field)
        if (event_name == "pull_request_target" and event.get("action") in ("synchronize", "converted_to_draft")) or (event_name == "pull_request_review" and stage == "Corrections"):
            update(issue_id, "À refaire", "Validation iPhone")
            update(issue_id, "À valider", "Livraison finale")
        if event_name == "workflow_run" and (stage == "Échec" or stage == "Corrections"):
            update(issue_id, "Corrections", DEFAULT_FIELD)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, RuntimeError, subprocess.CalledProcessError, ValueError, StopIteration) as error:
        print(f"Project update failed: {error}", file=sys.stderr)
        sys.exit(1)
