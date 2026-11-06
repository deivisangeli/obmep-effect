# LOCAL/offline workbook-data export for a second, disjoint random sample from
# the final degree-duration e-MEC regex hierarchy. It must not be sent to SEDAP.
library(DBI)
library(duckdb)
library(jsonlite)
library(readxl)

root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh <- file.path(root,'Data/intermediate/revelio_br_cohort')
input_dir <- Sys.getenv('OBMEP_EMEC_DURATION_OUT',
 file.path(coh,'emec_hierarchy_regex_v1'))
catalog_path <- file.path(coh,'emec_hierarchy','catalog.parquet')
prior_workbook <- 'outputs/degree_duration_emec_valid_sample_20260916/degree_duration_emec_valid_sample.xlsx'
output_dir <- 'outputs/degree_duration_emec_valid_sample_regex_v1_20260916'
json_path <- file.path(output_dir,'workbook_data.json')
seed <- 20260917L
n_draw <- 100L

stopifnot(file.exists(prior_workbook),file.exists(catalog_path),
 length(list.files(file.path(input_dir,'education_parts'),pattern='[.]parquet$'))==30L)
dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)

old <- rbind(
 as.data.frame(read_excel(prior_workbook,'Matched',skip=4))[,c('source_file','source_row')],
 as.data.frame(read_excel(prior_workbook,'Unmatched',skip=4))[,c('source_file','source_row')])
stopifnot(nrow(old)==200L,!anyDuplicated(paste(old$source_file,old$source_row)))

con <- dbConnect(duckdb(),dbdir=':memory:')
on.exit(dbDisconnect(con,shutdown=TRUE),add=TRUE)
dbExecute(con,"SET memory_limit='4GB'")
dbExecute(con,'SET threads=4')
dbWriteTable(con,'prior_sample_keys',old)
input_glob <- gsub('\\\\','/',file.path(input_dir,'education_parts','*.parquet'))
catalog_sql <- gsub('\\\\','/',catalog_path)
dbExecute(con,sprintf("CREATE VIEW enriched AS SELECT * FROM read_parquet('%s')",input_glob))
dbExecute(con,sprintf("CREATE VIEW catalog AS SELECT * FROM read_parquet('%s')",catalog_sql))
dbExecute(con,"CREATE VIEW valid_disjoint AS SELECT e.*,
 CASE WHEN coalesce(degree,'empty')='empty' AND degree_matches_laxed=1
      THEN 'bachelor' ELSE ranked_level END effective_level
 FROM enriched e LEFT JOIN prior_sample_keys k USING(source_file,source_row)
 WHERE k.source_file IS NULL AND effective_level IN ('bachelor','master','phd')")

population <- dbGetQuery(con,"SELECT count(*) valid_rows,
 count(*) FILTER(WHERE CO_IES IS NOT NULL) matched_rows,
 count(*) FILTER(WHERE CO_IES IS NULL) unmatched_rows,
 count(*) FILTER(WHERE coalesce(emec_regex_selected,false)) regex_rows
 FROM valid_disjoint")

dbExecute(con,sprintf("CREATE TABLE sample_keys AS WITH matched AS (
 SELECT source_file,source_row,row_number() OVER(ORDER BY
  hash(source_file||chr(31)||CAST(source_row AS VARCHAR)||chr(31)||'%d'),source_file,source_row) sample_order
 FROM valid_disjoint WHERE CO_IES IS NOT NULL), unmatched AS (
 SELECT source_file,source_row,row_number() OVER(ORDER BY
  hash(source_file||chr(31)||CAST(source_row AS VARCHAR)||chr(31)||'%d'),source_file,source_row) sample_order
 FROM valid_disjoint WHERE CO_IES IS NULL)
 SELECT 'Matched' sample_group,* FROM matched WHERE sample_order<=%d
 UNION ALL SELECT 'Unmatched',* FROM unmatched WHERE sample_order<=%d",seed,seed,n_draw,n_draw))

sample <- dbGetQuery(con,"SELECT k.sample_group,k.sample_order,
 CAST(e.user_id AS VARCHAR) user_id,e.source_file,e.source_row,
 e.university_raw,e.university_name,e.university_country,e.global_oa_country_code,
 CAST(e.rsid AS VARCHAR) rsid,e.degree,e.degree_raw,e.field,
 CAST(e.startdate AS VARCHAR) startdate,CAST(e.enddate AS VARCHAR) enddate,
 e.effective_level,e.degree_match_route,e.degree_duration_years,
 e.emec_decision_id,e.emec_base_decision_id,e.emec_match_route,
 e.emec_selection_stage,e.emec_selection_status,e.emec_selected_count,e.CO_IES,
 c.nome_ies selected_ies_name,c.sigla selected_ies_sigla,c.situacao_ies selected_ies_status,
 c.municipio selected_ies_municipality,c.uf selected_ies_uf,
 CASE WHEN coalesce(e.emec_regex_selected,false) THEN 'Regex recovery'
      WHEN e.CO_IES IS NOT NULL THEN 'Base hierarchy' ELSE 'Unmatched' END match_origin,
 coalesce(e.emec_regex_selected,false) regex_selected,
 coalesce(e.emec_regex_conflict,false) regex_conflict,e.emec_regex_priority,
 e.emec_regex_rule_family,e.emec_regex_rule_id,e.emec_regex_source_field,
 e.emec_regex_target_code,e.emec_regex_proposal_count,
 coalesce(array_to_string(list_transform(e.emec_candidates,x->
  CAST(x.co_ies AS VARCHAR)||':'||coalesce(x.nome_ies,'')),' | '),'') candidate_summary,
 coalesce(array_to_string(list_transform(e.emec_regex_proposals,x->
  CAST(x.target_code AS VARCHAR)||':'||x.rule_id||':p'||CAST(x.priority AS VARCHAR)),' | '),'')
  regex_proposal_summary,
 '' review_verdict,'' review_notes
 FROM sample_keys k JOIN valid_disjoint e USING(source_file,source_row)
 LEFT JOIN catalog c ON c.CO_IES=e.CO_IES ORDER BY k.sample_group,k.sample_order")

matched <- sample[sample$sample_group=='Matched',setdiff(names(sample),'sample_group')]
unmatched <- sample[sample$sample_group=='Unmatched',setdiff(names(sample),'sample_group')]
stopifnot(nrow(matched)==n_draw,nrow(unmatched)==n_draw,
 all(matched$effective_level %in% c('bachelor','master','phd')),
 all(unmatched$effective_level %in% c('bachelor','master','phd')),
 all(!is.na(matched$CO_IES)),all(is.na(unmatched$CO_IES)),
 !anyDuplicated(paste(sample$source_file,sample$source_row)),
 !any(paste(sample$source_file,sample$source_row) %in% paste(old$source_file,old$source_row)),
 all(grepl('^[0-9]+$',sample$user_id)))

write_json(list(metadata=list(seed=seed,draw_per_group=n_draw,
 population=population,excluded_prior_rows=nrow(old),
 source='Latest degree_duration cohort after e-MEC regex recovery v1'),
 Matched=matched,Unmatched=unmatched),json_path,pretty=TRUE,auto_unbox=TRUE,
 dataframe='rows',na='null',digits=16)
cat('Prepared disjoint workbook sample:',nrow(matched),'matched and',nrow(unmatched),
 'unmatched rows; seed',seed,'\n')
