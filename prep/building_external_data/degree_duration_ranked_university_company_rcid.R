####################################################################
### Degree-duration CWUR/Shanghai universities -> Revelio RCIDs
###
### LOCAL, ONLINE PREPARATION. This script performs one metered Athena
### lookup against academic_company_ref and must never be sent to
### SEDAP. It pauses after the scan so the monthly cost tracker can be
### refreshed before the cached result is accepted and published.
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "RAthena", "arrow", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) stop("Missing package: ", p)
}
library(DBI)
library(duckdb)

root <- Sys.getenv("OBMEP_ROOT",
                   unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh <- file.path(root, "Data/intermediate/revelio_br_cohort")
hierarchy_dir <- file.path(coh, "global_oa_hierarchy_degree_duration")
catalog_path <- file.path(hierarchy_dir, "catalog.parquet")
ranked_path <- file.path(
  hierarchy_dir, "global_oa_degree_duration_ranked_parent_catalog.parquet")
old_map_path <- file.path(
  root, "Data/intermediate/ranked_university_company_rcid",
  "ranked_university_company_rcid.parquet")

out_dir <- file.path(
  root, "Data/intermediate/degree_duration_ranked_university_company_rcid")
out_path <- file.path(
  out_dir, "degree_duration_ranked_university_company_rcid.parquet")
report_path <- file.path(
  out_dir, "degree_duration_ranked_university_company_rcid_report.json")
published_ledger_path <- file.path(
  out_dir, "degree_duration_ranked_university_company_rcid_scan_ledger.csv")
run_id <- Sys.getenv(
  "OBMEP_DD_UNIVERSITY_RCID_RUN_ID", unset = format(Sys.time(), "%Y%m%dT%H%M%S"))
if (!grepl("^[0-9]{8}T[0-9]{6}$", run_id)) stop("Invalid run id: ", run_id)
stage_dir <- file.path(out_dir, ".staging", run_id)
hit_path <- file.path(stage_dir, "reference_hits.parquet")
ledger_path <- file.path(stage_dir, "scan_ledger.csv")
stage_out <- file.path(stage_dir, basename(out_path))
stage_report <- file.path(stage_dir, basename(report_path))

resume_query_id <- Sys.getenv("OBMEP_RESUME_ATHENA_QUERY_ID", unset = "")
synced_query_id <- Sys.getenv("OBMEP_COST_TRACKER_SYNCED_QUERY_ID", unset = "")
resume_mode <- nzchar(resume_query_id)
approved_budget <- suppressWarnings(as.numeric(Sys.getenv(
  "OBMEP_DD_FIRMS_APPROVED_BUDGET_BYTES", unset = "0")))
aggregate_budget <- 47000000000
estimated_scan <- 1077370931
query_cap <- 1300000000
rate_per_tb <- 5

athena_schema <- "revelio_database"
ref_table <- "academic_company_ref"
s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "8GB")
tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_dd_university_company_rcid")

