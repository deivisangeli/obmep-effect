####################################################################
### Selected profiles for the refreshed degree-duration cohort
###
### LOCAL, OFFLINE PIPELINE. This script unions every user with at
### least one of the six refreshed headline flags, then attaches the
### civil name from the frozen LinkedIn-name snapshot by exact user_id.
### It does not use Athena, S3, or the internet and must not be sent to
### SEDAP. Its output contains personal data.
###
### The two source families both call their CWUR columns `cw_*` even
### though one means STUDIED and the other WORKED. The combined output
### therefore uses `cw_degree_*` and `cw_work_*`; no ambiguous `cw_*`
### column survives.
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) stop("Missing package: ", p)
}
library(DBI)
library(duckdb)

obmep_root <- Sys.getenv(
  "OBMEP_ROOT", unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
gt_root <- Sys.getenv(
  "GT_ROOT", unset = "C:/Users/megaj/Globtalent Dropbox/GTAllocation")

coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
cohort_path <- file.path(
  coh_dir, "obmep_candidates_step_1_degree_duration.parquet")
cw_degree_path <- file.path(
  coh_dir, "obmep_candidates_step_1_degree_duration_cwur.parquet")
sh_degree_path <- file.path(
  coh_dir, "obmep_candidates_step_1_degree_duration_shanghai.parquet")
firms_path <- file.path(
  coh_dir, "obmep_candidates_step_1_degree_duration_firms.parquet")
legacy_selected_path <- file.path(coh_dir, "obmep_candidates_selected.parquet")
name_dir <- file.path(gt_root, "Data/intermediate/fuzzy_match/linkedin_names")
name_files <- sort(list.files(
  name_dir, pattern = "^linkedin_chunk_.*[.]parquet$", full.names = TRUE))

out_path <- Sys.getenv(
  "OBMEP_DD_SELECTED_OUT",
  unset = file.path(coh_dir, "obmep_candidates_selected_degree_duration.parquet"))
part_path <- paste0(out_path, ".part")

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")
tmp_dir <- Sys.getenv(
  "OBMEP_DD_SELECTED_TMP",
  unset = file.path(Sys.getenv("TEMP"), "duckdb_tmp_selected_degree_duration"))

required <- c(cohort_path, cw_degree_path, sh_degree_path, firms_path)
if (!all(file.exists(required))) {
  stop("Missing input(s): ", paste(required[!file.exists(required)], collapse = ", "))
}
if (length(name_files) != 20L) {
  stop("Expected 20 LinkedIn-name chunks, found ", length(name_files), ".")
}
if (file.exists(out_path) || file.exists(part_path)) {
  stop("Output already exists: ", c(out_path, part_path)[
    file.exists(c(out_path, part_path))][1])
}
if (normalizePath(out_path, mustWork = FALSE) ==
    normalizePath(legacy_selected_path, mustWork = FALSE)) {
  stop("The degree-duration output resolves to the protected legacy selection.")
}
dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

input_files <- c(required, name_files)
input_info_before <- file.info(input_files)[, c("size", "mtime"), drop = FALSE]
legacy_md5_before <- if (file.exists(legacy_selected_path)) {
  unname(tools::md5sum(legacy_selected_path))
} else NA_character_

fw <- gsub("\\\\", "/", c(
  cohort = cohort_path, cw_degree = cw_degree_path,
  sh_degree = sh_degree_path, firms = firms_path,
  names = file.path(name_dir, "linkedin_chunk_*.parquet"), output = part_path))

con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
dbExecute(con, sprintf("SET memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", gsub("\\\\", "/", tmp_dir)))
dbExecute(con, "SET preserve_insertion_order=false")

expected_cw_degree <- c(
  "user_id", "cw_any", "cw_rsid_any", "cw_raw_any", "cw_bachelor",
  "cw_master", "cw_master_strict", "cw_phd", "cw_lato", "cw_best_rank",
  "cw_bach_rank", "cw_mast_rank", "cw_phd_rank", "cw_bach_inst",
  "cw_mast_inst", "cw_phd_inst", "cw_bach_year", "cw_mast_year",
  "cw_phd_year", "cw_bach_institutions", "cw_mast_institutions",
  "cw_mast_strict_institutions", "cw_phd_institutions", "cw_n_rows")
expected_sh_degree <- c(
  "user_id", "sh_any", "sh_raw_any", "sh_bachelor", "sh_master",
  "sh_master_strict", "sh_phd", "sh_lato", "sh_best_rank", "sh_bach_rank",
  "sh_mast_rank", "sh_phd_rank", "sh_bach_inst", "sh_mast_inst",
  "sh_phd_inst", "sh_bach_year", "sh_mast_year", "sh_phd_year",
  "sh_n_rows", "sh_rsid_any", "sh_bach_institutions",
  "sh_mast_institutions", "sh_mast_strict_institutions",
  "sh_phd_institutions", "sh_bach_institution_keys",
  "sh_mast_institution_keys", "sh_phd_institution_keys")
expected_firms <- c(
  "user_id", "un_any", "un_exact_any", "un_parent_any", "un_arm3_any",
  "un_best_rank", "un_best_firm", "un_first_year", "n_un_firms",
  "n_un_positions", "tc_any", "tc_exact_any", "tc_parent_any",
  "tc_arm3_any", "tc_best_rank", "tc_best_firm", "tc_first_year",
  "n_tc_firms", "n_tc_positions", "cw_any", "cw_exact_any",
  "cw_parent_any", "cw_best_rank", "cw_best_inst", "cw_first_year",
  "n_cw_inst", "n_cw_positions", "sw_any", "sw_exact_any",
  "sw_parent_any", "sw_best_rank", "sw_best_inst", "sw_first_year",
  "n_sw_inst", "n_sw_positions", "ranked_university_work_any",
  "firm_any", "n_matched_positions")

actual_cw <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", fw["cw_degree"]))$column_name
actual_sh <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", fw["sh_degree"]))$column_name
actual_fm <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", fw["firms"]))$column_name
if (!identical(actual_cw, expected_cw_degree) ||
    !identical(actual_sh, expected_sh_degree) ||
    !identical(actual_fm, expected_firms)) {
  stop("A refreshed flag input has drifted from its validated schema.")
}

input_qa <- dbGetQuery(con, sprintf("
  SELECT
    (SELECT count(*) FROM read_parquet('%1$s')) AS cw_rows,
    (SELECT count(DISTINCT user_id) FROM read_parquet('%1$s')) AS cw_users,
    (SELECT count_if(cw_any <> 1) FROM read_parquet('%1$s')) AS cw_bad,
    (SELECT count(*) FROM read_parquet('%2$s')) AS sh_rows,
    (SELECT count(DISTINCT user_id) FROM read_parquet('%2$s')) AS sh_users,
    (SELECT count_if(sh_any <> 1) FROM read_parquet('%2$s')) AS sh_bad,
    (SELECT count(*) FROM read_parquet('%3$s')) AS firm_rows,
    (SELECT count(DISTINCT user_id) FROM read_parquet('%3$s')) AS firm_users,
    (SELECT count_if(firm_any <> 1 OR
       greatest(un_any, tc_any, cw_any, sw_any) <> 1)
       FROM read_parquet('%3$s')) AS firm_bad",
  fw["cw_degree"], fw["sh_degree"], fw["firms"]))
print(input_qa, row.names = FALSE)
if (input_qa$cw_rows != input_qa$cw_users ||
    input_qa$sh_rows != input_qa$sh_users ||
    input_qa$firm_rows != input_qa$firm_users ||
    input_qa$cw_bad != 0L || input_qa$sh_bad != 0L ||
    input_qa$firm_bad != 0L) {
  stop("Refreshed flag inputs violate their positive-user grain.")
}

dbExecute(con, sprintf("
  CREATE TABLE selected_flags AS
  WITH ids AS (
    SELECT user_id FROM read_parquet('%1$s')
    UNION SELECT user_id FROM read_parquet('%2$s')
    UNION SELECT user_id FROM read_parquet('%3$s'))
  SELECT i.user_id,
    CAST(c.user_id IS NOT NULL AS INTEGER) AS in_cwur_degree,
    CAST(s.user_id IS NOT NULL AS INTEGER) AS in_shanghai_degree,
    CAST(f.user_id IS NOT NULL AS INTEGER) AS in_firms,

    coalesce(c.cw_any, 0)::INTEGER AS cw_degree_any,
    coalesce(c.cw_rsid_any, 0)::INTEGER AS cw_degree_rsid_any,
    coalesce(c.cw_raw_any, 0)::INTEGER AS cw_degree_raw_any,
    coalesce(c.cw_bachelor, 0)::INTEGER AS cw_degree_bachelor,
    coalesce(c.cw_master, 0)::INTEGER AS cw_degree_master,
    coalesce(c.cw_master_strict, 0)::INTEGER AS cw_degree_master_strict,
    coalesce(c.cw_phd, 0)::INTEGER AS cw_degree_phd,
    coalesce(c.cw_lato, 0)::INTEGER AS cw_degree_lato,
    c.cw_best_rank AS cw_degree_best_rank,
    c.cw_bach_rank AS cw_degree_bach_rank,
    c.cw_mast_rank AS cw_degree_mast_rank,
    c.cw_phd_rank AS cw_degree_phd_rank,
    c.cw_bach_inst AS cw_degree_bach_inst,
    c.cw_mast_inst AS cw_degree_mast_inst,
    c.cw_phd_inst AS cw_degree_phd_inst,
    c.cw_bach_year AS cw_degree_bach_year,
    c.cw_mast_year AS cw_degree_mast_year,
    c.cw_phd_year AS cw_degree_phd_year,
    c.cw_bach_institutions AS cw_degree_bach_institutions,
    c.cw_mast_institutions AS cw_degree_mast_institutions,
    c.cw_mast_strict_institutions AS cw_degree_mast_strict_institutions,
    c.cw_phd_institutions AS cw_degree_phd_institutions,
    coalesce(c.cw_n_rows, 0)::INTEGER AS cw_degree_n_rows,

    coalesce(s.sh_any, 0)::INTEGER AS sh_any,
    coalesce(s.sh_raw_any, 0)::INTEGER AS sh_raw_any,
    coalesce(s.sh_bachelor, 0)::INTEGER AS sh_bachelor,
    coalesce(s.sh_master, 0)::INTEGER AS sh_master,
    coalesce(s.sh_master_strict, 0)::INTEGER AS sh_master_strict,
    coalesce(s.sh_phd, 0)::INTEGER AS sh_phd,
    coalesce(s.sh_lato, 0)::INTEGER AS sh_lato,
    s.sh_best_rank, s.sh_bach_rank, s.sh_mast_rank, s.sh_phd_rank,
    s.sh_bach_inst, s.sh_mast_inst, s.sh_phd_inst,
    s.sh_bach_year, s.sh_mast_year, s.sh_phd_year,
    coalesce(s.sh_n_rows, 0)::INTEGER AS sh_n_rows,
    coalesce(s.sh_rsid_any, 0)::INTEGER AS sh_rsid_any,
    s.sh_bach_institutions, s.sh_mast_institutions,
    s.sh_mast_strict_institutions, s.sh_phd_institutions,
    s.sh_bach_institution_keys, s.sh_mast_institution_keys,
    s.sh_phd_institution_keys,

    coalesce(f.un_any, 0)::INTEGER AS un_any,
    coalesce(f.un_exact_any, 0)::INTEGER AS un_exact_any,
    coalesce(f.un_parent_any, 0)::INTEGER AS un_parent_any,
    coalesce(f.un_arm3_any, 0)::INTEGER AS un_arm3_any,
    f.un_best_rank, f.un_best_firm, f.un_first_year,
    coalesce(f.n_un_firms, 0)::INTEGER AS n_un_firms,
    coalesce(f.n_un_positions, 0)::INTEGER AS n_un_positions,
    coalesce(f.tc_any, 0)::INTEGER AS tc_any,
    coalesce(f.tc_exact_any, 0)::INTEGER AS tc_exact_any,
    coalesce(f.tc_parent_any, 0)::INTEGER AS tc_parent_any,
    coalesce(f.tc_arm3_any, 0)::INTEGER AS tc_arm3_any,
    f.tc_best_rank, f.tc_best_firm, f.tc_first_year,
    coalesce(f.n_tc_firms, 0)::INTEGER AS n_tc_firms,
    coalesce(f.n_tc_positions, 0)::INTEGER AS n_tc_positions,
    coalesce(f.cw_any, 0)::INTEGER AS cw_work_any,
    coalesce(f.cw_exact_any, 0)::INTEGER AS cw_work_exact_any,
    coalesce(f.cw_parent_any, 0)::INTEGER AS cw_work_parent_any,
    f.cw_best_rank AS cw_work_best_rank,
    f.cw_best_inst AS cw_work_best_inst,
    f.cw_first_year AS cw_work_first_year,
    coalesce(f.n_cw_inst, 0)::INTEGER AS n_cw_work_inst,
    coalesce(f.n_cw_positions, 0)::INTEGER AS n_cw_work_positions,
    coalesce(f.sw_any, 0)::INTEGER AS sw_any,
    coalesce(f.sw_exact_any, 0)::INTEGER AS sw_exact_any,
    coalesce(f.sw_parent_any, 0)::INTEGER AS sw_parent_any,
    f.sw_best_rank, f.sw_best_inst, f.sw_first_year,
    coalesce(f.n_sw_inst, 0)::INTEGER AS n_sw_inst,
    coalesce(f.n_sw_positions, 0)::INTEGER AS n_sw_positions,
    coalesce(f.ranked_university_work_any, 0)::INTEGER
      AS ranked_university_work_any,
    coalesce(f.firm_any, 0)::INTEGER AS firm_any,
    coalesce(f.n_matched_positions, 0)::INTEGER AS n_matched_positions
  FROM ids i
  LEFT JOIN read_parquet('%1$s') c USING(user_id)
  LEFT JOIN read_parquet('%2$s') s USING(user_id)
  LEFT JOIN read_parquet('%3$s') f USING(user_id)
  WHERE greatest(coalesce(c.cw_any, 0), coalesce(s.sh_any, 0),
    coalesce(f.un_any, 0), coalesce(f.tc_any, 0),
    coalesce(f.cw_any, 0), coalesce(f.sw_any, 0)) = 1",
  fw["cw_degree"], fw["sh_degree"], fw["firms"]))

selection_qa <- dbGetQuery(con, sprintf("
  SELECT count(*) AS users, count(DISTINCT user_id) AS user_ids,
    count_if(user_id IS NULL) AS null_users,
    count_if(greatest(cw_degree_any, sh_any, un_any, tc_any,
      cw_work_any, sw_any) <> 1) AS bad_gate,
    count_if(ranked_university_work_any <>
      greatest(cw_work_any, sw_any)) AS bad_ranked_work,
    count_if(firm_any <> greatest(un_any, tc_any, cw_work_any, sw_any))
      AS bad_firm_union,
    (SELECT count(*) FROM selected_flags x WHERE NOT EXISTS
      (SELECT 1 FROM read_parquet('%s') c WHERE c.user_id=x.user_id))
      AS outside_cohort
  FROM selected_flags", fw["cohort"]))
print(selection_qa, row.names = FALSE)
if (selection_qa$users != selection_qa$user_ids ||
    selection_qa$null_users != 0L || selection_qa$bad_gate != 0L ||
    selection_qa$bad_ranked_work != 0L ||
    selection_qa$bad_firm_union != 0L || selection_qa$outside_cohort != 0L) {
  stop("Selected-profile union failed structural validation.")
}
if (selection_qa$users != 2289937L) {
  warning("Selected union is ", selection_qa$users,
          ", not the 2,289,937-user preflight value.")
}

cat("Scanning 20 LinkedIn-name chunks (local, 15.17 GB)...\n")
dbExecute(con, sprintf("
  CREATE TABLE selected_names AS
  SELECT n.user_id, n.fullname
  FROM read_parquet('%s') n
  SEMI JOIN selected_flags s USING(user_id)", fw["names"]))
name_qa <- dbGetQuery(con, "
  SELECT count(*) AS names, count(DISTINCT user_id) AS user_ids
  FROM selected_names")
if (name_qa$names != name_qa$user_ids) {
  stop("The LinkedIn-name join would multiply selected users.")
}

dbExecute(con, "
  CREATE TABLE output AS
  SELECT s.user_id, n.fullname, s.* EXCLUDE(user_id)
  FROM selected_flags s LEFT JOIN selected_names n USING(user_id)")
output_qa <- dbGetQuery(con, "
  SELECT count(*) AS users, count(DISTINCT user_id) AS user_ids,
    count_if(fullname IS NOT NULL) AS named
  FROM output")
if (output_qa$users != selection_qa$users ||
    output_qa$users != output_qa$user_ids) {
  stop("Attaching names changed the selected-user grain.")
}

dbExecute(con, sprintf(
  "COPY (SELECT * FROM output ORDER BY user_id) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", fw["output"]))
out_ds <- arrow::open_dataset(part_path, format = "parquet")
if (nrow(out_ds) != output_qa$users ||
    names(out_ds)[1] != "user_id" || names(out_ds)[2] != "fullname" ||
    any(grepl("^cw_(?!degree_|work_)", names(out_ds), perl = TRUE)) ||
    !all(c("cw_degree_any", "cw_work_any", "sh_any", "sw_any",
           "un_any", "tc_any") %in% names(out_ds))) {
  stop("Staged selected-profile Parquet failed schema/readback validation.")
}

input_info_after <- file.info(input_files)[, c("size", "mtime"), drop = FALSE]
legacy_md5_after <- if (file.exists(legacy_selected_path)) {
  unname(tools::md5sum(legacy_selected_path))
} else NA_character_
if (!identical(input_info_before, input_info_after) ||
    !identical(legacy_md5_before, legacy_md5_after)) {
  stop("An immutable input or the protected legacy selection changed.")
}
if (!file.rename(part_path, out_path)) stop("Could not publish ", out_path)

cat("\nSelected users:", format(output_qa$users, big.mark = ","), "\n")
cat("With fullname :", format(output_qa$named, big.mark = ","), "\n")
cat("Output        :", out_path, "\n")
cat("[OK] Published degree-duration selected profiles; legacy output intact.\n")
