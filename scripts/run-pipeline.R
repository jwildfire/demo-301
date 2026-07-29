# run-pipeline.R — the one entry point that produces a complete DEMO-301
# snapshot. Both lanes (local and Actions) call this, so both write the same
# tree.
#
#   1. RBQM domain    — workflows/1_mappings, 2_metrics, 3_reporting,
#                       4_modules            (open.gismo::og_run)
#   2. Safety domain  — the chart workflows in workflows/4_modules
#                       (scripts/run-safety-reports.R), then the overview's
#                       denominators (scripts/safety-census.R)
#
# Order is deliberate, and it is the opposite of what it used to be. The Safety
# charts no longer read a source family of their own: every one of them reads a
# `Mapped_*` domain, which is og_run()'s phase 1 output. Mapping has to happen
# before the charts can be drawn.
#
# og_run() regenerates _index.json and status.json by scanning what is on disk,
# which now happens before the charts exist; run-safety-reports.R rewrites both
# when it finishes, so the payload files still describe the whole snapshot.
#
# Usage:
#   Rscript scripts/run-pipeline.R [project_dir]

args <- commandArgs(trailingOnly = TRUE)
project_dir <- normalizePath(
  if (length(args) >= 1) args[[1]] else ".",
  mustWork = TRUE
)

script_dir <- file.path(project_dir, "scripts")

# --- The curated manifest ---------------------------------------------------
#
# manifest.csv on main is hand-curated: it names the org each package actually
# lives under (gsm.safety and open.gismo are `jwildfire`, not
# `Gilead-BioStats`) and pins a commit SHA per package. The Actions lane clones
# and installs from exactly those fields, so they have to survive a run.
#
# open.gismo::og_run() ends by calling its own manifest writer, which
# regenerates the file from the installed library: it hardcodes org
# "Gilead-BioStats" for every package, writes an empty url/sha, and omits
# gsm.safety entirely. That turns a reproducible pin into an unpinned
# default-branch install. Until that is fixed upstream, hold the curated
# contents across the run and write them back.
manifest_path <- file.path(project_dir, "manifest.csv")
curated_manifest <- if (file.exists(manifest_path)) {
  readLines(manifest_path, warn = FALSE)
} else {
  NULL
}

# --- 1. RBQM domain ---------------------------------------------------------
message("=== RBQM domain: og_run() ===")
res <- open.gismo::og_run(project_dir)

# --- 2. Safety domain -------------------------------------------------------
# Reads the Mapped_* CSVs phase 1 just wrote.
message("=== Safety domain: chart workflows in workflows/4_modules ===")
safety <- system2(
  file.path(R.home("bin"), "Rscript"),
  c(shQuote(file.path(script_dir, "run-safety-reports.R")), shQuote(project_dir))
)

# --- 3. Safety overview denominators ---------------------------------------
# Reduces the mapped domains to the census, exposure and coverage figures the
# Safety overview leads with, so the browser never loads a 57k-row lab domain.
message("=== Safety domain: overview census ===")
census <- system2(
  file.path(R.home("bin"), "Rscript"),
  c(shQuote(file.path(script_dir, "safety-census.R")), shQuote(project_dir))
)

# --- 4. Restore the curated manifest ---------------------------------------
if (!is.null(curated_manifest)) {
  writeLines(curated_manifest, manifest_path)
  message("Restored the curated manifest.csv.")
}

message("\n=== counts ===")
print(res$counts)
message("=== timings (s) ===")
print(res$timings)

if (!identical(safety, 0L)) {
  message(
    "\nNOTE: the Safety chart lane exited non-zero - see output/4_modules/charts.json."
  )
}

if (!identical(census, 0L)) {
  message("\nNOTE: the safety census lane exited non-zero.")
}
