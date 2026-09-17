# Offline local prep only; never send to SEDAP. All three families are staged and
# validated before their main products are replaced. No cohort selection is run.
library(DBI)
library(duckdb)
library(jsonlite)
options(stringsAsFactors=FALSE)
test_run <- '--test' %in% commandArgs(trailingOnly=TRUE)
root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh_dir <- file.path(root,'Data/intermediate/revelio_br_cohort')
if(test_run) coh_dir <- file.path(root,'test/education_flags_rebuild/products')
dir.create(coh_dir,recursive=TRUE,showWarnings=FALSE)
resume_run <- Sys.getenv('OBMEP_FLAG_RESUME_RUN','')
stopifnot(!nzchar(resume_run) || grepl('^[0-9]{8}T[0-9]{6}$',resume_run))
run_id <- if(nzchar(resume_run)) resume_run else format(Sys.time(),'%Y%m%dT%H%M%S')
stage_dir <- file.path(coh_dir,'.education_flags_staging',run_id)
backup_dir <- file.path(coh_dir,'education_flags_backups',run_id)
if(nzchar(resume_run)) stopifnot(dir.exists(stage_dir),!dir.exists(backup_dir))
dir.create(stage_dir,recursive=TRUE,showWarnings=FALSE)
br_prefix <- 'obmep_candidates_step_1_br_openalex_rsid_nofloor'
sh_prefix <- 'obmep_candidates_step_1_shanghai_rsid_nofloor'
flag_names <- c(br=paste0(br_prefix,'.parquet'),rd='obmep_candidates_step_1_ruf_degree.parquet',
 sh='obmep_candidates_step_1_shanghai.parquet')
replace_names <- c(unname(flag_names),paste0(sh_prefix,'.parquet'),
 paste0(c(br_prefix,sh_prefix),'_matches.parquet'),paste0(c(br_prefix,sh_prefix),'_report.json'),
 'obmep_candidates_step_1_ruf_degree_report.json','education_flags_rebuild_report.json')
before_paths <- file.path(coh_dir,replace_names)
before_paths <- before_paths[file.exists(before_paths)]
before_md5 <- tools::md5sum(before_paths)
# Hash all other top-level products, including selected candidates and employers.
protected <- setdiff(list.files(coh_dir,full.names=TRUE),before_paths)
protected <- protected[!dir.exists(protected)]
# Position products are partition directories; include their files as well.
protected_dirs <- list.dirs(coh_dir,recursive=FALSE,full.names=TRUE)
protected_dirs <- protected_dirs[!basename(protected_dirs) %in%
 c('.education_flags_staging','education_flags_backups','obmep_candidates_step_1_education')]
protected <- c(protected,unlist(lapply(protected_dirs,list.files,recursive=TRUE,full.names=TRUE),use.names=FALSE))
protected_md5 <- tools::md5sum(protected)
patterns_path <- Sys.getenv('OBMEP_DEGREE_PATTERNS','prep/building_external_data/br_degree_patterns.R')
source(patterns_path)
patterns_md5 <- tools::md5sum(patterns_path)

if(!nzchar(resume_run)) {
 Sys.setenv(OBMEP_FLAG_BUILD_INTERNAL='1',OBMEP_FLAG_STAGE_DIR=stage_dir)
 for(engine in c('br_openalex_rsid_nofloor_degree_flags.R','shanghai_rsid_nofloor_degree_flags.R')) {
  cat('Building matching records:',engine,'\n')
  sys.source(file.path('prep/building_external_data',engine),envir=new.env())
 }
 Sys.unsetenv(c('OBMEP_FLAG_BUILD_INTERNAL','OBMEP_FLAG_STAGE_DIR'))
} else {
 cat('Resuming staged matches; all input and row validations will run:',run_id,'\n')
}
engine_br <- read_json(file.path(stage_dir,'engine_br.json'),simplifyVector=TRUE)
engine_sh <- read_json(file.path(stage_dir,'engine_sh.json'),simplifyVector=TRUE)
br_matches <- engine_br$matches_stage
sh_matches <- engine_sh$matches_stage
inputs <- unique(rbind(engine_br$inputs,engine_sh$inputs))
stopifnot(file.exists(br_matches),file.exists(sh_matches),
 identical(unname(tools::md5sum(inputs$path)),inputs$md5))
