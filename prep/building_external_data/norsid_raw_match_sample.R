####################################################################
###
### Dev e holdout para o matcher de university_raw SEM rsid [local only]
###
### 8h deixa 2.832.149 linhas de educacao no escopo sem openalex_id.
### 8i pegou os 71,5% que trazem university_name da Revelio. Sobra esta
### populacao: 805.913 linhas, 755.996 usuarios, 293.940 grafias
### distintas de university_raw, sem rsid E sem university_name.
###
### Elas falharam por motivo ESTRUTURAL, nao por serem lixo: tres dos
### quatro mapas existentes casam por rsid, e estas nao tem rsid. O
### quarto (shanghai_raw, 16b) casa por university_raw mas so cobre o
### top-1000 de Xangai, por igualdade de string inteira. O que sobra e
### universidade brasileira comum e resolvivel:
###
###   UNIP                                            4.640 linhas
###   Uninove - Universidade Nove de Julho            4.204
###   UFRJ - Universidade Federal do Rio de Janeiro   3.844
###   Faculdade Anhanguera                            3.596
###   UNESP - Universidade Estadual Paulista          3.523
###
### Este script SO sorteia e estaciona. O matcher e o 8l.
###
### Produtos:
###   norsid_match_dev.parquet       100 linhas, para iterar
###   norsid_match_holdout.parquet   200 linhas, pontuadas UMA vez
###   norsid_match_labels.csv        gabarito do dev, para congelar
###
### Depends on:
###   unmatched_university_raw_openalex.R (8h)  o parquet linha a linha
###
### Shape reused from:
###   capes_obmep_match_sample.R (27a) e field_manual_review.R (10i):
###   sorteio hash-ordenado, estacionado, e a consulta refeita e
###   conferida com setequal.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Le um parquet local, escreve dois parquets e um CSV.
###    Ainda e prep/; nao vai para o SEDAP.
### 2. DEV E HOLDOUT SAO DISJUNTOS POR CONSTRUCAO e o script afirma
###    isso. O holdout existe para ser pontuado UMA VEZ, no fim, com a
###    estrategia congelada. A diferenca dev-holdout e a estimativa
###    honesta de quanto eu superajustei. Pontuar o holdout durante a
###    iteracao destroi a unica medida confiavel que este desenho tem.
### 3. O SORTEIO E POR LINHA, NAO POR GRAFIA. Uma grafia com 4.640
###    linhas e 4.640 vezes mais provavel. Isso mede a fracao de
###    ENTRADAS resolvidas, que e o numero que o pipeline usa, e
###    favorece universidades famosas -- honesto quanto a impacto,
###    lisonjeiro quanto a generalidade. A fracao de GRAFIAS resolvidas
###    seria outro numero, e menor. Nao confunda os dois.
### 4. ORDER BY hash(...) LIMIT n, NUNCA USING SAMPLE. O DuckDB empurra
###    USING SAMPLE para baixo do filtro -- armadilha medida no README,
###    onde 500 linhas viraram 23. Sem set.seed(): a pasta semeia pelo
###    hash, com o seed como constante nos Parametros.
### 5. UM SEED QUE NAO REPRODUZ E PIOR QUE NENHUM. Os sorteios sao
###    estacionados, pulados na re-execucao, e as consultas refeitas e
###    conferidas com setequal contra o que ficou estacionado.
### 6. O GABARITO E CONGELADO ANTES DE QUALQUER BRACO EXISTIR. Se eu
###    rotulasse depois de ver o que o matcher diz, estaria corrigindo o
###    gabarito para o matcher, nao medindo o matcher. Este script
###    escreve o template VAZIO; o 8l recusa pontuar enquanto houver
###    rotulo em branco e recusa reescrever rotulo ja preenchido.
### 7. EXISTEM LINHAS DE EDUCACAO EXATAMENTE DUPLICADAS, e a chave do
###    sorteio carrega um indice de ocorrencia por causa disso. Medido
###    nesta populacao: 3.093 chaves (user_id, grafia, datas) aparecem 2
###    vezes e 87 aparecem 3+, somando 6.488 linhas (0,8%); mesmo
###    acrescentando degree_raw e lvl sobram 708 chaves repetidas em
###    1.476 linhas. Sao duplicatas reais da Revelio, nao erro daqui.
###    Sem o indice a chave nao e unica e a assercao de unicidade
###    quebra -- foi assim que apareceu.
### 8. OS CONJUNTOS SAO FATIAS DE UMA UNICA ORDEM TOTAL, e por isso a
###    disjuncao e PROVADA e nao provavel. A rodada 1 ordenou a
###    populacao por hash(row_key || '#seed') e tomou os rangos 1-100
###    (dev) e 101-300 (holdout); a rodada 2 toma 301-500 (dev2) e
###    501-1000 (holdout2). Semear de novo daria disjuncao apenas
###    provavel. O script AFIRMA que os rangos 1-300 continuam
###    reproduzindo os conjuntos estacionados da rodada 1.
### 9. 31 GRAFIAS REAPARECEM da rodada 1 -- 10 linhas no dev2, 21 no
###    holdout2. O rotulo da rodada 1 e reaproveitado literalmente:
###    mesma grafia, mesma instituicao, e rotular de novo convidaria
###    inconsistencia. Mas o 8l reporta o holdout2 DAS DUAS FORMAS, com
###    as 500 linhas e com as 479 cuja grafia nunca foi vista, porque
###    essas 21 nao sao estritamente ineditas.
### 10. O holdout1 ESTA GASTO. A nota dele ja foi reportada, entao nao
###    serve mais de holdout limpo: virou conjunto de REGRESSAO, medido
###    a cada iteracao e nunca otimizado.
### 11. OS ROTULOS SERAO ESCRITOS POR LLM, NAO POR HUMANO. Mesmo conflito
###    de interesse que o README registra para 17, 8i e 16a: rubrica e
###    rotulo saem do mesmo lugar, logo isto e consistencia interna e
###    NAO medida independente. O CSV e editavel para uma pessoa
###    sobrepor, e a coluna source marca cada linha.
###
####################################################################

