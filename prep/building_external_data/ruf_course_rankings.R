####################################################################
### Ranking de Cursos do RUF (Ranking Universitario Folha) 2025
###
### Baixa o ranking das 40 carreiras avaliadas pelo RUF 2025 e grava
### um parquet no Dropbox do OBMEP com UMA LINHA POR CURSO x
### INSTITUICAO, marcando as 50 primeiras de cada curso na coluna
### top_50. Guarda a lista inteira, e nao so as 50, para que o corte
### possa ser alargado depois sem baixar nada de novo.
###
### ESTE SCRIPT USA REDE. E local e online, como os scripts 2, 5 e 7-9
### desta pasta; ver AGENTS.md -> Execution Environments. Nao pode ser
### copiado para scripts_sedap/. Nao usa S3 nem Athena: so HTTP contra
### ruf.folha.uol.com.br e escrita de parquet no Dropbox.
###
### As paginas de curso do RUF sao uma casca Vue: a tabela nao esta no
### HTML. Os dados vem de tres arquivos JSON publicos, e e deles que
### este script le. NAO raspar HTML.
###
###   .../2025/database/courses_ids_map.json          40 cursos
###   .../2025/database/cursos/<slug>/ranking.json    ranking do curso
###   .../2025/database/lista_cidades.json            1.061 cidades
###
### Tres armadilhas dos dados, todas verificadas contra a fonte:
###
###  1. O ARRAY NAO VEM ORDENADO POR POSICAO. Ele chega em ordem de id
###     da instituicao: o segundo elemento de administracao e o 5o
###     colocado. Qualquer coisa que pegue "as 50 primeiras linhas"
###     esta silenciosamente errada. O corte e filtro por rank.
###
###  2. ACIMA DE 200 O RANK VIRA FAIXA. As posicoes individuais vao de
###     1 a 200; a partir dai o campo 'rank' traz "201-250", "501-600",
###     ..., "1001+" (395 linhas dividem "1001+" em administracao). O
###     'rank_clean' e o PISO da faixa, entao acima de 200 ele repete e
###     NAO e ordenacao. So e confiavel na regiao individual, onde o
###     corte das 50 esta com folga. A coluna is_banded marca as
###     linhas em faixa justamente para que ninguem ordene por elas.
###
###  3. HA EMPATES, INCLUSIVE EM CIMA DO CORTE. A numeracao e de
###     competicao (1, 2, 2, 4), entao um empate normalmente se paga
###     pulando o numero seguinte e rank <= 50 devolve 50 linhas. Mas
###     FISIOTERAPIA tem duas instituicoes na posicao 50 (Universidade
###     Catolica de Pernambuco e UFRN) e nenhuma na 51: o top 50 dela
###     tem 51 linhas, e esta certo. E por isso que o corte e filtro por
###     rank e nunca LIMIT 50, e que a divergencia e reportada em vez de
###     abortar. Direito tem o mesmo empate na posicao 17.
###
### Uma armadilha de tipo, tambem verificada: dentro de 'pos' os campos
### *_clean, 'mec' e 'oab' alternam INTEIRO e STRING VAZIA na mesma
### coluna, linha a linha. Por isso 'pos' inteiro e declarado VARCHAR na
### projecao e convertido com try_cast(nullif(x,'')) no SQL. Declarar
### INTEGER ali quebra a leitura.
###
### As colunas score_evasion, score_rh e score_tn vem inteiramente
### nulas no RUF 2025, e score_oab so existe em direito. Sao mantidas de
### proposito: derruba-las esconderia uma edicao futura passando a
### preenche-las. O script reporta quais estao 100% nulas.
###
### Escopo: SOMENTE a edicao 2025. As edicoes 2012-2019 e 2023-2024
### existem sob o mesmo esquema de URL, mas o schema delas nao foi
### verificado aqui.
###
### O conteudo e da Folha de S.Paulo e esta protegido por direito
### autoral. Isto e insumo interno de pesquisa, nao material para
### redistribuicao.
####################################################################

