#!/usr/bin/env bash
# Pins scripts/test-verdict.sh on hand-written event streams.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
verdict="${root}/scripts/test-verdict.sh"
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

event() { # kind test iteration [known]
  local issue=''
  [[ "$1" == issueRecorded ]] && issue=",\"issue\":{\"isFailure\":true,\"isKnown\":${4:-false}}"
  local id=''
  [[ -n "$2" ]] && id=",\"testID\":\"$2\""
  echo "{\"kind\":\"event\",\"payload\":{\"kind\":\"$1\",\"iteration\":$3${id}${issue}}}"
}

run() { # prints the output and the exit status of the verdict on stdin's stream
  local out status=0
  out="$("${verdict}" "$1")" || status=$?
  echo "${out}|${status}"
}

a='M.S/a()/F.swift:1:1'
b='M.S/b(_:)/F.swift:2:1'

{ event runStarted '' 1; event testCaseStarted "$a" 1; event testCaseEnded "$a" 1; event runEnded '' 1; } >"${dir}/pass"
check "a passing run is clean" "$(run "${dir}/pass")" "|0"

{
  event runStarted '' 1
  event testCaseStarted "$a" 1; event issueRecorded "$a" 1; event testCaseEnded "$a" 1
  event testCaseStarted "$a" 2; event testCaseEnded "$a" 2
  event runEnded '' 2
} >"${dir}/flaky"
check "a test that failed then passed is flaky and does not fail the run" "$(run "${dir}/flaky")" "flaky M.S/a()|0"

{
  event runStarted '' 1
  event testCaseStarted "$a" 1; event issueRecorded "$a" 1; event testCaseEnded "$a" 1
  event testCaseStarted "$a" 2; event issueRecorded "$a" 2; event testCaseEnded "$a" 2
  event runEnded '' 2
} >"${dir}/both"
check "a test that failed twice fails the run" "$(run "${dir}/both")" "failed M.S/a()|1"

{
  event runStarted '' 1
  event testCaseStarted "$a" 1; event issueRecorded "$a" 1; event testCaseEnded "$a" 1
  event testCaseStarted "$a" 2; event testCaseEnded "$a" 2
  event testCaseStarted "$b" 1; event issueRecorded "$b" 1; event issueRecorded "$b" 2; event testCaseEnded "$b" 1
  event runEnded '' 2
} >"${dir}/mixed"
check "one flaky and one failed test are both named" "$(run "${dir}/mixed")" $'failed M.S/b(_:)\nflaky M.S/a()|1'

{ event runStarted '' 1; event issueRecorded "$a" 1 true; event runEnded '' 1; } >"${dir}/known"
check "a known issue is not a failure" "$(run "${dir}/known")" "|0"

{ event runStarted '' 1; event issueRecorded '' 1; event runEnded '' 1; } >"${dir}/outside"
check "a failure outside any test fails the run" "$(run "${dir}/outside")" "failed (outside a test)|1"

{ event runStarted '' 1; event testCaseStarted "$a" 1; } >"${dir}/crash"
check "a run that never ends fails" "$(run "${dir}/crash")" "failed (the run did not end)|1"

: >"${dir}/empty"
check "an empty stream fails" "$(run "${dir}/empty")" "failed (the run did not end)|1"
check "a missing stream fails" "$(run "${dir}/none")" "failed (no event stream was written)|1"

exit "${failed}"
