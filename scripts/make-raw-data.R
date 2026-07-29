# make-raw-data.R — build DEMO-301's single raw data layer.
#
# WHY THIS EXISTS
#
# DEMO-301 used to carry *two* synthetic source families: `input/Raw_*.csv`
# (operational data for the RBQM lane) and `input/adbds.csv` + `adae.csv` +
# `adeg.csv` (ADaM-shaped data for the Safety charts, lifted from
# `gsm.safety::ExampleData()`). They described different participants, so the
# two lenses on the study could not be compared: the AE count the KRI computed
# had nothing to do with the AE count the AE Explorer drew.
#
# This script replaces both families with one. Every domain below describes the
# same participants, at the same sites, on the same study days, and every
# number the Safety charts render is derived from the same rows the KRIs count.
# See hub jwildfire/obot.roadmap#134.
#
# WHAT IT WRITES
#
#   input/Raw_SITE.csv      150 sites          (from gsm.core::lSource)
#   input/Raw_SUBJ.csv    1,000 participants   (lSource + treatment arm)
#   input/Raw_ENROLL.csv  1,000 enrollment records
#   input/Raw_STUDCOMP.csv  765 study-completion records
#   input/Raw_SDRGCOMP.csv  765 study-drug completion records
#   input/Raw_IE.csv        765 eligibility records
#   input/Raw_AE.csv      ~2,900 adverse events   (synthesized on this cohort)
#   input/Raw_LB.csv     ~52,000 lab results      (synthesized on this cohort)
#   input/Raw_EG.csv      ~6,600 ECG results      (synthesized on this cohort)
#
# The remaining `input/Raw_*.csv` domains — STUDY, PD, PK, QUERY, DATACHG,
# DATAENT — are the og_init() extract of `gsm.core::lSource` and are
# left exactly as they are. They key on `subjid` / `subject_nsv`, both of which
# this script preserves, and none of them carries `invid`, so nothing in them
# needs to move.
#
# THREE THINGS THIS SCRIPT FIXES AT THE SOURCE
#
#   1. Site identifiers. `lSource` writes them as `0X4323`, which base R reads
#      as a *hexadecimal literal*: `read.csv()` silently turns all 150 of them
#      into decimal integers, so every site in the app was labelled `34713`
#      instead of `0X4323`. They are written here as `SITE4323`, which no
#      reader can mistake for a number.
#   2. Lab results. `lSource$Raw_LB` carries a toxicity grade and nothing else —
#      no numeric result, no units, no reference range. Every safety chart needs
#      all three. They are synthesized here, and the toxicity grade is *derived
#      from* the numeric result against the reference range, so the Grade 3+ Lab
#      Abnormality KRI and the lab charts cannot disagree.
#   3. Adverse events. `lSource$Raw_AE` has two SOC values ("soc1", "soc2") and
#      two preferred terms, which makes the AE Explorer's body-system/term
#      drill-down meaningless. Realistic MedDRA-shaped terms are assigned here,
#      along with the severity, sequence and onset/resolution study days the
#      timelines chart needs.
#
# Everything random is seeded. Re-running the script on any machine reproduces
# input/ byte for byte. These are inputs, not derived data: the CSVs are
# committed, and this script exists so they are reproducible, not so they are
# regenerated on every pipeline run.
#
# Usage:
#   Rscript scripts/make-raw-data.R [project_dir]

args <- commandArgs(trailingOnly = TRUE)
project_dir <- normalizePath(
  if (length(args) >= 1) args[[1]] else ".",
  mustWork = TRUE
)

if (!requireNamespace("gsm.core", quietly = TRUE)) {
  stop("gsm.core is required (it supplies the source study). ", call. = FALSE)
}

input_dir <- file.path(project_dir, "input")
dir.create(input_dir, recursive = TRUE, showWarnings = FALSE)

write_input <- function(df, name) {
  path <- file.path(input_dir, name)
  utils::write.csv(df, path, row.names = FALSE, na = "")
  message(sprintf("  %-20s %7d rows x %2d cols", name, nrow(df), ncol(df)))
  invisible(path)
}

lSource <- gsm.core::lSource

# Site identifiers, made unmistakably non-numeric. `0X4323` -> `SITE4323`.
# Idempotent: applying it twice is the same as applying it once.
HarmonizeInvid <- function(x) {
  x <- as.character(x)
  ifelse(grepl("^0X", x), sub("^0X", "SITE", x), x)
}

set.seed(20260728)

# ---------------------------------------------------------------------------
# 1. Sites
# ---------------------------------------------------------------------------

