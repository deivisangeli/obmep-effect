# Offline LOCAL prep. Parks one deterministic 100-decision semantic audit sample
# from the completed degree-duration e-MEC hierarchy. It uses no network and
# must not be sent to SEDAP.
# Run from the repository root:
#   Rscript prep/building_external_data/degree_duration_emec_audit_sample.R
library(DBI)
library(duckdb)
library(jsonlite)

root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
out <- Sys.getenv('OBMEP_EMEC_DURATION_OUT',file.path(root,'Data/intermediate/revelio_br_cohort/emec_hierarchy'))
crosswalk_path <- file.path(out,'degree_duration_emec_crosswalk.parquet')
catalog_path <- file.path(out,'catalog.parquet')
report_path <- file.path(out,'degree_duration_emec_hierarchy_report.json')
sample_path <- file.path(out,'degree_duration_emec_audit_sample.parquet')
sample_csv <- file.path(out,'degree_duration_emec_audit_sample.csv')
manifest_path <- file.path(out,'degree_duration_emec_audit_sample_manifest.json')
sample_source <- Sys.getenv('OBMEP_EMEC_AUDIT_SAMPLE_SOURCE','')
decision_paths <- sort(list.files(file.path(out,'decisions'),pattern='[.]parquet$',full.names=TRUE))
stopifnot(file.exists(crosswalk_path),file.exists(catalog_path),file.exists(report_path),
 length(decision_paths)==64L)

fingerprint_paths <- c(report_path,crosswalk_path,catalog_path,decision_paths)
fingerprint <- data.frame(path=fingerprint_paths,md5=unname(tools::md5sum(fingerprint_paths)))
stopifnot(!anyNA(fingerprint$md5))
parked <- file.exists(c(sample_path,sample_csv,manifest_path))
if(any(parked)) {
 stopifnot(all(parked))
 old <- read_json(manifest_path,simplifyVector=TRUE)
 stopifnot(identical(old$source_fingerprint$path,fingerprint$path),
  identical(old$source_fingerprint$md5,fingerprint$md5),
  identical(unname(tools::md5sum(c(sample_path,sample_csv))),old$outputs$md5))
 con <- dbConnect(duckdb())
 stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n,count(DISTINCT emec_decision_id) decisions
  FROM read_parquet('%s')",gsub('\\\\','/',sample_path)))$n==100L)
 dbDisconnect(con,shutdown=TRUE)
 cat('Reused parked degree-duration e-MEC audit sample:',sample_path,'\n')
 quit(save='no',status=0)
}

preserved_sample <- NULL
if(nzchar(sample_source)) {
 stopifnot(file.exists(sample_source))
 source_con <- dbConnect(duckdb())
 preserved_sample <- dbGetQuery(source_con,sprintf("SELECT emec_decision_id,sample_stratum,sample_order
  FROM read_parquet('%s') ORDER BY sample_order",gsub('\\\\','/',sample_source)))
 dbDisconnect(source_con,shutdown=TRUE)
 stopifnot(nrow(preserved_sample)==100L,length(unique(preserved_sample$emec_decision_id))==100L)
}

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con,shutdown=TRUE),add=TRUE)
dbExecute(con,"SET memory_limit='4GB'")
dbExecute(con,'SET threads=4')
crosswalk_sql <- gsub('\\\\','/',crosswalk_path)
catalog_sql <- gsub('\\\\','/',catalog_path)
dbExecute(con,sprintf("CREATE VIEW audit_universe AS SELECT * FROM read_parquet('%s')",crosswalk_sql))
dbExecute(con,sprintf("CREATE VIEW catalog AS SELECT * FROM read_parquet('%s')",catalog_sql))
dbExecute(con,"CREATE TABLE sampled(emec_decision_id BIGINT,sample_stratum VARCHAR,
 stratum_order INTEGER,stratum_rank INTEGER)")

