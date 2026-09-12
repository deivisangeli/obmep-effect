####################################################################
###
### Refreshed OBMEP country/name union and complete education history
###
### LOCAL, ONLINE PIPELINE. This script uploads a narrow local cohort
### to S3, registers it in Athena, executes one metered UNLOAD from
### academic_individual_user_education, and downloads the result to
### Dropbox. It must not be run in SEDAP.
###
### The canonical obmep_candidates_step_1 files and tables are never
### overwritten. The only raw-table scan is the education UNLOAD.
### Classification, comparison, validation and sampling run locally.
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "aws.s3", "RAthena", "arrow", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(duckdb)
library(aws.s3)

####################################################################
### Parameters and immutable inputs
####################################################################

obmep_root <- Sys.getenv(
  "OBMEP_ROOT", unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
repo_root <- Sys.getenv(
  "OBMEP_REPO", unset = "C:/Users/megaj/repos/obmep_effect")
cohort_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

country_path <- file.path(
  cohort_dir, "obmep_br_cohort_user_ids_degree_duration.parquet")
name_path <- file.path(cohort_dir, "obmep_br_name_cohort_user_ids.parquet")
canonical_union_path <- file.path(cohort_dir, "obmep_candidates_step_1.parquet")
canonical_education_dir <- file.path(
  cohort_dir, "obmep_candidates_step_1_education")

union_path <- file.path(
  cohort_dir, "obmep_candidates_step_1_degree_duration.parquet")
education_dir <- file.path(
  cohort_dir, "obmep_candidates_step_1_degree_duration_education")
sample_path <- file.path(
  cohort_dir,
  "obmep_candidates_step_1_degree_duration_education_sample_100.csv")
report_path <- file.path(
  cohort_dir,
  "obmep_candidates_step_1_degree_duration_education_report.json")
ledger_path <- file.path(
  cohort_dir,
  "obmep_candidates_step_1_degree_duration_education_scan_ledger.csv")

patterns_file <- file.path(
  repo_root, "prep/building_external_data/br_degree_patterns.R")

expected_country <- 7762714
expected_name <- 3779509
expected_union <- 8901904
expected_country_only <- 5122395
expected_both <- 2640319
expected_name_only <- 1139190
expected_current_union <- 6849674
expected_retained <- 6812493
expected_added <- 2089411
expected_removed <- 37181

sample_seed <- 20260910L
scan_budget_bytes <- 92000000000
athena_rate_per_tb <- 5
resume_query_id <- Sys.getenv("OBMEP_RESUME_ATHENA_QUERY_ID", unset = "")
resume_mode <- nzchar(resume_query_id)

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
union_prefix <- "obmep_candidates_step_1_degree_duration"
union_object <- paste0(
  union_prefix, "/obmep_candidates_step_1_degree_duration.parquet")
union_s3_path <- paste0("s3://", s3_bucket, "/", union_prefix, "/")
education_prefix <-
  "exports/obmep_candidates_step_1_degree_duration_education"
education_s3_path <- paste0(
  "s3://", s3_bucket, "/", education_prefix, "/")

athena_schema <- "revelio_database"
union_table <- "obmep_candidates_step_1_degree_duration"
education_table <- "obmep_candidates_step_1_degree_duration_education"
education_source <- "academic_individual_user_education"

input_paths <- c(country_path, name_path, canonical_union_path)
if (!all(file.exists(input_paths))) {
  stop("Missing local input(s): ",
       paste(input_paths[!file.exists(input_paths)], collapse = ", "))
}
if (!dir.exists(canonical_education_dir)) {
  stop("Canonical education directory is missing: ", canonical_education_dir)
}
if (!file.exists(patterns_file)) {
  stop("Shared degree-pattern file is missing: ", patterns_file)
}
output_paths <- c(union_path, education_dir, sample_path, report_path, ledger_path)
if (!resume_mode && any(file.exists(output_paths))) {
  stop("This build never overwrites a prior output: ",
       paste(output_paths[file.exists(output_paths)], collapse = ", "))
}
if (resume_mode) {
  if (!file.exists(union_path) || !file.exists(ledger_path)) {
    stop("Resume mode requires the existing refreshed union and scan ledger.")
  }
  resumed_forbidden <- c(education_dir, sample_path, report_path)
  if (any(file.exists(resumed_forbidden))) {
    stop("Resume mode will not overwrite completed downstream output: ",
         paste(resumed_forbidden[file.exists(resumed_forbidden)], collapse = ", "))
  }
}
if (Sys.which("aws") == "") {
  stop("The AWS CLI is required for upload and download.")
}

source(patterns_file)

py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

canonical_union_md5_before <- unname(tools::md5sum(canonical_union_path))
canonical_files_before <- file.info(sort(list.files(
  canonical_education_dir, recursive = TRUE, full.names = TRUE)))
canonical_manifest_before <- data.frame(
  path = rownames(canonical_files_before),
  size = canonical_files_before$size,
  mtime = as.numeric(canonical_files_before$mtime),
  stringsAsFactors = FALSE)

####################################################################
### Build and validate the refreshed union locally (zero Athena scan)
####################################################################

duckdb_temp_dir <- file.path(
  Sys.getenv("TEMP"), "duckdb_obmep_degree_duration_education")
dir.create(duckdb_temp_dir, recursive = TRUE, showWarnings = FALSE)
local_con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(local_con, shutdown = TRUE), silent = TRUE), add = TRUE)
dbExecute(local_con, "SET preserve_insertion_order=false")
dbExecute(local_con, "PRAGMA threads=4")
dbExecute(local_con, "PRAGMA memory_limit='12GB'")
dbExecute(local_con, sprintf("PRAGMA temp_directory='%s'", gsub(
  "'", "''", duckdb_temp_dir, fixed = TRUE)))

