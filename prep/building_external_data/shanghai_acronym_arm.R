####################################################################
### Braco da SIGLA para as flags de Xangai
###
### Marca quem escreveu SO a sigla de uma instituicao do top-1000 no
### university_raw -- "UCL", "UFSCar", "UNSW" -- casos que o script 16
### nao enxerga, porque uma sigla nua nao compartilha string nenhuma
### com "University College London".
###
### Escreve obmep_candidates_step_1_shanghai_acr.parquet, com colunas
### sh_acr_*, uma linha por user_id marcado. NAO mexe no script 16 nem
### na saida dele.
###
### Pontos de atencao, todos medidos:
###
### 1. O CASAMENTO E SOBRE university_raw, string inteira. Nao ha braco
###    de segmento e nao ha casamento por university_name. Decisao do
###    usuario, e ela importa: "Curso de Extensao - USP" nao deve virar
###    Xangai por um pedaco de string de tres letras.
###
###    university_name aparece neste script uma unica vez, como PISTA
###    na planilha de revisao (nota 4). Nunca como chave de join, nunca
###    como filtro.
###
### 2. SIGLA REIVINDICADA POR MAIS DE UMA INSTITUICAO DO RANKING E
###    DESCARTADA, sem tentativa de desempate. 'UM' e reivindicada por
###    SETE (Maastricht, Malaya, Montana, Muenster, Miami, Michigan,
###    Macau), 'UW' e 'CMU' por cinco cada. Das 554 siglas dobradas
###    distintas do top-1000, sobram 486.
###
###    O script 20 resolve as colisoes dele com arg_min(best_rank)
###    porque a lista do RUF e brasileira e tem 23 escolas. Aqui isso
###    entregaria 'UM' a qualquer uma das sete que estivesse melhor
###    colocada, o que e sorteio, nao casamento.
###
### 3. NAO HA PISO DE COMPRIMENTO. Um rascunho deste script tinha um
###    corte em 4 caracteres. A revisao da nota 4 o torna pior que
###    inutil: 'UCL' (2.715 pessoas), 'USP', 'UFC', 'UEA', 'PUC' e
###    'UnB' tem tres letras, e a revisao decide cada uma delas
###    individualmente. Um corte cego jogaria fora as 2.715 pessoas de
###    'UCL' para evitar as 196 de 'PUC'.
###
### 4. A PRECISAO VEM DA REVISAO MANUAL, nao de uma regra. Sao 209
###    strings. O script grava shanghai_acronym_candidates.csv com um
###    rotulo automatico proposto e PARA; o arquivo revisado a mao,
###    shanghai_acronym_class.csv, e que libera as flags.
###
###    Dois arquivos, e nao um, porque o script pode ser rodado de novo
###    a qualquer momento: se ele escrevesse por cima do arquivo
###    revisado, uma re-execucao apagaria a revisao em silencio.
###
###    O rotulo automatico usa university_name como pista. Ele nao e
###    confiavel sozinho, e e exatamente por isso que existe revisao:
###      * 'UCL'    -> "UCL - University of London"        certo
###      * 'UNIME'  -> "UNIFAS University Centre"          ERRADO, e um
###        centro universitario da Bahia, nao Messina; 1.109 pessoas
###      * 'UNAM'   -> "National University of Misiones"   ERRADO
###      * 'UNISC'  -> "University of Santa Cruz do Sul"   ERRADO
###      * 'UnB'    -> "Nazi Boni University"              ERRADO
###      * 'UFC'    -> "University of Continuing Education"
###        AMBIGUO: o university_name esta errado, mas quem escreve
###        'UFC' no Brasil quase sempre quer a Federal do Ceara, que E
###        a instituicao do ranking.
###
### 5. O VETO POR PAIS FOI CONSIDERADO E DESCARTADO, com medicao.
###    university_country e nulo na maioria destas linhas -- 'UNIME'
###    tem pais em 3 de 1.188 linhas. Com piso de 25 linhas o veto
###    dispara 3 vezes em 209, e DUAS delas erradas: ele poe a UnB na
###    Argentina e a UNAM na Islandia, porque o campo de pais do
###    Revelio para essas strings esta corrompido. Um guarda que erra
###    dois tercos das vezes que fala e pior que nenhum.
###
### 6. AS FLAGS FICAM NA PROPRIA COLUNA, sh_acr_*, e NUNCA entram em
###    sh_any. Mesma logica de rd_abbr_any no script 20: quem nao
###    quiser o braco simplesmente nao faz o join, sem pedir rebuild.
###
### 7. A DOBRA DURA (fold_hard) SO SERVE PARA RESOLVER A PISTA, nunca
###    para casar sigla. Ela tira virgula, ponto e apostrofo e derruba
###    "the " inicial, o que resolve "University of California Los
###    Angeles" contra "University of California, Los Angeles" e
###    "University of New South Wales" contra "The University of New
###    South Wales". O casamento da sigla continua na dobra padrao da
###    pasta, lower(strip_accents(trim())), identica a dos scripts 16,
###    19 e 20.
####################################################################

