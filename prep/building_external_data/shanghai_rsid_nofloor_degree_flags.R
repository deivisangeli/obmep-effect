# Offline local prep. The public entrypoint keeps the Shanghai alias synchronized
# with the parent-adjusted Shanghai and RUF rebuild. The internal branch remains
# the legacy no-floor row-matching engine used by rebuild_education_flags.R.
if (Sys.getenv('OBMEP_FLAG_BUILD_INTERNAL')!='1') {
  source('prep/building_external_data/redefine_ranked_education_flags.R')
} else {
# Local prep, offline. Never send to SEDAP.
# User-requested alternative: every real-rsid crosswalk pair, with no floor or
# audit/country filter. Only missing-rsid rows receive the C_norm raw fallback.
# This internal engine stages matches; the driver backs up and replaces flag products.
# Run from repo root; --test exercises the same pipeline on explicit fixtures.
library(DBI)
library(duckdb)
library(jsonlite)
options(stringsAsFactors=FALSE)
test_run <- '--test' %in% commandArgs(trailingOnly=TRUE)
obmep_root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh_dir <- file.path(obmep_root,'Data/intermediate/revelio_br_cohort')
ranking_path <- file.path(obmep_root,'Data/intermediate/shanghai_ranking/shanghai_ranking_oa_parents.parquet')
crosswalk_path <- file.path(obmep_root,'Data/intermediate/shanghai_ranking/shanghai_rsid_oa_crosswalk.parquet')
ed_dir <- file.path(coh_dir,'obmep_candidates_step_1_education')
baseline_path <- file.path(coh_dir,'obmep_candidates_step_1_shanghai.parquet')
out_dir <- coh_dir
patterns_path <- Sys.getenv('OBMEP_DEGREE_PATTERNS','prep/building_external_data/br_degree_patterns.R')
source(patterns_path)
# Veto applies only in flag production, never in the cohort's shared constants.
sql_shanghai_level <- sprintf("CASE WHEN regexp_like(dr,'%s') THEN 'other' ELSE (%s) END",rx_hs,sql_shanghai_level)
con <- dbConnect(duckdb())
invisible(dbExecute(con,"SET memory_limit='8GB'"))
invisible(dbExecute(con,'SET threads=4'))
spill_dir <- gsub('\\\\','/',file.path(Sys.getenv('TEMP'),'duckdb_shanghai_rsid_nofloor'))
dir.create(spill_dir,recursive=TRUE,showWarnings=FALSE)
invisible(dbExecute(con,sprintf("SET temp_directory='%s'",spill_dir)))
invisible(dbExecute(con,'CREATE MACRO regexp_like(s,p) AS regexp_matches(s,p)'))

if (test_run) {
  # Fixtures live under the project's designated test root, not production data.
  out_dir <- file.path(obmep_root,'test/education_flags_rebuild/fixtures/sh')
  ed_dir <- file.path(out_dir,'education')
  dir.create(ed_dir,recursive=TRUE,showWarnings=FALSE)
  ranking_path <- file.path(out_dir,'ranking.parquet')
  crosswalk_path <- file.path(out_dir,'crosswalk.parquet')
  baseline_path <- file.path(out_dir,'baseline.parquet')
  invisible(dbExecute(con,"CREATE TABLE fixture_ranking AS SELECT * FROM (VALUES
    ('I1',10,'Alpha University','Universit\u00e9 Alpha','Alpha University',1),
    ('I2',20,'Beta University','Beta University','Beta Uni',1),
    ('I3',20,'Gamma University','Gamma University','Gamma Uni',1),
    ('missing-id',30,'No ID University',NULL,NULL,0),
    ('I5',40,'Shared College East','Shared College','East College',1),
    ('I6',50,'Shared College West','Shared College','West College',1)
    ) t(oa_key,shanghai_rank,shanghai_name,display_name,cleaned_display_name,oa_id_valid)"))
  invisible(dbExecute(con,sprintf("COPY fixture_ranking TO '%s' (FORMAT PARQUET)",ranking_path)))
  invisible(dbExecute(con,"CREATE TABLE fixture_crosswalk AS
    SELECT CAST(v.rsid AS INTEGER) rsid,r.oa_key,r.shanghai_rank,r.shanghai_name,
      CAST(1 AS BIGINT) n_rows,CAST(1000000 AS BIGINT) rsid_n_rows
    FROM (VALUES (10,'I1'),(10,'I2'),(11,'I1'),(12,'I3'),(12,'I2'),
      (NULL,'I1'),(2147483647,'I1')) v(rsid,oa_key)
    JOIN fixture_ranking r USING(oa_key)"))
  invisible(dbExecute(con,sprintf("COPY fixture_crosswalk TO '%s' (FORMAT PARQUET)",crosswalk_path)))
  invisible(dbExecute(con,"CREATE TABLE fixture_education AS
    SELECT CAST(uid AS BIGINT) user_id,raw AS university_raw,'ignored normalized name' university_name,
      CAST(school AS INTEGER) rsid,dr AS degree_raw,dg AS degree,
      DATE '2001-01-01' startdate,DATE '2005-01-01' enddate
    FROM (VALUES
      (9007199254740993,10,'different typed school','bachelor','Bachelor'),
      (9007199254740993,10,'different typed school','bachelor','Bachelor'),
      (2,11,NULL,'MBA','MBA'),
      (3,12,'anything','master','Master'),
      (4,999,'Alpha University','bachelor','Bachelor'),
      (5,NULL,'  UNIVERSITE ALPHA  ','bachelor','Bachelor'),
      (6,NULL,'Dept / Beta University','master','Master'),
      (7,NULL,'School (Gamma University)','phd','Doctor'),
      (8,NULL,'Course | Alpha University','bachelor','Bachelor'),
      (9,NULL,'Course - Alpha University','bachelor','Bachelor'),
      (10,NULL,'No ID University','bachelor','Bachelor'),
      (11,NULL,'Beta Uni','bachelor','Bachelor'),
      (12,NULL,'Shared College','bachelor','Bachelor'),
      (13,NULL,'','bachelor','Bachelor'),
      (14,NULL,NULL,'bachelor','Bachelor'),
      (15,NULL,'Alpha University extra text','bachelor','Bachelor'),
      (16,NULL,'AB','bachelor','Bachelor'),
      (17,2147483647,'Alpha University','bachelor','Bachelor'),
      (18,NULL,'Alpha University / Beta University','bachelor','Bachelor'),
      (19,10,'ignored','pos-doutorado','Doctor'),
      (20,10,'ignored','MBA','MBA'),
      (21,10,'ignored','master','Master'),
      (21,NULL,'Gamma University','especializacao lato sensu','Other'),
      (22,10,'ignored','phd','Doctor'),
      (23,10,'ignored','bachelor','Bachelor'),
      (23,NULL,'Beta University','master','Master')
    ) t(uid,school,raw,dr,dg)"))
  invisible(dbExecute(con,"INSERT INTO fixture_education VALUES
    (24,'misclassified secondary','ignored',10,'high school','Bachelor',DATE '2010-01-01',NULL),
    (25,'misclassified technical','ignored',10,'curso tecnico','Master',DATE '2010-01-01',NULL),
    (26,'bachelor despite label','ignored',10,'bacharelado','High School',DATE '2010-01-01',NULL),
    (27,'missing year','ignored',10,'bachelor','Bachelor',NULL,NULL)"))
  invisible(dbExecute(con,sprintf("COPY fixture_education TO '%s/part.parquet' (FORMAT PARQUET)",ed_dir)))
  invisible(dbExecute(con,sprintf("COPY (SELECT user_id,1 AS sh_any,1 AS sh_bachelor,
    0 AS sh_master,0 AS sh_master_strict,0 AS sh_phd FROM fixture_education
    WHERE user_id IN (4,5)) TO '%s' (FORMAT PARQUET)",baseline_path)))
}
stopifnot(file.exists(ranking_path),file.exists(crosswalk_path),dir.exists(ed_dir),file.exists(baseline_path))
out_dir <- Sys.getenv('OBMEP_FLAG_STAGE_DIR')
stopifnot(nzchar(out_dir),dir.exists(out_dir))
prefix <- 'obmep_candidates_step_1_shanghai_rsid_nofloor'
matches_path <- file.path(out_dir,paste0(prefix,'_matches.parquet'))
flags_path <- file.path(out_dir,paste0(prefix,'.parquet'))
matches_stage <- file.path(out_dir,paste0(prefix,'_matches.building.parquet'))
flags_stage <- file.path(out_dir,paste0(prefix,'.building.parquet'))
report_path <- file.path(out_dir,paste0(prefix,'_report.json'))
manifest_paths <- c(ranking_path,crosswalk_path,baseline_path,patterns_path,sort(Sys.glob(file.path(ed_dir,'*'))))
input_md5 <- tools::md5sum(manifest_paths)
invisible(dbExecute(con,sprintf("CREATE VIEW education AS SELECT * EXCLUDE(filename,file_row_number),
  filename AS source_file,file_row_number AS source_row
  FROM read_parquet('%s/*',filename=true,file_row_number=true)",ed_dir)))
invisible(dbExecute(con,sprintf("CREATE VIEW ranked AS SELECT oa_key,shanghai_rank,shanghai_name,
  display_name,cleaned_display_name,
  CASE WHEN oa_id_valid=1 AND regexp_full_match(oa_key,'I[0-9]+') THEN oa_key END openalex_id
  FROM read_parquet('%s') WHERE shanghai_rank<=901",ranking_path)))
stopifnot(dbGetQuery(con,'SELECT count(*) n FROM ranked')$n==if(test_run) 6L else 1000L)
stopifnot(dbGetQuery(con,'SELECT count(*)-count(DISTINCT oa_key) n FROM ranked')$n==0L)
invisible(dbExecute(con,sprintf("CREATE TABLE pairs AS SELECT rsid,oa_key,shanghai_rank,shanghai_name,
  CASE WHEN regexp_full_match(oa_key,'I[0-9]+') THEN oa_key END openalex_id
  FROM read_parquet('%s') WHERE rsid IS NOT NULL AND rsid<>2147483647 AND n_rows>0",crosswalk_path)))
stopifnot(dbGetQuery(con,'SELECT count(*)-count(DISTINCT (rsid,oa_key)) n FROM pairs')$n==0L)

# Collect candidates BEFORE the education join, so many-to-many links never fan
# out education records. Sorting also defines the best-institution tie-break.
invisible(dbExecute(con,"CREATE TABLE rsid_map AS SELECT rsid,
  list(struct_pack(oa_key:=oa_key,openalex_id:=openalex_id,
    shanghai_name:=shanghai_name,shanghai_rank:=shanghai_rank)
    ORDER BY shanghai_rank,oa_key,shanghai_name) candidates
  FROM pairs GROUP BY rsid"))
invisible(dbExecute(con,"CREATE TABLE name_keys AS
  SELECT DISTINCT lower(strip_accents(trim(nm))) nm_fold,oa_key,openalex_id,shanghai_name,shanghai_rank
  FROM (SELECT *,display_name nm FROM ranked UNION ALL
        SELECT *,cleaned_display_name FROM ranked UNION ALL
        SELECT *,shanghai_name FROM ranked)
  WHERE nm IS NOT NULL AND length(trim(nm))>=3"))
invisible(dbExecute(con,"CREATE TABLE missing_raws AS
  SELECT DISTINCT university_raw FROM education
  WHERE (rsid IS NULL OR rsid=2147483647)
    AND university_raw IS NOT NULL AND trim(university_raw)<>''"))
invisible(dbExecute(con,"CREATE TABLE raw_pairs AS
  WITH whole AS (
    SELECT r.university_raw,k.*,1 by_whole,0 by_segment
    FROM missing_raws r JOIN name_keys k
      ON lower(strip_accents(trim(r.university_raw)))=k.nm_fold
  ), segments AS (
    SELECT r.university_raw,k.*,0 by_whole,1 by_segment
    FROM missing_raws r CROSS JOIN UNNEST(str_split(regexp_replace(regexp_replace(
      r.university_raw,'[/()]','|','g'),' - ','|','g'),'|')) t(part)
    JOIN name_keys k ON lower(strip_accents(trim(t.part)))=k.nm_fold
    WHERE length(trim(t.part))>=3
  )
  SELECT university_raw,oa_key,openalex_id,shanghai_name,shanghai_rank,
    max(by_whole) by_whole,max(by_segment) by_segment
  FROM (SELECT * FROM whole UNION ALL SELECT * FROM segments)
  GROUP BY 1,2,3,4,5"))
invisible(dbExecute(con,"CREATE TABLE raw_map AS SELECT university_raw,
  list(struct_pack(oa_key:=oa_key,openalex_id:=openalex_id,
    shanghai_name:=shanghai_name,shanghai_rank:=shanghai_rank)
    ORDER BY shanghai_rank,oa_key,shanghai_name) candidates,
  max(by_whole) by_whole,max(by_segment) by_segment
  FROM raw_pairs GROUP BY university_raw"))

input_counts <- dbGetQuery(con,'SELECT count(*) education_rows,count(DISTINCT user_id) users FROM education')
cat('Input:',input_counts$education_rows,'education rows;',input_counts$users,'users\n')
cat('Maps:',dbGetQuery(con,'SELECT count(*) n FROM rsid_map')$n,'rsids;',
    dbGetQuery(con,'SELECT count(*) n FROM raw_map')$n,'missing-rsid raw names\n')
# All original source columns survive; input BIGINT identifiers never pass through
# R doubles. Missing candidate lists remain NULL, with an explicit zero count.
invisible(dbExecute(con,sprintf("COPY (
  WITH joined AS (
    SELECT e.*,coalesce(r.candidates,n.candidates) sh_candidates,
      CASE WHEN r.rsid IS NOT NULL THEN 'rsid'
           WHEN n.university_raw IS NOT NULL THEN 'raw_c_norm'
           WHEN e.rsid IS NULL OR e.rsid=2147483647 THEN 'unmatched_missing_rsid'
           ELSE 'unmatched_known_rsid' END sh_match_route,
      coalesce(n.by_whole,0) sh_raw_whole,coalesce(n.by_segment,0) sh_raw_segment
    FROM education e LEFT JOIN rsid_map r ON e.rsid=r.rsid
    LEFT JOIN raw_map n ON (e.rsid IS NULL OR e.rsid=2147483647)
      AND e.university_raw=n.university_raw
  ), classified AS (
    SELECT *,lower(trim(coalesce(degree_raw,''))) dr FROM joined
  )
  SELECT * EXCLUDE(dr),CAST(sh_candidates IS NOT NULL AS INTEGER) sh_match,
    CAST(coalesce(len(sh_candidates),0) AS INTEGER) sh_candidate_count,
    sh_candidates[1].shanghai_rank sh_rank,sh_candidates[1].shanghai_name sh_inst,
    sh_candidates[1].oa_key sh_oa_key,sh_candidates[1].openalex_id sh_openalex_id,
    CAST(year(startdate) AS INTEGER) sh_start_year,
    (%s) sh_level,(degree='MBA' OR regexp_like(dr,'%s')) sh_is_mba,
    regexp_like(dr,'%s') sh_is_lato
  FROM classified
) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",sql_shanghai_level,rx_mba,rx_lato,matches_stage)))

stopifnot(identical(input_md5,tools::md5sum(manifest_paths)))
write_json(list(inputs=data.frame(path=manifest_paths,md5=unname(input_md5)),education_dir=ed_dir,counts=input_counts,matches_stage=matches_stage),file.path(out_dir,'engine_sh.json'),auto_unbox=TRUE,pretty=TRUE,dataframe='rows')
dbDisconnect(con,shutdown=TRUE)
cat('Staged sh matching records.', '\n')
}
