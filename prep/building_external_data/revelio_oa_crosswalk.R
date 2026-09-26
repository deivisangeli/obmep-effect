####################################################################
###
### Crosswalk unificado Revelio -> openalex_id             [local only]
###
### Seis estrategias de casamento existem, cada uma construida sobre o
### residuo da anterior, e nenhuma estava composta num produto. O 8h
### compoe quatro delas, mas so para ACHAR O QUE FALTA; o 8i e o
### matcher da rodada 2 (8l) vieram depois, e o 8l nunca tinha rodado
### sobre a populacao inteira -- ele so pontua amostras.
###
### O JULGAMENTO MANUAL DE rsid ESTA FORA, por pedido: o mapa do 8i
### entra filtrado em source = 'fold' (410 rsids, dobra mecanica de
### nome exato) e as 38 linhas de julgamento sao descartadas.
###
### -----------------------------------------------------------------
### POR QUE SAO DUAS TABELAS
### -----------------------------------------------------------------
### Um crosswalk com chave SO em university_raw nao consegue carregar
### as tres estrategias que casam por rsid. Medido sobre as 15.712.737
### linhas de educacao:
###
###   3+ openalex_id distintos      322 grafias   5.186.226 linhas
###   2 openalex_id distintos       740 grafias   1.829.184 linhas
###   exatamente 1              102.944 grafias   3.768.483 linhas
###   nenhum                  1.313.845 grafias   4.921.686 linhas
###
### 1.062 grafias resolvem para DOIS OU MAIS openalex_id e carregam
### ~7,0 milhoes de linhas, 45% de todas as entradas. Grafia generica
### atravessa muitos rsid, e e o rsid que desambigua. Entao:
###
###   revelio_oa_crosswalk.parquet         chave (university_raw, rsid)
###                                        fiel, nada colapsado. TODA
###                                        estatistica sai desta.
###   revelio_oa_crosswalk_by_raw.parquet  chave university_raw, uma
###                                        linha por grafia, com
###                                        dom_openalex_id, n_ids,
###                                        dom_share e is_ambiguous.
###
### A segunda e a tabela por grafia pedida; as colunas extras existem
### para ela nao poder mentir em silencio. O precedente e a nota 9 do
### 8d: nunca consumir dom_openalex_id sem ler dom_share -- o caso
### registrado e o IFSP, 35 ids, dom_share 0,24, e a regra do dominante
### escolhe a PETROBRAS.
###
### -----------------------------------------------------------------
### AS SEIS ESTRATEGIAS, EM ORDEM DE PRECEDENCIA
### -----------------------------------------------------------------
### A precedencia segue a ordem historica de construcao, porque cada
### uma foi desenhada como residuo da anterior. Uma coluna por
### estrategia mais um flag by_*, para a composicao seguir reversivel
### -- a regra da pasta e guardar flag, nao filtrar.
###
###   1 oa_safe      rsid_openalex_safe_map (8f)      rsid    safe = 1
###   2 oa_8d        rsid_openalex_id_crosswalk (8d)  rsid+raw   --
###   3 oa_shraw     shanghai_raw_crosswalk (16b)     raw     by_acronym
###                                                           = 0 OR
###                                                           acr_label
###                                                           = 'OK'
###   4 oa_shname    shanghai_rsid_name_map           rsid    keep = 1
###   5 oa_8i_fold   unmatched_school_openalex_map    rsid    source =
###                  (8i)                                     'fold'
###   6 oa_norsid    bracos da rodada 2 do 8l         raw     config
###                                                           conservadora
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Le a pasta de educacao e seis parquet locais,
###    escreve dois parquet e um CSV. Ainda e prep/; nao para SEDAP.
### 2. OS BRACOS DA ESTRATEGIA 6 SAO COPIA VERBATIM DO 8l, macros
###    fs/dsh/mj/core inclusive. E o mesmo arranjo que o 8a declara no
###    proprio cabecalho -- "the matcher CTEs here are copied from that
###    script unchanged". AS DUAS COPIAS TEM DE FICAR EM SINCRONIA: a
###    validacao repontua os conjuntos dev2 e holdout2 do 8l atraves
###    desta copia e para se os numeros congelados nao sairem.
###    Os bracos prefix e idf do 8l NAO entram -- estao desligados por
###    padrao la (2/3 e 19% de precisao), e nao construir as tabelas
###    deles poupa o indice de IDF sobre 1,4 milhao de grafias.
### 3. A ESTRATEGIA 3 AINDA CONTEM JULGAMENTO HUMANO. O braco de sigla
###    do 16b e gateado na revisao a mao do 16a (acr_label = 'OK'), que
###    e escrita por LLM como a do 8i. Fica porque e o filtro
###    recomendado e documentado, e precede este trabalho, mas
###    by_shraw_acronym sai como flag proprio para poder ser removido
###    com um WHERE.
### 4. A PRECISAO DA ESTRATEGIA 6 NAO SE TRANSFERE PARA A TABELA TODA.
###    Os 89,7% do 8l foram medidos em entradas SEM rsid e SEM
###    university_name. A coluna in_norsid_domain separa o dominio
###    medido da extrapolacao. Fora do dominio, o numero e desconhecido.
### 5. CONFLITO ENTRE ESTRATEGIAS E SINAL, NAO RUIDO. n_ids_distinct e
###    conflict guardam quando duas estrategias falam e discordam na
###    mesma chave. Nao ha desempate: a precedencia decide qual entra
###    em openalex_id, e o conflito fica registrado.
### 6. NAO EXISTE PRIMITIVA "E ENSINO MEDIO" nesta pasta. O rx_hs do
###    script 7 existe SO como negativa dentro de sql_is_bachelor, e o
###    degree = 'High School' da Revelio e inutil como sinal positivo:
###    numa amostra de 1.000 linhas brasileiras, TODAS as 93 rotuladas
###    High School eram bacharelado, nenhuma era ensino medio. Por isso
###    o bloco B usa sql_shanghai_level IN ('bachelor','master','phd'),
###    escolha do usuario, que remove ensino medio E TAMBEM pos-doc,
###    intercambio, extensao, tecnologo/CST e o inclassificavel.
### 7. rsid E NULO EM MUITA LINHA, entao a tabela carrega rsid_key =
###    coalesce(rsid, 2147483647), o sentinela que o 8h ja usa, para o
###    consumidor juntar sem IS NOT DISTINCT FROM.
### 8b. O CROSSWALK NAO COBRE LINHA COM GRAFIA VAZIA, e nao pode:
###    a chave e a grafia. Sao 7.158 linhas de educacao com
###    university_raw nulo ou em branco. O 8h contava essas linhas no
###    escopo dele e casava parte delas pelos mapas de rsid, entao a
###    regressao contra o 8h RECONCILIA em vez de igualar: minhas
###    contagens mais as das linhas de grafia vazia tem de dar
###    exatamente os numeros do 8h. Isso pega erro de juncao sem
###    exigir que o produto cubra o que a chave dele nao alcanca.
### 8. A PARTE DA EDUCACAO NAO TEM EXTENSAO .parquet (o UNLOAD do
###    Athena nomeia <query-id>_<uuid>). read_parquet('<dir>/*'), nunca
###    '*.parquet' -- este ultimo casa nada em silencio.
### 10. TODO id DE ENTRADA PASSA POR UM TESTE DE FORMA, ^I[0-9]+$, e o
###    que nao passa e REJEITADO e contado. Isso nao e paranoia: a
###    asserção pegou um defeito real e anterior a este script. A linha
###    de rank 701 do shanghai_ranking_oa.parquet traz o NOME no campo
###    OA_key -- 'RUTGERS UNIVERSITY - NEWARK' em vez de um I-numero --
###    e o 16b propagou fielmente, contaminando 1 grafia, 248 linhas de
###    educacao e 229 usuarios. O defeito e a montante, no arquivo do
###    ranking; aqui ele so nao entra no produto. Se n_rejeitados subir,
###    o arquivo de origem mudou e alguem tem de olhar.
### 9. sql_shanghai_level E SQL DO TRINO e chama regexp_like(). O shim
###    do DuckDB abaixo e obrigatorio.
###
####################################################################

