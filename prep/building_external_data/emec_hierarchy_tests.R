# Offline synthetic tests for degree_duration_emec_hierarchy.R.
# Writes only its report under the repository's default OBMEP test area.
library(DBI)
library(duckdb)
library(stringdist)
library(jsonlite)

test_dir <- 'C:/Users/megaj/Globtalent Dropbox/OBMEP/test/degree_duration_emec_hierarchy'
dir.create(test_dir,recursive=TRUE,showWarnings=FALSE)
con <- dbConnect(duckdb())
on.exit(dbDisconnect(con,shutdown=TRUE),add=TRUE)
source('prep/building_external_data/global_oa_hierarchy_sql.R')

# oa_id is deliberately only an internal adapter for the shared selector.
dbExecute(con,"CREATE TABLE catalog AS SELECT * FROM (VALUES
 ('1',1::BIGINT,'Universidade Alfa','ALFA','Ativa','BR','Cidade A','SP'),
 ('2',2::BIGINT,'Alpha University','ALPHA','Extinta','BR','Cidade A','SP'),
 ('3',3::BIGINT,'Faculdade Gama','GAMA','Extinta','BR','Cidade G','MG'),
 ('4',4::BIGINT,'Faculdade Gama','GAMA','Ativa','BR','Cidade G','MG'),
 ('5',5::BIGINT,'Instituto Delta','DELTA','Ativa','BR','Cidade D','RJ'),
 ('6',6::BIGINT,'Instituto Delta','DELTA','Ativa','BR','Cidade D','RJ'),
 ('7',7::BIGINT,'Centro Epsilon','EPS','Extinta','BR','Cidade E','ES'),
 ('8',8::BIGINT,'Centro Epsilon','EPS','Extinta','BR','Cidade E','ES'),
 ('9',9::BIGINT,'MARHTA','null','Extinta','BR','Cidade M','BA'),
 ('11',11::BIGINT,'FACULDADE ATUAL','FAT','Ativa','BR','Cidade F','PR'),
 ('12',12::BIGINT,'Instituto de Ensino Superior de Bauru','IESB','Ativa','BR','Bauru','SP'),
 ('13',13::BIGINT,'Instituto de Educacao Superior de Brasilia','IESB','Ativa','BR','Brasilia','DF'),
 ('16',16::BIGINT,'Faculdade Interacao Americana','FIA','Ativa','BR','Cidade I','SP'),
 ('18',18::BIGINT,'Faculdade Zeta','ZETA','Extinta','BR','Cidade Z1','SP'),
 ('19',19::BIGINT,'Faculdade Zeta','ZETA2','Ativa','BR','Cidade Z2','RJ'),
 ('20',20::BIGINT,'Universidade Anhanguera','UNIA','Ativa','BR','Campo Grande','MS'),
 ('21',21::BIGINT,'Universidade Anhanguera de Sao Paulo','UNIASP','Ativa','BR','Sao Paulo','SP'),
 ('3000000000',3000000000::BIGINT,'Universidade Omega','OMGA','Ativa','BR','Cidade O','GO'))
 t(oa_id,co_ies,nome_ies,sigla,situacao_ies,country_code,municipio,uf)")
