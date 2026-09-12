####################################################################
### Caderno de revisao da auditoria de papeis (.xlsx)
###
### O gabarito da 10d esta 100% como o LLM o deixou. Este script faz
### os dois lados da revisao humana:
###
###   xlsx NAO existe  -> EXPORTA o caderno a partir do
###                       role_audit_class.csv
###   xlsx EXISTE      -> IMPORTA a coluna verdict_human de volta para
###                       o CSV, marca source=human nas linhas
###                       revisadas e diz o que mudou
###
### Para gerar de novo, APAGUE o xlsx. Nunca sobrescrevemos um caderno
### existente: ele pode conter revisao que nao existe em outro lugar.
### Mesma logica da nota 2 da 10d sobre nao re-sortear a amostra.
###
### OFFLINE. Nao usa rede, nao le Athena, nao escreve em S3. Nao mande
### nada disto para o SEDAP.
###
### Depende de:
###   revelio_br_cohort/role_audit_class.csv    (10d, o gabarito)
###   revelio_br_cohort/role_audit_vocab.csv    (10d)
###   revelio_br_cohort/obmep_candidates_selected_positions.parquet (21a)
###   revelio_br_cohort/obmep_candidates_step_1_position/           (10a)
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. OFFLINE E SEM REDE. Nao vai para o SEDAP.
### 2. NAO SOBRESCREVE UM XLSX EXISTENTE. Ver acima.
### 3. position_id E BIGINT E O EXCEL O DESTROI. Um inteiro de 13
###    digitos vira 1.23457E+12 na tela e, pior, pode voltar assim.
###    Isso quebraria a juncao em silencio ou, ainda pior, juntaria na
###    linha errada. Ele e escrito como TEXTO e, na importacao, o
###    conjunto de ids lido tem de bater EXATAMENTE com o do CSV --
###    aborta, e nao tenta recuperar numericamente. Recuperar seria
###    adivinhar.
###    Alem da igualdade, checamos a INVARIANTE (todo id e inteiro
###    exato) nas tres pontas: ao ler o CSV, ao reler o xlsx recem
###    gravado e ao importar. A igualdade sozinha ja falhou uma vez --
###    xlsx e CSV batiam porque os DOIS estavam corrompidos pela 10d.
###    Ver nota 8 da role_title_audit.R.
### 4. TITULO QUE COMECA COM = + - @ E FORMULA PARA O EXCEL. Sao
###    titulos digitados a mao no LinkedIn, entao acontece. O openxlsx
###    grava string como shared string (t="s"), que o Excel NAO
###    interpreta como formula, mas a checagem de ida e volta do
###    Step 4 confere isso em vez de confiar.
### 5. ACENTO. title_raw e portugues. O xlsx e UTF-8 por dentro, mas o
###    lado CSV so sobrevive com fileEncoding = "UTF-8" nas DUAS
###    pontas. "Garconete" e "Ilustradora" voltam quebrados se alguem
###    tirar isso.
### 6. SO LINHAS COM verdict_human PREENCHIDO SAO APLICADAS. Em branco
###    deixa o veredito do LLM como esta. Revisar 30 linhas e um
###    resultado valido; nao ha obrigacao de percorrer as 500.
### 7. reviewer_note E ANEXADA A note, nao substitui. Onde o humano
###    discorda, as duas leituras ficam visiveis no arquivo.
### 8. O CSV SO E ESCRITO DEPOIS QUE TUDO PASSA. Uma importacao
###    rejeitada deixa o gabarito intacto.
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

class_path <- file.path(coh_dir, "role_audit_class.csv")
vocab_path <- file.path(coh_dir, "role_audit_vocab.csv")
xlsx_path  <- file.path(coh_dir, "role_audit_review.xlsx")

sel_path <- file.path(coh_dir, "obmep_candidates_selected_positions.parquet")
pos_dir  <- file.path(coh_dir, "obmep_candidates_step_1_position")

ladder <- c("job_category", "role_k50", "role_k150", "role_k300",
            "role_k500", "role_k1000", "role_k1500")
vdom <- c("none", ladder, "undecidable")

# Ordem de gravidade: pior primeiro, undecidable por ultimo.
sev <- setNames(c(0, seq_along(ladder), 99), vdom)

