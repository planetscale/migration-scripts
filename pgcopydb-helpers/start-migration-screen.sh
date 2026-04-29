#!/bin/bash
#
# Usage: ~/start-migration-screen.sh [--no-monitor]
#
# Starts run-migration.sh inside a detached screen session named "migration".
# Kills any existing migration screen first. Use "screen -r migration" to
# attach and Ctrl-A D to detach.
#
# Slack monitoring via notify-migration.sh is enabled by default (every 2 min).
# Use --no-monitor to skip. To change the interval later:
#   ~/notify-migration.sh --uninstall
#   ~/notify-migration.sh --setup --interval N
#
set -eo pipefail

MONITOR=true

while [ $# -gt 0 ]; do
    case "$1" in
        --no-monitor)
            MONITOR=false
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: $0 [--no-monitor]" >&2
            exit 1
            ;;
    esac
done

# Kill any existing migration screen
screen -S migration -X quit 2>/dev/null || true

# Start new screen session
screen -dmS migration bash -c '~/run-migration.sh; echo "Press enter to exit."; read'

echo "Migration started in screen session 'migration'"
echo ""
echo "To watch:        screen -r migration"
echo "To detach:       Ctrl-A then D"
echo "To check status: ~/check-migration-status.sh"
echo ""
echo "────────────────────────────────────────────────────────"

if [ "$MONITOR" = true ]; then
    echo "Setting up Slack monitoring (every 2 min)..."
    echo "────────────────────────────────────────────────────────"
    echo ""
    if ~/notify-migration.sh --setup > /dev/null 2>&1; then
        echo "Monitoring is active."
        echo "To disable:      ~/notify-migration.sh --uninstall"
        echo "To reconfigure:  ~/notify-migration.sh --setup --interval N"
    else
        echo "WARNING: Monitoring setup failed."
        echo "Check SLACK_WEBHOOK_URL is set in ~/.env"
        echo "To enable manually: ~/notify-migration.sh --setup"
    fi
else
    echo "Slack monitoring: DISABLED (--no-monitor was passed)"
    echo "To enable later: ~/notify-migration.sh --setup [--interval N]"
fi

echo "────────────────────────────────────────────────────────"
