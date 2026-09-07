####################################################################
###
### C_norm COVERAGE audit -- 500 sampled universities
###
### Measures the one thing no script in this folder measures: how many
### university_raw strings the C_norm matcher MISSES.
###
### shanghai_flag_audit.R says so itself in its note 5 -- "MEDE
### PRECISAO, NUNCA COBERTURA". Its sample is drawn from rows that
### MATCHED, so it can say how often a match is right and nothing at
### all about how many were never made. Every C_norm number on record
### is a precision figure or a membership gain. Recall has never been
### measured. This is the complement.
###
### The method: group the cohort's education rows by Revelio's school
### key (rsid), keep the schools where C_norm matched at least one raw
### string, sample 500 of them, pull EVERY university_raw belonging to
### each, and measure the share the matcher covers.
###
### OFFLINE. No network, no Athena, no S3. READ-ONLY with respect to
### the pipeline: it changes no flag and feeds nothing downstream.
### Nothing here goes to SEDAP.
###
### Depends on:
###   revelio_br_cohort/obmep_candidates_step_1_education/   (script 10a)
###   openalex_institutions/openalex_institutions_br.parquet (script 3)
###   revelio_br_cohort/obmep_candidates_step_1.parquet      (script 10)
###
### Sampling and rubric conventions reused from:
###   prep/building_external_data/shanghai_flag_audit.R      (script 17)
###
### -----------------------------------------------------------------
### rsid IS A MEASURING DEVICE HERE, NEVER A CRITERION
### -----------------------------------------------------------------
### THIS IS NOT A REVIVAL OF THE WITHDRAWN C_rsid BRANCH. Read note 11
### of revelio_br_cohort_user_ids.R before concluding otherwise.
###
### That branch failed because propagating a match THROUGH a school key
### AMPLIFIES: one person whose rsid is Harvard typed "Universidade
### Federal do Rio de Janeiro", 1 row out of 562,968, and that admitted
### all of Harvard. Grouping by the same key in order to COUNT what a
### matcher reached amplifies nothing -- a wrong row adds one row to a
### denominator instead of adding a university to a cohort.
###
### The contamination is still there, and it is still visible: it is
### what the X class of the rubric below exists to remove.
###
### -----------------------------------------------------------------
### THE RUBRIC -- keyed on (rsid, university_raw)
### -----------------------------------------------------------------
### The claim under test is "this unmatched string denotes the school
### this rsid stands for, so C_norm should have matched it".
###
###   M  MISS. The string denotes the sampled school, including its
###      faculties, institutes and campuses, AND that school is a
###      Brazilian institution C_norm exists to find. This is a true
###      recall loss and THE ONLY CLASS THAT COUNTS AGAINST C_norm.
###      Under rsid 169381 (CESUMAR), "UniCesumar" is M.
###   A  AFFILIATED, but not the university -- a technical school,
###      application college, hospital or high-school arm run by it,
###      where the person did not study AT the university.
###      Under rsid 224861, "ETEC Carlos de Campos" is A.
###   X  A DIFFERENT INSTITUTION entirely. This is rsid grouping
###      contamination, NOT a C_norm fault.
###      Under rsid 136604 (Anhembi Morumbi), "Universidade Licungo"
###      -- which is Mozambican -- is X.
###   N  CORRECTLY NOT MATCHED. The string does denote the sampled
###      school, but that school is not Brazilian, so C_norm is right
###      to leave it alone. Under rsid 66310, "Harvard University"
###      is N.
###
### N EXISTS BECAUSE THE FRAME IS FULL OF FOREIGN UNIVERSITIES. A
### school enters the frame on ONE matched string, and band e of the
### coverage table is largely Harvard, Lund, Cambridge, Coimbra and
### UNAM, each dragged in by a single Brazilian string somebody typed
### under it. Without N, "Harvard University" left unmatched would
### score as a C_norm recall loss, which inverts the truth: C_norm is
### a BRAZILIAN institution matcher and not matching Harvard is the
### behaviour it is built for. This class was added after a first
### labelling pass made exactly that mistake.
###
### Only M is a defect. A, X and N are all excluded from the recall
### denominator, and each is reported on its own, because they are
### three different things: a scope question, a grouping artefact, and
### correct behaviour. A is kept SEPARATE from X for the reason
### shanghai_flag_audit.R gives for keeping its own A out of N.
###
### The key is the PAIR, not the string: the same string under a
### different school is a different question.
###
### -----------------------------------------------------------------
### RESULT -- measured 2026-09-03, seed 20260903
### -----------------------------------------------------------------
###   frame                744 schools, 8,441,553 education rows
###   naive coverage       4,622,325 / 8,441,553      54.8%
###   sampled              500 schools, 5,409,487 rows, 49.0% covered
###   labelled             1,200 rows -> 313 (school, string) pairs
###
###   M true miss   1,081 / 1,200  90.1%  [88.3; 91.7]
###   A affiliated     12            1.0%
###   X rsid noise     44            3.7%
###   N correct        63            5.2%
###
###   *** RECALL = matched / (matched + M) = 51.6% ***
###
### C_norm REACHES ABOUT HALF THE ROWS IT SHOULD. That is the finding.
### Note that the naive coverage (49.0%) and the recall (51.6%) are
### close, which is itself the point: on the sampled schools the rsid
### contamination the X class removes is small (101,120 rows), so the
### widely-feared grouping noise is NOT what makes coverage look bad.
### The misses are real.
###
### Where the 2,484,332 estimated missing rows come from:
###
###   no_candidate    42.3% of M   nothing in the OpenAlex Brazilian
###                                list is reachable from the string
###   brand_acronym   34.0%        UNINOVE, UniCesumar, UNIP, FGV,
###                                UFRJ, PUC-Rio, Unisinos, Unifacs
###   campus_suffix   11.2%        Faculdade Anhanguera de Sorocaba
###   type_word_form   7.0%        Universidade Anhembi Morumbi vs
###                                OpenAlex's "Anhembi Morumbi
###                                University"
###   contains         5.0%        Anhanguera Educacional
###   near_miss        0.5%
###
### TWO OF THESE ARE NOT MATCHER PROBLEMS AT ALL. `no_candidate`, the
### largest, is a REFERENCE-LIST gap: ETEC, SENAI and SENAC units and
### many private faculdades simply have no record in
### openalex_institutions_br. No change to the matching rule reaches
### them; only a better institution list does.
###
### THE README's "bare acronyms are only 1.5-2.5% of an institution's
### rows" IS TRUE ONLY OF THE TRADITIONAL PUBLICS IT WAS MEASURED ON
### (USP, FGV, UNICAMP). On private brand-name universities the
### acronym IS the name people type:
###
###   UNINOVE      170,151 rows   83.5% of its school's rows
###   UniCesumar   103,519        89.0%
###   UNIP          31,644        of a school already 86% covered
###   UNIASSELVI   114,651        95.6%
###
### That is measured on the 500 sampled schools and it is the single
### largest fixable arm.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 0. THE LABELS WERE WRITTEN BY AN LLM, NOT BY A PERSON, by the same
###    agent that wrote the script -- the same conflict of interest
###    shanghai_flag_audit.R records in its note 2, and no formatting
###    changes that. Read the numbers as an internal-consistency check,
###    not as an independent measurement. c_norm_coverage_class.csv is
###    an ordinary editable CSV keyed to the parked sample: correct a
###    row, run again, and the numbers move without redrawing anything.
###    The script prints how many labels are still as the LLM left
###    them. The `note` column flags the calls that are genuinely
###    arguable and is where a reviewer should start.
###
### 1. rsid IS NULL ON 3,140,954 OF 15,712,737 EDUCATION ROWS (20.0%).
###    Those rows cannot be grouped into a school at all, so this
###    method is structurally blind to them. Whatever coverage is
###    reported below, it is reported over the 80% that can be grouped.
###
###    The blindness is not uniform. The extract holds 1,417,851
###    distinct university_raw strings, of which C_norm matches 22,781;
###    restricted to rows that carry an rsid those become 256,200 and
###    9,170. So MOST distinct strings, and most matched ones, live
###    only on ungroupable rows. They are long-tail strings -- the
###    groupable 20% of strings carry 8,441,553 of the rows -- but a
###    recall figure computed here still describes the groupable part
###    of the table and not the whole of it.
###
### 2. rsid IS REVELIO'S OWN NORMALIZATION AND IS IMPERFECT. The C_rsid
###    measurement found Harvard's key holding 4,496 distinct raw
###    strings of which 3 were wrong -- 0.07%. That rate is fatal to a
###    criterion, which amplifies it into total contamination, and
###    harmless to a measurement, which the X class subtracts.
###
### 3. MEASURES COVERAGE, NEVER PRECISION. Nothing here says whether a
###    match that WAS made is correct; that is script 17's job. Neither
###    script alone characterizes the matcher.
###
### 4. THE FRAME IS THE COHORT EXTRACT, NOT ALL OF REVELIO. Cohort
###    members were admitted by A OR B OR C_norm, so a school C_norm
###    never matched still appears here through a Brazilian job or a
###    Brazilian university_country -- the extract is not circular. But
###    it IS enriched toward Brazilian schools, so coverage measured
###    here is not coverage over the full Revelio education table.
###
### 5. THE SAMPLES ARE DRAWN ONCE AND NEVER REDRAWN. The CSV is keyed
###    to this exact draw. Delete the parquet to force a new one, and
###    count on relabelling everything.
###
### 6. USING SAMPLE IS NOT USED. DuckDB pushes it BELOW the filter --
###    the trap recorded in the README, where drawing 500 of 708M
###    profiles and only then filtering returned 23 rows. ORDER BY
###    hash(...) LIMIT n is a top-N over the ALREADY filtered set and
###    cannot be reordered that way. Education rows have no unique key,
###    so the hash is over a digest of the row's content.
###
### 7. THE STRING SAMPLE IS ROW-WEIGHTED, so "Anhanguera Educacional"
###    enters with the 243,125 rows it really has. That is what makes
###    the rate an estimate of the production miss rate rather than a
###    portrait of the long tail.
###
### 8. THE why-it-missed TAXONOMY IS A DIAGNOSTIC, NOT A PROPOSAL. Its
###    arms are deliberately looser than anything that could be shipped
###    as a criterion -- `contains` and `type_word_form` in particular
###    would produce false positives if used to match. They exist to
###    size each failure mode, and the M/A/X labels are what say
###    whether a given firing was really the school.
###
### 9. *** DuckDB's trim() STRIPS U+00A0, TRINO'S DOES NOT. ***
###    This audit reproduces a Trino query in DuckDB, and that is the
###    one place the two engines silently disagree. Trino's trim()
###    follows Java's Character.isWhitespace, which deliberately
###    EXCLUDES the non-breaking space; DuckDB's trim() removes it.
###
###    So the obvious transcription of the cohort query is MORE
###    PERMISSIVE than the query that ran, and an audit that measured
###    the permissive version would credit C_norm with matches it never
###    made. Every trim() that stands for a Trino trim() is therefore
###    written trim(x, ' ') -- ASCII space only -- and fold_inst() does
###    not trim at all, because Trino's inst_fold does not either.
###
###    The binding check in Step 3 is what caught this: 59 cohort
###    members carried br_openalex_norm = 0 while the transcription
###    matched them. The whole disagreement is ONE string,
###    "Universidade Federal do Acre" + U+00A0 + "(UFAC)", worth 94
###    education rows and 83 users. 63 distinct university_raw values
###    in the extract contain a U+00A0.
###
###    That string is a real C_norm miss, and it is reported as the
###    `unicode_space` arm of the taxonomy rather than quietly matched.
###
###    Checked and NOT a divergence: DuckDB's strip_accents leaves the
###    undecomposable Latin letters alone, so l-stroke, o-slash, d-bar
###    and sharp-s survive it exactly as they survive Trino's
###    normalize(NFD) + \p{M} removal.
###
### 10. 163 DISTINCT university_raw VALUES, 12,384 ROWS, CARRY U+FFFD
###    -- the replacement character. "Universidade de Cuiaba" (7,164
###    rows), "Universidade Presidente Antonio Carlos" (1,667) and
###    "UFSCar - Universidade Federal de Sao Carlos" (489) all reach
###    the table with their accented letters already destroyed
###    upstream, in Revelio or in LinkedIn before it.
###
###    Nothing downstream can match those: the information is gone
###    before any folding rule sees it. They are counted here as
###    ordinary misses and land in `near_miss` or `no_candidate`. This
###    is recorded so the residue is not mistaken for a matcher defect
###    -- a fuzzy rule tolerant enough to absorb two replacement
###    characters would be far too loose to ship.
###
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(duckdb)

