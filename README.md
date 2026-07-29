# DEMO-301 — Safety Review

A complete, forkable clinical study repository for
[open.gismo](https://github.com/jwildfire/open.gismo). Everything the analysis
needs — configuration, workflows, input data, and the environment record — lives
here as plain files. No database, no server, no build step.

**The data in this repository is synthetic.** No real participant, site, or
study data appears anywhere in this repo, and none ever should. It is one study
database, built by one script — see [One raw layer](#one-raw-layer) below.

## Fork it and it runs

1. **Fork this repository.** You now own a complete study: config, workflows,
   data, and pinned package versions.
2. **Run the pipeline.** Actions → *Run Pipeline* → *Run workflow*. It installs
   the exact package versions pinned in `manifest.csv`, runs the workflows, and
   pushes the results to the `site` branch.
3. **Your study site publishes itself.** The push to `site` triggers *Build
   Site*, which deploys that branch to GitHub Pages. There is no build step —
   the branch root *is* the site.

Then make it yours: point `config/data-config.yaml` at your own `Raw_*.csv`
files, edit thresholds and chart settings in the workflow YAML, add or remove a
domain in `config/study-config.yaml`. Every one of those is a reviewable pull
request against this repo — configuration as code, with one approval trail.

> **Status (2026-07-28):** the local lane is the real one today. The two
> workflows under `.github/workflows/` are reviewed templates that have not yet
> been exercised, and GitHub Pages is not enabled on this repo. Locally, the
> full pipeline runs end to end and two published snapshots live on the `site`
> branch. See [hub#134](https://github.com/jwildfire/obot.roadmap/issues/134)
> for where this sits in the plan.

## Running it locally

```r
# install.packages("remotes"); remotes::install_github("jwildfire/open.gismo")
open.gismo::og_validate(".")   # are the inputs ready?
open.gismo::og_app(".")        # explore the results
```

```sh
Rscript scripts/run-pipeline.R .   # run every phase of both domains
```

`og_validate()` is the forgiveness layer: it names exactly which domain, file,
and column is missing rather than failing deep inside a pipeline step.

`scripts/run-pipeline.R` is the entry point rather than `og_run()` alone,
because `og_run()` covers the four RBQM phases but not `workflows/3_reports/`.
It runs `og_run()` first and the safety charts second: the charts read the
`Mapped_*` domains the mapping phase writes, so mapping has to happen before
they can be drawn.

## One raw layer

Safety monitoring and RBQM monitoring run **in parallel over the same study
data**. There is one set of `input/Raw_*.csv` files describing one cohort at one
set of sites; `workflows/1_mappings/` maps it once; and both lenses read the
result. A number one lens shows can be checked against the other.

| Domain | Rows (cut 1) | Read by RBQM | Read by Safety |
| --- | --- | --- | --- |
| `Mapped_SUBJ` | 760 participants | every metric's denominator | joined into the three below |
| `Mapped_AE` | 2,553 events | AE rate, serious AE rate (`kri0001`, `kri0002`) | AE explorer, AE timelines |
| `Mapped_LB` | 52,464 results | Grade 3+ lab abnormality rate (`kri0005`) | histogram, outlier explorer, results over time, shift plot, delta-delta, eDISH |
| `Mapped_EG` | 6,650 results | — | QT explorer |

The joins that make this work live in the mapping workflows, not in either
lane. `Mapped_LB`, `Mapped_AE` and `Mapped_EG` each carry the participant's
site, treatment arm and demographics, attached by an **inner** join against
`Mapped_SUBJ` — which is also the data cleaning step, since an event recorded
against someone who never enrolled has no denominator to be a rate over and no
arm to be compared in.

Two consequences worth stating, because they are the point:

- **The lab KRI and the lab charts cannot disagree.** `Raw_LB` carries a
  numeric result, its units and the reference range it was measured against;
  the CTCAE toxicity grade is *derived from* those. The KRI counts the grade,
  the charts plot the result.
- **Every AE the charts draw is an AE the KRI counted.** `Mapped_AE` has 2,553
  rows; the AE explorer and AE timelines each render 2,553 rows; and the AE rate
  KRI's numerator, summed across sites, is 2,553.

`scripts/make-raw-data.R` builds the whole raw layer from a fixed seed and
`gsm.core::lSource`, and documents what it synthesizes and why. The CSVs are
committed: they are inputs, not derived data, and the script exists so they are
reproducible, not so they are rebuilt on every run.

Each chart workflow names the domain it reads in its own `meta.Data` key
(`Data: Mapped_LB`), and `scripts/run-safety-reports.R` resolves that to the
CSV the mapping phase wrote under `output/1_mappings/`.

## Snapshots and data cuts

The `site` branch carries one Project Snapshot per pipeline run. Its root is the
current snapshot, flat; `ps-NNN/` directories hold the history, indexed by
`snapshots.json`. `scripts/publish-snapshot.py` writes both, and the branch's
`PUBLISHING.md` documents the layout.

`scripts/advance-cut.R` moves the study forward by one data cut,
deterministically (fixed seed, append-only): a later visit for the participants
still on study, a handful of unmistakable lab outliers, twenty-five new adverse
events, five newly enrolled participants — and four more weeks of follow-up on
the continuing participants, so the rate metrics see a denominator that grew
along with their numerator. One raw layer means one set of changes, and both
lenses see all of it. Two snapshots of the same code over two data cuts is the
whole point of the snapshot model, and this script is how the second cut is
reproducible rather than hand-made.

## Layout

```
config/
  study-config.yaml    study identity + the domain registry
  data-config.yaml     which CSV supplies each input domain
  packages.yaml        source packages (informational)
manifest.csv           the environment record — package versions and SHAs
workflows/             analysis workflows, snapshotted from the packages
  1_mappings/          raw -> mapped domains          (gsm.mapping)
  2_metrics/           KRI and country metrics        (gsm.kri)
  3_reporting/         the reporting data model       (gsm.reporting)
  3_reports/           safety chart reports           (gsm.safety)
  4_modules/           KRI report modules             (gsm.kri)
input/                 study data — one synthetic raw layer (below)
output/                results written by the pipeline (regenerable; not committed)
scripts/
  make-raw-data.R      builds input/ from a fixed seed — the one raw layer
  run-pipeline.R       the entry point: og_run(), then the safety charts
  run-safety-reports.R workflows/3_reports, which og_run() does not cover
  advance-cut.R        advances the inputs by one data cut, deterministically
  publish-snapshot.py  copies a completed run onto the site branch
.github/workflows/     the Actions lane (templates — see the status note above)
```

## Domains

A domain is a config entry, not code: a label, the chart bundle that renders it,
and the workflow phases that produce its data. Adding one is a pull request
against `config/study-config.yaml`.

| Domain | Label  | Charts     | Workflow phases                                |
| ------ | ------ | ---------- | ---------------------------------------------- |
| safety | Safety | safety.viz | `1_mappings`, `3_reports`                      |
| rbqm   | RBQM   | gsm.viz    | `1_mappings`, `2_metrics`, `3_reporting`, `4_modules` |

Both domains share `1_mappings`: mapping is study-level, and domains are lenses
over the mapped data. Not just in principle — every chart workflow in
`3_reports` names a `Mapped_*` domain as its input.

`3_reports` and `3_reporting` are two different phases from two different
packages that happen to sort together — gsm.safety names its chart phase
`3_reports`, gsm.reporting uses `3_reporting`. Rather than rename either one,
the domain registry lists the phases each domain runs, explicitly.

## Provenance

`manifest.csv` records the org, package, version, repository, and commit SHA of
every package that produces results here. Rows with a blank SHA were installed
from a local build rather than a pinned GitHub commit, and are honestly recorded
as unpinned rather than given a plausible-looking SHA.

## Background

- Requirement: [obot.roadmap#134 — demo-301 v0](https://github.com/jwildfire/obot.roadmap/issues/134)
- Design record: [App design, 2026-07-28](https://jwildfire.github.io/obot.roadmap/reports/app-design-2026-07-28/)
- Engine: [jwildfire/open.gismo](https://github.com/jwildfire/open.gismo)
