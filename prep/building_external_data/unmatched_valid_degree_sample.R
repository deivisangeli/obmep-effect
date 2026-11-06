####################################################################
###
### Entradas com diploma valido que NAO receberam openalex_id
###                                           [local only, offline]
###
### 8q (global_oa_hierarchy.R) atribuiu um openalex_id
### ao university_raw das 19.710.307 linhas de educacao do coorte
### refrescado _degree_duration e deixou 6.063.272 sem resolver. Este
### script separa, desse residuo, so o que interessa: as entradas que
### de fato carregam um diploma reconhecido.
###
### -----------------------------------------------------------------
### AS DUAS DEFINICOES, E POR QUE SAO ESSAS
### -----------------------------------------------------------------
### DIPLOMA VALIDO e o nivel efetivo usado a jusante em
### ranked_education_flags.R:207-208:
###
###   CASE WHEN coalesce(degree,'empty')='empty' AND degree_matches_laxed=1
###        THEN 'bachelor' ELSE ranked_level END
###
### mantido quando cai em ('bachelor','master','phd'). NAO se filtra
### pela coluna `degree` da Revelio: o README mede isso em 58,4% de
### recall (secao "Revelio's degree is unreliable on Brazilian
### records").
###
### NAO CASADO e global_oa_selected_count = 0. Empate retido
### (selected_count > 1) e casamento, nao falha.
###
### -----------------------------------------------------------------
### DOIS GRAOS NO MESMO CADERNO, E ISSO E O PONTO
### -----------------------------------------------------------------
### A populacao e 2.380.198 linhas sobre so 582.781 grafias distintas.
### Uma amostra de 100 LINHAS e dominada pelas grafias frequentes e
### responde "como e uma entrada nao casada tipica". Uma amostra de 100
### GRAFIAS distintas responde "por que o casamento falhou". As duas
### perguntas sao diferentes, entao o caderno traz as duas abas, cada
### uma com o seu denominador declarado no Resumo.
###
### Produtos:
###   degree_duration_unmatched_valid_degree_sample.parquet  as chaves
###   degree_duration_unmatched_valid_degree_sample.xlsx     o caderno
###
### Depends on:
###   global_oa_hierarchy.R (8q) -- education_parts/
###
### Shape reused from:
###   unmatched_school_audit_sample.R (8j), capes_obmep_match_sample.R
###   (27a) e field_manual_review.R (10i) -- caderno openxlsx, aba de
###   rubrica, dominio escondido, saveWorkbook(overwrite = FALSE),
###   releitura.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK, NO ATHENA, NO S3. Le 30 parquets locais, escreve um
###    parquet e um xlsx. E prep/; nao vai para o SEDAP.
### 2. A PERGUNTA NAO E "O SCORER ERROU". 2.375.107 das 2.380.198
###    linhas sairam com CONJUNTO DE CANDIDATOS VAZIO. A falha e de
###    OFERTA de candidato, nao de pontuacao. A aba "Como ler" diz isso
###    na primeira tela, senao o revisor julga a coisa errada.
### 3. ORDER BY hash(...) LIMIT n, NUNCA USING SAMPLE. O DuckDB empurra
###    USING SAMPLE para baixo do filtro -- armadilha medida no README,
###    onde 500 linhas viraram 23.
### 4. UM SEED QUE NAO REPRODUZ E PIOR QUE NENHUM. As chaves dos dois
###    sorteios ficam estacionadas em parquet, a consulta e refeita a
###    cada execucao e conferida com setequal contra o estacionado.
### 5. NAO SOBRESCREVE O XLSX. Se o caderno existe, veredito e motivo
###    sao lidos de volta -- por (university_raw, pais) numa aba e por
###    (source_file, source_row) na outra -- e a remocao so acontece
###    depois de a anotacao estar em memoria.
### 6. user_id E int64. Sem as.character ele vira 1.23457E+15 na
###    planilha. Mesma armadilha do role_audit_review.R (10e).
### 7. TEXTO QUE COMECA COM = + - @ E FORMULA PARA O EXCEL. O openxlsx
###    grava string como shared string, que o Excel nao avalia. Aqui o
###    university_raw e texto livre do LinkedIn, entao a assercao final
###    e de IDENTIDADE no round trip (mais forte) e o aviso sobre
###    = + - @ e so um aviso, nao um stop.
### 8. AS DUAS ABAS TEM DENOMINADORES DIFERENTES. Nao existe "a taxa"
###    deste caderno. O Resumo declara as duas populacoes.
###
####################################################################

