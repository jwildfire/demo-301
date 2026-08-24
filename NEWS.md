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

# Earlier releases

- None yet — the live site at [jwildfire.github.io/demo-301](https://jwildfire.github.io/demo-301/) tracks the `site` branch.
