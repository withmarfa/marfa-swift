#!/usr/bin/env bash
# Pins scripts/check-pr-description.sh: what counts as a description that
# follows the pull request template, and that the workflow runs it on a
# description edit without any other workflow doing so.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
checker="${root}/scripts/check-pr-description.sh"
failed=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected $3, got $2"
    failed=1
  fi
}

# verdict <body> prints "pass" or the problems the checker names, one per line.
verdict() {
  local out
  if out="$(printf '%s' "$1" | "${checker}" - 2>/dev/null)"; then
    echo pass
  else
    sed -n 's/^::error title=Pull request description:://p' <<<"${out}"
  fi
}

template='## Summary

<!-- What changed and why, in two or three plain sentences. End with "Closes #NN" when this closes an issue. -->

## Changes

-

## Testing

<!-- How this was tested: the commands or tests run and what they showed. Say what was not tested. -->

## Notes for reviewers

<!-- Trade-offs, follow-ups, and the depth of review this needs and why. -->

## Checklist

- [ ] The title is a scoped Conventional Commit.
- [ ] New behavior has a test that was seen failing first, or no test was needed and the reason is above.
- [ ] Docs, comments and the contract still say what is true after this change.
'

filled='## Summary

Requires the template. Closes #1.

## Changes

- Adds the check.

## Testing

Ran the tests.

## Notes for reviewers

Checks only.

## Checklist

- [x] The title is a scoped Conventional Commit.
- [x] New behavior has a test that was seen failing first, or no test was needed and the reason is above.
- [X] Docs, comments and the contract still say what is true after this change.
'

check "a filled description" "$(verdict "${filled}")" pass
check "Windows line endings, as the web editor saves them" \
  "$(verdict "${filled//$'\n'/$'\r\n'}")" pass
check "Notes for reviewers with nothing in it" \
  "$(verdict "${filled/Checks only./<!-- none -->}")" pass
check "another list marker for a ticked box" "$(verdict "${filled//- \[x\]/* [x]}")" pass

check "the empty template" "$(verdict "${template}")" \
  '"## Summary" has no content.
"## Changes" has no content.
"## Testing" has no content.
Checklist box not ticked: The title is a scoped Conventional Commit.
Checklist box not ticked: New behavior has a test that was seen failing first, or no test was needed and the reason is above.
Checklist box not ticked: Docs, comments and the contract still say what is true after this change.'

none='The "## Summary" heading is missing.
The "## Changes" heading is missing.
The "## Testing" heading is missing.
The "## Notes for reviewers" heading is missing.
The "## Checklist" heading is missing.'
check "an empty body" "$(verdict "")" "${none}"
check "a body with no headings" "$(verdict "Fixes the thing.")" "${none}"

for section in "Summary" "Changes" "Testing" "Notes for reviewers" "Checklist"; do
  check "a missing ${section} heading" \
    "$(verdict "${filled/"## ${section}"/"### ${section}"}")" \
    "The \"## ${section}\" heading is missing."
done

check "a heading hidden in a comment" \
  "$(verdict "${filled/"## Testing"/<!--
## Testing
-->
## Elsewhere}")" 'The "## Testing" heading is missing.'
check "a bare dash and a comment as no content" \
  "$(verdict "${filled/- Adds the check./- 
<!-- later -->}")" '"## Changes" has no content.'
check "a dash with words after it" \
  "$(verdict "${template/$'\n-\n'/$'\n- Adds the check.\n'}")" \
  "$(verdict "${template}" | grep -v 'Changes')"
check "one unticked box among ticked ones" \
  "$(verdict "${filled/- \[X\] Docs/- [ ] Docs}")" \
  'Checklist box not ticked: Docs, comments and the contract still say what is true after this change.'
check "a checklist emptied of its boxes" \
  "$(verdict "$(grep -v '^- \[' <<<"${filled}")")" '"## Checklist" has no boxes.'
check "an unclosed comment hiding the rest of the page" \
  "$(verdict "${filled/"## Notes"/"<!-- ## Notes"}")" \
  'The "## Notes for reviewers" heading is missing.
The "## Checklist" heading is missing.'

# A body is data: nothing in it runs.
marker="$(mktemp -u)"
verdict "\$(touch ${marker}) \`touch ${marker}\`
${filled}" >/dev/null
check "a body with command syntax runs nothing" "$([[ -e "${marker}" ]] && echo ran || echo clean)" clean

# The event file, as the workflow supplies it.
event="$(mktemp)"
trap 'rm -f "${event}" "${marker}"' EXIT
jq -n --arg body "${filled}" '{pull_request: {body: $body}}' >"${event}"
check "the event file with a filled body" \
  "$(GITHUB_EVENT_PATH="${event}" "${checker}" >/dev/null 2>&1 && echo pass || echo fail)" pass
jq -n '{pull_request: {body: null}}' >"${event}"
check "the event file with a null body" \
  "$(GITHUB_EVENT_PATH="${event}" "${checker}" >/dev/null 2>&1 && echo pass || echo fail)" fail

# The workflow: only this one runs on an edit, and it skips bots.
workflows="${root}/.github/workflows"
check "only the description workflow runs on an edit" \
  "$(grep -lE 'types:.*\bedited\b' "${workflows}"/*.yml | xargs -n1 basename)" pr-description.yml
check "the description job skips a bot" \
  "$(grep -c "if: \${{ github.event.pull_request.user.type != 'Bot' }}" "${workflows}/pr-description.yml")" 1

exit "${failed}"
