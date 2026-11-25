#!/bin/bash
# Build the missing iOS slices from the source used by b12236.
# LLAMA_BUILD_SLICES=simulator ne produit que la tranche simulateur (tests CI) ;
# la valeur par défaut, all, ajoute la tranche appareil utilisée par
# tools/build-device.sh.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
revision=3d94ffe452f42dbedde25277e2e6e97905ce6c02
slices="${LLAMA_BUILD_SLICES:-all}"
case "$slices" in
    simulator) targets=(ios-sim) ;;
    all) targets=(ios-sim ios-device) ;;
    *)
        printf 'LLAMA_BUILD_SLICES doit valoir "simulator" ou "all", pas "%s".\n' "$slices" >&2
        exit 2
        ;;
esac
artifact="$repo_root/ios/Packages/EudesLlama/Artifacts/llama-b12236.xcframework"
marker="$repo_root/ios/Packages/EudesLlama/Artifacts/.b12236-revision"
stamp="$revision $slices"
if [[ -f "$marker" && "$(cat "$marker")" == "$stamp" && -f "$artifact/Info.plist" ]]; then
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
(cd "$build_root" && bash build-xcframework.sh "${targets[@]}")
mkdir -p "$(dirname "$artifact")"
rm -rf "$artifact"
cp -R "$build_root/build-apple/llama.xcframework" "$artifact"
printf '%s\n' "$stamp" > "$marker"
