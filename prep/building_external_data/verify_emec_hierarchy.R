# Independent, read-only verification of the published degree-duration e-MEC
# hierarchy. It recomputes invariants from source and output files and writes
# only a verification JSON beside the build report.
library(DBI)
library(duckdb)
library(jsonlite)
library(stringdist)

root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh <- file.path(root,'Data/intermediate/revelio_br_cohort')
input_dir <- file.path(coh,'global_oa_hierarchy','education_parts')
out <- Sys.getenv('OBMEP_EMEC_DURATION_OUT',file.path(coh,'emec_hierarchy'))
emec_csv <- file.path(root,'Data/raw/PDA_Lista_Instituicoes_Ensino_Superior_do_Brasil_EMEC.csv')
report_path <- file.path(out,'degree_duration_emec_hierarchy_report.json')
verification_path <- file.path(out,'degree_duration_emec_hierarchy_verification.json')
sql_path <- 'prep/building_external_data/global_oa_hierarchy_sql.R'

input_paths <- sort(list.files(input_dir,pattern='[.]parquet$',full.names=TRUE))
output_paths <- sort(list.files(file.path(out,'education_parts'),pattern='[.]parquet$',full.names=TRUE))
decision_paths <- sort(list.files(file.path(out,'decisions'),pattern='[.]parquet$',full.names=TRUE))
evaluation_paths <- sort(list.files(file.path(out,'candidate_evaluations'),pattern='[.]parquet$',full.names=TRUE))
stopifnot(file.exists(report_path),file.exists(emec_csv),file.exists(sql_path),
 length(input_paths)==30L,length(output_paths)==30L,
 identical(basename(input_paths),basename(output_paths)),
 length(decision_paths)==64L,length(evaluation_paths)==64L)
report <- read_json(report_path,simplifyVector=TRUE)
stopifnot(identical(unname(tools::md5sum(report$inputs$path)),report$inputs$md5),
 identical(unname(tools::md5sum(report$outputs$path)),report$outputs$md5))
implementation <- data.frame(path=c('prep/building_external_data/degree_duration_emec_hierarchy.R',sql_path),
 md5=unname(tools::md5sum(c('prep/building_external_data/degree_duration_emec_hierarchy.R',sql_path))))
stopifnot(identical(readRDS(file.path(out,'implementation_manifest.rds')),implementation),
 identical(readRDS(file.path(out,'checkpoints','01_catalog.rds')),
  tools::md5sum(file.path(out,c('catalog.parquet','aliases.parquet')))),
 identical(readRDS(file.path(out,'checkpoints','02_crosswalk.rds')),
  tools::md5sum(file.path(out,paste0(c('raw_names','raw_links','crosswalk_evidence',
   'crosswalk','rsid_sets','raw_sets'),'.parquet')))),
 identical(readRDS(file.path(out,'checkpoints','03_population.rds')),
  tools::md5sum(file.path(out,'decision_inputs.parquet'))))

con <- dbConnect(duckdb(),dbdir=':memory:')
on.exit(dbDisconnect(con,shutdown=TRUE),add=TRUE)
dbExecute(con,"SET memory_limit='8GB'")
dbExecute(con,'SET threads=4')
source(sql_path)

