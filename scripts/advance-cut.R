# advance-cut.R — advance the study's input data by one data cut.
#
# A DEMO-301 snapshot is only interesting next to another snapshot, and the
# difference between two snapshots has to be a difference in the *data*, not in
# the code. This script produces that difference deterministically: same seed,
# same result, every time, on any machine. It appends only — nothing already in
# input/ is edited or removed — so cut N+1 is a strict superset of cut N and the
# diff on `main` is readable.
#
# What one cut adds, to both source families (see
# scripts/make-safety-inputs.R for why there are two):
#
#   Safety family (input/adbds.csv, adae.csv, adeg.csv)
#     * a later scheduled visit for about a third of participants: labs, vitals
#       and ECG carried forward from each participant's own most recent result
#       with modest noise;
#     * a handful of unmistakable outliers — six participants pushed to many
#       multiples of the upper limit of normal on ALT, AST and bilirubin, and
#       two pushed past the 500 ms QTcF threshold — so the charts have
#       something to find;
#     * about twenty new adverse events on existing participants;
#     * five newly enrolled participants, with a baseline and the new visit.
#
#   RBQM family (input/Raw_LB.csv, Raw_AE.csv, Raw_SUBJ.csv, Raw_ENROLL.csv)
#     * the same shape of change in the operational data: a follow-up lab visit
#       for the same fraction of participants, with a few toxicity grades
#       escalated; twenty new adverse events; five new participants with their
#       enrollment records.
#
# Usage:
#   Rscript scripts/advance-cut.R [project_dir]
#
# The script refuses to run twice: it stops if the visit it would add is
# already present.

args <- commandArgs(trailingOnly = TRUE)
project_dir <- normalizePath(
  if (length(args) >= 1) args[[1]] else ".",
  mustWork = TRUE
)

set.seed(20260728)

SAFETY_VISIT <- "Week 28"
SAFETY_VISITNUM <- 28
RBQM_VISIT <- "Follow-up Week 28"
N_NEW_SUBJECTS <- 5L
N_NEW_AES <- 20L
VISIT_FRACTION <- 1 / 3
N_OUTLIER_SUBJECTS <- 6L

input <- function(name) file.path(project_dir, "input", name)
read_input <- function(name) {
  utils::read.csv(input(name), stringsAsFactors = FALSE)
}
write_input <- function(df, name) {
  utils::write.csv(df, input(name), row.names = FALSE, na = "")
  message(sprintf("  %-18s -> %d rows", name, nrow(df)))
}
`%||%` <- function(x, y) if (is.null(x)) y else x

# ---------------------------------------------------------------------------
# Safety family
# ---------------------------------------------------------------------------

adbds <- read_input("adbds.csv")
adae <- read_input("adae.csv")
adeg <- read_input("adeg.csv")

if (SAFETY_VISIT %in% adbds$VISIT) {
  stop(
    sprintf(
      "input/adbds.csv already contains visit '%s' - the data has already been advanced.",
      SAFETY_VISIT
    ),
    call. = FALSE
  )
}

subjects <- sort(unique(adbds$USUBJID))
n_advance <- max(1L, round(length(subjects) * VISIT_FRACTION))
advancing <- sort(sample(subjects, n_advance))
outlier_subjects <- sort(sample(advancing, N_OUTLIER_SUBJECTS))

message(sprintf(
  "Advancing %d of %d participants to '%s' (%d carrying clear outliers).",
  length(advancing), length(subjects), SAFETY_VISIT, length(outlier_subjects)
))

# Each participant's most recent scheduled result per test, as the base for the
# new visit.
latest_by_test <- function(df, ids) {
  sub <- df[df$USUBJID %in% ids & !is.na(df$STRESN), , drop = FALSE]
  sub <- sub[order(sub$USUBJID, sub$TEST, sub$VISITNUM), , drop = FALSE]
  key <- paste(sub$USUBJID, sub$TEST, sep = "\r")
  sub[!duplicated(key, fromLast = TRUE), , drop = FALSE]
}

