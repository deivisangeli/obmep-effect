# Local audit: R/DuckDB sampling and analysis are offline; manual research may use web sources.
# Never send to SEDAP. Production files and previous audits are read-only inputs.
library(DBI)
library(duckdb)
library(jsonlite)
options(stringsAsFactors=FALSE)
root <- Sys.getenv('OBMEP_ROOT','C:/Users/megaj/Globtalent Dropbox/OBMEP')
coh <- file.path(root,'Data/intermediate/revelio_br_cohort')
out <- 'outputs/education-flags-audit-500-20260908'
for(d in c('raw_batches','reveal_batches','blind_reviews','reviews')) dir.create(file.path(out,d),recursive=TRUE,showWarnings=FALSE)
br_path <- file.path(coh,'obmep_candidates_step_1_br_openalex_rsid_nofloor_matches.parquet')
sh_path <- file.path(coh,'obmep_candidates_step_1_shanghai_rsid_nofloor_matches.parquet')
br_catalog <- file.path(root,'Data/intermediate/openalex_institutions/openalex_institutions_br.parquet')
sh_catalog <- file.path(root,'Data/intermediate/shanghai_ranking/shanghai_ranking_oa_parents.parquet')
ruf_paths <- file.path(root,c('Data/intermediate/ruf_ranking/ruf_openalex_br_2025.parquet','Data/intermediate/ruf_ranking/ruf_stem_top10_institutions_2025.parquet'))
production <- fromJSON(file.path(coh,'education_flags_rebuild_report.json'))
input_paths <- unique(c(production$inputs$path,production$publication$target,production$protected_products$path,
 file.path(coh,c('education_flags_rebuild_report.json','obmep_candidates_step_1_br_openalex_rsid_nofloor_report.json',
 'obmep_candidates_step_1_shanghai_rsid_nofloor_report.json','obmep_candidates_step_1_ruf_degree_report.json'))))
