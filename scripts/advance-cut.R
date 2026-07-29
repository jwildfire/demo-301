# advance-cut.R — advance the study's input data by one data cut.
#
# A DEMO-301 snapshot is only interesting next to another snapshot, and the
# difference between two snapshots has to be a difference in the *data*, not in
# the code. This script produces that difference deterministically: same seed,
# same result, every time, on any machine.
#
# There is one raw layer now (see scripts/make-raw-data.R), so there is one set
# of changes, and both lenses on the study see all of it:
#
#   * a later scheduled visit for the participants still on study — labs and
#     ECGs, carried forward from each participant's own most recent result with
#     modest noise, and with the toxicity trajectory continuing for the
#     participants who were already trending;
#   * a handful of unmistakable laboratory outliers, so the eDISH view and the
#     histogram have something new to find and the Grade 3+ Lab Abnormality KRI
#     moves for the same sites;
#   * about twenty-five new adverse events on existing participants;
#   * five newly enrolled participants, with a baseline, the new visit, and a
#     first adverse event each.
#
# The script appends and never edits, so cut N+1 is a strict superset of cut N
# and the diff on `main` stays readable. It refuses to run twice: it stops if
# the visit it would add is already present.
#
# Usage:
#   Rscript scripts/advance-cut.R [project_dir]

args <- commandArgs(trailingOnly = TRUE)
project_dir <- normalizePath(
  if (length(args) >= 1) args[[1]] else ".",
  mustWork = TRUE
)

set.seed(20260801)

VISIT_NAME <- "Week 16"
VISIT_NUM <- 9L
VISIT_DAY <- 113L
EG_VISIT_NUM <- 5L
N_NEW_SUBJECTS <- 5L
N_NEW_AES <- 25L
N_OUTLIER_SUBJECTS <- 8L
# Participants who reach the new visit: those who were still on study near the
# end of the previous cut.
MIN_TIME_ON_STUDY <- 40L
# Days of follow-up each continuing participant gains in this cut.
TIME_GAINED <- 28L

input <- function(name) file.path(project_dir, "input", name)

# Every identifier in this study is deliberately non-numeric (`S384`,
# `SITE4323`), but reading as character costs nothing and removes a whole class
# of type-inference surprise.
read_raw <- function(name) {
  utils::read.csv(input(name), colClasses = "character")
}
write_raw <- function(df, name) {
  utils::write.csv(df, input(name), row.names = FALSE, na = "")
  message(sprintf("  %-18s -> %d rows", name, nrow(df)))
}

subj <- read_raw("Raw_SUBJ.csv")
enroll <- read_raw("Raw_ENROLL.csv")
ae <- read_raw("Raw_AE.csv")
lb <- read_raw("Raw_LB.csv")
eg <- read_raw("Raw_EG.csv")

if (VISIT_NAME %in% lb$visnam) {
  stop(
    sprintf(
      "input/Raw_LB.csv already contains visit '%s' - the data has already been advanced.",
      VISIT_NAME
    ),
    call. = FALSE
  )
}

cohort <- subj[subj$enrollyn == "Y", , drop = FALSE]
continuing <- cohort$subjid[
  as.integer(cohort$timeonstudy) >= MIN_TIME_ON_STUDY
]
outliers <- sort(sample(continuing, N_OUTLIER_SUBJECTS))
cut_date <- as.character(as.Date(max(lb$lb_dt, na.rm = TRUE)) + 28)

message(sprintf(
  "Advancing %d of %d participants to '%s' (%d carrying clear lab outliers).",
  length(continuing), nrow(cohort), VISIT_NAME, length(outliers)
))

# Each participant's most recent result per test, as the base for the new visit.
latest_by_test <- function(df, ids, test_col, order_col, value_col) {
  sub <- df[df$subjid %in% ids & nzchar(df[[value_col]]), , drop = FALSE]
  sub <- sub[order(sub$subjid, sub[[test_col]], as.numeric(sub[[order_col]])), ]
  key <- paste(sub$subjid, sub[[test_col]], sep = "\r")
  sub[!duplicated(key, fromLast = TRUE), , drop = FALSE]
}

