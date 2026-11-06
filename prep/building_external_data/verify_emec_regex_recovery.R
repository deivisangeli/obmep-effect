# Independent, read-only verification of the versioned degree-duration e-MEC
# regex recovery. This is a LOCAL/offline check and must not be sent to SEDAP.
library(DBI)
library(duckdb)
library(jsonlite)

root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh <- file.path(root,'Data/intermediate/revelio_br_cohort')
base <- Sys.getenv('OBMEP_EMEC_DURATION_BASE',file.path(coh,'emec_hierarchy'))
out <- Sys.getenv('OBMEP_EMEC_DURATION_OUT',file.path(coh,'emec_hierarchy_regex_v1'))
report_path <- file.path(out,'degree_duration_emec_regex_recovery_report.json')
verification_path <- file.path(out,'degree_duration_emec_regex_recovery_verification.json')
registry_path <- 'prep/building_external_data/degree_duration_emec_regex_aliases.csv'
script_path <- 'prep/building_external_data/degree_duration_emec_regex_recovery.R'

base_parts <- sort(list.files(file.path(base,'education_parts'),pattern='[.]parquet$',full.names=TRUE))
output_parts <- sort(list.files(file.path(out,'education_parts'),pattern='[.]parquet$',full.names=TRUE))
decision_parts <- sort(list.files(file.path(out,'decisions'),pattern='[.]parquet$',full.names=TRUE))
catalog_path <- file.path(base,'catalog.parquet')
resolved_path <- file.path(out,'regex_alias_registry_resolved.parquet')
decisions_path <- file.path(out,'regex_decisions.parquet')
proposals_path <- file.path(out,'regex_proposals.parquet')
crosswalk_path <- file.path(out,'degree_duration_emec_crosswalk.parquet')
stopifnot(file.exists(report_path),file.exists(registry_path),file.exists(script_path),
 length(base_parts)==30L,length(output_parts)==30L,length(decision_parts)==64L,
 identical(basename(base_parts),basename(output_parts)),
 all(file.exists(c(catalog_path,resolved_path,decisions_path,proposals_path,crosswalk_path))))

report <- read_json(report_path,simplifyVector=TRUE)
stopifnot(identical(unname(tools::md5sum(report$inputs$path)),report$inputs$md5),
 identical(unname(tools::md5sum(report$outputs$path)),report$outputs$md5))
implementation <- data.frame(path=c(script_path,registry_path),
 md5=unname(tools::md5sum(c(script_path,registry_path))))
stopifnot(identical(readRDS(file.path(out,'implementation_manifest.rds')),implementation),
 identical(readRDS(file.path(out,'input_manifest.rds')),report$inputs),
 identical(readRDS(file.path(out,'checkpoints','01_recovery.rds')),
  tools::md5sum(c(resolved_path,proposals_path,decisions_path,crosswalk_path))))

con <- dbConnect(duckdb(),dbdir=':memory:')
on.exit(try(dbDisconnect(con,shutdown=TRUE),silent=TRUE),add=TRUE)
dbExecute(con,"SET memory_limit='8GB'")
dbExecute(con,'SET threads=4')
base_glob <- gsub('\\\\','/',file.path(base,'education_parts','*.parquet'))
output_glob <- gsub('\\\\','/',file.path(out,'education_parts','*.parquet'))
catalog_sql <- gsub('\\\\','/',catalog_path)
resolved_sql <- gsub('\\\\','/',resolved_path)
decisions_sql <- gsub('\\\\','/',decisions_path)
proposals_sql <- gsub('\\\\','/',proposals_path)
crosswalk_sql <- gsub('\\\\','/',crosswalk_path)
dbExecute(con,sprintf("CREATE VIEW base_enriched AS SELECT * FROM read_parquet('%s')",base_glob))
dbExecute(con,sprintf("CREATE VIEW enriched AS SELECT * FROM read_parquet('%s')",output_glob))
dbExecute(con,sprintf("CREATE VIEW catalog AS SELECT * FROM read_parquet('%s')",catalog_sql))
dbExecute(con,sprintf("CREATE VIEW registry_resolved AS SELECT * FROM read_parquet('%s')",resolved_sql))
dbExecute(con,sprintf("CREATE VIEW decisions AS SELECT * FROM read_parquet('%s')",decisions_sql))
dbExecute(con,sprintf("CREATE VIEW proposals AS SELECT * FROM read_parquet('%s')",proposals_sql))
dbExecute(con,sprintf("CREATE VIEW crosswalk AS SELECT * FROM read_parquet('%s')",crosswalk_sql))

# Every upstream, non-eMEC value is preserved by the physical source key.
derived <- c('CO_IES','emec_decision_id','emec_candidate_codes','emec_candidates',
 'emec_selected_codes','emec_selected_names','emec_selected_count','emec_selection_stage',
 'emec_selection_status','emec_selected_evidence')
