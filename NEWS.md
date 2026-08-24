<!--
NEWS.md is the running release log and the draft of each release's notes
(obot.agent/skills/rc-release-notes/SKILL.md): newest section first; unreleased
work accumulates under a vX.Y.Z (Upcoming) heading that loses the suffix when
the release is cut. Releases here are pushes of the live `site` branch; the
first formal release will be proposed as a main → site RC PR.
-->

# demo-301 v0.1.0 (Upcoming)

- **The safety metrics run in the pipeline**, and the chart phase folds into the `4_modules` step, aligning the demo study with the gsm workflow layout. ([#1](https://github.com/jwildfire/demo-301/pull/1))
- **The study advanced to data cut 2 on a unified raw data layer**, with both lenses (RBQM and Safety) rendering from the same source, disposition and eligibility data added, and the QTLs running.
- **Both snapshots rebuild from one recorded script**, so the published site's provenance is reproducible.
- **The weekly pipeline runs in Actions**, instead of failing on every one of its first three scheduled Mondays. The pinned packages are installed with their CRAN dependencies resolved and in an order that satisfies the dependencies they have on each other, and the snapshot Actions publishes is labelled `gha-<run>` so the provenance chip says which lane built it. ([#4](https://github.com/jwildfire/demo-301/issues/4))
- **A failed pipeline now says so.** A failing run raises a GitHub issue assigned to the maintainer and a green run closes it again; a separate weekly watchdog notices the weeks the pipeline does not run at all. Three consecutive failures went unnoticed before this, because a red check in the Actions tab is not a signal anybody receives.
- **Two stale package pins corrected, and a check added so the next one is found in a minute rather than in a pipeline run.** `manifest.csv` pinned `gsm.safety` at a commit from before v1.1.0 added the four functions the safety workflows call, and `open.gismo` at a commit whose bundled app shell is a quarter the size of the one the site serves. Both carried the exact version string the manifest claimed, so comparing versions found neither; `install-manifest.R` now resolves every `pkg::name` the project references against the installed builds and refuses the run if any is absent.
- **`Build Site` can run, and does.** It had zero runs ever, and could not have succeeded from anywhere: the `github-pages` environment admits only `gh-pages` and `site`, Pages here publishes the `site` branch directly rather than through Actions, and its `push: branches: [site]` trigger could never fire because the `site` branch is a static tree carrying no workflows at all. It now runs on `workflow_run` after each pipeline run. The deploy half is kept, dormant, in case Pages is ever moved onto it.
- **A snapshot is checked before it is published, not after.** Pages serves the `site` branch root verbatim, so the commit that lands on it is the publication; `.github/scripts/assert-site-contract.sh` runs on the assembled tree before that commit and refuses to push one that is missing a payload file, has an empty artifact directory, or has not recorded the run's own snapshot in `snapshots.json`.

# Earlier releases

- None yet — the live site at [jwildfire.github.io/demo-301](https://jwildfire.github.io/demo-301/) tracks the `site` branch.