raw_site <- lSource$Raw_SITE
raw_site <- data.frame(
  studyid = raw_site$protocol,
  invid = HarmonizeInvid(raw_site$pi_number),
  InvestigatorFirstName = raw_site$pi_first_name,
  InvestigatorLastName = raw_site$pi_last_name,
  site_status = raw_site$site_status,
  site_active_dt = raw_site$site_active_dt,
  City = raw_site$city,
  State = raw_site$state,
  Country = raw_site$country,
  stringsAsFactors = FALSE
)

# ---------------------------------------------------------------------------
# 2. Participants
# ---------------------------------------------------------------------------
#
# One row per screened participant. `enrollyn == 'Y'` marks the analysis
# cohort; the SUBJ mapping filters on it. `arm` is new — the source study has
# no treatment assignment at all, and six of the nine safety charts group or
# filter by it.

ARMS <- c("Placebo", "Drug 40mg", "Drug 80mg")

raw_subj <- lSource$Raw_SUBJ
raw_subj$invid <- HarmonizeInvid(raw_subj$invid)
raw_subj$studyid <- as.character(raw_subj$studyid)
raw_subj$subjid <- as.character(raw_subj$subjid)

enrolled <- raw_subj$enrollyn == "Y"
raw_subj$arm <- ""
raw_subj$arm[enrolled] <- sample(ARMS, sum(enrolled), replace = TRUE)

# Order the columns so `arm` sits next to the other participant attributes.
raw_subj <- raw_subj[, c(
  "studyid", "invid", "country", "subjid", "subject_nsv", "enrollyn",
  "enrolldt", "arm", "agerep", "sex", "race", "timeonstudy",
  "firstparticipantdate", "firstdosedate", "timeontreatment",
  "mincreated_dts"
)]

# The analysis cohort, used by every synthesis block below.
cohort <- raw_subj[raw_subj$enrollyn == "Y", , drop = FALSE]
cohort$timeonstudy <- as.integer(cohort$timeonstudy)
n_cohort <- nrow(cohort)
sites <- sort(unique(cohort$invid))

message(sprintf(
  "Cohort: %d enrolled of %d screened, at %d of %d sites.",
  n_cohort, nrow(raw_subj), length(sites), nrow(raw_site)
))

# A per-site risk multiplier. Most sites sit near 1; a handful are deliberately
# pushed high and low so the KRI charts have real signal to flag, and so the
# safety charts show that signal as the same participants.
site_risk <- stats::setNames(
  stats::rlnorm(length(sites), meanlog = 0, sdlog = 0.30),
  sites
)
extreme <- sample(sites, 12)
site_risk[extreme[1:6]] <- site_risk[extreme[1:6]] * 2.4
site_risk[extreme[7:12]] <- site_risk[extreme[7:12]] * 0.30

# Treatment effect: the active arms are more toxic than placebo, and the high
# dose more than the low.
arm_risk <- c("Placebo" = 0.45, "Drug 40mg" = 1.00, "Drug 80mg" = 1.55)

cohort$risk <- unname(site_risk[cohort$invid]) * unname(arm_risk[cohort$arm])

# ---------------------------------------------------------------------------
# 3. Enrollment, disposition and eligibility
# ---------------------------------------------------------------------------
#
# The source study carries 100 study-completion records for 1,000 participants
# and no eligibility data at all. Both gaps are visible in the analysis:
#
#   * The two discontinuation KRIs (kri0006 Study Discontinuation, kri0007
#     Treatment Discontinuation) are the joint-heaviest metrics in the site
#     risk score at weight 32 each. With disposition recorded for a tenth of
#     the cohort no site ever reaches their accrual threshold of 3, every row
#     comes back with a null Flag, and `gsm.kri::CalculateRiskScore()` drops
#     the whole metric in its weight join — so the published risk score is out
#     of 114 rather than 178, and two of the three heaviest KRIs contribute
#     nothing to it. Recording disposition for the whole cohort is what makes
#     the score mean what it says.
#   * The QTLs (`workflows/2_metrics/qtl*.yaml`, from gsm.qtl) are study-level
#     acceptable ranges. qtl0002 reads the same disposition; qtl0001 reads an
#     eligibility domain the study never extracted.
#
# Both are synthesized here on the same `risk` multiplier the AEs and labs use,
# so a site that looks bad in the safety charts is the same site that looks bad
# in the disposition metrics.

raw_enroll <- lSource$Raw_ENROLL
raw_enroll$invid <- HarmonizeInvid(raw_enroll$invid)

