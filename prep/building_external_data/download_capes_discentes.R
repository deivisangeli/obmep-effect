####################################################################
### Discentes da Pos-Graduacao Stricto Sensu (CAPES) 2004-2024
### Download dos 21 arquivos .xlsx publicados
###
### Baixa a serie completa de discentes de pos-graduacao stricto sensu
### do Brasil publicada pela CAPES em dados abertos: UM .xlsx POR ANO,
### de 2004 a 2024, espalhados por QUATRO conjuntos de dados distintos
### (2004-2012, 2013-2016, 2017-2020, 2021-2024). Grava os arquivos
### crus no Dropbox do OBMEP e um manifesto CSV com a procedencia de
### cada um.
###
### ESTE SCRIPT USA REDE. E local e online, como os scripts 2, 5, 7-9
### e 14 desta pasta; ver AGENTS.md -> Execution Environments. Nao pode
### ser copiado para scripts_sedap/. Nao usa S3 nem Athena: so HTTP
### contra dadosabertos.capes.gov.br e escrita no Dropbox.
###
### Cada ano existe em DUAS formas na CAPES, .xlsx e .csv, com o mesmo
### conteudo. Este script baixa o .xlsx de proposito. O .csv e latin1,
### delimitado por ponto-e-virgula, com texto livre acentuado; o .xlsx
### e UTF-8 por construcao e o problema de encoding simplesmente nao
### existe. O custo e um parse mais lento, pago uma unica vez porque o
### script seguinte guarda um parquet por ano.
###
### ATENCAO / LIMITACOES, todas medidas contra o servidor real:
###
###  1. AS URLS NAO PODEM SER FIXADAS NO CODIGO. O nome do arquivo
###     carrega a data de publicacao e o UUID do recurso muda junto a
###     cada republicacao: 2021-2023 sao "...-2025-03-31.xlsx" mas 2024
###     e "...-2025-12-01.xlsx". Por isso os recursos sao resolvidos em
###     tempo de execucao pela API CKAN, a partir dos quatro slugs de
###     conjunto, que sao estaveis. Fixar as 21 URLs garante um 404 na
###     proxima release.
###
###  2. O SERVIDOR LEVA DE 45 A 180 SEGUNDOS PARA O PRIMEIRO BYTE, e as
###     vezes mais. E um Werkzeug/1.0.0 Python/3.7.3 falando HTTP/1.0.
###     Toda requisicao testada com corte de 45s falhou com zero bytes;
###     a mesma requisicao com 180s devolveu 200. Este e o fato
###     operacional mais importante do script: um timeout normal de 30
###     ou 60 segundos faz tudo parecer permanentemente quebrado. Daqui
###     vem connecttimeout alto e timeout total desligado, com
###     low_speed_limit no lugar dele para ainda abortar socket morto.
###
###  3. NAO HA SUPORTE A RANGE, LOGO NAO HA RETOMADA. O servidor nao
###     manda Accept-Ranges, e mandar um cabecalho Range o faz TRAVAR de
###     vez, sem resposta nenhuma. Um arquivo parcial so pode ser jogado
###     fora e baixado de novo; nao ha como continuar de onde parou.
###
###  4. O SLUG DO CONJUNTO 2017-2020 MENTE. Ele diz "2017-a-2019", mas o
###     titulo e o conteudo sao 2017 a 2020, com quatro anos. O slug
###     esta escrito como a CAPES publicou; nao "corrigir".
###
###  5. SAO CERCA DE 1 GB EM 21 ARQUIVOS com o tempo de resposta acima.
###     Conte horas, nao minutos, e conte com reexecutar. Rodar de novo
###     pula tudo que ja esta em disco e nao transfere nada.
###
### Padrao de download com cache reaproveitado de:
###   prep/building_external_data/ruf_course_rankings.R
### Padrao de tabela de edicoes e manifesto reaproveitado de:
###   prep/download_hurun_global_unicorn_index.R
###
### Depends on:
###   (nada -- e a origem da cadeia)
###
### Consumed by:
###   prep/building_external_data/capes_discentes_panel.R
####################################################################

for (p in c("curl", "jsonlite", "readxl", "readr", "openssl")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}

####################################################################
### Parametros
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")

api_base <- "https://dadosabertos.capes.gov.br/api/3/action/package_show?id="

raw_dir       <- file.path(obmep_root, "Data/raw/capes_discentes")
manifest_path <- file.path(raw_dir, "capes_discentes_download_manifest.csv")

