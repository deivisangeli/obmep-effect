####################################################################
### job_category contra title_raw em Finance e Engineer, 250 + 250
###
### A 10d mediu job_category em 500 posicoes sorteadas de TODA a base
### e chegou a 84.2% [80.5, 87.5]. O corte por categoria saiu junto,
### mas com n pequeno demais para servir de conclusao:
###
###   Finance    22/25   88.0%  [68.8, 97.5]   <- 25 linhas
###   Engineer   98/109  89.9%  [82.7, 94.9]   <- 109 linhas
###
### Este script refaz a pergunta so para essas duas, com 250 de cada,
### que estreita o intervalo de ~29 pontos para ~9 no caso do Finance.
###
### A pergunta e BINARIA e so no topo da escada: o job_category
### descreve o title_raw? Nada de escada ordinal aqui -- isso e a 10d.
###
### OFFLINE. Somente-leitura em relacao ao pipeline. Nao mande para o
### SEDAP.
###
### Depende de:
###   revelio_br_cohort/obmep_candidates_selected_positions.parquet (21a)
###   revelio_br_cohort/obmep_candidates_step_1_position/           (10a)
###
### -----------------------------------------------------------------
### RUBRICA -- veredito binario, chaveado em position_id
### -----------------------------------------------------------------
###   correct       o job_category descreve o titulo
###   wrong         nao descreve; outra das 7 categorias caberia
###                 melhor, ou nenhuma
###   undecidable   title_raw nao carrega ocupacao nenhuma
###
### 'undecidable' e veredito sobre o DADO. As taxas saem do
### subconjunto decidivel e o excluido e impresso junto -- mesma
### convencao da 10d.
###
### Ao julgar, lembre que rotulo grosso e NOME DE GRUPO: 'Engineer'
### cobre TI, software, manufatura e QA; 'Finance' cobre
### contabilidade, seguro, credito e investimento. A pergunta e se o
### titulo cabe no grupo, nao se a palavra bate.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. OFFLINE, sem rede, fora do SEDAP.
### 2. AMOSTRA ESTRATIFICADA, NAO ALEATORIA SIMPLES. 250 de cada
###    categoria, entao as duas taxas sao CONDICIONAIS a categoria
###    atribuida. Elas NAO se combinam em taxa geral: o peso real de
###    Finance e 6.9% e o de Engineer 22.0% da base. Para taxa geral
###    use a 10d, que sorteia sem estrato.
### 3. MEDE PRECISAO, NAO COBERTURA. Responde "das linhas rotuladas
###    Finance, quantas sao mesmo Finance". NAO responde quantas
###    linhas de financas foram parar em outra categoria -- para isso
###    seria preciso sortear pelo TITULO, nao pelo rotulo.
### 4. A AMOSTRA NAO E REDESENHADA se o parquet ja existir.
### 5. JULGA-SE CONTRA title_raw, nunca contra title_translated.
### 6. position_id E bigint: CAST AS VARCHAR no SQL, sempre. Ver nota
###    8 da role_title_audit.R -- ja custou 499 ids errados uma vez.
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

sample_path <- file.path(coh_dir, "jobcat_audit_sample.parquet")
class_path  <- file.path(coh_dir, "jobcat_audit_class.csv")

seed     <- 20260901L
per_cat  <- 250L
cats     <- c("Finance", "Engineer")
vdom     <- c("correct", "wrong", "undecidable")

# Medido pela 10d, para comparacao no relatorio.
prior <- data.frame(job_category = cats, k = c(22, 98), n = c(25, 109),
                    stringsAsFactors = FALSE)

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")
tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_jobcat_audit")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

for (f in c(sel_path)) if (!file.exists(f)) stop("Nao encontrei ", f)
if (!dir.exists(pos_dir)) stop("Nao encontrei ", pos_dir)

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit)))
invisible(dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir)))
invisible(dbExecute(con, "SET preserve_insertion_order=false"))

