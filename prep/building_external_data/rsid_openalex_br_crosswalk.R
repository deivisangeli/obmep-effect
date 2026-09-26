####################################################################
###
### Revelio rsid <-> OpenAlex Brazilian institutions crosswalk
###                                          -> S3 + Athena
###
### Builds a crosswalk between Revelio's normalized school key
### (academic_individual_user_education.rsid) and the Brazilian
### institutions list in revelio_database.openalex_institutions_br.
###
### The match is EXACTLY the one criterion C already uses in
### revelio_br_cohort_user_ids.R:
###
###   lower(university_raw) = lower(cleaned_display_name)
###
### What is new is that the matched pair is published together with the
### rsid it belongs to. Since rsid is Revelio's own normalization of the
### school, every education row sharing a matched rsid is the same
### institution -- including the rows whose free-text university_raw was
### typed differently ("USP", "Universidade de Sao Paulo - USP", ...)
### and therefore never matched the string comparison.
###
### Columns published, one row per (rsid, university_raw, openalex_id):
###   rsid, university_raw, university_name,
###   openalex_id, openalex_display_name
### plus the OpenAlex extras and the per-rsid diagnostics described in
### note 4 below.
###
### Intended consumer: a widened Brazilian-education criterion
###
###   university_country = 'Brazil'
###   OR rsid IN (SELECT rsid FROM this table)          <- new
###   OR lower(university_raw) = lower(cleaned_display_name)
###
### That change to the cohort scripts is NOT made here: it needs all
### three cohort tables rebuilt and their exp_rows re-measured.
###
### Depends on:
###   prep/building_external_data/openalex_institutions_br_to_s3.R
###   (table revelio_database.openalex_institutions_br)
###
### Athena read/UNLOAD pattern reused from:
###   prep/building_external_data/revelio_br_cohort_user_ids.R
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. That is a deliberate exception: reading from Athena
###    and writing to S3 is the whole point. It is a local prep/ script
###    and must not be sent to the offline SEDAP environment.
### 2. ALL 1,947 OpenAlex rows are eligible, not only type =
###    'education'. That keeps this a strict SUPERSET of the current
###    criterion C -- nothing that matches today stops matching -- and
###    it keeps "Estacio (Brazil)" (typed `company`, 7,237 works, with
###    no education record of its own) working. See the README section
###    "`type` is about ownership, not function". openalex_type travels
###    in the table so a type filter can be applied later with no
###    re-scan.
### 3. The match itself is UNCHANGED from criterion C: lower() on both
###    sides, accents and punctuation still significant, and
###    cleaned_display_name rather than display_name. The OpenAlex
###    scripts never fold accents and their assertions depend on that;
###    folding here would create a second, silently different
###    definition of the same criterion.
### 4. Propagating a match through rsid also propagates a BAD match to
###    every row sharing that rsid. Nothing is filtered on that account
###    -- it is MEASURED instead, and the measurements travel in the
###    table: rsid_n_rows, rsid_n_rows_br, rsid_n_raw,
###    rsid_top_country(_n) and rsid_n_countries. So a suspect rsid is
###    visible, and the cut can be tightened in Athena without
###    rebuilding anything. Same reasoning as the stored-but-not-
###    filtering flags in the cohort tables.
###
###    *** NEVER CONSUME BARE rsid MEMBERSHIP. *** Measured on the
###    first run: the 725 matched rsids cover 62,348,045 education
###    rows, of which only 10,034,240 have university_country =
###    'Brazil'. ONE row is enough to poison an rsid -- someone whose
###    rsid is Harvard typed "Universidade Federal do Rio de Janeiro",
###    1 row out of 562,968, and that admits all of Harvard. The same
###    single-row mechanism drags in University of Phoenix, Delhi (via
###    "Microsoft" matching the OpenAlex record "Microsoft (Brazil)"),
###    Buenos Aires, Toronto, UNAM, Stanford and Cambridge.
###
###    The separating statistic is the share of the rsid's own rows
###    whose raw string matched, which any consumer can compute from
###    the published columns:
###
###      match_share = sum(n_rows) over the rsid's rows / rsid_n_rows
###
###    | rule                | rsids | education rows |
###    |---------------------|-------|----------------|
###    | any matched rsid    |   725 |     62,348,045 |
###    | match_share >= 0.5  |   234 |     12,343,509 |
###    | string match alone  |     - |     11,209,101 |
###
###    At >= 0.5 the mapping is right where it matters -- Estacio ->
###    Estacio, USP -> USP, UNICAMP -> UNICAMP, UFRJ -> UFRJ -- and it
###    still adds ~1.1M education rows over the string match. Step 5
###    prints the full band table on every run.
###
###    DO NOT filter on the Brazil share instead. rsid_n_rows_br /
###    rsid_n_rows is near zero for institutions that are beyond doubt
###    Brazilian: Fundacao Getulio Vargas 0.0011, UFRGS 0.0006, Centro
###    Universitario Una 0.0003. Those rows carry a NULL or non-Brazil
###    university_country, which is exactly the gap criterion C exists
###    to close -- filtering on it would discard the rows this whole
###    step is meant to recover.
### 5. The grain is (rsid, university_raw, openalex_id) and it is
###    asserted unique. A fan-out on openalex_id is EXPECTED and is not
###    an error: OpenAlex ships 4 pre-existing duplicate-name groups
###    (distinct ids sharing a name, e.g. "Hospital de Base" in
###    Brasilia and in Sao Jose do Rio Preto), and lower() collapses a
###    few more. Do NOT dedupe by keeping the largest works_count --
###    that would silently pick a city.
### 6. university_name and ultimate_parent_* are aggregated with
###    max()/min() per pair. rsid_name_constant / rsid_parent_constant
###    report whether they are actually constant within the rsid, which
###    is the thing that would have to be true for max() to be
###    meaningful. They are FLAGS, not assertions: a non-constant rsid
###    is reported, not fatal, because the crosswalk key is rsid and
###    the name is only an attribute.
### 7. ultimate_parent_rsid is carried but NOT used. Revelio also
###    resolves campuses to a parent school, so a second, wider
###    propagation (rsid -> ultimate_parent_rsid -> all children) is
###    available for free later. It is deliberately not applied here:
###    it would admit every campus of a matched parent, which is a
###    different criterion and needs its own measurement.
### 8. rsid is `int` in Revelio, verified with DESCRIBE (not bigint --
###    see trap 5 in the README: a type mismatch between the parquet
###    and the DDL only surfaces on read, never on write). count() and
###    sum() return bigint in Trino, hence the BIGINT columns.
### 9. Cost: one aggregate pass over academic_individual_user_education
###    reading 6 columns. MEASURED AT 58.50 GB (~$0.29), 15.6 s of
###    execution -- four times the README's "~16 GB for a full-column
###    diagnostic" reference, which was a filtered query and is not a
###    valid guide for a full GROUP BY. Paid once: the cohort scripts
###    then join this 5,446-row table instead of re-deriving it.
###    Everything in Step 5 reads the finished table, not the source,
###    so re-reporting is free.
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
out_path <- file.path(out_dir, "rsid_openalex_br.parquet")

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
s3_prefix <- "exports/rsid_openalex_br"
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table  <- "rsid_openalex_br"

