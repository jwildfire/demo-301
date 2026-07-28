# DEMO-301 — Safety Review

A complete, forkable clinical study repository for
[open.gismo](https://github.com/jwildfire/open.gismo). Everything the analysis
needs — configuration, workflows, input data, and the environment record — lives
here as plain files. No database, no server, no build step.

**The data in this repository is synthetic.** No real participant, site, or
study data appears anywhere in this repo, and none ever should. It comes from
two example datasets shipped with the analytics packages — see [Two source
families](#two-source-families) below.

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
The script runs the safety charts first, then `og_run()`, so the payload files
`og_run()` regenerates describe both domains.

## Two source families

The two domains need two different data shapes, so the study carries two
synthetic source families. Both are example data shipped with the packages;
neither describes a real study, and they describe *different* participant sets.

| Family | Files | Derived from | Columns |
| --- | --- | --- | --- |
| RBQM | `input/Raw_*.csv` | `gsm.core::lSource` | `studyid` / `subjid` / `invid` |
| Safety | `input/adbds.csv`, `adae.csv`, `adeg.csv` | `gsm.safety::ExampleData()` | `USUBJID` / `TEST` / `STRESN` / `ARM` |

The `Raw_*` family cannot feed the safety charts: `Raw_LB` carries a toxicity
grade but no numeric result, no reference range, and no baseline, and no `Raw_*`
domain carries a treatment arm. Every workflow in `workflows/3_reports/` needs
at least `USUBJID` + `TEST` + `STRESN`, and several need `ARM`, `BASE`, or
`STNRHI`. Rather than invent those values, the safety domain uses gsm.safety's
packaged ADaM example data and says so. `scripts/make-safety-inputs.R`
regenerates those three CSVs from the pinned package.

Each chart workflow names the domain it reads in its own `meta.Data` key
(`Data: adbds`), and that domain resolves to a file through
`config/data-config.yaml` — the same indirection the mapping workflows use.

## Snapshots and data cuts

The `site` branch carries one Project Snapshot per pipeline run. Its root is the
current snapshot, flat; `ps-NNN/` directories hold the history, indexed by
`snapshots.json`. `scripts/publish-snapshot.py` writes both, and the branch's
`PUBLISHING.md` documents the layout.

`scripts/advance-cut.R` moves the study forward by one data cut, deterministically
(fixed seed, append-only): a later visit for about a third of participants with a
handful of unmistakable outliers, about twenty new adverse events, and five newly
enrolled participants, applied to both source families. Two snapshots of the same
code over two data cuts is the whole point of the snapshot model, and this script
is how the second cut is reproducible rather than hand-made.

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
input/                 study data — synthetic; two source families (below)
output/                results written by the pipeline (regenerable; not committed)
scripts/
  run-pipeline.R       the entry point: safety charts, then og_run()
  run-safety-reports.R workflows/3_reports, which og_run() does not cover
  make-safety-inputs.R regenerates the safety domain's input CSVs
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
over the mapped data.

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
