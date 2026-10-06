#!/usr/bin/env bash
# The decision of .github/workflows/pin-bump.yml, kept here so a test can pin it.
#
#   scripts/pin-bump.sh decide <current-pin> <marfa-main> <marfa-ci> <open-bumps>
#
# <marfa-ci> is the state of marfa's `ci.yml` push run on <marfa-main>:
# pending (queued or running), none, or the conclusion of a finished run, where
# only `success` is green.
# <open-bumps> is how many open pull requests change `core.pin`.
# Prints `bump`, or `skip: <reason>` where the pin stays as it is.
set -euo pipefail

decide() {
  local current="$1" head="$2" ci="$3" open="$4"
  local sha='^[0-9a-f]{40}$'
  if [[ ! "${current}" =~ ${sha} ]]; then
    echo "pin-bump.sh: '${current}' is not a commit" >&2
    exit 1
  fi
  if [[ ! "${head}" =~ ${sha} ]]; then
    echo "pin-bump.sh: '${head}' is not a commit" >&2
    exit 1
  fi
  if [[ ! "${ci}" =~ ^[a-z_]+$ ]]; then
    echo "pin-bump.sh: '${ci}' is not a run state" >&2
    exit 1
  fi
  if [[ ! "${open}" =~ ^[0-9]+$ ]]; then
    echo "pin-bump.sh: '${open}' is not a count" >&2
    exit 1
  fi
  if [[ "${current}" == "${head}" ]]; then
    echo "skip: the pin is marfa's main already"
  elif ((open > 0)); then
    echo "skip: a pull request that moves the pin is open"
  else
    case "${ci}" in
      success) echo bump ;;
      pending | none) echo "skip: marfa's main has no finished run yet" ;;
      *) echo "skip: marfa's main is not green" ;;
    esac
  fi
}

case "${1:-}" in
  decide) decide "${2:?}" "${3:?}" "${4:?}" "${5:?}" ;;
  *)
    echo "usage: scripts/pin-bump.sh decide <current-pin> <marfa-main> <marfa-ci> <open-bumps>" >&2
    exit 2
    ;;
esac
