####################################################################
###
### Candidatos selecionados, VERSAO ALTERNATIVA: RUF substituido,   -> Dropbox
### Xangai alargado
###
### Copia do obmep_candidates_selected.R (21) com duas mudancas de
### definicao. O script 21 e a saida dele NAO sao tocados: as duas
### definicoes convivem, do mesmo jeito que obmep_candidates_step_1_alt
### convive com obmep_candidates_step_1.
###
### Saida:
###   obmep_candidates_selected_alt.parquet   uma linha por usuario
###                                           SELECIONADO, 53 colunas
###
### Depends on:
###   shanghai_top1000_degree_flags.R        (sh_,  16)
###   obmep_candidates_step_1_ruf_degree.R   (rd_,  20)  -- so procedencia
###   obmep_candidates_step_1_firms.R        (un_/tc_/rf_/sw_, 19)
###   ruf_shanghai_rsid_degree_flags.R       (_rsid_, 8g)
###   shanghai_acronym_arm.R                 (sh_acr_, 16a)
###   linkedin_names/linkedin_chunk_*.parquet (GTAllocation, os nomes)
###
### NO NETWORK. Reads local parquet, writes local parquet. Ainda e
### prep/ e ainda nao vai para o SEDAP. Ver AGENTS.md.
###
### -----------------------------------------------------------------
### O QUE MUDA EM RELACAO AO SCRIPT 21
### -----------------------------------------------------------------
### 1. O RUF E SUBSTITUIDO, XANGAI E ALARGADO, E A ASSIMETRIA NAO E
###    CAPRICHO. Os dois bracos novos saem do mesmo mapa seguro
###    rsid -> OpenAlex, mas o mapa foi construido a partir de
###    openalex_institutions_br, 1.947 registros BRASILEIROS:
###
###      RUF      23 de 23 instituicoes alcancadas. E uma reconstrucao
###               completa do conceito, entao rd_ passa a vir dela.
###      XANGAI   18 de 1.079 (1,7%), exatamente as brasileiras.
###               Harvard, MIT e Cambridge nao tem linha nesse mapa.
###               Substituir sh_ por ele perderia 413.557 pessoas.
###
###    Por isso sh_ vira UNIAO (script 16 OU rsid OU sigla) e rd_ vira
###    SUBSTITUICAO (so o braco rsid).
### 2. O QUE ISSO CUSTA, MEDIDO CONTRA A TABELA CANONICA:
###      rd_any     583.570 -> 632.464
###      sh_any     990.937 -> 1.020.485
###      linhas   1.297.109 -> 1.315.248   (+20.278 entram, 2.139 saem)
###
###    Os 2.139 que saem so tinham a flag do RUF por nome e o braco
###    rsid nao os alcanca. Eles continuam em
###    obmep_candidates_selected.parquet, que nao foi tocado. Dos
###    13.406 que perdem a flag rd_, 9.717 mantem uma flag de Xangai,
###    2.945 uma de emprego e 1.104 a da sigla.
### 3. A PROCEDENCIA FICA EM COLUNA, entao qualquer alargamento se
###    desfaz com um WHERE e nao com um rebuild -- a convencao da pasta
###    (sh_raw_any, br_openalex ao lado de br_openalex_norm):
###      sh_name_any  a definicao do script 16, que hoje E o sh_any
###      sh_rsid_any  o braco do rsid       (fatia brasileira, nota 1)
###      sh_acr_any   o braco da sigla
###      rd_name_any  a definicao do script 20, substituida
###      rd_abbr_any  o braco da sigla do script 20
### 4. RANK, INSTITUICAO E ANO POR NIVEL SAO MONTADOS EMPILHANDO, nao
###    comparando coluna com coluna. Os tres bracos de Xangai viram uma
###    tabela longa (usuario, nivel, braco) e sao agregados UMA vez com
###    min(rank) FILTER e arg_min(inst, rank) FILTER -- o mesmo idioma
###    dos scripts 16, 20 e 8g.
###
###    NAO troque isto por um CASE de tres pontas sobre as colunas de
###    rank. O least() do DuckDB IGNORA NULL (README, "Two traps that
###    must not be reintroduced"), o que aqui por acaso daria o
###    resultado certo -- e depender de um comportamento que o README
###    marca como armadilha e exatamente como a proxima pessoa se
###    machuca. Empilhar deixa o NULL explicito.
### 5. A UNIAO CONTINUA SENDO A SELECAO. Os cinco produtos escrevem so
###    usuarios marcados, entao "alguma flag e 1" nao e um WHERE capaz
###    de excluir nada. Nao ha filtro neste script.
### 6. AS FLAGS DE NIVEL SOBREVIVEM aos dois lados: bachelor, master e
###    phd existem para sh_ (uniao dos tres bracos) e para rd_ (do
###    braco rsid). Foi para isso que 8g e 16a ganharam as colunas por
###    nivel antes deste script existir.
### 7. AS DUAS PROCEDENCIAS NAO TEM A MESMA QUALIDADE, e quem usar a
###    tabela precisa saber:
###      - o braco da sigla passou por revisao a mao de 209 strings,
###        aberta em shanghai_acronym_class.xlsx;
###      - os bracos rsid apoiam-se no mapa seguro mais um piso de
###        evidencia e NUNCA foram revisados nesse grao.
###    O cabecalho do 8g registra uma classe de erro que ele nao
###    consegue eliminar: string que nao casou com nada, sob um rsid
###    bom, nomeando outra instituicao. O caso medido e
###    "FAC UNICAMPS - Faculdade Unida de Campinas" (Goiania) atribuido
###    a Unicamp, 671 usuarios, ~1% do ganho do RUF. Isso agora anda
###    dentro de rd_any.
### 8. HERDA AS NOTAS 1 A 7 DO SCRIPT 21 sem excecao -- os quatro
###    prefixos que se confundem, o coalesce das flags contra o NULL
###    dos ranks, in_* como verdade sobre presenca, fullname NULL
###    significando ausencia do snapshot, o nome guardado como chega,
###    as colunas estreitas deixadas para tras, e o fato de esta ser a
###    unica tabela da pasta com dado pessoal direto.
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
gt_root    <- Sys.getenv("GT_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/GTAllocation")

