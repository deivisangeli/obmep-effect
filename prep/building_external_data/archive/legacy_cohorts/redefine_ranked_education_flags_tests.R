# Offline fixtures for redefine_ranked_education_flags.R. Never sent to SEDAP.
library(DBI)
library(duckdb)
con <- dbConnect(duckdb(),dbdir=':memory:')
on.exit(dbDisconnect(con,shutdown=TRUE),add=TRUE)

dbExecute(con,"CREATE TABLE parent_map AS SELECT * FROM (VALUES
 ('I1',0,NULL,'I1',false),
 ('I2',1,'I1','I1',true),
 ('I3',1,'I1','I1',true),
 ('I4',2,NULL,'I4',false),
 ('I5',0,NULL,'I5',false)
 ) t(oa_id,n_parents,unique_parent_id,canonical_id,parent_replaced)")
dbExecute(con,"CREATE TABLE decision_sets AS SELECT * FROM (VALUES
 (1,['I1'],1),(2,['I2'],1),(3,['I2','I3'],2),(4,['I1','I4'],2),
 (5,[]::VARCHAR[],0),(6,['I4'],1),(7,['I5'],1)
 ) t(global_oa_decision_id,selected_ids,selected_count)")
dbExecute(con,"CREATE TABLE expanded AS SELECT d.global_oa_decision_id,u.oa_id,
 coalesce(p.canonical_id,u.oa_id) canonical_id,coalesce(p.parent_replaced,false) parent_replaced
 FROM decision_sets d CROSS JOIN unnest(d.selected_ids) u(oa_id)
 LEFT JOIN parent_map p ON p.oa_id=u.oa_id WHERE d.selected_count>0")
dbExecute(con,"CREATE TABLE agg AS SELECT global_oa_decision_id,
 list(DISTINCT canonical_id ORDER BY canonical_id) parent_adjusted_ids,
 bool_or(parent_replaced) parent_replacement_applied FROM expanded GROUP BY 1")
dbExecute(con,"CREATE TABLE decisions AS SELECT d.*,
 coalesce(a.parent_adjusted_ids,[]::VARCHAR[]) parent_adjusted_ids,
 coalesce(len(a.parent_adjusted_ids),0)::INTEGER parent_adjusted_count,
 coalesce(a.parent_replacement_applied,false) parent_replacement_applied
 FROM decision_sets d LEFT JOIN agg a USING(global_oa_decision_id)")
stopifnot(
 dbGetQuery(con,"SELECT parent_adjusted_ids=['I1'] ok FROM decisions WHERE global_oa_decision_id=2")$ok,
 dbGetQuery(con,"SELECT parent_adjusted_ids=['I1'] ok FROM decisions WHERE global_oa_decision_id=3")$ok,
 dbGetQuery(con,"SELECT parent_adjusted_count=2 ok FROM decisions WHERE global_oa_decision_id=4")$ok,
 dbGetQuery(con,"SELECT parent_adjusted_count=0 ok FROM decisions WHERE global_oa_decision_id=5")$ok,
 dbGetQuery(con,"SELECT parent_adjusted_ids=['I4'] ok FROM decisions WHERE global_oa_decision_id=6")$ok)

dbExecute(con,"CREATE TABLE ranked_parent_catalog AS SELECT * FROM (VALUES
 ('rd','I1',1,'RUF Alpha',101,'I1'),
 ('sh','I2',20,'Shanghai Child B',NULL,'I1'),
 ('sh','I3',10,'Shanghai Child C',NULL,'I1'),
 ('sh','I4',30,'Ambiguous Parent School',NULL,'I4')
 ) t(family,oa_id,rk,inst,rid,canonical_id)")
dbExecute(con,"CREATE TABLE family_rank_sets AS SELECT family,canonical_id,
 list(DISTINCT oa_id ORDER BY oa_id) source_ids,min(rk)::INTEGER rk,
 first(inst ORDER BY rk,oa_id,rid NULLS LAST) inst,
 first(oa_id ORDER BY rk,oa_id,rid NULLS LAST) inst_key,
 first(rid ORDER BY rk,oa_id,rid NULLS LAST) rid
 FROM ranked_parent_catalog GROUP BY family,canonical_id")
stopifnot(
 dbGetQuery(con,"SELECT source_ids=['I2','I3'] AND rk=10 AND inst_key='I3' ok
  FROM family_rank_sets WHERE family='sh' AND canonical_id='I1'")$ok,
 dbGetQuery(con,"SELECT count(*)=1 ok FROM family_rank_sets WHERE family='rd'")$ok)

dbExecute(con,"CREATE TABLE education AS SELECT * FROM (VALUES
 ('f1',1,9007199254740993,1,'bachelor',false,false,2000,'rsid'),
 ('f1',2,9007199254740993,2,'master',false,false,NULL,'raw_c_norm'),
 ('f1',3,2,3,'phd',false,false,2010,'rsid'),
 ('f1',4,3,4,'bachelor',false,false,2011,'rsid'),
 ('f1',5,4,5,'bachelor',false,false,2012,'rsid'),
 ('f1',6,5,6,'other',false,false,2013,'rsid'),
 ('f1',7,6,6,'bachelor',false,false,2014,'rsid'),
 ('f1',8,7,7,'bachelor',false,false,2015,'rsid')
 ) t(source_file,source_row,user_id,global_oa_decision_id,lvl,is_mba,is_lato,yr,route)")
dbExecute(con,"CREATE TABLE ranked_entries AS SELECT r.family,e.source_file,e.source_row,e.user_id,e.lvl,
 e.is_mba,e.is_lato,e.yr,e.route,d.parent_adjusted_count,d.parent_adjusted_ids[1] canonical_id,
 r.source_ids,r.rk,r.inst,r.inst_key,r.rid FROM education e JOIN decisions d USING(global_oa_decision_id)
 JOIN family_rank_sets r ON d.parent_adjusted_count=1 AND d.parent_adjusted_ids[1]=r.canonical_id")
stopifnot(
 dbGetQuery(con,"SELECT count(*)=0 ok FROM ranked_entries WHERE source_row IN (4,5)")$ok,
 dbGetQuery(con,"SELECT count(*)=2 ok FROM ranked_entries WHERE source_row=3")$ok,
 dbGetQuery(con,"SELECT count(*)=1 ok FROM ranked_entries WHERE source_row=7 AND family='sh'")$ok,
 dbGetQuery(con,"SELECT count(*)=0 ok FROM ranked_entries WHERE source_row=8")$ok,
 dbGetQuery(con,"SELECT count(*)=0 ok FROM (SELECT family,source_file,source_row,count(*) n FROM ranked_entries GROUP BY 1,2,3 HAVING n<>1)")$ok)

dbExecute(con,"CREATE TABLE sh_flags AS SELECT user_id,1::INTEGER sh_any,
 max((lvl='bachelor')::INTEGER)::INTEGER sh_bachelor,
 max((lvl='master')::INTEGER)::INTEGER sh_master,
 max((lvl='master' AND NOT is_mba)::INTEGER)::INTEGER sh_master_strict,
 max((lvl='phd')::INTEGER)::INTEGER sh_phd,
 min(rk) FILTER(WHERE lvl IN ('bachelor','master','phd')) sh_best_rank,
 first(inst ORDER BY rk,inst_key) FILTER(WHERE lvl='bachelor') sh_bach_inst,
 min(yr) FILTER(WHERE lvl='master') sh_mast_year,
 list_sort(list_distinct(flatten(list(source_ids) FILTER(WHERE lvl='bachelor')))) sh_bach_institutions,
 count(*)::INTEGER sh_n_rows FROM ranked_entries WHERE family='sh' GROUP BY user_id
 HAVING max(CASE WHEN lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END)=1")
stopifnot(
 dbGetQuery(con,"SELECT sh_bachelor=1 AND sh_master=1 AND sh_master_strict=1
  AND sh_best_rank=10 AND sh_mast_year IS NULL AND sh_n_rows=2 ok
  FROM sh_flags WHERE user_id=9007199254740993")$ok,
 dbGetQuery(con,"SELECT sh_bach_institutions=['I2','I3'] ok FROM sh_flags WHERE user_id=9007199254740993")$ok,
 dbGetQuery(con,"SELECT count(*)=0 ok FROM sh_flags WHERE user_id=5")$ok,
 dbGetQuery(con,"SELECT count(*)=1 ok FROM sh_flags WHERE user_id=6")$ok)

cat('All parent-adjusted ranked-flag fixtures passed.\n')
