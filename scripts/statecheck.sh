#!/usr/bin/env bash
# Builds and runs the headless terminal-emulation checks in scripts/statecheck.
#
# Compiles the real terminal sources directly rather than linking the app
# target: none of this needs a window, a Metal device or a PTY. All of
# MTermCore goes in — it is AppKit-free and self-contained by construction, so
# the list can't go stale the way a hand-kept one did — plus the settings index
# from MTermApp, which is pure data but belongs to the Settings window.
# SwiftUI is linked because ProfileStore uses its MutableCollection.move.
#
# `-package-name` because the core marks its cross-target API `package`.
set -euo pipefail

cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/mterm-statecheck"

swiftc -package-name mTerm -framework SwiftUI -o "$out" \
    scripts/statecheck/main.swift \
    $(find Sources/MTermCore -name '*.swift' | sort) \
    Sources/MTermApp/Settings/SettingsIndex.swift \
    Sources/MTermApp/Settings/SettingsKeyboard.swift

exec "$out" "$@"
