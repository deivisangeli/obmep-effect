# Read-only post-publication verification for the parent-adjusted ranked flags.
library(DBI)
library(duckdb)
library(jsonlite)
root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh <- file.path(root,'Data/intermediate/revelio_br_cohort')
global_dir <- file.path(coh,'global_oa_hierarchy')
report_path <- file.path(coh,'ranked_education_flags_redefinition_report.json')
report <- read_json(report_path,simplifyVector=TRUE)
run_id <- report$run_id
stage_dir <- file.path(coh,'.ranked_flags_staging',run_id)
backup_dir <- file.path(coh,'ranked_flags_backups',run_id)
paths <- c(rd=file.path(coh,'obmep_candidates_step_1_ruf_degree.parquet'),
 sh=file.path(coh,'obmep_candidates_step_1_shanghai.parquet'),
 sh_alias=file.path(coh,'obmep_candidates_step_1_shanghai_rsid_nofloor.parquet'))
stopifnot(all(file.exists(c(paths,report_path))),dir.exists(stage_dir),dir.exists(backup_dir))
con <- dbConnect(duckdb(),dbdir=':memory:')
on.exit(dbDisconnect(con,shutdown=TRUE),add=TRUE)
dbExecute(con,"SET memory_limit='8GB'")
dbExecute(con,'SET threads=4')
entry_dir <- gsub('\\\\','/',file.path(stage_dir,'ranked_entries'))
catalog_path <- gsub('\\\\','/',file.path(global_dir,'global_oa_ranked_parent_catalog.parquet'))

stopifnot(identical(unname(tools::md5sum(paths['sh'])),unname(tools::md5sum(paths['sh_alias']))),
 identical(unname(tools::md5sum(report$outputs$path)),report$outputs$md5))
for(nm in basename(c(paths,file.path(coh,'obmep_candidates_step_1_ruf_degree_report.json'),
 file.path(coh,'obmep_candidates_step_1_shanghai_rsid_nofloor_report.json')))) {
 stopifnot(file.exists(file.path(backup_dir,nm)))
}

dbExecute(con,sprintf("CREATE VIEW entries AS SELECT * FROM read_parquet('%s/*/*/*.parquet',hive_partitioning=true)",entry_dir))
dbExecute(con,sprintf("CREATE VIEW catalog AS SELECT * FROM read_parquet('%s')",catalog_path))
results <- list()
for(kind in c('rd','sh')) {
 pfx <- kind; path <- gsub('\\\\','/',paths[kind])
 dbExecute(con,sprintf("CREATE OR REPLACE VIEW flags AS SELECT * FROM read_parquet('%s')",path))
 counts <- dbGetQuery(con,sprintf("SELECT count(*) users,count(DISTINCT user_id) distinct_users,
  sum(%1$s_bachelor) bachelor,sum(%1$s_master) master,sum(%1$s_master_strict) master_strict,
  sum(%1$s_phd) phd,sum(%1$s_lato) lato FROM flags",pfx))
 report_cmp <- if(kind=='rd') report$comparisons$ruf else report$comparisons$shanghai
 stopifnot(counts$users==counts$distinct_users,
  counts$users==report_cmp$new_users[report_cmp$flag=='any'],
  counts$bachelor==report_cmp$new_users[report_cmp$flag=='bachelor'],
  counts$master==report_cmp$new_users[report_cmp$flag=='master'],
  counts$master_strict==report_cmp$new_users[report_cmp$flag=='master_strict'],
  counts$phd==report_cmp$new_users[report_cmp$flag=='phd'],
  counts$lato==report_cmp$new_users[report_cmp$flag=='lato'])
 stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM flags WHERE
  %1$s_any<>1 OR %1$s_master_strict>%1$s_master OR %1$s_bachelor+%1$s_master+%1$s_phd=0
  OR %1$s_rsid_any+%1$s_raw_any=0",pfx))$n==0)
 for(level in c('bachelor','master','phd')) {
  short <- c(bachelor='bach',master='mast',phd='phd')[level]
  stopifnot(dbGetQuery(con,sprintf("WITH x AS (SELECT user_id,min(yr) yr,min(rk) rk,
   first(inst ORDER BY rk,inst_key,rid NULLS LAST) inst,
   list_sort(list_distinct(flatten(list(source_ids)))) ids
   FROM entries WHERE family='%1$s' AND lvl='%2$s' GROUP BY user_id)
   SELECT count(*) n FROM flags f FULL JOIN x USING(user_id)
   WHERE (coalesce(f.%1$s_%2$s,0)=1) IS DISTINCT FROM (x.user_id IS NOT NULL)
    OR (x.user_id IS NOT NULL AND (f.%1$s_%3$s_year IS DISTINCT FROM x.yr
    OR f.%1$s_%3$s_rank IS DISTINCT FROM x.rk OR f.%1$s_%3$s_inst IS DISTINCT FROM x.inst
    OR f.%1$s_%3$s_institutions IS DISTINCT FROM x.ids))",kind,level,short))$n==0)
 }
 stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM flags f CROSS JOIN
  unnest(list_concat(f.%1$s_bach_institutions,f.%1$s_mast_institutions,f.%1$s_phd_institutions)) u(oa_id)
  LEFT JOIN catalog c ON c.family='%1$s' AND c.oa_id=u.oa_id WHERE c.oa_id IS NULL",kind))$n==0)
 if(kind=='rd') stopifnot(dbGetQuery(con,"WITH x AS (SELECT user_id,
  first(rid ORDER BY rk,inst_key,rid) FILTER(WHERE lvl IN ('bachelor','master','phd')) rid
  FROM entries WHERE family='rd' GROUP BY user_id)
  SELECT count(*) n FROM flags f JOIN x USING(user_id) WHERE f.rd_best_inst_id IS DISTINCT FROM x.rid")$n==0,
  dbGetQuery(con,"SELECT count(*) n FROM flags WHERE rd_abbr_any<>0 OR rd_name_any<>rd_raw_any")$n==0)
 if(kind=='sh') stopifnot(dbGetQuery(con,"SELECT count(*) n FROM flags WHERE
  sh_bach_institution_keys IS DISTINCT FROM sh_bach_institutions
  OR sh_mast_institution_keys IS DISTINCT FROM sh_mast_institutions
  OR sh_phd_institution_keys IS DISTINCT FROM sh_phd_institutions")$n==0)
 results[[kind]] <- counts
}

input_now <- unname(tools::md5sum(report$inputs$path))
stopifnot(identical(input_now,report$inputs$md5))
verification <- list(run_id=run_id,verified_at=format(Sys.time(),tz='America/Sao_Paulo',usetz=TRUE),
 counts=results,checks=list(published_checksums=TRUE,shanghai_alias_identical=TRUE,
 backups_present=TRUE,input_checksums=TRUE,unique_users=TRUE,degree_totals=TRUE,
 years_ranks_names_and_lists=TRUE,catalog_membership=TRUE,route_compatibility=TRUE))
write_json(verification,file.path(coh,'ranked_education_flags_redefinition_verification.json'),auto_unbox=TRUE,pretty=TRUE)
print(verification)
