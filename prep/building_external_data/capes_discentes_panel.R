####################################################################
### Discentes da Pos-Graduacao Stricto Sensu (CAPES) 2004-2024
### Painel unificado a partir dos 21 .xlsx
###
### Le os 21 arquivos .xlsx baixados pelo script anterior, grava UM
### PARQUET POR ANO como cache e depois une tudo em um parquet unico
### com uma linha por matricula-ano: 7.061.944 linhas e 54 colunas
### publicadas, mais source_period, source_file e built_at_utc.
###
### Nao usa rede. Roda depois de download_capes_discentes.R e nao
### precisa de conexao para nada. Continua sendo um script local: le e
### escreve no Dropbox do OBMEP, e nao pode ser copiado para
### scripts_sedap/ (ver AGENTS.md -> Execution Environments).
###
### TRES REGIMES DE SCHEMA, medidos nos DOIS extremos de cada periodo
### (2004 e 2012, 2013 e 2016, 2017 e 2024):
###
###   2004-2012   31 colunas   nomenclatura "entidade"
###   2013-2016   37 colunas   nomenclatura "programa"
###   2017-2024   37 colunas   nomenclatura "programa"
###
### ATENCAO / LIMITACOES:
###
###  1. A COLUNA 35 TROCA DE NOME SO EM 2013-2016. Ela e NM_ORIENTADOR
###     ali, e NM_ORIENTADOR_PRINCIPAL em 2004-2012 E em 2017-2024. E o
###     mesmo campo, na mesma posicao, com um nome de uma release so.
###     Deixadas separadas, a coluna obvia ficaria vazia por quatro anos
###     enquanto uma quase-duplicata que ninguem olha guardava o dado.
###     Por isso ha UMA fusao de alias neste script, e apenas uma, na
###     constante alias_fold abaixo. O relatorio de cobertura por
###     periodo existe para que qualquer OUTRA divisao dessas apareca em
###     vez de ser presumida inexistente.
###
###  2. A UNIAO E POR NOME PUBLICADO, SEM HARMONIZAR O RESTO. Entre
###     2004-2012 e 2013+ a CAPES nao so renomeou como REANCOROU
###     campos: SG_UF_ENTIDADE_ENSINO (UF da instituicao) virou
###     SG_UF_PROGRAMA (UF do programa), que nao e a mesma coisa; e
###     AN_MATRICULA_DISCENTE + ME_MATRICULA_DISCENTE (ano e mes)
###     viraram a data unica DT_MATRICULA_DISCENTE. Colapsar esses pares
###     seria inventar dado. Eles ficam como a fonte publicou, lado a
###     lado, e a concordancia esta na tabela do fim deste cabecalho.
###
###  3. PROJECAO EXPLICITA, NUNCA UNION BY NAME CRU. Uma coluna 100%
###     nula em um ano seria inferida com tipo diferente da mesma coluna
###     em outro e a uniao dos 21 arquivos falharia -- e a mesma
###     armadilha ja documentada em ruf_course_rankings.R. Tudo e lido
###     como texto e a projecao lista as 54 colunas na mao.
###
###  3a. O LEITOR E readxl, E NAO O read_xlsx DO DUCKDB, POR CORRECAO.
###     Os arquivos de 2004 a 2016 guardam caracteres como escapes
###     OOXML na sharedStrings: "UNIVERSIDADE_x0020_FEDERAL" em vez de
###     "UNIVERSIDADE FEDERAL". O read_xlsx do DuckDB 1.4.4 devolve
###     esses escapes literais; o readxl os resolve, como manda o
###     formato. Medido: com o DuckDB, 3.794.415 linhas -- os 13
###     arquivos de 2004-2016 inteiros, 54% do painel -- saem com o
###     texto corrompido, em TODAS as colunas de texto. E nao e so
###     espaco: aparecem 34 escapes distintos, inclusive DIGITOS
###     (_x0033_ e "3", _x0032_ e "2"), "/", "*", "," e aspas, o que
###     corromperia codigo de programa e titulo de tese em silencio.
###     Os arquivos de 2017 em diante nao usam escape nenhum e por isso
###     passariam pelos dois leitores -- o que torna o erro ainda mais
###     facil de nao ver. O readxl custa cerca de 13s e 0,2 GB por
###     arquivo, o que e barato demais para valer o risco. A validacao
###     final aborta se sobrar qualquer _xHHHH_ na saida.
###
###  4. AS COLUNAS DT_* SAO SERIAL DO EXCEL, E NAO TEXTO DE DATA. Como
###     tudo e lido como texto, elas saem como o numero: 37996, nao
###     "2004-01-10". A conversao e
###       as.Date(as.integer(DT_TESE_DISSERTACAO), origin = "1899-12-30")
###     Confira contra o .csv gemeo antes de duvidar do numero: la a
###     mesma celula aparece como literal de data do SAS,
###     "10JAN04:00:00:00", que e o mesmo 2004-01-10. As duas formas da
###     CAPES divergem na representacao, nao no valor, e e por isso que
###     nada aqui tenta adivinhar data: um parse implicito devolveria NA
###     calado em uma das duas. Faixas medidas: tese 37622-41244
###     (2003-2012), matricula 34421-45657 (1994-2024).
###     DT_TESE_DISSERTACAO so existe em 2004-2012 e DT_MATRICULA_ e
###     DT_SITUACAO_DISCENTE so de 2013 em diante.
###
###  5. O LIMITE DE LINHAS DA PLANILHA XLSX E 1.048.576. O ano de 2024
###     tem cerca de 800 mil linhas, com folga, mas um ano encostado no
###     limite significa planilha truncada pela CAPES e obriga a usar o
###     .csv gemeo daquele ano. Ha checagem por ano para isso.
###
###  6. AS LINHAS POR ANO SAO 7.061.944 NO TOTAL, medidas em
###     2026-08-31 e fixadas em exp_rows_by_year. Nenhum ano chega perto
###     do limite do xlsx: o maior e 2024, com 432.888. As contagens
###     foram conferidas contra o indice da ultima linha do sheet1.xml
###     cru em 2004, 2013 e 2024 (190.039, 300.211 e 432.889 menos o
###     cabecalho), o que descarta truncamento do leitor.
###
### Concordancia 2004-2012 -> 2017-2024 (14 nomes sao iguais nos dois):
###
###   NM_REGIAO_ENTIDADE            -> NM_REGIAO
###   SG_UF_ENTIDADE_ENSINO         -> SG_UF_PROGRAMA      (reancorado)
###   NM_NIVEL_PROGRAMA             -> NM_GRAU_PROGRAMA
###   NM_PAIS_ORIGEM_DISCENTE       -> NM_PAIS_NACIONALIDADE_DISCENTE
###   DS_FAIXA_ETARIA_DISCENTE      -> DS_FAIXA_ETARIA
###   NM_NIVEL_TITULACAO_DISCENTE   -> DS_GRAU_ACADEMICO_DISCENTE (aprox)
###   AN_ + ME_MATRICULA_DISCENTE   -> DT_MATRICULA_DISCENTE
###   AN_ + ME_SITUACAO_DISCENTE    -> DT_SITUACAO_DISCENTE
###   NR_SEQUENCIAL_DISCENTE        -> ID_PESSOA           (outro escopo)
###
### Padrao de projecao harmonizada reaproveitado de:
###   prep/building_external_data/linkedin_company_rcid.R
### Preambulo DuckDB reaproveitado de:
###   prep/building_external_data/shanghai_ranking_openalex_names.R
###
### Depends on:
###   prep/building_external_data/download_capes_discentes.R
###
### Consumed by:
###   (nada ainda)
####################################################################

