# Sourced by global_oa_rsid_hierarchy.R. Existing production degree aggregation,
# repeated for global crosswalk candidates (pre) and hierarchy selections (post).
dbExecute(con,sprintf("CREATE OR REPLACE TABLE family_catalog AS SELECT 'br' AS family,openalex_id oa_id,
 NULL::INTEGER rk,display_name inst,NULL::INTEGER rid FROM read_parquet('%s')
 UNION ALL SELECT 'rd',x.openalex_id,CAST(i.best_rank AS INTEGER),i.abbr,CAST(i.ruf_institution_id AS INTEGER)
 FROM read_parquet('%s') x JOIN read_parquet('%s') i USING(ruf_institution_id)
 UNION ALL SELECT 'sh',oa_key,CAST(shanghai_rank AS INTEGER),shanghai_name,NULL::INTEGER
 FROM read_parquet('%s') WHERE shanghai_rank<=901 AND oa_key IN (SELECT oa_id FROM catalog)",br_path,ruf_paths[1],ruf_paths[2],sh_path))
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM family_catalog WHERE family='rd'")$n==23,
 dbGetQuery(con,'SELECT count(*) n FROM family_catalog')$n==dbGetQuery(con,'SELECT count(DISTINCT(family,oa_id)) n FROM family_catalog')$n)
dbExecute(con,sprintf("COPY family_catalog TO '%s/family_catalog.parquet' (FORMAT PARQUET,COMPRESSION ZSTD)",out))
for(variant in c('pre','post')) for(kind in c('br','rd','sh')) {
 pfx <- if(kind=='br') 'br_oa' else kind
 phase <- file.path(out,'checkpoints',paste0('flags_',variant,'_',kind,'.rds'))
 flag_dest <- file.path(out,paste0('global_oa_',variant,'_',kind,'_flags.parquet'))
 if(file.exists(phase)) {stopifnot(identical(readRDS(phase),tools::md5sum(flag_dest)));next}
 cat('Aggregating comparison flags:',variant,kind,'\n')
 family_dir <- file.path(out,paste0('aggregation_',variant,'_',kind))
 dir.create(file.path(family_dir,'flags'),recursive=TRUE,showWarnings=FALSE)
 ids_col <- if(variant=='pre') 'global_oa_candidate_ids' else 'global_oa_selected_ids'
 pipe_col <- paste0(ids_col,'_pipe')
 dbExecute(con,sprintf("CREATE OR REPLACE TABLE family_sets AS WITH sets AS (
  SELECT DISTINCT %s ids,%s ids_pipe FROM enriched WHERE len(%s)>0)
  SELECT s.ids_pipe,list(c.oa_id ORDER BY c.oa_id) candidate_ids,
   first(c.rk ORDER BY c.rk,c.oa_id,c.rid) rk,
   first(c.inst ORDER BY c.rk,c.oa_id,c.rid) inst,
   first(c.oa_id ORDER BY c.rk,c.oa_id,c.rid) inst_key,
   first(c.rid ORDER BY c.rk,c.oa_id,c.rid) rid
  FROM sets s CROSS JOIN unnest(s.ids) u(oa_id) JOIN family_catalog c ON c.oa_id=u.oa_id AND c.family='%s'
  GROUP BY s.ids_pipe",ids_col,pipe_col,ids_col,kind))
 dbExecute(con,sprintf("CREATE OR REPLACE VIEW normalized AS SELECT e.user_id,e.br_oa_level lvl,
  e.br_oa_is_mba is_mba,e.br_oa_is_lato is_lato,e.br_oa_start_year yr,e.global_oa_match_route route,
  s.candidate_ids,s.candidate_ids candidate_keys,s.rk,s.inst,s.inst_key,s.rid
  FROM enriched e JOIN family_sets s ON e.%s=s.ids_pipe",pipe_col))
 input_done <- file.path(family_dir,'input_done.rds')
 if(!file.exists(input_done)) {
  dbExecute(con,sprintf("COPY (SELECT *,CAST(hash(user_id)%%32 AS INTEGER) bucket FROM normalized)
   TO '%s/input' (FORMAT PARQUET,PARTITION_BY(bucket),COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",family_dir))
  saveRDS(TRUE,input_done)
 }
 buckets <- sort(list.dirs(file.path(family_dir,'input'),recursive=FALSE,full.names=TRUE))
 rank_fields <- ''
 if(kind!='br') rank_fields <- sprintf(",min(rk) FILTER(WHERE lvl IN ('bachelor','master','phd')) %1$s_best_rank,
   min(rk) FILTER(WHERE lvl='bachelor') %1$s_bach_rank,min(rk) FILTER(WHERE lvl='master') %1$s_mast_rank,
   min(rk) FILTER(WHERE lvl='phd') %1$s_phd_rank,
   first(inst ORDER BY rk,inst_key,rid) FILTER(WHERE lvl='bachelor') %1$s_bach_inst,
   first(inst ORDER BY rk,inst_key,rid) FILTER(WHERE lvl='master') %1$s_mast_inst,
   first(inst ORDER BY rk,inst_key,rid) FILTER(WHERE lvl='phd') %1$s_phd_inst",pfx)
 if(kind=='rd') rank_fields <- paste0(rank_fields,",
   CAST(max(CASE WHEN route='raw_c_norm' AND lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) AS INTEGER) rd_name_any,
   0::INTEGER rd_abbr_any,
   first(rid ORDER BY rk,inst_key,rid) FILTER(WHERE lvl IN ('bachelor','master','phd')) rd_best_inst_id")
 if(kind=='sh') rank_fields <- paste0(rank_fields,",
   coalesce(list_sort(list_distinct(flatten(list(candidate_keys) FILTER(WHERE lvl='bachelor')))),[]::VARCHAR[]) sh_bach_institution_keys,
   coalesce(list_sort(list_distinct(flatten(list(candidate_keys) FILTER(WHERE lvl='master')))),[]::VARCHAR[]) sh_mast_institution_keys,
   coalesce(list_sort(list_distinct(flatten(list(candidate_keys) FILTER(WHERE lvl='phd')))),[]::VARCHAR[]) sh_phd_institution_keys")
 for(i in seq_along(buckets)) {
  part <- file.path(family_dir,'flags',sprintf('part_%02d.parquet',i))
  mark <- paste0(part,'.rds')
  if(file.exists(mark)) {stopifnot(identical(readRDS(mark),tools::md5sum(part)));next}
  dbExecute(con,sprintf("COPY (SELECT user_id,1::INTEGER %1$s_any,
  CAST(max(CASE WHEN route='rsid' AND lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) AS INTEGER) %1$s_rsid_any,
  CAST(max(CASE WHEN route='raw_c_norm' AND lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) AS INTEGER) %1$s_raw_any,
  CAST(max(CASE WHEN lvl='bachelor' THEN 1 ELSE 0 END) AS INTEGER) %1$s_bachelor,
  CAST(max(CASE WHEN lvl='master' THEN 1 ELSE 0 END) AS INTEGER) %1$s_master,
  CAST(max(CASE WHEN lvl='master' AND NOT is_mba THEN 1 ELSE 0 END) AS INTEGER) %1$s_master_strict,
  CAST(max(CASE WHEN lvl='phd' THEN 1 ELSE 0 END) AS INTEGER) %1$s_phd,
  CAST(max(CASE WHEN is_lato THEN 1 ELSE 0 END) AS INTEGER) %1$s_lato,
  min(yr) FILTER(WHERE lvl='bachelor') %1$s_bach_year,min(yr) FILTER(WHERE lvl='master') %1$s_mast_year,
  min(yr) FILTER(WHERE lvl='phd') %1$s_phd_year,
  coalesce(list_sort(list_distinct(flatten(list(candidate_ids) FILTER(WHERE lvl='bachelor')))),[]::VARCHAR[]) %1$s_bach_institutions,
  coalesce(list_sort(list_distinct(flatten(list(candidate_ids) FILTER(WHERE lvl='master')))),[]::VARCHAR[]) %1$s_mast_institutions,
  coalesce(list_sort(list_distinct(flatten(list(candidate_ids) FILTER(WHERE lvl='master' AND NOT is_mba)))),[]::VARCHAR[]) %1$s_mast_strict_institutions,
  coalesce(list_sort(list_distinct(flatten(list(candidate_ids) FILTER(WHERE lvl='phd')))),[]::VARCHAR[]) %1$s_phd_institutions,
  CAST(count(*) AS INTEGER) %1$s_n_rows %2$s
  FROM read_parquet('%3$s/*.parquet') GROUP BY user_id
  HAVING max(CASE WHEN lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END)=1)
  TO '%4$s' (FORMAT PARQUET,COMPRESSION ZSTD)",pfx,rank_fields,buckets[i],part))
  saveRDS(tools::md5sum(part),mark)
 }
 dbExecute(con,sprintf("CREATE OR REPLACE VIEW flags AS SELECT * FROM read_parquet('%s/flags/*.parquet')",family_dir))
 valid <- dbGetQuery(con,sprintf("SELECT count(*) n,count(DISTINCT user_id) ids,
  count(*) FILTER(WHERE user_id IS NULL OR %1$s_any<>1 OR %1$s_bachelor+%1$s_master+%1$s_phd=0
   OR %1$s_master_strict>%1$s_master OR %1$s_rsid_any+%1$s_raw_any=0) bad FROM flags",pfx))
 stopifnot(valid$n==valid$ids,valid$bad==0)
 # Independent user counts, flags, years, rank minima and exact list membership.
 for(i in seq_along(buckets)) {
  dbExecute(con,sprintf("CREATE OR REPLACE TEMP VIEW nb AS SELECT * FROM read_parquet('%s/*.parquet')",buckets[i]))
  dbExecute(con,sprintf("CREATE OR REPLACE TEMP VIEW fb AS SELECT * FROM read_parquet('%s/flags/part_%02d.parquet')",family_dir,i))
  stopifnot(dbGetQuery(con,sprintf("WITH x AS (SELECT user_id,count(*) n FROM nb GROUP BY 1
   HAVING bool_or(lvl IN ('bachelor','master','phd')))
   SELECT count(*) n FROM x FULL JOIN fb USING(user_id) WHERE x.n IS DISTINCT FROM fb.%s_n_rows",pfx))$n==0)
  for(level in c('bachelor','master','master_strict','phd','lato','rsid_any','raw_any')) {
   predicate <- switch(level,master_strict="lvl='master' AND NOT is_mba",lato='is_lato',
    rsid_any="route='rsid' AND lvl IN ('bachelor','master','phd')",
    raw_any="route='raw_c_norm' AND lvl IN ('bachelor','master','phd')",paste0("lvl='",level,"'"))
   stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM fb f WHERE f.%s_%s IS DISTINCT FROM
    CAST(EXISTS(SELECT 1 FROM nb e WHERE e.user_id=f.user_id AND %s) AS INTEGER)",pfx,level,predicate))$n==0)
   if(level %in% c('lato','rsid_any','raw_any')) next
   short <- c(bachelor='bach',master='mast',master_strict='mast_strict',phd='phd')[level]
   stopifnot(dbGetQuery(con,sprintf("WITH x AS (SELECT user_id,list(DISTINCT oa_id ORDER BY oa_id) ids
    FROM nb CROSS JOIN unnest(candidate_ids) u(oa_id) WHERE %s GROUP BY 1)
    SELECT count(*) n FROM fb f LEFT JOIN x USING(user_id) WHERE f.%s_%s_institutions IS DISTINCT FROM coalesce(x.ids,[]::VARCHAR[])",predicate,pfx,short))$n==0)
   if(level=='master_strict') next
   fields <- if(kind=='br') '' else sprintf('OR f.%s_%s_rank IS DISTINCT FROM x.rk OR f.%s_%s_inst IS DISTINCT FROM x.inst',pfx,short,pfx,short)
   stopifnot(dbGetQuery(con,sprintf("WITH x AS (SELECT user_id,min(yr) yr,min(rk) rk,
    first(inst ORDER BY rk,inst_key,rid) inst FROM nb WHERE %s GROUP BY 1)
    SELECT count(*) n FROM fb f LEFT JOIN x USING(user_id)
    WHERE f.%s_%s_year IS DISTINCT FROM x.yr %s",predicate,pfx,short,fields))$n==0)
  }
 }
 dbExecute(con,sprintf("COPY flags TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)",flag_dest))
 saveRDS(tools::md5sum(flag_dest),phase)
 cat('Validated',variant,kind,format(valid$n,big.mark=','),'users.\n')
}
