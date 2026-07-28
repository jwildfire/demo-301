# The `site` branch

This branch is not source. It is the published output of a pipeline run, and
its root **is** the website: `build-site.yaml` uploads it to GitHub Pages
verbatim, with no build step. Every commit here is written by
[`scripts/publish-snapshot.py`](https://github.com/jwildfire/demo-301/blob/main/scripts/publish-snapshot.py)
on `main`.

## Two shapes, one tree

The root carries the **current** snapshot, flat:

| Path | What it is |
| --- | --- |
| `index.html` | the open.gismo app shell |
| `_index.json` | the index of workflow YAMLs the app fetches first |
| `status.json` | per-workflow execution status for this snapshot |
| `manifest.csv` | the package versions and commit SHAs that produced it |
| `workflows/` | the YAMLs that ran |
| `config/` | the study and data configuration they ran against |
| `output/` | the artifacts themselves |

`ps-NNN/` directories carry the **history** — one per run, each with that run's
`status.json`, `manifest.csv`, `metadata.json`, and `output/`. `snapshots.json`
at the root indexes them.

The current snapshot therefore appears twice: once flat at the root, once under
its own `ps-NNN/`. That is deliberate. The flat copy keeps the existing app
shell working with no changes — it knows nothing about snapshots — while the
`ps-NNN/` copy makes history addressable for a snapshot picker. The two copies
are byte-identical, so git stores them as one set of blobs.

## What is not published

**Input data.** `input/` lives on `main`, which is the provenance. It is not
copied here.

**Large mapping artifacts.** Every mapping workflow in this study is a literal
`Mapped_X = Raw_X` assignment, so `output/1_mappings/Mapped_X.csv` is a
re-serialization of `input/Raw_X.csv`. Artifacts over 5 MB are dropped and
recorded, per snapshot, in `output/1_mappings/OMITTED.json`. The four bulk
domains (`LB`, `DATACHG`, `DATAENT`, `QUERY`) account for ~190 MB per run; the
nine smaller mapped domains are published in full. `status.json` still reports
those workflows as completed, because they did complete — the artifact is
omitted from the *publication*, not from the run.

## Size

A snapshot is roughly 70 MB, most of it self-contained report HTML (nine
safety.viz charts at ~7 MB each, two gsm.kri reports at ~8 MB each). Each new
snapshot adds about that much to the branch. Two snapshots is comfortable; a
weekly cron is not, so a retention policy belongs in this branch's contract
before `run-pipeline.yaml`'s schedule is switched on.
