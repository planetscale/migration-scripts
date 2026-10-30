#!/bin/bash
#
# Usage: ~/start-resume-cdc-screen.sh
#
# Resumes CDC (pgcopydb follow) inside a detached screen session named
# "resume-cdc". Kills any existing resume-cdc screen first. Use
# "screen -r resume-cdc" to attach and Ctrl-A D to detach.
#
set -eo pipefail

# Kill any existing resume-cdc screen
screen -S resume-cdc -X quit 2>/dev/null || true

# Start new screen session
screen -dmS resume-cdc bash -c '~/resume-cdc.sh; echo "Press enter to exit."; read'

echo "CDC resume started in screen session 'resume-cdc'"
echo ""
echo "To watch:        screen -r resume-cdc"
echo "To detach:       Ctrl-A then D"
echo "To check status: ~/check-migration-status.sh"
echo "────────────────────────────────────────────────────────"
