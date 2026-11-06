####################################################################
###
### Crosswalk de perfis possivelmente brasileiros -> S3 + Athena
###
### Seleciona todo user_id com p_brazil > 0.05 a partir da saida de
### prep/building_external_data/linkedin_br_name_flag.R, grava um parquet unico, envia para o
### S3 e registra como tabela externa no Athena. A ideia e usar este
### crosswalk depois COMBINADO com outros criterios (founder/CEO,
### educacao, empresa) dentro do Athena.
###
### Padrao de upload reaproveitado de:
###   gtl/gtfounders/Cleaning and Gathering/1-Get_Founders_IDs.R
###
### -----------------------------------------------------------------
### ATENCAO / LIMITACOES
### -----------------------------------------------------------------
### 1. Este script DEPENDE DE INTERNET, ao contrario da regra geral do
###    AGENTS.md. E uma excecao deliberada: enviar para o S3 e o
###    proprio objetivo. E script local de prep/, nao vai para o
###    ambiente offline do SEDAP. O Passo 1 (linkedin_br_name_flag.R)
###    continua 100% offline.
### 2. O crosswalk e um PRIOR baseado em nome, nao nacionalidade. Com
###    corte em 0,05 ele seleciona 19,8% de todos os perfis (140,3M),
###    muito acima da participacao plausivel do Brasil no LinkedIn
###    (~8-11%). NAO leia como "estes sao brasileiros": o uso previsto
###    e cruzar com outros criterios.
### 3. p_brazil e ORDENAMENTO, nao probabilidade calibrada.
### 4. Como p_brazil vai no arquivo, o corte pode ser APERTADO no
###    Athena sem regerar nada -- mas nao pode ser afrouxado abaixo
###    de 0,05.
### 5. Perfis com nome em alfabeto nao-latino (41,0M, 5,8%) tem
###    p_brazil NULL e ficam fora do crosswalk.
###
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "aws.s3", "RAthena", "glue")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}
library(DBI)
library(duckdb)
library(aws.s3)
library(glue)

####################################################################
### Parametros
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")

flag_dir   <- file.path(obmep_root, "Data/intermediate/linkedin_br_flags")
prof_glob  <- file.path(flag_dir, "profiles/chunk_*.parquet")
local_pq   <- file.path(flag_dir, "linkedin_br_name_flag.parquet")

p_cut      <- 0.05
mem_limit  <- "12GB"

s3_bucket  <- "revelio-misc"
s3_region  <- "us-east-2"
s3_prefix  <- "linkedin_br_name_flag"
s3_object  <- paste0(s3_prefix, "/linkedin_br_name_flag.parquet")
s3_path    <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table  <- "linkedin_br_name_flag"

# O RAthena fala com o Athena via boto3/reticulate. Nesta maquina o
# `python` do PATH e o shim de WindowsApps, que o reticulate ignora de
# proposito -- resultado: py_discover_config() nao acha nada e o
# RAthena conclui que falta boto3, quando na verdade existe um Python
# real com boto3 e numpy ja instalados. Apontar o reticulate para o
# interpretador de verdade resolve, sem instalar nada.
#
# So define se RETICULATE_PYTHON estiver vazio: sessao interativa que
# ja resolve o Python corretamente nunca e sobrescrita.
py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

# Medido no Passo 1: numero de perfis com p_brazil > 0.05.
exp_rows <- 140263729

stopifnot(dir.exists(flag_dir))

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_linkedin_br")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

####################################################################
### Passo 1: gravar o parquet local a partir do DuckDB
####################################################################

# 140M linhas nunca entram num data.frame de R: COPY faz streaming.
# ORDER BY user_id e deliberado -- alem de comprimir melhor, da a cada
# row group estatisticas min/max estreitas de user_id, o que permite ao
# Athena podar row groups quando este crosswalk for joinado por
# user_id, que e exatamente o uso previsto.
con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))
dbExecute(con, "SET preserve_insertion_order=false")

