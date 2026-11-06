# Offline local prep. Public entrypoint rebuilds all three flag families after validation.
if (Sys.getenv('OBMEP_FLAG_BUILD_INTERNAL')!='1') {
  source('prep/building_external_data/rebuild_education_flags.R')
} else {
# Local prep, offline; never send to SEDAP. Existing crosswalk, no floor or keep,
# dominance, country, or type gate. Only missing-rsid rows get a raw-name fallback.
# By explicit request, whole AND segment fallback matches accept every OA type.
# This internal engine stages matches; the driver backs up and replaces flag products.
# Run from repo root; --test uses the same pipeline with explicit local fixtures.
library(DBI)
library(duckdb)
library(jsonlite)
options(stringsAsFactors=FALSE)
test_run <- '--test' %in% commandArgs(trailingOnly=TRUE)
obmep_root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh_dir <- file.path(obmep_root,'Data/intermediate/revelio_br_cohort')
inst_path <- file.path(obmep_root,'Data/intermediate/openalex_institutions/openalex_institutions_br.parquet')
crosswalk_path <- file.path(coh_dir,'rsid_openalex_id_crosswalk.parquet')
ed_dir <- file.path(coh_dir,'obmep_candidates_step_1_education')
baseline_path <- file.path(coh_dir,'obmep_candidates_step_1.parquet')
out_dir <- coh_dir
patterns_path <- Sys.getenv('OBMEP_DEGREE_PATTERNS','prep/building_external_data/br_degree_patterns.R')
source(patterns_path)
# Veto applies only in flag production, never in the cohort's shared constants.
sql_shanghai_level <- sprintf("CASE WHEN regexp_like(dr,'%s') THEN 'other' ELSE (%s) END",rx_hs,sql_shanghai_level)
con <- dbConnect(duckdb())
invisible(dbExecute(con,"SET memory_limit='8GB'"))
invisible(dbExecute(con,'SET threads=4'))
# R's session temp directory is outside Dropbox and is cleaned at process exit.
work_dir <- gsub('\\\\','/',tempfile('br_oa_nofloor_'))
dir.create(file.path(work_dir,'spill'),recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(work_dir,'flags'),showWarnings=FALSE)
invisible(dbExecute(con,sprintf("SET temp_directory='%s/spill'",work_dir)))
invisible(dbExecute(con,'CREATE MACRO regexp_like(s,p) AS regexp_matches(s,p)'))

if (test_run) {
  out_dir <- file.path(obmep_root,'test/education_flags_rebuild/fixtures/br')
  ed_dir <- file.path(out_dir,'education')
  dir.create(ed_dir,recursive=TRUE,showWarnings=FALSE)
  inst_path <- file.path(out_dir,'institutions.parquet')
  crosswalk_path <- file.path(out_dir,'crosswalk.parquet')
  baseline_path <- file.path(out_dir,'baseline.parquet')
  invisible(dbExecute(con,"CREATE TABLE fixture_institutions AS SELECT * FROM (VALUES
    ('I1','Universit\u00e9 Alpha','Alpha University','education'),
    ('I2','Beta Technology (Brazil)','Beta Tech','company'),
    ('I3','Gamma Hospital (Brazil)','Gamma Hospital','healthcare'),
    ('I4','Delta Agency (Brazil)','Delta Agency','government'),
    ('I5','Shared College','East College','education'),
    ('I6','Shared College','West College','education')
    ) t(openalex_id,display_name,cleaned_display_name,type)"))
  invisible(dbExecute(con,sprintf("COPY fixture_institutions TO '%s' (FORMAT PARQUET)",inst_path)))
  invisible(dbExecute(con,"CREATE TABLE fixture_crosswalk AS SELECT CAST(rs AS INTEGER) rsid,
    oid openalex_id,raw university_raw,0 keep,0.000001 dom_share,0.0 br_share_known,1 n_rows
    FROM (VALUES (10,'I1','name A'),(10,'I1','name B'),(10,'I2','name C'),
      (11,'I1','name A'),(12,'I3','name D'),(12,'I2','name C'),
      (NULL,'I1','missing'),(2147483647,'I1','sentinel')) t(rs,oid,raw)"))
  invisible(dbExecute(con,sprintf("COPY fixture_crosswalk TO '%s' (FORMAT PARQUET)",crosswalk_path)))
  invisible(dbExecute(con,"CREATE TABLE fixture_education AS
    SELECT CAST(uid AS BIGINT) user_id,raw university_raw,'ignored normalized name' university_name,
      CAST(school AS INTEGER) rsid,dr degree_raw,dg degree,
      DATE '2001-01-01' startdate,DATE '2005-01-01' enddate
    FROM (VALUES
      (9007199254740993,10,'different typed school','bachelor','Bachelor'),
      (9007199254740993,10,'different typed school','bachelor','Bachelor'),
      (2,11,NULL,'MBA','MBA'),(3,12,'anything','master','Master'),
      (4,999,'Alpha University','bachelor','Bachelor'),
      (5,NULL,'  UNIVERSITE ALPHA  ','bachelor','Bachelor'),
      (6,NULL,'Dept / Beta Tech','master','Master'),
      (7,NULL,'School (Gamma Hospital)','phd','Doctor'),
      (8,NULL,'Course | Alpha University','bachelor','Bachelor'),
      (9,NULL,'Course - Delta Agency','bachelor','Bachelor'),
      (10,NULL,'Beta Tech','bachelor','Bachelor'),
      (11,NULL,'Gamma Hospital','bachelor','Bachelor'),
      (12,NULL,'Shared College','bachelor','Bachelor'),
      (13,NULL,'','bachelor','Bachelor'),(14,NULL,NULL,'bachelor','Bachelor'),
      (15,NULL,'Alpha University extra text','bachelor','Bachelor'),
      (16,NULL,'AB','bachelor','Bachelor'),
      (17,2147483647,'Alpha University','bachelor','Bachelor'),
      (18,NULL,'Alpha University / Beta Tech','bachelor','Bachelor'),
      (19,10,'ignored','pos-doutorado','Doctor'),(20,10,'ignored','MBA','MBA'),
      (21,10,'ignored','master','Master'),
      (21,NULL,'Gamma Hospital','especializacao lato sensu','Other'),
      (22,10,'ignored','phd','Doctor'),(23,10,'ignored','bachelor','Bachelor'),
      (23,NULL,'Beta Tech','master','Master')
    ) t(uid,school,raw,dr,dg)"))
  invisible(dbExecute(con,"INSERT INTO fixture_education VALUES
    (24,'misclassified secondary','ignored',10,'high school','Bachelor',DATE '2010-01-01',NULL),
    (25,'misclassified technical','ignored',10,'curso tecnico','Master',DATE '2010-01-01',NULL),
    (26,'bachelor despite label','ignored',10,'bacharelado','High School',DATE '2010-01-01',NULL),
    (27,'missing year','ignored',10,'bachelor','Bachelor',NULL,NULL)"))
  invisible(dbExecute(con,sprintf("COPY fixture_education TO '%s/part.parquet' (FORMAT PARQUET)",ed_dir)))
  invisible(dbExecute(con,sprintf("COPY (SELECT DISTINCT user_id,
    CASE WHEN user_id IN (4,5,19) THEN 1 ELSE 0 END br_openalex_norm
    FROM fixture_education) TO '%s' (FORMAT PARQUET)",baseline_path)))
}
stopifnot(file.exists(inst_path),file.exists(crosswalk_path),dir.exists(ed_dir),file.exists(baseline_path))
out_dir <- Sys.getenv('OBMEP_FLAG_STAGE_DIR')
stopifnot(nzchar(out_dir),dir.exists(out_dir))
prefix <- 'obmep_candidates_step_1_br_openalex_rsid_nofloor'
matches_path <- file.path(out_dir,paste0(prefix,'_matches.parquet'))
flags_path <- file.path(out_dir,paste0(prefix,'.parquet'))
matches_stage <- file.path(out_dir,paste0(prefix,'_matches.building.parquet'))
flags_stage <- file.path(out_dir,paste0(prefix,'.building.parquet'))
report_path <- file.path(out_dir,paste0(prefix,'_report.json'))
manifest_paths <- c(inst_path,crosswalk_path,baseline_path,patterns_path,sort(Sys.glob(file.path(ed_dir,'*'))))
input_md5 <- tools::md5sum(manifest_paths)
invisible(dbExecute(con,sprintf("CREATE VIEW education AS SELECT * EXCLUDE(filename,file_row_number),
  filename source_file,file_row_number source_row
  FROM read_parquet('%s/*',filename=true,file_row_number=true)",ed_dir)))
invisible(dbExecute(con,sprintf("CREATE TABLE institutions AS SELECT openalex_id,display_name,
  cleaned_display_name,type FROM read_parquet('%s')",inst_path)))
iv <- dbGetQuery(con,"SELECT count(*) n,count(DISTINCT openalex_id) ids,
  count(*) FILTER(WHERE openalex_id IS NULL OR NOT regexp_full_match(openalex_id,'I[0-9]+')) bad
  FROM institutions")
stopifnot(iv$n==if(test_run) 6L else 1947L,iv$n==iv$ids,iv$bad==0)
invisible(dbExecute(con,sprintf("CREATE TABLE pair_keys AS SELECT DISTINCT rsid,openalex_id
  FROM read_parquet('%s') WHERE rsid IS NOT NULL AND rsid<>2147483647",crosswalk_path)))
stopifnot(dbGetQuery(con,'SELECT count(*) n FROM pair_keys ANTI JOIN institutions USING(openalex_id)')$n==0)
invisible(dbExecute(con,'CREATE TABLE pairs AS SELECT p.*,i.* EXCLUDE(openalex_id) FROM pair_keys p JOIN institutions i USING(openalex_id)'))
map_counts <- dbGetQuery(con,'SELECT count(*) pairs,count(DISTINCT rsid) rsids,count(DISTINCT openalex_id) institutions FROM pairs')

# Deduplicate source spellings to pairs, then collapse candidates before joining
# to education. No primary candidate is selected for this unranked institution list.
invisible(dbExecute(con,"CREATE TABLE rsid_map AS SELECT rsid,
  list(struct_pack(openalex_id:=openalex_id,display_name:=display_name,
    cleaned_display_name:=cleaned_display_name,type:=type) ORDER BY openalex_id) candidates,
  list(openalex_id ORDER BY openalex_id) candidate_ids,
  list_sort(list_distinct(list(type))) candidate_types
  FROM pairs GROUP BY rsid"))
invisible(dbExecute(con,"CREATE TABLE name_keys AS SELECT DISTINCT
  lower(strip_accents(trim(nm))) nm_fold,openalex_id,display_name,cleaned_display_name,type
  FROM (SELECT *,display_name nm FROM institutions UNION ALL
        SELECT *,cleaned_display_name FROM institutions)
  WHERE nm IS NOT NULL AND length(trim(nm))>=3"))
invisible(dbExecute(con,"CREATE TABLE missing_raws AS SELECT DISTINCT university_raw FROM education
  WHERE (rsid IS NULL OR rsid=2147483647) AND university_raw IS NOT NULL AND trim(university_raw)<>''"))
invisible(dbExecute(con,"CREATE TABLE raw_pairs AS
  WITH whole AS (
    SELECT r.university_raw,k.*,1 by_whole,0 by_segment FROM missing_raws r
    JOIN name_keys k ON lower(strip_accents(trim(r.university_raw)))=k.nm_fold
  ), segments AS (
    SELECT r.university_raw,k.*,0 by_whole,1 by_segment FROM missing_raws r
    CROSS JOIN UNNEST(str_split(regexp_replace(regexp_replace(
      r.university_raw,'[/()]','|','g'),' - ','|','g'),'|')) t(part)
    JOIN name_keys k ON lower(strip_accents(trim(t.part)))=k.nm_fold
    WHERE length(trim(t.part))>=3
  )
  SELECT university_raw,openalex_id,display_name,cleaned_display_name,type,
    max(by_whole) by_whole,max(by_segment) by_segment
  FROM (SELECT * FROM whole UNION ALL SELECT * FROM segments) GROUP BY 1,2,3,4,5"))
invisible(dbExecute(con,"CREATE TABLE raw_map AS SELECT university_raw,
  list(struct_pack(openalex_id:=openalex_id,display_name:=display_name,
    cleaned_display_name:=cleaned_display_name,type:=type) ORDER BY openalex_id) candidates,
  list(openalex_id ORDER BY openalex_id) candidate_ids,
  list_sort(list_distinct(list(type))) candidate_types,
  max(by_whole) by_whole,max(by_segment) by_segment
  FROM raw_pairs GROUP BY university_raw"))
input_counts <- dbGetQuery(con,'SELECT count(*) education_rows,count(DISTINCT user_id) users FROM education')
cat('Input:',input_counts$education_rows,'education rows;',input_counts$users,'users\n')
cat('Map:',map_counts$pairs,'pairs;',map_counts$rsids,'rsids;',map_counts$institutions,'institutions\n')
raw_strings <- dbGetQuery(con,'SELECT count(*) n FROM raw_map')$n
cat('Missing-rsid fallback:',raw_strings,'distinct matched raw names\n')
invisible(dbExecute(con,sprintf("COPY (
  WITH joined AS (
    SELECT e.*,coalesce(r.candidates,n.candidates) br_oa_candidates,
      coalesce(r.candidate_ids,n.candidate_ids) br_oa_candidate_ids,
      coalesce(r.candidate_types,n.candidate_types) br_oa_candidate_types,
      CASE WHEN r.rsid IS NOT NULL THEN 'rsid' WHEN n.university_raw IS NOT NULL THEN 'raw_c_norm'
           WHEN e.rsid IS NULL OR e.rsid=2147483647 THEN 'unmatched_missing_rsid'
           ELSE 'unmatched_known_rsid' END br_oa_match_route,
      coalesce(n.by_whole,0) br_oa_raw_whole,coalesce(n.by_segment,0) br_oa_raw_segment
    FROM education e LEFT JOIN rsid_map r ON e.rsid=r.rsid
    LEFT JOIN raw_map n ON (e.rsid IS NULL OR e.rsid=2147483647) AND e.university_raw=n.university_raw
  ), classified AS (SELECT *,lower(trim(coalesce(degree_raw,''))) dr FROM joined)
  SELECT * EXCLUDE(dr),CAST(br_oa_candidates IS NOT NULL AS INTEGER) br_oa_match,
    CAST(coalesce(len(br_oa_candidate_ids),0) AS INTEGER) br_oa_candidate_count,
    CAST(year(startdate) AS INTEGER) br_oa_start_year,(%s) br_oa_level,
    (degree='MBA' OR regexp_like(dr,'%s')) br_oa_is_mba,regexp_like(dr,'%s') br_oa_is_lato,
    array_to_string(br_oa_candidate_ids,'|') br_oa_ids_pipe
  FROM classified
) TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)",sql_shanghai_level,rx_mba,rx_lato,matches_stage)))

stopifnot(identical(input_md5,tools::md5sum(manifest_paths)))
write_json(list(inputs=data.frame(path=manifest_paths,md5=unname(input_md5)),education_dir=ed_dir,counts=input_counts,matches_stage=matches_stage),file.path(out_dir,'engine_br.json'),auto_unbox=TRUE,pretty=TRUE,dataframe='rows')
dbDisconnect(con,shutdown=TRUE)
cat('Staged br matching records.', '\n')
}
