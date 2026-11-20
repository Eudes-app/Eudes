#!/usr/bin/env python3
"""Build, install and verify a signed app on a connected iPhone. Never claims human test success.

Manual use, no GitHub and no repository secret:
    bash tools/build-device.sh
    python3 tools/install-iphone.py install

The device and the version are discovered automatically (one connected iPhone,
ios/Version.xcconfig). In CI the same script reads IPHONE_DEVICE_ID,
DELIVERY_VERSION and DELIVERY_BUILD instead.
"""
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

BUNDLE = "fr.eudes.app"
ROOT = Path(os.environ.get("SOURCE_DIR", "."))
EVIDENCE = ROOT / "build/iphone-evidence"


def evidence_dir():
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    return EVIDENCE


def connected(device):
    state = device.get("connectionProperties", {}).get("tunnelState")
    return state in (None, "connected")


def device_id():
    configured = os.environ.get("IPHONE_DEVICE_ID")
    if configured:
        return configured
    output = evidence_dir() / "devices.json"
    subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", str(output), "--quiet"], check=True)
    devices = [d for d in json.loads(output.read_text())["result"]["devices"] if connected(d)]
    if len(devices) != 1:
        raise ValueError(f"Connect exactly one iPhone, or set IPHONE_DEVICE_ID ({len(devices)} detected)")
    return devices[0]["hardwareProperties"]["udid"]


def target_version():
    version, build = os.environ.get("DELIVERY_VERSION"), os.environ.get("DELIVERY_BUILD")
    if version and build:
        return version, build
    config = {}
    for line in (ROOT / "ios/Version.xcconfig").read_text().splitlines():
        if "=" in line and not line.strip().startswith("//"):
            key, value = line.split("=", 1)
            config[key.strip()] = value.strip()
    return config["MARKETING_VERSION"], config["CURRENT_PROJECT_VERSION"]


def installed(device, output):
    subprocess.run(["xcrun", "devicectl", "device", "info", "apps", "--device", device,
                    "--json-output", str(output), "--quiet"], check=True)
    apps = json.loads(output.read_text())["result"]["apps"]
    app = next((a for a in apps if a.get("bundleIdentifier") == BUNDLE), None)
    if not app:
        raise ValueError("Existing Eudes installation not found")
    return app.get("version") or app.get("shortVersion"), str(app.get("bundleVersion"))


def check_upgrade(before, target):
    old_version, old_build = before
    version, build = target
    if int(old_build) > int(build) or tuple(map(int, old_version.split('.'))) > tuple(map(int, version.split('.'))):
        raise ValueError("Refusing to downgrade the installed version; reserve a newer delivery")


def receipt(target):
    # Only CI produces a receipt; local installations stay on the tester's machine.
    if not (os.environ.get("PR_NUMBER") and os.environ.get("REVIEWED_SHA")):
        return
    payload = {"pr": os.environ["PR_NUMBER"], "sha": os.environ["REVIEWED_SHA"],
               "version": target[0], "build": target[1], "run": os.environ.get("GITHUB_RUN_ID"), "installed": True}
    (evidence_dir() / "receipt.json").write_text(json.dumps(payload, indent=2))


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "install"
    if command == "device-id":
        print(device_id())
        return
    if command == "version":
        version, build = target_version()
        print(version, build)
        return
    if command not in ("preflight", "install"):
        raise ValueError("Commands: device-id, version, preflight, install")
    root = ROOT
    evidence = evidence_dir()
    device = device_id()
    target = target_version()
    before = installed(device, evidence / "before.json")
    check_upgrade(before, target)
    if command == "preflight":
        print(f"Current version {before[0]} ({before[1]}); target {target[0]} ({target[1]})")
        return
    app = root / "build/Device/Build/Products/Release-iphoneos/Eudes.app"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    for bundle in [app, *app.glob("PlugIns/*.appex")]:
        with (bundle / "Info.plist").open("rb") as f:
            info = plistlib.load(f)
        if (info["CFBundleShortVersionString"], str(info["CFBundleVersion"])) != target:
            raise ValueError("Compiled app/widget version mismatch")
    with (app / "Info.plist").open("rb") as f:
        if plistlib.load(f)["CFBundleIdentifier"] != BUNDLE:
            raise ValueError("Unexpected application identifier")
    subprocess.run(["xcrun", "devicectl", "device", "install", "app", "--device", device, str(app), "--quiet"], check=True)
    if installed(device, evidence / "after.json") != target:
        raise ValueError("Installed version could not be verified")
    receipt(target)
    print("Installation verified; human iPhone tests are still required")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Installation blocked: {error}", file=sys.stderr)
        sys.exit(1)
