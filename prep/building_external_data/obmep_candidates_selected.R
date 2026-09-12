####################################################################
###
### Candidatos selecionados: os tres produtos de flag, unidos,   -> Dropbox
### com o nome de cada pessoa
###
### Uma linha por usuario que foi marcado por QUALQUER um dos tres
### produtos de flag, carregando as colunas de cabeca de cada um mais o
### `fullname` do perfil.
###
### A UNIAO E A SELECAO, NAO HA FILTRO. Os tres produtos escrevem SO
### usuarios marcados -- shanghai_top1000_degree_flags.R poe o literal
### 1 em sh_any, obmep_candidates_step_1_ruf_degree.R o mesmo em
### rd_any, obmep_candidates_step_1_firms.R em firm_any, e os tres
### abortam se alguma linha discordar. Logo "alguma flag e 1" nao e um
### WHERE capaz de excluir nada: ele E o conteudo dos arquivos. Por
### isso este script faz FULL OUTER JOIN e nao escreve filtro nenhum.
###
### Saida:
###   obmep_candidates_selected.parquet   uma linha por usuario
###                                       SELECIONADO, 48 colunas
###   ranked_university_work_any e a uniao explicita de rf_any/sw_any.
###
### Depends on:
###   shanghai_top1000_degree_flags.R        (sh_, 16)
###   obmep_candidates_step_1_ruf_degree.R   (rd_, 20)
###   obmep_candidates_step_1_firms.R        (un_/tc_/rf_/sw_, 19)
###   linkedin_names/linkedin_chunk_*.parquet (GTAllocation, os nomes)
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
###    das duas listas de instituicao e perguntada nas DUAS direcoes:
###
###      sh_  ESTUDOU   numa Shanghai top-1000   script 16
###      sw_  TRABALHOU numa Shanghai top-1000   script 19
###      rd_  ESTUDOU   numa RUF top-10 STEM     script 20
###      rf_  TRABALHOU numa RUF top-10 STEM     script 19
###
###    sh_ e sw_ compartilham a LISTA e diferem na PERGUNTA; rd_ e rf_
###    idem. Nada mais nesta tabela e tao facil de ler errado.
### 2. AS FLAGS DO LADO AUSENTE SAO 0; OS RANKS SAO NULL. Um usuario
###    que so aparece num dos tres produtos nao tem valor para as
###    colunas dos outros. As flags 0/1 recebem coalesce(...,0), para
###    que `sh_any = 1 OR rd_any = 1 OR sw_any = 1` se leia sem
###    armadilha de NULL. As colunas de rank, instituicao, empresa e
###    ano ficam NULL: nao existe zero para "sem rank", e 0 seria o
###    MELHOR rank possivel, envenenando qualquer min() a jusante.
###    Elas ja sao anulaveis dentro dos proprios arquivos de origem
###    pela mesma razao.
### 3. in_shanghai / in_ruf_deg / in_firms SAO A VERDADE SOBRE
###    PRESENCA. O coalesce da nota 2 e conveniencia; quem precisa
###    saber de qual produto o usuario veio le os tres marcadores.
### 4. fullname NULL SIGNIFICA "AUSENTE DO SNAPSHOT", NAO "SEM NOME".
###    Os 20 chunks de nome sao de 2025-07-01 e a coorte foi
###    reconstruida em agosto de 2026, entao uma lacuna de cobertura e
###    esperada. O join e LEFT de proposito: um usuario sem nome
###    mantem as flags e recebe NULL, nunca sai da selecao.
### 5. O NOME E GUARDADO EXATAMENTE COMO CHEGA. A fonte e global e
###    multi-script (CJK, cirilico) e nao e normalizada em caixa. Nada
###    disso importa aqui, porque este e um join exato por inteiro,
###    nao um casamento de nome. Nao limpe a coluna.
### 6. AS COLUNAS ESTREITAS FICARAM PARA TRAS, DE PROPOSITO. A pasta
###    guarda a versao estreita de cada definicao alargada para que um
###    corte possa ser APERTADO com um WHERE em vez de um rebuild.
###    Esta tabela leva so a flag de cabeca de cada conceito mais
###    rank/instituicao/ano. Nada se perde -- os tres arquivos de
###    origem seguem com tudo, chaveados por user_id -- mas apertar
###    uma definicao aqui exige re-juntar, nao filtrar. As que ficaram
###    de fora sao un_/tc_/rf_/sw_ _exact _parent _arm3 _raw, os
###    sh_/rd_ _raw_any _master_strict _lato, e todos os n_*.
### 7. ESTA E A UNICA TABELA DA PASTA COM DADO PESSOAL DIRETO. Os
###    outros produtos sao user_id e flags; esta carrega o nome civil.
###    Trate-a como tal.
###
### -----------------------------------------------------------------
### MEASURED, RCID employer rebuild of 2026-09-09
### -----------------------------------------------------------------
###   entradas   sh_ 1,140,993   rd_ 701,930   firms 484,890
###   SELECIONADOS              1,468,102   -- 21.43% da coorte
###   com fullname              1,467,285   -- 99.94%
###
###   O VENN DOS TRES:
###     so sh_                  430,647
###     sh_ + rd_               444,810
###     so firms                198,271
###     sh_ + firms             137,254
###     os tres                 128,282
###     so rd_                  107,755
###     rd_ + firms              21,083
###
###   estudou em alguma      1,269,831
###   trabalhou em alguma      484,890
###     sh_ 1,140,993  rd_ 701,930
###     un_ 28,735  tc_ 159,638  rf_ 66,683  sw_ 296,596
###     ranked_university_work_any 316,929
###
###   A COBERTURA DE NOME E DE 99,94%, e uniforme entre os tres
###   marcadores (99,94 / 99,90 / 99,94). A lacuna de versao entre o
###   snapshot de 2025-07 e a coorte de 2026-08 (nota 4) existe mas e
###   de 817 pessoas, nao o buraco que se poderia temer. Cobertura
###   perto de zero significaria que os dois lados nao compartilham
###   espaco de user_id -- investigue, nao remende.
###
###   Os cinco produtos foram validados juntos e publicados por 19a;
###   veja ranked_university_work_{rebuild,publication}_report.json.
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
gt_root    <- Sys.getenv("GT_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/GTAllocation")

