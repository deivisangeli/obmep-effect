################################################################################

## Download do dicionario publico da RAIS via Base dos Dados

################################################################################

rm(list = ls()); gc()

if (!requireNamespace("basedosdados", quietly = TRUE)) {
  stop("Instale o pacote 'basedosdados' antes de rodar este script.")
}

if (!requireNamespace("data.table", quietly = TRUE)) {
  stop("Instale o pacote 'data.table' antes de rodar este script.")
}

if (!requireNamespace("openxlsx", quietly = TRUE)) {
  stop("Instale o pacote 'openxlsx' antes de rodar este script.")
}

library(basedosdados)
library(data.table)
library(openxlsx)

################################################################################

### Parametros

################################################################################

billing_project_id <- Sys.getenv("BD_BILLING_PROJECT_ID", unset = "")
if (billing_project_id == "") {
  billing_project_id <- "comp-proj-457701"
}

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)

out_csv <- Sys.getenv(
  "RAIS_DICIONARIO_OUTPUT_CSV",
  unset = file.path(
    obmep_root,
    "Data",
    "raw",
    "RAIS",
    "rais_dicionario_basedosdados.csv"
  )
)

out_xlsx <- Sys.getenv(
  "RAIS_DICIONARIO_OUTPUT_XLSX",
  unset = sub("\\.csv$", ".xlsx", out_csv)
)

################################################################################

### Consulta

################################################################################

query <- "
SELECT
  *
FROM `basedosdados.br_me_rais.dicionario`
ORDER BY
  id_tabela,
  nome_coluna,
  chave
"

cat("Consulta SQL que sera executada:\n")
cat(query, "\n\n")

basedosdados::set_billing_id(billing_project_id)

dicionario_rais <- basedosdados::read_sql(
  query,
  billing_project_id = basedosdados::get_billing_id()
)

variaveis_geograficas <- grepl(
  "bairro|bairros|municipio|município|sigla_uf|uf|estado|distrito|regioes_administrativas",
  dicionario_rais$nome_coluna,
  ignore.case = TRUE
)

dicionario_rais <- dicionario_rais[!variaveis_geograficas, ]

################################################################################

### Saida

################################################################################

dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)

data.table::fwrite(
  dicionario_rais,
  file = out_csv
)

openxlsx::write.xlsx(
  dicionario_rais,
  file = out_xlsx,
  overwrite = TRUE
)

cat("Linhas salvas apos filtro:", nrow(dicionario_rais), "\n")
cat("Arquivo salvo em:", normalizePath(out_csv, winslash = "/"), "\n")
cat("Arquivo salvo em:", normalizePath(out_xlsx, winslash = "/"), "\n")
