####################################################################
### 24a. CAPES stricto sensu -> e-MEC IES and maintainer buckets
###
### Local, offline preparation. Reads the unified CAPES panel, the
### current e-MEC institution catalog and the 2024 Higher Education
### Census. It uses no network and must not be sent to SEDAP.
###
### The output preserves the exact 733,879-row population produced by
### script 24 (birth year >= 1988, master's/PhD, 2004-2024) and adds a
### conservative institution identity:
###   1. one unique native CD_ENTIDADE_EMEC within the source group;
###   2. one unique code observed for the exact CAPES institution name;
###   3. one unique exact normalized official/parenthetical-cleaned
###      e-MEC catalog name;
###   4. otherwise unresolved.
###
### The matching bucket is M:<CO_MANTENEDORA>. A code absent from the
### 2024 Census falls back to I:<CO_IES>. Prefixes prevent numerical
### collisions between the two identifier systems.
####################################################################

library(DBI)
library(duckdb)
library(jsonlite)

root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)
capes_dir <- file.path(root, "Data/intermediate/capes_discentes")
panel_path <- file.path(capes_dir, "capes_discentes_2004_2024.parquet")
extract_path <- file.path(
  capes_dir, "capes_masters_doctorates_born_1988plus_2004_2024.csv"
)
emec_path <- file.path(
  root, "Data/raw/PDA_Lista_Instituicoes_Ensino_Superior_do_Brasil_EMEC.csv"
)
census_path <- file.path(
  root, "Data/raw/Censo Superior/MICRODADOS_ED_SUP_IES_2024.CSV"
)
out_path <- file.path(
  capes_dir,
  "capes_masters_doctorates_born_1988plus_2004_2024_emec_mantenedora.parquet"
)
report_path <- file.path(capes_dir, "capes_emec_mantenedora_report.json")

stopifnot(
  file.exists(panel_path), file.exists(extract_path),
  file.exists(emec_path), file.exists(census_path)
)
if (file.exists(out_path) &&
    Sys.getenv("OBMEP_CAPES_MANTENEDORA_OVERWRITE", unset = "0") != "1") {
  stop("Output already exists: ", out_path,
       "\nSet OBMEP_CAPES_MANTENEDORA_OVERWRITE=1 to rebuild it.")
}

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_capes_mantenedora")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
part_path <- paste0(out_path, ".part")
report_part <- paste0(report_path, ".part")
for (p in c(part_path, report_part)) if (file.exists(p)) unlink(p)

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(dbExecute(con, "PRAGMA memory_limit='8GB'"))
invisible(dbExecute(con, "SET threads=4"))
invisible(dbExecute(
  con,
  sprintf("SET temp_directory=%s", as.character(dbQuoteString(con, tmp_dir)))
))
invisible(dbExecute(con, "SET preserve_insertion_order=false"))

qp <- function(path) {
  as.character(dbQuoteString(con, gsub("\\\\", "/", path)))
}

cat("CAPES -> e-MEC maintainer buckets\n")
cat("panel :", panel_path, "\n")
cat("e-MEC :", emec_path, "\n")
cat("census:", census_path, "\n")
cat("output:", out_path, "\n\n")

####################################################################
### Rebuild script 24's population, carrying native e-MEC evidence
####################################################################

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE base AS
   SELECT
     CASE WHEN TRY_CAST(AN_BASE AS INTEGER) >= 2013
            THEN concat('id:', trim(ID_PESSOA))
          ELSE concat('name_birth:', trim(NM_DISCENTE), '|',
                      trim(AN_NASCIMENTO_DISCENTE)) END AS person_key,
     CASE WHEN TRY_CAST(AN_BASE AS INTEGER) >= 2013
            THEN concat('id:', trim(CD_ENTIDADE_CAPES))
          ELSE concat('name:', trim(NM_ENTIDADE_ENSINO)) END AS institution_key,
     CASE WHEN TRY_CAST(AN_BASE AS INTEGER) >= 2013
            THEN trim(ID_PESSOA) END AS person_id,
     trim(NM_DISCENTE) AS full_name,
     TRY_CAST(AN_NASCIMENTO_DISCENTE AS INTEGER) AS birth_year,
     trim(CD_PROGRAMA_IES) AS course_code,
     trim(NM_PROGRAMA_IES) AS course_name,
     trim(NM_ENTIDADE_ENSINO) AS institution,
     trim(NM_AREA_AVALIACAO) AS course_area,
     CASE WHEN TRY_CAST(AN_BASE AS INTEGER) <= 2012
            THEN trim(NM_NIVEL_TITULACAO_DISCENTE)
          ELSE trim(DS_GRAU_ACADEMICO_DISCENTE) END AS course_type,
     CASE WHEN TRY_CAST(AN_BASE AS INTEGER) <= 2012
            THEN TRY_CAST(AN_MATRICULA_DISCENTE AS INTEGER)
          ELSE year(DATE '1899-12-30' +
                    TRY_CAST(DT_MATRICULA_DISCENTE AS INTEGER)) END
       AS course_start_year,
     TRY_CAST(nullif(trim(CD_ENTIDADE_EMEC), '') AS BIGINT) AS native_co_ies,
     TRY_CAST(AN_BASE AS INTEGER) AS base_year,
     source_file
   FROM read_parquet(%s)
   WHERE TRY_CAST(AN_NASCIMENTO_DISCENTE AS INTEGER) >= 1988
     AND ((TRY_CAST(AN_BASE AS INTEGER) <= 2012
           AND NM_NIVEL_TITULACAO_DISCENTE IN
             ('MESTRADO', 'MESTRADO PROFISSIONAL', 'DOUTORADO'))
       OR (TRY_CAST(AN_BASE AS INTEGER) >= 2013
           AND DS_GRAU_ACADEMICO_DISCENTE IN
             ('MESTRADO', 'MESTRADO PROFISSIONAL',
              'DOUTORADO', 'DOUTORADO PROFISSIONAL')))",
  qp(panel_path)
)))

