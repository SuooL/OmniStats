#!/bin/bash
# Install the privileged OmniStats fan-control helper as a root LaunchDaemon.
# Usage: sudo bash packaging/install-helper.sh [path-to-omnistats-smcd]
set -euo pipefail

HELPER_SRC="${1:-build/omnistats-smcd}"
HELPER_DST="/usr/local/sbin/omnistats-smcd"
PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/com.omnistats.smcd.plist"
PLIST_DST="/Library/LaunchDaemons/com.omnistats.smcd.plist"

if [[ $EUID -ne 0 ]]; then
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$HELPER_SRC"
fi

if [[ ! -f "$HELPER_SRC" ]]; then
    echo "error: helper binary not found at '$HELPER_SRC' — run 'make helper' first." >&2
    exit 1
fi

echo "Installing helper -> $HELPER_DST"
mkdir -p /usr/local/sbin
install -m 755 -o root -g wheel "$HELPER_SRC" "$HELPER_DST"

echo "Installing LaunchDaemon -> $PLIST_DST"
install -m 644 -o root -g wheel "$PLIST_SRC" "$PLIST_DST"

echo "Loading daemon..."
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load -w "$PLIST_DST"

echo "Done. omnistats-smcd is running as root; OmniStats.app can now control fans."
echo "Logs: /var/log/omnistats-smcd.log"