# The CTCAE grade is derived from the result, in this script exactly as in
# make-raw-data.R, so an advanced cut cannot drift into saying one thing in the
# lab charts and another in the lab KRI.
GRADE_CUTS <- list(
  "Alanine Aminotransferase" = list("high", c(41, 123, 205, 820)),
  "Aspartate Aminotransferase" = list("high", c(37, 111, 185, 740)),
  "Alkaline Phosphatase" = list("high", c(120, 300, 600, 2400)),
  "Bilirubin" = list("high", c(1.2, 1.8, 3.6, 12)),
  "Gamma Glutamyl Transferase" = list("high", c(48, 120, 240, 960)),
  "Creatinine" = list("high", c(1.2, 1.8, 3.6, 7.2)),
  "Glucose" = list("high", c(5.6, 8.9, 13.9, 27.8)),
  "Potassium" = list("high", c(5.1, 5.5, 6.0, 7.0)),
  "Sodium" = list("low", c(135, 130, 125, 120)),
  "Albumin" = list("low", c(3.5, 3.0, 2.0, 1.0)),
  "Hemoglobin" = list("low", c(12, 10, 8, 6.5)),
  "Hematocrit" = list("low", c(36, 30, 24, 20)),
  "Platelets" = list("low", c(150, 75, 50, 25)),
  "White Blood Cells" = list("low", c(4, 3, 2, 1)),
  "Neutrophils" = list("low", c(1.8, 1.5, 1.0, 0.5)),
  "Lymphocytes" = list("low", c(1.0, 0.8, 0.5, 0.2))
)

DeriveGrade <- function(test, value) {
  vapply(seq_along(test), function(i) {
    rule <- GRADE_CUTS[[test[i]]]
    if (is.null(rule)) {
      return("0")
    }
    cuts <- rule[[2]]
    n <- if (identical(rule[[1]], "high")) {
      sum(value[i] > cuts)
    } else {
      sum(value[i] < cuts)
    }
    as.character(n)
  }, character(1))
}

DecimalsFor <- function(test) {
  ifelse(
    test %in% c("Bilirubin", "Creatinine"), 2,
    ifelse(
      test %in% c(
        "Glucose", "Potassium", "Albumin", "Hemoglobin", "Hematocrit",
        "White Blood Cells", "Neutrophils", "Lymphocytes"
      ), 1, 0
    )
  )
}

# ---------------------------------------------------------------------------
# Labs
# ---------------------------------------------------------------------------

new_lb <- latest_by_test(lb, continuing, "lbtstnam", "visnum", "lbstresn")
new_lb$visnam <- VISIT_NAME
new_lb$visnum <- as.character(VISIT_NUM)
new_lb$lb_dy <- as.character(VISIT_DAY)
new_lb$lb_dt <- cut_date
new_lb$lbblfl <- ""

value <- as.numeric(new_lb$lbstresn) * (1 + stats::rnorm(nrow(new_lb), 0, 0.08))

# The outliers: hepatic and haematological markers pushed to many multiples of
# their limit of normal, which is what the eDISH view and the histogram are for.
high_markers <- c(
  "Alanine Aminotransferase", "Aspartate Aminotransferase", "Bilirubin",
  "Gamma Glutamyl Transferase"
)
low_markers <- c("Platelets", "Neutrophils")
is_high <- new_lb$subjid %in% outliers & new_lb$lbtstnam %in% high_markers
is_low <- new_lb$subjid %in% outliers & new_lb$lbtstnam %in% low_markers
if (any(is_high)) {
  value[is_high] <- as.numeric(new_lb$lbstnrhi[is_high]) *
    stats::runif(sum(is_high), 3.5, 12)
}
if (any(is_low)) {
  value[is_low] <- as.numeric(new_lb$lbstnrlo[is_low]) *
    stats::runif(sum(is_low), 0.12, 0.35)
}

value <- round(value, DecimalsFor(new_lb$lbtstnam))
new_lb$lbstresn <- as.character(value)
new_lb$toxgrg_nsv <- DeriveGrade(new_lb$lbtstnam, value)

# ---------------------------------------------------------------------------
# ECG
# ---------------------------------------------------------------------------