rm(list = ls()); gc()
options(width = 200)

for (p in c("DBI", "duckdb")) {
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
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

rows_pq <- file.path(coh_dir, "unmatched_openalex_education_rows.parquet")

seed <- 20260906L

# Nota 8: fatias de uma unica ordem total. Nao mexer nos rangos 1-300 --
# sao os conjuntos da rodada 1 e o script afirma que reproduzem.
sets <- list(dev = 1:100, holdout = 101:300,
             dev2 = 301:500, holdout2 = 501:1000)

# Genericas, para a ausencia verificada. Mesma lista do 8l.
stop_tok <- c("faculdade","faculdades","centro","universitario","universitaria",
  "universidade","instituto","institute","ensino","superior","educacional",
  "educacao","university","college","school","schools","faculty","tecnologia",
  "ciencias","ciencia","estudos","integradas","integrado","unidas","grupo",
  "associacao","fundacao","sociedade","escola","curso","cursos","campus",
  "brasil","brasileira","brasileiro","santa","santo","sao","nossa","senhora",
  "estadual","federal","municipal","nacional","regional","metropolitana",
  "center","centre","virtual","online","distancia","unidade","polo",
  "universidad","universitas","uniwersytet","universita","universite")

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "8GB")
tmp_dir   <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_norsid_sample")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

# Medidos. Divergencia e sinal de dado novo -- warning, nao stop.
exp_rows    <- 805913L
exp_users   <- 755996L
exp_strings <- 293940L

stopifnot(file.exists(rows_pq))
fw <- function(z) gsub("'", "''", z)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

####################################################################
### Step 1 -- a populacao sem rsid
####################################################################

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE nr AS
SELECT user_id, university_raw, university_country, lvl, degree, degree_raw,
       startdate, enddate
FROM read_parquet('%s')
WHERE oa_source IS NULL
  AND rsid IS NULL
  AND (university_name IS NULL OR trim(university_name) = '')
  AND university_raw IS NOT NULL AND trim(university_raw) <> ''", fw(rows_pq)))

