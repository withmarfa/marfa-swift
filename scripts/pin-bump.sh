#!/usr/bin/env bash
# The decision of .github/workflows/pin-bump.yml, kept here so a test can pin it.
#
#   scripts/pin-bump.sh decide <current-pin> <release-commit> <open-bumps>
#   scripts/pin-bump.sh peel <tag> < `git ls-remote` output
#
# <release-commit> is the commit that the tag of marfa's newest published release
# (not a draft, not a prerelease) points at. A published release has already passed
# marfa's release workflow, so the decision checks nothing else about it.
# <open-bumps> is how many open pull requests change `core.pin`.
# `decide` prints `bump`, or `skip: <reason>` where the pin stays as it is.
#
# `peel` reads the `git ls-remote` lines for `refs/tags/<tag>` and `refs/tags/<tag>^{}` and
# prints the commit the tag points at: the peeled line when the tag is annotated, the tag's
# own line when it is a lightweight tag.
set -euo pipefail

sha='^[0-9a-f]{40}$'

decide() {
  local current="$1" release="$2" open="$3"
  if [[ ! "${current}" =~ ${sha} ]]; then
    echo "pin-bump.sh: '${current}' is not a commit" >&2
    exit 1
  fi
  if [[ ! "${release}" =~ ${sha} ]]; then
    echo "pin-bump.sh: '${release}' is not a commit" >&2
    exit 1
  fi
  if [[ ! "${open}" =~ ^[0-9]+$ ]]; then
    echo "pin-bump.sh: '${open}' is not a count" >&2
    exit 1
  fi
  if [[ "${current}" == "${release}" ]]; then
    echo "skip: the pin is marfa's newest release already"
  elif ((open > 0)); then
    echo "skip: a pull request that moves the pin is open"
  else
    echo bump
  fi
}

peel() {
  local tag="$1" lines commit
  lines="$(cat)"
  commit="$(awk -v ref="refs/tags/${tag}^{}" '$2 == ref { print $1 }' <<<"${lines}")"
  if [[ -z "${commit}" ]]; then
    commit="$(awk -v ref="refs/tags/${tag}" '$2 == ref { print $1 }' <<<"${lines}")"
  fi
  if [[ ! "${commit}" =~ ${sha} ]]; then
    echo "pin-bump.sh: the tag '${tag}' does not name a commit" >&2
    exit 1
  fi
  echo "${commit}"
}

case "${1:-}" in
  decide) decide "${2:?}" "${3:?}" "${4:?}" ;;
  peel) peel "${2:?}" ;;
  *)
    echo "usage: scripts/pin-bump.sh decide <current-pin> <release-commit> <open-bumps>" >&2
    echo "       scripts/pin-bump.sh peel <tag> < ls-remote-output" >&2
    exit 2
    ;;
esac