for(i in seq_along(base_parts)) {
 src <- gsub('\\\\','/',base_parts[i]); dest <- gsub('\\\\','/',output_parts[i])
 dbExecute(con,sprintf("CREATE OR REPLACE TEMP VIEW source_part AS SELECT * FROM read_parquet('%s')",src))
 cols <- setdiff(dbGetQuery(con,'DESCRIBE source_part')$column_name,derived)
 mismatch <- paste(sprintf('b."%1$s" IS DISTINCT FROM e."%1$s"',cols),collapse=' OR ')
 n_bad <- dbGetQuery(con,sprintf("SELECT count(*) n FROM source_part b
  FULL JOIN read_parquet('%s') e USING(source_file,source_row)
  WHERE b.source_file IS NULL OR e.source_file IS NULL OR %s",dest,mismatch))$n
 stopifnot(n_bad==0L)
 cat('Verified source preservation:',i,'of',length(base_parts),'\n')
}

population <- dbGetQuery(con,"SELECT count(*) education_rows,count(DISTINCT user_id) users,
 count(DISTINCT (source_file,source_row)) physical_keys,
 count(*) FILTER(WHERE CO_IES IS NOT NULL) matched_rows,
 count(DISTINCT user_id) FILTER(WHERE CO_IES IS NOT NULL) matched_users,
 count(*) FILTER(WHERE coalesce(emec_regex_selected,false)) regex_rows,
 count(DISTINCT user_id) FILTER(WHERE coalesce(emec_regex_selected,false)) regex_users
 FROM enriched")
base_population <- dbGetQuery(con,"SELECT count(*) education_rows,count(DISTINCT user_id) users,
 count(DISTINCT (source_file,source_row)) physical_keys,
 count(*) FILTER(WHERE CO_IES IS NOT NULL) matched_rows FROM base_enriched")
stopifnot(population$education_rows==base_population$education_rows,
 population$users==base_population$users,
 population$physical_keys==population$education_rows,
 population$education_rows==19710307L,population$users==8901904L)

checks <- list(
 base_scalar_matches_changed=dbGetQuery(con,"SELECT count(*) n FROM base_enriched b
  JOIN enriched e USING(source_file,source_row) WHERE b.CO_IES IS NOT NULL AND
  (e.CO_IES IS DISTINCT FROM b.CO_IES OR coalesce(e.emec_regex_selected,false))")$n,
 scalar_count_inconsistent=dbGetQuery(con,"SELECT count(*) n FROM enriched WHERE
  (CO_IES IS NOT NULL) IS DISTINCT FROM (emec_selected_count=1) OR
  (emec_selected_count=1 AND CO_IES<>emec_selected_codes[1])")$n,
 selected_outside_candidates=dbGetQuery(con,"SELECT count(*) n FROM decisions WHERE
  selected_count>0 AND NOT list_has_all(candidate_codes,selected_codes)")$n,
 inactive_regex_targets=dbGetQuery(con,"SELECT count(*) n FROM decisions d JOIN catalog c
  ON c.CO_IES=d.regex_target_code WHERE coalesce(d.regex_selected,false) AND
  c.situacao_ies NOT IN ('Ativa','Em atividade')")$n,
 missing_regex_targets=dbGetQuery(con,"SELECT count(*) n FROM decisions d LEFT JOIN catalog c
  ON c.CO_IES=d.regex_target_code WHERE coalesce(d.regex_selected,false) AND c.CO_IES IS NULL")$n,
 explicit_foreign_recovered=dbGetQuery(con,"SELECT count(*) n FROM decisions WHERE
  coalesce(regex_selected,false) AND NOT recovery_country_ok")$n,
 top_priority_conflicts_selected=dbGetQuery(con,"SELECT count(*) n FROM decisions WHERE
  regex_conflict AND (coalesce(regex_selected,false) OR selected_count<>pre_regex_selected_count OR
  selected_codes IS DISTINCT FROM pre_regex_selected_codes)")$n,
 regex_without_single_top_target=dbGetQuery(con,"WITH w AS (SELECT decision_id,min(priority) p
  FROM proposals GROUP BY 1),t AS (SELECT p.decision_id,count(DISTINCT target_code) n
  FROM proposals p JOIN w ON w.decision_id=p.decision_id AND w.p=p.priority GROUP BY 1)
  SELECT count(*) n FROM decisions d LEFT JOIN t USING(decision_id) WHERE
  coalesce(d.regex_selected,false) IS DISTINCT FROM (coalesce(t.n,0)=1)")$n)
stopifnot(all(unlist(checks)==0L))

registry <- read.csv(registry_path,stringsAsFactors=FALSE,check.names=FALSE)
registry_check <- dbGetQuery(con,"SELECT count(*) rules,count(DISTINCT rule_id) rule_ids,
 count(*) FILTER(WHERE target_code IS NULL) unresolved,
 count(*) FILTER(WHERE c.situacao_ies NOT IN ('Ativa','Em atividade')) inactive
 FROM registry_resolved r LEFT JOIN catalog c ON c.CO_IES=r.target_code")
stopifnot(nrow(registry)==10L,registry_check$rules==10L,registry_check$rule_ids==10L,
 registry_check$unresolved==0L,registry_check$inactive==0L,
 !any(grepl('CO_IES|target_code',names(registry),ignore.case=TRUE)))

acceptance_path <- file.path(root,'test/degree_duration_emec_regex_recovery/test_report.json')
stopifnot(file.exists(acceptance_path))
acceptance <- read_json(acceptance_path,simplifyVector=TRUE)
stopifnot(isTRUE(acceptance$passed),acceptance$reviewed_rows==100L,
 acceptance$intended_matches==57L,acceptance$rejected_unmatched==43L)

verification <- list(completed_utc=format(Sys.time(),tz='UTC',usetz=TRUE),
 population=population,base_population=base_population,zero_count_checks=checks,
 registry=registry_check,acceptance=acceptance,
 verified=list(latest_degree_duration_population=TRUE,all_30_partitions_preserved=TRUE,
  base_scalar_matches_immutable=TRUE,scalar_code_iff_unique=TRUE,
  selected_codes_subset_augmented_candidates=TRUE,regex_targets_active=TRUE,
  explicit_foreign_excluded=TRUE,top_priority_conflicts_unresolved=TRUE,
  registry_targets_dynamic_unique_active=TRUE,report_checksums_current=TRUE))
write_json(verification,verification_path,pretty=TRUE,auto_unbox=TRUE,
 dataframe='rows',digits=16,na='null')
print(verification)
dbDisconnect(con,shutdown=TRUE)
cat('Independent degree-duration e-MEC regex recovery verification passed.\n')
