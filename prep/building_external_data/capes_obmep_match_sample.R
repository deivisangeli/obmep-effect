####################################################################
### 27a. Amostra de 100 pares do produto CONSERVADOR do script 27
### Caderno .xlsx para inspecao manual
###
### Pipeline local e OFFLINE. Le a tabela de candidatos do script 27,
### o CSV do 24, os dois crosswalks de instituicao do 25 e 26, a
### educacao do 10a, o mapa seguro do 8f e os nomes de instituicao do
### 3. Nao usa rede e NAO deve ser enviado nem executado no SEDAP.
###
### POR QUE ESTE SCRIPT EXISTE
### O produto conservador do 27 -- jw_combo >= 0,90 E jw_lastname >=
### 0,90 -- tem 87.110 pares e NUNCA foi validado contra verdade de
### campo. O que existe hoje sao ~50 pares julgados a olho, o
### suficiente para ordenar as regras de pontuacao entre si e NAO o
### suficiente para atestar a vencedora. Isto estaciona 100 pares
### sorteados e os enriquece com a INSTITUICAO e o CURSO dos DOIS
### lados, que e a evidencia independente que um revisor pode usar.
###
### O QUE JA E VERDADE POR CONSTRUCAO -- E PORTANTO NAO SE REVISA
### A chave do 27 exigiu igualdade EXATA em primeiro nome, ano de
### inicio do mestrado, ano de inicio do doutorado e os dois
### openalex_id. Entao nas duas pontas esses campos batem
### necessariamente. Conferi-los e perder tempo. O que resta em
### julgamento e o NOME (o resto dele) e a plausibilidade do par
### diante do curso e da instituicao.
###
### DADO PESSOAL: as duas saidas carregam nome civil de duas fontes ao
### mesmo tempo. Trate como o script 21.
###
### CAUTION / LIMITATIONS
###   1. A AMOSTRA E ESTACIONADA. Se o parquet ja existe, nao se
###      sorteia de novo -- a anotacao do revisor esta amarrada a
###      ESTE sorteio e nao pode deslizar por baixo dela. Para
###      forcar um novo sorteio, APAGUE o parquet e espere
###      reclassificar tudo.
###   2. user_id e BIGINT e o DuckDB o entrega ao R como DOUBLE. Todo
###      ponto de leitura faz CAST(... AS VARCHAR). O README registra
###      esse descuido corrompendo 499 de 500 ids uma vez; a
###      invariante conferida no fim e "inteiro exato", nao "igual a
###      origem".
###   3. USING SAMPLE nao e usado. No DuckDB ele e empurrado para
###      BAIXO do filtro. ORDER BY hash(...) LIMIT n e um top-N sobre
###      o conjunto JA filtrado.
###   4. As linhas de diploma sao reconstruidas com o MESMO desempate
###      do script 27 (row_number). Se as contagens dos dois lados
###      divergirem, o caderno estaria mostrando OUTRO diploma que nao
###      o que gerou a chave -- por isso isso aborta, nao avisa.
###   5. NADA le este xlsx de volta automaticamente. As colunas
###      veredito/motivo sao para o revisor; se o caderno for
###      regravado, elas sao preservadas por pair_id e o script aborta
###      se alguma linha nao casar.
###
### Depends on:
###   prep/building_external_data/capes_obmep_candidates_name_match.R (27)
###   prep/building_external_data/br_degree_patterns.R                (7)
###
### Outputs (Data/intermediate/capes_discentes/capes_obmep_match/):
###   capes_obmep_match_sample.parquet   100 linhas, estacionada
###   capes_obmep_match_sample.xlsx      o caderno de revisao
####################################################################

for (p in c("DBI", "duckdb", "openxlsx")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}
library(DBI)
library(duckdb)
library(openxlsx)

####################################################################
### Parametros e caminhos
####################################################################

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)

capes_dir <- file.path(obmep_root, "Data/intermediate/capes_discentes")
rev_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
oa_dir <- file.path(obmep_root, "Data/intermediate/openalex_institutions")
# A mesma chave do script 27: env OBMEP_MATCH_KEY_OA decide de qual
# produto a amostra sai. Ligado = canonico; desligado = a variante sem
# openalex_id na chave, onde as duas instituicoes PODEM divergir.
key_oa_ids <- Sys.getenv("OBMEP_MATCH_KEY_OA", unset = "1") != "0"
variant_tag <- if (key_oa_ids) "" else "_noinst"

out_dir <- file.path(capes_dir, paste0("capes_obmep_match", variant_tag))

cand_path <- file.path(out_dir, "capes_obmep_match_candidates.parquet")
capes_path <- file.path(
  capes_dir, "capes_masters_doctorates_born_1988plus_2004_2024.csv"
)
xw_path <- file.path(capes_dir, "capes_openalex_br_crosswalk.parquet")
manual_path <- file.path(
  capes_dir,
  "capes_openalex_manual/capes_openalex_manual_br_crosswalk.parquet"
)
edu_dir <- file.path(rev_dir, "obmep_candidates_step_1_education")
map_path <- file.path(rev_dir, "rsid_openalex_safe_map.parquet")
oa_path <- file.path(oa_dir, "openalex_institutions_br.parquet")

