#!/usr/bin/env bash
# The format lint CI runs, and the one to run before a push.
#
#   scripts/lint.sh              # every rule, with the Mac's swift-format
#   scripts/lint.sh --portable   # every rule that answers the same on Linux
#
# `BeginDocumentationCommentWithOneLineSummary` splits a comment into sentences, and swift-format does
# that differently on Linux: the Linux toolchain of the same release flags 16 comments the Mac's does
# not. So the Linux job in `ci.yml`, which fails a pull request in seconds without a Mac, runs
# `--portable`, and the Mac job runs every rule. Run it without a flag before a push.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${root}"

configuration=".swift-format"
case "${1:-}" in
  "") ;;
  --portable)
    configuration="$(mktemp)"
    trap 'rm -f "${configuration}"' EXIT
    sed -E 's/("BeginDocumentationCommentWithOneLineSummary":) true/\1 false/' .swift-format >"${configuration}"
    if cmp -s .swift-format "${configuration}"; then
      echo "lint.sh: .swift-format no longer turns BeginDocumentationCommentWithOneLineSummary on, so --portable has nothing to turn off" >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: scripts/lint.sh [--portable]" >&2
    exit 2
    ;;
esac

swift format lint --strict --configuration "${configuration}" -r \
  Package.swift Sources/Marfa Sources/MarfaAPI/*.swift Sources/MarfaTesting Sources/MarfaTelemetry \
  Sources/MarfaIcons Sources/MarfaBrandIcons Tests Examples/MarfaSample/Sources \
  generator/MarfaNullValue.swift generator/MarfaNullable.swift
