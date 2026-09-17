####################################################################
### 27d. Sample of the CO_MANTENEDORA master/PhD union for review
###
### Local, OFFLINE pipeline. It samples the conservative union from 27c and
### reconstructs the exact CAPES and Revelio diploma rows selected by 27.
### It does not use the network and must not be sent to SEDAP.
####################################################################

for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) stop("Missing package: ", p)
}
library(DBI)
library(duckdb)

obmep_root <- Sys.getenv(
  "OBMEP_ROOT", unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
capes_dir <- file.path(obmep_root, "Data/intermediate/capes_discentes")
rev_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
co_ies_version <- Sys.getenv("OBMEP_MATCH_CO_IES_VERSION", unset = "base")
if (!co_ies_version %in% c("base", "regex_v1")) {
  stop("OBMEP_MATCH_CO_IES_VERSION = '", co_ies_version,
       "' does not exist. Use base or regex_v1.")
}
out_dir <- file.path(
  capes_dir, paste0("capes_obmep_match_union_degree_duration_mantenedora",
                    if (co_ies_version == "regex_v1") "_regex_v1" else ""))
union_path <- file.path(out_dir, "capes_obmep_match_candidates.parquet")
capes_path <- file.path(
  capes_dir,
  "capes_masters_doctorates_born_1988plus_2004_2024_emec_mantenedora.parquet")
edu_dir <- file.path(
  rev_dir,
  if (co_ies_version == "regex_v1") "university_identity_crosswalk" else
    "emec_hierarchy",
  if (co_ies_version == "regex_v1") "education_row_identity" else
    "education_parts")
census_path <- file.path(
  obmep_root, "Data/raw/Censo Superior/MICRODADOS_ED_SUP_IES_2024.CSV")
sample_path <- file.path(out_dir, "capes_obmep_match_audit_sample.parquet")
json_path <- file.path(
  Sys.getenv("TEMP"), paste0("capes_obmep_match_audit_sample_",
                             co_ies_version, ".json"))

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
patterns_path <- if (length(script_arg) == 1L) {
  file.path(dirname(sub("^--file=", "", script_arg)), "br_degree_patterns.R")
} else {
  "prep/building_external_data/br_degree_patterns.R"
}
stopifnot(file.exists(union_path), file.exists(capes_path),
          dir.exists(edu_dir), file.exists(census_path),
          file.exists(patterns_path))
source(patterns_path, local = TRUE)

n_draw <- 100L
year_min <- 1950L
year_max <- 2030L
con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, "PRAGMA memory_limit='8GB'")
dbExecute(con, "SET preserve_insertion_order=false")
dbExecute(con, "CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)")
qp <- function(path) as.character(dbQuoteString(con, gsub("\\\\", "/", path)))

union_sql <- qp(union_path)
capes_sql <- qp(capes_path)
edu_sql <- qp(file.path(edu_dir, "*"))
census_sql <- qp(census_path)