con <- dbConnect(duckdb())
dbExecute(con,"SET memory_limit='8GB'")
dbExecute(con,'SET threads=4')
work_dir <- gsub('\\\\','/',tempfile('education_flags_'))
dir.create(work_dir,recursive=TRUE)
dbExecute(con,sprintf("SET temp_directory='%s'",work_dir))
dbExecute(con,sprintf("CREATE VIEW br AS SELECT * FROM read_parquet('%s')",br_matches))
dbExecute(con,sprintf("CREATE VIEW sh AS SELECT * FROM read_parquet('%s')",sh_matches))
if(test_run) {
 dbExecute(con,"CREATE TABLE ruf AS SELECT * FROM (VALUES ('I1',2,'Alpha University','ALPHA',1),
 ('I2',1,'Beta Technology','BETA',1)) t(openalex_id,ruf_institution_id,institution_name,abbr,best_rank)")
} else {
 ruf_paths <- file.path(root,c('Data/intermediate/ruf_ranking/ruf_openalex_br_2025.parquet',
   'Data/intermediate/ruf_ranking/ruf_stem_top10_institutions_2025.parquet'))
 inputs <- rbind(inputs,data.frame(path=ruf_paths,md5=unname(tools::md5sum(ruf_paths))))
 dbExecute(con,sprintf("CREATE TABLE ruf AS SELECT x.openalex_id,i.ruf_institution_id,i.institution_name,i.abbr,i.best_rank
   FROM read_parquet('%s') x JOIN read_parquet('%s') i USING(ruf_institution_id)",ruf_paths[1],ruf_paths[2]))
}
rv <- dbGetQuery(con,'SELECT count(*) n,count(DISTINCT openalex_id) ids,count(*) FILTER(WHERE openalex_id IS NULL OR best_rank IS NULL OR best_rank>10) bad FROM ruf')
stopifnot(rv$n==if(test_run) 2L else 23L,rv$n==rv$ids,rv$bad==0)
# Intersect DISTINCT candidate sets, not millions of expanded education records.
dbExecute(con,"CREATE TABLE ruf_sets AS WITH sets AS (
 SELECT DISTINCT br_oa_ids_pipe,br_oa_candidate_ids FROM br WHERE br_oa_match=1)
 SELECT s.br_oa_ids_pipe,list_sort(list_distinct(list(r.openalex_id))) candidate_ids,
 first(r.best_rank ORDER BY r.best_rank,r.openalex_id,r.ruf_institution_id) best_rank,
 first(r.abbr ORDER BY r.best_rank,r.openalex_id,r.ruf_institution_id) best_inst,
 first(r.openalex_id ORDER BY r.best_rank,r.openalex_id,r.ruf_institution_id) best_key,
 first(r.ruf_institution_id ORDER BY r.best_rank,r.openalex_id,r.ruf_institution_id) best_rid
 FROM sets s CROSS JOIN UNNEST(s.br_oa_candidate_ids) u(oa_id)
 JOIN ruf r ON r.openalex_id=u.oa_id GROUP BY s.br_oa_ids_pipe")
report <- list(run_id=run_id,test_run=test_run,backup_directory=backup_dir,education_input=engine_br$counts,
 method=list(floor='none',ruf='Any Brazilian candidate in RUF STEM top-10 institution list',
 shanghai='Global Shanghai crosswalk only',degree='Existing cascade with global rx_hs veto in flag processing',
 sample_verdicts_applied=FALSE,candidate_selection_rebuilt=FALSE),families=list())

# Verify refreshed matching products and every original physical education value.
for(kind in c('br','sh')) {
 eng <- if(kind=='br') engine_br else engine_sh
 pfx <- if(kind=='br') 'br_oa' else 'sh'
 dbExecute(con,sprintf("CREATE OR REPLACE VIEW original AS SELECT * EXCLUDE(filename,file_row_number),
 filename source_file,file_row_number source_row FROM read_parquet('%s/*',filename=true,file_row_number=true)",eng$education_dir))
 original_columns <- dbGetQuery(con,'DESCRIBE original')$column_name
 mismatch <- paste(sprintf('o."%1$s" IS DISTINCT FROM m."%1$s"',original_columns),collapse=' OR ')
 files <- dbGetQuery(con,'SELECT DISTINCT source_file FROM original ORDER BY 1')$source_file
 stopifnot(setequal(files,dbGetQuery(con,sprintf('SELECT DISTINCT source_file FROM %s',kind))$source_file))
 for(i in seq_along(files)) {
  q <- as.character(dbQuoteString(con,files[i]))
  keys <- dbGetQuery(con,sprintf("SELECT count(*) n,count(DISTINCT source_row) keys_n FROM %s WHERE source_file=%s",kind,q))
  stopifnot(keys$n==keys$keys_n)
  bad <- dbGetQuery(con,sprintf("SELECT count(*) n FROM (SELECT * FROM original WHERE source_file=%1$s) o
   FULL JOIN (SELECT * FROM %2$s WHERE source_file=%1$s) m USING(source_file,source_row) WHERE %3$s",q,kind,mismatch))$n
  stopifnot(bad==0)
 }
 veto <- dbGetQuery(con,sprintf("SELECT count(*) n FROM %s WHERE regexp_matches(lower(trim(coalesce(degree_raw,''))),'%s') AND %s_level<>'other'",kind,rx_hs,pfx))$n
 stopifnot(veto==0)
 stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM %1$s WHERE
  (%2$s_match=1) IS DISTINCT FROM (%2$s_match_route IN ('rsid','raw_c_norm'))
  OR (%2$s_match_route='rsid' AND (rsid IS NULL OR rsid=2147483647))
  OR (%2$s_match_route='raw_c_norm' AND rsid IS NOT NULL AND rsid<>2147483647)
  OR %2$s_candidate_count<>coalesce(len(%2$s_candidates),0)",kind,pfx))$n==0)
 if(kind=='br') stopifnot(dbGetQuery(con,"SELECT count(*) n FROM br WHERE
  string_split(br_oa_ids_pipe,'|') IS DISTINCT FROM br_oa_candidate_ids
  OR br_oa_candidate_ids IS DISTINCT FROM list_sort(list_distinct(br_oa_candidate_ids))")$n==0)
 if(test_run) {
  stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM %s WHERE user_id IN (5,6,7,8,9,10,11,12,17,18)
   AND %s_match_route='raw_c_norm'",kind,pfx))$n==10,
   dbGetQuery(con,sprintf("SELECT %s_candidate_count n FROM %s WHERE user_id=12",pfx,kind))$n==2,
   dbGetQuery(con,sprintf("SELECT count(*) n FROM %s WHERE user_id IN (6,7,8,9) AND %s_raw_segment=1",kind,pfx))$n==4)
 }
 old_match <- file.path(coh_dir,paste0(if(kind=='br') br_prefix else sh_prefix,'_matches.parquet'))
 if(file.exists(old_match) && !test_run) {
  # Matching rules are unchanged. Compare all pre-existing fields except degree level.
  dbExecute(con,sprintf("CREATE OR REPLACE VIEW previous_matches AS SELECT * FROM read_parquet('%s')",old_match))
  old_fields <- setdiff(dbGetQuery(con,'DESCRIBE previous_matches')$column_name,paste0(pfx,'_level'))
  changed_fields <- paste(sprintf('o."%1$s" IS DISTINCT FROM m."%1$s"',old_fields),collapse=' OR ')
  for(source_file in files) {
   q <- as.character(dbQuoteString(con,source_file))
   bad <- dbGetQuery(con,sprintf("SELECT count(*) n FROM (SELECT * FROM previous_matches WHERE source_file=%1$s) o
    FULL JOIN (SELECT * FROM %2$s WHERE source_file=%1$s) m USING(source_file,source_row) WHERE %3$s",q,kind,changed_fields))$n
   stopifnot(bad==0)
  }
 }
 # Independent rsid coverage uses the real pair keys from the source crosswalk.
 cw <- eng$inputs$path[grepl('crosswalk.parquet$',eng$inputs$path)][1]
 if(kind=='sh' && !test_run) cw <- eng$inputs$path[grepl('shanghai_rsid_oa_crosswalk.parquet$',eng$inputs$path)][1]
 expected <- dbGetQuery(con,sprintf("SELECT count(*) n FROM original e WHERE EXISTS(SELECT 1 FROM read_parquet('%s') p WHERE p.rsid=e.rsid AND p.rsid IS NOT NULL AND p.rsid<>2147483647)",cw))$n
 actual <- dbGetQuery(con,sprintf("SELECT count(*) n FROM %s WHERE %s_match_route='rsid'",kind,pfx))$n
 stopifnot(expected==actual)
 report[[paste0(kind,'_all_row_routes')]] <- dbGetQuery(con,sprintf("SELECT %s_match_route route,
  count(*) education_rows,count(DISTINCT user_id) users FROM %s GROUP BY 1 ORDER BY 1",pfx,kind))
 cat('Validated',kind,'original values, candidates, degree veto and rsid coverage across',length(files),'files.\n')
}

for(kind in c('br','rd','sh')) {
 pfx <- if(kind=='br') 'br_oa' else kind
 if(kind=='br') sql <- "SELECT user_id,br_oa_level lvl,br_oa_is_mba is_mba,br_oa_is_lato is_lato,
   br_oa_start_year yr,br_oa_match_route route,br_oa_candidate_ids candidate_ids,
   br_oa_candidate_ids candidate_keys,NULL::INTEGER rk,NULL::VARCHAR inst,NULL::VARCHAR inst_key,NULL::INTEGER rid
   FROM br WHERE br_oa_match=1"
 if(kind=='rd') sql <- "SELECT e.user_id,e.br_oa_level lvl,e.br_oa_is_mba is_mba,e.br_oa_is_lato is_lato,
   e.br_oa_start_year yr,e.br_oa_match_route route,r.candidate_ids,r.candidate_ids candidate_keys,
   CAST(r.best_rank AS INTEGER) rk,r.best_inst inst,r.best_key inst_key,CAST(r.best_rid AS INTEGER) rid
   FROM br e JOIN ruf_sets r USING(br_oa_ids_pipe)"
 if(kind=='sh') sql <- "SELECT user_id,sh_level lvl,sh_is_mba is_mba,sh_is_lato is_lato,sh_start_year yr,sh_match_route route,
   list_sort(list_distinct(list_transform(sh_candidates,x->x.openalex_id))) candidate_ids,
   list_sort(list_distinct(list_transform(sh_candidates,x->x.oa_key))) candidate_keys,
   CAST(sh_rank AS INTEGER) rk,sh_inst inst,sh_oa_key inst_key,NULL::INTEGER rid FROM sh WHERE sh_match=1"
 dbExecute(con,paste('CREATE OR REPLACE VIEW normalized AS',sql))
 family_work <- file.path(work_dir,kind)
 dir.create(file.path(family_work,'flags'),recursive=TRUE)
 dbExecute(con,sprintf("COPY (SELECT *,CAST(hash(user_id)%%32 AS INTEGER) bucket FROM normalized)
   TO '%s/input' (FORMAT PARQUET,PARTITION_BY(bucket),COMPRESSION ZSTD)",family_work))
 buckets <- sort(list.dirs(file.path(family_work,'input'),recursive=FALSE,full.names=TRUE))
 rank_fields <- ''
 if(kind!='br') {
  rank_fields <- sprintf(",min(rk) FILTER(WHERE lvl IN ('bachelor','master','phd')) %1$s_best_rank,
   min(rk) FILTER(WHERE lvl='bachelor') %1$s_bach_rank,min(rk) FILTER(WHERE lvl='master') %1$s_mast_rank,
   min(rk) FILTER(WHERE lvl='phd') %1$s_phd_rank,
   first(inst ORDER BY rk,inst_key,rid) FILTER(WHERE lvl='bachelor') %1$s_bach_inst,
   first(inst ORDER BY rk,inst_key,rid) FILTER(WHERE lvl='master') %1$s_mast_inst,
   first(inst ORDER BY rk,inst_key,rid) FILTER(WHERE lvl='phd') %1$s_phd_inst",pfx)
 }
 if(kind=='rd') rank_fields <- paste0(rank_fields,",
   CAST(max(CASE WHEN route='raw_c_norm' AND lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) AS INTEGER) rd_name_any,
   0::INTEGER rd_abbr_any,
   first(rid ORDER BY rk,inst_key,rid) FILTER(WHERE lvl IN ('bachelor','master','phd')) rd_best_inst_id")
 if(kind=='sh') rank_fields <- paste0(rank_fields,",
   coalesce(list_sort(list_distinct(flatten(list(candidate_keys) FILTER(WHERE lvl='bachelor')))),[]::VARCHAR[]) sh_bach_institution_keys,
   coalesce(list_sort(list_distinct(flatten(list(candidate_keys) FILTER(WHERE lvl='master')))),[]::VARCHAR[]) sh_mast_institution_keys,
   coalesce(list_sort(list_distinct(flatten(list(candidate_keys) FILTER(WHERE lvl='phd')))),[]::VARCHAR[]) sh_phd_institution_keys")
 for(i in seq_along(buckets)) dbExecute(con,sprintf("COPY (SELECT user_id,1::INTEGER %1$s_any,
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
  FROM read_parquet('%3$s/*') GROUP BY user_id
  HAVING max(CASE WHEN lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END)=1)
  TO '%4$s/flags/part_%5$02d.parquet' (FORMAT PARQUET,COMPRESSION ZSTD)",pfx,rank_fields,gsub('\\\\','/',buckets[i]),family_work,i))
 dbExecute(con,sprintf("CREATE OR REPLACE VIEW flags AS SELECT * FROM read_parquet('%s/flags/*')",family_work))
 new_schema <- dbGetQuery(con,'DESCRIBE flags')
 old_path <- file.path(coh_dir,flag_names[kind])
 cols <- new_schema$column_name
 if(file.exists(old_path)) {
  old_schema <- dbGetQuery(con,sprintf("DESCRIBE SELECT * FROM read_parquet('%s')",old_path))
  stopifnot(all(old_schema$column_name %in% cols),
   all(old_schema$column_type==new_schema$column_type[match(old_schema$column_name,cols)]))
  cols <- c(old_schema$column_name,setdiff(cols,old_schema$column_name))
 }
 flag_stage <- file.path(stage_dir,flag_names[kind])
 dbExecute(con,sprintf("COPY (SELECT %s FROM flags) TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)",paste(sprintf('"%s"',cols),collapse=','),flag_stage))
 valid <- dbGetQuery(con,sprintf("SELECT count(*) n,count(DISTINCT user_id) ids,
  count(*) FILTER(WHERE user_id IS NULL OR %1$s_any<>1 OR %1$s_bachelor+%1$s_master+%1$s_phd=0
  OR %1$s_master_strict>%1$s_master OR %1$s_rsid_any+%1$s_raw_any=0) bad FROM flags",pfx))
 stopifnot(valid$n==valid$ids,valid$bad==0)
 # Full user membership and matched-row totals, independently aggregated.
 bad <- dbGetQuery(con,sprintf("WITH expected AS (SELECT user_id,count(*) n FROM normalized GROUP BY user_id
  HAVING count(*) FILTER(WHERE lvl IN ('bachelor','master','phd'))>0)
  SELECT count(*) n FROM expected e FULL JOIN flags f USING(user_id)
  WHERE e.user_id IS NULL OR f.user_id IS NULL OR e.n<>f.%s_n_rows",pfx))$n
 stopifnot(bad==0)
 for(level in c('bachelor','master','phd')) {
  expected <- dbGetQuery(con,sprintf("SELECT count(DISTINCT user_id) n FROM normalized WHERE lvl='%s'",level))$n
  actual <- dbGetQuery(con,sprintf('SELECT sum(%s_%s) n FROM flags',pfx,level))$n
  stopifnot(expected==actual)
  short <- c(bachelor='bach',master='mast',phd='phd')[level]
  bad <- dbGetQuery(con,sprintf("WITH expected AS (SELECT user_id,min(yr) yr,min(rk) rk
   FROM normalized WHERE lvl='%1$s' GROUP BY user_id)
   SELECT count(*) n FROM expected e JOIN flags f USING(user_id)
   WHERE e.yr IS DISTINCT FROM f.%2$s_%3$s_year %4$s",level,pfx,short,
   if(kind=='br') '' else sprintf('OR e.rk IS DISTINCT FROM f.%s_%s_rank',pfx,short)))$n
  stopifnot(bad==0)
 }
 for(level in c('bach','mast','mast_strict','phd')) {
  field <- paste0(pfx,'_',level,'_institutions')
  stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM flags WHERE %1$s IS NULL OR %1$s<>list_sort(list_distinct(%1$s))",field))$n==0)
 }
 stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM flags WHERE NOT list_has_all(%1$s_mast_institutions,%1$s_mast_strict_institutions)",pfx))$n==0)
 if(kind!='br') stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM flags WHERE %1$s_best_rank IS NULL OR %1$s_best_rank>%2$d",pfx,if(kind=='rd') 10L else 901L))$n==0)
 routes <- dbGetQuery(con,"SELECT route,count(*) education_rows,count(DISTINCT user_id) users,
  count(*) FILTER(WHERE lvl IN ('bachelor','master','phd')) qualifying_rows,
  count(DISTINCT user_id) FILTER(WHERE lvl IN ('bachelor','master','phd')) qualifying_users FROM normalized GROUP BY 1 ORDER BY 1")
 institution_counts <- dbGetQuery(con,'SELECT count(*) education_rows,count(DISTINCT user_id) users FROM normalized')
 metrics <- c('any','bachelor','master','master_strict','phd','lato')
 comparisons <- vector('list',length(metrics))
 if(file.exists(old_path)) dbExecute(con,sprintf("CREATE OR REPLACE VIEW old_flags AS SELECT * FROM read_parquet('%s')",old_path))
 else dbExecute(con,'CREATE OR REPLACE VIEW old_flags AS SELECT * FROM flags WHERE FALSE')
 for(i in seq_along(metrics)) {
  field <- paste0(pfx,'_',metrics[i])
  comparisons[[i]] <- dbGetQuery(con,sprintf("SELECT '%1$s' flag,
   count(*) FILTER(WHERE o.%2$s=1) old_users,count(*) FILTER(WHERE n.%2$s=1) new_users,
   count(*) FILTER(WHERE o.%2$s=1 AND n.%2$s=1) retained,
   count(*) FILTER(WHERE coalesce(o.%2$s,0)=0 AND n.%2$s=1) gained,
   count(*) FILTER(WHERE o.%2$s=1 AND coalesce(n.%2$s,0)=0) lost
   FROM old_flags o FULL JOIN flags n USING(user_id)",metrics[i],field))
 }
 comparison <- do.call(rbind,comparisons)
 stopifnot(all(comparison$old_users==comparison$retained+comparison$lost),all(comparison$new_users==comparison$retained+comparison$gained))
 report$families[[kind]] <- list(institution_matching=institution_counts,routes=routes,flags=comparison,
  checks=list(unique_users=TRUE,original_schema_preserved=TRUE,independent_users_and_counts=TRUE,degree_invariants=TRUE,
  sorted_distinct_lists=TRUE,rank_invariants=TRUE))
 if(test_run) {
  stopifnot(dbGetQuery(con,'SELECT count(*) n FROM flags WHERE user_id IN (24,25,19,4,13,14,15,16)')$n==0,
   dbGetQuery(con,sprintf('SELECT %s_bachelor n FROM flags WHERE user_id=26',pfx))$n==1,
   is.na(dbGetQuery(con,sprintf('SELECT %s_bach_year yr FROM flags WHERE user_id=27',pfx))$yr),
   dbGetQuery(con,sprintf('SELECT %s_n_rows n FROM flags WHERE user_id=9007199254740993',pfx))$n==2,
   dbGetQuery(con,sprintf('SELECT %1$s_master-%1$s_master_strict n FROM flags WHERE user_id=20',pfx))$n==1)
  if(kind=='rd') stopifnot(dbGetQuery(con,'SELECT rd_best_inst_id n FROM flags WHERE user_id=9007199254740993')$n==2,
    dbGetQuery(con,"SELECT rd_mast_institutions=['I2'] ok FROM flags WHERE user_id=3")$ok,
    dbGetQuery(con,'SELECT sum(rd_abbr_any) n FROM flags')$n==0)
  if(kind=='sh') stopifnot(dbGetQuery(con,"SELECT sh_mast_inst='Beta University' ok FROM flags WHERE user_id=3")$ok,
    dbGetQuery(con,"SELECT sh_bach_institution_keys=['missing-id'] ok FROM flags WHERE user_id=10")$ok)
 }
 cat('Validated flags:',kind,'-',valid$n,'users.\n');print(comparison,row.names=FALSE)
}

inputs <- unique(inputs)
stopifnot(identical(unname(tools::md5sum(inputs$path)),inputs$md5),
 identical(before_md5,tools::md5sum(before_paths)),identical(protected_md5,tools::md5sum(protected)),
 identical(patterns_md5,tools::md5sum(patterns_path)))
dbDisconnect(con,shutdown=TRUE)
publish <- data.frame(staged=c(file.path(stage_dir,unname(flag_names)),file.path(stage_dir,flag_names['sh']),br_matches,sh_matches),
 target=file.path(coh_dir,c(unname(flag_names),paste0(sh_prefix,'.parquet'),paste0(c(br_prefix,sh_prefix),'_matches.parquet'))))
publish$md5 <- unname(tools::md5sum(publish$staged))
dir.create(backup_dir,recursive=TRUE)
backups <- data.frame(original=before_paths,backup=file.path(backup_dir,basename(before_paths)),md5=unname(before_md5))
for(i in seq_len(nrow(backups))) stopifnot(file.copy(backups$original[i],backups$backup[i],overwrite=FALSE),
 identical(unname(tools::md5sum(backups$backup[i])),backups$md5[i]))
write_json(backups,file.path(backup_dir,'backup_manifest.json'),dataframe='rows',auto_unbox=TRUE,pretty=TRUE)
report$inputs <- inputs
report$protected_products <- data.frame(path=protected,md5=unname(protected_md5))
report$backups <- backups
report$publication <- publish
report$checks <- list(all_original_values_and_keys_equal=TRUE,candidate_sets_unchanged=TRUE,
 independent_rsid_coverage=TRUE,high_school_veto=TRUE,all_families_validated=TRUE,
 source_checksums_unchanged=TRUE,protected_products_unchanged=TRUE,backups_verified=TRUE,fixtures_run=test_run)
# Keep backup and staging manifests before any replacement so an interrupted
# multi-file publication is recoverable; no dependent cohort processes are run.
write_json(report,file.path(stage_dir,'validated_manifest.json'),dataframe='rows',auto_unbox=TRUE,pretty=TRUE)
for(i in seq_len(nrow(publish))) stopifnot(file.copy(publish$staged[i],publish$target[i],overwrite=TRUE),
 identical(unname(tools::md5sum(publish$target[i])),publish$md5[i]))
stopifnot(identical(protected_md5,tools::md5sum(protected)))
report$checks$published_checksums_equal <- TRUE
report$completed_utc <- format(Sys.time(),tz='UTC',usetz=TRUE)
report_names <- c(paste0(c(br_prefix,sh_prefix),'_report.json'),'obmep_candidates_step_1_ruf_degree_report.json','education_flags_rebuild_report.json')
for(name in report_names) write_json(report,file.path(coh_dir,name),dataframe='rows',auto_unbox=TRUE,pretty=TRUE,digits=15)
unlink(unique(publish$staged))
cat('Published all education flags. Backups:',backup_dir,'\n')
if(!test_run && Sys.getenv('OBMEP_SKIP_RANKED_REDEFINITION')!='1') {
 cat('Applying the current parent-adjusted RUF and Shanghai definitions...\n')
 source('prep/building_external_data/redefine_ranked_education_flags.R')
}