if (!file.exists(class_path)) {
  stop("Nao encontrei ", class_path, ". Rode role_title_audit.R antes.")
}

# colClasses = "character" em TODAS as colunas: e o que impede o R de
# ler position_id como double e perder digito (nota 3).
cl <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
               colClasses = "character")
stopifnot(nrow(cl) > 0, "position_id" %in% names(cl))

# Nota 3: a INVARIANTE, checada antes de qualquer coisa. Comparar as
# duas pontas nao basta -- ja houve o caso em que xlsx e CSV
# concordavam porque os DOIS estavam corrompidos. Ver nota 8 da 10d.
if (!all(grepl("^-?[0-9]+$", cl$position_id))) {
  ruins <- cl$position_id[!grepl("^-?[0-9]+$", cl$position_id)]
  stop(length(ruins), " position_id do gabarito nao sao inteiros exatos: ",
       paste(head(ruins, 5), collapse = ", "),
       ". O CSV esta corrompido na origem; conserte a 10d antes.")
}

cat("gabarito :", basename(class_path), "-", nrow(cl), "linhas\n")
cat("caderno  :", xlsx_path, "\n\n")

####################################################################
### MODO IMPORTACAO
####################################################################

if (file.exists(xlsx_path)) {

  cat("=========== IMPORTANDO A REVISAO ===========\n")

  rv <- openxlsx::read.xlsx(xlsx_path, sheet = "Auditoria")
  # Tudo como texto, pelo mesmo motivo do CSV (nota 3).
  for (j in names(rv)) rv[[j]] <- as.character(rv[[j]])
  rv[is.na(rv)] <- ""

  for (need in c("position_id", "verdict_human", "reviewer_note")) {
    if (!need %in% names(rv)) {
      stop("A aba Auditoria nao tem a coluna ", need,
           ". O caderno foi editado de forma destrutiva.")
    }
  }

  # Nota 3: o conjunto de ids tem de bater EXATAMENTE. Nao ha
  # recuperacao numerica aqui de proposito.
  if (anyDuplicated(rv$position_id) != 0) {
    stop("position_id repetido no caderno: ",
         paste(head(unique(rv$position_id[duplicated(rv$position_id)]), 10),
               collapse = " | "))
  }
  if (!setequal(rv$position_id, cl$position_id)) {
    faltam <- setdiff(cl$position_id, rv$position_id)
    sobram <- setdiff(rv$position_id, cl$position_id)
    stop("Os position_id do caderno nao batem com os do gabarito.\n",
         "  faltando no caderno: ", length(faltam), " -> ",
         paste(head(faltam, 5), collapse = ", "), "\n",
         "  sobrando no caderno: ", length(sobram), " -> ",
         paste(head(sobram, 5), collapse = ", "), "\n",
         "  Se aparecem em notacao cientifica, o Excel converteu a ",
         "coluna para numero (nota 3). Nao da para recuperar: refaca ",
         "a revisao a partir de um caderno novo.")
  }
  if (!all(grepl("^-?[0-9]+$", rv$position_id))) {
    ruins <- rv$position_id[!grepl("^-?[0-9]+$", rv$position_id)]
    stop(length(ruins), " position_id voltaram do Excel sem ser inteiro ",
         "exato: ", paste(head(ruins, 5), collapse = ", "),
         ". O Excel converteu a coluna para numero (nota 3). Nao da ",
         "para recuperar: refaca a revisao a partir de um caderno novo.")
  }
  cat("[OK] os", nrow(rv), "position_id batem com o gabarito\n")

  rv$verdict_human <- trimws(rv$verdict_human)
  edited <- rv[nzchar(rv$verdict_human), ]

  if (nrow(edited) == 0) {
    cat("\nNenhuma linha com verdict_human preenchido. Nada a fazer.\n")
    cat("Preencha a coluna verdict_human na aba Auditoria e rode de novo.\n")
    quit(save = "no", status = 0)
  }

  off <- setdiff(edited$verdict_human, vdom)
  if (length(off)) {
    stop("verdict_human fora de {", paste(vdom, collapse = ", "), "}: ",
         paste(sort(unique(off)), collapse = ", "),
         "\n  O gabarito NAO foi alterado (nota 8).")
  }
  cat("[OK]", nrow(edited), "linha(s) revisada(s), dominio valido\n")

  # A partir daqui tudo passou; so agora o CSV muda (nota 8).
  idx <- match(edited$position_id, cl$position_id)
  antes <- cl$verdict[idx]
  depois <- edited$verdict_human

  mudou <- antes != depois
  cl$verdict[idx] <- depois
  cl$source[idx]  <- "human"

  # Nota 7: anexa, nao substitui.
  rn <- trimws(edited$reviewer_note)
  tem <- nzchar(rn)
  if (any(tem)) {
    velha <- cl$note[idx][tem]
    cl$note[idx][tem] <- ifelse(nzchar(velha),
                                paste0(velha, " || revisor: ", rn[tem]),
                                paste0("revisor: ", rn[tem]))
  }

  write.csv(cl, class_path, row.names = FALSE, fileEncoding = "UTF-8")

  cat("\n=========== O QUE MUDOU ===========\n")
  cat("  linhas revisadas          :", nrow(edited), "\n")
  cat("  vereditos efetivamente    :", sum(mudou), "\n")
  cat("  confirmaram o LLM         :", sum(!mudou), "\n")
  if (sum(mudou) > 0) {
    cat("\n  antes -> depois\n")
    ch <- data.frame(de = antes[mudou], para = depois[mudou],
                     stringsAsFactors = FALSE)
    tb <- table(paste(ch$de, "->", ch$para))
    for (nm in names(sort(tb, decreasing = TRUE))) {
      cat(sprintf("    %-34s %d\n", nm, tb[[nm]]))
    }
  }
  n_h <- sum(cl$source == "human")
  cat(sprintf("\n  gabarito agora: %d human, %d llm (%.0f%% revisado)\n",
              n_h, nrow(cl) - n_h, 100 * n_h / nrow(cl)))
  cat("\nRode a auditoria de novo para as taxas atualizadas:\n")
  cat("  Rscript prep/building_external_data/role_title_audit.R\n")
  quit(save = "no", status = 0)
}