rm(list = ls()); gc()
options(width = 200)

for (p in c("DBI", "duckdb", "openxlsx")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}
library(DBI)
library(duckdb)
library(openxlsx)

####################################################################
### Parametros
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

edu_dir <- file.path(coh_dir, "global_oa_hierarchy",
                     "education_parts")

sample_path <- file.path(coh_dir,
  "degree_duration_unmatched_valid_degree_sample.parquet")
xlsx_path <- file.path(coh_dir,
  "degree_duration_unmatched_valid_degree_sample.xlsx")

seed <- 20260914L
n_draw <- 100L

verdict_domain <- c("existe_no_openalex", "nao_existe_no_openalex",
                    "nao_e_instituicao_de_ensino", "ilegivel", "duvidoso")

# Medidos em 2026-09-14 sobre education_parts/. Servem de trava: se o
# 8q for reconstruido por baixo, o sorteio para em vez de mudar calado.
exp_rows_pop  <- 2380198L
exp_users_pop <- 2108775L
exp_bachelor  <- 2107972L
exp_master    <- 258841L
exp_phd       <- 13385L
exp_nocand    <- 2375107L
exp_escolas   <- 582781L

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "8GB")
tmp_dir   <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_dd_unmatched")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(dir.exists(edu_dir))
edu_files <- list.files(edu_dir, pattern = "[.]parquet$", full.names = TRUE)
if (length(edu_files) != 30L) {
  stop("esperava 30 parts em education_parts/, achei ", length(edu_files))
}

# Nota 5: recusa rodar contra caderno aberto. Gravar por cima falharia
# so no fim, e o veredito digitado ainda nao teria sido salvo pelo Excel.
lock_file <- file.path(dirname(xlsx_path), paste0("~$", basename(xlsx_path)))
if (file.exists(xlsx_path) && file.exists(lock_file)) {
  stop("O caderno esta ABERTO no Excel (existe ", basename(lock_file),
       "). Feche-o antes de rodar.")
}

fw <- function(z) gsub("'", "''", z)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
dbExecute(con, "SET threads=4")
dbExecute(con, sprintf("SET temp_directory='%s'", fw(gsub("\\\\", "/", tmp_dir))))

####################################################################
### Step 1 -- a populacao
####################################################################

edu_glob <- gsub("\\\\", "/", file.path(edu_dir, "*.parquet"))