# --- Disposition -----------------------------------------------------------
#
# Two related events per participant, in the order they can happen: a
# participant may come off study drug and stay on study for follow-up, but a
# participant off study is off drug too. The rates are the ones a short Phase 2
# would report — around a quarter off treatment, a sixth off study — and both
# are scaled by site risk, so attrition and toxicity tell the same story.
STUDY_DISC_RATE <- 0.155
TREAT_DISC_RATE <- 0.245

DiscontinuationReason <- function(n) {
  sample(
    c(
      "Withdrew Consent", "Lost to Follow-Up", "Adverse Event",
      "Physician Decision", "Protocol Deviation", "Death"
    ),
    n,
    replace = TRUE,
    prob = c(0.30, 0.24, 0.22, 0.12, 0.10, 0.02)
  )
}

# `risk` is centred near 1, so clamping keeps a high-risk site's probability a
# probability rather than letting the multiplier run past 1.
disc_p <- pmin(0.85, cohort$risk * STUDY_DISC_RATE)
study_disc <- stats::runif(n_cohort) < disc_p
treat_p <- pmin(0.90, cohort$risk * TREAT_DISC_RATE)
# Everyone off study is off treatment; the rest discontinue treatment at the
# residual rate that leaves the marginal rate near TREAT_DISC_RATE.
treat_disc <- study_disc | (stats::runif(n_cohort) < pmax(0, treat_p - disc_p))

raw_studcomp <- data.frame(
  studyid = cohort$studyid,
  compyn = ifelse(study_disc, "N", "Y"),
  compreas = ifelse(study_disc, DiscontinuationReason(n_cohort), ""),
  mincreated_dts = as.character(cohort$mincreated_dts),
  subjid = cohort$subjid,
  invid = cohort$invid,
  stringsAsFactors = FALSE
)

raw_sdrgcomp <- data.frame(
  studyid = cohort$studyid,
  subjid = cohort$subjid,
  invid = cohort$invid,
  sdrgyn = ifelse(treat_disc, "N", "Y"),
  # `phase` is the treatment phase the participant was in; this study has one.
  phase = "Treatment",
  mincreated_dts = as.character(cohort$mincreated_dts),
  stringsAsFactors = FALSE
)

message(sprintf(
  "Disposition: %d of %d off study (%.1f%%), %d off treatment (%.1f%%); %d sites reach kri0006's accrual threshold of 3.",
  sum(study_disc), n_cohort, 100 * mean(study_disc),
  sum(treat_disc), 100 * mean(treat_disc),
  sum(table(cohort$invid[study_disc]) >= 3)
))

# --- Eligibility (inclusion/exclusion) -------------------------------------
#
# One row per enrolled participant, which is what gsm.qtl's qtl0001 expects:
# the denominator is every row, the numerator is every row whose `Source` is
# not "Neither". `Source` names where the eligibility concern was found — the
# EDC's own inclusion/exclusion form, a recorded protocol deviation, or both —
# and the criteria columns carry what was violated, which is what the QTL
# report's bar charts and listing break down.
IE_CRITERIA <- data.frame(
  code = c(
    "INCL03", "INCL07", "INCL11", "EXCL02", "EXCL05", "EXCL09", "EXCL14"
  ),
  text = c(
    "Confirmed diagnosis at screening",
    "Adequate organ function at baseline",
    "Written informed consent before any study procedure",
    "Clinically significant hepatic impairment",
    "Prohibited concomitant medication within 28 days",
    "QTcF > 450 ms at screening",
    "Participation in another interventional trial"
  ),
  stringsAsFactors = FALSE
)

IE_RATE <- 0.028 # qtl0001 compares against a historical rate of 3%
ie_p <- pmin(0.5, cohort$risk * IE_RATE)
ie_violation <- stats::runif(n_cohort) < ie_p
n_ie <- sum(ie_violation)

ie_source <- rep("Neither", n_cohort)
ie_source[ie_violation] <- sample(
  c("EDC I/E", "Protocol Deviation", "Both"),
  n_ie, replace = TRUE, prob = c(0.55, 0.30, 0.15)
)