catalog_path <- gsub('\\\\','/',file.path(out,'catalog.parquet'))
aliases_path <- gsub('\\\\','/',file.path(out,'aliases.parquet'))
decisions_glob <- gsub('\\\\','/',file.path(out,'decisions','*.parquet'))
evaluations_glob <- gsub('\\\\','/',file.path(out,'candidate_evaluations','*.parquet'))
education_glob <- gsub('\\\\','/',file.path(out,'education_parts','*.parquet'))
crosswalk_path <- gsub('\\\\','/',file.path(out,'degree_duration_emec_crosswalk.parquet'))
decision_inputs_path <- gsub('\\\\','/',file.path(out,'decision_inputs.parquet'))
dbExecute(con,sprintf("CREATE VIEW catalog_public AS SELECT * FROM read_parquet('%s')",catalog_path))
dbExecute(con,sprintf("CREATE VIEW aliases_public AS SELECT * FROM read_parquet('%s')",aliases_path))
dbExecute(con,sprintf("CREATE VIEW decisions AS SELECT * FROM read_parquet('%s')",decisions_glob))
dbExecute(con,sprintf("CREATE VIEW evaluations_public AS SELECT * FROM read_parquet('%s')",evaluations_glob))
dbExecute(con,sprintf("CREATE VIEW enriched AS SELECT * FROM read_parquet('%s')",education_glob))
dbExecute(con,sprintf("CREATE VIEW crosswalk AS SELECT * FROM read_parquet('%s')",crosswalk_path))
dbExecute(con,sprintf("CREATE VIEW decision_inputs_public AS SELECT * FROM read_parquet('%s')",decision_inputs_path))

# Independently reconstruct every catalog and alias field from the source CSV.
dbExecute(con,sprintf("CREATE TABLE emec_source AS SELECT * FROM read_csv('%s',header=true,all_varchar=true)",
 gsub('\\\\','/',emec_csv)))