sample_path <- file.path(out_dir, "capes_obmep_match_sample.parquet")
xlsx_path <- file.path(out_dir, "capes_obmep_match_sample.xlsx")

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
patterns_path <- if (length(script_arg) == 1L) {
  file.path(dirname(sub("^--file=", "", script_arg)), "br_degree_patterns.R")
} else {
  "prep/building_external_data/br_degree_patterns.R"
}

# Tem de bater com o script 27. Se o corte de la mudar, este muda junto
# ou a amostra deixa de ser do produto conservador.
jw_cut <- 0.90
year_min <- 1950L
year_max <- 2030L

seed <- 20260906L
n_draw <- 100L

verdict_domain <- c("mesma_pessoa", "pessoa_diferente", "ambiguo")

# Medidos em 2026-09-06 sobre este sorteio. Divergencia de contagem
# avisa; divergencia estrutural aborta.
if (key_oa_ids) {
  exp_pop <- 87110L
  exp_msc_only <- 66L
  exp_both <- 33L
  exp_phd_only <- 1L
  exp_msc_rows <- 99L
  exp_phd_rows <- 34L
} else {
  # Medidos em 2026-09-06 sobre este sorteio da variante.
  exp_pop <- 282769L
  exp_msc_only <- 85L
  exp_both <- 15L
  exp_phd_only <- 0L
  exp_msc_rows <- 100L
  exp_phd_rows <- 15L
}

mem_limit <- "10GB"
tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_capes_obmep_sample")

stopifnot(
  file.exists(cand_path), file.exists(capes_path), file.exists(xw_path),
  file.exists(manual_path), file.exists(map_path), file.exists(oa_path),
  file.exists(patterns_path), dir.exists(edu_dir), dir.exists(out_dir)
)
lock_file <- file.path(dirname(xlsx_path),
                       paste0("~$", basename(xlsx_path)))
if (file.exists(xlsx_path) && file.exists(lock_file)) {
  stop("O caderno esta ABERTO no Excel (existe ", basename(lock_file),
       "). Feche-o antes de rodar: gravar por cima falharia so no fim, ",
       "depois de todo o trabalho, e o veredito ja digitado nao teria ",
       "sido salvo pelo Excel ainda.")
}

dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

source(patterns_path, local = TRUE)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

invisible(dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit)))
invisible(dbExecute(
  con, sprintf("SET temp_directory=%s",
               as.character(dbQuoteString(con, tmp_dir)))
))
invisible(dbExecute(con, "SET preserve_insertion_order=false"))
invisible(dbExecute(
  con, "CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)"
))

qp <- function(path) {
  as.character(dbQuoteString(con, gsub("\\\\", "/", path)))
}
fw <- function(path) gsub("\\\\", "/", path)

cand_sql <- qp(cand_path)
capes_sql <- qp(capes_path)
xw_sql <- qp(xw_path)
manual_sql <- qp(manual_path)
edu_sql <- qp(file.path(edu_dir, "*"))
map_sql <- qp(map_path)
oa_sql <- qp(oa_path)

cat("Amostra de", n_draw, "pares do produto conservador do script 27\n")
cat("candidatos:", cand_path, "\n")
cat("corte     : jw_combo >=", jw_cut, "E jw_lastname >=", jw_cut, "\n")
cat("seed      :", seed, "\n")
cat("saida     :", out_dir, "\n")
cat("DuckDB    :", dbGetQuery(con, "SELECT version() AS v")$v, "\n\n")

####################################################################
### Passo 1: sortear e ESTACIONAR
###
### ORDER BY hash(...) LIMIT n, nunca USING SAMPLE -- nota 3. Os
### criterios de desempate depois de hk existem para que o LIMIT nunca
### quebre um empate de hash de forma arbitraria; que nao ha empate e
### afirmado logo abaixo.
####################################################################

sample_sql <- sprintf(
  "SELECT person_key,
          CAST(user_id AS VARCHAR)              AS user_id,
          capes_full_name, revelio_fullname, best_variant,
          revelio_surnames, birth_year, key_string,
          jw_combo, jw_lastname, jw_name,
          capes_msc_start_year, capes_msc_oa_id,
          capes_phd_start_year, capes_phd_oa_id,
          hash(person_key || '#' || CAST(user_id AS VARCHAR)
               || '#%d')                        AS hk
   FROM read_parquet(%s)
   WHERE jw_combo >= %.17g AND jw_lastname >= %.17g
   ORDER BY hk, person_key, user_id
   LIMIT %d",
  seed, cand_sql, jw_cut, jw_cut, n_draw
)

