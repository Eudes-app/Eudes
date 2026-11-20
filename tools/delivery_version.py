#!/usr/bin/env python3
"""Reserve delivery numbers in GitHub, independently of the iPhone and CI runs.

The orphan branch eudes-delivery-versions contains an append-only registry.
Updating its file requires the previous blob SHA (optimistic concurrency).
Only a new delivery ID allocates numbers; rebuilding an ID never changes them.
"""

import argparse
import base64
import copy
import datetime
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.request


BRANCH = "eudes-delivery-versions"
REGISTRY_PATH = "deliveries.json"
BASELINE_PATH = Path(__file__).resolve().parents[1] / "ios/Version.xcconfig"
ID_PATTERN = r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}"
SHA_PATTERN = r"[0-9a-f]{40}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version_parts(version):
    require(isinstance(version, str) and re.fullmatch(r"[1-9][0-9]*\.(0|[1-9][0-9]*)", version),
            "Version must use the Eudes major.minor format, e.g. 1.112")
    return tuple(map(int, version.split(".")))


def validate_numbers(numbers):
    version_parts(numbers["version"])
    require(type(numbers["build"]) is int and 1 <= numbers["build"] <= 9999,
            "Build must be an integer between 1 and 9999")


def next_numbers(numbers):
    major, minor = version_parts(numbers["version"])
    result = {"version": f"{major}.{minor + 1}", "build": numbers["build"] + 1}
    validate_numbers(result)
    return result


def read_baseline(path=BASELINE_PATH):
    settings = {}
    for line in Path(path).read_text().splitlines():
        match = re.fullmatch(r"(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*([0-9.]+)\s*", line)
        if match:
            require(match[1] not in settings, "Duplicate baseline setting")
            settings[match[1]] = match[2]
    result = {"version": settings["MARKETING_VERSION"], "build": int(settings["CURRENT_PROJECT_VERSION"])}
    validate_numbers(result)
    return result


def initial_registry(baseline):
    validate_numbers(baseline)
    return {"schema": 1, "baseline": copy.deepcopy(baseline), "deliveries": []}


def validate_registry(registry):
    require(type(registry) is dict and registry.get("schema") == 1, "Unsupported registry schema")
    validate_numbers(registry["baseline"])
    require(type(registry["deliveries"]) is list, "Invalid deliveries list")
    previous = registry["baseline"]
    ids = set()
    for entry in registry["deliveries"]:
        require(re.fullmatch(ID_PATTERN, entry["id"]) and entry["id"] not in ids,
                "Invalid or duplicate delivery ID in registry")
        require(re.fullmatch(SHA_PATTERN, entry["first_commit"]), "Invalid source commit in registry")
        expected = next_numbers(previous)
        require(entry["version"] == expected["version"] and type(entry["build"]) is int
                and entry["build"] == expected["build"], "Registry sequence is inconsistent")
        ids.add(entry["id"])
        previous = entry


class APIError(RuntimeError):
    def __init__(self, status):
        self.status = status
        super().__init__(f"GitHub API returned HTTP {status}")