# Os quatro conjuntos. O slug e estavel; o UUID do conjunto e os UUIDs
# dos recursos nao sao, e por isso nao aparecem aqui. Ver ATENCAO 1 e 4.
packages <- data.frame(
  period = c("2004a2012", "2013a2016", "2017a2020", "2021a2024"),
  slug = c(
    "discentes-dos-programas-de-pos-graduacao-stricto-sensu-no-brasil-2004-a-2012",
    "discentes-da-pos-graduacao-stricto-sensu-do-brasil-2013-a-2016",
    "discentes-da-pos-graduacao-stricto-sensu-do-brasil-2017-a-2019",
    "2021-a-2024-discentes-da-pos-graduacao-stricto-sensu-do-brasil"
  ),
  stringsAsFactors = FALSE
)

exp_years <- 2004:2024

max_attempts <- 5L
sleep_s      <- 1.0

# Ver ATENCAO 2. connecttimeout generoso, timeout total desligado, e
# low_speed_* no lugar do timeout para que um socket que parou de
# entregar bytes ainda aborte em vez de pendurar o script para sempre.
ua <- paste("Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
            "AppleWebKit/537.36 (KHTML, like Gecko)",
            "Chrome/140.0.0.0 Safari/537.36")
connect_timeout_s <- 120L
low_speed_bytes   <- 1024L
low_speed_secs    <- 300L

dir.create(raw_dir, recursive = TRUE, showWarnings = FALSE)

cat("CAPES discentes stricto sensu", min(exp_years), "-", max(exp_years), "\n")
cat("destino:", raw_dir, "\n\n")

####################################################################
### Resolucao dos recursos pela API CKAN
####################################################################

# Um GET por conjunto. Guarda so os recursos XLSX e tira o ano do nome
# do recurso, que e sempre BR-CAPES-COLSUCUP-DISCENTES-<ano>-<data>.
h_api <- curl::new_handle()
curl::handle_setopt(h_api, useragent = ua, followlocation = TRUE,
                    connecttimeout = connect_timeout_s, timeout = 0L,
                    accept_encoding = "gzip, deflate")

cat("Resolvendo recursos:\n")
found <- vector("list", nrow(packages))

for (i in seq_len(nrow(packages))) {
  slug <- packages$slug[[i]]
  cat("  ", packages$period[[i]], " ... ", sep = "")

  resp <- NULL
  for (attempt in seq_len(max_attempts)) {
    r <- try(curl::curl_fetch_memory(paste0(api_base, slug), handle = h_api),
             silent = TRUE)
    if (!inherits(r, "try-error") && r$status_code == 200L) {
      resp <- r
      break
    }
    if (attempt < max_attempts) Sys.sleep(2^(attempt - 1L))
  }
  if (is.null(resp)) {
    stop("Nao foi possivel ler a API CKAN para o conjunto ", slug)
  }

  txt <- rawToChar(resp$content)
  Encoding(txt) <- "UTF-8"
  parsed <- jsonlite::fromJSON(txt, simplifyVector = FALSE)
  if (!isTRUE(parsed$success)) {
    stop("API CKAN devolveu success=false para ", slug)
  }

  res <- parsed$result$resources
  keep <- vapply(res, function(x) identical(toupper(x$format), "XLSX"),
                 logical(1))
  res <- res[keep]
  if (!length(res)) stop("Nenhum recurso XLSX em ", slug)

  # O ano vem do nome do recurso, nao da ordem: a API nao promete ordem.
  nm <- toupper(vapply(res, function(x) x$name, character(1)))
  yr <- rep(NA_integer_, length(nm))
  hit <- grepl("DISCENTES[-][0-9]{4}[-]", nm)
  yr[hit] <- as.integer(sub(".*DISCENTES[-]([0-9]{4})[-].*", "\\1", nm[hit]))
  if (anyNA(yr)) {
    stop("Nome de recurso XLSX fora do padrao esperado em ", slug, ": ",
         paste(nm[is.na(yr)], collapse = ", "))
  }

  found[[i]] <- data.frame(
    year        = yr,
    period      = packages$period[[i]],
    slug        = slug,
    resource_id = vapply(res, function(x) x$id, character(1)),
    url         = vapply(res, function(x) x$url, character(1)),
    stringsAsFactors = FALSE
  )
  cat(nrow(found[[i]]), "xlsx\n")
}

resources <- do.call(rbind, found)
resources <- resources[order(resources$year), , drop = FALSE]
rownames(resources) <- NULL
resources$filename <- basename(resources$url)
resources$dest     <- file.path(raw_dir, resources$filename)

# A checagem que transforma uma republicacao da CAPES em erro claro em
# vez de um dataset silenciosamente incompleto. Ver ATENCAO 1.
stopifnot(anyDuplicated(resources$year) == 0L,
          identical(resources$year, exp_years),
          all(grepl("[.]xlsx$", resources$filename)))

cat("\n", nrow(resources), " recursos XLSX resolvidos, ",
    min(resources$year), "-", max(resources$year), ", sem lacuna\n\n", sep = "")

####################################################################
### Download, com cache
####################################################################

