#!/usr/bin/env bash
# Builds the core from the monorepo commit core.pin names and copies the
# framework and its Swift glue into this package.
#
#   scripts/core.sh                         # fetches the monorepo into .build/marfa
#   MARFA_MONOREPO=<checkout> scripts/core.sh  # a checkout already at the pin
#
# Needs the Rust toolchain and cargo-swift, which the monorepo's build.sh
# installs when it is missing.
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
cp "${built}/Sources/MarfaCore/MarfaCore.swift" "${root}/Sources/MarfaCore/MarfaCore.swift"
