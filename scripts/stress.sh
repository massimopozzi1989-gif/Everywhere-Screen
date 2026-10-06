#!/bin/bash
# Stress test del server, dello streaming H.264/MJPEG e dell'abbinamento (in-process, frame sintetici).
# Non cattura lo schermo, non muove il mouse e non crea schermi virtuali.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/stress
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o build/stress/stress-tests \
  Sources/HTTPServer.swift Sources/WebSocket.swift Sources/WebApp.swift Sources/Pairing.swift \
  Sources/Page.swift Sources/L10n.swift Sources/StreamHub.swift Sources/H264Encoder.swift Sources/FMP4Muxer.swift \
  Sources/Edition.swift Tests/Stress/main.swift
build/stress/stress-tests build/stress "$@"
