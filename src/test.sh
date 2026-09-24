#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
xcrun swiftc -swift-version 5 Sources/BrewBar/CommandRunner.swift Sources/BrewBar/InstalledPackage.swift Sources/BrewBar/PackageUpdate.swift Tests/RunnerTests.swift -o build/RunnerTests
build/RunnerTests
xcrun swiftc -swift-version 5 Sources/BrewBar/CommandRunner.swift Sources/BrewBar/InstalledPackage.swift Sources/BrewBar/PackageUpdate.swift Sources/BrewBar/BrewModel.swift Tests/UninstallTests.swift -o build/UninstallTests
build/UninstallTests
