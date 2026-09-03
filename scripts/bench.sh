#!/usr/bin/env bash
# Builds and runs the headless parse/snapshot benchmark in scripts/bench.
#
# It compiles the real terminal sources directly rather than linking the app
# target: the app is a GUI executable with a Metal renderer and a PTY, none of
# which a throughput measurement should have to start. Optimisation settings
# match the release build, so the numbers are the ones a shipped mTerm gets.
set -euo pipefail

cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/mterm-bench"

swiftc -O -whole-module-optimization -o "$out" \
    scripts/bench/main.swift \
    Sources/mTerm/Terminal/TerminalState.swift \
    Sources/mTerm/Terminal/Parser.swift \
    Sources/mTerm/Triggers/Trigger.swift \
    Sources/mTerm/Triggers/TriggerEvaluator.swift \
    Sources/mTerm/Theme/Theme.swift \
    Sources/mTerm/Theme/ThemeStore.swift \
    Sources/mTerm/App/AppSettings.swift \
    Sources/mTerm/App/FontCatalog.swift

exec "$out" "$@"