####################################################################
### MODO EXPORTACAO -- Step 1: montar as tabelas
####################################################################

cat("=========== MONTANDO O CADERNO ===========\n")

if (!all(c("verdict", "better", "note") %in% names(cl))) {
  stop("O gabarito ainda nao foi classificado: faltam verdict/better/note.")
}
if (any(!nzchar(trimws(cl$verdict)))) {
  stop(sum(!nzchar(trimws(cl$verdict))), " linha(s) do gabarito sem ",
       "veredito. Classifique antes de exportar o caderno.")
}

# --- aba Auditoria, pior primeiro ---------------------------------
aud <- cl
aud$.sev <- sev[aud$verdict]
aud <- aud[order(aud$.sev, aud$job_category, aud$title_raw), ]
aud$.sev <- NULL
aud$verdict_human <- ""
aud$reviewer_note <- ""
aud_cols <- c("position_id", "title_raw", "title_translated", ladder,
              "seniority", "verdict", "better", "note",
              "verdict_human", "reviewer_note")
aud <- aud[, aud_cols]

# --- aba Resumo ---------------------------------------------------
depth <- setNames(seq_along(ladder), ladder)
vd <- ifelse(cl$verdict == "none", 0L,
             ifelse(cl$verdict == "undecidable", NA_integer_,
                    depth[cl$verdict]))
dec <- cl[!is.na(vd), ]
vdec <- vd[!is.na(vd)]
n_dec <- length(vdec)

ci_lo <- function(k, n) if (k == 0) 0 else as.numeric(binom.test(k, n)$conf.int)[1]
ci_hi <- function(k, n) if (k == n) 1 else as.numeric(binom.test(k, n)$conf.int)[2]

res <- data.frame(
  nivel = ladder,
  certos = sapply(ladder, function(l) sum(vdec >= depth[[l]])),
  decidiveis = n_dec, stringsAsFactors = FALSE)
res$acerto_pct <- round(100 * res$certos / res$decidiveis, 1)
res$ic95_inf <- round(100 * mapply(ci_lo, res$certos, res$decidiveis), 1)
res$ic95_sup <- round(100 * mapply(ci_hi, res$certos, res$decidiveis), 1)

