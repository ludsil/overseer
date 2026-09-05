#!/bin/bash
# Build and install the standalone native app for the current user.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "$ROOT/scripts/install-local.sh"