pop <- dbGetQuery(con, "
SELECT count(*) AS linhas, count(DISTINCT user_id) AS users,
       count(DISTINCT university_raw) AS strings
FROM nr")
print(pop)

drift <- function(nm, got, exp) {
  if (got != exp) {
    warning(sprintf("%s: esperado %d, obtido %d", nm, exp, got), call. = FALSE)
  }
}
drift("linhas",  pop$linhas,  exp_rows)
drift("users",   pop$users,   exp_users)
drift("strings", pop$strings, exp_strings)

####################################################################
### Step 2 -- sorteio por LINHA (nota 3), hash-ordenado (nota 4)
####################################################################

# A chave do hash e a LINHA, nao a grafia. Nota 7: linhas exatamente
# duplicadas existem, entao a chave leva um indice de ocorrencia --
# deterministico, porque para k linhas identicas sai 1..k sempre.
dbExecute(con, "
CREATE OR REPLACE TABLE keyed AS
SELECT *,
       row_number() OVER (PARTITION BY user_id, university_raw, startdate,
                                       enddate, degree_raw, lvl
                          ORDER BY 1) AS occ
FROM nr")

row_key <- "CAST(user_id AS VARCHAR) || '|' || university_raw || '|' ||
            coalesce(CAST(startdate AS VARCHAR), '') || '|' ||
            coalesce(CAST(enddate AS VARCHAR), '') || '|' ||
            coalesce(degree_raw, '') || '|' || coalesce(lvl, '') || '|' ||
            CAST(occ AS VARCHAR)"

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE ranked AS
SELECT * EXCLUDE (occ), %s AS row_key,
       hash(%s || '#%d') AS hk
FROM keyed", row_key, row_key, seed))

# Uma unica ordem total, cortada em quatro (nota 8).
dbExecute(con, sprintf("
CREATE OR REPLACE TABLE draw AS
SELECT *, row_number() OVER (ORDER BY hk, row_key) AS rk
FROM ranked
QUALIFY rk <= %d", max(unlist(sets))))

for (nm in names(sets)) {
  r <- sets[[nm]]
  sql <- sprintf("SELECT * EXCLUDE (rk) FROM draw WHERE rk BETWEEN %d AND %d",
                 min(r), max(r))
  pq <- file.path(coh_dir, sprintf("norsid_match_%s.parquet", nm))
  if (file.exists(pq)) {
    g <- dbGetQuery(con, sprintf("SELECT row_key FROM read_parquet('%s')", fw(pq)))
    e <- dbGetQuery(con, sql)
    if (!setequal(g$row_key, e$row_key)) {
      stop("Os rangos ", min(r), "-", max(r), " NAO reproduzem ", basename(pq),
           ". A ordem total mudou por baixo do sorteio.")
    }
    cat(sprintf("[ok]   %-9s ranks %4d-%4d reproduz o estacionado (%d linhas)\n",
                nm, min(r), max(r), nrow(g)))
  } else {
    invisible(dbExecute(con, sprintf(
      "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", sql, fw(pq))))
    cat(sprintf("[novo] %-9s ranks %4d-%4d estacionado\n", nm, min(r), max(r)))
  }
}

got <- lapply(names(sets), function(nm) dbGetQuery(con, sprintf(
  "SELECT row_key, university_raw FROM read_parquet('%s')",
  fw(file.path(coh_dir, sprintf("norsid_match_%s.parquet", nm))))))
names(got) <- names(sets)

####################################################################
### Validacao
####################################################################

for (nm in names(sets)) {
  if (nrow(got[[nm]]) != length(sets[[nm]])) {
    stop(sprintf("%s tem %d linhas, esperado %d",
                 nm, nrow(got[[nm]]), length(sets[[nm]])))
  }
}
all_keys <- unlist(lapply(got, function(z) z$row_key), use.names = FALSE)
if (anyDuplicated(all_keys) > 0L) {
  stop("row_key repetido ENTRE conjuntos: eles nao sao disjuntos (nota 8).")
}
cat(sprintf("\ndisjuncao afirmada: %d linhas, %d chaves unicas\n",
            length(all_keys), length(unique(all_keys))))

####################################################################
### Step 3 -- gabaritos dos conjuntos NOVOS: rotulo reaproveitado
###           (nota 9) e ausencia verificada
####################################################################

# Rotulos da rodada 1, por GRAFIA. O do dev1 e por linha, entao deduplica.
r1 <- do.call(rbind, lapply(
  c("norsid_match_labels.csv", "norsid_match_labels_holdout.csv"),
  function(f) {
    x <- read.csv(file.path(coh_dir, f), stringsAsFactors = FALSE,
                  fileEncoding = "UTF-8")
    x$label <- trimws(ifelse(is.na(x$label), "", x$label))
    x$label_name <- ifelse(is.na(x$label_name), "", x$label_name)
    x[nzchar(x$label), c("university_raw", "label", "label_name")]
  }))
r1 <- unique(r1)
if (anyDuplicated(r1$university_raw) > 0L) {
  d <- r1$university_raw[duplicated(r1$university_raw)]
  print(r1[r1$university_raw %in% d, ])
  stop("a mesma grafia tem rotulos diferentes na rodada 1.")
}
cat(sprintf("rotulos da rodada 1 disponiveis: %d grafias\n", nrow(r1)))

dbExecute(con, sprintf(
  "CREATE OR REPLACE VIEW cand AS SELECT * FROM read_parquet('%s')",
  fw(file.path(coh_dir, "oa_institution_cand_names.parquet"))))
dbExecute(con, "CREATE MACRO fs(s) AS lower(strip_accents(trim(s)))")
dbExecute(con, "
CREATE OR REPLACE TABLE oatok AS
SELECT tok, count(DISTINCT oa_id) AS df FROM (
  SELECT DISTINCT oa_id, unnest(string_split_regex(nm, '[^a-z0-9]+')) AS tok
  FROM cand
) WHERE length(tok) >= 4 GROUP BY tok")

for (nm in c("dev2", "holdout2")) {
  lab_path <- file.path(coh_dir, sprintf("norsid_match_labels_%s.csv", nm))
  if (file.exists(lab_path)) {
    x <- read.csv(lab_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8")
    x$label <- trimws(ifelse(is.na(x$label), "", x$label))
    cat(sprintf("[skip] gabarito %s existe: %d de %d rotulado(s)\n",
                nm, sum(nzchar(x$label)), nrow(x)))
    next
  }

  st <- dbGetQuery(con, sprintf("
    SELECT university_raw, count(*) AS n_rows,
           any_value(coalesce(university_country, '')) AS university_country,
           any_value(lvl) AS lvl
    FROM read_parquet('%s') GROUP BY university_raw",
    fw(file.path(coh_dir, sprintf("norsid_match_%s.parquet", nm)))))
  dbWriteTable(con, "curstr", st[, "university_raw", drop = FALSE],
               overwrite = TRUE)

  ab <- dbGetQuery(con, sprintf("
    WITH t AS (
      SELECT DISTINCT university_raw, tok FROM (
        SELECT university_raw,
               unnest(string_split_regex(fs(university_raw), '[^a-z0-9]+')) AS tok
        FROM curstr
      ) WHERE length(tok) >= 4 AND tok NOT IN ('%s')
    )
    SELECT t.university_raw, count(*) AS n_tok,
           sum(CASE WHEN o.tok IS NOT NULL THEN 1 ELSE 0 END) AS n_found,
           string_agg(t.tok, ',' ORDER BY t.tok) AS toks
    FROM t LEFT JOIN oatok o USING (tok) GROUP BY t.university_raw",
    paste(stop_tok, collapse = "','")))

  m <- merge(st, ab, by = "university_raw", all.x = TRUE)
  m$n_tok[is.na(m$n_tok)] <- 0L
  m$n_found[is.na(m$n_found)] <- 0L
  absent <- m$n_tok > 0 & m$n_found == 0

  k <- match(m$university_raw, r1$university_raw)
  reused <- !is.na(k)

  tpl <- data.frame(
    university_raw     = m$university_raw,
    university_country = m$university_country,
    lvl                = m$lvl,
    n_rows             = m$n_rows,
    seen_in_round1     = as.integer(reused),
    label       = ifelse(reused, r1$label[k], ifelse(absent, "NONE", "")),
    label_name  = ifelse(reused, r1$label_name[k], ""),
    evidence    = ifelse(reused, "rotulo reaproveitado da rodada 1 (nota 9)",
                  ifelse(absent, paste0(
                    "ausencia verificada: nenhum token distintivo (",
                    substr(m$toks, 1, 80),
                    ") aparece nas 120658 instituicoes"), "")),
    source      = ifelse(reused, "round1", ifelse(absent, "auto_absent", "")),
    stringsAsFactors = FALSE)
  tpl <- tpl[order(-tpl$n_rows, tpl$university_raw), ]

  write.csv(tpl, paste0(lab_path, ".part"), row.names = FALSE,
            fileEncoding = "UTF-8")
  if (!file.rename(paste0(lab_path, ".part"), lab_path)) {
    stop("Falha ao renomear o gabarito de ", nm)
  }
  cat(sprintf("[novo] gabarito %s: %d grafias | %d reaproveitadas | %d ausencia verificada | %d a rotular\n",
              nm, nrow(tpl), sum(reused), sum(absent & !reused),
              sum(!nzchar(tpl$label))))
}

####################################################################
### Relatorio
####################################################################

cat("\n==================================================================\n")
cat("Conjuntos -- university_raw sem rsid\n")
cat("==================================================================\n\n")
cat(sprintf("  populacao : %s linhas, %s usuarios, %s grafias\n",
            format(pop$linhas, big.mark = ","),
            format(pop$users, big.mark = ","),
            format(pop$strings, big.mark = ",")))
cat(sprintf("  seed      : %d\n\n", seed))
for (nm in names(sets)) {
  cat(sprintf("  %-9s ranks %4d-%4d  %4d linhas, %4d grafias\n", nm,
              min(sets[[nm]]), max(sets[[nm]]), nrow(got[[nm]]),
              length(unique(got[[nm]]$university_raw))))
}
cat("\n  dev/holdout = rodada 1 (holdout GASTO, virou regressao -- nota 10)\n")
cat("  dev2        = onde a rodada 2 itera\n")
cat("  holdout2    = pontuado UMA vez, no fim (nota 2)\n\n")
