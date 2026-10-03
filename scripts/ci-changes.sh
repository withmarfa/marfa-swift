#!/usr/bin/env bash
# Whether a pull request's changes can affect `Build + test`.
#
#   scripts/ci-changes.sh     # in CI: writes validate=true|false to GITHUB_OUTPUT
#   scripts/ci-changes.sh -   # prints the answer for NUL-separated paths on stdin
#
# A skipped job satisfies a required check, where a workflow filtered out by
# `paths` would leave it pending. A push, an empty diff and one that cannot
# be read all answer true, and so does a draft (DRAFT=true): it runs the job
# only to lint and then fail, so that the skip of everything after does not
# let it merge before the first full run. `scripts/ci-changes.test.sh` pins
# the rules.
set -euo pipefail

# Whether one changed path can affect the job. A path no rule names can.
affects() {
  case "$1" in
    scripts/ci-changes.sh | .github/workflows/ci.yml) return 0 ;;
    .github/*) return 1 ;;
    # A fixture is test input, whatever its extension.
    fixtures/* | */fixtures/*) return 0 ;;
    # Nothing builds, tests or lints Markdown, wherever it is.
    *.md | LICENSE | .claude/*) return 1 ;;
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

if [[ "${1:-}" == - ]]; then
  answer
  exit
fi

validate=true
if [[ "${GITHUB_EVENT_NAME:-}" == pull_request ]]; then
  list="$(mktemp)"
  trap 'rm -f "${list}"' EXIT
  if [[ "${BASE:-}" =~ ^[0-9a-f]{40}$ && "${HEAD:-}" =~ ^[0-9a-f]{40}$ ]] &&
    git diff --name-only --no-renames -z "${BASE}...${HEAD}" -- >"${list}"; then
    validate="$(answer <"${list}")"
  else
    echo "Could not classify the change; running the job."
  fi
fi
if [[ "${DRAFT:-}" == true ]]; then validate=true; fi
echo "validate=${validate}"
echo "validate=${validate}" >>"${GITHUB_OUTPUT:-/dev/null}"
