####################################################################
###
### Flags de diploma nas 23 do RUF top-10 STEM          -> Dropbox
###
### Uma pergunta para cada membro da coorte: esta pessoa tem bacharelado,
### mestrado ou doutorado em uma das 23 universidades brasileiras que
### estao no TOP 10 do RUF 2025 em algum dos 12 cursos STEM?
###
### Este script e o script 16 apontado para a lista do script 19. As
### duas metades ja existiam; aqui nao ha logica nova:
###
###   shanghai_top1000_degree_flags.R  o classificador C_norm sobre
###                                    education, a cascata de nivel
###   obmep_candidates_step_1_firms.R  como as duas fontes do RUF
###                                    viram inst + inst_ab
###
### Saida:
###   obmep_candidates_step_1_ruf_degree.parquet   uma linha por
###                                                USUARIO MARCADO
###
### Depends on:
###   obmep_candidates_step_1_entries.R      (education extract, 10a)
###   ruf_stem_top50.R                       (rank_cut = 10)
###   ruf_openalex_br_crosswalk.R            (the OpenAlex spellings)
###   br_degree_patterns.R                   (sourced constants, 7)
###
### NO NETWORK. Reads local parquet, writes local parquet. It is still
### a prep/ script and still must not be sent to SEDAP, because
### everything it depends on came from Athena. See AGENTS.md ->
### Execution Environments.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. QUATRO PREFIXOS, E ELES SE CONFUNDEM COM FACILIDADE. Cada uma
###    das duas listas e perguntada nas DUAS direcoes, em scripts
###    diferentes:
###
###      sh_  ESTUDOU   numa Shanghai top-1000  shanghai_top1000_degree_flags.R
###      sw_  TRABALHOU numa Shanghai top-1000  obmep_candidates_step_1_firms.R
###      rd_  ESTUDOU   numa RUF top-10 STEM    AQUI
###      rf_  TRABALHOU numa RUF top-10 STEM    obmep_candidates_step_1_firms.R
###
###    Este script escreve SO rd_. Quem trabalhou na USP sem estudar la
###    tem rf_ = 1 e rd_ = 0, e o contrario tambem acontece.
### 2. AS DUAS LISTAS NAO SAO A MESMA PERGUNTA, e por isso rd_ nao e
###    redundante com sh_. So 14 das 23 do RUF estao no top-1000 do
###    Shanghai; as outras 9 sao invisiveis para sh_ -- UTFPR, UFBA,
###    UFU, UFLA, UFABC, UEM, Maua, FEI e ITA. E mesmo para as 14, um
###    top-10 do RUF em um curso STEM especifico nao e a mesma
###    afirmacao que um top-1000 mundial de producao cientifica.
### 3. E CRITERIO C_NORM, o casamento padrao da pasta (README
###    "C_norm"): dobra acento, compara em minusculas, aceita a string
###    inteira ou qualquer segmento delimitado por `/`, `(`, `)`,
###    `" - "` com pelo menos 3 caracteres. Mesmo classificador do
###    script 16, rodado uma vez por coluna de origem.
### 4. O BRACO DA SIGLA E SEPARADO PORQUE E O PERIGOSO, e aqui ele
###    pesa MAIS que no script 19. `university_raw` e exatamente onde
###    as pessoas escrevem "USP" sozinho -- ao contrario do campo de
###    empregador. USP tambem e United States Pharmacopeia, FEI
###    tambem e um fabricante, ITA e UEM e UFG tem tres letras.
###    `rd_abbr_any` fica na sua propria coluna: quem nao quiser
###    escreve `WHERE rd_abbr_any = 0` em vez de pedir rebuild. Leia
###    as strings que so ela casou, impressas no fim, antes de usar.
### 5. O RANK E O MELHOR RANK DO RUF, 1 a 10, e nao um rank global. Ele
###    vem de best_rank em ruf_stem_top10_institutions_2025.parquet,
###    que e a melhor colocacao da instituicao entre os 12 cursos STEM.
###    Duas instituicoes com best_rank 1 estao empatadas em cursos
###    diferentes, nao no mesmo.
### 6. SO USUARIOS MARCADOS SAO ESCRITOS, como nos scripts 16 e 19.
###    Fazer LEFT JOIN de volta em obmep_candidates_step_1 e ler a
###    linha ausente como zero e trabalho do consumidor.
### 7. HERDA AS LIMITACOES DO SCRIPT 16, sem excecao:
###      - sigla sozinha so casa pelo braco da sigla (nota 4);
###      - homonimo casa errado, e casamento exato apos normalizacao
###        nao separa os dois;
###      - o rotulo `degree` do Revelio ganha quando discorda de
###        `degree_raw`;
###      - CONCLUSAO NAO E VERIFICADA. O Revelio registra matricula,
###        nao diploma, entao "mestrando" e "doutorando" marcam a
###        flag. O criterio E tem a mesma propriedade.
### 8. startdate E DATE NA TABELA DE EDUCATION, ao contrario da de
###    position, onde e string -- README trap 1. Aqui year() e o certo.
###
### -----------------------------------------------------------------
### MEASURED, run of 2026-08-29
### -----------------------------------------------------------------
###   linhas de educacao casadas    750,309
###   USUARIOS MARCADOS             583,570   -- 8.52% da coorte
###
###     rd_bachelor      515,608
###     rd_master        118,332   (rd_master_strict 98,674)
###     rd_phd            31,248
###     rd_lato           14,129
###     por nome         576,040
###     por sigla          9,019   -- 1.5% dos marcados, nota 4
###     so por raw       583,391
###
###   O ORDENAMENTO E A VALIDACAO, e ele le certo: USP 93,367, UFRJ
###   50,310, UFMG 43,242, UnB 36,550, UFPR 31,815, UFSC 31,424,
###   Unicamp 30,290. ITA fecha a lista com 2,247, o que e o esperado
###   de uma escola pequena e altamente seletiva.
###
###   O BRACO DA SIGLA SAIU PEQUENO E LIMPO (nota 4): 9,019 usuarios,
###   1.5% do total, contra os 1.5-2.5% que o README mede para siglas
###   nuas. As 30 strings que so ele casou sao todas siglas
###   brasileiras inequivocas -- UFSCar 2,001, UTFPR 1,274, FEI 1,150
###   e variantes de caixa. Nenhuma United States Pharmacopeia.
###
###   E ISTO E O QUE JUSTIFICA O ESTAGIO (nota 2): 133,940 dos 583,570
###   NAO estao em obmep_candidates_step_1_shanghai.parquet, e eles se
###   concentram exatamente nas 9 ausentes do top-1000 -- UTFPR
###   26,988, UFBA 22,383, UFU 19,073, UFABC 15,195, UEM 13,741, UFLA
###   10,018, FEI 7,826, Maua 5,407, ITA 1,997, somando 122,628 dos
###   133,940. O resto e quase todo Unesp (9,056), cuja grafia no RUF
###   casa onde a do Shanghai nao casa. Sem este estagio, esses
###   diplomas seriam invisiveis.
###
####################################################################

