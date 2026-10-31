#!/usr/bin/env bash
# Reports a pin bump that failed, which means the package no longer builds against marfa's
# newest release. The `report-failure` job of .github/workflows/pin-bump.yml runs this.
#
# One issue stays open, titled "Nightly failed: <workflow>", the title withmarfa/marfa's scheduled
# workflows use. The first failure opens it and each failure after that comments on it, so a
# pin that stays broken for a week is one issue and not seven.
#
# Every `gh` call must succeed: a report that cannot be made fails the job, which shows in the run,
# instead of passing with nothing reported. Only the compiler lines are best effort.
#
#   GH_TOKEN, GITHUB_REPOSITORY, GITHUB_WORKFLOW, GITHUB_RUN_ID and GITHUB_SHA come from the run.
#   MARFA_RELEASE is the marfa release that the bump built against, as `<tag> (<commit>)`.
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is not set}"
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}
workflow=${GITHUB_WORKFLOW:?GITHUB_WORKFLOW is not set}
run_id=${GITHUB_RUN_ID:?GITHUB_RUN_ID is not set}
sha=${GITHUB_SHA:?GITHUB_SHA is not set}
marfa_release=${MARFA_RELEASE:?MARFA_RELEASE is not set}
run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${run_id}"
title="Nightly failed: ${workflow}"

failed=$(
  gh run view "${run_id}" --repo "${repo}" --json jobs |
    jq -r '[.jobs[] | select(.conclusion == "failure") | "- " + .name] | join("\n")'
)
if [[ -z "${failed}" ]]; then
  failed="- None ended as failed. A job may have been cancelled or timed out."
fi

# The first compiler errors, without the runner's timestamps and color codes. The log may not be
# readable yet while the run is going, and the report is worth making without it.
errors=$(
  { gh run view "${run_id}" --repo "${repo}" --log-failed 2>/dev/null || true; } |
    cut -f3- | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g; s/^[0-9TZ:.-]+ //' |
    { grep -E ': error: ' || true; } | sort -u | head -5
)
if [[ -z "${errors}" ]]; then
  errors="No compiler error was found in the log."
fi

# The search matches words, not the whole title, so only an exact title counts.
open=$(
  gh issue list --repo "${repo}" --state open --limit 100 \
    --search "\"${title}\" in:title" --json number,title |
    jq -r --arg title "${title}" '[.[] | select(.title == $title)][0].number // empty'
)

if [[ -n "${open}" ]]; then
  gh issue comment "${open}" --repo "${repo}" --body "The run failed again: ${run_url}

marfa release: \`${marfa_release}\`

Failed jobs:

${failed}

First errors:

\`\`\`
${errors}
\`\`\`"
  echo "Commented on issue ${open}."
  exit 0
fi

body=$(mktemp)
trap 'rm -f "${body}"' EXIT
cat >"${body}" <<EOF2
## Summary

The ${workflow} run failed. Most often the hand-written package no longer compiles against the new core, so no pull request was opened and \`core.pin\` stays where it is.

## Context

- Run: ${run_url}
- marfa release it built against: \`${marfa_release}\`
- Commit of this repository: \`${sha}\`
- Failed jobs:

${failed}

First errors:

\`\`\`
${errors}
\`\`\`

## Acceptance criteria

- The package builds against the new core and the run passes, or the run is changed to cope with whatever broke it.

## Out of scope

- Jobs that passed in this run.

## Notes

This issue was opened by the workflow. Each later failure of the run comments here until the issue is closed.
EOF2

gh issue create --repo "${repo}" --title "${title}" --label needs-triage --body-file "${body}"