# --- adbds: the new visit for existing participants ---
new_bds <- latest_by_test(adbds, advancing)
new_bds$VISIT <- SAFETY_VISIT
new_bds$VISITNUM <- SAFETY_VISITNUM
new_bds$STRESN <- round(
  new_bds$STRESN * (1 + stats::rnorm(nrow(new_bds), 0, 0.08)),
  3
)

# The outliers: hepatic markers at many multiples of the upper limit of normal,
# which is what the eDISH view and the histogram are for.
hepatic <- c("Alanine Aminotransferase", "Aspartate Aminotransferase", "Bilirubin")
is_outlier <- new_bds$USUBJID %in% outlier_subjects & new_bds$TEST %in% hepatic
if (any(is_outlier)) {
  multiplier <- stats::runif(sum(is_outlier), 3.5, 14)
  new_bds$STRESN[is_outlier] <- round(
    new_bds$STNRHI[is_outlier] * multiplier,
    3
  )
}

# --- adbds: newly enrolled participants ---
new_ids <- sprintf("01-999-90%02d", seq_len(N_NEW_SUBJECTS))
donors <- sample(subjects, N_NEW_SUBJECTS)
arms <- sample(unique(adbds$ARM), N_NEW_SUBJECTS, replace = TRUE)

new_subject_rows <- do.call(rbind, lapply(seq_len(N_NEW_SUBJECTS), function(i) {
  donor <- adbds[adbds$USUBJID == donors[i] & adbds$VISIT == "Baseline", , drop = FALSE]
  donor <- donor[!duplicated(donor$TEST), , drop = FALSE]
  if (nrow(donor) == 0L) {
    return(NULL)
  }
  donor$USUBJID <- new_ids[i]
  donor$SITE <- "Clinical Site 999"
  donor$SITEID <- "999"
  donor$ARM <- arms[i]
  donor$STRESN <- round(
    donor$STRESN * (1 + stats::rnorm(nrow(donor), 0, 0.06)),
    3
  )
  followup <- donor
  followup$VISIT <- SAFETY_VISIT
  followup$VISITNUM <- SAFETY_VISITNUM
  followup$STRESN <- round(
    followup$STRESN * (1 + stats::rnorm(nrow(followup), 0, 0.08)),
    3
  )
  rbind(donor, followup)
}))

adbds_out <- rbind(adbds, new_bds, new_subject_rows)

# --- adeg: the same new visit, plus two clear QTcF prolongations ---
new_eg <- latest_by_test(adeg, advancing)
new_eg$VISIT <- SAFETY_VISIT
new_eg$VISITNUM <- SAFETY_VISITNUM
new_eg$ABLFL <- ""
new_eg$STRESN <- round(
  new_eg$STRESN * (1 + stats::rnorm(nrow(new_eg), 0, 0.04)),
  1
)
qt_outliers <- sample(advancing, 2)
prolonged <- new_eg$USUBJID %in% qt_outliers & new_eg$TEST %in% c("QTcF", "QTcB")
new_eg$STRESN[prolonged] <- round(stats::runif(sum(prolonged), 505, 545), 1)
new_eg$CHG <- round(new_eg$STRESN - new_eg$BASE, 1)

new_eg_subjects <- do.call(rbind, lapply(seq_len(N_NEW_SUBJECTS), function(i) {
  donor <- adeg[adeg$USUBJID == donors[i] & adeg$VISIT == "Baseline", , drop = FALSE]
  donor <- donor[!duplicated(donor$TEST), , drop = FALSE]
  if (nrow(donor) == 0L) {
    return(NULL)
  }
  donor$USUBJID <- new_ids[i]
  donor$SITE <- "Clinical Site 999"
  donor$SITEID <- "999"
  donor$ARM <- arms[i]
  donor$STRESN <- round(donor$STRESN * (1 + stats::rnorm(nrow(donor), 0, 0.04)), 1)
  donor$BASE <- donor$STRESN
  donor$CHG <- 0
  donor$ABLFL <- "Y"
  followup <- donor
  followup$VISIT <- SAFETY_VISIT
  followup$VISITNUM <- SAFETY_VISITNUM
  followup$ABLFL <- ""
  followup$STRESN <- round(
    followup$STRESN * (1 + stats::rnorm(nrow(followup), 0, 0.05)), 1
  )
  followup$CHG <- round(followup$STRESN - followup$BASE, 1)
  rbind(donor, followup)
}))