rm(list = ls()); gc()

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

coh_dir   <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
ed_dir    <- file.path(coh_dir, "obmep_candidates_step_1_education")
cand_path <- file.path(coh_dir, "obmep_candidates_step_1.parquet")

ruf_dir   <- file.path(obmep_root, "Data/intermediate/ruf_ranking")
ruf_inst  <- file.path(ruf_dir, "ruf_stem_top10_institutions_2025.parquet")
ruf_oa    <- file.path(ruf_dir, "ruf_openalex_br_2025.parquet")

out_path  <- file.path(coh_dir, "obmep_candidates_step_1_ruf_degree.parquet")

patterns_path <- Sys.getenv(
  "OBMEP_DEGREE_PATTERNS",
  unset = file.path("prep", "building_external_data", "br_degree_patterns.R"))

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "8GB")

# O RUF top-10 ja vem cortado; best_rank nunca passa de 10 (nota 5).
rank_cut     <- 10L
exp_ruf_inst <- 23L

# Tamanho da coorte de origem. Deterministico: o extrato foi construido
# a partir dela, entao isto aborta em vez de avisar.
exp_cohort <- 6849674L

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_ruf_degree")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(file.exists(ruf_inst), file.exists(ruf_oa), file.exists(cand_path),
          file.exists(patterns_path), dir.exists(ed_dir),
          length(Sys.glob(file.path(ed_dir, "*"))) > 0L)