dbExecute(con, sprintf(
  "CREATE TEMP TABLE sample_pairs AS
   SELECT *, md5(person_key || '#' || CAST(user_id AS VARCHAR)) AS pair_id
   FROM read_parquet(%s)
   ORDER BY hash(person_key || '#' || CAST(user_id AS VARCHAR))
   LIMIT %d", union_sql, n_draw))

dbExecute(con, sprintf(
  "CREATE TEMP TABLE census_map AS
   SELECT DISTINCT TRY_CAST(CO_IES AS BIGINT) AS co_ies,
          TRY_CAST(CO_MANTENEDORA AS BIGINT) AS co_mantenedora
   FROM read_csv(%s, delim=';', header=true, all_varchar=true,
                 encoding='latin-1')
   WHERE TRY_CAST(CO_IES AS BIGINT) IS NOT NULL", census_sql))

dbExecute(con, sprintf(
  "CREATE TEMP TABLE capes_detail AS
   SELECT * EXCLUDE (rn) FROM (
     SELECT coalesce(nullif(trim(c.person_id), ''),
                     trim(c.full_name) || '|' || CAST(c.birth_year AS VARCHAR))
              AS person_key,
            CASE WHEN trim(c.course_type) LIKE 'MESTRADO%%' THEN 'master'
                 WHEN trim(c.course_type) LIKE 'DOUTORADO%%' THEN 'phd' END AS lvl,
            c.course_name, c.course_area, c.institution,
            TRY_CAST(c.course_start_year AS INTEGER) AS start_year,
            c.CO_IES AS co_ies, c.CO_MANTENEDORA AS co_mantenedora,
            c.institution_bucket,
            row_number() OVER (
              PARTITION BY coalesce(nullif(trim(c.person_id), ''),
                           trim(c.full_name) || '|' ||
                           CAST(c.birth_year AS VARCHAR)),
                CASE WHEN trim(c.course_type) LIKE 'MESTRADO%%' THEN 'master'
                     WHEN trim(c.course_type) LIKE 'DOUTORADO%%' THEN 'phd' END
              ORDER BY TRY_CAST(c.course_start_year AS INTEGER) NULLS LAST,
                       c.institution_bucket NULLS LAST, c.course_code) AS rn
     FROM read_parquet(%s) c
     WHERE coalesce(nullif(trim(c.person_id), ''),
                    trim(c.full_name) || '|' || CAST(c.birth_year AS VARCHAR))
           IN (SELECT person_key FROM sample_pairs))
   WHERE rn = 1", capes_sql))

dbExecute(con, sprintf(
  "CREATE TEMP TABLE rev_detail AS
   SELECT * EXCLUDE (rn) FROM (
     SELECT e.user_id, e.lvl, e.degree_raw, e.field_raw, e.university_raw,
            e.y0 AS start_year, e.y1 AS end_year,
            e.co_ies, c.co_mantenedora,
            CASE WHEN c.co_mantenedora IS NOT NULL
                   THEN 'M:' || CAST(c.co_mantenedora AS VARCHAR)
                 WHEN e.co_ies IS NOT NULL
                   THEN 'I:' || CAST(e.co_ies AS VARCHAR) END
              AS institution_bucket,
            row_number() OVER (
              PARTITION BY e.user_id, e.lvl
              ORDER BY e.y0 NULLS LAST, e.y1 NULLS LAST,
                       CASE WHEN c.co_mantenedora IS NOT NULL
                              THEN 'M:' || CAST(c.co_mantenedora AS VARCHAR)
                            WHEN e.co_ies IS NOT NULL
                              THEN 'I:' || CAST(e.co_ies AS VARCHAR) END
                         NULLS LAST,
                       coalesce(e.rsid, 2147483647)) AS rn
     FROM (
       SELECT CAST(user_id AS VARCHAR) AS user_id, rsid,
              TRY_CAST(CO_IES AS BIGINT) AS co_ies,
              degree_raw, field_raw, university_raw,
              CAST(year(startdate) AS INTEGER) AS y0,
              CAST(year(enddate) AS INTEGER) AS y1,
              (%1$s) AS lvl,
              (degree = 'MBA' OR regexp_like(dr, '%2$s')) AS is_mba
       FROM (SELECT user_id, rsid, CO_IES, degree_raw, degree, field_raw,
                    university_raw, startdate, enddate,
                    lower(trim(coalesce(degree_raw, ''))) AS dr
             FROM read_parquet(%3$s)
             WHERE CAST(user_id AS VARCHAR) IN
                   (SELECT CAST(user_id AS VARCHAR) FROM sample_pairs))
     ) e
     LEFT JOIN census_map c USING (co_ies)
     WHERE (e.lvl = 'master' AND NOT e.is_mba) OR e.lvl = 'phd')
   WHERE rn = 1",
  sql_shanghai_level, rx_mba, edu_sql))

dbExecute(con, "
  CREATE TEMP TABLE audit AS
  SELECT
    s.pair_id, s.matched_arm, s.in_msc, s.in_phd,
    s.capes_full_name, s.birth_year, s.revelio_fullname,
    s.jw_combo, s.jw_lastname, s.jw_name,
    s.n_users, s.n_persons,
    cm.course_name AS capes_msc_course,
    cm.course_area AS capes_msc_area,
    cm.institution AS capes_msc_institution,
    cm.start_year AS capes_msc_start_year,
    cm.co_ies AS capes_msc_CO_IES,
    cm.co_mantenedora AS capes_msc_CO_MANTENEDORA,
    cm.institution_bucket AS capes_msc_bucket,
    rm.degree_raw AS linkedin_msc_degree,
    rm.field_raw AS linkedin_msc_field,
    rm.university_raw AS linkedin_msc_institution,
    rm.start_year AS linkedin_msc_start_year,
    rm.end_year AS linkedin_msc_end_year,
    rm.co_ies AS linkedin_msc_CO_IES,
    rm.co_mantenedora AS linkedin_msc_CO_MANTENEDORA,
    rm.institution_bucket AS linkedin_msc_bucket,
    cp.course_name AS capes_phd_course,
    cp.course_area AS capes_phd_area,
    cp.institution AS capes_phd_institution,
    cp.start_year AS capes_phd_start_year,
    cp.co_ies AS capes_phd_CO_IES,
    cp.co_mantenedora AS capes_phd_CO_MANTENEDORA,
    cp.institution_bucket AS capes_phd_bucket,
    rp.degree_raw AS linkedin_phd_degree,
    rp.field_raw AS linkedin_phd_field,
    rp.university_raw AS linkedin_phd_institution,
    rp.start_year AS linkedin_phd_start_year,
    rp.end_year AS linkedin_phd_end_year,
    rp.co_ies AS linkedin_phd_CO_IES,
    rp.co_mantenedora AS linkedin_phd_CO_MANTENEDORA,
    rp.institution_bucket AS linkedin_phd_bucket,
    ''::VARCHAR AS verdict, ''::VARCHAR AS reviewer_notes
  FROM sample_pairs s
  LEFT JOIN capes_detail cm
    ON s.person_key = cm.person_key AND cm.lvl = 'master'
  LEFT JOIN capes_detail cp
    ON s.person_key = cp.person_key AND cp.lvl = 'phd'
  LEFT JOIN rev_detail rm
    ON CAST(s.user_id AS VARCHAR) = rm.user_id AND rm.lvl = 'master'
  LEFT JOIN rev_detail rp
    ON CAST(s.user_id AS VARCHAR) = rp.user_id AND rp.lvl = 'phd'
  ORDER BY s.matched_arm, s.pair_id")

qa <- dbGetQuery(con, "
  SELECT count(*) AS rows, count(DISTINCT pair_id) AS pairs,
         count_if(in_msc AND capes_msc_bucket IS DISTINCT FROM
                   linkedin_msc_bucket) AS bad_msc_bucket,
         count_if(in_phd AND capes_phd_bucket IS DISTINCT FROM
                   linkedin_phd_bucket) AS bad_phd_bucket
  FROM audit")
if (qa$bad_msc_bucket != 0L || qa$bad_phd_bucket != 0L) {
  print(dbGetQuery(con, "
    SELECT pair_id, matched_arm,
           capes_msc_bucket, linkedin_msc_bucket,
           capes_phd_bucket, linkedin_phd_bucket
    FROM audit
    WHERE (in_msc AND capes_msc_bucket IS DISTINCT FROM linkedin_msc_bucket)
       OR (in_phd AND capes_phd_bucket IS DISTINCT FROM linkedin_phd_bucket)
    LIMIT 10"), row.names = FALSE)
}
stopifnot(qa$rows == n_draw, qa$pairs == n_draw,
          qa$bad_msc_bucket == 0L, qa$bad_phd_bucket == 0L)

for (p in c(sample_path, json_path)) if (file.exists(paste0(p, ".part"))) {
  unlink(paste0(p, ".part"))
}
dbExecute(con, sprintf(
  "COPY audit TO %s (FORMAT PARQUET, COMPRESSION ZSTD)",
  qp(paste0(sample_path, ".part"))))
dbExecute(con, sprintf(
  "COPY audit TO %s (FORMAT JSON, ARRAY true)",
  qp(paste0(json_path, ".part"))))
for (p in c(sample_path, json_path)) {
  if (file.exists(p)) unlink(p)
  stopifnot(file.rename(paste0(p, ".part"), p))
}
cat("audit rows:", qa$rows, "\n")
cat("sample:", sample_path, "\n")
cat("json:", json_path, "\n")
