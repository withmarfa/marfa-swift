#!/usr/bin/env bash
# Which SDK version each Swift consumer pins, and how far behind it is.
#
# The apps pin `exactVersion`, deliberately: neither auto-upgrades and
# neither breaks when a new SDK ships. The cost of that is silence — a
# consumer never notices the SDK moving, so the distance grows and the
# answer to "which SDK is each app on" costs a manual sweep every time
# somebody asks. One app sat a major and two minors behind for weeks, and
# what surfaced it was a stock-take rather than any signal.
#
# **Dependabot cannot do this and that is established rather than assumed.**
# Its `swift` ecosystem reads a `Package.swift`; neither app has one, only an
# Xcode-embedded `Package.resolved`. GitHub's dependency graph for both repos
# lists exactly two entries, `actions/checkout` and the repository itself —
# none of the packages either app resolves. So a `swift` entry in
# `dependabot.yml` would be accepted, look correct in review, and do nothing.
#
# Reads the pin out of each project file rather than cloning: the pin is four
# lines of a pbxproj and the whole checkout is an Xcode project.
#
# Exits non-zero when a consumer is behind, so the workflow's own job status
# is the signal and the notifier needs no second opinion.
set -euo pipefail

# Consumer repository and the project file carrying its package reference.
CONSUMERS=(
  "withmarfa/marfa-mini:MarfaMini.xcodeproj/project.pbxproj"
  "withmarfa/marfa-msg:MarfaMsg.xcodeproj/project.pbxproj"
)

# The newest release, which is what a consumer is measured against. Sorted by
# version rather than by date: a patch cut on an older line publishes after a
# newer minor and would otherwise read as the latest.
latest=$(gh api /repos/withmarfa/swift-sdk/tags --paginate --jq '.[].name' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sed 's/^v//' \
  | sort -t. -k1,1n -k2,2n -k3,3n \
  | tail -1)
[ -n "${latest}" ] || { echo "could not resolve the newest tag" >&2; exit 2; }
echo "swift-sdk latest: ${latest}"

behind=0
for entry in "${CONSUMERS[@]}"; do
  repo="${entry%%:*}"
  path="${entry#*:}"
  # `--jq` on the contents endpoint returns base64; decoding here keeps the
  # whole read to one call.
  # `|| true` is load-bearing under `pipefail`. Without it a `grep` that
  # matches nothing — which is exactly the case the branch below exists to
  # report — fails the pipeline, fails the assignment, and `set -e` kills
  # the script before it can say so. The check would then die silently on
  # the one input it was written for. Found by testing the failing
  # direction rather than by reading it.
  pin=$(gh api "/repos/${repo}/contents/${path}" --jq '.content' 2>/dev/null \
    | base64 --decode 2>/dev/null \
    | grep -A 3 'kind = exactVersion' \
    | grep -E '^[[:space:]]*version = ' \
    | head -1 \
    | sed -E 's/.*version = "?([0-9]+\.[0-9]+\.[0-9]+)"?;.*/\1/' || true)

  if [ -z "${pin}" ]; then
    # Reported rather than skipped. A consumer whose pin cannot be read is
    # the case this check exists for arriving in its worst form: silent.
    echo "  ${repo}: pin could not be read from ${path}"
    behind=$(( behind + 1 ))
    continue
  fi

  if [ "${pin}" = "${latest}" ]; then
    echo "  ${repo}: ${pin} (current)"
  else
    echo "  ${repo}: ${pin} — behind ${latest}"
    behind=$(( behind + 1 ))
  fi
done

if [ "${behind}" -gt 0 ]; then
  echo "${behind} consumer(s) not on ${latest}"
  exit 1
fi
echo "every consumer is on ${latest}"
