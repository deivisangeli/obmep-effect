# Local, offline preparation. Builds Brazilian-CWUR and Shanghai education
# flags for the refreshed degree-duration cohort. It never changes the legacy
# RUF, Shanghai, hierarchy, selection, or employer products.
# Run after global_oa_degree_duration_hierarchy.R from the repository root.
library(DBI)
library(duckdb)
library(jsonlite)
options(stringsAsFactors=FALSE)

root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh <- file.path(root,'Data/intermediate/revelio_br_cohort')
global_dir <- file.path(coh,'global_oa_hierarchy_degree_duration')
education_glob <- gsub('\\\\','/',file.path(global_dir,'education_parts','*.parquet'))
snapshot <- 'C:/Users/megaj/Globtalent Dropbox/GTAllocation/Data/external/oa_snapshot/data/institutions'
snapshot_paths <- sort(list.files(snapshot,pattern='[.]gz$',recursive=TRUE,full.names=TRUE))
cwur_path <- file.path(root,'Data/intermediate/cwur_ranking/cwur_openalex_2026.parquet')
shanghai_path <- file.path(root,'Data/intermediate/shanghai_ranking/shanghai_ranking_oa_parents.parquet')
patterns_path <- Sys.getenv('OBMEP_DEGREE_PATTERNS','prep/building_external_data/br_degree_patterns.R')
script_path <- 'prep/building_external_data/degree_duration_ranked_education_flags.R'
source(patterns_path)

resume_run <- Sys.getenv('OBMEP_DURATION_RANKED_FLAG_RESUME_RUN','')
stopifnot(!nzchar(resume_run) || grepl('^[0-9]{8}T[0-9]{6}$',resume_run))
run_id <- if(nzchar(resume_run)) resume_run else format(Sys.time(),'%Y%m%dT%H%M%S')
stage_dir <- file.path(coh,'.ranked_flags_degree_duration_staging',run_id)
backup_dir <- file.path(coh,'ranked_flags_degree_duration_backups',run_id)
dir.create(stage_dir,recursive=TRUE,showWarnings=FALSE)

dest <- c(
 cwur=file.path(coh,'obmep_candidates_step_1_degree_duration_cwur.parquet'),
 shanghai=file.path(coh,'obmep_candidates_step_1_degree_duration_shanghai.parquet'),
 report=file.path(coh,'ranked_education_flags_degree_duration_report.json'),
 parent_map=file.path(global_dir,'global_oa_degree_duration_parent_map.parquet'),
 decisions=file.path(global_dir,'global_oa_degree_duration_family_parent_adjusted_decisions.parquet'),
 ranked_catalog=file.path(global_dir,'global_oa_degree_duration_ranked_parent_catalog.parquet'))
stage <- file.path(stage_dir,basename(dest)); names(stage) <- names(dest)

education_paths <- sort(list.files(file.path(global_dir,'education_parts'),pattern='[.]parquet$',full.names=TRUE))
hierarchy_manifest <- file.path(global_dir,'implementation_manifest.rds')
stopifnot(length(education_paths)==30L,length(snapshot_paths)>0,
 all(file.exists(c(cwur_path,shanghai_path,patterns_path,hierarchy_manifest))))
input_paths <- c(education_paths,snapshot_paths,cwur_path,shanghai_path,patterns_path,hierarchy_manifest)
input_md5 <- unname(tools::md5sum(input_paths)); stopifnot(!anyNA(input_md5))
input_manifest <- file.path(stage_dir,'input_manifest.rds')
input_manifest_value <- data.frame(path=input_paths,md5=input_md5)
if(file.exists(input_manifest)) {
 stopifnot(identical(input_manifest_value,readRDS(input_manifest)))
} else saveRDS(input_manifest_value,input_manifest)
implementation_paths <- c(script_path,patterns_path)
implementation <- data.frame(path=implementation_paths,
 md5=unname(tools::md5sum(implementation_paths)))
implementation_manifest <- file.path(stage_dir,'implementation_manifest.rds')
if(file.exists(implementation_manifest)) {
 stopifnot(identical(implementation,readRDS(implementation_manifest)))
} else saveRDS(implementation,implementation_manifest)

