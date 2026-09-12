# Full-data reconciliation and checksummed report, sourced by the driver.
cat('Reconciling global crosswalk, education, decisions and comparison flags.\n')
report <- list(completed_utc=format(Sys.time(),tz='UTC',usetz=TRUE),
 method=list(population='Only the 15,712,737 local education rows; not the worldwide Revelio population',
  upstream='Primary and cleaned names only; C recorded; expanded C_norm whole/segments; all types; no gates',
  normalization='trim, lowercase, accent stripping; segments / ( ) | and spaced hyphen; at least 3 characters',
  hierarchy='First successful exact, contained-name, supplied anchored-acronym, country/Jaro-Winkler stage; all ties retained',
  jw='Jaro plus p=0.1 times prefix length (at most 4) times (1-Jaro), only when Jaro>0.7',
  jaro_implementation='DuckDB jaro_similarity for ASCII; stringdist stringsim(method=jw,p=0,useBytes=FALSE) for non-ASCII',
  duckdb_version=dbGetQuery(con,'SELECT version()')[[1]],stringdist_version=as.character(packageVersion('stringdist')),
  countrycode_version=as.character(packageVersion('countrycode')),tie_tolerance=1e-12,
  acronym_only_alternatives='Excluded from name pool; supplied acronyms available only at stage III',
  degrees='Unchanged production cascade, MBA, strict-master nullable MBA predicate, lato, enrollment, and raw high-school veto',
  interpretation='Coverage and selection behavior, not measured assignment accuracy'),inputs=inputs,
 validation=list(),comparisons=list())