if (file.exists(sample_path)) {
  cat("[skip] amostra ja estacionada:", basename(sample_path), "\n")
} else {
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    sample_sql, fw(sample_path)
  )))
  cat("sorteados", n_draw, "pares com seed", seed, "\n")
}

smp <- dbGetQuery(con, sprintf(
  "SELECT * EXCLUDE (user_id), CAST(user_id AS VARCHAR) AS user_id
   FROM read_parquet(%s) ORDER BY hk, person_key, user_id",
  qp(sample_path)
))
smp$user_id <- as.character(smp$user_id)

# Um seed que nao reproduz e pior do que nenhum.
s2 <- dbGetQuery(con, sample_sql)
s2$user_id <- as.character(s2$user_id)
if (!setequal(paste(smp$person_key, smp$user_id),
              paste(s2$person_key, s2$user_id))) {
  stop("O mesmo seed devolveu amostra DIFERENTE da estacionada. ",
       "A tabela de candidatos mudou por baixo do sorteio.")
}
if (anyDuplicated(smp$hk) != 0L) {
  stop("Chave de hash repetida: o LIMIT esta desempatando de forma ",
       "arbitraria e o sorteio nao e reproduzivel.")
}

pop_qa <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM read_parquet(%s)
   WHERE jw_combo >= %.17g AND jw_lastname >= %.17g",
  cand_sql, jw_cut, jw_cut
))$n
if (pop_qa != exp_pop) {
  warning("Produto conservador ", pop_qa, " != ", exp_pop, " medido.")
}

stopifnot(
  nrow(smp) == n_draw,
  length(unique(smp$person_key)) == n_draw,
  length(unique(smp$user_id)) == n_draw,
  all(grepl("^[0-9]+$", smp$user_id)),
  all(smp$jw_combo >= jw_cut), all(smp$jw_lastname >= jw_cut)
)

lvl_mix <- c(
  msc_only = sum(!is.na(smp$capes_msc_start_year) &
                   is.na(smp$capes_phd_start_year)),
  both = sum(!is.na(smp$capes_msc_start_year) &
               !is.na(smp$capes_phd_start_year)),
  phd_only = sum(is.na(smp$capes_msc_start_year) &
                   !is.na(smp$capes_phd_start_year))
)
exp_mix <- c(exp_msc_only, exp_both, exp_phd_only)
if (!anyNA(exp_mix) && !identical(as.integer(lvl_mix), exp_mix)) {
  warning("Mistura de niveis ", paste(lvl_mix, collapse = "/"), " != ",
          paste(exp_mix, collapse = "/"), " medido.")
}

dbWriteTable(con, "smp", smp[c("person_key", "user_id")],
             temporary = TRUE, overwrite = TRUE)

####################################################################
### Passo 2: o diploma CAPES que gerou a chave
###
### Mesmo desempate do script 27 -- nota 4.
####################################################################

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE capes_oa AS
   SELECT capes_institution, openalex_id FROM read_parquet(%1$s)
     WHERE n_candidates = 1
   UNION ALL
   SELECT capes_institution, openalex_id FROM (
     SELECT capes_institution, openalex_id,
            count(*) OVER (PARTITION BY capes_institution) AS n_tied
     FROM read_parquet(%1$s) WHERE score_rank = 1 AND n_candidates > 1)
     WHERE n_tied = 1
   UNION ALL
   SELECT capes_institution, openalex_id FROM read_parquet(%2$s)
     WHERE match_status = 'verified' AND openalex_id IS NOT NULL",
  xw_sql, manual_sql
)))

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE capes_pick AS
   SELECT person_key, lvl, yr, institution, course_name, course_area,
          course_type, openalex_id
   FROM (
     SELECT c.person_key, c.lvl, c.yr, c.institution, c.course_name,
            c.course_area, c.course_type, o.openalex_id,
            row_number() OVER (
              PARTITION BY c.person_key, c.lvl
              ORDER BY c.yr NULLS LAST,
                       coalesce(o.openalex_id, '~'), c.course_code) AS rn
     FROM (
       SELECT coalesce(nullif(trim(person_id), ''),
                       trim(full_name) || '|' || trim(birth_year))
                AS person_key,
              trim(institution) AS institution,
              trim(course_code) AS course_code,
              trim(course_name) AS course_name,
              trim(course_area) AS course_area,
              trim(course_type) AS course_type,
              CASE WHEN trim(course_type) LIKE 'MESTRADO%%'  THEN 'master'
                   WHEN trim(course_type) LIKE 'DOUTORADO%%' THEN 'phd' END
                AS lvl,
              TRY_CAST(trim(course_start_year) AS INTEGER) AS yr
       FROM read_csv_auto(%s, header = true, all_varchar = true)) c
     LEFT JOIN capes_oa o ON c.institution = o.capes_institution
     WHERE c.person_key IN (SELECT person_key FROM smp))
   WHERE rn = 1",
  capes_sql
)))

