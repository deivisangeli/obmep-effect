####################################################################
### Processed products: education-entry identity crosswalk and the
### selected LinkedIn profiles with their education and positions
###
### LOCAL, OFFLINE PIPELINE. This script reads existing Dropbox
### products under Data/intermediate/revelio_br_cohort only and writes
### only under Data/processed. It does not query Athena, access S3, or
### use the internet, and it must not be sent to SEDAP.
###
### Sources are copied or filtered, never moved: the row-level identity
### parts stay in place because ranked_education_flags.R and the CAPES
### scripts read them there. The crosswalk keeps the physical key
### (source_file, source_row) because university_raw alone is not a
### function of OA_id or CO_IES. The selected profiles contain civil
### names (fullname), as the source file does.
####################################################################

for (p in c("DBI", "duckdb", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(duckdb)
library(jsonlite)

root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)
coh <- file.path(root, "Data/intermediate/revelio_br_cohort")
identity_dir <- file.path(
  coh, "university_identity_crosswalk", "education_row_identity"
)
raw_education_dir <- file.path(coh, "obmep_candidates_step_1_education")
position_dir <- file.path(coh, "obmep_candidates_step_1_position")
position_rcid_dir <- file.path(coh, "obmep_candidates_step_1_position_rcid")
selected_path <- file.path(coh, "obmep_candidates_selected.parquet")

out_dir <- Sys.getenv(
  "OBMEP_PROCESSED_OUT", unset = file.path(root, "Data/processed")
)
targets <- c(
  "crosswalks/education_entry_oa_id_co_ies.parquet",
  "obmep_candidates_selected.parquet",
  "obmep_candidates_selected_education.parquet",
  "obmep_candidates_selected_positions",
  "processed_manifest.json"
)

identity_files <- sort(list.files(
  identity_dir, pattern = "[.]parquet$", full.names = TRUE
))
if (length(identity_files) != 30L) {
  stop("Expected 30 education identity parts; found ", length(identity_files))
}
for (d in c(raw_education_dir, position_dir, position_rcid_dir)) {
  if (length(list.files(d)) != 30L) stop("Expected 30 parquet parts in ", d)
}
if (!file.exists(selected_path)) stop("Missing selection: ", selected_path)
existing <- targets[file.exists(file.path(out_dir, targets))]
if (length(existing) > 0L) {
  stop("Output already exists: ", paste(existing, collapse = ", "))
}

source_files <- c(
  identity_files,
  sort(list.files(raw_education_dir, full.names = TRUE)),
  sort(list.files(position_dir, full.names = TRUE)),
  sort(list.files(position_rcid_dir, full.names = TRUE)),
  selected_path
)
source_info_before <- file.info(source_files)[, c("size", "mtime")]

run_id <- format(Sys.time(), "%Y%m%dT%H%M%S")
stage_dir <- file.path(out_dir, paste0(".staging_", run_id))
dir.create(file.path(stage_dir, "crosswalks"), recursive = TRUE,
           showWarnings = FALSE)
if (!dir.exists(stage_dir)) stop("Could not create staging directory: ", stage_dir)

tmp_dir <- file.path(Sys.getenv("TEMP"), paste0("duckdb_processed_", run_id))
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
dbExecute(con, sprintf(
  "SET temp_directory='%s'", gsub("\\\\", "/", tmp_dir)
))
dbExecute(con, "SET memory_limit='12GB'")
dbExecute(con, "SET preserve_insertion_order=false")

sql_path <- function(...) gsub("\\\\", "/", file.path(...))
dbExecute(con, sprintf(
  "CREATE VIEW identity_rows AS SELECT * FROM read_parquet('%s')",
  sql_path(identity_dir, "*.parquet")
))
dbExecute(con, sprintf(
  "CREATE TABLE selected_users AS
   SELECT user_id FROM read_parquet('%s')", sql_path(selected_path)
))
selected_qa <- dbGetQuery(con, "
  SELECT count(*) n, count(DISTINCT user_id) users,
         count(*) FILTER (WHERE user_id IS NULL) null_users
  FROM selected_users
")
stopifnot(selected_qa$n == 2289937L, selected_qa$users == selected_qa$n,
          selected_qa$null_users == 0L)

cat("Writing the education-entry identity crosswalk.\n")
crosswalk_stage <- file.path(stage_dir, targets[1])
dbExecute(con, sprintf(
  "COPY (
     SELECT user_id, source_file, source_row, university_raw,
            OA_id, OA_id_safe, CO_IES, CO_IES_base, co_ies_source
     FROM identity_rows
     ORDER BY source_file, source_row
   ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", sql_path(crosswalk_stage)
))
crosswalk_qa <- dbGetQuery(con, sprintf(
  "SELECT count(*) n_rows, count(DISTINCT user_id) users,
          count(*) - count(DISTINCT (source_file, source_row)) duplicate_keys,
          count(*) FILTER (WHERE OA_id IS NOT NULL) oa_rows,
          count(*) FILTER (WHERE CO_IES IS NOT NULL) co_rows,
          count(*) FILTER (WHERE OA_id IS NOT NULL AND CO_IES IS NOT NULL) both_rows,
          count(*) FILTER (WHERE OA_id IS NOT NULL OR CO_IES IS NOT NULL) either_rows
   FROM read_parquet('%s')", sql_path(crosswalk_stage)
))
stopifnot(crosswalk_qa$n_rows == 19710307L, crosswalk_qa$users == 8901904L,
          crosswalk_qa$duplicate_keys == 0L,
          crosswalk_qa$oa_rows == 13304177L,
          crosswalk_qa$co_rows == 11746464L,
          crosswalk_qa$both_rows == 9827794L)

cat("Copying the selected profiles.\n")
selected_stage <- file.path(stage_dir, targets[2])
if (!file.copy(selected_path, selected_stage, copy.date = TRUE)) {
  stop("Could not copy ", selected_path)
}
stopifnot(unname(tools::md5sum(selected_stage)) ==
            unname(tools::md5sum(selected_path)))

cat("Writing the selected profiles' education entries.\n")
education_stage <- file.path(stage_dir, targets[3])
dbExecute(con, sprintf(
  "COPY (
     SELECT user_id, university_raw, university_name, rsid,
            degree_raw, degree, field_raw, field, university_country,
            description, startdate, enddate, ranked_level,
            degree_duration_years, degree_residual_other,
            degree_match_ranked, degree_match_duration,
            degree_matches_laxed, degree_match_route,
            source_file, source_row,
            OA_id, OA_id_safe, CO_IES, CO_IES_base, co_ies_source
     FROM identity_rows
     WHERE user_id IN (SELECT user_id FROM selected_users)
     ORDER BY user_id, source_file, source_row
   ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", sql_path(education_stage)
))
education_qa <- dbGetQuery(con, sprintf(
  "SELECT count(*) n_rows, count(DISTINCT user_id) users,
          count(*) - count(DISTINCT (source_file, source_row)) duplicate_keys,
          count(*) FILTER (WHERE user_id NOT IN
            (SELECT user_id FROM selected_users)) outside_rows,
          count(*) FILTER (WHERE OA_id IS NOT NULL OR CO_IES IS NOT NULL)
            identity_rows
   FROM read_parquet('%s')", sql_path(education_stage)
))
education_expected <- dbGetQuery(con, sprintf(
  "SELECT count(*) n_rows FROM read_parquet('%s')
   WHERE user_id IN (SELECT user_id FROM selected_users)",
  sql_path(raw_education_dir, "*")
))
stopifnot(education_qa$duplicate_keys == 0L, education_qa$outside_rows == 0L,
          education_qa$n_rows == education_expected$n_rows)

cat("Writing the selected profiles' position entries.\n")
positions_stage <- file.path(stage_dir, targets[4])
dbExecute(con, sprintf(
  "COPY (
     SELECT p.*, r.rcid, r.ultimate_parent_rcid
     FROM read_parquet('%s') p
     LEFT JOIN read_parquet('%s') r USING (position_id)
     WHERE p.user_id IN (SELECT user_id FROM selected_users)
   ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD,
              FILE_SIZE_BYTES '500MB', FILENAME_PATTERN 'part_{i}')",
  sql_path(position_dir, "*"), sql_path(position_rcid_dir, "*"),
  sql_path(positions_stage)
))
positions_qa <- dbGetQuery(con, sprintf(
  "SELECT count(*) n_rows, count(DISTINCT user_id) users,
          count(*) - count(DISTINCT position_id) duplicate_positions,
          count(*) FILTER (WHERE user_id NOT IN
            (SELECT user_id FROM selected_users)) outside_rows,
          count(*) FILTER (WHERE rcid IS NOT NULL) rcid_rows,
          count(*) FILTER (WHERE ultimate_parent_rcid IS NOT NULL)
            parent_rcid_rows
   FROM read_parquet('%s')", sql_path(positions_stage, "*.parquet")
))
positions_expected <- dbGetQuery(con, sprintf(
  "SELECT count(*) n_rows FROM read_parquet('%s')
   WHERE user_id IN (SELECT user_id FROM selected_users)",
  sql_path(position_dir, "*")
))
stopifnot(positions_qa$duplicate_positions == 0L,
          positions_qa$outside_rows == 0L,
          positions_qa$n_rows == positions_expected$n_rows)

dbDisconnect(con, shutdown = TRUE)
unlink(tmp_dir, recursive = TRUE)

source_info_after <- file.info(source_files)[, c("size", "mtime")]
if (!identical(source_info_before, source_info_after)) {
  stop("A source file changed while the script was running.")
}

output_files <- c(
  crosswalk_stage, selected_stage, education_stage,
  sort(list.files(positions_stage, full.names = TRUE))
)
manifest <- list(
  created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  execution_environment = "local_offline_no_s3_no_athena",
  script = "prep/building_external_data/processed_selected_products.R",
  definitions = list(
    crosswalk = "one row per education entry; join on (source_file, source_row)",
    OA_id = "unique global OpenAlex hierarchy selection",
    OA_id_safe = "safe=1 one-to-one rsid_openalex_safe_map assignment",
    CO_IES_base = "verified base e-MEC hierarchy used by the saved CAPES match",
    CO_IES = "regex-v1 result; base assignments are immutable",
    selected = "canonical obmep_candidates_selected.parquet, byte copy",
    positions_rcid = "rcid and ultimate_parent_rcid joined on position_id"
  ),
  sources = data.frame(
    path = source_files,
    size = unname(source_info_before$size),
    mtime = format(source_info_before$mtime, "%Y-%m-%dT%H:%M:%S%z"),
    stringsAsFactors = FALSE
  ),
  counts = list(
    selected_users = selected_qa$users,
    crosswalk = crosswalk_qa,
    education = c(as.list(education_qa),
                  selected_users_without_education =
                    selected_qa$users - education_qa$users),
    positions = c(as.list(positions_qa),
                  selected_users_without_positions =
                    selected_qa$users - positions_qa$users)
  ),
  outputs = data.frame(
    path = sub(stage_dir, out_dir, output_files, fixed = TRUE),
    size = unname(file.info(output_files)$size),
    md5 = unname(tools::md5sum(output_files)),
    stringsAsFactors = FALSE
  )
)
write_json(
  manifest, file.path(stage_dir, targets[5]),
  pretty = TRUE, auto_unbox = TRUE, na = "null"
)

dir.create(file.path(out_dir, "crosswalks"), showWarnings = FALSE)
# Dropbox briefly locks freshly written folders while indexing them, so a
# denied rename is retried before giving up.
for (t in targets) {
  for (attempt in 1:10) {
    if (suppressWarnings(file.rename(file.path(stage_dir, t),
                                     file.path(out_dir, t)))) break
    if (attempt == 10L) stop("Could not promote ", t, " from ", stage_dir)
    Sys.sleep(30)
  }
}
left <- list.files(stage_dir, recursive = TRUE, all.files = TRUE)
if (length(left) == 0L) unlink(stage_dir, recursive = TRUE)

cat("\nProcessed products published under", out_dir, "\n")
cat("  crosswalk rows      :", crosswalk_qa$n_rows, "\n")
cat("  selected users      :", selected_qa$users, "\n")
cat("  education rows/users:", education_qa$n_rows, "/", education_qa$users, "\n")
cat("  position rows/users :", positions_qa$n_rows, "/", positions_qa$users, "\n")
cat("  positions with rcid :", positions_qa$rcid_rows, "\n")