previous <- 'outputs/br-openalex-education-audit-500-20260908'
previous_paths <- c(list.files(previous,full.names=TRUE),list.files(file.path(previous,'reviews'),full.names=TRUE),list.files(file.path(previous,'batches'),full.names=TRUE))
previous_paths <- previous_paths[!dir.exists(previous_paths)]
manifest_path <- file.path(out,'preservation_manifest.json')
if(!file.exists(manifest_path)) write_json(data.frame(path=c(input_paths,previous_paths),md5=unname(tools::md5sum(c(input_paths,previous_paths)))),manifest_path,pretty=TRUE,dataframe='rows',auto_unbox=TRUE)
preservation <- fromJSON(manifest_path)
stopifnot(identical(unname(tools::md5sum(preservation$path)),preservation$md5))
audit_mode <- if('--aggregate' %in% commandArgs(trailingOnly=TRUE)) 'aggregate' else if('--analyze' %in% commandArgs(trailingOnly=TRUE)) 'analyze' else 'prepare'
if(audit_mode=='prepare') {
con <- dbConnect(duckdb())
dbExecute(con,"SET memory_limit='8GB'")
dbExecute(con,'SET threads=4')
dbExecute(con,sprintf("CREATE VIEW br AS SELECT * FROM read_parquet('%s')",br_path))
dbExecute(con,sprintf("CREATE VIEW sh AS SELECT * FROM read_parquet('%s')",sh_path))
dbExecute(con,sprintf("CREATE TABLE ruf AS SELECT x.openalex_id,i.* FROM read_parquet('%s') x
 JOIN read_parquet('%s') i USING(ruf_institution_id)",ruf_paths[1],ruf_paths[2]))
stopifnot(dbGetQuery(con,'SELECT count(DISTINCT openalex_id) n FROM ruf')$n==23)
population <- dbGetQuery(con,'SELECT count(*) n FROM br')$n
stopifnot(population==15712737)
RNGkind('Mersenne-Twister','Inversion','Rejection');set.seed(20260909)
draw <- sample.int(population,500L,replace=FALSE)
dbWriteTable(con,'draw',data.frame(sample_id=1:500,position=draw))
dbExecute(con,"CREATE TABLE sampled AS WITH ordered AS (SELECT source_file,source_row,
 row_number() OVER(ORDER BY source_file,source_row) AS position FROM br),chosen AS (
 SELECT o.source_file,o.source_row,d.sample_id FROM ordered o JOIN draw d USING(position))
 SELECT d.sample_id,printf('EA%03d',d.sample_id) entry_id,CAST(ceil(d.sample_id/10.0) AS INTEGER) batch_id,
 b.*,s.sh_candidates,s.sh_match,s.sh_match_route,s.sh_level,s.sh_is_mba,s.sh_is_lato,s.sh_rank,s.sh_inst,s.sh_oa_key
 FROM chosen d JOIN br b USING(source_file,source_row) JOIN sh s USING(source_file,source_row)")
dbExecute(con,"CREATE TABLE sample_ruf AS SELECT s.entry_id,
 list(struct_pack(openalex_id:=r.openalex_id,name:=r.institution_name,abbr:=r.abbr,rank:=r.best_rank,ruf_id:=r.ruf_institution_id)
 ORDER BY r.best_rank,r.openalex_id,r.ruf_institution_id) candidates
 FROM sampled s CROSS JOIN UNNEST(s.br_oa_candidate_ids) u(oa_id) JOIN ruf r ON r.openalex_id=u.oa_id GROUP BY 1")
s <- dbGetQuery(con,"SELECT s.entry_id,s.sample_id,s.batch_id,CAST(s.user_id AS VARCHAR) user_id,s.source_file,
 CAST(s.source_row AS VARCHAR) source_row,s.university_raw,s.university_name,s.rsid,s.university_country,
 s.degree_raw,s.degree,s.field_raw,s.field,s.description,CAST(s.startdate AS VARCHAR) startdate,CAST(s.enddate AS VARCHAR) enddate,
 s.br_oa_level,s.br_oa_is_mba,s.br_oa_is_lato,s.br_oa_match_route,s.br_oa_ids_pipe,s.br_oa_candidate_count,
 CAST(to_json(s.br_oa_candidates) AS VARCHAR) br_candidates_json,
 CAST(to_json(r.candidates) AS VARCHAR) ruf_candidates_json,
 CAST(to_json(s.sh_candidates) AS VARCHAR) sh_candidates_json,s.sh_match_route,s.sh_level,s.sh_is_mba,s.sh_is_lato,
 s.sh_rank,s.sh_inst,s.sh_oa_key FROM sampled s LEFT JOIN sample_ruf r USING(entry_id) ORDER BY s.sample_id")
meta <- list(seed=20260909,rng=RNGkind(),r_version=R.version.string,population=population,sample_size=500L,
 sort=c('source_file','source_row'),positions=draw,input_checksums=preservation[match(c(br_path,sh_path,br_catalog,sh_catalog,ruf_paths),preservation$path),],
 scope='All physical education rows, including excluded and unmatched entries; three institution families and degree classifications')
frozen <- file.path(out,'sample.rds')
if(file.exists(frozen)) {
 prior <- readRDS(frozen);stopifnot(identical(prior$meta,meta),identical(prior$sample,s))
} else {
 saveRDS(list(meta=meta,sample=s),frozen)
 write_json(meta,file.path(out,'metadata.json'),pretty=TRUE,auto_unbox=TRUE,dataframe='rows')
 write_json(s,file.path(out,'sample.json'),pretty=TRUE,auto_unbox=TRUE,dataframe='rows',na='null')
 raw_fields <- c('entry_id','batch_id','university_raw','university_country','degree_raw','field_raw','description','startdate','enddate')
 for(b in 1:50) {
  write_json(s[s$batch_id==b,raw_fields],file.path(out,'raw_batches',sprintf('batch_%02d.json',b)),pretty=TRUE,auto_unbox=TRUE,dataframe='rows',na='null')
  write_json(s[s$batch_id==b,],file.path(out,'reveal_batches',sprintf('batch_%02d.json',b)),pretty=TRUE,auto_unbox=TRUE,dataframe='rows',na='null')
 }
}
stopifnot(nrow(s)==500,!anyDuplicated(paste(s$source_file,s$source_row)),all(table(s$batch_id)==10))
for(kind in c('br','ruf','sh')) {
 query <- switch(kind,br=sprintf("SELECT * FROM read_parquet('%s')",br_catalog),ruf='SELECT * FROM ruf',
  sh=sprintf("SELECT oa_key,shanghai_rank,shanghai_name,display_name,cleaned_display_name,oa_id_valid FROM read_parquet('%s') WHERE shanghai_rank<=901",sh_catalog))
 write_json(dbGetQuery(con,query),file.path(out,paste0(kind,'_catalog.json')),pretty=TRUE,auto_unbox=TRUE,dataframe='rows',na='null')
}
dbExecute(con,sprintf("COPY sampled TO '%s/sample.parquet' (FORMAT PARQUET,COMPRESSION ZSTD)",out))
cat('Frozen sample:',population,'rows; 500 entries in 50 batches.\n')
print(table(s$br_oa_match_route));print(table(s$br_oa_level))
dbDisconnect(con,shutdown=TRUE)
}

if(audit_mode=='aggregate') {
 source('prep/building_external_data/br_degree_patterns.R')
 con <- dbConnect(duckdb())
 dbExecute(con,"SET memory_limit='4GB'");dbExecute(con,'SET threads=4')
 dbExecute(con,'CREATE MACRO regexp_like(s,p) AS regexp_matches(s,p)')
 mismatches <- list();scope_results <- list();contexts <- list()
 for(scope in c('fixtures','sample')) {
  product_dir <- if(scope=='fixtures') file.path(root,'test/education_flags_rebuild/products') else coh
  br_input <- file.path(product_dir,'obmep_candidates_step_1_br_openalex_rsid_nofloor_matches.parquet')
  sh_input <- file.path(product_dir,'obmep_candidates_step_1_shanghai_rsid_nofloor_matches.parquet')
  if(scope=='fixtures') {
   dbExecute(con,sprintf("CREATE OR REPLACE TABLE selected_users AS SELECT DISTINCT user_id FROM read_parquet('%s')",br_input))
   ruf_map <- data.frame(openalex_id=c('I1','I2'),ruf_institution_id=c(2L,1L),abbr=c('ALPHA','BETA'),best_rank=c(1L,1L))
  } else {
   dbExecute(con,sprintf("CREATE OR REPLACE TABLE selected_users AS SELECT DISTINCT user_id FROM read_parquet('%s/sample.parquet')",out))
   ruf_map <- fromJSON(file.path(out,'ruf_catalog.json'))
  }
  scope_users <- dbGetQuery(con,'SELECT CAST(user_id AS VARCHAR) user_id FROM selected_users ORDER BY user_id')$user_id
  scope_results[[scope]] <- list(users=length(scope_users),families=list())
  for(kind in c('br','ruf','sh')) {
   pfx <- switch(kind,br='br_oa',ruf='rd',sh='sh')
   row_pfx <- if(kind=='sh') 'sh' else 'br_oa'
   path <- if(kind=='sh') sh_input else br_input
   computed <- sprintf("CASE WHEN regexp_like(dr,'%s') THEN 'other' ELSE (%s) END",rx_hs,sql_shanghai_level)
   rows <- dbGetQuery(con,sprintf("SELECT CAST(user_id AS VARCHAR) user_id,source_file,CAST(source_row AS VARCHAR) source_row,
    %1$s_level lvl,%1$s_is_mba is_mba,%1$s_is_lato is_lato,%1$s_start_year yr,%1$s_match_route route,
    CAST(to_json(%1$s_candidates) AS VARCHAR) candidates_json,(%3$s) recomputed_level
    FROM (SELECT e.*,lower(trim(coalesce(degree_raw,''))) dr FROM read_parquet('%2$s') e SEMI JOIN selected_users USING(user_id))",row_pfx,path,computed))
   stopifnot(all(rows$lvl==rows$recomputed_level))
   if(scope=='sample' && kind!='ruf') contexts[[kind]] <- rows
   ids <- keys <- vector('list',nrow(rows));ranks <- rep(NA_integer_,nrow(rows));insts <- inst_keys <- rep(NA_character_,nrow(rows));rids <- rep(NA_integer_,nrow(rows))
   for(i in seq_len(nrow(rows))) {
    cs <- if(is.na(rows$candidates_json[i])) NULL else fromJSON(rows$candidates_json[i])
    if(is.null(cs) || !nrow(cs)) {ids[[i]]<-keys[[i]]<-character();next}
    if(kind=='br') {ids[[i]]<-keys[[i]]<-sort(unique(cs$openalex_id));next}
    if(kind=='ruf') {
     cs <- ruf_map[ruf_map$openalex_id %in% cs$openalex_id,]
     if(!nrow(cs)){ids[[i]]<-keys[[i]]<-character();next}
     cs <- cs[order(cs$best_rank,cs$openalex_id,cs$ruf_institution_id,method='radix'),]
     ids[[i]]<-keys[[i]]<-sort(unique(cs$openalex_id));ranks[i]<-cs$best_rank[1];insts[i]<-cs$abbr[1];inst_keys[i]<-cs$openalex_id[1];rids[i]<-cs$ruf_institution_id[1]
    } else {
     cs <- cs[order(cs$shanghai_rank,cs$oa_key,method='radix'),]
     ids[[i]]<-sort(unique(cs$openalex_id[!is.na(cs$openalex_id)]));keys[[i]]<-sort(unique(cs$oa_key))
     ranks[i]<-cs$shanghai_rank[1];insts[i]<-cs$shanghai_name[1];inst_keys[i]<-cs$oa_key[1]
    }
   }
   matched <- lengths(keys)>0L
   flag_path <- file.path(product_dir,switch(kind,br='obmep_candidates_step_1_br_openalex_rsid_nofloor.parquet',ruf='obmep_candidates_step_1_ruf_degree.parquet',sh='obmep_candidates_step_1_shanghai.parquet'))
   actuals <- dbGetQuery(con,sprintf("SELECT CAST(f.user_id AS VARCHAR) user_id,CAST(to_json(f) AS VARCHAR) flag_json
    FROM read_parquet('%s') f SEMI JOIN selected_users USING(user_id)",flag_path))
   stopifnot(!anyDuplicated(actuals$user_id))
   comparisons <- 0L;positive <- 0L
   for(uid in scope_users) {
    ix <- which(rows$user_id==uid & matched)
    qual <- ix[rows$lvl[ix] %in% c('bachelor','master','phd')]
    ai <- match(uid,actuals$user_id)
    if(!length(qual)) {
     if(!is.na(ai)) mismatches[[length(mismatches)+1L]] <- data.frame(scope,kind,user_id=uid,field='presence',expected='absent',actual='present')
     next
    }
    positive <- positive+1L
    if(is.na(ai)){mismatches[[length(mismatches)+1L]]<-data.frame(scope,kind,user_id=uid,field='presence',expected='present',actual='absent');next}
    expected <- list(any=1L,rsid_any=as.integer(any(rows$route[qual]=='rsid')),raw_any=as.integer(any(rows$route[qual]=='raw_c_norm')),
     bachelor=as.integer(any(rows$lvl[ix]=='bachelor')),master=as.integer(any(rows$lvl[ix]=='master')),
     master_strict=as.integer(any((rows$lvl[ix]=='master' & !rows$is_mba[ix]) %in% TRUE)),phd=as.integer(any(rows$lvl[ix]=='phd')),
     lato=as.integer(any(rows$is_lato[ix] %in% TRUE)),n_rows=length(ix))
    for(level in c('bachelor','master','phd')) {
     short <- c(bachelor='bach',master='mast',phd='phd')[level]
     j <- ix[rows$lvl[ix]==level];years <- rows$yr[j];years<-years[!is.na(years)]
     expected[[paste0(short,'_year')]] <- if(length(years)) min(years) else NA_integer_
     expected[[paste0(short,'_institutions')]] <- sort(unique(as.character(unlist(ids[j],use.names=FALSE))))
     if(kind!='br') {
      expected[[paste0(short,'_rank')]] <- if(length(j)) min(ranks[j]) else NA_integer_
      bj <- j[order(ranks[j],inst_keys[j],rids[j],na.last=TRUE,method='radix')]
      expected[[paste0(short,'_inst')]] <- if(length(bj)) insts[bj[1]] else NA_character_
     }
     if(kind=='sh') expected[[paste0(short,'_institution_keys')]] <- sort(unique(as.character(unlist(keys[j],use.names=FALSE))))
    }
    strict <- ix[(rows$lvl[ix]=='master' & !rows$is_mba[ix]) %in% TRUE]
    expected$mast_strict_institutions <- sort(unique(as.character(unlist(ids[strict],use.names=FALSE))))
    if(kind!='br') expected$best_rank <- min(ranks[qual])
    if(kind=='ruf') {
     expected$name_any<-expected$raw_any;expected$abbr_any<-0L
     bq<-qual[order(ranks[qual],inst_keys[qual],rids[qual],method='radix')];expected$best_inst_id<-rids[bq[1]]
    }
    names(expected)<-paste0(pfx,'_',names(expected));actual<-fromJSON(actuals$flag_json[ai])
    stopifnot(setequal(names(expected),setdiff(names(actual),'user_id')))
    for(field in names(expected)) {
     ev<-expected[[field]];av<-actual[[field]]
     is_list<-grepl('_institutions$|_institution_keys$',field)
     if(!is_list && is.null(av)) av<-NA
     same<-identical(as.character(ev),as.character(av));comparisons<-comparisons+1L
     if(!same) mismatches[[length(mismatches)+1L]]<-data.frame(scope,kind,user_id=uid,field,
      expected=as.character(toJSON(ev,auto_unbox=!is_list,na='null')),actual=as.character(toJSON(av,auto_unbox=!is_list,na='null')))
    }
   }
   scope_results[[scope]]$families[[kind]]<-list(education_rows=nrow(rows),matched_rows=sum(matched),positive_users=positive,field_comparisons=comparisons)
   cat('Independent R aggregation:',scope,kind,positive,'positive users;',comparisons,'field comparisons.\n')
  }
 }
 errors <- if(length(mismatches)) do.call(rbind,mismatches) else data.frame()
 write_json(list(scopes=scope_results,mismatches=errors,passed=nrow(errors)==0),file.path(out,'aggregation_verification.json'),pretty=TRUE,auto_unbox=TRUE,dataframe='rows',na='null')
 for(kind in names(contexts)) write_json(contexts[[kind]],file.path(out,paste0('sampled_users_',kind,'_education.json')),pretty=TRUE,auto_unbox=TRUE,dataframe='rows',na='null')
 dbDisconnect(con,shutdown=TRUE)
 stopifnot(nrow(errors)==0)
}