fw <- function(p) gsub("\\\\", "/", p)
sel_src <- sprintf("read_parquet('%s')", fw(sel_path))
pos_src <- sprintf("read_parquet('%s/*')", fw(pos_dir))

####################################################################
### Step 1: sortear 250 de cada, estacionar
####################################################################

# Nota 6: CAST AS VARCHAR, sempre. Nota 4 da 10d: ORDER BY hash(...)
# LIMIT n, nunca USING SAMPLE -- ele e empurrado para baixo do filtro.
# qualify + row_number faz o top-N POR CATEGORIA numa passada so.
sample_sql <- sprintf("
  SELECT CAST(r.position_id AS VARCHAR) AS position_id,
         r.job_category,
         p.title_raw,
         coalesce(p.title_translated, '') AS title_translated,
         r.role_k50, r.role_k1500,
         hash(CAST(r.position_id AS VARCHAR) || '#%d') AS hk
  FROM %s r
  JOIN %s p ON r.position_id = p.position_id
  WHERE r.job_category IN ('%s')
    AND p.title_raw IS NOT NULL AND trim(p.title_raw) <> ''
  QUALIFY row_number() OVER (PARTITION BY r.job_category
                             ORDER BY hash(CAST(r.position_id AS VARCHAR)
                                           || '#%d')) <= %d",
  seed, sel_src, pos_src, paste(cats, collapse = "','"), seed, per_cat)

if (file.exists(sample_path)) {
  cat("[skip] amostra ja existe:", basename(sample_path), "\n")
} else {
  cat("Sorteando", per_cat, "de cada categoria...\n")
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    sample_sql, fw(sample_path))))
}

