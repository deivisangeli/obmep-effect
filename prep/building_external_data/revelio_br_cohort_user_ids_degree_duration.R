####################################################################
### Revelio Brazilian cohort, ranked-degree regex + duration fallback
###
### LOCAL, ONLINE PIPELINE. This script queries Athena, writes parquet
### to S3 (revelio-misc, us-east-2), registers an external table, and
### downloads the result to Dropbox. It must not be run in SEDAP.
###
### This is a parallel comparison cohort. It deliberately leaves the
### canonical obmep_br_cohort_user_ids table and parquet untouched.
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "aws.s3", "RAthena", "arrow", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(aws.s3)

####################################################################
### Parameters and immutable comparison target
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
out_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
out_path <- file.path(
  out_dir, "obmep_br_cohort_user_ids_degree_duration.parquet")
report_path <- file.path(
  out_dir, "obmep_br_cohort_user_ids_degree_duration_comparison.json")
detail_path <- file.path(
  out_dir, "obmep_br_cohort_user_ids_degree_duration_degree_values.csv")
canonical_path <- file.path(out_dir, "obmep_br_cohort_user_ids.parquet")

min_year <- 2007L
s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
s3_prefix <- "exports/obmep_br_cohort_user_ids_degree_duration"
s3_path <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table <- "obmep_br_cohort_user_ids_degree_duration"
canonical_table <- "obmep_br_cohort_user_ids"
inst_table <- "openalex_institutions_br"

if (file.exists(out_path) || file.exists(report_path) || file.exists(detail_path)) {
  stop("A local output already exists. This build never overwrites a prior run: ",
       paste(c(out_path, report_path, detail_path)[
         file.exists(c(out_path, report_path, detail_path))], collapse = ", "))
}
canonical_md5_before <- if (file.exists(canonical_path)) {
  unname(tools::md5sum(canonical_path))
} else {
  NA_character_
}

py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

patterns_file <- Sys.getenv(
  "OBMEP_DEGREE_PATTERNS",
  unset = paste0("C:/Users/megaj/repos/obmep_effect/prep/",
                 "building_external_data/br_degree_patterns.R"))
if (!file.exists(patterns_file)) patterns_file <- "br_degree_patterns.R"
stopifnot(file.exists(patterns_file))
source(patterns_file)

####################################################################
### Cohort query
####################################################################

