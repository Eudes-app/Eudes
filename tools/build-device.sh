#!/bin/bash
# Builds a signed Release app for a connected iPhone.
# Manual use: APPLE_TEAM_ID=XXXXXXXXXX bash tools/build-device.sh
# The device and the version are discovered automatically when the matching
# variables are absent (one connected iPhone, ios/Version.xcconfig).
set -euo pipefail
SOURCE_DIR="${SOURCE_DIR:-.}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
# La CI ne compile que la tranche simulateur ; un artefact local incomplet doit
# être complété avant une compilation appareil.
artifact_dir="$SOURCE_DIR/ios/Packages/EudesLlama/Artifacts"
local_artifact=( "$artifact_dir"/llama-*.xcframework )
if [[ -e "${local_artifact[0]}" && ! -d "${local_artifact[0]}/ios-arm64" ]]; then
  printf 'Artefact llama.cpp local sans tranche appareil : lancez bash "%s/tools/prepare-llama-simulator.sh".\n' "$SOURCE_DIR" >&2
  exit 1
fi
args=(-project "$SOURCE_DIR/ios/Eudes.xcodeproj" -scheme Eudes -configuration Release -sdk iphoneos -derivedDataPath "$SOURCE_DIR/build/Device")
if [[ "${SIGNED_BUILD:-true}" == true ]]; then
  : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID to the Apple developer team used for signing}"
  device="${IPHONE_DEVICE_ID:-$(python3 "$SOURCE_DIR/tools/install-iphone.py" device-id)}"
  if [[ -z "${DELIVERY_VERSION:-}" || -z "${DELIVERY_BUILD:-}" ]]; then
    read -r DELIVERY_VERSION DELIVERY_BUILD < <(python3 "$SOURCE_DIR/tools/install-iphone.py" version)
  fi
  args+=(-destination "id=$device" "DEVELOPMENT_TEAM=$APPLE_TEAM_ID"
         "MARKETING_VERSION=$DELIVERY_VERSION" "CURRENT_PROJECT_VERSION=$DELIVERY_BUILD")
else
  args+=(-destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi
xcodebuild "${args[@]}" build
