#!/usr/bin/env bash
# Pins scripts/release-archive.sh on hand-written tag lists and a hand-made archive.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="${root}/scripts/release-archive.sh"
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
failed=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected '$3', got '$2'"
    failed=1
  fi
}

run() { # prints the output and the exit status of the script
  local out status=0
  out="$("$@" 2>&1)" || status=$?
  echo "${out}|${status}"
}

sha=e5d5264ce1a26ab2ced1ef3396576b4b9b14192f
other=0000000000000000000000000000000000000001

printf '%s\trefs/tags/v0.0.75\n%s\trefs/tags/v0.0.76\n' "${other}" "${sha}" >"${dir}/light"
check "a lightweight tag at the pin is the release" "$(run "${script}" --tag "${sha}" <"${dir}/light")" "v0.0.76|0"

printf '%s\trefs/tags/v0.0.76\n%s\trefs/tags/v0.0.76^{}\n' "${other}" "${sha}" >"${dir}/annotated"
check "an annotated tag is read through its peeled line" "$(run "${script}" --tag "${sha}" <"${dir}/annotated")" "v0.0.76|0"

printf '%s\trefs/tags/v0.0.76\n%s\trefs/tags/nightly\n' "${sha}" "${sha}" >"${dir}/named"
check "a tag that is not a version is not a release" "$(run "${script}" --tag "${sha}" <"${dir}/named")" "v0.0.76|0"

printf '%s\trefs/tags/v0.0.75\n' "${other}" >"${dir}/none"
check "no tag at the pin fails" "$(run "${script}" --tag "${sha}" <"${dir}/none")" \
  "release-archive: no release tag points at ${sha}|1"

printf '%s\trefs/tags/v0.0.76\n%s\trefs/tags/v0.0.77\n' "${sha}" "${sha}" >"${dir}/two"
check "two release tags at the pin fail" "$(run "${script}" --tag "${sha}" <"${dir}/two" | head -n 1)" \
  "release-archive: more than one release tag points at ${sha}:"

printf 'bytes' >"${dir}/marfa-0.0.1-darwin-arm64.tar.gz"
digest="$(shasum -a 256 "${dir}/marfa-0.0.1-darwin-arm64.tar.gz" | cut -d' ' -f1)"
printf '%s  marfa-0.0.1-darwin-arm64.tar.gz\n%s  marfa-0.0.1-linux-x86_64.tar.gz\n' "${digest}" "${other}" >"${dir}/sums"
check "an archive that matches its line passes" "$(run "${script}" --check "${dir}/marfa-0.0.1-darwin-arm64.tar.gz" "${dir}/sums")" "|0"

printf 'changed' >"${dir}/marfa-0.0.1-darwin-arm64.tar.gz"
check "an archive that differs from its line fails" \
  "$(run "${script}" --check "${dir}/marfa-0.0.1-darwin-arm64.tar.gz" "${dir}/sums")" \
  "release-archive: marfa-0.0.1-darwin-arm64.tar.gz does not match its checksum|1"

printf '%s  marfa-0.0.1-linux-x86_64.tar.gz\n' "${other}" >"${dir}/sums-other"
check "an archive with no line fails" \
  "$(run "${script}" --check "${dir}/marfa-0.0.1-darwin-arm64.tar.gz" "${dir}/sums-other" | sed "s#${dir}/##")" \
  "release-archive: sums-other has no line for marfa-0.0.1-darwin-arm64.tar.gz|1"

exit "${failed}"
