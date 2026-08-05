#!/usr/bin/env bash
# sync-types.sh — copies core type and edge type schemas from the sibling
# marfa monorepo into scripts/MarfaCodegenCore/core-types/ (vendored snapshot
# used by codegen-domain and bundled as a resource by the MarfaCodegenCore
# library for custom-type codegen parent-chain resolution).
# Run from the swift-sdk repo root: ./scripts/sync-types.sh
set -euo pipefail

MARFA_TYPES="${1:-../marfa/packages/types/core}"
DEST="$(dirname "$0")/MarfaCodegenCore/core-types"

if [[ ! -d "$MARFA_TYPES" ]]; then
  echo "error: marfa types directory not found at $MARFA_TYPES" >&2
  echo "usage: $0 [path/to/marfa/packages/types/core]" >&2
  exit 1
fi

echo "syncing types from $MARFA_TYPES → $DEST"
# Remove before copying so a type deleted upstream disappears from the
# snapshot too — a bare copy carries deletions never and stale structs
# survive every regen.
rm -f "$DEST"/*.json
cp "$MARFA_TYPES"/*.json "$DEST/"
mkdir -p "$DEST/edges"
cp "$MARFA_TYPES/edges"/*.json "$DEST/edges/"
echo "synced $(ls "$DEST"/*.json | wc -l | tr -d ' ') type files and $(ls "$DEST/edges"/*.json | wc -l | tr -d ' ') edge type files"

echo "regenerating domain models…"
swift run codegen-domain
echo "done"
