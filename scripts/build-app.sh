#!/bin/zsh
# Builds TaskSorcerer.app (menu-bar app) and the `sorcerer` CLI into ./build.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP=build/TaskSorcerer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN/TaskSorcerer" "$APP/Contents/MacOS/TaskSorcerer"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/sorcerer" build/sorcerer

# Ad-hoc signature: enough to run locally and to get the Reminders permission prompt.
codesign --force --sign - "$APP"
codesign --force --sign - build/sorcerer

echo "Built $APP and build/sorcerer"
echo "Install: cp -R $APP /Applications/ && open /Applications/TaskSorcerer.app"
