#!/usr/bin/env bash
# Whether a pull request's description follows the organization's template
# (`.github/PULL_REQUEST_TEMPLATE.md` in withmarfa/.github).
#
#   scripts/check-pr-description.sh     # in CI: reads the body from the event file
#   scripts/check-pr-description.sh -   # reads the body from stdin
#
# A pull request opened from the command line with `--body` skips the
# template, and GitHub cannot require one, so `pr-description.yml` runs this
# and fails the check. The body is untrusted input: it is read from the event
# file or stdin and never reaches a shell. `scripts/check-pr-description.test.sh`
# pins the rules.
set -euo pipefail

body() {
  if [[ "${1:-}" == - ]]; then
    cat
  else
    jq -r '.pull_request.body // ""' "${GITHUB_EVENT_PATH}"
  fi
}

# Prints one problem per line, and nothing for a description that follows the
# template. Comments are dropped first, an unclosed one to the end, as GitHub
# hides the rest of the page behind it.
problems() {
  awk '
    function strip(line,   out, start, stop) {
      out = ""
      while (line != "") {
        if (comment) {
          stop = index(line, "-->")
          if (stop == 0) return out
          line = substr(line, stop + 3)
          comment = 0
        } else {
          start = index(line, "<!--")
          if (start == 0) return out line
          out = out substr(line, 1, start - 1)
          line = substr(line, start + 4)
          comment = 1
        }
      }
      return out
    }
    BEGIN {
      split("Summary|Changes|Testing|Notes for reviewers|Checklist", sections, "|")
      for (i in sections) known[sections[i]] = 1
      filled["Summary"] = filled["Changes"] = filled["Testing"] = 1
    }
    {
      sub(/\r$/, "")
      line = strip($0)
      if (match(line, /^## +/)) {
        name = substr(line, RLENGTH + 1)
        sub(/ +$/, "", name)
        current = (name in known) ? name : ""
        if (current != "") seen[current] = 1
      } else if (current != "") {
        trimmed = line
        gsub(/^[ \t]+|[ \t]+$/, "", trimmed)
        if (trimmed != "" && trimmed != "-") content[current] = 1
        if (current == "Checklist" && line ~ /^[ \t]*[-*+][ \t]+\[[ xX]\]/) {
          boxes++
          if (line ~ /^[ \t]*[-*+][ \t]+\[ \]/) {
            item = line
            sub(/^[ \t]*[-*+][ \t]+\[ \][ \t]*/, "", item)
            gsub(/[ \t]+$/, "", item)
            unticked[++count] = "Checklist box not ticked: " item
          }
        }
      }
    }
    END {
      for (i = 1; i <= 5; i++) {
        name = sections[i]
        if (!(name in seen)) {
          print "The \"## " name "\" heading is missing."
        } else if ((name in filled) && !(name in content)) {
          print "\"## " name "\" has no content."
        }
      }
      if (("Checklist" in seen) && boxes == 0) print "\"## Checklist\" has no boxes."
      for (i = 1; i <= count; i++) print unticked[i]
    }
  '
}

found="$(body "${1:-}" | problems)"
if [[ -n "${found}" ]]; then
  while IFS= read -r problem; do
    echo "::error title=Pull request description::${problem}"
  done <<<"${found}"
  echo "The description must follow the organization's pull request template: Summary, Changes, Testing, Notes for reviewers and Checklist, with the first three filled in and every checklist box ticked." >&2
  exit 1
fi
echo "The description follows the template."
