#!/usr/bin/env bash
#
# assert-site-contract.sh — refuse a half-written site tree.
#
# The `site` branch root IS the published site: GitHub Pages serves it verbatim,
# there is no build step between the two. So the only moment anything can be
# checked is before it lands, and the thing worth checking is that the tree is
# whole. A stale site is a nuisance; a half-written one is a broken demo.
#
# The contract, which is what the app shell fetches:
#   index.html      the app shell
#   _index.json     the payload index the app fetches first
#   manifest.csv    the environment record behind the provenance chip
#   status.json     what the run did
#   snapshots.json  the snapshot index the picker reads
#   workflows/      the YAMLs that produced this snapshot
#   config/         the study configuration they read
#   output/         the artifacts themselves
#
# Two callers, one list, on purpose:
#   * run-pipeline.yaml runs it on the assembled tree BEFORE committing and
#     pushing, so a bad tree is never published in the first place;
#   * build-site.yaml runs it on what is actually on the branch afterwards.
#
# Usage:
#   assert-site-contract.sh [DIR] [EXPECTED_PACKAGE_SNAPSHOT]
#
# With EXPECTED_PACKAGE_SNAPSHOT it additionally requires the newest entry in
# snapshots.json to carry that label, and the matching ps-NNN/ directory to
# exist — which is how a run checks that its own snapshot was actually recorded
# rather than that some snapshot was.

set -uo pipefail

dir="${1:-.}"
expected="${2:-}"
fail=0

err() { printf '::error::%s\n' "$*"; }

if [ ! -d "$dir" ]; then
  err "site tree not found: $dir"
  exit 1
fi

for f in index.html _index.json manifest.csv status.json snapshots.json; do
  if [ ! -s "$dir/$f" ]; then
    err "MISSING OR EMPTY FILE: $f"
    fail=1
  fi
done

for d in workflows config output; do
  if [ ! -d "$dir/$d" ]; then
    err "MISSING DIRECTORY: $d"
    fail=1
  elif [ -z "$(ls -A "$dir/$d" 2>/dev/null)" ]; then
    err "EMPTY DIRECTORY: $d"
    fail=1
  fi
done

if [ "$fail" -eq 0 ] && [ -n "$expected" ]; then
  # Not being able to read snapshots.json is a different thing from reading it
  # and finding the wrong snapshot, and the two must not print the same error.
  # Failing closed is right either way — do not publish what you cannot verify —
  # but the message has to say which happened.
  if ! command -v jq >/dev/null 2>&1; then
    err "jq is not available, so the snapshot could not be verified as recorded — refusing to publish rather than assuming it was"
    exit 1
  fi
  if ! latest="$(jq -er '.snapshots[-1] | "\(.snapshot_id)\t\(.package_snapshot)"' "$dir/snapshots.json" 2>&1)"; then
    err "could not read the newest entry from $dir/snapshots.json: $latest"
    exit 1
  fi
  snapshot_id="${latest%%$'\t'*}"
  package_snapshot="${latest#*$'\t'}"

  if [ "$package_snapshot" != "$expected" ]; then
    err "snapshots.json's newest entry says package_snapshot '$package_snapshot', expected '$expected' — this run's snapshot was not recorded"
    fail=1
  fi
  if [ -z "$snapshot_id" ] || [ ! -d "$dir/$snapshot_id" ]; then
    err "snapshots.json names '$snapshot_id' but there is no $snapshot_id/ directory beside it"
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  err "The site tree does not satisfy the artifact contract — refusing to publish."
  exit 1
fi

if [ -n "$expected" ]; then
  echo "Contract satisfied, and $(jq -r '.snapshots[-1].snapshot_id' "$dir/snapshots.json") is recorded as $expected."
else
  echo "Contract satisfied: index.html, _index.json, manifest.csv, status.json, snapshots.json, workflows/, config/, output/"
fi