coh_dir   <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
sh_path   <- file.path(coh_dir, "obmep_candidates_step_1_shanghai.parquet")
rd_path   <- file.path(coh_dir, "obmep_candidates_step_1_ruf_degree.parquet")
fm_path   <- Sys.getenv("OBMEP_SELECTED_FIRMS_PATH",
                        unset = file.path(coh_dir, "obmep_candidates_step_1_firms.parquet"))
cand_path <- file.path(coh_dir, "obmep_candidates_step_1.parquet")

lk_dir    <- file.path(gt_root, "Data/intermediate/fuzzy_match/linkedin_names")

out_path  <- Sys.getenv("OBMEP_SELECTED_OUT",
                        unset = file.path(coh_dir, "obmep_candidates_selected.parquet"))

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")

# Medidos contra os tres produtos atuais. Divergencia aqui significa
# que uma das entradas foi reconstruida -- warning, nao stop.
exp_shanghai <- 1140993L
exp_ruf_deg  <- 701930L
exp_firms    <- 484890L

# Tamanho da coorte de origem. Deterministico: aborta em vez de avisar.
exp_cohort <- 6849674L

# Os 20 chunks de nome, medidos no linkedin_br_name_flag.R.
exp_lk_rows <- 708365562

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_selected")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

for (f in c(sh_path, rd_path, fm_path, cand_path)) {
  if (!file.exists(f)) stop("Nao encontrei ", f)
}
if (!dir.exists(lk_dir)) stop("Nao encontrei o diretorio de nomes ", lk_dir)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# temp_directory explicito e OBRIGATORIO aqui: a varredura de 15,2 GB
# dos nomes derrama para disco, e o derrame nao pode cair em pasta
# sincronizada pelo Dropbox.
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))
dbExecute(con, "SET preserve_insertion_order=false")

fw <- function(p) gsub("\\\\", "/", p)

