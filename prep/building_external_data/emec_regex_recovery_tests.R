# Offline acceptance tests for the versioned degree-duration e-MEC regex recovery.
library(DBI)
library(duckdb)
library(jsonlite)
library(readxl)

root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
out <- Sys.getenv('OBMEP_EMEC_DURATION_OUT',file.path(root,
 'Data/intermediate/revelio_br_cohort/emec_hierarchy_regex_v1'))
sample_path <- 'outputs/degree_duration_emec_valid_sample_20260916/degree_duration_emec_valid_sample.xlsx'
registry_path <- 'prep/building_external_data/degree_duration_emec_regex_aliases.csv'
test_dir <- file.path(root,'test/degree_duration_emec_regex_recovery')
dir.create(test_dir,recursive=TRUE,showWarnings=FALSE)
stopifnot(file.exists(sample_path),file.exists(registry_path),
 length(list.files(file.path(out,'education_parts'),pattern='[.]parquet$'))==30L)

sample <- read_excel(sample_path,'Unmatched',skip=4)
expected <- c('1'=23820,'3'=298,'4'=1351,'5'=12916,'6'=1892,'9'=1561,'11'=55,
 '12'=1045,'13'=3368,'16'=1958,'20'=206,'21'=5387,'22'=1045,'23'=3804,'24'=410,
 '28'=2279,'31'=1045,'33'=163,'34'=1045,'35'=1680,'36'=1445,'37'=1255,'39'=1948,
 '42'=449,'44'=575,'45'=449,'46'=1811,'48'=4504,'49'=14161,'50'=298,'51'=4655,
 '52'=1045,'53'=2538,'55'=547,'57'=163,'58'=18009,'61'=163,'64'=54,'65'=790,
 '66'=163,'67'=298,'68'=5439,'73'=3840,'74'=2835,'78'=3371,'82'=55,'83'=319,
 '84'=1499,'86'=14161,'87'=163,'90'=163,'92'=600,'93'=1045,'94'=16934,
 '95'=1063,'97'=1430,'99'=3998)
sample$expected_CO_IES <- as.numeric(expected[as.character(sample$sample_order)])

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con,shutdown=TRUE),add=TRUE)
dbWriteTable(con,'sample_fixture',sample)
output_glob <- gsub('\\\\','/',file.path(out,'education_parts','*.parquet'))
catalog_path <- gsub('\\\\','/',file.path(root,
 'Data/intermediate/revelio_br_cohort/emec_hierarchy/catalog.parquet'))
registry_resolved <- gsub('\\\\','/',file.path(out,'regex_alias_registry_resolved.parquet'))
proposal_path <- gsub('\\\\','/',file.path(out,'regex_proposals.parquet'))
dbExecute(con,sprintf("CREATE VIEW enriched AS SELECT * FROM read_parquet('%s')",output_glob))
dbExecute(con,sprintf("CREATE VIEW catalog AS SELECT * FROM read_parquet('%s')",catalog_path))
dbExecute(con,sprintf("CREATE VIEW registry_resolved AS SELECT * FROM read_parquet('%s')",registry_resolved))
dbExecute(con,sprintf("CREATE VIEW proposals AS SELECT * FROM read_parquet('%s')",proposal_path))
reviewed <- dbGetQuery(con,"SELECT s.sample_order,s.university_raw,s.expected_CO_IES,e.CO_IES,
 e.emec_regex_selected,e.emec_regex_rule_family,e.emec_regex_rule_id,e.emec_regex_target_code,
 e.global_oa_country_code,e.university_country,
 string_agg(CAST(p.target_code AS VARCHAR)||':'||p.rule_id||':'||CAST(p.priority AS VARCHAR),';'
  ORDER BY p.priority,p.rule_id,p.target_code) proposal_summary
 FROM sample_fixture s JOIN enriched e USING(source_file,source_row)
 LEFT JOIN proposals p ON p.decision_id=e.emec_decision_id GROUP BY ALL ORDER BY s.sample_order")

intended <- !is.na(reviewed$expected_CO_IES)
correct <- intended & !is.na(reviewed$CO_IES) & reviewed$CO_IES==reviewed$expected_CO_IES
rejected_clean <- !intended & is.na(reviewed$CO_IES)
if(sum(correct)!=57L || sum(rejected_clean)!=43L) {
 print(reviewed[!correct & intended | !rejected_clean & !intended,],row.names=FALSE)
 cat('correct intended:',sum(correct),'of',sum(intended),
  '; rejected unmatched:',sum(rejected_clean),'of',sum(!intended),'\n')
}
stopifnot(nrow(reviewed)==100L,sum(intended)==57L,sum(correct)==57L,
 sum(!intended)==43L,sum(rejected_clean)==43L,
 is.na(reviewed$CO_IES[reviewed$sample_order==91L]),
 all(reviewed$emec_regex_selected[intended]))

stopifnot(
 dbGetQuery(con,"SELECT count(*) n FROM registry_resolved")$n==10L,
 dbGetQuery(con,"SELECT count(*) n FROM registry_resolved r JOIN catalog c
  ON c.CO_IES=r.target_code WHERE c.situacao_ies NOT IN ('Ativa','Em atividade')")$n==0L,
 dbGetQuery(con,"SELECT count(*) n FROM registry_resolved WHERE target_code IS NULL")$n==0L,
 grepl('^anha(n)?guera( educacional)?$','anhaguera educacional',perl=TRUE),
 grepl('^anha(n)?guera( educacional)?$','anhanguera educacional',perl=TRUE),
 !any(grepl('CO_IES|target_code',names(read.csv(registry_path)),ignore.case=TRUE)))

write_json(list(passed=TRUE,reviewed_rows=nrow(reviewed),intended_matches=sum(correct),
 rejected_unmatched=sum(rejected_clean),alias_rules=10,
 rule_families=as.list(table(reviewed$emec_regex_rule_family[intended])),
 libertas_business_school_remained_unmatched=TRUE,production_targets_not_hardcoded=TRUE),
 file.path(test_dir,'test_report.json'),pretty=TRUE,auto_unbox=TRUE)
dbDisconnect(con,shutdown=TRUE)
cat('Degree-duration e-MEC regex recovery acceptance fixtures passed.\n')
