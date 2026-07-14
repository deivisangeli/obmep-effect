################################################################################

## RAIS mock no nivel de vinculos

################################################################################

rm(list = ls()); gc()

required_packages <- c("arrow", "data.table")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
if (length(missing_packages) > 0) {
  stop(
    "Pacotes ausentes: ",
    paste(missing_packages, collapse = ", "),
    ". Instale-os antes de rodar este script."
  )
}

library(arrow)
library(data.table)

################################################################################

### Parametros

################################################################################

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)

catalog_root <- file.path(obmep_root, "Data", "raw", "Catalogos")
out_dir <- Sys.getenv(
  "RAIS_MOCK_OUTPUT_DIR",
  unset = file.path(obmep_root, "Data", "raw", "rais_mock")
)

years <- 2008:2023
target_bytes <- as.numeric(Sys.getenv("RAIS_MOCK_TARGET_BYTES", unset = 2 * 1024^3))
min_bytes <- as.numeric(Sys.getenv("RAIS_MOCK_MIN_BYTES", unset = 1.95 * 1024^3))
max_bytes <- as.numeric(Sys.getenv("RAIS_MOCK_MAX_BYTES", unset = 2.05 * 1024^3))
batch_rows <- as.integer(Sys.getenv("RAIS_MOCK_BATCH_ROWS", unset = 500000L))
pilot_rows <- as.integer(Sys.getenv("RAIS_MOCK_PILOT_ROWS", unset = 250000L))
max_attempts <- as.integer(Sys.getenv("RAIS_MOCK_MAX_ATTEMPTS", unset = 4L))
overwrite <- tolower(Sys.getenv("RAIS_MOCK_OVERWRITE", unset = "true")) %in%
  c("true", "t", "1", "yes", "y", "sim")

schema_names <- c(
  "ano",
  "CPF_MASC",
  "CO_CNPJ_CEI",
  "ultima_remuneracao",
  "remuneracao_media",
  "CO_CBO_1",
  "CO_CBO_2",
  "CO_CNAE_1",
  "CO_CNAE_2",
  "DT_NASCIMENTO"
)

################################################################################

### Catalogos locais

################################################################################

cbo_file <- file.path(catalog_root, "CBO2002", "CBO2002 - Ocupacao.csv")
cnae_file <- file.path(catalog_root, "CNAE20", "CNAE20_Subclasses_hierarquia.csv")

if (!file.exists(cbo_file)) stop("Catalogo CBO nao encontrado: ", cbo_file)
if (!file.exists(cnae_file)) stop("Catalogo CNAE nao encontrado: ", cnae_file)

cbo <- fread(cbo_file, encoding = "Latin-1")
cbo_codes <- sprintf("%06d", as.integer(cbo$CODIGO))
cbo_codes <- sort(unique(cbo_codes[!is.na(cbo_codes)]))

cnae <- fread(cnae_file, encoding = "UTF-8")
cnae_codes <- sprintf("%07d", as.integer(cnae$subclasse_codigo_rais))
cnae_codes <- sort(unique(cnae_codes[!is.na(cnae_codes)]))
cnae_classes <- substr(cnae_codes, 1L, 5L)

if (length(cbo_codes) == 0L) stop("Catalogo CBO sem codigos validos.")
if (length(cnae_codes) == 0L) stop("Catalogo CNAE sem codigos validos.")

################################################################################

### Funcoes auxiliares

################################################################################

make_batch <- function(year, n, offset) {
  idx <- as.numeric(offset) + seq_len(n)

  cpf_id <- ((idx * 7919 + year * 104729) %% 12000000) + 1
  cnpj_id <- ((idx * 3571 + year * 65537) %% 1800000) + 1

  cbo_idx <- as.integer(((idx * 17 + year) %% length(cbo_codes)) + 1)
  cnae_idx <- as.integer(((idx * 19 + year * 3) %% length(cnae_codes)) + 1)

  worker_component <- (cpf_id %% 8500) / 100
  firm_component <- (cnpj_id %% 2600) / 100
  year_component <- (year - 2008) * 15
  remuneracao_media <- round(
    900 + worker_component * 35 + firm_component * 18 + year_component,
    2
  )
  ultima_remuneracao <- round(
    pmax(0, remuneracao_media * (0.72 + ((idx %% 57) / 100))),
    2
  )

  birth_year <- 1948 + ((cpf_id * 13) %% 48)
  birth_month <- 1 + ((cpf_id * 7) %% 12)
  birth_day <- 1 + ((cpf_id * 11) %% 28)
  dt_nascimento <- as.Date(sprintf(
    "%04d-%02d-%02d",
    birth_year,
    birth_month,
    birth_day
  ))

  co_cbo_2 <- cbo_codes[cbo_idx]
  co_cnae_2 <- cnae_codes[cnae_idx]

  data.table(
    ano = as.integer(year),
    CPF_MASC = sprintf("%011d", cpf_id),
    CO_CNPJ_CEI = sprintf("%014d", cnpj_id),
    ultima_remuneracao = ultima_remuneracao,
    remuneracao_media = remuneracao_media,
    CO_CBO_1 = substr(co_cbo_2, 1L, 1L),
    CO_CBO_2 = co_cbo_2,
    CO_CNAE_1 = cnae_classes[cnae_idx],
    CO_CNAE_2 = co_cnae_2,
    DT_NASCIMENTO = dt_nascimento
  )
}