coh_dir   <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
sh_path   <- file.path(coh_dir, "obmep_candidates_step_1_shanghai.parquet")
rd_path   <- file.path(coh_dir, "obmep_candidates_step_1_ruf_degree.parquet")
fm_path   <- file.path(coh_dir, "obmep_candidates_step_1_firms.parquet")
rs_path   <- file.path(coh_dir, "obmep_candidates_step_1_rsid_degree.parquet")
ac_path   <- file.path(coh_dir, "obmep_candidates_step_1_shanghai_acr.parquet")
cand_path <- file.path(coh_dir, "obmep_candidates_step_1.parquet")

# A tabela canonica, so para o relatorio comparativo do fim. Este
# script NAO escreve nela.
old_path  <- file.path(coh_dir, "obmep_candidates_selected.parquet")

lk_dir    <- file.path(gt_root, "Data/intermediate/fuzzy_match/linkedin_names")

out_path  <- file.path(coh_dir, "obmep_candidates_selected_alt.parquet")

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")

# Medidos contra os cinco produtos atuais. Divergencia significa que
# uma das entradas foi reconstruida -- warning, nao stop.
exp_shanghai <- 990937L
exp_ruf_deg  <- 583570L
exp_firms    <- 436813L
exp_rsid     <- 729347L
exp_acr      <- 10907L

# A definicao nova. Estes tres sao o resultado deste script e mudam
# junto com qualquer entrada -- warning, nao stop.
exp_rows   <- 1315248L
exp_sh_any <- 1020485L
exp_rd_any <-  632464L

# Tamanho da coorte de origem. Deterministico: aborta em vez de avisar.
exp_cohort <- 6849674L

# Os 20 chunks de nome, medidos no linkedin_br_name_flag.R.
exp_lk_rows <- 708365562

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_selected_alt")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

for (f in c(sh_path, rd_path, fm_path, rs_path, ac_path, cand_path)) {
  if (!file.exists(f)) stop("Nao encontrei ", f)
}
if (!dir.exists(lk_dir)) stop("Nao encontrei o diretorio de nomes ", lk_dir)

# Guarda contra o acidente que este script existe para evitar.
if (normalizePath(out_path, mustWork = FALSE) ==
    normalizePath(old_path, mustWork = FALSE)) {
  stop("out_path aponta para a tabela canonica. Este script nunca escreve nela.")
}