dbExecute(con,"CREATE TABLE aliases AS WITH raw AS (SELECT * FROM (VALUES
 ('1',1::BIGINT,'Universidade Alfa','primary'),('1',1::BIGINT,'ALFA','acronym'),
 ('2',2::BIGINT,'Alpha University','primary'),('2',2::BIGINT,'ALPHA','acronym'),
 ('3',3::BIGINT,'Faculdade Gama','primary'),('4',4::BIGINT,'Faculdade Gama','primary'),
 ('5',5::BIGINT,'Instituto Delta','primary'),('6',6::BIGINT,'Instituto Delta','primary'),
 ('7',7::BIGINT,'Centro Epsilon','primary'),('8',8::BIGINT,'Centro Epsilon','primary'),
 ('9',9::BIGINT,'MARHTA','primary'),('9',9::BIGINT,'null','acronym'),
 ('9',9::BIGINT,'--','acronym'),('9',9::BIGINT,'AB','acronym'),
 ('11',11::BIGINT,'FACULDADE ATUAL','primary'),
 ('12',12::BIGINT,'Instituto de Ensino Superior de Bauru','primary'),('12',12::BIGINT,'IESB','acronym'),
 ('13',13::BIGINT,'Instituto de Educacao Superior de Brasilia','primary'),('13',13::BIGINT,'IESB','acronym'),
 ('16',16::BIGINT,'Faculdade Interacao Americana','primary'),('16',16::BIGINT,'FIA','acronym'),
 ('18',18::BIGINT,'Faculdade Zeta','primary'),('19',19::BIGINT,'Faculdade Zeta','primary'),
 ('20',20::BIGINT,'Universidade Anhanguera','primary'),
 ('21',21::BIGINT,'Universidade Anhanguera de Sao Paulo','primary'),
 ('3000000000',3000000000::BIGINT,'Universidade Omega','primary')
 ) t(oa_id,co_ies,alias,alias_kind)) SELECT oa_id,co_ies,alias,
 strip_accents(lower(trim(alias))) alias_norm,alias_kind,alias_kind<>'acronym' name_eligible
 FROM raw WHERE alias_kind<>'acronym' OR
  (lower(trim(alias))<>'null' AND length(regexp_replace(strip_accents(lower(trim(alias))),
   '[^a-z0-9]','','g'))>=3)")
