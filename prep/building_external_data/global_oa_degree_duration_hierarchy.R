# Offline LOCAL prep. Rebuilds the global OpenAlex hierarchy for the refreshed
# degree-duration education population. It never reads Athena or writes S3 and
# must not be sent to SEDAP.
# Run from the repository root:
#   Rscript prep/building_external_data/global_oa_degree_duration_hierarchy.R
# Completed partitions are resumable only while input and code checksums match.
library(DBI)
library(duckdb)
library(jsonlite)
library(countrycode)
options(stringsAsFactors=FALSE)

root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh <- file.path(root,'Data/intermediate/revelio_br_cohort')
education_dir <- file.path(coh,'obmep_candidates_step_1_degree_duration_education')
out <- Sys.getenv('OBMEP_GLOBAL_OA_DURATION_OUT',file.path(coh,'global_oa_hierarchy_degree_duration'))
snapshot <- 'C:/Users/megaj/Globtalent Dropbox/GTAllocation/Data/external/oa_snapshot/data/institutions'
sql_path <- 'prep/building_external_data/global_oa_hierarchy_sql.R'
script_path <- 'prep/building_external_data/global_oa_degree_duration_hierarchy.R'

education_paths <- sort(list.files(education_dir,full.names=TRUE))
snapshot_paths <- sort(list.files(snapshot,pattern='[.]gz$',recursive=TRUE,full.names=TRUE))
stopifnot(dir.exists(education_dir),length(education_paths)==30L,
 length(unique(basename(education_paths)))==length(education_paths),
 length(snapshot_paths)>0,file.exists(sql_path))

dir.create(out,recursive=TRUE,showWarnings=FALSE)
for(d in c('checkpoints','decisions','candidate_evaluations','education_parts','spill'))
 dir.create(file.path(out,d),showWarnings=FALSE)

input_paths <- c(education_paths,snapshot_paths,sql_path)
inputs <- data.frame(path=input_paths,md5=unname(tools::md5sum(input_paths)))
stopifnot(!anyNA(inputs$md5))
input_manifest <- file.path(out,'input_manifest.rds')
if(file.exists(input_manifest)) {
 stopifnot(identical(inputs,readRDS(input_manifest)))
} else saveRDS(inputs,input_manifest)

code_manifest <- file.path(out,'implementation_manifest.rds')
current_code <- data.frame(path=c(script_path,sql_path),
 md5=unname(tools::md5sum(c(script_path,sql_path))))
if(file.exists(code_manifest)) {
 prior_code <- readRDS(code_manifest)
 stopifnot(all(file.exists(prior_code$path)),identical(current_code,prior_code))
} else saveRDS(current_code,code_manifest)

# These are the existing production products most directly adjacent to this
# build. The new pipeline has no path that is allowed to replace them.
protected_paths <- c(
 file.path(coh,c('obmep_candidates_step_1_ruf_degree.parquet',
  'obmep_candidates_step_1_shanghai.parquet',
  'obmep_candidates_step_1_shanghai_rsid_nofloor.parquet',
  'ranked_education_flags_redefinition_report.json',
  'obmep_candidates_selected.parquet',
  'obmep_candidates_selected_positions.parquet')),
 file.path(coh,'global_oa_hierarchy',c('global_oa_hierarchy_report.json',
  'family_catalog.parquet','global_oa_parent_map.parquet',
  'global_oa_parent_adjusted_decisions.parquet',
  'global_oa_ranked_parent_catalog.parquet')))
protected_paths <- protected_paths[file.exists(protected_paths)]
protected <- data.frame(path=protected_paths,md5=unname(tools::md5sum(protected_paths)))