# Institutions table registered by openalex_institutions_br_to_s3.R.
inst_table <- "openalex_institutions_br"
educ_table <- "academic_individual_user_education"

# Measured 2026-08-24 on the first run. A Revelio refresh or a new
# OpenAlex snapshot legitimately moves these, so a mismatch warns
# rather than aborts. NA disables the check.
exp_rows  <- 5446
exp_rsids <- 725

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
# scratchpad/validate_sql_syntax.R), whereas UNLOAD and DDL cannot.
#
# Notes on the shape of the query:
#
#  - `base` is the ONLY pass over the education table. Everything else
#    aggregates its output. Grouping by university_country there costs
#    nothing extra and is what makes the per-rsid country profile
#    available without a second scan.
#  - the join to the institutions table is an INNER JOIN against the
#    TABLE, not the LEFT JOIN against SELECT DISTINCT lower(...) used
#    by the cohort scripts. They avoid the table to keep the join 1:1;
#    here openalex_id IS the payload, so the fan-out has to be handled
#    (note 5) rather than dodged.
#  - rsid_stats aggregates `pairs`, i.e. ALL rows of a matched rsid,
#    including the rows whose university_raw did NOT match. Those are
#    precisely the rows the widened criterion would newly admit, so
#    they have to be inside the denominator.
#  - min()/max() over a column, compared with IS NOT DISTINCT FROM,
#    tests constancy far more cheaply than count(DISTINCT ...). Both
#    ignore NULLs, so "constant" here means constant among the non-null
#    values.
#  - max_by(university_country, n_c) is the modal country of the rsid.
#    Rows with a NULL country are excluded from that computation and
#    the join back is a LEFT JOIN, so an rsid whose country is always
#    NULL keeps its other statistics instead of vanishing.
#  - rsid IS NOT NULL is explicit. Trino equality never matches NULL so
#    a NULL rsid could not join downstream anyway, but a NULL in a
#    published key list is a trap for anyone writing IN (SELECT rsid).
select_sql <- sprintf("
WITH base AS (
  SELECT rsid,
         university_raw,
         university_country,
         max(university_name)             AS uni_name_max,
         min(university_name)             AS uni_name_min,
         max(ultimate_parent_rsid)        AS up_rsid_max,
         min(ultimate_parent_rsid)        AS up_rsid_min,
         max(ultimate_parent_school_name) AS up_name_max,
         count(*)                         AS n
  FROM %s
  WHERE rsid IS NOT NULL AND university_raw IS NOT NULL
  GROUP BY rsid, university_raw, university_country
),
pairs AS (
  SELECT rsid,
         university_raw,
         max(uni_name_max) AS university_name,
         min(uni_name_min) AS uni_name_min,
         max(up_rsid_max)  AS ultimate_parent_rsid,
         min(up_rsid_min)  AS up_rsid_min,
         max(up_name_max)  AS ultimate_parent_school_name,
         sum(n)            AS n_rows,
         sum(CASE WHEN university_country = 'Brazil' THEN n ELSE 0 END) AS n_rows_br
  FROM base
  GROUP BY rsid, university_raw
),
rsid_stats AS (
  SELECT rsid,
         sum(n_rows)               AS rsid_n_rows,
         sum(n_rows_br)            AS rsid_n_rows_br,
         count(*)                  AS rsid_n_raw,
         max(university_name)      AS uni_name_max,
         min(uni_name_min)         AS uni_name_min,
         max(ultimate_parent_rsid) AS up_rsid_max,
         min(up_rsid_min)          AS up_rsid_min
  FROM pairs
  GROUP BY rsid
),
rsid_country AS (
  SELECT rsid,
         max_by(university_country, n_c) AS rsid_top_country,
         max(n_c)                        AS rsid_top_country_n,
         count(*)                        AS rsid_n_countries
  FROM (
    SELECT rsid, university_country, sum(n) AS n_c
    FROM base
    WHERE university_country IS NOT NULL
    GROUP BY rsid, university_country
  ) c
  GROUP BY rsid
)
SELECT p.rsid,
       p.university_raw,
       p.university_name,
       oa.openalex_id,
       oa.display_name         AS openalex_display_name,
       oa.cleaned_display_name AS openalex_cleaned_display_name,
       oa.type                 AS openalex_type,
       oa.works_count          AS openalex_works_count,
       p.ultimate_parent_rsid,
       p.ultimate_parent_school_name,
       p.n_rows,
       p.n_rows_br,
       s.rsid_n_rows,
       s.rsid_n_rows_br,
       s.rsid_n_raw,
       c.rsid_top_country,
       c.rsid_top_country_n,
       c.rsid_n_countries,
       CASE WHEN s.uni_name_min IS NOT DISTINCT FROM s.uni_name_max
            THEN 1 ELSE 0 END AS rsid_name_constant,
       CASE WHEN s.up_rsid_min IS NOT DISTINCT FROM s.up_rsid_max
            THEN 1 ELSE 0 END AS rsid_parent_constant
FROM pairs p
INNER JOIN %s oa
  ON lower(p.university_raw) = lower(oa.cleaned_display_name)
INNER JOIN rsid_stats s
  ON p.rsid = s.rsid
LEFT JOIN rsid_country c
  ON p.rsid = c.rsid",
  educ_table, inst_table)

unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')",
  select_sql, s3_path)

# STRING (not VARCHAR) and in the exact SELECT order: Hive DDL, and the
# Athena Parquet SerDe resolves columns by POSITION and TYPE. rsid is
# int in Revelio; count() and sum() are bigint in Trino.
ddl_txt <- sprintf(
"CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (
  rsid INT,
  university_raw STRING,
  university_name STRING,
  openalex_id STRING,
  openalex_display_name STRING,
  openalex_cleaned_display_name STRING,
  openalex_type STRING,
  openalex_works_count BIGINT,
  ultimate_parent_rsid INT,
  ultimate_parent_school_name STRING,
  n_rows BIGINT,
  n_rows_br BIGINT,
  rsid_n_rows BIGINT,
  rsid_n_rows_br BIGINT,
  rsid_n_raw BIGINT,
  rsid_top_country STRING,
  rsid_top_country_n BIGINT,
  rsid_n_countries BIGINT,
  rsid_name_constant INT,
  rsid_parent_constant INT
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
# with a clear message, beats spending the scan of the education table
# only for Athena to refuse the write afterwards.
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

# Without the institutions table the join returns nothing and the
# crosswalk comes out empty with no warning.
inst <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n,
         count(DISTINCT lower(cleaned_display_name)) AS n_clean_lower
  FROM %s.%s", athena_schema, inst_table))
cat("BR institutions available     :", format(inst$n, big.mark = ","), "\n")
cat("  distinct lower(cleaned)     :", format(inst$n_clean_lower, big.mark = ","), "\n")
if (inst$n == 0) {
  stop("Table ", athena_schema, ".", inst_table, " is empty. ",
       "Run openalex_institutions_br_to_s3.R first.")
}

cat("\nRunning UNLOAD (aggregates the education table)...\n")
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
         count(DISTINCT rsid) AS n_rsids,
         count(DISTINCT openalex_id) AS n_oa,
         count(DISTINCT (rsid, university_raw, openalex_id)) AS n_grain,
         sum(CASE WHEN rsid IS NULL OR university_raw IS NULL
                    OR openalex_id IS NULL THEN 1 ELSE 0 END) AS n_key_null,
         sum(CASE WHEN n_rows_br > n_rows THEN 1 ELSE 0 END) AS bad_pair,
         sum(CASE WHEN rsid_n_rows_br > rsid_n_rows THEN 1 ELSE 0 END) AS bad_rsid,
         sum(CASE WHEN n_rows > rsid_n_rows THEN 1 ELSE 0 END) AS bad_nest,
         sum(CASE WHEN rsid_top_country_n > rsid_n_rows THEN 1 ELSE 0 END) AS bad_country,
         sum(CASE WHEN rsid_name_constant = 0 THEN 1 ELSE 0 END) AS n_name_varies,
         sum(CASE WHEN rsid_parent_constant = 0 THEN 1 ELSE 0 END) AS n_parent_varies
  FROM %s.%s", athena_schema, athena_table))
print(v)

if (v$n_rows == 0) {
  stop("The crosswalk is empty -- the criterion would be dead on arrival.")
}
if (v$n_grain != v$n_rows) {
  stop("Grain violated: ", v$n_rows, " rows but ", v$n_grain,
       " distinct (rsid, university_raw, openalex_id).")
}
if (v$n_key_null != 0) stop("NULL in a key column of the crosswalk.")
# The two aggregation levels are computed separately; if the Brazilian
# subset ever exceeded the total, or a pair exceeded its own rsid, the
# CTEs would be aggregating different things.
if (v$bad_pair != 0 || v$bad_rsid != 0 || v$bad_nest != 0) {
  stop("Aggregation levels disagree: ", v$bad_pair, " pairs with ",
       "n_rows_br > n_rows, ", v$bad_rsid, " with rsid_n_rows_br > ",
       "rsid_n_rows, ", v$bad_nest, " with n_rows > rsid_n_rows.")
}
if (v$bad_country != 0) {
  stop(v$bad_country, " rows where the modal country covers more rows ",
       "than the rsid has.")
}

# Every openalex_id must exist in the institutions table. If the Parquet
# SerDe had resolved columns at the wrong position this is what breaks.
orph <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n
  FROM (SELECT DISTINCT openalex_id FROM %s.%s) x
  LEFT JOIN %s.%s oa ON x.openalex_id = oa.openalex_id
  WHERE oa.openalex_id IS NULL", athena_schema, athena_table,
  athena_schema, inst_table))
