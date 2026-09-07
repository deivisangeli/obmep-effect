####################################################################
### Diploma de universidade do top 1000 de Xangai
###
### Marca, para cada user_id de obmep_candidates_step_1, se a pessoa
### tem BACHARELADO, MESTRADO ou DOUTORADO em uma instituicao do top
### 1000 do ranking de Xangai.
###
### OFFLINE. Nao usa rede, nao le Athena, nao escreve em S3. As duas
### entradas ja estao em disco:
###
###   shanghai_ranking/shanghai_ranking_oa.parquet          (script 4)
###   revelio_br_cohort/obmep_candidates_step_1_education/  (script 10a)
###
### Por isso a varredura custa zero na conta da AWS e roda em cerca de
### um minuto. Nao reconstrua isto em Athena sem motivo: o extrato de
### educacao ja custou 72,9 GB de scan uma vez.
###
### -----------------------------------------------------------------
### O CASAMENTO E O MESMO DO CRITERIO C_norm
### -----------------------------------------------------------------
### O procedimento vem de revelio_br_cohort_user_ids.R: dobra acentos,
### compara em minusculas, e aceita o casamento tanto na string inteira
### quanto em qualquer SEGMENTO delimitado por barra, parenteses ou
### hifen cercado de espacos, com pelo menos 3 caracteres. Roda sobre
### university_raw DISTINTO (1.417.851 strings), nao sobre as 15,7
### milhoes de linhas de educacao -- e isso que torna o braco de
### segmento viavel. Os dois bracos agrupam por university_raw, entao a
### volta para a tabela de educacao e no maximo 1:1 e nao pode
### multiplicar linha.
###
### Ha exatamente UM desvio deliberado em relacao ao C_norm, e ele esta
### na nota 3 abaixo.
###
### -----------------------------------------------------------------
### PONTOS DE ATENCAO
### -----------------------------------------------------------------
### 1. Rank e codificado em FAIXAS, nao em posicao. De 1 a 100 e a
###    posicao exata; depois vem 101, 151, 201, 301, ..., 901, cada um
###    representando o inicio de uma faixa. Rank <= 901 seleciona
###    EXATAMENTE 1.000 linhas -- e essa a definicao de "top 1000"
###    aqui. As 79 linhas restantes do xlsx tem Rank nulo. Se o xlsx
###    mudar, a aritmetica da faixa tem de ser refeita, e nao
###    reinterpretada em silencio: por isso a checagem == 1000 aborta.
###
### 2. O lado da instituicao usa AS TRES colunas de nome, nao so
###    cleaned_display_name. shanghai_Name e o que cobre a unica linha
###    do top 1000 cujo id OpenAlex nao resolve (display_name nulo), e
###    tambem carrega a grafia do proprio ranking onde ela difere da do
###    OpenAlex -- 307 das 1.076 linhas casadas diferem. Depois de
###    dobrar acentos as tres colunas colapsam em 1.246 strings.
###
### 2b. O casamento le DUAS colunas, nao uma. university_raw e o que a
###    pessoa digitou; university_name e a normalizacao do proprio
###    Revelio, e traz o nome canonico em INGLES. As duas passam pelo
###    MESMO classificador -- mesmos dois bracos, mesma dobra de acento,
###    mesmo corte de 3 caracteres --, e o university_raw tem
###    precedencia: o nome do Revelio so entra quando o raw nao casa.
###
###    A ordem importa porque o Revelio erra de vez em quando: 1.922
###    linhas escritas "University of Sydney" tem university_name
###    "Western Sydney University", e ~300 escritas "Seoul National
###    University" viram "Gyeongsang National University". Onde as duas
###    colunas casam, elas concordam sobre a IDENTIDADE da instituicao
###    (OA_key) em 1.170.964 de 1.173.310 linhas -- 0,2% de discordancia,
###    quase toda ela esses dois defeitos.
###
###    O ganho: +166.023 linhas e +105.272 pessoas (+11,9%), vindas de
###    onde a auditoria de cobertura (script 17) disse que viriam --
###    Italia, Portugal, Alemanha e paises cujo nome local nunca bate
###    com o nome ingles do ranking. "Universitat Wien" tem
###    university_name "University of Vienna"; "Universita degli Studi
###    di Torino" tem "University of Turin".
###
###    sh_raw_any guarda a definicao ANTERIOR, so com university_raw,
###    para que o alargamento se desfaca com um WHERE e sem reconstruir
###    nada -- mesma logica de br_openalex ao lado de br_openalex_norm.
###
### 2c. O rsid NAO e usado, e foi considerado. O README ja registra por
###    que o ramo rsid foi retirado da coorte, e aqui ele falharia por
###    um motivo adicional e decisivo: o match_share que o torna seguro
###    e calculado A PARTIR do casamento de string que se quer
###    consertar. Para as instituicoes que faltam ele vale 0,005
###    (Politecnico di Torino), 0,014 (Padova), 0,02 (Torino), 0,048
###    (Poznan), 0,235 (Wien) -- todas abaixo do corte de 0,5 que o
###    README provou seguro. Baixar o corte reabre exatamente o
###    envenenamento de Harvard. Medido tambem: "MBA USP/Esalq" cai em
###    NOVE rsids diferentes, entre eles FGV e Mackenzie, e uma linha
###    "Tilburg University" carrega o rsid de Nottingham com
###    match_share 0,967.
###
### 3. O braco de SEGMENTO aqui NAO tem a restricao is_edu = 1 que o
###    C_norm tem. Aquela restricao existe porque a lista brasileira do
###    OpenAlex guarda nomes curtos de EMPRESA -- IBM, Vale, Intel,
###    Shell -- e um registro escrito "Curso de Ingles - Intel" casaria
###    com um deles. A lista de Xangai so tem universidade, e o parquet
###    nem sequer tem coluna type. Conferido: a string de instituicao
###    mais curta e UNESP, com 5 caracteres, e as 710 strings cruas que
###    so casam por segmento com ela sao todas UNESP de verdade. O
###    ruido visivel sao colegios tecnicos ligados a universidade, do
###    tipo "Colegio Tecnico Industrial - UNESP", que o filtro de grau
###    descarta de qualquer forma.
###
### 4. strip_accents() do DuckDB NAO e traducao literal do que os
###    scripts de coorte escrevem em Trino, e aqui ele e melhor. Trino
###    nao tem strip_accents e usa normalize(s, NFD) seguido de um
###    regexp_replace que joga fora as marcas combinantes -- mas a
###    cedilha NAO e marca combinante e sobrevive. O DuckDB resolve:
###    conferido, strip_accents aplicado a "Fundacao Getulio Vargas"
###    acentuado devolve a forma ASCII. NAO "corrija" isto de volta
###    para a expressao do Trino.
###
### 5. sql_is_bachelor e sql_shanghai_level sao SQL do TRINO e chamam
###    regexp_like(), que o DuckDB nao tem. O shim esta documentado em
###    scratchpad/validate_sql_syntax.R e e instalado abaixo:
###      CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)
###
###    ATENCAO -- ISTO MUDOU. Ate a auditoria (script 17) o braco de
###    bacharelado era sql_is_bachelor puro, e o cabecalho dizia que
###    "bacharelado" aqui significava byte a byte o que o criterio E
###    entende por isso. NAO SIGNIFICA MAIS. A auditoria achou dois
###    defeitos reais em rx_post e rx_b1/rx_b2, e corrigi-los na origem
###    tiraria 6.145 pessoas da coorte e obrigaria a refazer os scripts
###    8, 9, 10 e 10a. Entao a correcao mora em rx_post16 e rx_bach16,
###    usados SO por sql_shanghai_level.
###
###    O resultado e que o bacharelado do script 16 e o do criterio E
###    divergem, de forma medida e nos dois sentidos: rx_bach16 ALARGA
###    (grado, licenciado) e rx_post16 ESTREITA ("pos- graduacao" com
###    hifen e espaco, que virava bacharelado). sql_is_bachelor
###    continua interpolado inteiro, sem reescrita, entao da para ver
###    exatamente o que foi somado e subtraido dele.
###
### 6. As particoes do extrato de educacao NAO tem extensao -- o UNLOAD
###    do Athena nomeia os objetos <query-id>_<uuid>. Um glob terminado
###    em .parquet nao acha nada; a leitura usa o diretorio e um
###    asterisco.
###
### -----------------------------------------------------------------
### O QUE SAI, E O QUE E GUARDADO SEM FILTRAR
### -----------------------------------------------------------------
### Uma linha por user_id com pelo menos um bacharelado, mestrado ou
### doutorado no top 1000 -- 990.937 pessoas. Junto de cada flag vao a
### melhor faixa, a instituicao e o ano, para que todo user_id marcado
### seja auditavel de volta ate o que o marcou.
###
### sh_master_strict e sh_lato seguem o principio das flags guardadas
### mas nao filtrantes, o mesmo que poe min_bach_year_strict ao lado de
### min_bach_year: sh_master INCLUI MBA, sh_master_strict nao, entao a
### decisao "MBA conta como mestrado" se desfaz com um WHERE e sem
### reconstruir nada. sh_lato guarda quem tem so lato sensu, que por
### definicao nao entra em nenhuma das tres flags.
###
### -----------------------------------------------------------------
### LIMITACOES CONHECIDAS
### -----------------------------------------------------------------
###  - Sigla sozinha nao casa. "MIT", "UCLA" ou "Cambridge" isolados
###    nao sao encontrados a menos que a string tambem traga o nome por
###    extenso. O README mediu essa classe em 1,5% a 2,5% das linhas de
###    uma instituicao na lista brasileira, e e por isso que nao ha
###    tabela de apelidos aqui.
###  - Homonimo casa errado. "Saint Louis University - Maryheights
###    Campus, Baguio City", nas Filipinas, casa com a Saint Louis
###    University dos EUA pelo braco de segmento. Casamento exato apos
###    normalizacao nao separa os dois, e o registro do ramo rsid
###    retirado (README) e o argumento contra afrouxar mais.
###  - O rotulo degree do Revelio ganha quando discorda de degree_raw:
###    649 linhas dizem "graduacao" mas estao rotuladas Doctor e caem
###    em phd. Isso e herdado da forma "degree = 'Bachelor' OR ..." do
###    sql_is_bachelor e fica assim por consistencia com o criterio E.
###  - Conclusao nao e verificada. O Revelio registra matricula, nao
###    diploma, entao "mestrando" e "doutorando" marcam a flag. O
###    criterio E tem a mesma propriedade.
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