invisible(dbExecute(con, "
  CREATE TEMP TABLE cohort AS
  SELECT
    person_key, institution_key, course_code, course_type,
    first(person_id ORDER BY base_year, source_file) AS person_id,
    first(full_name ORDER BY base_year, source_file) AS full_name,
    first(birth_year ORDER BY base_year, source_file) AS birth_year,
    first(course_name ORDER BY base_year, source_file) AS course_name,
    first(institution ORDER BY base_year, source_file) AS institution,
    first(course_area ORDER BY base_year, source_file) AS course_area,
    min(course_start_year) AS course_start_year,
    count(DISTINCT native_co_ies) AS native_code_count,
    min(native_co_ies) AS native_co_ies
  FROM base
  GROUP BY person_key, institution_key, course_code, course_type
"))

cohort_qa <- dbGetQuery(con, "
  SELECT count(*) AS rows,
         count(DISTINCT person_key) AS persons,
         count_if(birth_year < 1988 OR birth_year IS NULL) AS bad_birth,
         count_if(course_type NOT IN
           ('MESTRADO', 'MESTRADO PROFISSIONAL',
            'DOUTORADO', 'DOUTORADO PROFISSIONAL')) AS bad_degree,
         count(*) - count(DISTINCT
           (person_key, institution_key, course_code, course_type)) AS dup_keys
  FROM cohort
")
stopifnot(
  cohort_qa$rows == 733879L,
  cohort_qa$persons == 567270L,
  cohort_qa$bad_birth == 0L,
  cohort_qa$bad_degree == 0L,
  cohort_qa$dup_keys == 0L
)

# The reconstructed nine public columns must reproduce script 24 exactly.
extract_cols <- paste(c(
  "person_id", "full_name", "birth_year", "course_code", "course_name",
  "institution", "course_area", "course_type", "course_start_year"
), collapse = ", ")
roundtrip_diff <- dbGetQuery(con, sprintf(
  "WITH old AS (
     SELECT person_id, full_name, TRY_CAST(birth_year AS INTEGER) birth_year,
            course_code, course_name, institution, course_area, course_type,
            TRY_CAST(course_start_year AS INTEGER) course_start_year
     FROM read_csv_auto(%1$s, header=true, all_varchar=true)),
   new AS (SELECT %2$s FROM cohort)
   SELECT (SELECT count(*) FROM (SELECT * FROM new EXCEPT ALL SELECT * FROM old))
            AS new_only,
          (SELECT count(*) FROM (SELECT * FROM old EXCEPT ALL SELECT * FROM new))
            AS old_only",
  qp(extract_path), extract_cols
))
stopifnot(roundtrip_diff$new_only == 0L, roundtrip_diff$old_only == 0L)

####################################################################
### Conservative CO_IES recovery
####################################################################

invisible(dbExecute(con, "
  CREATE TEMP TABLE later_name_map AS
  SELECT institution,
         count(DISTINCT native_co_ies) AS code_count,
         min(native_co_ies) AS co_ies
  FROM base
  WHERE native_co_ies IS NOT NULL
  GROUP BY institution
"))

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE emec_source AS
   SELECT TRY_CAST(CODIGO_DA_IES AS BIGINT) AS co_ies,
          NOME_DA_IES AS nome_ies,
          trim(regexp_replace(
            regexp_replace(NOME_DA_IES, '\\s*\\([^()]*\\)', '', 'g'),
            '\\s+', ' ', 'g')) AS cleaned_nome_ies
   FROM read_csv_auto(%s, header=true, all_varchar=true)",
  qp(emec_path)
)))
invisible(dbExecute(con, "
  CREATE TEMP TABLE catalog_name_map AS
  WITH aliases AS (
    SELECT co_ies, strip_accents(lower(trim(nome_ies))) AS name_norm
    FROM emec_source
    UNION
    SELECT co_ies, strip_accents(lower(trim(cleaned_nome_ies))) AS name_norm
    FROM emec_source
  )
  SELECT name_norm,
         count(DISTINCT co_ies) AS code_count,
         min(co_ies) AS co_ies
  FROM aliases
  WHERE length(name_norm) >= 3
  GROUP BY name_norm
"))

invisible(dbExecute(con, "
  CREATE TEMP TABLE resolved AS
  SELECT c.*,
    CASE
      WHEN c.native_code_count = 1 THEN c.native_co_ies
      WHEN c.native_code_count > 1 THEN NULL
      WHEN l.code_count = 1 THEN l.co_ies
      WHEN l.code_count > 1 THEN NULL
      WHEN e.code_count = 1 THEN e.co_ies
      ELSE NULL
    END::BIGINT AS co_ies,
    CASE
      WHEN c.native_code_count = 1 THEN 'native_unique'
      WHEN c.native_code_count > 1 THEN 'ambiguous_native'
      WHEN l.code_count = 1 THEN 'later_capes_exact_name'
      WHEN l.code_count > 1 THEN 'ambiguous_later_capes_name'
      WHEN e.code_count = 1 THEN 'emec_exact_name'
      WHEN e.code_count > 1 THEN 'ambiguous_emec_name'
      ELSE 'unresolved'
    END AS co_ies_source,
    CASE
      WHEN c.native_code_count > 0 THEN c.native_code_count
      WHEN coalesce(l.code_count, 0) > 0 THEN l.code_count
      ELSE coalesce(e.code_count, 0)
    END::INTEGER AS co_ies_candidate_count
  FROM cohort c
  LEFT JOIN later_name_map l USING (institution)
  LEFT JOIN catalog_name_map e
    ON e.name_norm = strip_accents(lower(trim(c.institution)))
"))

route_qa <- dbGetQuery(con, "
  SELECT co_ies_source, count(*) AS rows,
         count(DISTINCT institution) AS institutions
  FROM resolved GROUP BY 1 ORDER BY 1
")
expected_routes <- data.frame(
  co_ies_source = c(
    "ambiguous_later_capes_name", "ambiguous_native", "emec_exact_name",
    "later_capes_exact_name", "native_unique", "unresolved"
  ),
  rows = c(20, 1416, 934, 38574, 662354, 30581),
  stringsAsFactors = FALSE
)
got_routes <- route_qa[match(expected_routes$co_ies_source,
                            route_qa$co_ies_source), c("co_ies_source", "rows")]
if (!all(as.numeric(got_routes$rows) == expected_routes$rows)) {
  print(route_qa, row.names = FALSE)
  stop("CAPES e-MEC route counts drifted from the measured preflight.")
}
stopifnot(
  !anyNA(got_routes),
  identical(got_routes$co_ies_source, expected_routes$co_ies_source),
  sum(route_qa$rows) == 733879L,
  dbGetQuery(con, "SELECT count(*) n FROM resolved
                   WHERE (co_ies IS NULL) IS DISTINCT FROM
                         (co_ies_source IN
                           ('ambiguous_native',
                            'ambiguous_later_capes_name',
                            'ambiguous_emec_name', 'unresolved'))")$n == 0L
)

####################################################################
### CO_MANTENEDORA and the final bucket
####################################################################

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE census AS
   SELECT TRY_CAST(CO_IES AS BIGINT) AS co_ies,
          TRY_CAST(CO_MANTENEDORA AS BIGINT) AS co_mantenedora,
          NO_MANTENEDORA AS no_mantenedora,
          NO_IES AS census_ies_name
   FROM read_csv(%s, header=true, delim=';', all_varchar=true,
                 encoding='latin-1')",
  qp(census_path)
)))
census_qa <- dbGetQuery(con, "
  SELECT count(*) AS rows, count(DISTINCT co_ies) AS codes,
         count(DISTINCT co_mantenedora) AS maintainers,
         count_if(co_ies IS NULL OR co_mantenedora IS NULL) AS missing
  FROM census
")
stopifnot(
  census_qa$rows == 2561L, census_qa$codes == 2561L,
  census_qa$maintainers == 1755L, census_qa$missing == 0L
)

invisible(dbExecute(con, "
  CREATE TEMP TABLE final AS
  SELECT r.*,
         c.co_mantenedora, c.no_mantenedora, c.census_ies_name,
         CASE WHEN c.co_mantenedora IS NOT NULL
                THEN 'M:' || CAST(c.co_mantenedora AS VARCHAR)
              WHEN r.co_ies IS NOT NULL
                THEN 'I:' || CAST(r.co_ies AS VARCHAR)
              ELSE NULL END AS institution_bucket,
         CASE WHEN c.co_mantenedora IS NOT NULL THEN 'mantenedora'
              WHEN r.co_ies IS NOT NULL THEN 'co_ies_fallback'
              ELSE 'unresolved' END AS institution_bucket_source
  FROM resolved r LEFT JOIN census c USING (co_ies)
"))

bucket_qa <- dbGetQuery(con, "
  SELECT count(*) AS rows,
         count_if(co_ies IS NOT NULL) AS with_co_ies,
         count_if(co_mantenedora IS NOT NULL) AS with_maintainer,
         count_if(institution_bucket LIKE 'M:%') AS maintainer_buckets,
         count_if(institution_bucket LIKE 'I:%') AS ies_fallback_buckets,
         count_if(institution_bucket IS NULL) AS unresolved_buckets,
         count_if(institution_bucket IS NOT NULL AND
                  institution_bucket NOT LIKE 'M:%' AND
                  institution_bucket NOT LIKE 'I:%') AS bad_prefix
  FROM final
")
stopifnot(
  bucket_qa$rows == 733879L,
  bucket_qa$with_co_ies == bucket_qa$maintainer_buckets +
                            bucket_qa$ies_fallback_buckets,
  bucket_qa$unresolved_buckets == 733879L - bucket_qa$with_co_ies,
  bucket_qa$bad_prefix == 0L
)

####################################################################
### Atomic outputs and report
####################################################################

invisible(dbExecute(con, sprintf(
  "COPY (
     SELECT person_key, institution_key, person_id, full_name, birth_year,
            course_code, course_name, institution, course_area, course_type,
            course_start_year, co_ies AS CO_IES, co_ies_source,
            co_ies_candidate_count, co_mantenedora AS CO_MANTENEDORA,
            no_mantenedora, census_ies_name, institution_bucket,
            institution_bucket_source
     FROM final
     ORDER BY birth_year, full_name, institution, course_name, course_type,
              course_start_year, person_id NULLS FIRST
   ) TO %s (FORMAT PARQUET, COMPRESSION ZSTD)",
  qp(part_path)
)))

written_qa <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS rows, count(DISTINCT person_key) AS persons,
          count_if(birth_year < 1988) AS before_cutoff,
          count_if(institution_bucket IS NOT NULL AND
                   institution_bucket NOT LIKE 'M:%%' AND
                   institution_bucket NOT LIKE 'I:%%') AS bad_prefix
   FROM read_parquet(%s)", qp(part_path)
))
stopifnot(
  written_qa$rows == 733879L, written_qa$persons == 567270L,
  written_qa$before_cutoff == 0L, written_qa$bad_prefix == 0L
)

report <- list(
  completed_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
  population = cohort_qa,
  reconstructed_extract_diff = roundtrip_diff,
  routes = route_qa,
  census = census_qa,
  buckets = bucket_qa,
  method = list(
    birth_cutoff = 1988L,
    degrees = c("MESTRADO", "MESTRADO PROFISSIONAL",
                "DOUTORADO", "DOUTORADO PROFISSIONAL"),
    code_priority = c("native_unique", "later_capes_exact_name",
                      "emec_exact_name"),
    bucket = "M:<CO_MANTENEDORA>; fallback I:<CO_IES>; otherwise NULL",
    ambiguous_codes_publish = FALSE
  ),
  inputs = data.frame(
    path = c(panel_path, extract_path, emec_path, census_path),
    md5 = unname(tools::md5sum(c(panel_path, extract_path,
                                 emec_path, census_path)))
  ),
  output = data.frame(path = out_path,
                      md5 = unname(tools::md5sum(part_path)))
)
write_json(report, report_part, pretty = TRUE, auto_unbox = TRUE,
           dataframe = "rows", na = "null")

if (file.exists(out_path)) unlink(out_path)
if (!file.rename(part_path, out_path)) stop("Could not promote: ", out_path)
if (file.exists(report_path)) unlink(report_path)
if (!file.rename(report_part, report_path)) stop("Could not promote: ", report_path)

cat("Route counts:\n")
print(route_qa, row.names = FALSE)
cat("\nBucket coverage:\n")
print(bucket_qa, row.names = FALSE)
cat("\nOutputs:\n", out_path, "\n", report_path, "\n", sep = "")