# The ranked classifier is byte-identical to current RUF/Shanghai
# production: the shared cascade plus its outer raw high-school veto.
# Duration is a fallback only for degree='empty' records that reached the
# residual `other` arm and have valid endpoint years exactly 3--6 apart.
select_sql <- sprintf("
WITH inst_fold AS (
  SELECT lower(regexp_replace(normalize(cleaned_display_name, NFD), '\\p{M}', '')) AS nm_fold,
         max(CASE WHEN type = 'education' THEN 1 ELSE 0 END) AS is_edu
  FROM %1$s
  GROUP BY lower(regexp_replace(normalize(cleaned_display_name, NFD), '\\p{M}', ''))
),
inst_exact AS (
  SELECT DISTINCT lower(cleaned_display_name) AS nm_exact FROM %1$s
),
raws AS (
  SELECT DISTINCT university_raw
  FROM academic_individual_user_education
  WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''
),
seg AS (
  SELECT r.university_raw, 1 AS seg_edu
  FROM raws r
  CROSS JOIN UNNEST(split(regexp_replace(regexp_replace(
               r.university_raw, '[/()]', '|'), ' - ', '|'), '|')) AS t(part)
  JOIN inst_fold i
    ON lower(regexp_replace(normalize(trim(t.part), NFD), '\\p{M}', '')) = i.nm_fold
  WHERE length(trim(t.part)) >= 3 AND i.is_edu = 1
  GROUP BY r.university_raw
),
raw_cls AS (
  SELECT r.university_raw,
         CASE WHEN lower(trim(r.university_raw)) IN
                        (SELECT nm_exact FROM inst_exact)
              THEN 1 ELSE 0 END AS m_exact,
         CASE WHEN lower(regexp_replace(normalize(trim(r.university_raw), NFD), '\\p{M}', ''))
                        IN (SELECT nm_fold FROM inst_fold)
                    OR s.seg_edu = 1
              THEN 1 ELSE 0 END AS m_norm
  FROM raws r
  LEFT JOIN seg s ON r.university_raw = s.university_raw
),
education_base AS (
  SELECT e.user_id, e.startdate, e.enddate, e.degree, e.degree_raw,
         e.university_country, e.university_raw,
         lower(trim(coalesce(e.degree_raw, ''))) AS dr,
         CAST(year(e.startdate) AS integer) AS start_year,
         CAST(year(e.enddate) AS integer) AS end_year
  FROM academic_individual_user_education e
),
education_classified AS (
  SELECT e.*, (%2$s) AS ranked_level, (%3$s) AS residual_other
  FROM education_base e
),
education_scored AS (
  SELECT e.*,
         ranked_level = 'bachelor' AS is_ranked,
         residual_other
           AND startdate IS NOT NULL AND enddate IS NOT NULL
           AND end_year - start_year IN (3, 4, 5, 6) AS is_duration
  FROM education_classified e
),
education_users AS (
  SELECT e.user_id,
         min(CASE WHEN is_ranked OR is_duration THEN start_year END)
           AS min_bach_year,
         min(CASE WHEN degree = 'Bachelor' THEN start_year END)
           AS min_bach_year_strict,
         min(CASE WHEN is_ranked THEN start_year END)
           AS min_bach_year_ranked,
         min(CASE WHEN is_duration THEN start_year END)
           AS min_bach_year_duration,
         CAST(max(CASE WHEN is_ranked AND start_year IS NOT NULL
                       THEN 1 ELSE 0 END) AS integer)
           AS bach_by_ranked,
         CAST(max(CASE WHEN is_duration THEN 1 ELSE 0 END) AS integer)
           AS bach_by_duration,
         CAST(max(CASE WHEN university_country = 'Brazil' THEN 1 ELSE 0 END) AS integer)
           AS br_educ_country,
         CAST(max(coalesce(c.m_exact, 0)) AS integer) AS br_openalex,
         CAST(max(coalesce(c.m_norm, 0)) AS integer) AS br_openalex_norm
  FROM education_scored e
  LEFT JOIN raw_cls c ON e.university_raw = c.university_raw
  GROUP BY e.user_id
),
position_users AS (
  SELECT user_id,
         min(try_cast(substr(startdate, 1, 4) AS integer)) AS min_pos_year,
         CAST(max(CASE WHEN country = 'Brazil' THEN 1 ELSE 0 END) AS integer)
           AS br_position
  FROM academic_individual_position
  GROUP BY user_id
)
SELECT p.user_id,
       p.br_position,
       e.br_educ_country,
       e.br_openalex,
       e.br_openalex_norm,
       p.min_pos_year,
       e.min_bach_year,
       e.min_bach_year_strict,
       e.min_bach_year_ranked,
       e.min_bach_year_duration,
       e.bach_by_ranked,
       e.bach_by_duration
FROM position_users p
INNER JOIN education_users e ON p.user_id = e.user_id
WHERE (p.br_position = 1 OR e.br_educ_country = 1 OR e.br_openalex_norm = 1)
  AND p.min_pos_year IS NOT NULL AND p.min_pos_year >= %4$d
  AND e.min_bach_year IS NOT NULL AND e.min_bach_year >= %4$d",
  inst_table, sql_ranked_level, sql_is_residual_other, min_year)

unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')", select_sql, s3_path)

ddl_txt <- sprintf(
"CREATE EXTERNAL TABLE %s.%s (
  user_id BIGINT,
  br_position INT,
  br_educ_country INT,
  br_openalex INT,
  br_openalex_norm INT,
  min_pos_year INT,
  min_bach_year INT,
  min_bach_year_strict INT,
  min_bach_year_ranked INT,
  min_bach_year_duration INT,
  bach_by_ranked INT,
  bach_by_duration INT
)
STORED AS PARQUET
LOCATION '%s'", athena_schema, athena_table, s3_path)

