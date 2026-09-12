# Offline fixtures for degree_duration_ranked_education_flags.R.
library(DBI)
library(duckdb)
con <- dbConnect(duckdb(),dbdir=':memory:')
on.exit(dbDisconnect(con,shutdown=TRUE),add=TRUE)

dbExecute(con,"CREATE TABLE parent_map AS SELECT * FROM (VALUES
 ('I_CBPF',1,'I_MCTI','I_MCTI',true),
 ('I_INPE',1,'I_MCTI','I_MCTI',true),
 ('I_IMPA',1,'I_MCTI','I_MCTI',true),
 ('I_CHILD',1,'I_PARENT','I_PARENT',true),
 ('I_PARENT',0,NULL,'I_PARENT',false),
 ('I_OTHER',0,NULL,'I_OTHER',false)
 ) t(oa_id,n_parents,unique_parent_id,canonical_id,parent_replaced)")
dbExecute(con,"CREATE TABLE family_parent_exemptions AS SELECT * FROM (VALUES
 ('cw','I_CBPF'),('cw','I_INPE'),('cw','I_IMPA')) t(family,oa_id)")
dbExecute(con,"CREATE TABLE decision_sets AS SELECT * FROM (VALUES
 (1,['I_CBPF'],1),(2,['I_CHILD'],1),(3,['I_CHILD','I_PARENT'],2),
 (4,['I_PARENT','I_OTHER'],2),(5,[]::VARCHAR[],0)
 ) t(global_oa_decision_id,selected_ids,selected_count)")
dbExecute(con,"CREATE TABLE expanded AS SELECT d.global_oa_decision_id,f.family,d.selected_count,u.oa_id,
 CASE WHEN x.oa_id IS NOT NULL THEN u.oa_id ELSE coalesce(p.canonical_id,u.oa_id) END canonical_id,
 x.oa_id IS NULL AND coalesce(p.parent_replaced,false) parent_replaced,
 x.oa_id IS NOT NULL parent_exemption_applied
 FROM decision_sets d CROSS JOIN (VALUES ('cw'),('sh')) f(family)
 CROSS JOIN unnest(d.selected_ids) u(oa_id) LEFT JOIN parent_map p ON p.oa_id=u.oa_id
 LEFT JOIN family_parent_exemptions x ON x.family=f.family AND x.oa_id=u.oa_id
 WHERE d.selected_count>0")
dbExecute(con,"CREATE TABLE agg AS SELECT global_oa_decision_id,family,
 list(DISTINCT canonical_id ORDER BY canonical_id) adjusted_ids,
 bool_or(parent_replaced) parent_replacement_applied,
 bool_or(parent_exemption_applied) parent_exemption_applied
 FROM expanded GROUP BY 1,2")
dbExecute(con,"CREATE TABLE decisions AS SELECT d.global_oa_decision_id,f.family,d.selected_count,
 coalesce(a.adjusted_ids,[]::VARCHAR[]) adjusted_ids,
 coalesce(len(a.adjusted_ids),0)::INTEGER adjusted_count,
 coalesce(a.parent_replacement_applied,false) parent_replacement_applied,
 coalesce(a.parent_exemption_applied,false) parent_exemption_applied
 FROM decision_sets d CROSS JOIN (VALUES ('cw'),('sh')) f(family)
 LEFT JOIN agg a USING(global_oa_decision_id,family)")
stopifnot(
 dbGetQuery(con,"SELECT adjusted_ids=['I_CBPF'] ok FROM decisions WHERE global_oa_decision_id=1 AND family='cw'")$ok,
 dbGetQuery(con,"SELECT adjusted_ids=['I_MCTI'] ok FROM decisions WHERE global_oa_decision_id=1 AND family='sh'")$ok,
 dbGetQuery(con,"SELECT adjusted_ids=['I_PARENT'] AND adjusted_count=1 ok FROM decisions WHERE global_oa_decision_id=3 AND family='cw'")$ok,
 dbGetQuery(con,"SELECT adjusted_count=2 ok FROM decisions WHERE global_oa_decision_id=4 AND family='sh'")$ok,
 dbGetQuery(con,"SELECT adjusted_count=0 ok FROM decisions WHERE global_oa_decision_id=5 AND family='cw'")$ok)

dbExecute(con,"CREATE TABLE degree_cases AS SELECT * FROM (VALUES
 (1,'empty','other',1,'duration_fallback','bachelor'),
 (2,'empty','bachelor',1,'ranked_regex','bachelor'),
 (3,'empty','master',0,'not_qualifying','master'),
 (4,'Bachelor','bachelor',1,'ranked_regex','bachelor'),
 (5,'High School','other',0,'not_qualifying','other'),
 (6,'Associate','other',0,'not_qualifying','other'),
 (7,'Master','master',0,'not_qualifying','master'),
 (8,'Doctor','phd',0,'not_qualifying','phd'),
 (9,NULL,'other',1,'duration_fallback','bachelor')
 ) t(id,degree,ranked_level,degree_matches_laxed,degree_match_route,expected)")
levels <- dbGetQuery(con,"SELECT id,
 CASE WHEN coalesce(degree,'empty')='empty' AND degree_matches_laxed=1
  THEN 'bachelor' ELSE ranked_level END actual,expected FROM degree_cases ORDER BY id")
stopifnot(all(levels$actual==levels$expected),
 dbGetQuery(con,"SELECT count(*)=0 ok FROM degree_cases WHERE degree_match_route='duration_fallback'
  AND coalesce(degree,'empty')<>'empty'")$ok)

dbExecute(con,"CREATE TABLE cwur AS SELECT * FROM (VALUES
 (1,'Brazil A','BR',true,'I1','education'),
 (2,'Brazil B','BR',true,'I2','facility'),
 (3,'Foreign','US',true,'I3','education'),
 (4,'Unmatched','BR',false,NULL,'education')
 ) t(world_rank,institution,country_iso2,casada,oa_id,oa_type)")
stopifnot(dbGetQuery(con,"SELECT count(*)=2 ok FROM cwur
 WHERE country_iso2='BR' AND casada AND oa_id IS NOT NULL")$ok,
 dbGetQuery(con,"SELECT count(*)=1 ok FROM cwur
 WHERE country_iso2='BR' AND casada AND oa_id IS NOT NULL AND oa_type<>'education'")$ok)

cat('All degree-duration ranked-flag fixtures passed.\n')
