#!/usr/bin/env bash
# Pins scripts/ci-changes.sh: which changes run `Build + test`, that the job
# reads the answer, and that only a readable diff can skip it: a pull
# request's, or a push's after a commit with a green run. Also pins the last
# job of ci.yml, `Full CI`, and that a draft stops after the lint without
# failing.
# The workflow expressions below are matched literally, not expanded.
# shellcheck disable=SC2016
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
runs "the description check's workflow, which its test reads" true .github/workflows/pr-description.yml
runs "Dependabot's settings" false .github/dependabot.yml
runs "agent settings" false .claude/settings.json
runs "Codex's settings" false .codex/config.toml
runs "a skill's script" false .agents/skills/withmarfa-github/helper.py
runs "a Git hook" false .githooks/pre-push
runs "an issue template" false .github/ISSUE_TEMPLATE/bug.yml
runs "a fixture under agent files, which a test could read" true .agents/skills/x/fixtures/input.json
runs "a file that only looks like an agent directory" true Sources/Marfa/.agents/helper.swift
runs "a workflow other than the two the job reads" true .github/workflows/codeql.yml
runs "the release workflow" true .github/workflows/release.yml
runs "agent files beside Swift" true .agents/skills/x/helper.py Sources/Marfa/Server.swift
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
check "the classifier is not told whether the pull request is a draft" "$(grep -cF 'DRAFT' "${workflow}")" 0
check "the classifier runs in CI" "$(grep -cF "run: scripts/ci-changes.sh" "${workflow}")" 1
check "a push is classified against the commit before it" \
  "$(grep -cF 'BASE: ${{ github.event.pull_request.base.sha || github.event.before }}' "${workflow}")" 1
check "a push is classified up to its own commit" \
  "$(grep -cF 'HEAD: ${{ github.event.pull_request.head.sha || github.sha }}' "${workflow}")" 1
check "the classifier may read the runs of this workflow" "$(grep -cF '      actions: read' "${workflow}")" 1
check "the classifier is handed a token" "$(grep -cF 'GH_TOKEN: ${{ github.token }}' "${workflow}")" 1
check "the classifier asks about the workflow it is in" "$(grep -cF 'workflows/ci.yml/runs' "${classifier}")" 1

# A draft runs `Build + test` only to the lint, and passes there: a step that
# exits non-zero for a draft would turn the draft red.
draft='!github.event.pull_request.draft'
job_steps() { awk -v job="$1" '
  $0 ~ "^  " job ":$" { injob = 1; next }
  injob && /^  [a-z-]+:$/ { injob = 0 }
  injob && /^      - / { n++ }
  injob { print n "\t" $0 }' "${workflow}"; }
unguarded="$(job_steps validate | awk -F'\t' -v draft="${draft}" '
  /name: Lint$/ { lint = $1 }
  lint && $1 > lint { seen[$1] = 1; if (index($0, draft)) guarded[$1] = 1 }
  END { for (n in seen) if (!(n in guarded)) count++; print count + 0 }')"
after_lint="$(job_steps validate | awk -F'\t' '/name: Lint$/ { lint = $1 } lint && $1 > lint { seen[$1] = 1 } END { print length(seen) }')"
check "every step after the lint is skipped for a draft" "${unguarded}" 0
check "there are steps after the lint to skip" "$([[ "${after_lint}" -gt 10 ]] && echo yes)" yes
check "no step stops a draft with a failure" "$(grep -cF 'Stop a draft' "${workflow}")" 0

# The last job, `Full CI`, is the required check. It waits for every job, is
# named Draft CI for a draft so that `Full CI` stays expected, and fails only
# when a job it waited for failed or was cancelled.
check "the last job is named Full CI, or Draft CI for a draft" \
  "$(grep -cF "name: \${{ github.event.pull_request.draft && 'Draft CI' || 'Full CI' }}" "${workflow}")" 1
jobs="$(sed -n '/^jobs:$/,$p' "${workflow}" | grep -E '^  [a-z-]+:$' | tr -d ' :' | grep -vx gate | sort | tr '\n' ' ')"
needs="$(sed -n '/^  gate:$/,$p' "${workflow}" | sed -n 's/^    needs: \[\(.*\)\]$/\1/p' | tr -d ',' | tr ' ' '\n' | sort | tr '\n' ' ')"
check "Full CI waits for every other job" "${needs}" "${jobs}"
check "Full CI runs whatever the other jobs did" "$(sed -n '/^  gate:$/,$p' "${workflow}" | grep -cF 'if: ${{ always() }}')" 1
check "Full CI reads the results of the jobs it needs" \
  "$(sed -n '/^  gate:$/,$p' "${workflow}" | grep -cF "RESULTS: \${{ join(needs.*.result, ' ') }}")" 1
verdict="$(sed -n '/^  gate:$/,$p' "${workflow}" | awk '/^        run: \|$/ { on = 1; next } on { sub(/^          /, ""); print }')"
gate_passes() { RESULTS="$1" bash -c "${verdict}" >/dev/null 2>&1 && echo pass || echo fail; }
check "Full CI passes when every job passed" "$(gate_passes 'success success success')" pass
check "Full CI passes when jobs were skipped" "$(gate_passes 'success skipped skipped')" pass
check "Full CI fails when a job failed" "$(gate_passes 'success failure success')" fail
check "Full CI fails when a job was cancelled" "$(gate_passes 'success success cancelled')" fail
check "Full CI fails when the first job failed" "$(gate_passes 'failure skipped skipped')" fail

# CodeQL starts no run for a change to instructions alone, on a pull request or a push.
codeql="${root}/.github/workflows/codeql.yml"
for directory in .agents .codex .githooks .claude; do
  check "CodeQL ignores ${directory} on a pull request and on a push" "$(grep -cF -e "- \"${directory}/**\"" "${codeql}")" 2
