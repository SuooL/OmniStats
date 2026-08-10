#!/bin/bash
# Remove the OmniStats fan-control helper and revert fans to firmware auto.
# Usage: sudo bash packaging/uninstall-helper.sh
set -euo pipefail

PLIST_DST="/Library/LaunchDaemons/com.omnistats.smcd.plist"
HELPER_DST="/usr/local/sbin/omnistats-smcd"

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0"
fi

echo "Stopping daemon (fans revert to auto on exit)..."
launchctl unload "$PLIST_DST" 2>/dev/null || true
rm -f "$PLIST_DST" "$HELPER_DST" /var/run/omnistats.sock
echo "Uninstalled omnistats-smcd."
