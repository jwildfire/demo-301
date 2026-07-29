# run-safety-reports.R — run the Safety domain chart workflows.
#
# `open.gismo::og_run()` covers the four RBQM phases (1_mappings, 2_metrics,
# 3_reporting, 4_modules). It does not cover `workflows/3_reports/` — the
# gsm.safety chart workflows registered to the `safety` domain in
# config/study-config.yaml. This script runs those, on the same workr
# primitives og_run() uses (MakeWorkflowList + RunWorkflow), and writes their
# self-contained HTML to
#
#   output/3_reports/{workflow_id}/{workflow_id}.html
#
# Each chart workflow declares the domain it reads in `meta.Data`. Every one of
# them now names a *mapped* domain — `Mapped_LB`, `Mapped_AE`, `Mapped_EG` —
# which resolves to the CSV the mapping phase wrote at
#
#   output/1_mappings/{ID}/{domain}.csv
#
# so the charts and the RBQM metrics read the same rows, produced by the same
# workflows, from the one raw layer in input/. A domain that is not a mapped
# one still resolves through config/data-config.yaml, falling back to
# `input/{domain}.csv`. Columns are coerced to the types the workflow's own
# `spec` declares, so a CSV round-trip cannot silently turn a numeric result
# into a string.
#
# Order matters: run this AFTER og_run(), because the mapped CSVs this reads
# are og_run()'s phase 1 output. og_run() regenerates _index.json and
# status.json by scanning what is on disk, so this script refreshes both
# again at the end — otherwise a chart rendered after og_run() finished would
# be recorded as `not_run`.
#
# Usage:
#   Rscript scripts/run-safety-reports.R [project_dir]

args <- commandArgs(trailingOnly = TRUE)
project_dir <- normalizePath(
  if (length(args) >= 1) args[[1]] else ".",
  mustWork = TRUE
)

for (pkg in c("workr", "gsm.safety", "yaml", "jsonlite")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop(sprintf("Package '%s' is required by this script.", pkg), call. = FALSE)
  }
}

wf_dir <- file.path(project_dir, "workflows", "3_reports")
if (!dir.exists(wf_dir)) {
  stop("No workflows/3_reports directory in ", project_dir, call. = FALSE)
}

data_config <- local({
  path <- file.path(project_dir, "config", "data-config.yaml")
  if (file.exists(path)) yaml::read_yaml(path) else list()
})

resolve_input <- function(domain) {
  # A mapped domain is the mapping phase's output, not an input file.
  # `Mapped_LB` -> output/1_mappings/LB/Mapped_LB.csv
  if (grepl("^Mapped_", domain)) {
    return(file.path(
      project_dir, "output", "1_mappings",
      sub("^Mapped_", "", domain), paste0(domain, ".csv")
    ))
  }
  configured <- data_config[[domain]]
  path <- if (is.null(configured)) {
    file.path(project_dir, "input", paste0(domain, ".csv"))
  } else if (grepl("^(/|[A-Za-z]:)", configured)) {
    configured
  } else {
    file.path(project_dir, configured)
  }
  path
}

# Coerce a data.frame's columns to the types the workflow spec declares.
coerce_to_spec <- function(df, spec_domain) {
  if (is.null(spec_domain)) {
    return(df)
  }
  for (col in names(spec_domain)) {
    if (!col %in% names(df)) next
    type <- spec_domain[[col]]$type %||% "character"
    df[[col]] <- switch(
      type,
      numeric = suppressWarnings(as.numeric(df[[col]])),
      integer = suppressWarnings(as.integer(df[[col]])),
      character = as.character(df[[col]]),
      df[[col]]
    )
  }
  df
}
`%||%` <- function(x, y) if (is.null(x)) y else x

lWorkflows <- workr::MakeWorkflowList(strPath = wf_dir)
message(sprintf(
  "Running %d Safety chart workflow(s) from %s",
  length(lWorkflows), wf_dir
))

results <- list()
cache <- list()

for (id in names(lWorkflows)) {
  wf <- lWorkflows[[id]]
  wf_id <- wf$meta$ID %||% id
  domain <- wf$meta$Data

  entry <- list(
    id = wf_id,
    title = wf$meta$Name %||% wf_id,
    description = wf$meta$Description %||% "",
    data = domain %||% NA_character_,
    html = NA_character_,
    status = "failed",
    error = NULL
  )

  outcome <- tryCatch(
    {
      if (is.null(domain) || !nzchar(domain)) {
        stop("workflow declares no `meta.Data` input domain", call. = FALSE)
      }
      path <- resolve_input(domain)
      if (!file.exists(path)) {
        stop(sprintf(
          "data for domain '%s' not found at %s%s", domain, path,
          if (grepl("^Mapped_", domain)) {
            " - run the mapping phase (og_run) first"
          } else {
            ""
          }
        ), call. = FALSE)
      }
      if (is.null(cache[[domain]])) {
        cache[[domain]] <- utils::read.csv(path, stringsAsFactors = FALSE)
      }
      dfResults <- coerce_to_spec(cache[[domain]], wf$spec$dfResults)

      out_dir <- file.path(project_dir, "output", "3_reports", wf_id)
      dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

      # The workflow's first step is `getwd`, which becomes strOutputDir, so
      # the report lands wherever we are standing.
      old_wd <- setwd(out_dir)
      on.exit(setwd(old_wd), add = TRUE)
      suppressWarnings(
        workr::RunWorkflow(wf, lData = list(dfResults = dfResults))
      )
      setwd(old_wd)

      html <- file.path("output", "3_reports", wf_id, paste0(wf_id, ".html"))
      if (!file.exists(file.path(project_dir, html))) {
        stop("workflow completed but wrote no HTML", call. = FALSE)
      }
      entry$html <- html
      entry$status <- "completed"
      entry
    },
    error = function(e) {
      entry$error <- conditionMessage(e)
      entry
    }
  )

  results[[wf_id]] <- outcome
  message(sprintf(
    "  %-26s %-6s %s%s",
    wf_id,
    outcome$data,
    outcome$status,
    if (is.null(outcome$error)) "" else paste0(" - ", outcome$error)
  ))
}

# A reports.json for the Safety domain, mirroring the shape og_run() writes for
# output/4_modules. Failures are recorded, not dropped.
payload_dir <- file.path(project_dir, "output", "3_reports")
dir.create(payload_dir, recursive = TRUE, showWarnings = FALSE)
writeLines(
  jsonlite::toJSON(
    list(reports = unname(results)),
    auto_unbox = TRUE, pretty = TRUE, null = "null"
  ),
  file.path(payload_dir, "reports.json")
)

n_ok <- sum(vapply(results, function(r) r$status == "completed", logical(1)))
message(sprintf(
  "Safety charts: %d of %d completed.", n_ok, length(results)
))

# Refresh the payload files so a standalone run of this script leaves
# status.json / _index.json consistent with what is on disk. og_run() calls the
# same writer; it is not exported yet, so reach for it defensively.
try(
  {
    writer <- get("og_write_status_json", envir = asNamespace("open.gismo"))
    writer(project_dir)
    message("Refreshed _index.json and status.json.")
  },
  silent = TRUE
)

if (n_ok == 0L) {
  quit(status = 1L)
}
