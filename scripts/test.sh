#!/bin/bash
# Test della logica pura (senza avviare l'app).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 5 -o build/layout-tests Sources/DisplayLayout.swift Sources/L10n.swift Tests/DisplayLayout/main.swift 2>&1 | grep -v "^$" || true
build/layout-tests
