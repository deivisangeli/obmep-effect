####################################################################
###
### Revelio company key (rcid) for every position in the pool
###                                          -> S3 + Athena + Dropbox
###
### obmep_candidates_step_1_position (script 10a) carries 12 columns
### and NONE of them is a company identifier. It has company_raw,
### company_cleaned and company_linkedin_url -- three strings -- but
### not rcid, which is Revelio's own key for the firm.
###
### This adds it, and nothing else:
###
###   academic_individual_position
###       -> obmep_candidates_step_1_position_rcid
###          (user_id, position_id, rcid, ultimate_parent_rcid)
###
### position_id is the join key back to 10a's extract. No new
### criterion, the same semi-join, the same cohort.
###
### Depends on:
###   prep/building_external_data/obmep_candidates_step_1.R
###   (table revelio_database.obmep_candidates_step_1)
###   prep/building_external_data/obmep_candidates_step_1_entries.R
###   (table revelio_database.obmep_candidates_step_1_position, whose
###    position_id set this one must reproduce exactly)
###
### Consumed by:
###   prep/building_external_data/obmep_candidates_step_1_firms.R
###
### UNLOAD/DDL pattern reused from obmep_candidates_step_1_entries.R.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. THIS SCRIPT REQUIRES INTERNET ACCESS, the same deliberate
###    exception to AGENTS.md that 10a is. Athena + S3 + the AWS CLI
###    are the whole point. Local prep/ script, must not be sent to
###    the offline SEDAP environment.
### 2. WHY A SECOND EXTRACT INSTEAD OF RE-RUNNING 10a. Cost is set by
###    which columns are read, not by how the filter is written -- see
###    10a note 4 and README "Measured cost". 10a's 12 columns were
###    PREDICTED at 444 GB of a 685 GB table and MEASURED at 422.3 GB
###    for $2.06, with `description` alone about 47% of it. Four
###    integer columns are a small fraction of that; re-running 10a to
###    add rcid would pay the 422.3 GB again.
###    MEASURED: this UNLOAD scanned 40.43 GB, about $0.20, against
###    10a's two extracts together at 495 GB and $2.42.
### 3. WHY THE MAP IS STORED WHOLE RATHER THAN FILTERED TO THE FIRMS
###    OF INTEREST. Filtering to the ~500 listed rcids in Athena would
###    scan exactly the same bytes and cost exactly the same, and the
###    next change to the company lists would pay it a third time.
###    Stored whole, every later question about employers is offline
###    and free. This is the folder's standing convention: a cut can
###    be tightened without a rebuild.
### 4. rcid IS bigint HERE AND int ON academic_company_ref. Cast
###    explicitly whenever the two are joined. An implicit widening
###    that happens to work today is exactly the kind of thing that
###    stops working silently.
### 5. THE POSITION_ID SETS MUST BE IDENTICAL. This extract and 10a's
###    are two separate scans of a live table. If Revelio refreshed
###    between them the two disagree and position_id is not a safe
###    join key. The anti-join in both directions is checked below and
###    ABORTS, because a silent partial join is worse than no join.
### 6. NULL rcid IS EXPECTED AND IS NOT AN ERROR. Revelio resolves a
###    company key for a position only when it can; the unresolved
###    ones keep their raw strings. The rate is reported.
### 7. THE LOCAL COPY IS A DOWNLOAD, NOT A RE-ENCODE, and the parts
###    have NO .parquet EXTENSION -- Athena UNLOAD names its objects
###    <query-id>_<uuid>. Read the directory with
###    arrow::open_dataset(dir, format = "parquet") or, in DuckDB,
###    read_parquet('<dir>/*') with a bare glob.
###
### -----------------------------------------------------------------
### SOURCE SCHEMA -- AWS Glue catalogue, revelio_database, 2026-08-28
### -----------------------------------------------------------------
### academic_individual_position has 47 columns, of which 10a took 12.
### The company-side columns it did NOT take:
###
###   rcid                         bigint
###   company_name                 string
###   ultimate_parent_rcid         bigint
###   ultimate_parent_company_name string
###   ticker                       string
###   exchange                     string
###
### company_name and ultimate_parent_company_name are deliberately NOT
### unloaded here. They are strings, they would dominate the bill, and
### they carry nothing that academic_company_ref does not already give
### per rcid at a fraction of the cost.
###
### -----------------------------------------------------------------
### MEASURED, run of 2026-08-28
### -----------------------------------------------------------------
###   scanned                     40.43 GB  (~$0.20)
###   UNLOAD wall time            9 s
###   rows                        30,389,044   == 10a, exactly
###   distinct users              6,849,674    == the whole cohort
###   position_id                 unique; anti-join to 10a is 0 both
###                               ways, so the two extracts saw the
###                               same snapshot (note 5)
###   rcid resolved               23,901,223  (78.7%)
###   distinct rcid               2,089,051
###   ultimate_parent_rcid filled 23,901,197  (78.7%)
###   distinct parent rcid        1,997,948
###   on disk                     0.49 GB in 30 parts
###
### The 21.3% with no rcid is note 6, not a defect: Revelio resolves a
### company key when it can and leaves the raw strings otherwise.
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
pos_table  <- "obmep_candidates_step_1_position"

