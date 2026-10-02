#!/usr/bin/env bash
# Pins scripts/release.sh: the next version from the tags, the manifest a
# release tags, and the one a dry run builds on.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
release="${root}/scripts/release.sh"
failed=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected $3, got $2"
    failed=1
  fi
}

repo="$(mktemp -d)"
trap 'rm -rf "${repo}"' EXIT
git -C "${repo}" init -q
cp "${root}/Package.swift" "${repo}/Package.swift"
git -C "${repo}" add Package.swift
git -C "${repo}" -c user.email=fixture@example.invalid -c user.name=Fixture -c commit.gpgsign=false \
  commit -q -m base

next() { (cd "${repo}" && "${release}" version); }
tag() { git -C "${repo}" tag "$1"; }

check "no tags start at v0.0.1" "$(next)" v0.0.1
tag pre-rebase-1245
tag 0.9.0
check "tags that are not v<x>.<y>.<z> do not count" "$(next)" v0.0.1
tag v0.0.1
check "a release adds 0.0.1" "$(next)" v0.0.2
tag v0.0.9
tag v0.0.10
check "the patch compares as a number" "$(next)" v0.0.11
tag v0.1.0
tag v0.2.0-rc.1
check "the latest counts, whatever came before; a prerelease does not" "$(next)" v0.1.1
tag v01.0.0
check "a leading zero is not a version" "$(next)" v0.1.1

url="https://github.com/withmarfa/marfa-swift/releases/download/v0.0.1/MarfaCoreFFI.xcframework.zip"
checksum="$(printf 'a%.0s' {1..64})"
rewrite() { (cd "${repo}" && "${release}" manifest "$@" 2>/dev/null) && echo rewrote || echo refused; }

check "a URL that is not https is refused" "$(rewrite "http://example.invalid/a.zip" "${checksum}")" refused
check "a checksum that is not SHA-256 is refused" "$(rewrite "${url}" abc)" refused
check "a refused rewrite leaves the manifest alone" "$(git -C "${repo}" status --porcelain)" ""
check "a well-formed release rewrites the manifest" "$(rewrite "${url}" "${checksum}")" rewrote
expected="        .binaryTarget(name: \"MarfaCoreFFI\", url: \"${url}\", checksum: \"${checksum}\"),"
check "the binary target names the release asset and its checksum" \
  "$(grep -F '.binaryTarget(' "${repo}/Package.swift")" "${expected}"
check "only the binary target changes" \
  "$(git -C "${repo}" diff --numstat -- Package.swift)" "$(printf '1\t1\tPackage.swift')"
check "a manifest already rewritten is refused" "$(rewrite "${url}" "${checksum}")" refused

git -C "${repo}" checkout -q -- Package.swift
zip=MarfaCoreFFI.xcframework.zip
local_zip() { (cd "${repo}" && "${release}" archive "$1" 2>/dev/null) && echo rewrote || echo refused; }
check "a zip that is not there is refused" "$(local_zip "${zip}")" refused
touch "${repo}/${zip}"
check "a zip outside the package is refused" "$(local_zip "${repo}/${zip}")" refused
check "a zip in the package rewrites the manifest" "$(local_zip "${zip}")" rewrote
check "the binary target names the zip" \
  "$(grep -F '.binaryTarget(' "${repo}/Package.swift")" "        .binaryTarget(name: \"MarfaCoreFFI\", path: \"${zip}\"),"
check "only the binary target changes for a zip" \
  "$(git -C "${repo}" diff --numstat -- Package.swift)" "$(printf '1\t1\tPackage.swift')"

exit "${failed}"
