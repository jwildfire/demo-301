# install-manifest.R — install the packages pinned in manifest.csv, with their
# CRAN dependencies resolved first and in an order that satisfies the
# dependencies they have on each other.
#
# This exists because the two obvious ways to do it both fail on this project:
#
#   * `pak::pkg_install("Gilead-BioStats/gsm.core")` and friends resolve GitHub
#     refs through api.github.com, which the SSO/SAML-protected Gilead org
#     rejects even for public repositories.
#   * `R CMD INSTALL` on a plain clone installs nothing it needs. That is how
#     the Actions lane failed silently every Monday from 2026-08-03 to
#     2026-08-17: `dependencies 'DBI', 'dbplyr', 'duckdb', 'log4r' are not
#     available for package 'gsm.core'`.
#
# `remotes::install_deps()` would resolve the CRAN half, but every one of these
# packages carries a `Remotes:` field pointing at Gilead-BioStats GitHub refs
# on `@main`/`@dev`. Following those would both hit the SAML wall and silently
# replace the manifest's pinned commits with whatever the default branch holds
# today — the opposite of what a pinned manifest is for. So the `Remotes:`
# field is deliberately ignored here: the pins in manifest.csv are the only
# source of truth for which build of an in-manifest package gets installed.
#
# What it does, in order:
#   1. clone each pinned repository at its SHA (or reuse an existing clone),
#   2. read every DESCRIPTION and take the union of Depends/Imports/LinkingTo,
#   3. install the CRAN packages in that union that are not already present,
#   4. topologically sort the manifest packages by their dependencies on each
#      other, and `R CMD INSTALL` them in that order.
#
# Step 4 is not decoration. manifest.csv lists gsm.reporting before workr, and
# gsm.reporting Imports workr, so installing in file order fails even once the
# CRAN half is resolved.
#
# Usage:
#   Rscript scripts/install-manifest.R [project_dir] [source_dir]
#
# `project_dir` holds manifest.csv (default "."), `source_dir` is where the
# clones are kept (default "/tmp/pkgsrc"). Re-running is cheap: existing clones
# at the right SHA are reused.

args <- commandArgs(trailingOnly = TRUE)
project_dir <- normalizePath(
  if (length(args) >= 1 && nzchar(args[[1]])) args[[1]] else ".",
  mustWork = TRUE
)
source_dir <- if (length(args) >= 2 && nzchar(args[[2]])) args[[2]] else "/tmp/pkgsrc"
dir.create(source_dir, recursive = TRUE, showWarnings = FALSE)
source_dir <- normalizePath(source_dir, mustWork = TRUE)

fail <- function(...) {
  message("\n::error::", ...)
  quit(status = 1L, save = "no")
}

# --- repositories -----------------------------------------------------------
# setup-r's use-public-rspm points the default repo at Posit's binary mirror,
# which is what makes duckdb an eight-second install rather than an eight-minute
# one. Fall back to the CRAN cloud if this is run somewhere that has no repo set.
repos <- getOption("repos")
if (is.null(repos) || !length(repos) || any(repos %in% c("@CRAN@", ""))) {
  repos <- c(CRAN = "https://cloud.r-project.org")
  options(repos = repos)
}
message("repositories: ", paste(repos, collapse = ", "))

# --- 1. clone each pinned repository ---------------------------------------
manifest_path <- file.path(project_dir, "manifest.csv")
if (!file.exists(manifest_path)) fail("no manifest.csv in ", project_dir)
manifest <- utils::read.csv(manifest_path, stringsAsFactors = FALSE)

required_cols <- c("org", "package", "sha")
missing_cols <- setdiff(required_cols, names(manifest))
if (length(missing_cols)) {
  fail("manifest.csv is missing column(s): ", paste(missing_cols, collapse = ", "))
}
manifest <- manifest[nzchar(trimws(manifest$package)), , drop = FALSE]
if (!nrow(manifest)) fail("manifest.csv lists no packages")

git <- function(...) {
  status <- system2("git", c(...), stdout = TRUE, stderr = TRUE)
  code <- attr(status, "status")
  list(ok = is.null(code) || identical(code, 0L), output = status)
}

