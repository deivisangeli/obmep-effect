####################################################################
### Classificacao manual de CAMPO em 1.000 posicoes sorteadas
###
### Tudo o que veio antes auditou os rotulos DO REVELIO. Isto constroi
### um rotulo INDEPENDENTE: 1.000 posicoes sorteadas ao acaso,
### classificadas a mao a partir de title_raw + description no campo a
### que o trabalho pertence, com a evidencia de cada decisao gravada.
###
### OFFLINE. Somente-leitura em relacao ao pipeline. Nao escreve em
### nenhum gabarito existente. Nao mande para o SEDAP.
###
### Depende de:
###   revelio_br_cohort/obmep_candidates_selected_positions.parquet (21a)
###   revelio_br_cohort/obmep_candidates_step_1_position/           (10a)
###
### -----------------------------------------------------------------
### ISTO NAO E MAIS UMA AUDITORIA DE ACERTO
### -----------------------------------------------------------------
### O job_category do Revelio classifica FUNCAO -- o que a pessoa faz.
### Isto classifica CAMPO -- o dominio a que o trabalho pertence. Um
### professor de matematica e math_academic aqui e Admin la, e OS DOIS
### ESTAO CERTOS. Cruzar as duas colunas e DESCRITIVO, nunca medida de
### erro do Revelio. Se alguem ler o cruzamento como terceira taxa de
### acerto, leu errado.
###
### -----------------------------------------------------------------
### RUBRICA -- seis valores
### -----------------------------------------------------------------
###   math_academic  matematica de ENSINO e PESQUISA: professor,
###                  tutor, monitor de matematica, pesquisa academica
###                  em matematica
###   math_applied   matematica APLICADA: estatistica, atuaria,
###                  quantitativo, ciencia de dados, pesquisa
###                  operacional, econometria
###   science        ciencias naturais e da vida, e pesquisa
###                  cientifica fora da matematica
###   engineering    engenharias, mais software, TI e trabalho
###                  tecnico/industrial
###   finance        contabilidade, banco, investimento, credito,
###                  auditoria, tributos, planejamento financeiro
###   other          todo o resto: ensino que nao e de matematica,
###                  vendas, administrativo, marketing, saude,
###                  juridico, alimentacao
###
### verdict_2 e OPCIONAL, do mesmo dominio, para quem realmente cruza
### dois campos: bioestatistico e math_applied + science; engenheiro
### financeiro e engineering + finance. Em branco quando um campo
### domina com folga.
###
### O primario e o campo a que a SUBSTANCIA do trabalho pertence.
### Empate real: ganha a categoria MAIS ESTREITA, entao as duas de
### matematica tem precedencia sobre science/engineering/finance -- um
### quant em banco e math_applied primario, finance secundario. Separar
### matematica so faz sentido se ela nao for engolida pelos campos
### largos.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. OFFLINE, sem rede, fora do SEDAP.
### 2. 'other' E CATEGORIA DE VERDADE, nao valvula de escape. Medido
###    antes de sortear: so 41.0% das posicoes estao em
###    Engineer/Scientist/Finance pelo proprio Revelio, entao ~600 das
###    1.000 caem fora dos campos pedidos. Como o sorteio e aleatorio,
###    a distribuicao final tambem e estimativa de PREVALENCIA.
### 3. A EVIDENCIA TEM DE EXISTIR NO TEXTO. O Step 5 confere por
###    substring normalizada (minuscula, sem acento, pontuacao
###    colapsada) que cada evidencia aparece em title_raw ou
###    description. Sem isso a coluna vira racionalizacao a posteriori.
###    O prefixo 'inferred:' e permitido para a inferencia genuina e
###    essas linhas sao CONTADAS a parte, nao escondidas.
###    A normalizacao TEM de tirar marcas combinantes: a description
###    vem com acento decomposto (c + U+0327) e a evidencia digitada
###    vem pre-composta (U+00E7). Iguais na tela, diferentes em bytes.
###    Essa checagem pegou exatamente isso na primeira rodada.
### 4. A PLANILHA E CEGA AOS ROTULOS DO REVELIO. Nem job_category nem
###    role_k* chegam nela: eles ancorariam o julgamento, e mante-los
###    fora e o que permite usar esta coluna depois como referencia
###    independente. O Step 3 ABORTA se algum vazar.
### 5. 44.7% DAS POSICOES NAO TEM DESCRIPTION. Essas sao julgadas so
###    pelo titulo. Nao sao excluidas -- excluir enviesaria a
###    prevalencia -- mas a leitura delas e mais pobre por construcao.
### 6. position_id E bigint: CAST AS VARCHAR no SQL, sempre, inclusive
###    na releitura. Ver nota 8 da role_title_audit.R -- ja custou 499
###    ids errados.
### 7. NAO CONFUNDIR com prep/field_classification_gpt.r, que
###    classifica NOME DE CURSO do censo em STEM via GPT. Outro
###    insumo, outra taxonomia, outro mecanismo.
###
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb")) {
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
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