source(patterns_path)
stopifnot(exists("sql_is_bachelor"), exists("sql_shanghai_level"),
          exists("rx_mba"), exists("rx_lato"))

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# temp_directory explicito: o derrame para disco nao pode cair em pasta
# sincronizada pelo Dropbox.
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

# Shim Trino -> DuckDB: br_degree_patterns.R esta escrito na grafia do
# Trino, e regexp_like nao existe no DuckDB.
dbExecute(con, "CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)")

fw <- function(p) gsub("\\\\", "/", p)

cat("DuckDB   :", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("RUF      :", ruf_inst, "\n")
cat("educacao :", ed_dir, "\n")
cat("saida    :", out_path, "\n\n")

# Bare `*`: as partes do UNLOAD do Athena se chamam <query-id>_<uuid>,
# SEM extensao .parquet, entao um glob por extensao nao acha nada.
ed_src <- sprintf("read_parquet('%s/*')", fw(ed_dir))

####################################################################
### A -- o lado das instituicoes: as grafias das 23 do RUF
####################################################################

cat("=========== RUF ===========\n")
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE ruf AS
  SELECT i.ruf_institution_id, i.institution_name, i.abbr, i.uf,
         i.best_rank, i.n_courses_top10,
         o.display_name, o.cleaned_display_name
  FROM read_parquet('%s') i
  LEFT JOIN read_parquet('%s') o USING (ruf_institution_id)",
  fw(ruf_inst), fw(ruf_oa)))

n_ruf <- dbGetQuery(con, "SELECT count(*) n FROM ruf")$n
if (n_ruf != exp_ruf_inst) {
  warning("RUF top-10 tem ", n_ruf, " instituicoes, esperava ", exp_ruf_inst)
}
miss_oa <- dbGetQuery(con, "SELECT count(*) n FROM ruf WHERE display_name IS NULL")$n
if (miss_oa > 0) {
  warning(miss_oa, " RUF institutions have no OpenAlex spelling; the name arm ",
          "runs on the RUF name alone for those.")
}