cat("DuckDB   :", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("shanghai :", basename(sh_path), "\n")
cat("ruf_deg  :", basename(rd_path), "\n")
cat("firms    :", basename(fm_path), "\n")
cat("nomes    :", lk_dir, "\n")
cat("saida    :", out_path, "\n\n")

lk_glob <- file.path(lk_dir, "linkedin_chunk_*.parquet")

####################################################################
### A -- a uniao dos tres produtos
####################################################################

cat("=========== UNIAO ===========\n")

n_sh <- dbGetQuery(con, sprintf("SELECT count(*) n FROM read_parquet('%s')", fw(sh_path)))$n
n_rd <- dbGetQuery(con, sprintf("SELECT count(*) n FROM read_parquet('%s')", fw(rd_path)))$n
n_fm <- dbGetQuery(con, sprintf("SELECT count(*) n FROM read_parquet('%s')", fw(fm_path)))$n
cat("shanghai (sh_)  :", format(n_sh, big.mark = ","), "\n")
cat("ruf degree (rd_):", format(n_rd, big.mark = ","), "\n")
cat("firms (worked)  :", format(n_fm, big.mark = ","), "\n")

# coalesce explicito na chave em vez de USING (user_id): USING tambem
# coalesceria certo no DuckDB, mas a forma explicita sobrevive a
# alguem trocar o tipo do join depois, e custa uma linha.
#
# O coalesce no SEGUNDO predicado e OBRIGATORIO, nao estilo: depois do
# primeiro full outer join, s.user_id e NULL para todo usuario que so
# tem diploma do RUF, e juntar por s.user_id sozinho descartaria em
# silencio as flags de emprego dessas pessoas.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE sel AS
  SELECT coalesce(s.user_id, r.user_id, f.user_id)         AS user_id,
         CAST(s.user_id IS NOT NULL AS INTEGER)            AS in_shanghai,
         CAST(r.user_id IS NOT NULL AS INTEGER)            AS in_ruf_deg,
         CAST(f.user_id IS NOT NULL AS INTEGER)            AS in_firms,

         CAST(coalesce(s.sh_any,      0) AS INTEGER)       AS sh_any,
         CAST(coalesce(s.sh_bachelor, 0) AS INTEGER)       AS sh_bachelor,
         CAST(coalesce(s.sh_master,   0) AS INTEGER)       AS sh_master,
         CAST(coalesce(s.sh_phd,      0) AS INTEGER)       AS sh_phd,
         s.sh_best_rank, s.sh_bach_rank, s.sh_bach_inst, s.sh_bach_year,
         s.sh_mast_rank, s.sh_mast_inst, s.sh_mast_year,
         s.sh_phd_rank,  s.sh_phd_inst,  s.sh_phd_year,

         CAST(coalesce(r.rd_any,      0) AS INTEGER)       AS rd_any,
         CAST(coalesce(r.rd_abbr_any, 0) AS INTEGER)       AS rd_abbr_any,
         CAST(coalesce(r.rd_bachelor, 0) AS INTEGER)       AS rd_bachelor,
         CAST(coalesce(r.rd_master,   0) AS INTEGER)       AS rd_master,
         CAST(coalesce(r.rd_phd,      0) AS INTEGER)       AS rd_phd,
         r.rd_best_rank,
         r.rd_bach_inst, r.rd_bach_year,
         r.rd_mast_inst, r.rd_mast_year,
         r.rd_phd_inst,  r.rd_phd_year,

         CAST(coalesce(f.un_any, 0) AS INTEGER)            AS un_any,
         f.un_best_rank, f.un_best_firm, f.un_first_year,
         CAST(coalesce(f.tc_any, 0) AS INTEGER)            AS tc_any,
         f.tc_best_rank, f.tc_best_firm, f.tc_first_year,
         CAST(coalesce(f.rf_any, 0) AS INTEGER)            AS rf_any,
         f.rf_best_rank, f.rf_best_inst, f.rf_first_year,
         CAST(coalesce(f.sw_any, 0) AS INTEGER)            AS sw_any,
         f.sw_best_rank, f.sw_best_inst, f.sw_first_year,
         CAST(coalesce(f.ranked_university_work_any, 0) AS INTEGER)
                                                              AS ranked_university_work_any
  FROM            read_parquet('%s') s
  FULL OUTER JOIN read_parquet('%s') r ON s.user_id = r.user_id
  FULL OUTER JOIN read_parquet('%s') f
               ON coalesce(s.user_id, r.user_id) = f.user_id",
  fw(sh_path), fw(rd_path), fw(fm_path)))

n_sel <- dbGetQuery(con, "SELECT count(*) n FROM sel")$n

# A uniao contada de forma independente. Se este numero divergir de
# n_sel, algum lado do full outer join perdeu ou duplicou linha.
n_union <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM (
    SELECT user_id FROM read_parquet('%s')
    UNION
    SELECT user_id FROM read_parquet('%s')
    UNION
    SELECT user_id FROM read_parquet('%s'))",
  fw(sh_path), fw(rd_path), fw(fm_path)))$n

cat("uniao           :", format(n_sel, big.mark = ","), "\n")
if (n_sel != n_union) {
  stop("A uniao tem ", n_sel, " linhas mas os tres conjuntos de chave ",
       "somam ", n_union, " distintos. O full outer join esta errado.")
}

