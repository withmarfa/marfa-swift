#!/usr/bin/env bash
# Pins scripts/retried-tests.sh: which lines of a Swift Testing log name a retried test.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
retried="${root}/scripts/retried-tests.sh"
failed=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected '$3', got '$2'"
    failed=1
  fi
}

log=$'􀟈  Test run started.\n􀟈  Test fine() started.\n􀟈  Test flaky() started.\n􁁛  Test fine() passed after 0.001 seconds.\n􀢄  Test flaky() recorded an issue at T.swift:6:1: Expectation failed\n􀟈  Test flaky() started (repetition 2).\n􁁛  Test flaky() passed after 0.001 seconds.\n􀟈  Test other(_:) started (repetition 2).\n􀟈  Test other(_:) started (repetition 2).\n'

check "a repeated test is named once, sorted" "$("${retried}" <<<"${log}")" $'flaky()\nother(_:)'
check "a log with no repetition names nothing" "$("${retried}" <<<$'􀟈  Test fine() started.\n􁁛  Test fine() passed after 1 seconds.')" ""
check "an empty log names nothing" "$("${retried}" <"/dev/null")" ""
check "colored lines are read" "$("${retried}" <<<$'\x1b[1mTest colored() started (repetition 2).\x1b[0m')" "colored()"
check "a test that merely mentions a repetition is not named" \
  "$("${retried}" <<<'Note: the repetition 2 of nothing')" ""

exit "${failed}"
