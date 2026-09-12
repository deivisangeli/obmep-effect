####################################################################
###
### Caderno de auditoria do mapa escola -> openalex_id     [local only]
###
### 8i publicou unmatched_school_openalex_map.parquet: 448 rsids sobre
### 418 escolas. Deles, 410 vieram da DOBRA (casamento exato de nome,
### mecanico) e 38 do MEU JULGAMENTO. Os vereditos sao escritos por LLM,
### nao por humano. Este script sorteia 100 linhas para uma pessoa
### auditar em Excel.
###
### -----------------------------------------------------------------
### A AMOSTRA E ESTRATIFICADA, E ISSO E O PONTO
### -----------------------------------------------------------------
### Uma amostra aleatoria simples de 100 entre 448 traria ~8 linhas de
### julgamento (38/448 = 8,5%) e gastaria o resto da auditoria na parte
### mecanica, que e justamente a menos capaz de errar. Entao:
###
###   estrato      sorteadas   populacao   cobertura
###   judgement           38          38        100%
###   fold                62         410         15%
###   total              100         448
###
### A coluna `stratum` vai na planilha e a aba Resumo declara as duas
### populacoes, para que o resultado seja PONDERADO de volta e nao lido
### como uma taxa unica. Uma taxa de erro global desta amostra estaria
### errada por construcao: o estrato de risco esta 6,6x sobre-representado.
###
### Produtos:
###   unmatched_school_audit_sample.parquet   o sorteio estacionado
###   unmatched_school_audit_sample.xlsx      o caderno
###
### Depends on:
###   unmatched_school_name_worksheet.R (8i)  mapa, planilha e cache
###
### Shape reused from:
###   capes_obmep_match_sample.R (27a), role_audit_review.R (10e) e
###   field_manual_review.R (10i) -- caderno openxlsx, aba de rubrica,
###   dominio escondido, saveWorkbook(overwrite = FALSE), releitura.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Le tres arquivos locais, escreve um parquet e um
###    xlsx. Ainda e prep/; nao vai para o SEDAP.
### 2. O ID NAO VIAJA SOZINHO. 'I4210097431' nao e auditavel como
###    string, entao ao lado de university_name e openalex_id vao o
###    display_name, o pais, o tipo e o works_count do registro do
###    OpenAlex. Sem isso a auditoria seria de fe, nao de evidencia.
### 3. JULGUE CONTRA top_raw_variants, NAO CONTRA university_name. O
###    rotulo da Revelio e o suspeito, nao o gabarito: UNIASSELVI vem
###    rotulada "Dante University Centre", e rsid 3800 casa
###    university_raw = "Universidade Federal do Rio de Janeiro" com
###    university_name = "Universite d'Aix-Marseille". As grafias sao a
###    unica fonte de verdade aqui.
### 4. ORDER BY hash(...) LIMIT n, NUNCA USING SAMPLE. O DuckDB empurra
###    USING SAMPLE para baixo do filtro -- armadilha medida no README,
###    onde 500 linhas viraram 23. E sem set.seed(): a pasta semeia pelo
###    hash, com o seed como constante nos Parametros.
### 5. UM SEED QUE NAO REPRODUZ E PIOR QUE NENHUM. O sorteio e
###    estacionado em parquet, pulado na re-execucao, e a consulta e
###    refeita e conferida com setequal contra o que ficou estacionado.
### 6. NAO SOBRESCREVE O XLSX. Se o caderno existe, veredito e motivo
###    sao lidos de volta, casados por rsid, e a remocao so acontece
###    depois de a anotacao estar em memoria. Digitacao de auditor nao
###    existe em outro lugar.
### 7. TEXTO QUE COMECA COM = + - @ E FORMULA PARA O EXCEL. O openxlsx
###    grava string como shared string, que o Excel nao avalia, mas o
###    Step final confere em vez de confiar.
### 8. A RELEITURA CONFERE A INVARIANTE, NAO A CONCORDANCIA. O README
###    registra uma checagem que passou porque o xlsx e o CSV estavam
###    igualmente corrompidos. Aqui a assercao e openalex_id ~ ^I[0-9]+$
###    e rsid ~ ^[0-9]+$.
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

