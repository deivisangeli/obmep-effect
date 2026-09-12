####################################################################
### Employer flags for the candidate pool               -> Dropbox
###
### Local, offline preparation. Unicorn and market-cap employers use
### their existing resolved company RCIDs. RUF and Shanghai university
### employers use ranked_university_company_rcid.parquet, produced by
### the online Athena resolver ranked_university_company_rcid.R.
###
### The cohort-wide position extracts are immutable inputs. Output
### paths may be redirected by the publication orchestrator through
### OBMEP_FIRMS_* environment variables.
####################################################################

rm(list = ls()); gc()
for (p in c("DBI", "duckdb", "arrow", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) stop("Missing package: ", p)
}
library(DBI)
library(duckdb)

root <- Sys.getenv("OBMEP_ROOT",
                   unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh <- file.path(root, "Data/intermediate/revelio_br_cohort")
pos_dir <- file.path(coh, "obmep_candidates_step_1_position")
rcid_dir <- file.path(coh, "obmep_candidates_step_1_position_rcid")
cohort_path <- file.path(coh, "obmep_candidates_step_1.parquet")
firm_path <- file.path(root, "Data/intermediate/linkedin_company_urls",
                       "linkedin_company_rcid_2026.parquet")
unresolved_path <- file.path(root, "Data/intermediate/linkedin_company_urls",
                             "linkedin_company_unresolved_2026.parquet")
university_path <- file.path(root, "Data/intermediate/ranked_university_company_rcid",
                             "ranked_university_company_rcid.parquet")
legacy_ruf_inst <- file.path(root, "Data/intermediate/ruf_ranking",
                             "ruf_stem_top10_institutions_2025.parquet")
legacy_ruf_oa <- file.path(root, "Data/intermediate/ruf_ranking",
                           "ruf_openalex_br_2025.parquet")
legacy_shanghai <- file.path(root, "Data/intermediate/shanghai_ranking",
                             "shanghai_ranking_oa.parquet")

out_pos <- Sys.getenv("OBMEP_FIRMS_POS_OUT",
                      unset = file.path(coh, "obmep_candidates_step_1_firms_positions.parquet"))
out_user <- Sys.getenv("OBMEP_FIRMS_USER_OUT",
                       unset = file.path(coh, "obmep_candidates_step_1_firms.parquet"))
report_path <- Sys.getenv("OBMEP_FIRMS_REPORT_OUT",
                          unset = file.path(coh, "ranked_university_work_rebuild_report.json"))
old_pos <- Sys.getenv("OBMEP_FIRMS_OLD_POS",
                      unset = file.path(coh, "obmep_candidates_step_1_firms_positions.parquet"))
old_user <- Sys.getenv("OBMEP_FIRMS_OLD_USER",
                       unset = file.path(coh, "obmep_candidates_step_1_firms.parquet"))

inputs <- c(pos_dir, rcid_dir, cohort_path, firm_path, unresolved_path, university_path,
            legacy_ruf_inst, legacy_ruf_oa, legacy_shanghai)
if (!all(file.exists(inputs))) stop("Missing input(s): ", paste(inputs[!file.exists(inputs)], collapse=", "))
dir.create(dirname(out_pos), recursive=TRUE, showWarnings=FALSE)
dir.create(dirname(out_user), recursive=TRUE, showWarnings=FALSE)
dir.create(dirname(report_path), recursive=TRUE, showWarnings=FALSE)

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset="12GB")
tmp_dir <- Sys.getenv("OBMEP_FIRMS_TMP",
                      unset=file.path(Sys.getenv("TEMP"), "duckdb_ranked_university_work"))
dir.create(tmp_dir, recursive=TRUE, showWarnings=FALSE)
fw <- function(p) gsub("\\\\", "/", p)
pos_src <- sprintf("read_parquet('%s/*')", fw(pos_dir))
rcid_src <- sprintf("read_parquet('%s/*')", fw(rcid_dir))

con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con, shutdown=TRUE), silent=TRUE), add=TRUE)
dbExecute(con, sprintf("SET memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", fw(tmp_dir)))
dbExecute(con, "SET preserve_insertion_order=false")

