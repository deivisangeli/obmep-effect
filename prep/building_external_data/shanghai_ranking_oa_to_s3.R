####################################################################
###
### Shanghai top-1000 (with OpenAlex names and lineage) -> S3 + Athena
###
### Uploads the parquet produced by
### prep/building_external_data/shanghai_ranking_oa_parents.R (4a) to
### S3 and registers it as an external table, so the ranked
### institutions' names can be matched server-side against Revelio
### education records (academic_individual_user_education.
### university_raw). That match is script 6a.
###
### The Brazilian equivalent of this file is
### openalex_institutions_br_to_s3.R (5), and this is its shape
### unchanged. The difference is the list: 1,000 ranked universities
### worldwide instead of 1,947 Brazilian institutions of every type.
###
### Upload pattern reused from:
###   prep/building_external_data/openalex_institutions_br_to_s3.R
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. That is a deliberate exception: uploading to S3 is
###    the whole point. It is a local prep/ script and must not be sent
###    to the offline SEDAP environment.
### 2. An Athena LOCATION is a PREFIX. Any stray object under
###    shanghai_ranking_oa/ would be read as table data. The prefix is
###    listed before the upload precisely so that this stays visible.
### 3. *** THE PREFIX HAS NO exports/ COMPONENT, AND THAT IS THE
###    CONVENTION, NOT AN OVERSIGHT. *** Measured across this folder:
###
###      exports/<name>/   UNLOAD destinations, written by Athena
###      <name>/           put_object uploads, written from here
###
###    Script 5 uploads to `openalex_institutions_br/` and script 6
###    UNLOADs to `exports/rsid_openalex_br/`. This is an upload, so it
###    is bare. Script 6a is an UNLOAD, so it uses exports/.
###
###    One consequence: an UNLOAD refuses a non-empty prefix and so
###    every UNLOAD script stops on one. put_object OVERWRITES happily,
###    so this script warns on a non-empty prefix instead of stopping,
###    and skips the upload entirely when the remote byte count already
###    matches the local one.
### 4. The Athena Parquet SerDe resolves columns by POSITION AND TYPE,
###    not by name. The 20 columns in the DDL are in the same order as
###    the file, and both the order AND the types are checked before
###    uploading -- script 5 checks only the order, and README trap 5
###    is the reason that is not enough: a type mismatch registers
###    cleanly and fails on READ, never on write.
### 5. THE NUMERIC COLUMNS ARE NOT ALL THE SAME TYPE, and guessing
###    costs a broken table. 4a casts the three lineage counts and
###    shanghai_rank to INTEGER; math_rank, shanghai_rank_2003,
###    uni_ranking, top_50_uni and has_top_50_uni stay DOUBLE, which is
###    how they arrive from the source xlsx. Rank in particular reads
###    like an integer in the xlsx and is not one -- 4a note 10.
### 6. display_name and cleaned_display_name are NOT accent-folded or
###    case-folded. That is how script 4 writes them and its assertions
###    depend on it. Folding happens at query time in 6a, on both sides
###    with the same expression, never in the stored artifact.
### 7. ONE ROW CANNOT BE MATCHED BY ANYTHING and is uploaded anyway.
###    Rank 701 holds the name 'RUTGERS UNIVERSITY - NEWARK' in OA_key
###    instead of an I-number, so it resolves to no snapshot record and
###    both name columns are NULL. It ships with oa_id_valid = 0 and
###    in_snapshot = 0 rather than being dropped, because the table IS
###    the ranking and removing a ranked university would make the row
###    count lie. The defect is upstream, in
###    shanghai_ranking_full_cleaned.xlsx, and is still there.
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
                      "Data/intermediate/shanghai_ranking",
                      "shanghai_ranking_oa_parents.parquet")

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
# Note 3: bare, not exports/. This is a put_object upload.
s3_prefix <- "shanghai_ranking_oa"
s3_object <- paste0(s3_prefix, "/shanghai_ranking_oa_parents.parquet")
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table  <- "shanghai_ranking_oa"

