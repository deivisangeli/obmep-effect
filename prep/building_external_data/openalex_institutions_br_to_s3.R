####################################################################
###
### Brazilian OpenAlex institutions -> S3 + Athena
###
### Uploads the parquet produced by
### prep/building_external_data/openalex_br_institutions.R to S3 and
### registers it as an external table in Athena, so that institution
### names can be matched server-side against Revelio education records
### (academic_individual_user_education.university_raw).
###
### Upload pattern reused from:
###   prep/building_external_data/linkedin_br_flag_to_s3.R
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. That is a deliberate exception: uploading to S3 is
###    the whole point. It is a local prep/ script and must not be sent
###    to the offline SEDAP environment.
### 2. An Athena LOCATION is a PREFIX. Any stray object under
###    openalex_institutions_br/ would be read as table data. The
###    prefix is listed before the upload precisely so that this stays
###    visible.
### 3. The Athena Parquet SerDe resolves columns by POSITION, not by
###    name. The 11 columns in the DDL are in the same order as the
###    file, and that order is checked before uploading.
### 4. display_name and cleaned_display_name are NOT accent-folded or
###    case-folded -- that is how openalex_br_institutions.R writes
###    them, and its assertions depend on it. Case normalization
###    happens at query time, never in the stored artifact.
###
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "aws.s3", "RAthena")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(duckdb)
library(aws.s3)

####################################################################
### Parameters
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")

local_pq <- file.path(obmep_root,
                      "Data/intermediate/openalex_institutions",
                      "openalex_institutions_br.parquet")

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
s3_prefix <- "openalex_institutions_br"
s3_object <- paste0(s3_prefix, "/openalex_institutions_br.parquet")
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table  <- "openalex_institutions_br"

# Measured in openalex_br_institutions.R.
exp_rows <- 1947

exp_cols <- c("openalex_id", "openalex_url", "display_name",
              "cleaned_display_name", "ror", "type", "works_count",
              "city", "region", "country_source", "snapshot_date")

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

stopifnot(file.exists(local_pq))

sz <- file.info(local_pq)$size
cat(sprintf("File: %s (%.1f KB)\n\n", local_pq, sz / 2^10))

####################################################################
### Step 1: validate BEFORE uploading
####################################################################

# The upload is the hard-to-undo step, and validating here is cheap.
con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

cat("=========== PRE-UPLOAD VALIDATION ===========\n")
sch <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", local_pq))
print(sch)

# Order, not just presence: Athena reads Parquet by position.
if (!identical(sch$column_name, exp_cols)) {
  stop("Unexpected columns (order matters): ",
       paste(sch$column_name, collapse = ", "))
}

v <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_rows,
         count(DISTINCT openalex_id) AS n_ids,
         count(DISTINCT display_name) AS n_display,
         count(DISTINCT lower(cleaned_display_name)) AS n_clean_lower,
         sum(CASE WHEN display_name IS NULL THEN 1 ELSE 0 END) AS display_null,
         sum(CASE WHEN cleaned_display_name IS NULL THEN 1 ELSE 0 END) AS clean_null
  FROM read_parquet('%s')", local_pq))
print(v)

if (v$n_rows != exp_rows) stop("Expected ", exp_rows, " rows, got ", v$n_rows)
if (v$n_ids != v$n_rows) stop("Duplicate openalex_id in the parquet.")
if (v$display_null != 0 || v$clean_null != 0) {
  stop("NULL found in display_name or cleaned_display_name.")
}

# Diagnostic, not an invariant: the Revelio match compares
# lower(cleaned_display_name), so names that were distinct in the
# source but collide once lowercased become a single criterion. Not an
# error -- the consumer joins against SELECT DISTINCT -- but worth
# knowing how many there are.
cat("distinct names in display_name           :", v$n_display, "\n")
cat("distinct names in lower(cleaned_display) :", v$n_clean_lower, "\n")
if (v$n_clean_lower < v$n_display) {
  cat("[warn] lower(cleaned_display_name) collapses",
      v$n_display - v$n_clean_lower, "distinct name(s)\n")
}
cat("[OK] all pre-upload validations passed\n\n")

####################################################################
### Step 2: upload to S3
####################################################################

# An Athena LOCATION is a PREFIX: any stray object under
# openalex_institutions_br/ would be read as table data. That is why we
# inspect the prefix first.
cat("=========== CURRENT CONTENTS OF THE S3 PREFIX ===========\n")
existing <- tryCatch(
  get_bucket(bucket = s3_bucket, prefix = paste0(s3_prefix, "/"),
             region = s3_region, max = 100),
  error = function(e) { cat("  [listing error]:", conditionMessage(e), "\n"); NULL })
if (is.null(existing) || length(existing) == 0) {
  cat("  prefix is empty\n")
} else {
  for (o in existing) cat("  ", o$Key, " (", o$Size, " bytes )\n")
}