write_mock_parquet <- function(path, year, n_rows) {
  tmp_path <- paste0(path, ".tmp")
  if (file.exists(tmp_path)) file.remove(tmp_path)

  first_n <- min(batch_rows, n_rows)
  first_batch <- make_batch(year, first_n, 0L)
  first_batch <- first_batch[, ..schema_names]
  tab <- arrow_table(first_batch)

  properties <- get("ParquetWriterProperties", asNamespace("arrow"))$create(
    column_names = schema_names,
    compression = "uncompressed",
    use_dictionary = FALSE,
    write_statistics = FALSE
  )

  writer <- ParquetFileWriter$create(
    tab$schema,
    FileOutputStream$create(tmp_path),
    properties = properties
  )

  writer$WriteTable(tab, chunk_size = first_n)
  rm(first_batch, tab); gc()

  written <- first_n
  while (written < n_rows) {
    n <- min(batch_rows, n_rows - written)
    batch <- make_batch(year, n, written)
    batch <- batch[, ..schema_names]
    writer$WriteTable(arrow_table(batch), chunk_size = n)
    written <- written + n
    rm(batch); gc()
  }

  writer$Close()

  if (file.exists(path)) file.remove(path)
  file.rename(tmp_path, path)
  invisible(file.info(path)$size)
}

estimate_rows <- function(year) {
  pilot_path <- file.path(out_dir, sprintf(".rais_mock_pilot_%d.parquet", year))
  pilot_size <- write_mock_parquet(pilot_path, year, pilot_rows)
  file.remove(pilot_path)
  max(1L, as.integer(round(target_bytes / (pilot_size / pilot_rows))))
}

validate_file <- function(path, year, expected_rows) {
  reader <- ParquetFileReader$create(path)
  schema_ok <- identical(reader$GetSchema()$names, schema_names)
  rows_ok <- is.na(expected_rows) ||
    identical(as.numeric(reader$num_rows), as.numeric(expected_rows))
  size_bytes <- file.info(path)$size
  size_ok <- size_bytes >= min_bytes && size_bytes <= max_bytes

  sample_table <- reader$ReadRowGroup(0L)
  sample_dt <- as.data.table(sample_table)
  sample_dt <- sample_dt[seq_len(min(.N, 1000L))]

  sample_ok <- all(sample_dt$ano == year) &&
    all(nchar(sample_dt$CPF_MASC) == 11L) &&
    all(nchar(sample_dt$CO_CNPJ_CEI) == 14L) &&
    all(sample_dt$CO_CBO_2 %in% cbo_codes) &&
    all(sample_dt$CO_CNAE_2 %in% cnae_codes) &&
    all(sample_dt$CO_CBO_1 == substr(sample_dt$CO_CBO_2, 1L, 1L)) &&
    all(sample_dt$CO_CNAE_1 == substr(sample_dt$CO_CNAE_2, 1L, 5L)) &&
    all(!is.na(sample_dt$DT_NASCIMENTO)) &&
    all(sample_dt$ultima_remuneracao >= 0) &&
    all(sample_dt$remuneracao_media > 0)

  list(
    size_bytes = size_bytes,
    rows = reader$num_rows,
    size_ok = size_ok,
    schema_ok = schema_ok,
    rows_ok = rows_ok,
    sample_ok = sample_ok,
    status = if (size_ok && schema_ok && rows_ok && sample_ok) "ok" else "check"
  )
}

################################################################################

### Geracao

################################################################################

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
manifest <- vector("list", length(years))

cat("Diretorio de saida:", normalizePath(out_dir, winslash = "/"), "\n")
cat("Tamanho alvo por arquivo:", round(target_bytes / 1024^3, 3), "GiB\n")

for (i in seq_along(years)) {
  year <- years[i]
  out_file <- file.path(out_dir, sprintf("rais_mock_vinculos_%d.parquet", year))

  if (file.exists(out_file) && !overwrite) {
    cat("Pulando ano", year, "- arquivo ja existe.\n")
    validation <- validate_file(out_file, year, NA_integer_)
    manifest[[i]] <- data.table(
      ano = year,
      path = normalizePath(out_file, winslash = "/", mustWork = FALSE),
      rows = validation$rows,
      size_bytes = validation$size_bytes,
      size_gib = validation$size_bytes / 1024^3,
      status = validation$status
    )
    next
  }

  cat("\nAno", year, "- calibrando linhas...\n")
  rows_to_write <- estimate_rows(year)

  attempt <- 1L
  repeat {
    cat(
      "Ano", year,
      "- tentativa", attempt,
      "- linhas", format(rows_to_write, big.mark = ".", decimal.mark = ","),
      "\n"
    )

    size_bytes <- write_mock_parquet(out_file, year, rows_to_write)
    cat(
      "Ano", year,
      "- tamanho", round(size_bytes / 1024^3, 4), "GiB\n"
    )

    if ((size_bytes >= min_bytes && size_bytes <= max_bytes) ||
        attempt >= max_attempts) {
      break
    }

    rows_to_write <- max(
      1L,
      as.integer(round(rows_to_write * target_bytes / size_bytes))
    )
    attempt <- attempt + 1L
  }

  validation <- validate_file(out_file, year, rows_to_write)

  manifest[[i]] <- data.table(
    ano = year,
    path = normalizePath(out_file, winslash = "/", mustWork = FALSE),
    rows = validation$rows,
    size_bytes = validation$size_bytes,
    size_gib = validation$size_bytes / 1024^3,
    size_ok = validation$size_ok,
    schema_ok = validation$schema_ok,
    rows_ok = validation$rows_ok,
    sample_ok = validation$sample_ok,
    status = validation$status
  )

  cat("Ano", year, "- validacao:", validation$status, "\n")
}

manifest_dt <- rbindlist(manifest, fill = TRUE)
manifest_file <- file.path(out_dir, "rais_mock_manifest.csv")
fwrite(manifest_dt, manifest_file)

cat("\nManifesto salvo em:", normalizePath(manifest_file, winslash = "/"), "\n")
print(manifest_dt)

################################################################################
