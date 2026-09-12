# Offline synthetic validation in the repository's default OBMEP test area.
library(DBI)
library(duckdb)
library(stringdist)
library(jsonlite)
test_dir <- 'C:/Users/megaj/Globtalent Dropbox/OBMEP/test/global_oa_hierarchy'
dir.create(test_dir,recursive=TRUE,showWarnings=FALSE)
con <- dbConnect(duckdb())
source('prep/building_external_data/global_oa_hierarchy_sql.R')
dbExecute(con,"CREATE TABLE catalog AS SELECT * FROM (VALUES
 ('I1','BR'),('I2','US'),('I3',NULL),('I4','BR'),('I5','BR')) t(oa_id,country_code)")
dbExecute(con,"CREATE TABLE aliases AS SELECT oa_id,alias,strip_accents(lower(trim(alias))) alias_norm,
 alias_kind,alias_kind<>'acronym' name_eligible FROM (VALUES
 ('I1','Universidade S\u00e3o Paulo','primary'),('I1','Alpha University','alternative'),('I1','USP','acronym'),
 ('I2','Alpha University','primary'),('I2','MIT','acronym'),('I3','Zed Research','primary'),
 ('I4','Other Institution','primary'),('I4','USP','acronym'),('I5','MARHTA','primary')) t(oa_id,alias,alias_kind)")
dbExecute(con,"CREATE TABLE decision_batch AS SELECT decision_id,university_raw,country_code,candidate_ids,
 strip_accents(lower(trim(university_raw))) raw_norm,strip_accents(trim(university_raw)) raw_case,
 list_transform(regexp_split_to_array(strip_accents(lower(trim(university_raw))),'[/()|]| - '),x->trim(x)) raw_segments
 FROM (VALUES
 (1,'  UNIVERSIDADE SAO PAULO  ','BR',['I1','I2']),
 (2,'Alpha University','BR',['I1','I2']),
 (3,'Campus Alpha University / USP','BR',['I1','I2','I4']),
 (4,'Department USP campus','BR',['I1','I4']),
 (5,'Department usp campus','BR',['I1','I4']),
 (6,'usp',NULL,['I1','I4']),
 (7,'Department (usp)','BR',['I1','I4']),
 (8,'Department - usp','BR',['I1','I4']),
 (9,'xAlpha Universityz',NULL,['I1','I2']),
 (10,'','BR',['I1','I2']),
 (11,NULL,NULL,['I1']),
 (12,'No institution',NULL,NULL::VARCHAR[]),
 (13,'MARTHA',NULL,['I5']),
 (14,'Zed Research',NULL,['I3']),
 (15,'Department \u00e9Alpha University\u00e9',NULL,['I1','I2']),
 (16,'Department | mit','US',['I2']),
 (17,'Submit campus','US',['I2']),
 (18,'Alpha University','US',['I3']),
 (19,'University elsewhere',NULL,['I1','I2']),
 (20,'USP','US',['I1','I4']),
 (21,'Department/usp/campus','BR',['I1','I4']),
 (22,'Alpha Universiti',NULL,['I1','I2']),
 (23,'Alpha Universiti','BR',['I1','I2'])
 ) t(decision_id,university_raw,country_code,candidate_ids)")
unicode_scores <- dbGetQuery(con,hierarchy_unicode_pairs_sql)
unicode_scores$jaro <- stringsim(unicode_scores$raw_norm,unicode_scores$alias_norm,method='jw',p=0,useBytes=FALSE)
dbWriteTable(con,'unicode_scores',unicode_scores)
dbExecute(con,paste('CREATE TABLE evaluations AS',hierarchy_evaluation_sql))
dbExecute(con,paste('CREATE TABLE selected AS',hierarchy_decision_sql))
r <- dbGetQuery(con,'SELECT decision_id,selection_stage,selected_count,selection_status FROM selected ORDER BY 1')
print(r)
stopifnot(identical(r$selection_stage,c(1L,1L,2L,3L,4L,3L,3L,3L,4L,NA_integer_,NA_integer_,NA_integer_,4L,1L,4L,3L,4L,4L,4L,3L,3L,4L,4L)),
 all(r$selected_count[c(2,3,4,6,7,8,20,21,22)]==2),r$selected_count[23]==1,all(r$selected_count[10:12]==0),
 dbGetQuery(con,"SELECT count(*) n FROM selected WHERE selected_count>0 AND NOT list_has_all(candidate_ids,selected_ids)")$n==0,
 dbGetQuery(con,'SELECT country_match n FROM evaluations WHERE decision_id=14')$n==0)
# MARTHA/MARHTA: Jaro=17/18; prefix 3 -> JW=173/180.
score <- dbGetQuery(con,'SELECT jw_similarity FROM evaluations WHERE decision_id=13')$jw_similarity
stopifnot(abs(score-173/180)<1e-12)
f <- data.frame(a=c('MARTHA','DIXON','JELLYFISH','ab','ABC','same','a\u00e7\u00e3o'),
 b=c('MARHTA','DICKSONX','SMELLYFISH','ac','XYZ','same','ac\u00e3o'))
dbWriteTable(con,'score_fixtures',f)
q <- dbGetQuery(con,"SELECT *,jaro_similarity(a,b) jaro,
 least(4,length(a),length(b),CASE WHEN substr(a,1,1)<>substr(b,1,1) THEN 0
 WHEN substr(a,2,1)<>substr(b,2,1) THEN 1 WHEN substr(a,3,1)<>substr(b,3,1) THEN 2
 WHEN substr(a,4,1)<>substr(b,4,1) THEN 3 ELSE 4 END) prefix FROM score_fixtures")
unicode <- nchar(f$a,type='bytes')!=nchar(f$a,type='chars') | nchar(f$b,type='bytes')!=nchar(f$b,type='chars')
q$jaro[unicode] <- stringsim(f$a[unicode],f$b[unicode],method='jw',p=0)
explicit <- q$jaro+ifelse(q$jaro>0.7,0.1*q$prefix*(1-q$jaro),0)
independent <- ifelse(stringsim(f$a,f$b,method='jw',p=0)>0.7,
 stringsim(f$a,f$b,method='jw',p=0.1,bt=0),stringsim(f$a,f$b,method='jw',p=0))
print(data.frame(f,explicit,independent))
stopifnot(max(abs(explicit-independent))<1e-12)
# Restart/batch order must preserve complete decisions and floating scores.
dbExecute(con,'CREATE TABLE frozen AS SELECT * FROM selected')
dbExecute(con,'CREATE OR REPLACE TABLE decision_batch AS SELECT * FROM decision_batch ORDER BY decision_id DESC')
dbExecute(con,paste('CREATE OR REPLACE TABLE evaluations AS',hierarchy_evaluation_sql))
dbExecute(con,paste('CREATE OR REPLACE TABLE selected AS',hierarchy_decision_sql))
stopifnot(dbGetQuery(con,'SELECT count(*) n FROM ((SELECT * FROM frozen EXCEPT ALL SELECT * FROM selected) UNION ALL (SELECT * FROM selected EXCEPT ALL SELECT * FROM frozen))')$n==0)
# The crosswalk deliberately propagates both many-to-many directions; physical
# duplicate records remain two distinct rows, including a user above 2^53.
dbExecute(con,"CREATE TABLE evidence AS SELECT * FROM (VALUES (1,'I1'),(1,'I2'),(2,'I1'),(1,'I1')) t(rsid,oa_id)")
dbExecute(con,'CREATE TABLE links AS SELECT DISTINCT * FROM evidence')
dbExecute(con,"CREATE TABLE original AS SELECT * FROM (VALUES
 (9007199254740993::BIGINT,1,0),(9007199254740993::BIGINT,1,1),(4,99,2),(5,NULL,3),(6,2147483647,4)) t(user_id,rsid,source_row)")
dbExecute(con,"CREATE TABLE propagated AS SELECT e.*,s.ids FROM original e LEFT JOIN
 (SELECT rsid,list(oa_id ORDER BY oa_id) ids FROM links GROUP BY rsid) s USING(rsid)")
stopifnot(dbGetQuery(con,'SELECT count(*) n FROM propagated')$n==5,
 dbGetQuery(con,'SELECT count(*) n FROM propagated WHERE user_id=9007199254740993 AND len(ids)=2')$n==2,
 dbGetQuery(con,"SELECT count(*) n FROM links WHERE oa_id='I1'")$n==2)
dbExecute(con,"CREATE TABLE raw_fixture AS SELECT id,raw,strip_accents(lower(trim(raw))) folded FROM (VALUES
 (1,'Alpha University'),(2,' ALPHA UNIVERSITY '),(3,'Department/Alpha University'),
 (4,'Department (Alpha University)'),(5,'Department | Alpha University'),
 (6,'Department - Alpha University'),(7,'Department-Alpha University'),(8,'Other')) t(id,raw)")
upstream <- dbGetQuery(con,"SELECT id,bool_or(raw='Alpha University') c_exact,
 bool_or(folded='alpha university') whole,
 bool_or(trim(part)='alpha university') segment
 FROM raw_fixture CROSS JOIN unnest(regexp_split_to_array(folded,'[/()|]| - ')) u(part)
 GROUP BY id ORDER BY id")
stopifnot(identical(upstream$c_exact,c(TRUE,rep(FALSE,7))),
 identical(upstream$whole,c(TRUE,TRUE,rep(FALSE,6))),
 identical(upstream$segment,c(rep(TRUE,6),FALSE,FALSE)))
source('prep/building_external_data/br_degree_patterns.R')
dbExecute(con,'CREATE MACRO regexp_like(s,p) AS regexp_matches(s,p)')
degree_cases <- data.frame(degree_raw=c('high school','curso tecnico','bacharelado','mestrado','doutorado',
 'MBA','pos-doutorado','exchange program','especializacao lato sensu'),
 degree=c('Bachelor','Bachelor','High School','Bachelor','Master','MBA','Doctor','Bachelor','empty'),
 expected=c('other','other','bachelor','master','phd','master','other','other','other'))
dbWriteTable(con,'degree_cases',degree_cases)
dg <- dbGetQuery(con,sprintf("SELECT *,CASE WHEN regexp_like(dr,'%s') THEN 'other' ELSE (%s) END actual
 FROM (SELECT *,lower(trim(degree_raw)) dr FROM degree_cases)",rx_hs,sql_shanghai_level))
stopifnot(all(dg$actual==dg$expected))
# Exact numeric tolerance, without rounding or secondary tie-breaking.
dbExecute(con,'CREATE OR REPLACE TABLE evaluations AS SELECT * FROM evaluations WHERE decision_id=22')
dbExecute(con,"UPDATE evaluations SET score=CASE WHEN oa_id='I1' THEN 0.8 ELSE 0.8-5e-13 END,candidate_stage=NULL")
dbExecute(con,paste('CREATE OR REPLACE TABLE selected AS',hierarchy_decision_sql))
stopifnot(dbGetQuery(con,'SELECT selected_count n FROM selected WHERE decision_id=22')$n==2)
dbExecute(con,"UPDATE evaluations SET score=0.8-2e-12 WHERE oa_id='I2'")
dbExecute(con,paste('CREATE OR REPLACE TABLE selected AS',hierarchy_decision_sql))
stopifnot(dbGetQuery(con,'SELECT selected_count n FROM selected WHERE decision_id=22')$n==1)
write_json(list(passed=TRUE,selection_cases=nrow(r),scores=length(independent),
 stringdist_version=as.character(packageVersion('stringdist')),duckdb=dbGetQuery(con,'SELECT version()')[[1]],
 maximum_score_difference=max(abs(explicit-independent)),batch_order_identical=TRUE,
 many_to_many_and_bigint=TRUE,upstream_c_and_c_norm=TRUE,degree_cases=nrow(dg),numeric_tie_tolerance=TRUE),file.path(test_dir,'test_report.json'),pretty=TRUE,auto_unbox=TRUE)
print(r)
dbDisconnect(con,shutdown=TRUE)
cat('Global hierarchy fixtures passed.\n')