# One or two criteria per affected participant, joined with the ";;;" separator
# gsm.qtl's listing splits on.
ie_codes <- rep("", n_cohort)
ie_terms <- rep("", n_cohort)
ie_dates <- rep("", n_cohort)
n_criteria <- sample(1:2, n_ie, replace = TRUE, prob = c(0.8, 0.2))
picked_criteria <- lapply(n_criteria, function(k) {
  sample(seq_len(nrow(IE_CRITERIA)), k)
})
ie_codes[ie_violation] <- vapply(
  picked_criteria, function(i) paste(IE_CRITERIA$code[i], collapse = ","),
  character(1)
)
ie_terms[ie_violation] <- vapply(
  picked_criteria, function(i) paste(IE_CRITERIA$text[i], collapse = ";;;"),
  character(1)
)
ie_first_dose <- as.character(as.Date(cohort$firstdosedate[ie_violation]))
ie_dates[ie_violation] <- vapply(
  seq_len(n_ie),
  function(i) paste(rep(ie_first_dose[i], n_criteria[i]), collapse = ";;;"),
  character(1)
)

raw_ie <- data.frame(
  studyid = cohort$studyid,
  invid = cohort$invid,
  country = cohort$country,
  subjid = cohort$subjid,
  subjectid = cohort$subject_nsv,
  Source = ie_source,
  ie_violation = ifelse(ie_violation, "Y", "N"),
  ietestcd_concat = ie_codes,
  eligibility_criteria = ie_terms,
  dvdtm = ie_dates,
  mincreated_dts = as.character(cohort$mincreated_dts),
  stringsAsFactors = FALSE
)

message(sprintf(
  "Eligibility: %d of %d participants carry an I/E concern (%.1f%%; qtl0001's historical rate is %.1f%%).",
  n_ie, n_cohort, 100 * n_ie / n_cohort, 100 * IE_RATE
))

# ---------------------------------------------------------------------------
# 4. The visit schedule
# ---------------------------------------------------------------------------
#
# Follow-up in this study is short — the longest participant is on study 88
# days, the median 30 — so the schedule is front-loaded. A participant has a
# visit when they were still on study on that day; baseline is always present.

LB_VISITS <- data.frame(
  visnam = c(
    "Baseline", "Week 1", "Week 2", "Week 3",
    "Week 4", "Week 6", "Week 8", "Week 12"
  ),
  visnum = 1:8,
  day = c(1L, 8L, 15L, 22L, 29L, 43L, 57L, 85L),
  stringsAsFactors = FALSE
)

EG_VISITS <- LB_VISITS[LB_VISITS$visnam %in%
  c("Baseline", "Week 4", "Week 8", "Week 12"), , drop = FALSE]
EG_VISITS$visnum <- seq_len(nrow(EG_VISITS))

# The (participant, visit) grid for a schedule: one row per visit attended.
VisitGrid <- function(visits) {
  idx <- rep(seq_len(n_cohort), each = nrow(visits))
  grid <- data.frame(
    subjid = cohort$subjid[idx],
    invid = cohort$invid[idx],
    arm = cohort$arm[idx],
    risk = cohort$risk[idx],
    firstdosedate = cohort$firstdosedate[idx],
    timeonstudy = cohort$timeonstudy[idx],
    visnam = rep(visits$visnam, times = n_cohort),
    visnum = rep(visits$visnum, times = n_cohort),
    day = rep(visits$day, times = n_cohort),
    stringsAsFactors = FALSE
  )
  keep <- grid$visnum == 1L | grid$day <= grid$timeonstudy
  grid[keep, , drop = FALSE]
}

# ---------------------------------------------------------------------------
# 5. Laboratory results
# ---------------------------------------------------------------------------
#
# Sixteen analytes across a chemistry and a haematology panel. Each carries a
# reference range, a typical value, and the log-scale spread of the healthy
# population. `tox` is how strongly the analyte responds to drug toxicity.
#
# `g1`..`g4` are CTCAE-shaped grading cut points *in result units*. For a
# `high` analyte the grade is the number of cut points the result exceeds; for
# a `low` analyte, the number it falls below. Deriving the grade from the
# result — rather than drawing it independently, as the source study does — is
# what makes the Grade 3+ Lab Abnormality KRI and the lab charts two views of
# one fact.

