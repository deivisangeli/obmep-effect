####################################################################
###
### Revelio Brazilian cohort, ALTERNATIVE -> S3 + Athena
###
### Selects every Revelio user_id that satisfies
###
###   (A OR B OR C_norm OR C_norm_rsid) AND D AND E
###
###   A  some row in academic_individual_position with
###      country = 'Brazil'
###   B  some row in academic_individual_user_education with
###      university_country = 'Brazil'
###   C  some row whose university_raw equals a cleaned_display_name in
###      openalex_institutions_br, lowercased, accent-SENSITIVE, whole
###      string only. Stored, never filtered on.
###   C_norm  the same with accents folded and the match allowed to
###      land on any '/', '( )' or ' - ' delimited SEGMENT of at least
###      3 characters. Whole-string arm: any record type; segment arm:
###      education records only.
###   C_rsid       C      propagated through a surviving rsid  <- NEW
###   C_norm_rsid  C_norm propagated through a surviving rsid  <- NEW
###   D  the FIRST position (smallest startdate) starts in 2007 or later
###   E  the FIRST Bachelor starts in 2007 or later, where "Bachelor"
###      means degree = 'Bachelor' OR a bachelor pattern matched on
###      degree_raw -- see br_degree_patterns.R
###
### This is the ALTERNATIVE to revelio_br_cohort_user_ids.R. That
### script is NOT modified and its table is NOT touched. The only
### difference is the fourth disjunct.
###
### "A surviving rsid" means an rsid in
### revelio_database.rsid_br_user_share that passes
###
###   G1  at least one of its university_raw strings matches C
###       (has_exact) or C_norm (has_norm)
###   G2  br_share_known > 0.5 -- more than half of the rsid's DISTINCT
###       USERS whose user_country is known are located in Brazil
###
### G2 is the whole point. Propagating an institution match through
### Revelio's school key was tried before and WITHDRAWN (see
### revelio_br_cohort_user_ids.R note 11): one stray education row
### enrolled an entire foreign university, and even at its safest
### threshold the branch added 12,023 members of whom 6.3% were located
### in Brazil. G2 attacks that failure directly by asking where the
### school's own people actually are, which is a question the old
### match_share statistic never asked.
###
### Depends on:
###   prep/building_external_data/openalex_institutions_br_to_s3.R
###   (table revelio_database.openalex_institutions_br)
###   prep/building_external_data/rsid_br_user_share.R
###   (table revelio_database.rsid_br_user_share)
###
### Athena read pattern reused from:
###   prep/building_external_data/revelio_br_cohort_user_ids.R
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. That is a deliberate exception: reading from Athena
###    and writing to S3 is the whole point. It is a local prep/ script
###    and must not be sent to the offline SEDAP environment.
### 2. D and E are STRICT: anyone with no position at all, or no
###    Bachelor at all, or only null startdates in either one, is LEFT
###    OUT. The INNER JOIN between the two subqueries is what enforces
###    that -- switching it to a LEFT JOIN would change the definition
###    of the cohort, not just performance.
### 3. THIS COHORT IS A STRICT SUPERSET OF obmep_br_cohort_user_ids.
###    C_norm stays in the WHERE clause beside C_norm_rsid, so a user
###    whose only matched string sits under a REJECTED rsid is still
###    admitted by C_norm alone. That is what licenses min_rows below,
###    and it is why every column of the original table is reproduced
###    here unchanged and in the same order:
###      WHERE br_position = 1 OR br_educ_country = 1
###         OR br_openalex_norm = 1
###    reproduces the original cohort exactly, in place, with no
###    re-scan.
### 4. C_norm_rsid IS NOT A SUPERSET OF C_norm, and nothing here
###    asserts that it is. The gate can reject an rsid that contains a
###    genuinely matched string -- that is the gate doing its job. The
###    ONLY monotonicity that holds is
###      br_openalex_rsid = 1  =>  br_openalex_norm_rsid = 1
###    because the surviving exact rsids are a subset of the surviving
###    normalized ones by construction. That one IS asserted.
### 5. Two rsid flags, not one, because the request applies the
###    propagation to BOTH of the last two criteria. br_openalex_rsid
###    is stored and never filtered on, exactly as br_openalex is:
###    keeping the narrower version of every widened definition is what
###    makes any cut tightenable in Athena without a rebuild.
### 6. THE GATE AMPLIFIES BY DESIGN. A surviving rsid admits EVERY user
###    with an education row under it, including foreign students at
###    USP and including the minority of raw strings under that rsid
###    that Revelio resolved wrongly. That is the intended behaviour of
###    the criterion, not an oversight -- but it means the number to
###    read after a run is the one Step 5 prints: how many members the
###    rsid arm admits ALONE, and what share of them are located in
###    Brazil. Compare it against C_norm's own 5,705 at 32.5% and the
###    withdrawn branch's 12,023 at 6.3%.
### 7. That comparison is PARTLY CIRCULAR and must not be quoted as if
###    it were not. The gate itself reads user_country, so a high
###    Brazil share among rsid-admitted members is partly guaranteed by
###    construction. The honest out-of-sample read is p_brazil from
###    linkedin_br_name_flag, which is independent of both the gate and
###    the criterion; Step 5 reports it alongside.
### 8. startdate is stored differently in the two tables, verified with
###    DESCRIBE: string in academic_individual_position, date in
###    academic_individual_user_education. The two sides of the query
###    handle it differently ON PURPOSE. See README trap 1 before
###    touching either one.
### 9. Revelio's `degree` column is NOT trustworthy on Brazilian
###    records, which is why criterion E does not rely on it alone --
###    'bacharelado' is labelled High School on 489,815 rows and
###    Bachelor on 762,945, the same string split
###    non-deterministically. min_bach_year_strict stores the year
###    under the OLD degree = 'Bachelor' rule so the pre-correction
###    definition is recoverable in place. See br_degree_patterns.R.
### 10. The query aggregates BOTH Revelio individual tables in full and
###    joins the small rsid table.
###
###    MEASURED 2026-09-04: the UNLOAD scanned 90.17 GB (~$0.45) in
###    57.5 s. That is about TWICE the ~36-48 GB the README publishes
###    for the original cohort, and the cause is not established: the
###    only deliberate additions are the `rsid` column on a projection
###    that was already being read and a join against a few-thousand-row
###    table, neither of which plausibly doubles a scan. It may be that
###    the published figure predates a Revelio refresh. Budget $0.45,
###    and do not quote the README's cohort figure for this script.
###
###    Step 5's precision report is NOT free either -- it reads
###    academic_individual_user and linkedin_br_name_flag and measured
###    7.73 GB (~$0.04). Everything else in Step 5 reads finished
###    tables. Total for a rebuild: about $0.49.
###
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "aws.s3", "RAthena", "arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(aws.s3)

