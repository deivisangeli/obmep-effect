####################################################################
### Full employer flags for the refreshed degree-duration cohort
###
### LOCAL, OFFLINE PREPARATION. Unicorn and top-tech-company RCIDs are
### reused from the established company products. Brazilian CWUR and
### Shanghai use the degree-duration university RCID map. The source
### position and RCID directories are immutable inputs.
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "arrow", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) stop("Missing package: ", p)
}
library(DBI)
library(duckdb)

root <- Sys.getenv("OBMEP_ROOT",
                   unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh <- file.path(root, "Data/intermediate/revelio_br_cohort")
position_dir <- file.path(coh, "obmep_candidates_step_1_degree_duration_position")
rcid_dir <- file.path(coh, "obmep_candidates_step_1_degree_duration_position_rcid")
cohort_path <- file.path(coh, "obmep_candidates_step_1_degree_duration.parquet")
firm_path <- file.path(root, "Data/intermediate/linkedin_company_urls",
                       "linkedin_company_rcid_2026.parquet")
unresolved_path <- file.path(root, "Data/intermediate/linkedin_company_urls",
                             "linkedin_company_unresolved_2026.parquet")
university_path <- file.path(
  root, "Data/intermediate/degree_duration_ranked_university_company_rcid",
  "degree_duration_ranked_university_company_rcid.parquet")

run_id <- Sys.getenv("OBMEP_DD_FIRMS_RUN_ID", unset = format(Sys.time(), "%Y%m%dT%H%M%S"))
if (!grepl("^[0-9]{8}T[0-9]{6}$", run_id)) stop("Invalid run id: ", run_id)
stage_dir <- file.path(coh, ".degree_duration_firms_staging", run_id)
backup_dir <- file.path(coh, "degree_duration_firms_backups", run_id)
dest <- c(
  positions = file.path(coh, "obmep_candidates_step_1_degree_duration_firms_positions.parquet"),
  users = file.path(coh, "obmep_candidates_step_1_degree_duration_firms.parquet"),
  report = file.path(coh, "degree_duration_firm_flags_report.json"))
stage <- file.path(stage_dir, basename(dest)); names(stage) <- names(dest)

inputs <- c(position_dir, rcid_dir, cohort_path, firm_path,
            unresolved_path, university_path)
if (!all(file.exists(inputs))) {
  stop("Missing input(s): ", paste(inputs[!file.exists(inputs)], collapse = ", "))
}
if (dir.exists(stage_dir) && length(list.files(stage_dir, all.files = TRUE, no.. = TRUE))) {
  stop("Staging directory is not empty: ", stage_dir)
}
dir.create(stage_dir, recursive = TRUE, showWarnings = FALSE)

input_files <- c(
  sort(list.files(position_dir, full.names = TRUE)),
  sort(list.files(rcid_dir, full.names = TRUE)),
  cohort_path, firm_path, unresolved_path, university_path)
input_info_before <- file.info(input_files)[, c("size", "mtime"), drop = FALSE]
small_inputs <- c(cohort_path, firm_path, unresolved_path, university_path)
small_md5_before <- unname(tools::md5sum(small_inputs))

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")
tmp_dir <- Sys.getenv(
  "OBMEP_DD_FIRMS_TMP", unset = file.path(Sys.getenv("TEMP"), "duckdb_dd_firm_flags"))
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
fw <- function(p) gsub("\\\\", "/", p)
pos_src <- sprintf("read_parquet('%s/*')", fw(position_dir))
rcid_src <- sprintf("read_parquet('%s/*')", fw(rcid_dir))

con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
dbExecute(con, sprintf("SET memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", fw(tmp_dir)))
dbExecute(con, "SET preserve_insertion_order=false")

cat("=========== INPUT GRAIN ===========\n")
grain <- dbGetQuery(con, sprintf("
 SELECT (SELECT count(*) FROM %1$s) position_rows,
        (SELECT count(DISTINCT position_id) FROM %1$s) position_ids,
        (SELECT count(DISTINCT user_id) FROM %1$s) position_users,
        (SELECT count(*) FROM %2$s) rcid_rows,
        (SELECT count(DISTINCT position_id) FROM %2$s) rcid_ids,
        (SELECT count(DISTINCT user_id) FROM %2$s) rcid_users",
 pos_src, rcid_src))
print(grain, row.names = FALSE)
if (grain$position_rows != 37984489L || grain$position_ids != grain$position_rows ||
    grain$position_users != 8901904L || grain$rcid_rows != grain$position_rows ||
    grain$rcid_ids != grain$rcid_rows || grain$rcid_users != grain$position_users) {
  stop("Position and RCID inputs do not share the validated refreshed-cohort grain.")
}
anti <- dbGetQuery(con, sprintf("
 SELECT (SELECT count(*) FROM %1$s p WHERE NOT EXISTS
         (SELECT 1 FROM %2$s r WHERE r.position_id=p.position_id)) position_only,
        (SELECT count(*) FROM %2$s r WHERE NOT EXISTS
         (SELECT 1 FROM %1$s p WHERE p.position_id=r.position_id)) rcid_only",
 pos_src, rcid_src))
if (anti$position_only != 0 || anti$rcid_only != 0) stop("Position anti-join failed.")

cat("\n=========== CORPORATE RCIDS ===========\n")
dbExecute(con, sprintf("CREATE TABLE firm0 AS SELECT * FROM read_parquet('%s')",
                       fw(firm_path)))
if (dbGetQuery(con, "SELECT count(*) n FROM (SELECT rcid FROM firm0
 GROUP BY 1 HAVING count(*)<>1)")$n != 0) stop("Resolved firm map is not unique on rcid.")

dbExecute(con, sprintf("
CREATE TABLE arm3_candidates AS
WITH misses AS (SELECT * FROM read_parquet('%1$s')),
url_map AS (
 SELECT regexp_replace(regexp_replace(regexp_replace(regexp_replace(
        lower(trim(p.company_linkedin_url)),'^https?://',''),'^www[.]',''),
        '[?#].*$',''),'/+$','') url_norm,
        r.rcid,count(*) n_positions
 FROM %2$s p JOIN %3$s r USING(position_id)
 WHERE p.company_linkedin_url IS NOT NULL AND r.rcid IS NOT NULL
 GROUP BY 1,2)
SELECT m.lst,m.ident,m.nm,m.url_norm,count(DISTINCT u.rcid) n_rcid,
       min(u.rcid) rcid,sum(u.n_positions) n_positions
FROM misses m JOIN url_map u USING(url_norm) GROUP BY 1,2,3,4",
 fw(unresolved_path), pos_src, rcid_src))

dbExecute(con, "
CREATE TABLE firm AS
SELECT CAST(rcid AS BIGINT) rcid,in_unicorn,in_techcap,un_canonical_name,
 un_best_rank,tc_rank,tc_name,ref_primary_name,0::INTEGER arm3
FROM firm0
UNION ALL
SELECT CAST(a.rcid AS BIGINT),
 max(CAST(a.lst='unicorn' AS INTEGER))::INTEGER,
 max(CAST(a.lst='techcap' AS INTEGER))::INTEGER,
 first(a.nm ORDER BY a.nm) FILTER(WHERE a.lst='unicorn'),NULL::INTEGER,
 min(try_cast(a.ident AS INTEGER)) FILTER(WHERE a.lst='techcap'),
 first(a.nm ORDER BY try_cast(a.ident AS INTEGER),a.nm)
   FILTER(WHERE a.lst='techcap'),NULL,1::INTEGER
FROM arm3_candidates a WHERE a.n_rcid=1 AND NOT EXISTS
 (SELECT 1 FROM firm0 f WHERE CAST(f.rcid AS BIGINT)=CAST(a.rcid AS BIGINT))
GROUP BY a.rcid")
if (dbGetQuery(con, "SELECT count(*) n FROM (SELECT rcid FROM firm
 GROUP BY 1 HAVING count(*)<>1)")$n != 0) stop("Final corporate map is not unique on rcid.")

cat("\n=========== UNIVERSITY RCIDS ===========\n")
dbExecute(con, sprintf("
CREATE TABLE university_map AS
SELECT family,expanded_rcid::BIGINT expanded_rcid,canonical_oa_id,
 min(rank)::INTEGER rank,
 first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id) institution_name,
 first(source_oa_id ORDER BY rank,source_oa_id,canonical_oa_id) source_oa_id,
 list_sort(list_distinct(list(rcid_role))) rcid_roles
FROM read_parquet('%s')
GROUP BY family,expanded_rcid,canonical_oa_id", fw(university_path)))
university_summary <- dbGetQuery(con, "SELECT family,count(*) mapping_rows,
 count(DISTINCT expanded_rcid) rcids,count(DISTINCT canonical_oa_id) institutions
 FROM university_map GROUP BY 1 ORDER BY 1")
print(university_summary, row.names = FALSE)
if (!setequal(university_summary$family, c("cwur", "shanghai")) ||
    dbGetQuery(con, "SELECT count(*) n FROM university_map
                    WHERE expanded_rcid IS NULL")$n != 0) {
  stop("University map has an invalid family or identifier.")
}

dbExecute(con, sprintf("
CREATE TABLE university_position_match AS
WITH base AS (
 SELECT p.position_id,p.user_id,r.rcid,r.ultimate_parent_rcid
 FROM %1$s p JOIN %2$s r USING(position_id)
), matches AS (
 SELECT b.position_id,b.user_id,u.*,'exact' position_key
 FROM base b JOIN university_map u ON b.rcid=u.expanded_rcid
 UNION ALL
 SELECT b.position_id,b.user_id,u.*,'parent' position_key
 FROM base b JOIN university_map u ON b.ultimate_parent_rcid=u.expanded_rcid
)
SELECT position_id,user_id,family,canonical_oa_id,position_key,
 min(rank)::INTEGER rank,
 first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id) institution_name,
 first(source_oa_id ORDER BY rank,source_oa_id,canonical_oa_id) source_oa_id,
 list_sort(list_distinct(list(expanded_rcid))) matched_rcids
FROM matches GROUP BY position_id,user_id,family,canonical_oa_id,position_key",
 pos_src, rcid_src))

dbExecute(con, "
CREATE TABLE university_position AS
SELECT position_id,user_id,
 CAST(bool_or(family='cwur' AND position_key='exact') AS INTEGER) cw_exact,
 CAST(bool_or(family='cwur' AND position_key='parent') AS INTEGER) cw_parent,
 min(rank) FILTER(WHERE family='cwur')::INTEGER cw_rank,
 first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id)
   FILTER(WHERE family='cwur') cw_inst,
 first(source_oa_id ORDER BY rank,source_oa_id,canonical_oa_id)
   FILTER(WHERE family='cwur') cw_source_oa_id,
 coalesce(list_sort(list_distinct(list(canonical_oa_id)
   FILTER(WHERE family='cwur'))),[]::VARCHAR[]) cw_institution_ids,
 CAST(bool_or(family='shanghai' AND position_key='exact') AS INTEGER) sw_exact,
 CAST(bool_or(family='shanghai' AND position_key='parent') AS INTEGER) sw_parent,
 min(rank) FILTER(WHERE family='shanghai')::INTEGER sw_rank,
 first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id)
   FILTER(WHERE family='shanghai') sw_inst,
 first(source_oa_id ORDER BY rank,source_oa_id,canonical_oa_id)
   FILTER(WHERE family='shanghai') sw_source_oa_id,
 coalesce(list_sort(list_distinct(list(canonical_oa_id)
   FILTER(WHERE family='shanghai'))),[]::VARCHAR[]) sw_institution_ids
FROM university_position_match GROUP BY position_id,user_id")
if (dbGetQuery(con, "SELECT count(*) n FROM (SELECT position_id
 FROM university_position GROUP BY 1 HAVING count(*)<>1)")$n != 0) {
  stop("University aggregation multiplied position_id.")
}

cat("\n=========== MATCHED POSITIONS ===========\n")
dbExecute(con, sprintf("
CREATE TABLE hits AS
SELECT p.*,
 r.rcid,r.ultimate_parent_rcid,
 CAST(fe.rcid IS NOT NULL AND fe.in_unicorn=1 AS INTEGER) un_exact,
 CAST(fp.rcid IS NOT NULL AND fp.in_unicorn=1 AS INTEGER) un_parent,
 greatest(un_exact,un_parent)::INTEGER un_any,
 CAST(fe.rcid IS NOT NULL AND fe.in_techcap=1 AS INTEGER) tc_exact,
 CAST(fp.rcid IS NOT NULL AND fp.in_techcap=1 AS INTEGER) tc_parent,
 greatest(tc_exact,tc_parent)::INTEGER tc_any,
 greatest(coalesce(fe.arm3,0),coalesce(fp.arm3,0))::INTEGER firm_arm3,
 coalesce(fe.un_canonical_name,fp.un_canonical_name) un_firm,
 coalesce(fe.un_best_rank,fp.un_best_rank)::INTEGER un_rank,
 coalesce(fe.tc_name,fp.tc_name) tc_firm,
 coalesce(fe.tc_rank,fp.tc_rank)::INTEGER tc_rank,
 coalesce(u.cw_exact,0)::INTEGER cw_exact,
 coalesce(u.cw_parent,0)::INTEGER cw_parent,
 greatest(cw_exact,cw_parent)::INTEGER cw_any,
 u.cw_rank,u.cw_inst,u.cw_source_oa_id,
 coalesce(u.cw_institution_ids,[]::VARCHAR[]) cw_institution_ids,
 coalesce(u.sw_exact,0)::INTEGER sw_exact,
 coalesce(u.sw_parent,0)::INTEGER sw_parent,
 greatest(sw_exact,sw_parent)::INTEGER sw_any,
 u.sw_rank,u.sw_inst,u.sw_source_oa_id,
 coalesce(u.sw_institution_ids,[]::VARCHAR[]) sw_institution_ids,
 greatest(cw_any,sw_any)::INTEGER ranked_university_work,
 greatest(un_any,tc_any,cw_any,sw_any)::INTEGER firm_match,
 try_cast(substr(p.startdate,1,4) AS INTEGER)::INTEGER start_year
FROM %1$s p JOIN %2$s r USING(position_id)
LEFT JOIN firm fe ON r.rcid=fe.rcid
LEFT JOIN firm fp ON r.ultimate_parent_rcid=fp.rcid
LEFT JOIN university_position u
 ON u.position_id=p.position_id AND u.user_id=p.user_id
WHERE fe.rcid IS NOT NULL OR fp.rcid IS NOT NULL OR u.position_id IS NOT NULL",
 pos_src, rcid_src))

hit_summary <- dbGetQuery(con, "SELECT count(*) positions,
 count(DISTINCT position_id) position_ids,count(DISTINCT user_id) users,
 sum(un_any) unicorn_positions,sum(tc_any) techcap_positions,
 sum(cw_any) cwur_positions,sum(sw_any) shanghai_positions,
 sum(ranked_university_work) ranked_university_positions FROM hits")
print(hit_summary, row.names = FALSE)
if (hit_summary$positions != hit_summary$position_ids ||
    dbGetQuery(con, "SELECT count(*) n FROM hits WHERE firm_match<>1 OR
      ranked_university_work<>greatest(cw_any,sw_any) OR
      un_any<>greatest(un_exact,un_parent) OR tc_any<>greatest(tc_exact,tc_parent)
      OR cw_any<>greatest(cw_exact,cw_parent) OR sw_any<>greatest(sw_exact,sw_parent)")$n != 0) {
  stop("Matched-position grain or flag relations failed.")
}

cat("\n=========== USER FLAGS ===========\n")
dbExecute(con, "
CREATE TABLE output_users AS
SELECT user_id,
 max(un_any)::INTEGER un_any,max(un_exact)::INTEGER un_exact_any,
 max(un_parent)::INTEGER un_parent_any,
 max(CASE WHEN un_any=1 THEN firm_arm3 ELSE 0 END)::INTEGER un_arm3_any,
 min(un_rank) FILTER(WHERE un_any=1)::INTEGER un_best_rank,
 first(un_firm ORDER BY un_rank,un_firm) FILTER(WHERE un_any=1) un_best_firm,
 min(start_year) FILTER(WHERE un_any=1)::INTEGER un_first_year,
 count(DISTINCT rcid) FILTER(WHERE un_any=1)::INTEGER n_un_firms,
 sum(un_any)::INTEGER n_un_positions,
 max(tc_any)::INTEGER tc_any,max(tc_exact)::INTEGER tc_exact_any,
 max(tc_parent)::INTEGER tc_parent_any,
 max(CASE WHEN tc_any=1 THEN firm_arm3 ELSE 0 END)::INTEGER tc_arm3_any,
 min(tc_rank) FILTER(WHERE tc_any=1)::INTEGER tc_best_rank,
 first(tc_firm ORDER BY tc_rank,tc_firm) FILTER(WHERE tc_any=1) tc_best_firm,
 min(start_year) FILTER(WHERE tc_any=1)::INTEGER tc_first_year,
 count(DISTINCT rcid) FILTER(WHERE tc_any=1)::INTEGER n_tc_firms,
 sum(tc_any)::INTEGER n_tc_positions,
 max(cw_any)::INTEGER cw_any,max(cw_exact)::INTEGER cw_exact_any,
 max(cw_parent)::INTEGER cw_parent_any,
 min(cw_rank) FILTER(WHERE cw_any=1)::INTEGER cw_best_rank,
 first(cw_inst ORDER BY cw_rank,cw_source_oa_id,cw_inst)
   FILTER(WHERE cw_any=1) cw_best_inst,
 min(start_year) FILTER(WHERE cw_any=1)::INTEGER cw_first_year,
 coalesce(len(list_distinct(flatten(list(cw_institution_ids)
   FILTER(WHERE cw_any=1)))),0)::INTEGER n_cw_inst,
 sum(cw_any)::INTEGER n_cw_positions,
 max(sw_any)::INTEGER sw_any,max(sw_exact)::INTEGER sw_exact_any,
 max(sw_parent)::INTEGER sw_parent_any,
 min(sw_rank) FILTER(WHERE sw_any=1)::INTEGER sw_best_rank,
 first(sw_inst ORDER BY sw_rank,sw_source_oa_id,sw_inst)
   FILTER(WHERE sw_any=1) sw_best_inst,
 min(start_year) FILTER(WHERE sw_any=1)::INTEGER sw_first_year,
 coalesce(len(list_distinct(flatten(list(sw_institution_ids)
   FILTER(WHERE sw_any=1)))),0)::INTEGER n_sw_inst,
 sum(sw_any)::INTEGER n_sw_positions,
 max(ranked_university_work)::INTEGER ranked_university_work_any,
 1::INTEGER firm_any,count(*)::INTEGER n_matched_positions
FROM hits GROUP BY user_id")

user_summary <- dbGetQuery(con, "SELECT count(*) users,
 count(DISTINCT user_id) user_ids,sum(un_any) unicorn_users,
 sum(tc_any) techcap_users,sum(cw_any) cwur_users,sum(sw_any) shanghai_users,
 sum(ranked_university_work_any) ranked_university_users FROM output_users")
print(user_summary, row.names = FALSE)
if (user_summary$users != user_summary$user_ids ||
    dbGetQuery(con, "SELECT count(*) n FROM output_users WHERE firm_any<>1 OR
     ranked_university_work_any<>greatest(cw_any,sw_any) OR
     un_any<>greatest(un_exact_any,un_parent_any) OR
     tc_any<>greatest(tc_exact_any,tc_parent_any) OR
     cw_any<>greatest(cw_exact_any,cw_parent_any) OR
     sw_any<>greatest(sw_exact_any,sw_parent_any)")$n != 0) {
  stop("User grain or flag relations failed.")
}

rollup_diff <- dbGetQuery(con, "WITH x AS (
 SELECT user_id,max(un_any) un_any,max(tc_any) tc_any,max(cw_any) cw_any,
 max(sw_any) sw_any,max(ranked_university_work) ruw,count(*) n
 FROM hits GROUP BY 1)
SELECT count(*) n FROM x JOIN output_users u USING(user_id)
WHERE x.un_any<>u.un_any OR x.tc_any<>u.tc_any OR x.cw_any<>u.cw_any
 OR x.sw_any<>u.sw_any OR x.ruw<>u.ranked_university_work_any
 OR x.n<>u.n_matched_positions")$n
if (rollup_diff != 0) stop("Independent position-to-user rollup failed.")

arm3_summary <- dbGetQuery(con, "SELECT lst,count(*) listed_rows,
 count(*) FILTER(WHERE n_rcid=1) resolved_rows,
 count(*) FILTER(WHERE n_rcid>1) ambiguous_rows
 FROM arm3_candidates GROUP BY 1 ORDER BY 1")
largest <- dbGetQuery(con, "SELECT company_raw,
 sum(un_any) unicorn_positions,sum(tc_any) techcap_positions,
 sum(cw_any) cwur_positions,sum(sw_any) shanghai_positions
 FROM hits GROUP BY 1 ORDER BY greatest(unicorn_positions,techcap_positions,
 cwur_positions,shanghai_positions) DESC,company_raw LIMIT 100")

expected_user_cols <- c(
 "user_id","un_any","un_exact_any","un_parent_any","un_arm3_any",
 "un_best_rank","un_best_firm","un_first_year","n_un_firms","n_un_positions",
 "tc_any","tc_exact_any","tc_parent_any","tc_arm3_any","tc_best_rank",
 "tc_best_firm","tc_first_year","n_tc_firms","n_tc_positions",
 "cw_any","cw_exact_any","cw_parent_any","cw_best_rank","cw_best_inst",
 "cw_first_year","n_cw_inst","n_cw_positions",
 "sw_any","sw_exact_any","sw_parent_any","sw_best_rank","sw_best_inst",
 "sw_first_year","n_sw_inst","n_sw_positions","ranked_university_work_any",
 "firm_any","n_matched_positions")

dbExecute(con, sprintf("COPY (SELECT * FROM hits ORDER BY user_id,position_id)
 TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)", fw(stage["positions"])))
dbExecute(con, sprintf("COPY (SELECT * FROM output_users ORDER BY user_id)
 TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)", fw(stage["users"])))
pos_ds <- arrow::open_dataset(stage["positions"], format = "parquet")
user_ds <- arrow::open_dataset(stage["users"], format = "parquet")
if (nrow(pos_ds) != hit_summary$positions || nrow(user_ds) != user_summary$users ||
    !identical(names(user_ds), expected_user_cols)) {
  stop("Staged output schema or row count failed Parquet reread.")
}

input_info_after <- file.info(input_files)[, c("size", "mtime"), drop = FALSE]
if (!identical(input_info_before, input_info_after) ||
    !identical(small_md5_before, unname(tools::md5sum(small_inputs)))) {
  stop("An immutable input changed during the build.")
}

report <- list(
  generated_at = format(Sys.time(), tz = "UTC", usetz = TRUE), run_id = run_id,
  method = list(corporate_source = firm_path,
    corporate_rescue = "exact normalized cohort URL accepted only at one RCID",
    university_source = university_path,
    position_keys = c("rcid", "ultimate_parent_rcid"),
    university_families = c("cwur", "shanghai")),
  input_md5 = data.frame(path = small_inputs, md5 = small_md5_before),
  input_grain = grain, position_antijoin = anti,
  university_catalog = university_summary, arm3 = arm3_summary,
  matched_positions = hit_summary, user_flags = user_summary,
  largest_employer_labels = largest,
  checks = list(position_ids_identical = TRUE, position_output_unique = TRUE,
    user_output_unique = TRUE, binary_flag_relations = TRUE,
    independent_rollup = TRUE, staged_parquet_reread = TRUE,
    immutable_inputs = TRUE))
jsonlite::write_json(report, stage["report"], pretty = TRUE, auto_unbox = TRUE,
                     dataframe = "rows", na = "null", digits = 16)

if (any(file.exists(dest))) {
  dir.create(backup_dir, recursive = TRUE, showWarnings = FALSE)
  for (p in dest[file.exists(dest)]) {
    if (!file.copy(p, file.path(backup_dir, basename(p)), overwrite = FALSE)) {
      stop("Could not back up ", p)
    }
  }
}
stage_md5 <- unname(tools::md5sum(stage))
for (nm in names(dest)) {
  tmp <- paste0(dest[nm], ".publishing_", run_id)
  if (!file.copy(stage[nm], tmp, overwrite = TRUE) ||
      !identical(unname(tools::md5sum(stage[nm])), unname(tools::md5sum(tmp)))) {
    stop("Could not stage publication for ", dest[nm])
  }
  if (file.exists(dest[nm]) && !file.remove(dest[nm])) stop("Could not replace ", dest[nm])
  if (!file.rename(tmp, dest[nm])) stop("Could not publish ", dest[nm])
}
if (!identical(stage_md5, unname(tools::md5sum(dest)))) {
  stop("Published checksums differ from the validated staging files.")
}
cat("[OK] Published refreshed full-firm flags. Backup: ", backup_dir, "\n", sep = "")
