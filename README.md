# DEMO-301 — Safety Review

A complete, forkable clinical study repository for
[open.gismo](https://github.com/jwildfire/open.gismo). Everything the analysis
needs — configuration, workflows, input data, and the environment record — lives
here as plain files. No database, no server, no build step.

**The data in this repository is synthetic.** It is derived from
`gsm.core::lSource`, the example source data shipped with the gsm analytics
packages. No real participant, site, or study data appears anywhere in this
repo, and none ever should.

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
> been exercised, and GitHub Pages is not enabled on this repo. Locally,
> `og_validate()` passes on all 12 input domains. See
> [hub#134](https://github.com/jwildfire/obot.roadmap/issues/134) for where this
> sits in the plan.

## Running it locally

```r
# install.packages("remotes"); remotes::install_github("jwildfire/open.gismo")
open.gismo::og_validate(".")   # are the inputs ready?
open.gismo::og_run(".")        # run every phase, write output/
open.gismo::og_app(".")        # explore the results
```

`og_validate()` is the forgiveness layer: it names exactly which domain, file,
and column is missing rather than failing deep inside a pipeline step.

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
input/                 study data — synthetic Raw_*.csv
output/                results written by og_run() (regenerable; not committed)
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
