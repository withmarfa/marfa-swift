#!/usr/bin/env bash
# Pins scripts/ci-changes.sh: which changes run `Build + test`, that the job
# reads the answer, and that only a pull request's readable diff can skip it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
classifier="${root}/scripts/ci-changes.sh"
failed=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected $3, got $2"
    failed=1
  fi
}

# runs <description> <expected> <path>...
runs() {
  local what="$1" want="$2"
  shift 2
  if (($# == 0)); then
    check "${what}" "$(: | "${classifier}" -)" "${want}"
  else
    check "${what}" "$(printf '%s\0' "$@" | "${classifier}" -)" "${want}"
  fi
}

runs "a README in a subfolder" false Examples/MarfaSample/README.md
runs "top-level documentation and the licence" false README.md AGENTS.md LICENSE
runs "a pull request template" false .github/PULL_REQUEST_TEMPLATE.md
runs "Dependabot's settings" false .github/dependabot.yml
runs "agent settings" false .claude/settings.json
runs "a Swift-only change" true Sources/Marfa/Server.swift
runs "a test" true Tests/MarfaTests/LiveTests.swift
runs "the core's pin, which is Rust" true core.pin
runs "the generated glue" true Sources/MarfaCore/MarfaCore.swift
runs "the wire types' generator" true generator/Package.resolved
runs "the sample" true Examples/MarfaSample/project.yml
runs "the workflow" true .github/workflows/ci.yml
runs "the classifier" true scripts/ci-changes.sh
runs "Markdown a test reads as a fixture" true Tests/MarfaTests/fixtures/note.md
runs "a path no rule names" true Tools/new.swift
runs "documentation beside Swift" true README.md Sources/Marfa/Server.swift
runs "an empty change" true

# The job reads the answer, and runs when the classification itself failed.
workflow="${root}/.github/workflows/ci.yml"
gate="if: \${{ !cancelled() && (needs.changes.result != 'success' || needs.changes.outputs.validate != 'false') }}"
check "Build + test reads the answer" "$(grep -cF "${gate}" "${workflow}")" 1
check "the classifier runs in CI" "$(grep -cF "run: scripts/ci-changes.sh" "${workflow}")" 1

# As CI runs it, against a repository with a documentation-only commit.
repo="$(mktemp -d)"
trap 'rm -rf "${repo}"' EXIT
git -C "${repo}" init -q
git -C "${repo}" -c user.email=fixture@example.invalid -c user.name=Fixture -c commit.gpgsign=false \
  commit -q --allow-empty -m base
base="$(git -C "${repo}" rev-parse HEAD)"
echo words >"${repo}/README.md"
git -C "${repo}" add README.md
git -C "${repo}" -c user.email=fixture@example.invalid -c user.name=Fixture -c commit.gpgsign=false \
  commit -q -m docs
head="$(git -C "${repo}" rev-parse HEAD)"

ci() {
  local output="${repo}/output"
  : >"${output}"
  (cd "${repo}" && GITHUB_EVENT_NAME="$1" BASE="$2" HEAD="$3" GITHUB_OUTPUT="${output}" \
    "${classifier}" >/dev/null)
  cat "${output}"
}

check "a documentation-only pull request skips the job" "$(ci pull_request "${base}" "${head}")" validate=false
check "an unreadable diff runs it" "$(ci pull_request invalid "${head}")" validate=true
check "a push runs it" "$(ci push "${base}" "${head}")" validate=true
check "a dispatch runs it" "$(ci workflow_dispatch "${base}" "${head}")" validate=true

exit "${failed}"