####################################################################
### Parameters
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")

out_dir  <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
out_path <- file.path(out_dir, "obmep_br_cohort_user_ids_alt.parquet")

min_year <- 2007

# The gate. MUST match br_share_min in rsid_br_user_share.R: that
# script reports and rejects on this number, this one admits on it, and
# a disagreement would mean the rejected-pairs CSV describes a cut the
# cohort did not apply.
br_share_min <- 0.5

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
s3_prefix <- "exports/obmep_br_cohort_user_ids_alt"
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table  <- "obmep_br_cohort_user_ids_alt"

# Institutions table registered by openalex_institutions_br_to_s3.R.
inst_table <- "openalex_institutions_br"
# Per-rsid user location, registered by rsid_br_user_share.R.
share_table <- "rsid_br_user_share"
# The cohort this one is the alternative to, for the comparison in
# Step 5. Read-only; never written here.
base_table <- "obmep_br_cohort_user_ids"
# Name prior, for the independent precision read of note 7.
flag_table <- "linkedin_br_name_flag"
# Profile location. Read ONLY in the Step 5 report, never in the
# criterion: the gate already applied it, per rsid, in 8a.
user_table <- "academic_individual_user"

# Measured 2026-09-04 on the first run. The rsid arm admits 27,838
# members that (A OR B OR C_norm) does not, at 22.5% located in Brazil
# -- against the withdrawn branch's 12,023 at 6.3% and C_norm's own
# 5,705 at 32.5%. See Step 5 and the README.
exp_rows <- 5763858