if(!is.null(preserved_sample)) {
 dbWriteTable(con,'preserved_sample',preserved_sample,temporary=TRUE)
 dbExecute(con,"INSERT INTO sampled SELECT emec_decision_id,sample_stratum,
  sample_order::INTEGER,1::INTEGER FROM preserved_sample")
} else {
dbExecute(con,"INSERT INTO sampled SELECT emec_decision_id,'stage1_largest',1,
 row_number() OVER(ORDER BY education_rows DESC,users DESC,emec_decision_id)::INTEGER
 FROM audit_universe WHERE emec_selection_stage=1 AND CO_IES IS NOT NULL
 ORDER BY education_rows DESC,users DESC,emec_decision_id LIMIT 15")
dbExecute(con,"INSERT INTO sampled SELECT emec_decision_id,'stage1_deterministic',2,
 row_number() OVER(ORDER BY hash(emec_decision_id,20260916),emec_decision_id)::INTEGER
 FROM audit_universe u WHERE emec_selection_stage=1 AND CO_IES IS NOT NULL
 AND NOT EXISTS(SELECT 1 FROM sampled s WHERE s.emec_decision_id=u.emec_decision_id)
 ORDER BY hash(emec_decision_id,20260916),emec_decision_id LIMIT 15")
dbExecute(con,"INSERT INTO sampled SELECT emec_decision_id,'stage2_largest',3,
 row_number() OVER(ORDER BY education_rows DESC,users DESC,emec_decision_id)::INTEGER
 FROM audit_universe u WHERE emec_selection_stage=2 AND CO_IES IS NOT NULL
 AND NOT EXISTS(SELECT 1 FROM sampled s WHERE s.emec_decision_id=u.emec_decision_id)
 ORDER BY education_rows DESC,users DESC,emec_decision_id LIMIT 15")
dbExecute(con,"INSERT INTO sampled SELECT emec_decision_id,'stage2_deterministic',4,
 row_number() OVER(ORDER BY hash(emec_decision_id,20260916),emec_decision_id)::INTEGER
 FROM audit_universe u WHERE emec_selection_stage=2 AND CO_IES IS NOT NULL
 AND NOT EXISTS(SELECT 1 FROM sampled s WHERE s.emec_decision_id=u.emec_decision_id)
 ORDER BY hash(emec_decision_id,20260916),emec_decision_id LIMIT 15")
dbExecute(con,"INSERT INTO sampled SELECT emec_decision_id,'stage3_largest_publishable',5,
 row_number() OVER(ORDER BY education_rows DESC,users DESC,emec_decision_id)::INTEGER
 FROM audit_universe u WHERE emec_selection_stage=3 AND CO_IES IS NOT NULL
 AND NOT EXISTS(SELECT 1 FROM sampled s WHERE s.emec_decision_id=u.emec_decision_id)
 ORDER BY education_rows DESC,users DESC,emec_decision_id LIMIT 15")
dbExecute(con,"INSERT INTO sampled SELECT emec_decision_id,'stage3_deterministic_publishable',6,
 row_number() OVER(ORDER BY hash(emec_decision_id,20260916),emec_decision_id)::INTEGER
 FROM audit_universe u WHERE emec_selection_stage=3 AND CO_IES IS NOT NULL
 AND NOT EXISTS(SELECT 1 FROM sampled s WHERE s.emec_decision_id=u.emec_decision_id)
 ORDER BY hash(emec_decision_id,20260916),emec_decision_id LIMIT 10")
dbExecute(con,"INSERT INTO sampled SELECT emec_decision_id,'active_preference',7,
 row_number() OVER(ORDER BY education_rows DESC,users DESC,emec_decision_id)::INTEGER
 FROM audit_universe u WHERE emec_active_preference=1
 AND NOT EXISTS(SELECT 1 FROM sampled s WHERE s.emec_decision_id=u.emec_decision_id)
 ORDER BY education_rows DESC,users DESC,emec_decision_id LIMIT 5")
dbExecute(con,"INSERT INTO sampled SELECT emec_decision_id,'stage3_quarantine',8,
 row_number() OVER(ORDER BY education_rows DESC,users DESC,emec_decision_id)::INTEGER
 FROM audit_universe u WHERE emec_selection_stage=3 AND emec_selection_status IN
 ('unresolved_ambiguous_acronym','unresolved_contextual_acronym')
 AND NOT EXISTS(SELECT 1 FROM sampled s WHERE s.emec_decision_id=u.emec_decision_id)
 ORDER BY education_rows DESC,users DESC,emec_decision_id LIMIT 5")
dbExecute(con,"INSERT INTO sampled SELECT emec_decision_id,'stage4_quarantine',9,
 row_number() OVER(ORDER BY education_rows DESC,users DESC,emec_decision_id)::INTEGER
 FROM audit_universe u WHERE emec_selection_stage=4
 AND NOT EXISTS(SELECT 1 FROM sampled s WHERE s.emec_decision_id=u.emec_decision_id)
 ORDER BY education_rows DESC,users DESC,emec_decision_id LIMIT 5")

dbExecute(con,"INSERT INTO sampled SELECT emec_decision_id,'deterministic_risk_fill',10,
 row_number() OVER(ORDER BY CASE WHEN emec_active_preference=1 THEN 0
  WHEN CO_IES IS NOT NULL THEN 1 WHEN emec_selection_stage IN (3,4) THEN 2 ELSE 3 END,
  education_rows DESC,hash(emec_decision_id,20260916),emec_decision_id)::INTEGER
 FROM audit_universe u WHERE NOT EXISTS(
  SELECT 1 FROM sampled s WHERE s.emec_decision_id=u.emec_decision_id)
 QUALIFY row_number() OVER(ORDER BY CASE WHEN emec_active_preference=1 THEN 0
  WHEN CO_IES IS NOT NULL THEN 1 WHEN emec_selection_stage IN (3,4) THEN 2 ELSE 3 END,
  education_rows DESC,hash(emec_decision_id,20260916),emec_decision_id)
  <=100-(SELECT count(*) FROM sampled)")
}

sample_stats <- dbGetQuery(con,"SELECT count(*) sample_rows,count(DISTINCT emec_decision_id) decisions
 FROM sampled")
stopifnot(sample_stats$sample_rows==100L,sample_stats$decisions==100L)
dbExecute(con,"CREATE TABLE sample_candidate_details AS SELECT s.emec_decision_id,
 list(struct_pack(co_ies:=c.CO_IES,nome_ies:=c.nome_ies,sigla:=c.sigla,
  situacao_ies:=c.situacao_ies,municipio:=c.municipio,uf:=c.uf) ORDER BY c.CO_IES)
  emec_candidate_details
 FROM sampled s JOIN audit_universe u USING(emec_decision_id)
 CROSS JOIN unnest(u.emec_candidate_codes) x(co_ies) JOIN catalog c ON c.CO_IES=x.co_ies
 GROUP BY s.emec_decision_id")
dbExecute(con,"CREATE TABLE sample_final_details AS SELECT s.emec_decision_id,
 c.nome_ies selected_nome_ies,c.sigla selected_sigla,c.situacao_ies selected_situacao_ies,
 c.municipio selected_municipio,c.uf selected_uf
 FROM sampled s JOIN audit_universe u USING(emec_decision_id)
 JOIN catalog c USING(CO_IES)")
dbExecute(con,"CREATE TABLE audit_sample AS SELECT
 row_number() OVER(ORDER BY s.stratum_order,s.stratum_rank,s.emec_decision_id)::INTEGER sample_order,
 s.sample_stratum,u.*,d.emec_candidate_details,
 f.selected_nome_ies,f.selected_sigla,f.selected_situacao_ies,f.selected_municipio,f.selected_uf
 FROM sampled s JOIN audit_universe u USING(emec_decision_id)
 LEFT JOIN sample_candidate_details d USING(emec_decision_id)
 LEFT JOIN sample_final_details f USING(emec_decision_id)
 ORDER BY sample_order")
sample_sql <- gsub('\\\\','/',sample_path)
csv_sql <- gsub('\\\\','/',sample_csv)
dbExecute(con,sprintf("COPY audit_sample TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)",sample_sql))
dbExecute(con,sprintf("COPY audit_sample TO '%s' (FORMAT CSV,HEADER,DELIMITER ',')",csv_sql))
strata <- dbGetQuery(con,"SELECT sample_stratum,count(*) decisions,sum(education_rows) education_rows
 FROM audit_sample GROUP BY 1 ORDER BY min(sample_order)")
stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n,count(DISTINCT emec_decision_id) decisions
 FROM read_parquet('%s')",sample_sql))$n==100L)
dbDisconnect(con,shutdown=TRUE)

outputs <- c(sample_path,sample_csv)
manifest <- list(created_at=format(Sys.time(),tz='America/Sao_Paulo',usetz=TRUE),
 seed=20260916L,sample_decisions=100L,immutable=TRUE,
 redraw_policy='Reuse only when the complete source fingerprint matches; otherwise stop.',
 refreshed_from=if(nzchar(sample_source)) normalizePath(sample_source,winslash='/',mustWork=TRUE) else NULL,
 strata=strata,source_fingerprint=fingerprint,
 outputs=data.frame(path=outputs,md5=unname(tools::md5sum(outputs))))
write_json(manifest,manifest_path,pretty=TRUE,auto_unbox=TRUE,dataframe='rows',digits=16,na='null')
cat('Parked degree-duration e-MEC audit sample:',sample_path,'\n')
print(strata)