# Assinatura da tabela canonica ANTES de qualquer coisa. Conferida no
# fim: se mudar, algo escreveu onde nao devia.
old_sig <- if (file.exists(old_path)) {
  c(size = file.info(old_path)$size, mtime = as.numeric(file.info(old_path)$mtime))
} else NULL

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# temp_directory explicito e OBRIGATORIO: a varredura de 15,2 GB dos
# nomes derrama para disco, e o derrame nao pode cair em pasta
# sincronizada pelo Dropbox.
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))
dbExecute(con, "SET preserve_insertion_order=false")

fw <- function(p) gsub("\\\\", "/", p)
rp <- function(p) sprintf("read_parquet('%s')", fw(p))

cat("DuckDB   :", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("shanghai :", basename(sh_path), "\n")
cat("ruf_deg  :", basename(rd_path), " (procedencia)\n")
cat("firms    :", basename(fm_path), "\n")
cat("rsid_deg :", basename(rs_path), "\n")
cat("acronimo :", basename(ac_path), "\n")
cat("nomes    :", lk_dir, "\n")
cat("saida    :", out_path, "\n\n")

lk_glob <- file.path(lk_dir, "linkedin_chunk_*.parquet")

####################################################################
### A -- as cinco entradas
####################################################################

cat("=========== ENTRADAS ===========\n")

n_of <- function(p) dbGetQuery(con, sprintf("SELECT count(*) n FROM %s", rp(p)))$n
n_sh <- n_of(sh_path); n_rd <- n_of(rd_path); n_fm <- n_of(fm_path)
n_rs <- n_of(rs_path); n_ac <- n_of(ac_path)

cat("shanghai   (sh_)     :", format(n_sh, big.mark = ","), "\n")
cat("ruf degree (rd_)     :", format(n_rd, big.mark = ","), " <- procedencia\n")
cat("firms                :", format(n_fm, big.mark = ","), "\n")
cat("rsid degree (_rsid_) :", format(n_rs, big.mark = ","), "\n")
cat("acronimo   (sh_acr_) :", format(n_ac, big.mark = ","), "\n")

# Cada produto tem de ser unico por user_id. Os LEFT JOIN abaixo
# inflariam em silencio se nao fosse verdade.
for (nm in list(c("shanghai", sh_path), c("ruf_degree", rd_path),
                c("firms", fm_path), c("rsid_degree", rs_path),
                c("acronimo", ac_path))) {
  u <- dbGetQuery(con, sprintf(
    "SELECT count(*) n, count(DISTINCT user_id) d FROM %s", rp(nm[2])))
  if (u$n != u$d) {
    stop(nm[1], " tem ", u$n, " linhas para ", u$d,
         " user_id distintos. O join inflaria.")
  }
}

# Toda linha do produto rsid tem pelo menos um dos dois bracos ligado
# -- e assim que o 8g monta o arquivo. Se deixar de ser, o conjunto de
# chaves abaixo passa a incluir gente sem flag nenhuma.
z <- dbGetQuery(con, sprintf(
  "SELECT count(*) n FROM %s WHERE coalesce(rd_rsid_any,0)=0
                               AND coalesce(sh_rsid_any,0)=0", rp(rs_path)))$n
if (z != 0) stop(z, " linhas do produto rsid sem nenhum braco ligado.")

####################################################################
### B -- o conjunto de chaves, e so depois os atributos
####################################################################

# Chaves primeiro, LEFT JOIN depois, em vez da cadeia de FULL OUTER
# JOIN do script 21. Faz a mesma coisa e tira do caminho o coalesce
# encadeado na chave, que a nota do script 21 descreve como
# obrigatorio justamente porque e facil de errar.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE keys AS
  SELECT user_id FROM %s UNION
  SELECT user_id FROM %s UNION
  SELECT user_id FROM %s UNION
  SELECT user_id FROM %s",
  rp(sh_path), rp(rs_path), rp(ac_path), rp(fm_path)))

n_keys <- dbGetQuery(con, "SELECT count(*) n FROM keys")$n
cat("\nselecionados         :", format(n_keys, big.mark = ","), "\n")

####################################################################
### C -- os tres bracos de Xangai, empilhados (nota 4)
####################################################################

# Uma linha por (usuario, nivel, braco). O filtro pela flag do nivel E
# pelo rank nao nulo e o que impede um nivel vazio de virar linha.
arm <- function(src, pre) paste(vapply(
  c(bachelor = "bach", master = "mast", phd = "phd"),
  function(lv) {
    full <- c(bach = "bachelor", mast = "master", phd = "phd")[[lv]]
    sprintf("SELECT user_id, '%s' AS lvl, %s_%s_rank AS rk,
                    %s_%s_inst AS inst, %s_%s_year AS yr
             FROM %s WHERE coalesce(%s_%s, 0) = 1 AND %s_%s_rank IS NOT NULL",
            full, pre, lv, pre, lv, pre, lv, src, pre, full, pre, lv)
  }, character(1)), collapse = "\n    UNION ALL\n    ")

dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE sh_long AS
    %s
    UNION ALL
    %s
    UNION ALL
    %s",
  arm(rp(sh_path), "sh"),
  arm(rp(rs_path), "sh_rsid"),
  arm(rp(ac_path), "sh_acr")))

