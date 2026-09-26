####################################################################
###
### OBMEP candidate pool, step 1 -> S3 + Athena
###
### Unions the two cohort tables and deduplicates on user_id:
###
###   revelio_database.obmep_br_cohort_user_ids       (5,736,020)
###   revelio_database.obmep_br_name_cohort_user_ids  (3,779,509)
###   -> revelio_database.obmep_candidates_step_1     (6,849,674)
###
### Both sources apply the same date criteria -- first position in
### 2007 or later, first bachelor in 2007 or later, the latter using
### the corrected degree_raw test in br_degree_patterns.R -- and
### differ only in which Brazil signal admits a user:
###
###   country cohort : country = 'Brazil' on a position, OR
###                    university_country = 'Brazil', OR a normalized
###                    OpenAlex Brazilian institution name match
###   name cohort    : p_brazil > 0.5 on the given-name prior
###
### This is the BROAD pool handed to whatever narrowing comes next,
### not a final sample. Hence "step 1".
###
### Depends on:
###   prep/building_external_data/revelio_br_cohort_user_ids.R
###   prep/building_external_data/revelio_br_name_cohort_user_ids.R
###   prep/building_external_data/linkedin_br_flag_to_s3.R
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. That is a deliberate exception: reading from Athena
###    and writing to S3 is the whole point. It is a local prep/ script
###    and must not be sent to the offline SEDAP environment.
### 2. Some candidates carry NO observed Brazil signal at all -- no
###    Brazilian job, no Brazilian university, no institution name
###    OpenAlex institution match. Their only evidence is a first name
###    scoring above 0.5 on a prior that linkedin_br_flag_to_s3.R
###    explicitly warns is NOT nationality. They are exactly the
###    name-cohort-only set, and were 1,115,460 (16.3%) before the
###    C_norm existed. False positives concentrate there; every
###    flag plus the raw p_brazil is stored so they can be filtered or
###    down-weighted downstream without rescanning anything.
### 8. br_openalex is the OLD exact institution match and
###    br_openalex_norm the widened one (criterion C_norm; see
###    revelio_br_cohort_user_ids.R note 11). Both are carried, so
###      WHERE br_position = 1 OR br_educ_country = 1 OR br_openalex = 1
###    reproduces the pre-C_norm pool exactly with no re-scan. An
###    rsid-propagation branch was tried between the two and
###    withdrawn; the crosswalk it used survives as script 6 but
###    nothing consumes it.
### 3. COALESCE across the two sources is safe because they AGREE. For
###    all 2,664,049 users present in both, every shared column
###    (br_position, br_educ_country, br_openalex, min_pos_year,
###    min_bach_year, min_bach_year_strict) is identical -- measured,
###    zero discrepancies. No tie-breaking rule is needed.
### 4. A country-cohort-only member provably has br_name = 0: anyone
###    with p_brazil > 0.5 already satisfies the date criteria by
###    virtue of being in a cohort, so they would necessarily also be
###    in the name cohort. Verified in the other direction too -- 0
###    name-cohort members carrying an observed Brazil signal are
###    absent from the country cohort. The validation below re-asserts
###    this by requiring br_name = in_name_cohort on every row.
### 5. p_brazil is backfilled across the WHOLE union, so country-only
###    members carry their real name score instead of NULL. It stays
###    NULL only for profiles absent from linkedin_br_name_flag
###    entirely: non-Latin-alphabet names, which have NULL p_brazil
###    upstream and never enter that crosswalk.
### 6. No Revelio individual table is read here. This touches only the
###    two finished cohort tables and the name crosswalk, so it is
###    cheap -- about 0.85 GB scanned, versus ~38 GB for either cohort.
### 7. min_bach_year_strict is carried through: it holds the year under
###    the OLD degree = 'Bachelor' rule, so the pre-correction
###    definition stays recoverable in place.
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
out_path <- file.path(out_dir, "obmep_candidates_step_1.parquet")

min_year <- 2007
p_cut    <- 0.5

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
s3_prefix <- "exports/obmep_candidates_step_1"
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table  <- "obmep_candidates_step_1"

# Upstream tables.
country_table <- "obmep_br_cohort_user_ids"
name_table    <- "obmep_br_name_cohort_user_ids"
flag_table    <- "linkedin_br_name_flag"

# Deterministic from two fixed inputs, so unlike the cohort scripts a
# mismatch here is a stop(), not a warning(): it means an input changed
# underneath and the result should not be written.
#
# NA disables a check, which is what a deliberate rebuild needs: set
# them to NA, run, then IMMEDIATELY fill in the measured values so the
# stop() semantics come back. Leaving them NA turns this table's
# strongest guarantee off. Under (A OR B OR C) they were 6,845,775 /
# 3,066,266 / 2,664,049 / 1,115,460.
# Re-measured after C_norm replaced the withdrawn rsid branch.
exp_rows         <- 6849674
exp_country_only <- 3070165
exp_both         <- 2665855
exp_name_only    <- 1113654

# Membership floor: the union of two cohorts, one of which only grew.
min_rows <- 6845775

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

####################################################################
### Step 1: build the query
####################################################################

