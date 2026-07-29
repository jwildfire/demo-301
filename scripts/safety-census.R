# safety-census.R — the Safety overview's denominators.
#
# The Safety overview leads with exposure and census, not with event counts:
# how many participants there are, how many are on treatment, how much
# person-time has accrued, who has left, and how completely the safety data
# itself has been collected. A low event rate at a visit where 40% of
# participants have no lab result is not reassurance, and the only way the app
# can tell those apart is to be handed the denominator.
#
# The arithmetic lives in gsm.safety::SafetyCensus(); this script is the study's
# wiring. It reads the Mapped_* CSVs the mapping phase wrote and writes one
# compact payload:
#
#   output/4_modules/safety_census.json
#
# That file exists so the browser never has to. Mapped_LB alone is 57k rows and
# several megabytes; the census it reduces to is a few kilobytes, and the app
# fetches the reduction rather than the raw domain.
#
# Every figure is pooled across treatment arms — a study-team safety view is a
# blinded view.
#
# Order matters: run this AFTER og_run(), which writes the mapped CSVs.
#
# Usage:
#   Rscript scripts/safety-census.R [project_dir]

args <- commandArgs(trailingOnly = TRUE)
project_dir <- normalizePath(
  if (length(args) >= 1) args[[1]] else ".",
  mustWork = TRUE
)

for (pkg in c("gsm.safety", "jsonlite")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop(sprintf("Package '%s' is required by this script.", pkg), call. = FALSE)
  }
}

# A mapped domain is the mapping phase's output: Mapped_LB lives at
# output/1_mappings/LB/Mapped_LB.csv. A domain the study does not map is NULL,
# and SafetyCensus() reports the figures that depend on it as absent rather
# than as zero.
read_mapped <- function(domain) {
  path <- file.path(
    project_dir, "output", "1_mappings", domain, paste0("Mapped_", domain, ".csv")
  )
  if (!file.exists(path)) {
    message(sprintf("  %-10s not mapped - skipping", domain))
    return(NULL)
  }
  df <- utils::read.csv(path, stringsAsFactors = FALSE)
  message(sprintf("  %-10s %6d rows", domain, nrow(df)))
  df
}

message("Reading mapped domains for the safety census ...")
dfSubjects <- read_mapped("SUBJ")
if (is.null(dfSubjects)) {
  stop("No Mapped_SUBJ - run the mapping phase (og_run) first.", call. = FALSE)
}

lCensus <- gsm.safety::SafetyCensus(
  dfSubjects = dfSubjects,
  dfLabs = read_mapped("LB"),
  dfECG = read_mapped("EG"),
  dfAE = read_mapped("AE"),
  dfDisposition = read_mapped("STUDCOMP")
)

out_dir <- file.path(project_dir, "output", "4_modules")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out_path <- file.path(out_dir, "safety_census.json")
writeLines(
  jsonlite::toJSON(lCensus, auto_unbox = TRUE, pretty = TRUE, na = "null"),
  out_path
)

message(sprintf(
  "Safety census: %d figures, %d coverage rows, %d disposition states -> %s",
  nrow(lCensus$Census), nrow(lCensus$Coverage), nrow(lCensus$Disposition),
  sub(paste0("^", project_dir, "/"), "", out_path)
))
