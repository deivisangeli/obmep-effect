# Local preparation and consolidation for the 200-entry parent-adjusted audit.
# Sampling is offline. Reviewers may use authoritative web sources where needed.
# This script never modifies matching products, crosswalks, flags, or earlier audits.
library(DBI)
library(duckdb)
library(jsonlite)
options(stringsAsFactors=FALSE)
root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
global_dir <- file.path(root,'Data/intermediate/revelio_br_cohort/global_oa_hierarchy')
education_glob <- file.path(global_dir,'education_parts','*.parquet')
snapshot <- 'C:/Users/megaj/Globtalent Dropbox/GTAllocation/Data/external/oa_snapshot/data/institutions'
audit_dir <- 'outputs/global-oa-parent-audit-200-20260908'
dir.create(file.path(audit_dir,'batches'),recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(audit_dir,'reviews'),recursive=TRUE,showWarnings=FALSE)
patterns <- 'prep/building_external_data/br_degree_patterns.R'
source(patterns)
snapshot_paths <- list.files(snapshot,pattern='[.]gz$',recursive=TRUE,full.names=TRUE)
education_paths <- list.files(file.path(global_dir,'education_parts'),pattern='[.]parquet$',full.names=TRUE)
input_paths <- c(education_paths,snapshot_paths,patterns,
 file.path(global_dir,c('global_oa_hierarchy_report.json','implementation_manifest.rds')))
