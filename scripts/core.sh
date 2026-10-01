#!/usr/bin/env bash
# Builds the core from the monorepo commit core.pin names and copies the
# framework and its Swift glue into this package, then generates the wire
# types from the same commit's openapi.json.
#
#   scripts/core.sh                         # fetches the monorepo into .build/marfa
#   MARFA_MONOREPO=<checkout> scripts/core.sh  # a checkout already at the pin
#   MARFA_GENERATOR_BUILD=<dir> scripts/core.sh  # the generator built there
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
  # A change on top of the pin would build glue the pin does not generate.
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
# The glue, and the wire types below, go into an emptied directory, so that
# only what the pinned commit generates is left there.
rm -rf "${root}/Sources/MarfaCore"
cp -R "${built}/Sources/MarfaCore" "${root}/Sources/MarfaCore"

# The wire types, by the generator generator/Package.swift pins.
scratch="${MARFA_GENERATOR_BUILD:-${root}/generator/.build}"
swift build --quiet -c release --package-path "${root}/generator" --scratch-path "${scratch}" \
  --product swift-openapi-generator
types="${root}/Sources/MarfaTypes"
rm -rf "${types}"
mkdir -p "${types}"
"${scratch}/release/swift-openapi-generator" generate \
  --config "${root}/generator/openapi-generator-config.yaml" \
  --output-directory "${types}" "${src}/openapi.json"

# The contract the types describe, which the document states as a whole
# number in info.version.
contract="$(plutil -extract info.version raw -o - "${src}/openapi.json")"
if [[ ! "${contract}" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo "core.sh: openapi.json states the contract as '${contract}', not a whole number" >&2
  exit 1
fi
cat >"${types}/Contract.swift" <<SWIFT
// Generated from the pinned openapi.json by scripts/core.sh; do not edit.

/// The contract version these types describe: the document's \`info.version\`,
/// which an instance's root answers as \`contract\`.
public let marfaContractVersion = ${contract}
SWIFT