# Measured in shanghai_ranking_oa_parents.R (4a).
exp_rows <- 1000

# Note 4: ORDER AND TYPE, both. This is the file layout 4a writes.
exp_cols <- c("oa_key", "shanghai_rank", "shanghai_name", "oa_id",
              "display_name", "cleaned_display_name", "country_code", "iso3c",
              "math_rank", "shanghai_rank_2003", "uni_ranking", "top_50_uni",
              "has_top_50_uni", "oa_id_valid", "in_snapshot",
              "parent_openalex_id", "n_parents", "root_openalex_id",
              "n_roots", "lineage_depth")

exp_types <- c("VARCHAR", "INTEGER", "VARCHAR", "VARCHAR",
               "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR",
               "DOUBLE", "DOUBLE", "DOUBLE", "DOUBLE",
               "DOUBLE", "INTEGER", "INTEGER",
               "VARCHAR", "INTEGER", "VARCHAR",
               "INTEGER", "INTEGER")

# The Hive type for each column above, in the same order. Kept next to
# exp_types so the two can never drift apart unnoticed (note 4).
ddl_types <- c("STRING", "INT", "STRING", "STRING",
               "STRING", "STRING", "STRING", "STRING",
               "DOUBLE", "DOUBLE", "DOUBLE", "DOUBLE",
               "DOUBLE", "INT", "INT",
               "STRING", "INT", "STRING",
               "INT", "INT")

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

if (!file.exists(local_pq)) {
  stop("Missing input: ", local_pq,
       "\nRun shanghai_ranking_oa_parents.R (4a) first.")
}

sz <- file.info(local_pq)$size
cat(sprintf("File: %s (%.1f KB)\n\n", local_pq, sz / 2^10))

####################################################################
### Step 1: validate BEFORE uploading
####################################################################

# The upload is the hard-to-undo step, and validating here is cheap.
con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
fw <- function(p) gsub("\\\\", "/", p)

cat("=========== PRE-UPLOAD VALIDATION ===========\n")
sch <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", fw(local_pq)))
print(sch[, c("column_name", "column_type")], row.names = FALSE)

# Order, not just presence: Athena reads Parquet by position.
if (!identical(sch$column_name, exp_cols)) {
  stop("Unexpected columns (order matters): ",
       paste(sch$column_name, collapse = ", "))
}
# And type, because the DDL below hard-codes one per column (note 4).
if (!identical(sch$column_type, exp_types)) {
  print(data.frame(column = sch$column_name, found = sch$column_type,
                   expected = exp_types)[sch$column_type != exp_types, ],
        row.names = FALSE)
  stop("A column type changed. The Hive DDL hard-codes one type per ",
       "column; a mismatch registers cleanly and fails on READ. Fix 4a, ",
       "exp_types and ddl_types together -- never one of them.")
}
stopifnot(length(ddl_types) == length(exp_cols))