new_eg <- latest_by_test(eg, continuing, "egtstnam", "visnum", "egstresn")
new_eg$visnam <- VISIT_NAME
new_eg$visnum <- as.character(EG_VISIT_NUM)
new_eg$eg_dy <- as.character(VISIT_DAY)
new_eg$eg_dt <- cut_date
new_eg$egblfl <- ""
new_eg$egstresn <- as.character(round(
  as.numeric(new_eg$egstresn) * (1 + stats::rnorm(nrow(new_eg), 0, 0.035))
))

# ---------------------------------------------------------------------------
# New participants
# ---------------------------------------------------------------------------

new_ids <- sprintf("S9000%02d", seq_len(N_NEW_SUBJECTS))
donor_rows <- sample(which(subj$enrollyn == "Y"), N_NEW_SUBJECTS)

new_subj <- subj[donor_rows, , drop = FALSE]
new_subj$subjid <- new_ids
new_subj$subject_nsv <- paste0(new_ids, "-XXXX")
new_subj$enrollyn <- "Y"
new_subj$enrolldt <- cut_date
new_subj$mincreated_dts <- cut_date
new_subj$firstparticipantdate <- cut_date
new_subj$firstdosedate <- cut_date
new_subj$timeonstudy <- as.character(sample(20:45, N_NEW_SUBJECTS))
new_subj$timeontreatment <- new_subj$timeonstudy
new_subj$arm <- sample(
  c("Placebo", "Drug 40mg", "Drug 80mg"), N_NEW_SUBJECTS, replace = TRUE
)

new_enroll <- enroll[sample(nrow(enroll), N_NEW_SUBJECTS), , drop = FALSE]
new_enroll$subjid <- new_ids
new_enroll$subjectid <- paste0("XX-", new_ids)
new_enroll$enroll_dt <- cut_date
new_enroll$enrollyn <- "Y"
new_enroll$invid <- new_subj$invid
new_enroll$country <- new_subj$country

# A baseline and one follow-up for each new participant, donated from a
# continuing participant's own record so the panel and its reference ranges are
# internally consistent. They enrolled late, so their follow-up is Week 4 (day
# 29) rather than the new Week 16 visit — their `timeonstudy` says so, and a
# visit a participant could not have attended would be exactly the kind of
# inconsistency this rebuild exists to remove.
donors <- sample(continuing, N_NEW_SUBJECTS)
FOLLOWUP_NAME <- "Week 4"
FOLLOWUP_DAY <- "29"

# `visnum` for the follow-up differs between the two domains: labs are drawn at
# every scheduled visit, ECGs at four of them.
NewParticipantRows <- function(src, test_col, value_col, day_col, date_col,
                               flag_col, followup_num, decimals) {
  do.call(rbind, lapply(seq_len(N_NEW_SUBJECTS), function(i) {
    base <- src[src$subjid == donors[i] & src$visnum == "1", , drop = FALSE]
    base <- base[!duplicated(base[[test_col]]), , drop = FALSE]
    if (nrow(base) == 0L) {
      return(NULL)
    }
    base$subjid <- new_ids[i]
    base[[date_col]] <- cut_date
    jitter <- function(v, n) {
      round(as.numeric(v) * (1 + stats::rnorm(length(v), 0, n)), decimals(base))
    }
    base[[value_col]] <- as.character(jitter(base[[value_col]], 0.06))

    followup <- base
    followup$visnam <- FOLLOWUP_NAME
    followup$visnum <- followup_num
    followup[[day_col]] <- FOLLOWUP_DAY
    followup[[date_col]] <- as.character(as.Date(cut_date) + 28)
    followup[[flag_col]] <- ""
    followup[[value_col]] <- as.character(jitter(followup[[value_col]], 0.08))
    rbind(base, followup)
  }))
}

new_lb_subjects <- NewParticipantRows(
  lb, "lbtstnam", "lbstresn", "lb_dy", "lb_dt", "lbblfl", "5",
  function(d) DecimalsFor(d$lbtstnam)
)
new_lb_subjects$toxgrg_nsv <- DeriveGrade(
  new_lb_subjects$lbtstnam, as.numeric(new_lb_subjects$lbstresn)
)

