####################################################################
### CAPES -> OpenAlex: candidatos por nome de instituicao
### Jaro-Winkler >= 0,95 sobre nomes normalizados
###
### Pipeline local e offline. Le o CSV do script 24 e o parquet
### brasileiro do OpenAlex produzido pelo script 3. Nao usa rede e
### nao deve ser enviado nem executado no SEDAP.
###
### A saida principal e uma TABELA DE CANDIDATOS, nao um mapa 1:1:
### conserva todo par CAPES x OpenAlex acima do corte. Juntar esse
### arquivo ao CSV de pessoas sem antes resolver os multiplos candidatos
### pode multiplicar linhas. Os nomes sem candidato ficam num CSV de
### auditoria com o(s) melhor(es) candidato(s) abaixo do corte.
###
### Depends on:
###   prep/building_external_data/capes_masters_doctorates_born_1988plus.R
###   prep/building_external_data/openalex_br_institutions.R
###
### Outputs:
###   Data/intermediate/capes_discentes/
###     capes_openalex_br_crosswalk.parquet
###     capes_openalex_br_crosswalk_unmatched.csv
####################################################################

for (p in c("DBI", "duckdb", "arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}
library(DBI)
library(duckdb)

####################################################################
### Parametros e caminhos
####################################################################

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)

capes_dir <- file.path(obmep_root, "Data/intermediate/capes_discentes")
oa_dir <- file.path(obmep_root, "Data/intermediate/openalex_institutions")

capes_path <- file.path(
  capes_dir,
  "capes_masters_doctorates_born_1988plus_2004_2024.csv"
)
oa_path <- file.path(oa_dir, "openalex_institutions_br.parquet")

out_path <- file.path(capes_dir, "capes_openalex_br_crosswalk.parquet")
unmatched_path <- file.path(
  capes_dir,
  "capes_openalex_br_crosswalk_unmatched.csv"
)
out_part <- paste0(out_path, ".part")
unmatched_part <- paste0(unmatched_path, ".part")

jw_cut <- 0.95

# Valores medidos no CSV 2004-2024 e no snapshot OpenAlex de fevereiro/2026.
exp_source_rows <- 733879L
exp_capes_institutions <- 915L
exp_oa_rows <- 1947L
exp_pairs <- 1399L
exp_matched_institutions <- 438L
exp_unmatched_institutions <- 477L
exp_unmatched_rows <- 480L
exp_matched_source_rows <- 609252L

expected_capes_columns <- c(
  "person_id", "full_name", "birth_year", "course_code", "course_name",
  "institution", "course_area", "course_type", "course_start_year"
)
expected_oa_columns <- c(
  "openalex_id", "openalex_url", "display_name", "cleaned_display_name",
  "ror", "type", "works_count", "city", "region", "country_source",
  "snapshot_date"
)

stopifnot(file.exists(capes_path), file.exists(oa_path), dir.exists(capes_dir))

if (file.exists(out_part)) unlink(out_part)
if (file.exists(unmatched_part)) unlink(unmatched_part)

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_capes_openalex")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

####################################################################
### Conexao e schemas
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

invisible(dbExecute(
  con,
  sprintf("SET temp_directory=%s", as.character(dbQuoteString(con, tmp_dir)))
))

capes_sql <- as.character(dbQuoteString(con, gsub("\\\\", "/", capes_path)))
oa_sql <- as.character(dbQuoteString(con, gsub("\\\\", "/", oa_path)))
out_part_sql <- as.character(
  dbQuoteString(con, gsub("\\\\", "/", out_part))
)
unmatched_part_sql <- as.character(
  dbQuoteString(con, gsub("\\\\", "/", unmatched_part))
)

cat("CAPES -> OpenAlex: candidatos por nome\n")
cat("CAPES   :", capes_path, "\n")
cat("OpenAlex:", oa_path, "\n")
cat("corte   : Jaro-Winkler >=", jw_cut, "\n")
cat("saida   :", out_path, "\n")
cat("sem match:", unmatched_path, "\n\n")

capes_columns <- names(dbGetQuery(
  con,
  sprintf(
    "SELECT * FROM read_csv_auto(%s, header = true, all_varchar = true) LIMIT 0",
    capes_sql
  )
))
oa_columns <- names(dbGetQuery(
  con,
  sprintf("SELECT * FROM read_parquet(%s) LIMIT 0", oa_sql)
))

stopifnot(
  identical(capes_columns, expected_capes_columns),
  identical(oa_columns, expected_oa_columns)
)

####################################################################
### Um nome por instituicao e limpeza conservadora
####################################################################

invisible(dbExecute(
  con,
  sprintf(
    "CREATE TEMP TABLE capes_source AS
     SELECT institution
     FROM read_csv_auto(%s, header = true, all_varchar = true)",
    capes_sql
  )
))

invisible(dbExecute(
  con,
  "CREATE TEMP TABLE capes_institutions AS
   SELECT
     institution AS capes_institution,
     trim(regexp_replace(
       regexp_replace(
         lower(strip_accents(trim(institution))),
         '[^a-z0-9]+', ' ', 'g'
       ),
       ' +', ' ', 'g'
     )) AS capes_name_clean,
     count(*) AS capes_row_count
   FROM capes_source
   GROUP BY institution"
))

invisible(dbExecute(
  con,
  sprintf(
    "CREATE TEMP TABLE oa AS
     SELECT
       openalex_id,
       display_name,
       trim(regexp_replace(
         regexp_replace(
           lower(strip_accents(trim(display_name))),
           '[^a-z0-9]+', ' ', 'g'
         ),
         ' +', ' ', 'g'
       )) AS openalex_name_clean,
       ror,
       type AS oa_type,
       works_count,
       city,
       region,
       snapshot_date
     FROM read_parquet(%s)",
    oa_sql
  )
))

capes_qa <- dbGetQuery(
  con,
  "SELECT
     (SELECT count(*) FROM capes_source) AS source_rows,
     count(*) AS institutions,
     count_if(capes_institution IS NULL OR trim(capes_institution) = '')
       AS missing_name,
     count_if(capes_name_clean IS NULL OR capes_name_clean = '')
       AS missing_clean_name,
     sum(capes_row_count) AS grouped_rows
   FROM capes_institutions"
)
oa_qa <- dbGetQuery(
  con,
  "SELECT
     count(*) AS rows,
     count(DISTINCT openalex_id) AS ids,
     count_if(openalex_id IS NULL OR openalex_id = '') AS missing_id,
     count_if(display_name IS NULL OR trim(display_name) = '') AS missing_name,
     count_if(openalex_name_clean IS NULL OR openalex_name_clean = '')
       AS missing_clean_name
   FROM oa"
)

stopifnot(
  capes_qa$source_rows == exp_source_rows,
  capes_qa$institutions == exp_capes_institutions,
  capes_qa$missing_name == 0L,
  capes_qa$missing_clean_name == 0L,
  capes_qa$grouped_rows == capes_qa$source_rows,
  oa_qa$rows == exp_oa_rows,
  oa_qa$ids == oa_qa$rows,
  oa_qa$missing_id == 0L,
  oa_qa$missing_name == 0L,
  oa_qa$missing_clean_name == 0L
)

####################################################################
### Todos os pares acima do corte
####################################################################

invisible(dbExecute(
  con,
  "CREATE TEMP TABLE scores AS
   SELECT
     c.capes_institution,
     o.openalex_id,
     jaro_winkler_similarity(
       c.capes_name_clean,
       o.openalex_name_clean
     ) AS jw_similarity
   FROM capes_institutions c
   CROSS JOIN oa o"
))

invisible(dbExecute(
  con,
  sprintf(
    "CREATE TEMP TABLE crosswalk AS
     SELECT
       c.capes_institution,
       c.capes_name_clean,
       c.capes_row_count,
       s.jw_similarity,
       dense_rank() OVER (
         PARTITION BY s.capes_institution
         ORDER BY s.jw_similarity DESC
       ) AS score_rank,
       count(*) OVER (
         PARTITION BY s.capes_institution
       ) AS n_candidates,
       o.openalex_id,
       o.display_name,
       o.openalex_name_clean,
       o.ror,
       o.oa_type,
       o.works_count,
       o.city,
       o.region,
       o.snapshot_date
     FROM scores s
     JOIN capes_institutions c USING (capes_institution)
     JOIN oa o USING (openalex_id)
     WHERE s.jw_similarity >= %.17g",
    jw_cut
  )
))

# Para cada nome sem par aceito, conserva todos os empates no melhor
# escore abaixo do corte. Esses candidatos sao diagnostico, nao match.
invisible(dbExecute(
  con,
  sprintf(
    "CREATE TEMP TABLE unmatched AS
     WITH best AS (
       SELECT capes_institution, max(jw_similarity) AS best_jw_similarity
       FROM scores
       GROUP BY capes_institution
       HAVING max(jw_similarity) < %.17g
     ),
     tied AS (
       SELECT
         s.capes_institution,
         s.openalex_id,
         s.jw_similarity AS best_jw_similarity,
         count(*) OVER (PARTITION BY s.capes_institution) AS n_best_ties
       FROM scores s
       JOIN best b
         ON s.capes_institution = b.capes_institution
        AND s.jw_similarity = b.best_jw_similarity
     )
     SELECT
       c.capes_institution,
       c.capes_name_clean,
       c.capes_row_count,
       t.best_jw_similarity,
       t.n_best_ties,
       o.openalex_id AS best_openalex_id,
       o.display_name AS best_display_name,
       o.openalex_name_clean AS best_openalex_name_clean,
       o.ror AS best_ror,
       o.oa_type AS best_oa_type,
       o.works_count AS best_works_count,
       o.city AS best_city,
       o.region AS best_region,
       o.snapshot_date AS best_snapshot_date
     FROM tied t
     JOIN capes_institutions c USING (capes_institution)
     JOIN oa o USING (openalex_id)",
    jw_cut
  )
))

####################################################################
### Validacao antes de escrever
####################################################################

crosswalk_qa <- dbGetQuery(
  con,
  sprintf(
    "SELECT
     count(*) AS pairs,
     count(DISTINCT capes_institution) AS matched_institutions,
     count(DISTINCT openalex_id) AS matched_openalex_ids,
     min(jw_similarity) AS min_score,
     max(jw_similarity) AS max_score,
     count_if(jw_similarity < %.17g OR jw_similarity > 1) AS bad_score,
     count(*) - count(DISTINCT (capes_institution, openalex_id))
       AS duplicate_pairs,
     count_if(n_candidates <> observed_candidates) AS bad_candidate_count
   FROM (
     SELECT *, count(*) OVER (PARTITION BY capes_institution)
       AS observed_candidates
     FROM crosswalk
   )",
    jw_cut
  )
)

partition_qa <- dbGetQuery(
  con,
  sprintf(
    "SELECT
     (SELECT count(DISTINCT capes_institution) FROM crosswalk) AS matched,
     (SELECT count(DISTINCT capes_institution) FROM unmatched) AS unmatched,
     (SELECT count(*) FROM unmatched) AS unmatched_rows,
     (SELECT sum(capes_row_count)
        FROM capes_institutions c
       WHERE EXISTS (
         SELECT 1 FROM crosswalk x
         WHERE x.capes_institution = c.capes_institution
       )) AS matched_source_rows,
     (SELECT sum(capes_row_count)
        FROM capes_institutions c
       WHERE EXISTS (
         SELECT 1 FROM unmatched u
         WHERE u.capes_institution = c.capes_institution
       )) AS unmatched_source_rows,
     (SELECT count(*)
        FROM unmatched u
        JOIN crosswalk x USING (capes_institution)) AS overlap_rows,
     (SELECT count_if(best_jw_similarity >= %.17g OR best_jw_similarity < 0)
        FROM unmatched) AS bad_unmatched_score",
    jw_cut
  )
)

stopifnot(
  crosswalk_qa$bad_score == 0L,
  crosswalk_qa$duplicate_pairs == 0L,
  crosswalk_qa$bad_candidate_count == 0L,
  partition_qa$matched + partition_qa$unmatched == exp_capes_institutions,
  partition_qa$matched_source_rows + partition_qa$unmatched_source_rows ==
    exp_source_rows,
  partition_qa$overlap_rows == 0L,
  partition_qa$bad_unmatched_score == 0L
)

if (
  crosswalk_qa$pairs != exp_pairs ||
  partition_qa$matched != exp_matched_institutions ||
  partition_qa$unmatched != exp_unmatched_institutions ||
  partition_qa$unmatched_rows != exp_unmatched_rows ||
  partition_qa$matched_source_rows != exp_matched_source_rows
) {
  warning(
    "Resultado divergiu do medido: pares=", crosswalk_qa$pairs,
    ", CAPES com match=", partition_qa$matched,
    ", CAPES sem match=", partition_qa$unmatched,
    ", linhas no CSV sem match=", partition_qa$unmatched_rows,
    ", linhas-fonte cobertas=", partition_qa$matched_source_rows,
    ". O snapshot ou a entrada mudou?"
  )
}

####################################################################
### Escrita atomica e releitura
####################################################################

invisible(dbExecute(
  con,
  sprintf(
    "COPY (
       SELECT * FROM crosswalk
       ORDER BY capes_institution, jw_similarity DESC,
                works_count DESC NULLS LAST, openalex_id
     ) TO %s (FORMAT PARQUET, COMPRESSION ZSTD)",
    out_part_sql
  )
))