sel_path <- file.path(coh_dir, "obmep_candidates_selected_positions.parquet")
pos_dir  <- file.path(coh_dir, "obmep_candidates_step_1_position")

sample_path <- file.path(coh_dir, "field_manual_sample.parquet")
class_path  <- file.path(coh_dir, "field_manual_class.csv")

seed    <- 20260903L
n_draw  <- 1000L
vdom <- c("math_academic", "math_applied", "science", "engineering",
          "finance", "other")

if (!file.exists(sel_path)) stop("Nao encontrei ", sel_path)
if (!dir.exists(pos_dir)) stop("Nao encontrei ", pos_dir)

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(dbExecute(con, "PRAGMA memory_limit='8GB'"))
fw <- function(p) gsub("\\\\", "/", p)
sel_src <- sprintf("read_parquet('%s')", fw(sel_path))
pos_src <- sprintf("read_parquet('%s/*')", fw(pos_dir))

####################################################################
### Step 1: sortear e estacionar
####################################################################

# Nota 6: CAST AS VARCHAR. Nota da 10d: ORDER BY hash(...) LIMIT n,
# nunca USING SAMPLE.
sample_sql <- sprintf("
  SELECT CAST(r.position_id AS VARCHAR) AS position_id,
         p.title_raw,
         coalesce(p.title_translated, '') AS title_translated,
         coalesce(p.description, '') AS description,
         r.job_category, r.role_k50, r.role_k1500,
         hash(CAST(r.position_id AS VARCHAR) || '#%d') AS hk
  FROM %s r
  JOIN %s p ON r.position_id = p.position_id
  WHERE p.title_raw IS NOT NULL AND trim(p.title_raw) <> ''
  ORDER BY hk, r.position_id
  LIMIT %d", seed, sel_src, pos_src, n_draw)

if (file.exists(sample_path)) {
  cat("[skip] amostra ja existe:", basename(sample_path), "\n")
} else {
  cat("Sorteando", n_draw, "posicoes...\n")
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    sample_sql, fw(sample_path))))
}

