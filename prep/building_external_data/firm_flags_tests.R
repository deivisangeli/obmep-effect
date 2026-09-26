####################################################################
### Offline synthetic tests for refreshed full-firm flags.
### No network, Dropbox input, or production output.
####################################################################

rm(list = ls()); gc()
for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) stop("Missing package: ", p)
}
library(DBI)
library(duckdb)
con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, "CREATE TABLE names(family VARCHAR,source_oa_id VARCHAR,
 canonical_oa_id VARCHAR,rank INTEGER,institution_name VARCHAR,
 searched_name VARCHAR)")
dbExecute(con, "INSERT INTO names VALUES
 ('cwur','I1','I1',100,'USP','Universidade de S' || chr(227) || 'o Paulo'),
 ('cwur','I1','I1',100,'USP','University of Sao Paulo'),
 ('shanghai','I2','P2',20,'Ecole Parent',chr(201) || 'cole Parent'),
 ('shanghai','I3','P3',5,'Shared University','Shared University'),
 ('shanghai','I4','P4',10,'Shared University','Shared University')")
dbExecute(con, "CREATE TABLE refs(company VARCHAR,reference_rcid BIGINT,
 reference_child_rcid BIGINT,reference_ultimate_parent_rcid BIGINT)")
dbExecute(con, "INSERT INTO refs VALUES
 ('  UNIVERSIDADE DE SAO PAULO ',50,51,52),
 ('Universidade de Sao Paulo Campus',53,54,55),
 ('Ecole Parent',60,NULL,61),
 ('Shared University',70,71,NULL)")
dbExecute(con, "CREATE TABLE crosswalk AS
SELECT DISTINCT n.family,n.source_oa_id,n.canonical_oa_id,n.rank,n.institution_name,
 x.expanded_rcid::BIGINT expanded_rcid,x.rcid_role
FROM (SELECT *,lower(strip_accents(trim(searched_name))) searched_name_norm FROM names) n
JOIN (SELECT *,lower(strip_accents(trim(company))) company_norm FROM refs) r
 ON n.searched_name_norm=r.company_norm
CROSS JOIN (VALUES (r.reference_rcid,'rcid'),
 (r.reference_child_rcid,'child_rcid'),
 (r.reference_ultimate_parent_rcid,'ultimate_parent_rcid')) x(expanded_rcid,rcid_role)
WHERE x.expanded_rcid IS NOT NULL")
stopifnot(dbGetQuery(con, "SELECT count(*) n FROM crosswalk
 WHERE expanded_rcid IN (53,54,55)")$n == 0L)
stopifnot(dbGetQuery(con, "SELECT count(DISTINCT rcid_role) n FROM crosswalk
 WHERE family='cwur'")$n == 3L)
stopifnot(dbGetQuery(con, "SELECT count(DISTINCT canonical_oa_id) n FROM crosswalk
 WHERE expanded_rcid=70")$n == 2L)

dbExecute(con, "CREATE TABLE firm0(rcid BIGINT,in_unicorn INTEGER,in_techcap INTEGER,
 un_canonical_name VARCHAR,un_best_rank INTEGER,tc_rank INTEGER,tc_name VARCHAR,
 ref_primary_name VARCHAR)")
dbExecute(con, "INSERT INTO firm0 VALUES
 (10,1,0,'Known Unicorn',1,NULL,NULL,'Known Unicorn'),
 (20,0,1,NULL,NULL,2,'Known Tech','Known Tech')")
dbExecute(con, "CREATE TABLE misses(lst VARCHAR,ident VARCHAR,nm VARCHAR,url_norm VARCHAR)")
dbExecute(con, "INSERT INTO misses VALUES
 ('unicorn','u1','URL Unicorn','linkedin.com/company/url-unicorn'),
 ('techcap','9','Ambiguous Tech','linkedin.com/company/ambiguous')")
dbExecute(con, "CREATE TABLE positions(position_id BIGINT,user_id BIGINT,
 company_linkedin_url VARCHAR,company_raw VARCHAR,startdate VARCHAR)")
dbExecute(con, "INSERT INTO positions VALUES
 (1,3000000001,NULL,'Known Unicorn','2018-01-01'),
 (2,3000000001,NULL,'Known Tech','2019-01-01'),
 (3,3000000002,'https://www.linkedin.com/company/url-unicorn/','URL Unicorn','2020-01-01'),
 (4,3000000003,NULL,'USP','2021-01-01'),
 (5,3000000003,NULL,'USP Parent','2017-01-01'),
 (6,3000000004,NULL,'Ecole Parent','2022-01-01'),
 (7,3000000005,NULL,'Shared University','2023-01-01'),
 (8,3000000006,'https://linkedin.com/company/ambiguous','Ambiguous','2024-01-01'),
 (9,3000000007,'https://linkedin.com/company/ambiguous','Ambiguous','2024-01-01')")
dbExecute(con, "CREATE TABLE position_rcid(user_id BIGINT,position_id BIGINT,
 rcid BIGINT,ultimate_parent_rcid BIGINT)")
dbExecute(con, "INSERT INTO position_rcid VALUES
 (3000000001,1,10,NULL),(3000000001,2,999,20),(3000000002,3,30,NULL),
 (3000000003,4,50,NULL),(3000000003,5,999,51),(3000000004,6,60,NULL),
 (3000000005,7,70,71),(3000000006,8,40,NULL),(3000000007,9,41,NULL)")

dbExecute(con, "CREATE TABLE arm3_candidates AS
WITH url_map AS (
 SELECT regexp_replace(regexp_replace(regexp_replace(regexp_replace(
 lower(trim(p.company_linkedin_url)),'^https?://',''),'^www[.]',''),
 '[?#].*$',''),'/+$','') url_norm,r.rcid,count(*) n_positions
 FROM positions p JOIN position_rcid r USING(position_id)
 WHERE p.company_linkedin_url IS NOT NULL AND r.rcid IS NOT NULL GROUP BY 1,2)
SELECT m.*,count(DISTINCT u.rcid) n_rcid,min(u.rcid) rcid,sum(u.n_positions) n_positions
FROM misses m JOIN url_map u USING(url_norm) GROUP BY 1,2,3,4")
stopifnot(dbGetQuery(con, "SELECT n_rcid FROM arm3_candidates
 WHERE nm='URL Unicorn'")$n_rcid == 1L)
stopifnot(dbGetQuery(con, "SELECT n_rcid FROM arm3_candidates
 WHERE nm='Ambiguous Tech'")$n_rcid == 2L)

dbExecute(con, "CREATE TABLE firm AS
SELECT *,0::INTEGER arm3 FROM firm0
UNION ALL
SELECT rcid::BIGINT,CAST(lst='unicorn' AS INTEGER),CAST(lst='techcap' AS INTEGER),
 CASE WHEN lst='unicorn' THEN nm END,NULL::INTEGER,
 CASE WHEN lst='techcap' THEN try_cast(ident AS INTEGER) END,
 CASE WHEN lst='techcap' THEN nm END,NULL,1::INTEGER
FROM arm3_candidates WHERE n_rcid=1")
dbExecute(con, "CREATE TABLE university_map AS
SELECT family,expanded_rcid,canonical_oa_id,min(rank)::INTEGER rank,
 first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id) institution_name,
 first(source_oa_id ORDER BY rank,source_oa_id,canonical_oa_id) source_oa_id
FROM crosswalk GROUP BY 1,2,3")
dbExecute(con, "CREATE TABLE university_position_match AS
WITH matches AS (
 SELECT p.position_id,p.user_id,u.*,'exact' position_key
 FROM position_rcid p JOIN university_map u ON p.rcid=u.expanded_rcid
 UNION ALL
 SELECT p.position_id,p.user_id,u.*,'parent'
 FROM position_rcid p JOIN university_map u ON p.ultimate_parent_rcid=u.expanded_rcid)
SELECT * FROM matches")
dbExecute(con, "CREATE TABLE university_position AS
SELECT position_id,user_id,
 CAST(bool_or(family='cwur' AND position_key='exact') AS INTEGER) cw_exact,
 CAST(bool_or(family='cwur' AND position_key='parent') AS INTEGER) cw_parent,
 min(rank) FILTER(WHERE family='cwur')::INTEGER cw_rank,
 first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id)
  FILTER(WHERE family='cwur') cw_inst,
 coalesce(list_sort(list_distinct(list(canonical_oa_id)
  FILTER(WHERE family='cwur'))),[]::VARCHAR[]) cw_institution_ids,
 CAST(bool_or(family='shanghai' AND position_key='exact') AS INTEGER) sw_exact,
 CAST(bool_or(family='shanghai' AND position_key='parent') AS INTEGER) sw_parent,
 min(rank) FILTER(WHERE family='shanghai')::INTEGER sw_rank,
 first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id)
  FILTER(WHERE family='shanghai') sw_inst,
 coalesce(list_sort(list_distinct(list(canonical_oa_id)
  FILTER(WHERE family='shanghai'))),[]::VARCHAR[]) sw_institution_ids
FROM university_position_match GROUP BY 1,2")

dbExecute(con, "CREATE TABLE hits AS
SELECT p.position_id,p.user_id,r.rcid,r.ultimate_parent_rcid,
 CAST(fe.rcid IS NOT NULL AND fe.in_unicorn=1 AS INTEGER) un_exact,
 CAST(fp.rcid IS NOT NULL AND fp.in_unicorn=1 AS INTEGER) un_parent,
 greatest(un_exact,un_parent)::INTEGER un_any,
 CAST(fe.rcid IS NOT NULL AND fe.in_techcap=1 AS INTEGER) tc_exact,
 CAST(fp.rcid IS NOT NULL AND fp.in_techcap=1 AS INTEGER) tc_parent,
 greatest(tc_exact,tc_parent)::INTEGER tc_any,
 greatest(coalesce(fe.arm3,0),coalesce(fp.arm3,0))::INTEGER firm_arm3,
 coalesce(u.cw_exact,0)::INTEGER cw_exact,coalesce(u.cw_parent,0)::INTEGER cw_parent,
 greatest(cw_exact,cw_parent)::INTEGER cw_any,u.cw_rank,u.cw_inst,
 coalesce(u.cw_institution_ids,[]::VARCHAR[]) cw_institution_ids,
 coalesce(u.sw_exact,0)::INTEGER sw_exact,coalesce(u.sw_parent,0)::INTEGER sw_parent,
 greatest(sw_exact,sw_parent)::INTEGER sw_any,u.sw_rank,u.sw_inst,
 coalesce(u.sw_institution_ids,[]::VARCHAR[]) sw_institution_ids,
 greatest(cw_any,sw_any)::INTEGER ranked_university_work,
 greatest(un_any,tc_any,cw_any,sw_any)::INTEGER firm_match
FROM positions p JOIN position_rcid r USING(position_id)
LEFT JOIN firm fe ON r.rcid=fe.rcid LEFT JOIN firm fp ON r.ultimate_parent_rcid=fp.rcid
LEFT JOIN university_position u ON u.position_id=p.position_id AND u.user_id=p.user_id
WHERE fe.rcid IS NOT NULL OR fp.rcid IS NOT NULL OR u.position_id IS NOT NULL")

stopifnot(dbGetQuery(con, "SELECT count(*) n FROM hits")$n == 7L)
stopifnot(dbGetQuery(con, "SELECT un_exact FROM hits WHERE position_id=1")$un_exact == 1L)
stopifnot(dbGetQuery(con, "SELECT tc_parent FROM hits WHERE position_id=2")$tc_parent == 1L)
stopifnot(dbGetQuery(con, "SELECT un_any+firm_arm3 n FROM hits WHERE position_id=3")$n == 2L)
stopifnot(dbGetQuery(con, "SELECT cw_exact FROM hits WHERE position_id=4")$cw_exact == 1L)
stopifnot(dbGetQuery(con, "SELECT cw_parent FROM hits WHERE position_id=5")$cw_parent == 1L)
stopifnot(dbGetQuery(con, "SELECT sw_exact FROM hits WHERE position_id=6")$sw_exact == 1L)
multi <- dbGetQuery(con, "SELECT sw_exact,sw_parent,sw_rank,sw_inst,
 len(sw_institution_ids) n_inst FROM hits WHERE position_id=7")
stopifnot(multi$sw_exact == 1L, multi$sw_parent == 1L, multi$sw_rank == 5L,
          multi$sw_inst == "Shared University", multi$n_inst == 2L)
stopifnot(dbGetQuery(con, "SELECT min(user_id) n FROM hits")$n > 2147483647)
stopifnot(dbGetQuery(con, "SELECT count(*) n FROM hits WHERE firm_match<>1 OR
 ranked_university_work<>greatest(cw_any,sw_any)")$n == 0L)

dbExecute(con, "CREATE TABLE users AS SELECT user_id,max(un_any)::INTEGER un_any,
 max(tc_any)::INTEGER tc_any,max(cw_any)::INTEGER cw_any,max(sw_any)::INTEGER sw_any,
 max(ranked_university_work)::INTEGER ranked_university_work_any,
 count(*)::INTEGER n_matched_positions FROM hits GROUP BY 1")
u1 <- dbGetQuery(con, "SELECT * FROM users WHERE user_id=3000000001")
stopifnot(u1$un_any == 1L, u1$tc_any == 1L, u1$n_matched_positions == 2L)
u3 <- dbGetQuery(con, "SELECT * FROM users WHERE user_id=3000000003")
stopifnot(u3$cw_any == 1L, u3$n_matched_positions == 2L)

cat("[OK] exact normalization, three RCID roles, URL rescue gating, BIGINT IDs,\n")
cat("     corporate/CWUR/Shanghai flags, collisions, and user rollups.\n")
