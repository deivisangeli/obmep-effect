####################################################################
### Revelio company RCIDs for the refreshed degree-duration cohort
###
### LOCAL, ONLINE PIPELINE. This performs one metered Athena UNLOAD,
### registers its S3 output, and downloads the four-column parquet
### companion to Dropbox. It must never be sent to SEDAP.
###
### The script pauses after the UNLOAD. Refresh the monthly AWS cost
### tracker, then resume with the printed query-id variables. No
### validation query rescans Athena; all grain checks run locally.
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "aws.s3", "RAthena", "arrow", "duckdb", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) stop("Missing package: ", p)
}
library(DBI)
library(aws.s3)

root <- Sys.getenv("OBMEP_ROOT",
                   unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh <- file.path(root, "Data/intermediate/revelio_br_cohort")
cohort_path <- file.path(coh, "obmep_candidates_step_1_degree_duration.parquet")
position_dir <- file.path(coh, "obmep_candidates_step_1_degree_duration_position")
out_dir <- file.path(coh, "obmep_candidates_step_1_degree_duration_position_rcid")
report_path <- file.path(
  coh, "obmep_candidates_step_1_degree_duration_position_rcid_report.json")
ledger_path <- file.path(
  coh, "obmep_candidates_step_1_degree_duration_position_rcid_scan_ledger.csv")

expected_rows <- 37984489
expected_users <- 8901904
estimated_scan <- 40434077394
query_cap <- 45700000000
aggregate_budget <- 47000000000
rate_per_tb <- 5
approved_budget <- suppressWarnings(as.numeric(Sys.getenv(
  "OBMEP_DD_FIRMS_APPROVED_BUDGET_BYTES", unset = "0")))

resume_query_id <- Sys.getenv("OBMEP_RESUME_ATHENA_QUERY_ID", unset = "")
synced_query_id <- Sys.getenv("OBMEP_COST_TRACKER_SYNCED_QUERY_ID", unset = "")
resume_mode <- nzchar(resume_query_id)

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
s3_prefix <- "exports/obmep_candidates_step_1_degree_duration_position_rcid"
s3_path <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")
athena_schema <- "revelio_database"
cand_table <- "obmep_candidates_step_1_degree_duration"
table <- "obmep_candidates_step_1_degree_duration_position_rcid"
src <- "academic_individual_position"
cols <- c("user_id", "position_id", "rcid", "ultimate_parent_rcid")
ddl_cols <- c("user_id BIGINT", "position_id BIGINT", "rcid BIGINT",
              "ultimate_parent_rcid BIGINT")

required <- c(cohort_path, position_dir)
if (!all(file.exists(required))) {
  stop("Missing input(s): ", paste(required[!file.exists(required)], collapse = ", "))
}
if (Sys.which("aws") == "") stop("The AWS CLI is required.")

py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

output_paths <- c(out_dir, report_path, ledger_path)
if (!resume_mode && any(file.exists(output_paths))) {
  stop("A new run never overwrites output: ",
       paste(output_paths[file.exists(output_paths)], collapse = ", "))
}
if (resume_mode) {
  if (!file.exists(ledger_path)) stop("Resume requires ", ledger_path)
  if (dir.exists(out_dir) || file.exists(report_path)) {
    stop("Resume will not overwrite completed local output.")
  }
  if (!identical(resume_query_id, synced_query_id)) {
    stop("Resume query id must equal the cost-tracker synchronized query id.")
  }
}

local <- dbConnect(duckdb::duckdb())
on.exit(try(dbDisconnect(local, shutdown = TRUE), silent = TRUE), add = TRUE)
fw <- function(p) gsub("\\\\", "/", p)
dbExecute(local, sprintf("CREATE VIEW cohort AS SELECT * FROM read_parquet('%s')",
                         fw(cohort_path)))
dbExecute(local, sprintf("CREATE VIEW positions AS SELECT * FROM read_parquet('%s/*')",
                         fw(position_dir)))
local_preflight <- dbGetQuery(local, "
 SELECT (SELECT count(*) FROM cohort) cohort_rows,
        (SELECT count(DISTINCT user_id) FROM cohort) cohort_users,
        (SELECT count(*) FROM positions) position_rows,
        (SELECT count(DISTINCT position_id) FROM positions) position_ids,
        (SELECT count(DISTINCT user_id) FROM positions) position_users")
print(local_preflight, row.names = FALSE)
if (local_preflight$cohort_rows != expected_users ||
    local_preflight$cohort_users != expected_users ||
    local_preflight$position_rows != expected_rows ||
    local_preflight$position_ids != expected_rows ||
    local_preflight$position_users != expected_users) {
  stop("The refreshed cohort or position history changed from its validated grain.")
}

protected_files <- c(cohort_path, sort(list.files(position_dir, full.names = TRUE)))
protected_before <- file.info(protected_files)[, c("size", "mtime"), drop = FALSE]
cohort_md5_before <- unname(tools::md5sum(cohort_path))

cat("=========== ZERO-SCAN PREFLIGHT ===========\n")
source_lines <- system2(
  "aws", c("glue", "get-table", "--database-name", athena_schema,
           "--name", src, "--region", s3_region, "--output", "json"),
  stdout = TRUE, stderr = TRUE)
if (!is.null(attr(source_lines, "status")) && attr(source_lines, "status") != 0) {
  stop("Could not inspect source schema: ", paste(source_lines, collapse = "\n"))
}
source <- jsonlite::fromJSON(paste(source_lines, collapse = "\n"))
live <- setNames(tolower(source$Table$StorageDescriptor$Columns$Type),
                 source$Table$StorageDescriptor$Columns$Name)
expected_types <- c(user_id = "bigint", position_id = "bigint", rcid = "bigint",
                    ultimate_parent_rcid = "bigint")
if (!all(cols %in% names(live)) ||
    !identical(unname(live[cols]), unname(expected_types))) {
  stop("academic_individual_position schema drifted from the four-column contract.")
}

cand_lines <- system2(
  "aws", c("glue", "get-table", "--database-name", athena_schema,
           "--name", cand_table, "--region", s3_region, "--output", "json"),
  stdout = TRUE, stderr = TRUE)
if (!is.null(attr(cand_lines, "status")) && attr(cand_lines, "status") != 0) {
  stop("Could not inspect refreshed cohort table: ", paste(cand_lines, collapse = "\n"))
}
cand <- jsonlite::fromJSON(paste(cand_lines, collapse = "\n"))
if (!"user_id" %in% cand$Table$StorageDescriptor$Columns$Name) {
  stop("The refreshed Athena cohort has no user_id.")
}

tables_lines <- system2(
  "aws", c("glue", "get-tables", "--database-name", athena_schema,
           "--region", s3_region, "--query", "TableList[].Name", "--output", "json"),
  stdout = TRUE, stderr = TRUE)
tables <- unlist(jsonlite::fromJSON(paste(tables_lines, collapse = "\n")))
existing <- get_bucket(bucket = s3_bucket, prefix = paste0(s3_prefix, "/"),
                       region = s3_region, max = 100)
if (!resume_mode) {
  if (length(existing)) stop("The S3 destination is not empty: ", s3_path)
  if (table %in% tables) stop("The Athena destination table already exists: ", table)
} else {
  if (!length(existing) ||
      any(vapply(existing, function(x) as.numeric(x$Size), numeric(1)) == 0)) {
    stop("Resume requires nonempty UNLOAD parts in ", s3_path)
  }
  if (table %in% tables) stop("Resume expected the table not to be registered yet.")
}

select_sql <- sprintf(
  "SELECT p.%s FROM %s.%s p
   WHERE p.user_id IN (SELECT user_id FROM %s.%s)",
  paste(cols, collapse = ",p."), athena_schema, src, athena_schema, cand_table)
unload_sql <- sprintf(
  "UNLOAD (%s) TO '%s' WITH (format='PARQUET',compression='SNAPPY')",
  select_sql, s3_path)
ddl_sql <- sprintf(
  "CREATE EXTERNAL TABLE %s.%s (%s) STORED AS PARQUET LOCATION '%s'",
  athena_schema, table, paste(ddl_cols, collapse = ","), s3_path)

cat("  query purpose : refreshed-cohort four-column position RCID extract\n")
cat("  estimated scan: ", format(estimated_scan, big.mark = ","), " bytes\n", sep = "")
cat("  query cap     : ", format(query_cap, big.mark = ","), " bytes\n", sep = "")
cat("  aggregate cap : ", format(aggregate_budget, big.mark = ","), " bytes\n", sep = "")
if (!resume_mode && (!is.finite(approved_budget) || approved_budget < aggregate_budget)) {
  stop("Athena scan approval gate is closed. Set ",
       "OBMEP_DD_FIRMS_APPROVED_BUDGET_BYTES to at least ", aggregate_budget,
       " only after explicit approval of the disclosed two-query set.")
}

ath <- dbConnect(RAthena::athena(), s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name = s3_region, schema_name = athena_schema)
on.exit(try(dbDisconnect(ath), silent = TRUE), add = TRUE)
if (!resume_mode) {
  ledger <- data.frame(
    query_id = character(), purpose = character(), status = character(),
    estimated_bytes = numeric(), actual_bytes = numeric(),
    estimated_cost_usd = numeric(), disposition = character())
  res <- dbSendQuery(ath, unload_sql)
  query_error <- NULL
  tryCatch(invisible(dbFetch(res)), error = function(e) query_error <<- conditionMessage(e))
  info <- dbGetInfo(res)
  dbClearResult(res)
  actual <- if (is.null(info$Statistics$DataScannedInBytes)) 0 else
    as.numeric(info$Statistics$DataScannedInBytes)
  succeeded <- identical(info$Status, "SUCCEEDED")
  ledger <- rbind(ledger, data.frame(
    query_id = info$QueryExecutionId,
    purpose = "extract refreshed-cohort position RCIDs",
    status = info$Status, estimated_bytes = estimated_scan, actual_bytes = actual,
    estimated_cost_usd = actual / 1e12 * rate_per_tb,
    disposition = if (succeeded) "provisional" else "failed"))
  write.csv(ledger, ledger_path, row.names = FALSE)
  if (!succeeded) {
    stop("Position RCID UNLOAD failed and will not be retried. Refresh the cost ",
         "tracker for query ", info$QueryExecutionId, " (", actual,
         " bytes): ", query_error)
  }
  if (actual > query_cap) {
    stop("The position RCID query exceeded its approved sub-cap. Sync the cost tracker ",
         "but do not accept the output without revised approval. Query: ",
         info$QueryExecutionId)
  }
  cat("\n[PAUSED] Refresh AWS Monthly Costs 2026 YTD for query ",
      info$QueryExecutionId, " (", format(actual, big.mark = ","), " bytes).\n", sep = "")
  cat("Resume with both query-id variables set to this id.\n")
  quit(save = "no", status = 0)
}

ledger <- read.csv(ledger_path, stringsAsFactors = FALSE)
row <- ledger$query_id == resume_query_id
if (sum(row) != 1) stop("Resume query does not identify one ledger row.")
query_lines <- system2(
  "aws", c("athena", "get-query-execution", "--query-execution-id",
           resume_query_id, "--region", s3_region,
           "--query", "QueryExecution.{State:Status.State,WorkGroup:WorkGroup,DataScannedInBytes:Statistics.DataScannedInBytes}",
           "--output", "json"),
  stdout = TRUE, stderr = TRUE)
if (!is.null(attr(query_lines, "status")) && attr(query_lines, "status") != 0) {
  stop("Could not read cached Athena metadata: ", paste(query_lines, collapse = "\n"))
}
meta <- jsonlite::fromJSON(paste(query_lines, collapse = "\n"))
actual <- as.numeric(meta$DataScannedInBytes)
if (meta$State != "SUCCEEDED" || meta$WorkGroup != "primary" ||
    actual != ledger$actual_bytes[row] || actual > query_cap) {
  stop("Resume metadata failed status, workgroup, ledger, or scan-cap validation.")
}
ledger$disposition[row] <- "accepted"
write.csv(ledger, ledger_path, row.names = FALSE)

ddl_res <- dbSendQuery(ath, ddl_sql)
ddl_error <- NULL
tryCatch(invisible(dbFetch(ddl_res)), error = function(e) ddl_error <<- conditionMessage(e))
ddl_info <- dbGetInfo(ddl_res)
dbClearResult(ddl_res)
ddl_bytes <- if (is.null(ddl_info$Statistics$DataScannedInBytes)) 0 else
  as.numeric(ddl_info$Statistics$DataScannedInBytes)
ledger <- rbind(ledger, data.frame(
  query_id = ddl_info$QueryExecutionId, purpose = "register position RCID output",
  status = ddl_info$Status, estimated_bytes = 0, actual_bytes = ddl_bytes,
  estimated_cost_usd = 0,
  disposition = if (ddl_info$Status == "SUCCEEDED") "accepted" else "failed"))
write.csv(ledger, ledger_path, row.names = FALSE)
if (ddl_info$Status != "SUCCEEDED" || ddl_bytes != 0) {
  stop("Position RCID DDL failed or unexpectedly scanned data: ", ddl_error)
}

download_dir <- tempfile(pattern = "dd_position_rcid_download_", tmpdir = coh)
dir.create(download_dir)
status <- system2("aws", c("s3", "sync", s3_path, shQuote(download_dir),
                           "--region", s3_region, "--only-show-errors"))
if (status != 0) stop("S3 download failed; partial files remain at ", download_dir)
download_files <- list.files(download_dir, full.names = TRUE)
if (!length(download_files) || any(file.info(download_files)$size == 0)) {
  stop("The downloaded RCID dataset is empty or has an empty part.")
}

dbExecute(local, sprintf("CREATE VIEW position_rcid AS SELECT * FROM read_parquet('%s/*')",
                         fw(download_dir)))
schema <- dbGetQuery(local, "DESCRIBE position_rcid")
if (!identical(schema$column_name, cols) ||
    !identical(schema$column_type, rep("BIGINT", 4))) {
  stop("Downloaded RCID schema differs from the four-column contract.")
}
validation <- dbGetQuery(local, "
 SELECT count(*) AS n_rows,count(DISTINCT position_id) position_ids,
        count(DISTINCT user_id) users,
        count(*) FILTER(WHERE user_id IS NULL OR position_id IS NULL) null_keys,
        count(rcid) rcid_rows,count(DISTINCT rcid) rcids,
        count(ultimate_parent_rcid) parent_rows,
        count(DISTINCT ultimate_parent_rcid) parent_rcids
 FROM position_rcid")
anti <- dbGetQuery(local, "
 SELECT (SELECT count(*) FROM positions p WHERE NOT EXISTS
         (SELECT 1 FROM position_rcid r WHERE r.position_id=p.position_id)) position_only,
        (SELECT count(*) FROM position_rcid r WHERE NOT EXISTS
         (SELECT 1 FROM positions p WHERE p.position_id=r.position_id)) rcid_only")
print(validation, row.names = FALSE)
print(anti, row.names = FALSE)
if (validation$n_rows != expected_rows || validation$position_ids != expected_rows ||
    validation$users != expected_users || validation$null_keys != 0 ||
    anti$position_only != 0 || anti$rcid_only != 0) {
  stop("The downloaded RCID extract failed its local grain or anti-join checks.")
}

protected_after <- file.info(protected_files)[, c("size", "mtime"), drop = FALSE]
if (!identical(protected_before, protected_after) ||
    !identical(cohort_md5_before, unname(tools::md5sum(cohort_path)))) {
  stop("A protected refreshed-cohort input changed during the run.")
}
if (!file.rename(download_dir, out_dir)) stop("Could not promote ", download_dir)

total_scan <- sum(ledger$actual_bytes)
report <- list(
  generated_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
  inputs = data.frame(path = required, md5 = c(cohort_md5_before, NA)),
  output = list(local_directory = out_dir, s3_prefix = s3_path,
    athena_table = paste0(athena_schema, ".", table),
    parquet_parts = length(list.files(out_dir)),
    parquet_bytes = sum(file.info(list.files(out_dir, full.names = TRUE))$size)),
  validation = validation, position_antijoin = anti,
  scan = list(approved_aggregate_budget_bytes = aggregate_budget,
    query_cap_bytes = query_cap, actual_bytes = total_scan,
    estimated_cost_usd = total_scan / 1e12 * rate_per_tb,
    accepted_query_id = resume_query_id,
    cost_tracker_synced_query_id = synced_query_id, ledger = ledger_path),
  checks = list(schema_verified = TRUE, unique_position_ids = TRUE,
    complete_users = TRUE, exact_position_set = TRUE, protected_inputs_unchanged = TRUE))
jsonlite::write_json(report, report_path, pretty = TRUE, auto_unbox = TRUE,
                     dataframe = "rows", na = "null", digits = 16)
cat("[OK] Published refreshed position RCIDs to ", out_dir, "\n", sep = "")