adeg_out <- rbind(adeg, new_eg, new_eg_subjects)

# --- adae: new adverse events ---
ae_template <- adae[
  adae$USUBJID %in% advancing & nzchar(adae$AEDECOD), ,
  drop = FALSE
]
picked <- ae_template[sample(nrow(ae_template), N_NEW_AES), , drop = FALSE]
max_seq <- tapply(adae$AESEQ, adae$USUBJID, max, na.rm = TRUE)
max_day <- suppressWarnings(tapply(adae$ASTDY, adae$USUBJID, max, na.rm = TRUE))
picked$AESEQ <- as.integer(max_seq[picked$USUBJID]) + seq_len(nrow(picked))
base_day <- as.numeric(max_day[picked$USUBJID])
base_day[!is.finite(base_day)] <- 180
picked$ASTDY <- as.integer(base_day + sample(5:40, nrow(picked), replace = TRUE))
picked$AENDY <- picked$ASTDY + sample(1:14, nrow(picked), replace = TRUE)
picked$AESEV <- sample(
  c("MILD", "MODERATE", "SEVERE"), nrow(picked), replace = TRUE,
  prob = c(0.5, 0.35, 0.15)
)
picked$AESER <- sample(c("N", "Y"), nrow(picked), replace = TRUE, prob = c(0.85, 0.15))

new_ae_subjects <- do.call(rbind, lapply(seq_len(N_NEW_SUBJECTS), function(i) {
  row <- ae_template[sample(nrow(ae_template), 1), , drop = FALSE]
  row$USUBJID <- new_ids[i]
  row$ARM <- arms[i]
  row$AESEQ <- 1L
  row$ASTDY <- as.integer(sample(10:150, 1))
  row$AENDY <- row$ASTDY + sample(1:20, 1)
  row$AESEV <- sample(c("MILD", "MODERATE"), 1)
  row$AESER <- "N"
  row
}))

adae_out <- rbind(adae, picked, new_ae_subjects)

message("Safety family:")
write_input(adbds_out, "adbds.csv")
write_input(adae_out, "adae.csv")
write_input(adeg_out, "adeg.csv")

# ---------------------------------------------------------------------------
# RBQM family
# ---------------------------------------------------------------------------

raw_subj <- read_input("Raw_SUBJ.csv")
raw_enroll <- read_input("Raw_ENROLL.csv")
raw_ae <- read_input("Raw_AE.csv")
raw_lb <- read_input("Raw_LB.csv")

if (RBQM_VISIT %in% raw_lb$visnam) {
  stop(
    sprintf("input/Raw_LB.csv already contains visit '%s'.", RBQM_VISIT),
    call. = FALSE
  )
}

raw_subjects <- sort(unique(raw_subj$subjid))
raw_advancing <- sort(sample(
  raw_subjects, max(1L, round(length(raw_subjects) * VISIT_FRACTION))
))
raw_new_ids <- sprintf("S9000%02d", seq_len(N_NEW_SUBJECTS))
cut_date <- as.character(as.Date(max(raw_lb$lb_dt, na.rm = TRUE)) + 28)

# --- Raw_SUBJ / Raw_ENROLL: newly enrolled participants ---
subj_donors <- sample(nrow(raw_subj), N_NEW_SUBJECTS)
new_subj <- raw_subj[subj_donors, , drop = FALSE]
new_subj$subjid <- raw_new_ids
new_subj$subject_nsv <- paste0(raw_new_ids, "-XXXX")
new_subj$mincreated_dts <- cut_date
new_subj$enrollyn <- "Y"
new_subj$enrolldt <- cut_date

