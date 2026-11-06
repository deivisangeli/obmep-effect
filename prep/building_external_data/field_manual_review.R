####################################################################
### Caderno para auditar 50 linhas da classificacao manual de campo
###
### A 10h classificou 1.000 posicoes em seis campos e produziu a
### prevalencia (matematica em 2.5%). As 1.000 sao julgamento do LLM e
### estao sem revisao -- source = llm em todas. Este script sorteia 50
### delas e monta o caderno para conferencia a mao.
###
### SOMENTE INSPECAO. NADA volta para o field_manual_class.csv. As
### colunas em branco do caderno sao para anotacao do revisor e
### NENHUM script as le de volta -- a correcao volta conversada e o
### CSV e editado a mao. Sem esse aviso, coluna editavel sugeriria um
### ida-e-volta que nao existe.
###
### OFFLINE. Somente-leitura em relacao a TODOS os artefatos
### existentes. Nao mande para o SEDAP.
###
### Depende de:
###   revelio_br_cohort/field_manual_class.csv                    (10h)
###   revelio_br_cohort/obmep_candidates_selected_positions.parquet (21a)
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. OFFLINE, sem rede, fora do SEDAP.
### 2. SORTEIO PURAMENTE ALEATORIO, e o custo disso esta declarado, nao
###    escondido. E o unico desenho que estima sem vies a taxa de
###    concordancia GERAL. Em compensacao, a composicao esperada de 50
###    linhas e ~32 other, ~10 engineering, ~4 finance, ~3 science e
###    ~1 de matematica. Ou seja: este caderno diz o quanto o LLM
###    acerta EM GERAL e quase nada sobre os vereditos de matematica.
###    Para esses seria preciso um passe estratificado sobre as 25.
### 3. NAO SOBRESCREVE UM XLSX EXISTENTE nem re-sorteia se o parquet ja
###    existir. Apague para regerar.
### 4. position_id E bigint. Escrito como TEXTO e conferido contra
###    ^-?[0-9]+$ na ida E na releitura. Ver nota 8 da
###    role_title_audit.R: um as.character() sobre double ja corrompeu
###    499 de 500 ids em silencio.
### 5. TITULO QUE COMECA COM = + - @ E FORMULA PARA O EXCEL. O openxlsx
###    grava string como shared string, que o Excel nao avalia, mas o
###    Step 4 confere em vez de confiar.
### 7. O BLOCO DO REVELIO (colunas 11-17) E REFERENCIA, NAO GABARITO.
###    job_category classifica FUNCAO -- o que a pessoa faz. A coluna
###    `verdict` classifica CAMPO -- o dominio do trabalho. Professor de
###    matematica e math_academic num e Admin no outro, e OS DOIS estao
###    certos. Divergencia entre as duas colunas NAO e erro de nenhum
###    dos lados e nao deve ser contada como tal.
### 8. ANOTACAO DO REVISOR E PRESERVADA ao regerar. O caderno e lido
###    antes de ser apagado e as tres colunas voltam casadas por
###    position_id. Regerar por cima sem isso destruiria revisao que
###    nao existe em nenhum outro lugar.
### 9. role_k150 ATE role_k1000 REPETEM MUITO. A escada e aninhada e um
###    ramo que nao se subdivide carrega o rotulo do pai para baixo. A
###    informacao esta em job_category, role_k50 e role_k1500.
### 6. ACENTO PRE-COMPOSTO x DECOMPOSTO. title_raw e description
###    misturam as duas formas (c cedilha U+00E7 e c + U+0327). Na tela
###    sao iguais; em bytes nao. Isso nao afeta a exibicao, mas a
###    comparacao da releitura nao pode supor uma das formas.
###
####################################################################

rm(list = ls()); gc()

