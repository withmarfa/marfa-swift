#!/usr/bin/env bash
# Whether a change can affect `Build + test`.
#
#   scripts/ci-changes.sh     # in CI: writes validate=true|false to GITHUB_OUTPUT
#   scripts/ci-changes.sh -   # prints the answer for NUL-separated paths on stdin
#
# A skipped job satisfies a required check, where a workflow filtered out by
# `paths` would leave it pending. A pull request is classified by its diff
# against its base, and a push to main by its diff against the commit it
# follows, but only when that commit had a green run of `ci.yml`: otherwise a
# commit that touches nothing the job reads would show green on top of a
# commit that was never checked or was red. An empty diff, one that cannot be
# read, a push that is not a fast-forward, a schedule and a manual run all
# answer true, and so does a draft (DRAFT=true): it runs the job only to lint
# and then fail, so that the skip of everything after does not let it merge
# before the first full run. `scripts/ci-changes.test.sh` pins the rules.
set -euo pipefail

# Whether one changed path can affect the job. A path no rule names can.
affects() {
  case "$1" in
    # A change to a workflow or to this classifier runs everything.
    scripts/ci-changes.sh | .github/workflows/*) return 0 ;;
    .github/*) return 1 ;;
    # A fixture is test input, whatever its extension.
    fixtures/* | */fixtures/*) return 0 ;;
    # Nothing builds, tests or lints Markdown, wherever it is, or the
    # instructions for agents, in whatever format.
    *.md | LICENSE | .claude/* | .agents/* | .codex/* | .githooks/*) return 1 ;;
    *) return 0 ;;
  esac
}

# Reads NUL-separated paths and prints true when any can affect the job.
answer() {
  local path seen=false
  while IFS= read -r -d '' path; do
    seen=true
    if affects "${path}"; then
      echo true
      return
    fi
  done
  # An empty diff cannot be told apart from one that was not read.
  if [[ "${seen}" == true ]]; then echo false; else echo true; fi
}

# Whether the commit a push follows had a green run of `ci.yml` on main.
previous_green() {
  local count
  count="$(gh api "repos/${GITHUB_REPOSITORY}/actions/workflows/ci.yml/runs?head_sha=${BASE}&event=push&branch=main&status=success&per_page=1" --jq .total_count)" || return 1
  [[ "${count}" =~ ^[0-9]+$ ]] && ((count > 0))
}

# Prints the answer for the event's diff, or fails when the change cannot be
# classified safely.
classify() {
  local list
  [[ "${BASE:-}" =~ ^[0-9a-f]{40}$ && "${HEAD:-}" =~ ^[0-9a-f]{40}$ ]] || return 1
  if [[ "${GITHUB_EVENT_NAME}" == push ]]; then
    git merge-base --is-ancestor "${BASE}" "${HEAD}" || return 1
    previous_green || return 1
  fi
  list="$(mktemp)"
  if git diff --name-only --no-renames -z "${BASE}...${HEAD}" -- >"${list}"; then
    answer <"${list}"
    rm -f "${list}"
  else
    rm -f "${list}"
    return 1
  fi
}

if [[ "${1:-}" == - ]]; then
  answer
  exit
fi

validate=true
case "${GITHUB_EVENT_NAME:-}" in
  pull_request | push)
    if ! validate="$(classify)"; then
      validate=true
      echo "Could not classify the change; running the job."
    fi
    ;;
esac
if [[ "${DRAFT:-}" == true ]]; then validate=true; fi
echo "validate=${validate}"
echo "validate=${validate}" >>"${GITHUB_OUTPUT:-/dev/null}"