new_enroll <- raw_enroll[
  sample(nrow(raw_enroll), N_NEW_SUBJECTS), ,
  drop = FALSE
]
new_enroll$subjid <- raw_new_ids
new_enroll$subjectid <- paste0("XX-", raw_new_ids)
new_enroll$enroll_dt <- cut_date
new_enroll$enrollyn <- "Y"
new_enroll$invid <- new_subj$invid
new_enroll$country <- new_subj$country

# --- Raw_LB: a follow-up visit, with a few escalated toxicity grades ---
lb_latest <- raw_lb[raw_lb$subjid %in% raw_advancing, , drop = FALSE]
lb_latest <- lb_latest[
  order(lb_latest$subjid, lb_latest$lbtstnam, lb_latest$lb_dt), ,
  drop = FALSE
]
lb_key <- paste(lb_latest$subjid, lb_latest$lbtstnam, sep = "\r")
new_lb <- lb_latest[!duplicated(lb_key, fromLast = TRUE), , drop = FALSE]
new_lb$visnam <- RBQM_VISIT
new_lb$lb_dt <- cut_date
escalate <- sample(
  c(FALSE, TRUE), nrow(new_lb), replace = TRUE, prob = c(0.97, 0.03)
)
new_lb$toxgrg_nsv[escalate] <- sample(
  c("3", "4"), sum(escalate), replace = TRUE, prob = c(0.6, 0.4)
)

new_lb_subjects <- do.call(rbind, lapply(seq_len(N_NEW_SUBJECTS), function(i) {
  donor_id <- raw_advancing[i]
  donor <- new_lb[new_lb$subjid == donor_id, , drop = FALSE]
  if (nrow(donor) == 0L) {
    return(NULL)
  }
  donor$subjid <- raw_new_ids[i]
  donor$toxgrg_nsv <- sample(
    c("0", "1", "2"), nrow(donor), replace = TRUE, prob = c(0.7, 0.2, 0.1)
  )
  donor
}))

raw_lb_out <- rbind(raw_lb, new_lb, new_lb_subjects)

# --- Raw_AE: new adverse events ---
raw_ae_template <- raw_ae[raw_ae$subjid %in% raw_advancing, , drop = FALSE]
raw_picked <- raw_ae_template[
  sample(nrow(raw_ae_template), N_NEW_AES), ,
  drop = FALSE
]
raw_picked$mincreated_dts <- cut_date
raw_picked$aest_dt <- as.character(
  as.Date(cut_date) + sample(0:20, N_NEW_AES, replace = TRUE)
)
raw_picked$aeen_dt <- as.character(
  as.Date(raw_picked$aest_dt) + sample(1:10, N_NEW_AES, replace = TRUE)
)
raw_picked$aetoxgr <- sample(
  1:4, N_NEW_AES, replace = TRUE, prob = c(0.4, 0.3, 0.2, 0.1)
)
raw_picked$aeser <- sample(
  c("N", "Y"), N_NEW_AES, replace = TRUE, prob = c(0.85, 0.15)
)

raw_new_ae <- raw_ae[sample(nrow(raw_ae), N_NEW_SUBJECTS), , drop = FALSE]
raw_new_ae$subjid <- raw_new_ids
raw_new_ae$mincreated_dts <- cut_date
raw_new_ae$aest_dt <- as.character(as.Date(cut_date) + 3)
raw_new_ae$aeen_dt <- as.character(as.Date(cut_date) + 8)
raw_new_ae$aeser <- "N"

raw_ae_out <- rbind(raw_ae, raw_picked, raw_new_ae)

message("RBQM family:")
write_input(rbind(raw_subj, new_subj), "Raw_SUBJ.csv")
write_input(rbind(raw_enroll, new_enroll), "Raw_ENROLL.csv")
write_input(raw_ae_out, "Raw_AE.csv")
write_input(raw_lb_out, "Raw_LB.csv")

message("\nData cut advanced. Re-run scripts/run-pipeline.R to produce the next snapshot.")
