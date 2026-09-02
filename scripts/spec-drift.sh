#!/usr/bin/env bash
# Whether the vendored OpenAPI snapshot still matches the monorepo's.
#
# `scripts/openapi.json` is a verbatim copy of the monorepo's `openapi.json`,
# taken by `sync-openapi.sh`, and every wire type is generated from it. The
# copy is made by hand and nothing watched it, so the snapshot could trail
# indefinitely: `freshness` regenerates against the committed snapshot rather
# than re-syncing it, and `RouteCoverageTests` reads that same file, so both
# stay green over a spec that moved months ago. It cost a release — the
# connection install route changed shape on both sides of the call and the
# SDK went on sending a field the server had dropped.
#
# Byte equality is the exact invariant, because the sync is a `cp`. A
# difference is a finding rather than a fault, so the operation and schema
# breakdown below exists to say what moved: a bare "the files differ" over a
# 700KB document tells nobody what to do next.
#
# **Three outcomes, three exit codes, because two of them are not the same
# kind of news.** 0 is a match. 1 is drift: a finding, and a thing to go and
# do. 2 is "could not answer" — a missing token, a rate limit, an outage, a
# truncated download. Collapsing 2 into 1 would report an unreachable API as
# a stale snapshot, sending somebody to refresh a file that is already
# current; and a guard that cannot run must say so rather than inventing a
# verdict. The workflow maps each to its own alert title.
#
#   SPEC_SOURCE_FILE=../marfa/openapi.json ./scripts/spec-drift.sh
#
# reads a local monorepo checkout instead of the API, which is how this is
# run from a dev machine and how its own failing direction is exercised.
# Without it the spec is read from the API and `GH_TOKEN` must reach
# `SPEC_SOURCE_REPO`.
set -euo pipefail

SPEC_SOURCE_REPO="${SPEC_SOURCE_REPO:-withmarfa/marfa}"
SNAPSHOT="scripts/openapi.json"

if [ ! -f "$SNAPSHOT" ]; then
  echo "error: $SNAPSHOT not found — run this from the repository root" >&2
  exit 2
fi

upstream="$(mktemp)"
trap 'rm -f "$upstream"' EXIT

if [ -n "${SPEC_SOURCE_FILE:-}" ]; then
  if [ ! -f "$SPEC_SOURCE_FILE" ]; then
    echo "error: SPEC_SOURCE_FILE=$SPEC_SOURCE_FILE not found" >&2
    exit 2
  fi
  cp "$SPEC_SOURCE_FILE" "$upstream"
  origin="$SPEC_SOURCE_FILE"
else
  if ! gh api -H "Accept: application/vnd.github.raw" \
      "repos/${SPEC_SOURCE_REPO}/contents/openapi.json" > "$upstream"; then
    echo "::error title=Drift guard could not run::Could not read openapi.json from ${SPEC_SOURCE_REPO}. This says nothing about whether the snapshot is current — the comparison never happened. Check the token's reach over that repository, then the API's own status." >&2
    exit 2
  fi
  origin="${SPEC_SOURCE_REPO}:openapi.json"
fi

# A truncated or error-page download parses as neither, and comparing against
# it would report the entire document as drift. This separates "the fetch was
# wrong" from "the snapshot is wrong", which is the whole point of exit 2.
if ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d.get("paths"), dict) and d["paths"] else 1)' "$upstream" 2>/dev/null; then
  echo "::error title=Drift guard could not run::What came back from ${origin} is not an OpenAPI document with a populated \`paths\` object, so it was not compared. The snapshot may well be current; this is a bad read, not a finding." >&2
  exit 2
fi

if cmp -s "$upstream" "$SNAPSHOT"; then
  echo "$SNAPSHOT matches ${origin}."
  exit 0
fi

echo "::error title=Vendored spec is stale::$SNAPSHOT differs from ${origin}. Run './scripts/sync-openapi.sh' against a current monorepo checkout, resolve whatever the regenerated wire types break, and commit the delta. Every operation and schema below is one the SDK is generated against a stale copy of."

# The walk is over the registry's pointers rather than over
# `components.schemas`, because most of this document's shapes are declared
# inline under `paths` and never appear there.
#
# **What this does not name, said plainly.** Only the generated types are
# listed. A hand-written model in `Types/Wire/Hand/` reads a schema no
# registry knows about, so a change to one is invisible here — the whole
# refresh that prompted this check moved `OccurrencesResponse` and this
# report would not have said so. Reporting every operation whose shape moved
# was tried and is worse: `Item` is declared inline in most responses, so one
# added field reported 32 operations for 5 real changes and buried the list
# that mattered.
#
# That gap is covered, just not here. `WireFixtureSpecDriftTests` compares
# each hand-written fixture against this same snapshot and fails once it is
# refreshed, which fails the round-trip until the model gains the field. This
# report says the snapshot is stale and roughly what moved; the suite says
# precisely what has to change, and only the byte comparison above decides
# whether anything is wrong at all.
UPSTREAM="$upstream" SNAPSHOT="$SNAPSHOT" python3 <<'PY'
import json, os, sys

upstream = json.load(open(os.environ["UPSTREAM"]))
snapshot = json.load(open(os.environ["SNAPSHOT"]))

METHODS = ("get", "post", "put", "patch", "delete", "head", "options")


def operations(doc):
    return {
        f"{method.upper()} {path}"
        for path, item in doc.get("paths", {}).items()
        for method in item
        if method in METHODS
    }


up_ops, snap_ops = operations(upstream), operations(snapshot)
for label, ops in (
    ("declared upstream, missing here", up_ops - snap_ops),
    ("declared here, withdrawn upstream", snap_ops - up_ops),
):
    for op in sorted(ops):
        print(f"operation {label}: {op}")


def resolve(doc, pointer):
    node = doc
    for segment in pointer.split("/")[1:]:
        segment = segment.replace("~1", "/").replace("~0", "~")
        try:
            node = node[int(segment)] if isinstance(node, list) else node[segment]
        except (KeyError, IndexError, ValueError):
            return None
    return node


registry = json.load(open("scripts/wire-types.json"))
for entry in registry["types"]:
    here, there = resolve(snapshot, entry["pointer"]), resolve(upstream, entry["pointer"])
    if json.dumps(here, sort_keys=True) == json.dumps(there, sort_keys=True):
        continue
    if there is None:
        print(f"wire type {entry['name']}: its schema is gone from the upstream document")
        continue
    if here is None:
        print(f"wire type {entry['name']}: newly resolvable upstream")
        continue
    here_props, there_props = set(here.get("properties", {})), set(there.get("properties", {}))
    here_req, there_req = set(here.get("required", [])), set(there.get("required", []))
    changes = []
    if there_props - here_props:
        changes.append(f"gains {sorted(there_props - here_props)}")
    if here_props - there_props:
        changes.append(f"loses {sorted(here_props - there_props)}")
    if there_req - here_req:
        changes.append(f"newly requires {sorted(there_req - here_req)}")
    if here_req - there_req:
        changes.append(f"no longer requires {sorted(here_req - there_req)}")
    retyped = sorted(
        field
        for field in here_props & there_props
        if json.dumps(here["properties"][field], sort_keys=True)
        != json.dumps(there["properties"][field], sort_keys=True)
    )
    if retyped:
        changes.append(f"retypes {retyped}")
    # A difference the summary above cannot name is still a difference, and
    # saying so is better than printing the type with nothing after it.
    print(f"wire type {entry['name']}: {'; '.join(changes) if changes else 'changed'}")
PY

exit 1