# Membership floor: this cohort adds a DISJUNCT to
# (A OR B OR C_norm) and removes nothing, so everyone in
# obmep_br_cohort_user_ids is still admitted (note 3). A smaller cohort
# is impossible by construction and means the criterion is wrong --
# most likely that C_norm was replaced by C_norm_rsid in the WHERE
# clause rather than joined to it.
min_rows <- 5736020

# RAthena talks to Athena through boto3/reticulate. On this machine the
# `python` on PATH is the WindowsApps shim, which reticulate ignores on
# purpose -- so py_discover_config() finds nothing and RAthena concludes
# boto3 is missing, when in fact a real Python with boto3 and numpy is
# already installed. Pointing reticulate at the real interpreter fixes
# it without installing anything.
#
# Only set when RETICULATE_PYTHON is empty: an interactive session that
# already resolves Python correctly is never overridden.
py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

# Shared with revelio_br_cohort_user_ids.R and
# revelio_br_name_cohort_user_ids.R: defines rx_* and sql_is_bachelor.
# Constants only -- no functions, no side effects. Criterion E MUST be
# the same in every cohort or the cohorts stop being comparable.
patterns_file <- Sys.getenv(
  "OBMEP_DEGREE_PATTERNS",
  unset = paste0("C:/Users/megaj/repos/obmep_effect/prep/",
                 "building_external_data/br_degree_patterns.R"))
if (!file.exists(patterns_file)) patterns_file <- "br_degree_patterns.R"
stopifnot(file.exists(patterns_file))
source(patterns_file)

####################################################################
### Step 1: build the query
####################################################################

