#!/usr/bin/env bash
# Builds and runs the headless terminal-emulation checks in scripts/statecheck.
#
# Compiles the real terminal sources directly rather than linking the app
# target: none of this needs a window, a Metal device or a PTY. SwiftUI is
# linked because ProfileStore uses its MutableCollection.move.
set -euo pipefail

cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/mterm-statecheck"

swiftc -framework SwiftUI -o "$out" \
    scripts/statecheck/main.swift \
    Sources/mTerm/Terminal/TerminalState.swift \
    Sources/mTerm/Terminal/Parser.swift \
    Sources/mTerm/Triggers/Trigger.swift \
    Sources/mTerm/Triggers/TriggerEvaluator.swift \
    Sources/mTerm/Triggers/TriggerStore.swift \
    Sources/mTerm/Theme/Theme.swift \
    Sources/mTerm/Theme/ThemeStore.swift \
    Sources/mTerm/App/AppSettings.swift \
    Sources/mTerm/App/FontCatalog.swift \
    Sources/mTerm/App/Profile.swift \
    Sources/mTerm/App/Persistence.swift

exec "$out" "$@"
