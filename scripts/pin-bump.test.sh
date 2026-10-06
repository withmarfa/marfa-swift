#!/usr/bin/env bash
# Pins scripts/pin-bump.sh: when a scheduled run moves the pin and when it leaves it.
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

check "a new, green main with nothing open is bumped" "$(decide "${old}" "${new}" success 0)" bump
check "a pin that is main already stays" "$(decide "${new}" "${new}" success 0)" "skip: the pin is marfa's main already"
check "an open pull request that moves the pin is left to be settled" "$(decide "${old}" "${new}" success 1)" \
  "skip: a pull request that moves the pin is open"
check "a red main is not bumped to" "$(decide "${old}" "${new}" failure 0)" "skip: marfa's main is not green"
check "a cancelled run is not green" "$(decide "${old}" "${new}" cancelled 0)" "skip: marfa's main is not green"
check "a run still going waits for the next day" "$(decide "${old}" "${new}" pending 0)" \
  "skip: marfa's main has no finished run yet"
check "a main with no run waits for the next day" "$(decide "${old}" "${new}" none 0)" \
  "skip: marfa's main has no finished run yet"
check "a pin that is not a commit is refused" "$(decide main "${new}" success 0)" refused
check "a main that is not a commit is refused" "$(decide "${old}" "${new:0:39}" success 0)" refused
check "a count that is not a number is refused" "$(decide "${old}" "${new}" success many)" refused
check "a timed out run is not green" "$(decide "${old}" "${new}" timed_out 0)" "skip: marfa's main is not green"
check "a skipped run is not green" "$(decide "${old}" "${new}" skipped 0)" "skip: marfa's main is not green"
check "a state that is not a run state is refused" "$(decide "${old}" "${new}" 'not a state!' 0)" refused
check "missing arguments are refused" "$(decide "${old}" "${new}")" refused

exit "${failed}"