cat("=========== INPUT GRAIN ===========\n")
grain <- dbGetQuery(con, sprintf("
SELECT (SELECT count(*) FROM %1$s) pos_rows,
       (SELECT count(DISTINCT position_id) FROM %1$s) pos_ids,
       (SELECT count(*) FROM %2$s) rcid_rows,
       (SELECT count(DISTINCT position_id) FROM %2$s) rcid_ids", pos_src, rcid_src))
print(grain, row.names=FALSE)
if (grain$pos_rows != grain$pos_ids || grain$rcid_rows != grain$rcid_ids ||
    grain$pos_rows != grain$rcid_rows) stop("Position inputs do not share one unique position_id grain.")
anti <- dbGetQuery(con, sprintf("
SELECT (SELECT count(*) FROM %1$s p WHERE NOT EXISTS
        (SELECT 1 FROM %2$s r WHERE r.position_id=p.position_id)) pos_without_rcid,
       (SELECT count(*) FROM %2$s r WHERE NOT EXISTS
        (SELECT 1 FROM %1$s p WHERE p.position_id=r.position_id)) rcid_without_pos", pos_src, rcid_src))
if (anti$pos_without_rcid != 0 || anti$rcid_without_pos != 0) stop("Position_id anti-join failed.")

cat("\n=========== COMPANY LISTS ===========\n")
dbExecute(con, sprintf("CREATE TABLE firm0 AS SELECT * FROM read_parquet('%s')", fw(firm_path)))
if (dbGetQuery(con, "SELECT count(*) n FROM (SELECT rcid FROM firm0 GROUP BY 1 HAVING count(*)<>1)")$n != 0) {
  stop("Resolved firm list is not unique on rcid.")
}

# Existing exact-URL rescue for listed firms absent from academic_company_ref.
dbExecute(con, sprintf("
CREATE TABLE cand3 AS
WITH miss AS (SELECT * FROM read_parquet('%1$s')),
urlmap AS (
 SELECT regexp_replace(regexp_replace(regexp_replace(regexp_replace(
        lower(trim(p.company_linkedin_url)), '^https?://', ''), '^www[.]', ''),
        '[?#].*$', ''), '/+$', '') url_norm,
        r.rcid,count(*) n_pos
 FROM %2$s p JOIN %3$s r USING(position_id)
 WHERE p.company_linkedin_url IS NOT NULL AND r.rcid IS NOT NULL GROUP BY 1,2)
SELECT m.lst,m.ident,m.nm,m.url_norm,count(DISTINCT u.rcid) n_rcid,
       min(u.rcid) rcid,sum(u.n_pos) n_pos
FROM miss m JOIN urlmap u USING(url_norm) GROUP BY 1,2,3,4",
 fw(unresolved_path), pos_src, rcid_src))
dbExecute(con, "
CREATE TABLE firm AS
SELECT CAST(rcid AS BIGINT) rcid,in_unicorn,in_techcap,un_canonical_name,
       un_best_rank,tc_rank,tc_name,ref_primary_name,0::INTEGER arm3
FROM firm0
UNION ALL
SELECT CAST(c.rcid AS BIGINT),CAST(c.lst='unicorn' AS INTEGER),
       CAST(c.lst='techcap' AS INTEGER),CASE WHEN c.lst='unicorn' THEN c.nm END,
       NULL::INTEGER,CASE WHEN c.lst='techcap' THEN try_cast(c.ident AS INTEGER) END,
       CASE WHEN c.lst='techcap' THEN c.nm END,NULL,1::INTEGER
FROM cand3 c WHERE c.n_rcid=1 AND NOT EXISTS
 (SELECT 1 FROM firm0 f WHERE CAST(f.rcid AS BIGINT)=CAST(c.rcid AS BIGINT))")
if (dbGetQuery(con, "SELECT count(*) n FROM (SELECT rcid FROM firm GROUP BY 1 HAVING count(*)<>1)")$n != 0) {
  stop("Final firm list is not unique on rcid.")
}

cat("\n=========== RANKED UNIVERSITY RCIDS ===========\n")
dbExecute(con, sprintf("
CREATE TABLE university_map AS
SELECT family,CAST(expanded_rcid AS BIGINT) expanded_rcid,canonical_oa_id,
       min(rank)::INTEGER rank,
       first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id) institution_name,
       first(source_oa_id ORDER BY rank,source_oa_id,canonical_oa_id) source_oa_id,
       list_sort(list_distinct(list(rcid_role))) rcid_roles
FROM read_parquet('%s')
GROUP BY family,expanded_rcid,canonical_oa_id", fw(university_path)))
uni_summary <- dbGetQuery(con, "
 SELECT family,count(*) mapping_rows,count(DISTINCT expanded_rcid) rcids,
        count(DISTINCT canonical_oa_id) institutions
 FROM university_map GROUP BY family ORDER BY family")
print(uni_summary, row.names=FALSE)
if (!setequal(uni_summary$family, c("ruf","shanghai")) ||
    dbGetQuery(con, "SELECT count(*) n FROM university_map WHERE expanded_rcid IS NULL")$n != 0) {
  stop("University RCID map has an invalid family or null identifier.")
}

# One row per (position, family, canonical institution, position key).
dbExecute(con, sprintf("
CREATE TABLE university_position_match AS
WITH base AS (
 SELECT p.position_id,p.user_id,r.rcid,r.ultimate_parent_rcid
 FROM %1$s p JOIN %2$s r USING(position_id)
), matches AS (
 SELECT b.position_id,b.user_id,u.family,u.canonical_oa_id,u.rank,
        u.institution_name,u.source_oa_id,u.expanded_rcid,'exact' position_key
 FROM base b JOIN university_map u ON b.rcid=u.expanded_rcid
 UNION ALL
 SELECT b.position_id,b.user_id,u.family,u.canonical_oa_id,u.rank,
        u.institution_name,u.source_oa_id,u.expanded_rcid,'parent'
 FROM base b JOIN university_map u ON b.ultimate_parent_rcid=u.expanded_rcid
)
SELECT position_id,user_id,family,canonical_oa_id,position_key,
       min(rank)::INTEGER rank,
       first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id) institution_name,
       first(source_oa_id ORDER BY rank,source_oa_id,canonical_oa_id) source_oa_id,
       list_sort(list_distinct(list(expanded_rcid))) matched_rcids
FROM matches GROUP BY position_id,user_id,family,canonical_oa_id,position_key",
 pos_src, rcid_src))

dbExecute(con, "
CREATE TABLE university_position AS
SELECT position_id,user_id,
 CAST(bool_or(family='ruf' AND position_key='exact') AS INTEGER) rf_exact,
 CAST(bool_or(family='ruf' AND position_key='parent') AS INTEGER) rf_parent,
 min(rank) FILTER(WHERE family='ruf')::INTEGER rf_rank,
 first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id)
   FILTER(WHERE family='ruf') rf_inst,
 first(source_oa_id ORDER BY rank,source_oa_id,canonical_oa_id)
   FILTER(WHERE family='ruf') rf_source_oa_id,
 coalesce(list_sort(list_distinct(list(canonical_oa_id)
   FILTER(WHERE family='ruf'))),[]::VARCHAR[]) rf_institution_ids,
 CAST(bool_or(family='shanghai' AND position_key='exact') AS INTEGER) sw_exact,
 CAST(bool_or(family='shanghai' AND position_key='parent') AS INTEGER) sw_parent,
 min(rank) FILTER(WHERE family='shanghai')::INTEGER sw_rank,
 first(institution_name ORDER BY rank,source_oa_id,canonical_oa_id)
   FILTER(WHERE family='shanghai') sw_inst,
 first(source_oa_id ORDER BY rank,source_oa_id,canonical_oa_id)
   FILTER(WHERE family='shanghai') sw_source_oa_id,
 coalesce(list_sort(list_distinct(list(canonical_oa_id)
   FILTER(WHERE family='shanghai'))),[]::VARCHAR[]) sw_institution_ids
FROM university_position_match GROUP BY position_id,user_id")
if (dbGetQuery(con, "SELECT count(*) n FROM (SELECT position_id FROM university_position GROUP BY 1 HAVING count(*)<>1)")$n != 0) {
  stop("University match aggregation multiplied position_id.")
}

cat("\n=========== MATCHED POSITIONS ===========\n")
dbExecute(con, sprintf("
CREATE TABLE hits AS
SELECT p.position_id,p.user_id,r.rcid,r.ultimate_parent_rcid,
 CAST(fe.rcid IS NOT NULL AND fe.in_unicorn=1 AS INTEGER) un_exact,
 CAST(fp.rcid IS NOT NULL AND fp.in_unicorn=1 AS INTEGER) un_parent,
 CAST(fe.rcid IS NOT NULL AND fe.in_techcap=1 AS INTEGER) tc_exact,
 CAST(fp.rcid IS NOT NULL AND fp.in_techcap=1 AS INTEGER) tc_parent,
 CAST(coalesce(fe.arm3,fp.arm3,0) AS INTEGER) firm_arm3,
 coalesce(fe.un_canonical_name,fp.un_canonical_name) un_firm,
 coalesce(fe.un_best_rank,fp.un_best_rank)::INTEGER un_rank,
 coalesce(fe.tc_name,fp.tc_name) tc_firm,
 coalesce(fe.tc_rank,fp.tc_rank)::INTEGER tc_rank,
 coalesce(u.rf_exact,0)::INTEGER rf_exact,
 coalesce(u.rf_parent,0)::INTEGER rf_parent,
 greatest(coalesce(u.rf_exact,0),coalesce(u.rf_parent,0))::INTEGER rf_any,
 u.rf_rank,u.rf_inst,u.rf_source_oa_id,
 coalesce(u.rf_institution_ids,[]::VARCHAR[]) rf_institution_ids,
 coalesce(u.sw_exact,0)::INTEGER sw_exact,
 coalesce(u.sw_parent,0)::INTEGER sw_parent,
 greatest(coalesce(u.sw_exact,0),coalesce(u.sw_parent,0))::INTEGER sw_any,
 u.sw_rank,u.sw_inst,u.sw_source_oa_id,
 coalesce(u.sw_institution_ids,[]::VARCHAR[]) sw_institution_ids,
 greatest(greatest(coalesce(u.rf_exact,0),coalesce(u.rf_parent,0)),
          greatest(coalesce(u.sw_exact,0),coalesce(u.sw_parent,0)))::INTEGER ranked_university_work,
 p.company_raw,p.company_cleaned,p.company_linkedin_url,p.startdate,p.enddate,
 try_cast(substr(p.startdate,1,4) AS INTEGER)::INTEGER start_year
FROM %1$s p JOIN %2$s r USING(position_id)
LEFT JOIN firm fe ON r.rcid=fe.rcid
LEFT JOIN firm fp ON r.ultimate_parent_rcid=fp.rcid
LEFT JOIN university_position u
  ON u.position_id=p.position_id AND u.user_id=p.user_id
WHERE fe.rcid IS NOT NULL OR fp.rcid IS NOT NULL OR u.position_id IS NOT NULL",
 pos_src,rcid_src))

hit_summary <- dbGetQuery(con, "
 SELECT count(*) positions,count(DISTINCT position_id) position_ids,
        count(DISTINCT user_id) users,sum(rf_any) rf_positions,
        sum(sw_any) sw_positions,sum(ranked_university_work) ranked_university_positions
 FROM hits")
print(hit_summary, row.names=FALSE)
if (hit_summary$positions != hit_summary$position_ids) stop("Matched position output is not unique.")

cat("\n=========== USER FLAGS ===========\n")
dbExecute(con, "
CREATE TABLE output_users AS
SELECT user_id,
 max(greatest(un_exact,un_parent))::INTEGER un_any,
 max(un_exact)::INTEGER un_exact_any,max(un_parent)::INTEGER un_parent_any,
 max(CASE WHEN greatest(un_exact,un_parent)=1 THEN firm_arm3 ELSE 0 END)::INTEGER un_arm3_any,
 min(un_rank)::INTEGER un_best_rank,
 first(un_firm ORDER BY un_rank,un_firm) FILTER(WHERE greatest(un_exact,un_parent)=1) un_best_firm,
 min(start_year) FILTER(WHERE greatest(un_exact,un_parent)=1)::INTEGER un_first_year,
 count(DISTINCT rcid) FILTER(WHERE greatest(un_exact,un_parent)=1)::INTEGER n_un_firms,
 sum(greatest(un_exact,un_parent))::INTEGER n_un_positions,
 max(greatest(tc_exact,tc_parent))::INTEGER tc_any,
 max(tc_exact)::INTEGER tc_exact_any,max(tc_parent)::INTEGER tc_parent_any,
 max(CASE WHEN greatest(tc_exact,tc_parent)=1 THEN firm_arm3 ELSE 0 END)::INTEGER tc_arm3_any,
 min(tc_rank)::INTEGER tc_best_rank,
 first(tc_firm ORDER BY tc_rank,tc_firm) FILTER(WHERE greatest(tc_exact,tc_parent)=1) tc_best_firm,
 min(start_year) FILTER(WHERE greatest(tc_exact,tc_parent)=1)::INTEGER tc_first_year,
 count(DISTINCT rcid) FILTER(WHERE greatest(tc_exact,tc_parent)=1)::INTEGER n_tc_firms,
 sum(greatest(tc_exact,tc_parent))::INTEGER n_tc_positions,
 max(rf_any)::INTEGER rf_any,max(rf_exact)::INTEGER rf_exact_any,
 max(rf_parent)::INTEGER rf_parent_any,min(rf_rank)::INTEGER rf_best_rank,
 first(rf_inst ORDER BY rf_rank,rf_source_oa_id,rf_inst) FILTER(WHERE rf_any=1) rf_best_inst,
 min(start_year) FILTER(WHERE rf_any=1)::INTEGER rf_first_year,
 len(list_distinct(flatten(list(rf_institution_ids) FILTER(WHERE rf_any=1))))::INTEGER n_rf_inst,
 sum(rf_any)::INTEGER n_rf_positions,
 max(sw_any)::INTEGER sw_any,max(sw_exact)::INTEGER sw_exact_any,
 max(sw_parent)::INTEGER sw_parent_any,min(sw_rank)::INTEGER sw_best_rank,
 first(sw_inst ORDER BY sw_rank,sw_source_oa_id,sw_inst) FILTER(WHERE sw_any=1) sw_best_inst,
 min(start_year) FILTER(WHERE sw_any=1)::INTEGER sw_first_year,
 len(list_distinct(flatten(list(sw_institution_ids) FILTER(WHERE sw_any=1))))::INTEGER n_sw_inst,
 sum(sw_any)::INTEGER n_sw_positions,
 max(ranked_university_work)::INTEGER ranked_university_work_any,
 1::INTEGER firm_any,count(*)::INTEGER n_matched_positions
FROM hits GROUP BY user_id")

user_summary <- dbGetQuery(con, "
 SELECT count(*) users,sum(un_any) un_any,sum(tc_any) tc_any,sum(rf_any) rf_any,
        sum(rf_exact_any) rf_exact,sum(rf_parent_any) rf_parent,
        sum(sw_any) sw_any,sum(sw_exact_any) sw_exact,sum(sw_parent_any) sw_parent,
        sum(ranked_university_work_any) ranked_university_work_any
 FROM output_users")
print(user_summary, row.names=FALSE)

validation <- dbGetQuery(con, sprintf("
SELECT (SELECT count(*) FROM output_users) users,
 (SELECT count(DISTINCT user_id) FROM output_users) user_ids,
 (SELECT count(*) FROM output_users u WHERE NOT EXISTS
   (SELECT 1 FROM read_parquet('%1$s') c WHERE c.user_id=u.user_id)) orphan_users,
 (SELECT count(*) FROM output_users WHERE firm_any<>1
    OR ranked_university_work_any<>greatest(rf_any,sw_any)
    OR rf_any<>greatest(rf_exact_any,rf_parent_any)
    OR sw_any<>greatest(sw_exact_any,sw_parent_any)) bad_flags",
 fw(cohort_path)))
if (validation$users != validation$user_ids || validation$orphan_users != 0 || validation$bad_flags != 0) {
  print(validation); stop("User-level validation failed.")
}
rollup_diff <- dbGetQuery(con, "
WITH x AS (SELECT user_id,max(greatest(un_exact,un_parent)) un_any,
 max(greatest(tc_exact,tc_parent)) tc_any,max(rf_any) rf_any,max(sw_any) sw_any,
 max(ranked_university_work) ruw,count(*) n FROM hits GROUP BY user_id)
SELECT count(*) n FROM x JOIN output_users u USING(user_id)
WHERE x.un_any<>u.un_any OR x.tc_any<>u.tc_any OR x.rf_any<>u.rf_any
 OR x.sw_any<>u.sw_any OR x.ruw<>u.ranked_university_work_any
 OR x.n<>u.n_matched_positions")$n
if (rollup_diff != 0) stop(rollup_diff, " users differ from the independent position rollup.")
metadata_diff <- dbGetQuery(con, "
WITH x AS (
 SELECT user_id,min(rf_rank)::INTEGER rf_best_rank,
  first(rf_inst ORDER BY rf_rank,rf_source_oa_id,rf_inst) FILTER(WHERE rf_any=1) rf_best_inst,
  min(start_year) FILTER(WHERE rf_any=1)::INTEGER rf_first_year,
  len(list_distinct(flatten(list(rf_institution_ids) FILTER(WHERE rf_any=1))))::INTEGER n_rf_inst,
  sum(rf_any)::INTEGER n_rf_positions,min(sw_rank)::INTEGER sw_best_rank,
  first(sw_inst ORDER BY sw_rank,sw_source_oa_id,sw_inst) FILTER(WHERE sw_any=1) sw_best_inst,
  min(start_year) FILTER(WHERE sw_any=1)::INTEGER sw_first_year,
  len(list_distinct(flatten(list(sw_institution_ids) FILTER(WHERE sw_any=1))))::INTEGER n_sw_inst,
  sum(sw_any)::INTEGER n_sw_positions
 FROM hits GROUP BY user_id)
SELECT count(*) n FROM x JOIN output_users u USING(user_id)
WHERE x.rf_best_rank IS DISTINCT FROM u.rf_best_rank
 OR x.rf_best_inst IS DISTINCT FROM u.rf_best_inst
 OR x.rf_first_year IS DISTINCT FROM u.rf_first_year
 OR x.n_rf_inst IS DISTINCT FROM u.n_rf_inst
 OR x.n_rf_positions IS DISTINCT FROM u.n_rf_positions
 OR x.sw_best_rank IS DISTINCT FROM u.sw_best_rank
 OR x.sw_best_inst IS DISTINCT FROM u.sw_best_inst
 OR x.sw_first_year IS DISTINCT FROM u.sw_first_year
 OR x.n_sw_inst IS DISTINCT FROM u.n_sw_inst
 OR x.n_sw_positions IS DISTINCT FROM u.n_sw_positions")$n
if (metadata_diff != 0) stop(metadata_diff, " users differ on ranked-university metadata.")

cat("\n=========== LEGACY NAME-MATCH COMPARISON ===========\n")
# Reconstruct the former published matcher for validation only. These tables never
# enter either output: full RUF/Shanghai names match whole strings or /, (), " - "
# segments, while RUF acronyms match whole strings only.
dbExecute(con, sprintf("
CREATE TABLE legacy_ruf_full AS
SELECT DISTINCT lower(strip_accents(trim(nm))) nm_fold
FROM (
 SELECT i.institution_name nm FROM read_parquet('%1$s') i
 UNION ALL
 SELECT o.display_name FROM read_parquet('%1$s') i
 LEFT JOIN read_parquet('%2$s') o USING(ruf_institution_id)
 UNION ALL
 SELECT o.cleaned_display_name FROM read_parquet('%1$s') i
 LEFT JOIN read_parquet('%2$s') o USING(ruf_institution_id)
) WHERE nm IS NOT NULL AND length(trim(nm)) >= 3;
CREATE TABLE legacy_ruf_abbr AS
SELECT DISTINCT lower(strip_accents(trim(abbr))) nm_fold
FROM read_parquet('%1$s')
WHERE abbr IS NOT NULL AND length(trim(abbr)) >= 2",
 fw(legacy_ruf_inst),fw(legacy_ruf_oa)))
legacy_shanghai_n <- dbGetQuery(con, sprintf("
SELECT count(*) n FROM read_parquet('%s') WHERE Rank <= 901",fw(legacy_shanghai)))$n
if (legacy_shanghai_n != 1000) stop("Legacy Shanghai Rank <= 901 no longer selects 1,000 rows.")
dbExecute(con, sprintf("
CREATE TABLE legacy_shanghai_full AS
SELECT DISTINCT lower(strip_accents(trim(nm))) nm_fold
FROM (
 SELECT cleaned_display_name nm FROM read_parquet('%1$s') WHERE Rank <= 901
 UNION ALL SELECT display_name FROM read_parquet('%1$s') WHERE Rank <= 901
 UNION ALL SELECT shanghai_Name FROM read_parquet('%1$s') WHERE Rank <= 901
) WHERE nm IS NOT NULL AND length(trim(nm)) >= 3",fw(legacy_shanghai)))
dbExecute(con, sprintf("
CREATE TABLE legacy_strings AS
SELECT 'raw' source_field,company_raw s FROM %1$s
 WHERE company_raw IS NOT NULL AND trim(company_raw) != '' GROUP BY company_raw
UNION ALL
SELECT 'cleaned',company_cleaned FROM %1$s
 WHERE company_cleaned IS NOT NULL AND trim(company_cleaned) != '' GROUP BY company_cleaned;

CREATE TABLE legacy_classification AS
WITH whole AS (
 SELECT s.source_field,s.s,
  max(CAST(r.nm_fold IS NOT NULL AS INTEGER)) rf_name,
  max(CAST(a.nm_fold IS NOT NULL AS INTEGER)) rf_abbr,
  max(CAST(h.nm_fold IS NOT NULL AS INTEGER)) sw_name
 FROM legacy_strings s
 LEFT JOIN legacy_ruf_full r ON lower(strip_accents(trim(s.s)))=r.nm_fold
 LEFT JOIN legacy_ruf_abbr a ON lower(strip_accents(trim(s.s)))=a.nm_fold
 LEFT JOIN legacy_shanghai_full h ON lower(strip_accents(trim(s.s)))=h.nm_fold
 GROUP BY s.source_field,s.s
), segment AS (
 SELECT s.source_field,s.s,
  max(CAST(r.nm_fold IS NOT NULL AS INTEGER)) rf_segment,
  max(CAST(h.nm_fold IS NOT NULL AS INTEGER)) sw_segment
 FROM legacy_strings s
 CROSS JOIN UNNEST(str_split(regexp_replace(regexp_replace(
  s.s,'[/()]','|','g'),' - ','|','g'),'|')) t(part)
 LEFT JOIN legacy_ruf_full r ON lower(strip_accents(trim(t.part)))=r.nm_fold
 LEFT JOIN legacy_shanghai_full h ON lower(strip_accents(trim(t.part)))=h.nm_fold
 WHERE length(trim(t.part)) >= 3 GROUP BY s.source_field,s.s
), classified AS (
SELECT w.source_field,w.s,
 greatest(w.rf_name,coalesce(g.rf_segment,0))::INTEGER rf_name,
 w.rf_abbr::INTEGER rf_abbr,
 greatest(w.sw_name,coalesce(g.sw_segment,0))::INTEGER sw_name
FROM whole w LEFT JOIN segment g USING(source_field,s)
)
SELECT * FROM classified WHERE greatest(rf_name,rf_abbr,sw_name)=1",pos_src))
dbExecute(con, sprintf("
CREATE TABLE legacy_position AS
SELECT p.position_id,p.user_id,
 greatest(coalesce(r.rf_name,0),coalesce(c.rf_name,0),
          coalesce(r.rf_abbr,0),coalesce(c.rf_abbr,0))::INTEGER rf_old,
 greatest(coalesce(r.sw_name,0),coalesce(c.sw_name,0))::INTEGER sw_old
FROM %1$s p
LEFT JOIN legacy_classification r
 ON r.source_field='raw' AND p.company_raw=r.s
LEFT JOIN legacy_classification c
 ON c.source_field='cleaned' AND p.company_cleaned=c.s
WHERE greatest(coalesce(r.rf_name,0),coalesce(c.rf_name,0),
               coalesce(r.rf_abbr,0),coalesce(c.rf_abbr,0),
               coalesce(r.sw_name,0),coalesce(c.sw_name,0))=1;
CREATE TABLE legacy_user AS
SELECT user_id,max(rf_old)::INTEGER rf_old,max(sw_old)::INTEGER sw_old
FROM legacy_position GROUP BY user_id",pos_src))

comparison <- list(
 available=TRUE,
 reconstruction=list(
  ruf_full_names=dbGetQuery(con,"SELECT count(*) n FROM legacy_ruf_full")$n,
  ruf_acronyms=dbGetQuery(con,"SELECT count(*) n FROM legacy_ruf_abbr")$n,
  shanghai_full_names=dbGetQuery(con,"SELECT count(*) n FROM legacy_shanghai_full")$n,
  positions=dbGetQuery(con,"SELECT count(*) n FROM legacy_position")$n,
  users=dbGetQuery(con,"SELECT count(*) n FROM legacy_user")$n),
 users=dbGetQuery(con,"
WITH o AS (SELECT * FROM legacy_user),n AS (SELECT user_id,rf_any,sw_any FROM output_users)
SELECT count(*) FILTER(WHERE o.rf_old=1 AND n.rf_any=1) rf_retained,
 count(*) FILTER(WHERE coalesce(o.rf_old,0)=0 AND n.rf_any=1) rf_gained,
 count(*) FILTER(WHERE o.rf_old=1 AND coalesce(n.rf_any,0)=0) rf_lost,
 count(*) FILTER(WHERE o.sw_old=1 AND n.sw_any=1) sw_retained,
 count(*) FILTER(WHERE coalesce(o.sw_old,0)=0 AND n.sw_any=1) sw_gained,
 count(*) FILTER(WHERE o.sw_old=1 AND coalesce(n.sw_any,0)=0) sw_lost
FROM o FULL JOIN n USING(user_id)"),
 positions=dbGetQuery(con,"
WITH o AS (SELECT position_id,rf_old,sw_old FROM legacy_position),
n AS (SELECT position_id,rf_any,sw_any FROM hits)
SELECT count(*) FILTER(WHERE o.rf_old=1 AND n.rf_any=1) rf_retained,
 count(*) FILTER(WHERE coalesce(o.rf_old,0)=0 AND n.rf_any=1) rf_gained,
 count(*) FILTER(WHERE o.rf_old=1 AND coalesce(n.rf_any,0)=0) rf_lost,
 count(*) FILTER(WHERE o.sw_old=1 AND n.sw_any=1) sw_retained,
 count(*) FILTER(WHERE coalesce(o.sw_old,0)=0 AND n.sw_any=1) sw_gained,
 count(*) FILTER(WHERE o.sw_old=1 AND coalesce(n.sw_any,0)=0) sw_lost
FROM o FULL JOIN n USING(position_id)"),
 largest_disagreements=dbGetQuery(con,sprintf("
WITH o AS (SELECT position_id,rf_old,sw_old FROM legacy_position),
n AS (SELECT position_id,rf_any,sw_any,company_raw FROM hits),
d0 AS (SELECT coalesce(n.position_id,o.position_id) position_id,n.company_raw,
 coalesce(o.rf_old,0) rf_old,coalesce(n.rf_any,0) rf_new,
 coalesce(o.sw_old,0) sw_old,coalesce(n.sw_any,0) sw_new
 FROM o FULL JOIN n USING(position_id)
 WHERE coalesce(o.rf_old,0) != coalesce(n.rf_any,0)
    OR coalesce(o.sw_old,0) != coalesce(n.sw_any,0)),
d AS (SELECT d0.* EXCLUDE(company_raw),coalesce(d0.company_raw,p.company_raw) company_raw
 FROM d0 LEFT JOIN %s p USING(position_id))
SELECT company_raw,rf_old,rf_new,sw_old,sw_new,count(*) positions
FROM d GROUP BY 1,2,3,4,5 ORDER BY positions DESC,company_raw LIMIT 50",pos_src)))

# When a preserved pre-change product is supplied, prove the reconstruction is
# exact rather than merely similar. New-schema canonical files are ignored.
comparison$snapshot_verified <- FALSE
if (file.exists(old_user) && file.exists(old_pos)) {
  old_user_names <- names(arrow::open_dataset(old_user,format="parquet"))
  old_pos_names <- names(arrow::open_dataset(old_pos,format="parquet"))
  if (all(c("user_id","rf_any","sw_any") %in% old_user_names) &&
      all(c("position_id","rf_name","rf_abbr","sw_name") %in% old_pos_names)) {
    snapshot_diff <- dbGetQuery(con,sprintf("
WITH ou AS (SELECT user_id,rf_any rf_old,sw_any sw_old FROM read_parquet('%1$s')
 WHERE rf_any=1 OR sw_any=1),
op AS (SELECT position_id,greatest(rf_name,rf_abbr) rf_old,sw_name sw_old
 FROM read_parquet('%2$s') WHERE greatest(rf_name,rf_abbr)=1 OR sw_name=1)
SELECT
 (SELECT count(*) FROM (SELECT * FROM legacy_user EXCEPT SELECT * FROM ou)) +
 (SELECT count(*) FROM (SELECT * FROM ou EXCEPT SELECT * FROM legacy_user)) user_diff,
 (SELECT count(*) FROM (SELECT position_id,rf_old,sw_old FROM legacy_position
  EXCEPT SELECT * FROM op)) +
 (SELECT count(*) FROM (SELECT * FROM op EXCEPT
  SELECT position_id,rf_old,sw_old FROM legacy_position)) position_diff",
 fw(old_user),fw(old_pos)))
    if (snapshot_diff$user_diff != 0 || snapshot_diff$position_diff != 0) {
      print(snapshot_diff); stop("Rebuilt legacy matcher differs from the preserved legacy output.")
    }
    comparison$snapshot_verified <- TRUE
  }
}

expected_user_cols <- c(
 "user_id","un_any","un_exact_any","un_parent_any","un_arm3_any","un_best_rank",
 "un_best_firm","un_first_year","n_un_firms","n_un_positions",
 "tc_any","tc_exact_any","tc_parent_any","tc_arm3_any","tc_best_rank",
 "tc_best_firm","tc_first_year","n_tc_firms","n_tc_positions",
 "rf_any","rf_exact_any","rf_parent_any","rf_best_rank","rf_best_inst",
 "rf_first_year","n_rf_inst","n_rf_positions",
 "sw_any","sw_exact_any","sw_parent_any","sw_best_rank","sw_best_inst",
 "sw_first_year","n_sw_inst","n_sw_positions","ranked_university_work_any",
 "firm_any","n_matched_positions")

for (p in c(out_pos,out_user,report_path)) if (file.exists(p)) stop("Output already exists: ",p)
dbExecute(con, sprintf("COPY (SELECT * FROM hits ORDER BY user_id,position_id) TO '%s'
 (FORMAT PARQUET,COMPRESSION ZSTD)", fw(out_pos)))
dbExecute(con, sprintf("COPY (SELECT * FROM output_users ORDER BY user_id) TO '%s'
 (FORMAT PARQUET,COMPRESSION ZSTD)", fw(out_user)))
up <- arrow::open_dataset(out_user,format="parquet")
hp <- arrow::open_dataset(out_pos,format="parquet")
if (!identical(names(up),expected_user_cols) || nrow(up)!=validation$users || nrow(hp)!=hit_summary$positions) {
  stop("Published Parquet schema or row-count validation failed.")
}

report <- list(
 generated_at=format(Sys.time(),"%Y-%m-%dT%H:%M:%S%z"),
 method=list(university_source=university_path,
   position_keys=c("rcid","ultimate_parent_rcid"),
   legacy_name_matcher=paste("reconstructed former whole/segment matcher plus",
                             "whole-field RUF acronym arm; validation only")),
 input_md5=data.frame(
  path=c(cohort_path,firm_path,unresolved_path,university_path,
         legacy_ruf_inst,legacy_ruf_oa,legacy_shanghai),
  md5=unname(tools::md5sum(c(cohort_path,firm_path,unresolved_path,university_path,
                             legacy_ruf_inst,legacy_ruf_oa,legacy_shanghai)))),
 input_grain=grain,position_antijoin=anti,university_catalog=uni_summary,
 matched_positions=hit_summary,user_flags=user_summary,legacy_comparison=comparison,
 checks=list(position_ids_identical=TRUE,position_output_unique=TRUE,user_output_unique=TRUE,
  no_orphan_users=TRUE,binary_flag_relations=TRUE,independent_rollup=TRUE,
  independent_rank_year_institution_metadata=TRUE,staged_parquet_reread=TRUE))
jsonlite::write_json(report,report_path,pretty=TRUE,auto_unbox=TRUE,na="null")
cat("\nWrote staged employer products:\n ",out_pos,"\n ",out_user,"\n ",report_path,"\n",sep="")