####################################################################
### Passo 3: o diploma Revelio que gerou a chave
####################################################################

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE rev_pick AS
   SELECT user_id, arm, y0, y1, university_raw, university_name,
          university_country, degree_raw, field_raw, openalex_id
   FROM (
     SELECT CAST(e.user_id AS VARCHAR) AS user_id,
            CASE WHEN e.lvl = 'master' AND NOT e.is_mba THEN 'master'
                 WHEN e.lvl = 'phd'                     THEN 'phd' END AS arm,
            CASE WHEN e.y0 BETWEEN %4$d AND %5$d THEN e.y0 END AS y0,
            CASE WHEN e.y1 BETWEEN %4$d AND %5$d THEN e.y1 END AS y1,
            e.university_raw, e.university_name, e.university_country,
            e.degree_raw, e.field_raw, m.openalex_id,
            row_number() OVER (
              PARTITION BY e.user_id,
                CASE WHEN e.lvl = 'master' AND NOT e.is_mba THEN 'master'
                     WHEN e.lvl = 'phd'                     THEN 'phd' END
              ORDER BY CASE WHEN e.y0 BETWEEN %4$d AND %5$d THEN e.y0 END
                         NULLS LAST,
                       CASE WHEN e.y1 BETWEEN %4$d AND %5$d THEN e.y1 END
                         NULLS LAST,
                       coalesce(m.openalex_id, '~'),
                       coalesce(e.rsid, 2147483647)) AS rn
     FROM (
       SELECT user_id, rsid, university_raw, university_name,
              university_country, degree_raw, field_raw,
              CAST(year(startdate) AS INTEGER) AS y0,
              CAST(year(enddate)   AS INTEGER) AS y1,
              (%1$s) AS lvl,
              (degree = 'MBA' OR regexp_like(dr, '%2$s')) AS is_mba
       FROM (SELECT *, lower(trim(coalesce(degree_raw, ''))) AS dr
             FROM read_parquet(%3$s)
             WHERE CAST(user_id AS VARCHAR) IN (SELECT user_id FROM smp))) e
     LEFT JOIN (SELECT rsid, openalex_id FROM read_parquet(%6$s)
                WHERE safe = 1) m ON e.rsid = m.rsid
     WHERE (e.lvl = 'master' AND NOT e.is_mba) OR e.lvl = 'phd')
   WHERE rn = 1",
  sql_shanghai_level, rx_mba, edu_sql, year_min, year_max, map_sql
)))

# Nota 4: as duas pontas TEM de ter o mesmo numero de diplomas por
# nivel, porque a chave exigiu que ano e instituicao batessem. Se nao
# tiverem, o desempate deslizou e o caderno mostraria outro diploma.
side_qa <- dbGetQuery(con, "
  SELECT
    (SELECT count(*) FROM capes_pick WHERE lvl = 'master') AS c_msc,
    (SELECT count(*) FROM capes_pick WHERE lvl = 'phd')    AS c_phd,
    (SELECT count(*) FROM rev_pick   WHERE arm = 'master') AS r_msc,
    (SELECT count(*) FROM rev_pick   WHERE arm = 'phd')    AS r_phd")
if (side_qa$c_msc != side_qa$r_msc || side_qa$c_phd != side_qa$r_phd) {
  stop("Contagem de diplomas divergiu entre as pontas (",
       side_qa$c_msc, "/", side_qa$c_phd, " CAPES contra ",
       side_qa$r_msc, "/", side_qa$r_phd, " Revelio). O desempate ",
       "deslizou em relacao ao script 27 -- ver nota 4.")
}
if (!is.na(exp_msc_rows) &&
    (side_qa$c_msc != exp_msc_rows || side_qa$c_phd != exp_phd_rows)) {
  warning("Diplomas ", side_qa$c_msc, "/", side_qa$c_phd, " != ",
          exp_msc_rows, "/", exp_phd_rows, " medido.")
}

####################################################################
### Passo 4: montar o caderno, uma linha por PAR
####################################################################

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE oa AS
   SELECT openalex_id, display_name FROM read_parquet(%s)", oa_sql
)))