cat("linhas empilhadas    :",
    format(dbGetQuery(con, "SELECT count(*) n FROM sh_long")$n,
           big.mark = ","), "\n")

dbExecute(con, "
  CREATE OR REPLACE TABLE sh_lv AS
  SELECT user_id,
         CAST(min(rk) AS INTEGER)                                 AS sh_best_rank,
         CAST(min(rk) FILTER (WHERE lvl='bachelor') AS INTEGER)   AS sh_bach_rank,
         CAST(min(rk) FILTER (WHERE lvl='master')   AS INTEGER)   AS sh_mast_rank,
         CAST(min(rk) FILTER (WHERE lvl='phd')      AS INTEGER)   AS sh_phd_rank,
         arg_min(inst, rk) FILTER (WHERE lvl='bachelor')          AS sh_bach_inst,
         arg_min(inst, rk) FILTER (WHERE lvl='master')            AS sh_mast_inst,
         arg_min(inst, rk) FILTER (WHERE lvl='phd')               AS sh_phd_inst,
         CAST(min(yr) FILTER (WHERE lvl='bachelor') AS INTEGER)   AS sh_bach_year,
         CAST(min(yr) FILTER (WHERE lvl='master')   AS INTEGER)   AS sh_mast_year,
         CAST(min(yr) FILTER (WHERE lvl='phd')      AS INTEGER)   AS sh_phd_year
  FROM sh_long GROUP BY user_id")

####################################################################
### D -- a tabela larga
####################################################################

dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE sel AS
  SELECT k.user_id,

         CAST(s.user_id IS NOT NULL AS INTEGER)            AS in_shanghai,
         CAST(d.user_id IS NOT NULL AS INTEGER)            AS in_ruf_deg,
         CAST(f.user_id IS NOT NULL AS INTEGER)            AS in_firms,
         CAST(r.user_id IS NOT NULL AS INTEGER)            AS in_rsid_deg,
         CAST(a.user_id IS NOT NULL AS INTEGER)            AS in_sh_acr,

         -- sh_ ALARGADO: uniao dos tres bracos (nota 1)
         CAST(greatest(coalesce(s.sh_any,      0),
                       coalesce(r.sh_rsid_any, 0),
                       coalesce(a.sh_acr_any,  0)) AS INTEGER) AS sh_any,
         CAST(greatest(coalesce(s.sh_bachelor,      0),
                       coalesce(r.sh_rsid_bachelor, 0),
                       coalesce(a.sh_acr_bachelor,  0)) AS INTEGER) AS sh_bachelor,
         CAST(greatest(coalesce(s.sh_master,      0),
                       coalesce(r.sh_rsid_master, 0),
                       coalesce(a.sh_acr_master,  0)) AS INTEGER) AS sh_master,
         CAST(greatest(coalesce(s.sh_phd,      0),
                       coalesce(r.sh_rsid_phd, 0),
                       coalesce(a.sh_acr_phd,  0)) AS INTEGER)     AS sh_phd,
         v.sh_best_rank,
         v.sh_bach_rank, v.sh_bach_inst, v.sh_bach_year,
         v.sh_mast_rank, v.sh_mast_inst, v.sh_mast_year,
         v.sh_phd_rank,  v.sh_phd_inst,  v.sh_phd_year,

         -- procedencia de Xangai (nota 3)
         CAST(coalesce(s.sh_any,      0) AS INTEGER)       AS sh_name_any,
         CAST(coalesce(r.sh_rsid_any, 0) AS INTEGER)       AS sh_rsid_any,
         CAST(coalesce(a.sh_acr_any,  0) AS INTEGER)       AS sh_acr_any,

         -- rd_ SUBSTITUIDO: so o braco rsid (nota 1)
         CAST(coalesce(r.rd_rsid_any,      0) AS INTEGER)  AS rd_any,
         CAST(coalesce(r.rd_rsid_bachelor, 0) AS INTEGER)  AS rd_bachelor,
         CAST(coalesce(r.rd_rsid_master,   0) AS INTEGER)  AS rd_master,
         CAST(coalesce(r.rd_rsid_phd,      0) AS INTEGER)  AS rd_phd,
         r.rd_rsid_best_rank                               AS rd_best_rank,
         r.rd_rsid_bach_inst AS rd_bach_inst, r.rd_rsid_bach_year AS rd_bach_year,
         r.rd_rsid_mast_inst AS rd_mast_inst, r.rd_rsid_mast_year AS rd_mast_year,
         r.rd_rsid_phd_inst  AS rd_phd_inst,  r.rd_rsid_phd_year  AS rd_phd_year,

         -- procedencia do RUF (nota 3)
         CAST(coalesce(d.rd_any,      0) AS INTEGER)       AS rd_name_any,
         CAST(coalesce(d.rd_abbr_any, 0) AS INTEGER)       AS rd_abbr_any,

         CAST(coalesce(f.un_any, 0) AS INTEGER)            AS un_any,
         f.un_best_rank, f.un_best_firm, f.un_first_year,
         CAST(coalesce(f.tc_any, 0) AS INTEGER)            AS tc_any,
         f.tc_best_rank, f.tc_best_firm, f.tc_first_year,
         CAST(coalesce(f.rf_any, 0) AS INTEGER)            AS rf_any,
         f.rf_best_rank, f.rf_best_inst, f.rf_first_year,
         CAST(coalesce(f.sw_any, 0) AS INTEGER)            AS sw_any,
         f.sw_best_rank, f.sw_best_inst, f.sw_first_year
  FROM keys k
  LEFT JOIN %s s ON s.user_id = k.user_id
  LEFT JOIN %s d ON d.user_id = k.user_id
  LEFT JOIN %s f ON f.user_id = k.user_id
  LEFT JOIN %s r ON r.user_id = k.user_id
  LEFT JOIN %s a ON a.user_id = k.user_id
  LEFT JOIN sh_lv v ON v.user_id = k.user_id",
  rp(sh_path), rp(rd_path), rp(fm_path), rp(rs_path), rp(ac_path)))

