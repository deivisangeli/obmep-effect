####################################################################
###
### Posicoes dos candidatos selecionados, com papel e local,   -> Dropbox
### VERSAO ALTERNATIVA
###
### Copia de obmep_candidates_selected_positions.R apontada para a
### selecao alternativa. O script original e a saida dele NAO sao
### tocados; as duas versoes convivem.
###
### obmep_candidates_selected_alt.parquet (21alt) tem UMA LINHA POR
### USUARIO: as flags de selecao, os ranks e os nomes de instituicao.
### Ele nao diz nada sobre o que essas pessoas fazem no trabalho.
###
### Este script desce ao grao de POSICAO. Para cada um dos 1.315.248
### usuarios selecionados, toda posicao que ele tem, com a
### classificacao de papel e o local que a Revelio atribui a ela:
###
###   obmep_candidates_selected_alt        1,315,248 usuarios
###       + obmep_candidates_step_1_position_role_loc   (10c)
###       -> obmep_candidates_selected_positions_alt.parquet
###          (position_id, user_id, job_category,
###           role_k50 .. role_k1500, seniority, position_number,
###           onet_code, onet_title, location_raw, country, region,
###           state, metro_area)
###
### E UM SEMI JOIN, NAO HA FILTRO. O 10c ja cobre a coorte inteira; a
### unica coisa que este script faz e cortar para os selecionados.
### Nenhum criterio novo.
###
### Saida:
###   obmep_candidates_selected_positions_alt.parquet  uma linha por
###                                                 POSICAO, 18 colunas
###
### Depends on:
###   prep/building_external_data/obmep_candidates_selected_alt.R
###   prep/building_external_data/obmep_candidates_step_1_position_role_loc.R
###
### NO NETWORK. Reads local parquet, writes local parquet. It is still
### a prep/ script and still must not be sent to SEDAP, because
### everything it depends on came from Athena. See AGENTS.md ->
### Execution Environments.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. O DIRETORIO DO 10c NAO TEM EXTENSAO .parquet. O UNLOAD do
###    Athena nomeia os objetos <query-id>_<uuid>, sem sufixo, entao
###    read_parquet('<dir>/*.parquet') casa com NADA e o script morre
###    dizendo que a pasta esta vazia. O glob e NU: '<dir>/*'. Mesma
###    armadilha da nota 7 do 10c e da nota 5 do 10a.
### 2. TODO USUARIO SELECIONADO TEM DE APARECER, os 1.315.248. Nao e
###    sorte: os selecionados sao subconjunto da coorte step_1, e o
###    criterio D nao admite ninguem sem posicao cuja data parseie.
###    Uma contagem menor significa que o join pegou a coluna errada,
###    nao que o dado e ralo. Por isso ABORTA, e nao avisa. E a mesma
###    logica que faz da contagem de usuarios distintos do 10a "a
###    verificacao mais forte da rodada" (README:1344).
### 3. O GRAO E POSICAO, NAO USUARIO. position_id e unico nesta saida
###    e user_id NAO e. Qualquer contagem de pessoas aqui precisa de
###    DISTINCT user_id; somar linhas conta empregos, nao gente.
### 4. NULO EM PAPEL E LOCAL E ESPERADO. A Revelio classifica um
###    titulo e resolve um lugar so quando consegue. Nada aqui assere
###    taxa de preenchimento nenhuma -- veja a nota 6 do 10c. As taxas
###    sao RELATADAS no fim, e a primeira rodada e que as estabelece.
### 5. ESTE ARQUIVO NAO TRAZ EMPRESA NEM DATAS. company_cleaned,
###    title_raw, title_translated, naics_code, startdate e enddate
###    estao no extrato do 10a; rcid e ultimate_parent_rcid estao no
###    do 10b. Os tres cobrem exatamente o mesmo conjunto de
###    position_id -- o 10c aborta se nao cobrirem -- entao juntar por
###    position_id e seguro e barato. Nao duplicamos as colunas aqui
###    justamente para que exista um so lugar onde cada uma mora.
### 6. startdate DO 10a E STRING, NAO DATE. Se alguem juntar este
###    arquivo com o do 10a para ordenar carreira, a conversao e por
###    conta de quem junta. README trap 1.
### 7. country, region, state E metro_area MARCAM AUSENCIA COM A
###    STRING 'empty', NAO COM NULL. Nesta saida: 114,291 linhas em
###    country e region, 485,605 em state, 148,249 em metro_area.
###    Nenhum NULL, nenhuma string vazia. Logo `count(country)` diz
###    100% e `WHERE country IS NULL` nao devolve nada -- os dois
###    enganam. Filtre por `<> 'empty'`. location_raw e onet_code NAO
###    fazem isso: usam NULL de verdade. Veja a nota 9 do 10c.
###
### -----------------------------------------------------------------
### MEASURED, run of 2026-08-31
### -----------------------------------------------------------------
###   linhas (posicoes)           7,285,037
###   usuarios distintos          1,297,109  == toda a selecao (nota 2)
###   posicoes por usuario        5.62   (a coorte inteira faz 4.44:
###                               os selecionados tem carreira mais
###                               longa, nao e ruido)
###   em disco                    167.9 MB, parquet ZSTD
###
###   job_category                100%, 7 distintos. Os sete:
###                               Admin 24.7%, Engineer 22.0%,
###                               Sales 15.3%, Marketing 14.0%,
###                               Scientist 12.1%, Finance 6.9%,
###                               Operations 5.1%
###   role_k50 .. role_k1500      100%, cada uma com exatamente a
###                               contagem nominal
###   seniority                   100%, faixa 1..7
###   position_number             100%, faixa 1..128
###   onet_code / onet_title      99.5%, 383 distintos
###   location_raw                99.9%, 309,261 distintos
###   country                     98.4% fora o 'empty' (nota 7);
###                               Brazil 60.1%, United States 11.6%
###   state                       93.3% fora o 'empty';
###                               Sao Paulo 23.3%, Rio de Janeiro 7.1%
###
###   O contraste com a coorte inteira e o resultado: 60.1% das
###   posicoes dos SELECIONADOS sao no Brasil contra 75.8% da coorte.
###   Quem foi selecionado trabalha fora com mais frequencia.
###
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(duckdb)