if (orph$n != 0) {
  stop(orph$n, " openalex_id values are absent from ", inst_table,
       " -- columns out of position?")
}

# The widened criterion must be a SUPERSET of the old one: every pair
# here satisfies the old string match by construction, so checking it
# against the stored strings verifies the join did what it claims.
sup <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM %s.%s
  WHERE lower(university_raw) <> lower(openalex_cleaned_display_name)",
  athena_schema, athena_table))
if (sup$n != 0) {
  stop(sup$n, " rows where lower(university_raw) does not equal ",
       "lower(openalex_cleaned_display_name) -- the join is not the ",
       "criterion it claims to be.")
}

if (!is.na(exp_rows) && v$n_rows != exp_rows) {
  warning("Expected ", exp_rows, " rows, got ", v$n_rows)
}
if (!is.na(exp_rsids) && v$n_rsids != exp_rsids) {
  warning("Expected ", exp_rsids, " rsids, got ", v$n_rsids)
}

cat("\nrows in the crosswalk         :", format(v$n_rows, big.mark = ","), "\n")
cat("  distinct rsid               :", format(v$n_rsids, big.mark = ","), "\n")
cat("  distinct openalex_id        :", format(v$n_oa, big.mark = ","), "\n")
cat("  rsids whose university_name varies:",
    format(v$n_name_varies, big.mark = ","), "\n")
