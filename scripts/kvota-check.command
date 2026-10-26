#!/bin/bash
# Kvota check. Double-click to run: checks Claude Code's setup for Kvota, starts claude
# once in an empty temporary folder and sends one short message, so Claude Code shares
# your plan limits with Kvota. Saves a report to ~/Downloads/kvota-check-report.txt.
cd "$(dirname "$0")" || exit 1
python3 ./kvota-check.py --live --message
echo
echo "Done. You can close this window."