sh_path   <- file.path(obmep_root,
                       "Data/intermediate/shanghai_ranking/shanghai_ranking_oa.parquet")
coh_dir   <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
ed_dir    <- file.path(coh_dir, "obmep_candidates_step_1_education")
cand_path <- file.path(coh_dir, "obmep_candidates_step_1.parquet")
out_path  <- file.path(coh_dir, "obmep_candidates_step_1_shanghai.parquet")

patterns_path <- Sys.getenv(
  "OBMEP_DEGREE_PATTERNS",
  unset = file.path("prep", "building_external_data", "br_degree_patterns.R"))

# Corte do top 1000. Ver nota 1: e o inicio da ultima faixa, nao 1000.
rank_cut <- 901L

mem_limit <- "8GB"

# Valores medidos contra o parquet de Xangai e o extrato de educacao
# atuais. Divergencia aqui e sinal de que uma das entradas mudou, nao
# necessariamente de erro -- por isso warning e nao stop.
exp_inst_strings <- 1246L
exp_raws         <- 1417851L
exp_whole        <- 1725L
exp_seg          <- 6262L
exp_union        <- 6267L
exp_union_nam    <- 950L
exp_rows_matched <- 1607459L
exp_users        <- 990937L
exp_raw_users    <- 885665L  # a definicao anterior, so com university_raw
exp_bachelor     <- 856076L
exp_master       <- 272255L
exp_master_str   <- 242729L
exp_phd          <- 54985L
exp_lvl_rows <- c(bachelor = 917409L, master = 289767L,
                  phd = 56915L, other = 343368L)

