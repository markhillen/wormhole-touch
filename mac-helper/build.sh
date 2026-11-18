#!/bin/bash
# Builds PortalTouch.app into mac-helper/build/.
# Signing: set SIGN_IDENTITY to a codesigning identity (see `security find-identity -v -p codesigning`).
# A stable identity keeps the Accessibility permission across rebuilds; the default ad-hoc
# signature ("-") works but macOS asks for the permission again after every rebuild.
set -euo pipefail
cd "$(dirname "$0")"
IDENTITY="${SIGN_IDENTITY:--}"
APP=build/PortalTouch.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -target "$(uname -m)-apple-macos13" main.swift -o "$APP/Contents/MacOS/PortalTouch"
codesign --force --options runtime -s "$IDENTITY" "$APP"
echo "Built $APP"
