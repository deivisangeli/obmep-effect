# Offline LOCAL prep. Adds conservative regex/catalog recovery to the published
# degree-duration e-MEC hierarchy. It uses no network and must not be sent to SEDAP.
# Run from the repository root after degree_duration_emec_hierarchy.R.
library(DBI)
library(duckdb)
library(jsonlite)

root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh <- file.path(root,'Data/intermediate/revelio_br_cohort')
base <- Sys.getenv('OBMEP_EMEC_DURATION_BASE',file.path(coh,'emec_hierarchy'))
out <- Sys.getenv('OBMEP_EMEC_DURATION_OUT',file.path(coh,'emec_hierarchy_regex_v1'))
script_path <- 'prep/building_external_data/degree_duration_emec_regex_recovery.R'
registry_path <- 'prep/building_external_data/degree_duration_emec_regex_aliases.csv'

base_education <- sort(list.files(file.path(base,'education_parts'),pattern='[.]parquet$',full.names=TRUE))
base_decisions <- sort(list.files(file.path(base,'decisions'),pattern='[.]parquet$',full.names=TRUE))
base_catalog <- file.path(base,'catalog.parquet')
base_aliases <- file.path(base,'aliases.parquet')
stopifnot(length(base_education)==30L,length(base_decisions)==64L,
 file.exists(base_catalog),file.exists(base_aliases),file.exists(registry_path))

dir.create(out,recursive=TRUE,showWarnings=FALSE)
for(d in c('checkpoints','decisions','education_parts','spill'))
 dir.create(file.path(out,d),showWarnings=FALSE)

input_paths <- c(base_education,base_decisions,base_catalog,base_aliases,registry_path)
inputs <- data.frame(path=input_paths,md5=unname(tools::md5sum(input_paths)))
stopifnot(!anyNA(inputs$md5))
input_manifest <- file.path(out,'input_manifest.rds')
if(file.exists(input_manifest)) stopifnot(identical(inputs,readRDS(input_manifest))) else saveRDS(inputs,input_manifest)
implementation <- data.frame(path=c(script_path,registry_path),
 md5=unname(tools::md5sum(c(script_path,registry_path))))
code_manifest <- file.path(out,'implementation_manifest.rds')
if(file.exists(code_manifest)) stopifnot(identical(implementation,readRDS(code_manifest))) else saveRDS(implementation,code_manifest)

protected <- data.frame(path=input_paths,md5=unname(tools::md5sum(input_paths)))
con <- dbConnect(duckdb(),dbdir=file.path(out,'work.duckdb'))
on.exit(try(dbDisconnect(con,shutdown=TRUE),silent=TRUE),add=TRUE)
dbExecute(con,"SET memory_limit='8GB'")
dbExecute(con,'SET threads=2')
dbExecute(con,'SET preserve_insertion_order=false')
dbExecute(con,sprintf("SET temp_directory='%s'",gsub('\\\\','/',file.path(out,'spill'))))

education_glob <- gsub('\\\\','/',file.path(base,'education_parts','*.parquet'))
decision_glob <- gsub('\\\\','/',file.path(base,'decisions','*.parquet'))
dbExecute(con,sprintf("CREATE OR REPLACE VIEW base_enriched AS SELECT * FROM read_parquet('%s')",education_glob))
dbExecute(con,sprintf("CREATE OR REPLACE VIEW base_decisions AS SELECT * FROM read_parquet('%s')",decision_glob))
dbExecute(con,sprintf("CREATE OR REPLACE VIEW catalog_public AS SELECT * FROM read_parquet('%s')",gsub('\\\\','/',base_catalog)))
dbExecute(con,sprintf("CREATE OR REPLACE VIEW aliases_public AS SELECT * FROM read_parquet('%s')",gsub('\\\\','/',base_aliases)))

recovery_artifacts <- file.path(out,c('regex_alias_registry_resolved.parquet','regex_proposals.parquet',
 'regex_decisions.parquet','degree_duration_emec_crosswalk.parquet'))
