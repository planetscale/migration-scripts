#!/bin/bash
#
# Usage: ~/start-migration-screen.sh
#
# Starts run-migration.sh inside a detached screen session named "migration".
# Kills any existing migration screen first. Use "screen -r migration" to
# attach and Ctrl-A D to detach.
#
set -eo pipefail

# Kill any existing migration screen
screen -S migration -X quit 2>/dev/null || true

# Start new screen session
screen -dmS migration bash -c '~/run-migration.sh; echo "Press enter to exit."; read'

echo "Migration started in screen session 'migration'"
echo ""
echo "To watch: screen -r migration"
echo "To detach: Ctrl-A then D"
echo "To check status: ~/check-migration-status.sh"