# Lado a lado: cada campo da CAPES encostado no seu par do Revelio, e
# um sinalizador explicito de concordancia da INSTITUICAO derivado dos
# openalex_id (nunca das strings de nome). No produto canonico ele so
# pode ler 'igual' ou 'sem_id'; na variante ele le 'DIFERENTE' num
# terco dos pares, e e para isso que este arranjo existe.
inst_flag <- function(a, b) sprintf(
  "CASE WHEN %1$s IS NULL OR %2$s IS NULL THEN 'sem_id'
        WHEN %1$s = %2$s THEN 'igual' ELSE 'DIFERENTE' END", a, b)

wide <- dbGetQuery(con, sprintf("
  SELECT
    s.person_key, CAST(s.user_id AS VARCHAR) AS user_id,

    s.capes_full_name, s.revelio_fullname,
    s.best_variant, s.revelio_surnames,
    round(s.jw_combo, 4) AS jw_combo,
    round(s.jw_lastname, 4) AS jw_lastname,
    round(s.jw_name, 4) AS jw_name,
    s.birth_year, s.key_string,

    cm.yr                 AS msc_capes_year,
    rm.y0                 AS msc_rev_start,
    rm.y1                 AS msc_rev_end,
    cm.institution        AS msc_capes_institution,
    rm.university_raw     AS msc_rev_university_raw,
    om.display_name       AS msc_capes_oa_name,
    omr.display_name      AS msc_rev_oa_name,
    %1$s                  AS msc_inst_match,
    cm.course_name        AS msc_capes_course,
    rm.degree_raw         AS msc_rev_degree_raw,
    cm.course_area        AS msc_capes_area,
    rm.field_raw          AS msc_rev_field_raw,
    rm.university_name    AS msc_rev_university_name,
    rm.university_country AS msc_rev_country,

    cp.yr                 AS phd_capes_year,
    rp.y0                 AS phd_rev_start,
    rp.y1                 AS phd_rev_end,
    cp.institution        AS phd_capes_institution,
    rp.university_raw     AS phd_rev_university_raw,
    op.display_name       AS phd_capes_oa_name,
    opr.display_name      AS phd_rev_oa_name,
    %2$s                  AS phd_inst_match,
    cp.course_name        AS phd_capes_course,
    rp.degree_raw         AS phd_rev_degree_raw,
    cp.course_area        AS phd_capes_area,
    rp.field_raw          AS phd_rev_field_raw,
    rp.university_name    AS phd_rev_university_name,
    rp.university_country AS phd_rev_country,
    s.hk
  FROM read_parquet(%3$s) s
  LEFT JOIN capes_pick cm ON cm.person_key = s.person_key AND cm.lvl = 'master'
  LEFT JOIN capes_pick cp ON cp.person_key = s.person_key AND cp.lvl = 'phd'
  LEFT JOIN rev_pick   rm ON rm.user_id = CAST(s.user_id AS VARCHAR)
                         AND rm.arm = 'master'
  LEFT JOIN rev_pick   rp ON rp.user_id = CAST(s.user_id AS VARCHAR)
                         AND rp.arm = 'phd'
  LEFT JOIN oa om  ON om.openalex_id  = cm.openalex_id
  LEFT JOIN oa op  ON op.openalex_id  = cp.openalex_id
  LEFT JOIN oa omr ON omr.openalex_id = rm.openalex_id
  LEFT JOIN oa opr ON opr.openalex_id = rp.openalex_id
  ORDER BY s.hk, s.person_key, s.user_id",
  inst_flag("cm.openalex_id", "rm.openalex_id"),
  inst_flag("cp.openalex_id", "rp.openalex_id"),
  qp(sample_path)
))
wide$user_id <- as.character(wide$user_id)
wide$hk <- NULL
wide <- cbind(pair_id = seq_len(nrow(wide)), wide)
wide$veredito <- ""
wide$motivo <- ""

# As igualdades que a chave forcou. Falharem aqui significa que a
# reconstrucao esta errada, nao que o dado e interessante.
stopifnot(
  nrow(wide) == n_draw,
  all(grepl("^[0-9]+$", wide$user_id)),
  all(is.na(wide$msc_capes_year) | wide$msc_capes_year == wide$msc_rev_start),
  all(is.na(wide$phd_capes_year) | wide$phd_capes_year == wide$phd_rev_start),
  all(is.na(wide$msc_capes_year) | !is.na(wide$msc_capes_oa_name)),
  all(is.na(wide$phd_capes_year) | !is.na(wide$phd_capes_oa_name))
)

# No produto canonico a chave FORCOU os openalex_id a baterem, entao
# um 'DIFERENTE' aqui significaria que a chave nao fez o que promete.
if (key_oa_ids &&
    any(c(wide$msc_inst_match, wide$phd_inst_match) == "DIFERENTE",
        na.rm = TRUE)) {
  stop("Instituicoes divergentes no produto canonico. A chave exigiu ",
       "igualdade de openalex_id; isto e impossivel sem um bug.")
}

####################################################################
### Passo 5: preservar a anotacao de um caderno anterior
###
### Nota 5: regravar sem isto apagaria o trabalho do revisor. Casamos
### por pair_id e abortamos se alguma linha nao casar.
####################################################################

prev <- NULL
if (file.exists(xlsx_path)) {
  old <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra")
  need <- c("pair_id", "user_id", "veredito", "motivo")
  if (!all(need %in% names(old))) {
    stop("O caderno existente nao tem as colunas ",
         paste(need, collapse = ", "), ". Nao vou regravar por cima.")
  }
  prev <- old[, need]
  prev$user_id <- as.character(prev$user_id)
  k <- match(wide$pair_id, prev$pair_id)
  if (any(is.na(k))) {
    stop(sum(is.na(k)), " linha(s) do caderno anterior nao casaram por ",
         "pair_id; a anotacao seria perdida em silencio.")
  }
  if (!identical(wide$user_id, prev$user_id[k])) {
    stop("pair_id casou mas user_id nao: o caderno anterior e de outro ",
         "sorteio. Apague-o de proposito se e isso que voce quer.")
  }
  wide$veredito <- ifelse(is.na(prev$veredito[k]), "", prev$veredito[k])
  wide$motivo <- ifelse(is.na(prev$motivo[k]), "", prev$motivo[k])
  n_kept <- sum(trimws(wide$veredito) != "")
  cat("caderno anterior lido:", n_kept, "veredito(s) preservado(s)\n")
  invisible(file.remove(xlsx_path))
}

####################################################################
### Passo 6: o caderno
####################################################################

res <- data.frame(
  composicao = c("so mestrado", "mestrado + doutorado", "so doutorado",
                 "jw_combo = 1,00", "jw_combo < 1,00",
                 "mestrado: instituicao igual",
                 "mestrado: instituicao DIFERENTE",
                 "mestrado: um lado sem id"),
  na_amostra = c(lvl_mix[["msc_only"]], lvl_mix[["both"]],
                 lvl_mix[["phd_only"]],
                 sum(wide$jw_combo >= 1), sum(wide$jw_combo < 1),
                 sum(wide$msc_inst_match == "igual", na.rm = TRUE),
                 sum(wide$msc_inst_match == "DIFERENTE", na.rm = TRUE),
                 sum(wide$msc_inst_match == "sem_id", na.rm = TRUE)),
  stringsAsFactors = FALSE
)
res$pct_amostra <- round(100 * res$na_amostra / n_draw, 1)

pop_res <- dbGetQuery(con, sprintf("
  SELECT
    count_if(capes_msc_start_year IS NOT NULL
             AND capes_phd_start_year IS NULL) AS msc_only,
    count_if(capes_msc_start_year IS NOT NULL
             AND capes_phd_start_year IS NOT NULL) AS both,
    count_if(capes_msc_start_year IS NULL
             AND capes_phd_start_year IS NOT NULL) AS phd_only,
    count_if(jw_combo >= 1) AS exact,
    count_if(jw_combo < 1) AS inexact,
    count_if(c.msc_oa_id IS NOT NULL AND r.msc_oa_id IS NOT NULL
             AND c.msc_oa_id = r.msc_oa_id) AS inst_igual,
    count_if(c.msc_oa_id IS NOT NULL AND r.msc_oa_id IS NOT NULL
             AND c.msc_oa_id <> r.msc_oa_id) AS inst_dif,
    count_if(c.msc_oa_id IS NULL OR r.msc_oa_id IS NULL) AS inst_sem
  FROM read_parquet(%s) p
  JOIN read_parquet(%s) c USING (person_key)
  JOIN read_parquet(%s) r USING (user_id)
  WHERE p.jw_combo >= %.17g AND p.jw_lastname >= %.17g",
  cand_sql, qp(file.path(out_dir, "capes_person_keys.parquet")),
  qp(file.path(out_dir, "revelio_user_keys.parquet")), jw_cut, jw_cut))
res$na_populacao <- as.numeric(pop_res[1, ])
res$pct_populacao <- round(100 * res$na_populacao / pop_qa, 1)

leia <- data.frame(c(
  "AMOSTRA DE 100 PARES CAPES x LINKEDIN, PARA JULGAR A MAO",
  paste0("Produto: ", if (key_oa_ids) "CANONICO" else "VARIANTE SEM openalex_id",
         " -- conservador (jw_combo >= ", jw_cut, " E jw_lastname >= ", jw_cut, ")"),
  paste0("Populacao: ", formatC(pop_qa, big.mark = ".", decimal.mark = ",",
         format = "d"), " pares. Seed ", seed, "."),
  "",
  if (key_oa_ids)
    "A chave exigiu igualdade EXATA em cinco campos: primeiro nome, ano de"
  else
    "!!! ATENCAO: NESTE ARQUIVO A CHAVE NAO USA A INSTITUICAO !!!",
  if (key_oa_ids)
    "  inicio do mestrado, ano de inicio do doutorado, e o openalex_id"
  else
    "O placebo mede 57,6% dos pares reproduzidos dando a cada pessoa o",
  if (key_oa_ids)
    "  da instituicao de cada um dos dois."
  else
    "sobrenome de outro brasileiro. Isto e uma MEDICAO, nao uma tabela",
  if (key_oa_ids)
    "Nas duas pontas esses campos batem POR CONSTRUCAO -- conferir que"
  else
    "de pareamento. Espere encontrar erro grosseiro.",
  if (key_oa_ids)
    "o ano bate, ou que a instituicao e a mesma, nao mede nada."
  else
    "",
  "",
  "COMO ESTA ARRUMADO",
  "Cada campo da CAPES fica ENCOSTADO no seu par do Revelio, para a",
  "comparacao ser da esquerda para a direita entre vizinhos:",
  "  msc_capes_institution | msc_rev_university_raw",
  "  msc_capes_oa_name     | msc_rev_oa_name     | msc_inst_match",
  "  msc_capes_course      | msc_rev_degree_raw",
  "As colunas da CAPES tem um fundo, as do Revelio outro, entao a",
  "alternancia sozinha ja mostra de que lado voce esta lendo.",
  "",
  "msc_inst_match / phd_inst_match",
  "Comparam os openalex_id, NUNCA as strings de nome:",
  "  igual      as duas fontes apontam a mesma instituicao",
  "  DIFERENTE  apontam instituicoes diferentes",
  "  sem_id     um dos lados nao resolveu a instituicao",
  if (key_oa_ids)
    "Neste arquivo 'DIFERENTE' e impossivel: a chave forcou a igualdade."
  else
    "Neste arquivo 'DIFERENTE' aparece em ~1/3 dos pares da populacao.",
  "",
  "O QUE ESTA EM JULGAMENTO",
  "Se as duas linhas sao a MESMA PESSOA. A evidencia util e:",
  "  1. o resto do nome -- best_variant mostra qual combinacao dos",
  "     sobrenomes marcou o ponto.",
  "  2. o CURSO nos dois lados. A chave nao olhou para curso nenhum.",
  "  3. university_raw -- o que a pessoa DIGITOU no LinkedIn. E mais",
  "     diagnostico do que university_name, que ja e normalizado.",
  "",
  "VOCABULARIO DO VEREDITO",
  "  mesma_pessoa      as duas linhas sao a mesma pessoa",
  "  pessoa_diferente  homonimos que a chave nao separou",
  "  ambiguo           a evidencia nao decide",
  "",
  "DUAS RESSALVAS",
  "1. Bloco de nivel vazio e AUSENCIA de diploma daquele nivel, nao",
  "   dado faltando.",
  "2. NADA le este arquivo de volta automaticamente. Rodar o script de",
  "   novo preserva veredito/motivo por pair_id."),
  stringsAsFactors = FALSE)
leia <- leia[trimws(leia[[1]]) != "" | TRUE, , drop = FALSE]
names(leia) <- "Como ler este caderno"

n_col <- ncol(wide)
stopifnot(n_col == 42L)

# Colunas por LADO, nao por bloco: e a alternancia que mostra de que
# fonte cada celula vem.
capes_cols <- c(4, 6, 13, 16, 18, 21, 23, 27, 30, 32, 35, 37)
rev_cols <- c(5, 7, 14, 15, 17, 19, 22, 24, 25, 26,
              28, 29, 31, 33, 36, 38, 39, 40)
flag_cols <- c(20, 34)
score_cols <- 8:12
edit_cols <- c(41, 42)
wrap_cols <- c(4, 5, 6, 12, 16, 17, 21, 22, 30, 31, 35, 36, 42)

wb <- createWorkbook()
hdr <- createStyle(textDecoration = "bold", fgFill = "#E8E8E8",
                   border = "bottom", valign = "top", wrapText = TRUE)
wrap <- createStyle(wrap = TRUE, valign = "top")
txt <- createStyle(numFmt = "TEXT", valign = "top")
mine <- createStyle(fgFill = "#EEF4FB", valign = "top")
capsty <- createStyle(fgFill = "#F3EFF7", valign = "top")
revsty <- createStyle(fgFill = "#EDF2F7", valign = "top")
flagsty <- createStyle(fgFill = "#FBF0E6", valign = "top",
                       textDecoration = "bold")
yours <- createStyle(fgFill = "#FFF7D6", border = "TopBottomLeftRight",
                     borderColour = "#C9A227", valign = "top")

addWorksheet(wb, "Como ler")
writeData(wb, "Como ler", leia)
addStyle(wb, "Como ler", hdr, rows = 1, cols = 1)
setColWidths(wb, "Como ler", cols = 1, widths = 74)

addWorksheet(wb, "Amostra")
writeData(wb, "Amostra", wide, withFilter = TRUE)
freezePane(wb, "Amostra", firstActiveRow = 2, firstActiveCol = 6)
addStyle(wb, "Amostra", hdr, rows = 1, cols = 1:n_col, gridExpand = TRUE)
rr <- 2:(nrow(wide) + 1)
# Nota 2: id como TEXTO tambem no formato da celula.
addStyle(wb, "Amostra", txt, rows = rr, cols = 2:3, gridExpand = TRUE)
addStyle(wb, "Amostra", mine, rows = rr, cols = score_cols, gridExpand = TRUE)
addStyle(wb, "Amostra", capsty, rows = rr, cols = capes_cols, gridExpand = TRUE)
addStyle(wb, "Amostra", revsty, rows = rr, cols = rev_cols, gridExpand = TRUE)
addStyle(wb, "Amostra", flagsty, rows = rr, cols = flag_cols, gridExpand = TRUE)
addStyle(wb, "Amostra", yours, rows = rr, cols = edit_cols, gridExpand = TRUE)
addStyle(wb, "Amostra", wrap, rows = rr, cols = wrap_cols, gridExpand = TRUE,
         stack = TRUE)
setColWidths(wb, "Amostra", cols = 1:n_col, widths = c(
  7, 14, 13,
  32, 26, 24, 24, 10, 11, 10, 7, 26,
  8, 8, 8, 34, 34, 30, 30, 12, 28, 28, 22, 22, 28, 11,
  8, 8, 8, 34, 34, 30, 30, 12, 28, 28, 22, 22, 28, 11,
  17, 34))

# Lista suspensa a partir de aba escondida: 'inline' estoura o limite
# do Excel com facilidade e falha em silencio.
addWorksheet(wb, "dominio")
writeData(wb, "dominio", data.frame(veredito = verdict_domain))
sheetVisibility(wb)[which(names(wb) == "dominio")] <- "hidden"
dataValidation(wb, "Amostra", col = 41, rows = rr,
               type = "list", value = "'dominio'!$A$2:$A$4")

# O olho vai para a divergencia de instituicao (coluna T e AH).
conditionalFormatting(wb, "Amostra", cols = 1:n_col, rows = rr,
                      rule = 'OR($T2="DIFERENTE",$AH2="DIFERENTE")',
                      type = "expression",
                      style = createStyle(bgFill = "#FADBD8"))

addWorksheet(wb, "Resumo")
writeData(wb, "Resumo",
          paste0("Composicao: as ", n_draw, " sorteadas contra as ",
                 formatC(pop_qa, big.mark = ".", decimal.mark = ",",
                         format = "d")), startRow = 1)
writeData(wb, "Resumo", res, startRow = 2)
addStyle(wb, "Resumo", hdr, rows = 2, cols = 1:5, gridExpand = TRUE)
setColWidths(wb, "Resumo", cols = 1:5, widths = c(28, 12, 13, 14, 15))

saveWorkbook(wb, xlsx_path, overwrite = FALSE)

####################################################################
### Passo 7: conferir a ida e volta
####################################################################

chk <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra")
chk$user_id <- as.character(chk$user_id)
if (!all(grepl("^[0-9]+$", chk$user_id))) {
  stop("O xlsx gravou user_id em notacao cientifica (nota 2). A ",
       "invariante e ser inteiro exato, nao so bater com a origem.")
}
if (!identical(sort(chk$user_id), sort(wide$user_id))) {
  stop("Os user_id nao sobreviveram a gravacao (nota 2).")
}
if (!identical(sort(chk$capes_full_name), sort(wide$capes_full_name))) {
  stop("capes_full_name nao sobreviveu a gravacao.")
}
if (nrow(chk) != n_draw || ncol(chk) != n_col) {
  stop("O caderno gravado tem ", nrow(chk), "x", ncol(chk),
       ", esperado ", n_draw, "x", n_col, ".")
}
cat("[OK] ida e volta conferida: id, nome e formato intactos\n")

####################################################################
### Relatorio
####################################################################

cat("\n=========== A AMOSTRA ===========\n")
cat("populacao conservadora:", pop_qa, "pares\n")
cat("sorteados             :", n_draw, "pares,", n_draw, "pessoas,",
    n_draw, "users\n")
cat("diplomas reconstruidos:", side_qa$c_msc, "mestrados e",
    side_qa$c_phd, "doutorados, iguais nas duas pontas\n")

cat("\n=========== COMPOSICAO ===========\n")
print(res, row.names = FALSE)

cat("\n=========== CONCORDANCIA DE INSTITUICAO (mestrado) ===========\n")
print(as.data.frame(table(msc_inst_match = wide$msc_inst_match,
                          useNA = "ifany")), row.names = FALSE)

cat("\n=========== 10 LINHAS, LADO A LADO (mestrado) ===========\n")
print(head(wide[c("pair_id", "capes_full_name", "revelio_fullname",
                  "msc_capes_oa_name", "msc_rev_oa_name", "msc_inst_match",
                  "msc_capes_course", "msc_rev_degree_raw")], 10),
      row.names = FALSE)

cat("\nSaidas:\n")
for (p in c(sample_path, xlsx_path)) {
  cat(sprintf("  %s  %.2f KB\n", p, file.size(p) / 1024))
}
cat("\nA amostra esta ESTACIONADA: rodar de novo NAO sorteia outra.\n")
cat("Preencha veredito/motivo na aba Amostra. Contem nome civil das\n")
cat("duas fontes.\n")
