################################################################################

## Extracao de colunas selecionadas da RAIS Vinculos via Base dos Dados

################################################################################

rm(list = ls()); gc()

if (!requireNamespace("basedosdados", quietly = TRUE)) {
  stop("Instale o pacote 'basedosdados' antes de rodar este script.")
}

library(basedosdados)

################################################################################

### Parametros

################################################################################

## Projeto do Google Cloud usado para billing/autenticacao no BigQuery.
## Alternativa: defina a variavel de ambiente BD_BILLING_PROJECT_ID.
billing_project_id <- Sys.getenv("BD_BILLING_PROJECT_ID", unset = "")
if (billing_project_id == "") {
  billing_project_id <- "<YOUR_PROJECT_ID>"
}

## Filtros de particao. A tabela completa e muito grande; edite estes valores
## ou defina RAIS_ANOS e RAIS_UFS como listas separadas por virgula.
anos <- Sys.getenv("RAIS_ANOS", unset = "2024")
ufs <- Sys.getenv("RAIS_UFS", unset = "SP")

## Use RAIS_MAX_ROWS="" ou RAIS_MAX_ROWS="NA" para remover o limite.
max_rows <- Sys.getenv("RAIS_MAX_ROWS", unset = "1000")

## Por padrao, a saida contem somente as colunas substantivas solicitadas.
## Use RAIS_INCLUDE_PARTITIONS=true para tambem salvar ano e sigla_uf.
include_partition_cols <- Sys.getenv("RAIS_INCLUDE_PARTITIONS", unset = "false")

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)
out_dir <- Sys.getenv(
  "RAIS_OUTPUT_DIR",
  unset = file.path(obmep_root, "Data", "raw", "RAIS")
)

################################################################################

### Funcoes auxiliares

################################################################################

parse_int_vector <- function(x) {
  x <- trimws(x)
  if (x == "" || toupper(x) %in% c("NA", "NULL")) return(NULL)
  as.integer(trimws(strsplit(x, ",", fixed = TRUE)[[1]]))
}

parse_chr_vector <- function(x) {
  x <- trimws(x)
  if (x == "" || toupper(x) %in% c("NA", "NULL")) return(NULL)
  toupper(trimws(strsplit(x, ",", fixed = TRUE)[[1]]))
}

parse_optional_int <- function(x) {
  x <- trimws(x)
  if (x == "" || toupper(x) %in% c("NA", "NULL")) return(NA_integer_)
  as.integer(x)
}

parse_bool <- function(x) {
  tolower(trimws(x)) %in% c("true", "t", "1", "yes", "y", "sim")
}

sql_quote <- function(x) {
  paste0("'", gsub("'", "''", x, fixed = TRUE), "'")
}

sql_in_int <- function(column, values) {
  if (is.null(values)) return(NULL)
  paste0(column, " IN (", paste(values, collapse = ", "), ")")
}

sql_in_chr <- function(column, values) {
  if (is.null(values)) return(NULL)
  paste0(column, " IN (", paste(sql_quote(values), collapse = ", "), ")")
}

build_rais_query <- function(columns, years, states, limit_rows) {
  where_terms <- c(
    sql_in_int("ano", years),
    sql_in_chr("sigla_uf", states)
  )
  where_terms <- where_terms[!vapply(where_terms, is.null, logical(1))]

  if (length(where_terms) == 0 && is.na(limit_rows)) {
    stop("Defina RAIS_ANOS, RAIS_UFS ou RAIS_MAX_ROWS para evitar varrer a tabela completa.")
  }

  where_sql <- if (length(where_terms) > 0) {
    paste0("WHERE ", paste(where_terms, collapse = "\n  AND "))
  } else {
    ""
  }

  limit_sql <- if (!is.na(limit_rows)) {
    paste0("LIMIT ", limit_rows)
  } else {
    ""
  }

  paste(
    "SELECT",
    paste0("  ", columns, collapse = ",\n"),
    "FROM `basedosdados.br_me_rais.microdados_vinculos`",
    where_sql,
    limit_sql,
    sep = "\n"
  )
}

################################################################################

### Colunas selecionadas

################################################################################

## No esquema publico consultado em 2026-05-06 nao ha id individual, id de firma
## ou id do vinculo na tabela de vinculos. A Base dos Dados informa que os dados
## publicos sao anonimizados e nao contem CPFs nem CNPJs.
##
## Colunas disponiveis para os conceitos pedidos:
## - cbo_2002: CBO 2002 no nivel mais fino disponivel na tabela.
## - cnae_2 e cnae_2_subclasse: CNAE 2.0; subclasse e o nivel mais detalhado.
## - idade: idade do trabalhador.

anos <- parse_int_vector(anos)
ufs <- parse_chr_vector(ufs)
max_rows <- parse_optional_int(max_rows)
include_partition_cols <- parse_bool(include_partition_cols)

selected_columns <- c("cbo_2002", "cnae_2", "cnae_2_subclasse", "idade")
if (include_partition_cols) {
  selected_columns <- c("ano", "sigla_uf", selected_columns)
}

query <- build_rais_query(
  columns = selected_columns,
  years = anos,
  states = ufs,
  limit_rows = max_rows
)

cat("Consulta SQL que sera executada:\n")
cat(query, "\n\n")

################################################################################

### Execucao no padrao R indicado pela Base dos Dados

################################################################################

if (billing_project_id == "<YOUR_PROJECT_ID>") {
  stop("Defina billing_project_id ou a variavel de ambiente BD_BILLING_PROJECT_ID.")
}

basedosdados::set_billing_id(billing_project_id)

rais_vinculos <- basedosdados::read_sql(
  query,
  billing_project_id = basedosdados::get_billing_id()
)

################################################################################

### Saida

################################################################################

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

years_label <- if (is.null(anos)) "all_years" else paste(range(anos), collapse = "-")
ufs_label <- if (is.null(ufs)) "all_ufs" else paste(ufs, collapse = "-")
rows_label <- if (is.na(max_rows)) "full" else paste0("n", max_rows)

out_base <- paste(
  "rais_vinculos_basedosdados",
  years_label,
  ufs_label,
  rows_label,
  sep = "_"
)

saveRDS(rais_vinculos, file.path(out_dir, paste0(out_base, ".rds")))
utils::write.csv(
  rais_vinculos,
  file.path(out_dir, paste0(out_base, ".csv")),
  row.names = FALSE,
  fileEncoding = "UTF-8"
)

cat("Linhas extraidas:", nrow(rais_vinculos), "\n")
cat("Arquivos salvos em:", normalizePath(out_dir, winslash = "/"), "\n")