# Tamanho da coorte de origem. Deterministico: o extrato foi construido
# a partir dela, entao isto aborta em vez de avisar.
exp_cohort <- 6849674L

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_shanghai")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(file.exists(sh_path), dir.exists(ed_dir), file.exists(cand_path),
          file.exists(patterns_path),
          length(Sys.glob(file.path(ed_dir, "*"))) > 0L)

source(patterns_path)
stopifnot(exists("sql_is_bachelor"), exists("sql_shanghai_level"),
          exists("rx_mba"), exists("rx_lato"))

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# temp_directory explicito: o derrame para disco nao pode cair em pasta
# sincronizada pelo Dropbox.
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

# Shim Trino -> DuckDB. Ver nota 5.
dbExecute(con, "CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)")

cat("DuckDB   :", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("ranking  :", sh_path, "\n")
cat("educacao :", ed_dir, "\n")
cat("saida    :", out_path, "\n\n")

sh_src <- sprintf("read_parquet('%s')", sh_path)
ed_src <- sprintf("read_parquet('%s/*')", ed_dir)

####################################################################
### A -- lado da instituicao
####################################################################

# Conferencia da faixa ANTES de qualquer varredura. Ver nota 1.
n_top <- dbGetQuery(con, sprintf(
  "SELECT sum(CASE WHEN Rank <= %d THEN 1 ELSE 0 END) AS n_top,
          sum(CASE WHEN Rank IS NULL THEN 1 ELSE 0 END) AS n_null,
          count(*) AS n_all
   FROM %s", rank_cut, sh_src))

cat("linhas do ranking     :", n_top$n_all, "\n")
cat("com Rank <=", rank_cut, "      :", n_top$n_top, "\n")
cat("com Rank nulo         :", n_top$n_null, "\n")

if (n_top$n_top != 1000L) {
  stop("Rank <= ", rank_cut, " seleciona ", n_top$n_top, " linhas, nao 1000. ",
       "As faixas do ranking mudaram; refaca a aritmetica em vez de ",
       "reinterpretar o corte.")
}

# As tres colunas de nome, dobradas e deduplicadas. Ver nota 2.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE inst AS
  SELECT lower(strip_accents(trim(nm))) AS nm_fold,
         min(Rank)                      AS best_rank,
         arg_min(trim(nm), Rank)        AS sh_inst
  FROM (
    SELECT cleaned_display_name AS nm, Rank FROM %1$s WHERE Rank <= %2$d
    UNION ALL
    SELECT display_name,        Rank FROM %1$s WHERE Rank <= %2$d
    UNION ALL
    SELECT shanghai_Name,       Rank FROM %1$s WHERE Rank <= %2$d
  )
  WHERE nm IS NOT NULL AND length(trim(nm)) >= 3
  GROUP BY 1", sh_src, rank_cut))

n_inst <- dbGetQuery(con, "SELECT count(*) AS n FROM inst")$n
cat("strings de instituicao:", n_inst, "\n\n")

####################################################################
### B -- casamento sobre university_raw distinto
####################################################################

# O classificador roda uma vez POR COLUNA de origem. As duas colunas
# recebem exatamente o mesmo tratamento -- mesmos dois bracos, mesma
# dobra de acento, mesmo corte de 3 caracteres -- para que a unica
# diferenca entre elas seja a COLUNA lida, e nada mais.
classify <- function(col, tbl) {
  dbExecute(con, sprintf("
    CREATE OR REPLACE TABLE %1$s AS
    WITH r AS (
      SELECT DISTINCT %2$s AS s FROM %3$s
      WHERE %2$s IS NOT NULL AND trim(%2$s) <> ''
    ),
    whole AS (
      SELECT r.s, i.best_rank, i.sh_inst
      FROM r JOIN inst i ON lower(strip_accents(trim(r.s))) = i.nm_fold
    ),
    seg AS (
      SELECT r.s,
             min(i.best_rank)                AS best_rank,
             arg_min(i.sh_inst, i.best_rank) AS sh_inst
      FROM r
      CROSS JOIN UNNEST(str_split(regexp_replace(regexp_replace(
                   r.s, '[/()]', '|', 'g'), ' - ', '|', 'g'), '|')) AS t(part)
      JOIN inst i ON lower(strip_accents(trim(t.part))) = i.nm_fold
      WHERE length(trim(t.part)) >= 3
      GROUP BY r.s
    )
    SELECT s,
           CAST(min(best_rank) AS INTEGER) AS sh_rank,
           arg_min(sh_inst, best_rank)     AS sh_inst,
           CAST(max(is_whole) AS INTEGER)  AS m_whole,
           CAST(max(is_seg)   AS INTEGER)  AS m_seg
    FROM (
      SELECT s, best_rank, sh_inst, 1 AS is_whole, 0 AS is_seg FROM whole
      UNION ALL
      SELECT s, best_rank, sh_inst, 0, 1                       FROM seg
    )
    GROUP BY s", tbl, col, ed_src))
  dbGetQuery(con, sprintf("SELECT count(*) AS n_union, sum(m_whole) AS n_whole,
                                  sum(m_seg) AS n_seg FROM %s", tbl))
}

n_raws <- dbGetQuery(con, sprintf(
  "SELECT count(DISTINCT university_raw) AS n FROM %s
   WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''", ed_src))$n
cat("university_raw distinto:", format(n_raws, big.mark = ","), "\n")

m  <- classify("university_raw",  "cls")
mn <- classify("university_name", "cls_nam")

cat("casam na string inteira :", format(m$n_whole,  big.mark = ","), "\n")
cat("casam por segmento      :", format(m$n_seg,    big.mark = ","), "\n")
cat("uniao (university_raw)  :", format(m$n_union,  big.mark = ","), "\n")
cat("uniao (university_name) :", format(mn$n_union, big.mark = ","), "\n\n")

####################################################################
### C -- nivel do diploma, linha a linha
####################################################################

# A cascata vem de br_degree_patterns.R. Os quatro bracos particionam as
# linhas por construcao; a validacao confere isso.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE lvl AS
  SELECT e.user_id,
         coalesce(c.sh_rank, n.sh_rank) AS sh_rank,
         coalesce(c.sh_inst, n.sh_inst) AS sh_inst,
         coalesce(c.m_whole, n.m_whole) AS m_whole,
         CASE WHEN c.s IS NOT NULL THEN 1 ELSE 0 END   AS by_raw,
         CAST(year(e.startdate) AS INTEGER)            AS yr,
         (%s)                                          AS lvl,
         (e.degree = 'MBA' OR regexp_like(e.dr, '%s')) AS is_mba,
         regexp_like(e.dr, '%s')                       AS is_lato
  FROM (
    SELECT user_id, startdate, degree, university_raw, university_name,
           lower(trim(coalesce(degree_raw, ''))) AS dr
    FROM %s
  ) e
  LEFT JOIN cls     c ON e.university_raw  = c.s
  LEFT JOIN cls_nam n ON e.university_name = n.s
  WHERE c.s IS NOT NULL OR n.s IS NOT NULL",
  sql_shanghai_level, rx_mba, rx_lato, ed_src))

lvl_rows <- dbGetQuery(con, "
  SELECT lvl, count(*) AS n, count(DISTINCT user_id) AS usuarios
  FROM lvl GROUP BY 1 ORDER BY n DESC")

cat("--- linhas de educacao casadas, por nivel ---\n")
print(lvl_rows, right = FALSE, row.names = FALSE)

n_rows_matched <- sum(lvl_rows$n)
cat("\ntotal de linhas casadas:", format(n_rows_matched, big.mark = ","), "\n\n")

####################################################################
### D -- uma linha por user_id
####################################################################

dbExecute(con, "
  CREATE OR REPLACE TABLE saida AS
  SELECT user_id,
         1                                                                   AS sh_any,
         CAST(max(CASE WHEN by_raw = 1 AND lvl IN ('bachelor','master','phd')
                       THEN 1 ELSE 0 END)                       AS INTEGER) AS sh_raw_any,
         CAST(max(CASE WHEN lvl = 'bachelor' THEN 1 ELSE 0 END) AS INTEGER)  AS sh_bachelor,
         CAST(max(CASE WHEN lvl = 'master'   THEN 1 ELSE 0 END) AS INTEGER)  AS sh_master,
         CAST(max(CASE WHEN lvl = 'master' AND NOT is_mba
                       THEN 1 ELSE 0 END)                       AS INTEGER)  AS sh_master_strict,
         CAST(max(CASE WHEN lvl = 'phd'      THEN 1 ELSE 0 END) AS INTEGER)  AS sh_phd,
         CAST(max(CASE WHEN is_lato          THEN 1 ELSE 0 END) AS INTEGER)  AS sh_lato,
         min(sh_rank) FILTER (WHERE lvl IN ('bachelor','master','phd'))      AS sh_best_rank,
         min(sh_rank) FILTER (WHERE lvl = 'bachelor')                        AS sh_bach_rank,
         min(sh_rank) FILTER (WHERE lvl = 'master')                          AS sh_mast_rank,
         min(sh_rank) FILTER (WHERE lvl = 'phd')                             AS sh_phd_rank,
         arg_min(sh_inst, sh_rank) FILTER (WHERE lvl = 'bachelor')           AS sh_bach_inst,
         arg_min(sh_inst, sh_rank) FILTER (WHERE lvl = 'master')             AS sh_mast_inst,
         arg_min(sh_inst, sh_rank) FILTER (WHERE lvl = 'phd')                AS sh_phd_inst,
         min(yr) FILTER (WHERE lvl = 'bachelor')                             AS sh_bach_year,
         min(yr) FILTER (WHERE lvl = 'master')                               AS sh_mast_year,
         min(yr) FILTER (WHERE lvl = 'phd')                                  AS sh_phd_year,
         CAST(count(*) AS INTEGER)                                           AS sh_n_rows
  FROM lvl
  GROUP BY user_id
  HAVING max(CASE WHEN lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) = 1")

dbExecute(con, sprintf(
  "COPY (SELECT * FROM saida ORDER BY user_id) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", out_path))

####################################################################
### Validacao
####################################################################

v <- dbGetQuery(con, "
  SELECT count(*)                                         AS n_users,
         count(DISTINCT user_id)                          AS n_uid,
         sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS uid_null,
         sum(sh_any)                                      AS n_any,
         sum(sh_raw_any)                                  AS n_raw_any,
         sum(CASE WHEN sh_raw_any > sh_any THEN 1 ELSE 0 END) AS bad_rawsup,
         sum(sh_bachelor)                                 AS n_bachelor,
         sum(sh_master)                                   AS n_master,
         sum(sh_master_strict)                            AS n_master_str,
         sum(sh_phd)                                      AS n_phd,
         sum(sh_lato)                                     AS n_lato,
         sum(CASE WHEN sh_bachelor + sh_master + sh_phd = 0
                  THEN 1 ELSE 0 END)                      AS bad_empty,
         sum(CASE WHEN sh_master_strict > sh_master
                  THEN 1 ELSE 0 END)                      AS bad_strict,
         sum(CASE WHEN sh_best_rank IS NULL
                  THEN 1 ELSE 0 END)                      AS bad_norank,
         max(sh_best_rank)                                AS rank_max
  FROM saida")

if (v$n_users != v$n_uid) stop("user_id duplicado na saida.")
if (v$uid_null != 0)      stop("user_id nulo na saida.")
if (v$n_any != v$n_users) stop("sh_any nao e 1 em toda linha.")
if (v$bad_empty != 0) {
  stop(v$bad_empty, " linhas sem nenhuma das tres flags. O HAVING nao ",
       "esta cortando o que deveria.")
}
# Estrito e subconjunto por construcao: sh_master_strict exige tudo que
# sh_master exige e mais a negacao de MBA. Violacao aqui significa que o
# teste de MBA esta invertido.
if (v$bad_strict != 0) {
  stop(v$bad_strict, " linhas com sh_master_strict > sh_master. ",
       "O teste de MBA esta invertido.")
}
if (v$bad_norank != 0) stop(v$bad_norank, " linhas marcadas sem sh_best_rank.")
# sh_any e superconjunto de sh_raw_any por construcao: o braco do
# university_name so ACRESCENTA linha, nunca tira uma. Violacao aqui
# significa que o COALESCE ou o LEFT JOIN esta invertido.
if (v$bad_rawsup != 0) {
  stop(v$bad_rawsup, " linhas com sh_raw_any > sh_any. O braco do ",
       "university_name esta removendo linha em vez de acrescentar.")
}
if (v$rank_max > rank_cut) {
  stop("sh_best_rank chega a ", v$rank_max, ", acima do corte ", rank_cut, ".")
}

# A faixa vale em toda coluna de rank, nao so na melhor.
bad_rank <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM saida
  WHERE coalesce(sh_bach_rank, 0) > %1$d
     OR coalesce(sh_mast_rank, 0) > %1$d
     OR coalesce(sh_phd_rank,  0) > %1$d", rank_cut))$n
if (bad_rank != 0) stop(bad_rank, " linhas com rank de nivel acima do corte.")

# A cascata particiona: os quatro bracos tem de somar o total casado.
part <- dbGetQuery(con, "
  SELECT count(*) AS n_all,
         sum(CASE WHEN lvl IN ('bachelor','master','phd','other')
                  THEN 1 ELSE 0 END) AS n_named
  FROM lvl")
if (part$n_all != part$n_named) {
  stop("A cascata de nivel devolveu um valor fora de ",
       "{bachelor, master, phd, other}.")
}

# Todo user_id da saida tem de estar na coorte. O extrato foi construido
# a partir dela, entao um id estranho significa diretorio errado.
orf <- dbGetQuery(con, sprintf("
  SELECT (SELECT count(*) FROM read_parquet('%1$s')) AS n_cohort,
         (SELECT count(*) FROM saida o
          WHERE NOT EXISTS (SELECT 1 FROM read_parquet('%1$s') c
                            WHERE c.user_id = o.user_id)) AS n_orphan",
  cand_path))
if (orf$n_orphan != 0) {
  stop(orf$n_orphan, " user_id da saida nao estao em ",
       basename(cand_path), ". Diretorio de educacao errado?")
}
if (orf$n_cohort != exp_cohort) {
  stop("A coorte tem ", orf$n_cohort, " linhas, nao ", exp_cohort,
       ". As constantes medidas nao valem contra ela.")
}

####################################################################
### Regressao contra os valores medidos
####################################################################

chk <- function(nome, obtido, esperado) {
  if (obtido != esperado) {
    warning(nome, ": ", format(obtido, big.mark = ","), " (esperado ",
            format(esperado, big.mark = ","), ")", call. = FALSE)
  }
}

chk("strings de instituicao",  n_inst,            exp_inst_strings)
chk("university_raw distinto", n_raws,            exp_raws)
chk("casam na string inteira", m$n_whole,         exp_whole)
chk("casam por segmento",      m$n_seg,           exp_seg)
chk("uniao de casamentos",     m$n_union,         exp_union)
chk("uniao por nome Revelio",  mn$n_union,        exp_union_nam)
chk("linhas casadas",          n_rows_matched,    exp_rows_matched)
chk("usuarios marcados",       v$n_users,         exp_users)
chk("usuarios so por raw",     v$n_raw_any,       exp_raw_users)
chk("sh_bachelor",             v$n_bachelor,      exp_bachelor)
chk("sh_master",               v$n_master,        exp_master)
chk("sh_master_strict",        v$n_master_str,    exp_master_str)
chk("sh_phd",                  v$n_phd,           exp_phd)
for (k in names(exp_lvl_rows)) {
  got <- lvl_rows$n[lvl_rows$lvl == k]
  chk(paste0("linhas nivel ", k),
      if (length(got)) got else 0L, exp_lvl_rows[[k]])
}

####################################################################
### Releitura e relatorio
####################################################################

df <- arrow::read_parquet(out_path)
stopifnot(nrow(df) == v$n_users,
          all(c("user_id", "sh_any", "sh_raw_any", "sh_bachelor", "sh_master",
                "sh_master_strict", "sh_phd", "sh_lato", "sh_best_rank",
                "sh_bach_rank", "sh_mast_rank", "sh_phd_rank",
                "sh_bach_inst", "sh_mast_inst", "sh_phd_inst",
                "sh_bach_year", "sh_mast_year", "sh_phd_year",
                "sh_n_rows") %in% names(df)))

cat("\n=== resultado ===\n")
cat("usuarios marcados :", format(v$n_users,     big.mark = ","), "\n")
cat("  sh_bachelor     :", format(v$n_bachelor,  big.mark = ","), "\n")
cat("  sh_master       :", format(v$n_master,    big.mark = ","),
    "(sem MBA:", format(v$n_master_str, big.mark = ","), ")\n")
cat("  sh_phd          :", format(v$n_phd,       big.mark = ","), "\n")
cat("  sh_lato         :", format(v$n_lato,      big.mark = ","),
    "(guardado, nao filtra)\n")

cat("
  so pelo university_raw (definicao anterior):",
    format(v$n_raw_any, big.mark = ","), "
")
cat("  acrescentados pelo university_name        :",
    format(v$n_users - v$n_raw_any, big.mark = ","),
    sprintf("(+%.1f%%)", 100 * (v$n_users - v$n_raw_any) / v$n_raw_any), "
")

cat("\n--- por faixa do ranking (melhor nivel) ---\n")
print(dbGetQuery(con, "
  SELECT CASE WHEN sh_best_rank <= 10  THEN '01 top 10'
              WHEN sh_best_rank <= 100 THEN '02 11-100'
              WHEN sh_best_rank <= 200 THEN '03 101-200'
              WHEN sh_best_rank <= 500 THEN '04 201-500'
              ELSE                          '05 501-1000' END AS faixa,
         count(*) AS usuarios
  FROM saida GROUP BY 1 ORDER BY 1"), right = FALSE, row.names = FALSE)

# A precisao do braco de segmento fica visivel a cada rodada: se uma
# instituicao aparecer aqui com 100% vindo so do segmento, vale olhar
# quais strings cruas a alimentam antes de confiar nela.
cat("\n--- 20 maiores instituicoes casadas, e quanto vem so do segmento ---\n")
print(dbGetQuery(con, "
  SELECT sh_inst,
         count(*)                AS linhas,
         count(DISTINCT user_id) AS usuarios,
         round(100.0 * sum(CASE WHEN m_whole = 0 THEN 1 ELSE 0 END)
               / count(*), 1)    AS pct_so_segmento
  FROM lvl
  WHERE lvl IN ('bachelor','master','phd')
  GROUP BY 1 ORDER BY linhas DESC LIMIT 20"), right = FALSE, row.names = FALSE)

# Quantos destes ja tinham sido alcancados pelo casamento brasileiro do
# criterio C_norm, e quantos so aparecem por uma instituicao de fora.
cat("\n--- cruzamento com br_openalex_norm da coorte ---\n")
print(dbGetQuery(con, sprintf("
  SELECT c.br_openalex_norm, count(*) AS usuarios
  FROM saida o JOIN read_parquet('%s') c ON c.user_id = o.user_id
  GROUP BY 1 ORDER BY 1", cand_path)), right = FALSE, row.names = FALSE)

cat("\nGravado:", out_path, "\n")
cat("tamanho:", round(file.size(out_path) / 1024^2, 1), "MB\n")
