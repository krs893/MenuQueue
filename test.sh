#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests
swiftc -swift-version 5 -parse-as-library -framework AppKit -framework SwiftUI \
    Sources/PanelPlacement.swift Sources/Models.swift Sources/QueueStore.swift Sources/PlayerController.swift \
    Tests/TestMusicBridge.swift Tests/RegressionTests.swift -o build/tests/regression
build/tests/regression
