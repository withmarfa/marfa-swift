#!/usr/bin/env bash
#
# Sync the OpenAPI spec snapshot from the monorepo and regenerate wire types.
# Run from the swift-sdk repo root:
#
#   ./scripts/sync-openapi.sh
#
# By default expects the `myme` monorepo to live as a sibling of this repo
# (i.e. `../myme/openapi.json`). Override with `MYME_REPO_ROOT` when the
# monorepo lives elsewhere:
#
#   MYME_REPO_ROOT=/path/to/myme ./scripts/sync-openapi.sh

set -euo pipefail

MYME_REPO_ROOT="${MYME_REPO_ROOT:-../myme}"
MONOREPO_SPEC="${MYME_REPO_ROOT}/openapi.json"
LOCAL_SNAPSHOT="scripts/openapi.json"

if [[ ! -f "$MONOREPO_SPEC" ]]; then
    echo "error: $MONOREPO_SPEC not found" >&2
    echo "Set MYME_REPO_ROOT to the monorepo checkout (default: ../myme)." >&2
    exit 1
fi

cp "$MONOREPO_SPEC" "$LOCAL_SNAPSHOT"
echo "synced: $MONOREPO_SPEC → $LOCAL_SNAPSHOT"

swift run codegen-wire
echo "regenerated wire types"
