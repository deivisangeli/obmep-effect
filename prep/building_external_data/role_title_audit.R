####################################################################
### Auditoria da escada de papeis contra title_raw, em 500 posicoes
###
### Mede UMA decisao: o caminho de rotulos que o Revelio pendura em
### cada posicao descreve o titulo que a pessoa escreveu?
###
###   job_category -> role_k50 -> role_k150 -> role_k300
###                -> role_k500 -> role_k1000 -> role_k1500
###
### O script 10c trouxe essas sete colunas para o pipeline e mediu a
### COBERTURA delas (100%, cardinalidade exata em cada nivel). Ninguem
### mediu a CORRECAO. Doze linhas sorteadas a olho ja mostram erro
### real: "Office Manager & Assistant to Director" vira
### Engineer/Machine Operator/factory worker, "Bartender" vira cook.
### Este script poe numero e intervalo de confianca nisso.
###
### OFFLINE. Nao usa rede, nao le Athena, nao escreve em S3, e NAO
### altera nenhuma coluna -- e somente-leitura em relacao ao pipeline.
### Nao mande nada disto para o SEDAP.
###
### Depende de:
###   revelio_br_cohort/obmep_candidates_selected_positions.parquet (21a)
###   revelio_br_cohort/obmep_candidates_step_1_position/           (10a)
###
### Padrao de amostra + gabarito + IC reaproveitado de
### shanghai_flag_audit.R (script 17).
###
### -----------------------------------------------------------------
### RUBRICA -- veredito ORDINAL, chaveado em position_id
### -----------------------------------------------------------------
### A pergunta e SEMPRE: ate onde o caminho continua descrevendo
### title_raw? O veredito e o nivel MAIS FUNDO ainda correto.
###
###   none          o proprio job_category esta errado
###   job_category  certo no nivel k7, role_k50 errado
###   role_k50      certo ate k50, role_k150 errado
###   role_k150     certo ate k150, role_k300 errado
###   role_k300     certo ate k300, role_k500 errado
###   role_k500     certo ate k500, role_k1000 errado
###   role_k1000    certo ate k1000, role_k1500 errado
###   role_k1500    certo o caminho inteiro
###   undecidable   title_raw nao carrega sinal de ocupacao nenhum
###
### O nivel L conta como correto se profundidade(veredito) >=
### profundidade(L). Sete taxas saem de um julgamento so, e a
### consistencia entre elas e garantida por construcao.
###
### 'undecidable' e um veredito SOBRE O DADO, nao um "ainda nao
### classifiquei". Cobre titulo presente mas vazio de ocupacao: "-",
### "Colaborador", so o nome da empresa. As taxas principais saem do
### subconjunto decidivel e o numero de excluidos e impresso junto.
### Cobrar do classificador um titulo que nao informa nada inflaria o
### erro e descreveria outra coisa.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. OFFLINE E SOMENTE-LEITURA. Nao vai para o SEDAP: tudo que ele
###    le veio do Athena. Ver AGENTS.md -> Execution Environments.
### 2. A AMOSTRA NAO E REDESENHADA se o parquet ja existir. O gabarito
###    esta chaveado nesta amostra exata e nao pode derivar por baixo
###    dela. Apague o parquet para forcar novo sorteio, e conte com
###    reclassificar as 500.
### 3. USING SAMPLE NAO E USADO. No DuckDB ele e empurrado para BAIXO
###    do filtro -- documentado no README, onde sortear 500 de 708M
###    perfis e so depois filtrar devolveu 23 linhas. ORDER BY
###    hash(...) LIMIT n e um top-N sobre o conjunto JA filtrado.
###    Aqui position_id e unico, entao o hash e sobre ele direto e
###    empate e impossivel -- conferido mesmo assim.
### 4. JULGA-SE CONTRA title_raw, NUNCA CONTRA title_translated. A
###    traducao erra feio e de forma nao aleatoria: "Garconete" vira
###    "boy". Ela viaja na amostra so como apoio de leitura. Cobrar do
###    rotulo de papel um erro de traducao mediria a coisa errada.
### 5. A ESCADA E ESTRITAMENTE ANINHADA, e e isso que autoriza o
###    veredito ordinal. Medido nas 7,285,037 linhas: todo role_k50
###    tem exatamente um job_category, todo role_k150 exatamente um
###    role_k50, e assim por diante -- ZERO nos com mais de um pai nos
###    seis elos, e cada nivel com a cardinalidade nominal exata. Sem
###    isso, sete julgamentos independentes poderiam produzir
###    combinacoes impossiveis (k1500 certo com job_category errado).
### 6. MEDE PRECISAO, NUNCA COBERTURA. A pergunta e se o rotulo posto
###    cabe no titulo. Nada aqui diz se a taxonomia DEIXOU DE separar
###    ocupacoes que deveriam ser distintas: se role_k1500 junta dois
###    trabalhos diferentes sob um rotulo, as duas linhas contam como
###    certas. Script 17 nota 5 faz a mesma ressalva.
### 7. 'better' SEPARA DUAS FALHAS DIFERENTES. Para um nivel errado,
###    ou existia rotulo melhor no vocabulario e o classificador nao o
###    escolheu, ou a taxonomia nao tem resposta certa. As duas doem
###    de formas diferentes a jusante e a taxa sozinha nao as
###    distingue.
###
### 8. position_id E bigint E O R O RECEBE COMO DOUBLE. Os valores
###    passam de 2^53, entao as.character() sobre o double devolve
###    "9.107556275968e+18" e o digito esta perdido para sempre. O
###    SELECT converte com CAST AS VARCHAR e o Step 3 confere que todo
###    id e inteiro exato, em DOIS lugares: no SELECT que sorteia e no
###    SELECT que rele o parquet estacionado -- um SELECT * traz o
###    bigint de volta como double e o estrago recomeca.
###    Isto ja aconteceu e foi pior do que parecia: 499 das 500 linhas
###    do gabarito nasceram com o id errado. So 3 viraram notacao
###    cientifica visivel; nas outras 496 o R imprimiu o double em
###    decimal cheio e os ultimos digitos sairam ERRADOS em silencio
###    (7701199284207410109 virou ...176). Reparado casando por
###    posicao contra o parquet, com o alinhamento provado em nove
###    colunas antes de trocar qualquer id.
###    A checagem de ida e volta do caderno .xlsx nao pegou nada disso
###    porque comparava o arquivo contra o CSV JA corrompido -- os
###    dois lados concordavam. Uma verificacao tem de testar a
###    INVARIANTE (id e inteiro exato), nao so a igualdade entre as
###    duas pontas.
### -----------------------------------------------------------------
### MEDIDO, rodada de 2026-08-31, n=500, gabarito 100% LLM
### -----------------------------------------------------------------
### 443 decidiveis, 57 undecidable (11.4%) fora do denominador.
###
###   nivel          acerto   IC 95% exato
###   job_category    84.2%   [80.5, 87.5]
###   role_k50        81.0%   [77.1, 84.6]
###   role_k150       74.3%   [69.9, 78.3]
###   role_k300       71.3%   [66.9, 75.5]
###   role_k500       68.2%   [63.6, 72.5]
###   role_k1000      66.4%   [61.8, 70.8]
###   role_k1500      63.7%   [59.0, 68.1]
###
### Em 14.0% das linhas o proprio job_category esta errado.
### Por categoria, job_category vai de 94.1% (Scientist) a 76.9%
### (Sales); Admin 80.0%, Marketing 79.2%.
### Dos 161 caminhos com algum nivel errado, 31 (19%) nao tinham
### rotulo melhor no vocabulario -- limite da taxonomia (nota 7).
###
### O ACHADO PRINCIPAL NAO E A TAXA, E O QUE ELA ESCONDE. O 10c mediu
### 100% de preenchimento nestas colunas. Preenchimento nao e
### conhecimento: quando o titulo nao diz ocupacao nenhuma, o Revelio
### nao devolve nulo, ele CHUTA -- e chuta diferente a cada vez. Na
### amostra, "estagiario" aparece 8 vezes e recebe 7 caminhos
### distintos; "trainee" 4 vezes, 4 caminhos. Medido na base inteira:
###
###   titulo         linhas   job_category  role_k50  role_k1500
###                           distintos     distintos distintos
###   estagiario    178,093        7           47        467
###   estagiaria     97,567        7           49        672
###   intern         68,943        7           49        764
###   trainee        34,771        7           50        651
###   bolsista       25,789        7           39        230
###
### Somados os titulos sem conteudo ocupacional: 434,622 posicoes,
### 6.0% do arquivo, espalhadas pelas SETE categorias. Para essas
### linhas o rotulo nao classifica nada, e nada no dado sinaliza isso.
###
### CONSISTENCIA DO GABARITO: dos titulos repetidos na amostra, em
### ZERO casos o Revelio deu o mesmo caminho e este gabarito deu
### vereditos diferentes. Onde os vereditos divergem para o mesmo
### titulo (farmaceutico, pesquisadora, product owner) e porque o
### Revelio mandou o titulo para caminhos diferentes.
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