# Baixa so o que ainda nao existe. Escreve em .part e renomeia apenas
# depois de o arquivo abrir como xlsx de verdade, para que um download
# truncado nunca fique em disco fingindo ser cache valido. Sem Range em
# nenhuma hipotese: ver ATENCAO 3.
h_file <- curl::new_handle()
curl::handle_setopt(h_file, useragent = ua, followlocation = TRUE,
                    connecttimeout = connect_timeout_s, timeout = 0L,
                    low_speed_limit = low_speed_bytes,
                    low_speed_time = low_speed_secs,
                    accept_encoding = "gzip, deflate")
curl::handle_setheaders(h_file,
                        Referer = "https://dadosabertos.capes.gov.br/")

baixar <- function(url, destino) {
  if (file.exists(destino) && file.size(destino) > 0L) {
    cat("  [skip] ", basename(destino), " (",
        round(file.size(destino) / 1024^2, 1), " MB)\n", sep = "")
    return(invisible(FALSE))
  }
  parcial <- paste0(destino, ".part")
  if (file.exists(parcial)) unlink(parcial)

  for (attempt in seq_len(max_attempts)) {
    cat("  baixando ", basename(destino), " tentativa ", attempt, " ... ",
        sep = "")
    t0 <- Sys.time()
    r <- try(curl::curl_fetch_disk(url, parcial, handle = h_file),
             silent = TRUE)
    secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))

    ok <- !inherits(r, "try-error") && r$status_code == 200L &&
      file.exists(parcial) && file.size(parcial) > 0L

    if (ok) {
      # Os dois bytes PK sao o zip do xlsx; excel_sheets() confirma que
      # o zip esta inteiro, e nao so que comecou certo.
      magic <- readBin(parcial, "raw", n = 2L)
      ok <- identical(magic, as.raw(c(0x50, 0x4b))) &&
        !inherits(try(readxl::excel_sheets(parcial), silent = TRUE),
                  "try-error")
      if (!ok) cat("arquivo nao abre como xlsx; ")
    } else if (inherits(r, "try-error")) {
      cat("erro de rede; ")
    } else if (!inherits(r, "try-error")) {
      cat("HTTP ", r$status_code, "; ", sep = "")
    }

    if (ok) {
      file.rename(parcial, destino)
      cat("[OK] ", round(file.size(destino) / 1024^2, 1), " MB em ",
          round(secs), "s\n", sep = "")
      Sys.sleep(sleep_s)
      return(invisible(TRUE))
    }

    unlink(parcial)
    cat("falhou apos ", round(secs), "s\n", sep = "")
    if (attempt < max_attempts) Sys.sleep(2^(attempt - 1L) * 5)
  }
  stop("Nao foi possivel baixar ", basename(destino), " apos ",
       max_attempts, " tentativas: ", url)
}

for (i in seq_len(nrow(resources))) {
  cat(resources$year[[i]], ":\n", sep = "")
  baixar(resources$url[[i]], resources$dest[[i]])
}

####################################################################
### Validacao e manifesto
####################################################################

faltando <- resources$filename[!file.exists(resources$dest)]
if (length(faltando)) {
  stop("Sem arquivo em disco para: ", paste(faltando, collapse = ", "))
}

resources$bytes <- file.size(resources$dest)
stopifnot(all(resources$bytes > 0L))

# sha256 para que uma republicacao da CAPES apareca como conteudo
# diferente, e nao so como data diferente no nome do arquivo.
resources$sha256 <- vapply(
  resources$dest,
  function(p) {
    con <- file(p, "rb")
    on.exit(close(con), add = TRUE)
    as.character(openssl::sha256(con))
  },
  character(1), USE.NAMES = FALSE
)

manifest <- data.frame(
  year              = resources$year,
  period            = resources$period,
  package_slug      = resources$slug,
  resource_id       = resources$resource_id,
  resource_url      = resources$url,
  filename          = resources$filename,
  bytes             = resources$bytes,
  sha256            = resources$sha256,
  downloaded_at_utc = format(file.mtime(resources$dest), tz = "UTC",
                             format = "%Y-%m-%dT%H:%M:%SZ"),
  stringsAsFactors = FALSE
)
readr::write_csv(manifest, manifest_path, na = "")

cat("\nresumo por periodo:\n")
for (pr in packages$period) {
  sel <- manifest$period == pr
  cat("  ", pr, ": ", sum(sel), " arquivos, ",
      round(sum(manifest$bytes[sel]) / 1024^2), " MB\n", sep = "")
}

cat("\nGravado:", raw_dir, "\n")
cat("arquivos:", nrow(manifest), "\n")
cat("total   :", round(sum(manifest$bytes) / 1024^2, 1), "MB\n")
cat("manifesto:", manifest_path, "\n")
