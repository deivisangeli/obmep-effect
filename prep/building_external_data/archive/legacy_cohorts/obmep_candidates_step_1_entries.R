####################################################################
###
### Full position and education histories for the candidate pool
###                                          -> S3 + Athena + Dropbox
###
### obmep_candidates_step_1 holds 6,849,674 user_ids but only the
### flags and dates that admitted them. This pulls the underlying
### records: EVERY position and EVERY education entry those people
### have, Brazilian or not.
###
### No new criterion and no filtering beyond cohort membership.
###
###   academic_individual_position        -> obmep_candidates_step_1_position
###   academic_individual_user_education  -> obmep_candidates_step_1_education
###
### Depends on:
###   prep/building_external_data/obmep_candidates_step_1.R
###   (table revelio_database.obmep_candidates_step_1)
###
### UNLOAD/DDL pattern reused from:
###   prep/building_external_data/revelio_br_cohort_user_ids.R
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. That is a deliberate exception: reading from Athena,
###    writing to S3 and downloading with the AWS CLI is the whole
###    point. It is a local prep/ script and must not be sent to the
###    offline SEDAP environment.
### 2. `naics` DOES NOT EXIST on academic_individual_position. The
###    column is `naics_code`; `naics_description` does exist. Verified
###    with DESCRIBE. All other 22 requested columns are present.
### 3. THE SEMI-JOIN IS FOR CORRECTNESS, NOT COST.
###    WHERE user_id IN (SELECT ...) cannot multiply rows even if the
###    cohort table ever stopped being unique on user_id; an inner
###    join could. But it saves NOTHING on the bill, and that is
###    measured, not assumed:
###      - a count query reading ONLY user_id from both source tables
###        scanned 12.83 GB -- essentially the full columns, nothing
###        pruned;
###      - a source file's footer shows user_id SCATTERED, one row
###        group spanning 2.18e9 of id range. With 6.85M cohort users
###        spread across that space every row group holds some, so no
###        row group can be skipped;
###      - SHOW CREATE TABLE confirms no partitioning, no bucketing,
###        no sort order to exploit.
###    Do not expect the 1.8% selectivity to show up anywhere.
### 4. COST IS SET BY COLUMNS. Measured from per-column compressed
###    sizes in the parquet footers:
###      position   685.0 GB source, the 12 columns are 64.9% = 444 GB
###      education   89.8 GB source, the 12 columns are 86.2% =  77 GB
###    ~521 GB, about $2.55, paid once. `description` alone is 47% of
###    that (226 + 22 GB). It is kept deliberately: a single column
###    cannot be scanned in isolation, so re-adding it later would
###    mean paying the whole 521 GB again.
### 5. THE LOCAL COPY IS A DOWNLOAD, NOT A RE-ENCODE, and it is NOT
###    the arrow pattern every other script here ends with.
###    arrow::Scanner$create(ds)$ToTable() materialises the whole
###    result in memory: fine at 6.8M rows x 11 narrow columns, not
###    fine at 30M rows carrying a free-text description. UNLOAD
###    already writes Snappy parquet, so `aws s3 sync` copies it as
###    is. The result is a DIRECTORY OF PARTS, not one file; read it
###    with arrow::open_dataset(dir).
### 6. Every cohort member MUST appear in both extracts. Criterion D
###    admits nobody without a position whose year parses and E nobody
###    without a bachelor education row, so count(DISTINCT user_id)
###    has to come back at exactly 6,849,674 in each. That invariant
###    is asserted below and is the strongest check in the run.
### 7. startdate/enddate are STRING on position and DATE on education
###    -- README trap 1. The two DDLs differ accordingly; do not
###    "harmonise" them.
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
out_root <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
athena_schema <- "revelio_database"

cand_table <- "obmep_candidates_step_1"

# Every cohort member appears in both extracts; see note 6.
exp_users <- 6849674

# The two extracts share every guard, every validation and the whole
# download path, so they are described as data and processed in a
# loop. Writing them out twice would duplicate ~200 lines and invite
# the two copies to drift.
extracts <- list(
  list(
    name       = "position",
    table      = "obmep_candidates_step_1_position",
    src        = "academic_individual_position",
    exp_rows   = 30389044,
    cols       = c("user_id", "position_id", "company_raw",
                   "company_linkedin_url", "company_cleaned", "title_raw",
                   "title_translated", "description", "naics_code",
                   "naics_description", "startdate", "enddate"),
    ddl_cols   = c("user_id BIGINT", "position_id BIGINT", "company_raw STRING",
                   "company_linkedin_url STRING", "company_cleaned STRING",
                   "title_raw STRING", "title_translated STRING",
                   "description STRING", "naics_code STRING",
                   "naics_description STRING", "startdate STRING",
                   "enddate STRING"),
    extra_sql  = "count(DISTINCT naics_code) AS n_naics,
                  count(DISTINCT company_cleaned) AS n_companies"
  ),
  list(
    name       = "education",
    table      = "obmep_candidates_step_1_education",
    src        = "academic_individual_user_education",
    exp_rows   = 15712737,
    cols       = c("user_id", "university_raw", "university_name", "rsid",
                   "degree_raw", "degree", "field_raw", "field",
                   "university_country", "description", "startdate", "enddate"),
    ddl_cols   = c("user_id BIGINT", "university_raw STRING",
                   "university_name STRING", "rsid INT", "degree_raw STRING",
                   "degree STRING", "field_raw STRING", "field STRING",
                   "university_country STRING", "description STRING",
                   "startdate DATE", "enddate DATE"),
    extra_sql  = "count(DISTINCT rsid) AS n_rsid,
                  count(DISTINCT university_country) AS n_countries"
  )
)

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

