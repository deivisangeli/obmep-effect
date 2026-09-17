# Offline LOCAL prep. Matches the refreshed, OpenAlex-enriched degree-duration
# education population to the e-MEC institution catalog. It uses no network and
# must not be sent to SEDAP.
# Run from the repository root:
#   Rscript prep/building_external_data/degree_duration_emec_hierarchy.R
# Completed partitions are resumable only while all input and code checksums match.
library(DBI)
library(duckdb)
library(jsonlite)

root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh <- file.path(root,'Data/intermediate/revelio_br_cohort')
input_dir <- file.path(coh,'global_oa_hierarchy','education_parts')
emec_csv <- file.path(root,'Data/raw/PDA_Lista_Instituicoes_Ensino_Superior_do_Brasil_EMEC.csv')
out <- Sys.getenv('OBMEP_EMEC_DURATION_OUT',file.path(coh,'emec_hierarchy'))
sql_path <- 'prep/building_external_data/global_oa_hierarchy_sql.R'
script_path <- 'prep/building_external_data/degree_duration_emec_hierarchy.R'

input_paths <- sort(list.files(input_dir,pattern='[.]parquet$',full.names=TRUE))
stopifnot(dir.exists(input_dir),length(input_paths)==30L,
 length(unique(basename(input_paths)))==30L,file.exists(emec_csv),file.exists(sql_path))

dir.create(out,recursive=TRUE,showWarnings=FALSE)
for(d in c('checkpoints','decisions','candidate_evaluations','education_parts','spill'))
 dir.create(file.path(out,d),showWarnings=FALSE)

manifest_paths <- c(input_paths,emec_csv,sql_path)
inputs <- data.frame(path=manifest_paths,md5=unname(tools::md5sum(manifest_paths)))
stopifnot(!anyNA(inputs$md5))
input_manifest <- file.path(out,'input_manifest.rds')
if(file.exists(input_manifest)) {
 stopifnot(identical(inputs,readRDS(input_manifest)))
} else saveRDS(inputs,input_manifest)

code_manifest <- file.path(out,'implementation_manifest.rds')
implementation <- data.frame(path=c(script_path,sql_path),
 md5=unname(tools::md5sum(c(script_path,sql_path))))
if(file.exists(code_manifest)) {
 stopifnot(identical(implementation,readRDS(code_manifest)))
} else saveRDS(implementation,code_manifest)

# The entire input hierarchy is protected. The script has no output path inside it.
protected <- data.frame(path=input_paths,md5=unname(tools::md5sum(input_paths)))
con <- dbConnect(duckdb(),dbdir=file.path(out,'work.duckdb'))
on.exit(try(dbDisconnect(con,shutdown=TRUE),silent=TRUE),add=TRUE)
dbExecute(con,"SET memory_limit='8GB'")
dbExecute(con,'SET threads=4')
dbExecute(con,sprintf("SET temp_directory='%s'",gsub('\\\\','/',file.path(out,'spill'))))
input_glob <- gsub('\\\\','/',file.path(input_dir,'*.parquet'))
dbExecute(con,sprintf("CREATE OR REPLACE VIEW education AS SELECT * FROM read_parquet('%s')",input_glob))
source(sql_path)