dbExecute(con,"CREATE TABLE acronym_owner_counts AS SELECT alias_norm,
 count(DISTINCT oa_id)::INTEGER owner_count FROM aliases
 WHERE alias_kind='acronym' GROUP BY alias_norm")
dbExecute(con,"CREATE TABLE stage2_generic_tokens AS SELECT token FROM (VALUES
 ('a'),('o'),('as'),('os'),('e'),('da'),('de'),('do'),('das'),('dos'),('em'),('para'),
 ('the'),('of'),('and'),('at'),('in'),('for'),('faculdade'),('universidade'),('university'),
 ('centro'),('instituto'),('superior'),('educacao'),('ensino'),('school')) t(token)")
dbExecute(con,"CREATE TABLE decision_batch AS SELECT decision_id,university_raw,country_code,candidate_ids,
 strip_accents(lower(trim(university_raw))) raw_norm,strip_accents(trim(university_raw)) raw_case,
 list_filter(list_transform(regexp_split_to_array(strip_accents(lower(trim(university_raw))),
 '[/()|]| - '),x->trim(x)),x->length(x)>=3) raw_segments
 FROM (VALUES
 (1,' UNIVERSIDADE ALFA ','BR',['1','2']),
 (2,'Campus Alpha University / ALPHA','BR',['1','2']),
 (3,'Departamento ALFA campus','BR',['1','2']),
 (4,'MARTHA',NULL,['9']),
 (5,'Faculdade Gama','BR',['3','4']),
 (6,'Instituto Delta','BR',['5','6']),
 (7,'Centro Epsilon','BR',['7','8']),
 (8,'MARHTA',NULL,['9']),
 (9,'','BR',['1']),
 (10,'Sem instituicao',NULL,NULL::VARCHAR[]),
 (11,'MIT','US',['11']),
 (12,'Udemy Alumni',NULL,['3','4']),
 (13,'Universidade Omega','BR',['3000000000']),
 (14,'IESB','BR',['12']),
 (15,'FIA Business School','BR',['16']),
 (16,'ALFA','BR',['1']),
 (17,'Faculdade Zeta','BR',['18','19']),
 (18,'Universidade Anhanguera Sao Paulo','BR',['20','21'])
 ) t(decision_id,university_raw,country_code,candidate_ids)")

unicode_scores <- dbGetQuery(con,hierarchy_unicode_pairs_sql)
unicode_scores$jaro <- stringsim(unicode_scores$raw_norm,unicode_scores$alias_norm,
 method='jw',p=0,useBytes=FALSE)
dbWriteTable(con,'unicode_scores',unicode_scores)
dbExecute(con,paste('CREATE TABLE evaluations AS',hierarchy_evaluation_sql))
dbExecute(con,paste('CREATE TABLE selector_selected AS',hierarchy_decision_sql))
dbExecute(con,"CREATE TABLE selector_ambiguity AS
 SELECT s.decision_id,coalesce(max(o.owner_count),0)::INTEGER selector_acronym_owner_count,
  coalesce(bool_and(s.raw_norm=o.alias_norm OR list_contains(s.raw_segments,o.alias_norm))
   FILTER(WHERE s.selection_stage=3),true) selector_acronym_context_ok
 FROM selector_selected s LEFT JOIN unnest(s.selected_evidence) e(x) ON true
 LEFT JOIN acronym_owner_counts o ON s.selection_stage=3 AND
  o.alias_norm=strip_accents(lower(trim(x.supporting_alias))) GROUP BY s.decision_id")
dbExecute(con,"CREATE TABLE stage2_residuals AS WITH raw_tokens AS (
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
dbExecute(con,"CREATE TABLE stage2_conflicts AS SELECT DISTINCT r.decision_id
 FROM stage2_residuals r JOIN selector_selected s USING(decision_id)
 CROSS JOIN unnest(s.candidate_ids) u(oa_id)
 JOIN aliases a ON a.oa_id=u.oa_id AND a.name_eligible
 CROSS JOIN unnest(regexp_split_to_array(a.alias_norm,'[^a-z0-9]+')) t(token)
 WHERE NOT list_contains(s.selected_ids,u.oa_id) AND t.token=r.token")
dbExecute(con,"CREATE TABLE selector_stage2_context AS SELECT s.decision_id,
 (c.decision_id IS NULL) selector_stage2_context_ok
 FROM selector_selected s LEFT JOIN stage2_conflicts c USING(decision_id)")
dbExecute(con,"CREATE TABLE selected_base AS SELECT
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
dbExecute(con,"CREATE TABLE active_counts AS SELECT s.decision_id,
 count(u.oa_id) FILTER(WHERE c.situacao_ies IN ('Ativa','Em atividade')) active_count,
 min(u.oa_id) FILTER(WHERE c.situacao_ies IN ('Ativa','Em atividade')) active_id,
 count(DISTINCT lower(trim(c.municipio))||'|'||upper(trim(c.uf))) FILTER(WHERE c.municipio IS NOT NULL
  AND lower(trim(c.municipio))<>'null' AND c.uf IS NOT NULL AND lower(trim(c.uf))<>'null') location_count,
 count(*) FILTER(WHERE c.municipio IS NULL OR lower(trim(c.municipio))='null'
  OR c.uf IS NULL OR lower(trim(c.uf))='null') location_missing
 FROM selected_base s LEFT JOIN unnest(s.selected_ids) u(oa_id) ON true
 LEFT JOIN catalog c USING(oa_id) GROUP BY s.decision_id")
dbExecute(con,"CREATE TABLE selected AS WITH resolved AS (
 SELECT s.*,s.selected_ids pre_ids,s.selected_count pre_count,s.selection_status pre_status,
 CASE WHEN s.selected_count>1 AND a.active_count=1 AND a.location_count=1 AND a.location_missing=0
  THEN [a.active_id] ELSE s.selected_ids END final_ids,
 CASE WHEN s.selected_count>1 AND a.active_count=1 AND a.location_count=1 AND a.location_missing=0
  THEN 1 ELSE 0 END active_preference
 FROM selected_base s JOIN active_counts a USING(decision_id)
 ) SELECT *,coalesce(len(final_ids),0)::INTEGER final_count,
 CASE WHEN active_preference=1 THEN 'single_active_preference' ELSE selection_status END final_status
 FROM resolved")

r <- dbGetQuery(con,"SELECT decision_id,selection_stage,selector_selected_count selector_count,pre_count,final_count,
 active_preference,final_status FROM selected ORDER BY decision_id")
print(r)
stopifnot(
 identical(r$selection_stage,c(1L,2L,3L,4L,1L,1L,1L,1L,NA_integer_,NA_integer_,4L,4L,1L,3L,3L,3L,1L,2L)),
 r$selector_count[3]==1L,r$pre_count[3]==0L,r$final_status[3]=='unresolved_contextual_acronym',
 r$selector_count[4]==1L,r$pre_count[4]==0L,r$final_count[4]==0L,
 r$pre_count[5]==2L,r$final_count[5]==1L,r$active_preference[5]==1L,
 r$pre_count[6]==2L,r$final_count[6]==2L,r$active_preference[6]==0L,
 r$pre_count[7]==2L,r$final_count[7]==2L,r$active_preference[7]==0L,
 r$pre_count[8]==1L,r$final_count[8]==1L,r$active_preference[8]==0L,
  all(r$final_count[9:10]==0L),
 r$selector_count[11]==1L,r$pre_count[11]==0L,r$final_count[11]==0L,
 r$selector_count[12]==2L,r$pre_count[12]==0L,r$final_count[12]==0L,
 r$active_preference[12]==0L,r$final_status[12]=='unresolved_fuzzy_unvalidated',
 r$final_count[13]==1L,
 all(r$selector_count[14:15]==1L),all(r$pre_count[14:15]==0L),
 all(r$final_count[14:15]==0L),all(r$active_preference[14:15]==0L),
 r$final_status[14]=='unresolved_ambiguous_acronym',
 r$final_status[15]=='unresolved_contextual_acronym',
 r$pre_count[16]==1L,r$final_count[16]==1L,
 r$pre_count[17]==2L,r$final_count[17]==2L,r$active_preference[17]==0L,
 r$selector_count[18]==1L,r$pre_count[18]==0L,r$final_count[18]==0L,
 r$final_status[18]=='unresolved_containment_conflict',
 dbGetQuery(con,"SELECT final_ids[1] n FROM selected WHERE decision_id=5")$n=='4',
 dbGetQuery(con,"SELECT final_status n FROM selected WHERE decision_id=5")$n=='single_active_preference')

# Candidate supply uses names only. Acronyms can decide among supplied candidates
# but cannot create a raw/rsid link, and invalid source sentinels do not exist.
dbExecute(con,"CREATE TABLE raw_fixture AS SELECT row_number() OVER() raw_id,raw,
 strip_accents(lower(trim(raw))) folded FROM (VALUES
 ('Universidade Alfa'),('ALFA'),('Faculdade Gama')) t(raw)")
dbExecute(con,"CREATE TABLE supplied AS SELECT r.raw_id,a.oa_id FROM raw_fixture r
 JOIN aliases a ON r.folded=a.alias_norm AND a.name_eligible")
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM supplied s JOIN raw_fixture r USING(raw_id) WHERE r.raw='ALFA'")$n==0L,
 dbGetQuery(con,"SELECT count(*) n FROM supplied s JOIN raw_fixture r USING(raw_id) WHERE r.raw='Universidade Alfa'")$n==1L,
 dbGetQuery(con,"SELECT count(*) n FROM aliases WHERE alias_kind='acronym' AND
  (lower(trim(alias))='null' OR length(regexp_replace(alias_norm,'[^a-z0-9]','','g'))<3)")$n==0L)

# Real rsids never fall through to the raw-name route; NULL and the documented
# sentinel do. This also exercises the sentinel without coercing BIGINT codes.
dbExecute(con,"CREATE TABLE route_fixture AS SELECT * FROM (VALUES
 (1::BIGINT,true,true),(2::BIGINT,false,true),(NULL::BIGINT,false,true),
 (2147483647::BIGINT,false,true)) t(rsid,has_rsid_candidates,has_raw_candidates)")
route <- dbGetQuery(con,"SELECT rsid,CASE WHEN rsid IS NOT NULL AND rsid<>2147483647 THEN
 CASE WHEN has_rsid_candidates THEN 'rsid' ELSE 'unmatched_known_rsid' END
 ELSE CASE WHEN has_raw_candidates THEN 'raw_c_norm' ELSE 'unmatched_missing_rsid' END END route
 FROM route_fixture ORDER BY rsid NULLS LAST")
stopifnot(identical(route$route,c('rsid','unmatched_known_rsid','raw_c_norm','raw_c_norm')))

dbExecute(con,"CREATE TABLE public_selected AS SELECT decision_id,
 list_transform(selector_selected_ids,x->CAST(x AS BIGINT)) selector_selected_codes,
 list_transform(selector_selected_evidence,x->struct_pack(co_ies:=CAST(x.oa_id AS BIGINT),
  supporting_alias:=x.supporting_alias)) selector_selected_evidence,
 list_transform(pre_ids,x->CAST(x AS BIGINT)) pre_status_selected_codes,
 list_transform(final_ids,x->CAST(x AS BIGINT)) selected_codes,
 CASE WHEN final_count=1 THEN CAST(final_ids[1] AS BIGINT) END CO_IES
 FROM selected")
types <- dbGetQuery(con,'DESCRIBE public_selected')
stopifnot(types$column_type[types$column_name=='CO_IES']=='BIGINT',
 types$column_type[types$column_name=='selected_codes']=='BIGINT[]',
 grepl('co_ies BIGINT',types$column_type[types$column_name=='selector_selected_evidence'],fixed=TRUE),
 dbGetQuery(con,'SELECT CO_IES n FROM public_selected WHERE decision_id=13')$n==3000000000,
 !any(grepl('oa_id',types$column_name,ignore.case=TRUE)))

# Exact score ties survive the shared selector before the status preference.
dbExecute(con,"CREATE OR REPLACE TABLE evaluations AS SELECT * FROM evaluations WHERE decision_id=6")
dbExecute(con,"UPDATE evaluations SET candidate_stage=NULL,score=CASE WHEN oa_id='5' THEN 0.8 ELSE 0.8-1e-13 END")
dbExecute(con,paste('CREATE OR REPLACE TABLE tolerance_selected AS',hierarchy_decision_sql))
stopifnot(dbGetQuery(con,'SELECT selected_count n FROM tolerance_selected WHERE decision_id=6')$n==2L)
dbExecute(con,"UPDATE evaluations SET score=0.8-5e-12 WHERE oa_id='6'")
dbExecute(con,paste('CREATE OR REPLACE TABLE tolerance_selected AS',hierarchy_decision_sql))
stopifnot(dbGetQuery(con,'SELECT selected_count n FROM tolerance_selected WHERE decision_id=6')$n==1L)

write_json(list(passed=TRUE,selection_cases=nrow(r),active_preference_cases=1,
 unresolved_tie_cases=2,acronym_selection_only=TRUE,invalid_acronyms_removed=TRUE,
 score_stage_diagnostic_only=TRUE,rsid_poisoning_regression=TRUE,
 ambiguous_acronym_diagnostic_only=TRUE,
 contextual_acronym_diagnostic_only=TRUE,
 containment_conflict_diagnostic_only=TRUE,
 active_preference_requires_shared_location=TRUE,
 missing_and_sentinel_routing=TRUE,public_bigint_types=TRUE,nested_bigint_evidence=TRUE,
 numeric_tie_tolerance=TRUE,
 duckdb=dbGetQuery(con,'SELECT version()')[[1]],
 stringdist_version=as.character(packageVersion('stringdist'))),
 file.path(test_dir,'test_report.json'),pretty=TRUE,auto_unbox=TRUE)
dbDisconnect(con,shutdown=TRUE)
cat('Degree-duration e-MEC hierarchy fixtures passed.\n')