dir.create(out_root, recursive = TRUE, showWarnings = FALSE)

# The AWS CLI does the download (note 5). Failing here beats failing
# after ~$2.55 of scanning.
if (Sys.which("aws") == "") {
  stop("The AWS CLI is not on PATH. It is required for the local copy; ",
       "install it or run the `aws s3 sync` commands printed below by hand.")
}

####################################################################
### Step 1: build the queries
####################################################################

for (i in seq_along(extracts)) {
  e <- extracts[[i]]
  e$s3_prefix <- paste0("exports/", e$table)
  e$s3_path   <- paste0("s3://", s3_bucket, "/", e$s3_prefix, "/")
  e$local_dir <- file.path(out_root, e$table)

  # The SELECT lives in its own element so it can be validated on its
  # own (scratchpad/validate_sql_syntax.R), whereas UNLOAD and DDL
  # cannot.
  e$select_sql <- sprintf(
    "SELECT %s\nFROM %s\nWHERE user_id IN (SELECT user_id FROM %s.%s)",
    paste(e$cols, collapse = ",\n       "), e$src, athena_schema, cand_table)

  e$unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')", e$select_sql, e$s3_path)

  # STRING (not VARCHAR) and in the exact SELECT order: Hive DDL, and
  # the Athena Parquet SerDe resolves columns by POSITION and TYPE.
  e$ddl_txt <- sprintf(
    "CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (\n  %s\n)\nSTORED AS PARQUET\nLOCATION '%s'",
    athena_schema, e$table, paste(e$ddl_cols, collapse = ",\n  "), e$s3_path)

  extracts[[i]] <- e
}

cat("=========== GENERATED SQL ===========\n")
for (e in extracts) {
  cat(e$unload_sql, "\n\n", e$ddl_txt, "\n\n", sep = "")
}

####################################################################
### Step 2: both destination prefixes must be empty
####################################################################

# UNLOAD refuses a non-empty prefix. Check BOTH before running either,
# so a dirty second prefix cannot surface after the first extract has
# already been paid for.
cat("=========== CURRENT CONTENTS OF THE S3 PREFIXES ===========\n")
for (e in extracts) {
  existing <- tryCatch(
    get_bucket(bucket = s3_bucket, prefix = paste0(e$s3_prefix, "/"),
               region = s3_region, max = 100),
    error = function(e2) { cat("  [listing error]:", conditionMessage(e2), "\n"); NULL })
  if (is.null(existing) || length(existing) == 0) {
    cat("  ", e$s3_path, " empty\n", sep = "")
  } else {
    for (o in existing) cat("   ", o$Key, "(", o$Size, "bytes )\n")
    stop("Prefix ", e$s3_path, " is not empty. Athena UNLOAD requires an ",
         "empty destination: delete the objects above (and the table ",
         athena_schema, ".", e$table, ", if it exists) before regenerating.")
  }
}
cat("\n")

####################################################################
### Step 3: check the cohort table, then run both extracts
####################################################################

cat("=========== ATHENA ===========\n")
con <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name    = s3_region,
                 schema_name    = athena_schema)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

# Without the cohort the semi-join matches nothing and both extracts
# come out empty after a full scan has been paid for.
cn <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n, count(DISTINCT user_id) AS n_users
  FROM %s.%s", athena_schema, cand_table))
cat("cohort rows                   :", format(cn$n, big.mark = ","), "\n")
if (cn$n == 0) {
  stop("Table ", athena_schema, ".", cand_table, " is empty. ",
       "Run obmep_candidates_step_1.R first.")
}
if (cn$n != cn$n_users) stop("Cohort table is not unique on user_id.")
if (cn$n != exp_users) {
  warning("Cohort has ", cn$n, " rows, expected ", exp_users,
          " -- exp_users below and the invariant in note 6 are stale.")
}