dbExecute(con,"CREATE TABLE expected_catalog AS SELECT
 CAST(trim(CODIGO_DA_IES) AS BIGINT) CO_IES,NOME_DA_IES nome_ies,SIGLA sigla,
 CATEGORIA_DA_IES categoria_ies,COMUNITARIA comunitaria,CONFESSIONAL confessional,
 FILANTROPICA filantropica,ORGANIZACAO_ACADEMICA organizacao_academica,
 CODIGO_MUNICIPIO_IBGE codigo_municipio_ibge,MUNICIPIO municipio,UF uf,
 trim(SITUACAO_IES) situacao_ies,'BR' country_code,
 trim(regexp_replace(regexp_replace(NOME_DA_IES,'\\s*\\([^()]*\\)','','g'),'\\s+',' ','g')) cleaned_nome_ies
 FROM emec_source")
dbExecute(con,"CREATE TABLE expected_aliases AS WITH raw AS (
 SELECT CO_IES,nome_ies alias,'primary' alias_kind FROM expected_catalog
 UNION ALL SELECT CO_IES,cleaned_nome_ies,'cleaned' FROM expected_catalog
 UNION ALL SELECT CO_IES,sigla,'acronym' FROM expected_catalog
 WHERE sigla IS NOT NULL AND lower(trim(sigla))<>'null'
), folded AS (SELECT DISTINCT CO_IES,alias,alias_kind,
 strip_accents(lower(trim(alias))) alias_norm FROM raw)
SELECT CO_IES,alias,alias_kind,alias_norm,alias_kind<>'acronym' name_eligible FROM folded
WHERE alias_norm IS NOT NULL AND alias_norm<>'' AND (alias_kind<>'acronym' OR
 length(regexp_replace(alias_norm,'[^a-z0-9]','','g'))>=3)")
catalog_check <- dbGetQuery(con,"SELECT count(*) catalog_rows,count(DISTINCT CO_IES) codes,
 count(*) FILTER(WHERE CO_IES IS NULL) null_codes,
 count(*) FILTER(WHERE nome_ies IS NULL OR trim(nome_ies)='') blank_names,
 count(*) FILTER(WHERE situacao_ies NOT IN ('Ativa','Extinta','Em atividade')) bad_status
 FROM catalog_public")
stopifnot(catalog_check$catalog_rows==4328L,catalog_check$codes==4328L,
 catalog_check$null_codes==0L,catalog_check$blank_names==0L,catalog_check$bad_status==0L,
 dbGetQuery(con,"SELECT count(*) n FROM (
  (SELECT * FROM expected_catalog EXCEPT ALL SELECT * FROM catalog_public)
  UNION ALL (SELECT * FROM catalog_public EXCEPT ALL SELECT * FROM expected_catalog))")$n==0L,
 dbGetQuery(con,"SELECT count(*) n FROM (
  (SELECT * FROM expected_aliases EXCEPT ALL SELECT * FROM aliases_public)
  UNION ALL (SELECT * FROM aliases_public EXCEPT ALL SELECT * FROM expected_aliases))")$n==0L,
 dbGetQuery(con,"SELECT count(*) n FROM aliases_public WHERE alias_kind='acronym' AND
  (lower(trim(alias))='null' OR length(regexp_replace(alias_norm,'[^a-z0-9]','','g'))<3)")$n==0L)

# Public artifacts must never expose the shared selector's internal oa_id adapter.
public_artifacts <- c(catalog_path,aliases_path,decisions_glob,evaluations_glob,
 crosswalk_path,decision_inputs_path)
for(p in public_artifacts) {
 s <- dbGetQuery(con,sprintf("DESCRIBE SELECT * FROM read_parquet('%s')",p))
 stopifnot(!any(grepl('oa_id',paste(s$column_name,s$column_type),ignore.case=TRUE)))
}

population <- dbGetQuery(con,"SELECT count(*) education_rows,count(DISTINCT user_id) users,
 count(DISTINCT (source_file,source_row)) physical_keys,
 count(*) FILTER(WHERE emec_selected_count=1) single_rows,
 count(*) FILTER(WHERE emec_selected_count>1) tied_rows,
 count(*) FILTER(WHERE emec_selected_count=0) unresolved_rows,
 count(*) FILTER(WHERE emec_active_preference=1) active_preference_rows FROM enriched")
stopifnot(population$education_rows==19710307L,population$users==8901904L,
 population$physical_keys==population$education_rows)

# Recheck every upstream value by physical key, independently of the build report.
for(i in seq_along(input_paths)) {
 src <- gsub('\\\\','/',input_paths[i])
 dest <- gsub('\\\\','/',output_paths[i])
 dbExecute(con,sprintf("CREATE OR REPLACE TEMP VIEW source_part AS SELECT * FROM read_parquet('%s')",src))
 cols <- dbGetQuery(con,'DESCRIBE source_part')$column_name
 mismatch <- paste(sprintf('s."%1$s" IS DISTINCT FROM e."%1$s"',cols),collapse=' OR ')
 stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM source_part s
  FULL JOIN read_parquet('%s') e USING(source_file,source_row) WHERE %s",dest,mismatch))$n==0L)
 cat('Independent source preservation:',i,'of',length(input_paths),'\n')
}

stopifnot(
 dbGetQuery(con,"SELECT count(*) n FROM decisions WHERE
  selector_selected_count<>coalesce(len(selector_selected_codes),0)
  OR pre_status_selected_count<>coalesce(len(pre_status_selected_codes),0)
  OR selected_count<>coalesce(len(selected_codes),0)
  OR (selector_selected_count>0 AND NOT list_has_all(candidate_codes,selector_selected_codes))
  OR (pre_status_selected_count>0 AND NOT list_has_all(selector_selected_codes,pre_status_selected_codes))
  OR (selected_count>0 AND NOT list_has_all(pre_status_selected_codes,selected_codes))")$n==0L,
 dbGetQuery(con,"SELECT count(*) n FROM enriched WHERE
  (CO_IES IS NOT NULL) IS DISTINCT FROM (emec_selected_count=1)
  OR (emec_selected_count=1 AND CO_IES<>emec_selected_codes[1])")$n==0L,
 dbGetQuery(con,"SELECT count(*) n FROM crosswalk WHERE
  (CO_IES IS NOT NULL) IS DISTINCT FROM (emec_selected_count=1)
  OR (emec_selected_count=1 AND CO_IES<>emec_selected_codes[1])")$n==0L,
 dbGetQuery(con,"SELECT count(*) n FROM (
   SELECT unnest(candidate_codes) co_ies FROM decisions
   UNION SELECT unnest(selector_selected_codes) FROM decisions
   UNION SELECT unnest(pre_status_selected_codes) FROM decisions
   UNION SELECT unnest(selected_codes) FROM decisions) x
  LEFT JOIN catalog_public c ON c.CO_IES=x.co_ies WHERE c.CO_IES IS NULL")$n==0L)

score_stage_check <- dbGetQuery(con,"SELECT
 count(*) FILTER(WHERE selection_stage=4 AND selector_selected_count>0) provisional_decisions,
 count(*) FILTER(WHERE selection_stage=4 AND
  (pre_status_selected_count<>0 OR selected_count<>0 OR active_preference<>0)) published_decisions,
 count(*) FILTER(WHERE selection_stage=4 AND selector_selected_count>0 AND
  pre_status_selection_status<>'unresolved_fuzzy_unvalidated') bad_status
 FROM decisions")
stopifnot(score_stage_check$provisional_decisions>0L,
 score_stage_check$published_decisions==0L,score_stage_check$bad_status==0L,
 dbGetQuery(con,"SELECT count(*) n FROM enriched WHERE emec_selection_stage=4 AND CO_IES IS NOT NULL")$n==0L)

acronym_stage_check <- dbGetQuery(con,"SELECT
 count(*) FILTER(WHERE selection_stage=3 AND selector_acronym_owner_count>1) ambiguous_decisions,
 count(*) FILTER(WHERE selection_stage=3 AND selector_acronym_owner_count>1 AND
  (pre_status_selected_count<>0 OR selected_count<>0 OR active_preference<>0)) published_decisions,
 count(*) FILTER(WHERE selection_stage=3 AND selector_acronym_owner_count>1 AND
  pre_status_selection_status<>'unresolved_ambiguous_acronym') bad_status
 FROM decisions")
stopifnot(acronym_stage_check$ambiguous_decisions>0L,
 acronym_stage_check$published_decisions==0L,acronym_stage_check$bad_status==0L,
 dbGetQuery(con,"SELECT count(*) n FROM enriched WHERE emec_selection_stage=3 AND
  emec_selector_acronym_owner_count>1 AND CO_IES IS NOT NULL")$n==0L)

contextual_acronym_check <- dbGetQuery(con,"SELECT
 count(*) FILTER(WHERE selection_stage=3 AND NOT selector_acronym_context_ok) contextual_decisions,
 count(*) FILTER(WHERE selection_stage=3 AND NOT selector_acronym_context_ok AND
  (pre_status_selected_count<>0 OR selected_count<>0 OR active_preference<>0)) published_decisions,
 count(*) FILTER(WHERE selection_stage=3 AND selector_acronym_owner_count<=1 AND
  NOT selector_acronym_context_ok AND pre_status_selection_status<>'unresolved_contextual_acronym') bad_status
 FROM decisions")
stopifnot(contextual_acronym_check$contextual_decisions>0L,
 contextual_acronym_check$published_decisions==0L,contextual_acronym_check$bad_status==0L,
 dbGetQuery(con,"SELECT count(*) n FROM enriched WHERE emec_selection_stage=3 AND
 NOT emec_selector_acronym_context_ok AND CO_IES IS NOT NULL")$n==0L)

containment_check <- dbGetQuery(con,"SELECT
 count(*) FILTER(WHERE selection_stage=2 AND NOT selector_stage2_context_ok) conflict_decisions,
 count(*) FILTER(WHERE selection_stage=2 AND NOT selector_stage2_context_ok AND
  (pre_status_selected_count<>0 OR selected_count<>0 OR active_preference<>0)) published_decisions,
 count(*) FILTER(WHERE selection_stage=2 AND NOT selector_stage2_context_ok AND
  pre_status_selection_status<>'unresolved_containment_conflict') bad_status
 FROM decisions")
stopifnot(containment_check$conflict_decisions>0L,
 containment_check$published_decisions==0L,containment_check$bad_status==0L,
 dbGetQuery(con,"SELECT count(*) n FROM enriched WHERE emec_selection_stage=2 AND
  NOT emec_selector_stage2_context_ok AND CO_IES IS NOT NULL")$n==0L)

active_check <- dbGetQuery(con,"WITH a AS (SELECT d.decision_id,d.active_preference,
 d.pre_status_selected_count,d.selected_count,d.pre_status_selected_codes,d.selected_codes,
 count(u.co_ies) FILTER(WHERE c.situacao_ies IN ('Ativa','Em atividade')) active_count,
 count(DISTINCT lower(trim(c.municipio))||'|'||upper(trim(c.uf))) FILTER(WHERE c.municipio IS NOT NULL
  AND lower(trim(c.municipio))<>'null' AND c.uf IS NOT NULL AND lower(trim(c.uf))<>'null') location_count,
 count(*) FILTER(WHERE c.municipio IS NULL OR lower(trim(c.municipio))='null'
  OR c.uf IS NULL OR lower(trim(c.uf))='null') location_missing
 FROM decisions d LEFT JOIN unnest(d.pre_status_selected_codes) u(co_ies) ON true
 LEFT JOIN catalog_public c ON c.CO_IES=u.co_ies GROUP BY ALL)
 SELECT count(*) FILTER(WHERE active_preference=1 AND
  (pre_status_selected_count<=1 OR selected_count<>1 OR active_count<>1
   OR location_count<>1 OR location_missing<>0)) bad_applied,
 count(*) FILTER(WHERE pre_status_selected_count>1 AND active_count=1
  AND location_count=1 AND location_missing=0 AND active_preference<>1) missed,
 count(*) FILTER(WHERE active_preference=0 AND
  pre_status_selected_codes IS DISTINCT FROM selected_codes) changed_without_rule FROM a")
stopifnot(active_check$bad_applied==0L,active_check$missed==0L,
 active_check$changed_without_rule==0L)

# Recompute two complete deterministic decision buckets through the shared SQL.
dbExecute(con,"CREATE TABLE catalog AS SELECT CAST(CO_IES AS VARCHAR) oa_id,
 country_code,situacao_ies FROM catalog_public")
dbExecute(con,"CREATE TABLE aliases AS SELECT CAST(CO_IES AS VARCHAR) oa_id,
 alias,alias_norm,alias_kind,name_eligible FROM aliases_public")
dbExecute(con,"CREATE TABLE decision_batch AS SELECT decision_id,raw_id,country_code,
 list_transform(candidate_codes,x->CAST(x AS VARCHAR)) candidate_ids,
 university_raw,raw_norm,raw_case,raw_segments FROM decision_inputs_public
 WHERE decision_id%64 IN (0,37)")
unicode_scores <- dbGetQuery(con,hierarchy_unicode_pairs_sql)
unicode_scores$jaro <- stringsim(unicode_scores$raw_norm,unicode_scores$alias_norm,
 method='jw',p=0,useBytes=FALSE)
dbWriteTable(con,'unicode_scores',unicode_scores)
dbExecute(con,paste('CREATE TABLE evaluations AS',hierarchy_evaluation_sql))
dbExecute(con,paste('CREATE TABLE recomputed AS',hierarchy_decision_sql))
dbExecute(con,"CREATE TABLE acronym_owner_counts_verify AS SELECT alias_norm,
 count(DISTINCT oa_id)::INTEGER owner_count FROM aliases
 WHERE alias_kind='acronym' GROUP BY alias_norm")
dbExecute(con,"CREATE TABLE recomputed_ambiguity AS SELECT r.decision_id,
 coalesce(max(o.owner_count),0)::INTEGER selector_acronym_owner_count,
 coalesce(bool_and(r.raw_norm=o.alias_norm OR list_contains(r.raw_segments,o.alias_norm))
  FILTER(WHERE r.selection_stage=3),true) selector_acronym_context_ok
 FROM recomputed r LEFT JOIN unnest(r.selected_evidence) e(x) ON true
 LEFT JOIN acronym_owner_counts_verify o ON r.selection_stage=3 AND
  o.alias_norm=strip_accents(lower(trim(x.supporting_alias))) GROUP BY r.decision_id")
dbExecute(con,"CREATE TABLE stage2_generic_tokens_verify AS SELECT token FROM (VALUES
 ('a'),('o'),('as'),('os'),('e'),('da'),('de'),('do'),('das'),('dos'),('em'),('para'),
 ('the'),('of'),('and'),('at'),('in'),('for'),('la'),('las'),('el'),('los'),('del'),('y'),
 ('university'),('universidade'),('universidad'),('universite'),('college'),('faculty'),
 ('faculdade'),('faculdades'),('facultad'),('center'),('centre'),('centro'),('institute'),
 ('instituto'),('institut'),('school'),('escola'),('education'),('educacao'),('ensino'),
 ('higher'),('superior'),('superiores')) t(token)")
dbExecute(con,"CREATE TABLE recomputed_stage2_residuals AS WITH raw_tokens AS (
 SELECT DISTINCT r.decision_id,t.token FROM recomputed r
 CROSS JOIN unnest(regexp_split_to_array(r.raw_norm,'[^a-z0-9]+')) t(token)
 LEFT JOIN stage2_generic_tokens_verify g USING(token)
 WHERE r.selection_stage=2 AND length(t.token)>=3 AND g.token IS NULL
), selected_tokens AS (
 SELECT DISTINCT r.decision_id,t.token FROM recomputed r
 CROSS JOIN unnest(r.selected_evidence) e(x)
 CROSS JOIN unnest(regexp_split_to_array(strip_accents(lower(x.supporting_alias)),'[^a-z0-9]+')) t(token)
 WHERE r.selection_stage=2
) SELECT q.* FROM raw_tokens q LEFT JOIN selected_tokens t USING(decision_id,token)
WHERE t.token IS NULL")
dbExecute(con,"CREATE TABLE recomputed_stage2_conflicts AS SELECT DISTINCT q.decision_id
 FROM recomputed_stage2_residuals q JOIN recomputed r USING(decision_id)
 CROSS JOIN unnest(r.candidate_ids) u(oa_id)
 JOIN aliases a ON a.oa_id=u.oa_id AND a.name_eligible
 CROSS JOIN unnest(regexp_split_to_array(a.alias_norm,'[^a-z0-9]+')) t(token)
 WHERE NOT list_contains(r.selected_ids,u.oa_id) AND t.token=q.token")
dbExecute(con,"CREATE TABLE recomputed_stage2_context AS SELECT r.decision_id,
 (c.decision_id IS NULL) selector_stage2_context_ok
 FROM recomputed r LEFT JOIN recomputed_stage2_conflicts c USING(decision_id)")
recomputed_eval_bad <- dbGetQuery(con,"SELECT count(*) n FROM evaluations r
 FULL JOIN (SELECT * FROM evaluations_public WHERE decision_id%64 IN (0,37)) p
  ON p.decision_id=r.decision_id AND p.CO_IES=CAST(r.oa_id AS BIGINT)
 WHERE r.decision_id IS NULL OR p.decision_id IS NULL
  OR r.candidate_stage IS DISTINCT FROM p.candidate_stage
  OR r.country_match IS DISTINCT FROM p.country_match
  OR abs(r.jw_similarity-p.jw_similarity)>1e-12
  OR abs(r.score-p.score)>1e-12
  OR r.stage_alias IS DISTINCT FROM p.stage_alias
  OR r.stage_alias_kind IS DISTINCT FROM p.stage_alias_kind
  OR r.similarity_alias IS DISTINCT FROM p.similarity_alias")$n
recomputed_decision_bad <- dbGetQuery(con,"SELECT count(*) n FROM recomputed r
 JOIN recomputed_ambiguity a USING(decision_id)
 JOIN recomputed_stage2_context c USING(decision_id) JOIN decisions p USING(decision_id)
 WHERE r.selection_stage IS DISTINCT FROM p.selection_stage
  OR list_transform(r.selected_ids,x->CAST(x AS BIGINT)) IS DISTINCT FROM p.selector_selected_codes
  OR r.selected_count IS DISTINCT FROM p.selector_selected_count
  OR r.selection_status IS DISTINCT FROM p.selector_selection_status
  OR a.selector_acronym_owner_count IS DISTINCT FROM p.selector_acronym_owner_count
  OR a.selector_acronym_context_ok IS DISTINCT FROM p.selector_acronym_context_ok
  OR c.selector_stage2_context_ok IS DISTINCT FROM p.selector_stage2_context_ok
  OR (CASE WHEN r.selection_stage=4 OR (r.selection_stage=3 AND
       (a.selector_acronym_owner_count>1 OR NOT a.selector_acronym_context_ok)) OR
       (r.selection_stage=2 AND NOT c.selector_stage2_context_ok)
       THEN list_filter(list_transform(r.selected_ids,x->CAST(x AS BIGINT)),x->false)
       ELSE list_transform(r.selected_ids,x->CAST(x AS BIGINT)) END) IS DISTINCT FROM p.pre_status_selected_codes
  OR (CASE WHEN r.selection_stage=4 AND r.selected_count>0 THEN 'unresolved_fuzzy_unvalidated'
       WHEN r.selection_stage=3 AND a.selector_acronym_owner_count>1 THEN 'unresolved_ambiguous_acronym'
       WHEN r.selection_stage=3 AND NOT a.selector_acronym_context_ok THEN 'unresolved_contextual_acronym'
       WHEN r.selection_stage=2 AND NOT c.selector_stage2_context_ok THEN 'unresolved_containment_conflict'
       ELSE r.selection_status END) IS DISTINCT FROM p.pre_status_selection_status")$n
stopifnot(recomputed_eval_bad==0L,recomputed_decision_bad==0L,
 dbGetQuery(con,'SELECT count(*) n FROM recomputed')$n==dbGetQuery(con,'SELECT count(*) n FROM decision_batch')$n)

verification <- list(verified_at=format(Sys.time(),tz='America/Sao_Paulo',usetz=TRUE),
 population=population,catalog=catalog_check,active_preference=active_check,
 score_stage=score_stage_check,acronym_stage=acronym_stage_check,
 contextual_acronym=contextual_acronym_check,
 containment=containment_check,
 recomputed_buckets=c(0L,37L),
 checks=list(report_input_checksums=TRUE,report_output_checksums=TRUE,
  source_catalog_all_fields_exact=TRUE,source_alias_set_exact=TRUE,
  municipality_codes_preserved_as_text=TRUE,invalid_acronyms_absent=TRUE,
  checkpoint_and_implementation_hashes=TRUE,no_internal_adapter_fields=TRUE,
  source_rows_and_values_preserved=TRUE,physical_keys_unique=TRUE,
  candidate_and_selected_codes_in_catalog=TRUE,selection_sets_nested=TRUE,
  scalar_code_iff_unique=TRUE,active_preference_exact=TRUE,
  score_stage_diagnostic_only=TRUE,
  ambiguous_acronym_diagnostic_only=TRUE,
  contextual_acronym_diagnostic_only=TRUE,
  containment_conflict_diagnostic_only=TRUE,
  selector_buckets_recomputed=TRUE))
write_json(verification,verification_path,pretty=TRUE,auto_unbox=TRUE,
 dataframe='rows',digits=16,na='null')
print(verification)
dbDisconnect(con,shutdown=TRUE)
cat('Independent degree-duration e-MEC verification passed.\n')
