####################################################################
### Instituicoes brasileiras do snapshot OpenAlex
###
### Le o snapshot local de institutions do OpenAlex (JSON Lines
### gzipado, particionado por updated_date) no Dropbox da GTAllocation,
### filtra as instituicoes do Brasil e grava um parquet unico no
### Dropbox do OBMEP.
###
### Pontos de atencao do snapshot, todos verificados nos dados:
###
###  - country_code de topo e nulo em 7.043 dos 120.658 registros, e
###    nesses casos geo.country_code TAMBEM e nulo. O unico campo de
###    pais que sobra e geo.country, o nome por extenso. Sao 127
###    instituicoes brasileiras nessa situacao, entre elas
###    universidades federais reais (Agreste de Pernambuco,
###    Rondonopolis, Delta do Parnaiba, Norte do Tocantins). Por isso o
###    filtro cai para geo.country = 'Brazil' quando country_code e
###    nulo. Onde os dois campos existem eles nunca divergem: os 1.820
###    registros com country_code = 'BR' tem geo.country = 'Brazil', e
###    vice-versa.
###  - As particoes updated_date=* sao disjuntas nesta copia
###    (120.658 linhas, 120.658 ids distintos), mas o snapshot do
###    OpenAlex e publicado como dump inicial mais deltas diarios e
###    nada garante que continuem disjuntas. A deduplicacao por id
###    abaixo e uma salvaguarda; hoje ela nao remove nenhuma linha.
###  - O campo updated_date dentro do registro vem em formato
###    americano ("02/25/2026 06:01:00"), nao ISO. Por isso a
###    recencia e tomada do nome da pasta da particao, que e ISO e
###    ordena lexicograficamente.
###  - Cada registro tem ~21 KB por causa de topics, topic_share e
###    counts_by_year. A projecao explicita em columns= faz o leitor
###    JSON ignorar esses campos, que e o que mantem o job barato.
###  - Esta copia do snapshot nao traz a arvore merged_ids/, e nenhum
###    registro possui merge_into_id ou is_deleted. IDs redirecionados
###    por merge nao sao resolvidos aqui.
####################################################################