####################################################################
### Parameters
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")

coh_dir   <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
ed_dir    <- file.path(coh_dir, "obmep_candidates_step_1_education")
cand_path <- file.path(coh_dir, "obmep_candidates_step_1.parquet")
inst_path <- file.path(obmep_root,
  "Data/intermediate/openalex_institutions/openalex_institutions_br.parquet")

by_rsid_path  <- file.path(coh_dir, "c_norm_coverage_by_rsid.parquet")
rsid_smp_path <- file.path(coh_dir, "c_norm_coverage_rsid_sample.parquet")
str_smp_path  <- file.path(coh_dir, "c_norm_coverage_string_sample.parquet")
class_path    <- file.path(coh_dir, "c_norm_coverage_class.csv")
out_path      <- file.path(coh_dir, "c_norm_coverage_classified.parquet")

seed          <- 20260903L
n_rsid_sample <- 500L
n_str_sample  <- 1200L

# Matcher constant, taken from revelio_br_cohort_user_ids.R and NOT a
# free parameter: changing it makes this audit measure something the
# pipeline does not do.
min_seg_len <- 3L

# Taxonomy constants. The 8-character floor on `contains` is the same
# defence note 12 of revelio_br_cohort_user_ids.R raises for the
# segment arm: the Brazilian institution list holds IBM, AES, Vale,
# Intel and Shell, and a 3-character containment test would fire on
# half the free text in the table.
min_contain_len <- 8L
max_lev         <- 2L
acr_max_len     <- 20L

