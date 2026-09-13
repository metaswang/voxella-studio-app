#!/bin/bash
set -euo pipefail
artifact="${1:?Usage: check-mas-billing.sh path-to-app-or-binary}"
if [ ! -e "$artifact" ]; then
  echo "Missing MAS artifact: $artifact" >&2
  exit 1
fi
if LC_ALL=C grep -aERiq 'checkout\.stripe\.com|billing\.stripe\.com|billing/stripe/(checkout|portal)' "$artifact"; then
  echo "MAS artifact contains external billing endpoints" >&2
  exit 1
else
  scan_status=$?
  if [ "$scan_status" -ne 1 ]; then
    echo "Unable to inspect MAS artifact" >&2
    exit "$scan_status"
  fi
fi
echo "MAS external billing endpoint check passed"