if (file.exists(local_pq)) {
  cat("[skip] parquet local ja existe:", local_pq, "\n")
} else {
  cat("Gravando parquet local (p_brazil >", p_cut, ")...\n")
  t0 <- Sys.time()
  dbExecute(con, sprintf("
    COPY (SELECT user_id, p_brazil
          FROM read_parquet('%s')
          WHERE p_brazil > %.10f
          ORDER BY user_id)
    TO '%s' (FORMAT PARQUET, COMPRESSION SNAPPY)",
    prof_glob, p_cut, local_pq))
  cat("  concluido em",
      round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
}

sz <- file.info(local_pq)$size
cat(sprintf("Arquivo: %s (%.2f GB)\n\n", local_pq, sz / 2^30))

####################################################################
### Passo 2: validacao ANTES do upload
####################################################################

# O upload e a etapa dificil de reverter, e a validacao aqui e barata.
cat("=========== VALIDACAO PRE-UPLOAD ===========\n")
print(dbGetQuery(con, sprintf("DESCRIBE SELECT * FROM read_parquet('%s')", local_pq)))

v <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_rows,
         count(DISTINCT user_id) AS n_users,
         sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS uid_null,
         sum(CASE WHEN p_brazil IS NULL THEN 1 ELSE 0 END) AS p_null,
         min(p_brazil) AS p_min, max(p_brazil) AS p_max,
         min(user_id) AS uid_min, max(user_id) AS uid_max
  FROM read_parquet('%s')", local_pq))
print(v)

sch <- dbGetQuery(con, sprintf("DESCRIBE SELECT * FROM read_parquet('%s')", local_pq))
if (!identical(sch$column_name, c("user_id", "p_brazil"))) {
  stop("Schema inesperado: ", paste(sch$column_name, collapse = ", "))
}
if (!identical(sch$column_type, c("BIGINT", "DOUBLE"))) {
  stop("Tipos inesperados: ", paste(sch$column_type, collapse = ", "))
}
if (v$n_rows != exp_rows) stop("Esperado ", exp_rows, " linhas, obtido ", v$n_rows)
if (v$n_users != v$n_rows) stop("user_id duplicado no crosswalk.")
if (v$uid_null != 0 || v$p_null != 0) stop("Ha NULL em user_id ou p_brazil.")
if (v$p_min <= p_cut) stop("p_brazil minimo (", v$p_min, ") nao respeita o corte.")
if (v$p_max > 1) stop("p_brazil maximo acima de 1.")
cat("[OK] todas as validacoes pre-upload passaram\n\n")

####################################################################
### Passo 3: upload para o S3
####################################################################

# LOCATION do Athena e um PREFIXO: qualquer objeto solto sob
# linkedin_br_name_flag/ seria lido como dado da tabela. Por isso
# inspecionamos o prefixo antes.
cat("=========== CONTEUDO ATUAL DO PREFIXO S3 ===========\n")
existing <- tryCatch(
  get_bucket(bucket = s3_bucket, prefix = paste0(s3_prefix, "/"),
             region = s3_region, max = 100),
  error = function(e) { cat("  [erro ao listar]:", conditionMessage(e), "\n"); NULL })
if (is.null(existing) || length(existing) == 0) {
  cat("  prefixo vazio\n")
} else {
  for (o in existing) cat("  ", o$Key, " (", o$Size, " bytes )\n")
}

# Idempotencia: se o objeto ja esta no S3 com o mesmo numero de bytes,
# nao reenvia 0,77 GB de graca. E o que torna barato reexecutar o
# script so para concluir o registro no Athena.
hd0 <- tryCatch(head_object(object = s3_object, bucket = s3_bucket,
                            region = s3_region),
                error = function(e) NULL)
remote_sz <- if (!is.null(hd0) && as.logical(hd0)) {
  as.numeric(attr(hd0, "content-length")) } else NA_real_

if (!is.na(remote_sz) && remote_sz == sz) {
  cat("\n[skip] objeto ja existe no S3 com", remote_sz,
      "bytes (identico ao local) -- upload dispensado\n")
} else {
  if (!is.na(remote_sz)) {
    cat("\n[aviso] objeto remoto tem", remote_sz, "bytes vs", sz,
        "local -- reenviando\n")
  }
  cat("\nEnviando para s3://", s3_bucket, "/", s3_object, " ...\n", sep = "")
  t0 <- Sys.time()
  # multipart = TRUE: desvio deliberado do script de referencia, que usa
  # PUT unico. Para ~1 GB o PUT unico e lento e tudo-ou-nada.
  ok <- put_object(
    file      = local_pq,
    object    = s3_object,
    bucket    = s3_bucket,
    region    = s3_region,
    multipart = TRUE
  )
  cat("  put_object devolveu:", ok, "em",
      round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
}

hd <- head_object(object = s3_object, bucket = s3_bucket, region = s3_region)
cat("  objeto existe no S3:", as.logical(hd), "\n")
cat("  tamanho remoto:", attr(hd, "content-length"),
    "| local:", sz, "\n\n")
if (!as.logical(hd)) stop("Objeto nao encontrado no S3 apos o upload.")

####################################################################
### Passo 4: registrar a tabela externa no Athena
####################################################################

cat("=========== ATHENA ===========\n")

ddl_txt <- sprintf(
"CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (
  user_id BIGINT,
  p_brazil DOUBLE
)
STORED AS PARQUET
LOCATION '%s'", athena_schema, athena_table, s3_path)

# RAthena depende de boto3 via reticulate. Em sessao nao-interativa o
# reticulate pode resolver um Python sem boto3, e nesse caso o registro
# da tabela falha DEPOIS de o upload ja ter dado certo. Por isso a
# etapa e tolerante a falha: o objeto no S3 e o entregavel principal e
# nao pode ser perdido por causa de dependencia de Python. O DDL e
# impresso para execucao manual.
athena_ok <- tryCatch({
  acon <- dbConnect(RAthena::athena(),
                    s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                    region_name    = s3_region,
                    schema_name    = athena_schema)
  cat(ddl_txt, "\n")
  dbExecute(acon, ddl_txt)

  cat("\n--- verificacao via Athena ---\n")
  a <- dbGetQuery(acon, sprintf(
    "SELECT count(*) AS n_rows, count(DISTINCT user_id) AS n_users,
            min(p_brazil) AS p_min, max(p_brazil) AS p_max
     FROM %s.%s", athena_schema, athena_table))
  print(a)
  print(dbGetQuery(acon, sprintf("SELECT * FROM %s.%s LIMIT 10",
                                 athena_schema, athena_table)))

  if (a$n_rows != exp_rows) {
    stop("Athena devolveu ", a$n_rows, " linhas, esperado ", exp_rows)
  }
  if (a$n_users != a$n_rows) stop("Athena: user_id duplicado.")
  cat("\n[OK] tabela ", athena_schema, ".", athena_table,
      " registrada e verificada\n", sep = "")
  dbDisconnect(acon)
  TRUE
}, error = function(e) {
  cat("\n[FALHA NO PASSO ATHENA]", conditionMessage(e), "\n\n")
  cat("O upload para o S3 FOI CONCLUIDO -- so o registro da tabela\n",
      "faltou. Rode o DDL abaixo numa sessao onde RAthena/boto3\n",
      "funcione (ou instale com RAthena::install_boto()):\n\n", sep = "")
  cat(ddl_txt, "\n\n")
  FALSE
})

cat("\n=========== RESUMO ===========\n")
cat("  parquet local :", local_pq, sprintf("(%.2f GB)\n", sz / 2^30))
cat("  objeto S3     : s3://", s3_bucket, "/", s3_object, "\n", sep = "")
cat("  linhas        :", format(v$n_rows, big.mark = ","), "\n")
cat("  tabela Athena :", ifelse(athena_ok, "registrada e verificada",
                                "PENDENTE -- rodar o DDL acima"), "\n")
cat("  S3 LOCATION   :", s3_path, "\n")