stopifnot(length(education_paths)==30L,length(snapshot_paths)>0,all(file.exists(input_paths)))
checksums <- data.frame(path=input_paths,md5=unname(tools::md5sum(input_paths)))
con <- dbConnect(duckdb())
dbExecute(con,"SET memory_limit='6GB'")
dbExecute(con,'SET threads=4')
dbExecute(con,sprintf("CREATE VIEW education AS SELECT * FROM read_parquet('%s')",education_glob))
dbExecute(con,sprintf("CREATE TABLE oa AS SELECT regexp_extract(id,'I[0-9]+') oa_id,display_name,type,country_code,
 display_name_alternatives,display_name_acronyms,associated_institutions
 FROM read_json('%s/updated_date=*/part_*.gz',format='newline_delimited',filename=true,
 columns={id:'VARCHAR',display_name:'VARCHAR',type:'VARCHAR',country_code:'VARCHAR',
 display_name_alternatives:'VARCHAR[]',display_name_acronyms:'VARCHAR[]',
 associated_institutions:'STRUCT(id VARCHAR,display_name VARCHAR,relationship VARCHAR)[]'})
 QUALIFY row_number() OVER(PARTITION BY id ORDER BY filename DESC)=1",snapshot))
stopifnot(dbGetQuery(con,'SELECT count(*) n,count(DISTINCT oa_id) ids FROM oa')$n==120658)
dbExecute(con,"CREATE TABLE parent_map AS SELECT o.oa_id,
 count(DISTINCT regexp_extract(a.id,'I[0-9]+')) n_parents,
 CASE WHEN count(DISTINCT regexp_extract(a.id,'I[0-9]+'))=1
  THEN min(regexp_extract(a.id,'I[0-9]+')) END unique_parent_id
 FROM oa o CROSS JOIN unnest(o.associated_institutions) u(a)
 WHERE a.relationship='parent' AND a.id IS NOT NULL GROUP BY o.oa_id")
dbExecute(con,"CREATE TABLE entry_parent_sets AS SELECT e.source_file,e.source_row,
 list(DISTINCT coalesce(p.unique_parent_id,u.oa_id) ORDER BY coalesce(p.unique_parent_id,u.oa_id)) parent_ids,
 bool_or(p.unique_parent_id IS NOT NULL AND p.unique_parent_id<>u.oa_id) parent_replacement_applied,
 bool_or(coalesce(p.n_parents,0)>1) ambiguous_parent_present
 FROM education e CROSS JOIN unnest(e.global_oa_selected_ids) u(oa_id)
 LEFT JOIN parent_map p ON p.oa_id=u.oa_id WHERE e.global_oa_selected_count>0 GROUP BY 1,2")
dbExecute(con,sprintf("CREATE TABLE eligible AS SELECT e.*,
 coalesce(ps.parent_ids,[]::VARCHAR[]) parent_adjusted_ids,
 coalesce(len(ps.parent_ids),0)::INTEGER parent_adjusted_count,
 coalesce(ps.parent_replacement_applied,false) parent_replacement_applied,
 coalesce(ps.ambiguous_parent_present,false) ambiguous_parent_present
 FROM education e LEFT JOIN entry_parent_sets ps USING(source_file,source_row)
 WHERE (e.degree IN ('Bachelor','Master','Doctor') OR e.br_oa_level IN ('bachelor','master','phd'))
 AND NOT regexp_matches(lower(trim(coalesce(e.degree_raw,''))),'%s')",rx_hs))
population <- dbGetQuery(con,"SELECT
 count(*) FILTER(WHERE parent_adjusted_count=1) assigned,
 count(*) FILTER(WHERE parent_adjusted_count=0) unassigned,
 count(*) FILTER(WHERE parent_adjusted_count>1) excluded_multiple,
 count(*) total FROM eligible")
stopifnot(population$assigned>=100,population$unassigned>=100,
 population$assigned+population$unassigned+population$excluded_multiple==population$total)
RNGkind('Mersenne-Twister','Inversion','Rejection')
set.seed(20260910)
assigned_positions <- sample.int(population$assigned,100L,replace=FALSE)
unassigned_positions <- sample.int(population$unassigned,100L,replace=FALSE)
draw <- rbind(
 data.frame(group='assigned',group_position=assigned_positions,within_group=seq_len(100L)),
 data.frame(group='unassigned',group_position=unassigned_positions,within_group=seq_len(100L)))
draw$batch_id <- ((draw$within_group-1L)%/%5L)+1L
draw$batch_slot <- ifelse(draw$group=='assigned',draw$within_group-1L-(draw$batch_id-1L)*5L+1L,
 draw$within_group-1L-(draw$batch_id-1L)*5L+6L)
draw$sample_id <- (draw$batch_id-1L)*10L+draw$batch_slot
draw <- draw[order(draw$sample_id),]
dbWriteTable(con,'draw',draw,overwrite=TRUE)
dbExecute(con,"CREATE TEMP TABLE ordered_eligible AS SELECT source_file,source_row,
 CASE WHEN parent_adjusted_count=1 THEN 'assigned' ELSE 'unassigned' END sample_group,
 row_number() OVER(PARTITION BY CASE WHEN parent_adjusted_count=1 THEN 'assigned' ELSE 'unassigned' END
  ORDER BY source_file,source_row) group_position
 FROM eligible WHERE parent_adjusted_count IN (0,1)")
sample <- dbGetQuery(con,"WITH chosen AS (
 SELECT o.source_file,o.source_row,d.* FROM ordered_eligible o JOIN draw d
  ON d.group=o.sample_group AND d.group_position=o.group_position)
 SELECT d.sample_id,d.batch_id,d.batch_slot,d.group sample_group,
 'GPA'||lpad(CAST(d.sample_id AS VARCHAR),3,'0') entry_id,
 CAST(e.user_id AS VARCHAR) user_id,e.source_file,CAST(e.source_row AS VARCHAR) source_row,
 e.university_raw,e.university_name,e.rsid,e.university_country,e.degree_raw,e.degree,
 e.br_oa_level pipeline_degree_level,e.field_raw,e.field,e.description,
 CAST(e.startdate AS VARCHAR) startdate,CAST(e.enddate AS VARCHAR) enddate,
 e.global_oa_match_route,e.global_oa_selection_stage,e.global_oa_selection_status,
 array_to_string(e.global_oa_candidate_ids,'|') original_candidate_ids,
 array_to_string(e.global_oa_selected_ids,'|') original_selected_ids,
 array_to_string(e.parent_adjusted_ids,'|') parent_adjusted_ids,
 e.parent_adjusted_count,e.parent_replacement_applied,e.ambiguous_parent_present,
 p.display_name parent_adjusted_name,p.type parent_adjusted_type,p.country_code parent_adjusted_country,
 CASE WHEN e.parent_adjusted_count=1 THEN 'https://openalex.org/'||e.parent_adjusted_ids[1] END parent_adjusted_url
 FROM eligible e JOIN chosen d USING(source_file,source_row)
 LEFT JOIN oa p ON e.parent_adjusted_count=1 AND p.oa_id=e.parent_adjusted_ids[1]
 ORDER BY d.sample_id")
stopifnot(nrow(sample)==200L,!anyDuplicated(paste(sample$source_file,sample$source_row)),
 all(table(sample$sample_group)==100L),
 all(table(sample$batch_id)==10L),
 all(tapply(sample$sample_group=='assigned',sample$batch_id,sum)==5L),
 all(sample$parent_adjusted_count[sample$sample_group=='assigned']==1L),
 all(sample$parent_adjusted_count[sample$sample_group=='unassigned']==0L))
meta <- list(seed=20260910,rng=RNGkind(),r_version=R.version.string,
 sample_size=200L,assigned=100L,unassigned=100L,batches=20L,batch_size=10L,
 ordering=c('source_file','source_row'),population=population,
 eligibility="Revelio Bachelor/Master/Doctor OR production bachelor/master/phd; global rx_hs veto",
 parent_rule="Replace with unique immediate OA parent; retain original for zero or multiple parents; deduplicate; exclude entries still having multiple IDs",
 batch_rule='Each batch has five assigned and five unassigned entries',
 inputs=checksums,draw=draw)
frozen <- file.path(audit_dir,'sample.rds')
if(file.exists(frozen)) {
 prior <- readRDS(frozen)
 stopifnot(identical(prior$meta,meta),identical(prior$sample,sample))
} else {
 saveRDS(list(meta=meta,sample=sample),frozen)
 write_json(meta,file.path(audit_dir,'metadata.json'),pretty=TRUE,auto_unbox=TRUE,dataframe='rows',na='null')
 write_json(sample,file.path(audit_dir,'sample.json'),pretty=TRUE,auto_unbox=TRUE,dataframe='rows',na='null')
 for(b in 1:20) write_json(sample[sample$batch_id==b,],
  file.path(audit_dir,'batches',sprintf('batch_%02d.json',b)),pretty=TRUE,auto_unbox=TRUE,dataframe='rows',na='null')
}
write_json(dbGetQuery(con,"SELECT oa_id,display_name,type,country_code,display_name_alternatives,display_name_acronyms
 FROM oa ORDER BY oa_id"),file.path(audit_dir,'oa_catalog_reference.json'),dataframe='rows',na='null')
cat('Frozen sample. Population:\n');print(population);print(table(sample$sample_group,sample$pipeline_degree_level))

review_paths <- file.path(audit_dir,'reviews',sprintf('batch_%02d.json',1:20))
if(all(file.exists(review_paths))) {
 required <- c('entry_id','verdict','supporting_oa_id','supporting_name','relationship','reason',
  'evidence_type','evidence_url','evidence_note','degree_issue','degree_issue_note','reviewer')
 parts <- vector('list',20L)
 for(b in 1:20) {
  part <- fromJSON(review_paths[b])
  stopifnot(nrow(part)==10L,all(required %in% names(part)),
   setequal(part$entry_id,sample$entry_id[sample$batch_id==b]))
  parts[[b]] <- part[required]
 }
 labels <- do.call(rbind,parts)
 labels <- labels[match(sample$entry_id,labels$entry_id),]
 stopifnot(!anyDuplicated(labels$entry_id),setequal(labels$entry_id,sample$entry_id),
  all(nzchar(labels$reason)),all(labels$degree_issue %in% c(TRUE,FALSE)))
 assigned <- sample$sample_group=='assigned'
 stopifnot(all(labels$verdict[assigned] %in% c('same','associated','incorrect','unclear')),
  all(labels$verdict[!assigned] %in% c('same_found','associated_found','no_verified_match','unclear')))
 catalog_ids <- dbGetQuery(con,'SELECT oa_id FROM oa')$oa_id
 positive <- labels$verdict %in% c('same','associated','same_found','associated_found')
 stopifnot(all(labels$supporting_oa_id[positive] %in% catalog_ids),
  all(labels$supporting_oa_id[assigned & labels$verdict %in% c('same','associated')] == sample$parent_adjusted_ids[assigned & labels$verdict %in% c('same','associated')]),
  all(grepl('^https?://',labels$evidence_url[labels$evidence_type=='web'])),
  all(labels$evidence_type[labels$verdict %in% c('associated','associated_found')]=='web'))
 reviewed <- cbind(sample,labels[setdiff(names(labels),'entry_id')])
 counts <- list(sample=200L,assigned=100L,unassigned=100L,
  same=sum(assigned & labels$verdict=='same'),associated=sum(assigned & labels$verdict=='associated'),
  incorrect=sum(assigned & labels$verdict=='incorrect'),assigned_unclear=sum(assigned & labels$verdict=='unclear'),
  same_found=sum(!assigned & labels$verdict=='same_found'),associated_found=sum(!assigned & labels$verdict=='associated_found'),
  no_verified_match=sum(!assigned & labels$verdict=='no_verified_match'),unassigned_unclear=sum(!assigned & labels$verdict=='unclear'),
  degree_issues=sum(labels$degree_issue))
 z <- qnorm(.975)
 rates <- data.frame(
  measure=c('Assigned acceptance, resolved','Assigned acceptance, unclear as failure',
   'Unassigned match discovery, resolved','Unassigned match discovery, unclear as failure'),
  successes=c(counts$same+counts$associated,counts$same+counts$associated,
   counts$same_found+counts$associated_found,counts$same_found+counts$associated_found),
  denominator=c(100L-counts$assigned_unclear,100L,100L-counts$unassigned_unclear,100L))
 rates$rate <- rates$successes/rates$denominator
 rates$lower <- (rates$rate+z*z/(2*rates$denominator)-z*sqrt(rates$rate*(1-rates$rate)/rates$denominator+z*z/(4*rates$denominator^2)))/(1+z*z/rates$denominator)
 rates$upper <- (rates$rate+z*z/(2*rates$denominator)+z*sqrt(rates$rate*(1-rates$rate)/rates$denominator+z*z/(4*rates$denominator^2)))/(1+z*z/rates$denominator)
 stopifnot(counts$same+counts$associated+counts$incorrect+counts$assigned_unclear==100L,
  counts$same_found+counts$associated_found+counts$no_verified_match+counts$unassigned_unclear==100L,
  identical(checksums$md5,unname(tools::md5sum(checksums$path))))
 write_json(labels,file.path(audit_dir,'labels.json'),dataframe='rows',pretty=TRUE,na='null')
 write_json(reviewed,file.path(audit_dir,'reviewed_entries.json'),dataframe='rows',pretty=TRUE,na='null')
 write_json(list(counts=counts,rates=rates,z=z,checks=list(unique_rows=TRUE,balanced_sample=TRUE,
  complete_batches=TRUE,degree_eligible=TRUE,multiple_parent_adjusted_excluded=TRUE,
  supporting_ids_valid=TRUE,input_checksums_unchanged=TRUE)),file.path(audit_dir,'analysis.json'),
  dataframe='rows',pretty=TRUE,auto_unbox=TRUE,na='null',digits=15)
 print(counts);print(rates)
} else cat('Manual review pending:',sum(!file.exists(review_paths)),'batches.\n')
dbDisconnect(con,shutdown=TRUE)