cat("=========== DESTINATION GUARDS ===========\n")
existing <- tryCatch(
  get_bucket(bucket = s3_bucket, prefix = paste0(s3_prefix, "/"),
             region = s3_region, max = 100),
  error = function(e) {
    stop("Could not verify the destination prefix: ", conditionMessage(e))
  })
if (length(existing)) {
  stop("S3 destination is not empty: ", s3_path)
}
cat("  S3 prefix is empty\n")

con <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name = s3_region,
                 schema_name = athena_schema)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

tables <- dbGetQuery(con, sprintf("SHOW TABLES IN %s", athena_schema))[[1]]
if (athena_table %in% tables) {
  stop("Athena table already exists: ", athena_schema, ".", athena_table)
}
if (!canonical_table %in% tables) {
  stop("Canonical comparison table is missing: ",
       athena_schema, ".", canonical_table)
}
inst_n <- dbGetQuery(con, sprintf("SELECT count(*) AS n FROM %s.%s",
                                  athena_schema, inst_table))$n
if (inst_n == 0) stop("Brazilian OpenAlex institution table is empty.")
canonical_n_before <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM %s.%s", athena_schema, canonical_table))$n
if (canonical_n_before == 0) stop("Canonical cohort is empty.")
cat("  canonical rows:", format(canonical_n_before, big.mark = ","), "\n")

####################################################################
### Build and register the parallel cohort
####################################################################