for (p in c("openxlsx", "DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(openxlsx)

####################################################################
### Parametros
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

class_path  <- file.path(coh_dir, "field_manual_class.csv")
sel_path    <- file.path(coh_dir, "obmep_candidates_selected_positions.parquet")
sample_path <- file.path(coh_dir, "field_review_sample.parquet")
xlsx_path   <- file.path(coh_dir, "field_manual_review.xlsx")

seed   <- 20260904L
n_draw <- 50L
vdom <- c("math_academic", "math_applied", "science", "engineering",
          "finance", "other")

# Os rotulos do Revelio, para comparacao lado a lado. role_k150 ate
# role_k1000 repetem MUITO: a escada e aninhada e um ramo que nao se
# subdivide carrega o rotulo do pai para baixo. A informacao esta
# concentrada em job_category, role_k50 e role_k1500.
rev_cols <- c("job_category", "role_k50", "role_k150", "role_k300",
              "role_k500", "role_k1000", "role_k1500")

if (!file.exists(class_path)) {
  stop("Nao encontrei ", class_path, ". Rode role_field_manual.R antes.")
}
if (!file.exists(sel_path)) {
  stop("Nao encontrei ", sel_path, ". Os rotulos do Revelio vem dali.")
}

cl <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
               colClasses = "character")
cl[is.na(cl)] <- ""

# Nota 4: a invariante, antes de qualquer coisa.
if (!all(grepl("^-?[0-9]+$", cl$position_id))) {
  stop(sum(!grepl("^-?[0-9]+$", cl$position_id)),
       " position_id do 10h nao sao inteiros exatos (nota 4).")
}
if (any(!nzchar(cl$verdict))) {
  stop(sum(!nzchar(cl$verdict)), " linha(s) do 10h sem verdict.")
}
cat("classificacao 10h :", nrow(cl), "linhas\n")

####################################################################
### Step 1: sortear 50 e estacionar
####################################################################

con <- DBI::dbConnect(duckdb::duckdb())
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
fw <- function(p) gsub("\\\\", "/", p)

DBI::dbWriteTable(con, "cl", cl, overwrite = TRUE)
# Nota 2: ORDER BY hash(...) LIMIT n, nunca USING SAMPLE -- o DuckDB o
# empurra para baixo do filtro (armadilha ja documentada no README).
sample_sql <- sprintf("
  SELECT position_id, title_raw, title_translated, description,
         verdict, verdict_2, evidence,
         hash(position_id || '#%d') AS hk
  FROM cl
  ORDER BY hk, position_id
  LIMIT %d", seed, n_draw)

if (file.exists(sample_path)) {
  cat("[skip] amostra ja existe:", basename(sample_path), "\n")
} else {
  invisible(DBI::dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    sample_sql, fw(sample_path))))
  cat("sorteadas", n_draw, "linhas\n")
}