# Nota 6 outra vez: SELECT * traria o bigint como double.
s <- dbGetQuery(con, sprintf(
  "SELECT * EXCLUDE (position_id, hk),
          CAST(position_id AS VARCHAR) AS position_id,
          CAST(hk AS VARCHAR) AS hk
   FROM read_parquet('%s')", fw(sample_path)))

####################################################################
### Step 2: validar a amostra
####################################################################

cat("\n=========== VALIDACAO DA AMOSTRA ===========\n")
if (nrow(s) != n_draw) stop("A amostra tem ", nrow(s), ", esperado ", n_draw)
if (anyDuplicated(s$position_id) != 0) stop("position_id repetido.")
if (!all(grepl("^-?[0-9]+$", s$position_id))) {
  stop("position_id nao inteiro exato -- o CAST caiu (nota 6).")
}
if (any(trimws(s$title_raw) == "")) stop("title_raw vazio na amostra.")
s2 <- dbGetQuery(con, sample_sql)
s2$position_id <- as.character(s2$position_id)
if (!setequal(s$position_id, s2$position_id)) {
  stop("O mesmo seed devolveu amostra DIFERENTE.")
}
n_desc <- sum(nzchar(trimws(s$description)))
cat(sprintf("[OK] %d linhas, ids exatos e unicos, seed reproduzivel\n", nrow(s)))
cat(sprintf("     com description: %d (%.1f%%)  so titulo: %d (%.1f%%) -- nota 5\n",
            n_desc, 100 * n_desc / nrow(s), nrow(s) - n_desc,
            100 * (nrow(s) - n_desc) / nrow(s)))

####################################################################
### Step 3: a planilha, cega aos rotulos do Revelio
####################################################################

if (!file.exists(class_path)) {
  w <- s[order(s$hk), c("position_id", "title_raw", "title_translated",
                        "description")]
  # Nota 4: nenhum rotulo do Revelio pode chegar na planilha.
  leak <- intersect(names(w), c("job_category", "role_k50", "role_k150",
                                "role_k300", "role_k500", "role_k1000",
                                "role_k1500"))
  if (length(leak)) {
    stop("A planilha vazaria ", paste(leak, collapse = ", "),
         " -- isso ancoraria o julgamento (nota 4).")
  }
  w$verdict <- ""
  w$verdict_2 <- ""
  w$evidence <- ""
  w$source <- ""
  write.csv(w, class_path, row.names = FALSE, fileEncoding = "UTF-8")
  cat("\n[novo] planilha escrita:\n  ", class_path, "\n", sep = "")
  cat("\nPreencha nas ", nrow(w), " linhas:\n", sep = "")
  cat("  verdict   : um de ", paste(vdom, collapse = ", "), "\n", sep = "")
  cat("  verdict_2 : opcional, do mesmo dominio, diferente de verdict\n")
  cat("  evidence  : a palavra ou expressao que decidiu, COPIADA do\n")
  cat("              title_raw ou da description (nota 3)\n")
  cat("Depois rode este script de novo para o relatorio.\n")
  quit(save = "no", status = 0)
}

####################################################################
### Step 4: ler e validar a planilha
####################################################################

cat("\n=========== VALIDACAO DA PLANILHA ===========\n")
cl <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
               colClasses = "character")
cl[is.na(cl)] <- ""

if (!all(grepl("^-?[0-9]+$", cl$position_id))) {
  stop("position_id da planilha nao e inteiro exato (nota 6).")
}
if (anyDuplicated(cl$position_id) != 0) stop("position_id repetido na planilha.")
miss <- setdiff(s$position_id, cl$position_id)
if (length(miss)) {
  stop(length(miss), " posicao(oes) sem classificacao: ",
       paste(head(miss, 10), collapse = " | "))
}
off <- setdiff(cl$verdict, vdom)
if (length(off)) {
  stop("verdict fora de {", paste(vdom, collapse = ", "), "}: ",
       paste(sort(unique(off)), collapse = ", "))
}
off2 <- setdiff(cl$verdict_2[nzchar(cl$verdict_2)], vdom)
if (length(off2)) {
  stop("verdict_2 fora do dominio: ", paste(sort(unique(off2)), collapse = ", "))
}
same <- nzchar(cl$verdict_2) & cl$verdict_2 == cl$verdict
if (any(same)) {
  stop(sum(same), " linha(s) com verdict_2 igual a verdict; deixe em branco.")
}
if (any(!nzchar(trimws(cl$evidence)))) {
  stop(sum(!nzchar(trimws(cl$evidence))), " linha(s) sem evidence (nota 3).")
}
cat("[OK]", nrow(cl), "linhas, dominio valido, evidence presente em todas\n")

####################################################################
### Step 5: a evidencia existe mesmo no texto? (nota 3)
####################################################################

nrm <- function(x) {
  x <- tolower(x)
  # Acento DECOMPOSTO (NFD): o texto do LinkedIn traz tanto o c
  # cedilha pre-composto (U+00E7) quanto c + cedilha combinante
  # (U+0327). Sao identicos na tela e diferentes em bytes, entao
  # as marcas combinantes saem ANTES das substituicoes abaixo.
  x <- gsub('[̀-ͯ]', '', x, perl = TRUE)
  x <- gsub("[\u00e1\u00e0\u00e2\u00e3\u00e4]", "a", x)
  x <- gsub("[\u00e9\u00e8\u00ea\u00eb]", "e", x)
  x <- gsub("[\u00ed\u00ec\u00ee\u00ef]", "i", x)
  x <- gsub("[\u00f3\u00f2\u00f4\u00f5\u00f6]", "o", x)
  x <- gsub("[\u00fa\u00f9\u00fb\u00fc]", "u", x)
  x <- gsub("\u00e7", "c", x)
  x <- gsub("[^a-z0-9]+", " ", x)
  trimws(x)
}

m <- merge(cl, s[, c("position_id", "title_raw", "description")],
           by = "position_id", suffixes = c("", ".s"))
stopifnot(nrow(m) == n_draw)
hay <- paste(nrm(m$title_raw.s), nrm(m$description.s))
ev <- trimws(m$evidence)
inferred <- grepl("^inferred:", ev)
needle <- nrm(sub("^inferred:", "", ev))
ok <- mapply(function(n, h) nzchar(n) && grepl(n, h, fixed = TRUE),
             needle, hay)
bad <- which(!ok & !inferred)

cat("\n=========== INTEGRIDADE DA EVIDENCIA (nota 3) ===========\n")
cat(sprintf("  casam por substring : %d (%.1f%%)\n", sum(ok & !inferred),
            100 * sum(ok & !inferred) / nrow(m)))
cat(sprintf("  marcadas 'inferred:': %d (%.1f%%)\n", sum(inferred),
            100 * sum(inferred) / nrow(m)))
cat(sprintf("  NAO encontradas     : %d\n", length(bad)))
if (length(bad)) {
  cat("  (listadas, nao aceitas em silencio)\n")
  for (i in head(bad, 15)) {
    cat(sprintf("    \"%s\" nao aparece em: %s\n",
                substr(ev[i], 1, 30), substr(m$title_raw.s[i], 1, 46)))
  }
}

####################################################################
### Step 6: prevalencia
####################################################################

ci_txt <- function(k, n) {
  if (n == 0) return("      n/a       ")
  ci <- if (k == 0) c(0, 1 - 0.05^(1 / n)) else
    if (k == n) c(0.05^(1 / n), 1) else as.numeric(binom.test(k, n)$conf.int)
  sprintf("[%5.1f%%, %5.1f%%]", 100 * ci[1], 100 * ci[2])
}

cat("\n=========== PREVALENCIA (amostra aleatoria, n=1000) ===========\n")
cat("  campo            n     share   IC 95% exato\n")
for (v in vdom) {
  k <- sum(cl$verdict == v)
  cat(sprintf("  %-14s %4d  %6.1f%%   %s\n", v, k, 100 * k / nrow(cl),
              ci_txt(k, nrow(cl))))
}

km <- sum(cl$verdict %in% c("math_academic", "math_applied"))
km2 <- sum(cl$verdict %in% c("math_academic", "math_applied") |
           cl$verdict_2 %in% c("math_academic", "math_applied"))
cat(sprintf("\n  matematica (primario)        : %d  %.1f%%  %s\n",
            km, 100 * km / nrow(cl), ci_txt(km, nrow(cl))))
cat(sprintf("  matematica (inclui secundario): %d  %.1f%%  %s\n",
            km2, 100 * km2 / nrow(cl), ci_txt(km2, nrow(cl))))

n2 <- sum(nzchar(cl$verdict_2))
cat(sprintf("\n  com rotulo secundario: %d (%.1f%%)\n", n2, 100 * n2 / nrow(cl)))
if (n2 > 0) {
  pairs <- paste(cl$verdict[nzchar(cl$verdict_2)], "+",
                 cl$verdict_2[nzchar(cl$verdict_2)])
  tb <- sort(table(pairs), decreasing = TRUE)
  for (nm in head(names(tb), 8)) cat(sprintf("    %-34s %d\n", nm, tb[[nm]]))
}

####################################################################
### Step 7: cruzamento com o Revelio -- DESCRITIVO
####################################################################

cat("\n=========== CAMPO (manual) x job_category (Revelio) ===========\n")
cat("  DESCRITIVO, nao medida de erro: as duas colunas medem coisas\n")
cat("  diferentes -- campo contra funcao. Ver o bloco no cabecalho.\n\n")
x <- merge(cl[, c("position_id", "verdict")],
           s[, c("position_id", "job_category")], by = "position_id")
print(table(campo = x$verdict, funcao = x$job_category))

cat("\n[OK] relatorio completo\n")