report$catalog <- dbGetQuery(con,'SELECT count(*) institutions,count(*) FILTER(WHERE country_code IS NULL) missing_country FROM catalog')
report$crosswalk <- dbGetQuery(con,"SELECT count(*) pairs,count(DISTINCT rsid) rsids,count(DISTINCT oa_id) institutions,
 sum(supporting_rows) supporting_row_pair_observations FROM crosswalk")
report$crosswalk_evidence <- dbGetQuery(con,'SELECT count(*) evidence_records,count(DISTINCT university_raw) raw_names FROM crosswalk_evidence')
report$crosswalk_multiplicity <- dbGetQuery(con,"WITH n AS (
 SELECT 'OA IDs per rsid' direction,count(*) n FROM crosswalk GROUP BY rsid UNION ALL
 SELECT 'rsids per OA ID',count(*) FROM crosswalk GROUP BY oa_id)
 SELECT direction,count(*) group_count,min(n) minimum,median(n) median,avg(n) mean,max(n) maximum,
 count(*) FILTER(WHERE n>1) multiple FROM n GROUP BY direction")
report$education <- dbGetQuery(con,"SELECT count(*) education_rows,count(DISTINCT user_id) users,
 count(*) FILTER(WHERE len(global_oa_candidate_ids)>0) preselection_matched_rows,
 count(DISTINCT user_id) FILTER(WHERE len(global_oa_candidate_ids)>0) preselection_matched_users,
 count(*) FILTER(WHERE global_oa_selected_count>0) selected_rows,
 count(DISTINCT user_id) FILTER(WHERE global_oa_selected_count>0) selected_users FROM enriched")
stopifnot(report$education$education_rows==15712737)
report$routes <- dbGetQuery(con,"SELECT global_oa_match_route route,count(*) education_rows,count(DISTINCT user_id) users
 FROM enriched GROUP BY 1 ORDER BY 1")
report$stages <- dbGetQuery(con,"SELECT global_oa_selection_stage stage,global_oa_selection_status status,
 count(*) education_rows,count(DISTINCT global_oa_decision_id) decisions,count(DISTINCT user_id) users
 FROM enriched GROUP BY 1,2 ORDER BY 1,2")
report$decision_population <- dbGetQuery(con,'SELECT count(*) decisions,count(DISTINCT decision_id) unique_ids FROM decisions')
stopifnot(report$decision_population$decisions==report$decision_population$unique_ids)
report$candidate_counts <- dbGetQuery(con,"SELECT 'before' step,min(len(global_oa_candidate_ids)) minimum,
 median(len(global_oa_candidate_ids)) median,avg(len(global_oa_candidate_ids)) mean,max(len(global_oa_candidate_ids)) maximum
 FROM enriched WHERE len(global_oa_candidate_ids)>0 UNION ALL SELECT 'after',min(global_oa_selected_count),
 median(global_oa_selected_count),avg(global_oa_selected_count),max(global_oa_selected_count)
 FROM enriched WHERE global_oa_selected_count>0")
dbExecute(con,"CREATE OR REPLACE TEMP TABLE decision_scores AS SELECT decision_id,
 max(v.score) score,max(v.jw_similarity) jw_similarity,max(v.country_match) country_match
 FROM decisions CROSS JOIN unnest(selected_evidence) u(v) WHERE selection_stage=4 GROUP BY decision_id")
report$stage_iv_scores <- dbGetQuery(con,"SELECT count(*) education_rows,min(score) minimum,
 quantile_cont(score,[0.01,0.05,0.25,0.5,0.75,0.95,0.99]) quantiles,avg(score) mean,max(score) maximum,
 count(*) FILTER(WHERE score<0.5) below_0_5,count(*) FILTER(WHERE score<0.7) below_0_7,
 count(*) FILTER(WHERE country_match=1) country_match_rows
 FROM enriched e JOIN decision_scores s ON e.global_oa_decision_id=s.decision_id")
report$unrecognized_countries <- dbGetQuery(con,"SELECT e.university_country,count(*) education_rows
 FROM education e LEFT JOIN country_mapping m ON e.university_country=m.value
 WHERE m.country_code IS NULL GROUP BY 1 ORDER BY 2 DESC")
report$catalog_membership <- dbGetQuery(con,'SELECT family,count(*) institutions FROM family_catalog GROUP BY 1 ORDER BY 1')
report$shanghai_catalog_omissions <- dbGetQuery(con,sprintf("SELECT oa_key,shanghai_name,shanghai_rank
 FROM read_parquet('%s') WHERE shanghai_rank<=901 AND NOT EXISTS(SELECT 1 FROM catalog c WHERE c.oa_id=oa_key)",sh_path))

stopifnot(dbGetQuery(con,"SELECT count(*) n FROM enriched WHERE
 (global_oa_selected_count>0 AND (global_oa_selected_ids<>list_sort(list_distinct(global_oa_selected_ids))
 OR NOT list_has_all(global_oa_candidate_ids,global_oa_selected_ids)
 OR str_split(global_oa_selected_ids_pipe,'|') IS DISTINCT FROM global_oa_selected_ids))
 OR (len(global_oa_candidate_ids)>0 AND (global_oa_candidate_ids<>list_sort(list_distinct(global_oa_candidate_ids))
 OR str_split(global_oa_candidate_ids_pipe,'|') IS DISTINCT FROM global_oa_candidate_ids
 OR list_transform(global_oa_candidates,x->x.oa_id) IS DISTINCT FROM global_oa_candidate_ids))
 OR (global_oa_selected_count>0 AND
  list_transform(global_oa_selected_evidence,x->x.oa_id) IS DISTINCT FROM global_oa_selected_ids)
 OR (global_oa_selection_status='unresolved_blank_raw' AND global_oa_selected_count<>0)")$n==0)
expected_rsid <- dbGetQuery(con,"SELECT count(*) n FROM education e WHERE e.rsid IS NOT NULL AND e.rsid<>2147483647
 AND EXISTS(SELECT 1 FROM crosswalk x WHERE x.rsid=e.rsid)")$n
stopifnot(expected_rsid==sum(report$routes$education_rows[report$routes$route=='rsid']))
expected_fallback <- dbGetQuery(con,"SELECT count(*) n FROM education e WHERE (e.rsid IS NULL OR e.rsid=2147483647)
 AND EXISTS(SELECT 1 FROM raw_names r JOIN raw_links l USING(raw_id) WHERE r.university_raw=e.university_raw)")$n
stopifnot(expected_fallback==sum(report$routes$education_rows[report$routes$route=='raw_c_norm']))
dbExecute(con,sprintf("CREATE OR REPLACE VIEW all_evaluations AS SELECT * FROM read_parquet('%s/candidate_evaluations/*.parquet')",out))
# Independently derive the entire winning ID set from stored candidate assessments.
stopifnot(dbGetQuery(con,"WITH minima AS (SELECT decision_id,min(candidate_stage) stage,max(score) score
 FROM all_evaluations GROUP BY 1),expected AS (
 SELECT e.decision_id,list(e.oa_id ORDER BY e.oa_id) ids FROM all_evaluations e JOIN minima m USING(decision_id)
 WHERE (m.stage IS NOT NULL AND e.candidate_stage=m.stage)
  OR (m.stage IS NULL AND abs(e.score-m.score)<=1e-12) GROUP BY e.decision_id)
 SELECT count(*) n FROM decisions d LEFT JOIN expected e USING(decision_id)
 WHERE d.selected_ids IS DISTINCT FROM e.ids")$n==0)
files <- dbGetQuery(con,'SELECT DISTINCT source_file FROM education ORDER BY 1')$source_file
for(i in seq_along(files)) {
 qfile <- as.character(dbQuoteString(con,files[i]))
 dbExecute(con,sprintf("CREATE OR REPLACE TEMP VIEW physical_original AS SELECT * EXCLUDE(file_row_number),
  file_row_number source_row FROM read_parquet(%s,file_row_number=true)",qfile))
 cols <- dbGetQuery(con,'DESCRIBE physical_original')$column_name
 mismatch <- paste(sprintf('e."%1$s" IS DISTINCT FROM n."%1$s"',cols),collapse=' OR ')
 stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM physical_original e FULL JOIN
  (SELECT * FROM enriched WHERE source_file=%s) n USING(source_row) WHERE %s",qfile,mismatch))$n==0)
 k <- dbGetQuery(con,sprintf('SELECT count(*) n,count(DISTINCT source_row) keys FROM enriched WHERE source_file=%s',qfile))
 stopifnot(k$n==k$keys)
}
# Reapply the exact production degree expression once per distinct degree input.
dbExecute(con,"CREATE OR REPLACE TEMP TABLE degree_inputs AS SELECT DISTINCT degree_raw,degree,
 br_oa_level,br_oa_is_mba,br_oa_is_lato FROM enriched")
stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM (
 SELECT *,lower(trim(coalesce(degree_raw,''))) dr FROM degree_inputs)
 WHERE br_oa_level IS DISTINCT FROM (CASE WHEN regexp_like(dr,'%s') THEN 'other' ELSE (%s) END)
 OR br_oa_is_mba IS DISTINCT FROM (degree='MBA' OR regexp_like(dr,'%s'))
 OR br_oa_is_lato IS DISTINCT FROM regexp_like(dr,'%s')",rx_hs,sql_shanghai_level,rx_mba,rx_lato))$n==0)
report$validation$physical_rows_keys_and_original_values <- TRUE
report$validation$degree_rules_unchanged <- TRUE
report$validation$candidates_pipes_selected_subset_first_stage <- TRUE
report$validation$independent_exists_coverage <- TRUE
# Recompute a previously completed partition after checkpoint restoration,
# including the partitions produced before the equivalent substring prefilter.
dbExecute(con,'CREATE OR REPLACE TEMP VIEW decision_batch AS SELECT * FROM decisions_input WHERE decision_id%64=0')
unicode_scores <- dbGetQuery(con,hierarchy_unicode_pairs_sql)
unicode_scores$jaro <- stringdist::stringsim(unicode_scores$raw_norm,unicode_scores$alias_norm,method='jw',p=0,useBytes=FALSE)
dbWriteTable(con,'unicode_scores',unicode_scores,overwrite=TRUE,temporary=TRUE)
dbExecute(con,paste('CREATE OR REPLACE TEMP TABLE evaluations AS',hierarchy_evaluation_sql))
dbExecute(con,paste('CREATE OR REPLACE TEMP TABLE replayed AS',hierarchy_decision_sql))
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM (
 (SELECT * FROM replayed EXCEPT ALL SELECT * FROM decisions WHERE decision_id%64=0)
 UNION ALL (SELECT * FROM decisions WHERE decision_id%64=0 EXCEPT ALL SELECT * FROM replayed))")$n==0)
report$validation$resumed_partition_reproduces_identical_decisions <- TRUE

# Verify ranked selections directly against the institution catalogs and user
# lists, independently of the row-level rank reductions used during aggregation.
for(variant in c('pre','post')) for(kind in c('rd','sh')) {
 parts <- list.files(file.path(out,paste0('aggregation_',variant,'_',kind),'flags'),pattern='[.]parquet$',full.names=TRUE)
 for(part in parts) {
  dbExecute(con,sprintf("CREATE OR REPLACE TEMP VIEW ranked_flags AS SELECT * FROM read_parquet('%s')",part))
  stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM ranked_flags WHERE
   %1$s_best_rank IS DISTINCT FROM least(%1$s_bach_rank,%1$s_mast_rank,%1$s_phd_rank)",kind))$n==0)
  for(level in c('bach','mast','phd')) {
   dbExecute(con,sprintf("CREATE OR REPLACE TEMP TABLE ranked_expected AS SELECT f.user_id,c.rk,c.inst,c.rid
    FROM ranked_flags f CROSS JOIN unnest(f.%s_%s_institutions) u(oa_id)
    JOIN family_catalog c ON c.oa_id=u.oa_id AND c.family='%s'
    QUALIFY row_number() OVER(PARTITION BY f.user_id ORDER BY c.rk,c.oa_id,c.rid)=1",kind,level,kind))
   stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM ranked_flags f LEFT JOIN ranked_expected x USING(user_id)
    WHERE f.%1$s_%2$s_rank IS DISTINCT FROM x.rk OR f.%1$s_%2$s_inst IS DISTINCT FROM x.inst",kind,level))$n==0)
   if(kind=='sh') stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM ranked_flags WHERE
    sh_%1$s_institution_keys IS DISTINCT FROM sh_%1$s_institutions",level))$n==0)
  }
  if(kind=='rd') stopifnot(dbGetQuery(con,"WITH expected AS (
   SELECT f.user_id,c.rid FROM ranked_flags f CROSS JOIN unnest(list_distinct(list_concat(
    f.rd_bach_institutions,f.rd_mast_institutions,f.rd_phd_institutions))) u(oa_id)
   JOIN family_catalog c ON c.oa_id=u.oa_id AND c.family='rd'
   QUALIFY row_number() OVER(PARTITION BY f.user_id ORDER BY c.rk,c.oa_id,c.rid)=1)
   SELECT count(*) n FROM ranked_flags f JOIN expected x USING(user_id)
   WHERE f.rd_best_inst_id IS DISTINCT FROM x.rid OR f.rd_abbr_any<>0 OR f.rd_name_any<>f.rd_raw_any")$n==0)
 }
}
report$validation$ranked_best_fields_checked_directly_against_catalog <- TRUE

old_paths <- c(br=file.path(coh,'obmep_candidates_step_1_br_openalex_rsid_nofloor.parquet'),
 rd=file.path(coh,'obmep_candidates_step_1_ruf_degree.parquet'),sh=file.path(coh,'obmep_candidates_step_1_shanghai.parquet'))
for(kind in c('br','rd','sh')) {
 pfx <- if(kind=='br') 'br_oa' else kind
 report$comparisons[[kind]] <- list()
 for(pair in list(c('old','pre'),c('pre','post'),c('old','post'))) {
  for(j in 1:2) {
   path <- if(pair[j]=='old') old_paths[kind] else file.path(out,paste0('global_oa_',pair[j],'_',kind,'_flags.parquet'))
   dbExecute(con,sprintf("CREATE OR REPLACE TEMP VIEW cmp_%d AS SELECT * FROM read_parquet('%s')",j,path))
  }
  metrics <- c('any','bachelor','master','master_strict','phd','lato')
  expressions <- character()
  for(metric in metrics) {
   field <- paste0(pfx,'_',metric)
   expressions <- c(expressions,sprintf("count(*) FILTER(WHERE a.%1$s=1) %2$s_old,
    count(*) FILTER(WHERE b.%1$s=1) %2$s_new,
    count(*) FILTER(WHERE a.%1$s=1 AND b.%1$s=1) %2$s_retained,
    count(*) FILTER(WHERE coalesce(a.%1$s,0)=0 AND b.%1$s=1) %2$s_gained,
    count(*) FILTER(WHERE a.%1$s=1 AND coalesce(b.%1$s,0)=0) %2$s_lost",field,metric))
  }
  counts <- dbGetQuery(con,paste('SELECT',paste(expressions,collapse=','),'FROM cmp_1 a FULL JOIN cmp_2 b USING(user_id)'))
  comp <- data.frame(flag=metrics,old=0,new=0,retained=0,gained=0,lost=0)
  for(metric in metrics) for(stat in names(comp)[-1]) comp[comp$flag==metric,stat] <- as.numeric(counts[[paste0(metric,'_',stat)]])
  stopifnot(all(comp$old==comp$retained+comp$lost),all(comp$new==comp$retained+comp$gained))
  report$comparisons[[kind]][[paste(pair,collapse='_to_')]] <- comp
 }
 # Institution membership is measured across all rows, independently of degrees.
 report$comparisons[[kind]]$institution_coverage <- list()
 for(variant in c('pre','post')) {
  ids <- if(variant=='pre') 'global_oa_candidate_ids' else 'global_oa_selected_ids'
  report$comparisons[[kind]]$institution_coverage[[variant]] <- dbGetQuery(con,sprintf("SELECT count(*) education_rows,
   count(DISTINCT user_id) users FROM enriched e WHERE EXISTS(SELECT 1 FROM family_catalog c
   WHERE c.family='%s' AND list_contains(e.%s,c.oa_id))",kind,ids))
 }
}
report$validation$comparison_flags_independently_reconciled <- TRUE
report$fixtures <- read_json(file.path(root,'test/global_oa_hierarchy/test_report.json'),simplifyVector=TRUE)
stopifnot(isTRUE(report$fixtures$passed))
cat('Final input, production and previous-audit preservation checksums.\n')
stopifnot(identical(inputs$md5,unname(tools::md5sum(inputs$path))),
 identical(protected$md5,unname(tools::md5sum(protected$path))))
report$protected <- protected
report$validation$inputs_production_and_audits_unchanged <- TRUE
output_paths <- c(list.files(out,pattern='[.]parquet$',full.names=TRUE),
 list.files(file.path(out,'education_parts'),pattern='[.]parquet$',full.names=TRUE),
 list.files(file.path(out,'decisions'),pattern='[.]parquet$',full.names=TRUE),
 list.files(file.path(out,'candidate_evaluations'),pattern='[.]parquet$',full.names=TRUE))
report$outputs <- data.frame(path=output_paths,md5=unname(tools::md5sum(output_paths)))
script_paths <- list.files('prep/building_external_data',pattern='^global_oa_.*[.]R$',full.names=TRUE)
script_paths <- c(script_paths,'prep/building_external_data/br_degree_patterns.R')
report$implementation <- data.frame(path=script_paths,md5=unname(tools::md5sum(script_paths)))
saveRDS(report$implementation,file.path(out,'implementation_manifest.rds'))
report$completed_utc <- format(Sys.time(),tz='UTC',usetz=TRUE)
write_json(report,file.path(out,'global_oa_hierarchy_report.json'),pretty=TRUE,auto_unbox=TRUE,dataframe='rows',digits=16,na='null')
review_dir <- 'outputs/global_oa_hierarchy'
dir.create(review_dir,recursive=TRUE,showWarnings=FALSE)
file.copy(file.path(out,'global_oa_hierarchy_report.json'),file.path(review_dir,'global_oa_hierarchy_report.json'),overwrite=TRUE)
saveRDS(report,file.path(out,'validated_report.rds'))
print(report$education)
print(report$crosswalk)
print(report$stages)
for(kind in c('br','rd','sh')) {cat(kind,'old to selected:\n');print(report$comparisons[[kind]]$old_to_post)}
