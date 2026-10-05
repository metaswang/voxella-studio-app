#!/bin/bash
# Shipped at the marketplace root. Migration logic uses structured CLI JSON.
set -euo pipefail
PACKAGE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$PACKAGE_ROOT/install.py" "$@"