dbExecute(con, sprintf("
CREATE OR REPLACE VIEW pop AS
SELECT *,
       CASE WHEN coalesce(degree, 'empty') = 'empty'
             AND degree_matches_laxed = 1 THEN 'bachelor'
            ELSE ranked_level END                       AS lvl,
       coalesce(global_oa_country_code, '<null>')       AS country_key,
       coalesce(len(global_oa_candidate_ids), 0)        AS n_candidates
FROM read_parquet('%s')
WHERE global_oa_selected_count = 0", fw(edu_glob)))

dbExecute(con, "
CREATE OR REPLACE VIEW valid AS SELECT * FROM pop
WHERE lvl IN ('bachelor', 'master', 'phd')")

cat("Lendo a populacao (30 parts, ~1,3 GB).\n")
popstat <- dbGetQuery(con, "
SELECT count(*)                                      AS n_rows,
       count(DISTINCT user_id)                       AS n_users,
       count(DISTINCT (university_raw, country_key)) AS n_escolas,
       count(*) FILTER (WHERE lvl = 'bachelor')      AS n_bachelor,
       count(*) FILTER (WHERE lvl = 'master')        AS n_master,
       count(*) FILTER (WHERE lvl = 'phd')           AS n_phd,
       count(*) FILTER (WHERE n_candidates = 0)      AS n_sem_candidato
FROM valid")
print(t(popstat))

# Nota 4 / trava: a populacao e a que foi medida, ou o sorteio para.
stopifnot(popstat$n_rows == exp_rows_pop,
          popstat$n_users == exp_users_pop,
          popstat$n_escolas == exp_escolas,
          popstat$n_bachelor == exp_bachelor,
          popstat$n_master == exp_master,
          popstat$n_phd == exp_phd,
          popstat$n_sem_candidato == exp_nocand)

rotas <- dbGetQuery(con, "
SELECT global_oa_match_route                         AS rota,
       global_oa_selection_status                    AS status,
       count(*)                                      AS n_rows,
       count(DISTINCT (university_raw, country_key)) AS n_escolas,
       count(DISTINCT user_id)                       AS n_users
FROM valid GROUP BY 1, 2 ORDER BY 3 DESC")
print(rotas)

####################################################################
### Step 2 -- os dois sorteios (nota 3)
####################################################################

# Grao ESCOLA: (university_raw, pais padronizado) -- a propria chave de
# decisao do 8q. O peso da grafia vai junto para poder ponderar.
esc_sql <- sprintf("
WITH agg AS (
  SELECT university_raw, country_key,
         count(*)                                   AS n_rows,
         count(DISTINCT user_id)                    AS n_users,
         count(DISTINCT global_oa_decision_id)      AS n_decisions,
         count(*) FILTER (WHERE lvl = 'bachelor')   AS n_bachelor,
         count(*) FILTER (WHERE lvl = 'master')     AS n_master,
         count(*) FILTER (WHERE lvl = 'phd')        AS n_phd,
         max(n_candidates)                          AS n_candidates,
         hash(coalesce(university_raw, '<null>') || chr(31) ||
              country_key || chr(31) || '%d')       AS hk
  FROM valid GROUP BY 1, 2
)
SELECT 'escola' AS grain, university_raw, country_key,
       CAST(NULL AS VARCHAR) AS source_file, CAST(NULL AS BIGINT) AS source_row,
       hk
FROM agg ORDER BY hk, university_raw, country_key LIMIT %d", seed, n_draw)

# Grao ENTRADA: a linha de educacao, ponderada pela frequencia, com a
# chave fisica (source_file, source_row) que o 8q ja garante unica.
ent_sql <- sprintf("
SELECT 'entrada' AS grain,
       CAST(NULL AS VARCHAR) AS university_raw,
       CAST(NULL AS VARCHAR) AS country_key,
       source_file, source_row,
       hash(source_file || chr(31) || CAST(source_row AS VARCHAR) ||
            chr(31) || '%d') AS hk
FROM valid ORDER BY hk, source_file, source_row LIMIT %d", seed, n_draw)

draw_sql <- sprintf("SELECT * FROM (%s) UNION ALL SELECT * FROM (%s)",
                    esc_sql, ent_sql)

if (file.exists(sample_path)) {
  cat("[skip] sorteio ja estacionado:", basename(sample_path), "\n")
} else {
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    draw_sql, fw(sample_path))))
  cat("sorteadas", n_draw, "escolas e", n_draw, "entradas com seed", seed, "\n")
}

keys <- dbGetQuery(con, sprintf(
  "SELECT * FROM read_parquet('%s')", fw(sample_path)))

# Nota 4: o mesmo seed tem de devolver o mesmo sorteio.
k2 <- dbGetQuery(con, draw_sql)
id_of <- function(d) paste(d$grain, d$university_raw, d$country_key,
                           d$source_file, d$source_row, sep = "\u001f")
if (!setequal(id_of(keys), id_of(k2))) {
  stop("O mesmo seed devolveu sorteio DIFERENTE do estacionado. ",
       "O 8q mudou por baixo do sorteio.")
}
stopifnot(sum(keys$grain == "escola") == n_draw,
          sum(keys$grain == "entrada") == n_draw,
          !anyDuplicated(id_of(keys)))
if (anyDuplicated(keys$hk) > 0L) {
  warning("hk com colisao: o LIMIT pode ter desempatado arbitrariamente.",
          call. = FALSE)
}

####################################################################
### Step 3 -- a evidencia de cada grao
####################################################################

dbWriteTable(con, "k_esc", keys[keys$grain == "escola",
                                c("university_raw", "country_key")],
             overwrite = TRUE)
dbWriteTable(con, "k_ent", keys[keys$grain == "entrada",
                                c("source_file", "source_row")],
             overwrite = TRUE)

# Nota 2: n_candidates vai na planilha de proposito -- e zero em quase
# tudo, e e isso que explica a falha.
esc <- dbGetQuery(con, "
SELECT v.university_raw,
       nullif(v.country_key, '<null>')                    AS pais_padronizado,
       string_agg(DISTINCT v.university_country, ' | ')   AS university_country,
       mode(v.university_name)                            AS university_name_top,
       coalesce(string_agg(DISTINCT CAST(v.rsid AS VARCHAR), '|'), '')
                                                          AS rsid_list,
       string_agg(DISTINCT v.global_oa_match_route, '|')  AS global_oa_match_route,
       string_agg(DISTINCT v.global_oa_selection_status, '|')
                                                          AS global_oa_selection_status,
       max(v.n_candidates)                                AS n_candidates,
       count(*)                                           AS n_rows,
       count(DISTINCT v.user_id)                          AS n_users,
       count(DISTINCT v.global_oa_decision_id)            AS n_decisions,
       count(*) FILTER (WHERE v.lvl = 'bachelor')         AS n_bachelor,
       count(*) FILTER (WHERE v.lvl = 'master')           AS n_master,
       count(*) FILTER (WHERE v.lvl = 'phd')              AS n_phd
FROM valid v
JOIN k_esc k ON v.university_raw IS NOT DISTINCT FROM k.university_raw
            AND v.country_key = k.country_key
GROUP BY 1, 2
ORDER BY n_rows DESC, v.university_raw")

ent <- dbGetQuery(con, "
SELECT CAST(v.user_id AS VARCHAR)      AS user_id,
       v.source_file, v.source_row,
       v.university_raw, v.university_name, v.university_country,
       nullif(v.global_oa_country_code, '') AS pais_padronizado,
       v.rsid,
       v.degree, v.degree_raw, v.field,
       CAST(v.startdate AS VARCHAR)     AS startdate,
       CAST(v.enddate AS VARCHAR)       AS enddate,
       v.lvl, v.degree_match_route, v.degree_duration_years,
       v.global_oa_match_route, v.global_oa_selection_status,
       v.n_candidates,
       coalesce(v.global_oa_candidate_ids_pipe, '') AS global_oa_candidate_ids_pipe
FROM valid v
JOIN k_ent k ON v.source_file = k.source_file AND v.source_row = k.source_row
ORDER BY v.lvl, v.university_raw, v.source_file, v.source_row")

stopifnot(nrow(esc) == n_draw, nrow(ent) == n_draw)
# Nota 6: user_id ja saiu como VARCHAR do DuckDB; confere.
stopifnot(all(grepl("^[0-9]+$", ent$user_id)))
ent$rsid <- ifelse(is.na(ent$rsid), "", as.character(ent$rsid))

for (cl in names(esc)) if (is.character(esc[[cl]])) {
  esc[[cl]] <- ifelse(is.na(esc[[cl]]), "", esc[[cl]])
}
for (cl in names(ent)) if (is.character(ent[[cl]])) {
  ent[[cl]] <- ifelse(is.na(ent[[cl]]), "", ent[[cl]])
}

esc$veredito <- ""; esc$motivo <- ""
ent$veredito <- ""; ent$motivo <- ""

esc_cols <- c("university_raw", "university_country", "pais_padronizado",
              "university_name_top", "rsid_list", "global_oa_match_route",
              "global_oa_selection_status", "n_candidates",
              "n_rows", "n_users", "n_decisions",
              "n_bachelor", "n_master", "n_phd", "veredito", "motivo")
ent_cols <- c("user_id", "source_file", "source_row",
              "university_raw", "university_name", "university_country",
              "pais_padronizado", "rsid", "degree", "degree_raw", "field",
              "startdate", "enddate", "lvl", "degree_match_route",
              "degree_duration_years", "global_oa_match_route",
              "global_oa_selection_status", "n_candidates",
              "global_oa_candidate_ids_pipe", "veredito", "motivo")
esc <- esc[, esc_cols]
ent <- ent[, ent_cols]
n_esc_col <- ncol(esc); n_ent_col <- ncol(ent)
stopifnot(n_esc_col == 16L, n_ent_col == 22L)

####################################################################
### Step 4 -- resgatar anotacao de um caderno anterior (nota 5)
####################################################################

resgatados <- 0L
if (file.exists(xlsx_path)) {
  old_e <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra_escolas")
  old_n <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra_entradas")
  if (!all(c("university_raw", "pais_padronizado", "veredito", "motivo")
           %in% names(old_e)) ||
      !all(c("source_file", "source_row", "veredito", "motivo")
           %in% names(old_n))) {
    stop("O caderno existente nao tem as colunas de chave e anotacao. ",
         "Nao vou regravar por cima.")
  }
  ke_new <- paste(esc$university_raw, esc$pais_padronizado, sep = "\u001f")
  ke_old <- paste(ifelse(is.na(old_e$university_raw), "", old_e$university_raw),
                  ifelse(is.na(old_e$pais_padronizado), "",
                         old_e$pais_padronizado), sep = "\u001f")
  kn_new <- paste(ent$source_file, ent$source_row, sep = "\u001f")
  kn_old <- paste(old_n$source_file, old_n$source_row, sep = "\u001f")
  if (anyNA(match(ke_new, ke_old)) || anyNA(match(kn_new, kn_old))) {
    stop("Linha(s) do caderno anterior nao casaram por chave; a anotacao ",
         "seria perdida em silencio. Apague o caderno de proposito se e ",
         "isso que voce quer.")
  }
  ie <- match(ke_new, ke_old); ino <- match(kn_new, kn_old)
  esc$veredito <- ifelse(is.na(old_e$veredito[ie]), "", old_e$veredito[ie])
  esc$motivo   <- ifelse(is.na(old_e$motivo[ie]),   "", old_e$motivo[ie])
  ent$veredito <- ifelse(is.na(old_n$veredito[ino]), "", old_n$veredito[ino])
  ent$motivo   <- ifelse(is.na(old_n$motivo[ino]),   "", old_n$motivo[ino])
  resgatados <- sum(trimws(c(esc$veredito, ent$veredito)) != "")
  cat("caderno anterior lido:", resgatados, "veredito(s) preservado(s)\n")
  invisible(file.remove(xlsx_path))
}

####################################################################
### Step 5 -- o caderno
####################################################################

pct <- function(a, b) sprintf("%.1f%%", 100 * a / b)
# big.mark e decimal.mark seriam ambos "." no format(); formatC evita o aviso.
mil <- function(x) formatC(as.numeric(x), format = "d", big.mark = ".")

leia <- data.frame(c(
  "ENTRADAS COM DIPLOMA VALIDO QUE NAO RECEBERAM openalex_id",
  "Coorte _degree_duration, hierarquia global do script 8q.",
  "",
  "O QUE E A POPULACAO",
  sprintf("  %s linhas de educacao, %s usuarios, %s grafias distintas.",
          mil(popstat$n_rows),
          mil(popstat$n_users),
          mil(popstat$n_escolas)),
  "  Criterio: global_oa_selected_count = 0 (nenhum id selecionado) E",
  "  nivel efetivo em bachelor/master/phd.",
  "",
  "  Nivel efetivo (o mesmo do ranked_education_flags.R):",
  "    CASE WHEN coalesce(degree,'empty')='empty' AND degree_matches_laxed=1",
  "         THEN 'bachelor' ELSE ranked_level END",
  "  NAO e a coluna `degree` da Revelio -- essa mede 58,4% de recall.",
  "",
  "LEIA ISTO ANTES DE JULGAR",
  sprintf("  %s das %s linhas (%s) sairam com CONJUNTO DE CANDIDATOS VAZIO.",
          mil(popstat$n_sem_candidato),
          mil(popstat$n_rows),
          pct(popstat$n_sem_candidato, popstat$n_rows)),
  "  Ou seja: na esmagadora maioria o casamento nao errou de instituicao,",
  "  ele nunca teve uma para avaliar. A pergunta util aqui e",
  "",
  "     'existe no OpenAlex uma instituicao que esta grafia deveria ter",
  "      encontrado?'",
  "",
  "  e nao 'o scorer escolheu a instituicao errada?'.",
  "",
  "  As duas rotas de falha:",
  "    unmatched_missing_rsid   sem rsid, e o C_norm direto nao achou nada",
  "    unmatched_known_rsid     tem rsid, mas o rsid nao esta no crosswalk",
  "    unresolved_blank_raw     university_raw em branco",
  "",
  "AS DUAS ABAS TEM DENOMINADORES DIFERENTES (nota 8)",
  "  Amostra_escolas    100 grafias distintas (university_raw + pais).",
  sprintf("                     Populacao: %s grafias.",
          mil(popstat$n_escolas)),
  "                     Responde POR QUE o casamento falhou. Cada grafia",
  "                     conta 1, a mais rara igual a mais comum.",
  "",
  "  Amostra_entradas   100 linhas de educacao sorteadas direto.",
  sprintf("                     Populacao: %s linhas.",
          mil(popstat$n_rows)),
  "                     Ponderada pela frequencia: responde COMO E uma",
  "                     entrada nao casada tipica.",
  "",
  "  Nao existe 'a taxa' deste caderno. Para qualquer numero, diga de",
  "  qual aba ele veio e ponha o denominador da aba Resumo do lado.",
  "",
  sprintf("  Seed %d. Sorteio hash-ordenado, sem USING SAMPLE.", seed),
  "",
  "AS COLUNAS QUE IMPORTAM",
  "  university_raw       o texto digitado no LinkedIn -- a coisa a julgar",
  "  university_name(_top) o rotulo da Revelio. E O SUSPEITO, NAO O",
  "                       GABARITO: UNIASSELVI vem rotulada 'Dante",
  "                       University Centre'. Julgue pela grafia.",
  "  pais_padronizado     o pais que o 8q usou na decisao",
  "  rsid / rsid_list     a escola da Revelio, quando existe",
  "  n_candidates         quantos ids o 8q chegou a considerar. Zero em",
  "                       quase tudo -- veja acima.",
  "  n_rows/n_users       peso da grafia na base (so na aba de escolas)",
  "  lvl                  nivel efetivo: bachelor, master ou phd",
  "  degree_match_route   ranked_regex ou duration_fallback",
  "  veredito, motivo     fundo amarelo: VOCE preenche",
  "",
  "VEREDITO",
  "  existe_no_openalex            existe registro; o matcher e que falhou",
  "  nao_existe_no_openalex        instituicao real, sem registro no snapshot",
  "  nao_e_instituicao_de_ensino   empresa, curso livre, texto solto",
  "  ilegivel                      a grafia nao permite identificar nada",
  "  duvidoso                      da para argumentar dos dois lados",
  "",
  "Nada deste caderno volta para o pipeline automaticamente."),
  stringsAsFactors = FALSE)
names(leia) <- "Como ler este caderno"

res_pop <- data.frame(
  medida = c("linhas de educacao", "usuarios", "grafias distintas",
             "linhas bachelor", "linhas master", "linhas phd",
             "linhas sem candidato"),
  populacao = c(popstat$n_rows, popstat$n_users, popstat$n_escolas,
                popstat$n_bachelor, popstat$n_master, popstat$n_phd,
                popstat$n_sem_candidato),
  stringsAsFactors = FALSE)

res_draw <- data.frame(
  aba = c("Amostra_escolas", "Amostra_entradas"),
  grao = c("university_raw + pais", "linha de educacao"),
  sorteadas = c(n_draw, n_draw),
  populacao = c(popstat$n_escolas, popstat$n_rows),
  stringsAsFactors = FALSE)
res_draw$cobertura <- sprintf("%.4f%%",
                              100 * res_draw$sorteadas / res_draw$populacao)
res_draw$peso <- sprintf("%.0f", res_draw$populacao / res_draw$sorteadas)

res_lvl <- dbGetQuery(con, "
SELECT lvl, count(*) AS n_rows, count(DISTINCT user_id) AS n_users,
       count(DISTINCT (university_raw, country_key)) AS n_escolas
FROM valid GROUP BY 1 ORDER BY 2 DESC")

wb <- createWorkbook()
hdr <- createStyle(textDecoration = "bold", fgFill = "#E8E8E8",
                   border = "bottom", valign = "top", wrapText = TRUE)
wrap  <- createStyle(wrap = TRUE, valign = "top")
txt   <- createStyle(numFmt = "TEXT", valign = "top")
oasty <- createStyle(fgFill = "#F3EFF7", valign = "top")
degst <- createStyle(fgFill = "#EEF4FB", valign = "top")
yours <- createStyle(fgFill = "#FFF7D6", border = "TopBottomLeftRight",
                     borderColour = "#C9A227", valign = "top")

addWorksheet(wb, "Como ler")
writeData(wb, "Como ler", leia)
addStyle(wb, "Como ler", hdr, rows = 1, cols = 1)
setColWidths(wb, "Como ler", cols = 1, widths = 80)

## --- aba escolas ---------------------------------------------------
addWorksheet(wb, "Amostra_escolas")
writeData(wb, "Amostra_escolas", esc, withFilter = TRUE)
freezePane(wb, "Amostra_escolas", firstActiveRow = 2, firstActiveCol = 2)
addStyle(wb, "Amostra_escolas", hdr, rows = 1, cols = 1:n_esc_col,
         gridExpand = TRUE)
re <- 2:(nrow(esc) + 1)
addStyle(wb, "Amostra_escolas", txt, rows = re, cols = 5, gridExpand = TRUE)
addStyle(wb, "Amostra_escolas", oasty, rows = re, cols = 6:8,
         gridExpand = TRUE)
addStyle(wb, "Amostra_escolas", yours, rows = re, cols = 15:16,
         gridExpand = TRUE)
addStyle(wb, "Amostra_escolas", wrap, rows = re, cols = c(1, 2, 4, 16),
         gridExpand = TRUE, stack = TRUE)
setColWidths(wb, "Amostra_escolas", cols = 1:n_esc_col,
             widths = c(46, 20, 10, 40, 16, 24, 24, 8,
                        9, 9, 9, 10, 9, 7, 24, 40))

## --- aba entradas --------------------------------------------------
addWorksheet(wb, "Amostra_entradas")
writeData(wb, "Amostra_entradas", ent, withFilter = TRUE)
freezePane(wb, "Amostra_entradas", firstActiveRow = 2, firstActiveCol = 5)
addStyle(wb, "Amostra_entradas", hdr, rows = 1, cols = 1:n_ent_col,
         gridExpand = TRUE)
rn <- 2:(nrow(ent) + 1)
# Nota 6: user_id e rsid como TEXTO tambem no formato da celula.
addStyle(wb, "Amostra_entradas", txt, rows = rn, cols = c(1, 8),
         gridExpand = TRUE)
addStyle(wb, "Amostra_entradas", degst, rows = rn, cols = 9:16,
         gridExpand = TRUE)
addStyle(wb, "Amostra_entradas", oasty, rows = rn, cols = 17:20,
         gridExpand = TRUE)
addStyle(wb, "Amostra_entradas", yours, rows = rn, cols = 21:22,
         gridExpand = TRUE)
addStyle(wb, "Amostra_entradas", wrap, rows = rn, cols = c(4, 5, 10, 11, 22),
         gridExpand = TRUE, stack = TRUE)
setColWidths(wb, "Amostra_entradas", cols = 1:n_ent_col,
             widths = c(18, 34, 10, 46, 34, 20, 10, 10, 12, 34, 24,
                        12, 12, 10, 18, 9, 24, 24, 8, 26, 24, 40))

## --- dominio escondido ---------------------------------------------
addWorksheet(wb, "dominio")
writeData(wb, "dominio", data.frame(veredito = verdict_domain))
sheetVisibility(wb)[which(names(wb) == "dominio")] <- "hidden"
dv_range <- sprintf("'dominio'!$A$2:$A$%d", length(verdict_domain) + 1L)
dataValidation(wb, "Amostra_escolas", col = 15, rows = re,
               type = "list", value = dv_range)
dataValidation(wb, "Amostra_entradas", col = 21, rows = rn,
               type = "list", value = dv_range)

## --- resumo ---------------------------------------------------------
addWorksheet(wb, "Resumo")
writeData(wb, "Resumo",
          "Populacao: entradas com diploma valido e sem openalex_id",
          startRow = 1)
writeData(wb, "Resumo", res_pop, startRow = 2)
r <- nrow(res_pop) + 4
writeData(wb, "Resumo", "Os dois sorteios e seus denominadores (nota 8)",
          startRow = r)
writeData(wb, "Resumo", res_draw, startRow = r + 1)
r2 <- r + nrow(res_draw) + 4
writeData(wb, "Resumo", "Por nivel efetivo", startRow = r2)
writeData(wb, "Resumo", res_lvl, startRow = r2 + 1)
r3 <- r2 + nrow(res_lvl) + 4
writeData(wb, "Resumo", "Por rota de falha da hierarquia", startRow = r3)
writeData(wb, "Resumo", rotas, startRow = r3 + 1)
addStyle(wb, "Resumo", hdr, rows = c(2, r + 1, r2 + 1, r3 + 1), cols = 1:6,
         gridExpand = TRUE)
setColWidths(wb, "Resumo", cols = 1:6,
             widths = c(26, 24, 12, 14, 12, 12))

saveWorkbook(wb, xlsx_path, overwrite = FALSE)

####################################################################
### Validacao (nota 7)
####################################################################

chk_e <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra_escolas")
chk_n <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra_entradas")

if (nrow(chk_e) != n_draw || ncol(chk_e) != n_esc_col ||
    nrow(chk_n) != n_draw || ncol(chk_n) != n_ent_col) {
  stop(sprintf("releitura com %dx%d e %dx%d, esperado %dx%d e %dx%d",
               nrow(chk_e), ncol(chk_e), nrow(chk_n), ncol(chk_n),
               n_draw, n_esc_col, n_draw, n_ent_col))
}

# Nota 6: os inteiros grandes sobreviveram como texto legivel?
chk_n$user_id <- as.character(chk_n$user_id)
if (!all(grepl("^[0-9]+$", chk_n$user_id))) {
  stop("O xlsx gravou user_id em notacao cientifica (nota 6).")
}
if (!setequal(chk_n$user_id, ent$user_id)) {
  stop("releitura com user_ids diferentes dos gravados.")
}

# Nota 7: a assercao forte e de IDENTIDADE no round trip do texto livre.
rt <- function(a, b, nm) {
  a <- ifelse(is.na(a), "", as.character(a))
  b <- ifelse(is.na(b), "", as.character(b))
  if (!identical(a, b)) {
    bad <- which(a != b)
    print(data.frame(gravado = b[bad], relido = a[bad])[seq_len(min(5,
          length(bad))), ])
    stop(length(bad), " celula(s) de ", nm, " nao sobreviveram ao round trip.")
  }
}
rt(chk_e$university_raw, esc$university_raw, "escolas/university_raw")
rt(chk_e$university_name_top, esc$university_name_top,
   "escolas/university_name_top")
rt(chk_n$university_raw, ent$university_raw, "entradas/university_raw")
rt(chk_n$degree_raw, ent$degree_raw, "entradas/degree_raw")

if (!all(chk_n$lvl %in% c("bachelor", "master", "phd"))) {
  stop("aba de entradas com nivel fora de bachelor/master/phd.")
}
if (anyDuplicated(paste(chk_n$source_file, chk_n$source_row)) > 0L ||
    anyDuplicated(paste(chk_e$university_raw, chk_e$pais_padronizado)) > 0L) {
  stop("chave repetida numa das abas de amostra.")
}

# Nota 7: aviso, nao erro -- o texto e livre e o openxlsx grava string.
risky <- unlist(lapply(
  list(chk_e$university_raw, chk_e$university_name_top,
       chk_n$university_raw, chk_n$university_name, chk_n$degree_raw),
  function(z) {
    z <- ifelse(is.na(z), "", as.character(z))
    z[grepl("^[=+@-]", trimws(z))]
  }))
if (length(risky) > 0L) {
  warning(length(risky), " celula(s) comecam com = + - @; sobreviveram ao ",
          "round trip, mas confira a exibicao: ",
          paste(head(risky, 3), collapse = " / "), call. = FALSE)
}

####################################################################
### Relatorio
####################################################################

cat("\n==================================================================\n")
cat("Entradas com diploma valido e sem openalex_id -- coorte degree_duration\n")
cat("==================================================================\n\n")
print(res_pop, row.names = FALSE)
cat("\n")
print(res_draw, row.names = FALSE)
cat("\n")
print(rotas, row.names = FALSE)
cat(sprintf("\n  seed      : %d\n", seed))
cat(sprintf("  escolas   : %d linhas x %d colunas\n", nrow(esc), n_esc_col))
cat(sprintf("  entradas  : %d linhas x %d colunas\n", nrow(ent), n_ent_col))
if (resgatados > 0L) {
  cat(sprintf("  resgatados: %d veredito(s) do caderno anterior\n", resgatados))
}
cat(sprintf("\n  %s\n", sample_path))
cat(sprintf("  %s\n\n", xlsx_path))
cat("Julgue pela grafia (university_raw), nunca pelo rotulo da Revelio.\n")
cat("As duas abas tem denominadores diferentes; veja o Resumo (nota 8).\n\n")