# Tres grafias completas por instituicao, dobradas e deduplicadas -- a
# mesma construcao do script 19. A sigla NAO entra aqui: ela tem o seu
# proprio braco, com regra diferente (nota 4).
dbExecute(con, "
  CREATE OR REPLACE TABLE inst AS
  SELECT lower(strip_accents(trim(nm)))         AS nm_fold,
         min(best_rank)                         AS best_rank,
         arg_min(ruf_institution_id, best_rank) AS rid,
         arg_min(abbr, best_rank)               AS inst_name
  FROM (
    SELECT institution_name     AS nm, best_rank, ruf_institution_id, abbr FROM ruf
    UNION ALL
    SELECT display_name,         best_rank, ruf_institution_id, abbr FROM ruf
    UNION ALL
    SELECT cleaned_display_name, best_rank, ruf_institution_id, abbr FROM ruf
  )
  WHERE nm IS NOT NULL AND length(trim(nm)) >= 3
  GROUP BY 1")

dbExecute(con, "
  CREATE OR REPLACE TABLE inst_ab AS
  SELECT lower(strip_accents(trim(abbr)))       AS nm_fold,
         min(best_rank)                         AS best_rank,
         arg_min(ruf_institution_id, best_rank) AS rid,
         arg_min(abbr, best_rank)               AS inst_name
  FROM ruf
  WHERE abbr IS NOT NULL AND length(trim(abbr)) >= 2
  GROUP BY 1")

n_inst <- dbGetQuery(con, "SELECT count(*) n FROM inst")$n
n_ab   <- dbGetQuery(con, "SELECT count(*) n FROM inst_ab")$n
cat("grafias completas         :", n_inst, "\n")
cat("siglas                    :", n_ab, "\n")

# Uma instituicao cuja sigla dobrada colida com o nome completo de
# outra tornaria os dois bracos indistinguiveis. Nao acontece hoje;
# a checagem existe para o dia em que a lista mudar.
clash <- dbGetQuery(con, "
  SELECT a.nm_fold FROM inst_ab a JOIN inst i ON a.nm_fold = i.nm_fold")
if (nrow(clash)) {
  print(clash, row.names = FALSE)
  stop("An abbreviation folds to the same string as a full institution name.")
}

####################################################################
### B -- o classificador C_norm, uma vez por coluna de origem
####################################################################

# Identico ao do script 19: dois bracos de nome mais o braco da sigla,
# que e SO igualdade de string inteira (nota 4). As duas colunas de
# origem recebem exatamente o mesmo tratamento -- mesmos tres bracos,
# mesma dobra de acento, mesmo corte de 3 caracteres -- para que a
# unica diferenca entre elas seja a COLUNA lida.
classify <- function(col, tbl) {
  dbExecute(con, sprintf("
    CREATE OR REPLACE TABLE %1$s AS
    WITH r AS (
      SELECT DISTINCT %2$s AS s FROM %3$s
      WHERE %2$s IS NOT NULL AND trim(%2$s) <> ''
    ),
    whole AS (
      SELECT r.s, i.best_rank, i.rid, i.inst_name
      FROM r JOIN inst i ON lower(strip_accents(trim(r.s))) = i.nm_fold
    ),
    seg AS (
      SELECT r.s,
             min(i.best_rank)                  AS best_rank,
             arg_min(i.rid, i.best_rank)       AS rid,
             arg_min(i.inst_name, i.best_rank) AS inst_name
      FROM r
      CROSS JOIN UNNEST(str_split(regexp_replace(regexp_replace(
                   r.s, '[/()]', '|', 'g'), ' - ', '|', 'g'), '|')) AS t(part)
      JOIN inst i ON lower(strip_accents(trim(t.part))) = i.nm_fold
      WHERE length(trim(t.part)) >= 3
      GROUP BY r.s
    ),
    ab AS (
      SELECT r.s, a.best_rank, a.rid, a.inst_name
      FROM r JOIN inst_ab a ON lower(strip_accents(trim(r.s))) = a.nm_fold
    )
    SELECT s,
           CAST(min(best_rank) AS INTEGER)          AS m_rank,
           CAST(arg_min(rid, best_rank) AS INTEGER) AS m_id,
           arg_min(inst_name, best_rank)            AS m_inst,
           CAST(max(is_whole) AS INTEGER)           AS m_whole,
           CAST(max(is_seg)   AS INTEGER)           AS m_seg,
           CAST(max(is_ab)    AS INTEGER)           AS m_ab
    FROM (
      SELECT s, best_rank, rid, inst_name, 1 AS is_whole, 0 AS is_seg, 0 AS is_ab FROM whole
      UNION ALL
      SELECT s, best_rank, rid, inst_name, 0, 1, 0                                FROM seg
      UNION ALL
      SELECT s, best_rank, rid, inst_name, 0, 0, 1                                FROM ab
    )
    GROUP BY s", tbl, col, ed_src))
  dbGetQuery(con, sprintf("
    SELECT count(*) AS n_strings, sum(m_whole) AS n_whole,
           sum(m_seg) AS n_seg, sum(m_ab) AS n_ab FROM %s", tbl))
}

n_raws <- dbGetQuery(con, sprintf(
  "SELECT count(DISTINCT university_raw) AS n FROM %s
   WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''", ed_src))$n
cat("university_raw distinto   :", format(n_raws, big.mark = ","), "\n\n")

cat("--- classificando university_raw ---\n")
m  <- classify("university_raw",  "cls")
print(m, row.names = FALSE)
cat("--- classificando university_name ---\n")
mn <- classify("university_name", "cls_nam")
print(mn, row.names = FALSE)

####################################################################
### C -- nivel do diploma, linha a linha
####################################################################

# A cascata vem de br_degree_patterns.R. Os quatro bracos particionam
# as linhas por construcao; a validacao confere isso. Precedencia
# raw > name com coalesce, como no script 16: o que a pessoa escreveu
# decide, e o campo normalizado do Revelio so entra quando o cru falha.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE lvl AS
  SELECT e.user_id,
         CAST(coalesce(c.m_rank, n.m_rank) AS INTEGER) AS rd_rank,
         coalesce(c.m_inst, n.m_inst)                  AS rd_inst,
         CAST(coalesce(c.m_id, n.m_id) AS INTEGER)     AS rd_id,
         CAST(CASE WHEN coalesce(c.m_whole, n.m_whole, 0) = 1
                     OR coalesce(c.m_seg,   n.m_seg,   0) = 1
                   THEN 1 ELSE 0 END AS INTEGER)       AS by_name,
         CAST(CASE WHEN coalesce(c.m_ab, n.m_ab, 0) = 1
                   THEN 1 ELSE 0 END AS INTEGER)       AS by_abbr,
         CASE WHEN c.s IS NOT NULL THEN 1 ELSE 0 END   AS by_raw,
         CAST(year(e.startdate) AS INTEGER)            AS yr,
         (%s)                                          AS lvl,
         (e.degree = 'MBA' OR regexp_like(e.dr, '%s')) AS is_mba,
         regexp_like(e.dr, '%s')                       AS is_lato
  FROM (
    SELECT user_id, startdate, degree, university_raw, university_name,
           lower(trim(coalesce(degree_raw, ''))) AS dr
    FROM %s
  ) e
  LEFT JOIN cls     c ON e.university_raw  = c.s
  LEFT JOIN cls_nam n ON e.university_name = n.s
  WHERE c.s IS NOT NULL OR n.s IS NOT NULL",
  sql_shanghai_level, rx_mba, rx_lato, ed_src))

lvl_rows <- dbGetQuery(con, "
  SELECT lvl, count(*) AS n, count(DISTINCT user_id) AS usuarios
  FROM lvl GROUP BY 1 ORDER BY n DESC")

cat("\n--- linhas de educacao casadas, por nivel ---\n")
print(lvl_rows, right = FALSE, row.names = FALSE)

n_rows_matched <- sum(lvl_rows$n)
cat("\ntotal de linhas casadas   :", format(n_rows_matched, big.mark = ","), "\n\n")

####################################################################
### D -- uma linha por user_id
####################################################################

dbExecute(con, "
  CREATE OR REPLACE TABLE saida AS
  SELECT user_id,
         1                                                                   AS rd_any,
         CAST(max(CASE WHEN by_name = 1 AND lvl IN ('bachelor','master','phd')
                       THEN 1 ELSE 0 END)                       AS INTEGER)  AS rd_name_any,
         CAST(max(CASE WHEN by_abbr = 1 AND lvl IN ('bachelor','master','phd')
                       THEN 1 ELSE 0 END)                       AS INTEGER)  AS rd_abbr_any,
         CAST(max(CASE WHEN by_raw = 1 AND lvl IN ('bachelor','master','phd')
                       THEN 1 ELSE 0 END)                       AS INTEGER)  AS rd_raw_any,
         CAST(max(CASE WHEN lvl = 'bachelor' THEN 1 ELSE 0 END) AS INTEGER)  AS rd_bachelor,
         CAST(max(CASE WHEN lvl = 'master'   THEN 1 ELSE 0 END) AS INTEGER)  AS rd_master,
         CAST(max(CASE WHEN lvl = 'master' AND NOT is_mba
                       THEN 1 ELSE 0 END)                       AS INTEGER)  AS rd_master_strict,
         CAST(max(CASE WHEN lvl = 'phd'      THEN 1 ELSE 0 END) AS INTEGER)  AS rd_phd,
         CAST(max(CASE WHEN is_lato          THEN 1 ELSE 0 END) AS INTEGER)  AS rd_lato,
         min(rd_rank) FILTER (WHERE lvl IN ('bachelor','master','phd'))      AS rd_best_rank,
         min(rd_rank) FILTER (WHERE lvl = 'bachelor')                        AS rd_bach_rank,
         min(rd_rank) FILTER (WHERE lvl = 'master')                          AS rd_mast_rank,
         min(rd_rank) FILTER (WHERE lvl = 'phd')                             AS rd_phd_rank,
         arg_min(rd_inst, rd_rank) FILTER (WHERE lvl = 'bachelor')           AS rd_bach_inst,
         arg_min(rd_inst, rd_rank) FILTER (WHERE lvl = 'master')             AS rd_mast_inst,
         arg_min(rd_inst, rd_rank) FILTER (WHERE lvl = 'phd')                AS rd_phd_inst,
         min(yr) FILTER (WHERE lvl = 'bachelor')                             AS rd_bach_year,
         min(yr) FILTER (WHERE lvl = 'master')                               AS rd_mast_year,
         min(yr) FILTER (WHERE lvl = 'phd')                                  AS rd_phd_year,
         arg_min(rd_id, rd_rank) FILTER (WHERE lvl IN ('bachelor','master','phd'))
                                                                             AS rd_best_inst_id,
         CAST(count(*) AS INTEGER)                                           AS rd_n_rows
  FROM lvl
  GROUP BY user_id
  HAVING max(CASE WHEN lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) = 1")

dbExecute(con, sprintf(
  "COPY (SELECT * FROM saida ORDER BY user_id) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_path)))

####################################################################
### Validacao
####################################################################

v <- dbGetQuery(con, "
  SELECT count(*)                                         AS n_users,
         count(DISTINCT user_id)                          AS n_uid,
         sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS uid_null,
         sum(rd_any)                                      AS n_any,
         sum(rd_name_any)                                 AS n_name_any,
         sum(rd_abbr_any)                                 AS n_abbr_any,
         sum(rd_raw_any)                                  AS n_raw_any,
         sum(rd_bachelor)                                 AS n_bachelor,
         sum(rd_master)                                   AS n_master,
         sum(rd_master_strict)                            AS n_master_str,
         sum(rd_phd)                                      AS n_phd,
         sum(rd_lato)                                     AS n_lato,
         sum(CASE WHEN rd_bachelor + rd_master + rd_phd = 0
                  THEN 1 ELSE 0 END)                      AS bad_empty,
         sum(CASE WHEN rd_master_strict > rd_master
                  THEN 1 ELSE 0 END)                      AS bad_strict,
         sum(CASE WHEN rd_raw_any > rd_any THEN 1 ELSE 0 END)  AS bad_rawsup,
         sum(CASE WHEN rd_abbr_any > rd_any THEN 1 ELSE 0 END) AS bad_absup,
         sum(CASE WHEN rd_name_any = 0 AND rd_abbr_any = 0
                  THEN 1 ELSE 0 END)                      AS bad_noarm,
         sum(CASE WHEN rd_best_rank IS NULL
                  THEN 1 ELSE 0 END)                      AS bad_norank,
         sum(CASE WHEN rd_best_inst_id IS NULL
                  THEN 1 ELSE 0 END)                      AS bad_noid,
         max(rd_best_rank)                                AS rank_max
  FROM saida")

if (v$n_users == 0)       stop("Nenhum usuario marcado -- isso nao e plausivel.")
if (v$n_users != v$n_uid) stop("user_id duplicado na saida.")
if (v$uid_null != 0)      stop("user_id nulo na saida.")
if (v$n_any != v$n_users) stop("rd_any nao e 1 em toda linha.")
if (v$bad_empty != 0) {
  stop(v$bad_empty, " linhas sem nenhuma das tres flags. O HAVING nao ",
       "esta cortando o que deveria.")
}
# Estrito e subconjunto por construcao: rd_master_strict exige tudo que
# rd_master exige e mais a negacao de MBA.
if (v$bad_strict != 0) {
  stop(v$bad_strict, " linhas com rd_master_strict > rd_master. ",
       "O teste de MBA esta invertido.")
}
if (v$bad_rawsup != 0) stop(v$bad_rawsup, " linhas com rd_raw_any > rd_any.")
if (v$bad_absup  != 0) stop(v$bad_absup,  " linhas com rd_abbr_any > rd_any.")
# Todo usuario marcado entrou por ALGUM braco. Nenhum braco ligado
# significa que a marcacao veio de uma linha que nao era diploma.
if (v$bad_noarm != 0) {
  stop(v$bad_noarm, " linhas marcadas sem braco de nome nem de sigla.")
}
if (v$bad_norank != 0) stop(v$bad_norank, " linhas marcadas sem rd_best_rank.")
if (v$bad_noid   != 0) stop(v$bad_noid,   " linhas marcadas sem rd_best_inst_id.")
if (v$rank_max > rank_cut) {
  stop("rd_best_rank chega a ", v$rank_max, ", acima do corte ", rank_cut, ".")
}

# A faixa vale em toda coluna de rank, nao so na melhor.
bad_rank <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM saida
  WHERE coalesce(rd_bach_rank, 0) > %1$d
     OR coalesce(rd_mast_rank, 0) > %1$d
     OR coalesce(rd_phd_rank,  0) > %1$d", rank_cut))$n
if (bad_rank != 0) stop(bad_rank, " linhas com rank de nivel acima do corte.")

# A cascata particiona: os quatro bracos tem de somar o total casado.
part <- dbGetQuery(con, "
  SELECT count(*) AS n_all,
         sum(CASE WHEN lvl IN ('bachelor','master','phd','other')
                  THEN 1 ELSE 0 END) AS n_named
  FROM lvl")
if (part$n_all != part$n_named) {
  stop("A cascata de nivel devolveu um valor fora de ",
       "{bachelor, master, phd, other}.")
}

# Todo user_id da saida tem de estar na coorte. O extrato foi construido
# a partir dela, entao um id estranho significa diretorio errado.
orf <- dbGetQuery(con, sprintf("
  SELECT (SELECT count(*) FROM read_parquet('%1$s')) AS n_cohort,
         (SELECT count(*) FROM saida o
          WHERE NOT EXISTS (SELECT 1 FROM read_parquet('%1$s') c
                            WHERE c.user_id = o.user_id)) AS n_orphan",
  fw(cand_path)))
if (orf$n_orphan != 0) {
  stop(orf$n_orphan, " user_id da saida nao estao em ",
       basename(cand_path), ". Diretorio de educacao errado?")
}
if (orf$n_cohort != exp_cohort) {
  stop("A coorte tem ", orf$n_cohort, " linhas, nao ", exp_cohort,
       ". As constantes medidas nao valem contra ela.")
}

####################################################################
### Releitura e relatorio
####################################################################

df <- arrow::open_dataset(out_path, format = "parquet")
stopifnot(identical(names(df), c(
  "user_id", "rd_any", "rd_name_any", "rd_abbr_any", "rd_raw_any",
  "rd_bachelor", "rd_master", "rd_master_strict", "rd_phd", "rd_lato",
  "rd_best_rank", "rd_bach_rank", "rd_mast_rank", "rd_phd_rank",
  "rd_bach_inst", "rd_mast_inst", "rd_phd_inst",
  "rd_bach_year", "rd_mast_year", "rd_phd_year",
  "rd_best_inst_id", "rd_n_rows")))
stopifnot(nrow(df) == v$n_users)

cat("\n=========== USUARIOS MARCADOS ===========\n")
cat("usuarios marcados :", format(v$n_users,      big.mark = ","), "\n")
cat("  rd_bachelor     :", format(v$n_bachelor,   big.mark = ","), "\n")
cat("  rd_master       :", format(v$n_master,     big.mark = ","), "\n")
cat("  rd_master_strict:", format(v$n_master_str, big.mark = ","), "\n")
cat("  rd_phd          :", format(v$n_phd,        big.mark = ","), "\n")
cat("  rd_lato         :", format(v$n_lato,       big.mark = ","), "\n")
cat("  por nome        :", format(v$n_name_any,   big.mark = ","), "\n")
cat("  por sigla       :", format(v$n_abbr_any,   big.mark = ","), "\n")
cat("  so por raw      :", format(v$n_raw_any,    big.mark = ","), "\n")

# O ORDENAMENTO E A VALIDACAO. Nada garante que as marcacoes tenham de
# reproduzir o ranking do RUF, mas se nao reproduzirem, a dobra ou o
# join esta errado -- e nenhuma contagem de linhas mostraria isso.
cat("\n--- as 23 do RUF, todas, por usuarios marcados ---\n")
print(dbGetQuery(con, "
  SELECT r.abbr, r.institution_name, r.best_rank,
         coalesce(h.users, 0)        AS users,
         coalesce(h.by_abbr_only, 0) AS by_abbr_only
  FROM ruf r
  LEFT JOIN (
    SELECT rd_id AS rid, count(DISTINCT user_id) AS users,
           count(DISTINCT CASE WHEN by_name = 0 THEN user_id END) AS by_abbr_only
    FROM lvl WHERE lvl IN ('bachelor','master','phd') GROUP BY 1) h
    ON r.ruf_institution_id = h.rid
  ORDER BY users DESC"), row.names = FALSE, max = 1000)

cat("\n--- 30 strings que SO o braco da sigla casou (nota 4) ---\n")
cat("    Leia esta lista antes de usar rd_abbr_any.\n")
print(dbGetQuery(con, sprintf("
  SELECT c.s AS university_raw, c.m_inst, count(DISTINCT e.user_id) AS users
  FROM %s e JOIN cls c ON e.university_raw = c.s
  WHERE c.m_ab = 1 AND c.m_whole = 0 AND c.m_seg = 0
  GROUP BY 1, 2 ORDER BY users DESC LIMIT 30", ed_src)),
  row.names = FALSE, max = 1000)

cat("\n--- 20 strings que o braco de nome casou (para conferir) ---\n")
print(dbGetQuery(con, sprintf("
  SELECT c.s AS university_raw, c.m_inst, count(DISTINCT e.user_id) AS users
  FROM %s e JOIN cls c ON e.university_raw = c.s
  WHERE c.m_whole = 1 OR c.m_seg = 1
  GROUP BY 1, 2 ORDER BY users DESC LIMIT 20", ed_src)),
  row.names = FALSE, max = 1000)

cat("\nsaida em:", out_path, "\n")
cat(sprintf("  %s linhas  %.1f MB\n", format(v$n_users, big.mark = ","),
            file.info(out_path)$size / 2^20))
cat(sprintf("  coorte de %s; %.2f%% dela fica marcada\n",
            format(exp_cohort, big.mark = ","),
            100 * v$n_users / exp_cohort))