# The SELECT body lives in its own variable for two reasons: it is
# reused inside the UNLOAD, and it can be validated on its own (see
# scratchpad/validate_sql_syntax.R), whereas UNLOAD and DDL cannot.
#
# The inst_fold / inst_exact / raws / seg / raw_cls block is COPIED
# VERBATIM from revelio_br_cohort_user_ids.R. It is not re-derived and
# not "improved": criteria C and C_norm have to mean exactly what they
# mean in the original cohort or the two tables are not comparable.
# Everything the original file says about that block still applies --
# the LEFT JOIN goes against distinct strings so it cannot multiply
# education rows, the UNNEST runs over distinct university_raw rather
# than over every row, the whole-string arm reads inst_fold so Estacio
# (a `company` record with no education record of its own) still
# matches, the segment arm requires is_edu = 1 so "Curso de Ingles -
# Intel" cannot match Intel, and length(trim(part)) >= 3 drops the
# fragments splitting produces.
#
# What is new, and only this:
#
#  - rsid_keep reads rsid_br_user_share and applies the gate. It is
#    GROUPed to rsid grain because that table's grain is
#    (rsid, university_raw) -- joining it ungrouped would multiply
#    education rows by the number of matched strings under the school.
#    It is a few thousand rows, so the aggregation is free.
#  - the innermost education projection now also reads `rsid`. That
#    column was not read by the original cohort at all.
#  - br_openalex_rsid / br_openalex_norm_rsid come from a LEFT JOIN on
#    rsid, coalesced to 0, and are aggregated per user with max() like
#    every other flag. coalesce is right here and NOT a NULL: a user
#    whose rsid is absent from the gate table provably fails the
#    criterion, which is a measured 0 rather than an unknown.
#  - the WHERE clause gains the fourth disjunct and keeps the other
#    three (note 3).
#  - min(CASE WHEN degree = 'Bachelor' THEN ... END) gives the first
#    Bachelor and returns NULL for anyone with none -- exactly what
#    criterion E has to reject.
#  - the two tables do NOT store startdate the same way, which is why
#    the two sides look different: the position column is a string, so
#    it takes the year off the front with try_cast, and the education
#    column is a date, so it calls year() directly and CASTs the
#    bigint that returns down to integer. Do not "simplify" the two
#    sides into one form (note 8, README traps 1 and 5).
select_sql <- sprintf("
WITH inst_fold AS (
  SELECT lower(regexp_replace(normalize(cleaned_display_name, NFD), '\\p{M}', '')) AS nm_fold,
         max(CASE WHEN type = 'education' THEN 1 ELSE 0 END) AS is_edu
  FROM %s
  GROUP BY lower(regexp_replace(normalize(cleaned_display_name, NFD), '\\p{M}', ''))
),
inst_exact AS (
  SELECT DISTINCT lower(cleaned_display_name) AS nm_exact FROM %s
),
raws AS (
  SELECT DISTINCT university_raw
  FROM academic_individual_user_education
  WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''
),
seg AS (
  SELECT r.university_raw, 1 AS seg_edu
  FROM raws r
  CROSS JOIN UNNEST(split(regexp_replace(regexp_replace(
               r.university_raw, '[/()]', '|'), ' - ', '|'), '|')) AS t(part)
  JOIN inst_fold i
    ON lower(regexp_replace(normalize(trim(t.part), NFD), '\\p{M}', '')) = i.nm_fold
  WHERE length(trim(t.part)) >= 3 AND i.is_edu = 1
  GROUP BY r.university_raw
),
raw_cls AS (
  SELECT r.university_raw,
         CASE WHEN lower(trim(r.university_raw)) IN (SELECT nm_exact FROM inst_exact)
              THEN 1 ELSE 0 END AS m_exact,
         CASE WHEN lower(regexp_replace(normalize(trim(r.university_raw), NFD), '\\p{M}', ''))
                   IN (SELECT nm_fold FROM inst_fold)
               OR s.seg_edu = 1
              THEN 1 ELSE 0 END AS m_norm
  FROM raws r
  LEFT JOIN seg s ON r.university_raw = s.university_raw
),
rsid_keep AS (
  SELECT rsid,
         max(has_exact) AS keep_exact,
         max(has_norm)  AS keep_norm
  FROM %s
  WHERE br_share_known > %.4f
  GROUP BY rsid
)
SELECT p.user_id,
       p.br_position,
       e.br_educ_country,
       e.br_openalex,
       e.br_openalex_norm,
       e.br_openalex_rsid,
       e.br_openalex_norm_rsid,
       p.min_pos_year,
       e.min_bach_year,
       e.min_bach_year_strict
FROM (
  SELECT user_id,
         min(try_cast(substr(startdate, 1, 4) AS integer)) AS min_pos_year,
         max(CASE WHEN country = 'Brazil' THEN 1 ELSE 0 END) AS br_position
  FROM academic_individual_position
  GROUP BY user_id
) p
INNER JOIN (
  SELECT user_id,
         min(CASE WHEN is_bach   THEN bach_year END) AS min_bach_year,
         min(CASE WHEN is_strict THEN bach_year END) AS min_bach_year_strict,
         max(br_educ_country)       AS br_educ_country,
         max(br_openalex)           AS br_openalex,
         max(br_openalex_norm)      AS br_openalex_norm,
         max(br_openalex_rsid)      AS br_openalex_rsid,
         max(br_openalex_norm_rsid) AS br_openalex_norm_rsid
  FROM (
    SELECT e.user_id,
           CAST(year(e.startdate) AS integer) AS bach_year,
           (%s) AS is_bach,
           (e.degree = 'Bachelor') AS is_strict,
           CASE WHEN e.university_country = 'Brazil' THEN 1 ELSE 0 END AS br_educ_country,
           coalesce(c.m_exact, 0)   AS br_openalex,
           coalesce(c.m_norm, 0)    AS br_openalex_norm,
           coalesce(k.keep_exact, 0) AS br_openalex_rsid,
           coalesce(k.keep_norm, 0)  AS br_openalex_norm_rsid
    FROM (
      SELECT user_id, startdate, degree, university_country, university_raw,
             rsid,
             lower(trim(coalesce(degree_raw, ''))) AS dr
      FROM academic_individual_user_education
    ) e
    LEFT JOIN raw_cls c
      ON e.university_raw = c.university_raw
    LEFT JOIN rsid_keep k
      ON e.rsid = k.rsid
  ) x
  GROUP BY user_id
) e
  ON p.user_id = e.user_id
WHERE (p.br_position = 1 OR e.br_educ_country = 1
       OR e.br_openalex_norm = 1 OR e.br_openalex_norm_rsid = 1)
  AND p.min_pos_year  IS NOT NULL AND p.min_pos_year  >= %d
  AND e.min_bach_year IS NOT NULL AND e.min_bach_year >= %d",
  inst_table, inst_table, share_table, br_share_min, sql_is_bachelor,
  min_year, min_year)

unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')",
  select_sql, s3_path)

# The original eight columns, in the original order, with the two new
# flags inserted after br_openalex_norm (note 3).
ddl_txt <- sprintf(
"CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (
  user_id BIGINT,
  br_position INT,
  br_educ_country INT,
  br_openalex INT,
  br_openalex_norm INT,
  br_openalex_rsid INT,
  br_openalex_norm_rsid INT,
  min_pos_year INT,
  min_bach_year INT,
  min_bach_year_strict INT
)
STORED AS PARQUET
LOCATION '%s'", athena_schema, athena_table, s3_path)

cat("=========== GENERATED SQL ===========\n")
cat(unload_sql, "\n\n")
cat(ddl_txt, "\n\n")

####################################################################
### Step 2: check that the destination prefix is empty
####################################################################

# UNLOAD fails if the destination prefix is not empty. Failing here,
# with a clear message, beats spending the scan of both individual
# tables only for Athena to refuse the write afterwards.
cat("=========== CURRENT CONTENTS OF THE S3 PREFIX ===========\n")
existing <- tryCatch(
  get_bucket(bucket = s3_bucket, prefix = paste0(s3_prefix, "/"),
             region = s3_region, max = 100),
  error = function(e) { cat("  [listing error]:", conditionMessage(e), "\n"); NULL })
if (is.null(existing) || length(existing) == 0) {
  cat("  prefix is empty\n\n")
} else {
  for (o in existing) cat("  ", o$Key, " (", o$Size, " bytes )\n")
  stop("Prefix ", s3_path, " is not empty. Athena UNLOAD requires an ",
       "empty destination: delete the objects above (and the table ",
       athena_schema, ".", athena_table, ", if it exists) before regenerating.")
}

####################################################################
### Step 3: run the UNLOAD and register the table
####################################################################

cat("=========== ATHENA ===========\n")
con <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name    = s3_region,
                 schema_name    = athena_schema)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

# The institutions table has to exist first: without it criteria C and
# C_norm silently disappear and the cohort comes out smaller with no
# warning.
inst_n <- dbGetQuery(con, sprintf("SELECT count(*) AS n FROM %s.%s",
                                  athena_schema, inst_table))
cat("BR institutions available     :", format(inst_n$n, big.mark = ","), "\n")
if (inst_n$n == 0) {
  stop("Table ", athena_schema, ".", inst_table, " is empty. ",
       "Run openalex_institutions_br_to_s3.R first.")
}

# Same reasoning for the gate table, and one step further: an EMPTY
# rsid_br_user_share would make the new disjunct vanish and this script
# would quietly reproduce the original cohort under a different name,
# passing every other check on the way.
kp <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_rows,
         count(DISTINCT rsid) AS n_rsid,
         count(DISTINCT CASE WHEN br_share_known > %.4f THEN rsid END) AS n_keep,
         count(DISTINCT CASE WHEN br_share_known > %.4f AND has_exact = 1
                             THEN rsid END) AS n_keep_exact
  FROM %s.%s", br_share_min, br_share_min, athena_schema, share_table))
cat("rsid_br_user_share rows       :", format(kp$n_rows, big.mark = ","), "\n")
cat("  distinct rsid               :", format(kp$n_rsid, big.mark = ","), "\n")
cat("  surviving the gate          :", format(kp$n_keep, big.mark = ","),
    sprintf("(br_share_known > %g)\n", br_share_min))
cat("  of those, on the exact arm  :", format(kp$n_keep_exact, big.mark = ","), "\n")
if (kp$n_rows == 0) {
  stop("Table ", athena_schema, ".", share_table, " is empty. ",
       "Run rsid_br_user_share.R first.")
}
if (kp$n_keep == 0) {
  stop("No rsid survives br_share_known > ", br_share_min, ". The new ",
       "disjunct would be dead and this cohort would silently equal ",
       base_table, ". Read the band table printed by rsid_br_user_share.R ",
       "before changing the threshold.")
}