for (p in c("DBI", "duckdb", "arrow", "curl", "jsonlite")) {
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

edition  <- 2025L
base_url <- sprintf("https://ruf.folha.uol.com.br/%d/database", edition)

out_dir    <- file.path(obmep_root, "Data/intermediate/ruf_ranking")
raw_dir    <- file.path(out_dir, "raw", as.character(edition))
cursos_dir <- file.path(raw_dir, "cursos")

out_path    <- file.path(out_dir, sprintf("ruf_course_ranking_%d.parquet", edition))
out_courses <- file.path(out_dir, sprintf("ruf_courses_%d.parquet", edition))

courses_json <- file.path(raw_dir, "courses_ids_map.json")
cities_json  <- file.path(raw_dir, "lista_cidades.json")

# Valores medidos contra a edicao 2025.
exp_courses <- 40L
exp_cities  <- 1061L
exp_rows    <- 18830L

# Piso a partir do qual o RUF publica faixa em vez de posicao individual.
band_floor <- 201L

# Pausa entre requisicoes. Sao 42 arquivos; nao ha motivo para pressa.
sleep_s <- 0.5

for (d in c(out_dir, raw_dir, cursos_dir)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_ruf")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

####################################################################
### Download, com cache
####################################################################

# Baixa so o que ainda nao existe. Escreve o arquivo apenas depois de
# checar status 200 E de o JSON ter sido parseado com sucesso, para que
# um arquivo truncado nunca fique em disco fingindo ser cache valido.
baixar <- function(url, destino) {
  if (file.exists(destino) && file.size(destino) > 0L) {
    return(invisible(FALSE))
  }
  cat("  baixando", basename(destino), "... ")
  r <- curl::curl_fetch_memory(url)
  if (r$status_code != 200L) {
    stop("HTTP ", r$status_code, " em ", url)
  }
  txt <- rawToChar(r$content)
  Encoding(txt) <- "UTF-8"
  parsed <- tryCatch(jsonlite::fromJSON(txt, simplifyVector = FALSE),
                     error = function(e) stop("JSON invalido em ", url, ": ",
                                              conditionMessage(e)))
  if (!length(parsed)) stop("JSON vazio em ", url)
  writeBin(r$content, destino)
  cat(length(parsed), "registros,", round(length(r$content) / 1024), "KB\n")
  Sys.sleep(sleep_s)
  invisible(TRUE)
}

cat("RUF", edition, "\n")
cat("origem:", base_url, "\n")
cat("saida :", out_path, "\n\n")

cat("Indices:\n")
baixar(file.path(base_url, "courses_ids_map.json"), courses_json)
baixar(file.path(base_url, "lista_cidades.json"),  cities_json)

cursos <- jsonlite::fromJSON(courses_json)
stopifnot(is.data.frame(cursos),
          all(c("id", "name", "slug") %in% names(cursos)),
          !any(duplicated(cursos$slug)),
          !any(duplicated(cursos$id)))

cat("\ncursos no indice:", nrow(cursos), "\n")
if (nrow(cursos) != exp_courses) {
  warning("O RUF passou a listar ", nrow(cursos), " cursos, e nao ",
          exp_courses, ". Curso adicionado ou removido na fonte?")
}

cat("\nRankings por curso:\n")
for (s in cursos$slug) {
  baixar(sprintf("%s/cursos/%s/ranking.json", base_url, s),
         file.path(cursos_dir, paste0(s, ".json")))
}

arquivos <- file.path(cursos_dir, paste0(cursos$slug, ".json"))
faltando <- cursos$slug[!file.exists(arquivos)]
if (length(faltando)) {
  stop("Sem ranking.json para: ", paste(faltando, collapse = ", "))
}
cat("\n", length(arquivos), " arquivos de curso em ", cursos_dir, "\n\n", sep = "")

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# temp_directory explicito: o derrame para disco nao pode cair em pasta
# sincronizada pelo Dropbox.
nul <- dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))
cat("DuckDB:", dbGetQuery(con, "SELECT version() AS v")$v, "\n\n")

dbWriteTable(con, "cursos", cursos, overwrite = TRUE)

nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE cidades AS
  SELECT id, \"option\" AS city_name, upper(uf) AS city_uf
  FROM read_json('%s', columns={id:'INTEGER', \"option\":'VARCHAR', uf:'VARCHAR'})",
  gsub("\\\\", "/", cities_json)))

n_cid <- dbGetQuery(con, "SELECT count(*) n FROM cidades")$n
cat("cidades no indice:", n_cid, "\n")
if (n_cid != exp_cities) {
  warning("lista_cidades.json tem ", n_cid, " cidades, esperado ", exp_cities, ".")
}