cat("  rsids whose ultimate_parent varies:",
    format(v$n_parent_varies, big.mark = ","), "\n")
cat("[OK] all validations passed\n\n")

####################################################################
### Step 5: reports -- this is how the crosswalk gets judged
####################################################################

# 1. Coverage: education rows the rsid propagation reaches, against the
#    rows the string match alone reaches. The DIFFERENCE is the whole
#    point of this step; if it is small, the widening is not worth the
#    cohort rebuild it costs.
cat("=========== COVERAGE ===========\n")
cov <- dbGetQuery(con, sprintf("
  SELECT sum(rsid_n_rows)    AS rows_by_rsid,
         sum(rsid_n_rows_br) AS rows_by_rsid_br,
         sum(matched_rows)   AS rows_by_string
  FROM (
    SELECT rsid,
           max(rsid_n_rows)    AS rsid_n_rows,
           max(rsid_n_rows_br) AS rsid_n_rows_br,
           sum(matched_rows)   AS matched_rows
    FROM (
      SELECT rsid, university_raw,
             max(rsid_n_rows)    AS rsid_n_rows,
             max(rsid_n_rows_br) AS rsid_n_rows_br,
             max(n_rows)         AS matched_rows
      FROM %s.%s
      GROUP BY rsid, university_raw
    ) p
    GROUP BY rsid
  ) r", athena_schema, athena_table))
print(cov)
cat("education rows reached by the string match :",
    format(cov$rows_by_string, big.mark = ","), "\n")
cat("education rows reached through rsid        :",
    format(cov$rows_by_rsid, big.mark = ","), "\n")
cat("  of which university_country = 'Brazil'   :",
    format(cov$rows_by_rsid_br, big.mark = ","), "\n")
cat("NEWLY reachable (rsid but not the string)  :",
    format(cov$rows_by_rsid - cov$rows_by_string, big.mark = ","),
    sprintf("(%.2fx)\n",
            as.numeric(cov$rows_by_rsid) / as.numeric(cov$rows_by_string)))

# 2. match_share -- THE statistic a consumer of this table has to
#    compute (note 4). It is the share of an rsid's education rows
#    whose own university_raw matched, and it is what separates a real
#    institution match from an rsid poisoned by a single stray row.
#    Not a stored column, deliberately: it is a pure function of the
#    published ones, and computing it here over 5,446 rows is free.
#
#    `dominant` is the openalex_id that the largest number of an
#    rsid's matched rows point at. Reporting max(openalex_display_name)
#    instead -- alphabetically last -- reads as if USP mapped to
#    Universidade do Vale do Paraiba. It does not; that is a reporting
#    artefact of aggregating a table whose grain is finer than rsid.
share_sql <- sprintf("
  WITH p AS (
    SELECT DISTINCT rsid, university_raw, university_name, openalex_id,
           openalex_display_name, openalex_type, n_rows,
           rsid_n_rows, rsid_n_rows_br, rsid_top_country, rsid_n_raw
    FROM %s.%s
  ),
  dom AS (
    SELECT rsid, openalex_id, openalex_display_name, openalex_type,
           sum(n_rows) AS oa_rows,
           row_number() OVER (PARTITION BY rsid ORDER BY sum(n_rows) DESC,
                              openalex_id) AS rk
    FROM p GROUP BY rsid, openalex_id, openalex_display_name, openalex_type
  ),
  r AS (
    SELECT rsid,
           max(university_name)  AS university_name,
           max(rsid_n_rows)      AS rsid_n_rows,
           max(rsid_n_rows_br)   AS rsid_n_rows_br,
           max(rsid_top_country) AS rsid_top_country,
           max(rsid_n_raw)       AS rsid_n_raw,
           sum(n_rows)           AS matched_rows
    FROM p GROUP BY rsid
  )
  SELECT r.rsid, r.university_name,
         d.openalex_display_name AS dominant, d.openalex_type,
         r.matched_rows, r.rsid_n_rows, r.rsid_n_rows_br, r.rsid_n_raw,
         r.rsid_top_country,
         CAST(r.matched_rows  AS double) / r.rsid_n_rows AS match_share,
         CAST(r.rsid_n_rows_br AS double) / r.rsid_n_rows AS br_share
  FROM r JOIN dom d ON r.rsid = d.rsid AND d.rk = 1",
  athena_schema, athena_table)

cat("\n=========== match_share BANDS ===========\n")
bands <- dbGetQuery(con, sprintf("
  SELECT CASE WHEN match_share >= 0.5   THEN 'a  >= 0.5'
              WHEN match_share >= 0.1   THEN 'b  0.1 - 0.5'
              WHEN match_share >= 0.01  THEN 'c  0.01 - 0.1'
              WHEN match_share >= 0.001 THEN 'd  0.001 - 0.01'
              ELSE 'e  < 0.001' END AS band,
         count(*)            AS n_rsid,
         sum(rsid_n_rows)    AS rows_reached,
         sum(rsid_n_rows_br) AS rows_br
  FROM (%s) s GROUP BY 1 ORDER BY 1", share_sql))
print(bands, right = FALSE)
cat("\nA bare `rsid IN (SELECT rsid FROM this table)` reaches every row",
    "above.\nSee note 4: the bottom band is Harvard, Phoenix, Delhi and",
    "friends,\nadmitted by one stray education row each.\n")

# 3. Contamination candidates: high row count, low match_share. These
#    are the rsids a bare membership test would wrongly admit, and they
#    are the rows to read by hand. Nothing is dropped -- see note 4.
cat("\n=========== CONTAMINATION CANDIDATES (match_share < 0.01) ===========\n")
cont <- dbGetQuery(con, sprintf("
  SELECT rsid, university_name, dominant, openalex_type,
         matched_rows, rsid_n_rows, rsid_n_rows_br,
         match_share, br_share, rsid_top_country
  FROM (%s) s
  WHERE match_share < 0.01
  ORDER BY rsid_n_rows DESC
  LIMIT 40", share_sql))
print(cont, right = FALSE)
cat("\ncontamination candidates listed:", nrow(cont), "(capped at 40)\n")

# 4. Plausibility: among the rsids that pass match_share, the biggest
#    should be the obvious Brazilian universities, each mapped to
#    itself.
cat("\n=========== TOP 25 rsid WITH match_share >= 0.5 ===========\n")
top <- dbGetQuery(con, sprintf("
  SELECT rsid, university_name, dominant, openalex_type,
         matched_rows, rsid_n_rows, rsid_n_rows_br, rsid_n_raw,
         match_share, br_share, rsid_top_country
  FROM (%s) s
  WHERE match_share >= 0.5
  ORDER BY rsid_n_rows DESC
  LIMIT 25", share_sql))
print(top, right = FALSE)
cat("\nNote the br_share column: Fundacao Getulio Vargas, UFRGS and",
    "Centro Universitario Una\nsit near zero on it while being",
    "unmistakably Brazilian. That is why the Brazil share\nis NOT a",
    "usable filter -- see note 4.\n")

# 4. rsids matching more than one OpenAlex institution. Expected on the
#    duplicate-name groups (note 5); anything else is worth reading.
cat("\n=========== rsid MATCHING >1 openalex_id ===========\n")
multi <- dbGetQuery(con, sprintf("
  SELECT rsid, university_name, n_oa, ids, names
  FROM (
    SELECT rsid,
           max(university_name) AS university_name,
           count(DISTINCT openalex_id) AS n_oa,
           array_join(array_sort(array_agg(DISTINCT openalex_id)), ', ') AS ids,
           array_join(array_sort(array_agg(DISTINCT openalex_display_name)), ' | ') AS names
    FROM %s.%s GROUP BY rsid
  ) r
  WHERE n_oa > 1
  ORDER BY n_oa DESC, rsid
  LIMIT 50", athena_schema, athena_table))
print(multi, right = FALSE)
cat("\nrsids matching more than one institution:", nrow(multi),
    "(capped at 50)\n")

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
# write_parquet does not take a Dataset: materialize a Table first.
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
cat("  distinct rsid :", format(v$n_rsids, big.mark = ","), "\n")
cat("  match rule    : lower(university_raw) = lower(cleaned_display_name)\n")