cat("\n=========== ATHENA BUILD ===========\n")
t0 <- Sys.time()
dbExecute(con, unload_sql)
cat("  UNLOAD finished in",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
dbExecute(con, ddl_txt)

####################################################################
### Validation and current-vs-new comparison
####################################################################

cat("\n=========== VALIDATION ===========\n")
validation <- dbGetQuery(con, sprintf("
SELECT count(*) AS n_rows,
       count(DISTINCT user_id) AS n_users,
       sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS null_users,
       min(min_pos_year) AS min_pos_year,
       min(min_bach_year) AS min_bach_year,
       sum(CASE WHEN br_position NOT IN (0, 1)
                  OR br_educ_country NOT IN (0, 1)
                  OR br_openalex NOT IN (0, 1)
                  OR br_openalex_norm NOT IN (0, 1)
                  OR bach_by_ranked NOT IN (0, 1)
                  OR bach_by_duration NOT IN (0, 1)
                THEN 1 ELSE 0 END) AS bad_flags,
       sum(CASE WHEN br_position + br_educ_country + br_openalex_norm = 0
                THEN 1 ELSE 0 END) AS no_brazil_route,
       sum(CASE WHEN br_openalex = 1 AND br_openalex_norm = 0
                THEN 1 ELSE 0 END) AS bad_openalex_superset,
       sum(CASE WHEN bach_by_ranked = 0 AND bach_by_duration = 0
                THEN 1 ELSE 0 END) AS no_bachelor_route,
       sum(CASE WHEN (bach_by_ranked = 1) <>
                          (min_bach_year_ranked IS NOT NULL)
                  OR (bach_by_duration = 1) <>
                          (min_bach_year_duration IS NOT NULL)
                THEN 1 ELSE 0 END) AS bad_route_year,
       sum(CASE WHEN min_bach_year > coalesce(min_bach_year_ranked, 9999)
                  OR min_bach_year > coalesce(min_bach_year_duration, 9999)
                THEN 1 ELSE 0 END) AS bad_union_year
FROM %s.%s", athena_schema, athena_table))
print(validation)

stopifnot(
  validation$n_rows == validation$n_users,
  validation$null_users == 0,
  validation$min_pos_year >= min_year,
  validation$min_bach_year >= min_year,
  validation$bad_flags == 0,
  validation$no_brazil_route == 0,
  validation$bad_openalex_superset == 0,
  validation$no_bachelor_route == 0,
  validation$bad_route_year == 0,
  validation$bad_union_year == 0
)

comparison <- dbGetQuery(con, sprintf("
WITH membership AS (
  SELECT coalesce(c.user_id, n.user_id) AS user_id,
         c.user_id IS NOT NULL AS in_current,
         n.user_id IS NOT NULL AS in_new
  FROM %1$s.%2$s c
  FULL OUTER JOIN %1$s.%3$s n ON c.user_id = n.user_id
)
SELECT count_if(in_current) AS current_users,
       count_if(in_new) AS new_users,
       count_if(in_current AND in_new) AS retained_users,
       count_if(NOT in_current AND in_new) AS gained_users,
       count_if(in_current AND NOT in_new) AS lost_users
FROM membership", athena_schema, canonical_table, athena_table))
print(comparison)
stopifnot(comparison$current_users == canonical_n_before)

routes <- dbGetQuery(con, sprintf("
SELECT CASE WHEN bach_by_ranked = 1 AND bach_by_duration = 1 THEN 'both'
            WHEN bach_by_ranked = 1 THEN 'ranked_only'
            ELSE 'duration_only' END AS bachelor_route,
       count(*) AS users
FROM %s.%s
GROUP BY 1 ORDER BY 1", athena_schema, athena_table))
print(routes)

admission_routes <- dbGetQuery(con, sprintf("
SELECT br_position, br_educ_country, br_openalex_norm,
       count(*) AS users
FROM %s.%s
GROUP BY 1, 2, 3
ORDER BY users DESC, 1, 2, 3", athena_schema, athena_table))

earliest_bach_years <- dbGetQuery(con, sprintf("
SELECT min_bach_year, count(*) AS users
FROM %s.%s
GROUP BY 1 ORDER BY 1", athena_schema, athena_table))

duration_distribution <- dbGetQuery(con, sprintf("
WITH duration_users AS (
  SELECT user_id FROM %1$s.%2$s WHERE bach_by_duration = 1
),
base AS (
  SELECT e.user_id, e.degree, e.degree_raw, e.startdate, e.enddate,
         lower(trim(coalesce(e.degree_raw, ''))) AS dr,
         CAST(year(e.startdate) AS integer) AS start_year,
         CAST(year(e.enddate) AS integer) AS end_year
  FROM academic_individual_user_education e
  JOIN duration_users u ON e.user_id = u.user_id
),
classified AS (
  SELECT *, (%3$s) AS residual_other FROM base
),
qualified AS (
  SELECT * FROM classified
  WHERE residual_other
    AND startdate IS NOT NULL AND enddate IS NOT NULL
    AND end_year - start_year IN (3, 4, 5, 6)
)
SELECT end_year - start_year AS duration_years,
       count(*) AS education_rows,
       count(DISTINCT user_id) AS users
FROM qualified
GROUP BY 1 ORDER BY 1", athena_schema, athena_table,
  sql_is_residual_other))

# One focused rescan supplies auditable degree text for the changed users.
# Gained rows retain only new qualifying evidence; lost rows retain only old
# criterion-E evidence rejected by the new ranked/duration definition.
detail_sql <- sprintf("
WITH changed AS (
  SELECT coalesce(c.user_id, n.user_id) AS user_id,
         CASE WHEN c.user_id IS NULL THEN 'gained' ELSE 'lost' END AS membership_change
  FROM %1$s.%2$s c
  FULL OUTER JOIN %1$s.%3$s n ON c.user_id = n.user_id
  WHERE c.user_id IS NULL OR n.user_id IS NULL
),
base AS (
  SELECT e.user_id, e.degree, e.degree_raw, e.startdate, e.enddate,
         lower(trim(coalesce(e.degree_raw, ''))) AS dr,
         CAST(year(e.startdate) AS integer) AS start_year,
         CAST(year(e.enddate) AS integer) AS end_year
  FROM academic_individual_user_education e
  JOIN changed c ON e.user_id = c.user_id
),
classified AS (
  SELECT b.*, c.membership_change,
         (%4$s) AS ranked_level,
         (%5$s) AS residual_other,
         (%6$s) AS old_bachelor
  FROM base b JOIN changed c ON b.user_id = c.user_id
),
scored AS (
  SELECT *, ranked_level = 'bachelor' AS ranked_bachelor,
         residual_other AND startdate IS NOT NULL AND enddate IS NOT NULL
           AND end_year - start_year IN (3, 4, 5, 6) AS duration_bachelor
  FROM classified
),
relevant AS (
  SELECT *,
         CASE WHEN ranked_bachelor THEN 'ranked_regex'
              WHEN duration_bachelor THEN 'duration_fallback'
              ELSE 'old_regex_rejected' END AS evidence_route
  FROM scored
  WHERE (membership_change = 'gained' AND (ranked_bachelor OR duration_bachelor))
     OR (membership_change = 'lost' AND old_bachelor
         AND NOT ranked_bachelor AND NOT duration_bachelor)
)
SELECT membership_change, evidence_route,
       end_year - start_year AS duration_years,
       degree, degree_raw, count(*) AS education_rows,
       count(DISTINCT user_id) AS users
FROM relevant
GROUP BY 1, 2, 3, 4, 5
ORDER BY users DESC, education_rows DESC, membership_change, evidence_route
LIMIT 1000",
  athena_schema, canonical_table, athena_table,
  sql_ranked_level, sql_is_residual_other, sql_is_bachelor)
degree_values <- dbGetQuery(con, detail_sql)
utils::write.csv(degree_values, detail_path, row.names = FALSE, na = "")

####################################################################
### Download and prove that the canonical cohort did not change
####################################################################

cat("\n=========== LOCAL COPY ===========\n")
if (!arrow::arrow_with_s3()) {
  stop("This Arrow build has no S3 support; the Athena result is valid at ",
       s3_path, " but the local parquet was not written.")
}
ds <- arrow::open_dataset(s3_path, format = "parquet")
arrow::write_parquet(arrow::Scanner$create(ds)$ToTable(), out_path,
                     compression = "snappy")
local_n <- nrow(arrow::open_dataset(out_path, format = "parquet"))
if (local_n != validation$n_rows) {
  stop("Local parquet has ", local_n, " rows; Athena has ", validation$n_rows)
}

canonical_n_after <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM %s.%s", athena_schema, canonical_table))$n
canonical_md5_after <- if (file.exists(canonical_path)) {
  unname(tools::md5sum(canonical_path))
} else {
  NA_character_
}
if (canonical_n_after != canonical_n_before ||
    !identical(canonical_md5_before, canonical_md5_after)) {
  stop("The canonical cohort changed during the parallel build.")
}

report <- list(
  generated_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
  definition = list(
    min_year = min_year,
    ranked_classifier = "sql_ranked_level from br_degree_patterns.R",
    duration_fallback = "residual other; degree=empty; end_year-start_year in 3:6"
  ),
  outputs = list(local_parquet = out_path, s3_prefix = s3_path,
                 athena_table = paste0(athena_schema, ".", athena_table),
                 degree_values_csv = detail_path),
  validation = validation,
  comparison = comparison,
  bachelor_routes = routes,
  brazil_admission_routes = admission_routes,
  earliest_bachelor_years = earliest_bach_years,
  duration_distribution = duration_distribution,
  changed_degree_value_rows = nrow(degree_values),
  canonical = list(
    local_path = canonical_path,
    md5_before = canonical_md5_before,
    md5_after = canonical_md5_after,
    rows_before = canonical_n_before,
    rows_after = canonical_n_after,
    unchanged = TRUE
  )
)
jsonlite::write_json(report, report_path, pretty = TRUE, auto_unbox = TRUE,
                     dataframe = "rows", na = "null", digits = NA)

cat("\n=========== SUMMARY ===========\n")
cat("  local parquet :", out_path, "\n")
cat("  comparison    :", report_path, "\n")
cat("  degree values :", detail_path, "\n")
cat("  Athena table  :", paste0(athena_schema, ".", athena_table), "\n")
cat("  current/new   :", format(comparison$current_users, big.mark = ","), "/",
    format(comparison$new_users, big.mark = ","), "\n")
cat("  retained      :", format(comparison$retained_users, big.mark = ","), "\n")
cat("  gained/lost   :", format(comparison$gained_users, big.mark = ","), "/",
    format(comparison$lost_users, big.mark = ","), "\n")
cat("[OK] parallel cohort built, compared, downloaded, and validated\n")