for (i in seq_along(extracts)) {
  e <- extracts[[i]]
  cat("\n--- ", e$name, ": UNLOAD (scans the whole source table) ---\n", sep = "")
  t0 <- Sys.time()
  dbExecute(con, e$unload_sql)
  cat("  finished in",
      round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
  dbExecute(con, e$ddl_txt)
  cat("  registered ", athena_schema, ".", e$table, "\n", sep = "")
}

####################################################################
### Step 4: validation through Athena
####################################################################

cat("\n=========== VALIDATION ===========\n")
for (i in seq_along(extracts)) {
  e <- extracts[[i]]
  v <- dbGetQuery(con, sprintf("
    SELECT count(*) AS n_rows,
           count(DISTINCT user_id) AS n_users,
           sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS uid_null,
           count(description) AS n_desc,
           min(startdate) AS sd_min, max(startdate) AS sd_max,
           %s
    FROM %s.%s", e$extra_sql, athena_schema, e$table))
  print(v)

  n_rows  <- as.numeric(v$n_rows)
  n_users <- as.numeric(v$n_users)

  if (n_rows == 0) stop(e$name, ": the extract is empty.")
  if (v$uid_null != 0) stop(e$name, ": NULL user_id in the extract.")

  # The invariant, note 6. Every cohort member has at least one
  # position (criterion D) and at least one education row (E), so a
  # short count means the filter dropped members rather than that the
  # data is thin.
  if (n_users != exp_users) {
    stop(e$name, ": ", format(n_users, big.mark = ","),
         " distinct users, expected ", format(exp_users, big.mark = ","),
         ". Every cohort member must appear in both extracts.")
  }

  # Nothing from outside the cohort. If the semi-join had bound to the
  # wrong column this is what would catch it.
  orph <- dbGetQuery(con, sprintf("
    SELECT count(*) AS n
    FROM (SELECT DISTINCT user_id FROM %s.%s) x
    LEFT JOIN %s.%s s ON x.user_id = s.user_id
    WHERE s.user_id IS NULL",
    athena_schema, e$table, athena_schema, cand_table))
  if (orph$n != 0) {
    stop(e$name, ": ", orph$n, " user_ids are not in the cohort.")
  }

  # A Revelio refresh legitimately moves the row count, so this warns
  # rather than aborting -- unlike the invariant above.
  if (!is.na(e$exp_rows) && n_rows != e$exp_rows) {
    warning(e$name, ": expected ", e$exp_rows, " rows, got ", n_rows)
  }

  cat("\n", e$name, "\n", sep = "")
  cat("  rows                        :", format(n_rows, big.mark = ","), "\n")
  cat("  distinct users              :", format(n_users, big.mark = ","), "\n")
  cat(sprintf("  rows per member             : %.2f\n", n_rows / n_users))
  cat(sprintf("  description filled          : %s (%.1f%%)\n",
              format(as.numeric(v$n_desc), big.mark = ","),
              100 * as.numeric(v$n_desc) / n_rows))
  cat("  startdate range             :", format(v$sd_min), "..",
      format(v$sd_max), "\n")

  extracts[[i]]$n_rows <- n_rows
}
cat("\n[OK] all validations passed\n\n")

####################################################################
### Step 5: bring the result down to Dropbox
####################################################################

# aws s3 sync, NOT arrow -- see note 5. This copies the parquet parts
# as they are; the local artifact is a DIRECTORY, and arrow reads a
# directory of parts as one dataset.
cat("=========== LOCAL COPY ===========\n")
for (i in seq_along(extracts)) {
  e <- extracts[[i]]
  dir.create(e$local_dir, recursive = TRUE, showWarnings = FALSE)
  cat("\n", e$name, ": syncing to ", e$local_dir, "\n", sep = "")
  t0 <- Sys.time()
  st <- system2("aws", c("s3", "sync", e$s3_path, shQuote(e$local_dir),
                         "--region", s3_region, "--only-show-errors"))
  cat("  finished in",
      round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
  if (st != 0) {
    stop(e$name, ": `aws s3 sync` exited with status ", st,
         ". The S3 copy is intact -- rerun the sync by hand:\n  aws s3 sync ",
         e$s3_path, " \"", e$local_dir, "\" --region ", s3_region)
  }

  # No extension filter: Athena UNLOAD names its objects
  # <query-id>_<uuid> with NO .parquet suffix, so globbing for the
  # extension finds nothing. arrow reads them anyway because format is
  # passed explicitly below.
  files <- list.files(e$local_dir, full.names = TRUE)
  bytes <- sum(file.info(files)$size)
  cat("  files                       :", length(files), "\n")
  cat(sprintf("  on disk                     : %.2f GB\n", bytes / 2^30))

  # nrow() on a Dataset reads footers only, so this stays cheap at
  # 30M rows.
  local_n <- nrow(arrow::open_dataset(e$local_dir, format = "parquet"))
  cat("  rows in the local dataset   :", format(local_n, big.mark = ","), "\n")
  if (local_n != e$n_rows) {
    stop(e$name, ": local dataset has ", local_n, " rows, Athena reported ",
         e$n_rows, " -- the download is incomplete.")
  }
  extracts[[i]]$bytes <- bytes
}

cat("\n=========== SUMMARY ===========\n")
for (e in extracts) {
  cat(sprintf("  %-10s %14s rows  %6.2f GB  %s\n", e$name,
              format(e$n_rows, big.mark = ","), e$bytes / 2^30, e$local_dir))
  cat("             Athena: ", athena_schema, ".", e$table, "\n", sep = "")
  cat("             S3    : ", e$s3_path, "\n", sep = "")
}
cat("  cohort     :", format(exp_users, big.mark = ","), "users, every one of them",
    "present in both extracts\n")
