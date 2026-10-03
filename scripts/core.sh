#!/usr/bin/env bash
#   scripts/core.sh                              # fetches the pinned commit into .build/marfa
#   MARFA_MONOREPO=<checkout> scripts/core.sh    # a clean checkout already at the pin
#   MARFA_GENERATOR_BUILD=<dir> scripts/core.sh  # builds the generator there
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
pin="$(tr -d '[:space:]' <"${root}/core.pin")"

if [[ -n "${MARFA_MONOREPO:-}" ]]; then
  src="${MARFA_MONOREPO}"
  head="$(git -C "${src}" rev-parse HEAD)"
  if [[ "${head}" != "${pin}" ]]; then
    echo "core.sh: ${src} is at ${head}, and core.pin names ${pin}" >&2
    exit 1
  fi
  if [[ -n "$(git -C "${src}" status --porcelain)" ]]; then
    echo "core.sh: ${src} has changes on top of ${pin}" >&2
    exit 1
  fi
else
  src="${root}/.build/marfa"
  if [[ ! -d "${src}/.git" ]]; then
    git clone --quiet --no-checkout https://github.com/withmarfa/marfa.git "${src}"
  fi
  git -C "${src}" fetch --quiet origin "${pin}"
  git -C "${src}" checkout --quiet --detach "${pin}"
fi

"${src}/core/bindings/swift/build.sh"

built="${src}/core/bindings/swift/MarfaCore"
mkdir -p "${root}/Frameworks"
rm -rf "${root}/Frameworks/MarfaCoreFFI.xcframework"
cp -R "${built}/MarfaCoreFFI.xcframework" "${root}/Frameworks/"
# Emptied first, so only what the pinned commit generates is left.
rm -rf "${root}/Sources/MarfaCore"
cp -R "${built}/Sources/MarfaCore" "${root}/Sources/MarfaCore"

scratch="${MARFA_GENERATOR_BUILD:-${root}/generator/.build}"
swift build --quiet -c release --package-path "${root}/generator" --scratch-path "${scratch}" \
  --product swift-openapi-generator
node "${root}/generator/generate.mjs" \
  "${scratch}/release/swift-openapi-generator" "${src}/openapi.json" "${root}/Sources/MarfaTypes"
