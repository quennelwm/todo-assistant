#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
team="${TODO_TEAM:-$(security find-certificate -c 'Apple Development:' -p | openssl x509 -noout -subject -nameopt multiline | awk -F ' = ' '/organizationalUnitName/ {print $2}')}"
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
  echo '请在 Xcode 配置签名证书，并设置 TODO_TEAM 为你的开发团队 ID。' >&2
  exit 1
fi
identity="${TODO_SIGN_IDENTITY:-Apple Development}"
derived="${TODO_BUILD_DIR:-$PWD/build}"
xcodebuild -project DesktopTodo.xcodeproj -scheme DesktopTodo -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO DEVELOPMENT_TEAM="$team" \
  CODE_SIGN_IDENTITY="$identity" ENABLE_HARDENED_RUNTIME=YES build
app="$derived/Build/Products/Release/待办助手.app"
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || :
codesign --verify --deep --strict "$app"
printf '\n%s\n' "$app"
