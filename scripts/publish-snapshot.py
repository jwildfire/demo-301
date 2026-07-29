#!/usr/bin/env python3
"""publish-snapshot.py — copy a completed pipeline run onto the `site` branch.

The `site` branch root IS the published site: GitHub Pages uploads it verbatim,
there is no build step. This script arranges that root, and it arranges it in
two shapes at once:

  * **root, flat** — the CURRENT snapshot. `_index.json`, `status.json`,
    `manifest.csv`, `index.html`, `workflows/`, `config/`, `output/`. This is
    the static contract the app shell fetches today; it knows nothing about
    snapshots and must keep working unchanged.

  * **`ps-NNN/`** — the SNAPSHOT HISTORY. One directory per run, each holding
    that run's `status.json`, `manifest.csv`, `metadata.json` and `output/`.
    `snapshots.json` at the root indexes them.

Publishing the current snapshot twice (flat at the root and again under its own
`ps-NNN/`) is deliberate: the flat copy keeps the existing app working with no
changes, and the `ps-NNN/` copy makes history addressable for the snapshot
picker. Git stores the duplicate as one blob, so the branch does not pay for it
twice.

Very large mapping artifacts are omitted from the published
`output/1_mappings/`. The threshold is set above `Mapped_LB` on purpose: the
three domains the Safety charts read -- `Mapped_LB`, `Mapped_AE`, `Mapped_EG`
-- are published, because "both lenses read these files" is the claim this
demo makes and it should be checkable from the site. What gets dropped is the
operational bulk (data changes, data entry, queries), which is tens of
megabytes per snapshot and is reproducible by re-running the mapping phase
over `input/`, versioned on `main`. Each snapshot records exactly what was
left out in `output/1_mappings/OMITTED.json`.

Usage:
    python3 scripts/publish-snapshot.py SITE_DIR INPUT_DATA_VERSION \\
        [--package-snapshot LABEL] [--project-dir DIR]
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
from pathlib import Path

# Files copied flat to the site root (the app shell's contract).
ROOT_FILES = ["index.html", "_index.json", "status.json", "manifest.csv"]
# Directories copied flat to the site root.
ROOT_DIRS = ["workflows", "config", "output"]
# Per-snapshot copies under ps-NNN/.
SNAPSHOT_FILES = ["status.json", "manifest.csv"]
SNAPSHOT_DIRS = ["output"]

# Mapping artifacts larger than this are omitted from the published tree.
MAPPING_SIZE_LIMIT = 10 * 1024 * 1024


def next_snapshot_id(index: dict) -> str:
    nums = [
        int(s["snapshot_id"].split("-")[-1])
        for s in index.get("snapshots", [])
        if s.get("snapshot_id", "").startswith("ps-")
    ]
    return "ps-%03d" % ((max(nums) + 1) if nums else 1)


def prune_mappings(output_dir: Path) -> list[dict]:
    """Delete oversized 1_mappings artifacts; return what was removed."""
    mappings = output_dir / "1_mappings"
    if not mappings.is_dir():
        return []
    omitted = []
    for path in sorted(mappings.rglob("*")):
        if not path.is_file():
            continue
        size = path.stat().st_size
        if size <= MAPPING_SIZE_LIMIT:
            continue
        omitted.append(
            {
                "path": str(path.relative_to(output_dir.parent)),
                "bytes": size,
                "reason": (
                    "operational mapping output, omitted from the published "
                    "tree for size; reproducible by re-running the mapping "
                    "phase over input/, which is versioned on main"
                ),
            }
        )
        path.unlink()
    if omitted:
        (mappings / "OMITTED.json").write_text(
            json.dumps(
                {"size_limit_bytes": MAPPING_SIZE_LIMIT, "omitted": omitted},
                indent=2,
            )
            + "\n"
        )
    return omitted


def replace_dir(src: Path, dest: Path) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("site_dir", help="checkout of the `site` branch")
    ap.add_argument("input_data_version", help='e.g. "cut-1"')
    ap.add_argument("--package-snapshot", default="local")
    ap.add_argument("--project-dir", default=".")
    args = ap.parse_args()

    project = Path(args.project_dir).resolve()
    site = Path(args.site_dir).resolve()
    site.mkdir(parents=True, exist_ok=True)

    index_path = site / "snapshots.json"
    index = (
        json.loads(index_path.read_text())
        if index_path.exists()
        else {"snapshots": []}
    )
    snapshot_id = next_snapshot_id(index)
    created_at = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    # --- root: the current snapshot, flat -----------------------------------
    for name in ROOT_FILES:
        src = project / name
        if not src.exists():
            raise SystemExit("missing required payload file: %s" % src)
        shutil.copy2(src, site / name)
    for name in ROOT_DIRS:
        src = project / name
        if not src.is_dir():
            raise SystemExit("missing required payload directory: %s" % src)
        replace_dir(src, site / name)

    omitted = prune_mappings(site / "output")

    # --- ps-NNN/: the same snapshot, addressable ----------------------------
    snap = site / snapshot_id
    if snap.exists():
        shutil.rmtree(snap)
    snap.mkdir(parents=True)
    for name in SNAPSHOT_FILES:
        shutil.copy2(site / name, snap / name)
    for name in SNAPSHOT_DIRS:
        replace_dir(site / name, snap / name)

    metadata = {
        "snapshot_id": snapshot_id,
        "created_at": created_at,
        "input_data_version": args.input_data_version,
        "package_snapshot": args.package_snapshot,
        "previous_snapshots": [
            s["snapshot_id"] for s in index.get("snapshots", [])
        ],
    }
    (snap / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")

    # --- snapshots.json -----------------------------------------------------
    index.setdefault("snapshots", []).append(
        {
            "snapshot_id": snapshot_id,
            "created_at": created_at,
            "input_data_version": args.input_data_version,
            "package_snapshot": args.package_snapshot,
        }
    )
    index_path.write_text(json.dumps(index, indent=2) + "\n")

    print("published %s (%s)" % (snapshot_id, args.input_data_version))
    for entry in omitted:
        print("  omitted %s (%.1f MB)" % (entry["path"], entry["bytes"] / 1e6))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