invisible(dbExecute(
  con,
  sprintf(
    "COPY (
       SELECT * FROM unmatched
       ORDER BY capes_institution, best_jw_similarity DESC,
                best_works_count DESC NULLS LAST, best_openalex_id
     ) TO %s (FORMAT CSV, HEADER, DELIMITER ',')",
    unmatched_part_sql
  )
))

parquet_check <- arrow::read_parquet(out_part)
csv_check <- dbGetQuery(
  con,
  sprintf(
    "SELECT count(*) AS rows,
            count(DISTINCT capes_institution) AS institutions
     FROM read_csv_auto(%s, header = true, all_varchar = true)",
    unmatched_part_sql
  )
)

personal_columns <- c("person_id", "full_name", "birth_year")
stopifnot(
  nrow(parquet_check) == crosswalk_qa$pairs,
  !anyDuplicated(parquet_check[c("capes_institution", "openalex_id")]),
  !any(names(parquet_check) %in% personal_columns),
  csv_check$rows == partition_qa$unmatched_rows,
  csv_check$institutions == partition_qa$unmatched,
  !any(names(dbGetQuery(
    con,
    sprintf(
      "SELECT * FROM read_csv_auto(%s, header = true, all_varchar = true) LIMIT 0",
      unmatched_part_sql
    )
  )) %in% personal_columns)
)

