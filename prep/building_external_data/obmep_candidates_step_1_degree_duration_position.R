####################################################################
###
### Complete position history for the refreshed duration cohort
###
### LOCAL, ONLINE PIPELINE. This script executes one metered Athena
### UNLOAD from academic_individual_position, writes Snappy parquet to
### S3, registers an external table, and downloads the parts to Dropbox.
### It must not be run in SEDAP.
###
### The output is the 28-column union of the established step-1
### position and position-role/location extracts. The canonical
### position products and the refreshed education history are inputs
### protected from modification, never outputs of this script.
###
### COST-TRACKER BARRIER
### --------------------
### A new run stops after the single raw-table UNLOAD. Refresh the
### private AWS Monthly Costs 2026 YTD Sheet from complete Athena
### month-to-date metadata, then resume with BOTH variables set to the
### printed query id:
###
###   OBMEP_RESUME_ATHENA_QUERY_ID
###   OBMEP_COST_TRACKER_SYNCED_QUERY_ID
###
### This makes the mandatory cost refresh happen before registration,
### download and validation, and prevents an accidental second scan.
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "aws.s3", "RAthena", "arrow", "duckdb", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(aws.s3)

####################################################################
### Parameters and immutable inputs
####################################################################

obmep_root <- Sys.getenv(
  "OBMEP_ROOT", unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
cohort_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

cohort_path <- file.path(
  cohort_dir, "obmep_candidates_step_1_degree_duration.parquet")
canonical_union_path <- file.path(cohort_dir, "obmep_candidates_step_1.parquet")
canonical_position_dir <- file.path(
  cohort_dir, "obmep_candidates_step_1_position")
canonical_role_loc_dir <- file.path(
  cohort_dir, "obmep_candidates_step_1_position_role_loc")
duration_education_dir <- file.path(
  cohort_dir, "obmep_candidates_step_1_degree_duration_education")

position_dir <- file.path(
  cohort_dir, "obmep_candidates_step_1_degree_duration_position")
report_path <- file.path(
  cohort_dir, "obmep_candidates_step_1_degree_duration_position_report.json")
ledger_path <- file.path(
  cohort_dir, "obmep_candidates_step_1_degree_duration_position_scan_ledger.csv")

expected_users <- 8901904
expected_country_only <- 5122395
expected_both <- 2640319
expected_name_only <- 1139190

estimated_scan_bytes <- 535400000000
scan_budget_bytes <- 560000000000
athena_rate_per_tb <- 5

resume_query_id <- Sys.getenv("OBMEP_RESUME_ATHENA_QUERY_ID", unset = "")
synced_query_id <- Sys.getenv("OBMEP_COST_TRACKER_SYNCED_QUERY_ID", unset = "")
resume_mode <- nzchar(resume_query_id)

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
s3_prefix <- "exports/obmep_candidates_step_1_degree_duration_position"
s3_path <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
cand_table <- "obmep_candidates_step_1_degree_duration"
table <- "obmep_candidates_step_1_degree_duration_position"
src <- "academic_individual_position"

cols <- c(
  "user_id", "position_id", "company_raw", "company_linkedin_url",
  "company_cleaned", "title_raw", "title_translated", "description",
  "naics_code", "naics_description", "startdate", "enddate",
  "job_category", "role_k50", "role_k150", "role_k300", "role_k500",
  "role_k1000", "role_k1500", "seniority", "position_number",
  "onet_code", "onet_title", "location_raw", "country", "region",
  "state", "metro_area")

ddl_cols <- c(
  "user_id BIGINT", "position_id BIGINT", "company_raw STRING",
  "company_linkedin_url STRING", "company_cleaned STRING",
  "title_raw STRING", "title_translated STRING", "description STRING",
  "naics_code STRING", "naics_description STRING", "startdate STRING",
  "enddate STRING", "job_category STRING", "role_k50 STRING",
  "role_k150 STRING", "role_k300 STRING", "role_k500 STRING",
  "role_k1000 STRING", "role_k1500 STRING", "seniority SMALLINT",
  "position_number SMALLINT", "onet_code STRING", "onet_title STRING",
  "location_raw STRING", "country STRING", "region STRING", "state STRING",
  "metro_area STRING")

expected_source_types <- c(
  user_id = "bigint", position_id = "bigint", company_raw = "string",
  company_linkedin_url = "string", company_cleaned = "string",
  title_raw = "string", title_translated = "string", description = "string",
  naics_code = "string", naics_description = "string", startdate = "string",
  enddate = "string", job_category = "string", role_k50 = "string",
  role_k150 = "string", role_k300 = "string", role_k500 = "string",
  role_k1000 = "string", role_k1500 = "string", seniority = "smallint",
  position_number = "smallint", onet_code = "string", onet_title = "string",
  location_raw = "string", country = "string", region = "string",
  state = "string", metro_area = "string")

if (!identical(names(expected_source_types), cols)) {
  stop("The source-type map is not in the exact output-column order.")
}
if (length(cols) != 28L || length(ddl_cols) != 28L) {
  stop("The combined position schema must contain exactly 28 columns.")
}

required_inputs <- c(
  cohort_path, canonical_union_path, canonical_position_dir,
  canonical_role_loc_dir, duration_education_dir)
missing_inputs <- required_inputs[!file.exists(required_inputs)]
if (length(missing_inputs)) {
  stop("Missing protected input(s): ", paste(missing_inputs, collapse = ", "))
}
if (Sys.which("aws") == "") stop("The AWS CLI is required.")

output_paths <- c(position_dir, report_path, ledger_path)
if (!resume_mode && any(file.exists(output_paths))) {
  stop("A new run never overwrites output: ",
       paste(output_paths[file.exists(output_paths)], collapse = ", "))
}
if (resume_mode) {
  if (!file.exists(ledger_path)) {
    stop("Resume mode requires the scan ledger: ", ledger_path)
  }
  if (dir.exists(position_dir) || file.exists(report_path)) {
    stop("Resume mode will not overwrite completed downstream output.")
  }
  if (!identical(resume_query_id, synced_query_id)) {
    stop("Resume requires OBMEP_COST_TRACKER_SYNCED_QUERY_ID to equal ",
         "OBMEP_RESUME_ATHENA_QUERY_ID.")
  }
}

py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

####################################################################
### Protected-output manifest and local cohort validation
####################################################################

protected_files <- sort(unique(c(
  canonical_union_path,
  list.files(canonical_position_dir, recursive = TRUE, full.names = TRUE),
  list.files(canonical_role_loc_dir, recursive = TRUE, full.names = TRUE),
  list.files(duration_education_dir, recursive = TRUE, full.names = TRUE))))
protected_info_before <- file.info(protected_files)
protected_manifest_before <- data.frame(
  path = rownames(protected_info_before),
  size = protected_info_before$size,
  mtime = as.numeric(protected_info_before$mtime),
  stringsAsFactors = FALSE)
cohort_md5_before <- unname(tools::md5sum(cohort_path))

local_con <- dbConnect(duckdb::duckdb())
on.exit(try(dbDisconnect(local_con, shutdown = TRUE), silent = TRUE), add = TRUE)
cohort_sql_path <- gsub("'", "''", cohort_path, fixed = TRUE)
dbExecute(local_con, sprintf(
  "CREATE VIEW refreshed_union AS SELECT * FROM read_parquet('%s')",
  cohort_sql_path))

cohort_validation <- dbGetQuery(local_con,
  "SELECT count(*) AS n_rows,
          count(DISTINCT user_id) AS n_users,
          count_if(user_id IS NULL) AS null_users,
          count_if(in_country_cohort = 1 AND in_name_cohort = 0)
            AS country_only,
          count_if(in_country_cohort = 1 AND in_name_cohort = 1) AS both,
          count_if(in_country_cohort = 0 AND in_name_cohort = 1) AS name_only,
          count_if(in_country_cohort NOT IN (0, 1)
                   OR in_name_cohort NOT IN (0, 1)
                   OR in_country_cohort + in_name_cohort = 0) AS bad_flags
   FROM refreshed_union")
print(cohort_validation)
stopifnot(
  cohort_validation$n_rows == expected_users,
  cohort_validation$n_users == expected_users,
  cohort_validation$null_users == 0,
  cohort_validation$country_only == expected_country_only,
  cohort_validation$both == expected_both,
  cohort_validation$name_only == expected_name_only,
  cohort_validation$bad_flags == 0)

####################################################################
### Zero-scan live catalog and destination preflight
####################################################################

cat("\n=========== ZERO-SCAN PREFLIGHT ===========\n")
source_json_lines <- system2(
  "aws", c("glue", "get-table", "--database-name", athena_schema,
           "--name", src, "--region", s3_region, "--output", "json"),
  stdout = TRUE, stderr = TRUE)
source_json_status <- attr(source_json_lines, "status")
if (!is.null(source_json_status) && source_json_status != 0) {
  stop("Could not inspect the live source schema: ",
       paste(source_json_lines, collapse = "\n"))
}
source_meta <- jsonlite::fromJSON(paste(source_json_lines, collapse = "\n"))
source_columns <- source_meta$Table$StorageDescriptor$Columns
source_types <- setNames(tolower(source_columns$Type), source_columns$Name)
if (!all(cols %in% names(source_types))) {
  stop("Live source is missing requested column(s): ",
       paste(setdiff(cols, names(source_types)), collapse = ", "))
}
if (!identical(unname(source_types[cols]), unname(expected_source_types))) {
  bad <- cols[source_types[cols] != expected_source_types]
  stop("Live source type mismatch for: ", paste(bad, collapse = ", "))
}
cat("  live source schema has all 28 columns with exact types\n")

cohort_json_lines <- system2(
  "aws", c("glue", "get-table", "--database-name", athena_schema,
           "--name", cand_table, "--region", s3_region, "--output", "json"),
  stdout = TRUE, stderr = TRUE)
cohort_json_status <- attr(cohort_json_lines, "status")
if (!is.null(cohort_json_status) && cohort_json_status != 0) {
  stop("Could not inspect the refreshed-union table: ",
       paste(cohort_json_lines, collapse = "\n"))
}
cohort_meta <- jsonlite::fromJSON(paste(cohort_json_lines, collapse = "\n"))
live_cohort_cols <- cohort_meta$Table$StorageDescriptor$Columns
if (!identical(live_cohort_cols$Name,
               c("user_id", "in_country_cohort", "in_name_cohort"))) {
  stop("The live refreshed-union schema is not the expected narrow table.")
}

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

existing <- get_bucket(
  bucket = s3_bucket, prefix = paste0(s3_prefix, "/"),
  region = s3_region, max = 100)
if (!resume_mode) {
  if (length(existing)) stop("The destination S3 prefix is not empty: ", s3_path)
  if (table %in% tables) stop("The destination Athena table already exists.")
  cat("  local, S3 and Athena destinations are unused\n")
} else {
  if (!length(existing) ||
      any(vapply(existing, function(x) as.numeric(x$Size), 0) == 0)) {
    stop("Resume mode requires nonempty UNLOAD parts in ", s3_path)
  }
  if (table %in% tables) {
    stop("Resume mode expected the output table not to be registered yet.")
  }
  cat("  resume found ", length(existing), " nonempty UNLOAD parts\n", sep = "")
}

####################################################################
### The single approved raw-table query and exact output DDL
####################################################################

select_sql <- sprintf(
  "SELECT p.%s
   FROM %s.%s p
   WHERE p.user_id IN (SELECT user_id FROM %s.%s)",
  paste(cols, collapse = ",\n          p."),
  athena_schema, src, athena_schema, cand_table)

unload_sql <- sprintf(
  "UNLOAD (%s)
   TO '%s'
   WITH (format = 'PARQUET', compression = 'SNAPPY')",
  select_sql, s3_path)

ddl_txt <- sprintf(
  "CREATE EXTERNAL TABLE %s.%s (
     %s
   )
   STORED AS PARQUET
   LOCATION '%s'",
  athena_schema, table, paste(ddl_cols, collapse = ",\n     "), s3_path)

cat("\n=========== APPROVED ATHENA UNLOAD ===========\n")
cat("  purpose       : complete 28-column refreshed-union position history\n")
cat("  estimated scan:", format(estimated_scan_bytes, big.mark = ","), "bytes\n")
cat("  approved cap  :", format(scan_budget_bytes, big.mark = ","), "bytes\n")
cat("  estimated cost: $",
    sprintf("%.3f", estimated_scan_bytes / 1e12 * athena_rate_per_tb),
    " at $", athena_rate_per_tb, "/TB\n", sep = "")

athena_con <- dbConnect(
  RAthena::athena(), s3_staging_dir = paste0("s3://", s3_bucket, "/"),
  region_name = s3_region, schema_name = athena_schema)
on.exit(try(dbDisconnect(athena_con), silent = TRUE), add = TRUE)

if (!resume_mode) {
  ledger <- data.frame(
    query_id = character(), purpose = character(), status = character(),
    estimated_bytes = numeric(), actual_bytes = numeric(),
    estimated_cost_usd = numeric(), disposition = character(),
    stringsAsFactors = FALSE)

  unload_res <- dbSendQuery(athena_con, unload_sql)
  unload_error <- NULL
  tryCatch(invisible(dbFetch(unload_res)), error = function(e) {
    unload_error <<- conditionMessage(e)
  })
  unload_info <- dbGetInfo(unload_res)
  unload_bytes <- if (is.null(unload_info$Statistics$DataScannedInBytes)) 0 else
    as.numeric(unload_info$Statistics$DataScannedInBytes)
  unload_succeeded <- identical(unload_info$Status, "SUCCEEDED")
  ledger <- rbind(ledger, data.frame(
    query_id = unload_info$QueryExecutionId,
    purpose = "extract refreshed-union 28-column position history",
    status = unload_info$Status, estimated_bytes = estimated_scan_bytes,
    actual_bytes = unload_bytes,
    estimated_cost_usd = unload_bytes / 1e12 * athena_rate_per_tb,
    disposition = if (unload_succeeded) "provisional" else "failed",
    stringsAsFactors = FALSE))
  write.csv(ledger, ledger_path, row.names = FALSE)
  dbClearResult(unload_res)

  cat("  query id      : ", unload_info$QueryExecutionId, "\n", sep = "")
  cat("  status        : ", unload_info$Status, "\n", sep = "")
  cat("  actual scan   : ", format(unload_bytes, big.mark = ","), " bytes\n",
      sep = "")
  if (!is.null(unload_error) && unload_succeeded) {
    cat("  [note] Athena succeeded; ignored client result-file lookup: ",
        unload_error, "\n", sep = "")
  }
  if (!unload_succeeded) {
    stop("The approved UNLOAD failed. It was recorded and will not be retried: ",
         unload_error)
  }
  if (unload_bytes > scan_budget_bytes) {
    stop("The UNLOAD exceeded the approved 560 GB cap. Refresh the cost tracker ",
         "for query ", unload_info$QueryExecutionId,
         "; do not resume or accept this output without new authorization.")
  }

  cat("\n[PAUSED] Refresh AWS Monthly Costs 2026 YTD for query ",
      unload_info$QueryExecutionId, ", then resume with:\n", sep = "")
  cat("  $env:OBMEP_RESUME_ATHENA_QUERY_ID='",
      unload_info$QueryExecutionId, "'\n", sep = "")
  cat("  $env:OBMEP_COST_TRACKER_SYNCED_QUERY_ID='",
      unload_info$QueryExecutionId, "'\n", sep = "")
  quit(save = "no", status = 0)
}

####################################################################
### Resume only after the mandatory cost-sheet refresh
####################################################################

ledger <- read.csv(ledger_path, stringsAsFactors = FALSE)
ledger_row <- ledger$query_id == resume_query_id
if (sum(ledger_row) != 1) {
  stop("Resume query id does not identify exactly one scan-ledger row.")
}

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
unload_bytes <- as.numeric(query_execution$Statistics$DataScannedInBytes)
if (!identical(query_execution$Status$State, "SUCCEEDED")) {
  stop("Resume query is not successful: ", query_execution$Status$State)
}
if (!identical(query_execution$WorkGroup, "primary")) {
  stop("Resume query did not run in workgroup primary.")
}
if (ledger$actual_bytes[ledger_row] != unload_bytes) {
  stop("Resume query metadata does not reconcile with the scan ledger.")
}
if (unload_bytes > scan_budget_bytes) {
  stop("The successful query exceeded the approved scan budget and cannot be accepted.")
}
ledger$status[ledger_row] <- "SUCCEEDED"
ledger$disposition[ledger_row] <- "accepted"
ledger$estimated_cost_usd[ledger_row] <-
  unload_bytes / 1e12 * athena_rate_per_tb
write.csv(ledger, ledger_path, row.names = FALSE)
cat("  [resume] accepted successful UNLOAD ", resume_query_id,
    " after cost-tracker synchronization\n", sep = "")

ddl_res <- dbSendQuery(athena_con, ddl_txt)
ddl_error <- NULL
tryCatch(invisible(dbFetch(ddl_res)), error = function(e) {
  ddl_error <<- conditionMessage(e)
})
ddl_info <- dbGetInfo(ddl_res)
ddl_bytes <- if (is.null(ddl_info$Statistics$DataScannedInBytes)) 0 else
  as.numeric(ddl_info$Statistics$DataScannedInBytes)
ledger <- rbind(ledger, data.frame(
  query_id = ddl_info$QueryExecutionId,
  purpose = "register refreshed-union position output",
  status = ddl_info$Status, estimated_bytes = 0,
  actual_bytes = ddl_bytes,
  estimated_cost_usd = ddl_bytes / 1e12 * athena_rate_per_tb,
  disposition = if (identical(ddl_info$Status, "SUCCEEDED"))
    "accepted" else "failed",
  stringsAsFactors = FALSE))
write.csv(ledger, ledger_path, row.names = FALSE)
dbClearResult(ddl_res)
if (!identical(ddl_info$Status, "SUCCEEDED")) {
  stop("Output-table DDL failed: ", ddl_error)
}
if (ddl_bytes != 0) stop("Output-table DDL unexpectedly scanned data.")

####################################################################
### Download once and validate locally before promotion
####################################################################

download_dir <- tempfile(
  pattern = "obmep_candidates_step_1_degree_duration_position_download_",
  tmpdir = cohort_dir)
dir.create(download_dir)
cat("\nDownloading position parquet parts...\n")
download_status <- system2(
  "aws", c("s3", "sync", s3_path, shQuote(download_dir),
           "--region", s3_region, "--only-show-errors"))
if (download_status != 0) {
  stop("AWS CLI download failed; partial files remain at ", download_dir)
}
download_files <- list.files(download_dir, full.names = TRUE)
if (!length(download_files) || any(file.info(download_files)$size == 0)) {
  stop("Downloaded position dataset is empty or contains an empty part: ",
       download_dir)
}

position_glob <- gsub("'", "''", file.path(download_dir, "*"), fixed = TRUE)
dbExecute(local_con, sprintf(
  "CREATE VIEW position_history AS SELECT * FROM read_parquet('%s')",
  position_glob))

schema_validation <- dbGetQuery(local_con, "DESCRIBE position_history")
expected_duckdb_types <- c(
  "BIGINT", "BIGINT", rep("VARCHAR", 17), "SMALLINT", "SMALLINT",
  rep("VARCHAR", 7))
if (!identical(schema_validation$column_name, cols)) {
  stop("Downloaded column names/order do not match the 28-column contract.")
}
if (!identical(schema_validation$column_type, expected_duckdb_types)) {
  stop("Downloaded column types do not match the 28-column contract.")
}

position_validation <- dbGetQuery(local_con,
  "WITH position_users AS (
     SELECT DISTINCT user_id FROM position_history
   )
   SELECT (SELECT count(*) FROM position_history) AS position_rows,
          (SELECT count(*) FROM position_users) AS position_users,
          (SELECT count(DISTINCT position_id) FROM position_history)
            AS distinct_positions,
          (SELECT count_if(user_id IS NULL) FROM position_history)
            AS null_users,
          (SELECT count_if(position_id IS NULL) FROM position_history)
            AS null_positions,
          (SELECT count(*) FROM position_history p
             LEFT JOIN refreshed_union c ON p.user_id = c.user_id
             WHERE c.user_id IS NULL) AS outside_rows,
          (SELECT count(*) FROM refreshed_union c
             LEFT JOIN position_users p ON c.user_id = p.user_id
             WHERE p.user_id IS NULL) AS missing_users")
print(position_validation)
stopifnot(
  position_validation$position_rows > 0,
  position_validation$position_users == expected_users,
  position_validation$distinct_positions == position_validation$position_rows,
  position_validation$null_users == 0,
  position_validation$null_positions == 0,
  position_validation$outside_rows == 0,
  position_validation$missing_users == 0)

membership_routes <- dbGetQuery(local_con,
  "WITH position_users AS (SELECT DISTINCT user_id FROM position_history)
   SELECT c.in_country_cohort, c.in_name_cohort, count(*) AS users
   FROM refreshed_union c
   JOIN position_users p ON c.user_id = p.user_id
   GROUP BY 1, 2 ORDER BY 1, 2")
print(membership_routes)

geography <- dbGetQuery(local_con,
  "SELECT count_if(country = 'Brazil') AS brazil_positions,
          count(DISTINCT CASE WHEN country = 'Brazil' THEN user_id END)
            AS brazil_users,
          count_if(country = 'empty') AS missing_country,
          count_if(region = 'empty') AS missing_region,
          count_if(state = 'empty') AS missing_state,
          count_if(metro_area = 'empty') AS missing_metro_area
   FROM position_history")
print(geography)

fill_cols <- c(
  "job_category", "role_k50", "role_k150", "role_k300", "role_k500",
  "role_k1000", "role_k1500", "seniority", "position_number", "onet_code",
  "onet_title", "location_raw", "country", "region", "state", "metro_area")
sentinel_cols <- c("country", "region", "state", "metro_area")
missing_expr <- ifelse(
  fill_cols %in% sentinel_cols,
  sprintf("(%1$s IS NULL OR %1$s = 'empty')", fill_cols),
  sprintf("%s IS NULL", fill_cols))
fill_sql <- paste(sprintf(
  "count_if(NOT %2$s) AS filled_%1$s,
   count(DISTINCT CASE WHEN NOT %2$s THEN %1$s END) AS distinct_%1$s",
  fill_cols, missing_expr), collapse = ",\n       ")
fill_rates <- dbGetQuery(local_con, sprintf(
  "SELECT %s FROM position_history", fill_sql))

if (!file.rename(download_dir, position_dir)) {
  stop("Could not promote the validated download directory to ", position_dir)
}

####################################################################
### Protected-output reconciliation, report and handoff
####################################################################

protected_info_after <- file.info(protected_files)
protected_manifest_after <- data.frame(
  path = rownames(protected_info_after),
  size = protected_info_after$size,
  mtime = as.numeric(protected_info_after$mtime),
  stringsAsFactors = FALSE)
cohort_md5_after <- unname(tools::md5sum(cohort_path))
protected_unchanged <- identical(
  protected_manifest_before, protected_manifest_after) &&
  identical(cohort_md5_before, cohort_md5_after)
if (!protected_unchanged) {
  stop("A protected canonical or refreshed-education artifact changed.")
}

position_files <- list.files(position_dir, full.names = TRUE)
position_bytes <- sum(file.info(position_files)$size)
total_scan_bytes <- sum(ledger$actual_bytes)

report <- list(
  generated_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
  population = list(
    refreshed_union_users = expected_users,
    country_only = expected_country_only,
    both = expected_both,
    name_only = expected_name_only,
    validation = cohort_validation),
  position = list(
    local_directory = position_dir,
    s3_prefix = s3_path,
    athena_table = paste0(athena_schema, ".", table),
    parquet_parts = length(position_files),
    parquet_bytes = position_bytes,
    columns = cols,
    validation = position_validation,
    membership_routes = membership_routes,
    geography = geography,
    fill_rates = fill_rates),
  scan = list(
    approved_budget_bytes = scan_budget_bytes,
    estimated_bytes = estimated_scan_bytes,
    actual_bytes = total_scan_bytes,
    estimated_cost_usd = total_scan_bytes / 1e12 * athena_rate_per_tb,
    rate_per_tb_usd = athena_rate_per_tb,
    variance_from_budget_bytes = scan_budget_bytes - total_scan_bytes,
    ledger = ledger_path,
    accepted_unload_query_id = resume_query_id,
    cost_tracker_synced_query_id = synced_query_id),
  protected_outputs_unchanged = protected_unchanged)
jsonlite::write_json(
  report, report_path, pretty = TRUE, auto_unbox = TRUE,
  dataframe = "rows", na = "null", digits = NA)

cat("\n=========== COMPLETE ===========\n")
cat("  position directory:", position_dir, "\n")
cat("  position rows     :",
    format(position_validation$position_rows, big.mark = ","), "\n")
cat("  position users    :",
    format(position_validation$position_users, big.mark = ","), "\n")
cat("  parquet parts     :", length(position_files), "\n")
cat("  parquet bytes     :", format(position_bytes, big.mark = ","), "\n")
cat("  report            :", report_path, "\n")
cat("  scan ledger       :", ledger_path, "\n")
cat("  actual scan       :", format(total_scan_bytes, big.mark = ","),
    "bytes\n")
cat("  estimated cost    : $",
    sprintf("%.4f", total_scan_bytes / 1e12 * athena_rate_per_tb),
    "\n", sep = "")
cat("[OK] refreshed-union position history downloaded and validated\n")