####################################################################
### B -- os nomes
####################################################################

# SEMI JOIN em vez de juntar depois: o lado construido tem ~1,2M
# linhas e o semi-join impede que as ~707M restantes se materializem.
# Ainda assim le os 15,2 GB, porque os arquivos tem SO estas duas
# colunas e nao ha poda de coluna a explorar. E o passo mais caro.
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

# linkedin_br_name_flag.R ja reconcilia 708.365.562 linhas contra
# 708.365.562 usuarios distintos e aborta em fan-out, mas aquela
# checagem rodou sobre OUTRA saida. Re-afirmar aqui, sobre ~1,2M
# linhas, nao custa nada e e a unica coisa entre um user_id duplicado
# na origem e um resultado inflado em silencio.
nmv <- dbGetQuery(con, "
  SELECT count(*) AS n, count(DISTINCT user_id) AS d FROM nm")
if (nmv$n != nmv$d) {
  stop("nm tem ", nmv$n, " linhas para ", nmv$d, " user_id distintos. ",
       "Os chunks de nome nao sao unicos por usuario; o join inflaria.")
}
cat("nomes encontrados:", format(nmv$n, big.mark = ","), "\n")

# LEFT, nao INNER: um usuario ausente do snapshot de nomes mantem as
# flags e recebe fullname NULL (nota 4). Nunca sai da selecao.
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
         sum(CASE WHEN in_shanghai = 0 AND in_ruf_deg = 0
                   AND in_firms = 0 THEN 1 ELSE 0 END)     AS bad_none,
         sum(CASE WHEN in_shanghai = 1 AND sh_any <> 1
                  THEN 1 ELSE 0 END)                       AS bad_sh,
         sum(CASE WHEN in_ruf_deg = 1 AND rd_any <> 1
                  THEN 1 ELSE 0 END)                       AS bad_rd,
         sum(CASE WHEN in_firms = 1 AND un_any = 0 AND tc_any = 0
                   AND rf_any = 0 AND sw_any = 0
                  THEN 1 ELSE 0 END)                       AS bad_fm,
         sum(CASE WHEN ranked_university_work_any <>
                            greatest(rf_any, sw_any)
                  THEN 1 ELSE 0 END)                       AS bad_ranked_union,
         sum(CASE WHEN fullname IS NOT NULL THEN 1 ELSE 0 END) AS n_named
  FROM saida")
print(as.data.frame(v[, c("n_rows", "n_uid", "uid_null", "bad_none",
                          "bad_sh", "bad_rd", "bad_fm")]), row.names = FALSE)

if (v$n_rows != n_sel) {
  stop("O join de nome inflou de ", n_sel, " para ", v$n_rows, " linhas.")
}
if (v$n_rows != v$n_uid) stop("user_id duplicado na saida.")
if (v$uid_null != 0)     stop("user_id nulo na saida.")
if (v$bad_none != 0) {
  stop(v$bad_none, " linhas sem nenhum marcador de presenca. Impossivel ",
       "por construcao: o join esta errado.")
}
# Isto e o que RE-CONFERE a propriedade "so usuarios marcados sao
# escritos" nos tres produtos de origem, e e a assercao que pegaria um
# rebuild malfeito do script 19.
if (v$bad_sh != 0) stop(v$bad_sh, " linhas com in_shanghai = 1 e sh_any <> 1.")
if (v$bad_rd != 0) stop(v$bad_rd, " linhas com in_ruf_deg = 1 e rd_any <> 1.")
if (v$bad_fm != 0) {
  stop(v$bad_fm, " linhas com in_firms = 1 e nenhum dos quatro bracos ",
       "de emprego ligado.")
}
if (v$bad_ranked_union != 0) {
  stop(v$bad_ranked_union,
       " rows disagree with ranked_university_work_any = rf_any OR sw_any.")
}

# Todo user_id da saida tem de estar na coorte.
orf <- dbGetQuery(con, sprintf("
  SELECT (SELECT count(*) FROM read_parquet('%1$s')) AS n_cohort,
         (SELECT count(*) FROM saida o
          WHERE NOT EXISTS (SELECT 1 FROM read_parquet('%1$s') c
                            WHERE c.user_id = o.user_id)) AS n_orphan",
  fw(cand_path)))
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
chk("shanghai",   n_sh, exp_shanghai)
chk("ruf degree", n_rd, exp_ruf_deg)
chk("firms",      n_fm, exp_firms)

####################################################################
### Escrita e releitura
####################################################################

if (file.exists(out_path)) stop("Output already exists: ", out_path)
dir.create(dirname(out_path), recursive = TRUE, showWarnings = FALSE)
dbExecute(con, sprintf(
  "COPY (SELECT * FROM saida ORDER BY user_id) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_path)))

df <- arrow::open_dataset(out_path, format = "parquet")
stopifnot(identical(names(df), c(
  "user_id", "fullname", "in_shanghai", "in_ruf_deg", "in_firms",
  "sh_any", "sh_bachelor", "sh_master", "sh_phd", "sh_best_rank",
  "sh_bach_rank", "sh_bach_inst", "sh_bach_year",
  "sh_mast_rank", "sh_mast_inst", "sh_mast_year",
  "sh_phd_rank",  "sh_phd_inst",  "sh_phd_year",
  "rd_any", "rd_abbr_any", "rd_bachelor", "rd_master", "rd_phd",
  "rd_best_rank", "rd_bach_inst", "rd_bach_year",
  "rd_mast_inst", "rd_mast_year", "rd_phd_inst", "rd_phd_year",
  "un_any", "un_best_rank", "un_best_firm", "un_first_year",
  "tc_any", "tc_best_rank", "tc_best_firm", "tc_first_year",
  "rf_any", "rf_best_rank", "rf_best_inst", "rf_first_year",
  "sw_any", "sw_best_rank", "sw_best_inst", "sw_first_year",
  "ranked_university_work_any")))
stopifnot(nrow(df) == v$n_rows, length(names(df)) == 48L)

####################################################################
### Relatorio
####################################################################

cat("\n=========== O VENN DOS TRES PRODUTOS ===========\n")
print(dbGetQuery(con, "
  SELECT in_shanghai, in_ruf_deg, in_firms, count(*) AS users
  FROM saida GROUP BY 1, 2, 3 ORDER BY users DESC"), row.names = FALSE)

cat("\n=========== COBERTURA DE NOME (nota 4) ===========\n")
print(dbGetQuery(con, "
  SELECT 'total'                       AS grupo, count(*) AS users,
         sum(CASE WHEN fullname IS NOT NULL THEN 1 ELSE 0 END) AS com_nome,
         round(100.0 * sum(CASE WHEN fullname IS NOT NULL THEN 1 ELSE 0 END)
               / count(*), 2)          AS pct
  FROM saida
  UNION ALL
  SELECT 'in_shanghai', count(*), sum(CASE WHEN fullname IS NOT NULL THEN 1 ELSE 0 END),
         round(100.0 * sum(CASE WHEN fullname IS NOT NULL THEN 1 ELSE 0 END) / count(*), 2)
  FROM saida WHERE in_shanghai = 1
  UNION ALL
  SELECT 'in_ruf_deg', count(*), sum(CASE WHEN fullname IS NOT NULL THEN 1 ELSE 0 END),
         round(100.0 * sum(CASE WHEN fullname IS NOT NULL THEN 1 ELSE 0 END) / count(*), 2)
  FROM saida WHERE in_ruf_deg = 1
  UNION ALL
  SELECT 'in_firms', count(*), sum(CASE WHEN fullname IS NOT NULL THEN 1 ELSE 0 END),
         round(100.0 * sum(CASE WHEN fullname IS NOT NULL THEN 1 ELSE 0 END) / count(*), 2)
  FROM saida WHERE in_firms = 1"), row.names = FALSE)

cat("\n=========== AS OITO FLAGS DE CABECA ===========\n")
print(dbGetQuery(con, "
  SELECT sum(sh_any) sh_any, sum(rd_any) rd_any,
         sum(un_any) un_any, sum(tc_any) tc_any,
         sum(rf_any) rf_any, sum(sw_any) sw_any,
         sum(CASE WHEN sh_any=1 OR rd_any=1 THEN 1 ELSE 0 END) AS estudou_alguma,
         sum(CASE WHEN un_any=1 OR tc_any=1 OR rf_any=1 OR sw_any=1
                  THEN 1 ELSE 0 END)                           AS trabalhou_alguma
  FROM saida"), row.names = FALSE)

cat("\n=========== RESUMO ===========\n")
cat(sprintf("  %-40s %10s linhas  %6.1f MB\n", basename(out_path),
            format(v$n_rows, big.mark = ","), file.info(out_path)$size / 2^20))
cat("  em ", coh_dir, "\n", sep = "")
cat(sprintf("  coorte de %s; %.2f%% dela fica selecionada\n",
            format(exp_cohort, big.mark = ","),
            100 * v$n_rows / exp_cohort))
