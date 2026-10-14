#!/bin/zsh
# Builds and runs the unit tests.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 Sources/Core/*.swift Sources/App/Keys.swift Sources/App/Profile.swift Sources/App/AppModel.swift Tests/unit/main.swift -o build/unittests
build/unittests