cat("\nRunning UNLOAD (scans both individual tables)...\n")
t0 <- Sys.time()
dbExecute(con, unload_sql)
cat("  finished in",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n\n")

cat(ddl_txt, "\n")
dbExecute(con, ddl_txt)

####################################################################
### Step 4: validation through Athena
####################################################################

cat("\n=========== VALIDATION ===========\n")
v <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_rows,
         count(DISTINCT user_id) AS n_users,
         sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS uid_null,
         min(min_pos_year)  AS pos_year_min,  max(min_pos_year)  AS pos_year_max,
         min(min_bach_year) AS bach_year_min, max(min_bach_year) AS bach_year_max,
         sum(CASE WHEN min_bach_year_strict < min_bach_year THEN 1 ELSE 0 END) AS bad_strict,
         sum(br_position)           AS n_br_position,
         sum(br_educ_country)       AS n_br_educ_country,
         sum(br_openalex)           AS n_br_openalex,
         sum(br_openalex_norm)      AS n_br_openalex_norm,
         sum(br_openalex_rsid)      AS n_br_openalex_rsid,
         sum(br_openalex_norm_rsid) AS n_br_openalex_norm_rsid,
         sum(CASE WHEN br_openalex_norm_rsid = 1 AND br_position = 0
                   AND br_educ_country = 0 AND br_openalex_norm = 0
                  THEN 1 ELSE 0 END) AS n_rsid_only,
         sum(CASE WHEN br_openalex_norm = 1 AND br_position = 0
                   AND br_educ_country = 0 AND br_openalex = 0
                  THEN 1 ELSE 0 END) AS n_norm_only,
         sum(CASE WHEN br_openalex = 1 AND br_openalex_norm = 0
                  THEN 1 ELSE 0 END) AS bad_not_superset,
         sum(CASE WHEN br_openalex_rsid = 1 AND br_openalex_norm_rsid = 0
                  THEN 1 ELSE 0 END) AS bad_rsid_superset,
         sum(CASE WHEN br_position = 0 AND br_educ_country = 0
                   AND br_openalex_norm = 0 AND br_openalex_norm_rsid = 0
                  THEN 1 ELSE 0 END) AS bad_no_flag
  FROM %s.%s", athena_schema, athena_table))
print(v)

if (v$n_users != v$n_rows) stop("Duplicate user_id in the cohort.")
if (v$uid_null != 0) stop("NULL user_id in the cohort.")
if (v$pos_year_min < min_year) {
  stop("min_pos_year ", v$pos_year_min, " is below the cutoff of ", min_year)
}
if (v$bach_year_min < min_year) {
  stop("min_bach_year ", v$bach_year_min, " is below the cutoff of ", min_year)
}
# Every member must be admitted by something. Computed from the same
# four flags the WHERE clause uses, so a non-zero here means the flags
# stored do not match the flags filtered on.
if (v$bad_no_flag != 0) {
  stop(v$bad_no_flag, " rows have none of the four Brazil flags set.")
}
# C_norm is a strict superset of C at the string level: folding accents
# and accepting segment matches can only ADD strings, never remove one.
# The original cohort asserts this and so does this one.
if (v$bad_not_superset != 0) {
  stop(v$bad_not_superset, " rows have br_openalex = 1 but ",
       "br_openalex_norm = 0. C_norm must be a superset of C.")
}
# The only monotonicity the rsid arms have (note 4): the surviving
# exact rsids are a subset of the surviving normalized ones, because
# has_exact = 1 implies has_norm = 1 in the gate table.
if (v$bad_rsid_superset != 0) {
  stop(v$bad_rsid_superset, " rows have br_openalex_rsid = 1 but ",
       "br_openalex_norm_rsid = 0. The surviving exact rsids must be a ",
       "subset of the surviving normalized ones.")
}
# Strict rows are a SUBSET of union rows, so their minimum can never be
# earlier. If it is, the two aggregates disagree and the predicate is
# wrong.
if (v$bad_strict != 0) {
  stop(v$bad_strict, " rows have min_bach_year_strict < min_bach_year.")
}
# Note 3: a disjunct was added and nothing removed, so membership
# cannot shrink. This is the sharpest check in the run -- it is what
# catches C_norm being REPLACED by C_norm_rsid instead of joined to it.
if (!is.na(min_rows) && v$n_rows < min_rows) {
  stop("Cohort has ", v$n_rows, " rows, fewer than ", base_table, "'s ",
       min_rows, ". Adding a disjunct cannot shrink membership -- the ",
       "criterion is wrong.")
}
if (!is.na(exp_rows) && v$n_rows != exp_rows) {
  warning("Expected ", exp_rows, " rows, got ", v$n_rows)
}
if (is.na(exp_rows)) {
  cat("\n[!] exp_rows is NA -- the drift check is DISABLED.\n",
      "    Fill in the measured value above before relying on this table.\n",
      sep = "")
}

cat("\nrows in the alt cohort        :", format(v$n_rows, big.mark = ","), "\n")
cat("  A: by position in Brazil    :", format(v$n_br_position, big.mark = ","), "\n")
cat("  B: by university_country    :", format(v$n_br_educ_country, big.mark = ","), "\n")
cat("  C: exact institution name   :", format(v$n_br_openalex, big.mark = ","), "\n")
cat("  C_norm: normalized name     :",
    format(v$n_br_openalex_norm, big.mark = ","), "\n")
cat("  C_rsid: surviving rsid, exact arm      :",
    format(v$n_br_openalex_rsid, big.mark = ","), "\n")
cat("  C_norm_rsid: surviving rsid, norm arm  :",
    format(v$n_br_openalex_norm_rsid, big.mark = ","), "\n")
cat("[OK] all validations passed\n\n")

####################################################################
### Step 5: what the new criterion is actually worth
####################################################################

# Membership gain over the cohort this replaces. The comparison is
# against the LIVE table rather than against min_rows, so a stale
# constant cannot make it look better than it is.
cat("=========== MEMBERSHIP ===========\n")
cmp <- dbGetQuery(con, sprintf("
  SELECT (SELECT count(*) FROM %s.%s) AS n_base,
         (SELECT count(*) FROM %s.%s) AS n_alt,
         (SELECT count(*) FROM %s.%s a
            LEFT JOIN %s.%s b ON a.user_id = b.user_id
           WHERE b.user_id IS NULL) AS n_new,
         (SELECT count(*) FROM %s.%s b
            LEFT JOIN %s.%s a ON a.user_id = b.user_id
           WHERE a.user_id IS NULL) AS n_lost",
  athena_schema, base_table, athena_schema, athena_table,
  athena_schema, athena_table, athena_schema, base_table,
  athena_schema, base_table, athena_schema, athena_table))
print(cmp)
# n_lost is the same assertion as min_rows, checked member by member
# instead of by count: a superset cannot drop anybody (note 3).
if (cmp$n_lost != 0) {
  stop(cmp$n_lost, " members of ", base_table, " are ABSENT from the alt ",
       "cohort. A superset cannot lose members.")
}
cat("  ", base_table, ":", format(cmp$n_base, big.mark = ","), "\n")
cat("  ", athena_table, ":", format(cmp$n_alt, big.mark = ","),
    sprintf("(+%s, +%.2f%%)\n", format(cmp$n_new, big.mark = ","),
            100 * as.numeric(cmp$n_new) / as.numeric(cmp$n_base)))
cat("  admitted ONLY by the rsid arm:",
    format(v$n_rsid_only, big.mark = ","), "\n")
cat("  admitted ONLY by C_norm      :",
    format(v$n_norm_only, big.mark = ","),
    "(C_norm's own contribution was 5,705)\n")

# THE number, and its caveat. user_country is what the gate is built
# on, so a high Brazil share here is partly circular (note 7) -- which
# is why p_brazil, independent of both the gate and the criterion, is
# reported in the same table. Read the two together.
#
# Benchmarks from the README, measured on the ORIGINAL cohort:
#   C_norm only                          5,705 at 32.5% in Brazil
#   withdrawn C_rsid, match_share >= 0.5 12,023 at  6.3%
#   name prior only                  1,113,654 at  0.5%
cat("\n=========== PRECISION OF EACH ADMITTING ARM ===========\n")
prec <- dbGetQuery(con, sprintf("
  SELECT grp,
         count(*) AS users,
         sum(CASE WHEN u.user_country = 'Brazil' THEN 1 ELSE 0 END) AS in_brazil,
         avg(f.p_brazil) AS p_brazil_mean,
         approx_percentile(f.p_brazil, 0.5) AS p_brazil_p50,
         sum(CASE WHEN f.p_brazil > 0.5 THEN 1 ELSE 0 END) AS p_brazil_gt_half,
         sum(CASE WHEN f.p_brazil IS NULL THEN 1 ELSE 0 END) AS p_brazil_null
  FROM (
    SELECT user_id,
           CASE WHEN br_position = 1 THEN 'A  position in Brazil'
                WHEN br_educ_country = 1 THEN 'B  university_country, no A'
                WHEN br_openalex = 1 THEN 'C  exact name, no A/B'
                WHEN br_openalex_norm = 1 THEN 'D  C_norm only, no A/B/C'
                ELSE 'E  rsid arm ONLY' END AS grp
    FROM %s.%s
  ) c
  LEFT JOIN %s.%s u ON c.user_id = u.user_id
  LEFT JOIN %s.%s f ON c.user_id = f.user_id
  GROUP BY grp ORDER BY grp", athena_schema, athena_table,
  athena_schema, user_table, athena_schema, flag_table))
prec$pct_brazil <- 100 * as.numeric(prec$in_brazil) / as.numeric(prec$users)
print(prec, right = FALSE, row.names = FALSE)
cat("\n  Group E is the criterion on trial. Benchmarks on the ORIGINAL\n",
    "  cohort: C_norm-only 5,705 at 32.5%, the WITHDRAWN rsid branch\n",
    "  12,023 at 6.3%, name-prior-only 1,113,654 at 0.5%.\n",
    "  Near 6% means this has reproduced the withdrawn branch's failure.\n",
    "  And read pct_brazil together with p_brazil_*: the gate is built on\n",
    "  user_country, so that column is only partly out of sample, while\n",
    "  the name prior is fully independent of both (note 7).\n", sep = "")

print(dbGetQuery(con, sprintf("SELECT * FROM %s.%s LIMIT 10",
                              athena_schema, athena_table)))

####################################################################
### Step 6: bring the result back to Dropbox
####################################################################

# arrow reads the whole prefix: UNLOAD writes several files.
cat("\n=========== LOCAL COPY ===========\n")
if (!arrow::arrow_with_s3()) {
  stop("This arrow build has no S3 support. Download the files from ",
       s3_path, " with the AWS CLI and read them from disk, or reinstall ",
       "arrow with S3 enabled.")
}
ds <- arrow::open_dataset(s3_path, format = "parquet")
# write_parquet does not take a Dataset: materialize a Table first. Ten
# narrow columns, so it fits in memory even at tens of millions of rows.
arrow::write_parquet(arrow::Scanner$create(ds)$ToTable(), out_path,
                     compression = "snappy")

local_n <- nrow(arrow::open_dataset(out_path, format = "parquet"))
cat("rows in the local parquet     :", format(local_n, big.mark = ","), "\n")
if (local_n != v$n_rows) {
  stop("Local parquet has ", local_n, " rows, Athena reported ", v$n_rows)
}

cat("\n=========== SUMMARY ===========\n")
cat("  local parquet :", out_path,
    sprintf("(%.2f MB)\n", file.info(out_path)$size / 2^20))
cat("  S3 prefix     :", s3_path, "\n")
cat("  Athena table  :", paste0(athena_schema, ".", athena_table), "\n")
cat("  rows          :", format(v$n_rows, big.mark = ","), "\n")
cat("  criterion     : (A OR B OR C_norm OR C_norm_rsid) AND D AND E\n")
cat("  gate          : br_share_known >", br_share_min, "from",
    paste0(athena_schema, ".", share_table), "\n")
cat("  cutoff        : first position and first Bachelor >=",
    min_year, "\n")