sample_path <- file.path(coh_dir, "role_audit_sample.parquet")
vocab_path  <- file.path(coh_dir, "role_audit_vocab.csv")
class_path  <- file.path(coh_dir, "role_audit_class.csv")
out_path    <- file.path(coh_dir, "role_audit_classified.parquet")

seed     <- 20260831L
n_sample <- 500L

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")
tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_role_audit")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

# A escada, do raso ao fundo. A ordem E a semantica do veredito.
ladder <- c("job_category", "role_k50", "role_k150", "role_k300",
            "role_k500", "role_k1000", "role_k1500")
# Dominio do veredito: 'none' e profundidade 0, cada nivel a sua
# posicao na escada, 'undecidable' fora da escala.
vdom <- c("none", ladder, "undecidable")

if (!file.exists(sel_path)) {
  stop("Nao encontrei ", sel_path,
       ". Rode obmep_candidates_selected_positions.R antes.")
}
if (!dir.exists(pos_dir)) stop("Nao encontrei ", pos_dir)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit)))
invisible(dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir)))
invisible(dbExecute(con, "SET preserve_insertion_order=false"))

fw <- function(p) gsub("\\\\", "/", p)
sel_src <- sprintf("read_parquet('%s')", fw(sel_path))
pos_src <- sprintf("read_parquet('%s/*')", fw(pos_dir))