LB_TESTS <- data.frame(
  lbtstnam = c(
    "Alanine Aminotransferase", "Aspartate Aminotransferase",
    "Alkaline Phosphatase", "Bilirubin", "Gamma Glutamyl Transferase",
    "Creatinine", "Glucose", "Potassium", "Sodium", "Albumin",
    "Hemoglobin", "Hematocrit", "Platelets", "White Blood Cells",
    "Neutrophils", "Lymphocytes"
  ),
  battrnam = c(
    rep("CHEMISTRY PANEL", 10),
    rep("HEMATOLOGY&DIFFERENTIAL PANEL", 6)
  ),
  lbstresu = c(
    "U/L", "U/L", "U/L", "mg/dL", "U/L", "mg/dL", "mmol/L", "mmol/L",
    "mmol/L", "g/dL", "g/dL", "%", "10^9/L", "10^9/L", "10^9/L", "10^9/L"
  ),
  lbstnrlo = c(
    7, 8, 40, 0.2, 9, 0.6, 3.9, 3.5, 135, 3.5,
    12, 36, 150, 4, 1.8, 1.0
  ),
  lbstnrhi = c(
    41, 37, 120, 1.2, 48, 1.2, 5.6, 5.1, 145, 5.0,
    17, 50, 400, 11, 7.7, 4.8
  ),
  typical = c(
    22, 20, 68, 0.6, 25, 0.85, 4.9, 4.2, 140, 4.3,
    14.2, 43, 262, 7.2, 4.3, 2.2
  ),
  sdlog = c(
    0.30, 0.30, 0.22, 0.28, 0.35, 0.16, 0.15, 0.07, 0.03, 0.09,
    0.09, 0.09, 0.22, 0.25, 0.30, 0.28
  ),
  direction = c(
    rep("high", 8), rep("low", 2), rep("low", 6)
  ),
  tox = c(
    1.00, 0.90, 0.55, 0.45, 0.80, 0.40, 0.25, 0.25, 0.15, 0.35,
    0.70, 0.65, 0.80, 0.70, 0.85, 0.55
  ),
  digits = c(0, 0, 0, 2, 0, 2, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1),
  g1 = c(41, 37, 120, 1.2, 48, 1.2, 5.6, 5.1, 135, 3.5,
    12, 36, 150, 4, 1.8, 1.0),
  g2 = c(123, 111, 300, 1.8, 120, 1.8, 8.9, 5.5, 130, 3.0,
    10, 30, 75, 3, 1.5, 0.8),
  g3 = c(205, 185, 600, 3.6, 240, 3.6, 13.9, 6.0, 125, 2.0,
    8, 24, 50, 2, 1.0, 0.5),
  g4 = c(820, 740, 2400, 12, 960, 7.2, 27.8, 7.0, 120, 1.0,
    6.5, 20, 25, 1, 0.5, 0.2),
  stringsAsFactors = FALSE
)

# How far toxicity pushes a result, as a fraction of that analyte's own
# distance from its typical value to its grade 4 cut point. Scaling by the
# analyte's dynamic range rather than by a shared log-scale constant is what
# keeps the model physiological: a participant whose ALT reaches 20x the upper
# limit of normal does not also have a sodium of 77 mmol/L.
TOX_REACH <- 1.55
# Share of the cohort that develops a treatment-emergent laboratory toxicity,
# before the site and arm multipliers are applied.
TOX_BASE_RATE <- 0.30
# Severity of that toxicity, as a Beta(a, b) on [0, 1]: most affected
# participants shift mildly, a few severely. The shape matters — a flat
# severity distribution would make grade 4 results as common as grade 3.
TOX_SHAPE <- c(1.5, 3.0)
# Ceiling on that reach, in the same units: results plateau rather than run
# away to values no laboratory would report.
TOX_CAP <- 1.05
# Study day at which a participant's toxicity reaches its full effect.
TOX_RAMP_DAY <- 29

set.seed(20260729)

# Per-participant toxicity severity in [0, 1]; zero for most of the cohort.
p_affected <- pmin(0.85, TOX_BASE_RATE * cohort$risk)
affected <- stats::runif(n_cohort) < p_affected
cohort$tox <- 0
cohort$tox[affected] <- stats::rbeta(sum(affected), TOX_SHAPE[1], TOX_SHAPE[2])

lb_grid <- VisitGrid(LB_VISITS)
lb_grid$tox <- cohort$tox[match(lb_grid$subjid, cohort$subjid)]

n_visits <- nrow(lb_grid)
n_tests <- nrow(LB_TESTS)

# One row per (participant, visit, analyte).
ti <- rep(seq_len(n_tests), times = n_visits)
vi <- rep(seq_len(n_visits), each = n_tests)

test <- LB_TESTS[ti, , drop = FALSE]
visit <- lb_grid[vi, , drop = FALSE]

# A participant-by-analyte offset that persists across their visits, so a
# participant who runs high on a marker keeps running high.
subj_index <- match(visit$subjid, cohort$subjid)
subject_offset <- matrix(
  stats::rnorm(n_cohort * n_tests, 0, 1),
  nrow = n_cohort, ncol = n_tests
)
offset <- subject_offset[cbind(subj_index, ti)] * test$sdlog * 0.75