if (file.exists(unmatched_path)) unlink(unmatched_path)
if (!file.rename(unmatched_part, unmatched_path)) {
  stop("Nao foi possivel promover o CSV temporario: ", unmatched_path)
}
if (file.exists(out_path)) unlink(out_path)
if (!file.rename(out_part, out_path)) {
  stop("Nao foi possivel promover o parquet temporario: ", out_path)
}

####################################################################
### Relatorio
####################################################################

cat("instituicoes CAPES :", capes_qa$institutions, "\n")
cat("instituicoes OA    :", oa_qa$rows, "(todos os tipos)\n")
cat("pares >=", jw_cut, "     :", crosswalk_qa$pairs, "\n")
cat("CAPES com match    :", partition_qa$matched, "\n")
cat("CAPES sem match    :", partition_qa$unmatched, "\n")
cat("linhas-fonte cobertas:", partition_qa$matched_source_rows, "de",
    capes_qa$source_rows, "\n\n")

cat("Candidatos por nome CAPES:\n")
print(dbGetQuery(
  con,
  "SELECT n_candidates, count(*) AS capes_institutions
   FROM (
     SELECT DISTINCT capes_institution, n_candidates FROM crosswalk
   )
   GROUP BY n_candidates
   ORDER BY n_candidates"
), row.names = FALSE)

cat("\nEmpates no melhor escore aceito:\n")
print(dbGetQuery(
  con,
  "SELECT capes_institution, jw_similarity, count(*) AS n
   FROM crosswalk
   WHERE score_rank = 1
   GROUP BY capes_institution, jw_similarity
   HAVING count(*) > 1
   ORDER BY capes_institution"
), row.names = FALSE)

cat("\nGravado:", out_path, "\n")
cat("tamanho:", round(file.size(out_path) / 1024, 1), "KB\n")
cat("Gravado:", unmatched_path, "\n")
cat("tamanho:", round(file.size(unmatched_path) / 1024, 1), "KB\n")
cat("\nOK\n")