catalog_artifacts <- file.path(out,c('catalog.parquet','aliases.parquet'))
phase <- file.path(out,'checkpoints','01_catalog.rds')
if(file.exists(phase)) stopifnot(identical(readRDS(phase),tools::md5sum(catalog_artifacts)))
if(!file.exists(phase)) {
 cat('Reading and validating the e-MEC institution catalog.\n')
 emec_path <- gsub('\\\\','/',emec_csv)
 dbExecute(con,sprintf("CREATE OR REPLACE TABLE emec_source AS
  SELECT * FROM read_csv('%s',header=true,all_varchar=true)",emec_path))
 expected_columns <- c('CODIGO_DA_IES','NOME_DA_IES','SIGLA','CATEGORIA_DA_IES',
  'COMUNITARIA','CONFESSIONAL','FILANTROPICA','ORGANIZACAO_ACADEMICA',
  'CODIGO_MUNICIPIO_IBGE','MUNICIPIO','UF','SITUACAO_IES')
 stopifnot(identical(dbGetQuery(con,'DESCRIBE emec_source')$column_name,expected_columns))
 dbExecute(con,"CREATE OR REPLACE TABLE catalog AS SELECT
  CAST(trim(CODIGO_DA_IES) AS BIGINT) co_ies,
  CAST(trim(CODIGO_DA_IES) AS VARCHAR) oa_id,
  NOME_DA_IES nome_ies,SIGLA sigla,CATEGORIA_DA_IES categoria_ies,
  COMUNITARIA comunitaria,CONFESSIONAL confessional,FILANTROPICA filantropica,
  ORGANIZACAO_ACADEMICA organizacao_academica,
  CODIGO_MUNICIPIO_IBGE codigo_municipio_ibge,MUNICIPIO municipio,UF uf,
  trim(SITUACAO_IES) situacao_ies,'BR' country_code,
  trim(regexp_replace(regexp_replace(NOME_DA_IES,'\\s*\\([^()]*\\)','','g'),'\\s+',' ','g')) cleaned_nome_ies
  FROM emec_source")
 dbExecute(con,"CREATE OR REPLACE TABLE aliases AS WITH raw AS (
  SELECT oa_id,co_ies,nome_ies alias,'primary' alias_kind FROM catalog
  UNION ALL SELECT oa_id,co_ies,cleaned_nome_ies,'cleaned' FROM catalog
  UNION ALL SELECT oa_id,co_ies,sigla,'acronym' FROM catalog
  WHERE sigla IS NOT NULL AND lower(trim(sigla))<>'null'
 ), folded AS (
  SELECT DISTINCT oa_id,co_ies,alias,alias_kind,strip_accents(lower(trim(alias))) alias_norm
  FROM raw
 ) SELECT *,alias_kind<>'acronym' name_eligible FROM folded
 WHERE alias_norm IS NOT NULL AND alias_norm<>'' AND
  (alias_kind<>'acronym' OR length(regexp_replace(alias_norm,'[^a-z0-9]','','g'))>=3)")
 dbExecute(con,"CREATE OR REPLACE TABLE acronym_owner_counts AS
  SELECT alias_norm,count(DISTINCT oa_id)::INTEGER owner_count
  FROM aliases WHERE alias_kind='acronym' GROUP BY alias_norm")
 dbExecute(con,"CREATE OR REPLACE TABLE stage2_generic_tokens AS SELECT token FROM (VALUES
  ('a'),('o'),('as'),('os'),('e'),('da'),('de'),('do'),('das'),('dos'),('em'),('para'),
  ('the'),('of'),('and'),('at'),('in'),('for'),('la'),('las'),('el'),('los'),('del'),('y'),
  ('university'),('universidade'),('universidad'),('universite'),('college'),('faculty'),
  ('faculdade'),('faculdades'),('facultad'),('center'),('centre'),('centro'),('institute'),
  ('instituto'),('institut'),('school'),('escola'),('education'),('educacao'),('ensino'),
  ('higher'),('superior'),('superiores')) t(token)")
 cat_stats <- dbGetQuery(con,"SELECT count(*) catalog_rows,count(DISTINCT co_ies) codes,
  count(*) FILTER(WHERE co_ies IS NULL) null_codes,
  count(*) FILTER(WHERE nome_ies IS NULL OR trim(nome_ies)='') blank_names
  FROM catalog")
 stopifnot(cat_stats$catalog_rows==4328L,cat_stats$codes==4328L,
  cat_stats$null_codes==0L,cat_stats$blank_names==0L,
  dbGetQuery(con,"SELECT count(*) n FROM catalog WHERE situacao_ies NOT IN ('Ativa','Extinta','Em atividade')")$n==0L,
  dbGetQuery(con,"SELECT count(*) n FROM aliases WHERE alias_kind='acronym' AND
   (lower(trim(alias))='null' OR length(regexp_replace(alias_norm,'[^a-z0-9]','','g'))<3)")$n==0L)
 public_catalog <- gsub('\\\\','/',file.path(out,'catalog.parquet'))
 public_aliases <- gsub('\\\\','/',file.path(out,'aliases.parquet'))
 dbExecute(con,sprintf("COPY (SELECT co_ies AS CO_IES,nome_ies,sigla,categoria_ies,
  comunitaria,confessional,filantropica,organizacao_academica,codigo_municipio_ibge,
  municipio,uf,situacao_ies,country_code,cleaned_nome_ies FROM catalog ORDER BY co_ies)
  TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",public_catalog))
 dbExecute(con,sprintf("COPY (SELECT co_ies AS CO_IES,alias,alias_kind,alias_norm,name_eligible
  FROM aliases ORDER BY co_ies,alias_kind,alias)
  TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",public_aliases))
 saveRDS(tools::md5sum(catalog_artifacts),phase)
}

crosswalk_artifacts <- file.path(out,paste0(c('raw_names','raw_links','crosswalk_evidence',
 'crosswalk','rsid_sets','raw_sets'),'.parquet'))
phase <- file.path(out,'checkpoints','02_crosswalk.rds')
if(file.exists(phase)) stopifnot(identical(readRDS(phase),tools::md5sum(crosswalk_artifacts)))
if(!file.exists(phase)) {
 cat('Building whole-name and segment evidence from degree-duration rows.\n')
 dbExecute(con,"CREATE OR REPLACE TABLE raw_names AS SELECT row_number() OVER(ORDER BY university_raw) raw_id,
  university_raw,strip_accents(lower(trim(university_raw))) raw_norm,strip_accents(trim(university_raw)) raw_case
  FROM (SELECT DISTINCT university_raw FROM education)")
 dbExecute(con,"CREATE OR REPLACE TABLE raw_tokens AS
  SELECT raw_id,raw_norm token,true whole FROM raw_names WHERE length(raw_norm)>=3
  UNION SELECT raw_id,trim(unnest(regexp_split_to_array(raw_norm,'[/()|]| - '))),false FROM raw_names")
 # SIGLA is deliberately absent here. It is selection evidence only, exactly as
 # OpenAlex acronyms are in the source hierarchy.
 dbExecute(con,"CREATE OR REPLACE TABLE raw_links AS
  SELECT t.raw_id,a.oa_id,bool_or(t.whole)::INTEGER c_norm_whole,
   bool_or(NOT t.whole)::INTEGER c_norm_segment,
   bool_or(r.university_raw=a.alias)::INTEGER c_exact,
   list(DISTINCT a.alias ORDER BY a.alias) supporting_catalog_names
  FROM raw_tokens t JOIN aliases a ON a.alias_norm=t.token AND a.name_eligible
  JOIN raw_names r USING(raw_id) WHERE length(t.token)>=3 GROUP BY t.raw_id,a.oa_id")
 dbExecute(con,"CREATE OR REPLACE TABLE raw_rsid_counts AS
  SELECT rsid,university_raw,count(*) source_rows,count(DISTINCT user_id) source_users
  FROM education GROUP BY rsid,university_raw")
 dbExecute(con,"CREATE OR REPLACE TABLE crosswalk_evidence AS
  SELECT c.rsid,c.university_raw,l.* EXCLUDE(raw_id),c.source_rows,c.source_users
  FROM raw_rsid_counts c JOIN raw_names r ON c.university_raw IS NOT DISTINCT FROM r.university_raw
  JOIN raw_links l USING(raw_id) WHERE c.rsid IS NOT NULL AND c.rsid<>2147483647")
 dbExecute(con,"CREATE OR REPLACE TABLE crosswalk AS SELECT rsid,oa_id,
  sum(source_rows)::BIGINT supporting_rows,count(*) supporting_raw_names,
  max(c_exact)::INTEGER c_exact,max(c_norm_whole)::INTEGER c_norm_whole,
  max(c_norm_segment)::INTEGER c_norm_segment FROM crosswalk_evidence GROUP BY rsid,oa_id")
 dbExecute(con,"CREATE OR REPLACE TABLE rsid_sets AS SELECT rsid,list(oa_id ORDER BY oa_id) candidate_ids
  FROM crosswalk GROUP BY rsid")
 dbExecute(con,"CREATE OR REPLACE TABLE raw_sets AS SELECT raw_id,list(oa_id ORDER BY oa_id) candidate_ids,
  max(c_exact)::INTEGER c_exact,max(c_norm_whole)::INTEGER c_norm_whole,
  max(c_norm_segment)::INTEGER c_norm_segment FROM raw_links GROUP BY raw_id")
 stopifnot(dbGetQuery(con,'SELECT count(*) n FROM crosswalk')$n==
  dbGetQuery(con,'SELECT count(DISTINCT (rsid,oa_id)) n FROM crosswalk_evidence')$n)
 artifacts <- list(
  list('raw_names',"SELECT * FROM raw_names"),
  list('raw_links',"SELECT raw_id,CAST(oa_id AS BIGINT) CO_IES,c_norm_whole,c_norm_segment,c_exact,supporting_catalog_names FROM raw_links"),
  list('crosswalk_evidence',"SELECT rsid,university_raw,CAST(oa_id AS BIGINT) CO_IES,c_norm_whole,c_norm_segment,c_exact,supporting_catalog_names,source_rows,source_users FROM crosswalk_evidence"),
  list('crosswalk',"SELECT rsid,CAST(oa_id AS BIGINT) CO_IES,supporting_rows,supporting_raw_names,c_exact,c_norm_whole,c_norm_segment FROM crosswalk"),
  list('rsid_sets',"SELECT rsid,list_transform(candidate_ids,x->CAST(x AS BIGINT)) candidate_codes FROM rsid_sets"),
  list('raw_sets',"SELECT raw_id,list_transform(candidate_ids,x->CAST(x AS BIGINT)) candidate_codes,c_exact,c_norm_whole,c_norm_segment FROM raw_sets"))
 for(z in artifacts) dbExecute(con,sprintf("COPY (%s) TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",
  z[[2]],gsub('\\\\','/',file.path(out,paste0(z[[1]],'.parquet')))))
 saveRDS(tools::md5sum(crosswalk_artifacts),phase)
}

population_artifacts <- file.path(out,'decision_inputs.parquet')
phase <- file.path(out,'checkpoints','03_population.rds')
if(file.exists(phase)) stopifnot(identical(readRDS(phase),tools::md5sum(population_artifacts)))
if(!file.exists(phase)) {
 cat('Collapsing reusable e-MEC decisions by raw text, country and candidate set.\n')
 dbExecute(con,"CREATE OR REPLACE TABLE entry_keys AS
  SELECT DISTINCT e.rsid,r.raw_id,e.global_oa_country_code country_code FROM education e
  JOIN raw_names r ON e.university_raw IS NOT DISTINCT FROM r.university_raw")
 dbExecute(con,"CREATE OR REPLACE TABLE key_candidates AS
  SELECT k.*,CASE WHEN k.rsid IS NOT NULL AND k.rsid<>2147483647 THEN s.candidate_ids ELSE f.candidate_ids END candidate_ids,
  CASE WHEN k.rsid IS NOT NULL AND k.rsid<>2147483647 THEN
   CASE WHEN s.rsid IS NULL THEN 'unmatched_known_rsid' ELSE 'rsid' END
   ELSE CASE WHEN f.raw_id IS NULL THEN 'unmatched_missing_rsid' ELSE 'raw_c_norm' END END match_route,
  CASE WHEN k.rsid IS NULL OR k.rsid=2147483647 THEN f.c_exact END fallback_c_exact,
  CASE WHEN k.rsid IS NULL OR k.rsid=2147483647 THEN f.c_norm_whole END fallback_c_norm_whole,
  CASE WHEN k.rsid IS NULL OR k.rsid=2147483647 THEN f.c_norm_segment END fallback_c_norm_segment
  FROM entry_keys k LEFT JOIN rsid_sets s USING(rsid) LEFT JOIN raw_sets f USING(raw_id)")
 dbExecute(con,"CREATE OR REPLACE TABLE decisions_input AS SELECT
  row_number() OVER(ORDER BY raw_id,country_code NULLS FIRST,candidate_ids) decision_id,
  k.*,r.university_raw,r.raw_norm,r.raw_case,
  list_filter(list_transform(regexp_split_to_array(r.raw_norm,'[/()|]| - '),x->trim(x)),x->length(x)>=3) raw_segments
  FROM (SELECT DISTINCT raw_id,country_code,candidate_ids FROM key_candidates) k JOIN raw_names r USING(raw_id)")
 dbExecute(con,"CREATE OR REPLACE TABLE key_decisions AS SELECT k.*,d.decision_id FROM key_candidates k
  JOIN decisions_input d ON k.raw_id=d.raw_id AND k.country_code IS NOT DISTINCT FROM d.country_code
   AND k.candidate_ids IS NOT DISTINCT FROM d.candidate_ids")
 decision_input_path <- gsub('\\\\','/',file.path(out,'decision_inputs.parquet'))
 dbExecute(con,sprintf("COPY (SELECT decision_id,raw_id,country_code,
  list_transform(candidate_ids,x->CAST(x AS BIGINT)) candidate_codes,
  university_raw,raw_norm,raw_case,raw_segments FROM decisions_input)
  TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",decision_input_path))
 saveRDS(tools::md5sum(population_artifacts),phase)
}

for(bucket in 0:63) {
 dest <- file.path(out,'decisions',sprintf('part_%02d.parquet',bucket))
 evdest <- file.path(out,'candidate_evaluations',sprintf('part_%02d.parquet',bucket))
 done <- file.path(out,'checkpoints',sprintf('decision_%02d.rds',bucket))
 if(file.exists(done)) {
  stopifnot(identical(readRDS(done),tools::md5sum(c(dest,evdest))))
  next
 }
 stopifnot(!file.exists(dest),!file.exists(evdest))
 cat('Selecting e-MEC candidates: partition',bucket+1,'of 64.\n')
 dbExecute(con,sprintf('CREATE OR REPLACE TEMP VIEW decision_batch AS SELECT * FROM decisions_input WHERE decision_id%%64=%d',bucket))
 unicode_scores <- dbGetQuery(con,hierarchy_unicode_pairs_sql)
 unicode_scores$jaro <- stringdist::stringsim(unicode_scores$raw_norm,unicode_scores$alias_norm,
  method='jw',p=0,useBytes=FALSE)
 dbWriteTable(con,'unicode_scores',unicode_scores,overwrite=TRUE,temporary=TRUE)
 dbExecute(con,paste('CREATE OR REPLACE TEMP TABLE evaluations AS',hierarchy_evaluation_sql))
 dbExecute(con,paste('CREATE OR REPLACE TEMP TABLE selector_selected AS',hierarchy_decision_sql))
 dbExecute(con,"CREATE OR REPLACE TEMP TABLE selector_ambiguity AS
  SELECT s.decision_id,coalesce(max(o.owner_count),0)::INTEGER selector_acronym_owner_count,
   coalesce(bool_and(s.raw_norm=o.alias_norm OR list_contains(s.raw_segments,o.alias_norm))
    FILTER(WHERE s.selection_stage=3),true) selector_acronym_context_ok
  FROM selector_selected s LEFT JOIN unnest(s.selected_evidence) e(x) ON true
  LEFT JOIN acronym_owner_counts o ON s.selection_stage=3 AND
   o.alias_norm=strip_accents(lower(trim(x.supporting_alias))) GROUP BY s.decision_id")
 dbExecute(con,"CREATE OR REPLACE TEMP TABLE stage2_residuals AS WITH raw_tokens AS (
  SELECT DISTINCT s.decision_id,t.token FROM selector_selected s
  CROSS JOIN unnest(regexp_split_to_array(s.raw_norm,'[^a-z0-9]+')) t(token)
  LEFT JOIN stage2_generic_tokens g USING(token)
  WHERE s.selection_stage=2 AND length(t.token)>=3 AND g.token IS NULL
 ), selected_tokens AS (
  SELECT DISTINCT s.decision_id,t.token FROM selector_selected s
  CROSS JOIN unnest(s.selected_evidence) e(x)
  CROSS JOIN unnest(regexp_split_to_array(strip_accents(lower(x.supporting_alias)),'[^a-z0-9]+')) t(token)
  WHERE s.selection_stage=2
 ) SELECT r.* FROM raw_tokens r LEFT JOIN selected_tokens t USING(decision_id,token)
 WHERE t.token IS NULL")
 dbExecute(con,"CREATE OR REPLACE TEMP TABLE stage2_conflicts AS SELECT DISTINCT r.decision_id
  FROM stage2_residuals r JOIN selector_selected s USING(decision_id)
  CROSS JOIN unnest(s.candidate_ids) u(oa_id)
  JOIN aliases a ON a.oa_id=u.oa_id AND a.name_eligible
  CROSS JOIN unnest(regexp_split_to_array(a.alias_norm,'[^a-z0-9]+')) t(token)
  WHERE NOT list_contains(s.selected_ids,u.oa_id) AND t.token=r.token")
 dbExecute(con,"CREATE OR REPLACE TEMP TABLE selector_stage2_context AS
  SELECT s.decision_id,(c.decision_id IS NULL) selector_stage2_context_ok
  FROM selector_selected s LEFT JOIN stage2_conflicts c USING(decision_id)")
 # The OpenAlex selector always chooses a maximum-score stage-4 candidate, even
 # when every name score is zero. That is useful as a diagnostic ranking but is
 # unsafe as an e-MEC code: a stray raw name under an rsid can otherwise assign
 # an unrelated campus to millions of rows. Preserve the provisional winner and
 # its evidence, but publish CO_IES only from stages 1-3.
 dbExecute(con,"CREATE OR REPLACE TEMP TABLE selected_base AS SELECT
  s.* EXCLUDE(selected_ids,selected_ids_pipe,selected_evidence,selected_count,selection_status),
  s.selected_ids selector_selected_ids,s.selected_evidence selector_selected_evidence,
  s.selected_count selector_selected_count,s.selection_status selector_selection_status,
  a.selector_acronym_owner_count,a.selector_acronym_context_ok,g.selector_stage2_context_ok,
  CASE WHEN s.selection_stage=4 OR (s.selection_stage=3 AND
   (a.selector_acronym_owner_count>1 OR NOT a.selector_acronym_context_ok)) OR
   (s.selection_stage=2 AND NOT g.selector_stage2_context_ok)
   THEN list_filter(s.selected_ids,x->false) ELSE s.selected_ids END selected_ids,
  CASE WHEN s.selection_stage=4 OR (s.selection_stage=3 AND
   (a.selector_acronym_owner_count>1 OR NOT a.selector_acronym_context_ok)) OR
   (s.selection_stage=2 AND NOT g.selector_stage2_context_ok)
   THEN NULL ELSE s.selected_ids_pipe END selected_ids_pipe,
  CASE WHEN s.selection_stage=4 OR (s.selection_stage=3 AND
   (a.selector_acronym_owner_count>1 OR NOT a.selector_acronym_context_ok)) OR
   (s.selection_stage=2 AND NOT g.selector_stage2_context_ok)
   THEN list_filter(s.selected_evidence,x->false) ELSE s.selected_evidence END selected_evidence,
  CASE WHEN s.selection_stage=4 OR (s.selection_stage=3 AND
   (a.selector_acronym_owner_count>1 OR NOT a.selector_acronym_context_ok)) OR
   (s.selection_stage=2 AND NOT g.selector_stage2_context_ok)
   THEN 0 ELSE s.selected_count END::INTEGER selected_count,
  CASE WHEN s.selection_stage=4 AND s.selected_count>0 THEN 'unresolved_fuzzy_unvalidated'
   WHEN s.selection_stage=3 AND a.selector_acronym_owner_count>1 THEN 'unresolved_ambiguous_acronym'
   WHEN s.selection_stage=3 AND NOT a.selector_acronym_context_ok THEN 'unresolved_contextual_acronym'
   WHEN s.selection_stage=2 AND NOT g.selector_stage2_context_ok THEN 'unresolved_containment_conflict'
   ELSE s.selection_status END selection_status
  FROM selector_selected s JOIN selector_ambiguity a USING(decision_id)
  JOIN selector_stage2_context g USING(decision_id)")
 dbExecute(con,"CREATE OR REPLACE TEMP TABLE active_counts AS
  SELECT s.decision_id,count(u.oa_id) FILTER(WHERE c.situacao_ies IN ('Ativa','Em atividade')) active_count,
   min(u.oa_id) FILTER(WHERE c.situacao_ies IN ('Ativa','Em atividade')) active_id,
   count(DISTINCT lower(trim(c.municipio))||'|'||upper(trim(c.uf))) FILTER(WHERE c.municipio IS NOT NULL
    AND lower(trim(c.municipio))<>'null' AND c.uf IS NOT NULL AND lower(trim(c.uf))<>'null') location_count,
   count(*) FILTER(WHERE c.municipio IS NULL OR lower(trim(c.municipio))='null'
    OR c.uf IS NULL OR lower(trim(c.uf))='null') location_missing
  FROM selected_base s LEFT JOIN unnest(s.selected_ids) u(oa_id) ON true
  LEFT JOIN catalog c ON c.oa_id=u.oa_id GROUP BY s.decision_id")
 dbExecute(con,"CREATE OR REPLACE TEMP TABLE selected AS WITH resolved AS (
  SELECT s.*,s.selected_ids pre_status_selected_ids,s.selected_evidence pre_status_selected_evidence,
   s.selected_count pre_status_selected_count,s.selection_status pre_status_selection_status,
   CASE WHEN s.selected_count>1 AND a.active_count=1 AND a.location_count=1 AND a.location_missing=0
    THEN [a.active_id] ELSE s.selected_ids END final_ids,
   CASE WHEN s.selected_count>1 AND a.active_count=1 AND a.location_count=1 AND a.location_missing=0
    THEN 1 ELSE 0 END active_preference
  FROM selected_base s JOIN active_counts a USING(decision_id)
 ) SELECT * EXCLUDE(selected_ids,selected_ids_pipe,selected_evidence,selected_count,selection_status,final_ids),
  final_ids selected_ids,
  list_filter(pre_status_selected_evidence,x->list_contains(final_ids,x.oa_id)) selected_evidence,
  coalesce(len(final_ids),0)::INTEGER selected_count,
  CASE WHEN active_preference=1 THEN 'single_active_preference' ELSE selection_status END selection_status
  FROM resolved")
 stopifnot(dbGetQuery(con,"SELECT count(*) n FROM selected WHERE selected_count>0 AND
  NOT list_has_all(candidate_ids,selected_ids)")$n==0,
  dbGetQuery(con,'SELECT count(*) n FROM selected')$n==dbGetQuery(con,'SELECT count(*) n FROM decision_batch')$n)
 evout <- gsub('\\\\','/',evdest)
 dbExecute(con,sprintf("COPY (SELECT decision_id,CAST(oa_id AS BIGINT) CO_IES,
  candidate_stage,country_match,jw_similarity,score,stage_alias,stage_alias_kind,similarity_alias
  FROM evaluations) TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)",evout))
 dout <- gsub('\\\\','/',dest)
 dbExecute(con,sprintf("COPY (SELECT decision_id,raw_id,country_code,
  list_transform(candidate_ids,x->CAST(x AS BIGINT)) candidate_codes,
  university_raw,raw_norm,raw_case,raw_segments,selection_stage,
  list_transform(selector_selected_ids,x->CAST(x AS BIGINT)) selector_selected_codes,
  list_transform(selector_selected_evidence,x->struct_pack(
   co_ies:=CAST(x.oa_id AS BIGINT),supporting_alias:=x.supporting_alias,alias_kind:=x.alias_kind,
   country_match:=x.country_match,jw_similarity:=x.jw_similarity,score:=x.score)) selector_selected_evidence,
  selector_selected_count,selector_selection_status,
  selector_acronym_owner_count,
  selector_acronym_context_ok,
  selector_stage2_context_ok,
  list_transform(pre_status_selected_ids,x->CAST(x AS BIGINT)) pre_status_selected_codes,
  list_transform(pre_status_selected_evidence,x->struct_pack(
   co_ies:=CAST(x.oa_id AS BIGINT),supporting_alias:=x.supporting_alias,alias_kind:=x.alias_kind,
   country_match:=x.country_match,jw_similarity:=x.jw_similarity,score:=x.score)) pre_status_selected_evidence,
  pre_status_selected_count,pre_status_selection_status,
  list_transform(selected_ids,x->CAST(x AS BIGINT)) selected_codes,
  list_transform(selected_evidence,x->struct_pack(
   co_ies:=CAST(x.oa_id AS BIGINT),supporting_alias:=x.supporting_alias,alias_kind:=x.alias_kind,
   country_match:=x.country_match,jw_similarity:=x.jw_similarity,score:=x.score)) selected_evidence,
  selected_count,selection_status,active_preference
  FROM selected ORDER BY decision_id) TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)",dout))
 saveRDS(tools::md5sum(c(dest,evdest)),done)
}

decision_glob <- gsub('\\\\','/',file.path(out,'decisions','*.parquet'))
dbExecute(con,sprintf("CREATE OR REPLACE VIEW decisions_public AS SELECT * FROM read_parquet('%s')",decision_glob))

phase <- file.path(out,'checkpoints','04_education.rds')
if(!file.exists(phase)) {
 cat('Writing OpenAlex-enriched rows with e-MEC decisions.\n')
 dbExecute(con,"CREATE OR REPLACE TABLE candidate_sets AS SELECT DISTINCT candidate_ids,
  array_to_string(candidate_ids,'|') candidate_ids_pipe FROM decisions_input WHERE len(candidate_ids)>0")
 dbExecute(con,"CREATE OR REPLACE TABLE candidate_details AS SELECT s.candidate_ids_pipe,
  list(struct_pack(co_ies:=c.co_ies,nome_ies:=c.nome_ies,sigla:=c.sigla,
   situacao_ies:=c.situacao_ies,municipio:=c.municipio,uf:=c.uf)
   ORDER BY c.co_ies) candidates
  FROM candidate_sets s CROSS JOIN unnest(s.candidate_ids) u(oa_id)
  JOIN catalog c ON c.oa_id=u.oa_id GROUP BY 1")
 dbExecute(con,"CREATE OR REPLACE TABLE selected_details AS SELECT d.decision_id,
  list(c.nome_ies ORDER BY c.co_ies) selected_names
  FROM decisions_public d CROSS JOIN unnest(d.selected_codes) u(co_ies)
  JOIN catalog c USING(co_ies) GROUP BY d.decision_id")
 for(i in seq_along(input_paths)) {
  src <- input_paths[i]
  dest <- file.path(out,'education_parts',basename(src))
  done <- file.path(out,'checkpoints',sprintf('education_%02d.rds',i))
  if(file.exists(done)) {stopifnot(identical(readRDS(done),tools::md5sum(dest)));next}
  stopifnot(!file.exists(dest))
  dbExecute(con,sprintf("CREATE OR REPLACE TEMP VIEW input_part AS SELECT * FROM read_parquet('%s')",
   gsub('\\\\','/',src)))
  dbExecute(con,sprintf("COPY (SELECT e.*,k.decision_id emec_decision_id,
   k.match_route emec_match_route,k.fallback_c_exact emec_fallback_c_exact,
   k.fallback_c_norm_whole emec_fallback_c_norm_whole,
   k.fallback_c_norm_segment emec_fallback_c_norm_segment,
   list_transform(k.candidate_ids,x->CAST(x AS BIGINT)) emec_candidate_codes,
   c.candidates emec_candidates,d.selector_selected_codes emec_selector_selected_codes,
   d.selector_selected_count emec_selector_selected_count,
   d.selector_selection_status emec_selector_selection_status,
   d.selector_acronym_owner_count emec_selector_acronym_owner_count,
   d.selector_acronym_context_ok emec_selector_acronym_context_ok,
   d.selector_stage2_context_ok emec_selector_stage2_context_ok,
   d.selector_selected_evidence emec_selector_selected_evidence,
   d.pre_status_selected_codes emec_pre_status_selected_codes,
   d.pre_status_selected_count emec_pre_status_selected_count,
   d.pre_status_selection_status emec_pre_status_selection_status,
   d.selected_codes emec_selected_codes,n.selected_names emec_selected_names,
   d.selected_count emec_selected_count,d.selection_stage emec_selection_stage,
   d.selection_status emec_selection_status,d.active_preference emec_active_preference,
   d.selected_evidence emec_selected_evidence,
   CASE WHEN d.selected_count=1 THEN d.selected_codes[1] END AS CO_IES
   FROM input_part e JOIN raw_names r ON e.university_raw IS NOT DISTINCT FROM r.university_raw
   JOIN key_decisions k ON k.rsid IS NOT DISTINCT FROM e.rsid AND k.raw_id=r.raw_id
    AND k.country_code IS NOT DISTINCT FROM e.global_oa_country_code
   JOIN decisions_public d USING(decision_id)
   LEFT JOIN candidate_details c ON c.candidate_ids_pipe=array_to_string(k.candidate_ids,'|')
   LEFT JOIN selected_details n USING(decision_id)
   ORDER BY e.source_row) TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)",gsub('\\\\','/',dest)))
  cols <- dbGetQuery(con,'DESCRIBE input_part')$column_name
  mismatch <- paste(sprintf('e."%1$s" IS DISTINCT FROM n."%1$s"',cols),collapse=' OR ')
  stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM input_part e FULL JOIN read_parquet('%s') n
   USING(source_file,source_row) WHERE %s",gsub('\\\\','/',dest),mismatch))$n==0)
  saveRDS(tools::md5sum(dest),done)
  cat('Preserved and verified input partition',i,'of',length(input_paths),'\n')
 }
 saveRDS(TRUE,phase)
}

education_glob <- gsub('\\\\','/',file.path(out,'education_parts','*.parquet'))
dbExecute(con,sprintf("CREATE OR REPLACE VIEW enriched AS SELECT * FROM read_parquet('%s')",education_glob))
dbExecute(con,"CREATE OR REPLACE TABLE decision_weights AS SELECT emec_decision_id decision_id,
 count(*) education_rows,count(DISTINCT user_id) users FROM enriched GROUP BY 1")
crosswalk_path <- gsub('\\\\','/',file.path(out,'degree_duration_emec_crosswalk.parquet'))
dbExecute(con,sprintf("COPY (SELECT d.decision_id emec_decision_id,d.university_raw,
 d.country_code,d.candidate_codes emec_candidate_codes,
 d.selector_selected_codes emec_selector_selected_codes,
 d.selector_selected_count emec_selector_selected_count,
 d.selector_selection_status emec_selector_selection_status,
 d.selector_acronym_owner_count emec_selector_acronym_owner_count,
 d.selector_acronym_context_ok emec_selector_acronym_context_ok,
 d.selector_stage2_context_ok emec_selector_stage2_context_ok,
 d.selector_selected_evidence emec_selector_selected_evidence,
 d.pre_status_selected_codes emec_pre_status_selected_codes,
 d.pre_status_selected_count emec_pre_status_selected_count,
 d.pre_status_selection_status emec_pre_status_selection_status,
 d.selected_codes emec_selected_codes,d.selected_count emec_selected_count,
 d.selection_stage emec_selection_stage,d.selection_status emec_selection_status,
 d.active_preference emec_active_preference,d.selected_evidence emec_selected_evidence,
 CASE WHEN d.selected_count=1 THEN d.selected_codes[1] END CO_IES,
 w.education_rows,w.users FROM decisions_public d JOIN decision_weights w USING(decision_id)
 ORDER BY d.decision_id) TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",crosswalk_path))

cat('Reconciling the e-MEC hierarchy.\n')
population <- dbGetQuery(con,"SELECT count(*) education_rows,count(DISTINCT user_id) users,
 count(DISTINCT (source_file,source_row)) physical_keys,
 count(*) FILTER(WHERE emec_selected_count=1) single_rows,
 count(*) FILTER(WHERE emec_pre_status_selected_count>1 AND emec_active_preference=1) active_preference_rows,
 count(*) FILTER(WHERE emec_selected_count>1) tied_rows,
 count(*) FILTER(WHERE emec_selected_count=0) unresolved_rows FROM enriched")
stopifnot(population$education_rows==19710307L,population$users==8901904L,
 population$physical_keys==population$education_rows)

bad_sets <- dbGetQuery(con,"SELECT count(*) n FROM decisions_public WHERE
 (selector_selected_count<>coalesce(len(selector_selected_codes),0)) OR
 (pre_status_selected_count<>coalesce(len(pre_status_selected_codes),0)) OR
 (selected_count<>coalesce(len(selected_codes),0)) OR
 (selector_selected_count>0 AND NOT list_has_all(candidate_codes,selector_selected_codes)) OR
 (pre_status_selected_count>0 AND NOT list_has_all(selector_selected_codes,pre_status_selected_codes)) OR
 (selected_count>0 AND NOT list_has_all(pre_status_selected_codes,selected_codes))")$n
bad_scalar <- dbGetQuery(con,"SELECT count(*) n FROM enriched WHERE
 (CO_IES IS NOT NULL) IS DISTINCT FROM (emec_selected_count=1) OR
 (emec_selected_count=1 AND CO_IES<>emec_selected_codes[1])")$n
bad_catalog <- dbGetQuery(con,"SELECT count(*) n FROM (
 SELECT unnest(candidate_codes) co_ies FROM decisions_public
 UNION SELECT unnest(selector_selected_codes) FROM decisions_public
 UNION SELECT unnest(pre_status_selected_codes) FROM decisions_public
 UNION SELECT unnest(selected_codes) FROM decisions_public) x
 LEFT JOIN catalog c USING(co_ies) WHERE c.co_ies IS NULL")$n
bad_active <- dbGetQuery(con,"WITH a AS (SELECT d.decision_id,d.active_preference,
 d.pre_status_selected_count,d.selected_count,d.pre_status_selected_codes,d.selected_codes,
 count(u.co_ies) FILTER(WHERE c.situacao_ies IN ('Ativa','Em atividade')) active_count,
 count(DISTINCT lower(trim(c.municipio))||'|'||upper(trim(c.uf))) FILTER(WHERE c.municipio IS NOT NULL
  AND lower(trim(c.municipio))<>'null' AND c.uf IS NOT NULL AND lower(trim(c.uf))<>'null') location_count,
 count(*) FILTER(WHERE c.municipio IS NULL OR lower(trim(c.municipio))='null'
  OR c.uf IS NULL OR lower(trim(c.uf))='null') location_missing
 FROM decisions_public d LEFT JOIN unnest(d.pre_status_selected_codes) u(co_ies) ON true
 LEFT JOIN catalog c USING(co_ies) GROUP BY ALL)
 SELECT count(*) n FROM a WHERE
 (active_preference=1 AND (pre_status_selected_count<=1 OR selected_count<>1 OR active_count<>1
  OR location_count<>1 OR location_missing<>0)) OR
 (pre_status_selected_count>1 AND active_count=1 AND location_count=1 AND location_missing=0
  AND active_preference<>1) OR
 (active_preference=0 AND pre_status_selected_codes IS DISTINCT FROM selected_codes)")$n
bad_score_publish <- dbGetQuery(con,"SELECT count(*) n FROM decisions_public WHERE
 selection_stage=4 AND (pre_status_selected_count<>0 OR selected_count<>0 OR active_preference<>0)")$n
bad_acronym_publish <- dbGetQuery(con,"SELECT count(*) n FROM decisions_public WHERE
 selection_stage=3 AND (selector_acronym_owner_count>1 OR NOT selector_acronym_context_ok) AND
 (pre_status_selected_count<>0 OR selected_count<>0 OR active_preference<>0)")$n
bad_containment_publish <- dbGetQuery(con,"SELECT count(*) n FROM decisions_public WHERE
 selection_stage=2 AND NOT selector_stage2_context_ok AND
 (pre_status_selected_count<>0 OR selected_count<>0 OR active_preference<>0)")$n
public_schema <- dbGetQuery(con,sprintf("DESCRIBE SELECT * FROM read_parquet('%s')",decision_glob))
stopifnot(bad_sets==0L,bad_scalar==0L,bad_catalog==0L,bad_active==0L,bad_score_publish==0L,
 bad_acronym_publish==0L,
 bad_containment_publish==0L,
 !any(grepl('oa_id',paste(public_schema$column_name,public_schema$column_type),ignore.case=TRUE)),
 identical(inputs$md5,unname(tools::md5sum(inputs$path))),
 identical(protected$md5,unname(tools::md5sum(protected$path))))

routes <- dbGetQuery(con,"SELECT emec_match_route route,count(*) education_rows,
 count(DISTINCT user_id) users FROM enriched GROUP BY 1 ORDER BY 1")
stages <- dbGetQuery(con,"SELECT emec_selection_stage stage,emec_selection_status status,
 count(*) education_rows,count(DISTINCT emec_decision_id) decisions,count(DISTINCT user_id) users
 FROM enriched GROUP BY 1,2 ORDER BY 1,2")
country <- dbGetQuery(con,"SELECT coalesce(global_oa_country_code,'(missing)') source_country,
 count(*) education_rows,count(*) FILTER(WHERE CO_IES IS NOT NULL) matched_rows,
 count(DISTINCT user_id) users FROM enriched GROUP BY 1 ORDER BY education_rows DESC")
levels <- dbGetQuery(con,"SELECT CASE WHEN coalesce(degree,'empty')='empty' AND degree_matches_laxed=1
 THEN 'bachelor' ELSE coalesce(ranked_level,'other') END effective_level,
 count(*) education_rows,count(*) FILTER(WHERE CO_IES IS NOT NULL) matched_rows,
 count(DISTINCT user_id) users FROM enriched GROUP BY 1 ORDER BY 1")
catalog_stats <- dbGetQuery(con,"SELECT count(*) catalog_rows,count(DISTINCT co_ies) codes,
 count(DISTINCT strip_accents(lower(trim(nome_ies)))) folded_names,
 count(*) FILTER(WHERE situacao_ies IN ('Ativa','Em atividade')) active_codes,
 count(*) FILTER(WHERE situacao_ies='Extinta') extinct_codes FROM catalog")
name_collisions <- dbGetQuery(con,"WITH x AS (SELECT strip_accents(lower(trim(nome_ies))) name_norm,
 count(*) codes,count(*) FILTER(WHERE situacao_ies IN ('Ativa','Em atividade')) active_codes
 FROM catalog GROUP BY 1 HAVING count(*)>1) SELECT count(*) collision_names,
 max(codes) maximum_codes,sum(CASE WHEN active_codes=1 THEN 1 ELSE 0 END)::BIGINT sole_active_names FROM x")

output_paths <- c(list.files(file.path(out,'education_parts'),pattern='[.]parquet$',full.names=TRUE),
 list.files(file.path(out,'decisions'),pattern='[.]parquet$',full.names=TRUE),
 list.files(file.path(out,'candidate_evaluations'),pattern='[.]parquet$',full.names=TRUE),
 file.path(out,c('catalog.parquet','aliases.parquet','raw_names.parquet','raw_links.parquet',
  'crosswalk_evidence.parquet','crosswalk.parquet','rsid_sets.parquet','raw_sets.parquet',
  'decision_inputs.parquet','degree_duration_emec_crosswalk.parquet')))
report <- list(completed_utc=format(Sys.time(),tz='UTC',usetz=TRUE),
 method=list(population='OpenAlex-enriched refreshed degree-duration education population',
  decision_key='Original university_raw, global OpenAlex country and e-MEC candidate set',
  candidate_supply='Official and cleaned e-MEC names only; SIGLA is selection-only',
  selection='Normalized equality, contained name and catalog-unique supplied acronyms publish CO_IES; ambiguous acronyms and 0.2 country plus 0.8 Jaro-Winkler are provisional diagnostics only',
  country_limit='All candidates are BR, so country cannot rank candidates within e-MEC',
  score_stage_limit='Stage 4 never publishes CO_IES and never enters the active-status tie-break',
  acronym_limit='A stage-3 acronym with multiple owners anywhere in the e-MEC catalog never publishes CO_IES',
  acronym_context_limit='A stage-3 acronym publishes only as the whole raw value or a complete delimited segment',
  containment_limit='Stage-2 proposals are diagnostic when leftover distinctive raw tokens identify another candidate',
  ties='Ties in stages 1-3 are resolved only when exactly one winner is active and all tied codes share one nonmissing municipality/UF'),
 inputs=inputs,catalog=catalog_stats,name_collisions=name_collisions,population=population,
 routes=routes,stages=stages,country=country,effective_levels=levels,
 protected_inputs=protected,outputs=data.frame(path=output_paths,md5=unname(tools::md5sum(output_paths))),
 implementation=implementation,
 validation=list(source_rows_and_users=TRUE,physical_keys_unique=TRUE,
  upstream_values_preserved=TRUE,selected_codes_subset_candidates=TRUE,
  selected_codes_in_catalog=TRUE,scalar_code_iff_unique=TRUE,active_preference_exact=TRUE,
  no_scalar_from_score_stage=TRUE,
  no_scalar_from_ambiguous_acronym=TRUE,
  no_scalar_from_contextual_acronym=TRUE,
  no_scalar_from_containment_conflict=TRUE,
  no_internal_oa_id_fields=TRUE,inputs_unchanged=TRUE))
write_json(report,file.path(out,'degree_duration_emec_hierarchy_report.json'),
 pretty=TRUE,auto_unbox=TRUE,dataframe='rows',digits=16,na='null')
dbDisconnect(con,shutdown=TRUE)
cat('Completed degree-duration e-MEC hierarchy:',out,'\n')
print(population)
print(routes)