# O CAST tem de estar aqui tambem: um SELECT * traria o bigint de
# volta como double (nota 6).
s <- dbGetQuery(con, sprintf(
  "SELECT * EXCLUDE (position_id, hk),
          CAST(position_id AS VARCHAR) AS position_id,
          CAST(hk AS VARCHAR) AS hk
   FROM read_parquet('%s')", fw(sample_path)))

####################################################################
### Step 2: validar a amostra
####################################################################

cat("\n=========== VALIDACAO DA AMOSTRA ===========\n")
if (nrow(s) != per_cat * length(cats)) {
  stop("A amostra tem ", nrow(s), " linhas, esperado ", per_cat * length(cats))
}
tb <- table(s$job_category)
if (!all(tb == per_cat)) {
  stop("Estrato desbalanceado: ", paste(names(tb), tb, collapse = " | "))
}
if (anyDuplicated(s$position_id) != 0) stop("position_id repetido.")
if (!all(grepl("^-?[0-9]+$", s$position_id))) {
  stop("position_id nao inteiro exato -- o CAST caiu (nota 6).")
}
if (any(is.na(s$title_raw)) || any(trimws(s$title_raw) == "")) {
  stop("title_raw vazio na amostra; o filtro nao pegou.")
}
s2 <- dbGetQuery(con, sample_sql)
s2$position_id <- as.character(s2$position_id)
if (!setequal(s$position_id, s2$position_id)) {
  stop("O mesmo seed devolveu amostra DIFERENTE; o gabarito nao serve.")
}
cat("[OK] ", nrow(s), " linhas, ", per_cat, " por categoria, ids inteiros ",
    "e unicos, seed reproduzivel\n", sep = "")

####################################################################
### Step 3: esqueleto do gabarito
####################################################################

if (!file.exists(class_path)) {
  sk <- s[order(s$job_category, s$hk),
          c("position_id", "job_category", "title_raw", "title_translated",
            "role_k50", "role_k1500")]
  sk$verdict <- ""
  sk$note <- ""
  sk$source <- ""
  write.csv(sk, class_path, row.names = FALSE, fileEncoding = "UTF-8")
  cat("\n[novo] esqueleto escrito:\n  ", class_path, "\n", sep = "")
  cat("\nPreencha `verdict` nas ", nrow(sk), " linhas com um de: ",
      paste(vdom, collapse = ", "), "\n", sep = "")
  cat("Depois rode este script de novo para o relatorio.\n")
  quit(save = "no", status = 0)
}

####################################################################
### Step 4: ler o gabarito
####################################################################

cat("\n=========== VALIDACAO DO GABARITO ===========\n")
cl <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
               colClasses = "character")
if (anyDuplicated(cl$position_id) != 0) stop("position_id repetido no gabarito.")
if (!all(grepl("^-?[0-9]+$", cl$position_id))) {
  stop("position_id do gabarito nao e inteiro exato (nota 6).")
}
off <- setdiff(cl$verdict, vdom)
if (length(off)) {
  stop("Vereditos fora de {", paste(vdom, collapse = ", "), "}: ",
       paste(sort(unique(off)), collapse = ", "))
}
miss <- setdiff(s$position_id, cl$position_id)
if (length(miss)) {
  stop(length(miss), " posicao(oes) sem classificacao: ",
       paste(head(miss, 10), collapse = " | "))
}
cat("[OK]", nrow(cl), "linhas classificadas, dominio valido\n")
n_llm <- sum(cl$source == "llm")
cat(sprintf("rotulos ainda como o LLM os deixou: %d de %d (%.0f%%)\n",
            n_llm, nrow(cl), 100 * n_llm / nrow(cl)))

####################################################################
### Step 5: relatorio
####################################################################

ci_txt <- function(k, n) {
  if (n == 0) return("      n/a       ")
  ci <- if (k == 0) c(0, 1 - 0.05^(1 / n)) else
    if (k == n) c(0.05^(1 / n), 1) else as.numeric(binom.test(k, n)$conf.int)
  sprintf("[%5.1f%%, %5.1f%%]", 100 * ci[1], 100 * ci[2])
}

cat("\n=========== ACERTO DE job_category ===========\n")
cat("  (nota 2: taxas CONDICIONAIS a categoria; nao se somam)\n\n")
cat("  categoria    certos  decid.  undec.    taxa   IC 95% exato\n")
for (g in cats) {
  d <- cl[cl$job_category == g, ]
  dec <- d[d$verdict != "undecidable", ]
  k <- sum(dec$verdict == "correct")
  cat(sprintf("  %-11s %5d  %6d  %6d  %6.1f%%   %s\n", g, k, nrow(dec),
              sum(d$verdict == "undecidable"), 100 * k / nrow(dec),
              ci_txt(k, nrow(dec))))
}

cat("\n=========== CONTRA A ESTIMATIVA DA 10d ===========\n")
cat("  categoria      10d (n pequeno)          este script\n")
for (g in cats) {
  p <- prior[prior$job_category == g, ]
  d <- cl[cl$job_category == g, ]
  dec <- d[d$verdict != "undecidable", ]
  k <- sum(dec$verdict == "correct")
  cat(sprintf("  %-11s %5.1f%% %-18s %5.1f%% %s\n", g,
              100 * p$k / p$n, ci_txt(p$k, p$n),
              100 * k / nrow(dec), ci_txt(k, nrow(dec))))
}

cat("\n=========== PARA ONDE DEVERIA TER IDO ===========\n")
for (g in cats) {
  d <- cl[cl$job_category == g & cl$verdict == "wrong", ]
  if (nrow(d) == 0) next
  cat("\n  rotulado ", g, ", mas errado (", nrow(d), " linhas):\n", sep = "")
  tb <- sort(table(d$role_k50), decreasing = TRUE)
  for (nm in head(names(tb), 6)) {
    cat(sprintf("    via role_k50 %-28s %d\n", nm, tb[[nm]]))
  }
  for (i in seq_len(min(6L, nrow(d)))) {
    cat(sprintf("    \"%s\"\n        -> %s / %s%s\n",
                substr(d$title_raw[i], 1, 58), d$job_category[i],
                d$role_k50[i],
                if (nzchar(d$note[i])) paste0("  -- ", d$note[i]) else ""))
  }
}
cat("\n")