# Toxicity ramps in over the treatment period, and is expressed in units of
# the analyte's own span: the log distance from its typical value to its
# grade 4 cut point.
span <- abs(log(test$g4 / test$typical))
ramp <- pmin(1, visit$day / TOX_RAMP_DAY)
# Capped just past the grade 4 cut point: real markers plateau, and an
# uncapped tail would put an ALT of 5,000 U/L on the chart.
drift <- pmin(visit$tox * test$tox * ramp * TOX_REACH, TOX_CAP) * span
drift <- ifelse(test$direction == "high", drift, -drift)

noise <- stats::rnorm(length(ti), 0, 1) * test$sdlog * 0.65

value <- test$typical * exp(offset + noise + drift)
value <- round(value, test$digits)
value <- pmax(value, 10^(-test$digits))

above <- (value > test$g1) + (value > test$g2) + (value > test$g3) +
  (value > test$g4)
below <- (value < test$g1) + (value < test$g2) + (value < test$g3) +
  (value < test$g4)
grade <- ifelse(test$direction == "high", above, below)

raw_lb <- data.frame(
  studyid = cohort$studyid[subj_index],
  subjid = visit$subjid,
  visnam = visit$visnam,
  visnum = visit$visnum,
  lb_dy = visit$day,
  lb_dt = as.character(as.Date(visit$firstdosedate) + visit$day - 1L),
  lbblfl = ifelse(visit$visnum == 1L, "Y", ""),
  battrnam = test$battrnam,
  lbtstnam = test$lbtstnam,
  lbstresn = value,
  lbstresu = test$lbstresu,
  lbstnrlo = test$lbstnrlo,
  lbstnrhi = test$lbstnrhi,
  toxgrg_nsv = as.character(grade),
  stringsAsFactors = FALSE
)
raw_lb <- raw_lb[order(raw_lb$subjid, raw_lb$visnum, raw_lb$lbtstnam), ]
rownames(raw_lb) <- NULL

hy_alt <- unique(raw_lb$subjid[
  raw_lb$lbtstnam == "Alanine Aminotransferase" & raw_lb$lbstresn > 3 * 41
])
hy_tb <- unique(raw_lb$subjid[
  raw_lb$lbtstnam == "Bilirubin" & raw_lb$lbstresn > 2 * 1.2
])
message(sprintf(
  "Labs: %d results; grades %s; %.2f%% grade 3+.",
  nrow(raw_lb),
  paste(sprintf(
    "%s=%.1f%%", names(table(raw_lb$toxgrg_nsv)),
    100 * prop.table(table(raw_lb$toxgrg_nsv))
  ), collapse = " "),
  100 * mean(raw_lb$toxgrg_nsv %in% c("3", "4"))
))
message(sprintf(
  "      %d participants above 3x ULN ALT, %d above 2x ULN bilirubin, %d in both (Hy's Law quadrant).",
  length(hy_alt), length(hy_tb), length(intersect(hy_alt, hy_tb))
))

# ---------------------------------------------------------------------------
# 6. ECG results
# ---------------------------------------------------------------------------
#
# The QT explorer compares change-from-baseline against placebo, so the drug
# effect here is deliberate: the high dose prolongs QTc enough to cross the
# ICH E14 10 ms threshold of regulatory concern, the low dose less so, placebo
# not at all.

EG_TESTS <- data.frame(
  egtstnam = c("QTcF", "QTcB", "Heart Rate", "PR Interval", "QRS Duration"),
  egstresu = c("ms", "ms", "beats/min", "ms", "ms"),
  typical = c(404, 412, 72, 158, 92),
  sdlog = c(0.055, 0.060, 0.14, 0.13, 0.10),
  qt = c(1, 1, 0, 0, 0),
  digits = c(0, 0, 0, 0, 0),
  stringsAsFactors = FALSE
)

# Mean QTc prolongation in ms at full exposure, by arm.
QT_EFFECT <- c("Placebo" = 0.5, "Drug 40mg" = 8.0, "Drug 80mg" = 16.0)

set.seed(20260730)

eg_grid <- VisitGrid(EG_VISITS)
n_eg_visits <- nrow(eg_grid)
n_eg_tests <- nrow(EG_TESTS)

ei <- rep(seq_len(n_eg_tests), times = n_eg_visits)
ev <- rep(seq_len(n_eg_visits), each = n_eg_tests)
etest <- EG_TESTS[ei, , drop = FALSE]
evisit <- eg_grid[ev, , drop = FALSE]