class GitHubRegistry:
    def __init__(self, repository, token):
        require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository), "Invalid repository")
        require(bool(token), "GH_TOKEN with repository contents:write is required")
        self.repository = repository
        self.token = token

    def request(self, method, path, data=None):
        request = urllib.request.Request(
            f"https://api.github.com/repos/{self.repository}/{path}",
            method=method,
            data=json.dumps(data).encode() if data is not None else None,
            headers={"Authorization": f"Bearer {self.token}",
                     "Accept": "application/vnd.github+json", "Content-Type": "application/json",
                     "X-GitHub-Api-Version": "2026-03-10", "User-Agent": "Eudes-delivery-version"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            # Do not include response bodies, headers or credentials in diagnostics.
            raise APIError(error.code) from None
        except (urllib.error.URLError, TimeoutError):
            raise RuntimeError("GitHub connection failed; retry the SAME delivery ID") from None

    def initialize(self, baseline):
        try:
            self.request("GET", f"git/ref/heads/{BRANCH}")
            return
        except APIError as error:
            if error.status != 404:
                raise
        # An orphan branch keeps registry history separate from application code.
        tree = self.request("POST", "git/trees", {"tree": [{
            "path": REGISTRY_PATH, "mode": "100644", "type": "blob",
            "content": json.dumps(initial_registry(baseline), indent=2) + "\n"}]})
        commit = self.request("POST", "git/commits", {
            "message": "Initialize Eudes delivery registry", "tree": tree["sha"], "parents": []})
        try:
            self.request("POST", "git/refs", {"ref": f"refs/heads/{BRANCH}", "sha": commit["sha"]})
        except APIError as error:
            if error.status not in (409, 422):
                raise
            # Another allocator may have created the branch. Never replace it.
            self.request("GET", f"git/ref/heads/{BRANCH}")

    def read(self):
        response = self.request("GET", f"contents/{REGISTRY_PATH}?ref={BRANCH}")
        require(response.get("type") == "file" and response.get("encoding") == "base64",
                "Invalid registry file; refusing to reset it")
        return json.loads(base64.b64decode(response["content"], validate=False)), response["sha"]

    def write(self, registry, expected_sha):
        self.request("PUT", f"contents/{REGISTRY_PATH}", {
            "message": f"Reserve Eudes delivery {registry['deliveries'][-1]['id']}",
            "branch": BRANCH, "sha": expected_sha,
            "content": base64.b64encode((json.dumps(registry, indent=2) + "\n").encode()).decode()})


def reserve(registry, baseline, delivery_id, source_sha, requested_version=None, pause=time.sleep):
    require(isinstance(delivery_id, str) and re.fullmatch(ID_PATTERN, delivery_id),
            "Delivery ID must contain 1–80 letters, digits, dots, underscores or hyphens")
    require(isinstance(source_sha, str) and re.fullmatch(SHA_PATTERN, source_sha), "Invalid source commit")
    validate_numbers(baseline)
    if requested_version is not None:
        version_parts(requested_version)
    registry.initialize(baseline)
    for attempt in range(8):
        state, sha = registry.read()
        validate_registry(state)
        require(state["baseline"] == baseline, "Baseline differs from registry; explicit migration required")
        for entry in state["deliveries"]:
            if entry["id"] == delivery_id:
                require(not requested_version or entry["version"] == requested_version,
                        "Delivery ID and tag version disagree")
                return entry
        if requested_version:
            for entry in state["deliveries"]:
                if entry["version"] == requested_version:
                    return entry
        numbers = next_numbers(state["deliveries"][-1] if state["deliveries"] else baseline)
        require(not requested_version or requested_version == numbers["version"],
                f"Tag must name an existing delivery or the next version ({numbers['version']})")
        entry = {"id": delivery_id, **numbers, "first_commit": source_sha,
                 "reserved_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
        state["deliveries"].append(entry)
        try:
            registry.write(state, sha)
            return entry
        except APIError as error:
            if error.status not in (409, 422):
                raise
            # Re-read after a collision, including when the competing ID is identical.
            pause(min(0.25 * (attempt + 1), 2))
    raise RuntimeError("Registry remained busy; retry the SAME delivery ID")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--delivery-id", default="")
    args = parser.parse_args()
    run_id = os.environ["GITHUB_RUN_ID"]
    require(re.fullmatch(r"[1-9][0-9]*", run_id), "Invalid workflow run ID")
    requested_version = None
    if os.environ.get("GITHUB_REF_TYPE") == "tag":
        tag = os.environ["GITHUB_REF_NAME"]
        require(tag.startswith("v"), "Delivery tags must start with v")
        requested_version = tag[1:]
        delivery_id = f"tag-{tag}"
    else:
        delivery_id = args.delivery_id or f"run-{run_id}"
    entry = reserve(GitHubRegistry(os.environ["GITHUB_REPOSITORY"], os.environ.get("GH_TOKEN")),
                    read_baseline(), delivery_id, os.environ["GITHUB_SHA"], requested_version)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"version={entry['version']}\nbuild={entry['build']}\ndelivery_id={entry['id']}\n")
    print(f"Delivery {entry['id']}: Eudes {entry['version']} ({entry['build']})")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, TypeError, ValueError, RuntimeError, OSError) as error:
        print(f"Delivery version failed: {error}", file=sys.stderr)
        sys.exit(1)