table      <- "obmep_candidates_step_1_position_rcid"
src        <- "academic_individual_position"

cols     <- c("user_id", "position_id", "rcid", "ultimate_parent_rcid")
ddl_cols <- c("user_id BIGINT", "position_id BIGINT",
              "rcid BIGINT", "ultimate_parent_rcid BIGINT")

# Measured on 10a's run. Both are asserted below; see note 5 and 10a
# note 6.
exp_rows  <- 30389044
exp_users <- 6849674

s3_prefix <- paste0("exports/", table)
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")
local_dir <- file.path(out_root, table)

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

# The AWS CLI does the download (note 7). Failing here beats failing
# after the scan has been paid for.
if (Sys.which("aws") == "") {
  stop("The AWS CLI is not on PATH. It is required for the local copy; ",
       "install it or run the `aws s3 sync` command printed below by hand.")
}

####################################################################
### Step 1: build the queries
####################################################################

# The SELECT lives in its own object so it can be validated on its own
# (scratchpad/validate_sql_syntax.R), whereas UNLOAD and DDL cannot.
select_sql <- sprintf(
  "SELECT %s\nFROM %s\nWHERE user_id IN (SELECT user_id FROM %s.%s)",
  paste(cols, collapse = ",\n       "), src, athena_schema, cand_table)

unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')", select_sql, s3_path)

# STRING/BIGINT (not VARCHAR) and in the exact SELECT order: Hive DDL,
# and the Athena Parquet SerDe resolves columns by POSITION and TYPE.
ddl_txt <- sprintf(
  "CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (\n  %s\n)\nSTORED AS PARQUET\nLOCATION '%s'",
  athena_schema, table, paste(ddl_cols, collapse = ",\n  "), s3_path)

cat("=========== GENERATED SQL ===========\n")
cat(unload_sql, "\n\n", ddl_txt, "\n\n", sep = "")

####################################################################
### Step 2: the destination prefix must be empty
####################################################################

# UNLOAD refuses a non-empty prefix (README trap 7).
cat("=========== CURRENT CONTENTS OF THE S3 PREFIX ===========\n")
existing <- tryCatch(
  get_bucket(bucket = s3_bucket, prefix = paste0(s3_prefix, "/"),
             region = s3_region, max = 100),
  error = function(e2) { cat("  [listing error]:", conditionMessage(e2), "\n"); NULL })
if (is.null(existing) || length(existing) == 0) {
  cat("  ", s3_path, " empty\n\n", sep = "")
} else {
  for (o in existing) cat("   ", o$Key, "(", o$Size, "bytes )\n")
  stop("Prefix ", s3_path, " is not empty. Athena UNLOAD requires an ",
       "empty destination: delete the objects above (and the table ",
       athena_schema, ".", table, ", if it exists) before regenerating.")
}

####################################################################
### Step 3: check the two tables this depends on, then unload
####################################################################

cat("=========== ATHENA ===========\n")
con <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name    = s3_region,
                 schema_name    = athena_schema)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

# Without the cohort the semi-join matches nothing and the extract
# comes out empty after a full scan has been paid for.
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
          " -- exp_users is stale.")
}

# 10a's extract is what this one has to line up with (note 5). If it
# is not there the position_id cross-check cannot run, and running
# without it would produce a table nobody can safely join.
pn <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM %s.%s", athena_schema, pos_table))
cat("10a position rows             :", format(pn$n, big.mark = ","), "\n")
if (pn$n == 0) {
  stop("Table ", athena_schema, ".", pos_table, " is empty. ",
       "Run obmep_candidates_step_1_entries.R first -- this extract is ",
       "only useful joined to it.")
}