n_sel <- dbGetQuery(con, "SELECT count(*) n FROM sel")$n
if (n_sel != n_keys) {
  stop("sel tem ", n_sel, " linhas para ", n_keys,
       " chaves. Algum LEFT JOIN inflou.")
}

####################################################################
### E -- os nomes
####################################################################

cat("\n=========== NOMES ===========\n")
cat("varrendo os 20 chunks (15,2 GB)...\n")
t0 <- Sys.time()
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE nm AS
  SELECT l.user_id, l.fullname
  FROM read_parquet('%s') l
  SEMI JOIN sel s ON l.user_id = s.user_id", fw(lk_glob)))
cat(sprintf("  concluido em %.1f min\n",
            as.numeric(difftime(Sys.time(), t0, units = "mins"))))

nmv <- dbGetQuery(con, "SELECT count(*) AS n, count(DISTINCT user_id) AS d FROM nm")
if (nmv$n != nmv$d) {
  stop("nm tem ", nmv$n, " linhas para ", nmv$d, " user_id distintos. ",
       "Os chunks de nome nao sao unicos por usuario; o join inflaria.")
}
cat("nomes encontrados:", format(nmv$n, big.mark = ","), "\n")

dbExecute(con, "
  CREATE OR REPLACE TABLE saida AS
  SELECT s.user_id, n.fullname, s.* EXCLUDE (user_id)
  FROM sel s LEFT JOIN nm n ON s.user_id = n.user_id")

####################################################################
### Validacao
####################################################################

cat("\n=========== VALIDACAO ===========\n")

v <- dbGetQuery(con, "
  SELECT count(*)                                          AS n_rows,
         count(DISTINCT user_id)                           AS n_uid,
         sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END)  AS uid_null,
         sum(CASE WHEN in_shanghai = 0 AND in_firms = 0
                   AND in_rsid_deg = 0 AND in_sh_acr = 0
                  THEN 1 ELSE 0 END)                       AS bad_none,
         sum(CASE WHEN in_shanghai = 1 AND sh_name_any <> 1
                  THEN 1 ELSE 0 END)                       AS bad_sh,
         sum(CASE WHEN in_ruf_deg = 1 AND rd_name_any <> 1
                  THEN 1 ELSE 0 END)                       AS bad_rd,
         sum(CASE WHEN in_sh_acr = 1 AND sh_acr_any <> 1
                  THEN 1 ELSE 0 END)                       AS bad_ac,
         sum(CASE WHEN in_firms = 1 AND un_any = 0 AND tc_any = 0
                   AND rf_any = 0 AND sw_any = 0
                  THEN 1 ELSE 0 END)                       AS bad_fm,
         sum(CASE WHEN sh_any <> greatest(sh_name_any, sh_rsid_any, sh_acr_any)
                  THEN 1 ELSE 0 END)                       AS bad_union,
         sum(CASE WHEN sh_name_any > sh_any THEN 1 ELSE 0 END) AS bad_narrow,
         sum(CASE WHEN sh_any = 1 AND sh_bachelor = 0 AND sh_master = 0
                   AND sh_phd = 0 AND sh_best_rank IS NOT NULL
                  THEN 1 ELSE 0 END)                       AS bad_lvl,
         sum(CASE WHEN sh_best_rank IS NULL AND (sh_bach_inst IS NOT NULL
                   OR sh_mast_inst IS NOT NULL OR sh_phd_inst IS NOT NULL)
                  THEN 1 ELSE 0 END)                       AS bad_inst,
         sum(CASE WHEN fullname IS NOT NULL THEN 1 ELSE 0 END) AS n_named
  FROM saida")
print(as.data.frame(v[, c("n_rows", "n_uid", "uid_null", "bad_none", "bad_sh",
                          "bad_rd", "bad_ac", "bad_fm", "bad_union",
                          "bad_narrow", "bad_lvl", "bad_inst")]),
      row.names = FALSE)

if (v$n_rows != n_sel) {
  stop("O join de nome inflou de ", n_sel, " para ", v$n_rows, " linhas.")
}
if (v$n_rows != v$n_uid) stop("user_id duplicado na saida.")
if (v$uid_null != 0)     stop("user_id nulo na saida.")
if (v$bad_none != 0) {
  stop(v$bad_none, " linhas sem nenhum marcador de presenca dos QUATRO que ",
       "definem a selecao. in_ruf_deg nao conta: e procedencia, nao ",
       "criterio, e um usuario so do script 20 nao entra nesta tabela.")
}
# Re-confere "so usuarios marcados sao escritos" em cada produto.
if (v$bad_sh != 0) stop(v$bad_sh, " linhas com in_shanghai = 1 e sh_name_any <> 1.")
if (v$bad_rd != 0) stop(v$bad_rd, " linhas com in_ruf_deg = 1 e rd_name_any <> 1.")
if (v$bad_ac != 0) stop(v$bad_ac, " linhas com in_sh_acr = 1 e sh_acr_any <> 1.")
if (v$bad_fm != 0) {
  stop(v$bad_fm, " linhas com in_firms = 1 e nenhum dos quatro bracos de emprego.")
}
# A definicao alargada tem de ser exatamente a uniao, e nunca menor que
# a estreita. Isto e o que pegaria um greatest() escrito errado.
if (v$bad_union != 0) {
  stop(v$bad_union, " linhas onde sh_any nao e a uniao dos tres bracos.")
}
if (v$bad_narrow != 0) {
  stop(v$bad_narrow, " linhas com sh_name_any = 1 e sh_any = 0. O ",
       "alargamento esta REMOVENDO gente em vez de acrescentar.")
}
if (v$bad_lvl != 0) {
  stop(v$bad_lvl, " linhas com rank de Xangai e nenhuma flag de nivel.")
}
if (v$bad_inst != 0) {
  stop(v$bad_inst, " linhas com instituicao de Xangai e sem rank.")
}

# rd_ tem de ser exatamente o braco rsid, sem residuo do script 20.
bad_rdrep <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM saida o
  LEFT JOIN %s r ON r.user_id = o.user_id
  WHERE o.rd_any <> coalesce(r.rd_rsid_any, 0)", rp(rs_path)))$n
if (bad_rdrep != 0) {
  stop(bad_rdrep, " linhas onde rd_any nao e o braco rsid. A ",
       "substituicao esta incompleta.")
}

# Todo user_id da saida tem de estar na coorte.
orf <- dbGetQuery(con, sprintf("
  SELECT (SELECT count(*) FROM %1$s) AS n_cohort,
         (SELECT count(*) FROM saida o
          WHERE NOT EXISTS (SELECT 1 FROM %1$s c
                            WHERE c.user_id = o.user_id)) AS n_orphan",
  rp(cand_path)))
if (orf$n_orphan != 0) {
  stop(orf$n_orphan, " user_id da saida nao estao em ", basename(cand_path), ".")
}
if (orf$n_cohort != exp_cohort) {
  stop("A coorte tem ", orf$n_cohort, " linhas, nao ", exp_cohort, ".")
}

chk <- function(nome, obtido, esperado) {
  if (obtido != esperado) {
    warning(nome, ": ", format(obtido, big.mark = ","), " (esperado ",
            format(esperado, big.mark = ","), ")", call. = FALSE)
  }
}
chk("shanghai",    n_sh, exp_shanghai)
chk("ruf degree",  n_rd, exp_ruf_deg)
chk("firms",       n_fm, exp_firms)
chk("rsid degree", n_rs, exp_rsid)
chk("acronimo",    n_ac, exp_acr)
chk("linhas",      v$n_rows, exp_rows)

####################################################################
### Escrita e releitura
####################################################################

dbExecute(con, sprintf(
  "COPY (SELECT * FROM saida ORDER BY user_id) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_path)))

df <- arrow::open_dataset(out_path, format = "parquet")
stopifnot(identical(names(df), c(
  "user_id", "fullname",
  "in_shanghai", "in_ruf_deg", "in_firms", "in_rsid_deg", "in_sh_acr",
  "sh_any", "sh_bachelor", "sh_master", "sh_phd", "sh_best_rank",
  "sh_bach_rank", "sh_bach_inst", "sh_bach_year",
  "sh_mast_rank", "sh_mast_inst", "sh_mast_year",
  "sh_phd_rank",  "sh_phd_inst",  "sh_phd_year",
  "sh_name_any", "sh_rsid_any", "sh_acr_any",
  "rd_any", "rd_bachelor", "rd_master", "rd_phd", "rd_best_rank",
  "rd_bach_inst", "rd_bach_year", "rd_mast_inst", "rd_mast_year",
  "rd_phd_inst", "rd_phd_year",
  "rd_name_any", "rd_abbr_any",
  "un_any", "un_best_rank", "un_best_firm", "un_first_year",
  "tc_any", "tc_best_rank", "tc_best_firm", "tc_first_year",
  "rf_any", "rf_best_rank", "rf_best_inst", "rf_first_year",
  "sw_any", "sw_best_rank", "sw_best_inst", "sw_first_year")))
stopifnot(nrow(df) == v$n_rows, length(names(df)) == 53L)

####################################################################
### Relatorio
####################################################################

cat("\n=========== O VENN DA SELECAO ===========\n")
print(dbGetQuery(con, "
  SELECT in_shanghai, in_rsid_deg, in_sh_acr, in_firms, count(*) AS users
  FROM saida GROUP BY 1, 2, 3, 4 ORDER BY users DESC LIMIT 16"),
  row.names = FALSE)

cat("\n=========== COBERTURA DE NOME (script 21, nota 4) ===========\n")
cat(sprintf("  %s de %s  (%.2f%%)\n", format(v$n_named, big.mark = ","),
            format(v$n_rows, big.mark = ","), 100 * v$n_named / v$n_rows))

cat("\n=========== AS FLAGS DE CABECA ===========\n")
print(dbGetQuery(con, "
  SELECT sum(sh_any) sh_any, sum(rd_any) rd_any,
         sum(un_any) un_any, sum(tc_any) tc_any,
         sum(rf_any) rf_any, sum(sw_any) sw_any,
         sum(CASE WHEN sh_any=1 OR rd_any=1 THEN 1 ELSE 0 END) AS estudou_alguma,
         sum(CASE WHEN un_any=1 OR tc_any=1 OR rf_any=1 OR sw_any=1
                  THEN 1 ELSE 0 END)                           AS trabalhou_alguma
  FROM saida"), row.names = FALSE)

cat("\n=========== PROCEDENCIA (nota 3) ===========\n")
print(dbGetQuery(con, "
  SELECT sum(sh_name_any) AS sh_name_any, sum(sh_rsid_any) AS sh_rsid_any,
         sum(sh_acr_any)  AS sh_acr_any,  sum(sh_any)      AS sh_any_uniao,
         sum(rd_name_any) AS rd_name_any, sum(rd_any)      AS rd_any_rsid
  FROM saida"), row.names = FALSE)

chk("sh_any", dbGetQuery(con, "SELECT sum(sh_any) n FROM saida")$n, exp_sh_any)
chk("rd_any", dbGetQuery(con, "SELECT sum(rd_any) n FROM saida")$n, exp_rd_any)

####################################################################
### Comparacao com a tabela canonica
####################################################################

if (file.exists(old_path)) {
  cat("\n=========== CONTRA obmep_candidates_selected.parquet ===========\n")
  cmp <- dbGetQuery(con, sprintf("
    SELECT (SELECT count(*) FROM %1$s)                        AS canonica,
           (SELECT count(*) FROM saida)                       AS alternativa,
           (SELECT count(*) FROM saida o WHERE NOT EXISTS
              (SELECT 1 FROM %1$s c WHERE c.user_id = o.user_id)) AS entram,
           (SELECT count(*) FROM %1$s c WHERE NOT EXISTS
              (SELECT 1 FROM saida o WHERE o.user_id = c.user_id)) AS saem",
    rp(old_path)))
  print(cmp, row.names = FALSE)

  # Quem sai tem de sair pelo motivo previsto: so tinha a flag do RUF
  # por nome. Qualquer outro motivo e a substituicao derrubando gente
  # que ela nao deveria.
  why <- dbGetQuery(con, sprintf("
    SELECT sum(CASE WHEN c.rd_any = 1 AND c.sh_any = 0 AND c.un_any = 0
                     AND c.tc_any = 0 AND c.rf_any = 0 AND c.sw_any = 0
                    THEN 1 ELSE 0 END) AS so_rd_nome,
           count(*)                    AS total
    FROM %s c WHERE NOT EXISTS
      (SELECT 1 FROM saida o WHERE o.user_id = c.user_id)", rp(old_path)))
  cat("  quem sai, so com a flag rd_ por nome:",
      format(why$so_rd_nome, big.mark = ","), "de", format(why$total, big.mark = ","), "\n")
  if (why$so_rd_nome != why$total) {
    stop(why$total - why$so_rd_nome, " pessoas saem da selecao por um motivo ",
         "que nao e a substituicao do RUF. Investigue antes de usar a tabela.")
  }
}

# A tabela canonica nao pode ter sido tocada.
if (!is.null(old_sig)) {
  now <- c(size = file.info(old_path)$size,
           mtime = as.numeric(file.info(old_path)$mtime))
  if (!isTRUE(all.equal(old_sig, now))) {
    stop("obmep_candidates_selected.parquet MUDOU durante esta execucao. ",
         "Este script nunca deve escrever nela.")
  }
  cat("\n  canonica intacta (", format(file.info(old_path)$mtime), ")\n", sep = "")
}

cat("\n=========== RESUMO ===========\n")
cat(sprintf("  %-44s %10s linhas  %6.1f MB\n", basename(out_path),
            format(v$n_rows, big.mark = ","), file.info(out_path)$size / 2^20))
cat("  em ", coh_dir, "\n", sep = "")
cat(sprintf("  coorte de %s; %.2f%% dela fica selecionada\n",
            format(exp_cohort, big.mark = ","),
            100 * v$n_rows / exp_cohort))
