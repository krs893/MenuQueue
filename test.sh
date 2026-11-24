#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests
swiftc -swift-version 5 -parse-as-library -framework AppKit -framework SwiftUI \
    Sources/YTMusic.swift Sources/ScriptRunner.swift Sources/PanelPlacement.swift Sources/Marquee.swift \
    Sources/TickerView.swift Sources/EventLog.swift Sources/DiscordPresence.swift \
    Tests/RegressionTests.swift -o build/tests/regression
build/tests/regression

swiftc -swift-version 5 -parse-as-library -framework AppKit \
    Sources/ScriptRunner.swift Tests/ScriptRunnerTests.swift -o build/tests/script-runner
build/tests/script-runner
