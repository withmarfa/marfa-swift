#!/usr/bin/env bash
# sync-types.sh — copies core type and edge type schemas from the sibling
# myme monorepo into scripts/MymeCodegenCore/core-types/ (vendored snapshot
# used by codegen-domain and bundled as a resource by the MymeCodegenCore
# library for custom-type codegen parent-chain resolution).
# Run from the swift-sdk repo root: ./scripts/sync-types.sh
set -euo pipefail

MYME_TYPES="${1:-../myme/packages/types/core}"
DEST="$(dirname "$0")/MymeCodegenCore/core-types"

if [[ ! -d "$MYME_TYPES" ]]; then
  echo "error: myme types directory not found at $MYME_TYPES" >&2
  echo "usage: $0 [path/to/myme/packages/types/core]" >&2
  exit 1
fi

echo "syncing types from $MYME_TYPES → $DEST"
cp "$MYME_TYPES"/*.json "$DEST/"
mkdir -p "$DEST/edges"
cp "$MYME_TYPES/edges"/*.json "$DEST/edges/"
echo "synced $(ls "$DEST"/*.json | wc -l | tr -d ' ') type files and $(ls "$DEST/edges"/*.json | wc -l | tr -d ' ') edge type files"

echo "regenerating domain models…"
swift run codegen-domain
echo "done"
