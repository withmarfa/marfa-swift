#!/usr/bin/env bash
#
# Sync the OpenAPI spec snapshot from the monorepo and regenerate wire types.
# Run from the swift-sdk repo root:
#
#   ./scripts/sync-openapi.sh
#
# By default expects the `marfa` monorepo to live as a sibling of this repo
# (i.e. `../marfa/openapi.json`). Override with `MARFA_REPO_ROOT` when the
# monorepo lives elsewhere:
#
#   MARFA_REPO_ROOT=/path/to/marfa ./scripts/sync-openapi.sh

set -euo pipefail

MARFA_REPO_ROOT="${MARFA_REPO_ROOT:-../marfa}"
MONOREPO_SPEC="${MARFA_REPO_ROOT}/openapi.json"
LOCAL_SNAPSHOT="scripts/openapi.json"

if [[ ! -f "$MONOREPO_SPEC" ]]; then
    echo "error: $MONOREPO_SPEC not found" >&2
    echo "Set MARFA_REPO_ROOT to the monorepo checkout (default: ../marfa)." >&2
    exit 1
fi

cp "$MONOREPO_SPEC" "$LOCAL_SNAPSHOT"
echo "synced: $MONOREPO_SPEC → $LOCAL_SNAPSHOT"

swift run codegen-wire
echo "regenerated wire types"