legacy_paths <- file.path(coh,c('obmep_candidates_step_1_ruf_degree.parquet',
 'obmep_candidates_step_1_shanghai.parquet','obmep_candidates_step_1_shanghai_rsid_nofloor.parquet',
 'ranked_education_flags_redefinition_report.json','obmep_candidates_selected.parquet',
 'obmep_candidates_selected_positions.parquet'))
legacy_paths <- legacy_paths[file.exists(legacy_paths)]
protected <- data.frame(path=legacy_paths,md5=unname(tools::md5sum(legacy_paths)))

con <- dbConnect(duckdb(),dbdir=file.path(stage_dir,'work.duckdb'))
on.exit(try(dbDisconnect(con,shutdown=TRUE),silent=TRUE),add=TRUE)
dbExecute(con,"SET memory_limit='8GB'")
dbExecute(con,'SET threads=4')
spill <- gsub('\\\\','/',file.path(stage_dir,'spill'))
dir.create(spill,recursive=TRUE,showWarnings=FALSE)
dbExecute(con,sprintf("SET temp_directory='%s'",spill))
dbExecute(con,"CREATE OR REPLACE MACRO regexp_like(s,p) AS regexp_matches(s,p)")
dbExecute(con,sprintf("CREATE OR REPLACE VIEW education AS SELECT * FROM read_parquet('%s')",education_glob))

