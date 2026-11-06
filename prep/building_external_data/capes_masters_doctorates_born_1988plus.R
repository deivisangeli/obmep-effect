####################################################################
### CAPES: mestrados e doutorados de discentes nascidos em 1988+
### Extrato CSV do painel unificado de discentes, 2004-2024
###
### Pipeline local e offline. Le o parquet produzido por
### capes_discentes_panel.R e grava um CSV no Dropbox do OBMEP.
### Nao deve ser enviado nem executado no SEDAP.
###
### Uma linha por pessoa, programa CAPES, instituicao e tipo de curso.
### Reingressos na mesma combinacao ficam com o primeiro ano de inicio.
### Inclui mestrado, mestrado profissional, doutorado e doutorado
### profissional. ID_PESSOA so existe em 2013+; por isso person_id fica
### vazio em 2004-2012 e a pessoa e identificada por nome + nascimento.
###
### ATENCAO: a saida contem nomes completos e ano de nascimento.
### Trate-a como dado pessoal e mantenha-a no Dropbox controlado.
###
### Depends on:
###   prep/building_external_data/capes_discentes_panel.R
###
### Output:
###   Data/intermediate/capes_discentes/
###     capes_masters_doctorates_born_1988plus_2004_2024.csv
####################################################################

for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}
library(DBI)
library(duckdb)

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)

out_dir <- file.path(obmep_root, "Data/intermediate/capes_discentes")
in_path <- file.path(out_dir, "capes_discentes_2004_2024.parquet")
out_path <- file.path(
  out_dir,
  "capes_masters_doctorates_born_1988plus_2004_2024.csv"
)
part_path <- paste0(out_path, ".part")

birth_cutoff <- 1988L
exp_legacy <- 26975L
exp_identified <- 706904L
exp_total <- exp_legacy + exp_identified

stopifnot(file.exists(in_path), dir.exists(out_dir))

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

in_sql <- as.character(dbQuoteString(con, gsub("\\\\", "/", in_path)))
part_sql <- as.character(dbQuoteString(con, gsub("\\\\", "/", part_path)))

if (file.exists(part_path)) unlink(part_path)

cat("CAPES -- mestrados e doutorados, nascidos em 1988+\n")
cat("entrada:", in_path, "\n")
cat("saida  :", out_path, "\n\n")

sql <- sprintf(
  "CREATE TEMP TABLE cohort AS
   WITH base AS (
     SELECT
       CASE
         WHEN TRY_CAST(AN_BASE AS INTEGER) >= 2013
           THEN concat('id:', trim(ID_PESSOA))
         ELSE concat(
           'name_birth:', trim(NM_DISCENTE), '|',
           trim(AN_NASCIMENTO_DISCENTE)
         )
       END AS person_key,
       CASE
         WHEN TRY_CAST(AN_BASE AS INTEGER) >= 2013
           THEN concat('id:', trim(CD_ENTIDADE_CAPES))
         ELSE concat('name:', trim(NM_ENTIDADE_ENSINO))
       END AS institution_key,
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
            ELSE year(
              DATE '1899-12-30' +
              TRY_CAST(DT_MATRICULA_DISCENTE AS INTEGER)
            ) END AS course_start_year,
       TRY_CAST(AN_BASE AS INTEGER) AS base_year,
       source_file
     FROM read_parquet(%s)
     WHERE TRY_CAST(AN_NASCIMENTO_DISCENTE AS INTEGER) >= %d
       AND (
         (
           TRY_CAST(AN_BASE AS INTEGER) <= 2012
           AND NM_NIVEL_TITULACAO_DISCENTE IN (
             'MESTRADO', 'MESTRADO PROFISSIONAL', 'DOUTORADO'
           )
         ) OR (
           TRY_CAST(AN_BASE AS INTEGER) >= 2013
           AND DS_GRAU_ACADEMICO_DISCENTE IN (
             'MESTRADO', 'MESTRADO PROFISSIONAL',
             'DOUTORADO', 'DOUTORADO PROFISSIONAL'
           )
         )
       )
     ),
   grouped AS (
     SELECT
       person_key,
       institution_key,
       course_code,
       course_type,
       first(person_id ORDER BY base_year, source_file) AS person_id,
       first(full_name ORDER BY base_year, source_file) AS full_name,
       first(birth_year ORDER BY base_year, source_file) AS birth_year,
       first(course_name ORDER BY base_year, source_file) AS course_name,
       first(institution ORDER BY base_year, source_file) AS institution,
       first(course_area ORDER BY base_year, source_file) AS course_area,
       min(course_start_year) AS course_start_year
     FROM base
     GROUP BY person_key, institution_key, course_code, course_type
   )
   SELECT person_key, institution_key, person_id, full_name, birth_year,
          course_code, course_name, institution, course_area, course_type,
          course_start_year
   FROM grouped",
  in_sql, birth_cutoff
)
invisible(dbExecute(con, sql))

