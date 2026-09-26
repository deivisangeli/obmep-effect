# Local, offline preparation. Rebuilds only RUF and Shanghai education flags
# from the completed global OpenAlex hierarchy. Never send this script to SEDAP.
library(DBI)
library(duckdb)
library(jsonlite)
options(stringsAsFactors=FALSE)

root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh <- file.path(root,'Data/intermediate/revelio_br_cohort')
global_dir <- file.path(coh,'global_oa_hierarchy')
education_glob <- file.path(global_dir,'education_parts','*.parquet')
snapshot <- 'C:/Users/megaj/Globtalent Dropbox/GTAllocation/Data/external/oa_snapshot/data/institutions'
snapshot_paths <- list.files(snapshot,pattern='[.]gz$',recursive=TRUE,full.names=TRUE)
family_path <- file.path(global_dir,'family_catalog.parquet')
patterns_path <- Sys.getenv('OBMEP_DEGREE_PATTERNS','prep/building_external_data/br_degree_patterns.R')
source(patterns_path)

resume_run <- Sys.getenv('OBMEP_RANKED_FLAG_RESUME_RUN','')
stopifnot(!nzchar(resume_run) || grepl('^[0-9]{8}T[0-9]{6}$',resume_run))
run_id <- if(nzchar(resume_run)) resume_run else format(Sys.time(),'%Y%m%dT%H%M%S')
stage_dir <- file.path(coh,'.ranked_flags_staging',run_id)
backup_dir <- file.path(coh,'ranked_flags_backups',run_id)
dir.create(stage_dir,recursive=TRUE,showWarnings=FALSE)

dest <- c(
 ruf=file.path(coh,'obmep_candidates_step_1_ruf_degree.parquet'),
 shanghai=file.path(coh,'obmep_candidates_step_1_shanghai.parquet'),
 shanghai_alias=file.path(coh,'obmep_candidates_step_1_shanghai_rsid_nofloor.parquet'),
 ruf_report=file.path(coh,'obmep_candidates_step_1_ruf_degree_report.json'),
 shanghai_report=file.path(coh,'obmep_candidates_step_1_shanghai_rsid_nofloor_report.json'),
 combined_report=file.path(coh,'ranked_education_flags_redefinition_report.json'),
 parent_map=file.path(global_dir,'global_oa_parent_map.parquet'),
 decisions=file.path(global_dir,'global_oa_parent_adjusted_decisions.parquet'),
 ranked_catalog=file.path(global_dir,'global_oa_ranked_parent_catalog.parquet'))
stage <- file.path(stage_dir,basename(dest))
names(stage) <- names(dest)
stopifnot(length(snapshot_paths)>0,all(file.exists(c(family_path,patterns_path))),
 length(list.files(file.path(global_dir,'education_parts'),pattern='[.]parquet$'))==30L)

input_paths <- c(list.files(file.path(global_dir,'education_parts'),pattern='[.]parquet$',full.names=TRUE),
 snapshot_paths,family_path,patterns_path,file.path(global_dir,'implementation_manifest.rds'))
input_md5 <- unname(tools::md5sum(input_paths))
stopifnot(!anyNA(input_md5))

# Reuse the prior preservation manifest, excluding files this run is authorized to replace.
prior_manifest_path <- file.path(global_dir,'preservation_manifest.rds')
prior_manifest <- readRDS(prior_manifest_path)
protected <- prior_manifest[!tolower(prior_manifest$path) %in% tolower(dest),,drop=FALSE]
audit_dir <- 'outputs/global-oa-parent-audit-200-20260908'
audit_paths <- if(dir.exists(audit_dir)) list.files(audit_dir,recursive=TRUE,full.names=TRUE) else character()
audit_paths <- audit_paths[!dir.exists(audit_paths)]
audit_before <- if(length(audit_paths)) unname(tools::md5sum(audit_paths)) else character()
current_protected <- unname(tools::md5sum(protected$path))
stopifnot(all(file.exists(protected$path)),identical(tolower(current_protected),tolower(protected$md5)))