v <- dbGetQuery(con, sprintf("
  SELECT count(*)                                   AS n_rows,
         count(DISTINCT oa_key)                     AS n_keys,
         count(DISTINCT lower(display_name))        AS n_display_lower,
         count(DISTINCT lower(cleaned_display_name)) AS n_clean_lower,
         sum(CASE WHEN display_name IS NULL THEN 1 ELSE 0 END) AS display_null,
         sum(CASE WHEN oa_id_valid = 0 THEN 1 ELSE 0 END)      AS bad_key,
         sum(CASE WHEN in_snapshot = 0 THEN 1 ELSE 0 END)      AS not_in_snapshot,
         min(shanghai_rank)                         AS min_rank,
         max(shanghai_rank)                         AS max_rank
  FROM read_parquet('%s')", fw(local_pq)))
print(v, row.names = FALSE)

if (v$n_rows != exp_rows) stop("Expected ", exp_rows, " rows, got ", v$n_rows)
if (v$n_keys != v$n_rows) stop("Duplicate oa_key in the parquet.")
if (v$min_rank < 1 || v$max_rank > 901) {
  stop("shanghai_rank outside [1, 901]: ", v$min_rank, "..", v$max_rank,
       " -- 4a's band filter did not do what it claims.")
}

# Note 7. Reported, never fatal: the row belongs in the ranking.
cat("\nrows that can never match (note 7)   :", v$display_null, "\n")
cat("[OK] all pre-upload validations passed\n\n")

####################################################################
### Step 2: upload to S3
####################################################################

# An Athena LOCATION is a PREFIX: any stray object under
# shanghai_ranking_oa/ would be read as table data. That is why we
# inspect the prefix first (notes 2 and 3).
cat("=========== CURRENT CONTENTS OF THE S3 PREFIX ===========\n")
existing <- tryCatch(
  get_bucket(bucket = s3_bucket, prefix = paste0(s3_prefix, "/"),
             region = s3_region, max = 100),
  error = function(e) { cat("  [listing error]:", conditionMessage(e), "\n"); NULL })
if (is.null(existing) || length(existing) == 0) {
  cat("  prefix is empty\n")
} else {
  for (o in existing) cat("  ", o$Key, " (", o$Size, " bytes )\n")
  stray <- setdiff(vapply(existing, function(o) o$Key, character(1)), s3_object)
  if (length(stray)) {
    cat("\n[warn] ", length(stray), " object(s) under the prefix that are NOT\n",
        "       this upload. Athena would read them AS TABLE DATA (note 2).\n",
        "       Remove them before trusting the registered table:\n", sep = "")
    for (k in stray) cat("         ", k, "\n")
  }
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
  # 56 KB: a single PUT is enough, no multipart.
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
cat("  remote size:", attr(hd, "content-length"), "| local:", sz, "\n\n")
if (!as.logical(hd)) stop("Object not found in S3 after the upload.")

####################################################################
### Step 3: register the external table in Athena
####################################################################

cat("=========== ATHENA ===========\n")

# STRING (not VARCHAR) and in the exact file order: Hive DDL, columns
# resolved by position AND type (notes 4 and 5). Built from the same
# two vectors the validation above checked, so the DDL cannot drift
# away from the file it describes.
ddl_txt <- sprintf(
  "CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (\n%s\n)\nSTORED AS PARQUET\nLOCATION '%s'",
  athena_schema, athena_table,
  paste0("  ", exp_cols, " ", ddl_types, collapse = ",\n"),
  s3_path)

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
            count(DISTINCT oa_key) AS n_keys,
            count(DISTINCT lower(cleaned_display_name)) AS n_clean_lower,
            min(shanghai_rank) AS min_rank,
            max(shanghai_rank) AS max_rank
     FROM %s.%s", athena_schema, athena_table))
  print(a, row.names = FALSE)
  print(dbGetQuery(acon, sprintf(
    "SELECT oa_key, shanghai_rank, shanghai_name, display_name, root_openalex_id
     FROM %s.%s ORDER BY shanghai_rank LIMIT 10",
    athena_schema, athena_table)), row.names = FALSE)

  if (a$n_rows != exp_rows) {
    stop("Athena returned ", a$n_rows, " rows, expected ", exp_rows)
  }
  if (a$n_keys != a$n_rows) stop("Athena: duplicate oa_key.")
  # If the columns had been resolved at the wrong position, neither of
  # these two would match the locally measured value. They are the
  # cheapest test there is for note 4, one on a string column and one
  # on a numeric, because a positional slip usually moves both.
  if (a$n_clean_lower != v$n_clean_lower) {
    stop("Athena: ", a$n_clean_lower, " distinct lowercased names, expected ",
         v$n_clean_lower, " -- columns out of position?")
  }
  if (a$min_rank != v$min_rank || a$max_rank != v$max_rank) {
    stop("Athena: shanghai_rank spans ", a$min_rank, "..", a$max_rank,
         ", expected ", v$min_rank, "..", v$max_rank,
         " -- wrong position, or INT declared over a DOUBLE?")
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