clone_dirs <- character(nrow(manifest))
for (i in seq_len(nrow(manifest))) {
  pkg <- trimws(manifest$package[[i]])
  org <- trimws(manifest$org[[i]])
  sha <- trimws(if (is.na(manifest$sha[[i]])) "" else manifest$sha[[i]])
  dest <- file.path(source_dir, pkg)
  clone_dirs[[i]] <- dest

  if (!dir.exists(file.path(dest, ".git"))) {
    unlink(dest, recursive = TRUE)
    message("cloning ", org, "/", pkg)
    res <- git("clone", "--quiet", sprintf("https://github.com/%s/%s.git", org, pkg), dest)
    if (!res$ok) fail("clone failed for ", org, "/", pkg, ": ", paste(res$output, collapse = "\n"))
  }
  if (nzchar(sha)) {
    res <- git("-C", dest, "checkout", "--quiet", sha)
    if (!res$ok) fail("checkout of ", sha, " failed for ", pkg, ": ", paste(res$output, collapse = "\n"))
    head_sha <- git("-C", dest, "rev-parse", "HEAD")$output[[1]]
    if (!identical(head_sha, sha)) {
      fail(pkg, " is at ", head_sha, " but manifest.csv pins ", sha)
    }
    message("  ", pkg, " @ ", substr(sha, 1, 10))
  } else {
    # Loud, because an unpinned package makes the whole snapshot unreproducible.
    message("::warning::no SHA pinned for ", pkg, " — installing the default branch tip")
  }
}

# --- 2. read the dependency graph ------------------------------------------
dep_fields <- c("Depends", "Imports", "LinkingTo")

parse_deps <- function(path) {
  dcf <- read.dcf(file.path(path, "DESCRIPTION"))
  present <- intersect(dep_fields, colnames(dcf))
  raw <- paste(dcf[1, present], collapse = ",")
  names <- trimws(strsplit(raw, ",")[[1]])
  names <- sub("\\s*\\(.*", "", names)      # drop version constraints
  names <- names[nzchar(names) & names != "R"]
  unique(names)
}

pkgs <- trimws(manifest$package)
deps <- stats::setNames(lapply(clone_dirs, parse_deps), pkgs)

# Base and recommended packages ship with R; asking CRAN for them is an error.
bundled <- rownames(installed.packages(priority = c("base", "recommended")))
external <- setdiff(unique(unlist(deps, use.names = FALSE)), c(pkgs, bundled))

# --- 3. install the CRAN half ----------------------------------------------
have <- rownames(installed.packages())
needed <- setdiff(external, have)
message(
  "\nCRAN dependencies: ", length(external), " required, ",
  length(needed), " missing"
)
if (length(needed)) {
  message("  installing: ", paste(sort(needed), collapse = ", "))
  install.packages(needed, quiet = FALSE)
  still_missing <- setdiff(needed, rownames(installed.packages()))
  if (length(still_missing)) {
    fail("could not install CRAN dependencies: ", paste(sort(still_missing), collapse = ", "))
  }
}

# --- 4. install the pinned packages, in dependency order -------------------
order <- character(0)
remaining <- pkgs
while (length(remaining)) {
  ready <- remaining[vapply(
    remaining,
    function(p) all(intersect(deps[[p]], pkgs) %in% order),
    logical(1)
  )]
  if (!length(ready)) {
    fail(
      "circular dependency among the manifest packages: ",
      paste(remaining, collapse = ", ")
    )
  }
  order <- c(order, ready)
  remaining <- setdiff(remaining, ready)
}

if (!identical(order, pkgs)) {
  message(
    "\ninstall order differs from manifest order (dependencies between the ",
    "pinned packages):\n  manifest: ", paste(pkgs, collapse = " -> "),
    "\n  install:  ", paste(order, collapse = " -> ")
  )
}

lib <- .libPaths()[[1]]
message("\ninstalling ", length(order), " pinned packages into ", lib)
for (pkg in order) {
  dest <- clone_dirs[[match(pkg, pkgs)]]
  cat(sprintf("::group::install %s\n", pkg))
  code <- system2(
    file.path(R.home("bin"), "R"),
    c("CMD", "INSTALL", "--no-docs", "--no-multiarch", shQuote(dest))
  )
  cat("::endgroup::\n")
  if (!identical(code, 0L)) fail("R CMD INSTALL failed for ", pkg)
}

# --- 5. say what was installed ---------------------------------------------
message("\n=== installed from manifest.csv ===")
for (i in seq_len(nrow(manifest))) {
  pkg <- pkgs[[i]]
  version <- tryCatch(
    as.character(utils::packageVersion(pkg)),
    error = function(e) "NOT INSTALLED"
  )
  expected <- trimws(manifest$version[[i]])
  flag <- if (identical(version, expected)) "" else sprintf("  <-- manifest says %s", expected)
  message(sprintf("  %-14s %-12s %s%s", pkg, version, substr(trimws(manifest$sha[[i]]), 1, 10), flag))
  if (identical(version, "NOT INSTALLED")) fail(pkg, " is not loadable after installation")
}
