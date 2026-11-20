#!/bin/bash
# Run the same simulator suite locally and in GitHub Actions.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    DEVELOPER_DIR="$(xcode-select -p)"
    if [[ "$DEVELOPER_DIR" == */CommandLineTools && -d /Applications/Xcode.app/Contents/Developer ]]; then
        DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    fi
fi
export DEVELOPER_DIR
# Also make simctl available to Xcode's diagnostic collection subprocesses.
export PATH="$DEVELOPER_DIR/usr/bin:$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# The upstream iOS binary lacks a Simulator slice; prepare the pinned source build.
bash tools/prepare-llama-simulator.sh

results_dir="$repo_root/build/test-results/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$results_dir"
{
    xcodebuild -version
    printf 'Developer directory: %s\n' "$DEVELOPER_DIR"
    printf 'Simulator SDK: '
    xcrun --sdk iphonesimulator --show-sdk-version
    printf 'Revision: '
    git rev-parse HEAD
} | tee "$results_dir/environment.log"

xcode_version="$(xcodebuild -version | awk '/^Xcode / { print $2 }')"
if [[ "${xcode_version%%.*}" -lt 27 ]]; then
    printf 'Xcode 27 or later is required (found %s).\n' "$xcode_version" >&2
    exit 1
fi

xcrun simctl list devices available --json > "$results_dir/simulators.json"
python3 - "$results_dir/simulators.json" "${EUDES_SIMULATOR_ID:-}" > "$results_dir/destination.txt" <<'PY'
import json
import re
import sys

with open(sys.argv[1]) as source:
    devices = json.load(source)["devices"]
requested = sys.argv[2]
candidates = []
for runtime, entries in devices.items():
    match = re.search(r"\.iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    if not match:
        continue
    version = tuple(int(part or 0) for part in match.groups())
    if version[0] < 27:
        continue
    for device in entries:
        if not device.get("isAvailable") or "iPhone" not in device["name"]:
            continue
        if requested and device["udid"] != requested:
            continue
        candidates.append((version, device["state"] == "Booted", device["udid"], device))
if not candidates:
    raise SystemExit("No available iPhone simulator with iOS 27 or later matches the requested destination.")
device = max(candidates, key=lambda candidate: candidate[:3])[3]
print(device["udid"], device["state"])
print(f'Simulator: {device["name"]} ({device["udid"]})', file=sys.stderr)
PY

read -r simulator_id simulator_state < "$results_dir/destination.txt"
if [[ "$simulator_state" != Booted ]]; then
    xcrun simctl boot "$simulator_id"
fi
xcrun simctl bootstatus "$simulator_id" -b

# Ad-hoc signing lets the test host exercise Keychain on the simulator.
# It does not require an Apple account, certificate, or provisioning profile.
xcodebuild \
    -packageAuthorizationProvider netrc \
    -project ios/Eudes.xcodeproj \
    -scheme Eudes \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -destination-timeout 120 \
    -derivedDataPath "${EUDES_DERIVED_DATA_PATH:-$repo_root/build/DerivedData}" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$results_dir/EudesTests.xcresult" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    test 2>&1 | tee "$results_dir/xcodebuild.log"

printf '\nTests passed. Results: %s\n' "$results_dir"