hd0 <- tryCatch(head_object(object = s3_object, bucket = s3_bucket,
                            region = s3_region),
                error = function(e) NULL)
remote_sz <- if (!is.null(hd0) && as.logical(hd0)) {
  as.numeric(attr(hd0, "content-length")) } else NA_real_

if (!is.na(remote_sz) && remote_sz == sz) {
  cat("\n[skip] object already in S3 with", remote_sz,
      "bytes (identical to local) -- upload not needed\n")
} else {
  if (!is.na(remote_sz)) {
    cat("\n[warn] remote object has", remote_sz, "bytes vs", sz,
        "local -- re-uploading\n")
  }
  cat("\nUploading to s3://", s3_bucket, "/", s3_object, " ...\n", sep = "")
  # 83 KB: a single PUT is enough, no multipart.
  ok <- put_object(
    file   = local_pq,
    object = s3_object,
    bucket = s3_bucket,
    region = s3_region
  )
  cat("  put_object returned:", ok, "\n")
}

hd <- head_object(object = s3_object, bucket = s3_bucket, region = s3_region)
cat("  object exists in S3:", as.logical(hd), "\n")
cat("  remote size:", attr(hd, "content-length"),
    "| local:", sz, "\n\n")
if (!as.logical(hd)) stop("Object not found in S3 after the upload.")

####################################################################
### Step 3: register the external table in Athena
####################################################################

cat("=========== ATHENA ===========\n")

# STRING (not VARCHAR) and in the exact file order: Hive DDL, columns
# resolved by position.
ddl_txt <- sprintf(
"CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (
  openalex_id STRING,
  openalex_url STRING,
  display_name STRING,
  cleaned_display_name STRING,
  ror STRING,
  type STRING,
  works_count BIGINT,
  city STRING,
  region STRING,
  country_source STRING,
  snapshot_date STRING
)
STORED AS PARQUET
LOCATION '%s'", athena_schema, athena_table, s3_path)

# RAthena depends on boto3 through reticulate. In a non-interactive
# session reticulate may resolve a Python without boto3, in which case
# registering the table fails AFTER the upload has already succeeded.
# That is why this step tolerates failure: the S3 object is the main
# deliverable and must not be lost to a Python dependency problem. The
# DDL is printed so it can be run manually.
athena_ok <- tryCatch({
  acon <- dbConnect(RAthena::athena(),
                    s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                    region_name    = s3_region,
                    schema_name    = athena_schema)
  cat(ddl_txt, "\n")
  dbExecute(acon, ddl_txt)

  cat("\n--- verification through Athena ---\n")
  a <- dbGetQuery(acon, sprintf(
    "SELECT count(*) AS n_rows,
            count(DISTINCT openalex_id) AS n_ids,
            count(DISTINCT lower(cleaned_display_name)) AS n_clean_lower
     FROM %s.%s", athena_schema, athena_table))
  print(a)
  print(dbGetQuery(acon, sprintf(
    "SELECT openalex_id, display_name, cleaned_display_name, works_count
     FROM %s.%s ORDER BY works_count DESC LIMIT 10",
    athena_schema, athena_table)))

  if (a$n_rows != exp_rows) {
    stop("Athena returned ", a$n_rows, " rows, expected ", exp_rows)
  }
  if (a$n_ids != a$n_rows) stop("Athena: duplicate openalex_id.")
  # If the columns had been resolved at the wrong position, this number
  # would not match the one measured locally.
  if (a$n_clean_lower != v$n_clean_lower) {
    stop("Athena: ", a$n_clean_lower, " distinct lowercased names, ",
         "expected ", v$n_clean_lower, " -- columns out of position?")
  }
  cat("\n[OK] table ", athena_schema, ".", athena_table,
      " registered and verified\n", sep = "")
  dbDisconnect(acon)
  TRUE
}, error = function(e) {
  cat("\n[FAIL AT THE ATHENA STEP]", conditionMessage(e), "\n\n")
  cat("The S3 upload DID COMPLETE -- only the table registration is\n",
      "missing. Run the DDL below in a session where RAthena/boto3\n",
      "works (or install it with RAthena::install_boto()):\n\n", sep = "")
  cat(ddl_txt, "\n\n")
  FALSE
})

cat("\n=========== SUMMARY ===========\n")
cat("  local parquet :", local_pq, sprintf("(%.1f KB)\n", sz / 2^10))
cat("  S3 object     : s3://", s3_bucket, "/", s3_object, "\n", sep = "")
cat("  rows          :", format(v$n_rows, big.mark = ","), "\n")
cat("  Athena table  :", ifelse(athena_ok, "registered and verified",
                                "PENDING -- run the DDL above"), "\n")
cat("  S3 LOCATION   :", s3_path, "\n")