eg_subj_index <- match(evisit$subjid, cohort$subjid)
eg_subject_offset <- matrix(
  stats::rnorm(n_cohort * n_eg_tests, 0, 1),
  nrow = n_cohort, ncol = n_eg_tests
)
eg_offset <- eg_subject_offset[cbind(eg_subj_index, ei)] * etest$sdlog * 0.8
eg_noise <- stats::rnorm(length(ei), 0, 1) * etest$sdlog * 0.6

eg_value <- etest$typical * exp(eg_offset + eg_noise)
# The QTc drug effect is additive in ms, applied only after baseline.
eg_ramp <- ifelse(evisit$visnum == 1L, 0, pmin(1, evisit$day / 57))
eg_value <- eg_value +
  etest$qt * eg_ramp * unname(QT_EFFECT[evisit$arm]) +
  etest$qt * eg_ramp * stats::rnorm(length(ei), 0, 6)
eg_value <- round(eg_value, etest$digits)

raw_eg <- data.frame(
  studyid = cohort$studyid[eg_subj_index],
  subjid = evisit$subjid,
  visnam = evisit$visnam,
  visnum = evisit$visnum,
  eg_dy = evisit$day,
  eg_dt = as.character(as.Date(evisit$firstdosedate) + evisit$day - 1L),
  egblfl = ifelse(evisit$visnum == 1L, "Y", ""),
  egtstnam = etest$egtstnam,
  egstresn = eg_value,
  egstresu = etest$egstresu,
  stringsAsFactors = FALSE
)
raw_eg <- raw_eg[order(raw_eg$subjid, raw_eg$visnum, raw_eg$egtstnam), ]
rownames(raw_eg) <- NULL

message(sprintf("ECG: %d results across %d participants.",
  nrow(raw_eg), length(unique(raw_eg$subjid))))

# ---------------------------------------------------------------------------
# 7. Adverse events
# ---------------------------------------------------------------------------

AE_TERMS <- list(
  "Gastrointestinal disorders" = c(
    "Nausea", "Vomiting", "Diarrhoea", "Abdominal pain", "Constipation"
  ),
  "Nervous system disorders" = c(
    "Headache", "Dizziness", "Somnolence", "Paraesthesia"
  ),
  "General disorders and administration site conditions" = c(
    "Fatigue", "Pyrexia", "Oedema peripheral", "Chills"
  ),
  "Skin and subcutaneous tissue disorders" = c(
    "Rash", "Pruritus", "Urticaria"
  ),
  "Infections and infestations" = c(
    "Upper respiratory tract infection", "Urinary tract infection",
    "Nasopharyngitis"
  ),
  "Musculoskeletal and connective tissue disorders" = c(
    "Arthralgia", "Myalgia", "Back pain"
  ),
  "Investigations" = c(
    "Alanine aminotransferase increased",
    "Aspartate aminotransferase increased",
    "Blood bilirubin increased", "Platelet count decreased"
  ),
  "Blood and lymphatic system disorders" = c(
    "Anaemia", "Neutropenia", "Thrombocytopenia"
  ),
  "Respiratory, thoracic and mediastinal disorders" = c(
    "Cough", "Dyspnoea"
  ),
  "Metabolism and nutrition disorders" = c(
    "Decreased appetite", "Hypokalaemia"
  )
)

ae_dict <- do.call(rbind, lapply(names(AE_TERMS), function(soc) {
  data.frame(
    mdrsoc_nsv = soc, mdrpt_nsv = AE_TERMS[[soc]], stringsAsFactors = FALSE
  )
}))
# Terms are not equally likely; the common ones dominate, as in a real study.
ae_dict$weight <- stats::runif(nrow(ae_dict), 0.4, 1)
ae_dict$weight[ae_dict$mdrsoc_nsv == "Gastrointestinal disorders"] <-
  ae_dict$weight[ae_dict$mdrsoc_nsv == "Gastrointestinal disorders"] * 2.6
ae_dict$weight[ae_dict$mdrsoc_nsv == "Investigations"] <-
  ae_dict$weight[ae_dict$mdrsoc_nsv == "Investigations"] * 1.4

# Laboratory-toxicity participants report the matching investigation and
# blood-disorder terms, so an AE the explorer shows lines up with a lab value
# the eDISH view shows for the same participant.
LAB_LINKED <- c(
  "Alanine aminotransferase increased", "Aspartate aminotransferase increased",
  "Blood bilirubin increased", "Platelet count decreased",
  "Anaemia", "Neutropenia", "Thrombocytopenia"
)

