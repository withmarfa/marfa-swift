#!/usr/bin/env bash
# Fetches the marfa release that `core.pin` names and puts its `marfa-server` and `marfa` in a directory, so
# the live tests boot the server marfa shipped and use the command line marfa shipped, not ones built here.
#
#   scripts/release-archive.sh <directory>                     # download, verify and unpack the pin's macOS archive
#   scripts/release-archive.sh --tag <sha> < ls-remote-output  # the release tag that points at <sha>
#   scripts/release-archive.sh --check <archive> <checksums>   # fails unless the archive matches its line
#
# The release is the one whose tag points at the pin. The archive is
# `marfa-<version>-darwin-arm64.tar.gz`, checked against the release's `marfa-<version>-checksums.txt` before
# anything in it is unpacked. It holds `marfa`, `marfa-server` and `NOTICES.txt`.
set -euo pipefail

repository="withmarfa/marfa"

# `git ls-remote --tags` output in, the one `v<version>` tag at <sha> out. An annotated tag lists its commit on
# the `^{}` line, and a lightweight one on its own.
tag_for() {
  local sha="$1" tags
  tags="$(awk -v sha="${sha}" '
    $1 == sha && $2 ~ /^refs\/tags\/v[0-9]/ {
      name = $2
      sub(/^refs\/tags\//, "", name)
      sub(/\^\{\}$/, "", name)
      print name
    }' | sort -u)"
  if [[ -z "${tags}" ]]; then
    echo "release-archive: no release tag points at ${sha}" >&2
    return 1
  fi
  if [[ "$(wc -l <<<"${tags}")" -ne 1 ]]; then
    echo "release-archive: more than one release tag points at ${sha}:" >&2
    echo "${tags}" >&2
    return 1
  fi
  echo "${tags}"
}

check() {
  local archive="$1" checksums="$2" name line
  name="$(basename "${archive}")"
  line="$(awk -v name="${name}" '$2 == name { print }' "${checksums}")"
  if [[ -z "${line}" ]]; then
    echo "release-archive: ${checksums} has no line for ${name}" >&2
    return 1
  fi
  (cd "$(dirname "${archive}")" && echo "${line}" | shasum -a 256 -c - >/dev/null 2>&1) || {
    echo "release-archive: ${name} does not match its checksum" >&2
    return 1
  }
}

case "${1:-}" in
  --tag)
    [[ $# -eq 2 ]] || { echo "usage: $0 --tag <sha> < ls-remote-output" >&2; exit 2; }
    tag_for "$2"
    exit
    ;;
  --check)
    [[ $# -eq 3 ]] || { echo "usage: $0 --check <archive> <checksums>" >&2; exit 2; }
    check "$2" "$3"
    exit
    ;;
esac

[[ $# -eq 1 ]] || { echo "usage: $0 <directory>" >&2; exit 2; }
destination="$1"

root="$(cd "$(dirname "$0")/.." && pwd)"
pin="$(tr -d '[:space:]' <"${root}/core.pin")"
tag="$(git ls-remote --tags "https://github.com/${repository}.git" | tag_for "${pin}")"
version="${tag#v}"
archive="marfa-${version}-darwin-arm64.tar.gz"

download="$(mktemp -d)"
trap 'rm -rf "${download}"' EXIT
gh release download "${tag}" --repo "${repository}" --dir "${download}" \
  --pattern "${archive}" --pattern "marfa-${version}-checksums.txt"
check "${download}/${archive}" "${download}/marfa-${version}-checksums.txt"

mkdir -p "${destination}"
tar -xzf "${download}/${archive}" -C "${destination}"
for program in marfa marfa-server; do
  [[ -x "${destination}/${program}" ]] || { echo "release-archive: ${archive} holds no ${program}" >&2; exit 1; }
done
echo "release-archive: ${tag} unpacked in ${destination}" >&2
