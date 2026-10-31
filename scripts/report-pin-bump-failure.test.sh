#!/usr/bin/env bash
# Pins scripts/report-pin-bump-failure.sh against a stand-in for `gh`: the first failure opens one issue,
# a later one comments on it, and a report that cannot be made fails.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
report="${root}/scripts/report-pin-bump-failure.sh"
bin="$(mktemp -d)"
trap 'rm -rf "${bin}"' EXIT
failed=0

check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: expected '$3', got '$2'"
    failed=1
  fi
}

# FAKE_OPEN is the number of the open issue with the title, if any; FAKE_FAIL names the `gh` call that fails.
cat >"${bin}/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_GH_LOG}"
case "$1 $2" in
  "run view")
    if [[ "$*" == *--log-failed* ]]; then
      printf 'Open the pin bump\tBuild\t2026-10-31T10:00:00.1Z /w/Sources/Marfa/X.swift:3:4: error: missing argument for parameter %s in call\n' "'inPlaceOnly'"
      printf 'Open the pin bump\tBuild\t2026-10-31T10:00:01.1Z note: other\n'
    else
      echo '{"jobs":[{"name":"Open the pin bump","conclusion":"failure"},{"name":"Other","conclusion":"success"}]}'
    fi
    ;;
  "issue list") echo "[{\"number\":${FAKE_OPEN:-0},\"title\":\"${FAKE_TITLE}\"}]" ;;
  "issue comment" | "issue create") [[ "${FAKE_FAIL:-}" == "$1 $2" ]] && exit 1 || echo "done" ;;
esac
STUB
chmod +x "${bin}/gh"

run() {
  : >"${bin}/log"
  (PATH="${bin}:${PATH}" FAKE_GH_LOG="${bin}/log" GH_TOKEN=x GITHUB_REPOSITORY=example/repository \
    GITHUB_WORKFLOW="Bump the core pin" GITHUB_RUN_ID=42 GITHUB_SHA=abc MARFA_RELEASE='v1.2.3 (def)' "$@" "${report}" >/dev/null 2>&1) &&
    echo ok || echo failed
}
title="Nightly failed: Bump the core pin"

check "a first failure opens an issue" "$(run env FAKE_TITLE=none FAKE_OPEN=0)" ok
check "the issue has the shared title" "$(grep -cF "issue create --repo example/repository --title ${title}" "${bin}/log")" 1
check "the issue is for triage" "$(grep -cF -e '--label needs-triage' "${bin}/log")" 1
check "a first failure comments nowhere" "$(grep -cF 'issue comment' "${bin}/log")" 0
check "a later failure comments on the open issue" "$(run env "FAKE_TITLE=${title}" FAKE_OPEN=7)" ok
check "the comment goes to that issue" "$(grep -cF 'issue comment 7 --repo example/repository' "${bin}/log")" 1
check "no second issue is opened" "$(grep -cF 'issue create' "${bin}/log")" 0
check "an issue of another title is not the one" "$(run env FAKE_TITLE=Something FAKE_OPEN=9)" ok
check "it opens its own" "$(grep -cF 'issue create' "${bin}/log")" 1
check "an issue that cannot be opened fails the report" "$(run env FAKE_TITLE=none FAKE_OPEN=0 "FAKE_FAIL=issue create")" failed
check "a comment that cannot be made fails the report" "$(run env "FAKE_TITLE=${title}" FAKE_OPEN=7 "FAKE_FAIL=issue comment")" failed
check "a missing marfa release fails the report" "$(run env -u MARFA_RELEASE FAKE_TITLE=none)" failed

exit "${failed}"