cat("\n--- UNLOAD (scans the whole source table) ---\n")
t0 <- Sys.time()
dbExecute(con, unload_sql)
cat("  finished in",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
dbExecute(con, ddl_txt)
cat("  registered ", athena_schema, ".", table, "\n", sep = "")

####################################################################
### Step 4: validation through Athena
####################################################################

cat("\n=========== VALIDATION ===========\n")
v <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_rows,
         count(DISTINCT user_id) AS n_users,
         count(DISTINCT position_id) AS n_pos,
         sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS uid_null,
         count(rcid) AS n_rcid,
         count(DISTINCT rcid) AS n_firms,
         count(ultimate_parent_rcid) AS n_up,
         count(DISTINCT ultimate_parent_rcid) AS n_up_firms
  FROM %s.%s", athena_schema, table))
print(v)

n_rows  <- as.numeric(v$n_rows)
n_users <- as.numeric(v$n_users)
n_pos   <- as.numeric(v$n_pos)

if (n_rows == 0) stop("The extract is empty.")
if (v$uid_null != 0) stop("NULL user_id in the extract.")

# position_id is the join key to 10a. If it is not unique here the
# join fans out.
if (n_pos != n_rows) {
  stop("position_id is not unique: ", format(n_pos, big.mark = ","),
       " distinct values over ", format(n_rows, big.mark = ","), " rows. ",
       "It is the join key back to ", pos_table, " and a fan-out would be ",
       "silent.")
}

# The invariant from 10a note 6: criterion D admits nobody without a
# position, so every cohort member must be here.
if (n_users != exp_users) {
  stop(format(n_users, big.mark = ","), " distinct users, expected ",
       format(exp_users, big.mark = ","),
       ". Every cohort member must have at least one position.")
}

# Note 5 -- the check this whole extract rests on. Two separate scans
# of a live table have to have seen the same rows.
xw <- dbGetQuery(con, sprintf("
  SELECT
    (SELECT count(*) FROM %1$s.%2$s r
      LEFT JOIN %1$s.%3$s p ON r.position_id = p.position_id
      WHERE p.position_id IS NULL) AS only_rcid,
    (SELECT count(*) FROM %1$s.%3$s p
      LEFT JOIN %1$s.%2$s r ON p.position_id = r.position_id
      WHERE r.position_id IS NULL) AS only_10a",
  athena_schema, table, pos_table))
cat("position_id only in this extract :", format(xw$only_rcid, big.mark = ","), "\n")
cat("position_id only in 10a's extract:", format(xw$only_10a, big.mark = ","), "\n")
if (xw$only_rcid != 0 || xw$only_10a != 0) {
  stop("The two position extracts do not cover the same position_ids (",
       xw$only_rcid, " / ", xw$only_10a, "). Revelio refreshed between the ",
       "two scans; position_id is not a safe join key until both are ",
       "rebuilt from the same snapshot.")
}

# A Revelio refresh legitimately moves the row count, so this warns
# rather than aborting -- unlike the invariants above.
if (n_rows != exp_rows) {
  warning("Expected ", exp_rows, " rows, got ", n_rows)
}

cat("\n")
cat("  rows                        :", format(n_rows, big.mark = ","), "\n")
cat("  distinct users              :", format(n_users, big.mark = ","), "\n")
cat(sprintf("  rows per member             : %.2f\n", n_rows / n_users))
cat(sprintf("  rcid resolved               : %s (%.1f%%)  -- note 6\n",
            format(as.numeric(v$n_rcid), big.mark = ","),
            100 * as.numeric(v$n_rcid) / n_rows))
cat("  distinct rcid               :", format(as.numeric(v$n_firms), big.mark = ","), "\n")
cat(sprintf("  ultimate_parent_rcid filled : %s (%.1f%%)\n",
            format(as.numeric(v$n_up), big.mark = ","),
            100 * as.numeric(v$n_up) / n_rows))
cat("  distinct parent rcid        :", format(as.numeric(v$n_up_firms), big.mark = ","), "\n")
cat("\n[OK] all validations passed\n\n")

####################################################################
### Step 5: bring the result down to Dropbox
####################################################################

# aws s3 sync, NOT arrow -- 10a note 5. The local artifact is a
# DIRECTORY of parts with no file extension.
cat("=========== LOCAL COPY ===========\n")
dir.create(local_dir, recursive = TRUE, showWarnings = FALSE)
cat("syncing to ", local_dir, "\n", sep = "")
t0 <- Sys.time()
st <- system2("aws", c("s3", "sync", s3_path, shQuote(local_dir),
                       "--region", s3_region, "--only-show-errors"))
cat("  finished in",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
if (st != 0) {
  stop("`aws s3 sync` exited with status ", st,
       ". The S3 copy is intact -- rerun the sync by hand:\n  aws s3 sync ",
       s3_path, " \"", local_dir, "\" --region ", s3_region)
}

files <- list.files(local_dir, full.names = TRUE)
bytes <- sum(file.info(files)$size)
cat("  files                       :", length(files), "\n")
cat(sprintf("  on disk                     : %.2f GB\n", bytes / 2^30))

# nrow() on a Dataset reads footers only, so this stays cheap.
local_n <- nrow(arrow::open_dataset(local_dir, format = "parquet"))
cat("  rows in the local dataset   :", format(local_n, big.mark = ","), "\n")
if (local_n != n_rows) {
  stop("Local dataset has ", local_n, " rows, Athena reported ", n_rows,
       " -- the download is incomplete.")
}

cat("\n=========== SUMMARY ===========\n")
cat(sprintf("  %14s rows  %6.2f GB  %s\n",
            format(n_rows, big.mark = ","), bytes / 2^30, local_dir))
cat("  Athena: ", athena_schema, ".", table, "\n", sep = "")
cat("  S3    : ", s3_path, "\n", sep = "")
cat("  join to ", pos_table, " on position_id; the two cover the same set\n",
    sep = "")