required <- c(catalog_path, ranked_path, old_map_path)
if (!all(file.exists(required))) {
  stop("Missing input(s): ", paste(required[!file.exists(required)], collapse = ", "))
}
if (Sys.which("aws") == "") stop("The AWS CLI is required.")
dir.create(stage_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
fw <- function(p) gsub("\\\\", "/", p)

py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
dbExecute(con, sprintf("SET memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", fw(tmp_dir)))
dbExecute(con, "SET preserve_insertion_order=false")

dbExecute(con, sprintf("
CREATE TABLE ranked AS
SELECT CASE family WHEN 'cw' THEN 'cwur' WHEN 'sh' THEN 'shanghai' END AS family,
       oa_id source_oa_id, canonical_id canonical_oa_id, rk::INTEGER rank,
       inst institution_name
FROM read_parquet('%s')
WHERE family IN ('cw','sh')", fw(ranked_path)))

ranked_counts <- dbGetQuery(con, "
 SELECT family,count(*) AS n_rows,count(DISTINCT source_oa_id) source_ids,
        count(DISTINCT canonical_oa_id) canonical_ids
 FROM ranked GROUP BY 1 ORDER BY 1")
print(ranked_counts, row.names = FALSE)
cw <- ranked_counts[ranked_counts$family == "cwur", ]
sh <- ranked_counts[ranked_counts$family == "shanghai", ]
if (nrow(cw) != 1 || cw$n_rows != 52L || cw$source_ids != 52L ||
    cw$canonical_ids != 52L || nrow(sh) != 1 || sh$n_rows != 999L ||
    sh$source_ids != 999L || sh$canonical_ids != 930L) {
  stop("The ranked catalog does not have the required CWUR/Shanghai grain.")
}
if (dbGetQuery(con, "SELECT count(*) n FROM ranked WHERE family IS NULL OR
                     source_oa_id IS NULL OR canonical_oa_id IS NULL OR
                     institution_name IS NULL")$n != 0) {
  stop("The ranked catalog contains an invalid row.")
}

dbExecute(con, sprintf("
CREATE TABLE institution_names AS
WITH variants AS (
 SELECT r.*,'source' name_scope,'display_name' name_variant,c.display_name searched_name
 FROM ranked r JOIN read_parquet('%1$s') c ON r.source_oa_id=c.oa_id
 UNION ALL
 SELECT r.*,'source','cleaned_display_name',c.cleaned_display_name
 FROM ranked r JOIN read_parquet('%1$s') c ON r.source_oa_id=c.oa_id
 UNION ALL
 SELECT r.*,'parent','display_name',c.display_name
 FROM ranked r JOIN read_parquet('%1$s') c ON r.canonical_oa_id=c.oa_id
 UNION ALL
 SELECT r.*,'parent','cleaned_display_name',c.cleaned_display_name
 FROM ranked r JOIN read_parquet('%1$s') c ON r.canonical_oa_id=c.oa_id
 UNION ALL
 SELECT r.*,'ranking','supplied_name',r.institution_name FROM ranked r
 UNION ALL
 SELECT r.*,'ranking_peer',concat('supplied_name_',p.family),p.institution_name
 FROM ranked r JOIN ranked p
   ON r.canonical_oa_id=p.canonical_oa_id AND r.family<>p.family
)
SELECT DISTINCT family,source_oa_id,canonical_oa_id,rank,institution_name,
 name_scope,name_variant,trim(searched_name) searched_name,
 lower(strip_accents(trim(searched_name))) searched_name_norm
FROM variants WHERE searched_name IS NOT NULL AND length(trim(searched_name))>=3",
fw(catalog_path)))

name_counts <- dbGetQuery(con, "SELECT family,count(*) provenance_rows,
 count(DISTINCT searched_name_norm) distinct_names FROM institution_names
 GROUP BY 1 ORDER BY 1")
names_to_query <- dbGetQuery(con, "SELECT DISTINCT searched_name_norm
 FROM institution_names ORDER BY 1")$searched_name_norm
if (!length(names_to_query)) stop("No university names were generated.")
quoted_names <- paste0("'", gsub("'", "''", names_to_query, fixed = TRUE), "'")
athena_fold <- "lower(regexp_replace(normalize(trim(company), NFD), '\\p{M}', ''))"
query_sql <- sprintf("
 SELECT %1$s company_norm,company,
  CAST(rcid AS BIGINT) reference_rcid,
  CAST(child_rcid AS BIGINT) reference_child_rcid,
  CAST(ultimate_parent_rcid AS BIGINT) reference_ultimate_parent_rcid
 FROM %2$s.%3$s
 WHERE company IS NOT NULL AND %1$s IN (%4$s)",
 athena_fold, athena_schema, ref_table, paste(quoted_names, collapse = ","))

cat("=========== ZERO-SCAN PREFLIGHT ===========\n")
schema_lines <- system2(
  "aws", c("glue", "get-table", "--database-name", athena_schema,
           "--name", ref_table, "--region", s3_region, "--output", "json"),
  stdout = TRUE, stderr = TRUE)
if (!is.null(attr(schema_lines, "status")) && attr(schema_lines, "status") != 0) {
  stop("Could not inspect academic_company_ref: ", paste(schema_lines, collapse = "\n"))
}
schema <- jsonlite::fromJSON(paste(schema_lines, collapse = "\n"))
live <- setNames(tolower(schema$Table$StorageDescriptor$Columns$Type),
                 schema$Table$StorageDescriptor$Columns$Name)
expected <- c(rcid = "int", company = "string", child_rcid = "int",
              ultimate_parent_rcid = "int")
if (!all(names(expected) %in% names(live)) ||
    !identical(unname(live[names(expected)]), unname(expected))) {
  stop("academic_company_ref schema drifted from the required contract.")
}

if (!resume_mode) {
  if (file.exists(hit_path) || file.exists(ledger_path)) {
    stop("The new-run staging directory already contains scan state: ", stage_dir)
  }
  cat("  query purpose : resolve degree-duration CWUR/Shanghai names\n")
  cat("  estimated scan: ", format(estimated_scan, big.mark = ","), " bytes\n", sep = "")
  cat("  query cap     : ", format(query_cap, big.mark = ","), " bytes\n", sep = "")
  cat("  aggregate cap : ", format(aggregate_budget, big.mark = ","), " bytes\n", sep = "")
  if (!is.finite(approved_budget) || approved_budget < aggregate_budget) {
    stop("Athena scan approval gate is closed. Set ",
         "OBMEP_DD_FIRMS_APPROVED_BUDGET_BYTES to at least ", aggregate_budget,
         " only after explicit approval of the disclosed two-query set.")
  }

  ath <- dbConnect(RAthena::athena(),
                   s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                   region_name = s3_region, schema_name = athena_schema)
  on.exit(try(dbDisconnect(ath), silent = TRUE), add = TRUE)
  res <- dbSendQuery(ath, query_sql)
  query_error <- NULL
  refs <- tryCatch(dbFetch(res), error = function(e) {
    query_error <<- conditionMessage(e); data.frame()
  })
  info <- dbGetInfo(res)
  dbClearResult(res)
  actual <- if (is.null(info$Statistics$DataScannedInBytes)) 0 else
    as.numeric(info$Statistics$DataScannedInBytes)
  succeeded <- identical(info$Status, "SUCCEEDED")
  ledger <- data.frame(
    query_id = info$QueryExecutionId,
    purpose = "resolve degree-duration CWUR and Shanghai employer RCIDs",
    status = info$Status, estimated_bytes = estimated_scan, actual_bytes = actual,
    estimated_cost_usd = actual / 1e12 * rate_per_tb,
    disposition = if (succeeded) "provisional" else "failed")
  write.csv(ledger, ledger_path, row.names = FALSE)
  if (!succeeded) {
    stop("University lookup failed and will not be retried. Refresh the cost ",
         "tracker for query ", info$QueryExecutionId, " (", actual,
         " bytes): ", query_error)
  }
  if (!nrow(refs)) {
    stop("University lookup returned no rows. Refresh the cost tracker for query ",
         info$QueryExecutionId, " (", actual, " bytes); do not retry.")
  }
  arrow::write_parquet(refs, hit_path, compression = "zstd")
  if (actual > query_cap) {
    stop("The university lookup exceeded its approved sub-cap. Refresh the cost ",
         "tracker for query ", info$QueryExecutionId, " (", actual,
         " bytes), but do not accept it without revised approval.")
  }
  cat("\n[PAUSED] Refresh AWS Monthly Costs 2026 YTD for query ",
      info$QueryExecutionId, " (", format(actual, big.mark = ","), " bytes).\n", sep = "")
  cat("Resume with the same run id and both query-id variables:\n")
  cat("  $env:OBMEP_DD_UNIVERSITY_RCID_RUN_ID='", run_id, "'\n", sep = "")
  cat("  $env:OBMEP_RESUME_ATHENA_QUERY_ID='", info$QueryExecutionId, "'\n", sep = "")
  cat("  $env:OBMEP_COST_TRACKER_SYNCED_QUERY_ID='", info$QueryExecutionId, "'\n", sep = "")
  quit(save = "no", status = 0)
}

if (!file.exists(hit_path) || !file.exists(ledger_path)) {
  stop("Resume requires cached reference hits and a scan ledger in ", stage_dir)
}
if (!identical(resume_query_id, synced_query_id)) {
  stop("Resume query id must equal the cost-tracker synchronized query id.")
}
ledger <- read.csv(ledger_path, stringsAsFactors = FALSE)
if (nrow(ledger) != 1 || ledger$query_id != resume_query_id ||
    ledger$status != "SUCCEEDED") stop("Resume query does not match the ledger.")
query_lines <- system2(
  "aws", c("athena", "get-query-execution", "--query-execution-id",
           resume_query_id, "--region", s3_region,
           "--query", "QueryExecution.{State:Status.State,WorkGroup:WorkGroup,DataScannedInBytes:Statistics.DataScannedInBytes}",
           "--output", "json"),
  stdout = TRUE, stderr = TRUE)
if (!is.null(attr(query_lines, "status")) && attr(query_lines, "status") != 0) {
  stop("Could not read cached Athena metadata: ", paste(query_lines, collapse = "\n"))
}
query_meta <- jsonlite::fromJSON(paste(query_lines, collapse = "\n"))
actual <- as.numeric(query_meta$DataScannedInBytes)
if (query_meta$State != "SUCCEEDED" || query_meta$WorkGroup != "primary" ||
    actual != ledger$actual_bytes || actual > query_cap) {
  stop("Resume metadata failed status, workgroup, ledger, or scan-cap validation.")
}
ledger$disposition <- "accepted"
write.csv(ledger, ledger_path, row.names = FALSE)

refs <- arrow::read_parquet(hit_path)
for (cc in c("reference_rcid", "reference_child_rcid",
             "reference_ultimate_parent_rcid")) refs[[cc]] <- as.numeric(refs[[cc]])
dbWriteTable(con, "reference_hits", refs, overwrite = TRUE)
dbExecute(con, "
CREATE TABLE crosswalk AS
SELECT DISTINCT n.family,n.source_oa_id,n.canonical_oa_id,n.rank,
 n.institution_name,n.name_scope,n.name_variant,n.searched_name,
 n.searched_name_norm,r.company reference_company,
 r.reference_rcid::BIGINT reference_rcid,
 r.reference_child_rcid::BIGINT reference_child_rcid,
 r.reference_ultimate_parent_rcid::BIGINT reference_ultimate_parent_rcid,
 x.expanded_rcid::BIGINT expanded_rcid,x.rcid_role
FROM institution_names n JOIN reference_hits r
 ON n.searched_name_norm=r.company_norm
CROSS JOIN (VALUES (r.reference_rcid,'rcid'),
 (r.reference_child_rcid,'child_rcid'),
 (r.reference_ultimate_parent_rcid,'ultimate_parent_rcid')) x(expanded_rcid,rcid_role)
WHERE x.expanded_rcid IS NOT NULL")

bad <- dbGetQuery(con, "SELECT count(*) n FROM crosswalk WHERE expanded_rcid IS NULL
 OR family NOT IN ('cwur','shanghai') OR expanded_rcid<1")$n
if (bad != 0) stop("Invalid row in the expanded university RCID map.")
summary <- dbGetQuery(con, "SELECT family,count(*) provenance_rows,
 count(DISTINCT source_oa_id) matched_source_institutions,
 count(DISTINCT canonical_oa_id) matched_canonical_institutions,
 count(DISTINCT reference_rcid) reference_rows,
 count(DISTINCT expanded_rcid) expanded_rcids
 FROM crosswalk GROUP BY 1 ORDER BY 1")
unmatched <- dbGetQuery(con, "SELECT r.* FROM ranked r WHERE NOT EXISTS
 (SELECT 1 FROM crosswalk c WHERE c.family=r.family
  AND c.source_oa_id=r.source_oa_id) ORDER BY family,rank,source_oa_id")
collisions <- dbGetQuery(con, "SELECT family,expanded_rcid,
 count(DISTINCT canonical_oa_id) n_institutions,
 string_agg(DISTINCT institution_name,' | ' ORDER BY institution_name) institutions
 FROM crosswalk GROUP BY 1,2 HAVING count(DISTINCT canonical_oa_id)>1
 ORDER BY family,n_institutions DESC,expanded_rcid")

dbExecute(con, sprintf("CREATE VIEW old_map AS SELECT * FROM read_parquet('%s')",
                       fw(old_map_path)))
shanghai_loss <- dbGetQuery(con, "SELECT count(*) n FROM (
 SELECT source_oa_id,canonical_oa_id,expanded_rcid FROM old_map
 WHERE family='shanghai' GROUP BY 1,2,3 EXCEPT
 SELECT source_oa_id,canonical_oa_id,expanded_rcid FROM crosswalk
 WHERE family='shanghai' GROUP BY 1,2,3)")$n
cwur_overlap <- dbGetQuery(con, "WITH expected AS (
 SELECT r.source_oa_id,r.canonical_oa_id,m.expanded_rcid
 FROM ranked r JOIN old_map m ON r.source_oa_id=m.source_oa_id
 WHERE r.family='cwur' AND m.family='shanghai' GROUP BY 1,2,3),
 got AS (SELECT source_oa_id,canonical_oa_id,expanded_rcid FROM crosswalk
        WHERE family='cwur' GROUP BY 1,2,3)
 SELECT (SELECT count(DISTINCT source_oa_id) FROM expected) expected_institutions,
        (SELECT count(DISTINCT expanded_rcid) FROM expected) expected_rcids,
        (SELECT count(*) FROM (SELECT * FROM expected EXCEPT SELECT * FROM got)) losses")
if (shanghai_loss != 0 || cwur_overlap$expected_institutions != 18L ||
    cwur_overlap$expected_rcids != 41L || cwur_overlap$losses != 0) {
  cat("Regression diagnostics:\n")
  print(data.frame(shanghai_losses = shanghai_loss,
                   cwur_expected_institutions = cwur_overlap$expected_institutions,
                   cwur_expected_rcids = cwur_overlap$expected_rcids,
                   cwur_losses = cwur_overlap$losses), row.names = FALSE)
  if (shanghai_loss != 0) {
    print(dbGetQuery(con, "SELECT source_oa_id,canonical_oa_id,expanded_rcid
      FROM old_map WHERE family='shanghai' GROUP BY 1,2,3 EXCEPT
      SELECT source_oa_id,canonical_oa_id,expanded_rcid FROM crosswalk
      WHERE family='shanghai' GROUP BY 1,2,3 LIMIT 20"), row.names = FALSE)
  }
  if (cwur_overlap$losses != 0) {
    print(dbGetQuery(con, "WITH expected AS (
      SELECT r.source_oa_id,r.canonical_oa_id,m.expanded_rcid
      FROM ranked r JOIN old_map m ON r.source_oa_id=m.source_oa_id
      WHERE r.family='cwur' AND m.family='shanghai' GROUP BY 1,2,3),
      got AS (SELECT source_oa_id,canonical_oa_id,expanded_rcid FROM crosswalk
             WHERE family='cwur' GROUP BY 1,2,3)
      SELECT * FROM expected EXCEPT SELECT * FROM got"), row.names = FALSE)
  }
  stop("The new resolver lost an established Shanghai or CWUR-overlap mapping.")
}

dbExecute(con, sprintf("COPY (SELECT * FROM crosswalk ORDER BY family,rank,
 source_oa_id,expanded_rcid,rcid_role,searched_name_norm) TO '%s'
 (FORMAT PARQUET,COMPRESSION ZSTD)", fw(stage_out)))
report <- list(
  generated_at = format(Sys.time(), tz = "UTC", usetz = TRUE), run_id = run_id,
  method = list(source = paste0(athena_schema, ".", ref_table),
    match = "trim + lowercase + NFD accent removal + whole-field equality",
    expanded_fields = c("rcid", "child_rcid", "ultimate_parent_rcid"),
    excluded = c("alternative-name fields", "derived acronyms", "segments",
                 "substrings", "fuzzy")),
  inputs = data.frame(path = required, md5 = unname(tools::md5sum(required))),
  ranking_catalog = ranked_counts, names = name_counts, summary = summary,
  unmatched_institutions = unmatched, multi_institution_rcids = collisions,
  regression = list(shanghai_losses = shanghai_loss, cwur_overlap = cwur_overlap),
  scan = list(approved_aggregate_budget_bytes = aggregate_budget,
    query_cap_bytes = query_cap, actual_bytes = actual,
    estimated_cost_usd = actual / 1e12 * rate_per_tb,
    query_id = resume_query_id, cost_tracker_synced_query_id = synced_query_id,
    ledger = published_ledger_path),
  checks = list(schema_verified = TRUE, family_grain = TRUE,
    no_null_expanded_rcid = TRUE, established_mappings_retained = TRUE))
jsonlite::write_json(report, stage_report, pretty = TRUE, auto_unbox = TRUE,
                     dataframe = "rows", na = "null", digits = 16)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
if (file.exists(out_path) || file.exists(report_path) || file.exists(published_ledger_path)) {
  backup <- file.path(out_dir, "backups", run_id)
  dir.create(backup, recursive = TRUE, showWarnings = FALSE)
  prior <- c(out_path, report_path, published_ledger_path)
  for (p in prior[file.exists(prior)]) {
    if (!file.copy(p, file.path(backup, basename(p)), overwrite = FALSE)) {
      stop("Could not back up ", p)
    }
  }
}
for (pair in list(c(stage_out, out_path), c(stage_report, report_path),
                  c(ledger_path, published_ledger_path))) {
  tmp <- paste0(pair[2], ".publishing_", run_id)
  if (!file.copy(pair[1], tmp, overwrite = TRUE) ||
      !identical(unname(tools::md5sum(pair[1])), unname(tools::md5sum(tmp)))) {
    stop("Could not stage publication for ", pair[2])
  }
  if (file.exists(pair[2]) && !file.remove(pair[2])) stop("Could not replace ", pair[2])
  if (!file.rename(tmp, pair[2])) stop("Could not publish ", pair[2])
}
cat("Published degree-duration university RCID map:\n  ", out_path, "\n", sep = "")
