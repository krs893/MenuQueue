#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/tests
swiftc -swift-version 5 -parse-as-library -framework AppKit -framework SwiftUI \
    Sources/QueueTextParser.swift Sources/PanelPlacement.swift Sources/Marquee.swift Sources/ArtworkStore.swift Sources/LibraryModel.swift Sources/MediaKeys.swift Sources/TickerView.swift Sources/EventLog.swift Sources/DiscordPresence.swift Sources/Models.swift Sources/LibraryIndex.swift Sources/QueueStore.swift Sources/PlayerController.swift \
    Tests/TestMusicBridge.swift Tests/RegressionTests.swift -o build/tests/regression
build/tests/regression

swiftc -swift-version 5 -parse-as-library -framework AppKit \
    Sources/ScriptRunner.swift Tests/ScriptRunnerTests.swift -o build/tests/script-runner
build/tests/script-runner

swiftc -swift-version 5 -parse-as-library -framework AppKit \
    Sources/ScriptRunner.swift Sources/Models.swift Sources/MusicStatusPayload.swift \
    Tests/MusicStatusPayloadTests.swift -o build/tests/music-status
build/tests/music-status
