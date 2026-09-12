####################################################################
### CWUR Global 2000 - World University Rankings 2026
###
### Baixa a lista Global 2000 do Center for World University Rankings e
### grava um parquet no Dropbox do OBMEP com UMA LINHA POR INSTITUICAO,
### 2.000 no total, com a posicao mundial, a nacional, as quatro
### sub-posicoes, a nota e o pais ja em ISO2.
###
### ESTE SCRIPT USA REDE. E local e online, como os scripts 2, 5, 7-9,
### 14 e 22 desta pasta; ver AGENTS.md -> Execution Environments. Nao
### pode ser copiado para scripts_sedap/. Nao usa S3 nem Athena: so HTTP
### contra cwur.org e escrita de parquet no Dropbox.
###
### AO CONTRARIO DO RUF, AQUI E HTML. A pagina do RUF e uma casca Vue e
### os dados vem de JSON; a do CWUR traz a tabela inteira no HTML
### estatico, dentro de <table id="cwurTable">, sem paginacao, sem
### datatable em JS e sem link de CSV ou XLSX. UMA requisicao traz tudo.
### Este e o primeiro parse de HTML desta pasta - dai o xml2, que ja e o
### motor do rvest e evita trazer o rvest inteiro por uma unica chamada.
###
### QUATRO ARMADILHAS, todas medidas contra a pagina real:
###
###  1. A CELULA DA POSICAO CARREGA DOIS VALORES. O HTML e
###     <td>1<br>Top&nbsp;0.1%</td> e o texto sai como '1Top 0.1%',
###     separado por ESPACO NAO SEPARAVEL (U+00A0). No locale
###     Portuguese_Brazil.utf8 desta maquina, sub('^([0-9]+).*$','\\1',x)
###     devolve STRING VAZIA nele - em silencio, nas 2.000 linhas. A
###     extracao e feita no DuckDB com regexp_extract(x,'^[0-9]+'), que e
###     seguro em UTF-8.
###
###  2. FALTANTE TEM DUAS FORMAS, NAO UMA. As quatro sub-posicoes usam
###     '-' (1.555 / 965 / 1.689 / 64 linhas), mas faculty_rank TAMBEM
###     traz 31 linhas com STRING VAZIA. nullif(x,'-') sozinho deixa
###     essas 31 como '' e o cast falha calado; por isso
###     nullif(nullif(x,'-'),'').
###
###  3. O SLUG NAO E [a-z0-9-]+. 186 dos 2.000 hrefs tem virgula,
###     apostrofo, e comercial, ponto ou travessao:
###     'university-of-california,-berkeley', 'texas-a&m-university,...',
###     'technion---israel-institute-of-technology'. Um regex
###     ([a-z0-9-]+)[.]php$ devolve 15 vazios e 31 duplicados. O que
###     funciona e ([^/]+)[.]php$, unico e nao vazio nas 2.000.
###
###  4. O 403 VEM DA LISTA DE BOTS DO SITE, NAO DA FALTA DE USER-AGENT.
###     Um UA de crawler de IA conhecido leva 403; curl puro, sem UA
###     nenhum, e um UA descritivo levam 200. O robots.txt e
###     'User-agent: * / Allow: /', com Disallow so para ClaudeBot,
###     GPTBot, CCBot, Amazonbot e afins, e o content signal e
###     'search=yes, ai-train=no, use=reference'. Um cliente de pesquisa
###     comum pegando UMA pagina esta dentro do Allow e dentro do
###     use=reference. O UA daqui e descritivo de proposito: nao ha por
###     que fingir ser um navegador.
###
### ESCOPO: SOMENTE a edicao 2026. As paginas 2021, 2023, 2024 e 2025
### existem sob o mesmo padrao de URL, e so a 2026 foi verificada aqui;
### 2020 e 2022 nem respondem nesse padrao.
###
### O conteudo e do Center for World University Rankings e esta protegido
### por direito autoral (c) 2012-2026. Isto e insumo interno de pesquisa,
### nao material para redistribuicao.
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "arrow", "curl", "xml2", "countrycode")) {
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

edition  <- 2026L
page_url <- sprintf("https://cwur.org/%d.php", edition)

out_dir  <- file.path(obmep_root, "Data/intermediate/cwur_ranking")
raw_dir  <- file.path(out_dir, "raw", as.character(edition))
raw_path <- file.path(raw_dir, sprintf("cwur_%d.html", edition))
out_path <- file.path(out_dir, sprintf("cwur_global_2000_%d.parquet", edition))

# Valores medidos contra a edicao 2026.
exp_rows      <- 2000L
exp_cols      <- 9L
exp_labels    <- 95L
exp_countries <- 94L
exp_accents   <- 151L
exp_ranked    <- 21291L
exp_dash      <- c(education_rank = 1555L, employability_rank = 965L,
                   faculty_rank = 1689L, research_rank = 64L)
exp_empty_fac <- 31L

# Ver armadilha 4. UA descritivo, nao de navegador.
ua <- "obmep-effect research pipeline (R/curl)"
max_attempts      <- 5L
connect_timeout_s <- 120L

for (d in c(out_dir, raw_dir)) dir.create(d, recursive = TRUE, showWarnings = FALSE)

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_cwur")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

cat("CWUR Global 2000", edition, "\n")
cat("origem:", page_url, "\n")
cat("cache :", raw_path, "\n")
cat("saida :", out_path, "\n\n")

####################################################################
### Download, com cache
####################################################################

# Mesma disciplina do script 14: le do cache se ele existir, e so escreve
# o arquivo depois de status 200 E do HTML ter sido parseado com a tabela
# esperada dentro. Assim uma pagina truncada nunca fica em disco fingindo
# ser cache valido.
if (file.exists(raw_path) && file.size(raw_path) > 0L) {
  cat("cache encontrado,", round(file.size(raw_path) / 1024), "KB; sem rede\n")
  html_txt <- readChar(raw_path, file.size(raw_path), useBytes = TRUE)
  Encoding(html_txt) <- "UTF-8"
} else {
  h <- curl::new_handle()
  curl::handle_setopt(h, useragent = ua, followlocation = TRUE,
                      connecttimeout = connect_timeout_s, timeout = 0L,
                      accept_encoding = "gzip, deflate")

  cat("baixando ... ")
  resp <- NULL
  for (attempt in seq_len(max_attempts)) {
    r <- try(curl::curl_fetch_memory(page_url, handle = h), silent = TRUE)
    if (!inherits(r, "try-error") && r$status_code == 200L) {
      resp <- r
      break
    }
    if (attempt < max_attempts) Sys.sleep(2^(attempt - 1L))
  }
  if (is.null(resp)) stop("Nao foi possivel baixar ", page_url)

  html_txt <- rawToChar(resp$content)
  Encoding(html_txt) <- "UTF-8"

  n_chk <- length(xml2::xml_find_all(xml2::read_html(html_txt),
                                     "//table[@id='cwurTable']//tbody/tr"))
  if (n_chk < 1L) stop("HTML baixado nao tem a tabela cwurTable em ", page_url)

  writeBin(resp$content, raw_path)
  cat(n_chk, "linhas,", round(length(resp$content) / 1024), "KB\n")
}

####################################################################
### Parse
####################################################################

doc  <- xml2::read_html(html_txt)
rows <- xml2::xml_find_all(doc, "//table[@id='cwurTable']//tbody/tr")

cat("linhas na tabela:", length(rows), "\n")
stopifnot(length(rows) > 0L)

n_cells <- vapply(rows, function(r) length(xml2::xml_find_all(r, "./td")),
                  integer(1))
stopifnot(all(n_cells == exp_cols))

cells <- t(vapply(rows,
                  function(r) xml2::xml_text(xml2::xml_find_all(r, "./td")),
                  character(exp_cols)))

href <- vapply(rows, function(r) {
  a <- xml2::xml_find_first(r, "./td[2]/a")
  if (inherits(a, "xml_missing")) NA_character_ else xml2::xml_attr(a, "href")
}, character(1))

stopifnot(!anyNA(href))

bruto <- data.frame(
  world_rank_raw     = cells[, 1],
  institution        = cells[, 2],
  location           = cells[, 3],
  national_rank_raw  = cells[, 4],
  education_rank_raw = cells[, 5],
  employability_raw  = cells[, 6],
  faculty_rank_raw   = cells[, 7],
  research_rank_raw  = cells[, 8],
  score_raw          = cells[, 9],
  href               = href,
  stringsAsFactors   = FALSE
)

# A propria pagina publica o denominador do recorte. Guardado como
# procedencia: se ele mudar, o Global 2000 foi reprocessado.
paras <- trimws(xml2::xml_text(xml2::xml_find_all(doc, "//p")))
ranked_txt <- paras[grepl("institutions were ranked", paras, fixed = TRUE)]
ranked_total <- if (length(ranked_txt)) {
  as.integer(gsub(",", "", sub("^([0-9,]+).*$", "\\1", ranked_txt[[1]])))
} else NA_integer_

cat("instituicoes avaliadas segundo a pagina:", ranked_total, "\n")

# O pais vem por extenso e e convertido aqui, e nao no SQL, porque
# countrycode nao existe em DuckDB. As 95 grafias da edicao 2026 resolvem
# todas; uma grafia nova aborta em vez de virar NULL.
bruto$country_iso2 <- suppressWarnings(
  countrycode::countrycode(bruto$location, "country.name", "iso2c"))

sem_iso <- unique(bruto$location[is.na(bruto$country_iso2)])
if (length(sem_iso)) {
  stop("Grafia de pais sem ISO2: ", paste(sem_iso, collapse = ", "))
}

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# temp_directory explicito: o derrame para disco nao pode cair em pasta
# sincronizada pelo Dropbox.
nul <- dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))
cat("DuckDB:", dbGetQuery(con, "SELECT version() AS v")$v, "\n\n")