####################################################################
### Leitura dos rankings
####################################################################

# Projecao explicita, nunca read_json_auto: uma coluna 100% nula em um
# curso seria inferida com tipo diferente da mesma coluna em outro e a
# uniao dos 40 arquivos falharia. 'pos' e todo VARCHAR de proposito
# (ver armadilha de tipo no cabecalho).
cols <- paste0(
  "columns={",
  "name:'VARCHAR', abbr:'VARCHAR', searchable:'VARCHAR', url:'VARCHAR', ",
  "uf:'VARCHAR', type:'INTEGER', rank:'VARCHAR', rank_clean:'INTEGER', ",
  "rank_pp:'INTEGER', size:'VARCHAR', age:'VARCHAR', demand:'VARCHAR', ",
  "locs:'STRUCT(city INTEGER, uf VARCHAR)[]', ",
  "scores:'STRUCT(m DOUBLE, t DOUBLE, dm DOUBLE, nh DOUBLE, enade DOUBLE, ",
  "retention DOUBLE, evasion DOUBLE, mec DOUBLE, oab DOUBLE, rh DOUBLE, tn DOUBLE)', ",
  "pos:'STRUCT(m VARCHAR, m_clean VARCHAR, t VARCHAR, t_clean VARCHAR, ",
  "dm VARCHAR, dm_clean VARCHAR, nh VARCHAR, nh_clean VARCHAR, ",
  "enade VARCHAR, enade_clean VARCHAR, retention VARCHAR, retention_clean VARCHAR, ",
  "evasion_clean VARCHAR, oab VARCHAR, rh VARCHAR, tn VARCHAR, mec VARCHAR)'}")

glob_cursos <- gsub("\\\\", "/", file.path(cursos_dir, "*.json"))

nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE bruto AS
  SELECT
    regexp_extract(filename, '([a-z0-9-]+)[.]json$', 1)   AS course_slug,
    -- O id da instituicao esta embutido na URL da ficha
    -- (.../universidade-de-sao-paulo-55.shtml -> 55). E a unica chave
    -- estavel entre cursos: o nome nao serve para juntar.
    try_cast(regexp_extract(url, '-([0-9]+)[.]shtml$', 1) AS INTEGER)
                                                          AS ruf_institution_id,
    name                                                  AS institution_name,
    abbr, uf, type, url                                   AS ruf_url,
    rank                                                  AS rank_label,
    rank_clean                                            AS rank,
    rank_pp, size, age, demand,
    len(locs)                                             AS n_campi,
    locs, scores, pos
  FROM read_json('%s', filename=true, %s)", glob_cursos, cols))

