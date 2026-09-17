####################################################################
### Canonical university identity crosswalk for the refreshed cohort
###
### LOCAL, OFFLINE PIPELINE. This script reads existing Dropbox
### products only. It does not query Athena, access S3, or use the
### internet, and it must not be sent to SEDAP.
###
### OA_id deliberately reproduces the CAPES match: only the safe
### one-to-one rsid -> OpenAlex map is eligible. CO_IES_base preserves
### the verified e-MEC hierarchy used by the published CAPES match;
### CO_IES is the wider regex-v1 result. The physical education key is
### retained because university_raw alone is not a function of either
### identifier.
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
base_dir <- file.path(coh, "emec_hierarchy", "education_parts")
regex_dir <- file.path(
  coh, "emec_hierarchy_regex_v1", "education_parts"
)
safe_map_path <- file.path(coh, "rsid_openalex_safe_map.parquet")
out_dir <- Sys.getenv(
  "OBMEP_UNIVERSITY_IDENTITY_OUT",
  unset = file.path(coh, "university_identity_crosswalk")
)
row_dir <- file.path(out_dir, "education_row_identity")
compact_path <- file.path(out_dir, "university_raw_oa_id_co_ies.parquet")
compat_path <- file.path(
  out_dir, "university_raw_oa_id_co_ies_capes_v1.parquet"
)
report_path <- file.path(out_dir, "university_raw_oa_id_co_ies_report.json")

base_files <- sort(list.files(
  base_dir, pattern = "[.]parquet$", full.names = TRUE
))
regex_files <- sort(list.files(
  regex_dir, pattern = "[.]parquet$", full.names = TRUE
))
if (length(base_files) != 30L || length(regex_files) != 30L) {
  stop("Expected 30 base and 30 regex-v1 education parts; found ",
       length(base_files), " and ", length(regex_files), ".")
}
if (!identical(basename(base_files), basename(regex_files))) {
  stop("Base and regex-v1 education partition names do not agree.")
}
if (!file.exists(safe_map_path)) stop("Missing safe OA map: ", safe_map_path)
if (file.exists(out_dir)) stop("Output already exists: ", out_dir)

run_id <- format(Sys.time(), "%Y%m%dT%H%M%S")
stage_dir <- file.path(coh, paste0(".university_identity_crosswalk_", run_id))
stage_rows <- file.path(stage_dir, "education_row_identity")
dir.create(stage_rows, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(stage_rows)) stop("Could not create staging directory: ", stage_rows)

tmp_dir <- file.path(
  Sys.getenv("TEMP"), paste0("duckdb_university_identity_", run_id)
)
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
dbExecute(con, sprintf(
  "SET temp_directory='%s'", gsub("\\\\", "/", tmp_dir)
))
dbExecute(con, "SET memory_limit='12GB'")
dbExecute(con, "SET preserve_insertion_order=false")