# Measured 2026-09-03 against the local extract. A Revelio refresh or a
# new OpenAlex snapshot legitimately moves these, so they warn rather
# than abort. NA disables a check.
#
# exp_raw_total and exp_raw_matched count the strings on GROUPABLE rows
# only -- the ones with a non-NULL rsid. Over the whole extract the
# extract holds 1,417,851 distinct strings, the figure quoted in
# shanghai_flag_audit.R, and most of that difference is note 1.
exp_ed_rows        <- 15712737
exp_rsid_null_rows <- 3140954
exp_raw_total      <- 256200
exp_raw_matched    <- 9170
exp_frame_rsid     <- 744
exp_frame_rows     <- 8441553
exp_frame_rows_m   <- 4622325

cls_dom <- c("M", "A", "X", "N")

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_cnorm_cov")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(dir.exists(ed_dir), file.exists(inst_path), file.exists(cand_path))

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(dbExecute(con, "PRAGMA memory_limit='8GB'"))
invisible(dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir)))

ed_src   <- sprintf("read_parquet('%s/*')", ed_dir)
inst_src <- sprintf("read_parquet('%s')", inst_path)
cand_src <- sprintf("read_parquet('%s')", cand_path)

# fold() is Trino's lower(regexp_replace(normalize(trim(s), NFD),
# '\p{M}', '')) as the cohort script writes it. Two details are
# load-bearing and are note 9:
#
#   trim(s, ' ')  ASCII space ONLY. Bare trim() in DuckDB also strips
#                 U+00A0, which Trino's trim() does not, and that alone
#                 makes the transcription match a string production
#                 missed.
#   fold_inst()   does NOT trim, because Trino's inst_fold does not.
#
# fold_uni() is the Unicode-aware version -- NOT the criterion, only
# the probe that sizes the gap, as the `unicode_space` taxonomy arm.
#
# core() strips institution-TYPE words from a folded name so that
# "Universidade Anhembi Morumbi" and "Anhembi Morumbi University"
# reduce to the same core. It belongs to the taxonomy only; the matcher
# under test never calls it.
invisible(dbExecute(con,
  "CREATE MACRO fold(s) AS lower(strip_accents(trim(s, ' ')))"))
invisible(dbExecute(con,
  "CREATE MACRO fold_inst(s) AS lower(strip_accents(s))"))
invisible(dbExecute(con,
  "CREATE MACRO fold_uni(s) AS lower(strip_accents(trim(s)))"))
invisible(dbExecute(con, paste0(
  "CREATE MACRO core(s) AS trim(regexp_replace(regexp_replace(s, ",
  "'\\b(universidades|universidade|university|universitario|universitaria|",
  "univ|faculdades|faculdade|faculty|college|colegio|instituto|institute|",
  "escola|school|centro|center|centre|uni)\\b', ' ', 'g'), '\\s+', ' ', 'g'))")))

####################################################################
### Step 1: rebuild C_norm, and regression-test it before reading
###         the 15.7M-row extract
####################################################################

cat("=========== STEP 1: THE MATCHER ===========\n")

