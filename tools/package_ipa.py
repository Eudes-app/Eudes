#!/usr/bin/env python3
"""Verify app/widget delivery numbers, then package an unsigned IPA and its manifest."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

from delivery_version import ID_PATTERN, SHA_PATTERN, require, validate_numbers


def verify_app(app, version, build):
    validate_numbers({"version": version, "build": build})
    expected = {app: "fr.eudes.app",
                app / "PlugIns/EudesVoiceWidget.appex": "fr.eudes.app.voice-widget"}
    for bundle in [app, *sorted((app / "PlugIns").glob("*.appex"))]:
        with (bundle / "Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        require(info.get("CFBundleShortVersionString") == version
                and info.get("CFBundleVersion") == str(build), f"Wrong version/build in {bundle.name}")
        if bundle in expected:
            require(info.get("CFBundleIdentifier") == expected.pop(bundle), f"Wrong bundle ID in {bundle.name}")
        require(not (bundle / "embedded.mobileprovision").exists()
                and not (bundle / "_CodeSignature").exists(), f"Expected unsigned bundle: {bundle.name}")
    require(not expected, "EudesVoiceWidget.appex is missing")


def package(app, output, version, build, delivery_id, source_sha, run_id, attempt):
    require(re.fullmatch(ID_PATTERN, delivery_id), "Invalid delivery ID")
    require(re.fullmatch(SHA_PATTERN, source_sha), "Invalid source commit")
    require(re.fullmatch(r"[1-9][0-9]*", run_id) and re.fullmatch(r"[1-9][0-9]*", attempt),
            "Invalid workflow run/attempt")
    verify_app(app, version, build)
    name = f"eudes-{version}-build-{build}-unsigned-{run_id}-{attempt}"
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    ipa = output / f"{name}.ipa"
    manifest = output / f"{name}.json"
    require(not ipa.exists() and not manifest.exists(), "Output already exists; use an empty output directory")
    # Isolated staging avoids old files left by previous jobs on the Mac runner.
    with tempfile.TemporaryDirectory(prefix="eudes-ipa-") as directory:
        staging = Path(directory)
        shutil.copytree(app, staging / "Payload/Eudes.app", symlinks=True)
        temporary_ipa = staging / "delivery.ipa"
        subprocess.run(["zip", "-qry", str(temporary_ipa), "Payload"], cwd=staging, check=True)
        shutil.move(temporary_ipa, ipa)
    manifest.write_text(json.dumps({"delivery_id": delivery_id, "version": version, "build": build,
                                   "source_commit": source_sha, "run_id": run_id, "run_attempt": attempt,
                                   "signed": False, "ipa": ipa.name}, indent=2) + "\n")
    return name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", type=int, required=True)
    parser.add_argument("--delivery-id", required=True)
    args = parser.parse_args()
    name = package(args.app, args.output, args.version, args.build, args.delivery_id,
                   os.environ["GITHUB_SHA"], os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"])
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"artifact_name={name}\n")
    print(f"Verified and packaged {name}.ipa (unsigned)")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"IPA packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
