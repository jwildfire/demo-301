# make-safety-inputs.R — write the Safety domain's input CSVs.
#
# WHY THIS EXISTS
#
# DEMO-301 carries two synthetic source families, because the two domains in
# config/study-config.yaml need two different data shapes:
#
#   * RBQM domain  -> input/Raw_*.csv, derived from `gsm.core::lSource`.
#     Operational/administrative data (queries, data entry lag, protocol
#     deviations). Column convention: studyid / subjid / invid.
#
#   * Safety domain -> input/adbds.csv, input/adae.csv, input/adeg.csv,
#     derived from `gsm.safety::ExampleData()` (ADaM-shaped BDS labs+vitals,
#     adverse events, and ECG). Column convention: USUBJID / TEST / STRESN /
#     ARM / VISIT.
#
# The Raw_* family cannot feed the Safety charts: `Raw_LB` carries a toxicity
# grade (`toxgrg_nsv`) but no numeric result, no reference range, and no
# baseline; and no `Raw_*` domain carries a treatment arm. Every workflow in
# workflows/3_reports/ requires at least `USUBJID` + `TEST` + `STRESN`, and
# several require `ARM`, `BASE`, or `STNRHI`. Rather than invent those values,
# DEMO-301 uses gsm.safety's packaged ADaM example data for the Safety domain
# and says so. Both families are synthetic; neither describes a real study, and
# they describe *different* participant sets.
#
# Both are inputs, not derived data: this script exists so the CSVs on main are
# reproducible from a pinned package, not so they are regenerated on every run.
#
# Usage:
#   Rscript scripts/make-safety-inputs.R [project_dir]

args <- commandArgs(trailingOnly = TRUE)
project_dir <- if (length(args) >= 1) args[[1]] else "."

if (!requireNamespace("gsm.safety", quietly = TRUE)) {
  stop("gsm.safety is required. Install it, then re-run.", call. = FALSE)
}

input_dir <- file.path(project_dir, "input")
dir.create(input_dir, recursive = TRUE, showWarnings = FALSE)

for (dataset in c("adbds", "adae", "adeg")) {
  df <- gsm.safety::ExampleData(dataset)
  out <- file.path(input_dir, paste0(dataset, ".csv"))
  utils::write.csv(df, out, row.names = FALSE, na = "")
  message(sprintf(
    "wrote %s (%d rows x %d cols)", out, nrow(df), ncol(df)
  ))
}
