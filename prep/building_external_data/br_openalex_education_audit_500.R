# Local prep. Sampling/analysis are offline; manual identity research uses the web.
# Never send to SEDAP. This audit does not change data, crosswalks, or flags.
library(DBI)
library(duckdb)
library(jsonlite)
options(stringsAsFactors=FALSE)
root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
audit_dir <- 'outputs/br-openalex-education-audit-500-20260908'
dir.create(file.path(audit_dir,'batches'),recursive=TRUE,showWarnings=FALSE)
dir.create(file.path(audit_dir,'reviews'),showWarnings=FALSE)
src <- file.path(root,'Data/intermediate/revelio_br_cohort/obmep_candidates_step_1_br_openalex_rsid_nofloor_matches.parquet')
# An archived copy can reproduce the frozen audit after production flags change.
# Metadata retains the original logical path; the frozen MD5 still must agree.
source_read <- Sys.getenv('OBMEP_BR_EDUCATION_AUDIT_SOURCE',src)
catalog <- file.path(root,'Data/intermediate/openalex_institutions/openalex_institutions_br.parquet')
patterns <- 'prep/building_external_data/br_degree_patterns.R'
source(patterns)
checksums <- tools::md5sum(c(source_read,catalog,patterns))
names(checksums) <- c(src,catalog,patterns)
con <- dbConnect(duckdb())
dbExecute(con,"SET memory_limit='8GB'")
dbExecute(con,'SET threads=4')
dbExecute(con,sprintf("CREATE VIEW eligible AS SELECT *,lower(trim(coalesce(degree_raw,''))) dr
 FROM read_parquet('%s') WHERE (degree IN ('Bachelor','Master','Doctor') OR br_oa_level IN ('bachelor','master','phd'))
 AND NOT regexp_matches(lower(trim(coalesce(degree_raw,''))),'%s')",source_read,rx_hs))
population <- dbGetQuery(con,'SELECT count(*) n FROM eligible')$n
RNGkind('Mersenne-Twister','Inversion','Rejection')
set.seed(20260908)
draw <- sample.int(population,500L,replace=FALSE)
dbWriteTable(con,'draw',data.frame(sample_id=seq_len(500L),position=draw))
s <- dbGetQuery(con,"WITH ordered AS (SELECT source_file,source_row,row_number() OVER(ORDER BY source_file,source_row) AS position FROM eligible),
 chosen AS (SELECT o.source_file,o.source_row,d.sample_id FROM ordered o JOIN draw d USING(position))
 SELECT d.sample_id,CAST(ceil(d.sample_id/10.0) AS INTEGER) batch_id,
 CAST(e.user_id AS VARCHAR) user_id,e.source_file,CAST(e.source_row AS VARCHAR) source_row,
 e.university_raw,e.university_name,e.rsid,e.university_country,e.degree_raw,e.degree,
 e.field_raw,e.field,e.description,CAST(e.startdate AS VARCHAR) startdate,CAST(e.enddate AS VARCHAR) enddate,
 e.br_oa_level,e.br_oa_match_route,e.br_oa_ids_pipe,e.br_oa_candidate_count,
 CAST(to_json(e.br_oa_candidates) AS VARCHAR) candidates_json
 FROM eligible e JOIN chosen d USING(source_file,source_row) ORDER BY d.sample_id")
s$entry_id <- sprintf('BR%03d',s$sample_id)
meta <- list(seed=20260908,rng=RNGkind(),r_version=R.version.string,population=population,
 sample_size=500L,sort=c('source_file','source_row'),positions=draw,
 inputs=data.frame(path=names(checksums),md5=unname(checksums)),
 eligibility="Revelio Bachelor/Master/Doctor OR existing bachelor/master/phd classification; exclude rx_hs globally")
frozen <- file.path(audit_dir,'sample.rds')
if(file.exists(frozen)) {
 prior <- readRDS(frozen)
 stopifnot(identical(prior$meta,meta),identical(prior$sample,s))
} else {
 saveRDS(list(meta=meta,sample=s),frozen)
 write_json(meta,file.path(audit_dir,'metadata.json'),auto_unbox=TRUE,pretty=TRUE,dataframe='rows')
 write_json(s,file.path(audit_dir,'sample.json'),auto_unbox=TRUE,pretty=TRUE,dataframe='rows',na='null')
 for(b in 1:50) write_json(s[s$batch_id==b,],file.path(audit_dir,'batches',sprintf('batch_%02d.json',b)),auto_unbox=TRUE,pretty=TRUE,dataframe='rows',na='null')
}
stopifnot(nrow(s)==500L,!anyDuplicated(paste(s$source_file,s$source_row)),all(table(s$batch_id)==10L),
 identical(unname(checksums),unname(tools::md5sum(c(source_read,catalog,patterns)))))
print(table(s$br_oa_match_route))
cat('Sample frozen:',population,'eligible rows; 500 entries in 50 batches.\n')
dbDisconnect(con,shutdown=TRUE)
if('--verify-sample-only' %in% commandArgs(trailingOnly=TRUE)) quit(status=0L)

review_paths <- file.path(audit_dir,'reviews',sprintf('batch_%02d.json',1:50))
if(all(file.exists(review_paths))) {
  review_parts <- vector('list',50L)
  required <- c('entry_id','verdict','supporting_oa_id','relationship','reason','evidence_type',
    'evidence_url','evidence_note','degree_verdict','degree_reason','reviewer')
  for(b in 1:50) {
    part <- fromJSON(review_paths[b])
    stopifnot(nrow(part)==10L,all(required %in% names(part)),
      setequal(part$entry_id,s$entry_id[s$batch_id==b]))
    review_parts[[b]] <- part[required]
  }
  labels <- do.call(rbind,review_parts)
  stopifnot(!anyDuplicated(labels$entry_id),setequal(labels$entry_id,s$entry_id))
  labels <- labels[match(s$entry_id,labels$entry_id),]
  stopifnot(all(labels$verdict %in% c('same','affiliate','incorrect','unclear','unmatched')),
    all(labels$degree_verdict %in% c('eligible','ineligible','unclear')),
    all(nzchar(labels$reason)),all(nzchar(labels$degree_reason)))
  for(i in seq_len(500L)) {
    candidates <- if(is.na(s$candidates_json[i])) NULL else fromJSON(s$candidates_json[i])
    positive <- labels$verdict[i] %in% c('same','affiliate')
    stopifnot((labels$verdict[i]=='unmatched')==(s$br_oa_candidate_count[i]==0L))
    if(positive) stopifnot(labels$supporting_oa_id[i] %in% candidates$openalex_id)
    if(labels$verdict[i]=='affiliate') stopifnot(labels$evidence_type[i]=='web',grepl('^https?://',labels$evidence_url[i]))
    if(labels$evidence_type[i]=='web') stopifnot(grepl('^https?://',labels$evidence_url[i]))
  }
  reviewed <- cbind(s,labels[setdiff(names(labels),'entry_id')])
  good_degree <- reviewed$degree_verdict=='eligible'
  matched <- reviewed$br_oa_candidate_count>0
  accepted <- reviewed$verdict %in% c('same','affiliate')
  counts <- list(sample=500L,matched=sum(matched),unmatched=sum(!matched),
    eligible=sum(good_degree),ineligible=sum(reviewed$degree_verdict=='ineligible'),degree_unclear=sum(reviewed$degree_verdict=='unclear'),
    eligible_matched=sum(good_degree & matched),same=sum(good_degree & reviewed$verdict=='same'),
    affiliate=sum(good_degree & reviewed$verdict=='affiliate'),incorrect=sum(good_degree & reviewed$verdict=='incorrect'),
    unclear=sum(good_degree & reviewed$verdict=='unclear'),eligible_unmatched=sum(good_degree & !matched))
  precision <- data.frame(method=c('Resolved assignments','Unclear counted as failure'),
    accepted=rep(sum(good_degree & accepted),2),
    denominator=c(sum(good_degree & matched & reviewed$verdict!='unclear'),sum(good_degree & matched)))
  z <- qnorm(0.975)
  precision$rate <- with(precision,ifelse(denominator>0,accepted/denominator,NA_real_))
  precision$lower <- with(precision,ifelse(denominator>0,(rate+z*z/(2*denominator)-z*sqrt(rate*(1-rate)/denominator+z*z/(4*denominator^2)))/(1+z*z/denominator),NA_real_))
  precision$upper <- with(precision,ifelse(denominator>0,(rate+z*z/(2*denominator)+z*sqrt(rate*(1-rate)/denominator+z*z/(4*denominator^2)))/(1+z*z/denominator),NA_real_))
  stopifnot(counts$eligible_matched==counts$same+counts$affiliate+counts$incorrect+counts$unclear,
    counts$sample==counts$eligible+counts$ineligible+counts$degree_unclear,
    identical(checksums,tools::md5sum(c(src,catalog,patterns))))
  write_json(labels,file.path(audit_dir,'labels.json'),dataframe='rows',auto_unbox=TRUE,pretty=TRUE,na='null')
  write_json(reviewed,file.path(audit_dir,'reviewed_entries.json'),dataframe='rows',auto_unbox=TRUE,pretty=TRUE,na='null')
  write_json(list(counts=counts,precision=precision,z=z,checks=list(reproducible_sample=TRUE,
    complete_batches=TRUE,supporting_ids_valid=TRUE,input_checksums_unchanged=TRUE)),
    file.path(audit_dir,'analysis.json'),dataframe='rows',auto_unbox=TRUE,pretty=TRUE,na='null',digits=15)
  print(counts);print(precision)
} else cat('Manual review pending:',sum(!file.exists(review_paths)),'batches.\n')