if(!'oa' %in% dbListTables(con)) {
 cat('Loading the frozen OpenAlex institution snapshot.\n')
 dbExecute(con,sprintf("CREATE TABLE oa AS SELECT regexp_extract(id,'I[0-9]+') oa_id,
  display_name,type,country_code,associated_institutions
  FROM read_json('%s/updated_date=*/part_*.gz',format='newline_delimited',filename=true,
   columns={id:'VARCHAR',display_name:'VARCHAR',type:'VARCHAR',country_code:'VARCHAR',
   associated_institutions:'STRUCT(id VARCHAR,display_name VARCHAR,relationship VARCHAR)[]'})
  QUALIFY row_number() OVER(PARTITION BY id ORDER BY filename DESC)=1",snapshot))
 stopifnot(dbGetQuery(con,'SELECT count(*) n,count(DISTINCT oa_id) ids FROM oa')$n==120658L)
}

if(!'parent_map' %in% dbListTables(con)) {
 cat('Building the unique immediate-parent map.\n')
 dbExecute(con,"CREATE TABLE parent_edges AS SELECT o.oa_id,
  count(DISTINCT regexp_extract(a.id,'I[0-9]+')) n_parents,
  CASE WHEN count(DISTINCT regexp_extract(a.id,'I[0-9]+'))=1
   THEN min(regexp_extract(a.id,'I[0-9]+')) END unique_parent_id
  FROM oa o CROSS JOIN unnest(o.associated_institutions) u(a)
  WHERE a.relationship='parent' AND a.id IS NOT NULL GROUP BY o.oa_id")
 dbExecute(con,"CREATE TABLE parent_map AS SELECT o.oa_id,
  coalesce(p.n_parents,0)::INTEGER n_parents,p.unique_parent_id,
  coalesce(p.unique_parent_id,o.oa_id) canonical_id,
  (p.unique_parent_id IS NOT NULL AND p.unique_parent_id<>o.oa_id) parent_replaced
  FROM oa o LEFT JOIN parent_edges p USING(oa_id)")
 stopifnot(dbGetQuery(con,"SELECT count(*) n,count(DISTINCT oa_id) ids,
  count(*) FILTER(WHERE canonical_id IS NULL) bad FROM parent_map")$n==120658L,
  dbGetQuery(con,"SELECT count(*) n FROM parent_map WHERE n_parents<>1 AND unique_parent_id IS NOT NULL")$n==0)
}

# CWUR ranks the three research institutes themselves. Their shared immediate
# parent is MCTI, which is not a ranked institution and must not receive credit.
dbExecute(con,"CREATE OR REPLACE TABLE family_parent_exemptions AS SELECT * FROM (VALUES
 ('cw','I4210125245','CBPF'),
 ('cw','I80849659','INPE'),
 ('cw','I141883831','IMPA')
 ) t(family,oa_id,label)")
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM family_parent_exemptions x
 JOIN parent_map p USING(oa_id) WHERE p.parent_replaced AND p.canonical_id='I4210151455'")$n==3L)

if(!'family_catalog' %in% dbListTables(con)) {
 cat('Building the Brazilian-CWUR and Shanghai ranking catalogs.\n')
 dbExecute(con,sprintf("CREATE TABLE family_catalog AS
  SELECT 'cw' AS family,oa_id,CAST(world_rank AS INTEGER) rk,institution inst,NULL::INTEGER rid
  FROM read_parquet('%s') WHERE country_iso2='BR' AND casada AND oa_id IS NOT NULL
  UNION ALL
  SELECT 'sh' AS family,oa_key,CAST(shanghai_rank AS INTEGER),shanghai_name,NULL::INTEGER
  FROM read_parquet('%s') WHERE shanghai_rank<=901 AND oa_key IN (SELECT oa_id FROM oa)",
  gsub('\\\\','/',cwur_path),gsub('\\\\','/',shanghai_path)))
 stopifnot(dbGetQuery(con,"SELECT count(*) n FROM family_catalog WHERE family='cw'")$n==52L,
  dbGetQuery(con,"SELECT count(DISTINCT oa_id) n FROM family_catalog WHERE family='cw'")$n==52L,
  dbGetQuery(con,"SELECT count(*) n FROM family_catalog WHERE family='sh'")$n==999L,
  dbGetQuery(con,"SELECT count(*) n FROM family_catalog")$n==
   dbGetQuery(con,"SELECT count(DISTINCT (family,oa_id)) n FROM family_catalog")$n)
}

if(!'decision_family_parent' %in% dbListTables(con)) {
 cat('Applying family-specific parent rules to hierarchy decisions.\n')
 dbExecute(con,"CREATE TABLE decision_sets AS SELECT global_oa_decision_id,
  first(global_oa_selected_ids) selected_ids,
  first(global_oa_selected_ids_pipe) selected_ids_pipe,
  first(global_oa_selected_count)::INTEGER selected_count
  FROM education WHERE global_oa_decision_id IS NOT NULL GROUP BY 1")
 stopifnot(dbGetQuery(con,"SELECT count(*) n FROM (SELECT global_oa_decision_id FROM education
  WHERE global_oa_decision_id IS NOT NULL GROUP BY 1
  HAVING count(DISTINCT coalesce(global_oa_selected_ids_pipe,''))>1
   OR count(DISTINCT global_oa_selected_count)>1)")$n==0)
 dbExecute(con,"CREATE TABLE decision_family_expanded AS
  SELECT d.global_oa_decision_id,f.family,d.selected_count,u.oa_id,
   CASE WHEN x.oa_id IS NOT NULL THEN u.oa_id ELSE coalesce(p.canonical_id,u.oa_id) END canonical_id,
   x.oa_id IS NULL AND coalesce(p.parent_replaced,false) parent_replaced,
   x.oa_id IS NOT NULL parent_exemption_applied,p.oa_id IS NULL missing_from_snapshot
  FROM decision_sets d CROSS JOIN (VALUES ('cw'),('sh')) f(family)
  CROSS JOIN unnest(d.selected_ids) u(oa_id)
  LEFT JOIN parent_map p ON p.oa_id=u.oa_id
  LEFT JOIN family_parent_exemptions x ON x.family=f.family AND x.oa_id=u.oa_id
  WHERE d.selected_count>0")
 dbExecute(con,"CREATE TABLE decision_family_agg AS SELECT global_oa_decision_id,family,
  list(DISTINCT canonical_id ORDER BY canonical_id) adjusted_ids,
  bool_or(parent_replaced) parent_replacement_applied,
  bool_or(parent_exemption_applied) parent_exemption_applied,
  bool_or(missing_from_snapshot) missing_selected_id
  FROM decision_family_expanded GROUP BY 1,2")
 dbExecute(con,"CREATE TABLE decision_family_parent AS
  SELECT d.global_oa_decision_id,f.family,d.selected_ids,d.selected_ids_pipe,d.selected_count,
   coalesce(a.adjusted_ids,[]::VARCHAR[]) adjusted_ids,
   coalesce(len(a.adjusted_ids),0)::INTEGER adjusted_count,
   coalesce(a.parent_replacement_applied,false) parent_replacement_applied,
   coalesce(a.parent_exemption_applied,false) parent_exemption_applied,
   coalesce(a.missing_selected_id,false) missing_selected_id,
   CASE WHEN d.selected_count=0 THEN 'unassigned'
    WHEN len(a.adjusted_ids)=1 THEN 'unique' ELSE 'multiple' END adjusted_status
  FROM decision_sets d CROSS JOIN (VALUES ('cw'),('sh')) f(family)
  LEFT JOIN decision_family_agg a USING(global_oa_decision_id,family)")
 stopifnot(dbGetQuery(con,"SELECT count(*) n FROM decision_family_parent WHERE
  adjusted_count<>len(adjusted_ids) OR adjusted_count>selected_count
  OR (adjusted_status='unique') IS DISTINCT FROM (adjusted_count=1)")$n==0,
  dbGetQuery(con,"SELECT count(*) n FROM decision_family_parent WHERE missing_selected_id")$n==0)
}

if(!'ranked_parent_catalog' %in% dbListTables(con)) {
 cat('Applying the same family-specific rules to the ranking catalogs.\n')
 dbExecute(con,"CREATE TABLE ranked_parent_catalog AS SELECT f.*,
  CASE WHEN x.oa_id IS NOT NULL THEN f.oa_id ELSE coalesce(p.canonical_id,f.oa_id) END canonical_id,
  coalesce(p.n_parents,0)::INTEGER n_parents,p.unique_parent_id,
  x.oa_id IS NULL AND coalesce(p.parent_replaced,false) parent_replaced,
  x.oa_id IS NOT NULL parent_exemption_applied,p.oa_id IS NULL missing_from_snapshot
  FROM family_catalog f LEFT JOIN parent_map p USING(oa_id)
  LEFT JOIN family_parent_exemptions x ON x.family=f.family AND x.oa_id=f.oa_id")
 stopifnot(dbGetQuery(con,"SELECT count(*) n FROM ranked_parent_catalog WHERE
  oa_id IS NULL OR canonical_id IS NULL OR missing_from_snapshot")$n==0,
  dbGetQuery(con,"SELECT count(DISTINCT canonical_id) n FROM ranked_parent_catalog WHERE family='cw'")$n==52L,
  dbGetQuery(con,"SELECT count(*) n FROM ranked_parent_catalog WHERE family='cw' AND parent_exemption_applied")$n==3L)
 dbExecute(con,"CREATE TABLE family_rank_sets AS SELECT family,canonical_id,
  list(DISTINCT oa_id ORDER BY oa_id) source_ids,min(rk)::INTEGER rk,
  first(inst ORDER BY rk NULLS LAST,oa_id,rid NULLS LAST) inst,
  first(oa_id ORDER BY rk NULLS LAST,oa_id,rid NULLS LAST) inst_key,
  first(rid ORDER BY rk NULLS LAST,oa_id,rid NULLS LAST) rid
  FROM ranked_parent_catalog GROUP BY family,canonical_id")
}

dbExecute(con,sprintf("COPY (SELECT * FROM parent_map ORDER BY oa_id) TO '%s'
 (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",gsub('\\\\','/',stage['parent_map'])))
dbExecute(con,sprintf("COPY (SELECT * FROM decision_family_parent ORDER BY global_oa_decision_id,family) TO '%s'
 (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",gsub('\\\\','/',stage['decisions'])))
dbExecute(con,sprintf("COPY (SELECT * FROM ranked_parent_catalog ORDER BY family,canonical_id,rk,oa_id) TO '%s'
 (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",gsub('\\\\','/',stage['ranked_catalog'])))

entry_dir <- file.path(stage_dir,'ranked_entries')
if(!dir.exists(entry_dir) || !length(list.files(entry_dir,recursive=TRUE,pattern='[.]parquet$'))) {
 cat('Writing family-adjusted ranked education entries.\n')
 dir.create(entry_dir,recursive=TRUE,showWarnings=FALSE)
 dbExecute(con,sprintf("COPY (SELECT r.family,CAST(hash(e.user_id)%%32 AS INTEGER) bucket,
  e.source_file,e.source_row,e.user_id,
  CASE WHEN coalesce(e.degree,'empty')='empty' AND e.degree_matches_laxed=1
   THEN 'bachelor' ELSE e.ranked_level END lvl,
  (e.degree='MBA' OR regexp_like(lower(trim(coalesce(e.degree_raw,''))),'%s')) is_mba,
  regexp_like(lower(trim(coalesce(e.degree_raw,''))),'%s') is_lato,
  CAST(year(e.startdate) AS INTEGER) yr,e.degree_match_route degree_route,
  e.global_oa_match_route oa_route,d.selected_count,d.adjusted_count,
  d.parent_replacement_applied,d.parent_exemption_applied,
  d.adjusted_ids[1] canonical_id,r.source_ids,r.rk,r.inst,r.inst_key,r.rid
  FROM education e JOIN decision_family_parent d USING(global_oa_decision_id)
  JOIN family_rank_sets r ON r.family=d.family AND d.adjusted_count=1
   AND d.adjusted_ids[1]=r.canonical_id)
  TO '%s' (FORMAT PARQUET,PARTITION_BY(family,bucket),COMPRESSION ZSTD)",
  rx_mba,rx_lato,gsub('\\\\','/',entry_dir)))
}
dbExecute(con,sprintf("CREATE OR REPLACE VIEW ranked_entries AS
 SELECT * FROM read_parquet('%s/*/*/*.parquet',hive_partitioning=true)",gsub('\\\\','/',entry_dir)))
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM (SELECT family,source_file,source_row,count(*) c
 FROM ranked_entries GROUP BY 1,2,3 HAVING c<>1)")$n==0,
 dbGetQuery(con,"SELECT count(*) n FROM ranked_entries WHERE adjusted_count<>1
  OR canonical_id IS NULL OR len(source_ids)=0")$n==0,
 dbGetQuery(con,"SELECT count(*) n FROM ranked_entries WHERE degree_route='duration_fallback'
  AND lvl<>'bachelor'")$n==0,
 dbGetQuery(con,"SELECT count(*) n FROM ranked_entries WHERE degree_route='duration_fallback'")$n>0)

for(kind in c('cw','sh')) {
 out_dir <- file.path(stage_dir,paste0(kind,'_flag_parts'))
 dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)
 buckets <- sort(list.dirs(file.path(entry_dir,paste0('family=',kind)),recursive=FALSE,full.names=TRUE))
 stopifnot(length(buckets)>0)
 for(i in seq_along(buckets)) {
  part <- file.path(out_dir,sprintf('part_%02d.parquet',i))
  if(file.exists(part)) next
  extra <- if(kind=='sh') ",
   coalesce(list_sort(list_distinct(flatten(list(source_ids) FILTER(WHERE lvl='bachelor')))),[]::VARCHAR[]) sh_bach_institution_keys,
   coalesce(list_sort(list_distinct(flatten(list(source_ids) FILTER(WHERE lvl='master')))),[]::VARCHAR[]) sh_mast_institution_keys,
   coalesce(list_sort(list_distinct(flatten(list(source_ids) FILTER(WHERE lvl='phd')))),[]::VARCHAR[]) sh_phd_institution_keys" else ''
  dbExecute(con,sprintf("COPY (SELECT user_id,1::INTEGER %1$s_any,
   CAST(max(CASE WHEN oa_route='rsid' AND lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) AS INTEGER) %1$s_rsid_any,
   CAST(max(CASE WHEN oa_route='raw_c_norm' AND lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) AS INTEGER) %1$s_raw_any,
   CAST(max(CASE WHEN lvl='bachelor' THEN 1 ELSE 0 END) AS INTEGER) %1$s_bachelor,
   CAST(max(CASE WHEN lvl='master' THEN 1 ELSE 0 END) AS INTEGER) %1$s_master,
   CAST(max(CASE WHEN lvl='master' AND NOT is_mba THEN 1 ELSE 0 END) AS INTEGER) %1$s_master_strict,
   CAST(max(CASE WHEN lvl='phd' THEN 1 ELSE 0 END) AS INTEGER) %1$s_phd,
   CAST(max(CASE WHEN is_lato THEN 1 ELSE 0 END) AS INTEGER) %1$s_lato,
   min(rk) FILTER(WHERE lvl IN ('bachelor','master','phd')) %1$s_best_rank,
   min(rk) FILTER(WHERE lvl='bachelor') %1$s_bach_rank,
   min(rk) FILTER(WHERE lvl='master') %1$s_mast_rank,
   min(rk) FILTER(WHERE lvl='phd') %1$s_phd_rank,
   first(inst ORDER BY rk,inst_key) FILTER(WHERE lvl='bachelor') %1$s_bach_inst,
   first(inst ORDER BY rk,inst_key) FILTER(WHERE lvl='master') %1$s_mast_inst,
   first(inst ORDER BY rk,inst_key) FILTER(WHERE lvl='phd') %1$s_phd_inst,
   min(yr) FILTER(WHERE lvl='bachelor') %1$s_bach_year,
   min(yr) FILTER(WHERE lvl='master') %1$s_mast_year,
   min(yr) FILTER(WHERE lvl='phd') %1$s_phd_year,
   coalesce(list_sort(list_distinct(flatten(list(source_ids) FILTER(WHERE lvl='bachelor')))),[]::VARCHAR[]) %1$s_bach_institutions,
   coalesce(list_sort(list_distinct(flatten(list(source_ids) FILTER(WHERE lvl='master')))),[]::VARCHAR[]) %1$s_mast_institutions,
   coalesce(list_sort(list_distinct(flatten(list(source_ids) FILTER(WHERE lvl='master' AND NOT is_mba)))),[]::VARCHAR[]) %1$s_mast_strict_institutions,
   coalesce(list_sort(list_distinct(flatten(list(source_ids) FILTER(WHERE lvl='phd')))),[]::VARCHAR[]) %1$s_phd_institutions,
   CAST(count(*) AS INTEGER) %1$s_n_rows %2$s
   FROM read_parquet('%3$s/*.parquet') GROUP BY user_id
   HAVING max(CASE WHEN lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END)=1)
   TO '%4$s' (FORMAT PARQUET,COMPRESSION ZSTD)",kind,extra,gsub('\\\\','/',buckets[i]),gsub('\\\\','/',part)))
 }
 dbExecute(con,sprintf("CREATE OR REPLACE VIEW new_%s AS SELECT * FROM read_parquet('%s/*.parquet')",kind,gsub('\\\\','/',out_dir)))
 out_path <- if(kind=='cw') stage['cwur'] else stage['shanghai']
 if(kind=='sh') {
  legacy_schema <- dbGetQuery(con,sprintf("DESCRIBE SELECT * FROM read_parquet('%s')",gsub('\\\\','/',file.path(coh,'obmep_candidates_step_1_shanghai.parquet'))))
  new_schema <- dbGetQuery(con,'DESCRIBE new_sh')
  stopifnot(all(legacy_schema$column_name %in% new_schema$column_name),
   all(legacy_schema$column_type==new_schema$column_type[match(legacy_schema$column_name,new_schema$column_name)]))
  select_cols <- paste(sprintf('"%s"',legacy_schema$column_name),collapse=',')
 } else select_cols <- '*'
 dbExecute(con,sprintf("COPY (SELECT %s FROM new_%s) TO '%s'
  (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",select_cols,kind,gsub('\\\\','/',out_path)))
}

coverage <- dbGetQuery(con,"SELECT family,count(*) matched_rows,count(DISTINCT user_id) matched_users,
 count(*) FILTER(WHERE lvl IN ('bachelor','master','phd')) qualifying_rows,
 count(DISTINCT user_id) FILTER(WHERE lvl IN ('bachelor','master','phd')) qualifying_users,
 count(*) FILTER(WHERE degree_route='duration_fallback') duration_rows,
 count(DISTINCT user_id) FILTER(WHERE degree_route='duration_fallback') duration_users
 FROM ranked_entries GROUP BY family ORDER BY family")

for(kind in c('cw','sh')) {
 flag_path <- if(kind=='cw') stage['cwur'] else stage['shanghai']
 dbExecute(con,sprintf("CREATE OR REPLACE VIEW flags AS SELECT * FROM read_parquet('%s')",gsub('\\\\','/',flag_path)))
 valid <- dbGetQuery(con,sprintf("SELECT count(*) n,count(DISTINCT user_id) ids,
  count(*) FILTER(WHERE user_id IS NULL OR %1$s_any<>1
   OR %1$s_bachelor+%1$s_master+%1$s_phd=0
   OR %1$s_master_strict>%1$s_master OR %1$s_rsid_any+%1$s_raw_any=0) bad FROM flags",kind))
 stopifnot(valid$n==valid$ids,valid$bad==0,
  valid$n==dbGetQuery(con,sprintf("SELECT count(DISTINCT user_id) n FROM ranked_entries
   WHERE family='%s' AND lvl IN ('bachelor','master','phd')",kind))$n)
 stopifnot(dbGetQuery(con,sprintf("WITH x AS (SELECT user_id,count(*) n FROM ranked_entries
  WHERE family='%1$s' GROUP BY 1 HAVING bool_or(lvl IN ('bachelor','master','phd')))
  SELECT count(*) n FROM x FULL JOIN flags f USING(user_id)
  WHERE x.user_id IS NULL OR f.user_id IS NULL OR x.n<>f.%1$s_n_rows",kind))$n==0)
 for(level in c('bachelor','master','phd')) {
  short <- c(bachelor='bach',master='mast',phd='phd')[level]
  stopifnot(dbGetQuery(con,sprintf("SELECT sum(%s_%s) n FROM flags",kind,level))$n==
   dbGetQuery(con,sprintf("SELECT count(DISTINCT user_id) n FROM ranked_entries WHERE family='%s' AND lvl='%s'",kind,level))$n)
  stopifnot(dbGetQuery(con,sprintf("WITH x AS (SELECT user_id,min(yr) yr,min(rk) rk FROM ranked_entries
   WHERE family='%1$s' AND lvl='%2$s' GROUP BY 1) SELECT count(*) n FROM x JOIN flags f USING(user_id)
   WHERE x.yr IS DISTINCT FROM f.%1$s_%3$s_year OR x.rk IS DISTINCT FROM f.%1$s_%3$s_rank",kind,level,short))$n==0)
 }
 list_fields <- c('bach','mast','mast_strict','phd')
 stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM flags WHERE %s",
  paste(sprintf("%1$s_%2$s_institutions IS DISTINCT FROM list_sort(list_distinct(%1$s_%2$s_institutions))",kind,list_fields),collapse=' OR ')))$n==0)
 if(kind=='sh') stopifnot(dbGetQuery(con,"SELECT count(*) n FROM flags WHERE
  sh_bach_institution_keys IS DISTINCT FROM sh_bach_institutions
  OR sh_mast_institution_keys IS DISTINCT FROM sh_mast_institutions
  OR sh_phd_institution_keys IS DISTINCT FROM sh_phd_institutions")$n==0)
}

catalog_stats <- dbGetQuery(con,"SELECT family,count(*) source_ids,count(DISTINCT canonical_id) canonical_ids,
 count(*) FILTER(WHERE parent_replaced) parent_replaced,
 count(*) FILTER(WHERE parent_exemption_applied) parent_exemptions
 FROM ranked_parent_catalog GROUP BY family ORDER BY family")
decision_stats <- dbGetQuery(con,"SELECT family,count(*) decisions,
 count(*) FILTER(WHERE selected_count>0) selected_decisions,
 count(*) FILTER(WHERE adjusted_count=1) unique_adjusted,
 count(*) FILTER(WHERE adjusted_count>1) excluded_multiple,
 count(*) FILTER(WHERE parent_replacement_applied) parent_replacements,
 count(*) FILTER(WHERE parent_exemption_applied) parent_exemptions
 FROM decision_family_parent GROUP BY family ORDER BY family")
degree_routes <- dbGetQuery(con,"SELECT family,degree_route,lvl,count(*) education_rows,
 count(DISTINCT user_id) users FROM ranked_entries GROUP BY 1,2,3 ORDER BY 1,2,3")

stopifnot(identical(input_md5,unname(tools::md5sum(input_paths))),
 identical(protected$md5,unname(tools::md5sum(protected$path))))
output_names <- c('cwur','shanghai','parent_map','decisions','ranked_catalog')
report <- list(run_id=run_id,completed_utc=format(Sys.time(),tz='UTC',usetz=TRUE),
 method=list(education_source='Refreshed degree-duration global OpenAlex hierarchy selections',
  degree_rule="Stored ranked_level, plus degree_matches_laxed when degree is the literal 'empty'",
  parent_rule='Unique immediate parent for both families, with three named CWUR research-institute exemptions',
  cwur_scope='All 52 matched 2026 CWUR institutions with country_iso2 BR; no OA type filter',
  shanghai_scope='Existing Shanghai rank bands through 901',
  ambiguity_rule='Require exactly one family-adjusted selected ID'),
 inputs=data.frame(path=input_paths,md5=input_md5),ranking_catalog=catalog_stats,
 decisions=decision_stats,coverage=coverage,degree_routes=degree_routes,
 outputs=data.frame(path=unname(dest[output_names]),md5=unname(tools::md5sum(stage[output_names]))),
 protected_products=protected,implementation=implementation,
 validation=list(cwur_52_source_and_canonical_ids=TRUE,cwur_parent_exemptions=TRUE,
  shanghai_schema_compatible=TRUE,unique_users=TRUE,ambiguous_ids_excluded=TRUE,
  lax_bachelor_restricted_to_empty_degree=TRUE,degree_counts_reconciled=TRUE,
  years_ranks_and_lists_reconciled=TRUE,legacy_products_unchanged=TRUE,
  published_checksums_match_stage=TRUE))
write_json(report,stage['report'],pretty=TRUE,auto_unbox=TRUE,dataframe='rows',digits=16,na='null')

cat('Publishing validated degree-duration outputs.\n')
dir.create(backup_dir,recursive=TRUE,showWarnings=FALSE)
for(nm in names(dest)) {
 src <- stage[nm]; target <- dest[nm]
 stopifnot(file.exists(src))
 if(file.exists(target)) {
  backup <- file.path(backup_dir,basename(target))
  stopifnot(!file.exists(backup),file.copy(target,backup,overwrite=FALSE),
   identical(unname(tools::md5sum(target)),unname(tools::md5sum(backup))))
 }
 tmp <- paste0(target,'.publishing_',run_id)
 stopifnot(file.copy(src,tmp,overwrite=TRUE),
  identical(unname(tools::md5sum(src)),unname(tools::md5sum(tmp))))
 if(file.exists(target)) stopifnot(file.remove(target))
 stopifnot(file.rename(tmp,target),
  identical(unname(tools::md5sum(src)),unname(tools::md5sum(target))))
}
stopifnot(identical(input_md5,unname(tools::md5sum(input_paths))),
 identical(protected$md5,unname(tools::md5sum(protected$path))),
 identical(unname(tools::md5sum(dest)),unname(tools::md5sum(stage))))
dbDisconnect(con,shutdown=TRUE)
cat('Completed degree-duration CWUR and Shanghai flags:',run_id,'\n')
print(catalog_stats)
print(coverage)