new_eg_subjects <- NewParticipantRows(
  eg, "egtstnam", "egstresn", "eg_dy", "eg_dt", "egblfl", "2",
  function(d) 0
)

# ---------------------------------------------------------------------------
# Adverse events
# ---------------------------------------------------------------------------

ae_template <- ae[ae$subjid %in% continuing, , drop = FALSE]
picked <- ae_template[sample(nrow(ae_template), N_NEW_AES), , drop = FALSE]
max_seq <- tapply(as.integer(ae$aeseq), ae$subjid, max)
base_seq <- as.integer(max_seq[picked$subjid])
base_seq[is.na(base_seq)] <- 0L
picked$aeseq <- as.character(base_seq + seq_len(nrow(picked)))
picked$aest_dy <- as.character(
  as.integer(picked$aest_dy) + sample(20:60, nrow(picked), replace = TRUE)
)
picked$aeen_dy <- as.character(
  as.integer(picked$aest_dy) + sample(2:20, nrow(picked), replace = TRUE)
)
picked$aetoxgr <- as.character(sample(
  1:4, nrow(picked), replace = TRUE, prob = c(0.35, 0.30, 0.22, 0.13)
))
picked$aesev <- c("MILD", "MODERATE", "SEVERE", "LIFE THREATENING")[
  as.integer(picked$aetoxgr)
]
picked$aeser <- ifelse(
  stats::runif(nrow(picked)) <
    ifelse(as.integer(picked$aetoxgr) >= 3, 0.55, 0.05),
  "Y", "N"
)
picked$aest_dt <- as.character(as.Date(cut_date) - sample(0:20, nrow(picked), replace = TRUE))
picked$aeen_dt <- as.character(as.Date(picked$aest_dt) + sample(2:20, nrow(picked), replace = TRUE))
picked$mincreated_dts <- cut_date

new_subject_ae <- ae[sample(nrow(ae), N_NEW_SUBJECTS), , drop = FALSE]
new_subject_ae$subjid <- new_ids
new_subject_ae$aeseq <- "1"
new_subject_ae$aest_dy <- as.character(sample(3:20, N_NEW_SUBJECTS))
new_subject_ae$aeen_dy <- as.character(
  as.integer(new_subject_ae$aest_dy) + sample(2:12, N_NEW_SUBJECTS)
)
new_subject_ae$aetoxgr <- as.character(sample(1:2, N_NEW_SUBJECTS, replace = TRUE))
new_subject_ae$aesev <- c("MILD", "MODERATE")[as.integer(new_subject_ae$aetoxgr)]
new_subject_ae$aeser <- "N"
new_subject_ae$aeongo <- "N"
new_subject_ae$aest_dt <- cut_date
new_subject_ae$aeen_dt <- as.character(as.Date(cut_date) + 7)
new_subject_ae$mincreated_dts <- cut_date

# ---------------------------------------------------------------------------
# Extend follow-up for the continuing participants
# ---------------------------------------------------------------------------
#
# A data cut is not only new rows: the participants still on study have been on
# it longer. Without this, the AE rate KRI would see a numerator that grew and
# a denominator that did not, and every continuing site would look like it had
# deteriorated.

is_continuing <- subj$subjid %in% continuing
subj$timeonstudy[is_continuing] <- as.character(
  as.integer(subj$timeonstudy[is_continuing]) + TIME_GAINED
)
subj$timeontreatment[is_continuing] <- as.character(
  as.integer(subj$timeontreatment[is_continuing]) + TIME_GAINED
)

message("\nWriting input/:")
write_raw(rbind(subj, new_subj), "Raw_SUBJ.csv")
write_raw(rbind(enroll, new_enroll), "Raw_ENROLL.csv")
write_raw(rbind(ae, picked, new_subject_ae), "Raw_AE.csv")
write_raw(rbind(lb, new_lb, new_lb_subjects), "Raw_LB.csv")
write_raw(rbind(eg, new_eg, new_eg_subjects), "Raw_EG.csv")

message("\nData cut advanced. Re-run scripts/run-pipeline.R to produce the next snapshot.")