done
check "CodeQL ignores Markdown on a pull request and on a push" "$(grep -cF -e '- "**/*.md"' "${codeql}")" 2

# As CI runs it, against a repository whose history holds each kind of change.
repo="$(mktemp -d)"
bin="$(mktemp -d)"
trap 'rm -rf "${repo}" "${bin}"' EXIT

git_in_repo() {
  git -C "${repo}" -c user.email=fixture@example.invalid -c user.name=Fixture -c commit.gpgsign=false "$@"
}

# commit <message> <path>...: writes each path (a path in the working tree that
# exists is moved when its name is `from=>to`) and commits the lot.
commit() {
  local message="$1" path
  shift
  for path in "$@"; do
    if [[ "${path}" == *'=>'* ]]; then
      mkdir -p "$(dirname "${repo}/${path#*=>}")"
      git_in_repo mv "${path%%=>*}" "${path#*=>}"
    else
      mkdir -p "$(dirname "${repo}/${path}")"
      echo "${message}" >>"${repo}/${path}"
      git_in_repo add "${path}"
    fi
  done
  git_in_repo commit -q --allow-empty -m "${message}"
  git_in_repo rev-parse HEAD
}

git_in_repo init -q
base="$(commit base)"
docs="$(commit docs README.md)"
agents="$(commit agents AGENTS.md .agents/skills/x/helper.py .codex/config.toml .githooks/pre-push)"
swift="$(commit swift Sources/Marfa/Server.swift)"
pin="$(commit pin core.pin)"
flow="$(commit workflow .github/workflows/codeql.yml)"
out="$(commit "move out of an agent directory" .agents/skills/x/helper.py=\>Sources/Marfa/helper.py)"
into="$(commit "move into an agent directory" Sources/Marfa/Server.swift=\>.agents/Server.swift)"
git_in_repo checkout -q -b elsewhere "${base}"
elsewhere="$(commit "documentation on a line of history without the Swift change" NOTES.md)"

# A stand-in for the API: FAKE_RUNS is the count of green runs it reports, and
# the stub records what it was asked.
cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_GH_LOG}"
if [[ "${FAKE_RUNS}" == error ]]; then exit 1; fi
echo "${FAKE_RUNS}"
STUB
chmod +x "${bin}/gh"

# ci <event> <base> <head> [draft] [green runs the API reports for the base]
ci() {
  local output="${repo}/output"
  : >"${output}"
  : >"${bin}/log"
  (cd "${repo}" && PATH="${bin}:${PATH}" GITHUB_REPOSITORY=example/repository FAKE_GH_LOG="${bin}/log" \
    FAKE_RUNS="${5:-1}" GITHUB_EVENT_NAME="$1" BASE="$2" HEAD="$3" DRAFT="${4:-}" GITHUB_OUTPUT="${output}" \
    "${classifier}" >/dev/null 2>&1)
  cat "${output}"
}

check "a documentation-only pull request skips the job" "$(ci pull_request "${base}" "${docs}")" validate=false
check "agent files alone, in a pull request, skip it" "$(ci pull_request "${docs}" "${agents}")" validate=false
check "a Swift change in a pull request runs it" "$(ci pull_request "${agents}" "${swift}")" validate=true
check "a new pin in a pull request runs it" "$(ci pull_request "${swift}" "${pin}")" validate=true
check "a workflow change in a pull request runs it" "$(ci pull_request "${pin}" "${flow}")" validate=true
check "a move out of an agent directory runs it" "$(ci pull_request "${flow}" "${out}")" validate=true
check "a move into an agent directory runs it, for the file it left" "$(ci pull_request "${out}" "${into}")" validate=true
check "a pull request over several commits runs it when one needs it" "$(ci pull_request "${base}" "${agents}")" validate=false
check "a pull request over several commits, one of them Swift" "$(ci pull_request "${base}" "${swift}")" validate=true
check "an unreadable diff runs it" "$(ci pull_request invalid "${docs}")" validate=true
check "an unknown commit runs it" "$(ci pull_request 1111111111111111111111111111111111111111 "${docs}")" validate=true
check "a documentation-only draft skips it, as any pull request does" "$(ci pull_request "${base}" "${docs}" true)" validate=false
check "a draft with a Swift change runs it, to the lint" "$(ci pull_request "${agents}" "${swift}" true)" validate=true
check "a documentation-only pull request that is no draft skips it" "$(ci pull_request "${base}" "${docs}" false)" validate=false

# A push to main is classified too, but only on top of a commit that went green.
check "documentation alone, on a green commit, skips the push" "$(ci push "${base}" "${docs}" "" 1)" validate=false
check "agent files alone, on a green commit, skip the push" "$(ci push "${docs}" "${agents}" "" 3)" validate=false
check "documentation on a commit with no green run runs the push" "$(ci push "${base}" "${docs}" "" 0)" validate=true
check "documentation after a failed API call runs the push" "$(ci push "${base}" "${docs}" "" error)" validate=true
check "documentation after an unreadable answer runs the push" "$(ci push "${base}" "${docs}" "" none)" validate=true
check "a Swift change on a green commit runs the push" "$(ci push "${agents}" "${swift}" "" 1)" validate=true
check "a new pin on a green commit runs the push" "$(ci push "${swift}" "${pin}" "" 1)" validate=true
check "a workflow change on a green commit runs the push" "$(ci push "${pin}" "${flow}" "" 1)" validate=true
check "a push to a new branch (no commit before) runs it" "$(ci push 0000000000000000000000000000000000000000 "${docs}" "" 1)" validate=true
check "a push that rewrites history runs it" "$(ci push "${docs}" "${base}" "" 1)" validate=true
check "a push that does not descend from the commit before it runs it" "$(ci push "${swift}" "${elsewhere}" "" 1)" validate=true
check "a push with an unreadable diff runs it" "$(ci push invalid "${docs}" "" 1)" validate=true
check "an empty push runs it" "$(ci push "${docs}" "${docs}" "" 1)" validate=true

# The question asked of the API names the commit before the push, a push run on main.
ci push "${base}" "${docs}" "" 1 >/dev/null
asked="$(cat "${bin}/log")"
check "the push asks about the commit before it" "$([[ "${asked}" == *"head_sha=${base}&"* ]] && echo yes)" yes
check "the push asks about push runs on main that succeeded" \
  "$([[ "${asked}" == *"event=push&branch=main&status=success"* ]] && echo yes)" yes

# Nothing else asks the API, and nothing but a pull request or a push is classified.
ci pull_request "${base}" "${docs}" >/dev/null
check "a pull request does not ask the API" "$(wc -c <"${bin}/log" | tr -d ' ')" 0
check "a scheduled run runs the job" "$(ci schedule "${base}" "${docs}")" validate=true
check "a manual run runs the job" "$(ci workflow_dispatch "${base}" "${docs}")" validate=true

exit "${failed}"