dist <- as.data.frame(table(factor(cl$verdict, levels = vdom)),
                      stringsAsFactors = FALSE)
names(dist) <- c("veredito", "linhas")
dist$pct <- round(100 * dist$linhas / nrow(cl), 1)
dist$significado <- c(
  "o proprio job_category esta errado",
  "certo no nivel k7, role_k50 errado",
  "certo ate k50, role_k150 errado",
  "certo ate k150, role_k300 errado",
  "certo ate k300, role_k500 errado",
  "certo ate k500, role_k1000 errado",
  "certo ate k1000, role_k1500 errado",
  "certo o caminho inteiro",
  "title_raw nao carrega ocupacao; fora do denominador")

cats <- sort(unique(dec$job_category))
porcat <- data.frame(
  job_category = cats,
  certos = sapply(cats, function(g) sum(vdec[dec$job_category == g] >= 1L)),
  linhas = sapply(cats, function(g) sum(dec$job_category == g)),
  stringsAsFactors = FALSE)
porcat$acerto_pct <- round(100 * porcat$certos / porcat$linhas, 1)
porcat$ic95_inf <- round(100 * mapply(ci_lo, porcat$certos, porcat$linhas), 1)
porcat$ic95_sup <- round(100 * mapply(ci_hi, porcat$certos, porcat$linhas), 1)
porcat <- porcat[order(-porcat$acerto_pct), ]

# --- aba Titulos vazios, medida na base inteira -------------------
cat("medindo a dispersao dos titulos sem conteudo...\n")
con <- DBI::dbConnect(duckdb::duckdb())
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(DBI::dbExecute(con, "PRAGMA memory_limit='8GB'"))
fw <- function(p) gsub("\\\\", "/", p)
vazios <- DBI::dbGetQuery(con, sprintf("
  SELECT lower(trim(p.title_raw)) AS title_raw, count(*) AS posicoes,
         count(DISTINCT r.job_category) AS d_job_category,
         count(DISTINCT r.role_k50) AS d_role_k50,
         count(DISTINCT r.role_k1500) AS d_role_k1500
  FROM read_parquet('%s') r
  JOIN read_parquet('%s/*') p ON r.position_id = p.position_id
  WHERE lower(trim(p.title_raw)) IN
    ('estagiario','estagiaria','estagiario','estagiaria','trainee','intern',
     'bolsista','aprendiz','jovem aprendiz','voluntario','voluntaria',
     'estudante','estagiario','estagiaria')
     OR lower(trim(p.title_raw)) LIKE 'estagi%%'
  GROUP BY 1 HAVING count(*) >= 200 ORDER BY posicoes DESC",
  fw(sel_path), fw(pos_dir)))