set.seed(20260731)

# Event count per participant: proportional to exposure, scaled by site and
# arm risk, so the AE rate KRI flags the same sites the raw data made risky.
lambda <- (0.085 * cohort$timeonstudy + 0.35) * cohort$risk^0.8
n_ae <- stats::rpois(n_cohort, lambda)
n_ae[cohort$timeonstudy < 1] <- 0L

ae_subj <- rep(cohort$subjid, times = n_ae)
n_events <- length(ae_subj)
ae_idx <- rep(seq_len(n_cohort), times = n_ae)

ae_tox <- cohort$tox[ae_idx]
# 45% of a toxic participant's events are the lab-linked terms.
use_linked <- ae_tox > 0 & stats::runif(n_events) < 0.45
term_idx <- integer(n_events)
term_idx[!use_linked] <- sample(
  seq_len(nrow(ae_dict)), sum(!use_linked), replace = TRUE,
  prob = ae_dict$weight
)
linked_rows <- which(ae_dict$mdrpt_nsv %in% LAB_LINKED)
term_idx[use_linked] <- sample(
  linked_rows, sum(use_linked), replace = TRUE
)

tos <- pmax(1L, cohort$timeonstudy[ae_idx])
aest_dy <- as.integer(ceiling(stats::runif(n_events) * tos))
duration <- as.integer(1 + stats::rgeom(n_events, 0.12))
aeen_dy <- pmin(aest_dy + duration, tos)

# Toxicity grade rises with the participant's lab toxicity.
grade_p <- cbind(
  0.44 - 0.28 * ae_tox,
  0.31 - 0.02 * ae_tox,
  0.17 + 0.16 * ae_tox,
  0.08 + 0.14 * ae_tox
)
grade_p <- grade_p / rowSums(grade_p)
aetoxgr <- apply(grade_p, 1, function(p) sample.int(4L, 1L, prob = p))

aeser <- ifelse(
  stats::runif(n_events) < ifelse(aetoxgr >= 3, 0.55, 0.05), "Y", "N"
)

raw_ae <- data.frame(
  studyid = cohort$studyid[ae_idx],
  subjid = ae_subj,
  aeseq = as.integer(stats::ave(seq_len(n_events), ae_subj, FUN = seq_along)),
  aeterm = ae_dict$mdrpt_nsv[term_idx],
  mdrpt_nsv = ae_dict$mdrpt_nsv[term_idx],
  mdrsoc_nsv = ae_dict$mdrsoc_nsv[term_idx],
  aesev = c("MILD", "MODERATE", "SEVERE", "LIFE THREATENING")[aetoxgr],
  aetoxgr = aetoxgr,
  aeser = aeser,
  aerel = ifelse(stats::runif(n_events) < 0.55, "Y", "N"),
  aeongo = ifelse(aeen_dy >= tos, "Y", "N"),
  aest_dy = aest_dy,
  aeen_dy = aeen_dy,
  aest_dt = as.character(
    as.Date(cohort$firstdosedate[ae_idx]) + aest_dy - 1L
  ),
  aeen_dt = as.character(
    as.Date(cohort$firstdosedate[ae_idx]) + aeen_dy - 1L
  ),
  mincreated_dts = as.character(cohort$mincreated_dts[ae_idx]),
  stringsAsFactors = FALSE
)
raw_ae <- raw_ae[order(raw_ae$subjid, raw_ae$aeseq), ]
rownames(raw_ae) <- NULL

message(sprintf(
  "AEs: %d events across %d participants (%.0f%% serious).",
  nrow(raw_ae), length(unique(raw_ae$subjid)),
  100 * mean(raw_ae$aeser == "Y")
))

# ---------------------------------------------------------------------------
# 8. Write
# ---------------------------------------------------------------------------

message("\nWriting input/:")
write_input(raw_site, "Raw_SITE.csv")
write_input(raw_subj, "Raw_SUBJ.csv")
write_input(raw_enroll, "Raw_ENROLL.csv")
write_input(raw_studcomp, "Raw_STUDCOMP.csv")
write_input(raw_sdrgcomp, "Raw_SDRGCOMP.csv")
write_input(raw_ie, "Raw_IE.csv")
write_input(raw_ae, "Raw_AE.csv")
write_input(raw_lb, "Raw_LB.csv")
write_input(raw_eg, "Raw_EG.csv")

message("\nOne raw layer written. Run scripts/run-pipeline.R to build a snapshot.")
