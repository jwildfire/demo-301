#!/usr/bin/env bash
#
# rebuild-snapshots.sh — rebuild the whole published study from scratch.
#
# The site branch holds two snapshots taken from two data cuts. They have to be
# produced in order, in one sequence, because the second one is only interesting
# next to the first: og_run() accumulates each run's results under the project's
# (gitignored) history/, and gsm.reporting::CalculateChange() reads that to write
# the Metric_Change / Flag_Previous / SnapshotDate_Previous columns the app
# renders as "since last snapshot". Run cut 2 without cut 1's history on disk and
# the snapshot is still valid, it just cannot say what moved.
#
# So: clear the derived directories, regenerate the raw layer at cut 1, publish,
# advance the data by one cut, publish again. Same seed, same result, every time.
#
# The snapshot ids are assigned by publish-snapshot.py from what is already in
# the site tree, so the site branch's ps-*/ directories and snapshots.json are
# reset first — the two snapshots keep their ids (ps-001, ps-002) and their URLs
# rather than accumulating as ps-003 and ps-004.
#
# Usage:
#   scripts/rebuild-snapshots.sh [site_dir]
#
# `site_dir` is a checkout of the `site` branch; it defaults to the sibling
# worktree ../site. Nothing here commits or pushes — read the diff, then commit.

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
site_dir="${1:-$project_dir/../site}"
package_snapshot="local-$(date +%Y-%m-%d)"

cd "$project_dir"

if [ ! -d "$site_dir" ]; then
  echo "site checkout not found: $site_dir" >&2
  exit 1
fi

echo "=== project: $project_dir"
echo "=== site:    $site_dir"

echo "=== 1/6 clearing derived directories (output/, history/, outputs/)"
Rscript -e 'unlink(c("output", "history", "outputs"), recursive = TRUE)'

echo "=== 2/6 regenerating the raw layer at cut 1"
Rscript scripts/make-raw-data.R .

echo "=== 3/6 resetting the published snapshot index"
SITE_DIR="$site_dir" Rscript -e '
  setwd(Sys.getenv("SITE_DIR"))
  unlink(list.files(".", pattern = "^ps-[0-9]{3}$"), recursive = TRUE)
  unlink("snapshots.json")
'

echo "=== 4/6 running cut 1"
Rscript scripts/run-pipeline.R .
python3 scripts/publish-snapshot.py "$site_dir" cut-1 \
  --package-snapshot "$package_snapshot" --project-dir .

echo "=== 5/6 advancing to cut 2"
Rscript scripts/advance-cut.R .

echo "=== 6/6 running cut 2"
Rscript scripts/run-pipeline.R .
python3 scripts/publish-snapshot.py "$site_dir" cut-2 \
  --package-snapshot "$package_snapshot" --project-dir .

echo
echo "Done. input/ is at cut 2 (commit it on main); $site_dir holds both"
echo "snapshots (commit it on site)."