qa <- dbGetQuery(
  con,
  "SELECT
     count(*) AS n,
     count_if(person_id IS NULL) AS legacy,
     count_if(person_id IS NOT NULL) AS identified,
     count(DISTINCT (
       person_key, course_code, institution_key, course_type
     )) AS unique_keys,
     count(DISTINCT (
       person_id, full_name, birth_year, course_code, course_name,
       institution, course_area, course_type, course_start_year
     )) AS unique_export_rows,
     count_if(full_name IS NULL OR full_name = '') AS missing_name,
     count_if(institution IS NULL OR institution = '') AS missing_institution,
     count_if(course_area IS NULL OR course_area = '') AS missing_area,
     count_if(birth_year IS NULL) AS missing_birth,
     count_if(course_type IS NULL OR course_type = '') AS missing_type,
     count_if(course_code IS NULL OR course_code = '') AS missing_course_code,
     count_if(course_name IS NULL OR course_name = '') AS missing_course_name,
     count_if(course_start_year IS NULL) AS missing_start_year,
     count_if(birth_year < 1988) AS before_cutoff,
     count_if(course_type NOT IN (
       'MESTRADO', 'MESTRADO PROFISSIONAL',
       'DOUTORADO', 'DOUTORADO PROFISSIONAL'
     )) AS invalid_type,
     count_if(
       contains(full_name, chr(10)) OR contains(full_name, chr(13)) OR
       contains(institution, chr(10)) OR contains(institution, chr(13)) OR
       contains(course_code, chr(10)) OR contains(course_code, chr(13)) OR
       contains(course_name, chr(10)) OR contains(course_name, chr(13)) OR
       contains(course_area, chr(10)) OR contains(course_area, chr(13)) OR
       contains(course_type, chr(10)) OR contains(course_type, chr(13))
     ) AS embedded_newlines
   FROM cohort"
)

stopifnot(
  qa$n == exp_total,
  qa$legacy == exp_legacy,
  qa$identified == exp_identified,
  qa$unique_keys == exp_total,
  qa$unique_export_rows == exp_total,
  qa$missing_name == 0L,
  qa$missing_institution == 0L,
  qa$missing_area == 0L,
  qa$missing_birth == 0L,
  qa$missing_type == 0L,
  qa$missing_course_code == 0L,
  qa$missing_course_name == 0L,
  qa$missing_start_year == 0L,
  qa$before_cutoff == 0L,
  qa$invalid_type == 0L,
  qa$embedded_newlines == 0L
)

type_counts <- dbGetQuery(
  con,
  "SELECT course_type, count(*) AS n
   FROM cohort
   GROUP BY 1
   ORDER BY 1"
)
start_range <- dbGetQuery(
  con,
  "SELECT min(course_start_year) AS first_year,
          max(course_start_year) AS last_year
   FROM cohort"
)

copy_sql <- sprintf(
  "COPY (
     SELECT person_id, full_name, birth_year, course_code, course_name,
            institution, course_area, course_type, course_start_year
     FROM cohort
     ORDER BY birth_year, full_name, institution, course_name,
              course_type, course_start_year, person_id NULLS FIRST
   ) TO %s (HEADER, DELIMITER ',')",
  part_sql
)
invisible(dbExecute(con, copy_sql))

roundtrip <- dbGetQuery(
  con,
  sprintf(
    "SELECT count(*) AS n
     FROM read_csv_auto(%s, header = true, all_varchar = true)",
    part_sql
  )
)
roundtrip_names <- names(dbGetQuery(
  con,
  sprintf("SELECT * FROM read_csv_auto(%s, header = true,
                  all_varchar = true) LIMIT 0", part_sql)
))
stopifnot(
  roundtrip$n == exp_total,
  identical(
    roundtrip_names,
    c(
      "person_id", "full_name", "birth_year", "course_code",
      "course_name", "institution", "course_area", "course_type",
      "course_start_year"
    )
  )
)

if (file.exists(out_path)) unlink(out_path)
if (!file.rename(part_path, out_path)) {
  stop("Nao foi possivel promover o CSV temporario para: ", out_path)
}

cat("linhas de dados :", format(qa$n, big.mark = ","), "\n")
cat("com person_id   :", format(qa$identified, big.mark = ","), "\n")
cat("person_id vazio :", format(qa$legacy, big.mark = ","), "\n")
cat("inicio (min-max):", start_range$first_year, "-", start_range$last_year, "\n")
cat("bytes           :", format(file.size(out_path), big.mark = ","), "\n\n")
print(type_counts, row.names = FALSE)
cat("\nOK\n")
