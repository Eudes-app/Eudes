#!/bin/bash
# Build the missing iOS Simulator slice from the source used by b12236.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
revision=3d94ffe452f42dbedde25277e2e6e97905ce6c02
artifact="$repo_root/ios/Packages/EudesLlama/Artifacts/llama-b12236.xcframework"
marker="$repo_root/ios/Packages/EudesLlama/Artifacts/.b12236-revision"
if [[ -f "$marker" && "$(cat "$marker")" == "$revision" && -f "$artifact/Info.plist" ]]; then
    exit 0
fi
build_root="$repo_root/build/llama-b12236"
if [[ ! -d "$build_root/.git" ]]; then
    mkdir -p "$build_root"
    git -C "$build_root" init -q
    git -C "$build_root" remote add origin https://github.com/ggml-org/llama.cpp.git
fi
if ! git -C "$build_root" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$build_root" fetch --depth 1 origin "$revision"
fi
git -C "$build_root" checkout --detach "$revision"
[[ "$(git -C "$build_root" rev-parse HEAD)" == "$revision" ]]
(cd "$build_root" && bash build-xcframework.sh ios-sim ios-device)
mkdir -p "$(dirname "$artifact")"
rm -rf "$artifact"
cp -R "$build_root/build-apple/llama.xcframework" "$artifact"
printf '%s\n' "$revision" > "$marker"