rm(list = ls()); gc()
options(width = 200)

for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop(sprintf("Pacote ausente: %s", p), call. = FALSE)
  }
}
library(DBI)
library(duckdb)

####################################################################
### Parametros
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
ed_dir  <- file.path(coh_dir, "obmep_candidates_step_1_education")

safe_pq  <- file.path(coh_dir, "rsid_openalex_safe_map.parquet")
cw8d_pq  <- file.path(coh_dir, "rsid_openalex_id_crosswalk.parquet")
shraw_pq <- file.path(coh_dir, "shanghai_raw_crosswalk.parquet")
shnam_pq <- file.path(coh_dir, "shanghai_rsid_name_map.parquet")
map8i_pq <- file.path(coh_dir, "unmatched_school_openalex_map.parquet")
inst_pq  <- file.path(coh_dir, "oa_institution_cache.parquet")
cand_pq  <- file.path(coh_dir, "oa_institution_cand_names.parquet")

out_pair <- file.path(coh_dir, "revelio_oa_crosswalk.parquet")
out_raw  <- file.path(coh_dir, "revelio_oa_crosswalk_by_raw.parquet")
out_cov  <- file.path(coh_dir, "revelio_oa_coverage.csv")

deg_path <- Sys.getenv("OBMEP_DEGREE_PATTERNS",
                       unset = file.path("prep", "building_external_data",
                                         "br_degree_patterns.R"))

min_seg <- 3L   # 8a, 16 e 8l usam 3
rsid_na <- 2147483647L

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")
tmp_dir   <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_oa_crosswalk")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

# Medidos. Divergencia e sinal de dado novo -- warning, nao stop.
# 15.705.579, nao 15.712.737: a diferenca sao as 7.158 linhas de
# grafia vazia, que a nota 8b explica e este produto nao chaveia.
exp_ed_rows   <- 15705579L
# 1.417.851, nao 1.417.852: a contagem antiga incluia o proprio valor
# vazio como grafia distinta.
exp_raw_str   <- 1417851L
# 3.275, nao 1.062: os 1.062 do cabecalho foram medidos com SO os tres
# mapas por rsid. A composicao completa acrescenta 8d, shanghai_raw e
# norsid_8l, e cada estrategia nova pode dar a uma grafia um id que as
# outras nao davam -- entao a ambiguidade por grafia SOBE. Os 1.062
# seguem certos para o subconjunto que os mediu.
exp_ambiguous <- 3275L
# Nota 10: um unico id malformado conhecido, o Rutgers-Newark do 16b.
exp_rejected  <- 1L

# Regressao contra o 8h, na populacao no escopo dele. E a checagem mais
# forte de que a composicao esta ligada certo (nota 2 do 8h).
exp_8h <- c(safe_map = 5104434L, shanghai_raw = 503090L,
            shanghai_name = 63635L, crosswalk_8d = 1917L)

# Numeros congelados do 8l, para pinar a copia dos bracos (nota 2).
exp_dev2_ok      <- 50L
exp_hold2_ok     <- 131L
exp_hold2_propos <- 146L

stopifnot(dir.exists(ed_dir),
          length(Sys.glob(file.path(ed_dir, "*"))) > 0L,
          file.exists(safe_pq), file.exists(cw8d_pq), file.exists(shraw_pq),
          file.exists(shnam_pq), file.exists(map8i_pq), file.exists(inst_pq),
          file.exists(cand_pq), file.exists(deg_path))

