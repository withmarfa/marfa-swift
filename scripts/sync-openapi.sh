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
SOURCE_RECORD="scripts/openapi-source.txt"

if [[ ! -f "$MONOREPO_SPEC" ]]; then
    echo "error: $MONOREPO_SPEC not found" >&2
    echo "Set MARFA_REPO_ROOT to the monorepo checkout (default: ../marfa)." >&2
    exit 1
fi

cp "$MONOREPO_SPEC" "$LOCAL_SNAPSHOT"
echo "synced: $MONOREPO_SPEC → $LOCAL_SNAPSHOT"

# Which monorepo commit this copy was taken at. Recorded by the script
# rather than by hand: the question a stale snapshot raises is "how far
# behind, and since when", and the answer is unrecoverable afterwards
# because a `cp` leaves no trace of where it came from. Written on a
# best-effort basis — a checkout that is not a git repository still syncs.
if commit="$(git -C "$MARFA_REPO_ROOT" rev-parse HEAD 2>/dev/null)"; then
    spec_commit="$(git -C "$MARFA_REPO_ROOT" log -1 --format=%H -- openapi.json 2>/dev/null)"
    {
        echo "# Provenance of ${LOCAL_SNAPSHOT}. Written by sync-openapi.sh; do not edit."
        echo "monorepo_head=${commit}"
        echo "spec_last_written_by=${spec_commit}"
    } > "$SOURCE_RECORD"
    echo "recorded: $SOURCE_RECORD (monorepo ${commit})"
else
    echo "warning: $MARFA_REPO_ROOT is not a git checkout; $SOURCE_RECORD left unchanged" >&2
fi

swift run codegen-wire
echo "regenerated wire types"