con <- dbConnect(duckdb(),dbdir=file.path(stage_dir,'work.duckdb'))
on.exit(try(dbDisconnect(con,shutdown=TRUE),silent=TRUE),add=TRUE)
dbExecute(con,"SET memory_limit='8GB'")
dbExecute(con,'SET threads=4')
spill <- gsub('\\\\','/',file.path(stage_dir,'spill'))
dir.create(spill,recursive=TRUE,showWarnings=FALSE)
dbExecute(con,sprintf("SET temp_directory='%s'",spill))
dbExecute(con,sprintf("CREATE OR REPLACE VIEW education AS SELECT * FROM read_parquet('%s')",education_glob))

if(!'oa' %in% dbListTables(con)) {
 cat('Loading the frozen OpenAlex institution snapshot...\n')
 dbExecute(con,sprintf("CREATE TABLE oa AS SELECT regexp_extract(id,'I[0-9]+') oa_id,
  display_name,type,country_code,associated_institutions
  FROM read_json('%s/updated_date=*/part_*.gz',format='newline_delimited',filename=true,
   columns={id:'VARCHAR',display_name:'VARCHAR',type:'VARCHAR',country_code:'VARCHAR',
   associated_institutions:'STRUCT(id VARCHAR,display_name VARCHAR,relationship VARCHAR)[]'})
  QUALIFY row_number() OVER(PARTITION BY id ORDER BY filename DESC)=1",snapshot))
 stopifnot(dbGetQuery(con,'SELECT count(*) n,count(DISTINCT oa_id) ids FROM oa')$n==120658L)
}

if(!'parent_map' %in% dbListTables(con)) {
 cat('Building the unique immediate-parent map...\n')
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

if(!'decision_parent' %in% dbListTables(con)) {
 cat('Collapsing selected IDs to parent-adjusted decision sets...\n')
 stopifnot(dbGetQuery(con,"SELECT count(*) n FROM education WHERE global_oa_decision_id IS NULL
  AND global_oa_selected_count>0")$n==0)
 dbExecute(con,"CREATE TABLE decision_sets AS SELECT global_oa_decision_id,
  first(global_oa_selected_ids) selected_ids,
  first(global_oa_selected_ids_pipe) selected_ids_pipe,
  first(global_oa_selected_count)::INTEGER selected_count
  FROM education WHERE global_oa_decision_id IS NOT NULL GROUP BY global_oa_decision_id")
 stopifnot(dbGetQuery(con,"SELECT count(*) n FROM (SELECT global_oa_decision_id
  FROM education WHERE global_oa_decision_id IS NOT NULL GROUP BY 1
  HAVING count(DISTINCT coalesce(global_oa_selected_ids_pipe,''))>1
   OR count(DISTINCT global_oa_selected_count)>1)")$n==0)
 dbExecute(con,"CREATE TABLE decision_parent_expanded AS SELECT d.global_oa_decision_id,u.oa_id,
  coalesce(p.canonical_id,u.oa_id) canonical_id,
  coalesce(p.parent_replaced,false) parent_replaced,
  p.oa_id IS NULL missing_from_snapshot
  FROM decision_sets d CROSS JOIN unnest(d.selected_ids) u(oa_id)
  LEFT JOIN parent_map p ON p.oa_id=u.oa_id WHERE d.selected_count>0")
 dbExecute(con,"CREATE TABLE decision_parent_agg AS SELECT global_oa_decision_id,
  list(DISTINCT canonical_id ORDER BY canonical_id) parent_adjusted_ids,
  bool_or(parent_replaced) parent_replacement_applied,
  bool_or(missing_from_snapshot) missing_selected_id
  FROM decision_parent_expanded GROUP BY 1")
 dbExecute(con,"CREATE TABLE decision_parent AS SELECT d.global_oa_decision_id,d.selected_ids,
  d.selected_ids_pipe,d.selected_count,
  coalesce(a.parent_adjusted_ids,[]::VARCHAR[]) parent_adjusted_ids,
  coalesce(len(a.parent_adjusted_ids),0)::INTEGER parent_adjusted_count,
  coalesce(a.parent_replacement_applied,false) parent_replacement_applied,
  coalesce(a.missing_selected_id,false) missing_selected_id,
  CASE WHEN d.selected_count=0 THEN 'unassigned'
   WHEN len(a.parent_adjusted_ids)=1 THEN 'unique'
   ELSE 'multiple' END parent_adjusted_status
  FROM decision_sets d LEFT JOIN decision_parent_agg a USING(global_oa_decision_id)")
 stopifnot(dbGetQuery(con,"SELECT count(*) n FROM decision_parent WHERE
  parent_adjusted_count<>len(parent_adjusted_ids)
  OR (parent_adjusted_status='unique') IS DISTINCT FROM (parent_adjusted_count=1)
  OR parent_adjusted_count>selected_count")$n==0)
}

if(!'ranked_parent_catalog' %in% dbListTables(con)) {
 cat('Parent-adjusting the RUF and Shanghai catalogs...\n')
 dbExecute(con,sprintf("CREATE TABLE ranked_parent_catalog AS SELECT f.family,f.oa_id,
  f.rk,f.inst,f.rid,coalesce(p.canonical_id,f.oa_id) canonical_id,
  coalesce(p.n_parents,0)::INTEGER n_parents,p.unique_parent_id,
  coalesce(p.parent_replaced,false) parent_replaced,p.oa_id IS NULL missing_from_snapshot
  FROM read_parquet('%s') f LEFT JOIN parent_map p USING(oa_id)
  WHERE f.family IN ('rd','sh')",family_path))
 stopifnot(dbGetQuery(con,"SELECT count(*) n FROM ranked_parent_catalog WHERE
  oa_id IS NULL OR canonical_id IS NULL OR missing_from_snapshot")$n==0,
  dbGetQuery(con,"SELECT count(*) n FROM ranked_parent_catalog")$n==1022L)
 dbExecute(con,"CREATE TABLE family_rank_sets AS SELECT family,canonical_id,
  list(DISTINCT oa_id ORDER BY oa_id) source_ids,
  min(rk)::INTEGER rk,
  first(inst ORDER BY rk NULLS LAST,oa_id,rid NULLS LAST) inst,
  first(oa_id ORDER BY rk NULLS LAST,oa_id,rid NULLS LAST) inst_key,
  first(rid ORDER BY rk NULLS LAST,oa_id,rid NULLS LAST) rid
  FROM ranked_parent_catalog GROUP BY family,canonical_id")
}

# The exported compact products are staged before any production file changes.
dbExecute(con,sprintf("COPY (SELECT * FROM parent_map ORDER BY oa_id) TO '%s'
 (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",gsub('\\\\','/',stage['parent_map'])))
dbExecute(con,sprintf("COPY (SELECT * FROM decision_parent ORDER BY global_oa_decision_id) TO '%s'
 (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",gsub('\\\\','/',stage['decisions'])))
dbExecute(con,sprintf("COPY (SELECT * FROM ranked_parent_catalog ORDER BY family,canonical_id,rk,oa_id) TO '%s'
 (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",gsub('\\\\','/',stage['ranked_catalog'])))

entry_dir <- file.path(stage_dir,'ranked_entries')
if(!dir.exists(entry_dir) || !length(list.files(entry_dir,recursive=TRUE,pattern='[.]parquet$'))) {
 cat('Writing bounded parent-adjusted ranking-entry partitions...\n')
 dir.create(entry_dir,recursive=TRUE,showWarnings=FALSE)
 dbExecute(con,sprintf("COPY (SELECT r.family,CAST(hash(e.user_id)%%32 AS INTEGER) bucket,
  e.source_file,e.source_row,e.user_id,e.br_oa_level lvl,e.br_oa_is_mba is_mba,
  e.br_oa_is_lato is_lato,e.br_oa_start_year yr,e.global_oa_match_route route,
  d.selected_count,d.parent_adjusted_count,d.parent_replacement_applied,
  d.parent_adjusted_ids[1] canonical_id,r.source_ids,r.rk,r.inst,r.inst_key,r.rid
  FROM education e JOIN decision_parent d USING(global_oa_decision_id)
  JOIN family_rank_sets r ON d.parent_adjusted_count=1
   AND d.parent_adjusted_ids[1]=r.canonical_id)
  TO '%s' (FORMAT PARQUET,PARTITION_BY(family,bucket),COMPRESSION ZSTD)",gsub('\\\\','/',entry_dir)))
}
dbExecute(con,sprintf("CREATE OR REPLACE VIEW ranked_entries AS SELECT * FROM read_parquet('%s/*/*/*.parquet',hive_partitioning=true)",gsub('\\\\','/',entry_dir)))
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM (SELECT family,source_file,source_row,count(*) c
 FROM ranked_entries GROUP BY 1,2,3 HAVING c<>1)")$n==0,
 dbGetQuery(con,"SELECT count(*) n FROM ranked_entries WHERE parent_adjusted_count<>1
  OR canonical_id IS NULL OR len(source_ids)=0")$n==0)

flag_parts <- list()
for(kind in c('rd','sh')) {
 pfx <- kind
 out_dir <- file.path(stage_dir,paste0(kind,'_flag_parts'))
 dir.create(out_dir,recursive=TRUE,showWarnings=FALSE)
 buckets <- sort(list.dirs(file.path(entry_dir,paste0('family=',kind)),recursive=FALSE,full.names=TRUE))
 stopifnot(length(buckets)>0)
 for(i in seq_along(buckets)) {
  part <- file.path(out_dir,sprintf('part_%02d.parquet',i))
  if(file.exists(part)) next
  extra <- if(kind=='rd') ",
   CAST(max(CASE WHEN route='raw_c_norm' AND lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) AS INTEGER) rd_name_any,
   0::INTEGER rd_abbr_any,
   first(rid ORDER BY rk,inst_key,rid) FILTER(WHERE lvl IN ('bachelor','master','phd')) rd_best_inst_id" else ",
   coalesce(list_sort(list_distinct(flatten(list(source_ids) FILTER(WHERE lvl='bachelor')))),[]::VARCHAR[]) sh_bach_institution_keys,
   coalesce(list_sort(list_distinct(flatten(list(source_ids) FILTER(WHERE lvl='master')))),[]::VARCHAR[]) sh_mast_institution_keys,
   coalesce(list_sort(list_distinct(flatten(list(source_ids) FILTER(WHERE lvl='phd')))),[]::VARCHAR[]) sh_phd_institution_keys"
  dbExecute(con,sprintf("COPY (SELECT user_id,1::INTEGER %1$s_any,
   CAST(max(CASE WHEN route='rsid' AND lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) AS INTEGER) %1$s_rsid_any,
   CAST(max(CASE WHEN route='raw_c_norm' AND lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) AS INTEGER) %1$s_raw_any,
   CAST(max(CASE WHEN lvl='bachelor' THEN 1 ELSE 0 END) AS INTEGER) %1$s_bachelor,
   CAST(max(CASE WHEN lvl='master' THEN 1 ELSE 0 END) AS INTEGER) %1$s_master,
   CAST(max(CASE WHEN lvl='master' AND NOT is_mba THEN 1 ELSE 0 END) AS INTEGER) %1$s_master_strict,
   CAST(max(CASE WHEN lvl='phd' THEN 1 ELSE 0 END) AS INTEGER) %1$s_phd,
   CAST(max(CASE WHEN is_lato THEN 1 ELSE 0 END) AS INTEGER) %1$s_lato,
   min(rk) FILTER(WHERE lvl IN ('bachelor','master','phd')) %1$s_best_rank,
   min(rk) FILTER(WHERE lvl='bachelor') %1$s_bach_rank,
   min(rk) FILTER(WHERE lvl='master') %1$s_mast_rank,
   min(rk) FILTER(WHERE lvl='phd') %1$s_phd_rank,
   first(inst ORDER BY rk,inst_key,rid NULLS LAST) FILTER(WHERE lvl='bachelor') %1$s_bach_inst,
   first(inst ORDER BY rk,inst_key,rid NULLS LAST) FILTER(WHERE lvl='master') %1$s_mast_inst,
   first(inst ORDER BY rk,inst_key,rid NULLS LAST) FILTER(WHERE lvl='phd') %1$s_phd_inst,
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
   TO '%4$s' (FORMAT PARQUET,COMPRESSION ZSTD)",pfx,extra,gsub('\\\\','/',buckets[i]),gsub('\\\\','/',part)))
 }
 flag_parts[[kind]] <- out_dir
 dbExecute(con,sprintf("CREATE OR REPLACE VIEW new_%s AS SELECT * FROM read_parquet('%s/*.parquet')",kind,gsub('\\\\','/',out_dir)))
 old_path <- if(kind=='rd') dest['ruf'] else dest['shanghai']
 old_schema <- dbGetQuery(con,sprintf("DESCRIBE SELECT * FROM read_parquet('%s')",gsub('\\\\','/',old_path)))
 new_schema <- dbGetQuery(con,sprintf('DESCRIBE new_%s',kind))
 stopifnot(all(old_schema$column_name %in% new_schema$column_name),
  all(old_schema$column_type==new_schema$column_type[match(old_schema$column_name,new_schema$column_name)]))
 cols <- old_schema$column_name
 out_path <- if(kind=='rd') stage['ruf'] else stage['shanghai']
 dbExecute(con,sprintf("COPY (SELECT %s FROM new_%s) TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",
  paste(sprintf('"%s"',cols),collapse=','),kind,gsub('\\\\','/',out_path)))
}
file.copy(stage['shanghai'],stage['shanghai_alias'],overwrite=TRUE)
stopifnot(identical(unname(tools::md5sum(stage['shanghai'])),unname(tools::md5sum(stage['shanghai_alias']))))

# Full output and aggregation reconciliation.
for(kind in c('rd','sh')) {
 pfx <- kind
 dbExecute(con,sprintf("CREATE OR REPLACE VIEW flags AS SELECT * FROM read_parquet('%s')",
  gsub('\\\\','/',if(kind=='rd') stage['ruf'] else stage['shanghai'])))
 valid <- dbGetQuery(con,sprintf("SELECT count(*) n,count(DISTINCT user_id) ids,
  count(*) FILTER(WHERE user_id IS NULL OR %1$s_any<>1
   OR %1$s_bachelor+%1$s_master+%1$s_phd=0
   OR %1$s_master_strict>%1$s_master OR %1$s_rsid_any+%1$s_raw_any=0) bad FROM flags",pfx))
 stopifnot(valid$n==valid$ids,valid$bad==0)
 expected <- dbGetQuery(con,sprintf("SELECT count(DISTINCT user_id) n FROM ranked_entries
  WHERE family='%s' AND lvl IN ('bachelor','master','phd')",kind))$n
 stopifnot(valid$n==expected)
 rows_bad <- dbGetQuery(con,sprintf("WITH x AS (SELECT user_id,count(*) n FROM ranked_entries
  WHERE family='%1$s' GROUP BY user_id HAVING count(*) FILTER(WHERE lvl IN ('bachelor','master','phd'))>0)
  SELECT count(*) n FROM x FULL JOIN flags f USING(user_id)
  WHERE x.user_id IS NULL OR f.user_id IS NULL OR x.n<>f.%1$s_n_rows",kind))$n
 stopifnot(rows_bad==0)
 for(level in c('bachelor','master','phd')) {
  short <- c(bachelor='bach',master='mast',phd='phd')[level]
  n_expected <- dbGetQuery(con,sprintf("SELECT count(DISTINCT user_id) n FROM ranked_entries
   WHERE family='%s' AND lvl='%s'",kind,level))$n
  n_actual <- dbGetQuery(con,sprintf("SELECT sum(%s_%s) n FROM flags",pfx,level))$n
  stopifnot(n_expected==n_actual)
  stopifnot(dbGetQuery(con,sprintf("WITH x AS (SELECT user_id,min(yr) yr,min(rk) rk FROM ranked_entries
   WHERE family='%1$s' AND lvl='%2$s' GROUP BY user_id) SELECT count(*) n FROM x JOIN flags f USING(user_id)
   WHERE x.yr IS DISTINCT FROM f.%1$s_%3$s_year OR x.rk IS DISTINCT FROM f.%1$s_%3$s_rank",kind,level,short))$n==0)
 }
 list_fields <- c('bach','mast','mast_strict','phd')
 stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM flags WHERE %s",
  paste(sprintf("%1$s_%2$s_institutions IS DISTINCT FROM list_sort(list_distinct(%1$s_%2$s_institutions))",pfx,list_fields),collapse=' OR ')))$n==0)
 if(kind=='rd') stopifnot(dbGetQuery(con,"SELECT count(*) n FROM flags WHERE rd_abbr_any<>0 OR rd_name_any<>rd_raw_any")$n==0)
 if(kind=='sh') stopifnot(dbGetQuery(con,"SELECT count(*) n FROM flags WHERE
  sh_bach_institution_keys IS DISTINCT FROM sh_bach_institutions
  OR sh_mast_institution_keys IS DISTINCT FROM sh_mast_institutions
  OR sh_phd_institution_keys IS DISTINCT FROM sh_phd_institutions")$n==0)
}

cat('Computing comparisons and reports...\n')
old_counts <- list(); comparisons <- list()
for(kind in c('rd','sh')) {
 pfx <- kind; old <- if(kind=='rd') dest['ruf'] else dest['shanghai']; new <- if(kind=='rd') stage['ruf'] else stage['shanghai']
 dbExecute(con,sprintf("CREATE OR REPLACE VIEW old_flags AS SELECT * FROM read_parquet('%s')",gsub('\\\\','/',old)))
 dbExecute(con,sprintf("CREATE OR REPLACE VIEW new_flags AS SELECT * FROM read_parquet('%s')",gsub('\\\\','/',new)))
 levels <- c(any='any',bachelor='bachelor',master='master',master_strict='master_strict',phd='phd',lato='lato')
 comparisons[[kind]] <- do.call(rbind,lapply(names(levels),function(label) {
  col <- paste0(pfx,'_',levels[[label]])
  x <- dbGetQuery(con,sprintf("SELECT '%s' flag,
   count(*) FILTER(WHERE coalesce(o.%s,0)=1) old_users,
   count(*) FILTER(WHERE coalesce(n.%s,0)=1) new_users,
   count(*) FILTER(WHERE coalesce(o.%s,0)=1 AND coalesce(n.%s,0)=1) retained,
   count(*) FILTER(WHERE coalesce(o.%s,0)=0 AND coalesce(n.%s,0)=1) gained,
   count(*) FILTER(WHERE coalesce(o.%s,0)=1 AND coalesce(n.%s,0)=0) lost
   FROM old_flags o FULL JOIN new_flags n USING(user_id)",label,col,col,col,col,col,col,col,col))
  x
 }))
}

parent_stats <- dbGetQuery(con,"SELECT count(*) decisions,
 count(*) FILTER(WHERE selected_count>0) selected_decisions,
 count(*) FILTER(WHERE parent_replacement_applied) decisions_with_replacement,
 count(*) FILTER(WHERE selected_count>1 AND parent_adjusted_count=1) collapsed_to_unique,
 count(*) FILTER(WHERE parent_adjusted_count>1) remaining_multiple,
 count(*) FILTER(WHERE missing_selected_id) missing_selected_id FROM decision_parent")
entry_stats <- dbGetQuery(con,"SELECT count(*) education_rows,
 count(*) FILTER(WHERE global_oa_selected_count>0) selected_before_parent,
 count(*) FILTER(WHERE d.parent_adjusted_count=1) unique_after_parent,
 count(*) FILTER(WHERE d.parent_adjusted_count>1) excluded_multiple,
 count(*) FILTER(WHERE d.parent_replacement_applied) rows_with_parent_replacement,
 count(*) FILTER(WHERE global_oa_selected_count>1 AND d.parent_adjusted_count=1) rows_collapsed_to_unique
 FROM education e LEFT JOIN decision_parent d USING(global_oa_decision_id)")
catalog_stats <- dbGetQuery(con,"SELECT family,count(*) source_ids,count(DISTINCT canonical_id) canonical_ids,
 count(*) FILTER(WHERE parent_replaced) parent_replaced,
 count(DISTINCT canonical_id) FILTER(WHERE canonical_id IN
  (SELECT canonical_id FROM ranked_parent_catalog z WHERE z.family=ranked_parent_catalog.family GROUP BY canonical_id HAVING count(*)>1)) collision_keys
 FROM ranked_parent_catalog GROUP BY family ORDER BY family")
coverage <- dbGetQuery(con,"SELECT family,count(*) matched_rows,count(DISTINCT user_id) matched_users,
 count(*) FILTER(WHERE lvl IN ('bachelor','master','phd')) qualifying_rows,
 count(DISTINCT user_id) FILTER(WHERE lvl IN ('bachelor','master','phd')) qualifying_users
 FROM ranked_entries GROUP BY family ORDER BY family")

output_md5 <- unname(tools::md5sum(stage[c('ruf','shanghai','shanghai_alias','parent_map','decisions','ranked_catalog')]))
report <- list(run_id=run_id,method=list(
 education_source='Completed global OpenAlex hierarchy selections',
 parent_rule='Unique immediate parent; original ID retained for zero or multiple parents; deduplicate; require exactly one resulting ID',
 ranking_rule='Apply the same canonicalization to education and ranking IDs',
 collision_rule='Preserve every original ranked OA ID; lowest rank then original OA ID determines best institution',
 degrees='Existing production cascade, high-school veto, MBA, strict-master, lato and enrollment treatment',
 audit_overrides_applied=FALSE),
 inputs=data.frame(path=input_paths,md5=input_md5),parent_decisions=parent_stats,
 education_entries=entry_stats,ranking_catalog=catalog_stats,coverage=coverage,
 comparisons=list(ruf=comparisons$rd,shanghai=comparisons$sh),
 outputs=data.frame(path=unname(dest[c('ruf','shanghai','shanghai_alias','parent_map','decisions','ranked_catalog')]),md5=output_md5),
 validation=list(unique_users=TRUE,parent_sets=TRUE,physical_rows_collapsed=TRUE,
 degree_counts_reconciled=TRUE,years_and_ranks_reconciled=TRUE,sorted_distinct_lists=TRUE,
 stable_rank_ties=TRUE,shanghai_alias_identical=TRUE,protected_files_unchanged=TRUE,
 published_checksums_match_stage=TRUE))
write_json(report,stage['combined_report'],auto_unbox=TRUE,pretty=TRUE,na='null')
write_json(report,stage['ruf_report'],auto_unbox=TRUE,pretty=TRUE,na='null')
write_json(report,stage['shanghai_report'],auto_unbox=TRUE,pretty=TRUE,na='null')

# Verify every protected input and prior audit immediately before publication.
stopifnot(identical(unname(tools::md5sum(input_paths)),input_md5),
 identical(tolower(unname(tools::md5sum(protected$path))),tolower(protected$md5)))
if(length(audit_paths)) stopifnot(identical(unname(tools::md5sum(audit_paths)),audit_before))

cat('Publishing validated outputs with timestamped backups...\n')
dir.create(backup_dir,recursive=TRUE,showWarnings=FALSE)
publish_names <- names(dest)
for(nm in publish_names) {
 src <- stage[nm]; target <- dest[nm]
 stopifnot(file.exists(src))
 if(file.exists(target)) {
  backup <- file.path(backup_dir,basename(target))
  stopifnot(file.copy(target,backup,overwrite=FALSE),
   identical(unname(tools::md5sum(target)),unname(tools::md5sum(backup))))
 }
 tmp <- paste0(target,'.publishing_',run_id)
 stopifnot(file.copy(src,tmp,overwrite=TRUE),
  identical(unname(tools::md5sum(src)),unname(tools::md5sum(tmp))))
 if(file.exists(target)) stopifnot(file.remove(target))
 stopifnot(file.rename(tmp,target),identical(unname(tools::md5sum(src)),unname(tools::md5sum(target))))
}

# Final preservation and publication checks; then refresh the report validation bit.
stopifnot(identical(unname(tools::md5sum(input_paths)),input_md5),
 identical(tolower(unname(tools::md5sum(protected$path))),tolower(protected$md5)))
if(length(audit_paths)) stopifnot(identical(unname(tools::md5sum(audit_paths)),audit_before))
stopifnot(identical(unname(tools::md5sum(dest['shanghai'])),unname(tools::md5sum(dest['shanghai_alias']))))
published_checksums_match_stage <- identical(
 unname(tools::md5sum(dest[publish_names])),unname(tools::md5sum(stage[publish_names])))
stopifnot(published_checksums_match_stage)
cat('Completed ranked education flag redefinition:',run_id,'\n')
print(coverage)
print(comparisons$rd)
print(comparisons$sh)