####################################################################
### Parametros
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")

coh_dir  <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
sel_path <- file.path(coh_dir, "obmep_candidates_selected_alt.parquet")
rl_dir   <- file.path(coh_dir, "obmep_candidates_step_1_position_role_loc")

out_path <- file.path(coh_dir, "obmep_candidates_selected_positions_alt.parquet")

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")

# Deterministico: aborta em vez de avisar (nota 2).
exp_selected <- 1315248L

# Medido na rodada do 10c. Divergencia significa que o extrato foi
# reconstruido -- warning, nao stop.
exp_rl_rows <- 30389044

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_sel_positions_alt")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

if (!file.exists(sel_path)) {
  stop("Nao encontrei ", sel_path, ". Rode obmep_candidates_selected.R antes.")
}
if (!dir.exists(rl_dir)) {
  stop("Nao encontrei ", rl_dir,
       ". Rode obmep_candidates_step_1_position_role_loc.R antes.")
}
# A pasta existe mas pode ter vindo vazia de um sync interrompido.
# list.files() SEM filtro de extensao, pela nota 1.
rl_files <- list.files(rl_dir, full.names = TRUE)
if (length(rl_files) == 0) {
  stop("O diretorio ", rl_dir, " esta vazio. O `aws s3 sync` do 10c ",
       "nao terminou.")
}

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# O derrame nao pode cair em pasta sincronizada pelo Dropbox.
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))
dbExecute(con, "SET preserve_insertion_order=false")

fw <- function(p) gsub("\\\\", "/", p)

# Glob NU, sem '.parquet' -- nota 1.
rl_glob <- paste0(fw(rl_dir), "/*")

