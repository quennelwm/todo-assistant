#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-$PWD/build/Build/Products/Release/待办助手.app}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
mkdir -p dist
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto --noextattr "$app" "$stage/待办助手.app"
xattr -dr com.apple.FinderInfo "$stage/待办助手.app" 2>/dev/null || :
codesign --verify --deep --strict "$stage/待办助手.app"
cp docs/INSTALL.md "$stage/安装说明.md"
cp LICENSE "$stage/LICENSE.txt"
archive="$PWD/dist/TodoAssistant-$version-macOS-universal.zip"
ditto -c -k --norsrc "$stage" "$archive"
(cd dist && shasum -a 256 "$(basename "$archive")" > SHA256SUMS.txt)
printf '%s\n' "$archive"