phase <- file.path(out,'checkpoints','01_recovery.rds')
if(file.exists(phase)) stopifnot(identical(readRDS(phase),tools::md5sum(recovery_artifacts)))
if(!file.exists(phase)) {
 cat('Resolving reusable regex rules against the current active e-MEC catalog.\n')
 dbExecute(con,"CREATE OR REPLACE TABLE catalog AS SELECT *,CAST(CO_IES AS VARCHAR) oa_id,
  trim(regexp_replace(regexp_replace(strip_accents(lower(nome_ies)),'[^a-z0-9]+',' ','g'),' +',' ','g')) name_regex_norm,
  trim(regexp_replace(regexp_replace(strip_accents(lower(coalesce(municipio,''))),'[^a-z0-9]+',' ','g'),' +',' ','g')) municipio_norm
  FROM catalog_public")
 dbExecute(con,"CREATE OR REPLACE TABLE catalog_active AS SELECT * FROM catalog
  WHERE situacao_ies IN ('Ativa','Em atividade')")
 dbExecute(con,sprintf("CREATE OR REPLACE TABLE regex_registry AS
  SELECT CAST(priority AS INTEGER) priority,* EXCLUDE(priority)
  FROM read_csv('%s',header=true,all_varchar=true)",gsub('\\\\','/',registry_path)))
 expected_registry <- c('priority','rule_id','source_raw_regex','source_name_regex','source_name_policy',
  'target_name_regex','target_municipality_regex','target_uf','notes')
 stopifnot(setequal(dbGetQuery(con,'DESCRIBE regex_registry')$column_name,expected_registry),
  dbGetQuery(con,"SELECT count(*) n FROM regex_registry WHERE source_name_policy NOT IN
   ('required_match','if_present_match','ignore')")$n==0L)
 dbExecute(con,"CREATE OR REPLACE TABLE regex_registry_resolved AS SELECT r.*,
  min(c.CO_IES)::BIGINT target_code,min(c.nome_ies) target_name,min(c.municipio) target_municipio,
  min(c.uf) target_catalog_uf,count(DISTINCT c.CO_IES)::INTEGER target_count
  FROM regex_registry r LEFT JOIN catalog_active c
   ON regexp_matches(c.name_regex_norm,r.target_name_regex)
   AND regexp_matches(c.municipio_norm,r.target_municipality_regex)
   AND upper(c.uf)=upper(r.target_uf) GROUP BY ALL")
 bad_registry <- dbGetQuery(con,"SELECT rule_id,target_count FROM regex_registry_resolved
  WHERE target_count<>1 ORDER BY rule_id")
 if(nrow(bad_registry)>0) {print(bad_registry);stop('Every registry rule must resolve to exactly one active CO_IES.')}
 dbExecute(con,sprintf("COPY (SELECT * EXCLUDE(target_count) FROM regex_registry_resolved ORDER BY priority,rule_id)
  TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",
  gsub('\\\\','/',recovery_artifacts[1])))

 dbExecute(con,"CREATE OR REPLACE TABLE recovery_generic_tokens AS SELECT token FROM (VALUES
  ('a'),('o'),('as'),('os'),('e'),('da'),('de'),('do'),('das'),('dos'),('em'),('para'),('por'),
  ('the'),('of'),('and'),('at'),('in'),('for'),('from'),('la'),('las'),('el'),('los'),('del'),('y'),
  ('university'),('universidade'),('universidad'),('universite'),('college'),('faculty'),('faculdade'),
  ('faculdades'),('facultad'),('center'),('centre'),('centro'),('institute'),('instituto'),('institut'),
  ('school'),('escola'),('education'),('educacao'),('ensino'),('higher'),('superior'),('superiores'),
  ('technology'),('tecnologia'),('science'),('sciences'),('ciencia'),('ciencias'),('federal'),('estadual'),
  ('state'),('foundation'),('fundacao'),('grupo'),('educacional'),('brasil'),('brazil'),('mba'),('phd'),
  ('bba'),('alumni'),('campus'),('colegio'),('academy'),('academia')) t(token)")
 dbExecute(con,"CREATE OR REPLACE TABLE catalog_brand_tokens AS WITH tokenized AS (
  SELECT c.oa_id,c.CO_IES,c.nome_ies,c.municipio_norm,c.uf,t.token
  FROM catalog_active c CROSS JOIN unnest(regexp_split_to_array(c.name_regex_norm,' +')) t(token)
 ), kept AS (SELECT t.* FROM tokenized t LEFT JOIN recovery_generic_tokens g USING(token)
  WHERE g.token IS NULL AND length(t.token)>=3 AND
   NOT list_contains(regexp_split_to_array(t.municipio_norm,' +'),t.token))
 SELECT DISTINCT * FROM kept
 UNION SELECT DISTINCT * EXCLUDE(token),substr(token,4) token FROM kept
  WHERE regexp_matches(token,'^uni[a-z0-9]{3,}$')")
 dbExecute(con,"CREATE OR REPLACE TABLE brand_token_owners AS SELECT token,
  count(DISTINCT oa_id)::INTEGER active_owner_count FROM catalog_brand_tokens GROUP BY token")
 dbExecute(con,"CREATE OR REPLACE TABLE active_acronyms AS SELECT a.alias_norm,
  min(a.CO_IES)::BIGINT target_code,min(c.nome_ies) target_name,
  count(DISTINCT a.CO_IES)::INTEGER active_owner_count
  FROM aliases_public a JOIN catalog_active c USING(CO_IES)
  WHERE a.alias_kind='acronym' GROUP BY a.alias_norm HAVING count(DISTINCT a.CO_IES)=1")

 cat('Building the extended decision grain and catalog-derived proposals.\n')
 dbExecute(con,"CREATE OR REPLACE TABLE recovery_decisions AS WITH keys AS (
  SELECT DISTINCT emec_decision_id base_decision_id,university_name,university_country
  FROM base_enriched
 ), folded AS (SELECT row_number() OVER(ORDER BY k.base_decision_id,k.university_name NULLS FIRST,
   k.university_country NULLS FIRST) decision_id,k.*,b.* EXCLUDE(decision_id,university_raw,raw_norm),
   b.university_raw,
   trim(regexp_replace(regexp_replace(strip_accents(lower(coalesce(b.university_raw,''))),
    '[^a-z0-9]+',' ','g'),' +',' ','g')) raw_regex_norm,
   trim(regexp_replace(regexp_replace(strip_accents(lower(coalesce(k.university_name,''))),
    '[^a-z0-9]+',' ','g'),' +',' ','g')) name_regex_norm
  FROM keys k JOIN base_decisions b ON b.decision_id=k.base_decision_id
 ), translated AS (SELECT *,
  trim(replace(replace(replace(replace(' '||
  regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(raw_regex_norm,
   '^federal university foundation of (.+)$','fundacao universidade federal de \\1'),
   '^federal university of (.+)$','universidade federal de \\1'),
   '^state university of (.+)$','universidade do estado de \\1'),
   '^university centre of the (.+)$','centro universitario do \\1'),
   '^university center of the (.+)$','centro universitario do \\1'),
   '^(.+) university centre of (.+)$','centro universitario \\1 \\2'),
   '^(.+) university center of (.+)$','centro universitario \\1 \\2'),
   '^(.+) faculty of (.+)$','faculdade \\1 de \\2'),
   '^(.+) institute$','instituto \\1'),
   '^(.+) university$','universidade \\1')||' ',
   ' south of ',' sul de '),' israeli ',' israelita '),' health ',' saude '),' sciences ',' ciencias ')) raw_translated_norm,
  trim(replace(replace(replace(replace(' '||
  regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(regexp_replace(name_regex_norm,
   '^federal university foundation of (.+)$','fundacao universidade federal de \\1'),
   '^federal university of (.+)$','universidade federal de \\1'),
   '^state university of (.+)$','universidade do estado de \\1'),
   '^university centre of the (.+)$','centro universitario do \\1'),
   '^university center of the (.+)$','centro universitario do \\1'),
   '^(.+) university centre of (.+)$','centro universitario \\1 \\2'),
   '^(.+) university center of (.+)$','centro universitario \\1 \\2'),
   '^(.+) faculty of (.+)$','faculdade \\1 de \\2'),
   '^(.+) institute$','instituto \\1'),
   '^(.+) university$','universidade \\1')||' ',
   ' south of ',' sul de '),' israeli ',' israelita '),' health ',' saude '),' sciences ',' ciencias ')) name_translated_norm
  FROM folded)
 SELECT *,regexp_matches(raw_regex_norm||' '||name_regex_norm,
  '(^| )(faculdade|faculdades|universidade|centro universitario|centro educacional|instituto de|instituto federal)( |$)')
  source_has_portuguese_form,
  CASE WHEN (country_code IS NULL OR upper(country_code)='BR') AND
   (university_country IS NULL OR strip_accents(lower(trim(university_country))) IN ('br','brazil','brasil'))
   THEN true ELSE false END recovery_country_ok FROM translated")

 dbExecute(con,"CREATE OR REPLACE TABLE alias_proposals AS SELECT d.decision_id,r.target_code,
  r.rule_id,'regex_alias' rule_family,r.priority,
  CASE WHEN r.source_name_policy='ignore' THEN 'university_raw' ELSE 'university_raw+university_name' END source_field,
  'registry target resolved uniquely in active catalog' evidence
  FROM recovery_decisions d CROSS JOIN regex_registry_resolved r
  WHERE d.selected_count<>1 AND d.recovery_country_ok
   AND regexp_matches(d.raw_regex_norm,r.source_raw_regex)
   AND (r.source_name_policy='ignore' OR
    (r.source_name_policy='required_match' AND d.name_regex_norm<>'' AND
     regexp_matches(d.name_regex_norm,r.source_name_regex)) OR
    (r.source_name_policy='if_present_match' AND (d.name_regex_norm='' OR
     regexp_matches(d.name_regex_norm,r.source_name_regex))))")

 dbExecute(con,"CREATE OR REPLACE TABLE source_values AS SELECT decision_id,source_field,source_value FROM (
  SELECT decision_id,'university_raw' source_field,raw_regex_norm source_value FROM recovery_decisions
  UNION ALL SELECT decision_id,'university_name',name_regex_norm FROM recovery_decisions
  UNION ALL SELECT decision_id,'translated_university_raw',raw_translated_norm FROM recovery_decisions
  UNION ALL SELECT decision_id,'translated_university_name',name_translated_norm FROM recovery_decisions)
  WHERE source_value<>''")
 dbExecute(con,"CREATE OR REPLACE TABLE exact_proposals AS WITH hits AS (
  SELECT d.decision_id,c.CO_IES target_code,v.source_field,v.source_value
  FROM recovery_decisions d JOIN source_values v USING(decision_id)
  JOIN catalog_active c ON c.name_regex_norm=v.source_value
  WHERE d.selected_count<>1 AND d.recovery_country_ok
 ), unique_hits AS (SELECT decision_id,source_field,source_value,min(target_code)::BIGINT target_code
  FROM hits GROUP BY ALL HAVING count(DISTINCT target_code)=1)
 SELECT decision_id,target_code,'catalog_exact' rule_id,'regex_catalog_exact' rule_family,
  20 priority,source_field,'normalized active catalog name equality' evidence FROM unique_hits")
 dbExecute(con,"CREATE OR REPLACE TABLE core_proposals AS WITH catalog_core AS (
  SELECT CO_IES,trim(regexp_replace(regexp_replace(regexp_replace(name_regex_norm,
   '^(faculdade|faculdades|instituto|centro universitario|universidade)( (de|do|da|dos|das))? ',''),
   '(^| )(de|do|da|dos|das)( |$)',' ','g'),' +',' ','g')) core
  FROM catalog_active
 ), source_core AS (SELECT decision_id,source_field,trim(regexp_replace(regexp_replace(regexp_replace(source_value,
   '^(faculdade|faculdades|instituto|centro universitario|universidade)( (de|do|da|dos|das))? ',''),
   '(^| )(de|do|da|dos|das)( |$)',' ','g'),' +',' ','g')) core
  FROM source_values), hits AS (SELECT d.decision_id,c.CO_IES target_code,s.source_field,s.core
  FROM recovery_decisions d JOIN source_core s USING(decision_id) JOIN catalog_core c USING(core)
  WHERE d.selected_count<>1 AND d.recovery_country_ok AND length(s.core)>=10 AND
   len(regexp_split_to_array(s.core,' +'))>=2
 ), unique_hits AS (SELECT decision_id,source_field,core,min(target_code)::BIGINT target_code
  FROM hits GROUP BY ALL HAVING count(DISTINCT target_code)=1)
 SELECT decision_id,target_code,'catalog_core_exact' rule_id,'regex_catalog_exact' rule_family,
  20 priority,source_field,'institution-form-neutral active catalog equality' evidence FROM unique_hits")

 dbExecute(con,"CREATE OR REPLACE TABLE source_tokens AS WITH raw_tokens AS (
  SELECT d.decision_id,v.source_field,t.token FROM recovery_decisions d JOIN source_values v USING(decision_id)
  CROSS JOIN unnest(regexp_split_to_array(v.source_value,' +')) t(token)
  LEFT JOIN recovery_generic_tokens g USING(token)
  WHERE d.selected_count<>1 AND d.recovery_country_ok AND g.token IS NULL AND length(t.token)>=3
 ), expanded AS (SELECT * FROM raw_tokens UNION SELECT * EXCLUDE(token),substr(token,4) token
  FROM raw_tokens WHERE regexp_matches(token,'^uni[a-z0-9]{3,}$')) SELECT DISTINCT * FROM expanded")
 dbExecute(con,"CREATE OR REPLACE TABLE brand_matches AS SELECT d.decision_id,c.CO_IES target_code,
  min(c.nome_ies) target_name,count(DISTINCT s.token)::INTEGER shared_tokens,
  min(o.active_owner_count)::INTEGER minimum_token_owners,
  bool_or(o.active_owner_count=1) unique_shared_token,
  bool_or(list_contains(d.candidate_codes,c.CO_IES)) candidate_supported,
  bool_or(c.municipio_norm<>'' AND (regexp_matches(d.raw_regex_norm,'(^| )'||regexp_escape(c.municipio_norm)||'($| )')
   OR regexp_matches(d.name_regex_norm,'(^| )'||regexp_escape(c.municipio_norm)||'($| )'))) municipality_supported,
  string_agg(DISTINCT s.token,',' ORDER BY s.token) shared_token_text,
  bool_or(d.source_has_portuguese_form) source_has_portuguese_form,
  bool_or(
   (regexp_matches(d.raw_regex_norm||' '||d.name_regex_norm,'(^| )(faculdade|faculty)( |$)') AND
    regexp_matches(lower(c.nome_ies),'^faculdade')) OR
   (regexp_matches(d.raw_regex_norm||' '||d.name_regex_norm,'(^| )(centro universitario|centro educacional|university centre|university center)( |$)') AND
    regexp_matches(strip_accents(lower(c.nome_ies)),'^(centro universitario|faculdade)')) OR
   (regexp_matches(d.raw_regex_norm||' '||d.name_regex_norm,'(^| )(universidade|university)( |$)') AND
    regexp_matches(strip_accents(lower(c.nome_ies)),'^universidade')) OR
   (regexp_matches(d.raw_regex_norm||' '||d.name_regex_norm,'(^| )(instituto|institute)( |$)') AND
    regexp_matches(strip_accents(lower(c.nome_ies)),'^instituto'))
  ) source_form_compatible
 FROM recovery_decisions d JOIN source_tokens s USING(decision_id)
  JOIN brand_token_owners o ON o.token=s.token AND o.active_owner_count<=25
  JOIN catalog_brand_tokens c ON c.token=s.token
  GROUP BY d.decision_id,c.CO_IES")
 dbExecute(con,"CREATE OR REPLACE TABLE containment_proposals AS WITH hits AS (
  SELECT b.decision_id,b.target_code,v.source_field,v.source_value,c.name_regex_norm
  FROM brand_matches b JOIN source_values v USING(decision_id)
  JOIN catalog_active c ON c.CO_IES=b.target_code
  WHERE length(v.source_value)>=8 AND length(c.name_regex_norm)>=8
   AND (contains(v.source_value,c.name_regex_norm) OR contains(c.name_regex_norm,v.source_value))
   AND least(length(v.source_value),length(c.name_regex_norm))*1.0 /
    greatest(length(v.source_value),length(c.name_regex_norm))>=0.6
 ), unique_hits AS (SELECT decision_id,source_field,source_value,
  min(target_code)::BIGINT target_code FROM hits GROUP BY ALL HAVING count(DISTINCT target_code)=1)
 SELECT decision_id,target_code,'catalog_name_containment' rule_id,
  'regex_catalog_exact' rule_family,20 priority,source_field,
  'guarded normalized full-name containment with at least 60 percent coverage' evidence FROM unique_hits")
 dbExecute(con,"CREATE OR REPLACE TABLE contextual_brand_proposals AS SELECT decision_id,target_code,
  CASE WHEN candidate_supported THEN 'catalog_brand_candidate' ELSE 'catalog_brand_municipality' END rule_id,
  'regex_brand_location' rule_family,CASE WHEN candidate_supported AND shared_tokens>=3 THEN 25
   WHEN candidate_supported AND shared_tokens>=2 THEN 30 ELSE 45 END priority,
  'university_raw+university_name' source_field,
  'shared='||shared_token_text||CASE WHEN candidate_supported THEN ';existing_candidate' ELSE ';municipality' END evidence
  FROM brand_matches WHERE shared_tokens>=1 AND (candidate_supported OR municipality_supported)")
 dbExecute(con,"CREATE OR REPLACE TABLE global_brand_proposals AS SELECT decision_id,target_code,
  CASE WHEN shared_tokens>=2 THEN 'catalog_two_brand_tokens' ELSE 'catalog_unique_brand_form' END rule_id,
  'regex_catalog_brand' rule_family,50 priority,'university_raw+university_name' source_field,
  'shared='||shared_token_text||';minimum_active_owners='||minimum_token_owners evidence
  FROM brand_matches WHERE shared_tokens>=2 OR (unique_shared_token AND source_form_compatible)")

 dbExecute(con,"CREATE OR REPLACE TABLE acronym_proposals AS WITH tokenized AS (
  SELECT d.decision_id,d.candidate_codes,d.source_has_portuguese_form,d.raw_regex_norm,d.name_regex_norm,
   v.source_field,t.token FROM recovery_decisions d JOIN source_values v USING(decision_id)
  CROSS JOIN unnest(regexp_split_to_array(v.source_value,' +')) t(token)
  LEFT JOIN recovery_generic_tokens g USING(token)
  WHERE d.selected_count<>1 AND d.recovery_country_ok AND g.token IS NULL AND length(t.token)>=3
 ) SELECT DISTINCT t.decision_id,a.target_code,'catalog_unique_active_acronym' rule_id,
  'regex_unique_acronym' rule_family,40 priority,t.source_field,
  'complete source token='||t.token||';unique active acronym owner' evidence
  FROM tokenized t JOIN active_acronyms a ON a.alias_norm=t.token
  WHERE list_contains(t.candidate_codes,a.target_code) OR t.source_has_portuguese_form
   OR t.raw_regex_norm=a.alias_norm OR t.name_regex_norm=a.alias_norm OR length(a.alias_norm)<=6")

 dbExecute(con,"CREATE OR REPLACE TABLE regex_proposals AS SELECT DISTINCT * FROM (
  SELECT * FROM alias_proposals UNION ALL SELECT * FROM exact_proposals
  UNION ALL SELECT * FROM core_proposals UNION ALL SELECT * FROM containment_proposals
  UNION ALL SELECT * FROM contextual_brand_proposals
  UNION ALL SELECT * FROM acronym_proposals UNION ALL SELECT * FROM global_brand_proposals)")
 dbExecute(con,"CREATE OR REPLACE TABLE proposal_summary AS WITH priorities AS (
  SELECT decision_id,min(priority)::INTEGER winning_priority FROM regex_proposals GROUP BY decision_id
 ), top AS (SELECT p.* FROM regex_proposals p JOIN priorities w USING(decision_id)
  WHERE p.priority=w.winning_priority), chosen AS (SELECT decision_id,min(priority)::INTEGER winning_priority,
   count(DISTINCT target_code)::INTEGER winning_target_count,min(target_code)::BIGINT target_code,
   first(rule_id ORDER BY rule_id,target_code) rule_id,
   first(rule_family ORDER BY rule_id,target_code) rule_family,
   first(source_field ORDER BY rule_id,target_code) source_field
  FROM top GROUP BY decision_id), all_proposals AS (SELECT decision_id,
   list(struct_pack(target_code:=target_code,rule_id:=rule_id,rule_family:=rule_family,
    priority:=priority,source_field:=source_field,evidence:=evidence)
    ORDER BY priority,rule_id,target_code) proposals,count(*)::INTEGER proposal_count
   FROM regex_proposals GROUP BY decision_id)
  SELECT c.*,a.proposals,a.proposal_count FROM chosen c JOIN all_proposals a USING(decision_id)")

 dbExecute(con,"CREATE OR REPLACE TABLE decisions_final AS SELECT
  d.decision_id,d.base_decision_id emec_base_decision_id,d.raw_id,d.country_code,d.university_country,
  CASE WHEN p.winning_target_count=1 THEN list_sort(list_distinct(list_concat(
   coalesce(d.candidate_codes,[]::BIGINT[]),[p.target_code]))) ELSE d.candidate_codes END candidate_codes,
  d.university_raw,d.university_name,d.raw_regex_norm,d.name_regex_norm,d.raw_translated_norm,d.name_translated_norm,
  CASE WHEN p.winning_target_count=1 THEN 0 ELSE d.selection_stage END::INTEGER selection_stage,
  d.selection_stage pre_regex_selection_stage,
  d.selector_selected_codes,d.selector_selected_evidence,d.selector_selected_count,d.selector_selection_status,
  d.selector_acronym_owner_count,d.selector_acronym_context_ok,d.selector_stage2_context_ok,
  d.pre_status_selected_codes,d.pre_status_selected_evidence,d.pre_status_selected_count,d.pre_status_selection_status,
  d.selected_codes pre_regex_selected_codes,d.selected_evidence pre_regex_selected_evidence,
  d.selected_count pre_regex_selected_count,d.selection_status pre_regex_selection_status,
  CASE WHEN p.winning_target_count=1 THEN [p.target_code] ELSE d.selected_codes END selected_codes,
  CASE WHEN p.winning_target_count=1 THEN list_filter(d.selected_evidence,x->false) ELSE d.selected_evidence END selected_evidence,
  CASE WHEN p.winning_target_count=1 THEN 1 ELSE d.selected_count END::INTEGER selected_count,
  CASE WHEN p.winning_target_count=1 THEN p.rule_family
   WHEN p.winning_target_count>1 THEN 'unresolved_regex_conflict' ELSE d.selection_status END selection_status,
  d.active_preference,d.recovery_country_ok,(p.winning_target_count=1) regex_selected,
  coalesce(p.winning_target_count>1,false) regex_conflict,p.winning_priority regex_priority,
  CASE WHEN p.winning_target_count=1 THEN p.rule_id END regex_rule_id,
  CASE WHEN p.winning_target_count=1 THEN p.rule_family END regex_rule_family,
  CASE WHEN p.winning_target_count=1 THEN p.source_field END regex_source_field,
  CASE WHEN p.winning_target_count=1 THEN p.target_code END regex_target_code,
  coalesce(p.proposal_count,0)::INTEGER regex_proposal_count,p.proposals regex_proposals
  FROM recovery_decisions d LEFT JOIN proposal_summary p USING(decision_id)")
 stopifnot(
  dbGetQuery(con,"SELECT count(*) n FROM decisions_final WHERE pre_regex_selected_count=1 AND
   (regex_selected OR selected_codes IS DISTINCT FROM pre_regex_selected_codes OR selected_count<>1)")$n==0L,
  dbGetQuery(con,"SELECT count(*) n FROM decisions_final WHERE selected_count>0 AND
   NOT list_has_all(candidate_codes,selected_codes)")$n==0L,
  dbGetQuery(con,"SELECT count(*) n FROM decisions_final d JOIN catalog c
   ON c.CO_IES=d.regex_target_code WHERE d.regex_selected AND c.situacao_ies NOT IN ('Ativa','Em atividade')")$n==0L,
  dbGetQuery(con,"SELECT count(*) n FROM decisions_final WHERE regex_selected AND NOT recovery_country_ok")$n==0L)

 dbExecute(con,sprintf("COPY (SELECT * FROM regex_proposals ORDER BY decision_id,priority,rule_id,target_code)
  TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",gsub('\\\\','/',recovery_artifacts[2])))
 dbExecute(con,sprintf("COPY (SELECT * FROM decisions_final ORDER BY decision_id)
  TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",gsub('\\\\','/',recovery_artifacts[3])))
 for(bucket in 0:63) dbExecute(con,sprintf("COPY (SELECT * FROM decisions_final WHERE decision_id%%64=%d
  ORDER BY decision_id) TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",bucket,
  gsub('\\\\','/',file.path(out,'decisions',sprintf('part_%02d.parquet',bucket)))))

 dbExecute(con,"CREATE OR REPLACE TABLE decision_weights AS SELECT d.decision_id,
  count(*)::BIGINT education_rows,count(DISTINCT user_id)::BIGINT users FROM base_enriched e
  JOIN decisions_final d ON d.emec_base_decision_id=e.emec_decision_id
   AND d.university_name IS NOT DISTINCT FROM e.university_name
   AND d.university_country IS NOT DISTINCT FROM e.university_country GROUP BY 1")
 dbExecute(con,sprintf("COPY (SELECT d.*,w.education_rows,w.users FROM decisions_final d
  JOIN decision_weights w USING(decision_id) ORDER BY d.decision_id)
  TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",gsub('\\\\','/',recovery_artifacts[4])))
 saveRDS(tools::md5sum(recovery_artifacts),phase)
}

dbExecute(con,"CREATE OR REPLACE TABLE catalog AS SELECT *,CAST(CO_IES AS VARCHAR) oa_id FROM catalog_public")
dbExecute(con,sprintf("CREATE OR REPLACE TABLE decisions_final AS SELECT * FROM read_parquet('%s')",
 gsub('\\\\','/',file.path(out,'regex_decisions.parquet'))))
dbExecute(con,"CREATE OR REPLACE TABLE candidate_sets AS SELECT DISTINCT candidate_codes,
 array_to_string(candidate_codes,'|') candidate_codes_pipe FROM decisions_final WHERE len(candidate_codes)>0")
dbExecute(con,"CREATE OR REPLACE TABLE candidate_details AS SELECT s.candidate_codes_pipe,
 list(struct_pack(co_ies:=c.CO_IES,nome_ies:=c.nome_ies,sigla:=c.sigla,situacao_ies:=c.situacao_ies,
  municipio:=c.municipio,uf:=c.uf) ORDER BY c.CO_IES) candidates
 FROM candidate_sets s CROSS JOIN unnest(s.candidate_codes) u(co_ies)
 JOIN catalog c ON c.CO_IES=u.co_ies GROUP BY 1")
dbExecute(con,"CREATE OR REPLACE TABLE selected_sets AS SELECT DISTINCT selected_codes,
 array_to_string(selected_codes,'|') selected_codes_pipe FROM decisions_final WHERE len(selected_codes)>0")
dbExecute(con,"CREATE OR REPLACE TABLE selected_details AS SELECT s.selected_codes_pipe,
 list(c.nome_ies ORDER BY c.CO_IES) selected_names FROM selected_sets s
 CROSS JOIN unnest(s.selected_codes) u(co_ies) JOIN catalog c ON c.CO_IES=u.co_ies GROUP BY 1")

for(i in seq_along(base_education)) {
 dest <- file.path(out,'education_parts',basename(base_education[i]))
 done <- file.path(out,'checkpoints',sprintf('education_%02d.rds',i))
 if(file.exists(done)) {stopifnot(identical(readRDS(done),tools::md5sum(dest)));next}
 stopifnot(!file.exists(dest))
 dbExecute(con,sprintf("CREATE OR REPLACE TEMP VIEW input_part AS SELECT * FROM read_parquet('%s')",
  gsub('\\\\','/',base_education[i])))
 dbExecute(con,sprintf("COPY (SELECT e.* REPLACE (
  d.decision_id AS emec_decision_id,d.candidate_codes AS emec_candidate_codes,
  c.candidates AS emec_candidates,d.selected_codes AS emec_selected_codes,
  n.selected_names AS emec_selected_names,d.selected_count AS emec_selected_count,
  d.selection_stage AS emec_selection_stage,d.selection_status AS emec_selection_status,
  d.selected_evidence AS emec_selected_evidence,
  CASE WHEN d.selected_count=1 THEN d.selected_codes[1] END AS CO_IES),
  d.emec_base_decision_id,d.pre_regex_selection_stage AS emec_pre_regex_selection_stage,
  d.pre_regex_selected_codes AS emec_pre_regex_selected_codes,
  d.pre_regex_selected_count AS emec_pre_regex_selected_count,
  d.pre_regex_selection_status AS emec_pre_regex_selection_status,
  d.regex_selected AS emec_regex_selected,d.regex_conflict AS emec_regex_conflict,
  d.regex_priority AS emec_regex_priority,d.regex_rule_id AS emec_regex_rule_id,
  d.regex_rule_family AS emec_regex_rule_family,d.regex_source_field AS emec_regex_source_field,
  d.regex_target_code AS emec_regex_target_code,d.regex_proposal_count AS emec_regex_proposal_count,
  d.regex_proposals AS emec_regex_proposals
  FROM input_part e JOIN decisions_final d ON d.emec_base_decision_id=e.emec_decision_id
   AND d.university_name IS NOT DISTINCT FROM e.university_name
   AND d.university_country IS NOT DISTINCT FROM e.university_country
  LEFT JOIN candidate_details c ON c.candidate_codes_pipe=array_to_string(d.candidate_codes,'|')
  LEFT JOIN selected_details n ON n.selected_codes_pipe=array_to_string(d.selected_codes,'|')
  ORDER BY e.source_row) TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)",gsub('\\\\','/',dest)))
 stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM input_part e FULL JOIN read_parquet('%s') n
  USING(source_file,source_row) WHERE e.user_id IS DISTINCT FROM n.user_id OR
   e.university_raw IS DISTINCT FROM n.university_raw OR e.university_name IS DISTINCT FROM n.university_name",
  gsub('\\\\','/',dest)))$n==0L)
 saveRDS(tools::md5sum(dest),done)
 cat('Wrote regex-recovered education partition',i,'of',length(base_education),'\n')
}

output_glob <- gsub('\\\\','/',file.path(out,'education_parts','*.parquet'))
dbExecute(con,sprintf("CREATE OR REPLACE VIEW enriched AS SELECT * FROM read_parquet('%s')",output_glob))
population <- dbGetQuery(con,"SELECT count(*) education_rows,count(DISTINCT user_id) users,
 count(DISTINCT (source_file,source_row)) physical_keys,count(*) FILTER(WHERE CO_IES IS NOT NULL) matched_rows,
 count(DISTINCT user_id) FILTER(WHERE CO_IES IS NOT NULL) matched_users,
 count(*) FILTER(WHERE emec_regex_selected) regex_rows,
 count(DISTINCT user_id) FILTER(WHERE emec_regex_selected) regex_users FROM enriched")
stopifnot(population$education_rows==19710307L,population$users==8901904L,
 population$physical_keys==population$education_rows)
regex_by_rule <- dbGetQuery(con,"SELECT emec_regex_rule_family rule_family,emec_regex_rule_id rule_id,
 count(*) education_rows,count(DISTINCT user_id) users,count(DISTINCT emec_decision_id) decisions
 FROM enriched WHERE emec_regex_selected GROUP BY ALL ORDER BY 1,2")
conflicts <- dbGetQuery(con,"SELECT count(*) decisions,sum(education_rows) education_rows,sum(users) users
 FROM read_parquet(?) WHERE regex_conflict",params=list(gsub('\\\\','/',file.path(out,'degree_duration_emec_crosswalk.parquet'))))
levels <- dbGetQuery(con,"SELECT CASE WHEN coalesce(degree,'empty')='empty' AND degree_matches_laxed=1
 THEN 'bachelor' ELSE coalesce(ranked_level,'other') END effective_level,
 count(*) education_rows,count(*) FILTER(WHERE CO_IES IS NOT NULL) matched_rows,
 count(*) FILTER(WHERE emec_regex_selected) regex_rows,count(DISTINCT user_id) users
 FROM enriched GROUP BY 1 ORDER BY 1")

output_paths <- c(sort(list.files(file.path(out,'education_parts'),pattern='[.]parquet$',full.names=TRUE)),
 sort(list.files(file.path(out,'decisions'),pattern='[.]parquet$',full.names=TRUE)),recovery_artifacts)
report <- list(completed_utc=format(Sys.time(),tz='UTC',usetz=TRUE),
 method=list(population='Latest refreshed degree-duration education population inherited from the checked base hierarchy',
  protection='Existing unique CO_IES assignments are immutable; recovery runs only where the base has no scalar code',
  decision_key='Base e-MEC decision plus university_name and university_country',
  priority='Alias registry; normalized/translated equality; candidate or municipality brand; unique active acronym; guarded catalog brand',
  conflict='Different targets at the highest available priority remain unresolved',
  country='Explicitly non-Brazilian source countries are excluded',
  target_resolution='Registry targets and every selected generated target resolve dynamically to active current catalog rows'),
 inputs=inputs,population=population,regex_by_rule=regex_by_rule,conflicts=conflicts,
 effective_levels=levels,protected_inputs=protected,
 outputs=data.frame(path=output_paths,md5=unname(tools::md5sum(output_paths))),implementation=implementation,
 validation=list(base_unique_matches_unchanged=TRUE,source_physical_keys_preserved=TRUE,
  selected_codes_subset_augmented_candidates=TRUE,regex_targets_active=TRUE,
  registry_targets_unique_active=TRUE,explicit_foreign_excluded=TRUE))
write_json(report,file.path(out,'degree_duration_emec_regex_recovery_report.json'),
 pretty=TRUE,auto_unbox=TRUE,dataframe='rows',digits=16,na='null')
stopifnot(identical(protected$md5,unname(tools::md5sum(protected$path))))
dbDisconnect(con,shutdown=TRUE)
cat('Completed degree-duration e-MEC regex recovery:',out,'\n')
print(population)
print(regex_by_rule)