for (p in c("DBI", "duckdb", "arrow")) {
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
gt_root    <- Sys.getenv("GT_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/GTAllocation")

oa_dir  <- file.path(gt_root, "Data/external/oa_snapshot/data/institutions")
oa_glob <- file.path(oa_dir, "updated_date=*/part_*.gz")

out_dir  <- file.path(obmep_root, "Data/intermediate/openalex_institutions")
out_path <- file.path(out_dir, "openalex_institutions_br.parquet")

mem_limit <- "8GB"

# Valores medidos contra o snapshot de fevereiro/2026. Servem como
# teste de regressao: divergencia significa que o snapshot mudou ou
# que o filtro de pais quebrou.
exp_rows      <- 1947L
exp_by_code   <- 1820L
exp_by_geo    <- 127L

# Limpeza de display_name: 501 dos 1.947 nomes tem parenteses, todos
# balanceados, um grupo por nome e nenhum aninhado. 939 nomes tem
# caractere fora do ASCII antes e depois da limpeza; essa igualdade e
# o que garante que os acentos continuam intactos.
exp_cleaned_changed <- 501L
exp_nonascii        <- 939L

# Instituicoes de referencia, em trechos sem acento para nao depender
# da codificacao do arquivo ao comparar.
exp_names <- c("Universidade de S",                    # USP
               "Pura e Aplicada",                      # IMPA
               "Universidade Estadual de Campinas",
               "Universidade Federal do Rio de Janeiro")

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_openalex")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(dir.exists(oa_dir), length(Sys.glob(oa_glob)) > 0L)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# temp_directory explicito: o derrame para disco nao pode cair em
# pasta sincronizada pelo Dropbox.
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

cat("DuckDB:", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("particoes encontradas:", length(Sys.glob(oa_glob)), "\n")
cat("entrada:", oa_glob, "\n")
cat("saida  :", out_path, "\n\n")

####################################################################
### Leitura projetada do snapshot
####################################################################

# Apenas as chaves usadas sao declaradas. geo entra como struct
# parcial: cidade e regiao vao para a saida e country e o campo de
# pais de reserva quando country_code de topo e nulo.
sql_read <- sprintf("
  read_ndjson(
    '%s',
    filename = true,
    columns = {
      id: 'VARCHAR',
      ror: 'VARCHAR',
      display_name: 'VARCHAR',
      country_code: 'VARCHAR',
      type: 'VARCHAR',
      works_count: 'BIGINT',
      geo: 'STRUCT(city VARCHAR, region VARCHAR, country VARCHAR, country_code VARCHAR)'
    }
  )", oa_glob)

dbExecute(con, sprintf("
  CREATE OR REPLACE VIEW oa_raw AS
  SELECT
    *,
    regexp_extract(filename, 'updated_date=([0-9]{4}-[0-9]{2}-[0-9]{2})', 1)
      AS snapshot_date
  FROM %s", sql_read))

# Predicado de nacionalidade, reutilizado no filtro e na validacao.
where_br <- "country_code = 'BR'
             OR (country_code IS NULL AND geo.country = 'Brazil')"

####################################################################
### Filtro Brasil e deduplicacao
####################################################################

dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE oa_br AS
  SELECT
    regexp_extract(id, 'I[0-9]+') AS openalex_id,
    id                            AS openalex_url,
    display_name,
    -- Limpeza minima: remove apenas expressoes entre parenteses
    -- ('Estacio (Brazil)' -> 'Estacio'). O \\s* inicial engole o espaco
    -- que antecede o grupo; o colapso de \\s+ cobre o unico caso em que
    -- o grupo esta no meio do nome; trim fecha as pontas. Acentos,
    -- caixa e pontuacao ficam como estao: display_name original
    -- permanece na coluna ao lado para desambiguar.
    trim(regexp_replace(
      regexp_replace(display_name, '\\s*\\([^()]*\\)', '', 'g'),
      '\\s+', ' ', 'g'))          AS cleaned_display_name,
    ror,
    type,
    works_count,
    geo.city                      AS city,
    geo.region                    AS region,
    CASE WHEN country_code = 'BR' THEN 'country_code' ELSE 'geo_country' END
                                  AS country_source,
    snapshot_date
  FROM oa_raw
  WHERE %s
  QUALIFY row_number() OVER (PARTITION BY id ORDER BY snapshot_date DESC) = 1
  ORDER BY works_count DESC", where_br))

dbExecute(con, sprintf(
  "COPY oa_br TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", out_path))

####################################################################
### Validacao
####################################################################

# Contagens de controle tiradas da propria fonte, nao da saida.
chk <- dbGetQuery(con, sprintf("
  SELECT
    count(*)                     AS linhas_br_brutas,
    count(DISTINCT id)           AS ids_br_distintos,
    sum(country_code = 'BR')     AS por_country_code,
    sum(country_code IS NULL)    AS por_geo_country
  FROM oa_raw
  WHERE %s", where_br))

out <- dbGetQuery(con, "
  SELECT
    count(*)                                     AS linhas,
    count(DISTINCT openalex_id)                  AS ids_distintos,
    sum(openalex_id IS NULL OR openalex_id = '') AS id_vazio,
    sum(display_name IS NULL)                    AS nome_nulo,
    min(snapshot_date)                           AS particao_min,
    max(snapshot_date)                           AS particao_max
  FROM oa_br")

cat("linhas BR antes de deduplicar :", chk$linhas_br_brutas, "\n")
cat("ids BR distintos na fonte     :", chk$ids_br_distintos, "\n")
cat("  por country_code = 'BR'     :", chk$por_country_code, "\n")
cat("  por geo.country = 'Brazil'  :", chk$por_geo_country, "\n")
cat("linhas gravadas               :", out$linhas, "\n")
cat("ids distintos gravados        :", out$ids_distintos, "\n")
cat("ids vazios / nomes nulos      :", out$id_vazio, "/", out$nome_nulo, "\n")
cat("particoes de origem           :", out$particao_min, "a", out$particao_max, "\n\n")

# A saida tem de ser exatamente um registro por id brasileiro.
stopifnot(out$linhas == out$ids_distintos,
          out$linhas == chk$ids_br_distintos,
          out$id_vazio == 0L,
          out$nome_nulo == 0L)

# Regressao contra os valores medidos no snapshot de fevereiro/2026.
if (out$linhas != exp_rows ||
    chk$por_country_code != exp_by_code ||
    chk$por_geo_country != exp_by_geo) {
  warning("Contagens divergem do esperado (", exp_rows, " = ",
          exp_by_code, " + ", exp_by_geo, "). O snapshot mudou?")
}

# Limpeza de display_name. As contagens saem em SQL, nao em R, para
# nao depender da codificacao do console do Windows ao comparar
# literais acentuados.
lim <- dbGetQuery(con, "
  SELECT
    sum(cleaned_display_name IS NULL
        OR cleaned_display_name = '')                        AS vazio,
    sum(cleaned_display_name LIKE '%(%'
        OR cleaned_display_name LIKE '%)%')                   AS sobra_paren,
    sum(cleaned_display_name <> trim(cleaned_display_name))   AS com_borda,
    sum(display_name <> cleaned_display_name)                 AS alterados,
    sum(NOT regexp_matches(display_name, '^[\\x00-\\x7F]*$')) AS acento_orig,
    sum(NOT regexp_matches(cleaned_display_name,
                           '^[\\x00-\\x7F]*$'))               AS acento_limpo,
    (SELECT count(*) FROM (SELECT display_name FROM oa_br
       GROUP BY 1 HAVING count(*) > 1))                       AS dup_orig,
    (SELECT count(*) FROM (SELECT cleaned_display_name FROM oa_br
       GROUP BY 1 HAVING count(*) > 1))                       AS dup_limpo
  FROM oa_br")

cat("nomes alterados pela limpeza  :", lim$alterados, "\n")
cat("nomes com acento (orig/limpo) :", lim$acento_orig, "/", lim$acento_limpo, "\n")
cat("grupos duplicados (orig/limpo):", lim$dup_orig, "/", lim$dup_limpo, "\n\n")

# Invariantes da limpeza. A igualdade de acentuados e o que quebra se
# alguem inserir strip_accents ou lower() na expressao. A igualdade de
# duplicados e o que quebra se a limpeza passar a fundir instituicoes
# distintas em um mesmo nome.
stopifnot(lim$vazio == 0L,
          lim$sobra_paren == 0L,
          lim$com_borda == 0L,
          lim$acento_limpo == lim$acento_orig,
          lim$dup_limpo == lim$dup_orig)

if (lim$alterados != exp_cleaned_changed || lim$acento_limpo != exp_nonascii) {
  warning("Limpeza diverge do esperado (", exp_cleaned_changed,
          " alterados, ", exp_nonascii, " acentuados). O snapshot mudou?")
}

# Nenhum registro nao brasileiro pode ter escapado.
vazamento <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n
  FROM oa_br b
  WHERE NOT EXISTS (
    SELECT 1 FROM oa_raw r
    WHERE r.id = b.openalex_url AND (%s))", where_br))
stopifnot(vazamento$n == 0L)

# Releitura do arquivo gravado, com arrow, para conferir que o parquet
# e legivel fora do DuckDB e bate com a tabela.
df <- arrow::read_parquet(out_path)
cat("releitura arrow:", nrow(df), "linhas,", ncol(df), "colunas\n")
cat("colunas:", paste(names(df), collapse = ", "), "\n")
stopifnot(nrow(df) == out$linhas, anyDuplicated(df$openalex_id) == 0L)

faltando <- exp_names[!vapply(exp_names, function(x)
  any(grepl(x, df$display_name, fixed = TRUE)), logical(1))]
if (length(faltando)) {
  stop("Instituicoes de referencia ausentes: ",
       paste(faltando, collapse = " | "))
}

cat("\nTop 10 por works_count:\n")
print(head(df[, c("openalex_id", "display_name", "type", "works_count")], 10))

# Amostra antes/depois: mostra a remocao dos parenteses e, ao mesmo
# tempo, que os acentos sobreviveram.
cat("\nLimpeza de nome, antes e depois (10 maiores alterados):\n")
alt <- df[df$display_name != df$cleaned_display_name,
          c("display_name", "cleaned_display_name")]
print(head(alt, 10), right = FALSE)

cat("\nGravado:", out_path, "\n")
cat("tamanho:", round(file.size(out_path) / 1024, 1), "KB\n")