# Cidades dos campi, resolvidas pelo indice. LEFT JOIN a partir do
# unnest: instituicao sem locs simplesmente nao aparece aqui e volta
# com cities nulo no join de baixo.
nul <- dbExecute(con, "
  CREATE OR REPLACE TABLE campi AS
  SELECT
    x.course_slug,
    x.ruf_institution_id,
    string_agg(coalesce(c.city_name, '?') || '/' ||
               coalesce(c.city_uf, upper(x.loc.uf)), '; '
               ORDER BY c.city_name) AS cities
  FROM (SELECT course_slug, ruf_institution_id, unnest(locs) AS loc FROM bruto) x
  LEFT JOIN cidades c ON c.id = x.loc.city
  GROUP BY 1, 2")

nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE ruf AS
  SELECT
    %d                                          AS edition,
    cu.id                                       AS course_id,
    b.course_slug,
    cu.name                                     AS course_name,

    b.rank,
    b.rank_label,
    b.rank_pp,
    b.rank <= 50                                AS top_50,
    -- Fora da regiao individual o rotulo e uma faixa e deixa de bater
    -- com o inteiro. E essa a definicao de is_banded.
    b.rank_label <> CAST(b.rank AS VARCHAR)     AS is_banded,

    b.ruf_institution_id,
    b.institution_name,
    b.abbr,
    b.uf,
    CASE b.type WHEN 1 THEN 'Publica' WHEN 2 THEN 'Privada' END AS administration,
    b.type,
    b.ruf_url,

    b.size, b.age, b.demand,
    b.n_campi,
    ca.cities,

    b.scores.m         AS score_market,
    b.scores.t         AS score_teaching,
    b.scores.dm        AS score_dm,
    b.scores.nh        AS score_nh,
    b.scores.enade     AS score_enade,
    b.scores.retention AS score_retention,
    b.scores.evasion   AS score_evasion,
    b.scores.mec       AS score_mec,
    b.scores.oab       AS score_oab,
    b.scores.rh        AS score_rh,
    b.scores.tn        AS score_tn,

    try_cast(nullif(b.pos.m_clean, '')         AS INTEGER) AS pos_market,
    try_cast(nullif(b.pos.t_clean, '')         AS INTEGER) AS pos_teaching,
    try_cast(nullif(b.pos.dm_clean, '')        AS INTEGER) AS pos_dm,
    try_cast(nullif(b.pos.nh_clean, '')        AS INTEGER) AS pos_nh,
    try_cast(nullif(b.pos.enade_clean, '')     AS INTEGER) AS pos_enade,
    try_cast(nullif(b.pos.retention_clean, '') AS INTEGER) AS pos_retention,
    try_cast(nullif(b.pos.mec, '')             AS INTEGER) AS pos_mec,
    try_cast(nullif(b.pos.oab, '')             AS INTEGER) AS pos_oab
  FROM bruto b
  JOIN cursos cu       ON cu.slug = b.course_slug
  LEFT JOIN campi ca   ON ca.course_slug = b.course_slug
                      AND ca.ruf_institution_id = b.ruf_institution_id
  ORDER BY cu.name, b.rank, b.institution_name", edition))

####################################################################
### Validacao
####################################################################

n_bruto <- dbGetQuery(con, "SELECT count(*) n FROM bruto")$n
n_ruf   <- dbGetQuery(con, "SELECT count(*) n FROM ruf")$n

# O JOIN com cursos e inner: se um slug do arquivo nao existisse no
# indice, a linha sumiria. Esta igualdade e o que pega isso.
stopifnot(n_bruto == n_ruf)

chk <- dbGetQuery(con, "
  SELECT
    count(*)                        AS linhas,
    count(DISTINCT course_slug)     AS cursos,
    sum(ruf_institution_id IS NULL) AS sem_id,
    sum(type NOT IN (1, 2))         AS tipo_estranho,
    sum(rank IS NULL)               AS sem_rank,
    sum(administration IS NULL)     AS sem_natureza
  FROM ruf")

# Chave: um id nunca pode repetir dentro do mesmo curso, senao o
# ranking teria fan-out.
dupes <- dbGetQuery(con, "
  SELECT count(*) n FROM (
    SELECT course_slug, ruf_institution_id
    FROM ruf GROUP BY 1, 2 HAVING count(*) > 1)")$n

# O mesmo id nunca pode carregar dois nomes diferentes entre cursos.
id_conflito <- dbGetQuery(con, "
  SELECT count(*) n FROM (
    SELECT ruf_institution_id
    FROM ruf GROUP BY 1 HAVING count(DISTINCT institution_name) > 1)")$n

# Armadilha 2: nenhuma linha dentro da regiao individual pode estar em
# faixa. Se isso disparar, o piso da faixa desceu e pode ter alcancado
# o corte das 50.
banda_baixa <- dbGetQuery(con, sprintf("
  SELECT count(*) n FROM ruf WHERE is_banded AND rank < %d", band_floor))$n

cat("linhas                :", chk$linhas, "\n")
cat("cursos                :", chk$cursos, "\n")
cat("instituicoes distintas:",
    dbGetQuery(con, "SELECT count(DISTINCT ruf_institution_id) n FROM ruf")$n, "\n\n")

stopifnot(chk$sem_id == 0L,
          chk$tipo_estranho == 0L,
          chk$sem_rank == 0L,
          chk$sem_natureza == 0L,
          dupes == 0L,
          id_conflito == 0L,
          banda_baixa == 0L,
          chk$cursos == nrow(cursos))

if (chk$linhas != exp_rows) {
  warning("Total de linhas ", chk$linhas, " diverge do medido (", exp_rows,
          "). O RUF atualizou a edicao ", edition, "?")
}

# Cobertura por curso. n_top50 tem de ser min(50, linhas); qualquer
# outra coisa e empate em cima do corte ou curso com menos de 50
# instituicoes, e e reportado em vez de abortar.
por_curso <- dbGetQuery(con, "
  SELECT
    course_name,
    count(*)                            AS linhas,
    sum(top_50::INT)                    AS n_top50,
    max(CASE WHEN top_50 THEN rank END) AS pior_rank_top50,
    max(rank)                           AS rank_max,
    sum(is_banded::INT)                 AS em_faixa
  FROM ruf GROUP BY 1 ORDER BY 1")

print(por_curso, right = FALSE)

estranhos <- por_curso[por_curso$n_top50 != pmin(50L, por_curso$linhas), ]
if (nrow(estranhos)) {
  cat("\nCursos cujo top 50 nao tem exatamente 50 linhas:\n")
  print(estranhos, right = FALSE)
  empates <- dbGetQuery(con, sprintf("
    SELECT course_name, rank, count(*) AS n
    FROM ruf WHERE top_50 AND course_name IN ('%s')
    GROUP BY 1, 2 HAVING count(*) > 1 ORDER BY 1, 2",
    paste(estranhos$course_name, collapse = "','")))
  cat("Empates dentro do corte:\n")
  print(empates, right = FALSE)
} else {
  cat("\nTodos os cursos: top 50 com exatamente min(50, linhas) linhas.\n")
}

# O corte nunca pode ter saido da ordem do arquivo.
stopifnot(all(por_curso$pior_rank_top50 <= 50L))

# Colunas de score integralmente nulas nesta edicao.
nulas <- dbGetQuery(con, "
  SELECT * FROM (
    SELECT 'score_market' AS c, count(score_market) AS n FROM ruf
    UNION ALL SELECT 'score_teaching',  count(score_teaching)  FROM ruf
    UNION ALL SELECT 'score_dm',        count(score_dm)        FROM ruf
    UNION ALL SELECT 'score_nh',        count(score_nh)        FROM ruf
    UNION ALL SELECT 'score_enade',     count(score_enade)     FROM ruf
    UNION ALL SELECT 'score_retention', count(score_retention) FROM ruf
    UNION ALL SELECT 'score_evasion',   count(score_evasion)   FROM ruf
    UNION ALL SELECT 'score_mec',       count(score_mec)       FROM ruf
    UNION ALL SELECT 'score_oab',       count(score_oab)       FROM ruf
    UNION ALL SELECT 'score_rh',        count(score_rh)        FROM ruf
    UNION ALL SELECT 'score_tn',        count(score_tn)        FROM ruf)
  ORDER BY n DESC, c")

cat("\nPreenchimento das colunas de score (nao nulos de", chk$linhas, "):\n")
print(nulas, right = FALSE)
cat("Integralmente nulas:",
    paste(nulas$c[nulas$n == 0L], collapse = ", "), "\n")

####################################################################
### Escrita
####################################################################

nul <- dbExecute(con, sprintf(
  "COPY ruf TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  gsub("\\\\", "/", out_path)))

nul <- dbExecute(con, sprintf("
  COPY (SELECT %d AS edition, id AS course_id, name AS course_name, slug AS course_slug
        FROM cursos ORDER BY name)
  TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  edition, gsub("\\\\", "/", out_courses)))

# Releitura com arrow: confirma que o parquet e legivel fora do DuckDB
# e que os acentos sobreviveram (o JSON e UTF-8 e nada aqui dobra
# acento de proposito).
df <- arrow::read_parquet(out_path)
nao_ascii <- sum(grepl("[^\x01-\x7f]", df$institution_name))

cat("\nreleitura arrow:", nrow(df), "linhas,", ncol(df), "colunas\n")
cat("nomes com acento:", nao_ascii, "\n")
stopifnot(nrow(df) == chk$linhas, nao_ascii > 0L,
          all(c("top_50", "rank", "course_name", "ruf_institution_id") %in% names(df)))

cat("\nTop 10 de Medicina:\n")
med <- df[df$course_name == "Medicina" & df$rank <= 10,
          c("rank", "institution_name", "abbr", "uf", "administration")]
print(med[order(med$rank), ], right = FALSE)

cat("\nGravado:", out_path, "\n")
cat("tamanho:", round(file.size(out_path) / 1024, 1), "KB\n")
cat("indice :", out_courses, "\n")
