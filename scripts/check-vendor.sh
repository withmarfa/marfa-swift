#!/usr/bin/env bash
# Fails when shipped code names the analytics vendor or carries its project key,
# in a file's path or its text. A vendor SDK in Package.swift, Package.resolved
# or a project file is found the same way, by its name.
#
#   scripts/check-vendor.sh [directory]   # a Git checkout; the default is this one
#
# Documentation and instructions for agents are not shipped code. The
# exceptions are the exact paths in scripts/vendor-allowlist.txt
# (VENDOR_ALLOWLIST names another), each with its reason; a listed path that no
# longer exists fails, so the list cannot go stale.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "${1:-${here}/..}" && pwd)"
allowlist="${VENDOR_ALLOWLIST:-${here}/vendor-allowlist.txt}"

# Assembled, so this file does not hold the names it looks for.
pattern="post""hog|phc""_"

declare -a allowed=()
while IFS=$'\t' read -r path _; do
  [[ -z "${path}" || "${path}" == '#'* ]] && continue
  allowed+=("${path}")
done <"${allowlist}"

is_allowed() {
  local path
  for path in "${allowed[@]+"${allowed[@]}"}"; do
    [[ "${path}" == "$1" ]] && return 0
  done
  return 1
}

# Whether a path is documentation or instructions, which are not shipped code.
documentation() {
  case "$1" in
    *.md | LICENSE | .claude/* | .codex/* | .githooks/* | .github/ISSUE_TEMPLATE/*) return 0 ;;
    *) return 1 ;;
  esac
}

# The files whose path or text holds the vendor, NUL-separated: the path of any
# file that is in the tree and not ignored, and, through Git's own search, the
# text of each text file, and a symlink's target, which Git's search does not read.
vendor_paths() {
  git -C "${root}" ls-files -z --cached --others --exclude-standard | { grep -ziE -- "${pattern}" || true; }
  git -C "${root}" grep -I -l -i -z -E --untracked -e "${pattern}" || true
  local path
  while IFS= read -r -d '' path; do
    if [[ -L "${root}/${path}" ]] && readlink "${root}/${path}" | grep -qiE -- "${pattern}"; then
      printf '%s\0' "${path}"
    fi
  done < <(git -C "${root}" ls-files -z --cached --others --exclude-standard)
}

declare -a found=() stale=()
while IFS= read -r -d '' path; do
  documentation "${path}" && continue
  is_allowed "${path}" && continue
  [[ "${root}/${path}" == "${allowlist}" ]] && continue
  found+=("${path}")
done < <(vendor_paths | sort -zu)

for path in "${allowed[@]+"${allowed[@]}"}"; do
  [[ -e "${root}/${path}" || -L "${root}/${path}" ]] || stale+=("${path}")
done

status=0
for path in "${found[@]+"${found[@]}"}"; do
  echo "::error file=${path}::Shipped code names the analytics vendor. Marfa sends nothing about itself until its owner sets where." >&2
  echo "vendor: ${path}" >&2
  status=1
done
for path in "${stale[@]+"${stale[@]}"}"; do
  echo "::error file=${path}::Listed in ${allowlist##*/} but not in the tree: remove the entry." >&2
  echo "stale allowlist entry: ${path}" >&2
  status=1
done
exit "${status}"