dbWriteTable(con, "bruto", bruto, overwrite = TRUE)

extracted_at <- format(as.POSIXct(Sys.time(), tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ")

nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE cwur AS
  SELECT
    %d                                                            AS edition,
    -- Armadilha 1: posicao e rotulo de percentil dividem a celula,
    -- separados por U+00A0.
    try_cast(regexp_extract(world_rank_raw, '^[0-9]+') AS INTEGER) AS world_rank,
    regexp_replace(regexp_extract(world_rank_raw, 'Top.*$'),
                   '\u00a0', ' ')                                 AS pct_label,
    institution,
    location,
    country_iso2,
    -- Armadilha 2: faltante e '-' em quatro colunas e TAMBEM string
    -- vazia em faculty_rank.
    try_cast(nullif(nullif(national_rank_raw,  '-'), '') AS INTEGER) AS national_rank,
    try_cast(nullif(nullif(education_rank_raw, '-'), '') AS INTEGER) AS education_rank,
    try_cast(nullif(nullif(employability_raw,  '-'), '') AS INTEGER) AS employability_rank,
    try_cast(nullif(nullif(faculty_rank_raw,   '-'), '') AS INTEGER) AS faculty_rank,
    try_cast(nullif(nullif(research_rank_raw,  '-'), '') AS INTEGER) AS research_rank,
    try_cast(score_raw AS DOUBLE)                                 AS score,
    -- Armadilha 3: o slug tem virgula, apostrofo e travessao.
    regexp_extract(href, '([^/]+)[.]php$', 1)                     AS cwur_slug,
    'https://cwur.org/' || href                                   AS cwur_url,
    %d                                                            AS institutions_ranked,
    '%s'                                                          AS source_url,
    '%s'                                                          AS extracted_at_utc
  FROM bruto
  ORDER BY world_rank", edition, ranked_total, page_url, extracted_at))

####################################################################
### Validacao
####################################################################

chk <- dbGetQuery(con, "
  SELECT
    count(*)                                  AS linhas,
    count(DISTINCT world_rank)                AS ranks,
    min(world_rank)                           AS rank_min,
    max(world_rank)                           AS rank_max,
    sum(world_rank IS NULL)                   AS sem_rank,
    count(DISTINCT institution)               AS instituicoes,
    count(DISTINCT cwur_slug)                 AS slugs,
    sum(cwur_slug IS NULL OR cwur_slug = '')  AS slug_vazio,
    sum(country_iso2 IS NULL)                 AS sem_pais,
    count(DISTINCT location)                  AS grafias,
    count(DISTINCT country_iso2)              AS paises,
    sum(national_rank IS NULL)                AS sem_rank_nac,
    sum(pct_label IS NULL OR pct_label = '')  AS sem_percentil,
    sum(score IS NULL)                        AS sem_nota,
    min(score)                                AS nota_min,
    max(score)                                AS nota_max
  FROM cwur")

cat("linhas       :", chk$linhas, "\n")
cat("world_rank   :", chk$rank_min, "-", chk$rank_max, "|", chk$ranks,
    "distintos\n")
cat("instituicoes :", chk$instituicoes, "| slugs:", chk$slugs, "\n")
cat("paises       :", chk$grafias, "grafias ->", chk$paises, "ISO2\n")
cat("nota         :", chk$nota_min, "-", chk$nota_max, "\n\n")

# Estrutural: aborta. A ausencia de empate e de lacuna em world_rank e o
# que garante que a posicao serve de chave da lista.
stopifnot(chk$sem_rank == 0L,
          chk$ranks == chk$linhas,
          chk$rank_min == 1L,
          chk$rank_max == chk$linhas,
          chk$instituicoes == chk$linhas,
          chk$slugs == chk$linhas,
          chk$slug_vazio == 0L,
          chk$sem_pais == 0L,
          chk$sem_rank_nac == 0L,
          chk$sem_percentil == 0L,
          chk$sem_nota == 0L,
          chk$nota_min > 0, chk$nota_max <= 100)

# Deriva: reporta. Qualquer um destes muda quando o CWUR republica a
# edicao, e nenhum deles e defeito.
if (chk$linhas != exp_rows) {
  warning("O Global 2000 veio com ", chk$linhas, " linhas, e nao ", exp_rows,
          ". O CWUR republicou a edicao ", edition, "?")
}
# As 95 grafias colapsam em 94 ISO2 porque o countrycode manda
# 'Northern Cyprus' para CY, junto com 'Cyprus' - 2 linhas cada. E
# colapso de codigo, nao perda de linha, e por isso os dois numeros sao
# afirmados separadamente.
if (chk$grafias != exp_labels || chk$paises != exp_countries) {
  warning("Paises: ", chk$grafias, " grafias e ", chk$paises,
          " ISO2, esperado ", exp_labels, " e ", exp_countries, ".")
}
if (!identical(ranked_total, exp_ranked)) {
  warning("A pagina diz ", ranked_total, " instituicoes avaliadas, esperado ",
          exp_ranked, ".")
}

faltantes <- dbGetQuery(con, "
  SELECT 'education_rank' AS coluna,
         sum(education_rank_raw = '-')::INTEGER AS traco,
         sum(education_rank_raw = '')::INTEGER  AS vazio FROM bruto
  UNION ALL SELECT 'employability_rank',
         sum(employability_raw = '-')::INTEGER,
         sum(employability_raw = '')::INTEGER FROM bruto
  UNION ALL SELECT 'faculty_rank',
         sum(faculty_rank_raw = '-')::INTEGER,
         sum(faculty_rank_raw = '')::INTEGER FROM bruto
  UNION ALL SELECT 'research_rank',
         sum(research_rank_raw = '-')::INTEGER,
         sum(research_rank_raw = '')::INTEGER FROM bruto
  ORDER BY coluna")

cat("Sub-posicoes faltantes por coluna:\n")
print(faltantes, right = FALSE)

medido <- setNames(faltantes$traco, faltantes$coluna)
if (!identical(as.integer(medido[names(exp_dash)]), as.integer(exp_dash))) {
  warning("Contagem de '-' mudou: ",
          paste(sprintf("%s=%d", names(medido), medido), collapse = ", "))
}
vazio_fac <- faltantes$vazio[faltantes$coluna == "faculty_rank"]
if (!identical(as.integer(vazio_fac), exp_empty_fac)) {
  warning("faculty_rank com string vazia: ", vazio_fac, ", esperado ",
          exp_empty_fac, ". Ver armadilha 2.")
}

####################################################################
### Escrita
####################################################################

nul <- dbExecute(con, sprintf(
  "COPY cwur TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  gsub("\\\\", "/", out_path)))

# Releitura com arrow: confirma que o parquet e legivel fora do DuckDB e
# que os acentos sobreviveram. Sao 151 nomes acentuados na edicao 2026, e
# zero seria sinal de encoding perdido, nao de fonte mudada.
df <- arrow::read_parquet(out_path)
nao_ascii <- sum(grepl("[^\x01-\x7f]", df$institution))

cat("\nreleitura arrow:", nrow(df), "linhas,", ncol(df), "colunas\n")
cat("nomes com acento:", nao_ascii, "\n")
stopifnot(nrow(df) == chk$linhas, nao_ascii > 0L,
          all(c("world_rank", "institution", "country_iso2", "cwur_slug",
                "score") %in% names(df)))
if (nao_ascii != exp_accents) {
  warning("Nomes acentuados: ", nao_ascii, ", esperado ", exp_accents, ".")
}

cat("\nTop 10 mundial:\n")
print(df[df$world_rank <= 10L,
         c("world_rank", "institution", "country_iso2", "score")],
      right = FALSE)

cat("\nBrasil na lista:", sum(df$country_iso2 == "BR"), "instituicoes\n")
br <- df[df$country_iso2 == "BR" & df$national_rank <= 5L,
         c("world_rank", "national_rank", "institution", "score")]
print(br[order(br$national_rank), ], right = FALSE)

cat("\nGravado:", out_path, "\n")
cat("tamanho:", round(file.size(out_path) / 1024, 1), "KB\n")
