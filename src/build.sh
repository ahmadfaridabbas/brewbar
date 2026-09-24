#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/BrewBar.app/Contents/MacOS
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 -parse-as-library Sources/BrewBar/*.swift -o build/BrewBar.app/Contents/MacOS/BrewBar
cp Info.plist build/BrewBar.app/Contents/Info.plist
mkdir -p build/BrewBar.app/Contents/Resources
cp Resources/AppIcon.icns Resources/AppIcon.png Resources/MenuBarTemplate.png Resources/MenuBarTemplate@2x.png Resources/AppIconLight.png Resources/AppIconDark.png build/BrewBar.app/Contents/Resources/
codesign --force --sign - build/BrewBar.app
printf 'Built build/BrewBar.app\n'