cat("DuckDB   :", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("amostra  :", sample_path, "\n")
cat("gabarito :", class_path, "\n\n")

####################################################################
### Step 1: a escada e mesmo aninhada? (nota 5)
####################################################################

# Isto nao e curiosidade: se falhar, o veredito ordinal deixa de fazer
# sentido e a rubrica inteira cai. Roda em toda invocacao.
cat("=========== ANINHAMENTO DA ESCADA ===========\n")
for (i in seq_len(length(ladder) - 1L)) {
  child <- ladder[i + 1L]; parent <- ladder[i]
  r <- dbGetQuery(con, sprintf(
    "SELECT count(*) AS nchild, max(np) AS mx
     FROM (SELECT %s AS c, count(DISTINCT %s) AS np
           FROM %s GROUP BY 1)", child, parent, sel_src))
  cat(sprintf("  %-11s -> %-12s  %5s filhos, max %s pai(s)\n",
              child, parent, r$nchild, r$mx))
  if (r$mx > 1) {
    stop("A escada NAO e aninhada em ", child, " -> ", parent,
         ": ha filho com ", r$mx, " pais. O veredito ordinal desta ",
         "rubrica pressupoe aninhamento estrito (nota 5).")
  }
}
cat("[OK] aninhamento estrito confirmado\n\n")

####################################################################
### Step 2: sortear e estacionar a amostra
####################################################################

# title_translated viaja so como apoio de leitura (nota 4).
# CAST AS VARCHAR nao e enfeite: position_id e bigint, o duckdb o
# entrega ao R como DOUBLE, e acima de 2^53 as.character() cospe
# notacao cientifica e PERDE DIGITO. Convertido no SQL ele nunca vira
# double. Ver nota 8.
sample_sql <- sprintf("
  SELECT CAST(r.position_id AS VARCHAR) AS position_id,
         p.title_raw,
         coalesce(p.title_translated, '') AS title_translated,
         r.job_category, r.role_k50, r.role_k150, r.role_k300,
         r.role_k500, r.role_k1000, r.role_k1500,
         r.seniority,
         hash(CAST(r.position_id AS VARCHAR) || '#%d') AS hk
  FROM %s r
  JOIN %s p ON r.position_id = p.position_id
  WHERE p.title_raw IS NOT NULL AND trim(p.title_raw) <> ''
  ORDER BY hk, r.position_id
  LIMIT %d", seed, sel_src, pos_src, n_sample)

if (file.exists(sample_path)) {
  cat("[skip] amostra ja existe:", basename(sample_path), "\n")
} else {
  cat("Sorteando", n_sample, "posicoes...\n")
  t0 <- Sys.time()
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    sample_sql, fw(sample_path))))
  cat("  pronto em",
      round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
}

# A amostra e sempre RELIDA do parquet. O arquivo e a fonte da
# verdade, nunca o resultado da consulta.
# O CAST tem de estar AQUI TAMBEM, e nao so no sample_sql: um
# SELECT * traz o bigint de volta como double e o estrago recomeca
# (nota 8).
s <- dbGetQuery(con, sprintf(
  "SELECT * EXCLUDE (position_id, hk),
          CAST(position_id AS VARCHAR) AS position_id,
          CAST(hk AS VARCHAR) AS hk
   FROM read_parquet('%s')", fw(sample_path)))
s$position_id <- as.character(s$position_id)
s$hk <- as.character(s$hk)

# Nota 8: se um id escapou como double, ele chega aqui em notacao
# cientifica e o digito ja se foi. Barre agora, nao na juncao.
if (!all(grepl("^-?[0-9]+$", s$position_id))) {
  ruins <- s$position_id[!grepl("^-?[0-9]+$", s$position_id)]
  stop(length(ruins), " position_id nao sao inteiros exatos: ",
       paste(head(ruins, 5), collapse = ", "),
       ". Alguem tirou o CAST AS VARCHAR do SELECT (nota 8).")
}

####################################################################
### Step 3: validacao da amostra
####################################################################

cat("\n=========== VALIDACAO DA AMOSTRA ===========\n")
if (nrow(s) != n_sample) {
  stop("A amostra tem ", nrow(s), " linhas, esperado ", n_sample)
}
if (anyDuplicated(s$position_id) != 0) {
  stop("position_id repetido na amostra.")
}
if (anyDuplicated(s$hk) != 0) {
  stop("Chave de hash repetida: o LIMIT esta desempatando de forma ",
       "arbitraria e o sorteio nao e reproduzivel.")
}
if (any(is.na(s$title_raw)) || any(trimws(s$title_raw) == "")) {
  stop("Ha title_raw nulo ou vazio na amostra; o filtro nao pegou.")
}

# Um seed que nao reproduz e pior do que nenhum: o gabarito pararia de
# casar com a amostra em silencio. A consulta e local e gratuita.
s2 <- dbGetQuery(con, sample_sql)
s2$position_id <- as.character(s2$position_id)
if (!identical(sort(s$position_id), sort(s2$position_id))) {
  stop("Rodar a consulta com o mesmo seed devolveu uma amostra ",
       "DIFERENTE. O gabarito nao pode ser confiado.")
}
cat("[OK] ", n_sample, " linhas, position_id e hash unicos, ",
    "seed reproduzivel\n", sep = "")

# Quanto da populacao ficou de fora por titulo ausente (nota da
# rubrica): relatado, nao asserido.
fr <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n,
          sum(CASE WHEN p.title_raw IS NULL OR trim(p.title_raw) = ''
                   THEN 1 ELSE 0 END) AS sem_titulo
   FROM %s r JOIN %s p ON r.position_id = p.position_id",
  sel_src, pos_src))
cat(sprintf("populacao: %s posicoes, %s sem title_raw (%.2f%%) -- fora do quadro\n",
            format(fr$n, big.mark = ","), format(fr$sem_titulo, big.mark = ","),
            100 * fr$sem_titulo / fr$n))

####################################################################
### Step 4: o vocabulario, para julgar contra as alternativas reais
####################################################################

# Sem saber que rotulos EXISTIAM, "errado" nao tem conteudo: nao da
# para separar rotulo melhor disponivel de taxonomia sem resposta
# (nota 7).
if (!file.exists(vocab_path)) {
  v <- dbGetQuery(con, sprintf("
    SELECT 'job_category' AS nivel, job_category AS rotulo,
           '' AS pai, count(*) AS n
      FROM %1$s GROUP BY 1,2,3
    UNION ALL
    SELECT 'role_k50', role_k50, job_category, count(*)
      FROM %1$s GROUP BY 1,2,3
    UNION ALL
    SELECT 'role_k1500', role_k1500, role_k1000, count(*)
      FROM %1$s GROUP BY 1,2,3
    ORDER BY nivel, n DESC", sel_src))
  write.csv(v, vocab_path, row.names = FALSE, fileEncoding = "UTF-8")
  cat("[novo] vocabulario escrito:", basename(vocab_path),
      "-", nrow(v), "rotulos\n")
} else {
  cat("[skip] vocabulario ja existe:", basename(vocab_path), "\n")
}

####################################################################
### Step 5: o esqueleto do gabarito
####################################################################

if (!file.exists(class_path)) {
  sk <- s[order(s$hk), c("position_id", "title_raw", "title_translated",
                         ladder, "seniority")]
  sk$verdict <- ""
  sk$better  <- ""
  sk$note    <- ""
  sk$source  <- ""
  write.csv(sk, class_path, row.names = FALSE, fileEncoding = "UTF-8")
  cat("\n[novo] esqueleto do gabarito escrito:\n  ", class_path, "\n", sep = "")
  cat("\nPreencha a coluna `verdict` em cada uma das ", n_sample,
      " linhas com um de:\n  ", paste(vdom, collapse = ", "), "\n", sep = "")
  cat("`better` e `note` sao livres; `source` = llm ou human.\n")
  cat("Depois rode este script de novo para o relatorio.\n")
  quit(save = "no", status = 0)
}

####################################################################
### Step 6: ler o gabarito
####################################################################

cat("\n=========== VALIDACAO DO GABARITO ===========\n")
cl <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
               colClasses = "character")
if (!all(c("position_id", "verdict") %in% names(cl))) {
  stop(basename(class_path), " nao tem as colunas position_id e verdict.")
}
if (anyDuplicated(cl$position_id) != 0) {
  stop("position_id repetido no gabarito: ",
       paste(head(unique(cl$position_id[duplicated(cl$position_id)]), 10),
             collapse = " | "))
}
# Um veredito em branco cai AQUI, no dominio: o desenho supoe o
# gabarito ausente ou completo, sem meio termo.
off <- setdiff(cl$verdict, vdom)
if (length(off)) {
  stop("Vereditos fora de {", paste(vdom, collapse = ", "), "}: ",
       paste(sort(unique(off)), collapse = ", "))
}
# Uma chave sem classificacao sumiria das contagens e subestimaria o
# erro em silencio, entao isto e stop() e a mensagem E a lista.
miss <- setdiff(s$position_id, cl$position_id)
if (length(miss)) {
  stop(length(miss), " posicao(oes) sem classificacao: ",
       paste(head(miss, 20), collapse = " | "))
}
cat("[OK]", nrow(cl), "linhas classificadas, dominio valido, sem repetida\n")

s <- merge(s, cl[, c("position_id", "verdict", "better", "note", "source")],
           by = "position_id", all.x = TRUE)
stopifnot(nrow(s) == n_sample, !any(is.na(s$verdict)))

# Quanto do gabarito ainda esta como o LLM deixou. Torna a revisao
# humana visivel; nao e assercao.
n_llm <- sum(s$source == "llm", na.rm = TRUE)
cat(sprintf("rotulos ainda como o LLM os deixou: %d de %d (%.0f%%)\n",
            n_llm, nrow(s), 100 * n_llm / nrow(s)))

####################################################################
### Step 7: relatorio
####################################################################

# profundidade(veredito): none = 0, cada nivel a sua posicao.
depth <- setNames(seq_along(ladder), ladder)
s$vd <- ifelse(s$verdict == "none", 0L,
               ifelse(s$verdict == "undecidable", NA_integer_,
                      depth[s$verdict]))

dec <- s[!is.na(s$vd), ]
n_und <- sum(is.na(s$vd))
n_dec <- nrow(dec)

# CI binomial exato. binom.test(0, n) devolve intervalo degenerado,
# entao o zero recebe o limite estilo regra-dos-tres, como no
# linkedin_br_name_audit.R.
ci_txt <- function(k, n) {
  if (n == 0) return("      n/a       ")
  ci <- if (k == 0) c(0, 1 - 0.05^(1 / n)) else
    if (k == n) c(0.05^(1 / n), 1) else as.numeric(binom.test(k, n)$conf.int)
  sprintf("[%5.1f%%, %5.1f%%]", 100 * ci[1], 100 * ci[2])
}

cat("\n=========== ACERTO POR NIVEL ===========\n")
cat(sprintf("decidiveis %d de %d; %d undecidable, fora do denominador\n\n",
            n_dec, nrow(s), n_und))
cat("  nivel          certos      taxa   IC 95% exato\n")
for (lv in ladder) {
  k <- sum(dec$vd >= depth[[lv]])
  cat(sprintf("  %-12s %5d/%-5d %6.1f%%   %s\n", lv, k, n_dec,
              100 * k / n_dec, ci_txt(k, n_dec)))
}

cat("\n=========== ONDE O CAMINHO QUEBRA ===========\n")
tb <- table(factor(s$verdict, levels = vdom))
for (nm in names(tb)) {
  cat(sprintf("  %-13s %4d (%5.1f%%)\n", nm, tb[[nm]],
              100 * tb[[nm]] / nrow(s)))
}

cat("\n=========== ACERTO DE job_category POR CATEGORIA ===========\n")
cat("  (IC largo: sao subconjuntos pequenos)\n")
for (g in sort(unique(dec$job_category))) {
  d <- dec[dec$job_category == g, ]
  k <- sum(d$vd >= 1L)
  cat(sprintf("  %-12s %4d/%-4d %6.1f%%   %s\n", g, k, nrow(d),
              100 * k / nrow(d), ci_txt(k, nrow(d))))
}

# Nota 7: rotulo melhor existia, ou a taxonomia nao tem resposta?
bad <- dec[dec$vd < length(ladder), ]
if (nrow(bad) > 0) {
  nb <- sum(tolower(trimws(bad$better)) == "none")
  cat(sprintf("\nDos %d caminhos com algum nivel errado, %d (%.0f%%) sem ",
              nrow(bad), nb, 100 * nb / nrow(bad)))
  cat("rotulo melhor\n  no vocabulario -- limite da taxonomia, nao do ")
  cat("classificador (nota 7).\n")
}

cat("\n=========== PIORES CASOS ===========\n")
worst <- dec[dec$vd <= 1L, ]
worst <- worst[order(worst$vd), ]
for (i in seq_len(min(15L, nrow(worst)))) {
  cat(sprintf("  [%s] %s\n      -> %s / %s / %s\n",
              worst$verdict[i], worst$title_raw[i], worst$job_category[i],
              worst$role_k50[i], worst$role_k1500[i]))
  if (nzchar(worst$note[i])) cat("      nota: ", worst$note[i], "\n", sep = "")
}

####################################################################
### Step 8: escrita
####################################################################

s$vd <- NULL
write_cols <- c("position_id", "title_raw", "title_translated", ladder,
                "seniority", "verdict", "better", "note", "source")
dbWriteTable(con, "audited", s[, write_cols], overwrite = TRUE)
invisible(dbExecute(con, sprintf(
  "COPY (SELECT * FROM audited ORDER BY position_id) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_path))))

cat("\n=========== RESUMO ===========\n")
cat(sprintf("  %d posicoes auditadas, %d decidiveis\n", nrow(s), n_dec))
cat(sprintf("  job_category certo : %.1f%%\n",
            100 * sum(dec$vd >= 1L) / n_dec))
cat(sprintf("  caminho inteiro    : %.1f%%\n",
            100 * sum(dec$vd >= length(ladder)) / n_dec))
cat("  ", out_path, "\n", sep = "")
