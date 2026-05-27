#!/usr/bin/env bash
# =============================================================================
# deploy_dev.sh — Deploy LOCID_PKG_DEV / LOCID_APP_DEV (provider sandbox only)
#
# Usage (from na_app_pkg/):
#   ./deploy_dev.sh --connection <conn>
#
# What this does:
#   1. Drops LOCID_APP (prod) if installed — LOCID_APP and LOCID_APP_DEV cannot
#      coexist in the same account (shared account-level EAI conflict).
#   2. Backs up snowflake.yml (prod config) and swaps in snowflake-dev.yml.
#   3. Runs: snow app deploy + version create + run (installs LOCID_APP_DEV).
#   4. Restores snowflake.yml (always, even on failure via trap).
#
#   NOTE: LOCID_APP is dropped before this script runs. To restore it afterwards:
#     snow app run --version v1_0 --connection <conn>
#
# Pass any extra snow flags after --connection, e.g.:
#   ./deploy_dev.sh --connection locid
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PROD_CONFIG="snowflake.yml"
DEV_CONFIG="snowflake-dev.yml"
BACKUP="snowflake.yml.prod.bak"

if [ ! -f "$DEV_CONFIG" ]; then
    echo "Error: $DEV_CONFIG not found in $(pwd)" >&2
    exit 1
fi

# Extract connection flag for the drop step
CONN_FLAG=""
for arg in "$@"; do
    if [[ "$arg" == --connection=* ]]; then
        CONN_FLAG="$arg"
    elif [[ "$prev" == "--connection" ]]; then
        CONN_FLAG="--connection $arg"
    fi
    prev="$arg"
done

# Step 1: Drop LOCID_APP (prod) if installed — EAI ownership conflict
echo "Dropping LOCID_APP (if installed) — EAI conflict prevention..."
snow sql $CONN_FLAG \
    -q "DROP APPLICATION IF EXISTS LOCID_APP CASCADE" 2>/dev/null || true

# Always restore prod config on exit (success, failure, or interrupt)
trap 'echo "Restoring prod config..."; mv "$BACKUP" "$PROD_CONFIG"' EXIT

# Step 2: Swap snowflake.yml → dev config
echo "Swapping to dev config..."
cp "$PROD_CONFIG" "$BACKUP"
cp "$DEV_CONFIG" "$PROD_CONFIG"

# Step 3: Deploy LOCID_PKG_DEV / LOCID_APP_DEV
echo "Deploying LOCID_PKG_DEV / LOCID_APP_DEV..."
snow app deploy "$@"
snow app version create v1_0 --force --skip-git-check "$@"
snow app run --version v1_0 "$@"

echo ""
echo "Dev deployment complete. Prod config restored."
echo ""
echo "To reinstall LOCID_APP (prod) when done testing:"
echo "  snow app run --version v1_0 $CONN_FLAG"
