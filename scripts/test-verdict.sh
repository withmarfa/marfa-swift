#!/usr/bin/env bash
# Decides which tests failed and which were flaky, from the event stream that
# `swift test --repeat-until pass --maximum-repetitions 2 --event-stream-output-path <file>` writes.
# The exit status of `swift test` cannot decide this: it is 1 when any repetition failed, even when
# the test passed on the next one.
#
# A test fails when its last repetition recorded a failure. It is flaky when an earlier repetition
# failed and the last did not. A failure recorded outside any test, or a stream that never reaches
# the end of the run (a crash), fails the run too.
#
# Prints `failed <test>` and `flaky <test>` lines, sorted, and exits 1 when anything failed.
#
#   scripts/test-verdict.sh events.jsonl
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <event-stream.jsonl>" >&2; exit 2; }
[[ -r "$1" ]] || { echo "failed (no event stream was written)"; exit 1; }

verdict="$(jq -rs '
  [.[] | select(.kind == "event") | .payload] as $events
  | if ($events | any(.kind == "runEnded")) | not then "failed (the run did not end)"
    else
      def failure: .kind == "issueRecorded" and .issue.isFailure and (.issue.isKnown | not);
      def name: (.testID // "(outside a test)") | sub("/[^/]*:[0-9]+:[0-9]+$"; "");
      [ $events | map(select(failure or .kind == "testCaseStarted" or .kind == "testCaseEnded"))
        | group_by(.testID)[]
        | (map(.iteration // 1) | max) as $last
        | (map(select(failure)) ) as $failures
        | ($failures | map(select((.iteration // 1) == $last)) | length) as $final
        | ($failures | map(select((.iteration // 1) < $last)) | length) as $earlier
        | if $final > 0 then "failed \(.[0] | name)"
          elif $earlier > 0 then "flaky \(.[0] | name)"
          else empty end
      ] | unique | .[]
    end
' "$1")"

[[ -z "${verdict}" ]] || echo "${verdict}"
if grep -q '^failed' <<<"${verdict}"; then exit 1; fi
