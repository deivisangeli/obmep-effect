####################################################################
### A escada de papeis relida COM a description, as cegas
###
### A 10d julgou os rotulos so contra title_raw. Foi decisao
### deliberada, mas talvez injusta: description esta no mesmo extrato
### da 10a, existe em 263 das 500 linhas da amostra, e resolve o que o
### titulo nao resolve. Tres exemplos vistos a olho:
###
###   "Socia"          -> undecidable na 10d. A description e projeto
###                       arquitetonico em ArchiCAD/AutoCAD. Engineer
###                       esta CERTO.
###   "Account Manager"-> wrong na 10d. A description e planejamento
###                       financeiro e consultoria de investimento.
###                       Finance esta CERTO.
###   "Novos projetos" -> undecidable na 10d. A description e
###                       prospeccao ativa e reuniao com cliente.
###                       Finance esta ERRADO.
###
### Ou seja: o veredito anda nos DOIS sentidos, e por isso a taxa
### precisa ser medida de novo em vez de corrigida no chute.
###
### OFFLINE. Somente-leitura em relacao ao pipeline. NAO escreve no
### gabarito da 10d. Nao mande para o SEDAP.
###
### Depende de:
###   revelio_br_cohort/role_audit_sample.parquet   (10d, a amostra)
###   revelio_br_cohort/role_audit_class.csv        (10d, o gabarito)
###   revelio_br_cohort/obmep_candidates_step_1_position/  (10a)
###
### -----------------------------------------------------------------
### RUBRICA -- IDENTICA a da 10d, de proposito
### -----------------------------------------------------------------
###   none / job_category / role_k50 / role_k150 / role_k300 /
###   role_k500 / role_k1000 / role_k1500 / undecidable
###
### O veredito continua sendo o nivel MAIS FUNDO ainda correto.
### Mudar a regua invalidaria a comparacao antes/depois, que e o
### objetivo inteiro do script.
###
### O que MUDA e so a evidencia: agora vale title_raw + description.
### 'undecidable' passa a significar que NEM o titulo NEM a descricao
### carregam ocupacao -- barra mais alta, entao deve ficar mais raro.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. OFFLINE, sem rede, fora do SEDAP.
### 2. NAO HA SORTEIO NOVO. Reaproveita a amostra estacionada da 10d,
###    entao as linhas sao exatamente as ja julgadas e a comparacao e
###    PAREADA. Sortear de novo destruiria isso.
### 3. JULGA-SE AS CEGAS. A planilha leva titulo, traducao, descricao
###    e os sete rotulos -- e NAO leva o veredito anterior, e vem
###    embaralhada. Medir quanto um julgamento se move nao significa
###    nada se quem julga enxerga o numero que deveria mover. O Step 2
###    ABORTA se alguma coluna com o veredito antigo vazar.
### 4. RE-JULGA TODA LINHA COM DESCRIPTION, nao so as que deram
###    errado. Revisitar so as falhas tornaria o procedimento
###    monotono: a taxa so poderia subir, porque um 'correct' que a
###    descricao desmente nunca seria olhado. O caso "Novos projetos"
###    prova que esse sentido existe.
### 5. AS 237 LINHAS SEM DESCRIPTION FICAM COMO ESTAVAM. A taxa
###    combinada sobre as 500 mistura DUAS reguas de evidencia e esta
###    marcada como tal no relatorio. Nao e estimativa limpa.
### 6. VIES DE SELECAO. Quem tem descricao pode ser diferente de quem
###    nao tem: cargo mais elaborado, mais tempo de casa, mais chance
###    de ser emprego de verdade. O Step 4 compara a taxa ORIGINAL das
###    263 contra a das 237 justamente para medir isso. Se diferirem,
###    a taxa revisada e CONDICIONAL a ter descricao e nao pode ser
###    citada como taxa global.
### 7. ISTO NAO PROVA NADA SOBRE O REVELIO LER A DESCRIPTION. Taxa
###    diferente nas linhas com descricao -- para cima OU para baixo --
###    e igualmente compativel com o classificador ler a descricao e
###    com essas vagas serem simplesmente melhor documentadas. Nao
###    afirme o mecanismo a partir deste desenho. (A redacao original
###    desta nota supunha acerto MAIOR; a medicao deu menor, o que so
###    reforca que o desenho nao identifica mecanismo nenhum.)
### 8. position_id E bigint: CAST AS VARCHAR no SQL, sempre, inclusive
###    na releitura. Ver nota 8 da role_title_audit.R -- ja custou 499
###    ids errados.
###
### -----------------------------------------------------------------
### MEDIDO, rodada de 2026-09-01, n=263, as cegas
### -----------------------------------------------------------------
### A EXPECTATIVA ERA A TAXA SUBIR. ELA CAIU.
###
###   nivel          so titulo   titulo + description
###   job_category     86.1%           78.4%
###   role_k50         83.5%           70.3%
###   role_k1500       68.0%           61.4%
###
### Movimento nos DOIS sentidos, que e o que atesta a cegueira:
### 183 identicos, 18 mais fundos, 34 mais rasos, 28 saindo de
### undecidable, ZERO entrando.
###
### DOIS MECANISMOS, e o primeiro e falha do desenho original:
###
### 1. 'undecidable' ESTAVA MAQUIANDO A NOTA. 32 linhas ficavam fora
###    do denominador por titulo vazio. Com descricao, 28 viraram
###    decidiveis -- e 36% delas estao ERRADAS ja no job_category.
###    Eram justamente as dificeis, e estavam sendo excluidas.
### 2. TITULO PLAUSIVEL ESCONDE OUTRO EMPREGO. 15 linhas passaram de
###    totalmente certas a erradas no topo: "Global Planning" e S&OP
###    (Operations, nao Engineer); "Analista de laboratorio" e exame
###    CLINICO (saude, nao QA industrial); "Repositor" repoe pecas da
###    LINHA DE PRODUCAO, nao da loja.
###
### E as 263 com descricao eram as MAIS FACEIS: na regua antiga elas
### ja marcavam 86.1% contra 82.1% das sem descricao (role_k1500:
### 68.0% contra 59.0%). Subconjunto favoravel, e ainda assim caiu.
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

