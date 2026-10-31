#!/usr/bin/env bash
# Names the tests that `swift test --repeat-until pass --maximum-repetitions 2` ran a second time, one per
# line, sorted, from the log on standard input. A test that failed once and passed on the repetition is
# flaky, and CI reports it where it would otherwise pass unseen. A test that failed both times is named
# here too, and fails the run on its own.
#
#   scripts/retried-tests.sh < swift-test.log
set -euo pipefail

sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' |
  sed -nE 's/^.*Test (.+) started \(repetition [0-9]+\)\.?[[:space:]]*$/\1/p' |
  sort -u