source(deg_path)
stopifnot(exists("sql_shanghai_level"), exists("rx_mba"))

fw <- function(z) gsub("'", "''", z)

####################################################################
### Conexao e macros (nota 2: copia verbatim do 8l)
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

# Nota 9.
dbExecute(con, "CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)")

# A dobra padrao da pasta, identica a de 16, 16a, 16b, 19, 20 e 8i.
dbExecute(con, "CREATE MACRO fs(s) AS lower(strip_accents(trim(s)))")
dbExecute(con, "
CREATE MACRO dsh(s) AS replace(replace(s, chr(8211), '-'), chr(8212), '-')")
dbExecute(con, "
CREATE MACRO mj(s) AS
  replace(replace(replace(replace(replace(replace(replace(replace(
  replace(replace(replace(replace(replace(replace(replace(replace(s,
    'u00e0','a'),'u00e1','a'),'u00e2','a'),'u00e3','a'),'u00e4','a'),
    'u00e7','c'),'u00e8','e'),'u00e9','e'),'u00ea','e'),'u00ec','i'),
    'u00ed','i'),'u00f3','o'),'u00f4','o'),'u00f5','o'),'u00fa','u'),
    'u00fc','u')")

type_tok <- c("universidade","university","universidad","universitario",
  "universitaria","universitario","faculdade","faculdades","instituto",
  "institute","institucao","escola","school","college","centro","center",
  "centre","ensino","superior","educacional","educational","the","del",
  "estadual","federal","state","nacional","national",
  "univercidade","universitiy","univesidade","faculadade")
dbExecute(con, sprintf("
CREATE MACRO core_tok(s) AS list_sort(list_filter(
  string_split_regex(fs(s), '[^a-z0-9]+'),
  x -> length(x) >= 3 AND NOT list_contains(['%s'], x)))",
  paste(type_tok, collapse = "','")))
dbExecute(con, "CREATE MACRO core(s) AS array_to_string(core_tok(s), ' ')")
dbExecute(con, "CREATE MACRO core_n(s) AS len(core_tok(s))")

dbExecute(con, sprintf(
  "CREATE OR REPLACE VIEW ins AS SELECT * FROM read_parquet('%s')", fw(inst_pq)))
dbExecute(con, sprintf(
  "CREATE OR REPLACE VIEW cand AS SELECT * FROM read_parquet('%s')", fw(cand_pq)))

dbExecute(con, "
CREATE OR REPLACE TABLE ix_name AS
SELECT nm, any_value(oa_id) AS oa_id
FROM cand WHERE nm IS NOT NULL AND length(nm) >= 2
GROUP BY nm HAVING count(DISTINCT oa_id) = 1")

dbExecute(con, "
CREATE OR REPLACE TABLE ix_core AS
SELECT core(display_name) AS ck, any_value(oa_id) AS oa_id
FROM ins WHERE display_name IS NOT NULL AND length(core(display_name)) >= 4
GROUP BY core(display_name) HAVING count(DISTINCT oa_id) = 1")

####################################################################
### Step 1 -- os pares (university_raw, rsid) que de fato ocorrem
####################################################################

message("Step 1: pares (university_raw, rsid) da pasta de educacao ...")

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE ed AS
SELECT user_id, university_raw, university_name, rsid, degree, degree_raw,
       lower(trim(coalesce(degree_raw, ''))) AS dr
FROM read_parquet('%s/*')
WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''", ed_dir))

ed_n <- dbGetQuery(con, "SELECT count(*) AS n FROM ed")$n

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE pairs AS
SELECT university_raw, rsid, coalesce(rsid, %d) AS rsid_key,
       count(*) AS n_rows, count(DISTINCT user_id) AS n_users,
       CAST(max(CASE WHEN university_name IS NULL OR trim(university_name) = ''
                     THEN 0 ELSE 1 END) AS INTEGER) AS has_name
FROM ed GROUP BY university_raw, rsid", rsid_na))

dbExecute(con, "
CREATE OR REPLACE TABLE s AS
SELECT DISTINCT university_raw, fs(university_raw) AS rf FROM pairs")

n_str <- dbGetQuery(con, "SELECT count(*) AS n FROM s")$n
cat(sprintf("  linhas de educacao com grafia : %s\n", format(ed_n, big.mark = ",")))
cat(sprintf("  grafias distintas             : %s\n", format(n_str, big.mark = ",")))
cat(sprintf("  pares (grafia, rsid)          : %s\n",
            format(dbGetQuery(con, "SELECT count(*) AS n FROM pairs")$n,
                   big.mark = ",")))

####################################################################
### Step 2 -- tabelas de derivacao do 8l (copia verbatim, nota 2)
####################################################################

message("Step 2: derivacoes dos bracos da rodada 2 ...")

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE seg AS
SELECT DISTINCT university_raw, trim(part) AS part FROM (
  SELECT university_raw, unnest(string_split_regex(
           regexp_replace(regexp_replace(dsh(rf), '[/()|]', '#', 'g'),
                          ' - ', '#', 'g'), '#')) AS part
  FROM s
) WHERE length(trim(part)) >= %d", min_seg))

dbExecute(con, "
CREATE OR REPLACE TABLE mjs AS
SELECT university_raw, mj(rf) AS mf FROM s WHERE mj(rf) <> rf")

dbExecute(con, "
CREATE OR REPLACE TABLE par AS
SELECT university_raw, base FROM (
  SELECT university_raw,
         CASE
           WHEN regexp_matches(rf, ' d[ao]s? universidade d[aeo]s? ')
             THEN 'universidade ' || regexp_extract(rf,
                  ' d[ao]s? universidade (d[aeo]s? .+)$', 1)
           WHEN regexp_matches(rf, '(^|[^a-z])university of ')
             THEN 'university of ' || regexp_extract(rf,
                  'university of (.+)$', 1)
           WHEN regexp_matches(rf, '(^|[^a-z])universidad de ')
             THEN 'universidad de ' || regexp_extract(rf,
                  'universidad de (.+)$', 1)
         END AS base
  FROM s
) WHERE base IS NOT NULL AND length(base) >= 12")

dbExecute(con, "
CREATE OR REPLACE TABLE camp AS
SELECT university_raw, base FROM (
  SELECT university_raw,
         trim(regexp_replace(rf, '( de | -+ ?)[a-z]+$', '')) AS base FROM s
  UNION ALL
  SELECT university_raw,
         trim(regexp_replace(rf, '( de | -+ ?)[a-z]+ [a-z]+$', '')) AS base FROM s
) WHERE length(base) >= 6")

####################################################################
### Step 3 -- a estrategia 6, composta na ordem congelada do 8l
####################################################################

message("Step 3: rodando os seis bracos conservadores ...")

arm_sql <- list(
  whole = "SELECT s.university_raw, i.oa_id FROM s JOIN ix_name i ON i.nm = s.rf",
  segment = "
    SELECT g.university_raw, any_value(i.oa_id) AS oa_id
    FROM seg g JOIN ix_name i ON i.nm = g.part
    GROUP BY g.university_raw HAVING count(DISTINCT i.oa_id) = 1",
  core = "
    SELECT s.university_raw, c.oa_id
    FROM s JOIN ix_core c ON c.ck = core(s.university_raw)
    WHERE length(core(s.university_raw)) >= 4
      AND core_n(s.university_raw) >= 2",
  campus = "
    SELECT c.university_raw, i.oa_id
    FROM camp c JOIN ix_name i ON i.nm = c.base
    WHERE length(c.base) >= 6
    QUALIFY row_number() OVER (PARTITION BY c.university_raw
                               ORDER BY length(c.base) DESC) = 1",
  mojibake = "
    SELECT m.university_raw, any_value(i.oa_id) AS oa_id
    FROM mjs m JOIN ix_name i ON i.nm = m.mf
    GROUP BY m.university_raw HAVING count(DISTINCT i.oa_id) = 1",
  parent = "
    SELECT p.university_raw, any_value(i.oa_id) AS oa_id
    FROM par p JOIN ix_name i ON i.nm = p.base
    GROUP BY p.university_raw HAVING count(DISTINCT i.oa_id) = 1")

arm_order <- c("whole", "segment", "core", "campus", "mojibake", "parent")

res <- list()
for (a in arm_order) {
  d <- dbGetQuery(con, arm_sql[[a]])
  d <- d[!is.na(d$oa_id), c("university_raw", "oa_id"), drop = FALSE]
  res[[a]] <- data.frame(university_raw = d$university_raw, oa_id = d$oa_id,
                         arm = rep(a, nrow(d)), pri = match(a, arm_order),
                         stringsAsFactors = FALSE)
  cat(sprintf("  %-9s %s grafias\n", a, format(nrow(d), big.mark = ",")))
}
nors <- do.call(rbind, res)
nors <- nors[order(nors$pri), ]
nors <- nors[!duplicated(nors$university_raw), c("university_raw", "oa_id", "arm")]
names(nors) <- c("university_raw", "oa_norsid", "norsid_arm")
dbWriteTable(con, "m_norsid", nors, overwrite = TRUE)
cat(sprintf("  estrategia 6 total: %s grafias\n",
            format(nrow(nors), big.mark = ",")))

####################################################################
### Step 4 -- as cinco estrategias que ja existiam
####################################################################

message("Step 4: carregando as cinco estrategias anteriores ...")

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE m_safe AS
SELECT rsid, any_value(openalex_id) AS oa_safe
FROM read_parquet('%s')
WHERE safe = 1 AND regexp_matches(openalex_id, '^I[0-9]+$')
GROUP BY rsid", fw(safe_pq)))

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE m_8d AS
SELECT rsid, university_raw, any_value(openalex_id) AS oa_8d
FROM read_parquet('%s')
WHERE regexp_matches(openalex_id, '^I[0-9]+$')
GROUP BY rsid, university_raw", fw(cw8d_pq)))

# Nota 3: o filtro recomendado do 16b, com o flag da sigla separado.
dbExecute(con, sprintf("
CREATE OR REPLACE TABLE m_shraw AS
SELECT university_raw,
       any_value(openalex_id) AS oa_shraw,
       CAST(max(by_acronym) AS INTEGER) AS by_shraw_acronym
FROM read_parquet('%s')
WHERE (by_acronym = 0 OR acr_label = 'OK')
  AND regexp_matches(openalex_id, '^I[0-9]+$')
GROUP BY university_raw", fw(shraw_pq)))

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE m_shname AS
SELECT rsid, any_value(openalex_id) AS oa_shname
FROM read_parquet('%s')
WHERE keep = 1 AND regexp_matches(openalex_id, '^I[0-9]+$')
GROUP BY rsid", fw(shnam_pq)))

# O julgamento manual fica FORA: so source = 'fold'.
dbExecute(con, sprintf("
CREATE OR REPLACE TABLE m_8i AS
SELECT rsid, any_value(openalex_id) AS oa_8i_fold
FROM read_parquet('%s')
WHERE source = 'fold' AND regexp_matches(openalex_id, '^I[0-9]+$')
GROUP BY rsid", fw(map8i_pq)))

# Nota 10: quantos ids de entrada foram rejeitados por forma.
rej <- dbGetQuery(con, sprintf("
SELECT 'safe_map' AS mapa, count(*) AS n FROM read_parquet('%s')
  WHERE safe = 1 AND NOT regexp_matches(coalesce(openalex_id,''), '^I[0-9]+$')
UNION ALL SELECT 'crosswalk_8d', count(*) FROM read_parquet('%s')
  WHERE NOT regexp_matches(coalesce(openalex_id,''), '^I[0-9]+$')
UNION ALL SELECT 'shanghai_raw', count(*) FROM read_parquet('%s')
  WHERE (by_acronym = 0 OR acr_label = 'OK')
    AND NOT regexp_matches(coalesce(openalex_id,''), '^I[0-9]+$')
UNION ALL SELECT 'shanghai_name', count(*) FROM read_parquet('%s')
  WHERE keep = 1 AND NOT regexp_matches(coalesce(openalex_id,''), '^I[0-9]+$')
UNION ALL SELECT 'school_fold_8i', count(*) FROM read_parquet('%s')
  WHERE source = 'fold' AND NOT regexp_matches(coalesce(openalex_id,''), '^I[0-9]+$')",
  fw(safe_pq), fw(cw8d_pq), fw(shraw_pq), fw(shnam_pq), fw(map8i_pq)))
n_rej <- sum(rej$n)
if (n_rej > 0L) {
  cat("  ids rejeitados por forma (nota 10):\n")
  print(rej[rej$n > 0L, ], row.names = FALSE)
}
if (n_rej > exp_rejected) {
  stop(sprintf("%d ids malformados nos mapas de entrada, esperado %d. ",
               n_rej, exp_rejected),
       "O arquivo de origem mudou -- olhe antes de seguir.", call. = FALSE)
}

n_8i_fold <- dbGetQuery(con, "SELECT count(*) AS n FROM m_8i")$n
n_8i_llm  <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM read_parquet('%s') WHERE source <> 'fold'",
  fw(map8i_pq)))$n
cat(sprintf("  8i: %d rsids de dobra usados, %d de julgamento DESCARTADOS\n",
            n_8i_fold, n_8i_llm))

####################################################################
### Step 5 -- a tabela fiel, chave (university_raw, rsid)
####################################################################

message("Step 5: compondo o crosswalk fiel ...")

dbExecute(con, "
CREATE OR REPLACE TABLE xw AS
WITH j AS (
  SELECT p.university_raw, p.rsid, p.rsid_key, p.n_rows, p.n_users, p.has_name,
         sa.oa_safe, d8.oa_8d, sr.oa_shraw, sr.by_shraw_acronym,
         sn.oa_shname, i8.oa_8i_fold, nr.oa_norsid, nr.norsid_arm
  FROM pairs p
  LEFT JOIN m_safe   sa ON p.rsid = sa.rsid
  LEFT JOIN m_8d     d8 ON p.rsid = d8.rsid AND p.university_raw = d8.university_raw
  LEFT JOIN m_shraw  sr ON p.university_raw = sr.university_raw
  LEFT JOIN m_shname sn ON p.rsid = sn.rsid
  LEFT JOIN m_8i     i8 ON p.rsid = i8.rsid
  LEFT JOIN m_norsid nr ON p.university_raw = nr.university_raw
)
SELECT university_raw, rsid, rsid_key,
       oa_safe, oa_8d, oa_shraw, oa_shname, oa_8i_fold, oa_norsid,
       CAST(CASE WHEN oa_safe    IS NOT NULL THEN 1 ELSE 0 END AS INTEGER) AS by_safe,
       CAST(CASE WHEN oa_8d      IS NOT NULL THEN 1 ELSE 0 END AS INTEGER) AS by_8d,
       CAST(CASE WHEN oa_shraw   IS NOT NULL THEN 1 ELSE 0 END AS INTEGER) AS by_shraw,
       CAST(CASE WHEN oa_shname  IS NOT NULL THEN 1 ELSE 0 END AS INTEGER) AS by_shname,
       CAST(CASE WHEN oa_8i_fold IS NOT NULL THEN 1 ELSE 0 END AS INTEGER) AS by_8i_fold,
       CAST(CASE WHEN oa_norsid  IS NOT NULL THEN 1 ELSE 0 END AS INTEGER) AS by_norsid,
       CAST(coalesce(by_shraw_acronym, 0) AS INTEGER) AS by_shraw_acronym,
       norsid_arm,
       coalesce(oa_safe, oa_8d, oa_shraw, oa_shname, oa_8i_fold, oa_norsid)
         AS openalex_id,
       CASE WHEN oa_safe    IS NOT NULL THEN 'safe_map'
            WHEN oa_8d      IS NOT NULL THEN 'crosswalk_8d'
            WHEN oa_shraw   IS NOT NULL THEN 'shanghai_raw'
            WHEN oa_shname  IS NOT NULL THEN 'shanghai_name'
            WHEN oa_8i_fold IS NOT NULL THEN 'school_fold_8i'
            WHEN oa_norsid  IS NOT NULL THEN 'norsid_8l'
       END AS match_source,
       CAST(len(list_distinct(list_filter(
              [oa_safe, oa_8d, oa_shraw, oa_shname, oa_8i_fold, oa_norsid],
              x -> x IS NOT NULL))) AS INTEGER) AS n_ids_distinct,
       CAST(CASE WHEN len(list_distinct(list_filter(
              [oa_safe, oa_8d, oa_shraw, oa_shname, oa_8i_fold, oa_norsid],
              x -> x IS NOT NULL))) > 1 THEN 1 ELSE 0 END AS INTEGER) AS conflict,
       -- Nota 4: onde a precisao medida do 8l vale.
       CAST(CASE WHEN rsid IS NULL AND has_name = 0 THEN 1 ELSE 0 END
            AS INTEGER) AS in_norsid_domain,
       n_rows, n_users
FROM j")

####################################################################
### Step 6 -- a tabela por grafia, com dominante e ambiguidade
####################################################################

message("Step 6: colapsando por grafia ...")

dbExecute(con, "
CREATE OR REPLACE TABLE xw_raw AS
WITH e AS (
  SELECT university_raw, openalex_id, sum(n_rows) AS w
  FROM xw GROUP BY university_raw, openalex_id
),
d AS (
  SELECT university_raw,
         arg_max(openalex_id, w) AS dom_openalex_id,
         sum(CASE WHEN openalex_id IS NOT NULL THEN w ELSE 0 END) AS w_matched,
         sum(w) AS w_all,
         max(CASE WHEN openalex_id IS NOT NULL THEN w ELSE 0 END) AS w_dom,
         CAST(count(DISTINCT openalex_id) AS INTEGER) AS n_ids
  FROM e GROUP BY university_raw
)
SELECT d.university_raw, d.dom_openalex_id, d.n_ids,
       CASE WHEN d.w_matched > 0 THEN d.w_dom / d.w_matched END AS dom_share,
       CAST(CASE WHEN d.n_ids > 1 THEN 1 ELSE 0 END AS INTEGER) AS is_ambiguous,
       x.n_rows, x.n_users, x.n_matched_rows,
       CAST(x.n_rsid AS INTEGER) AS n_rsid,
       x.by_safe, x.by_8d, x.by_shraw, x.by_shname, x.by_8i_fold, x.by_norsid
FROM d
JOIN (SELECT university_raw, sum(n_rows) AS n_rows, sum(n_users) AS n_users,
             sum(CASE WHEN openalex_id IS NOT NULL THEN n_rows ELSE 0 END)
               AS n_matched_rows,
             count(DISTINCT rsid_key) AS n_rsid,
             CAST(max(by_safe) AS INTEGER) AS by_safe,
             CAST(max(by_8d) AS INTEGER) AS by_8d,
             CAST(max(by_shraw) AS INTEGER) AS by_shraw,
             CAST(max(by_shname) AS INTEGER) AS by_shname,
             CAST(max(by_8i_fold) AS INTEGER) AS by_8i_fold,
             CAST(max(by_norsid) AS INTEGER) AS by_norsid
      FROM xw GROUP BY university_raw) x USING (university_raw)")

####################################################################
### Step 7 -- as estatisticas (blocos A, B, C)
####################################################################

message("Step 7: estatisticas de cobertura ...")

# Nota 8b: as linhas de grafia vazia, que o crosswalk nao pode cobrir,
# contadas em separado para a reconciliacao com o 8h.
dbExecute(con, sprintf("
CREATE OR REPLACE TABLE blank_raw AS
SELECT e.rsid, %s AS lvl, e.degree,
       (e.degree = 'MBA' OR regexp_like(e.dr, '%s')) AS is_mba
FROM (SELECT rsid, degree, degree_raw,
             lower(trim(coalesce(degree_raw, ''))) AS dr
      FROM read_parquet('%s/*')
      WHERE university_raw IS NULL OR trim(university_raw) = '') e",
  sql_shanghai_level, rx_mba, ed_dir))

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE rows_lvl AS
SELECT e.user_id, e.university_raw, coalesce(e.rsid, %d) AS rsid_key,
       e.degree,
       %s AS lvl,
       (e.degree = 'MBA' OR regexp_like(e.dr, '%s')) AS is_mba
FROM ed e", rsid_na, sql_shanghai_level, rx_mba))

dbExecute(con, "
CREATE OR REPLACE TABLE rows_oa AS
SELECT r.user_id, r.lvl, r.is_mba, x.openalex_id, x.match_source
FROM rows_lvl r
LEFT JOIN (SELECT university_raw, rsid_key, openalex_id, match_source FROM xw)
  x USING (university_raw, rsid_key)")

blk <- function(nm, where) {
  dbGetQuery(con, sprintf("
    SELECT '%s' AS bloco, '%s' AS celula,
           count(*) AS n_rows, count(DISTINCT user_id) AS n_users,
           sum(CASE WHEN openalex_id IS NOT NULL THEN 1 ELSE 0 END) AS n_rows_oa,
           count(DISTINCT CASE WHEN openalex_id IS NOT NULL THEN user_id END)
             AS n_users_oa
    FROM rows_oa WHERE %s", nm[1], nm[2], where))
}

cov <- rbind(
  blk(c("A. todas as entradas", "todas"), "TRUE"),
  blk(c("B. so grau (bachelor/master/phd)", "todos os graus"),
      "lvl IN ('bachelor','master','phd')"),
  blk(c("C. por nivel", "bachelor"), "lvl = 'bachelor'"),
  blk(c("C. por nivel", "master"),   "lvl = 'master'"),
  blk(c("C. por nivel", "phd"),      "lvl = 'phd'"))
cov$share_rows  <- cov$n_rows_oa  / cov$n_rows
cov$share_users <- cov$n_users_oa / cov$n_users

src <- dbGetQuery(con, "
SELECT coalesce(match_source, '(sem casamento)') AS match_source,
       count(*) AS n_rows, count(DISTINCT user_id) AS n_users
FROM rows_oa GROUP BY 1 ORDER BY n_rows DESC")

####################################################################
### Validacao
####################################################################

message("Validacao ...")

# 1. Regressao contra o 8h. O escopo do 8h e "by_level OU by_degree",
#    com MBA fora do braco de mestrado -- reproduzido aqui letra por
#    letra. E as linhas de grafia vazia entram pela reconciliacao da
#    nota 8b, porque o 8h as contava e este produto nao as chaveia.
h8_scope <- "(lvl IN ('bachelor','master','phd')
              AND NOT (lvl = 'master' AND is_mba))
             OR degree IN ('Bachelor','Master','Doctor')"

h8 <- dbGetQuery(con, sprintf("
SELECT x.match_source, count(*) AS n
FROM (SELECT university_raw, rsid_key FROM rows_lvl WHERE %s) q
JOIN (SELECT university_raw, rsid_key, match_source FROM xw)
  x USING (university_raw, rsid_key)
WHERE x.match_source IN ('safe_map','shanghai_raw','shanghai_name','crosswalk_8d')
GROUP BY 1", h8_scope))

# Grafia vazia: shanghai_raw e crosswalk_8d precisam da grafia, entao
# so os mapas por rsid podem casar la.
h8_blank <- dbGetQuery(con, sprintf("
SELECT sum(CASE WHEN sa.oa_safe IS NOT NULL THEN 1 ELSE 0 END) AS safe_map,
       sum(CASE WHEN sa.oa_safe IS NULL AND sn.oa_shname IS NOT NULL
                THEN 1 ELSE 0 END) AS shanghai_name
FROM blank_raw b
LEFT JOIN m_safe   sa ON b.rsid = sa.rsid
LEFT JOIN m_shname sn ON b.rsid = sn.rsid
WHERE %s", h8_scope))

# Terceiro termo: as linhas que o 8h contava como casadas e que a
# guarda de forma REJEITA agora (nota 10). Nao e perda, e correcao --
# o 8h aceitava 'RUTGERS UNIVERSITY - NEWARK' como se fosse um id.
h8_shape <- dbGetQuery(con, sprintf("
SELECT count(*) AS n
FROM (SELECT university_raw FROM rows_lvl WHERE %s) q
JOIN (SELECT university_raw FROM read_parquet('%s')
      WHERE (by_acronym = 0 OR acr_label = 'OK')
        AND NOT regexp_matches(coalesce(openalex_id, ''), '^I[0-9]+$'))
  r USING (university_raw)", h8_scope, fw(shraw_pq)))$n

got   <- setNames(h8$n, h8$match_source)
blank <- c(safe_map = as.integer(h8_blank$safe_map),
           shanghai_name = as.integer(h8_blank$shanghai_name),
           shanghai_raw = 0L, crosswalk_8d = 0L)
shape <- c(safe_map = 0L, shanghai_name = 0L,
           shanghai_raw = as.integer(h8_shape), crosswalk_8d = 0L)
bad <- character(0)
for (k in names(exp_8h)) {
  g <- if (k %in% names(got)) as.integer(got[[k]]) else 0L
  if (g + blank[[k]] + shape[[k]] != exp_8h[[k]]) {
    bad <- c(bad, sprintf(
      "%s: %d aqui + %d grafia vazia + %d rejeitado por forma = %d, 8h diz %d",
      k, g, blank[[k]], shape[[k]], g + blank[[k]] + shape[[k]], exp_8h[[k]]))
  }
}
if (length(bad) > 0L) {
  cat("\n"); cat(paste0("  ", bad, collapse = "\n"), "\n")
  stop("regressao contra o 8h nao reconcilia.", call. = FALSE)
}
cat(sprintf("  [ok] regressao 8h reconcilia: %s de grafia vazia + %s rejeitadas por forma\n",
            format(sum(blank), big.mark = ","), format(sum(shape), big.mark = ",")))

# 2. Nenhum id inventado.
gh <- dbGetQuery(con, "
WITH a AS (
  SELECT DISTINCT unnest([oa_safe, oa_8d, oa_shraw, oa_shname,
                          oa_8i_fold, oa_norsid]) AS oa FROM xw
)
SELECT count(*) AS n FROM a LEFT JOIN ins i ON a.oa = i.oa_id
WHERE a.oa IS NOT NULL AND i.oa_id IS NULL")$n
if (gh > 0L) stop(gh, " openalex_id nao existem no snapshot.", call. = FALSE)
cat("  [ok] todo openalex_id emitido existe no snapshot\n")

# 3. Grao.
v <- dbGetQuery(con, "
SELECT (SELECT count(*) FROM xw) AS n_xw,
       (SELECT count(*) FROM (SELECT DISTINCT university_raw, rsid_key FROM xw)) AS n_key,
       (SELECT count(*) FROM xw_raw) AS n_raw,
       (SELECT count(DISTINCT university_raw) FROM xw) AS n_str,
       (SELECT sum(is_ambiguous) FROM xw_raw) AS n_amb,
       (SELECT sum(conflict) FROM xw) AS n_conf")
if (v$n_xw != v$n_key) stop("crosswalk fiel nao e unico em (grafia, rsid_key).")
if (v$n_raw != v$n_str) stop("crosswalk por grafia nao e unico em grafia.")
cat(sprintf("  [ok] grao: %s pares, %s grafias\n",
            format(v$n_xw, big.mark = ","), format(v$n_raw, big.mark = ",")))
if (v$n_amb != exp_ambiguous) {
  warning(sprintf("ambiguas: esperado %d, obtido %d", exp_ambiguous, v$n_amb),
          call. = FALSE)
}

# 4. O julgamento do 8i mesmo fora.
jl <- dbGetQuery(con, sprintf("
SELECT count(*) AS n FROM xw
WHERE oa_8i_fold IS NOT NULL AND rsid IN (
  SELECT rsid FROM read_parquet('%s') WHERE source <> 'fold')", fw(map8i_pq)))$n
if (jl > 0L) stop(jl, " pares usam rsid julgado a mao do 8i.", call. = FALSE)
cat(sprintf("  [ok] os %d rsids julgados a mao do 8i estao fora\n", n_8i_llm))

# 4b. A COPIA DOS BRACOS AINDA E A DO 8l (nota 2). Repontua os
#     conjuntos congelados dev2 e holdout2 atraves de m_norsid -- se a
#     copia divergir do 8l, estes numeros mudam e o script para.
for (nm in c("dev2", "holdout2")) {
  lp <- file.path(coh_dir, sprintf("norsid_match_labels_%s.csv", nm))
  sp <- file.path(coh_dir, sprintf("norsid_match_%s.parquet", nm))
  if (!file.exists(lp) || !file.exists(sp)) {
    warning("conjunto ", nm, " do 8l ausente; a copia dos bracos nao foi pinada.",
            call. = FALSE)
    next
  }
  lb <- read.csv(lp, stringsAsFactors = FALSE, fileEncoding = "UTF-8")
  lb$label <- trimws(ifelse(is.na(lb$label), "", lb$label))
  dbWriteTable(con, "chk_lab", lb[, c("university_raw", "label")],
               overwrite = TRUE)
  z <- dbGetQuery(con, sprintf("
    SELECT sum(CASE WHEN n.oa_norsid IS NOT NULL THEN 1 ELSE 0 END) AS propostos,
           sum(CASE WHEN n.oa_norsid = l.label THEN 1 ELSE 0 END) AS corretos
    FROM (SELECT university_raw FROM read_parquet('%s')) q
    JOIN chk_lab l USING (university_raw)
    LEFT JOIN m_norsid n USING (university_raw)", fw(sp)))
  e_ok <- if (nm == "dev2") exp_dev2_ok else exp_hold2_ok
  if (as.integer(z$corretos) != e_ok ||
      (nm == "holdout2" && as.integer(z$propostos) != exp_hold2_propos)) {
    stop(sprintf("a copia dos bracos divergiu do 8l em %s: %d propostos, %d corretos (esperado %d)",
                 nm, z$propostos, z$corretos, e_ok), call. = FALSE)
  }
  cat(sprintf("  [ok] copia dos bracos reproduz o 8l em %s (%d/%d)\n",
              nm, z$corretos, z$propostos))
}

# 5. Coerencia das estatisticas: B = soma de C.
b <- cov[cov$celula == "todos os graus", ]
c3 <- cov[cov$bloco == "C. por nivel", ]
if (b$n_rows != sum(c3$n_rows) || b$n_rows_oa != sum(c3$n_rows_oa)) {
  stop("bloco B nao e a soma do bloco C.", call. = FALSE)
}
cat("  [ok] bloco B = soma do bloco C\n")

drift <- function(nm, g, e) {
  if (g != e) warning(sprintf("%s: esperado %d, obtido %d", nm, e, g),
                      call. = FALSE)
}
drift("linhas de educacao", ed_n, exp_ed_rows)
drift("grafias distintas", n_str, exp_raw_str)

####################################################################
### Gravacao
####################################################################

for (z in list(list("xw", out_pair), list("xw_raw", out_raw))) {
  dbExecute(con, sprintf(
    "COPY (SELECT * FROM %s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    z[[1]], fw(paste0(z[[2]], ".part"))))
  if (!file.rename(paste0(z[[2]], ".part"), z[[2]])) {
    stop("Falha ao renomear ", basename(z[[2]]), call. = FALSE)
  }
}
write.csv(cov, paste0(out_cov, ".part"), row.names = FALSE,
          fileEncoding = "UTF-8")
if (!file.rename(paste0(out_cov, ".part"), out_cov)) {
  stop("Falha ao renomear a cobertura", call. = FALSE)
}

####################################################################
### Relatorio
####################################################################

fm <- function(z) format(z, big.mark = ",")
cat("\n==================================================================\n")
cat("Crosswalk Revelio -> openalex_id, e a cobertura\n")
cat("==================================================================\n\n")

cat("Estrategias, por quantos PARES cada uma resolve (flag, nao precedencia):\n")
print(dbGetQuery(con, "
SELECT 'safe_map (8f)' AS estrategia, sum(by_safe) AS pares, sum(by_safe * n_rows) AS linhas FROM xw
UNION ALL SELECT 'crosswalk_8d', sum(by_8d), sum(by_8d * n_rows) FROM xw
UNION ALL SELECT 'shanghai_raw (16b)', sum(by_shraw), sum(by_shraw * n_rows) FROM xw
UNION ALL SELECT 'shanghai_name', sum(by_shname), sum(by_shname * n_rows) FROM xw
UNION ALL SELECT 'school_fold_8i', sum(by_8i_fold), sum(by_8i_fold * n_rows) FROM xw
UNION ALL SELECT 'norsid_8l', sum(by_norsid), sum(by_norsid * n_rows) FROM xw
ORDER BY linhas DESC"), row.names = FALSE)

cat("\nQuem ganhou a precedencia, por linha de educacao:\n")
print(src, row.names = FALSE)

cat("\n------------------------------------------------------------------\n")
cat("COBERTURA\n")
cat("------------------------------------------------------------------\n")
for (i in seq_len(nrow(cov))) {
  r <- cov[i, ]
  cat(sprintf("\n%s -- %s\n", r$bloco, r$celula))
  cat(sprintf("  entradas          : %s\n", fm(r$n_rows)))
  cat(sprintf("  com openalex_id   : %s  (%.1f%%)\n",
              fm(r$n_rows_oa), 100 * r$share_rows))
  cat(sprintf("  usuarios          : %s\n", fm(r$n_users)))
  cat(sprintf("  usuarios com id   : %s  (%.1f%%)\n",
              fm(r$n_users_oa), 100 * r$share_users))
}

cat(sprintf("\nconflito entre estrategias: %s pares (nota 5)\n",
            fm(v$n_conf)))
cat(sprintf("grafias ambiguas por rsid : %s (nota das duas tabelas)\n",
            fm(v$n_amb)))
cat(sprintf("\n  %s\n  %s\n  %s\n\n",
            out_pair, out_raw, out_cov))
cat("Bloco B remove ensino medio E TAMBEM pos-doc, intercambio,\n")
cat("extensao, tecnologo/CST e o inclassificavel (nota 6).\n")
cat("A precisao do norsid_8l foi medida SO em in_norsid_domain = 1 (nota 4).\n\n")
