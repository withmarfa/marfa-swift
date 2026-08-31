#!/usr/bin/env bash
#
# Writes the current public surface of MarfaSDK.
#
#   ./scripts/public-surface.sh                     # → scripts/public-surface.txt
#   ./scripts/public-surface.sh /tmp/current.txt    # → somewhere else
#
# Run it with no argument at a release cut, after the Unreleased section has
# been renamed to the version being cut, and commit the result. CI runs it with
# an argument and compares the result against the committed file.
#
# `swift package dump-symbol-graph` builds the package, so this is not cheap on
# a cold tree and is close to free on a warm one.

set -euo pipefail

cd "$(dirname "$0")/.."

out="${1:-scripts/public-surface.txt}"

# `dump-symbol-graph` emits for every module in the package, the test module
# included, and fails outright when one of them has not been built. So a plain
# `swift build` beforehand is not enough — it leaves the test module absent and
# the extraction dies naming a module nobody asked about.
echo "→ Building, tests included, so every module can be extracted"
swift build --build-tests >/dev/null

echo "→ Extracting the public symbol graph"
swift package dump-symbol-graph --minimum-access-level public >/dev/null

# SwiftPM writes the graph under the build directory for the host triple. Ask
# rather than guess: the path carries the architecture, and hard-coding one
# means this works on the machine it was written on and nowhere else.
build_dir="$(swift build --show-bin-path)"
graph_dir="$(dirname "${build_dir}")/symbolgraph"

if [ ! -d "${graph_dir}" ]; then
  echo "✗ No symbol graph at ${graph_dir} after extraction." >&2
  echo "  The extraction reported success and produced nothing, which would" >&2
  echo "  otherwise write an empty baseline that accepts every change." >&2
  exit 1
fi

echo "→ Distilling the public surface"
swift run --quiet public-surface emit "${graph_dir}" "${out}"