for (p in c("DBI", "duckdb", "arrow", "readxl", "readr")) {
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
mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")

raw_dir  <- file.path(obmep_root, "Data/raw/capes_discentes")
out_dir  <- file.path(obmep_root, "Data/intermediate/capes_discentes")
year_dir <- file.path(out_dir, "by_year")

out_path      <- file.path(out_dir, "capes_discentes_2004_2024.parquet")
manifest_path <- file.path(out_dir, "capes_discentes_manifest.csv")
coverage_path <- file.path(out_dir, "capes_discentes_column_coverage.csv")

dl_manifest_path <- file.path(raw_dir, "capes_discentes_download_manifest.csv")

# Anos a processar. Argumento opcional na linha de comando restringe o
# conjunto, o que e como se testa um ano so sem editar o script.
#   Rscript capes_discentes_panel.R 2004
#   Rscript capes_discentes_panel.R 2004:2012
args <- commandArgs(trailingOnly = TRUE)
all_years <- 2004:2024
years <- if (length(args) > 0L) {
  as.integer(eval(parse(text = args[[1]])))
} else {
  all_years
}
stopifnot(!anyNA(years), all(years %in% all_years))
partial_run <- !identical(sort(years), all_years)

# Os tres regimes de schema, medidos. Ver cabecalho.
regime_of <- function(y) {
  ifelse(y <= 2012L, "2004a2012",
         ifelse(y <= 2016L, "2013a2016",
                ifelse(y <= 2020L, "2017a2020", "2021a2024")))
}
exp_ncol <- c("2004a2012" = 31L, "2013a2016" = 37L,
              "2017a2020" = 37L, "2021a2024" = 37L)

# Linhas por ano, medidas na rodada de 2026-08-31 contra os arquivos
# baixados naquele dia. Divergencia aqui avisa e nao aborta: quer dizer
# que a CAPES republicou algum ano, o que e informacao, nao erro.
exp_rows_by_year <- setNames(c(
  190038L, 212073L, 229290L,
  252102L, 270170L, 290592L,
  316398L, 345048L, 375260L,
  300210L, 317846L, 338035L,
  357353L, 374429L, 390174L,
  401311L, 395870L, 419905L,
  424354L, 428598L, 432888L
), as.character(all_years))

# Ver ATENCAO 5.
xlsx_row_limit <- 1048576L

# Ver ATENCAO 1. Fusao unica e reversivel: apague esta linha e as duas
# colunas voltam a existir separadas na saida.
alias_fold <- c(NM_ORIENTADOR_PRINCIPAL = "NM_ORIENTADOR")

for (d in c(out_dir, year_dir)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_capes")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(dir.exists(raw_dir), file.exists(dl_manifest_path))

dl <- readr::read_csv(dl_manifest_path, show_col_types = FALSE,
                      progress = FALSE)
dl <- as.data.frame(dl, stringsAsFactors = FALSE)
dl$year <- as.integer(dl$year)
dl <- dl[dl$year %in% years, , drop = FALSE]
dl <- dl[order(dl$year), , drop = FALSE]
dl$path <- file.path(raw_dir, dl$filename)

stopifnot(nrow(dl) == length(years), identical(sort(dl$year), sort(years)))
faltando <- dl$filename[!file.exists(dl$path)]
if (length(faltando)) {
  stop("Arquivo ausente em ", raw_dir, ": ",
       paste(faltando, collapse = ", "),
       ". Rode download_capes_discentes.R primeiro.")
}

cat("CAPES discentes -- painel unificado\n")
cat("origem:", raw_dir, "\n")
cat("saida :", out_path, "\n")
cat("anos  :", length(years), "de", min(years), "a", max(years), "\n")
if (partial_run) cat("[aviso] rodada parcial: a uniao final sera parcial\n")
cat("\n")

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
nul <- dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# temp_directory explicito: o derrame para disco nao pode cair em
# pasta sincronizada pelo Dropbox.
nul <- dbExecute(con, sprintf("SET temp_directory='%s'", gsub("\\\\", "/", tmp_dir)))
nul <- dbExecute(con, "SET preserve_insertion_order=false")
cat("DuckDB:", dbGetQuery(con, "SELECT version() AS v")$v, "\n")

fw <- function(p) gsub("\\\\", "/", p)

####################################################################
### Projecao canonica
####################################################################

# As 54 colunas publicadas, na ordem em que aparecem: primeiro os nomes
# do regime mais recente, depois o que so existe em 2004-2012. Ordem
# fixa e deliberada -- a saida nao pode mudar de forma so porque a
# rodada foi parcial.
canon_2013 <- c(
  "AN_BASE", "NM_GRANDE_AREA_CONHECIMENTO", "CD_AREA_AVALIACAO",
  "NM_AREA_AVALIACAO", "CD_ENTIDADE_CAPES", "CD_ENTIDADE_EMEC",
  "SG_ENTIDADE_ENSINO", "NM_ENTIDADE_ENSINO", "CS_STATUS_JURIDICO",
  "DS_DEPENDENCIA_ADMINISTRATIVA", "NM_MODALIDADE_PROGRAMA",
  "NM_GRAU_PROGRAMA", "CD_PROGRAMA_IES", "NM_PROGRAMA_IES", "NM_REGIAO",
  "SG_UF_PROGRAMA", "NM_MUNICIPIO_PROGRAMA_IES", "CD_CONCEITO_PROGRAMA",
  "CD_CONCEITO_CURSO", "ID_PESSOA", "TP_DOCUMENTO_DISCENTE",
  "NR_DOCUMENTO_DISCENTE", "NM_DISCENTE", "NM_PAIS_NACIONALIDADE_DISCENTE",
  "DS_TIPO_NACIONALIDADE_DISCENTE", "AN_NASCIMENTO_DISCENTE",
  "DS_FAIXA_ETARIA", "DS_GRAU_ACADEMICO_DISCENTE", "ST_INGRESSANTE",
  "NM_SITUACAO_DISCENTE", "DT_MATRICULA_DISCENTE", "DT_SITUACAO_DISCENTE",
  "QT_MES_TITULACAO", "NM_TESE_DISSERTACAO", "NM_ORIENTADOR_PRINCIPAL",
  "ID_ADD_FOTO_PROGRAMA", "ID_ADD_FOTO_PROGRAMA_IES"
)
only_2004 <- c(
  "NM_REGIAO_ENTIDADE", "SG_UF_ENTIDADE_ENSINO", "NM_NIVEL_PROGRAMA",
  "NR_SEQUENCIAL_DISCENTE", "NM_PAIS_ORIGEM_DISCENTE", "NR_IDADE_DISCENTE",
  "DS_FAIXA_ETARIA_DISCENTE", "AN_MATRICULA_DISCENTE",
  "ME_MATRICULA_DISCENTE", "AN_SITUACAO_DISCENTE", "ME_SITUACAO_DISCENTE",
  "NM_NIVEL_TITULACAO_DISCENTE", "NM_NIVEL_CONCLUSAO_DISCENTE",
  "NR_SEQUENCIAL_TESE", "DT_TESE_DISSERTACAO",
  "NR_SEQ_ORIENTADOR_PRINCIPAL", "NM_TIPO_DOCENTE_ORIENT_PRINC"
)
canon <- c(canon_2013, only_2004)
stopifnot(length(canon) == 54L, anyDuplicated(canon) == 0L)

####################################################################
### Parse por ano, com cache em parquet
####################################################################

# Um readxl por arquivo, tudo como texto, direto para parquet. Ver
# ATENCAO 3a: o read_xlsx do DuckDB seria mais rapido e devolveria o
# texto de 2004-2016 corrompido, entao nao e usado aqui.
#
# O cabecalho de cada ano e conferido dentro deste laco, e nao em uma
# passagem previa: ler so o cabecalho com readxl custa quase o mesmo
# que ler o arquivo inteiro, entao a passagem previa dobrava o tempo
# total sem antecipar nada de util. Em ano vindo do cache os nomes sao
# lidos do proprio parquet, que e barato.
cat("\nParse por ano:\n")
built <- data.frame(
  year = dl$year, period = dl$period, source_file = dl$filename,
  source_bytes = dl$bytes, rows = NA_integer_, cols = NA_integer_,
  parser = NA_character_, parquet_path = NA_character_,
  secs = NA_real_, stringsAsFactors = FALSE
)
headers <- vector("list", nrow(dl))
names(headers) <- as.character(dl$year)

for (i in seq_len(nrow(dl))) {
  y <- dl$year[[i]]
  dest <- file.path(year_dir, sprintf("capes_discentes_%d.parquet", y))
  built$parquet_path[[i]] <- dest

  if (file.exists(dest) && file.size(dest) > 0L) {
    chk <- dbGetQuery(con, sprintf(
      "SELECT count(*) AS n FROM read_parquet('%s')", fw(dest)))
    headers[[as.character(y)]] <- names(dbGetQuery(con, sprintf(
      "SELECT * FROM read_parquet('%s') LIMIT 0", fw(dest))))
    built$rows[[i]]   <- as.integer(chk$n)
    built$cols[[i]]   <- length(headers[[as.character(y)]])
    built$parser[[i]] <- "cache"
    cat("  [skip] ", y, " ", chk$n, " linhas\n", sep = "")
    next
  }

  # excel_sheets le so o workbook.xml e e realmente barato.
  sheets <- readxl::excel_sheets(dl$path[[i]])
  if (length(sheets) != 1L) {
    stop("Esperava uma planilha em ", dl$filename[[i]], ", achei ",
         length(sheets), ": ", paste(sheets, collapse = ", "))
  }

  parcial <- paste0(dest, ".part")
  if (file.exists(parcial)) unlink(parcial)
  cat("  ", y, " ... ", sep = "")
  t0 <- Sys.time()

  df <- readxl::read_xlsx(dl$path[[i]], sheet = 1L, col_types = "text",
                          .name_repair = "minimal")
  h <- names(df)
  reg <- regime_of(y)

  # Violacao estrutural aborta: a projecao explicita nao pode ser
  # confiada se o regime de colunas mudou.
  if (length(h) != exp_ncol[[reg]]) {
    stop("O ano ", y, " tem ", length(h), " colunas, o regime ", reg,
         " foi medido com ", exp_ncol[[reg]], ".")
  }
  if (nrow(df) == 0L) stop("Parse de ", y, " devolveu zero linhas.")
  # Ver ATENCAO 5.
  if (nrow(df) >= xlsx_row_limit - 1L) {
    stop("O ano ", y, " tem ", nrow(df), " linhas, encostado no limite de ",
         xlsx_row_limit, " do xlsx: a planilha esta truncada na fonte e ",
         "esse ano precisa vir do .csv gemeo.")
  }
  # AN_BASE e o ano da coleta e tem de ser constante e igual ao arquivo.
  ab <- unique(df[["AN_BASE"]])
  if (length(ab) != 1L || as.integer(ab) != y) {
    stop("AN_BASE em ", y, " nao e o ano constante esperado: ",
         paste(utils::head(ab, 5), collapse = ", "))
  }
  # Ver ATENCAO 3a: e aqui que um leitor que nao resolve escape apareceria.
  esc <- sum(vapply(df, function(x)
    sum(grepl("_x[0-9A-Fa-f]{4}_", x), na.rm = TRUE), integer(1)))
  if (esc > 0L) {
    stop("O ano ", y, " saiu com ", esc, " celulas contendo escape ",
         "_xHHHH_ nao resolvido. O leitor de xlsx nao serve.")
  }

  arrow::write_parquet(df, parcial, compression = "zstd")
  n <- nrow(df)
  rm(df)
  gc(verbose = FALSE)

  secs <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  file.rename(parcial, dest)
  headers[[as.character(y)]] <- h
  built$rows[[i]]   <- n
  built$cols[[i]]   <- length(h)
  built$parser[[i]] <- "readxl"
  built$secs[[i]]   <- secs
  cat("[OK] ", n, " linhas, ", length(h), " colunas, ", round(secs), "s\n", sep = "")
}

stopifnot(!anyNA(built$rows), all(built$rows > 0L),
          !vapply(headers, is.null, logical(1)))

# Dentro de cada periodo os extremos foram verificados iguais contra a
# fonte; aqui se checa tambem o meio, que era a unica parte presumida.
for (reg in unique(regime_of(dl$year))) {
  hs <- headers[regime_of(as.integer(names(headers))) == reg]
  if (length(hs) > 1L && !all(vapply(hs[-1], identical, logical(1), hs[[1]]))) {
    stop("Cabecalhos divergem dentro do periodo ", reg,
         "; a projecao explicita assume que sao iguais.")
  }
}

# Nome novo na fonte avisa em vez de abortar: um campo a mais nao
# invalida nada do que ja esta aqui, mas nao pode passar em silencio.
observed <- sort(unique(unlist(headers, use.names = FALSE)))
novos <- setdiff(observed, c(canon, unname(alias_fold)))
if (length(novos)) {
  warning("Coluna nao prevista na fonte: ", paste(novos, collapse = ", "),
          ". Ela NAO entra na saida ate ser adicionada a canon.")
}
cat("\nuniao de nomes publicados:", length(observed), "\n")
cat("projecao canonica         :", length(canon), "\n")

# Deriva de contagem avisa; ver ATENCAO 6.
for (i in seq_len(nrow(built))) {
  e <- exp_rows_by_year[[as.character(built$year[[i]])]]
  if (!is.na(e) && e != built$rows[[i]]) {
    warning("Linhas de ", built$year[[i]], ": ", built$rows[[i]],
            " diverge do medido (", e, "). A CAPES republicou o ano?")
  }
}

####################################################################
### Uniao com projecao explicita
####################################################################

# Projecao na mao, coluna por coluna, com CAST(NULL AS VARCHAR) onde o
# periodo nao tem o campo. Ver ATENCAO 3: union_by_name cru sobre os
# arquivos brutos quebraria na primeira coluna 100% nula.
year_paths <- built$parquet_path[order(built$year)]
year_order <- built$year[order(built$year)]

sel_for <- function(y) {
  have <- headers[[as.character(y)]]
  parts <- vapply(canon, function(col) {
    if (col %in% have) {
      sprintf("\"%s\"", col)
    } else if (!is.na(alias_fold[col]) && alias_fold[[col]] %in% have) {
      # Ver ATENCAO 1: NM_ORIENTADOR de 2013-2016 entra na coluna
      # NM_ORIENTADOR_PRINCIPAL, que e o mesmo campo.
      sprintf("\"%s\" AS \"%s\"", alias_fold[[col]], col)
    } else {
      sprintf("CAST(NULL AS VARCHAR) AS \"%s\"", col)
    }
  }, character(1))
  parts
}

built_at <- format(Sys.time(), tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")

pieces <- character(length(year_order))
for (k in seq_along(year_order)) {
  y <- year_order[[k]]
  pieces[[k]] <- sprintf(
    "SELECT %s,
            '%s' AS source_period,
            '%s' AS source_file,
            '%s' AS built_at_utc
       FROM read_parquet('%s')",
    paste(sel_for(y), collapse = ",\n           "),
    built$period[built$year == y][[1]],
    built$source_file[built$year == y][[1]],
    built_at, fw(year_paths[[k]]))
}

cat("\nUnindo", length(pieces), "anos ...\n")
nul <- dbExecute(con, paste0("CREATE OR REPLACE VIEW unificado AS\n",
                      paste(pieces, collapse = "\nUNION ALL\n")))

chk <- dbGetQuery(con, "
  SELECT count(*) AS linhas,
         count(DISTINCT AN_BASE) AS anos,
         min(AN_BASE) AS a_min,
         max(AN_BASE) AS a_max,
         sum(CASE WHEN NM_DISCENTE IS NULL THEN 1 ELSE 0 END) AS sem_nome
    FROM unificado")

cat("linhas :", chk$linhas, "\n")
cat("anos   :", chk$anos, "(", chk$a_min, "-", chk$a_max, ")\n")

stopifnot(chk$linhas == sum(built$rows),
          chk$anos == length(year_order))

####################################################################
### Escrita
####################################################################

if (partial_run) {
  cat("\n[aviso] rodada parcial: NAO sobrescrevendo", basename(out_path), "\n")
  cat("        os parquets por ano em", year_dir, "estao gravados\n")
} else {
  nul <- dbExecute(con, sprintf(
    "COPY unificado TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    fw(out_path)))
}

####################################################################
### Cobertura por coluna e periodo
####################################################################

# O relatorio que torna a uniao honesta: uma coluna 100% nula em um
# periodo onde deveria existir e exatamente a falha que um UNION BY
# NAME calado esconde. Ver ATENCAO 1.
cov_sql <- paste(
  sprintf("SELECT source_period AS periodo, '%s' AS coluna,
                  count(*) AS linhas,
                  sum(CASE WHEN \"%s\" IS NULL THEN 1 ELSE 0 END) AS nulos
             FROM unificado GROUP BY 1", canon, canon),
  collapse = "\nUNION ALL\n")
cobertura <- dbGetQuery(con, cov_sql)
cobertura$pct_nulo <- round(100 * cobertura$nulos / cobertura$linhas, 2)
cobertura <- cobertura[order(cobertura$coluna, cobertura$periodo), ,
                       drop = FALSE]
readr::write_csv(cobertura, coverage_path, na = "")

# As 14 colunas presentes nos tres regimes nao podem estar vazias em
# periodo nenhum -- se estiverem, a projecao errou o nome.
sempre <- Reduce(intersect, headers)
sempre <- intersect(sempre, canon)
vazias <- cobertura[cobertura$coluna %in% sempre & cobertura$pct_nulo == 100, ]
if (nrow(vazias)) {
  stop("Coluna sempre presente veio 100% nula: ",
       paste(unique(paste0(vazias$coluna, "/", vazias$periodo)),
             collapse = ", "))
}
cat("\ncolunas presentes em todos os regimes:", length(sempre),
    "-- nenhuma 100% nula\n")

# A checagem que prova que a fusao de alias funcionou.
if ("2013a2016" %in% cobertura$periodo) {
  o <- cobertura[cobertura$coluna == "NM_ORIENTADOR_PRINCIPAL" &
                   cobertura$periodo == "2013a2016", ]
  cat("NM_ORIENTADOR_PRINCIPAL em 2013a2016:", o$pct_nulo, "% nulo\n")
  stopifnot(nrow(o) == 1L, o$pct_nulo < 50)
}

####################################################################
### Manifesto
####################################################################

built$built_at_utc <- built_at
readr::write_csv(built[, c("year", "period", "source_file", "source_bytes",
                           "rows", "cols", "parser", "parquet_path",
                           "secs", "built_at_utc")],
                 manifest_path, na = "")

cat("\nlinhas por ano:\n")
for (i in order(built$year)) {
  cat("  ", built$year[[i]], " ", built$rows[[i]],
      "\n", sep = "")
}

####################################################################
### Validacao final
####################################################################

if (!partial_run) {
  # Releitura com arrow: confirma que o parquet e legivel fora do
  # DuckDB e que os acentos sobreviveram (o xlsx e UTF-8 e nada aqui
  # dobra acento de proposito).
  # open_dataset e nao read_parquet: 13-15 milhoes de linhas nao precisam
  # entrar no heap do R so para conferir contagem e nomes.
  ds <- arrow::open_dataset(out_path)
  n_arrow <- nrow(ds)
  cols_arrow <- names(ds)

  cat("\nreleitura arrow:", n_arrow, "linhas,",
      length(cols_arrow), "colunas\n")

  # Classe explicita [ -~] em vez de faixa hexadecimal: o RE2 do DuckDB
  # nao interpreta \\xHH dentro de colchete, e uma contagem zero aqui
  # seria lida como "os acentos morreram" quando o que morreu foi o regex.
  nao_ascii <- dbGetQuery(con, sprintf("
    SELECT count(*) AS n
      FROM read_parquet('%s')
     WHERE NOT regexp_matches(NM_ENTIDADE_ENSINO, '^[ -~]*$')",
    fw(out_path)))$n

  # Ver ATENCAO 3a. Este e o teste que pega um leitor de xlsx que nao
  # resolve os escapes OOXML, e ele olha TODAS as colunas publicadas,
  # nao so as obvias.
  esc_sql <- paste(sprintf(
    "SELECT sum(CASE WHEN regexp_matches(%s, '_x[0-9A-Fa-f]{4}_')
                     THEN 1 ELSE 0 END) AS n
       FROM read_parquet('%s')",
    sprintf('"%s"', canon), fw(out_path)), collapse = "
    UNION ALL
    ")
  escapes <- dbGetQuery(con, sprintf(
    "SELECT coalesce(sum(n), 0) AS n FROM (%s)", esc_sql))$n

  anos <- dbGetQuery(con, sprintf("
    SELECT DISTINCT CAST(AN_BASE AS INTEGER) AS ano
      FROM read_parquet('%s') ORDER BY 1", fw(out_path)))$ano

  cat("nao-ascii em NM_ENTIDADE_ENSINO:", nao_ascii, "linhas\n")
  cat("celulas com escape _xHHHH_      :", escapes, "(tem de ser 0)\n")

  stopifnot(n_arrow == chk$linhas,
            length(cols_arrow) == length(canon) + 3L,
            all(c("AN_BASE", "NM_DISCENTE", "NM_ENTIDADE_ENSINO",
                  "NM_ORIENTADOR_PRINCIPAL", "source_period") %in% cols_arrow),
            nao_ascii > 0L,
            escapes == 0L,
            identical(anos, all_years))

  cat("\nGravado:", out_path, "\n")
  cat("tamanho:", round(file.size(out_path) / 1024^2, 1), "MB\n")
}
cat("manifesto:", manifest_path, "\n")
cat("cobertura:", coverage_path, "\n")