safe_sql <- gsub("\\\\", "/", safe_map_path)
dbExecute(con, sprintf(
  "CREATE TABLE safe_oa AS
   SELECT CAST(rsid AS INTEGER) rsid, CAST(openalex_id AS VARCHAR) OA_id
   FROM read_parquet('%s') WHERE safe=1", safe_sql
))
safe_qa <- dbGetQuery(con, "
  SELECT count(*) rows_n, count(DISTINCT rsid) rsids,
         count(*) FILTER (WHERE rsid IS NULL OR OA_id IS NULL) bad
  FROM safe_oa
")
stopifnot(safe_qa$rows_n == safe_qa$rsids, safe_qa$bad == 0L,
          safe_qa$rows_n == 655L)

cat("Building row-faithful university identity parts.\n")
for (i in seq_along(regex_files)) {
  base_path <- gsub("\\\\", "/", base_files[i])
  regex_path <- gsub("\\\\", "/", regex_files[i])
  dest <- file.path(stage_rows, basename(regex_files[i]))
  dest_sql <- gsub("\\\\", "/", dest)

  dbExecute(con, sprintf(
    "CREATE OR REPLACE TEMP VIEW base_part AS
     SELECT source_file, source_row, CO_IES AS CO_IES_base
     FROM read_parquet('%s')", base_path
  ))
  dbExecute(con, sprintf(
    "CREATE OR REPLACE TEMP VIEW regex_part AS
     SELECT * FROM read_parquet('%s')", regex_path
  ))

  part_qa <- dbGetQuery(con, "
    SELECT count(*) regex_rows,
           count(b.source_row) base_rows,
           count(*) - count(DISTINCT (r.source_file, r.source_row)) duplicate_keys,
           count(*) FILTER (
             WHERE b.CO_IES_base IS DISTINCT FROM
               CASE WHEN r.emec_pre_regex_selected_count=1
                    THEN r.emec_pre_regex_selected_codes[1] END
           ) base_disagreements
    FROM regex_part r
    LEFT JOIN base_part b USING(source_file, source_row)
  ")
  if (part_qa$regex_rows != part_qa$base_rows ||
      part_qa$duplicate_keys != 0L || part_qa$base_disagreements != 0L) {
    stop("Base/regex physical-key disagreement in ", basename(regex_files[i]))
  }

  dbExecute(con, sprintf(
    "COPY (
       SELECT r.* EXCLUDE (CO_IES),
              s.OA_id,
              CASE WHEN r.global_oa_selected_count=1
                   THEN r.global_oa_selected_ids[1] END AS OA_hierarchy_id,
              r.global_oa_selected_ids AS OA_hierarchy_selected_ids,
              r.global_oa_selected_count AS OA_hierarchy_selected_count,
              r.global_oa_selection_status AS OA_hierarchy_selection_status,
              b.CO_IES_base,
              r.CO_IES,
              CASE WHEN b.CO_IES_base IS NOT NULL THEN 'base_hierarchy'
                   WHEN coalesce(r.emec_regex_selected,false) THEN 'regex_v1'
                   ELSE 'unresolved' END AS co_ies_source
       FROM regex_part r
       JOIN base_part b USING(source_file, source_row)
       LEFT JOIN safe_oa s USING(rsid)
       ORDER BY r.source_row
     ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", dest_sql
  ))
  cat("  part", i, "of", length(regex_files), "\n")
}

row_glob <- gsub("\\\\", "/", file.path(stage_rows, "*.parquet"))
dbExecute(con, sprintf(
  "CREATE VIEW identity_rows AS SELECT * FROM read_parquet('%s')", row_glob
))

population <- dbGetQuery(con, "
  SELECT count(*) education_rows,
         count(DISTINCT user_id) users,
         count(DISTINCT (source_file, source_row)) physical_keys,
         count(*) FILTER (WHERE OA_id IS NOT NULL) oa_rows,
         count(*) FILTER (WHERE CO_IES_base IS NOT NULL) base_co_rows,
         count(*) FILTER (WHERE CO_IES IS NOT NULL) final_co_rows,
         count(*) FILTER (WHERE OA_id IS NOT NULL AND CO_IES_base IS NOT NULL)
           oa_base_both,
         count(*) FILTER (WHERE OA_id IS NOT NULL AND CO_IES IS NOT NULL)
           oa_final_both,
         count(*) FILTER (WHERE CO_IES_base IS NOT NULL
                           AND CO_IES IS DISTINCT FROM CO_IES_base)
           changed_base,
         count(*) FILTER (WHERE co_ies_source='regex_v1') regex_rows
  FROM identity_rows
")
stopifnot(
  population$education_rows == 19710307L,
  population$users == 8901904L,
  population$physical_keys == population$education_rows,
  population$oa_rows == 10223542L,
  population$base_co_rows == 7371101L,
  population$final_co_rows == 11746464L,
  population$oa_base_both == 6274503L,
  population$oa_final_both == 9242853L,
  population$changed_base == 0L,
  population$regex_rows == 4375363L
)

stage_compact <- file.path(stage_dir, basename(compact_path))
stage_compat <- file.path(stage_dir, basename(compat_path))
dbExecute(con, sprintf(
  "COPY (
     SELECT university_raw, OA_id, CO_IES,
            CASE WHEN bool_or(co_ies_source='base_hierarchy')
                       AND bool_or(co_ies_source='regex_v1') THEN 'mixed'
                 WHEN bool_or(co_ies_source='base_hierarchy') THEN 'base_hierarchy'
                 WHEN bool_or(co_ies_source='regex_v1') THEN 'regex_v1'
                 ELSE 'unresolved' END co_ies_source,
            CAST(count(*) AS BIGINT) n_rows,
            CAST(count(DISTINCT user_id) AS BIGINT) n_users,
            CAST(count(DISTINCT rsid) FILTER (WHERE rsid IS NOT NULL) AS INTEGER)
              n_rsids
     FROM identity_rows
     WHERE OA_id IS NOT NULL OR CO_IES IS NOT NULL
     GROUP BY university_raw, OA_id, CO_IES
     ORDER BY university_raw NULLS LAST, OA_id NULLS LAST, CO_IES NULLS LAST
   ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  gsub("\\\\", "/", stage_compact)
))
dbExecute(con, sprintf(
  "COPY (
     SELECT university_raw, OA_id, CO_IES_base AS CO_IES,
            CAST(count(*) AS BIGINT) n_rows,
            CAST(count(DISTINCT user_id) AS BIGINT) n_users,
            CAST(count(DISTINCT rsid) FILTER (WHERE rsid IS NOT NULL) AS INTEGER)
              n_rsids
     FROM identity_rows
     WHERE OA_id IS NOT NULL OR CO_IES_base IS NOT NULL
     GROUP BY university_raw, OA_id, CO_IES_base
     ORDER BY university_raw NULLS LAST, OA_id NULLS LAST,
              CO_IES_base NULLS LAST
   ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  gsub("\\\\", "/", stage_compat)
))

compact_qa <- dbGetQuery(con, sprintf(
  "SELECT
     (SELECT count(*) FROM read_parquet('%s')) final_triples,
     (SELECT count(*) FROM read_parquet('%s')) base_triples",
  gsub("\\\\", "/", stage_compact),
  gsub("\\\\", "/", stage_compat)
))
stopifnot(compact_qa$final_triples == 377854L,
          compact_qa$base_triples == 148215L)

ambiguity <- dbGetQuery(con, "
  WITH x AS (
    SELECT university_raw,
           count(DISTINCT struct_pack(oa:=OA_id, co:=CO_IES))
             FILTER (WHERE OA_id IS NOT NULL OR CO_IES IS NOT NULL) n_pairs
    FROM identity_rows GROUP BY university_raw
  )
  SELECT count(*) FILTER (WHERE n_pairs>1) ambiguous_raw_values,
         max(n_pairs) max_pairs_per_raw
  FROM x
")
stopifnot(ambiguity$ambiguous_raw_values == 14021L,
          ambiguity$max_pairs_per_raw == 321L)

input_paths <- c(base_files, regex_files, safe_map_path)
input_info <- file.info(input_paths)
output_paths <- c(
  sort(list.files(stage_rows, pattern = "[.]parquet$", full.names = TRUE)),
  stage_compact, stage_compat
)
report <- list(
  created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  execution_environment = "local_offline_no_s3_no_athena",
  definitions = list(
    OA_id = "safe=1 one-to-one rsid_openalex_safe_map assignment",
    CO_IES_base = "verified base e-MEC hierarchy used by the saved CAPES match",
    CO_IES = "regex-v1 result; base assignments are immutable",
    join_grain = c("source_file", "source_row")
  ),
  inputs = data.frame(
    path = input_paths,
    size = unname(input_info$size),
    mtime = format(input_info$mtime, "%Y-%m-%dT%H:%M:%S%z"),
    stringsAsFactors = FALSE
  ),
  population = population,
  compact = compact_qa,
  ambiguity = ambiguity,
  outputs = data.frame(
    path = sub(stage_dir, out_dir, output_paths, fixed = TRUE),
    size = unname(file.info(output_paths)$size),
    md5 = unname(tools::md5sum(output_paths)),
    stringsAsFactors = FALSE
  ),
  validation = list(
    physical_keys_unique = TRUE,
    safe_oa_map_functional = TRUE,
    base_codes_reproduced = TRUE,
    regex_preserves_base_codes = TRUE,
    raw_only_join_forbidden = TRUE
  )
)
write_json(
  report, file.path(stage_dir, basename(report_path)),
  pretty = TRUE, auto_unbox = TRUE, na = "null"
)

dbDisconnect(con, shutdown = TRUE)
if (!file.rename(stage_dir, out_dir)) {
  stop("Could not promote staged crosswalk to ", out_dir)
}

cat("\nCanonical university identity crosswalk published.\n")
cat("  row parts      :", row_dir, "\n")
cat("  final triples  :", compact_path, "\n")
cat("  CAPES-v1 view  :", compat_path, "\n")
cat("  report         :", report_path, "\n")