con <- dbConnect(duckdb(),dbdir=file.path(out,'work.duckdb'))
on.exit(try(dbDisconnect(con,shutdown=TRUE),silent=TRUE),add=TRUE)
dbExecute(con,"SET memory_limit='8GB'")
dbExecute(con,'SET threads=4')
dbExecute(con,sprintf("SET temp_directory='%s'",gsub('\\\\','/',file.path(out,'spill'))))
dbExecute(con,"CREATE OR REPLACE MACRO regexp_like(s,p) AS regexp_matches(s,p)")
education_glob <- gsub('\\\\','/',file.path(education_dir,'*'))
dbExecute(con,sprintf("CREATE OR REPLACE VIEW education AS SELECT
 * EXCLUDE(filename,file_row_number),
 regexp_extract(replace(filename,chr(92),'/'),'([^/]+)$',1) source_file,
 CAST(file_row_number AS BIGINT) source_row
 FROM read_parquet('%s',filename=true,file_row_number=true)",education_glob))
source(sql_path)

phase <- file.path(out,'checkpoints','01_catalog.rds')
if(!file.exists(phase)) {
 cat('Reading the full global institution snapshot.\n')
 dbExecute(con,sprintf("CREATE OR REPLACE TABLE catalog_source AS
  SELECT regexp_extract(id,'I[0-9]+') oa_id,* EXCLUDE(id,filename),
   regexp_extract(filename,'updated_date=([0-9-]+)',1) snapshot_date
  FROM read_json('%s/updated_date=*/part_*.gz',format='newline_delimited',filename=true,
   columns={id:'VARCHAR',display_name:'VARCHAR',country_code:'VARCHAR',type:'VARCHAR',works_count:'BIGINT',
   display_name_alternatives:'VARCHAR[]',display_name_acronyms:'VARCHAR[]',
   geo:'STRUCT(city VARCHAR,region VARCHAR,country VARCHAR,country_code VARCHAR)'})
  QUALIFY row_number() OVER(PARTITION BY id ORDER BY filename DESC)=1",snapshot))
 country_values <- dbGetQuery(con,"SELECT DISTINCT university_country AS value FROM education
  UNION SELECT DISTINCT geo.country FROM catalog_source UNION SELECT DISTINCT country_code FROM catalog_source
  UNION SELECT DISTINCT geo.country_code FROM catalog_source")
 country_values$country_code <- suppressWarnings(countrycode(country_values$value,'country.name','iso2c',warn=FALSE))
 for(origin in c('iso2c','iso3c')) {
  converted <- suppressWarnings(countrycode(toupper(trimws(country_values$value)),origin,'iso2c',warn=FALSE))
  use <- is.na(country_values$country_code) & !is.na(converted)
  country_values$country_code[use] <- converted[use]
 }
 country_values$country_code[toupper(trimws(country_values$value)) %in% c('XK','KOSOVO')] <- 'XK'
 dbWriteTable(con,'country_mapping',country_values,overwrite=TRUE)
 dbExecute(con,"CREATE OR REPLACE TABLE catalog AS SELECT c.* EXCLUDE(country_code),
  c.country_code country_code_original,coalesce(m.country_code,g.country_code,n.country_code) country_code,
  trim(regexp_replace(regexp_replace(display_name,'\\s*\\([^()]*\\)','','g'),'\\s+',' ','g')) cleaned_display_name
  FROM catalog_source c LEFT JOIN country_mapping m ON c.country_code=m.value
  LEFT JOIN country_mapping g ON c.geo.country_code=g.value
  LEFT JOIN country_mapping n ON c.geo.country=n.value")
 dbExecute(con,"CREATE OR REPLACE TABLE aliases AS WITH raw AS (
  SELECT oa_id,display_name alias,'primary' alias_kind FROM catalog
  UNION ALL SELECT oa_id,cleaned_display_name,'cleaned' FROM catalog
  UNION ALL SELECT oa_id,unnest(display_name_alternatives),'alternative' FROM catalog
  UNION ALL SELECT oa_id,unnest(display_name_acronyms),'acronym' FROM catalog
 ), folded AS (SELECT DISTINCT *,strip_accents(lower(trim(alias))) alias_norm FROM raw)
 SELECT *,alias_kind IN ('primary','cleaned') OR (alias_kind='alternative' AND NOT EXISTS(
  SELECT 1 FROM folded x WHERE x.oa_id=f.oa_id AND x.alias_kind='acronym' AND x.alias_norm=f.alias_norm)) name_eligible
 FROM folded f WHERE alias_norm IS NOT NULL AND alias_norm<>''")
 stopifnot(dbGetQuery(con,'SELECT count(*) n,count(DISTINCT oa_id) ids FROM catalog')$n==120658L,
  dbGetQuery(con,"SELECT count(*) n FROM catalog WHERE oa_id IS NULL OR oa_id='' ")$n==0)
 for(tbl in c('catalog','aliases','country_mapping')) dbExecute(con,sprintf(
  "COPY %s TO '%s/%s.parquet' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",tbl,out,tbl))
 saveRDS(TRUE,phase)
}

phase <- file.path(out,'checkpoints','02_crosswalk.rds')
if(!file.exists(phase)) {
 cat('Building whole-name and segment evidence from refreshed education rows.\n')
 dbExecute(con,"CREATE OR REPLACE TABLE raw_names AS SELECT row_number() OVER(ORDER BY university_raw) raw_id,
  university_raw,strip_accents(lower(trim(university_raw))) raw_norm,strip_accents(trim(university_raw)) raw_case
  FROM (SELECT DISTINCT university_raw FROM education)")
 dbExecute(con,"CREATE OR REPLACE TABLE raw_tokens AS
  SELECT raw_id,raw_norm token,true whole FROM raw_names WHERE length(raw_norm)>=3
  UNION SELECT raw_id,trim(unnest(regexp_split_to_array(raw_norm,'[/()|]| - '))),false FROM raw_names")
 dbExecute(con,"CREATE OR REPLACE TABLE raw_links AS
  SELECT t.raw_id,a.oa_id,bool_or(t.whole)::INTEGER c_norm_whole,bool_or(NOT t.whole)::INTEGER c_norm_segment,
   bool_or(r.university_raw=a.alias)::INTEGER c_exact,
   list(DISTINCT a.alias ORDER BY a.alias) supporting_catalog_names
  FROM raw_tokens t JOIN aliases a ON a.alias_norm=t.token AND a.alias_kind IN ('primary','cleaned')
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
  max(c_exact)::INTEGER c_exact,max(c_norm_whole)::INTEGER c_norm_whole,max(c_norm_segment)::INTEGER c_norm_segment
  FROM crosswalk_evidence GROUP BY rsid,oa_id")
 dbExecute(con,"CREATE OR REPLACE TABLE rsid_sets AS SELECT rsid,list(oa_id ORDER BY oa_id) candidate_ids
  FROM crosswalk GROUP BY rsid")
 dbExecute(con,"CREATE OR REPLACE TABLE raw_sets AS SELECT raw_id,list(oa_id ORDER BY oa_id) candidate_ids,
  max(c_exact)::INTEGER c_exact,max(c_norm_whole)::INTEGER c_norm_whole,max(c_norm_segment)::INTEGER c_norm_segment
  FROM raw_links GROUP BY raw_id")
 for(tbl in c('crosswalk','crosswalk_evidence','raw_links','raw_names','rsid_sets','raw_sets'))
  dbExecute(con,sprintf("COPY %s TO '%s/%s.parquet' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",tbl,out,tbl))
 stopifnot(dbGetQuery(con,'SELECT count(*) n FROM crosswalk')$n==
  dbGetQuery(con,'SELECT count(DISTINCT (rsid,oa_id)) n FROM crosswalk_evidence')$n)
 saveRDS(TRUE,phase)
}

phase <- file.path(out,'checkpoints','03_population.rds')
if(!file.exists(phase)) {
 cat('Collapsing reusable decisions by raw text, country, and candidate set.\n')
 dbExecute(con,"CREATE OR REPLACE TABLE entry_keys AS
  SELECT DISTINCT e.rsid,r.raw_id,m.country_code FROM education e
  JOIN raw_names r ON e.university_raw IS NOT DISTINCT FROM r.university_raw
  LEFT JOIN country_mapping m ON e.university_country=m.value")
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
 dbExecute(con,sprintf("COPY decisions_input TO '%s/decision_inputs.parquet' (FORMAT PARQUET,COMPRESSION ZSTD,OVERWRITE_OR_IGNORE)",out))
 saveRDS(TRUE,phase)
}

for(bucket in 0:63) {
 dest <- file.path(out,'decisions',sprintf('part_%02d.parquet',bucket))
 evdest <- file.path(out,'candidate_evaluations',sprintf('part_%02d.parquet',bucket))
 done <- file.path(out,'checkpoints',sprintf('decision_%02d.rds',bucket))
 if(file.exists(done)) {
  stopifnot(identical(readRDS(done),tools::md5sum(c(dest,evdest))))
  next
 }
 cat('Selecting candidates: partition',bucket+1,'of 64.\n')
 dbExecute(con,sprintf('CREATE OR REPLACE TEMP VIEW decision_batch AS SELECT * FROM decisions_input WHERE decision_id%%64=%d',bucket))
 unicode_scores <- dbGetQuery(con,hierarchy_unicode_pairs_sql)
 unicode_scores$jaro <- stringdist::stringsim(unicode_scores$raw_norm,unicode_scores$alias_norm,method='jw',p=0,useBytes=FALSE)
 dbWriteTable(con,'unicode_scores',unicode_scores,overwrite=TRUE,temporary=TRUE)
 dbExecute(con,paste('CREATE OR REPLACE TEMP TABLE evaluations AS',hierarchy_evaluation_sql))
 dbExecute(con,sprintf("COPY evaluations TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)",evdest))
 dbExecute(con,paste('CREATE OR REPLACE TEMP TABLE selected AS',hierarchy_decision_sql))
 stopifnot(dbGetQuery(con,"SELECT count(*) n FROM selected WHERE selected_count>0 AND
  NOT list_has_all(candidate_ids,selected_ids)")$n==0,
  dbGetQuery(con,'SELECT count(*) n FROM selected')$n==dbGetQuery(con,'SELECT count(*) n FROM decision_batch')$n)
 dbExecute(con,sprintf("COPY selected TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)",dest))
 saveRDS(tools::md5sum(c(dest,evdest)),done)
}
dbExecute(con,sprintf("CREATE OR REPLACE VIEW decisions AS SELECT * FROM read_parquet('%s/decisions/*.parquet')",out))

phase <- file.path(out,'checkpoints','04_education.rds')
if(!file.exists(phase)) {
 cat('Writing refreshed education rows with global candidates and selections.\n')
 dbExecute(con,"CREATE OR REPLACE TABLE candidate_sets AS SELECT DISTINCT candidate_ids,
  array_to_string(candidate_ids,'|') candidate_ids_pipe FROM decisions_input WHERE len(candidate_ids)>0")
 dbExecute(con,"CREATE OR REPLACE TABLE candidate_details AS SELECT s.candidate_ids_pipe,
  list(struct_pack(oa_id:=c.oa_id,display_name:=c.display_name,type:=c.type,country_code:=c.country_code) ORDER BY c.oa_id) candidates
  FROM candidate_sets s CROSS JOIN unnest(s.candidate_ids) u(oa_id) JOIN catalog c ON c.oa_id=u.oa_id GROUP BY 1")
 dbExecute(con,"CREATE OR REPLACE TABLE selected_details AS SELECT s.selected_ids_pipe,
  list(c.display_name ORDER BY c.oa_id) selected_names FROM (SELECT DISTINCT selected_ids_pipe,selected_ids FROM decisions
   WHERE selected_count>0) s CROSS JOIN unnest(s.selected_ids) u(oa_id) JOIN catalog c ON c.oa_id=u.oa_id GROUP BY 1")
 files <- dbGetQuery(con,'SELECT DISTINCT source_file FROM education ORDER BY 1')$source_file
 stopifnot(length(files)==30L)
 for(i in seq_along(files)) {
  dest <- file.path(out,'education_parts',sprintf('part_%02d.parquet',i))
  done <- file.path(out,'checkpoints',sprintf('education_%02d.rds',i))
  if(file.exists(done)) {stopifnot(identical(readRDS(done),tools::md5sum(dest)));next}
  qfile <- as.character(dbQuoteString(con,files[i]))
  dbExecute(con,sprintf("COPY (SELECT e.*,k.decision_id global_oa_decision_id,m.country_code global_oa_country_code,
   k.match_route global_oa_match_route,k.fallback_c_exact global_oa_fallback_c_exact,
   k.fallback_c_norm_whole global_oa_fallback_c_norm_whole,k.fallback_c_norm_segment global_oa_fallback_c_norm_segment,
   k.candidate_ids global_oa_candidate_ids,array_to_string(k.candidate_ids,'|') global_oa_candidate_ids_pipe,
   c.candidates global_oa_candidates,d.selected_ids global_oa_selected_ids,d.selected_ids_pipe global_oa_selected_ids_pipe,
   n.selected_names global_oa_selected_names,d.selected_count global_oa_selected_count,
   d.selection_stage global_oa_selection_stage,d.selection_status global_oa_selection_status,
   d.selected_evidence global_oa_selected_evidence
   FROM (SELECT * FROM education WHERE source_file=%s) e
   JOIN raw_names r ON e.university_raw IS NOT DISTINCT FROM r.university_raw
   LEFT JOIN country_mapping m ON e.university_country=m.value
   JOIN key_decisions k ON k.rsid IS NOT DISTINCT FROM e.rsid AND k.raw_id=r.raw_id
    AND k.country_code IS NOT DISTINCT FROM m.country_code
   JOIN decisions d USING(decision_id)
   LEFT JOIN candidate_details c ON c.candidate_ids_pipe=array_to_string(k.candidate_ids,'|')
   LEFT JOIN selected_details n ON n.selected_ids_pipe=d.selected_ids_pipe
   ORDER BY e.source_row) TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)",qfile,dest))
  cols <- dbGetQuery(con,'DESCRIBE education')$column_name
  mismatch <- paste(sprintf('e."%1$s" IS DISTINCT FROM n."%1$s"',cols),collapse=' OR ')
  stopifnot(dbGetQuery(con,sprintf("SELECT count(*) n FROM (SELECT * FROM education WHERE source_file=%s) e
   FULL JOIN read_parquet('%s') n USING(source_file,source_row) WHERE %s",qfile,dest,mismatch))$n==0)
  saveRDS(tools::md5sum(dest),done)
  cat('Preserved and verified source partition',i,'of',length(files),'\n')
 }
 saveRDS(TRUE,phase)
}

dbExecute(con,sprintf("CREATE OR REPLACE VIEW enriched AS SELECT * FROM read_parquet('%s/education_parts/*.parquet')",out))
cat('Reconciling the refreshed hierarchy.\n')
population <- dbGetQuery(con,"SELECT count(*) education_rows,count(DISTINCT user_id) users,
 count(DISTINCT (source_file,source_row)) physical_keys,
 count(*) FILTER(WHERE global_oa_selected_count=1) single_rows,
 count(*) FILTER(WHERE global_oa_selected_count>1) tied_rows,
 count(*) FILTER(WHERE global_oa_selected_count=0) unresolved_rows FROM enriched")
stopifnot(population$education_rows==19710307L,population$users==8901904L,
 population$physical_keys==population$education_rows)
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM enriched WHERE
 global_oa_selected_count<>coalesce(len(global_oa_selected_ids),0)
 OR (global_oa_selected_count>0 AND NOT list_has_all(global_oa_candidate_ids,global_oa_selected_ids))")$n==0)
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM enriched e CROSS JOIN unnest(e.global_oa_selected_ids) u(oa_id)
 LEFT JOIN catalog c USING(oa_id) WHERE c.oa_id IS NULL")$n==0)
routes <- dbGetQuery(con,"SELECT global_oa_match_route route,count(*) education_rows,
 count(DISTINCT user_id) users FROM enriched GROUP BY 1 ORDER BY 1")
stages <- dbGetQuery(con,"SELECT global_oa_selection_stage stage,global_oa_selection_status status,
 count(*) education_rows,count(DISTINCT global_oa_decision_id) decisions,count(DISTINCT user_id) users
 FROM enriched GROUP BY 1,2 ORDER BY 1,2")
candidate_counts <- dbGetQuery(con,"SELECT min(len(global_oa_candidate_ids)) minimum,
 avg(len(global_oa_candidate_ids)) mean,max(len(global_oa_candidate_ids)) maximum,
 min(global_oa_selected_count) selected_minimum,avg(global_oa_selected_count) selected_mean,
 max(global_oa_selected_count) selected_maximum FROM enriched")

stopifnot(identical(inputs$md5,unname(tools::md5sum(inputs$path))),
 identical(protected$md5,unname(tools::md5sum(protected$path))))
implementation <- current_code
saveRDS(implementation,code_manifest)
output_paths <- c(list.files(file.path(out,'education_parts'),pattern='[.]parquet$',full.names=TRUE),
 list.files(file.path(out,'decisions'),pattern='[.]parquet$',full.names=TRUE),
 file.path(out,c('catalog.parquet','aliases.parquet','country_mapping.parquet','crosswalk.parquet',
  'crosswalk_evidence.parquet','raw_links.parquet','raw_names.parquet','rsid_sets.parquet',
  'raw_sets.parquet','decision_inputs.parquet')))
report <- list(completed_utc=format(Sys.time(),tz='UTC',usetz=TRUE),
 method=list(population='Refreshed degree-duration education population',
  decision_key='Original university_raw, standardized country and candidate set',
  upstream='Primary and cleaned names; exact and C_norm whole/segment evidence',
  selection='First successful normalized equality, containment, supplied acronym, then 0.2 country plus 0.8 Jaro-Winkler',
  ties='All score ties within 1e-12 retained; no similarity floor or arbitrary ID tie-break'),
 inputs=inputs,population=population,routes=routes,stages=stages,
 candidate_counts=candidate_counts,protected_products=protected,
 outputs=data.frame(path=output_paths,md5=unname(tools::md5sum(output_paths))),
 implementation=implementation,
 validation=list(source_rows_and_users=TRUE,physical_keys_unique=TRUE,
  original_values_preserved=TRUE,selected_ids_subset_candidates=TRUE,
  selected_ids_in_snapshot=TRUE,inputs_and_legacy_products_unchanged=TRUE))
write_json(report,file.path(out,'global_oa_hierarchy_degree_duration_report.json'),
 pretty=TRUE,auto_unbox=TRUE,dataframe='rows',digits=16,na='null')
dbDisconnect(con,shutdown=TRUE)
cat('Completed refreshed global OpenAlex hierarchy:',out,'\n')
print(population)
print(routes)