# The SELECT body lives in its own variable for two reasons: it is
# reused inside the UNLOAD, and it can be validated on its own (see
# validate_sql_syntax.R), whereas UNLOAD and DDL cannot.
#
# Notes on the shape of the query:
#
#  - UNION, not UNION ALL, in the driving subquery. That IS the
#    deduplication: 9,509,824 stacked rows collapse to 6,845,775
#    distinct user_ids.
#  - all three joins are 1:1. The two cohort tables are unique on
#    user_id by their own validation, and linkedin_br_name_flag is
#    checked below before this runs.
#  - coalesce() over the two cohort sources is safe because they agree
#    on every shared column for the 2,664,049 users in both. See note 3
#    in the header.
#  - br_name is recomputed from a FRESH p_brazil lookup rather than
#    copied from the name cohort. That makes it independent of
#    in_name_cohort, so requiring the two to agree is a real check
#    rather than a tautology.
select_sql <- sprintf("
SELECT u.user_id,
       CASE WHEN c.user_id IS NOT NULL THEN 1 ELSE 0 END AS in_country_cohort,
       CASE WHEN n.user_id IS NOT NULL THEN 1 ELSE 0 END AS in_name_cohort,
       CASE WHEN f.p_brazil > %.4f     THEN 1 ELSE 0 END AS br_name,
       coalesce(c.br_position,          n.br_position)          AS br_position,
       coalesce(c.br_educ_country,      n.br_educ_country)      AS br_educ_country,
       coalesce(c.br_openalex,          n.br_openalex)          AS br_openalex,
       coalesce(c.br_openalex_norm,     n.br_openalex_norm)     AS br_openalex_norm,
       f.p_brazil,
       coalesce(c.min_pos_year,         n.min_pos_year)         AS min_pos_year,
       coalesce(c.min_bach_year,        n.min_bach_year)        AS min_bach_year,
       coalesce(c.min_bach_year_strict, n.min_bach_year_strict) AS min_bach_year_strict
FROM (
  SELECT user_id FROM %s
  UNION
  SELECT user_id FROM %s
) u
LEFT JOIN %s c ON u.user_id = c.user_id
LEFT JOIN %s n ON u.user_id = n.user_id
LEFT JOIN %s f ON u.user_id = f.user_id",
  p_cut, country_table, name_table, country_table, name_table, flag_table)

unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')",
  select_sql, s3_path)

ddl_txt <- sprintf(
"CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (
  user_id BIGINT,
  in_country_cohort INT,
  in_name_cohort INT,
  br_name INT,
  br_position INT,
  br_educ_country INT,
  br_openalex INT,
  br_openalex_norm INT,
  p_brazil DOUBLE,
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
# with a clear message, beats letting Athena refuse the write.
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
### Step 3: check the upstream tables
####################################################################

cat("=========== ATHENA ===========\n")
con <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name    = s3_region,
                 schema_name    = athena_schema)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

# Sizes of the two sources, and uniqueness of the crosswalk. If any
# right-hand table stopped being unique on user_id the LEFT JOINs would
# silently multiply rows instead of failing.
src <- dbGetQuery(con, sprintf("
  SELECT (SELECT count(*) FROM %s.%s) AS n_country,
         (SELECT count(*) FROM %s.%s) AS n_name,
         (SELECT count(*) FROM %s.%s) AS n_flag_rows,
         (SELECT count(DISTINCT user_id) FROM %s.%s) AS n_flag_users",
  athena_schema, country_table, athena_schema, name_table,
  athena_schema, flag_table, athena_schema, flag_table))
cat("country cohort rows           :", format(src$n_country, big.mark = ","), "\n")
cat("name cohort rows              :", format(src$n_name, big.mark = ","), "\n")
cat("name-flag rows                :", format(src$n_flag_rows, big.mark = ","), "\n")
cat("  distinct user_id            :", format(src$n_flag_users, big.mark = ","), "\n")
if (src$n_country == 0 || src$n_name == 0) {
  stop("A source cohort table is empty. Rebuild it before consolidating.")
}
if (src$n_flag_users != src$n_flag_rows) {
  stop("Table ", athena_schema, ".", flag_table, " is not unique on user_id: ",
       "the LEFT JOIN would multiply rows.")
}

####################################################################
### Step 4: run the UNLOAD and register the table
####################################################################