map_path   <- file.path(coh_dir, "unmatched_school_openalex_map.parquet")
class_path <- file.path(coh_dir, "unmatched_school_name_class.csv")
inst_path  <- file.path(coh_dir, "oa_institution_cache.parquet")

sample_path <- file.path(coh_dir, "unmatched_school_audit_sample.parquet")
xlsx_path   <- file.path(coh_dir, "unmatched_school_audit_sample.xlsx")

seed   <- 20260906L
n_fold <- 62L      # do estrato mecanico; o de julgamento vai inteiro

verdict_domain <- c("correto", "errado", "duvidoso")

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "8GB")
tmp_dir   <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_school_audit")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(file.exists(map_path), file.exists(class_path),
          file.exists(inst_path))

# Nota 6: recusa rodar contra caderno aberto. Gravar por cima falharia
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
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

####################################################################
### Step 1 -- populacao a auditar
####################################################################

dbExecute(con, sprintf("
CREATE OR REPLACE VIEW mp  AS SELECT * FROM read_parquet('%s')", fw(map_path)))
dbExecute(con, sprintf("
CREATE OR REPLACE VIEW ins AS SELECT * FROM read_parquet('%s')", fw(inst_path)))

cls <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8")
cls <- cls[, c("university_name", "top_raw_variants", "note")]
names(cls)[3] <- "note_llm"
dbWriteTable(con, "cl", cls, overwrite = TRUE)

pop <- dbGetQuery(con, "
SELECT CASE WHEN safe = 1 THEN 'fold' ELSE 'judgement' END AS stratum,
       count(*) AS n
FROM mp GROUP BY 1 ORDER BY 1")
print(pop)

n_pop_fold <- pop$n[pop$stratum == "fold"]
n_pop_jud  <- pop$n[pop$stratum == "judgement"]
if (n_fold > n_pop_fold) {
  stop(sprintf("n_fold = %d maior que o estrato (%d).", n_fold, n_pop_fold))
}

# Nota 4: hash-ordenado sobre o estrato JA filtrado, nunca USING SAMPLE.
sample_sql <- sprintf("
WITH base AS (
  SELECT m.rsid,
         CASE WHEN m.safe = 1 THEN 'fold' ELSE 'judgement' END AS stratum,
         m.university_name, m.openalex_id, m.verdict, m.source,
         m.from_candidates, m.n_rows, m.n_users,
         hash(CAST(m.rsid AS VARCHAR) || '#%d') AS hk
  FROM mp m
),
jud AS (SELECT * FROM base WHERE stratum = 'judgement'),
fld AS (SELECT * FROM base WHERE stratum = 'fold'
        ORDER BY hk, rsid LIMIT %d)
SELECT * FROM jud UNION ALL SELECT * FROM fld", seed, n_fold)

if (file.exists(sample_path)) {
  cat("[skip] amostra ja estacionada:", basename(sample_path), "\n")
} else {
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    sample_sql, fw(sample_path))))
  cat("sorteadas", n_fold, "linhas fold com seed", seed,
      "mais", n_pop_jud, "de julgamento\n")
}

smp <- dbGetQuery(con, sprintf(
  "SELECT * FROM read_parquet('%s')", fw(sample_path)))

# Nota 5: um seed que nao reproduz e pior que nenhum.
s2 <- dbGetQuery(con, sample_sql)
if (!setequal(smp$rsid, s2$rsid)) {
  stop("O mesmo seed devolveu amostra DIFERENTE da estacionada. ",
       "O mapa mudou por baixo do sorteio.")
}
if (anyDuplicated(smp$hk) > 0L) {
  warning("hk com colisao: o LIMIT pode ter desempatado arbitrariamente.",
          call. = FALSE)
}

####################################################################
### Step 2 -- juntar a evidencia (nota 2 e nota 3)
####################################################################

dbWriteTable(con, "smp", smp[, setdiff(names(smp), "hk")], overwrite = TRUE)

am <- dbGetQuery(con, "
SELECT s.rsid, s.stratum, s.university_name,
       s.openalex_id,
       i.display_name                     AS oa_display_name,
       coalesce(i.country_code, '??')     AS oa_country,
       coalesce(i.type, '?')              AS oa_type,
       coalesce(i.works_count, 0)         AS oa_works,
       c.top_raw_variants,
       s.n_rows, s.n_users,
       s.verdict, s.source, s.from_candidates,
       coalesce(c.note_llm, '')           AS note_llm
FROM smp s
LEFT JOIN ins i ON s.openalex_id = i.oa_id
LEFT JOIN cl  c ON s.university_name = c.university_name
ORDER BY s.stratum, s.n_rows DESC, s.rsid")

if (any(is.na(am$oa_display_name))) {
  stop(sum(is.na(am$oa_display_name)),
       " linha(s) sem display_name: o id nao esta no cache (nota 2).")
}
if (nrow(am) != n_pop_jud + n_fold) {
  stop(sprintf("amostra com %d linhas, esperado %d",
               nrow(am), n_pop_jud + n_fold))
}

am$rsid        <- as.character(am$rsid)
am$veredito    <- ""
am$motivo      <- ""

am_cols <- c("rsid", "stratum", "university_name",
             "openalex_id", "oa_display_name", "oa_country", "oa_type",
             "oa_works", "top_raw_variants", "n_rows", "n_users",
             "verdict", "source", "from_candidates", "note_llm",
             "veredito", "motivo")
am <- am[, am_cols]
n_col <- ncol(am)
stopifnot(n_col == 17L)

####################################################################
### Step 3 -- resgatar anotacao de um caderno anterior (nota 6)
####################################################################

if (file.exists(xlsx_path)) {
  old <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra")
  need <- c("rsid", "veredito", "motivo")
  if (!all(need %in% names(old))) {
    stop("O caderno existente nao tem as colunas ",
         paste(need, collapse = ", "), ". Nao vou regravar por cima.")
  }
  old$rsid <- as.character(old$rsid)
  k <- match(am$rsid, old$rsid)
  if (any(is.na(k))) {
    stop(sum(is.na(k)), " linha(s) do caderno anterior nao casaram por ",
         "rsid; a anotacao seria perdida em silencio. Apague o caderno ",
         "de proposito se e isso que voce quer.")
  }
  am$veredito <- ifelse(is.na(old$veredito[k]), "", old$veredito[k])
  am$motivo   <- ifelse(is.na(old$motivo[k]),   "", old$motivo[k])
  cat("caderno anterior lido:", sum(trimws(am$veredito) != ""),
      "veredito(s) preservado(s)\n")
  invisible(file.remove(xlsx_path))
}

####################################################################
### Step 4 -- o caderno
####################################################################

leia <- data.frame(c(
  "CADERNO DE AUDITORIA -- mapa escola -> openalex_id (script 8i)",
  "",
  "O QUE ESTA AQUI",
  sprintf("100 linhas do mapa publicado: %d rsids sobre %d escolas.",
          n_pop_fold + n_pop_jud, length(unique(smp$university_name))),
  sprintf("Seed %d. Sorteio hash-ordenado, sem USING SAMPLE.", seed),
  "",
  "A AMOSTRA E ESTRATIFICADA -- NAO LEIA UMA TAXA UNICA",
  sprintf("  judgement  %3d de %3d  (100%%)  -- decididas por julgamento",
          n_pop_jud, n_pop_jud),
  sprintf("  fold       %3d de %3d  ( %2.0f%%)  -- casamento exato de nome",
          n_fold, n_pop_fold, 100 * n_fold / n_pop_fold),
  "O estrato de risco esta deliberadamente sobre-representado (6,6x).",
  "Para uma taxa de erro do mapa, PONDERE pelas populacoes da aba Resumo.",
  "",
  "COMO JULGAR -- LEIA ISTO",
  "Compare openalex_id/oa_display_name contra top_raw_variants, que sao",
  "as grafias que as pessoas realmente digitaram. NAO julgue contra",
  "university_name: esse rotulo da Revelio e o suspeito, nao o gabarito.",
  "Exemplo real: UNIASSELVI vem rotulada 'Dante University Centre' e a",
  "instituicao certa e o Centro Universitario Leonardo da Vinci.",
  "",
  "AS COLUNAS",
  "  rsid, stratum       chave e estrato",
  "  university_name     rotulo da Revelio (o suspeito)",
  "  openalex_id         o id atribuido",
  "  oa_display_name     o que esse id E, de fato, no OpenAlex",
  "  oa_country/type/works   o resto do registro, para plausibilidade",
  "  top_raw_variants    as grafias digitadas -- a fonte de verdade",
  "  n_rows, n_users     peso da escola na base",
  "  verdict/source/from_candidates/note_llm   fundo azul: minha decisao",
  "    source = fold        dobra mecanica, sem julgamento",
  "    source = llm         escolhido por julgamento",
  "    from_candidates = 1  escolhido da lista curta gerada por codigo",
  "    from_candidates = 0  achado por busca dirigida no snapshot",
  "  veredito, motivo    fundo amarelo: VOCE preenche",
  "",
  "VEREDITO",
  "  correto    o id corresponde a instituicao das grafias",
  "  errado     o id e de outra instituicao",
  "  duvidoso   as grafias nao permitem decidir",
  "",
  "As linhas de julgamento estao tingidas de bege: comece por elas.",
  "Nada deste caderno volta para o pipeline automaticamente."),
  stringsAsFactors = FALSE)
names(leia) <- "Como ler este caderno"

res <- as.data.frame(table(estrato = am$stratum), stringsAsFactors = FALSE)
names(res) <- c("estrato", "sorteadas")
res$populacao <- ifelse(res$estrato == "fold", n_pop_fold, n_pop_jud)
res$cobertura <- sprintf("%.0f%%", 100 * res$sorteadas / res$populacao)
res$peso <- sprintf("%.2f", res$populacao / res$sorteadas)

res2 <- as.data.frame(table(source = am$source, verdict = am$verdict))
res2 <- res2[res2$Freq > 0, ]

wb <- createWorkbook()
hdr <- createStyle(textDecoration = "bold", fgFill = "#E8E8E8",
                   border = "bottom", valign = "top", wrapText = TRUE)
wrap <- createStyle(wrap = TRUE, valign = "top")
txt  <- createStyle(numFmt = "TEXT", valign = "top")
mine <- createStyle(fgFill = "#EEF4FB", valign = "top")
oasty <- createStyle(fgFill = "#F3EFF7", valign = "top")
yours <- createStyle(fgFill = "#FFF7D6", border = "TopBottomLeftRight",
                     borderColour = "#C9A227", valign = "top")

addWorksheet(wb, "Como ler")
writeData(wb, "Como ler", leia)
addStyle(wb, "Como ler", hdr, rows = 1, cols = 1)
setColWidths(wb, "Como ler", cols = 1, widths = 78)

addWorksheet(wb, "Amostra")
writeData(wb, "Amostra", am, withFilter = TRUE)
# Congela ate oa_display_name: nome, id e o que o id e ficam sempre a vista.
freezePane(wb, "Amostra", firstActiveRow = 2, firstActiveCol = 6)
addStyle(wb, "Amostra", hdr, rows = 1, cols = 1:n_col, gridExpand = TRUE)
rr <- 2:(nrow(am) + 1)
# Nota 8: rsid e openalex_id como TEXTO tambem no formato da celula.
addStyle(wb, "Amostra", txt, rows = rr, cols = c(1, 4), gridExpand = TRUE)
addStyle(wb, "Amostra", oasty, rows = rr, cols = 4:8, gridExpand = TRUE)
addStyle(wb, "Amostra", mine, rows = rr, cols = 12:15, gridExpand = TRUE)
addStyle(wb, "Amostra", yours, rows = rr, cols = 16:17, gridExpand = TRUE)
addStyle(wb, "Amostra", wrap, rows = rr, cols = c(3, 5, 9, 15, 17),
         gridExpand = TRUE, stack = TRUE)
setColWidths(wb, "Amostra", cols = 1:n_col,
             widths = c(10, 12, 40, 14, 40, 9, 12, 10, 62,
                        9, 9, 20, 15, 10, 46, 12, 40))
# O olho vai para o estrato de risco.
conditionalFormatting(wb, "Amostra", cols = 1:n_col, rows = rr,
                      rule = '$B2="judgement"', type = "expression",
                      style = createStyle(bgFill = "#FBF0E6"))

# Nota: lista suspensa de aba escondida; 'inline' estoura o limite do
# Excel com facilidade e falha em silencio.
addWorksheet(wb, "dominio")
writeData(wb, "dominio", data.frame(veredito = verdict_domain))
sheetVisibility(wb)[which(names(wb) == "dominio")] <- "hidden"
dataValidation(wb, "Amostra", col = 16, rows = rr,
               type = "list", value = "'dominio'!$A$2:$A$4")

addWorksheet(wb, "Resumo")
writeData(wb, "Resumo",
          "Composicao: as 100 sorteadas contra os 448 rsids publicados",
          startRow = 1)
writeData(wb, "Resumo", res, startRow = 2)
writeData(wb, "Resumo", "Por fonte e veredito do 8i", startRow = nrow(res) + 5)
writeData(wb, "Resumo", res2, startRow = nrow(res) + 6)
addStyle(wb, "Resumo", hdr, rows = c(2, nrow(res) + 6), cols = 1:5,
         gridExpand = TRUE)
setColWidths(wb, "Resumo", cols = 1:5, widths = c(14, 11, 11, 11, 8))

saveWorkbook(wb, xlsx_path, overwrite = FALSE)

####################################################################
### Validacao (nota 7 e nota 8)
####################################################################

chk <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra")
if (nrow(chk) != nrow(am) || ncol(chk) != n_col) {
  stop(sprintf("releitura com %d x %d, esperado %d x %d",
               nrow(chk), ncol(chk), nrow(am), n_col))
}
chk$rsid <- as.character(chk$rsid)
if (!all(grepl("^[0-9]+$", chk$rsid))) {
  stop("O xlsx gravou rsid em notacao cientifica (nota 8).")
}
if (!all(grepl("^I[0-9]+$", chk$openalex_id))) {
  stop("openalex_id nao sobreviveu como ^I[0-9]+$ (nota 8).")
}
if (!setequal(chk$rsid, as.character(am$rsid))) {
  stop("releitura com rsids diferentes dos gravados.")
}

# Nota 7: nada pode comecar com = + - @.
risky <- unlist(lapply(chk[, c("university_name", "oa_display_name",
                               "top_raw_variants", "note_llm")],
                       function(z) z[grepl("^[=+@-]", trimws(z))]))
if (length(risky) > 0L) {
  print(head(risky, 5))
  stop(length(risky), " celula(s) comecam com = + - @ (nota 7).")
}

got <- table(am$stratum)
if (!identical(as.integer(got[["judgement"]]), as.integer(n_pop_jud)) ||
    !identical(as.integer(got[["fold"]]), as.integer(n_fold))) {
  stop("estratos com tamanho inesperado.")
}

####################################################################
### Relatorio
####################################################################

cat("\n==================================================================\n")
cat("Caderno de auditoria do mapa escola -> openalex_id\n")
cat("==================================================================\n\n")
print(res, row.names = FALSE)
cat(sprintf("\n  linhas   : %d\n  colunas  : %d\n  seed     : %d\n",
            nrow(am), n_col, seed))
cat(sprintf("  escolas  : %d\n", length(unique(am$university_name))))
cat(sprintf("\n  %s\n", sample_path))
cat(sprintf("  %s\n\n", xlsx_path))
cat("Julgue contra top_raw_variants, nunca contra university_name (nota 3).\n")
cat("Para uma taxa de erro do mapa, ponderar pela coluna peso do Resumo.\n\n")
