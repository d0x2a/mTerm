#!/usr/bin/env bash
# Drives a real `tmux -CC` through mTerm's control-mode chain. Separate from
# statecheck.sh because it needs tmux installed and spawns a server; statecheck
# is pure and always runnable.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux not installed — skipping the control-mode end-to-end check."
    exit 0
fi

out="${TMPDIR:-/tmp}/mterm-tmuxcheck"
swiftc -package-name mTerm -framework SwiftUI -o "$out" \
    scripts/tmuxcheck/main.swift \
    $(find Sources/MTermCore -name '*.swift' | sort)

status=0
"$out" "$@" || status=$?

# tmux only removes its socket when the server shuts down cleanly; a killed
# one leaves the file behind, and a stale socket confuses the next `tmux ls`.
rm -f "${TMPDIR:-/tmp}/tmux-$(id -u)/mtermcheck" "/private/tmp/tmux-$(id -u)/mtermcheck" 2>/dev/null || true
exit "$status"
