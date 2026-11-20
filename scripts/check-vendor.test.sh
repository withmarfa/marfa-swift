#!/usr/bin/env bash
# Pins scripts/check-vendor.sh on throwaway repositories.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
check_vendor="${root}/scripts/check-vendor.sh"
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
failed=0

# Assembled, so this file does not hold the names the check looks for.
name="post""hog"
key="phc""_abc"

check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected '$3', got '$2'"
    failed=1
  fi
}

# fresh <name>: an empty repository with an empty allowlist in ${dir}/<name>
fresh() {
  mkdir -p "${dir}/$1"
  git -C "${dir}/$1" init -q
  : >"${dir}/$1.allow"
}

# verdict <name>: the exit status and the paths the check names
verdict() {
  local out status=0
  out="$(VENDOR_ALLOWLIST="${dir}/$1.allow" "${check_vendor}" "${dir}/$1" 2>&1 >/dev/null | grep -E '^(vendor|stale allowlist entry):' | tr '\n' ';')" || true
  VENDOR_ALLOWLIST="${dir}/$1.allow" "${check_vendor}" "${dir}/$1" >/dev/null 2>&1 || status=$?
  echo "${status} ${out}"
}

fresh clean
echo 'let a = 1' >"${dir}/clean/a.swift"
check "shipped code that names no vendor passes" "$(verdict clean)" "0 "

fresh source
echo "// uses ${name}" >"${dir}/source/a.swift"
check "the vendor's name in a source file fails" "$(verdict source)" "1 vendor: a.swift;"

fresh upper
echo "import $(printf '%s' "${name}" | tr '[:lower:]' '[:upper:]')" >"${dir}/upper/a.swift"
echo "// P${name:1:3}H${name:5}" >"${dir}/upper/b.swift"
check "any case fails" "$(verdict upper)" "1 vendor: a.swift;vendor: b.swift;"

fresh key
echo "let key = \"${key}\"" >"${dir}/key/a.swift"
check "the vendor's project key fails" "$(verdict key)" "1 vendor: a.swift;"

fresh manifest
echo ".package(url: \"https://github.com/${name}/${name}-ios\", from: \"3.0.0\")" >"${dir}/manifest/Package.swift"
echo "{ \"identity\": \"${name}-ios\" }" >"${dir}/manifest/Package.resolved"
check "a vendor SDK in a manifest fails" "$(verdict manifest)" "1 vendor: Package.resolved;vendor: Package.swift;"

fresh pathname
mkdir -p "${dir}/pathname/Sources"
: >"${dir}/pathname/Sources/${name}.swift"
check "a file named for the vendor fails, even empty" "$(verdict pathname)" "1 vendor: Sources/${name}.swift;"

fresh docs
mkdir -p "${dir}/docs/.claude" "${dir}/docs/Docs"
echo "no ${name}" >"${dir}/docs/README.md"
echo "no ${name}" >"${dir}/docs/Docs/Deep Note.md"
echo "no ${name}" >"${dir}/docs/.claude/settings.json"
check "documentation and agent instructions are not shipped code" "$(verdict docs)" "0 "

fresh spaces
mkdir -p "${dir}/spaces/My Sources"
echo "// ${name}" >"${dir}/spaces/My Sources/a file.swift"
check "a path with spaces is read whole" "$(verdict spaces)" "1 vendor: My Sources/a file.swift;"

fresh link
ln -s "${name}-target" "${dir}/link/a"
check "a symlink's target is read" "$(verdict link)" "1 vendor: a;"

fresh allowed
echo "// ${name}" >"${dir}/allowed/Generated.swift"
printf '# a comment\nGenerated.swift\tgenerated from the server\n' >"${dir}/allowed.allow"
check "an allowlisted path passes" "$(verdict allowed)" "0 "
echo "// ${name}" >"${dir}/allowed/Other.swift"
check "a path beside it still fails" "$(verdict allowed)" "1 vendor: Other.swift;"

fresh stale
printf 'Gone.swift\tonce generated\n' >"${dir}/stale.allow"
check "an allowlisted path that is gone fails" "$(verdict stale)" "1 stale allowlist entry: Gone.swift;"

check "the repository passes its own check" "$("${check_vendor}" >/dev/null 2>&1 && echo 0 || echo 1)" "0"

exit "${failed}"
