####################################################################
### Offline synthetic tests for ranked-university employer RCIDs.
### No network and no production files.
####################################################################

rm(list=ls()); gc()
for (p in c("DBI","duckdb")) if (!requireNamespace(p,quietly=TRUE)) stop("Missing package: ",p)
library(DBI); library(duckdb)
con <- dbConnect(duckdb())
on.exit(dbDisconnect(con,shutdown=TRUE),add=TRUE)

dbExecute(con, "CREATE TABLE names(family VARCHAR,source_oa_id VARCHAR,
 canonical_oa_id VARCHAR,rank INTEGER,institution_name VARCHAR,
 searched_name VARCHAR)")
dbExecute(con, "INSERT INTO names VALUES
 ('ruf','I1','P1',1,'USP','Universidade de S' || chr(227) || 'o Paulo'),
 ('ruf','I1','P1',1,'USP','University of Sao Paulo'),
 ('shanghai','I2','P2',20,'Ecole Parent',chr(201) || 'cole Parent'),
 ('shanghai','I3','P3',5,'Shared University','Shared University'),
 ('shanghai','I4','P4',10,'Shared University','Shared University')")
dbExecute(con, "CREATE TABLE refs(company VARCHAR,reference_rcid BIGINT,
 reference_child_rcid BIGINT,reference_ultimate_parent_rcid BIGINT)")
dbExecute(con, "INSERT INTO refs VALUES
 ('  UNIVERSIDADE DE SAO PAULO ',10,11,12),
 ('University of Sao Paulo',20,NULL,20),
 ('Universidade de Sao Paulo Campus',21,22,23),
 ('Ecole Parent',30,NULL,31),
 ('Shared University',500,501,NULL),
 ('No Match',NULL,700,NULL)")

dbExecute(con, "CREATE TABLE crosswalk AS
SELECT DISTINCT n.family,n.source_oa_id,n.canonical_oa_id,n.rank,n.institution_name,
 x.expanded_rcid,x.rcid_role
FROM (SELECT *,lower(strip_accents(trim(searched_name))) searched_name_norm FROM names) n
JOIN (SELECT *,lower(strip_accents(trim(company))) company_norm FROM refs) r
 ON n.searched_name_norm=r.company_norm
CROSS JOIN (VALUES (r.reference_rcid,'rcid'),
 (r.reference_child_rcid,'child_rcid'),
 (r.reference_ultimate_parent_rcid,'ultimate_parent_rcid')) x(expanded_rcid,rcid_role)
WHERE x.expanded_rcid IS NOT NULL")

ruf_expanded <- dbGetQuery(con,"SELECT * FROM crosswalk WHERE family='ruf' ORDER BY expanded_rcid,rcid_role")
stopifnot(nrow(ruf_expanded)==5L)
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM crosswalk WHERE expanded_rcid IN (21,22,23)")$n==0L)
stopifnot(dbGetQuery(con,"SELECT count(DISTINCT rcid_role) n FROM crosswalk WHERE expanded_rcid IN (10,11,12)")$n==3L)
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM crosswalk WHERE family='shanghai' AND expanded_rcid=30")$n==1L)
stopifnot(dbGetQuery(con,"SELECT count(DISTINCT canonical_oa_id) n FROM crosswalk WHERE expanded_rcid=500")$n==2L)

dbExecute(con, "CREATE TABLE university_map AS
SELECT family,expanded_rcid,canonical_oa_id,min(rank)::INTEGER rank,
 first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id) institution_name,
 first(source_oa_id ORDER BY rank,source_oa_id,canonical_oa_id) source_oa_id
FROM crosswalk GROUP BY family,expanded_rcid,canonical_oa_id")
dbExecute(con, "CREATE TABLE positions(position_id BIGINT,user_id BIGINT,rcid BIGINT,
 ultimate_parent_rcid BIGINT)")
dbExecute(con, "INSERT INTO positions VALUES
 (1,3000000001,10,NULL),
 (2,3000000002,999,11),
 (3,3000000003,20,12),
 (4,3000000004,30,NULL),
 (5,3000000005,999,NULL),
 (6,3000000006,500,501)")

dbExecute(con, "CREATE TABLE matches AS
SELECT p.position_id,p.user_id,u.*,'exact' position_key
FROM positions p JOIN university_map u ON p.rcid=u.expanded_rcid
UNION ALL
SELECT p.position_id,p.user_id,u.*,'parent'
FROM positions p JOIN university_map u ON p.ultimate_parent_rcid=u.expanded_rcid")
dbExecute(con, "CREATE TABLE position_flags AS
SELECT position_id,user_id,
 CAST(bool_or(family='ruf' AND position_key='exact') AS INTEGER) rf_exact,
 CAST(bool_or(family='ruf' AND position_key='parent') AS INTEGER) rf_parent,
 CAST(bool_or(family='shanghai' AND position_key='exact') AS INTEGER) sw_exact,
 CAST(bool_or(family='shanghai' AND position_key='parent') AS INTEGER) sw_parent,
 min(rank) FILTER(WHERE family='shanghai')::INTEGER sw_rank,
 first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id)
  FILTER(WHERE family='shanghai') sw_inst,
 count(DISTINCT canonical_oa_id) FILTER(WHERE family='shanghai')::INTEGER n_sw_inst
FROM matches GROUP BY position_id,user_id")

stopifnot(dbGetQuery(con,"SELECT count(*) n FROM position_flags")$n==5L)
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM (SELECT position_id FROM position_flags GROUP BY 1 HAVING count(*)<>1)")$n==0L)
stopifnot(dbGetQuery(con,"SELECT rf_exact FROM position_flags WHERE position_id=1")$rf_exact==1L)
stopifnot(dbGetQuery(con,"SELECT rf_parent FROM position_flags WHERE position_id=2")$rf_parent==1L)
both <- dbGetQuery(con,"SELECT rf_exact,rf_parent FROM position_flags WHERE position_id=3")
stopifnot(both$rf_exact==1L,both$rf_parent==1L)
stopifnot(dbGetQuery(con,"SELECT count(*) n FROM position_flags WHERE position_id=5")$n==0L)
multi <- dbGetQuery(con,"SELECT sw_exact,sw_parent,sw_rank,sw_inst,n_sw_inst FROM position_flags WHERE position_id=6")
stopifnot(multi$sw_exact==1L,multi$sw_parent==1L,multi$sw_rank==5L,
          multi$sw_inst=="Shared University",multi$n_sw_inst==2L)
stopifnot(dbGetQuery(con,"SELECT min(user_id) n FROM position_flags")$n>2147483647)

cat("[OK] normalization, whole-field exclusion, all RCID roles, both position keys,\n")
cat("     deduplication, multi-institution tie-breaking, nulls, and BIGINT IDs.\n")