country_sql_path <- gsub("'", "''", country_path, fixed = TRUE)
name_sql_path <- gsub("'", "''", name_path, fixed = TRUE)
canonical_sql_path <- gsub("'", "''", canonical_union_path, fixed = TRUE)
union_sql_path <- gsub("'", "''", union_path, fixed = TRUE)

cat("=========== LOCAL REFRESHED UNION ===========\n")
if (!file.exists(union_path)) {
  dbExecute(local_con, sprintf(
    "COPY (
       SELECT coalesce(c.user_id, n.user_id) AS user_id,
              CAST(c.user_id IS NOT NULL AS INTEGER) AS in_country_cohort,
              CAST(n.user_id IS NOT NULL AS INTEGER) AS in_name_cohort
       FROM read_parquet('%s') c
       FULL OUTER JOIN read_parquet('%s') n ON c.user_id = n.user_id
       ORDER BY user_id
     ) TO '%s' (FORMAT PARQUET, COMPRESSION SNAPPY)",
    country_sql_path, name_sql_path, union_sql_path))
} else {
  cat("  [resume] using existing local refreshed union\n")
}

union_validation <- dbGetQuery(local_con, sprintf(
  "SELECT count(*) AS n_rows,
          count(DISTINCT user_id) AS n_users,
          count_if(user_id IS NULL) AS null_users,
          count_if(in_country_cohort = 1 AND in_name_cohort = 0)
            AS country_only,
          count_if(in_country_cohort = 1 AND in_name_cohort = 1) AS both,
          count_if(in_country_cohort = 0 AND in_name_cohort = 1) AS name_only,
          count_if(in_country_cohort = 0 AND in_name_cohort = 0) AS orphan
   FROM read_parquet('%s')", union_sql_path))
print(union_validation)
stopifnot(
  union_validation$n_rows == expected_union,
  union_validation$n_users == expected_union,
  union_validation$null_users == 0,
  union_validation$country_only == expected_country_only,
  union_validation$both == expected_both,
  union_validation$name_only == expected_name_only,
  union_validation$orphan == 0)

input_counts <- dbGetQuery(local_con, sprintf(
  "SELECT (SELECT count(*) FROM read_parquet('%s')) AS country_users,
          (SELECT count(*) FROM read_parquet('%s')) AS name_users",
  country_sql_path, name_sql_path))
stopifnot(input_counts$country_users == expected_country,
          input_counts$name_users == expected_name)

comparison <- dbGetQuery(local_con, sprintf(
  "WITH old AS (SELECT user_id FROM read_parquet('%s')),
        new AS (SELECT user_id FROM read_parquet('%s')),
        membership AS (
          SELECT coalesce(o.user_id, n.user_id) AS user_id,
                 o.user_id IS NOT NULL AS in_current,
                 n.user_id IS NOT NULL AS in_refreshed
          FROM old o FULL OUTER JOIN new n ON o.user_id = n.user_id
        )
   SELECT count_if(in_current) AS current_users,
          count_if(in_refreshed) AS refreshed_users,
          count_if(in_current AND in_refreshed) AS retained_users,
          count_if(NOT in_current AND in_refreshed) AS added_users,
          count_if(in_current AND NOT in_refreshed) AS removed_users
   FROM membership", canonical_sql_path, union_sql_path))
print(comparison)
stopifnot(
  comparison$current_users == expected_current_union,
  comparison$refreshed_users == expected_union,
  comparison$retained_users == expected_retained,
  comparison$added_users == expected_added,
  comparison$removed_users == expected_removed)

####################################################################
### Destination guards, narrow upload and zero-scan table registration
####################################################################

cat("\n=========== DESTINATION GUARDS ===========\n")
union_objects <- get_bucket(
  bucket = s3_bucket, prefix = paste0(union_prefix, "/"),
  region = s3_region, max = 100)
education_objects <- get_bucket(
  bucket = s3_bucket, prefix = paste0(education_prefix, "/"),
  region = s3_region, max = 100)
if (!resume_mode) {
  if (length(union_objects) || length(education_objects)) {
    stop("A new-run S3 destination is not empty.")
  }
  cat("  both S3 destinations are empty\n")
} else {
  if (length(union_objects) != 1 || !length(education_objects) ||
      any(vapply(education_objects, function(x) as.numeric(x$Size), 0) == 0)) {
    stop("Resume mode requires one union object and nonempty education parts.")
  }
  remote_union_size <- as.numeric(union_objects[[1]]$Size)
  if (remote_union_size != file.info(union_path)$size) {
    stop("Resume-mode union object size differs from the local parquet.")
  }
  cat("  [resume] found the union object and ", length(education_objects),
      " education parts\n", sep = "")
}

athena_con <- dbConnect(
  RAthena::athena(), s3_staging_dir = paste0("s3://", s3_bucket, "/"),
  region_name = s3_region, schema_name = athena_schema)
on.exit(try(dbDisconnect(athena_con), silent = TRUE), add = TRUE)

tables_json_lines <- system2(
  "aws", c("glue", "get-tables", "--database-name", athena_schema,
           "--region", s3_region, "--query", "TableList[].Name",
           "--output", "json"), stdout = TRUE, stderr = TRUE)
tables_json_status <- attr(tables_json_lines, "status")
if (!is.null(tables_json_status) && tables_json_status != 0) {
  stop("Could not inspect the Glue catalog: ",
       paste(tables_json_lines, collapse = "\n"))
}
tables <- unlist(jsonlite::fromJSON(paste(tables_json_lines, collapse = "\n")))
if (!resume_mode && (union_table %in% tables || education_table %in% tables)) {
  stop("An output Athena table already exists: ",
       paste(intersect(c(union_table, education_table), tables), collapse = ", "))
}
if (resume_mode && (!union_table %in% tables || education_table %in% tables)) {
  stop("Resume mode requires the union table and no education output table.")
}

union_ddl <- sprintf(
  "CREATE EXTERNAL TABLE %s.%s (
     user_id BIGINT,
     in_country_cohort INT,
     in_name_cohort INT
   )
   STORED AS PARQUET
   LOCATION '%s'",
  athena_schema, union_table, union_s3_path)

if (!resume_mode) {
  cat("\nUploading refreshed union...\n")
  upload_status <- system2(
    "aws", c("s3", "cp", shQuote(union_path),
             paste0("s3://", s3_bucket, "/", union_object),
             "--region", s3_region, "--only-show-errors"))
  if (upload_status != 0) stop("AWS CLI failed to upload the refreshed union.")

  ledger <- data.frame(
    query_id = character(), purpose = character(), status = character(),
    estimated_bytes = numeric(), actual_bytes = numeric(),
    estimated_cost_usd = numeric(), disposition = character(),
    stringsAsFactors = FALSE)

  union_res <- dbSendQuery(athena_con, union_ddl)
  union_error <- NULL
  tryCatch(invisible(dbFetch(union_res)), error = function(e) {
    union_error <<- conditionMessage(e)
  })
  union_info <- dbGetInfo(union_res)
  union_bytes <- if (is.null(union_info$Statistics$DataScannedInBytes)) 0 else
    union_info$Statistics$DataScannedInBytes
  ledger <- rbind(ledger, data.frame(
    query_id = union_info$QueryExecutionId, purpose = "register refreshed union",
    status = union_info$Status, estimated_bytes = 0,
    actual_bytes = union_bytes, estimated_cost_usd = 0,
    disposition = if (identical(union_info$Status, "SUCCEEDED"))
      "accepted" else "failed",
    stringsAsFactors = FALSE))
  write.csv(ledger, ledger_path, row.names = FALSE)
  dbClearResult(union_res)
  if (!identical(union_info$Status, "SUCCEEDED")) {
    stop("Union DDL failed: ", union_error)
  }
  if (union_bytes != 0) stop("Union DDL unexpectedly scanned data.")
} else {
  ledger <- read.csv(ledger_path, stringsAsFactors = FALSE)
}

####################################################################
### One approved raw education scan
####################################################################

select_sql <- sprintf(
  "WITH education_base AS (
     SELECT e.user_id, e.university_raw, e.university_name, e.rsid,
            e.degree_raw, e.degree, e.field_raw, e.field,
            e.university_country, e.description, e.startdate, e.enddate,
            lower(trim(coalesce(e.degree_raw, ''))) AS dr,
            CAST(year(e.startdate) AS integer) AS start_year,
            CAST(year(e.enddate) AS integer) AS end_year
     FROM %1$s.%2$s e
     WHERE e.user_id IN (SELECT user_id FROM %1$s.%3$s)
   ),
   education_classified AS (
     SELECT e.*, (%4$s) AS ranked_level, (%5$s) AS residual_other
     FROM education_base e
   ),
   education_scored AS (
     SELECT e.*,
            ranked_level = 'bachelor' AS is_ranked,
            residual_other
              AND startdate IS NOT NULL AND enddate IS NOT NULL
              AND end_year - start_year IN (3, 4, 5, 6) AS is_duration
     FROM education_classified e
   )
   SELECT user_id, university_raw, university_name, rsid,
          degree_raw, degree, field_raw, field, university_country,
          description, startdate, enddate,
          ranked_level,
          CAST(end_year - start_year AS integer) AS degree_duration_years,
          CAST(residual_other AS integer) AS degree_residual_other,
          CAST(is_ranked AS integer) AS degree_match_ranked,
          CAST(is_duration AS integer) AS degree_match_duration,
          CAST(is_ranked OR is_duration AS integer) AS degree_matches_laxed,
          CASE WHEN is_ranked THEN 'ranked_regex'
               WHEN is_duration THEN 'duration_fallback'
               ELSE 'not_qualifying' END AS degree_match_route
   FROM education_scored",
  athena_schema, education_source, union_table,
  sql_ranked_level, sql_is_residual_other)

unload_sql <- sprintf(
  "UNLOAD (%s)
   TO '%s'
   WITH (format = 'PARQUET', compression = 'SNAPPY')",
  select_sql, education_s3_path)

education_ddl <- sprintf(
  "CREATE EXTERNAL TABLE %s.%s (
     user_id BIGINT,
     university_raw STRING,
     university_name STRING,
     rsid INT,
     degree_raw STRING,
     degree STRING,
     field_raw STRING,
     field STRING,
     university_country STRING,
     description STRING,
     startdate DATE,
     enddate DATE,
     ranked_level STRING,
     degree_duration_years INT,
     degree_residual_other INT,
     degree_match_ranked INT,
     degree_match_duration INT,
     degree_matches_laxed INT,
     degree_match_route STRING
   )
   STORED AS PARQUET
   LOCATION '%s'",
  athena_schema, education_table, education_s3_path)

cat("\n=========== APPROVED ATHENA UNLOAD ===========\n")
cat("  purpose       : complete education history plus classifier provenance\n")
cat("  estimated scan: 89,823,300,000 bytes\n")
cat("  approved cap  :", format(scan_budget_bytes, big.mark = ","), "bytes\n")
cat("  estimated cost: $", sprintf("%.2f", 89823300000 / 1e12 * athena_rate_per_tb),
    " at $", athena_rate_per_tb, "/TB\n", sep = "")

if (!resume_mode) {
  unload_res <- dbSendQuery(athena_con, unload_sql)
  unload_error <- NULL
  tryCatch(invisible(dbFetch(unload_res)), error = function(e) {
    unload_error <<- conditionMessage(e)
  })
  unload_info <- dbGetInfo(unload_res)
  unload_bytes <- if (is.null(unload_info$Statistics$DataScannedInBytes)) 0 else
    unload_info$Statistics$DataScannedInBytes
  unload_succeeded <- identical(unload_info$Status, "SUCCEEDED")
  ledger <- rbind(ledger, data.frame(
    query_id = unload_info$QueryExecutionId,
    purpose = "extract refreshed-union education history and provenance",
    status = unload_info$Status, estimated_bytes = 89823300000,
    actual_bytes = unload_bytes,
    estimated_cost_usd = unload_bytes / 1e12 * athena_rate_per_tb,
    disposition = if (unload_succeeded) "accepted" else "failed",
    stringsAsFactors = FALSE))
  write.csv(ledger, ledger_path, row.names = FALSE)
  dbClearResult(unload_res)
  if (!unload_succeeded) {
    stop("The approved UNLOAD failed. It was recorded and will not be retried: ",
         unload_error)
  }
  if (!is.null(unload_error)) {
    cat("  [note] Athena SUCCEEDED; ignored client result-file lookup: ",
        unload_error, "\n", sep = "")
  }
} else {
  query_json_lines <- system2(
    "aws", c("athena", "get-query-execution", "--query-execution-id",
             resume_query_id, "--region", s3_region, "--output", "json"),
    stdout = TRUE, stderr = TRUE)
  query_json_status <- attr(query_json_lines, "status")
  if (!is.null(query_json_status) && query_json_status != 0) {
    stop("Could not retrieve the resume query metadata: ",
         paste(query_json_lines, collapse = "\n"))
  }
  query_meta <- jsonlite::fromJSON(paste(query_json_lines, collapse = "\n"))
  query_execution <- query_meta$QueryExecution
  unload_bytes <- query_execution$Statistics$DataScannedInBytes
  if (!identical(query_execution$Status$State, "SUCCEEDED")) {
    stop("Resume query is not successful: ", query_execution$Status$State)
  }
  ledger_row <- ledger$query_id == resume_query_id
  if (sum(ledger_row) != 1 || ledger$actual_bytes[ledger_row] != unload_bytes) {
    stop("Resume query metadata does not reconcile with the scan ledger.")
  }
  ledger$status[ledger_row] <- "SUCCEEDED"
  ledger$disposition[ledger_row] <- "accepted"
  ledger$estimated_cost_usd[ledger_row] <-
    unload_bytes / 1e12 * athena_rate_per_tb
  write.csv(ledger, ledger_path, row.names = FALSE)
  cat("  [resume] accepted successful UNLOAD ", resume_query_id,
      " without rerunning it\n", sep = "")
}
if (sum(ledger$actual_bytes) > scan_budget_bytes) {
  stop("Actual scan exceeded the approved 92 GB cap; output is not accepted.")
}

education_res <- dbSendQuery(athena_con, education_ddl)
education_ddl_error <- NULL
tryCatch(invisible(dbFetch(education_res)), error = function(e) {
  education_ddl_error <<- conditionMessage(e)
})
education_info <- dbGetInfo(education_res)
education_ddl_bytes <- if (is.null(
  education_info$Statistics$DataScannedInBytes)) 0 else
  education_info$Statistics$DataScannedInBytes
ledger <- rbind(ledger, data.frame(
  query_id = education_info$QueryExecutionId,
  purpose = "register refreshed education output",
  status = education_info$Status, estimated_bytes = 0,
  actual_bytes = education_ddl_bytes, estimated_cost_usd = 0,
  disposition = if (is.null(education_ddl_error)) "accepted" else "failed",
  stringsAsFactors = FALSE))
write.csv(ledger, ledger_path, row.names = FALSE)
dbClearResult(education_res)
if (!is.null(education_ddl_error)) {
  stop("Education DDL failed after the successful UNLOAD: ", education_ddl_error)
}
if (education_ddl_bytes != 0) stop("Education DDL unexpectedly scanned data.")

####################################################################
### Download once; validate and sample locally
####################################################################

download_dir <- tempfile(
  pattern = "obmep_candidates_step_1_degree_duration_education_download_",
  tmpdir = cohort_dir)
dir.create(download_dir)
cat("\nDownloading education parquet parts...\n")
download_status <- system2(
  "aws", c("s3", "sync", education_s3_path, shQuote(download_dir),
           "--region", s3_region, "--only-show-errors"))
if (download_status != 0) {
  stop("AWS CLI download failed; partial files remain at ", download_dir)
}
download_files <- list.files(download_dir, full.names = TRUE)
if (!length(download_files) || any(file.info(download_files)$size == 0)) {
  stop("Downloaded education dataset is empty or contains an empty part: ",
       download_dir)
}
if (!file.rename(download_dir, education_dir)) {
  stop("Could not promote the validated download directory to ", education_dir)
}

education_glob <- gsub(
  "'", "''", file.path(education_dir, "*"), fixed = TRUE)
dbExecute(local_con, sprintf(
  "CREATE VIEW refreshed_union AS SELECT * FROM read_parquet('%s')",
  union_sql_path))
dbExecute(local_con, sprintf(
  "CREATE VIEW education AS SELECT * FROM read_parquet('%s')",
  education_glob))

education_validation <- dbGetQuery(local_con,
  "WITH education_users AS (SELECT DISTINCT user_id FROM education)
   SELECT (SELECT count(*) FROM education) AS education_rows,
          (SELECT count(*) FROM education_users) AS education_users,
          (SELECT count(*) FROM education e LEFT JOIN refreshed_union u
             ON e.user_id = u.user_id WHERE u.user_id IS NULL) AS outside_rows,
          (SELECT count(*) FROM refreshed_union u LEFT JOIN education_users e
             ON u.user_id = e.user_id WHERE e.user_id IS NULL) AS missing_users,
          (SELECT count_if(user_id IS NULL) FROM education) AS null_users,
          (SELECT count_if(degree_matches_laxed NOT IN (0, 1))
             FROM education) AS bad_laxed_flag,
          (SELECT count_if(degree_match_route NOT IN
             ('ranked_regex', 'duration_fallback', 'not_qualifying'))
             FROM education) AS bad_route")
print(education_validation)
stopifnot(
  education_validation$education_users == expected_union,
  education_validation$outside_rows == 0,
  education_validation$missing_users == 0,
  education_validation$null_users == 0,
  education_validation$bad_laxed_flag == 0,
  education_validation$bad_route == 0)

# DuckDB compatibility shim for the shared Trino expressions.
dbExecute(local_con,
  "CREATE OR REPLACE MACRO regexp_like(s, p) AS regexp_matches(s, p)")
classifier_validation <- dbGetQuery(local_con, sprintf(
  "WITH base AS (
     SELECT *, lower(trim(coalesce(degree_raw, ''))) AS dr,
            CAST(year(startdate) AS integer) AS start_year,
            CAST(year(enddate) AS integer) AS end_year
     FROM education
   ),
   recomputed AS (
     SELECT *, (%1$s) AS expected_level, (%2$s) AS expected_residual
     FROM base
   ),
   scored AS (
     SELECT *, expected_level = 'bachelor' AS expected_ranked,
            expected_residual
              AND startdate IS NOT NULL AND enddate IS NOT NULL
              AND end_year - start_year IN (3, 4, 5, 6)
              AS expected_duration
     FROM recomputed
   )
   SELECT count_if(ranked_level <> expected_level) AS bad_level,
          count_if(degree_residual_other <>
                   CAST(expected_residual AS integer)) AS bad_residual,
          count_if(degree_match_ranked <>
                   CAST(expected_ranked AS integer)) AS bad_ranked,
          count_if(degree_match_duration <>
                   CAST(expected_duration AS integer)) AS bad_duration,
          count_if(degree_matches_laxed <>
                   CAST(expected_ranked OR expected_duration AS integer))
            AS bad_laxed,
          count_if(degree_match_route <>
                   CASE WHEN expected_ranked THEN 'ranked_regex'
                        WHEN expected_duration THEN 'duration_fallback'
                        ELSE 'not_qualifying' END) AS bad_route,
          count_if(degree_match_duration = 1 AND
                   (degree_residual_other <> 1 OR
                    degree_duration_years NOT IN (3, 4, 5, 6)))
            AS bad_duration_boundary
   FROM scored", sql_ranked_level, sql_is_residual_other))
print(classifier_validation)
stopifnot(all(unlist(classifier_validation) == 0))

route_counts <- dbGetQuery(local_con,
  "SELECT degree_match_route, count(*) AS education_rows,
          count(DISTINCT user_id) AS users
   FROM education GROUP BY 1 ORDER BY 1")
print(route_counts)
if (!all(c("ranked_regex", "duration_fallback") %in%
         route_counts$degree_match_route)) {
  stop("Both qualifying sample strata must be non-empty.")
}

sample_sql_path <- gsub("'", "''", sample_path, fixed = TRUE)
dbExecute(local_con, sprintf(
  "COPY (
     WITH qualifying AS (
       SELECT DISTINCT * FROM education
       WHERE degree_match_route IN ('ranked_regex', 'duration_fallback')
     ),
     ranked AS (
       SELECT *, row_number() OVER (
         PARTITION BY degree_match_route
         ORDER BY hash(%1$d, user_id, university_raw, university_name, rsid,
                       degree_raw, degree, field_raw, field,
                       university_country, description, startdate, enddate))
         AS sample_rank
       FROM qualifying
     )
     SELECT %1$d AS sample_seed,
            degree_match_route AS sample_stratum,
            sample_rank,
            * EXCLUDE (sample_rank)
     FROM ranked
     WHERE sample_rank <= 50
     ORDER BY sample_stratum, sample_rank
   ) TO '%2$s' (HEADER, DELIMITER ',')",
  sample_seed, sample_sql_path))

sample_validation <- dbGetQuery(local_con, sprintf(
  "SELECT count(*) AS n_rows,
          count_if(degree_matches_laxed <> 1) AS nonmatches,
          count_if(sample_stratum = 'ranked_regex') AS ranked_rows,
          count_if(sample_stratum = 'duration_fallback') AS duration_rows,
          count(DISTINCT hash(user_id, university_raw, university_name, rsid,
                              degree_raw, degree, field_raw, field,
                              university_country, description,
                              startdate, enddate)) AS distinct_entries
   FROM read_csv_auto('%s', header = true)", sample_sql_path))
print(sample_validation)
stopifnot(
  sample_validation$n_rows == 100,
  sample_validation$nonmatches == 0,
  sample_validation$ranked_rows == 50,
  sample_validation$duration_rows == 50,
  sample_validation$distinct_entries == 100)

####################################################################
### Protected-output and final reconciliation checks
####################################################################

canonical_union_md5_after <- unname(tools::md5sum(canonical_union_path))
canonical_files_after <- file.info(sort(list.files(
  canonical_education_dir, recursive = TRUE, full.names = TRUE)))
canonical_manifest_after <- data.frame(
  path = rownames(canonical_files_after),
  size = canonical_files_after$size,
  mtime = as.numeric(canonical_files_after$mtime),
  stringsAsFactors = FALSE)
canonical_unchanged <- identical(
  canonical_union_md5_before, canonical_union_md5_after) &&
  identical(canonical_manifest_before, canonical_manifest_after)
if (!canonical_unchanged) {
  stop("A protected canonical union or education artifact changed.")
}

report <- list(
  generated_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
  population = list(
    country_cohort_users = expected_country,
    name_cohort_users = expected_name,
    refreshed_union_users = expected_union,
    country_only = expected_country_only,
    both = expected_both,
    name_only = expected_name_only),
  current_comparison = comparison,
  education = list(
    local_directory = education_dir,
    s3_prefix = education_s3_path,
    athena_table = paste0(athena_schema, ".", education_table),
    parquet_parts = length(download_files),
    parquet_bytes = sum(file.info(list.files(
      education_dir, full.names = TRUE))$size),
    validation = education_validation,
    classifier_validation = classifier_validation,
    route_counts = route_counts),
  sample = list(
    path = sample_path, seed = sample_seed,
    design = "50 ranked_regex plus 50 duration_fallback",
    validation = sample_validation),
  scan = list(
    approved_budget_bytes = scan_budget_bytes,
    actual_bytes = sum(ledger$actual_bytes),
    estimated_cost_usd = sum(ledger$actual_bytes) / 1e12 * athena_rate_per_tb,
    rate_per_tb_usd = athena_rate_per_tb,
    ledger = ledger_path,
    resumed_successful_unload_query_id = if (resume_mode)
      resume_query_id else NA_character_),
  outputs = list(
    refreshed_union_local = union_path,
    refreshed_union_s3 = union_s3_path,
    refreshed_union_table = paste0(athena_schema, ".", union_table)),
  protected_canonical_outputs_unchanged = canonical_unchanged)
jsonlite::write_json(
  report, report_path, pretty = TRUE, auto_unbox = TRUE,
  dataframe = "rows", na = "null", digits = NA)

cat("\n=========== COMPLETE ===========\n")
cat("  refreshed union    :", union_path, "\n")
cat("  education directory:", education_dir, "\n")
cat("  education rows     :",
    format(education_validation$education_rows, big.mark = ","), "\n")
cat("  sample             :", sample_path, "\n")
cat("  report             :", report_path, "\n")
cat("  scan ledger        :", ledger_path, "\n")
cat("  actual scan        :", format(sum(ledger$actual_bytes), big.mark = ","),
    "bytes\n")
cat("  estimated cost     : $",
    sprintf("%.4f", sum(ledger$actual_bytes) / 1e12 * athena_rate_per_tb),
    "\n", sep = "")
cat("[OK] refreshed union education downloaded, validated and sampled\n")