cat("DuckDB       :", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("selecionados :", basename(sel_path), "\n")
cat("papel+local  :", rl_dir, "(", length(rl_files), "partes )\n")
cat("saida        :", out_path, "\n\n")

####################################################################
### A -- o corte
####################################################################

cat("=========== ENTRADAS ===========\n")

n_sel <- dbGetQuery(con, sprintf(
  "SELECT count(*) n, count(DISTINCT user_id) d FROM read_parquet('%s')",
  fw(sel_path)))
cat("usuarios selecionados :", format(n_sel$n, big.mark = ","), "\n")
if (n_sel$n != n_sel$d) stop("user_id duplicado em ", basename(sel_path), ".")
if (n_sel$n != exp_selected) {
  stop("A selecao tem ", format(n_sel$n, big.mark = ","), " usuarios, nao ",
       format(exp_selected, big.mark = ","),
       ". O script 21 foi reconstruido: confira antes de seguir.")
}

n_rl <- dbGetQuery(con, sprintf(
  "SELECT count(*) n, count(DISTINCT position_id) d FROM read_parquet('%s')",
  rl_glob))
cat("posicoes no 10c       :", format(n_rl$n, big.mark = ","), "\n")
if (n_rl$n != n_rl$d) {
  stop("position_id nao e unico em ", basename(rl_dir), ": ",
       format(n_rl$d, big.mark = ","), " distintos em ",
       format(n_rl$n, big.mark = ","), " linhas.")
}
if (n_rl$n != exp_rl_rows) {
  warning("O 10c tem ", format(n_rl$n, big.mark = ","), " linhas, esperado ",
          format(exp_rl_rows, big.mark = ","), " -- exp_rl_rows esta velho.")
}

# SEMI JOIN por EXISTS: nao pode multiplicar linha nem que a tabela de
# selecionados deixasse de ser unica em user_id. Um INNER JOIN poderia.
cat("\n--- corte para os selecionados ---\n")
n_cut <- dbExecute(con, sprintf("
CREATE TEMP TABLE saida AS
SELECT p.position_id,
       p.user_id,
       p.job_category,
       p.role_k50, p.role_k150, p.role_k300,
       p.role_k500, p.role_k1000, p.role_k1500,
       p.seniority, p.position_number,
       p.onet_code, p.onet_title,
       p.location_raw, p.country, p.region, p.state, p.metro_area
FROM read_parquet('%s') p
WHERE EXISTS (SELECT 1 FROM read_parquet('%s') s
              WHERE s.user_id = p.user_id)", rl_glob, fw(sel_path)))
cat("posicoes selecionadas :", format(n_cut, big.mark = ","), "\n")

####################################################################
### B -- validacao
####################################################################

cat("\n=========== VALIDACAO ===========\n")
v <- dbGetQuery(con, "
  SELECT count(*) AS n_rows,
         count(DISTINCT user_id) AS n_uid,
         count(DISTINCT position_id) AS n_pid,
         sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS uid_null,
         sum(CASE WHEN position_id IS NULL THEN 1 ELSE 0 END) AS pid_null
  FROM saida")
print(as.data.frame(v), row.names = FALSE)

if (v$n_rows == 0)   stop("A saida esta vazia.")
if (v$uid_null != 0) stop("user_id nulo na saida.")
if (v$pid_null != 0) stop("position_id nulo na saida.")

# Nota 3: o grao e posicao.
if (v$n_pid != v$n_rows) {
  stop("position_id duplicado na saida: ", format(v$n_pid, big.mark = ","),
       " distintos em ", format(v$n_rows, big.mark = ","), " linhas.")
}

# Nota 2, a assercao que sustenta o script.
if (v$n_uid != exp_selected) {
  stop(format(v$n_uid, big.mark = ","), " usuarios distintos na saida, ",
       "esperado ", format(exp_selected, big.mark = ","),
       ". Todo selecionado e membro da coorte step_1 e o criterio D nao ",
       "admite ninguem sem posicao, entao faltar usuario significa que o ",
       "join pegou a coluna errada.")
}

# Nada de fora da selecao. Se o EXISTS tivesse ligado na coluna errada
# e isto que pegaria.
orf <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_orphan
  FROM saida o
  WHERE NOT EXISTS (SELECT 1 FROM read_parquet('%s') s
                    WHERE s.user_id = o.user_id)", fw(sel_path)))
if (orf$n_orphan != 0) {
  stop(format(orf$n_orphan, big.mark = ","),
       " linhas com user_id fora de ", basename(sel_path), ".")
}
cat("[OK] nenhuma linha fora da selecao\n")

####################################################################
### C -- escrita e releitura
####################################################################

invisible(dbExecute(con, sprintf(
  "COPY (SELECT * FROM saida ORDER BY user_id, position_id) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_path))))

df <- arrow::open_dataset(out_path, format = "parquet")
stopifnot(identical(names(df), c(
  "position_id", "user_id", "job_category",
  "role_k50", "role_k150", "role_k300",
  "role_k500", "role_k1000", "role_k1500",
  "seniority", "position_number", "onet_code", "onet_title",
  "location_raw", "country", "region", "state", "metro_area")))
stopifnot(nrow(df) == v$n_rows, length(names(df)) == 18L)

####################################################################
### D -- relatorio
####################################################################

# Nota 4: relatado, nunca asserido. A primeira rodada estabelece isto.
cat("\n=========== PREENCHIMENTO (primeira medicao) ===========\n")
fill_cols <- c("job_category", "role_k50", "role_k150", "role_k300",
               "role_k500", "role_k1000", "role_k1500", "seniority",
               "position_number", "onet_code", "onet_title",
               "location_raw", "country", "region", "state", "metro_area")

# Nota 7: 'empty' e o marcador de ausencia das quatro colunas
# derivadas de local. count() sozinho daria 100%.
sentinel_cols <- c("country", "region", "state", "metro_area")
miss <- ifelse(fill_cols %in% sentinel_cols,
               sprintf("(%1$s IS NULL OR %1$s = 'empty')", fill_cols),
               sprintf("%s IS NULL", fill_cols))
fq <- paste(sprintf(
  "sum(CASE WHEN NOT %2$s THEN 1 ELSE 0 END) AS f_%1$s,
   count(DISTINCT CASE WHEN NOT %2$s THEN %1$s END) AS d_%1$s",
  fill_cols, miss), collapse = ", ")
fv <- dbGetQuery(con, sprintf("SELECT %s FROM saida", fq))
for (cc in fill_cols) {
  cat(sprintf("  %-16s %12s (%5.1f%%)  distintos %10s%s\n", cc,
              format(as.numeric(fv[[paste0("f_", cc)]]), big.mark = ","),
              100 * as.numeric(fv[[paste0("f_", cc)]]) / v$n_rows,
              format(as.numeric(fv[[paste0("d_", cc)]]), big.mark = ","),
              if (cc %in% sentinel_cols) "  -- sem 'empty', nota 7" else ""))
}

cat("\n=========== OS VALORES MAIS COMUNS ===========\n")
for (cc in c("job_category", "role_k50", "country", "state")) {
  tp <- dbGetQuery(con, sprintf("
    SELECT %1$s AS v, count(*) AS n FROM saida
    WHERE %1$s IS NOT NULL AND %1$s <> 'empty'
    GROUP BY 1 ORDER BY 2 DESC LIMIT 10", cc))
  cat("\n  ", cc, "\n", sep = "")
  for (i in seq_len(nrow(tp))) {
    cat(sprintf("    %-42s %12s (%4.1f%%)\n", substr(tp$v[i], 1, 42),
                format(tp$n[i], big.mark = ","), 100 * tp$n[i] / v$n_rows))
  }
}

# seniority e smallint e a faixa nunca foi documentada. Se ela nao for
# um inteiro pequeno, a coluna significa outra coisa que nao o que se
# supoe -- veja a nota 4.
sr <- dbGetQuery(con, "
  SELECT min(seniority) AS lo, max(seniority) AS hi,
         count(DISTINCT seniority) AS d,
         min(position_number) AS pn_lo, max(position_number) AS pn_hi
  FROM saida")
cat(sprintf("\n  seniority       : %s .. %s (%s valores distintos)\n",
            sr$lo, sr$hi, sr$d))
cat(sprintf("  position_number : %s .. %s\n", sr$pn_lo, sr$pn_hi))

bytes <- file.info(out_path)$size
cat("\n=========== RESUMO ===========\n")
cat(sprintf("  %14s posicoes  %14s usuarios\n",
            format(v$n_rows, big.mark = ","), format(v$n_uid, big.mark = ",")))
cat(sprintf("  posicoes por usuario : %.2f\n", v$n_rows / v$n_uid))
cat(sprintf("  em disco             : %.1f MB\n", bytes / 2^20))
cat("  ", out_path, "\n", sep = "")
cat("  junte a 10a/10b por position_id para empresa, titulo e datas\n")
