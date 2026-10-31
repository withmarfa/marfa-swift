#!/usr/bin/env bash
# Pins scripts/pin-bump.sh: when a run moves the pin to marfa's newest release and when it leaves it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bump="${root}/scripts/pin-bump.sh"
failed=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected $3, got $2"
    failed=1
  fi
}

old="$(printf 'a%.0s' {1..40})"
new="$(printf 'b%.0s' {1..40})"
decide() { "${bump}" decide "$@" 2>/dev/null || echo refused; }

check "a newer release with nothing open is bumped" "$(decide "${old}" "${new}" 0)" bump
check "a pin that is the newest release already stays" "$(decide "${new}" "${new}" 0)" \
  "skip: the pin is marfa's newest release already"
check "a pin that is the newest release already stays, with a pull request open" "$(decide "${new}" "${new}" 1)" \
  "skip: the pin is marfa's newest release already"
check "an open pull request that moves the pin is left to be settled" "$(decide "${old}" "${new}" 1)" \
  "skip: a pull request that moves the pin is open"
check "several open pull requests are left to be settled" "$(decide "${old}" "${new}" 3)" \
  "skip: a pull request that moves the pin is open"
check "a pin that is not a commit is refused" "$(decide main "${new}" 0)" refused
check "a release that is not a commit is refused" "$(decide "${old}" "${new:0:39}" 0)" refused
check "a release that is a tag name is refused" "$(decide "${old}" v0.0.50 0)" refused
check "a count that is not a number is refused" "$(decide "${old}" "${new}" many)" refused
check "missing arguments are refused" "$(decide "${old}" "${new}")" refused

peel() { "${bump}" peel "$@" 2>/dev/null || echo refused; }

tag_object="$(printf 'c%.0s' {1..40})"
check "an annotated tag is peeled to its commit" \
  "$(printf '%s\trefs/tags/v1.2.3\n%s\trefs/tags/v1.2.3^{}\n' "${tag_object}" "${new}" | peel v1.2.3)" "${new}"
check "the peeled line counts wherever it comes" \
  "$(printf '%s\trefs/tags/v1.2.3^{}\n%s\trefs/tags/v1.2.3\n' "${new}" "${tag_object}" | peel v1.2.3)" "${new}"
check "a lightweight tag is its own commit" "$(printf '%s\trefs/tags/v1.2.3\n' "${new}" | peel v1.2.3)" "${new}"
check "another tag's line is not used" \
  "$(printf '%s\trefs/tags/v1.2.30\n%s\trefs/tags/v1.2.3\n' "${old}" "${new}" | peel v1.2.3)" "${new}"
check "a tag the remote does not have is refused" "$(printf '' | peel v1.2.3)" refused
check "a tag whose line is not a commit is refused" "$(printf 'nope\trefs/tags/v1.2.3\n' | peel v1.2.3)" refused

exit "${failed}"