# --- aba Vocabulario ----------------------------------------------
voc <- if (file.exists(vocab_path)) {
  read.csv(vocab_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8")
} else {
  data.frame(nivel = character(), rotulo = character(),
             pai = character(), n = integer())
}

# --- aba Como ler --------------------------------------------------
leia <- data.frame(c(
  "CADERNO DE REVISAO -- auditoria da escada de papeis do Revelio",
  "",
  "O QUE ESTA SENDO MEDIDO",
  "Para cada posicao, o caminho de rotulos que o Revelio pendura nela",
  "descreve o titulo que a pessoa escreveu (title_raw)?",
  "",
  "A escada e ESTRITAMENTE ANINHADA -- todo role_k50 tem exatamente um",
  "job_category, e assim por diante ate role_k1500. Entao cada linha",
  "carrega UM caminho, e o veredito e o nivel MAIS FUNDO ainda correto.",
  "O acerto de cada nivel sai desse unico julgamento.",
  "",
  "OS NOVE VALORES DE verdict_human",
  "  none          o proprio job_category esta errado",
  "  job_category  certo no nivel k7, role_k50 errado",
  "  role_k50      certo ate k50, role_k150 errado",
  "  role_k150     certo ate k150, role_k300 errado",
  "  role_k300     certo ate k300, role_k500 errado",
  "  role_k500     certo ate k500, role_k1000 errado",
  "  role_k1000    certo ate k1000, role_k1500 errado",
  "  role_k1500    certo o caminho inteiro",
  "  undecidable   title_raw nao carrega ocupacao nenhuma",
  "",
  "COMO REVISAR",
  "Aba Auditoria, ordenada do pior para o melhor: as linhas que o LLM",
  "julgou totalmente erradas vem primeiro. A coluna verdict (do LLM) e",
  "as notas dele estao visiveis. Preencha verdict_human SO onde voce",
  "discorda ou quer confirmar; em branco mantem o veredito do LLM.",
  "A celula tem lista suspensa com os nove valores.",
  "reviewer_note e livre e fica ANEXADA a nota do LLM, nao a substitui.",
  "",
  "Revisar 30 linhas ja e um resultado. Nao precisa percorrer as 500.",
  "Depois de salvar, rode:",
  "  Rscript prep/building_external_data/role_audit_review.R",
  "para trazer a revisao de volta, e depois role_title_audit.R para as",
  "taxas atualizadas.",
  "",
  "TRES COISAS QUE MUDAM O JULGAMENTO",
  "1. Julgue contra title_raw, NUNCA contra title_translated. A",
  "   traducao erra feio: 'Garconete' virou 'boy', 'Presidente' virou",
  "   'resident'. Ela esta ali so como apoio de leitura.",
  "2. Rotulo grosso e NOME DE GRUPO, nao rotulo literal. 'Medical Rep'",
  "   e na pratica o grupo de saude (contem Nurse, Paramedic); ",
  "   'Corporate Trainer' e o grupo de ensino. Julgue se o titulo cabe",
  "   no grupo, nao se a palavra bate.",
  "3. A coluna better diz se EXISTIA rotulo melhor. 'none' ali",
  "   significa que a taxonomia nao tem resposta certa -- limite do",
  "   vocabulario, nao do classificador. A aba Vocabulario lista os",
  "   1.557 rotulos disponiveis para conferir isso.",
  "",
  "O QUE ISTO NAO MEDE",
  "Precisao, nunca cobertura. Se um rotulo junta dois trabalhos",
  "diferentes sob o mesmo nome, as duas linhas contam como certas."),
  stringsAsFactors = FALSE)
names(leia) <- "Como ler este caderno"

####################################################################
### Step 2: escrever o xlsx
####################################################################

wb <- createWorkbook()

hdr <- createStyle(textDecoration = "bold", fgFill = "#E8E8E8",
                   border = "bottom", valign = "top")
wrap <- createStyle(wrap = TRUE, valign = "top")
txt  <- createStyle(numFmt = "TEXT", valign = "top")
edit <- createStyle(fgFill = "#FFF7D6", border = "TopBottomLeftRight",
                    borderColour = "#C9A227", valign = "top")

addWorksheet(wb, "Como ler")
writeData(wb, "Como ler", leia)
addStyle(wb, "Como ler", hdr, rows = 1, cols = 1)
setColWidths(wb, "Como ler", cols = 1, widths = 78)

addWorksheet(wb, "Auditoria")
writeData(wb, "Auditoria", aud, withFilter = TRUE)
freezePane(wb, "Auditoria", firstActiveRow = 2, firstActiveCol = 3)
addStyle(wb, "Auditoria", hdr, rows = 1, cols = seq_along(aud_cols),
         gridExpand = TRUE)
# Nota 3: position_id como texto, tambem no formato da celula.
addStyle(wb, "Auditoria", txt, rows = 2:(nrow(aud) + 1), cols = 1,
         gridExpand = TRUE)
addStyle(wb, "Auditoria", wrap, rows = 2:(nrow(aud) + 1),
         cols = c(2, 3, 14), gridExpand = TRUE)
addStyle(wb, "Auditoria", edit, rows = 2:(nrow(aud) + 1), cols = 15:16,
         gridExpand = TRUE)
setColWidths(wb, "Auditoria",
             cols = seq_along(aud_cols),
             widths = c(16, 46, 34, 13, 20, 20, 20, 20, 20, 22, 5,
                        13, 22, 52, 15, 34))

# Lista suspensa a partir de uma aba escondida: 'inline' estoura o
# limite de tamanho do Excel com facilidade e falha em silencio.
addWorksheet(wb, "dominio")
writeData(wb, "dominio", data.frame(verdict = vdom))
sheetVisibility(wb)[which(names(wb) == "dominio")] <- "hidden"
dataValidation(wb, "Auditoria", col = 15, rows = 2:(nrow(aud) + 1),
               type = "list", value = "'dominio'!$A$2:$A$10")

# O olho vai direto para os piores.
conditionalFormatting(
  wb, "Auditoria", cols = 1:16, rows = 2:(nrow(aud) + 1),
  rule = '$L2="none"', type = "expression",
  style = createStyle(bgFill = "#FADBD8"))
conditionalFormatting(
  wb, "Auditoria", cols = 1:16, rows = 2:(nrow(aud) + 1),
  rule = '$L2="undecidable"', type = "expression",
  style = createStyle(bgFill = "#EDEDED"))

addWorksheet(wb, "Resumo")
writeData(wb, "Resumo", "Acerto por nivel (denominador = decidiveis)",
          startRow = 1)
writeData(wb, "Resumo", res, startRow = 2)
writeData(wb, "Resumo", "Onde o caminho quebra (denominador = 500)",
          startRow = nrow(res) + 5)
writeData(wb, "Resumo", dist, startRow = nrow(res) + 6)
r3 <- nrow(res) + nrow(dist) + 9
writeData(wb, "Resumo", "Acerto de job_category por categoria", startRow = r3)
writeData(wb, "Resumo", porcat, startRow = r3 + 1)
addStyle(wb, "Resumo", hdr, rows = c(2, nrow(res) + 6, r3 + 1), cols = 1:6,
         gridExpand = TRUE)
setColWidths(wb, "Resumo", cols = 1:6, widths = c(16, 12, 12, 13, 11, 11))

addWorksheet(wb, "Titulos vazios")
writeData(wb, "Titulos vazios", vazios, withFilter = TRUE)
addStyle(wb, "Titulos vazios", hdr, rows = 1, cols = 1:5, gridExpand = TRUE)
setColWidths(wb, "Titulos vazios", cols = 1:5, widths = c(26, 12, 17, 14, 16))

addWorksheet(wb, "Vocabulario")
writeData(wb, "Vocabulario", voc, withFilter = TRUE)
freezePane(wb, "Vocabulario", firstActiveRow = 2)
addStyle(wb, "Vocabulario", hdr, rows = 1, cols = 1:4, gridExpand = TRUE)
setColWidths(wb, "Vocabulario", cols = 1:4, widths = c(14, 40, 26, 12))

saveWorkbook(wb, xlsx_path, overwrite = FALSE)

####################################################################
### Step 3: conferir a ida e volta antes de entregar
####################################################################

# Nota 3 e 4: o unico jeito de saber se o position_id e o titulo
# sobreviveram e reler o arquivo gravado.
chk <- openxlsx::read.xlsx(xlsx_path, sheet = "Auditoria")
chk$position_id <- as.character(chk$position_id)
if (!all(grepl("^-?[0-9]+$", chk$position_id))) {
  stop("O xlsx gravado tem position_id em notacao cientifica (nota 3). ",
       "Igualdade entre as pontas nao basta: a invariante e que todo id ",
       "seja inteiro exato.")
}
if (!identical(sort(chk$position_id), sort(aud$position_id))) {
  stop("Os position_id nao sobreviveram a gravacao do xlsx (nota 3). ",
       "O caderno nao serve para reimportar.")
}
if (!identical(sort(chk$title_raw), sort(aud$title_raw))) {
  stop("title_raw nao sobreviveu a gravacao (nota 4 ou 5): formula ou ",
       "acento quebrado.")
}
cat("[OK] ida e volta conferida: position_id e title_raw intactos\n")

cat("\n=========== RESUMO ===========\n")
cat("  ", xlsx_path, "\n", sep = "")
cat(sprintf("  %d linhas, piores primeiro (%d 'none', %d undecidable)\n",
            nrow(aud), sum(cl$verdict == "none"),
            sum(cl$verdict == "undecidable")))
cat("  abas: Como ler | Auditoria | Resumo | Titulos vazios | Vocabulario\n")
cat("  preencha verdict_human e rode este script de novo para importar\n")