sample_path <- file.path(coh_dir, "role_audit_sample.parquet")
class_path  <- file.path(coh_dir, "role_audit_class.csv")
pos_dir     <- file.path(coh_dir, "obmep_candidates_step_1_position")

desc_path    <- file.path(coh_dir, "role_desc_class.csv")
compare_path <- file.path(coh_dir, "role_desc_compare.parquet")

shuffle_seed <- 20260902L

ladder <- c("job_category", "role_k50", "role_k150", "role_k300",
            "role_k500", "role_k1000", "role_k1500")
vdom <- c("none", ladder, "undecidable")
depth <- setNames(seq_along(ladder), ladder)

for (f in c(sample_path, class_path)) {
  if (!file.exists(f)) stop("Nao encontrei ", f, ". Rode role_title_audit.R antes.")
}
if (!dir.exists(pos_dir)) stop("Nao encontrei ", pos_dir)

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(dbExecute(con, "PRAGMA memory_limit='8GB'"))
fw <- function(p) gsub("\\\\", "/", p)

# Nota 8: CAST na releitura tambem.
smp <- dbGetQuery(con, sprintf(
  "SELECT CAST(position_id AS VARCHAR) AS position_id, title_raw,
          title_translated, job_category, role_k50, role_k150, role_k300,
          role_k500, role_k1000, role_k1500, CAST(seniority AS VARCHAR) seniority
   FROM read_parquet('%s')", fw(sample_path)))
old <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
                colClasses = "character")

if (!all(grepl("^-?[0-9]+$", smp$position_id)) ||
    !all(grepl("^-?[0-9]+$", old$position_id))) {
  stop("position_id nao e inteiro exato (nota 8).")
}
if (!setequal(smp$position_id, old$position_id)) {
  stop("A amostra e o gabarito da 10d nao cobrem os mesmos position_id.")
}

# description vem da 10a, chaveada por position_id.
dbWriteTable(con, "ids", smp[, "position_id", drop = FALSE], overwrite = TRUE)
dsc <- dbGetQuery(con, sprintf("
  SELECT CAST(p.position_id AS VARCHAR) AS position_id,
         coalesce(p.description, '') AS description
  FROM ids i JOIN read_parquet('%s/*') p
    ON CAST(p.position_id AS VARCHAR) = i.position_id", fw(pos_dir)))
smp <- merge(smp, dsc, by = "position_id", all.x = TRUE)
smp$description[is.na(smp$description)] <- ""
smp$has_desc <- nzchar(trimws(smp$description))

cat("amostra da 10d      :", nrow(smp), "linhas\n")
cat("com description     :", sum(smp$has_desc),
    sprintf("(%.1f%%)\n", 100 * mean(smp$has_desc)))
cat("sem description     :", sum(!smp$has_desc), "-- ficam como estavam (nota 5)\n\n")

####################################################################
### Step 1: a planilha cega
####################################################################

if (!file.exists(desc_path)) {
  w <- smp[smp$has_desc, c("position_id", "title_raw", "title_translated",
                           "description", ladder, "seniority")]
  # Nota 3: embaralha, para que a posicao na lista nao denuncie a
  # linha correspondente do gabarito antigo.
  set.seed(shuffle_seed)
  w <- w[sample(nrow(w)), ]
  w$verdict_desc <- ""
  w$note_desc <- ""
  w$source <- ""

  # Nota 3, a checagem que sustenta a cegueira: nenhuma coluna pode
  # carregar o veredito anterior.
  leak <- intersect(names(w), c("verdict", "better", "note"))
  if (length(leak)) {
    stop("A planilha cega vazaria ", paste(leak, collapse = ", "),
         " -- isso destruiria a medicao (nota 3).")
  }
  if (any(w$position_id %in% names(old))) stop("vazamento inesperado")

  write.csv(w, desc_path, row.names = FALSE, fileEncoding = "UTF-8")
  cat("[novo] planilha cega escrita:\n  ", desc_path, "\n", sep = "")
  cat("\nPreencha `verdict_desc` nas ", nrow(w), " linhas com um de:\n  ",
      paste(vdom, collapse = ", "), "\n", sep = "")
  cat("Julgue contra title_raw + description. Mesma regua da 10d.\n")
  cat("Depois rode este script de novo para a comparacao.\n")
  quit(save = "no", status = 0)
}

####################################################################
### Step 2: ler a planilha
####################################################################

cat("=========== VALIDACAO DA PLANILHA ===========\n")
nw <- read.csv(desc_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
               colClasses = "character")
if (!all(grepl("^-?[0-9]+$", nw$position_id))) {
  stop("position_id da planilha nao e inteiro exato (nota 8).")
}
if (anyDuplicated(nw$position_id) != 0) stop("position_id repetido na planilha.")
alvo <- smp$position_id[smp$has_desc]
if (!setequal(nw$position_id, alvo)) {
  stop("A planilha nao cobre exatamente as ", length(alvo),
       " linhas com description.")
}
off <- setdiff(nw$verdict_desc, vdom)
if (length(off)) {
  stop("verdict_desc fora de {", paste(vdom, collapse = ", "), "}: ",
       paste(sort(unique(off)), collapse = ", "))
}
cat("[OK]", nrow(nw), "linhas, ids exatos, dominio valido\n")

####################################################################
### Step 3: comparacao pareada
####################################################################

m <- merge(old[, c("position_id", "title_raw", "verdict", "job_category")],
           nw[, c("position_id", "verdict_desc", "note_desc")],
           by = "position_id")
stopifnot(nrow(m) == length(alvo))

dep <- function(v) ifelse(v == "none", 0L,
                   ifelse(v == "undecidable", NA_integer_, depth[v]))
m$d_old <- dep(m$verdict)
m$d_new <- dep(m$verdict_desc)

cat("\n=========== PARA ONDE OS VEREDITOS ANDARAM ===========\n")
cat(sprintf("  linhas re-julgadas        : %d\n", nrow(m)))
cat(sprintf("  veredito identico         : %d\n", sum(m$verdict == m$verdict_desc)))
both <- !is.na(m$d_old) & !is.na(m$d_new)
cat(sprintf("  ficou MAIS FUNDO (melhor) : %d\n", sum(both & m$d_new > m$d_old)))
cat(sprintf("  ficou MAIS RASO (pior)    : %d\n", sum(both & m$d_new < m$d_old)))
cat(sprintf("  saiu de undecidable       : %d\n",
            sum(is.na(m$d_old) & !is.na(m$d_new))))
cat(sprintf("  virou undecidable         : %d\n",
            sum(!is.na(m$d_old) & is.na(m$d_new))))

# Nota 3: se tudo andou para o mesmo lado, desconfie da cegueira.
up <- sum(both & m$d_new > m$d_old) + sum(is.na(m$d_old) & !is.na(m$d_new))
dn <- sum(both & m$d_new < m$d_old) + sum(!is.na(m$d_old) & is.na(m$d_new))
if (up > 0 && dn == 0) {
  cat("\n  [ATENCAO] todo movimento foi para cima. Isso e o que se ",
      "esperaria\n  se a cegueira tivesse falhado -- confira antes de ",
      "publicar (nota 3).\n", sep = "")
}

cat("\n=========== MATRIZ antes x depois ===========\n")
print(table(antes = factor(m$verdict, levels = vdom),
            depois = factor(m$verdict_desc, levels = vdom)))

####################################################################
### Step 4: taxas
####################################################################

ci_txt <- function(k, n) {
  if (n == 0) return("      n/a       ")
  ci <- if (k == 0) c(0, 1 - 0.05^(1 / n)) else
    if (k == n) c(0.05^(1 / n), 1) else as.numeric(binom.test(k, n)$conf.int)
  sprintf("[%5.1f%%, %5.1f%%]", 100 * ci[1], 100 * ci[2])
}
rate <- function(d, lv) {
  dd <- d[!is.na(d)]
  c(k = sum(dd >= depth[[lv]]), n = length(dd))
}

cat("\n=========== ACERTO NAS", nrow(m), "COM DESCRIPTION ===========\n")
cat("  nivel          so titulo            titulo + description\n")
for (lv in ladder) {
  a <- rate(m$d_old, lv); b <- rate(m$d_new, lv)
  cat(sprintf("  %-12s %5.1f%% %-18s %5.1f%% %s\n", lv,
              100 * a[["k"]] / a[["n"]], ci_txt(a[["k"]], a[["n"]]),
              100 * b[["k"]] / b[["n"]], ci_txt(b[["k"]], b[["n"]])))
}

# Nota 6: as 263 sao diferentes das 237 mesmo ANTES de reler?
cat("\n=========== VIES DE SELECAO (nota 6) ===========\n")
cat("  taxa ORIGINAL, so titulo, nos dois grupos:\n")
o <- merge(old[, c("position_id", "verdict")],
           smp[, c("position_id", "has_desc")], by = "position_id")
o$d <- dep(o$verdict)
for (g in c(TRUE, FALSE)) {
  a <- rate(o$d[o$has_desc == g], "job_category")
  b <- rate(o$d[o$has_desc == g], "role_k1500")
  cat(sprintf("  %-16s job_category %5.1f%% %s   role_k1500 %5.1f%% %s\n",
              if (g) "COM description" else "SEM description",
              100 * a[["k"]] / a[["n"]], ci_txt(a[["k"]], a[["n"]]),
              100 * b[["k"]] / b[["n"]], ci_txt(b[["k"]], b[["n"]])))
}

# Nota 5: mistura duas reguas. Marcado como tal.
cat("\n=========== COMBINADO SOBRE AS 500 (nota 5) ===========\n")
cat("  263 relidas com description + 237 mantidas so com titulo.\n")
cat("  Mistura DUAS reguas de evidencia; nao e estimativa limpa.\n")
bl <- old[, c("position_id", "verdict")]
bl <- merge(bl, nw[, c("position_id", "verdict_desc")], by = "position_id",
            all.x = TRUE)
bl$final <- ifelse(is.na(bl$verdict_desc), bl$verdict, bl$verdict_desc)
bl$d <- dep(bl$final)
for (lv in c("job_category", "role_k50", "role_k1500")) {
  a <- rate(bl$d, lv)
  cat(sprintf("  %-12s %5.1f%% %s  (n=%d)\n", lv,
              100 * a[["k"]] / a[["n"]], ci_txt(a[["k"]], a[["n"]]), a[["n"]]))
}

####################################################################
### Step 5: gravar a comparacao
####################################################################

out <- m[, c("position_id", "title_raw", "job_category", "verdict",
             "verdict_desc", "note_desc")]
names(out)[names(out) == "verdict"] <- "verdict_title_only"
dbWriteTable(con, "cmp", out, overwrite = TRUE)
invisible(dbExecute(con, sprintf(
  "COPY (SELECT * FROM cmp ORDER BY position_id) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", fw(compare_path))))

cat("\n=========== MUDANCAS MAIS INFORMATIVAS ===========\n")
ch <- m[m$verdict != m$verdict_desc, ]
ch <- ch[order(-abs(ifelse(is.na(ch$d_new), 9, ch$d_new) -
                    ifelse(is.na(ch$d_old), 9, ch$d_old))), ]
for (i in seq_len(min(12L, nrow(ch)))) {
  cat(sprintf("  %-42s %s -> %s\n", substr(ch$title_raw[i], 1, 42),
              ch$verdict[i], ch$verdict_desc[i]))
  if (nzchar(ch$note_desc[i])) cat("      ", ch$note_desc[i], "\n", sep = "")
}
cat("\n  ", compare_path, "\n", sep = "")
