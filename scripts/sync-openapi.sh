#!/usr/bin/env bash
#
# Sync the OpenAPI spec snapshot from the monorepo and regenerate wire types.
# Run from the swift-sdk repo root:
#
#   ./scripts/sync-openapi.sh
#
# Requires ~/aic-local/Dev/MymeHQ/myme (the monorepo) to be checked out as a
# sibling of this repo.

set -euo pipefail

MONOREPO_SPEC="../myme/openapi.json"
LOCAL_SNAPSHOT="scripts/openapi.json"

if [[ ! -f "$MONOREPO_SPEC" ]]; then
    echo "error: $MONOREPO_SPEC not found" >&2
    echo "Expected the monorepo to be checked out at a sibling of this repo." >&2
    exit 1
fi

cp "$MONOREPO_SPEC" "$LOCAL_SNAPSHOT"
echo "synced: $MONOREPO_SPEC → $LOCAL_SNAPSHOT"

swift run codegen-wire
echo "regenerated wire types"