cat("\nRunning UNLOAD...\n")
t0 <- Sys.time()
dbExecute(con, unload_sql)
cat("  finished in",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n\n")

cat(ddl_txt, "\n")
dbExecute(con, ddl_txt)

####################################################################
### Step 5: validation through Athena
####################################################################

cat("\n=========== VALIDATION ===========\n")
v <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_rows,
         count(DISTINCT user_id) AS n_users,
         sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS uid_null,
         sum(CASE WHEN in_country_cohort = 1 AND in_name_cohort = 0 THEN 1 ELSE 0 END) AS country_only,
         sum(CASE WHEN in_country_cohort = 1 AND in_name_cohort = 1 THEN 1 ELSE 0 END) AS both,
         sum(CASE WHEN in_country_cohort = 0 AND in_name_cohort = 1 THEN 1 ELSE 0 END) AS name_only,
         sum(CASE WHEN in_country_cohort = 0 AND in_name_cohort = 0 THEN 1 ELSE 0 END) AS orphan,
         sum(CASE WHEN br_name != in_name_cohort THEN 1 ELSE 0 END) AS bad_brname,
         sum(CASE WHEN min_bach_year_strict < min_bach_year THEN 1 ELSE 0 END) AS bad_strict,
         min(min_pos_year)  AS pos_year_min,  max(min_pos_year)  AS pos_year_max,
         min(min_bach_year) AS bach_year_min, max(min_bach_year) AS bach_year_max,
         sum(CASE WHEN br_position = 1 OR br_educ_country = 1
                    OR br_openalex_norm = 1
                  THEN 0 ELSE 1 END) AS n_name_only_evidence,
         sum(br_openalex_norm) AS n_br_openalex_norm,
         sum(CASE WHEN br_openalex_norm = 1 AND br_position = 0
                   AND br_educ_country = 0 AND br_openalex = 0
                  THEN 1 ELSE 0 END) AS n_norm_only,
         sum(CASE WHEN p_brazil IS NULL THEN 1 ELSE 0 END) AS p_null
  FROM %s.%s", athena_schema, athena_table))
print(v)

if (v$n_users != v$n_rows) stop("Duplicate user_id in the consolidated table.")
if (v$uid_null != 0) stop("NULL user_id in the consolidated table.")
if (v$orphan != 0) {
  stop(v$orphan, " rows belong to neither source cohort -- impossible by construction.")
}
# br_name is recomputed from a fresh p_brazil lookup while in_name_cohort
# comes from membership. They are derived independently, so requiring
# agreement on every row is a genuine check of both the backfill and the
# union rather than a restatement of one of them.
if (v$bad_brname != 0) {
  stop(v$bad_brname, " rows where br_name != in_name_cohort.")
}
if (v$bad_strict != 0) {
  stop(v$bad_strict, " rows have min_bach_year_strict < min_bach_year.")
}
if (v$pos_year_min < min_year) {
  stop("min_pos_year ", v$pos_year_min, " is below the cutoff of ", min_year)
}
if (v$bach_year_min < min_year) {
  stop("min_bach_year ", v$bach_year_min, " is below the cutoff of ", min_year)
}
if (!is.na(exp_rows) && v$n_rows != exp_rows) {
  stop("Expected ", exp_rows, " rows, got ", v$n_rows,
       " -- a source table changed underneath this script.")
}
if (!is.na(exp_country_only) && !is.na(exp_both) && !is.na(exp_name_only) &&
    (v$country_only != exp_country_only || v$both != exp_both ||
     v$name_only != exp_name_only)) {
  stop("Provenance split changed: got ", v$country_only, "/", v$both, "/",
       v$name_only, ", expected ", exp_country_only, "/", exp_both, "/",
       exp_name_only)
}
# Holds regardless of whether the constants above are pinned: the
# country cohort only gained members, and a union cannot shrink.
if (!is.na(min_rows) && v$n_rows < min_rows) {
  stop("Consolidated table has ", v$n_rows, " rows, fewer than the ",
       "pre-C_norm ", min_rows, ". A union of a grown cohort cannot shrink.")
}
if (is.na(exp_rows)) {
  cat("\n[!] exp_rows is NA -- the deterministic check is DISABLED.\n",
      "    Fill in the measured values above before relying on this table.\n",
      sep = "")
}

cat("\ncandidates                    :", format(v$n_rows, big.mark = ","), "\n")
cat("  country cohort only         :", format(v$country_only, big.mark = ","), "\n")
cat("  in both                     :", format(v$both, big.mark = ","), "\n")
cat("  name cohort only            :", format(v$name_only, big.mark = ","), "\n")
cat("\n  no observed Brazil signal (name prior only):",
    format(v$n_name_only_evidence, big.mark = ","),
    sprintf("(%.1f%%)\n", 100 * as.numeric(v$n_name_only_evidence) /
                          as.numeric(v$n_rows)))
cat("  p_brazil NULL (absent from the name crosswalk):",
    format(v$p_null, big.mark = ","), "\n")

print(dbGetQuery(con, sprintf("SELECT * FROM %s.%s LIMIT 10",
                              athena_schema, athena_table)))
cat("[OK] all validations passed\n\n")

####################################################################
### Step 6: bring the result back to Dropbox
####################################################################

# arrow reads the whole prefix: UNLOAD writes several files.
cat("=========== LOCAL COPY ===========\n")
if (!arrow::arrow_with_s3()) {
  stop("This arrow build has no S3 support. Download the files from ",
       s3_path, " with the AWS CLI and read them from disk, or reinstall ",
       "arrow with S3 enabled.")
}
ds <- arrow::open_dataset(s3_path, format = "parquet")
# write_parquet does not take a Dataset: materialize a Table first.
# Eleven narrow columns, so it fits in memory at this row count.
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
cat("  candidates    :", format(v$n_rows, big.mark = ","), "\n")
cat("  sources       :", country_table, "+", name_table, "\n")
