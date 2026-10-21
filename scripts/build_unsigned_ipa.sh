#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate
rm -rf build ipa Payload KairoBody.ipa
xcodebuild \
  -project KairoBody.xcodeproj \
  -scheme KairoBody \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  clean build

APP_PATH="build/Build/Products/Release-iphoneos/KairoBody.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at: $APP_PATH" >&2
  exit 1
fi
mkdir -p Payload
cp -R "$APP_PATH" Payload/
zip -qry KairoBody.ipa Payload
rm -rf Payload
printf 'Built %s/KairoBody.ipa\n' "$PWD"
