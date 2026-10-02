#!/usr/bin/env bash
# The steps of .github/workflows/release.yml that hold logic.
#
#   scripts/release.sh version                    # the next tag: the latest v<x>.<y>.<z> plus 0.0.1
#   scripts/release.sh manifest <url> <checksum>  # points Package.swift's binary target at a release
#   scripts/release.sh consumer <dependency>      # builds and runs an app on the package, without Rust
#
# Each acts on the repository in the current directory.
# `scripts/release.test.sh` pins the first two.
set -euo pipefail

version() {
  local latest
  latest="$(git tag --list 'v*' |
    grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' |
    sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 || true)"
  if [[ -z "${latest}" ]]; then
    echo v0.0.1
    return
  fi
  local major minor patch
  IFS=. read -r major minor patch <<<"${latest}"
  echo "v${major}.${minor}.$((patch + 1))"
}

manifest() {
  local url="$1" checksum="$2" file=Package.swift
  if [[ ! "${url}" =~ ^https://[^[:space:]\"]+\.zip$ ]]; then
    echo "release.sh: '${url}' is not an https URL of a zip" >&2
    exit 1
  fi
  if [[ ! "${checksum}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "release.sh: '${checksum}' is not a SHA-256 checksum" >&2
    exit 1
  fi
  local local_target='.binaryTarget(name: "MarfaCoreFFI", path: "Frameworks/MarfaCoreFFI.xcframework"),'
  local count
  count="$(grep -cF "${local_target}" "${file}" || true)"
  if [[ "${count}" != 1 ]]; then
    echo "release.sh: Package.swift declares the local binary target ${count} times, not once" >&2
    exit 1
  fi
  local rewritten
  rewritten="$(mktemp)"
  awk -v from="${local_target}" \
    -v to=".binaryTarget(name: \"MarfaCoreFFI\", url: \"${url}\", checksum: \"${checksum}\")," '
    { i = index($0, from) }
    i { $0 = substr($0, 1, i - 1) to substr($0, i + length(from)) }
    { print }' "${file}" >"${rewritten}"
  mv "${rewritten}" "${file}"
}

# Builds a package that depends on Marfa through <dependency>, such as
# `.package(url: "https://github.com/withmarfa/marfa-swift", exact: "0.0.1")`,
# for macOS and the iOS simulator, and runs it on the Mac, with no Rust
# toolchain on the PATH.
consumer() {
  local dependency="$1" dir path="" entry
  dir="$(mktemp -d)"
  local IFS=:
  for entry in ${PATH}; do
    [[ -x "${entry}/cargo" || -x "${entry}/rustc" || -x "${entry}/rustup" ]] && continue
    path="${path:+${path}:}${entry}"
  done
  unset IFS
  export PATH="${path}"
  if command -v cargo rustc rustup >/dev/null; then
    echo "release.sh: a Rust toolchain is still on the PATH" >&2
    exit 1
  fi

  mkdir -p "${dir}/Sources/Consumer" "${dir}/Sources/Run"
  cat >"${dir}/Package.swift" <<SWIFT
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [.iOS(.v18), .macOS(.v15)],
    dependencies: [${dependency}],
    targets: [
        .target(
            name: "Consumer",
            dependencies: [
                .product(name: "Marfa", package: "marfa-swift"),
                .product(name: "MarfaTypes", package: "marfa-swift"),
            ]
        ),
        .executableTarget(name: "Run", dependencies: ["Consumer"]),
    ]
)
SWIFT
  cat >"${dir}/Sources/Consumer/Consumer.swift" <<'SWIFT'
import Foundation
import Marfa
import MarfaTypes

public func check(store: URL) async throws -> String {
    let copy = try await WorkingCopy.open(store: store)
    let status = try await copy.status()
    await copy.close()
    return "contract \(marfaContractVersion), \(status)"
}
SWIFT
  cat >"${dir}/Sources/Run/main.swift" <<'SWIFT'
import Consumer
import Foundation

let store = URL(fileURLWithPath: CommandLine.arguments[1])
print(try await check(store: store))
SWIFT

  (
    cd "${dir}"
    swift build
    "$(swift build --show-bin-path)/Run" "${dir}/store.sqlite"
    # The core has arm64 slices only, as an app's simulator build must too.
    xcodebuild -quiet -scheme Consumer -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "${dir}/derived" EXCLUDED_ARCHS=x86_64 build
  )
  rm -rf "${dir}"
}

case "${1:-}" in
  version) version ;;
  manifest) manifest "$2" "$3" ;;
  consumer) consumer "$2" ;;
  *)
    echo "usage: scripts/release.sh version | manifest <url> <checksum> | consumer <dependency>" >&2
    exit 2
    ;;
esac