s <- DBI::dbGetQuery(con, sprintf(
  "SELECT * EXCLUDE (hk), CAST(hk AS VARCHAR) AS hk
   FROM read_parquet('%s')", fw(sample_path)))
s$position_id <- as.character(s$position_id)

####################################################################
### Step 2: validar a amostra
####################################################################

cat("\n=========== VALIDACAO DA AMOSTRA ===========\n")
if (nrow(s) != n_draw) stop("A amostra tem ", nrow(s), ", esperado ", n_draw)
if (anyDuplicated(s$position_id) != 0) stop("position_id repetido.")
if (!all(grepl("^-?[0-9]+$", s$position_id))) {
  stop("position_id nao inteiro exato na amostra (nota 4).")
}
if (!all(s$position_id %in% cl$position_id)) {
  stop("Ha position_id na amostra que nao esta no 10h.")
}
s2 <- DBI::dbGetQuery(con, sample_sql)
s2$position_id <- as.character(s2$position_id)
if (!setequal(s$position_id, s2$position_id)) {
  stop("O mesmo seed devolveu amostra DIFERENTE.")
}
cat("[OK]", nrow(s), "linhas, ids exatos e unicos, seed reproduzivel\n")

####################################################################
### Step 3: montar o caderno
####################################################################

# Nota 7: rotulos do Revelio, juntados por position_id. CAST AS
# VARCHAR NOS DOIS LADOS -- e a armadilha bigint->double que ja
# corrompeu 499 ids (nota 4).
DBI::dbWriteTable(con, "ids", s[, "position_id", drop = FALSE],
                  overwrite = TRUE)
rev <- DBI::dbGetQuery(con, sprintf("
  SELECT CAST(p.position_id AS VARCHAR) AS position_id, %s
  FROM ids i JOIN read_parquet('%s') p
    ON CAST(p.position_id AS VARCHAR) = i.position_id",
  paste0("p.", rev_cols, collapse = ", "), fw(sel_path)))

if (nrow(rev) != n_draw) {
  stop(nrow(rev), " linhas voltaram do join, esperado ", n_draw,
       ". Alguma posicao da amostra nao esta no arquivo do 21a.")
}
if (anyDuplicated(rev$position_id) != 0) {
  stop("O join multiplicou linhas: position_id repetido no 21a.")
}
for (rc in rev_cols) {
  if (any(is.na(rev[[rc]])) || any(!nzchar(trimws(rev[[rc]])))) {
    stop("Rotulo vazio em ", rc, " apos o join -- aborta em vez de ",
         "entregar celula em branco.")
  }
}
cat("[OK] os", nrow(rev), "rotulos do Revelio juntaram por position_id\n")

# Nota 8: se o caderno ja existe, a anotacao do revisor e LIDA e
# carregada para o novo. Regerar por cima sem isso destruiria revisao
# que nao existe em nenhum outro lugar.
prev <- NULL
if (file.exists(xlsx_path)) {
  old <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra")
  for (j in names(old)) old[[j]] <- as.character(old[[j]])
  old[is.na(old)] <- ""
  if (!all(c("position_id", "sua_avaliacao") %in% names(old))) {
    stop("O caderno existente nao tem as colunas do revisor; nao da ",
         "para preservar anotacao. Mova-o antes de regerar.")
  }
  n_ann <- sum(nzchar(trimws(unlist(
    old[, c("sua_avaliacao", "sua_evidencia", "nota")]))))
  cat("caderno anterior  :", n_ann, "celula(s) de revisao preenchida(s)\n")
  prev <- old[, c("position_id", "sua_avaliacao", "sua_evidencia", "nota")]
  invisible(file.remove(xlsx_path))
}

am <- s[order(s$hk), c("position_id", "title_raw", "title_translated",
                       "description", "verdict", "verdict_2", "evidence")]
am$sua_avaliacao <- ""
am$sua_evidencia <- ""
am$nota <- ""

if (!is.null(prev)) {
  k <- match(am$position_id, prev$position_id)
  if (any(is.na(k))) {
    stop(sum(is.na(k)), " linha(s) do caderno anterior nao casaram por ",
         "position_id; a anotacao seria perdida em silencio.")
  }
  am$sua_avaliacao <- prev$sua_avaliacao[k]
  am$sua_evidencia <- prev$sua_evidencia[k]
  am$nota <- prev$nota[k]
  cat("[OK] anotacao do revisor preservada\n")
}

# O bloco do Revelio vai no fim, colunas 11-17, sem mexer no layout ja
# existente: texto 1-4, meu julgamento 5-7, revisor 8-10.
am <- cbind(am, rev[match(am$position_id, rev$position_id), rev_cols])

# Resumo: a composicao das 50 ao lado das 1.000, para dar para ver de
# relance se o sorteio saiu representativo.
res <- data.frame(campo = vdom, stringsAsFactors = FALSE)
res$n_1000 <- sapply(vdom, function(v) sum(cl$verdict == v))
res$pct_1000 <- round(100 * res$n_1000 / nrow(cl), 1)
res$n_50 <- sapply(vdom, function(v) sum(am$verdict == v))
res$pct_50 <- round(100 * res$n_50 / nrow(am), 1)
res$esperado_50 <- round(50 * res$n_1000 / nrow(cl), 1)

leia <- data.frame(c(
  "CADERNO DE AUDITORIA -- 50 linhas sorteadas da classificacao de campo",
  "",
  "O QUE ESTA AQUI",
  "A 10h classificou 1.000 posicoes sorteadas ao acaso no CAMPO a que o",
  "trabalho pertence, a partir de title_raw + description. Todas as 1.000",
  "sao julgamento do LLM, sem revisao humana. Estas 50 sao um sorteio",
  "aleatorio simples dessas 1.000.",
  "",
  "OS SEIS VALORES",
  "  math_academic  matematica de ENSINO e PESQUISA (professor, monitor,",
  "                 pesquisa academica em matematica)",
  "  math_applied   matematica APLICADA (estatistica, atuaria, quant,",
  "                 ciencia de dados, pesquisa operacional, econometria)",
  "  science        ciencias naturais e da vida, pesquisa cientifica",
  "                 fora da matematica",
  "  engineering    engenharias, software, TI, tecnico/industrial",
  "  finance        contabilidade, banco, investimento, credito,",
  "                 auditoria, tributos, planejamento financeiro",
  "  other          o resto: ensino que nao e de matematica, vendas,",
  "                 administrativo, marketing, saude, juridico",
  "",
  "COMO O LLM DECIDIU",
  "- O primario e o campo a que a SUBSTANCIA do trabalho pertence.",
  "- Empate real: ganha a categoria MAIS ESTREITA. Um quant em banco e",
  "  math_applied primario e finance secundario, nao o contrario.",
  "- verdict_2 so aparece quando o cargo cruza dois campos de verdade.",
  "- A coluna `evidence` tem de ser texto que EXISTE em title_raw ou",
  "  description. 999 das 1.000 casam por substring; 1 esta marcada",
  "  'inferred:'. Se uma evidencia parecer parafrase, e um achado.",
  "",
  "O QUE ESTE CADERNO NAO RESPONDE",
  "O sorteio e aleatorio simples, entao estima sem vies a concordancia",
  "GERAL -- mas a composicao esperada e ~32 other, ~10 engineering,",
  "~4 finance, ~3 science e ~1 de matematica. Sobre os vereditos de",
  "matematica, que sao 25 nas 1.000, estas 50 dizem quase nada. Para",
  "esses seria preciso um passe estratificado sobre as 25.",
  "",
  "SOMENTE INSPECAO",
  "As colunas sua_avaliacao / sua_evidencia / nota sao para anotacao do",
  "revisor. NENHUM SCRIPT AS LE DE VOLTA. Para corrigir um veredito,",
  "diga qual e o CSV e editado a mao.",
  "",
  "AS COLUNAS DO REVELIO (11-17) SAO REFERENCIA, NAO GABARITO",
  "job_category e role_k* classificam FUNCAO -- o que a pessoa faz.",
  "A coluna verdict classifica CAMPO -- o dominio do trabalho. Um",
  "professor de matematica e math_academic aqui e Admin la, e os dois",
  "estao certos. Divergir NAO e erro de nenhum dos lados.",
  "role_k150 ate role_k1000 costumam repetir o mesmo rotulo: a escada",
  "e aninhada. Olhe job_category, role_k50 e role_k1500.",
  "",
  "DUAS RESSALVAS DE LEITURA",
  "1. 42% das posicoes nao tem description; essas foram julgadas so",
  "   pelo titulo e sao por construcao mais fracas.",
  "2. Isto e CAMPO, nao funcao. Nao confunda com o job_category do",
  "   Revelio, que classifica o que a pessoa faz. Um professor de",
  "   matematica e math_academic aqui e Admin la, e os dois estao",
  "   certos."),
  stringsAsFactors = FALSE)
names(leia) <- "Como ler este caderno"

wb <- createWorkbook()
hdr  <- createStyle(textDecoration = "bold", fgFill = "#E8E8E8",
                    border = "bottom", valign = "top")
wrap <- createStyle(wrap = TRUE, valign = "top")
txt  <- createStyle(numFmt = "TEXT", valign = "top")
mine <- createStyle(fgFill = "#EEF4FB", valign = "top")
yours <- createStyle(fgFill = "#FFF7D6", border = "TopBottomLeftRight",
                     borderColour = "#C9A227", valign = "top")
revsty <- createStyle(fgFill = "#F3EFF7", valign = "top")

addWorksheet(wb, "Como ler")
writeData(wb, "Como ler", leia)
addStyle(wb, "Como ler", hdr, rows = 1, cols = 1)
setColWidths(wb, "Como ler", cols = 1, widths = 74)

addWorksheet(wb, "Amostra")
writeData(wb, "Amostra", am, withFilter = TRUE)
freezePane(wb, "Amostra", firstActiveRow = 2, firstActiveCol = 3)
addStyle(wb, "Amostra", hdr, rows = 1, cols = 1:17, gridExpand = TRUE)
# Nota 4: texto, tambem no formato da celula.
addStyle(wb, "Amostra", txt, rows = 2:(nrow(am) + 1), cols = 1, gridExpand = TRUE)
addStyle(wb, "Amostra", wrap, rows = 2:(nrow(am) + 1), cols = c(2, 3, 4),
         gridExpand = TRUE)
addStyle(wb, "Amostra", mine, rows = 2:(nrow(am) + 1), cols = 5:7,
         gridExpand = TRUE)
addStyle(wb, "Amostra", yours, rows = 2:(nrow(am) + 1), cols = 8:10,
         gridExpand = TRUE)
# Bloco do Revelio, fundo proprio: e referencia, nao gabarito (nota 9).
addStyle(wb, "Amostra", revsty, rows = 2:(nrow(am) + 1), cols = 11:17,
         gridExpand = TRUE)
setColWidths(wb, "Amostra", cols = 1:17,
             widths = c(16, 40, 32, 62, 15, 15, 34, 15, 26, 30,
                        14, 22, 22, 22, 22, 22, 24))
# O olho vai para o que nao e 'other'.
conditionalFormatting(wb, "Amostra", cols = 1:17, rows = 2:(nrow(am) + 1),
                      rule = '$E2<>"other"', type = "expression",
                      style = createStyle(bgFill = "#EAF5EA"))

addWorksheet(wb, "Resumo")
writeData(wb, "Resumo", "Composicao: as 50 sorteadas contra as 1.000",
          startRow = 1)
writeData(wb, "Resumo", res, startRow = 2)
addStyle(wb, "Resumo", hdr, rows = 2, cols = 1:6, gridExpand = TRUE)
setColWidths(wb, "Resumo", cols = 1:6, widths = c(16, 10, 11, 9, 9, 13))

saveWorkbook(wb, xlsx_path, overwrite = FALSE)

####################################################################
### Step 4: conferir a ida e volta antes de entregar
####################################################################

# Notas 4, 5 e 6: o unico jeito de saber se sobreviveu e reler.
chk <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra")
chk$position_id <- as.character(chk$position_id)
if (!all(grepl("^-?[0-9]+$", chk$position_id))) {
  stop("O xlsx gravou position_id em notacao cientifica (nota 4). ",
       "A invariante e ser inteiro exato, nao so bater com a origem.")
}
if (!identical(sort(chk$position_id), sort(am$position_id))) {
  stop("Os position_id nao sobreviveram a gravacao (nota 4).")
}
if (!identical(sort(chk$title_raw), sort(am$title_raw))) {
  stop("title_raw nao sobreviveu a gravacao (nota 5 ou 6).")
}
if (!identical(sort(chk$verdict), sort(am$verdict))) {
  stop("verdict nao sobreviveu a gravacao.")
}
cat("[OK] ida e volta conferida: id, titulo e veredito intactos\n")

cat("\n=========== COMPOSICAO ===========\n")
print(res, row.names = FALSE)

cat("\n=========== RESUMO ===========\n")
cat("  ", xlsx_path, "\n", sep = "")
cat(sprintf("  %d linhas | abas: Como ler | Amostra | Resumo\n", nrow(am)))
cat("  somente inspecao: nada e lido de volta (nota 3 do cabecalho)\n")