# The institution side. It carries EVERY record type because the
# whole-string arm does; is_edu is what the segment arm restricts on.
# No trim and no length floor here: Trino's inst_fold has neither, and
# adding either would make this audit measure a narrower matcher than
# the one that ran.
invisible(dbExecute(con, sprintf("
  CREATE TABLE inst AS
  SELECT fold_inst(cleaned_display_name) AS nm_fold,
         max(CASE WHEN type = 'education' THEN 1 ELSE 0 END) AS is_edu,
         arg_max(cleaned_display_name, works_count)          AS inst_name
  FROM %s
  WHERE cleaned_display_name IS NOT NULL
  GROUP BY 1", inst_src)))
n_inst <- dbGetQuery(con, "SELECT count(*) n FROM inst")$n
cat("institution names (folded)    :", format(n_inst, big.mark = ","), "\n")
if (n_inst == 0) stop("The institution list is empty.")

# The classifier itself, over an arbitrary table src(university_raw).
# Written ONCE and reused for the regression test and for production,
# because two copies of this would drift and the audit would silently
# stop measuring the pipeline.
cls_sql <- sprintf("
  WITH whole AS (
    SELECT r.university_raw, i.inst_name
    FROM %%1$s r JOIN inst i ON fold(r.university_raw) = i.nm_fold
  ),
  seg AS (
    SELECT r.university_raw, min(i.inst_name) AS inst_name
    FROM %%1$s r,
         UNNEST(str_split(regexp_replace(regexp_replace(
           r.university_raw, '[/()]', '|', 'g'), ' - ', '|', 'g'), '|')) t(part)
    JOIN inst i ON fold(t.part) = i.nm_fold
    WHERE length(trim(t.part, ' ')) >= %d AND i.is_edu = 1
    GROUP BY 1
  )
  SELECT university_raw,
         CAST(max(w) AS INTEGER) AS m_whole,
         CAST(max(s) AS INTEGER) AS m_seg,
         arg_max(inst_name, w)   AS inst_name
  FROM (SELECT university_raw, inst_name, 1 AS w, 0 AS s FROM whole
        UNION ALL
        SELECT university_raw, inst_name, 0, 1 FROM seg)
  GROUP BY 1", min_seg_len)

# The taxonomy, over the same shape.
#
# IT IS ONLY DEFINED OVER STRINGS THE MATCHER ALREADY REJECTED. Every
# arm answers "what would it have taken to reach this string", so a
# string that C_norm matched has no meaningful answer -- and `perm`
# in particular would fire on all of them, since anything matching
# under an ASCII trim also matches under a Unicode one. In production
# it is only ever applied to `unm`, which is unmatched by
# construction; the regression test below suppresses it for the
# matched cases for the same reason.
#
# Its ORDER IS LOAD-BEARING, in the manner of the degree cascade in
# br_degree_patterns.R: campus_suffix is a special case of contains
# and must be tested first, or every prefix would be reported as a
# generic containment.
tax_sql <- sprintf("
  WITH u AS (SELECT DISTINCT university_raw, fold(university_raw) AS rf FROM %%1$s),
  perm AS (
    SELECT university_raw FROM (
      SELECT r.university_raw
      FROM u r JOIN inst i ON fold_uni(r.university_raw) = i.nm_fold
      UNION ALL
      SELECT r.university_raw
      FROM u r,
           UNNEST(str_split(regexp_replace(regexp_replace(
             r.university_raw, '[/()]', '|', 'g'), ' - ', '|', 'g'), '|')) t(part)
      JOIN inst i ON fold_uni(t.part) = i.nm_fold
      WHERE length(trim(t.part)) >= %d AND i.is_edu = 1
    ) GROUP BY 1
  ),
  hit AS (
    SELECT u.university_raw,
           max(CASE WHEN starts_with(u.rf, i.nm_fold || ' ') THEN 1 ELSE 0 END) AS h_pre,
           max(CASE WHEN contains(' ' || u.rf || ' ', ' ' || i.nm_fold || ' ')
                    THEN 1 ELSE 0 END) AS h_con
    FROM u JOIN inst i ON length(i.nm_fold) >= %d
    WHERE contains(u.rf, i.nm_fold)
    GROUP BY 1
  ),
  cor AS (
    SELECT DISTINCT u.university_raw, 1 AS h_core
    FROM u JOIN inst i ON core(u.rf) = core(i.nm_fold)
    WHERE length(core(u.rf)) >= %d
  ),
  lev AS (
    SELECT DISTINCT u.university_raw, 1 AS h_lev
    FROM u JOIN inst i ON substr(u.rf, 1, 4) = substr(i.nm_fold, 1, 4)
    WHERE length(u.rf) >= %d AND levenshtein(u.rf, i.nm_fold) <= %d
  )
  SELECT u.university_raw,
         CASE
           WHEN p.university_raw IS NOT NULL             THEN 'unicode_space'
           WHEN regexp_matches(u.rf, '^[a-z0-9][a-z0-9.-]*$')
                AND length(u.rf) BETWEEN %d AND %d       THEN 'brand_acronym'
           WHEN coalesce(h.h_pre,  0) = 1                THEN 'campus_suffix'
           WHEN coalesce(h.h_con,  0) = 1                THEN 'contains'
           WHEN coalesce(c.h_core, 0) = 1                THEN 'type_word_form'
           WHEN coalesce(l.h_lev,  0) = 1                THEN 'near_miss'
           ELSE 'no_candidate'
         END AS miss_cat
  FROM u
  LEFT JOIN perm p ON u.university_raw = p.university_raw
  LEFT JOIN hit  h ON u.university_raw = h.university_raw
  LEFT JOIN cor  c ON u.university_raw = c.university_raw
  LEFT JOIN lev  l ON u.university_raw = l.university_raw",
  min_seg_len, min_contain_len, min_contain_len, min_contain_len, max_lev,
  min_seg_len, acr_max_len)

# ---- regression test, before the education extract is touched ------
# Both known positives and one case per taxonomy arm. A drift here
# means the audit is no longer measuring criterion C_norm, and no
# number below would be worth reading.
#
# The last case is note 9 pinned as a test. intToUtf8(160) is the
# non-breaking space: written as an escape on purpose, because a
# literal one in this file would be invisible to the next reader and
# would be normalised away by the first editor that touched the line.
# It MUST come back unmatched. If it ever matches, DuckDB's trim has
# been reintroduced somewhere and the audit has stopped reproducing
# Trino.
reg <- data.frame(
  university_raw = c(
    "Universidade de Sao Paulo", "USP - Universidade de Sao Paulo",
    "Universidade de Sao Paulo / USP",
    "Universidade Estadual de Campinas (UNICAMP)",
    "UNINOVE", "UniCesumar", "Universidade Anhembi Morumbi",
    "Anhanguera Educacional", "Faculdade Anhanguera de Sorocaba",
    "ETEC - Escola Tecnica Estadual de Sao Paulo",
    paste0("Universidade Federal do Acre", intToUtf8(160), "(UFAC)")),
  exp_match = c(1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0),
  exp_cat = c(NA, NA, NA, NA, "brand_acronym", "brand_acronym",
              "type_word_form", "campus_suffix", "campus_suffix",
              "no_candidate", "unicode_space"),
  stringsAsFactors = FALSE)
invisible(dbWriteTable(con, "reg_src", reg["university_raw"], overwrite = TRUE))

rg <- dbGetQuery(con, sprintf("
  WITH m AS (
    SELECT r.university_raw,
           CAST(coalesce(greatest(c.m_whole, c.m_seg), 0) AS INTEGER) AS got_match
    FROM reg_src r
    LEFT JOIN (%s) c ON r.university_raw = c.university_raw
  )
  SELECT m.university_raw, m.got_match,
         CASE WHEN m.got_match = 1 THEN NULL ELSE t.miss_cat END AS got_cat
  FROM m LEFT JOIN (%s) t ON m.university_raw = t.university_raw",
  sprintf(cls_sql, "reg_src"), sprintf(tax_sql, "reg_src")))
rg <- merge(reg, rg, by = "university_raw")
rg$ok <- rg$exp_match == rg$got_match &
         ifelse(rg$exp_match == 1, is.na(rg$got_cat), rg$exp_cat == rg$got_cat)
print(rg[, c("university_raw", "exp_match", "got_match", "exp_cat",
             "got_cat", "ok")], right = FALSE)
if (!all(rg$ok)) {
  stop(sum(!rg$ok), " regression case(s) drifted. The matcher or the ",
       "taxonomy is no longer what this audit documents.")
}
cat("[OK] ", nrow(rg), " regression cases pass\n", sep = "")

####################################################################
### Step 2: coverage over the WHOLE frame -- exact, no sampling
####################################################################

cat("\n=========== STEP 2: FRAME COVERAGE (EXACT) ===========\n")

tot <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_all,
         sum(CASE WHEN rsid IS NULL THEN 1 ELSE 0 END) AS n_rsid_null
  FROM %s", ed_src))
cat("education rows in the extract :", format(tot$n_all, big.mark = ","), "\n")
cat("  rsid IS NULL (ungroupable)  :", format(tot$n_rsid_null, big.mark = ","),
    sprintf("(%.1f%%)  <- note 1\n", 100 * tot$n_rsid_null / tot$n_all))
if (!is.na(exp_ed_rows) && tot$n_all != exp_ed_rows) {
  warning("Extract has ", tot$n_all, " rows, expected ", exp_ed_rows,
          call. = FALSE)
}
if (!is.na(exp_rsid_null_rows) && tot$n_rsid_null != exp_rsid_null_rows) {
  warning("NULL rsid rows: ", tot$n_rsid_null, call. = FALSE)
}

invisible(dbExecute(con, sprintf("
  CREATE TABLE e AS
  SELECT user_id, rsid, university_raw, university_name, degree_raw, degree,
         field_raw, university_country, startdate
  FROM %s
  WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''
    AND rsid IS NOT NULL", ed_src)))
invisible(dbExecute(con,
  "CREATE TABLE raws AS SELECT DISTINCT university_raw FROM e"))
invisible(dbExecute(con, sprintf("CREATE TABLE cls AS %s",
                                 sprintf(cls_sql, "raws"))))

rw <- dbGetQuery(con, "
  SELECT (SELECT count(*) FROM raws) AS n_raw,
         (SELECT count(*) FROM cls)  AS n_raw_m")
cat("distinct university_raw       :", format(rw$n_raw, big.mark = ","), "\n")
cat("  matched by C_norm           :", format(rw$n_raw_m, big.mark = ","),
    sprintf("(%.1f%%)\n", 100 * rw$n_raw_m / rw$n_raw))

# Note 10. Reported, not fixed: these strings lost their accents to an
# upstream encoding fault and no folding rule can recover them.
moj <- dbGetQuery(con, sprintf("
  SELECT count(DISTINCT university_raw) AS n_str, count(*) AS n_rows
  FROM %s WHERE contains(university_raw, chr(65533))", ed_src))
cat("  unmatchable, U+FFFD in the raw string :",
    format(moj$n_str, big.mark = ","), "strings /",
    format(moj$n_rows, big.mark = ","), "rows  <- note 10\n")

# THE FRAME: schools where C_norm matched at least one raw string.
invisible(dbExecute(con, "
  CREATE TABLE frame AS
  SELECT e.rsid,
         any_value(e.university_name) AS university_name,
         count(*)                         AS n_rows,
         count(DISTINCT e.university_raw) AS n_raw,
         count(DISTINCT e.user_id)        AS n_users,
         sum(CASE WHEN c.university_raw IS NOT NULL THEN 1 ELSE 0 END)
           AS n_rows_m,
         count(DISTINCT CASE WHEN c.university_raw IS NOT NULL
                             THEN e.university_raw END) AS n_raw_m,
         count(DISTINCT CASE WHEN c.university_raw IS NOT NULL
                             THEN e.user_id END)        AS n_users_m,
         arg_max(c.inst_name,
                 CASE WHEN c.university_raw IS NOT NULL THEN 1 ELSE 0 END)
           AS dom_inst
  FROM e LEFT JOIN cls c ON e.university_raw = c.university_raw
  GROUP BY e.rsid
  HAVING n_raw_m > 0"))
invisible(dbExecute(con, "ALTER TABLE frame ADD COLUMN match_share DOUBLE"))
invisible(dbExecute(con,
  "UPDATE frame SET match_share = CAST(n_rows_m AS DOUBLE) / n_rows"))

fr <- dbGetQuery(con, "
  SELECT count(*) AS n_rsid, sum(n_rows) AS rows_under,
         sum(n_rows_m) AS rows_m, sum(n_raw) AS raw_under,
         sum(n_raw_m) AS raw_m, sum(n_users) AS users_under,
         sum(n_users_m) AS users_m FROM frame")
cat("\n--- the frame: schools with >=1 C_norm-matched string ---\n")
cat("  schools (rsid)              :", format(fr$n_rsid, big.mark = ","), "\n")
cat(sprintf("  education rows covered      : %s / %s   %.1f%%\n",
    format(fr$rows_m, big.mark = ","), format(fr$rows_under, big.mark = ","),
    100 * fr$rows_m / fr$rows_under))
cat(sprintf("  distinct strings covered    : %s / %s   %.1f%%\n",
    format(fr$raw_m, big.mark = ","), format(fr$raw_under, big.mark = ","),
    100 * fr$raw_m / fr$raw_under))
cat(sprintf("  users reached               : %s / %s   %.1f%%\n",
    format(fr$users_m, big.mark = ","), format(fr$users_under, big.mark = ","),
    100 * fr$users_m / fr$users_under))

for (chk in list(list(exp_frame_rsid, fr$n_rsid, "schools in the frame"),
                 list(exp_frame_rows, fr$rows_under, "rows under the frame"),
                 list(exp_frame_rows_m, fr$rows_m, "rows matched"),
                 list(exp_raw_matched, rw$n_raw_m, "distinct strings matched"),
                 list(exp_raw_total, rw$n_raw, "distinct strings total"))) {
  if (!is.na(chk[[1]]) && chk[[2]] != chk[[1]]) {
    warning(chk[[3]], ": got ", chk[[2]], ", expected ", chk[[1]],
            call. = FALSE)
  }
}

cat("\n--- coverage by band: the raw total is NOT the headline ---\n")
bands <- dbGetQuery(con, "
  SELECT CASE WHEN match_share >= 0.5   THEN 'a  >= 0.5'
              WHEN match_share >= 0.1   THEN 'b  0.1 - 0.5'
              WHEN match_share >= 0.01  THEN 'c  0.01 - 0.1'
              WHEN match_share >= 0.001 THEN 'd  0.001 - 0.01'
              ELSE 'e  < 0.001' END AS band,
         count(*) AS n_rsid, sum(n_rows) AS rows_under,
         sum(n_rows_m) AS rows_m,
         round(100.0 * sum(n_rows_m) / sum(n_rows), 2) AS pct
  FROM frame GROUP BY 1 ORDER BY 1")
print(bands, right = FALSE)
cat("\n  Band e is the Harvard mechanism of note 11 in the cohort script:\n")
cat("  one stray string dragging a whole foreign school into the frame.\n")
cat("  It is NOT a C_norm miss, and the X class below is what removes it.\n")

invisible(dbExecute(con, sprintf(
  "COPY (SELECT * FROM frame ORDER BY n_rows DESC) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  by_rsid_path)))

####################################################################
### Step 3: bind the audit to the flag the pipeline actually wrote
####################################################################

cat("\n=========== STEP 3: BINDING CHECK ===========\n")

# Worth more than any coverage number below: it proves this script is
# measuring the matcher THAT RAN and not a copy that drifted. Every
# user with a C_norm-matched education row must carry
# br_openalex_norm = 1 in the cohort table. Analogue of Step 3 of
# shanghai_flag_audit.R.
bind <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_checked,
         sum(CASE WHEN k.br_openalex_norm IS NULL THEN 1 ELSE 0 END) AS n_absent,
         sum(CASE WHEN k.br_openalex_norm = 0 THEN 1 ELSE 0 END)     AS n_zero
  FROM (SELECT DISTINCT e.user_id FROM e
        JOIN cls c ON e.university_raw = c.university_raw) x
  LEFT JOIN %s k ON x.user_id = k.user_id", cand_src))
cat("users with a matched row      :", format(bind$n_checked, big.mark = ","), "\n")
cat("  absent from the cohort table:", bind$n_absent, "\n")
cat("  carrying br_openalex_norm=0 :", bind$n_zero, "\n")
if (bind$n_absent != 0 || bind$n_zero != 0) {
  stop(bind$n_absent + bind$n_zero, " users match here but do not carry ",
       "br_openalex_norm = 1. The matcher in this audit is not the one ",
       "revelio_br_cohort_user_ids.R ran. This check earned its keep once ",
       "already -- see note 9.")
}
cat("[OK] the audited matcher reproduces the flag written by scripts 8/9/10\n")

# Same vintage. The cohort (script 10) and this extract (script 10a) are
# separate scans of live Revelio, 19 hours apart. If Revelio had
# refreshed between them, rows would exist here that the cohort never
# saw, and every coverage figure below would be measuring a matcher
# against data it never ran on. criterion B is the probe: an education
# row with university_country = 'Brazil' MUST have set br_educ_country
# on its user. Measured 0 of 2,733,411 users.
vint <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_stale
  FROM (SELECT DISTINCT user_id FROM e WHERE university_country = 'Brazil') x
  JOIN %s k ON x.user_id = k.user_id
  WHERE k.br_educ_country = 0", cand_src))
if (vint$n_stale != 0) {
  stop(vint$n_stale, " users have a Brazilian education row here but ",
       "br_educ_country = 0 in the cohort. The extract post-dates the ",
       "cohort -- Revelio refreshed between scripts 10 and 10a, and the ",
       "coverage figures would be measured against data C_norm never saw.")
}
cat("[OK] extract and cohort are the same Revelio vintage\n")

####################################################################
### Step 4: the 500-university sample
####################################################################

cat("\n=========== STEP 4: THE 500-SCHOOL SAMPLE ===========\n")

rsid_smp_sql <- sprintf("
  SELECT rsid, university_name, dom_inst, n_rows, n_raw, n_users,
         n_rows_m, n_raw_m, n_users_m, match_share,
         hash(CAST(rsid AS VARCHAR) || '#%d') AS hk
  FROM frame ORDER BY hk, rsid LIMIT %d", seed, n_rsid_sample)

if (file.exists(rsid_smp_path)) {
  cat("[skip] school sample already parked:", basename(rsid_smp_path), "\n")
} else {
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    rsid_smp_sql, rsid_smp_path)))
  cat("drew", n_rsid_sample, "schools ->", basename(rsid_smp_path), "\n")
}
invisible(dbExecute(con, sprintf(
  "CREATE TABLE smp_rsid AS SELECT * FROM read_parquet('%s')", rsid_smp_path)))

ns <- dbGetQuery(con,
  "SELECT count(*) AS n, count(DISTINCT rsid) AS nd FROM smp_rsid")
if (ns$n != min(n_rsid_sample, fr$n_rsid) || ns$nd != ns$n) {
  stop("School sample has ", ns$n, " rows / ", ns$nd, " distinct rsid.")
}
# A seed that does not reproduce is worse than no seed: the CSV would
# stop matching the sample in silence. The query is local and free, so
# this runs on EVERY invocation, not only on the draw.
r2 <- dbGetQuery(con, rsid_smp_sql)
if (!identical(sort(dbGetQuery(con, "SELECT rsid FROM smp_rsid")$rsid),
               sort(r2$rsid))) {
  stop("Re-running the school query with the same seed returned a ",
       "DIFFERENT sample.")
}
cat("[OK] ", ns$n, " schools, unique, seed reproducible\n", sep = "")

sm <- dbGetQuery(con, "
  SELECT sum(n_rows) AS rows_under, sum(n_rows_m) AS rows_m,
         sum(n_raw) AS raw_under, sum(n_raw_m) AS raw_m FROM smp_rsid")
cat(sprintf("sampled coverage (rows)       : %s / %s   %.1f%%\n",
    format(sm$rows_m, big.mark = ","), format(sm$rows_under, big.mark = ","),
    100 * sm$rows_m / sm$rows_under))
cat(sprintf("sampled coverage (strings)    : %s / %s   %.1f%%\n",
    format(sm$raw_m, big.mark = ","), format(sm$raw_under, big.mark = ","),
    100 * sm$raw_m / sm$raw_under))

####################################################################
### Step 5: why the unmatched strings missed -- all of them
####################################################################

cat("\n=========== STEP 5: WHY-IT-MISSED TAXONOMY ===========\n")

invisible(dbExecute(con, "
  CREATE TABLE unm AS
  SELECT e.rsid, e.university_raw, count(*) AS n_rows
  FROM e JOIN smp_rsid s ON e.rsid = s.rsid
  LEFT JOIN cls c ON e.university_raw = c.university_raw
  WHERE c.university_raw IS NULL
  GROUP BY 1, 2"))
invisible(dbExecute(con, sprintf("CREATE TABLE tax AS %s",
                                 sprintf(tax_sql, "unm"))))

# The taxonomy is only defined over rejected strings, so this states
# what `unm` is built to guarantee rather than trusting the CTE.
n_leak <- dbGetQuery(con,
  "SELECT count(*) AS n FROM unm u JOIN cls c USING (university_raw)")$n
if (n_leak != 0) {
  stop(n_leak, " matched string(s) leaked into the unmatched set. Every ",
       "taxonomy arm below would be meaningless for them.")
}

un <- dbGetQuery(con, "
  SELECT count(*) AS n_pair, sum(n_rows) AS n_rows,
         count(DISTINCT university_raw) AS n_str FROM unm")
cat("unmatched under the 500       :", format(un$n_rows, big.mark = ","),
    "rows,", format(un$n_str, big.mark = ","), "distinct strings,",
    format(un$n_pair, big.mark = ","), "(rsid, string) pairs\n\n")

print(dbGetQuery(con, "
  SELECT t.miss_cat, count(DISTINCT u.university_raw) AS n_strings,
         sum(u.n_rows) AS n_rows,
         round(100.0 * sum(u.n_rows) / (SELECT sum(n_rows) FROM unm), 1)
           AS pct_rows
  FROM unm u JOIN tax t ON u.university_raw = t.university_raw
  GROUP BY 1 ORDER BY n_rows DESC"), right = FALSE)
cat("\n  Sizes only -- note 8. These arms are looser than anything\n")
cat("  shippable as a criterion; M/A/X below is what adjudicates them.\n")

cat("\n--- worst offenders: biggest schools, lowest coverage ---\n")
print(dbGetQuery(con, "
  SELECT s.rsid, substr(s.university_name, 1, 32) AS school,
         substr(s.dom_inst, 1, 24) AS matched_as, s.n_rows,
         round(s.match_share, 4) AS ms,
         substr(arg_max(u.university_raw, u.n_rows), 1, 38) AS top_unmatched,
         max(u.n_rows) AS top_n
  FROM smp_rsid s JOIN unm u ON s.rsid = u.rsid
  GROUP BY 1, 2, 3, 4, 5 ORDER BY s.n_rows DESC LIMIT 20"), right = FALSE)

####################################################################
### Step 6: the row-weighted string sample and its rubric
####################################################################

cat("\n=========== STEP 6: THE CLASSIFIED SAMPLE ===========\n")

# Row-weighted (note 7) and hashed over a digest of the row's content,
# because education rows carry no unique key (note 6). The context
# columns travel only so the pair can be judged; nothing classifies on
# them.
str_smp_sql <- sprintf("
  SELECT e.rsid, s.university_name AS rsid_school, s.dom_inst,
         s.match_share, e.university_raw, t.miss_cat,
         CAST(e.user_id AS VARCHAR)         AS user_id,
         coalesce(e.degree_raw, '')         AS degree_raw,
         coalesce(e.degree, '')             AS degree,
         coalesce(e.field_raw, '')          AS field_raw,
         coalesce(e.university_country, '') AS university_country,
         CAST(year(e.startdate) AS INTEGER) AS yr,
         CAST(hash(concat_ws('|', e.user_id, e.rsid, e.university_raw,
                        coalesce(e.degree_raw, ''), coalesce(e.degree, ''),
                        coalesce(CAST(e.startdate AS VARCHAR), ''),
                        coalesce(e.field_raw, '')) || '#%d') AS VARCHAR) AS hk
  FROM e
  JOIN smp_rsid s ON e.rsid = s.rsid
  LEFT JOIN cls c ON e.university_raw = c.university_raw
  LEFT JOIN tax t ON e.university_raw = t.university_raw
  WHERE c.university_raw IS NULL
  ORDER BY hk, e.user_id, e.university_raw
  LIMIT %d", seed, n_str_sample)

if (file.exists(str_smp_path)) {
  cat("[skip] string sample already parked:", basename(str_smp_path), "\n")
} else {
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    str_smp_sql, str_smp_path)))
  cat("drew", n_str_sample, "unmatched rows ->", basename(str_smp_path), "\n")
}

s <- dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s')", str_smp_path))

if (nrow(s) != min(n_str_sample, un$n_rows)) {
  stop("String sample has ", nrow(s), " rows, expected ", n_str_sample)
}
if (anyDuplicated(s$hk) != 0) {
  stop("Repeated hash key: the LIMIT is breaking ties arbitrarily and the ",
       "draw is not reproducible.")
}
s2 <- dbGetQuery(con, str_smp_sql)
if (!identical(sort(s$hk), sort(s2$hk))) {
  stop("Re-running the string query with the same seed returned a ",
       "DIFFERENT sample.")
}
# Whatever predicate defined the population is re-asserted in R against
# the rows that came back.
smp_ids <- dbGetQuery(con, "SELECT rsid FROM smp_rsid")$rsid
if (any(is.na(s$rsid)) || !all(s$rsid %in% smp_ids)) {
  stop("A sampled row belongs to a school outside the 500.")
}
cat("[OK] ", nrow(s), " rows, unique hash, seed reproducible, all in frame\n",
    sep = "")

s$ck <- paste(s$rsid, s$university_raw, sep = "###")
uk <- unique(s$ck)
cat("(rsid, university_raw) pairs to classify:", length(uk), "\n")

# The CSV is an ordinary editable file keyed to the parked sample, the
# convention of scripts 11, 13 and 17. A blank verdict is caught by the
# domain check below, which is the intended stop on the first run.
if (!file.exists(class_path)) {
  tpl <- s[!duplicated(s$ck),
           c("rsid", "rsid_school", "dom_inst", "university_raw", "miss_cat",
             "degree_raw", "field_raw", "university_country")]
  tpl <- tpl[order(tpl$rsid, tpl$university_raw), ]
  tpl$verdict <- ""
  tpl$source <- "todo"
  tpl$note <- ""
  write.csv(tpl, class_path, row.names = FALSE, fileEncoding = "UTF-8")
  stop("Wrote an EMPTY classification template with ", nrow(tpl), " rows:\n  ",
       class_path, "\nFill `verdict` with M, A or X on every row (see the ",
       "rubric in the header), set `source` to 'llm' or 'human', and run ",
       "again. The sample is parked and will not be redrawn.")
}

cl <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
               colClasses = "character")
if (!all(c("rsid", "university_raw", "verdict") %in% names(cl))) {
  stop(basename(class_path), " must carry rsid, university_raw and verdict.")
}
cl$ck <- paste(cl$rsid, cl$university_raw, sep = "###")
if (anyDuplicated(cl$ck) != 0) {
  stop("Repeated key in ", basename(class_path), ": ",
       paste(head(unique(cl$ck[duplicated(cl$ck)]), 10), collapse = " | "))
}
off <- setdiff(cl$verdict, cls_dom)
if (length(off)) {
  stop("Verdicts outside {", paste(cls_dom, collapse = ", "), "} in ",
       basename(class_path), ": ", paste(sort(unique(off)), collapse = ", "),
       " (a blank verdict lands here)")
}
# An unclassified key would vanish from the counts and understate the
# miss rate in silence, so this is stop() and the message IS the work list.
miss <- setdiff(uk, cl$ck)
if (length(miss)) {
  stop(length(miss), " (rsid, university_raw) pair(s) unclassified: ",
       paste(head(miss, 20), collapse = " | "))
}
cat("[OK] ", nrow(cl), " pairs classified, one row each, domain valid\n",
    sep = "")

n_before <- nrow(s)
s <- merge(s, cl[, c("ck", "verdict")], by = "ck", all.x = TRUE)
stopifnot(nrow(s) == n_before, !any(is.na(s$verdict)))
if ("source" %in% names(cl)) {
  cat("labels still as the LLM left them   :", sum(cl$source == "llm"), "of",
      nrow(cl), "\n")
}

####################################################################
### Step 7: report
####################################################################

# Exact binomial CI. binom.test(0, n) returns a degenerate interval, so
# zero gets the rule-of-three style bound, as in linkedin_br_name_audit.R
# and shanghai_flag_audit.R.
ci_txt <- function(k, n) {
  if (n == 0) return("     n/a      ")
  ci <- if (k == 0) c(0, 1 - 0.05^(1 / n)) else
    as.numeric(binom.test(k, n)$conf.int)
  sprintf("[%5.1f%%, %5.1f%%]", 100 * ci[1], 100 * ci[2])
}
rate <- function(k, n, lab) {
  cat(sprintf("  %-44s %5d / %5d  %5.1f%%  %s\n", lab, k, n,
              if (n) 100 * k / n else NA_real_, ci_txt(k, n)))
}

cat("\n=========== THE UNMATCHED ROWS, CLASSIFIED ===========\n")
tb <- table(factor(s$verdict, levels = cls_dom))
lab <- c(M = "M  true miss -- C_norm should have matched",
         A = "A  affiliated unit, not the university",
         X = "X  a different institution (rsid noise)",
         N = "N  correctly unmatched (school not Brazilian)")
for (k in cls_dom) {
  cat(sprintf("  %-44s %5d  %5.1f%%\n", lab[[k]], tb[[k]],
              100 * tb[[k]] / nrow(s)))
}

sm_rows_unm <- sm$rows_under - sm$rows_m
est <- setNames(as.numeric(tb) / nrow(s) * sm_rows_unm, cls_dom)

cat("\n=========== RECALL ===========\n")
cat("Reweighted from the labelled rows to the sampled schools.\n")
cat("Only M is a defect. A, X and N leave the denominator: a school's\n")
cat("technical arm, an unrelated string sitting under its key, and a\n")
cat("foreign university are three different things, and none of them\n")
cat("is something C_norm failed to do.\n\n")
cat(sprintf("  unmatched rows under the 500 schools      : %s\n",
            format(round(sm_rows_unm), big.mark = ",")))
for (k in cls_dom) {
  cat(sprintf("    %s  %-38s : %s\n", k,
              c(M = "true misses", A = "affiliated units",
                X = "rsid contamination",
                N = "correctly unmatched")[[k]],
              format(round(est[[k]]), big.mark = ",")))
}
est_M <- est[["M"]]
cat(sprintf("\n  naive coverage  matched / all under frame : %.1f%%\n",
            100 * sm$rows_m / sm$rows_under))
cat(sprintf("  RECALL          matched / (matched + M)   : %.1f%%\n",
            100 * sm$rows_m / (sm$rows_m + est_M)))
cat("\n  The gap between the two lines is what rsid grouping costs a\n")
cat("  naive reading, and is exactly the error the withdrawn C_rsid\n")
cat("  branch made in the opposite direction.\n\n")
rate(tb[["M"]], nrow(s), "labelled rows that are a true miss")

cat("\n=========== TRUE MISSES BY TAXONOMY ARM ===========\n")
cat("Of the rows labelled M, which failure mode produced them.\n")
cat("This is the to-do list, ordered by what it would recover.\n\n")
mm <- s[s$verdict == "M", ]
if (nrow(mm)) {
  tt <- sort(table(mm$miss_cat), decreasing = TRUE)
  for (k in names(tt)) {
    cat(sprintf("  %-16s %5d rows labelled M  (%4.1f%% of all M)\n",
                k, tt[[k]], 100 * tt[[k]] / nrow(mm)))
  }
}

cat("\n=========== PRECISION OF THE TAXONOMY ARMS ===========\n")
cat("When an arm fires, how often is the string really the school?\n\n")
cat(sprintf("  %-16s %8s %7s %7s %7s %7s %8s\n",
            "arm", "fires", "M", "A", "X", "N", "M rate"))
for (k in sort(unique(s$miss_cat))) {
  f <- s[s$miss_cat %in% k, ]
  cat(sprintf("  %-16s %8d %7d %7d %7d %7d %7.1f%%\n", k, nrow(f),
              sum(f$verdict == "M"), sum(f$verdict == "A"),
              sum(f$verdict == "X"), sum(f$verdict == "N"),
              100 * mean(f$verdict == "M")))
}

cat("\n=========== EVERY LABELLED PAIR THAT IS A TRUE MISS ===========\n")
em <- unique(mm[, c("rsid", "rsid_school", "university_raw", "miss_cat")])
em <- em[order(em$miss_cat, em$rsid), ]
cat(nrow(em), "distinct (school, string) pairs C_norm should have matched:\n\n")
if (nrow(em)) {
  for (i in seq_len(min(nrow(em), 60))) {
    cat(sprintf("  [%-14s] %-32s <- %s\n", em$miss_cat[i],
                substr(em$rsid_school[i], 1, 32),
                substr(em$university_raw[i], 1, 46)))
  }
  if (nrow(em) > 60) cat("  ... and", nrow(em) - 60, "more (see the parquet)\n")
}

####################################################################
### Step 8: persist and summarize
####################################################################

invisible(dbWriteTable(con, "classified", s, overwrite = TRUE))
invisible(dbExecute(con, sprintf(
  "COPY classified TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", out_path)))

cat("\n=========== SUMMARY ===========\n")
cat("  per-school coverage :", by_rsid_path, "\n")
cat("  school sample       :", rsid_smp_path, "\n")
cat("  string sample       :", str_smp_path, "\n")
cat("  classification      :", class_path, "\n")
cat("  classified          :", out_path, "\n\n")
cat(sprintf("  frame               : %s schools, %s rows, %.1f%% covered\n",
            format(fr$n_rsid, big.mark = ","),
            format(fr$rows_under, big.mark = ","),
            100 * fr$rows_m / fr$rows_under))
cat(sprintf("  sampled             : %s schools, %s rows, %.1f%% covered\n",
            format(ns$n, big.mark = ","),
            format(sm$rows_under, big.mark = ","),
            100 * sm$rows_m / sm$rows_under))
cat(sprintf("  RECALL after M/A/X/N: %.1f%%\n",
            100 * sm$rows_m / (sm$rows_m + est_M)))
cat("\n  Coverage only. Precision of the matches that WERE made is\n")
cat("  script 17's job -- see note 3.\n")