for (p in c("DBI", "duckdb", "arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}
library(DBI)
library(duckdb)

####################################################################
### Parametros
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")

rank_dir  <- file.path(obmep_root, "Data/intermediate/shanghai_ranking")
sh_path   <- file.path(rank_dir, "shanghai_ranking_oa.parquet")
acr_path  <- file.path(rank_dir, "shanghai_ranking_oa_acronyms.parquet")

coh_dir   <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
ed_dir    <- file.path(coh_dir, "obmep_candidates_step_1_education")
cand_path <- file.path(coh_dir, "obmep_candidates_step_1.parquet")
sh16_path <- file.path(coh_dir, "obmep_candidates_step_1_shanghai.parquet")

cands_path <- file.path(coh_dir, "shanghai_acronym_candidates.csv")
class_path <- file.path(coh_dir, "shanghai_acronym_class.csv")
out_path   <- file.path(coh_dir, "obmep_candidates_step_1_shanghai_acr.parquet")

patterns_path <- Sys.getenv(
  "OBMEP_DEGREE_PATTERNS",
  unset = file.path("prep", "building_external_data", "br_degree_patterns.R"))

# Mesmo corte do script 16. Ver nota 1 daquele script: e o inicio da
# ultima faixa, nao 1000.
rank_cut <- 901L

mem_limit <- "8GB"

# Valores medidos. Divergencia e sinal de que o ranking, o snapshot ou
# o extrato mudou -- warning, nao stop.
exp_acr_all    <- 554L   # siglas dobradas distintas no top-1000
exp_acr_uniq   <- 486L   # sobreviventes da nota 2
exp_strings    <- 209L   # university_raw distintos casados
exp_cand_rows  <- 17927L
exp_cand_users <- 16814L

exp_cohort <- 6849674L

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_shanghai_acr")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(file.exists(sh_path), file.exists(acr_path), dir.exists(ed_dir),
          file.exists(cand_path), file.exists(patterns_path),
          length(Sys.glob(file.path(ed_dir, "*"))) > 0L)

source(patterns_path)
stopifnot(exists("sql_shanghai_level"), exists("rx_mba"), exists("rx_lato"))

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

# Shim Trino -> DuckDB, igual ao do script 16.
dbExecute(con, "CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)")

# A dobra padrao da pasta. E ela, e so ela, que casa sigla.
dbExecute(con, "
  CREATE MACRO fold_soft(s) AS lower(strip_accents(trim(s)))")

# A dobra dura. Ver nota 7: existe para resolver a PISTA, nunca para
# casar sigla. Sem barra invertida em lugar nenhum -- replace() no
# lugar de classe de caractere, de proposito.
dbExecute(con, "
  CREATE MACRO fold_hard(s) AS
    trim(regexp_replace(
      regexp_replace(
        replace(replace(replace(lower(strip_accents(trim(s))),
                ',', ''), '.', ''), '''', ''),
        '^the ', ''),
      ' +', ' ', 'g'))")

cat("DuckDB   :", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("ranking  :", sh_path, "\n")
cat("siglas   :", acr_path, "\n")
cat("educacao :", ed_dir, "\n")
cat("saida    :", out_path, "\n\n")

sh_src <- sprintf("read_parquet('%s')", sh_path)
ac_src <- sprintf("read_parquet('%s')", acr_path)
ed_src <- sprintf("read_parquet('%s/*')", ed_dir)

####################################################################
### A -- a tabela de siglas, com o descarte da nota 2
####################################################################

n_top <- dbGetQuery(con, sprintf(
  "SELECT sum(CASE WHEN Rank <= %d THEN 1 ELSE 0 END) AS n FROM %s",
  rank_cut, sh_src))$n
if (n_top != 1000L) {
  stop("Rank <= ", rank_cut, " seleciona ", n_top, " linhas, nao 1000. ",
       "As faixas do ranking mudaram; refaca a aritmetica em vez de ",
       "reinterpretar o corte.")
}

dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE acr_all AS
  SELECT fold_soft(a.alt_name) AS acr_fold,
         a.OA_key, a.shanghai_Name, a.country_code, a.Rank
  FROM %s a
  WHERE a.kind = 'acronym' AND a.Rank <= %d
    AND a.alt_name IS NOT NULL AND length(trim(a.alt_name)) >= 2",
  ac_src, rank_cut))

n_acr_all <- dbGetQuery(con,
  "SELECT count(DISTINCT acr_fold) AS n FROM acr_all")$n

# Nota 2: sobrevive so a sigla de dono unico.
dbExecute(con, "
  CREATE OR REPLACE TABLE acr AS
  SELECT acr_fold,
         any_value(OA_key)         AS OA_key,
         any_value(shanghai_Name)  AS sh_inst,
         any_value(country_code)   AS sh_country,
         CAST(min(Rank) AS INTEGER) AS sh_rank
  FROM acr_all
  GROUP BY acr_fold
  HAVING count(DISTINCT OA_key) = 1")

n_acr <- dbGetQuery(con, "SELECT count(*) AS n FROM acr")$n

# Redundante com o HAVING acima, e de proposito: e a invariante toda do
# braco. Se um dia alguem trocar o HAVING por um arg_min, isto para.
dono2 <- dbGetQuery(con, "
  SELECT count(*) AS n FROM (
    SELECT a.acr_fold FROM acr_all a
    JOIN acr k ON k.acr_fold = a.acr_fold
    GROUP BY a.acr_fold HAVING count(DISTINCT a.OA_key) > 1)")$n
if (dono2 != 0) {
  stop(dono2, " siglas aceitas com mais de uma instituicao dona. Ver nota 2.")
}

cat("siglas dobradas no top-1000 :", n_acr_all, "\n")
cat("com dono unico (nota 2)     :", n_acr, "\n")

ambig <- dbGetQuery(con, "
  SELECT acr_fold, count(DISTINCT OA_key) AS n,
         string_agg(DISTINCT shanghai_Name, ' | ') AS quem
  FROM acr_all GROUP BY 1 HAVING count(DISTINCT OA_key) > 1
  ORDER BY n DESC, acr_fold LIMIT 8")
cat("\n--- siglas descartadas por ambiguidade, as piores ---\n")
print(ambig, right = FALSE, row.names = FALSE)

####################################################################
### B -- os nomes do ranking, para resolver a pista da nota 4
####################################################################

# As tres grafias do ranking mais os display_name_alternatives, todos
# na dobra dura. So nome de dono unico entra: um nome reivindicado por
# duas instituicoes nao resolve pista nenhuma.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE nm2key AS
  SELECT nm_fold, any_value(OA_key) AS OA_key,
         any_value(sh_inst) AS sh_inst
  FROM (
    SELECT fold_hard(cleaned_display_name) AS nm_fold, OA_key,
           shanghai_Name AS sh_inst FROM %1$s WHERE Rank <= %2$d
    UNION ALL
    SELECT fold_hard(display_name),         OA_key, shanghai_Name
      FROM %1$s WHERE Rank <= %2$d
    UNION ALL
    SELECT fold_hard(shanghai_Name),        OA_key, shanghai_Name
      FROM %1$s WHERE Rank <= %2$d
    UNION ALL
    SELECT fold_hard(alt_name), OA_key, shanghai_Name
      FROM %3$s WHERE kind = 'alternative' AND Rank <= %2$d
  )
  WHERE nm_fold IS NOT NULL AND length(nm_fold) >= 3
  GROUP BY nm_fold
  HAVING count(DISTINCT OA_key) = 1", sh_src, rank_cut, ac_src))

cat("\nnomes do ranking (dobra dura):",
    dbGetQuery(con, "SELECT count(*) AS n FROM nm2key")$n, "\n")

# Quanto a dobra dura ganha sobre a dobra padrao. Ver nota 7.
mov <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM (
    SELECT DISTINCT fold_hard(shanghai_Name) AS h, fold_soft(shanghai_Name) AS s
    FROM %s WHERE Rank <= %d
  ) WHERE h <> s", sh_src, rank_cut))$n
cat("nomes que a dobra dura muda :", mov, "\n\n")

####################################################################
### C -- casamento sobre university_raw, string inteira
####################################################################

# O grao e a string DOBRADA, nao a grafia. "USP", "usp" e "Usp" sao a
# mesma decisao de revisao; separa-las triplicaria a planilha sem
# acrescentar uma pergunta sequer. spellings guarda as grafias vistas
# para que a revisao saiba o que esta aceitando.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE raws AS
  SELECT fold_soft(university_raw)                AS raw_fold,
         string_agg(DISTINCT university_raw, ' | ')
           AS spellings,
         count(DISTINCT university_raw)           AS n_spellings,
         count(*)                                 AS n_rows,
         count(DISTINCT user_id)                  AS n_users
  FROM %s
  WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''
  GROUP BY 1", ed_src))

# A pista: o university_name modal das MESMAS linhas. Modal, e nao
# any_value, porque any_value devolve o que estiver a mao e ja induziu
# erro antes nesta cadeia.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE hint AS
  SELECT raw_fold, university_name, n_name
  FROM (
    SELECT fold_soft(university_raw) AS raw_fold,
           university_name,
           count(*) AS n_name,
           row_number() OVER (PARTITION BY fold_soft(university_raw)
                              ORDER BY count(*) DESC, university_name) AS rk
    FROM %s
    WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''
      AND university_name IS NOT NULL AND trim(university_name) <> ''
    GROUP BY 1, 2
  ) WHERE rk = 1", ed_src))

dbExecute(con, "
  CREATE OR REPLACE TABLE cand AS
  SELECT a.acr_fold,
         r.spellings,
         r.n_spellings,
         a.sh_inst      AS claims_institution,
         a.sh_country   AS claims_country,
         a.sh_rank      AS claims_rank,
         r.n_rows,
         r.n_users,
         h.university_name AS revelio_university_name,
         h.n_name          AS revelio_name_rows,
         CASE WHEN h.university_name IS NULL THEN 'no_name'
              WHEN k.OA_key = a.OA_key       THEN 'confirms'
              WHEN k.OA_key IS NOT NULL      THEN 'contradicts'
              ELSE 'unresolved' END AS hint_bucket,
         k.sh_inst AS hint_resolves_to
  FROM raws r
  JOIN acr  a ON a.acr_fold = r.raw_fold
  LEFT JOIN hint   h ON h.raw_fold = r.raw_fold
  LEFT JOIN nm2key k ON k.nm_fold  = fold_hard(h.university_name)")

# n_users por sigla e somado para exibicao, mas o total de PESSOAS tem
# de ser contagem distinta: quem escreveu 'UFRJ' numa linha e 'UFRJ '
# noutra e uma pessoa, e quem escreveu duas siglas diferentes tambem.
cs <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_str, sum(n_rows) AS n_rows, sum(n_users) AS n_sum,
         (SELECT count(DISTINCT e.user_id)
            FROM %s e JOIN cand c ON fold_soft(e.university_raw) = c.acr_fold)
           AS n_users
  FROM cand", ed_src))

cat("siglas casadas              :", format(cs$n_str,   big.mark = ","), "\n")
cat("linhas de educacao          :", format(cs$n_rows,  big.mark = ","), "\n")
cat("pessoas (antes da revisao)  :", format(cs$n_users, big.mark = ","), "\n\n")

cat("--- pista da nota 4, por balde ---\n")
print(dbGetQuery(con, "
  SELECT hint_bucket, count(*) AS n_str, sum(n_users) AS n_users
  FROM cand GROUP BY 1 ORDER BY n_users DESC"), right = FALSE, row.names = FALSE)

if (n_acr_all != exp_acr_all || n_acr != exp_acr_uniq ||
    cs$n_str != exp_strings || cs$n_rows != exp_cand_rows ||
    cs$n_users != exp_cand_users) {
  warning("Candidatos divergem do medido (", exp_acr_all, " siglas, ",
          exp_acr_uniq, " unicas, ", exp_strings, " strings, ",
          exp_cand_rows, " linhas, ", exp_cand_users, " pessoas).")
}

####################################################################
### D -- a planilha de candidatos
####################################################################

# label_auto e PROPOSTA, nao veredito. Ver nota 4.
cnd <- dbGetQuery(con, "
  SELECT acr_fold, spellings, n_spellings, claims_institution,
         claims_country, claims_rank, n_rows, n_users,
         revelio_university_name, revelio_name_rows, hint_bucket,
         hint_resolves_to,
         CASE WHEN hint_bucket = 'confirms'    THEN 'OK'
              WHEN hint_bucket = 'contradicts' THEN 'WRONG'
              ELSE '' END AS label_auto
  FROM cand ORDER BY n_users DESC, acr_fold")

write.csv(cnd, cands_path, row.names = FALSE, fileEncoding = "UTF-8")
cat("\nCandidatos gravados:", cands_path, "\n")
cat("linhas:", nrow(cnd), " sem rotulo automatico:",
    sum(cnd$label_auto == ""), "\n")

if (!file.exists(class_path)) {
  cat("\n")
  cat("Falta o arquivo revisado:\n  ", class_path, "\n")
  cat("Copie os candidatos, preencha a coluna `label` com OK, WRONG ou\n")
  cat("AMBIGUOUS em TODAS as linhas e rode de novo. Sem ele nao ha flag.\n")
  stop("Revisao ausente. Ver nota 4.")
}

####################################################################
### E -- a revisao manda
####################################################################

cls <- read.csv(class_path, stringsAsFactors = FALSE,
                fileEncoding = "UTF-8")
stopifnot(all(c("acr_fold", "label") %in% names(cls)))

cls$acr_fold <- trimws(cls$acr_fold)
cls$label    <- toupper(trimws(cls$label))

bad <- setdiff(cls$label, c("OK", "WRONG", "AMBIGUOUS"))
if (length(bad)) {
  stop("Rotulos invalidos em ", basename(class_path), ": ",
       paste(unique(bad), collapse = ", "))
}
if (anyDuplicated(cls$acr_fold)) {
  stop("acr_fold repetido em ", basename(class_path), ".")
}

# A revisao tem de cobrir exatamente os candidatos. Uma string que
# aparece so num dos lados e revisao desatualizada, nao detalhe.
falta <- setdiff(cnd$acr_fold, cls$acr_fold)
sobra <- setdiff(cls$acr_fold, cnd$acr_fold)
if (length(falta)) {
  cat("Sem revisao:\n"); print(utils::head(falta, 20))
  stop(length(falta), " candidatos sem linha em ", basename(class_path), ".")
}
if (length(sobra)) {
  cat("Revisados mas nao candidatos:\n"); print(utils::head(sobra, 20))
  stop(length(sobra), " linhas de revisao sem candidato correspondente.")
}

cat("\n--- revisao ---\n")
print(table(cls$label), right = FALSE)

keep <- cls[cls$label == "OK", c("acr_fold"), drop = FALSE]
cat("\nsiglas aceitas:", nrow(keep), "de", nrow(cls), "\n")

dbWriteTable(con, "keep", keep, overwrite = TRUE)

dbExecute(con, "
  CREATE OR REPLACE TABLE cls AS
  SELECT c.acr_fold AS s, c.claims_rank AS sh_rank,
         c.claims_institution AS sh_inst
  FROM cand c JOIN keep k ON k.acr_fold = c.acr_fold")

####################################################################
### F -- nivel do diploma e uma linha por user_id
####################################################################

# Mesma cascata do script 16, mesmo br_degree_patterns.R. A unica
# diferenca e a tabela de casamento: aqui so cls, so university_raw.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE lvl AS
  SELECT e.user_id,
         c.sh_rank,
         c.sh_inst,
         CAST(year(e.startdate) AS INTEGER)            AS yr,
         (%s)                                          AS lvl,
         (e.degree = 'MBA' OR regexp_like(e.dr, '%s')) AS is_mba,
         regexp_like(e.dr, '%s')                       AS is_lato
  FROM (
    SELECT user_id, startdate, degree, university_raw,
           lower(trim(coalesce(degree_raw, ''))) AS dr
    FROM %s
  ) e
  JOIN cls c ON fold_soft(e.university_raw) = c.s",
  sql_shanghai_level, rx_mba, rx_lato, ed_src))

lvl_rows <- dbGetQuery(con, "
  SELECT lvl, count(*) AS n, count(DISTINCT user_id) AS usuarios
  FROM lvl GROUP BY 1 ORDER BY n DESC")
cat("--- linhas casadas, por nivel ---\n")
print(lvl_rows, right = FALSE, row.names = FALSE)

dbExecute(con, "
  CREATE OR REPLACE TABLE saida AS
  SELECT user_id,
         1                                                                  AS sh_acr_any,
         CAST(max(CASE WHEN lvl = 'bachelor' THEN 1 ELSE 0 END) AS INTEGER) AS sh_acr_bachelor,
         CAST(max(CASE WHEN lvl = 'master'   THEN 1 ELSE 0 END) AS INTEGER) AS sh_acr_master,
         CAST(max(CASE WHEN lvl = 'master' AND NOT is_mba
                       THEN 1 ELSE 0 END)                      AS INTEGER) AS sh_acr_master_strict,
         CAST(max(CASE WHEN lvl = 'phd'      THEN 1 ELSE 0 END) AS INTEGER) AS sh_acr_phd,
         CAST(max(CASE WHEN is_lato          THEN 1 ELSE 0 END) AS INTEGER) AS sh_acr_lato,
         min(sh_rank) FILTER (WHERE lvl IN ('bachelor','master','phd'))     AS sh_acr_best_rank,
         min(sh_rank) FILTER (WHERE lvl = 'bachelor')                       AS sh_acr_bach_rank,
         min(sh_rank) FILTER (WHERE lvl = 'master')                         AS sh_acr_mast_rank,
         min(sh_rank) FILTER (WHERE lvl = 'phd')                            AS sh_acr_phd_rank,
         arg_min(sh_inst, sh_rank)
           FILTER (WHERE lvl IN ('bachelor','master','phd'))                AS sh_acr_inst,
         arg_min(sh_inst, sh_rank) FILTER (WHERE lvl = 'bachelor')          AS sh_acr_bach_inst,
         arg_min(sh_inst, sh_rank) FILTER (WHERE lvl = 'master')            AS sh_acr_mast_inst,
         arg_min(sh_inst, sh_rank) FILTER (WHERE lvl = 'phd')               AS sh_acr_phd_inst,
         min(yr) FILTER (WHERE lvl = 'bachelor')                            AS sh_acr_bach_year,
         min(yr) FILTER (WHERE lvl = 'master')                              AS sh_acr_mast_year,
         min(yr) FILTER (WHERE lvl = 'phd')                                 AS sh_acr_phd_year
  FROM lvl
  WHERE lvl IN ('bachelor','master','phd') OR is_lato
  GROUP BY user_id")

####################################################################
### G -- validacao
####################################################################

v <- dbGetQuery(con, sprintf("
  SELECT count(*)                                   AS n,
         count(DISTINCT user_id)                    AS n_users,
         max(coalesce(sh_acr_best_rank, 0))         AS rank_max,
         sum(CASE WHEN sh_acr_any <> 1 THEN 1 ELSE 0 END) AS bad_any,
         sum(CASE WHEN sh_acr_bachelor + sh_acr_master + sh_acr_phd
                       + sh_acr_lato = 0 THEN 1 ELSE 0 END) AS bad_empty,
         sum(CASE WHEN coalesce(sh_acr_bach_rank, 0) > %1$d
                    OR coalesce(sh_acr_mast_rank, 0) > %1$d
                    OR coalesce(sh_acr_phd_rank,  0) > %1$d
                  THEN 1 ELSE 0 END)                AS bad_rank
  FROM saida", rank_cut))

if (v$n != v$n_users) stop("saida tem user_id repetido.")
if (v$bad_any != 0)   stop(v$bad_any, " linhas com sh_acr_any diferente de 1.")
if (v$bad_empty != 0) stop(v$bad_empty, " linhas marcadas sem nenhum nivel.")
if (v$rank_max > rank_cut) {
  stop("sh_acr_best_rank chega a ", v$rank_max, ", acima do corte ", rank_cut)
}
if (v$bad_rank != 0) stop(v$bad_rank, " linhas com rank de nivel acima do corte.")

# Nota 1: nenhuma linha pode ter entrado por segmento. Por construcao o
# join e por igualdade de string inteira; esta checagem existe para o
# dia em que alguem "melhorar" o join.
seg <- dbGetQuery(con, "
  SELECT count(*) AS n FROM cls c
  WHERE NOT EXISTS (SELECT 1 FROM acr a WHERE a.acr_fold = c.s)")$n
if (seg != 0) stop(seg, " strings aceitas que nao sao sigla de string inteira.")

# Todo mundo marcado tem de estar na coorte.
fora <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM saida o
  WHERE NOT EXISTS (SELECT 1 FROM read_parquet('%s') c
                    WHERE c.user_id = o.user_id)", cand_path))$n
if (fora != 0) stop(fora, " user_id marcados fora de obmep_candidates_step_1.")

n_cohort <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM read_parquet('%s')", cand_path))$n
if (n_cohort != exp_cohort) {
  stop("A coorte tem ", n_cohort, " linhas, nao ", exp_cohort, ".")
}

dbExecute(con, sprintf(
  "COPY saida TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", out_path))

####################################################################
### H -- quanto o braco acrescenta
####################################################################

cat("\n--- resultado ---\n")
cat("pessoas marcadas        :", format(v$n_users, big.mark = ","),
    sprintf("(%.2f%% da coorte)\n", 100 * v$n_users / n_cohort))

if (file.exists(sh16_path)) {
  novo <- dbGetQuery(con, sprintf("
    SELECT count(*) AS n_novos FROM saida o
    WHERE NOT EXISTS (SELECT 1 FROM read_parquet('%s') s
                      WHERE s.user_id = o.user_id)", sh16_path))$n_novos
  n16 <- dbGetQuery(con, sprintf(
    "SELECT count(*) AS n FROM read_parquet('%s')", sh16_path))$n
  cat("ja marcadas pelo script 16:",
      format(v$n_users - novo, big.mark = ","), "\n")
  cat("NOVAS, invisiveis a sh_any:", format(novo, big.mark = ","),
      sprintf("(+%.2f%% sobre %s)\n", 100 * novo / n16,
              format(n16, big.mark = ",")))
} else {
  cat("obmep_candidates_step_1_shanghai.parquet ausente; sem comparacao.\n")
}

cat("\n--- as strings aceitas, por tamanho ---\n")
print(dbGetQuery(con, "
  SELECT c.acr_fold, c.claims_institution, c.claims_rank,
         c.n_rows, c.n_users
  FROM cand c JOIN keep k ON k.acr_fold = c.acr_fold
  ORDER BY c.n_users DESC LIMIT 25"), right = FALSE, row.names = FALSE)

df <- arrow::read_parquet(out_path)
stopifnot(nrow(df) == v$n_users,
          all(c("user_id", "sh_acr_any", "sh_acr_inst",
                "sh_acr_best_rank") %in% names(df)))

# O ano so pode estar preenchido onde a flag do nivel e 1. O contrario
# NAO vale: year(startdate) e nulo quando startdate falta, entao flag 1
# sem ano e normal. Mesma situacao do script 16, que tem 2.754 de
# 856.076 usuarios com sh_bachelor = 1 e sh_bach_year nulo.
for (lv in c("bach", "mast", "phd")) {
  fl <- df[[paste0("sh_acr_",
                   c(bach = "bachelor", mast = "master", phd = "phd")[[lv]])]]
  yr_col <- df[[paste0("sh_acr_", lv, "_year")]]
  orf <- sum(fl != 1L & !is.na(yr_col))
  if (orf != 0L) {
    stop(orf, " linhas com sh_acr_", lv, "_year preenchido sem a flag do nivel.")
  }
  sem <- sum(fl == 1L & is.na(yr_col))
  if (sem > 0L) {
    cat(sprintf("  sh_acr_%s_year ausente em %s de %s (startdate nulo)\n",
                lv, format(sem, big.mark = ","), format(sum(fl == 1L), big.mark = ",")))
  }
}

# A revisao nao mudou, entao a populacao marcada nao pode ter mudado.
if (nrow(df) != 10907L) {
  warning("O braco da sigla marca ", nrow(df), " pessoas, nao 10.907. ",
          "A revisao ou o extrato mudou?")
}

cat("\nGravado:", out_path, "\n")
cat("linhas :", format(nrow(df), big.mark = ","), " colunas:", ncol(df), "\n")
cat("tamanho:", round(file.size(out_path) / 1024, 1), "KB\n")
