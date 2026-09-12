####################################################################
### 27. CAPES stricto sensu -> candidatos OBMEP selecionados
### Piloto de pareamento aproximado por nome, bloqueado por hash
###
### Pipeline local e OFFLINE. Le o CSV do script 24, os dois
### crosswalks de instituicao dos scripts 25 e 26, a tabela de
### educacao do script 10a, os selecionados do script 21 e o mapa
### seguro rsid -> openalex_id do script 8f. Nao usa rede, nao
### instala pacote e NAO deve ser enviado nem executado no SEDAP.
###
### O METODO
###   1. Cada lado e reduzido a uma linha por pessoa com primeiro
###      nome, ano de inicio do mestrado, ano de inicio do doutorado
###      e o openalex_id da instituicao de cada um dos dois.
###   2. Esses campos viram uma CHAVE de 7 posicoes separadas por
###      '-', e a chave vira um bucket: hash(chave) % 128.
###   3. Dentro de cada bucket o par so e comparado quando as chaves
###      sao IDENTICAS. O que resta de aproximado e o nome.
###   4. O lado CAPES entra com TODAS AS COMBINACOES dos sobrenomes
###      preservando a ordem -- "joao francisco gomes marques" gera
###      "joao francisco", "joao gomes", "joao marques",
###      "joao francisco gomes", "joao francisco marques",
###      "joao gomes marques" e o nome inteiro -- porque o LinkedIn
###      carrega qualquer subconjunto dessa lista. As variantes NAO
###      mudam o bucket: todas compartilham o primeiro token.
###   5. A comparacao TIRA O PRIMEIRO NOME DOS DOIS LADOS. O bloco ja
###      exigiu que ele fosse identico, entao pontua-lo de novo mede
###      uma constante -- e o bonus de prefixo do Winkler premia
###      exatamente essa constante. Medido na selecao de 2026-09-09:
###      86.018 pares passavam de
###      0,90 no nome inteiro e reprovavam em qualquer comparacao de
###      sobrenome; numa amostra aleatoria de 30, os 30 eram pessoas
###      diferentes ("MELISSA PEREIRA DOS SANTOS" x "Melissa Lima",
###      0,900).
###
### A saida principal e uma TABELA DE CANDIDATOS, nao um mapa 1:1.
### Um person_key pode alcancar varios user_id e vice-versa; as duas
### direcoes saem em n_users e n_persons. Nao colapse nenhuma das
### duas sem tratar a outra.
###
### DADO PESSOAL: os dois lados carregam nome civil, e toda saida
### deste script tambem. Trate como o script 21.
###
### CAUTION / LIMITATIONS
###   1. concat_ws() DESCARTA NULL no DuckDB. Todo campo da chave e
###      coalesce()-ado para o literal 'NA' ANTES do concat_ws. Sem
###      isso um campo ausente desloca todos os seguintes para a
###      esquerda e a chave passa a significar outra coisa, sem erro.
###   2. O CSV do script 24 NAO TEM ano de conclusao -- suas 9
###      colunas param em course_start_year. As posicoes 3 e 5 da
###      chave existem, mas recebem 'NA' nos dois lados enquanto
###      key_end_years for FALSE. Os anos de fim do lado Revelio sao
###      calculados e carregados como COLUNA, fora da chave.
###   3. A chave exige igualdade EXATA em 7 posicoes. Um ano de
###      mestrado auto-declarado com um ano de diferenca joga o par
###      em outro bucket, definitivamente. Isso e medido pela escada
###      de atrito no relatorio, nao contornado.
###   4. As posicoes de openalex_id restringem o lado Revelio a
###      diplomas brasileiros -- correto, porque so esses podem estar
###      na CAPES -- mas qualquer instituicao brasileira fora dos
###      667 rsid do mapa seguro le 'NA' enquanto a CAPES le um id
###      real, e esses dois nunca se encontram.
###   5. O corte Jaro-Winkler e 0,90 e NAO 0,95. Ver README, "Por que
###      o fuzzy match foi abandonado": JW >= 0,95 e aritmeticamente
###      inalcancavel para uma substituicao no meio de nomes com
###      menos de 8 caracteres.
###   6. degree_raw manda, degree nao. A coluna degree e 'empty' em
###      7,89M linhas e sistematicamente errada em registros
###      brasileiros -- ver o cabecalho de br_degree_patterns.R.
###   7. NOMES COMPOSTOS sao o limite conhecido deste metodo. O bloco
###      usa SO o primeiro token, entao em "Ana Carolina", "Pedro
###      Henrique", "Joao Pedro" e "Ana Clara" o SEGUNDO token ainda
###      e um nome de batismo ocupando a posicao de sobrenome -- e ele
###      concorda por razoes que nada tem a ver com identidade.
###      jw_lastname existe para expor isso: dos 94.315 pares com
###      jw_combo >= 0,90, os 88.772 em que o ULTIMO sobrenome tambem
###      concorda sao o produto conservador, e os 5.543 restantes sao
###      um balde de JULGAMENTO -- numa amostra de 15, cerca de um
###      terco eram verdadeiros (nome de casada, "Jr.", ", PhD") e o
###      resto eram "ANA CAROLINA GUSMAO MARCAL" x "Ana Carolina
###      Martins". NAO filtre esse balde em silencio.
###   9. DUAS VARIANTES. key_oa_ids (env OBMEP_MATCH_KEY_OA) decide se
###      as posicoes 6 e 7 -- os openalex_id -- entram na chave.
###      Ligado (padrao) escreve em capes_obmep_match/; desligado
###      escreve em capes_obmep_match_noinst/ e NUNCA toca no
###      canonico (ha guarda no topo e no fim). A comparacao abaixo e
###      HISTORICA: as duas variantes foram medidas sobre a selecao de
###      2026-09-06. A variante desligada
###      alcanca 451.331 pessoas da CAPES em vez de 166.086 e pareia
###      164.747 em vez de 79.764 -- e o PLACEBO dela sobe de 4,15%
###      para 57,6%. Mais da metade dos pares sobrevive quando se da a
###      cada pessoa o sobrenome de outro brasileiro, e apertar o
###      corte para 1,00 so leva a 52,9%. Os openalex_id sao o que
###      torna este vinculo identificavel; sem eles a chave e
###      "primeiro nome + ano de diploma", que entre 567.270
###      brasileiros nao chega perto de ser unica. A variante existe
###      para MEDIR isso, nao para ser consumida.
###   8. Tres escores sao gravados, nao um. jw_combo e o principal;
###      jw_lastname separa o balde da nota 7; jw_name reproduz a
###      regra antiga (nome inteiro) para a mudanca continuar
###      mensuravel. O portao de escrita e a UNIAO de jw_combo e
###      jw_name, entao nenhuma das regras perde recall no arquivo.
###
###  10. TRES BRACOS POR DIPLOMA. match_arm (env OBMEP_MATCH_ARM)
###      escolhe quais posicoes da chave valem. "both" (padrao) e a
###      chave canonica, que exige os DOIS diplomas de quem tem os
###      dois: se o LinkedIn lista so um, ou lista o outro com ano
###      ou instituicao diferente, o par cai em outro bucket para
###      sempre. "msc" apaga as posicoes do doutorado e "phd" as do
###      mestrado, entao cada braco pede que UM diploma concorde.
###
###      Diferente da nota 9, o braco NAO tira a instituicao da
###      chave -- ele mantem um openalex_id, que e o que o placebo
###      mostrou ser o que identifica esta ligacao. E cada braco
###      EXIGE o seu diploma nos dois lados, senao um doutor-so
###      entraria no braco de mestrado com a chave toda em NA e o
###      bloco saturaria como em maria-2023-NA.
###
###      Os bracos escrevem em capes_obmep_match_msc/ e
###      capes_obmep_match_phd/ e NUNCA tocam no canonico (mesma
###      guarda da nota 9, agora sob is_variant). Cada braco e um
###      SUPERCONJUNTO do canonico no seu diploma, o que e
###      afirmado, nao deduzido -- ver arm_superset abaixo. A uniao
###      deduplicada dos dois sai no script 27c, e como sempre o
###      placebo do 27b e que diz se o ganho vale algo.
###
### Depends on:
###   prep/building_external_data/br_degree_patterns.R              (7)
###   prep/building_external_data/rsid_openalex_one_to_one.R        (8f)
###   prep/building_external_data/obmep_candidates_step_1_entries.R (10a)
###   prep/building_external_data/obmep_candidates_selected.R       (21)
###   prep/building_external_data/capes_masters_doctorates_born_1988plus.R (24)
###   prep/building_external_data/capes_openalex_br_crosswalk.R     (25)
###   prep/building_external_data/capes_openalex_manual_crosswalk.R (26)
###
### Outputs (Data/intermediate/capes_discentes/capes_obmep_match/):
###   capes_person_keys.parquet
###   capes_name_variants.parquet
###   revelio_user_keys.parquet
###   pairs/bucket=NNN.parquet          128 arquivos, retomavel
###   best/bucket=NNN.parquet           melhor escore por pessoa CAPES
###   capes_obmep_match_candidates.parquet
###   capes_obmep_match_unmatched.csv
###   capes_obmep_match_summary.csv
####################################################################

for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}
library(DBI)
library(duckdb)

####################################################################
### Parametros e caminhos
####################################################################

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)

capes_dir <- file.path(obmep_root, "Data/intermediate/capes_discentes")
rev_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

# Population routing is deliberately an enum rather than independent path
# overrides: the selected-profile file and education history must always come
# from the same cohort. The legacy behavior remains the default.
match_cohort <- Sys.getenv("OBMEP_MATCH_COHORT", unset = "legacy")
if (!match_cohort %in% c("legacy", "degree_duration")) {
  stop("OBMEP_MATCH_COHORT = '", match_cohort,
       "' does not exist. Use legacy or degree_duration.")
}
cohort_tag <- if (match_cohort == "degree_duration") "_degree_duration" else ""
# A VARIANTE. Ligado (padrao) = a chave de 7 posicoes descrita acima.
# Desligado = as posicoes 6 e 7, os openalex_id, viram o literal 'NA'
# nos dois lados, exatamente como key_end_years ja faz com as posicoes
# 3 e 5. Env var para produzir as duas sem editar o arquivo.
#
# NAO e um sucessor do produto canonico: e uma MEDICAO. Ver nota 9.
key_oa_ids <- Sys.getenv("OBMEP_MATCH_KEY_OA", unset = "1") != "0"

# O BRACO. "both" (padrao) = a chave canonica, em que quem tem os dois
# diplomas precisa que os DOIS concordem. "msc" apaga as posicoes do
# doutorado e "phd" as do mestrado, do mesmo jeito que key_end_years ja
# apaga as posicoes 3 e 5 -- a chave continua com 7 posicoes.
#
# Cada braco EXIGE o seu proprio diploma nos dois lados. Sem isso um
# doutor-so entraria no braco de mestrado como a chave
# 'maria-NA-NA-NA-NA-NA-NA' e o bloco saturaria, que e exactamente o
# que inutilizou a variante sem instituicao. Ver nota 10.
match_arm <- Sys.getenv("OBMEP_MATCH_ARM", unset = "both")
if (!match_arm %in% c("both", "msc", "phd")) {
  stop("OBMEP_MATCH_ARM = '", match_arm, "' nao existe. ",
       "Use both, msc ou phd.")
}
arm_tag <- switch(match_arm, both = "", msc = "_msc", phd = "_phd")

variant_tag <- paste0(cohort_tag, if (key_oa_ids) "" else "_noinst", arm_tag)

out_dir <- file.path(capes_dir, paste0("capes_obmep_match", variant_tag))

capes_path <- file.path(
  capes_dir, "capes_masters_doctorates_born_1988plus_2004_2024.csv"
)
xw_path <- file.path(capes_dir, "capes_openalex_br_crosswalk.parquet")
manual_path <- file.path(
  capes_dir,
  "capes_openalex_manual/capes_openalex_manual_br_crosswalk.parquet"
)
edu_dir <- file.path(
  rev_dir, if (match_cohort == "degree_duration")
    "obmep_candidates_step_1_degree_duration_education" else
    "obmep_candidates_step_1_education")
sel_path <- file.path(
  rev_dir, if (match_cohort == "degree_duration")
    "obmep_candidates_selected_degree_duration.parquet" else
    "obmep_candidates_selected.parquet")
map_path <- file.path(rev_dir, "rsid_openalex_safe_map.parquet")

script_arg <- grep("^--file=", commandArgs(), value = TRUE)
patterns_path <- if (length(script_arg) == 1L) {
  file.path(dirname(sub("^--file=", "", script_arg)), "br_degree_patterns.R")
} else {
  "prep/building_external_data/br_degree_patterns.R"
}

n_buckets <- 128L
jw_cut <- 0.90
year_min <- 1950L
year_max <- 2030L

# Teto de tokens por nome CAPES. As variantes sao o POWER SET dos
# sobrenomes, 2^(n-1)-1 por pessoa, entao um nome anormalmente longo
# explodiria o job em silencio. Medido: o maximo real e 8 tokens, em
# 10 pessoas, 127 subconjuntos cada. 12 deixa folga (2.047) e aborta
# muito antes de virar problema.
max_tokens <- 12L

# As posicoes 3 e 5 da chave. FALSE porque o CSV do script 24 nao tem
# ano de conclusao -- ver limitacao 2. Ligar isto sem antes derivar o
# ano de titulacao da CAPES faria o lado CAPES emitir 'NA' contra um
# ano real do lado Revelio, e nada casaria.
key_end_years <- FALSE

mem_limit <- if (key_oa_ids) "12GB" else "16GB"
tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_capes_obmep")
# O tag de versao carrega a variante E o braco: sem isso uma rodada do
# braco phd releria em silencio os parquet de bucket do braco msc.
cache_dir <- file.path(tmp_dir, paste0("v1_b128", variant_tag))

# Valores medidos na rodada canonica de 2026-09-09. Servem como teste
# de regressao; os valores da variante sem instituicao continuam sendo
# os historicos de 2026-09-06.
# divergencia estrutural aborta, divergencia de contagem avisa.
exp_capes_rows <- 733879L
exp_capes_institutions <- 915L
exp_capes_inst_with_oa <- 843L
exp_capes_rows_with_oa <- 730667L
if (match_cohort == "degree_duration") {
  exp_edu_rows <- 19710307L
  exp_edu_users <- 8901904L
  exp_selected_users <- 2289937L
  exp_selected_named <- 2288180L
} else {
  exp_edu_rows <- 15712737L
  exp_edu_users <- 6849674L
  exp_selected_users <- 1468102L
  exp_selected_named <- 1467285L
}
exp_safe_map_rows <- 667L
# O power set roda sobre TODAS as grafias do nome de cada pessoa, nao
# so a canonica: as 2.228 pessoas com mais de uma grafia rendem 15.415
# variantes a mais do que um teste sobre capes_person_keys.full_name
# sozinho daria. Isso e deliberado -- uma grafia alternativa e
# exatamente o tipo de coisa que o LinkedIn pode ter copiado.
exp_variants <- 2755694L
exp_max_tokens <- 8L
exp_users_no_surname <- if (match_cohort == "degree_duration") {
  44778L
} else 33806L

# As tres regras no corte 0,90. jw_name nao reproduz exatamente os
# 172.269 do piloto anterior porque a variante "nome inteiro" agora e
# a juncao dos TOKENS, sem as particulas; a diferenca e de 279 pares.
if (match_cohort == "degree_duration") {
  exp_pairs_compared <- switch(
    match_arm, both = 975226L, msc = 1131720L, phd = 169797L)
  exp_combo_pairs <- switch(
    match_arm, both = 143411L, msc = 171901L, phd = 43956L)
  exp_combo_persons <- switch(
    match_arm, both = 128112L, msc = 151365L, phd = 39915L)
  exp_strict_pairs <- switch(
    match_arm, both = 135777L, msc = 161823L, phd = 41873L)
  exp_legacy_pairs <- switch(
    match_arm, both = 251319L, msc = 304210L, phd = 59725L)
} else if (match_arm != "both") {
  # Primeira rodada dos bracos por diploma: nao ha valor medido ainda.
  # NA cala o comparador de CONTAGEM sem desligar nenhuma guarda
  # estrutural. Preencher com o que a rodada imprimir.
  exp_pairs_compared <- NA_integer_
  exp_combo_pairs <- NA_integer_
  exp_combo_persons <- NA_integer_
  exp_strict_pairs <- NA_integer_
  exp_legacy_pairs <- NA_integer_
} else if (key_oa_ids) {
  exp_pairs_compared <- 769710L
  exp_combo_pairs <- 94315L
  exp_combo_persons <- 84373L
  exp_strict_pairs <- 88772L
  exp_legacy_pairs <- 179627L
} else {
  # Historicos: medidos em 2026-09-06 sobre a variante sem instituicao.
  exp_pairs_compared <- 51645722L
  exp_combo_pairs <- 455265L
  exp_combo_persons <- 179685L
  exp_strict_pairs <- 282769L
  exp_legacy_pairs <- NA_integer_
}

expected_capes_columns <- c(
  "person_id", "full_name", "birth_year", "course_code", "course_name",
  "institution", "course_area", "course_type", "course_start_year"
)
expected_edu_columns <- c(
  "user_id", "university_raw", "university_name", "rsid", "degree_raw",
  "degree", "field_raw", "field", "university_country", "description",
  "startdate", "enddate"
)
if (match_cohort == "degree_duration") {
  expected_edu_columns <- c(
    expected_edu_columns, "ranked_level", "degree_duration_years",
    "degree_residual_other", "degree_match_ranked", "degree_match_duration",
    "degree_matches_laxed", "degree_match_route")
}

if (key_end_years) {
  stop("key_end_years = TRUE exige um ano de conclusao da CAPES, que o ",
       "CSV do script 24 nao tem. Derive AN_SITUACAO_DISCENTE em ",
       "NM_SITUACAO_DISCENTE = 'TITULADO' antes de ligar isto.")
}

stopifnot(
  file.exists(capes_path), file.exists(xw_path), file.exists(manual_path),
  file.exists(sel_path), file.exists(map_path), file.exists(patterns_path),
  dir.exists(edu_dir)
)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(out_dir, "pairs"), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(out_dir, "best"), recursive = TRUE, showWarnings = FALSE)
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)

# Guarda do padrao 21alt: uma rodada da variante nao pode, por
# nenhum caminho, escrever no produto canonico. Tamanho e mtime do
# arquivo canonico sao capturados aqui e reconferidos no fim.
canon_dir <- file.path(capes_dir, paste0("capes_obmep_match", cohort_tag))
canon_file <- file.path(canon_dir, "capes_obmep_match_candidates.parquet")
# Qualquer rodada que NAO seja a canonica e uma variante, e nenhuma
# variante pode escrever no produto canonico por nenhum caminho.
is_variant <- !key_oa_ids || match_arm != "both"
legacy_canon_file <- file.path(
  capes_dir, "capes_obmep_match", "capes_obmep_match_candidates.parquet")
guarded_files <- unique(c(
  if (match_cohort == "degree_duration") legacy_canon_file else character(),
  if (is_variant) canon_file else character()))
guarded_files <- guarded_files[file.exists(guarded_files)]
guarded_before <- if (length(guarded_files)) {
  file.info(guarded_files)[c("size", "mtime")]
} else NULL
if (is_variant && normalizePath(out_dir, mustWork = FALSE) ==
    normalizePath(canon_dir, mustWork = FALSE)) {
  stop("A variante resolveu para o diretorio canonico. Abortando.")
}

source(patterns_path, local = TRUE)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

invisible(dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit)))
# temp_directory explicito: o derrame para disco nao pode cair em pasta
# sincronizada pelo Dropbox.
invisible(dbExecute(
  con, sprintf("SET temp_directory=%s",
               as.character(dbQuoteString(con, tmp_dir)))
))
invisible(dbExecute(con, "SET preserve_insertion_order=false"))

# Shim Trino -> DuckDB, exigido por sql_shanghai_level.
invisible(dbExecute(
  con, "CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)"
))

qp <- function(path) {
  as.character(dbQuoteString(con, gsub("\\\\", "/", path)))
}

capes_sql <- qp(capes_path)
xw_sql <- qp(xw_path)
manual_sql <- qp(manual_path)
edu_sql <- qp(file.path(edu_dir, "*"))
sel_sql <- qp(sel_path)
map_sql <- qp(map_path)

cat("CAPES -> candidatos OBMEP selecionados: piloto de pareamento\n")
cat("coorte      :", match_cohort, "\n")
cat("CAPES       :", capes_path, "\n")
cat("educacao    :", edu_dir, "\n")
cat("selecionados:", sel_path, "\n")
cat("saida       :", out_dir, "\n")
cat("buckets     :", n_buckets, " corte JW >=", jw_cut, "\n")
cat("variante    :", if (key_oa_ids) "canonica (openalex_id na chave)" else
    "SEM openalex_id -- MEDICAO, nao tabela de pareamento", "\n")
cat("DuckDB      :", dbGetQuery(con, "SELECT version() AS v")$v, "\n\n")

####################################################################
### Expressoes de nome -- IDENTICAS nos dois lados
###
### Copiadas de linkedin_br_name_flag.R (script 1). strip_accents e a
### funcao certa do DuckDB; unaccent() NAO existe. Caracteres nao
### alfabeticos viram ESPACO, nao sao deletados.
####################################################################

particles <- c("de", "da", "do", "dos", "das", "di", "del", "dello", "della",
               "du", "van", "von", "der", "den", "ter", "la", "le", "el",
               "al", "bin", "ibn", "dr", "dra", "prof", "eng", "sr", "sra",
               "mr", "ms", "mrs")
plist <- paste0("'", particles, "'", collapse = ",")

clean_tpl <- paste0(
  "trim(regexp_replace(regexp_replace(",
  "lower(strip_accents(%s)), '[^a-z ]', ' ', 'g'), ' +', ' ', 'g'))"
)
tokens_tpl <- paste0(
  "list_filter(str_split(%s, ' '), x -> length(x) >= 2 AND x NOT IN (",
  plist, "))"
)

capes_clean <- sprintf(clean_tpl, "full_name")
capes_tokens <- sprintf(tokens_tpl, capes_clean)
rev_clean <- sprintf(clean_tpl, "fullname")
rev_tokens <- sprintf(tokens_tpl, rev_clean)

####################################################################
### Teste de regressao das expressoes de nome
###
### ORDER BY id explicito: preserve_insertion_order=false pode
### reordenar linhas e invalidar silenciosamente uma comparacao
### posicional.
####################################################################

fixture <- data.frame(
  id = 1:6,
  full_name = c("JOAO FRANCISCO GOMES MARQUES", "JOAO DE SOUZA",
                "MARIA", "Ana Ma. Silva-Costa", "Jose  da  Silva  Jr",
                "\u00c9RICA S\u00c1 P\u00c9REZ"),
  stringsAsFactors = FALSE
)
dbWriteTable(con, "fixture", fixture, temporary = TRUE, overwrite = TRUE)

fx <- dbGetQuery(con, sprintf(
  "SELECT id, t[1] AS first_name,
          list_aggregate(list_transform(t[2:], x -> t[1] || ' ' || x),
                         'string_agg', '|') AS variants
   FROM (SELECT id, %s AS t FROM fixture) ORDER BY id",
  capes_tokens
))

stopifnot(
  identical(fx$first_name,
            c("joao", "joao", "maria", "ana", "jose", "erica")),
  identical(fx$variants,
            c("joao francisco|joao gomes|joao marques",
              "joao souza",
              NA_character_,
              "ana ma|ana silva|ana costa",
              "jose silva|jose jr",
              "erica sa|erica perez"))
)

# As COMBINACOES, na ordem das mascaras de bits. Preservar a ordem dos
# tokens e o requisito: "joao gomes marques" vale, "joao marques gomes"
# nao. A mascara i liga os sobrenomes cujo bit esta aceso, sempre da
# esquerda para a direita, entao a ordem sai de graca.
fxc <- dbGetQuery(con, sprintf(
  "SELECT mask,
          t[1] || ' ' || list_aggregate(list_transform(
            list_filter(range(1, len(st) + 1), i -> ((mask >> (i - 1)) & 1) = 1),
            i -> st[i]), 'string_agg', ' ') AS variant
   FROM (SELECT t, t[2:] AS st,
                unnest(range(1, CAST(pow(2, len(t[2:])) AS BIGINT))) AS mask
         FROM (SELECT %s AS t FROM fixture WHERE id = 1))
   ORDER BY mask",
  capes_tokens
))

stopifnot(
  nrow(fxc) == 7L,
  identical(fxc$variant,
            c("joao francisco",
              "joao gomes",
              "joao francisco gomes",
              "joao marques",
              "joao francisco marques",
              "joao gomes marques",
              "joao francisco gomes marques"))
)

cat("[ok] fixture de nomes: 6 casos, primeiro nome e variantes conferem\n")
cat("     particula descartada: JOAO DE SOUZA -> joao souza\n")
cat("[ok] fixture de combinacoes: JOAO FRANCISCO GOMES MARQUES ->\n")
cat("     7 variantes, ordem dos tokens preservada\n\n")

####################################################################
### Etapa A -- lado CAPES, uma linha por pessoa
####################################################################

capes_columns <- names(dbGetQuery(con, sprintf(
  "SELECT * FROM read_csv_auto(%s, header = true, all_varchar = true) LIMIT 0",
  capes_sql
)))
stopifnot(identical(capes_columns, expected_capes_columns))

# person_id so existe a partir de 2013. As linhas legadas sao
# agrupadas por nome completo aparado mais ano de nascimento, como o
# script 24 documenta.
invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE capes_rows AS
   SELECT
     coalesce(nullif(trim(person_id), ''),
              trim(full_name) || '|' || trim(birth_year)) AS person_key,
     trim(full_name)  AS full_name,
     trim(birth_year) AS birth_year,
     trim(institution) AS institution,
     trim(course_code) AS course_code,
     trim(course_type) AS course_type,
     CASE WHEN trim(course_type) LIKE 'MESTRADO%%'  THEN 'master'
          WHEN trim(course_type) LIKE 'DOUTORADO%%' THEN 'phd' END AS lvl,
     TRY_CAST(trim(course_start_year) AS INTEGER) AS course_start_year
   FROM read_csv_auto(%s, header = true, all_varchar = true)",
  capes_sql
)))

capes_qa <- dbGetQuery(con, "
  SELECT count(*) AS rows,
         count(DISTINCT person_key) AS persons,
         count(DISTINCT institution) AS institutions,
         count_if(lvl IS NULL) AS bad_level,
         count_if(person_key IS NULL OR person_key = '') AS bad_key
  FROM capes_rows")

# Um person_key com mais de uma grafia do nome: a chave usa a grafia
# canonica (min), mas as variantes saem de TODAS as grafias.
capes_multi_name <- dbGetQuery(con, "
  SELECT count(*) AS n FROM (
    SELECT person_key FROM capes_rows
    GROUP BY person_key HAVING count(DISTINCT full_name) > 1)")$n

stopifnot(capes_qa$bad_level == 0L, capes_qa$bad_key == 0L)
if (capes_qa$rows != exp_capes_rows) {
  warning("Linhas CAPES ", capes_qa$rows, " != ", exp_capes_rows, " medido.")
}
if (capes_qa$institutions != exp_capes_institutions) {
  warning("Instituicoes CAPES ", capes_qa$institutions, " != ",
          exp_capes_institutions, " medido.")
}

# instituicao -> openalex_id, em tres bracos, UM id por instituicao.
# NAO juntar o crosswalk do script 25 sem resolver n_candidates: aquele
# arquivo e uma tabela de CANDIDATOS e multiplicaria linhas.
invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE capes_oa AS
   SELECT capes_institution, openalex_id, 'jw_unique' AS oa_source
     FROM read_parquet(%1$s) WHERE n_candidates = 1
   UNION ALL
   SELECT capes_institution, openalex_id, 'jw_rank1'
     FROM (SELECT capes_institution, openalex_id,
                  count(*) OVER (PARTITION BY capes_institution) AS n_tied
           FROM read_parquet(%1$s)
           WHERE score_rank = 1 AND n_candidates > 1)
     WHERE n_tied = 1
   UNION ALL
   SELECT capes_institution, openalex_id, 'manual'
     FROM read_parquet(%2$s)
     WHERE match_status = 'verified' AND openalex_id IS NOT NULL",
  xw_sql, manual_sql
)))

oa_qa <- dbGetQuery(con, "
  SELECT count(*) AS rows, count(DISTINCT capes_institution) AS institutions
  FROM capes_oa")
# A checagem que importa: nenhuma instituicao com dois ids, ou o join
# abaixo abriria em leque.
stopifnot(oa_qa$rows == oa_qa$institutions)
if (oa_qa$rows != exp_capes_inst_with_oa) {
  warning("Instituicoes CAPES com openalex_id ", oa_qa$rows, " != ",
          exp_capes_inst_with_oa, " medido.")
}

capes_row_cover <- dbGetQuery(con, "
  SELECT count_if(o.openalex_id IS NOT NULL) AS rows_with_oa
  FROM capes_rows c
  LEFT JOIN capes_oa o ON c.institution = o.capes_institution")$rows_with_oa
if (capes_row_cover != exp_capes_rows_with_oa) {
  warning("Linhas CAPES com openalex_id ", capes_row_cover, " != ",
          exp_capes_rows_with_oa, " medido.")
}

# Uma linha por (pessoa, nivel): o ANO e o ID saem do MESMO diploma, o
# mais antigo. Agregar os dois de forma independente misturaria o ano
# de um mestrado com a instituicao de outro.
invisible(dbExecute(con, "
  CREATE TEMP TABLE capes_lvl AS
  SELECT person_key, lvl, course_start_year AS yr, openalex_id AS oa_id
  FROM (
    SELECT c.person_key, c.lvl, c.course_start_year, o.openalex_id,
           row_number() OVER (
             PARTITION BY c.person_key, c.lvl
             ORDER BY c.course_start_year NULLS LAST,
                      coalesce(o.openalex_id, '~'), c.course_code) AS rn
    FROM capes_rows c
    LEFT JOIN capes_oa o ON c.institution = o.capes_institution)
  WHERE rn = 1"))

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE capes_person AS
   SELECT n.person_key, n.full_name, n.birth_year,
          (%s)[1] AS first_name,
          l.msc_start_year, l.msc_oa_id, l.phd_start_year, l.phd_oa_id
   FROM (SELECT person_key, min(full_name) AS full_name,
                min(birth_year) AS birth_year
         FROM capes_rows GROUP BY person_key) n
   LEFT JOIN (
     SELECT person_key,
            max(yr)    FILTER (WHERE lvl = 'master') AS msc_start_year,
            max(oa_id) FILTER (WHERE lvl = 'master') AS msc_oa_id,
            max(yr)    FILTER (WHERE lvl = 'phd')    AS phd_start_year,
            max(oa_id) FILTER (WHERE lvl = 'phd')    AS phd_oa_id
     FROM capes_lvl GROUP BY person_key) l USING (person_key)",
  capes_tokens
)))

####################################################################
### Etapa B -- combinacoes de sobrenome do lado CAPES
###
### O nome da CAPES e sempre completo; o do LinkedIn e qualquer
### subconjunto dele. Entao cada pessoa entra com TODAS as combinacoes
### dos seus sobrenomes, preservando a ordem -- o power set de
### toks[2:], gerado por mascara de bits:
###
###   JOAO FRANCISCO GOMES MARQUES
###     1 joao francisco          5 joao francisco marques
###     2 joao gomes              6 joao gomes marques
###     3 joao francisco gomes    7 joao francisco gomes marques
###     4 joao marques
###
### Duas colunas saem daqui e as duas sao usadas:
###   variant  a combinacao COM o primeiro nome, para leitura humana
###   csur     a mesma combinacao SEM ele, que e o que se compara
###
### csur existe porque o bloco ja exigiu primeiro nome identico. Ver
### nota 5 do cabecalho.
###
### n_parts e n_sur nao sao decoracao: n_parts = 1 seleciona as
### combinacoes de um sobrenome so (de onde sai jw_lastname) e
### (n_parts = 1 OR n_parts = n_sur) reproduz o conjunto de variantes
### da regra ANTIGA, de onde sai jw_name.
###
### As variantes sao instrumento de PONTUACAO, nao de bloqueio: todas
### comecam pelo mesmo token e caem no mesmo bucket da pessoa.
####################################################################

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE capes_tok AS
   SELECT DISTINCT person_key, %s AS name_clean, %s AS toks
   FROM (SELECT DISTINCT person_key, full_name FROM capes_rows)",
  capes_clean, capes_tokens
)))

# O power set e 2^(n-1)-1 por pessoa. Um nome longo demais explodiria
# o job sem erro, entao o teto e verificado ANTES de gerar qualquer
# combinacao.
tok_qa <- dbGetQuery(con, "
  SELECT max(len(toks)) AS max_tokens,
         count_if(len(toks) < 2) AS sem_sobrenome
  FROM capes_tok")
if (tok_qa$max_tokens > max_tokens) {
  stop("Nome CAPES com ", tok_qa$max_tokens, " tokens excede o teto de ",
       max_tokens, ": o power set teria ",
       2^(tok_qa$max_tokens - 1) - 1, " combinacoes por pessoa.")
}
if (tok_qa$max_tokens != exp_max_tokens) {
  warning("Maximo de tokens ", tok_qa$max_tokens, " != ", exp_max_tokens,
          " medido.")
}

invisible(dbExecute(con, "
  CREATE TEMP TABLE capes_variants AS
  SELECT DISTINCT person_key, variant, csur, n_parts, n_sur FROM (
    SELECT person_key,
           toks[1] || ' ' || csur AS variant,
           csur, len(idx) AS n_parts, len(st) AS n_sur
    FROM (
      SELECT person_key, toks, st, idx,
             list_aggregate(list_transform(idx, i -> st[i]),
                            'string_agg', ' ') AS csur
      FROM (
        SELECT person_key, toks, st, mask,
               list_filter(range(1, len(st) + 1),
                           i -> ((mask >> (i - 1)) & 1) = 1) AS idx
        FROM (
          SELECT person_key, toks, toks[2:] AS st,
                 unnest(range(1, CAST(pow(2, len(toks[2:])) AS BIGINT))) AS mask
          FROM capes_tok WHERE len(toks) >= 2))))"))

var_qa <- dbGetQuery(con, "
  SELECT (SELECT count(*) FROM capes_variants) AS variants,
         (SELECT count(DISTINCT person_key) FROM capes_variants) AS persons,
         round(avg(n), 2) AS per_person, max(n) AS max_per_person
  FROM (SELECT person_key, count(*) AS n FROM capes_variants
        GROUP BY person_key)")

stopifnot(
  dbGetQuery(con, "SELECT count_if(csur IS NULL OR csur = '') AS n
                   FROM capes_variants")$n == 0L,
  dbGetQuery(con, "SELECT count_if(n_parts < 1 OR n_parts > n_sur) AS n
                   FROM capes_variants")$n == 0L
)
if (var_qa$variants != exp_variants) {
  warning("Variantes ", var_qa$variants, " != ", exp_variants, " medido.")
}

####################################################################
### Etapa C -- lado Revelio, uma linha por candidato selecionado
####################################################################

edu_columns <- names(dbGetQuery(con, sprintf(
  "SELECT * FROM read_parquet(%s) LIMIT 0", edu_sql
)))
stopifnot(identical(edu_columns, expected_edu_columns))

# name_sur e o nome do LinkedIn SEM o primeiro token -- o outro lado
# da comparacao. name_last e o ultimo token, que alimenta jw_lastname.
# Os dois ficam NULL quando so ha um token utilizavel: 33.806 usuarios
# (2,3%) nao tem sobrenome nenhum e por isso nao podem ser pontuados
# por jw_combo. Eles NAO sao removidos -- continuam elegiveis por
# jw_name, e o portao de escrita e a uniao das duas regras.
invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE sel AS
   SELECT user_id, fullname, name_clean,
          rtoks[1] AS first_name,
          CASE WHEN len(rtoks) >= 2
               THEN list_aggregate(rtoks[2:], 'string_agg', ' ') END AS name_sur,
          CASE WHEN len(rtoks) >= 2 THEN rtoks[len(rtoks)] END AS name_last
   FROM (SELECT user_id, fullname, %s AS name_clean, %s AS rtoks
         FROM read_parquet(%s))",
  rev_clean, rev_tokens, sel_sql
)))

sel_qa <- dbGetQuery(con, "
  SELECT count(*) AS users, count(DISTINCT user_id) AS ids,
         count_if(fullname IS NOT NULL) AS named,
         count_if(first_name IS NOT NULL AND name_sur IS NULL)
           AS no_surname
  FROM sel")
stopifnot(sel_qa$users == sel_qa$ids)
if (sel_qa$users != exp_selected_users) {
  warning("Selecionados ", sel_qa$users, " != ", exp_selected_users, " medido.")
}
if (!is.na(exp_selected_named) && sel_qa$named != exp_selected_named) {
  warning("Selecionados com nome ", sel_qa$named, " != ",
          exp_selected_named, " medido.")
}
if (!is.na(exp_users_no_surname) &&
    sel_qa$no_surname != exp_users_no_surname) {
  warning("Usuarios sem sobrenome ", sel_qa$no_surname, " != ",
          exp_users_no_surname, " medido.")
}

map_qa <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS rows, count(DISTINCT rsid) AS rsids
   FROM read_parquet(%s)", map_sql))
stopifnot(map_qa$rows == map_qa$rsids)
if (map_qa$rows != exp_safe_map_rows) {
  warning("Mapa rsid seguro ", map_qa$rows, " != ", exp_safe_map_rows,
          " medido.")
}

edu_qa <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS rows, count(DISTINCT user_id) AS users
   FROM read_parquet(%s)", edu_sql))
if (edu_qa$rows != exp_edu_rows || edu_qa$users != exp_edu_users) {
  warning("Educacao ", edu_qa$rows, "/", edu_qa$users, " != ",
          exp_edu_rows, "/", exp_edu_users, " medido.")
}

# degree_raw manda; degree sozinho nao. sql_shanghai_level le os
# aliases `dr` e `degree`. O braco de mestrado exclui MBA -- e a
# definicao sh_master_strict.
invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE ed_arm AS
   SELECT e.user_id,
          CASE WHEN e.lvl = 'master' AND NOT e.is_mba THEN 'master'
               WHEN e.lvl = 'phd'                     THEN 'phd' END AS arm,
          CASE WHEN e.y0 BETWEEN %4$d AND %5$d THEN e.y0 END AS y0,
          CASE WHEN e.y1 BETWEEN %4$d AND %5$d THEN e.y1 END AS y1,
          m.openalex_id AS oa_id,
          e.rsid
   FROM (
     SELECT user_id, rsid,
            CAST(year(startdate) AS INTEGER) AS y0,
            CAST(year(enddate)   AS INTEGER) AS y1,
            (%1$s) AS lvl,
            (degree = 'MBA' OR regexp_like(dr, '%2$s')) AS is_mba
     FROM (SELECT user_id, rsid, startdate, enddate, degree,
                  lower(trim(coalesce(degree_raw, ''))) AS dr
           FROM read_parquet(%3$s)
           WHERE user_id IN (SELECT user_id FROM sel))
   ) e
   LEFT JOIN (SELECT rsid, openalex_id FROM read_parquet(%6$s) WHERE safe = 1) m
     ON e.rsid = m.rsid
   WHERE (e.lvl = 'master' AND NOT e.is_mba) OR e.lvl = 'phd'",
  sql_shanghai_level, rx_mba, edu_sql, year_min, year_max, map_sql
)))

# Mesma regra do lado CAPES: ano de inicio, ano de fim e instituicao
# saem do MESMO diploma, o mais antigo.
invisible(dbExecute(con, "
  CREATE TEMP TABLE rev_lvl AS
  SELECT user_id, arm, y0, y1, oa_id FROM (
    SELECT *, row_number() OVER (
      PARTITION BY user_id, arm
      ORDER BY y0 NULLS LAST, y1 NULLS LAST,
               coalesce(oa_id, '~'), coalesce(rsid, 2147483647)) AS rn
    FROM ed_arm)
  WHERE rn = 1"))

invisible(dbExecute(con, "
  CREATE TEMP TABLE rev_person AS
  SELECT s.user_id, s.fullname, s.name_clean, s.first_name,
         s.name_sur, s.name_last,
         l.msc_start_year, l.msc_end_year, l.msc_oa_id,
         l.phd_start_year, l.phd_end_year, l.phd_oa_id
  FROM sel s
  LEFT JOIN (
    SELECT user_id,
           max(y0)    FILTER (WHERE arm = 'master') AS msc_start_year,
           max(y1)    FILTER (WHERE arm = 'master') AS msc_end_year,
           max(oa_id) FILTER (WHERE arm = 'master') AS msc_oa_id,
           max(y0)    FILTER (WHERE arm = 'phd')    AS phd_start_year,
           max(y1)    FILTER (WHERE arm = 'phd')    AS phd_end_year,
           max(oa_id) FILTER (WHERE arm = 'phd')    AS phd_oa_id
    FROM rev_lvl GROUP BY user_id) l USING (user_id)"))

####################################################################
### Etapa D -- chave de 7 posicoes e bucket
###
### concat_ws() DESCARTA NULL. Todo campo e coalesce()-ado para 'NA'
### ANTES de entrar, senao um campo ausente desloca os seguintes para
### a esquerda. Ver limitacao 1.
####################################################################

# O braco apaga as posicoes do OUTRO diploma. As 7 posicoes ficam de
# pe: o assert de contagem de posicao nao muda e a chave do 27b
# continua tendo a mesma forma.
use_msc <- match_arm != "phd"
use_phd <- match_arm != "msc"

slot_msc_start <- if (use_msc) {
  "coalesce(CAST(msc_start_year AS VARCHAR), 'NA')"
} else "'NA'"
slot_phd_start <- if (use_phd) {
  "coalesce(CAST(phd_start_year AS VARCHAR), 'NA')"
} else "'NA'"
slot_msc_end <- if (key_end_years && use_msc) {
  "coalesce(CAST(msc_end_year AS VARCHAR), 'NA')"
} else "'NA'"
slot_phd_end <- if (key_end_years && use_phd) {
  "coalesce(CAST(phd_end_year AS VARCHAR), 'NA')"
} else "'NA'"

slot_msc_oa <- if (key_oa_ids && use_msc) {
  "coalesce(msc_oa_id, 'NA')"
} else "'NA'"
slot_phd_oa <- if (key_oa_ids && use_phd) {
  "coalesce(phd_oa_id, 'NA')"
} else "'NA'"

key_expr <- sprintf(
  "concat_ws('-',
     coalesce(first_name, 'NA'),
     %s,
     %s,
     %s,
     %s,
     %s,
     %s)",
  slot_msc_start, slot_msc_end, slot_phd_start, slot_phd_end,
  slot_msc_oa, slot_phd_oa
)

# A trava do braco, nos DOIS lados. O openalex_id so entra na
# exigencia quando ele esta na chave -- exigi-lo fora dela produziria
# um recorte incoerente com a propria chave.
arm_where <- if (match_arm == "both") "" else {
  paste0(" AND ", match_arm, "_start_year IS NOT NULL",
         if (key_oa_ids) paste0(" AND ", match_arm, "_oa_id IS NOT NULL")
         else "")
}
bucket_expr <- sprintf("CAST(hash(%s) %% %d AS INTEGER)", key_expr, n_buckets)

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE capes_keys AS
   SELECT person_key, full_name, birth_year, first_name,
          msc_start_year, msc_oa_id, phd_start_year, phd_oa_id,
          %s AS key_string, %s AS bucket
   FROM capes_person
   WHERE first_name IS NOT NULL AND first_name <> ''%s",
  key_expr, bucket_expr, arm_where
)))

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE rev_keys AS
   SELECT user_id, fullname, name_clean, first_name, name_sur, name_last,
          msc_start_year, msc_end_year, msc_oa_id,
          phd_start_year, phd_end_year, phd_oa_id,
          %s AS key_string, %s AS bucket
   FROM rev_person
   WHERE first_name IS NOT NULL AND first_name <> ''%s",
  key_expr, bucket_expr, arm_where
)))

key_qa <- dbGetQuery(con, sprintf("
  SELECT
    (SELECT count(*) FROM capes_keys) AS capes_persons,
    (SELECT count(DISTINCT person_key) FROM capes_keys) AS capes_ids,
    (SELECT count(*) FROM rev_keys) AS rev_users,
    (SELECT count(DISTINCT user_id) FROM rev_keys) AS rev_ids,
    (SELECT count_if(len(str_split(key_string, '-')) <> 7) FROM capes_keys)
      AS capes_bad_slots,
    (SELECT count_if(len(str_split(key_string, '-')) <> 7) FROM rev_keys)
      AS rev_bad_slots,
    (SELECT count_if(bucket < 0 OR bucket >= %1$d) FROM capes_keys)
      AS capes_bad_bucket,
    (SELECT count_if(bucket < 0 OR bucket >= %1$d) FROM rev_keys)
      AS rev_bad_bucket", n_buckets))

stopifnot(
  key_qa$capes_persons == key_qa$capes_ids,
  key_qa$rev_users == key_qa$rev_ids,
  key_qa$capes_bad_slots == 0L, key_qa$rev_bad_slots == 0L,
  key_qa$capes_bad_bucket == 0L, key_qa$rev_bad_bucket == 0L
)

# A trava do braco tem de ter pegado: ninguem sem o diploma do braco
# pode ter sobrado, de nenhum dos dois lados.
if (match_arm != "both") {
  gate_qa <- dbGetQuery(con, sprintf("
    SELECT
      (SELECT count_if(%1$s_start_year IS NULL) FROM capes_keys)
        AS capes_sem_ano,
      (SELECT count_if(%1$s_start_year IS NULL) FROM rev_keys)
        AS rev_sem_ano,
      (SELECT count_if(%1$s_oa_id IS NULL) FROM capes_keys)
        AS capes_sem_id,
      (SELECT count_if(%1$s_oa_id IS NULL) FROM rev_keys)
        AS rev_sem_id", match_arm))
  stopifnot(
    gate_qa$capes_sem_ano == 0L, gate_qa$rev_sem_ano == 0L,
    !key_oa_ids ||
      (gate_qa$capes_sem_id == 0L && gate_qa$rev_sem_id == 0L)
  )
  cat(sprintf("braco %s: %d pessoas CAPES x %d users com o diploma\n",
              match_arm, key_qa$capes_persons, key_qa$rev_users))
}

# O bucket tem de ser reprodutivel a partir da chave.
rehash <- dbGetQuery(con, sprintf(
  "SELECT count_if(bucket <> CAST(hash(key_string) %% %d AS INTEGER)) AS bad
   FROM (SELECT key_string, bucket FROM capes_keys LIMIT 100000)", n_buckets
))$bad
stopifnot(rehash == 0L)

####################################################################
### Copias particionadas por bucket para o laco
####################################################################

invisible(dbExecute(con, "
  CREATE TEMP TABLE capes_var_keys AS
  SELECT k.person_key, k.bucket, k.key_string,
         v.variant, v.csur, v.n_parts, v.n_sur
  FROM capes_keys k JOIN capes_variants v USING (person_key)"))

for (nm in c("capes_var_keys", "rev_keys")) {
  d <- file.path(cache_dir, nm)
  if (dir.exists(d)) unlink(d, recursive = TRUE)
  invisible(dbExecute(con, sprintf(
    "COPY (SELECT * FROM %s) TO %s
     (FORMAT PARQUET, COMPRESSION ZSTD, PARTITION_BY bucket,
      OVERWRITE_OR_IGNORE)",
    nm, qp(d)
  )))
}

bucket_load <- dbGetQuery(con, "
  SELECT min(n) AS min_n, CAST(median(n) AS BIGINT) AS median_n,
         CAST(quantile_cont(n, 0.99) AS BIGINT) AS p99_n, max(n) AS max_n
  FROM (SELECT bucket, count(*) AS n FROM capes_var_keys GROUP BY bucket)")

####################################################################
### Etapa E -- o laco de 128 buckets, retomavel
####################################################################

cat("=========== LACO DE BUCKETS ===========\n")
t_loop <- Sys.time()
for (b in seq_len(n_buckets) - 1L) {
  f_pairs <- file.path(out_dir, "pairs", sprintf("bucket=%03d.parquet", b))
  f_best <- file.path(out_dir, "best", sprintf("bucket=%03d.parquet", b))
  if (file.exists(f_pairs) && file.exists(f_best)) next

  d_var <- file.path(cache_dir, "capes_var_keys", sprintf("bucket=%d", b))
  d_rev <- file.path(cache_dir, "rev_keys", sprintf("bucket=%d", b))

  if (dir.exists(d_var) && dir.exists(d_rev)) {
    src_var <- qp(file.path(d_var, "*.parquet"))
    src_rev <- qp(file.path(d_rev, "*.parquet"))
  } else {
    # Bucket vazio de um dos lados. Le a si mesmo com WHERE false para
    # manter exatamente o mesmo SQL e escrever um arquivo com o schema
    # certo, de modo que o laco siga retomavel.
    src_var <- qp(file.path(cache_dir, "capes_var_keys", "*", "*.parquet"))
    src_rev <- qp(file.path(cache_dir, "rev_keys", "*", "*.parquet"))
  }
  empty_guard <- if (dir.exists(d_var) && dir.exists(d_rev)) "" else
    " WHERE false"

  # Os tres escores saem de UMA passada sobre a mesma juncao.
  #   jw_combo    melhor combinacao x sobrenomes do LinkedIn
  #   jw_lastname melhor sobrenome isolado x ultimo token do LinkedIn
  #   jw_name     a regra ANTIGA: nome inteiro, primeiro nome incluido.
  #               O filtro (n_parts = 1 OR n_parts = n_sur) reconstroi
  #               exatamente o conjunto de variantes que ela usava.
  # coalesce para 0: jaro_winkler_similarity devolve NULL contra o
  # name_sur NULL de quem nao tem sobrenome, e max() de um grupo todo
  # NULL tambem e NULL.
  invisible(dbExecute(con, sprintf(
    "CREATE OR REPLACE TEMP TABLE best_pair AS
     SELECT person_key, user_id,
            coalesce(max(jw_combo), 0)          AS jw_combo,
            arg_max(variant, jw_combo)          AS best_variant,
            coalesce(max(jw_last)
                     FILTER (WHERE n_parts = 1), 0) AS jw_lastname,
            coalesce(max(jw_nm)
                     FILTER (WHERE n_parts = 1
                             OR n_parts = n_sur), 0) AS jw_name
     FROM (
       SELECT c.person_key, r.user_id, c.variant, c.n_parts, c.n_sur,
              jaro_winkler_similarity(c.csur, r.name_sur)     AS jw_combo,
              jaro_winkler_similarity(c.csur, r.name_last)    AS jw_last,
              jaro_winkler_similarity(c.variant, r.name_clean) AS jw_nm
       FROM read_parquet(%s) c
       JOIN read_parquet(%s) r ON c.key_string = r.key_string%s)
     GROUP BY person_key, user_id",
    src_var, src_rev, empty_guard
  )))

  # Portao de escrita: a UNIAO das duas regras. Guardar so o que
  # jw_combo aceita tornaria impossivel medir a regra antiga a partir
  # do arquivo, e vice-versa -- e o padrao sh_master / sh_master_strict
  # da pasta: apertar depois e um WHERE, nunca um re-run.
  invisible(dbExecute(con, sprintf(
    "COPY (SELECT person_key, user_id, jw_combo, jw_lastname, jw_name,
                  best_variant, %d::INTEGER AS bucket
           FROM best_pair
           WHERE jw_combo >= %.17g OR jw_name >= %.17g
           ORDER BY person_key, jw_combo DESC, user_id)
     TO %s (FORMAT PARQUET, COMPRESSION ZSTD)",
    b, jw_cut, jw_cut, qp(f_pairs))))

  invisible(dbExecute(con, sprintf(
    "COPY (SELECT person_key,
                  max(jw_combo)              AS best_jw,
                  arg_max(user_id, jw_combo) AS best_user_id,
                  count(*)                   AS n_bucket_mates,
                  %d::INTEGER                AS bucket
           FROM best_pair GROUP BY person_key ORDER BY person_key)
     TO %s (FORMAT PARQUET, COMPRESSION ZSTD)",
    b, qp(f_best))))

  if (b %% 16L == 0L) {
    cat(sprintf("  bucket %3d  %.1f s\n", b,
                as.numeric(difftime(Sys.time(), t_loop, units = "secs"))))
  }
}
cat(sprintf("laco completo em %.1f s\n\n",
            as.numeric(difftime(Sys.time(), t_loop, units = "secs"))))

####################################################################
### Etapa F -- consolidacao
###
### O ranking sai nas DUAS direcoes. Uma pessoa CAPES pode alcancar
### varios user_id e um user_id varias pessoas; colapsar uma direcao
### sem olhar a outra inventa identidade.
####################################################################

out_path <- file.path(out_dir, "capes_obmep_match_candidates.parquet")
unm_path <- file.path(out_dir, "capes_obmep_match_unmatched.csv")
sum_path <- file.path(out_dir, "capes_obmep_match_summary.csv")
keys_path <- file.path(out_dir, "capes_person_keys.parquet")
vars_path <- file.path(out_dir, "capes_name_variants.parquet")
revk_path <- file.path(out_dir, "revelio_user_keys.parquet")

for (p in c(out_path, unm_path, sum_path, keys_path, vars_path, revk_path)) {
  if (file.exists(paste0(p, ".part"))) unlink(paste0(p, ".part"))
}

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE pairs AS SELECT * FROM read_parquet(%s)",
  qp(file.path(out_dir, "pairs", "*.parquet"))
)))
invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE best_all AS SELECT * FROM read_parquet(%s)",
  qp(file.path(out_dir, "best", "*.parquet"))
)))

invisible(dbExecute(con, "
  CREATE TEMP TABLE crosswalk AS
  SELECT
    p.person_key, c.full_name AS capes_full_name, c.birth_year, c.first_name,
    c.msc_start_year AS capes_msc_start_year,
    c.msc_oa_id      AS capes_msc_oa_id,
    c.phd_start_year AS capes_phd_start_year,
    c.phd_oa_id      AS capes_phd_oa_id,
    p.user_id, r.fullname AS revelio_fullname,
    r.msc_start_year AS revelio_msc_start_year,
    r.msc_end_year   AS revelio_msc_end_year,
    r.msc_oa_id      AS revelio_msc_oa_id,
    r.phd_start_year AS revelio_phd_start_year,
    r.phd_end_year   AS revelio_phd_end_year,
    r.phd_oa_id      AS revelio_phd_oa_id,
    p.jw_combo, p.jw_lastname, p.jw_name, p.best_variant,
    r.name_sur AS revelio_surnames,
    p.bucket, c.key_string,
    dense_rank() OVER (PARTITION BY p.person_key
                       ORDER BY p.jw_combo DESC) AS user_rank,
    count(*)     OVER (PARTITION BY p.person_key)     AS n_users,
    dense_rank() OVER (PARTITION BY p.user_id
                       ORDER BY p.jw_combo DESC) AS person_rank,
    count(*)     OVER (PARTITION BY p.user_id)        AS n_persons
  FROM pairs p
  JOIN capes_keys c USING (person_key)
  JOIN rev_keys   r USING (user_id)"))

invisible(dbExecute(con, "
  CREATE TEMP TABLE unmatched AS
  SELECT b.person_key, c.full_name AS capes_full_name, c.birth_year,
         c.key_string, b.bucket, b.n_bucket_mates,
         b.best_jw AS best_jw_similarity,
         b.best_user_id, r.fullname AS best_revelio_fullname
  FROM best_all b
  JOIN capes_keys c USING (person_key)
  LEFT JOIN rev_keys r ON r.user_id = b.best_user_id
  WHERE b.person_key NOT IN (SELECT person_key FROM crosswalk)"))

xw_qa <- dbGetQuery(con, sprintf("
  SELECT count(*) AS pairs,
         count(DISTINCT person_key) AS capes_matched,
         count(DISTINCT user_id) AS users_matched,
         min(jw_combo) AS min_jw, max(jw_combo) AS max_jw,
         count_if(jw_combo < 0 OR jw_combo > 1
                  OR jw_lastname < 0 OR jw_lastname > 1
                  OR jw_name < 0 OR jw_name > 1) AS bad_jw,
         count_if(jw_combo < %1$.17g AND jw_name < %1$.17g) AS bad_gate,
         count(*) - count(DISTINCT (person_key, user_id)) AS dup_pairs,
         count_if(jw_combo >= %1$.17g) AS combo_pairs,
         count(DISTINCT person_key) FILTER (WHERE jw_combo >= %1$.17g)
           AS combo_persons,
         count(DISTINCT user_id) FILTER (WHERE jw_combo >= %1$.17g)
           AS combo_users,
         count_if(jw_combo >= %1$.17g AND jw_lastname >= %1$.17g)
           AS strict_pairs,
         count(DISTINCT person_key)
           FILTER (WHERE jw_combo >= %1$.17g AND jw_lastname >= %1$.17g)
           AS strict_persons,
         count_if(jw_name >= %1$.17g) AS legacy_pairs,
         count(DISTINCT person_key) FILTER (WHERE jw_name >= %1$.17g)
           AS legacy_persons
  FROM crosswalk", jw_cut))
unm_qa <- dbGetQuery(con, "
  SELECT count(*) AS rows, count(DISTINCT person_key) AS persons,
         (SELECT count(*) FROM unmatched u
          JOIN crosswalk x USING (person_key)) AS overlap
  FROM unmatched")

stopifnot(
  xw_qa$bad_jw == 0L, xw_qa$bad_gate == 0L, xw_qa$dup_pairs == 0L,
  unm_qa$rows == unm_qa$persons, unm_qa$overlap == 0L
)

# Um braco so pode ADICIONAR pares: relaxar a chave nao tira nada de
# ninguem, e os escores nao dependem da chave. Entao todo par
# conservador do canonico cuja pessoa tem o diploma do braco resolvido
# TEM de reaparecer aqui, com o mesmo escore. Isso e afirmado e nao
# deduzido -- e o mesmo teste que o 27b faz contra a variante _noinst,
# e e ele que pega um erro na edicao da chave.
if (match_arm != "both" && key_oa_ids && file.exists(canon_file)) {
  arm_superset <- dbGetQuery(con, sprintf("
    SELECT count(*) AS faltando FROM (
      SELECT person_key, CAST(user_id AS VARCHAR) AS user_id
      FROM read_parquet(%1$s)
      WHERE jw_combo >= %2$.17g AND jw_lastname >= %2$.17g
        AND capes_%3$s_start_year IS NOT NULL
        AND capes_%3$s_oa_id IS NOT NULL) c
    LEFT JOIN (
      SELECT person_key, CAST(user_id AS VARCHAR) AS user_id
      FROM crosswalk
      WHERE jw_combo >= %2$.17g AND jw_lastname >= %2$.17g) x
      USING (person_key, user_id)
    WHERE x.person_key IS NULL",
    qp(canon_file), jw_cut, match_arm))$faltando
  if (arm_superset != 0L) {
    stop(arm_superset, " par(es) conservador(es) do canonico com ",
         match_arm, " resolvido NAO estao neste braco. O braco tinha ",
         "de ser um superconjunto -- a edicao da chave quebrou algo.")
  }
  cat("[OK] braco e superconjunto do canonico no diploma ",
      match_arm, "\n", sep = "")
}

for (v in list(c("combo_pares", xw_qa$combo_pairs, exp_combo_pairs),
               c("combo_pessoas", xw_qa$combo_persons, exp_combo_persons),
               c("combo+ultimo_sobrenome", xw_qa$strict_pairs,
                 exp_strict_pairs),
               c("regra_antiga", xw_qa$legacy_pairs, exp_legacy_pairs))) {
  if (!is.na(v[3]) && v[3] != "NA" &&
      as.numeric(v[2]) != as.numeric(v[3])) {
    warning(v[1], " ", v[2], " != ", v[3], " medido.")
  }
}

####################################################################
### Escrita atomica
####################################################################

writes <- list(
  list(sql = "SELECT * FROM crosswalk
              ORDER BY person_key, jw_combo DESC, user_id",
       path = out_path, fmt = "(FORMAT PARQUET, COMPRESSION ZSTD)"),
  list(sql = "SELECT * FROM unmatched
              ORDER BY best_jw_similarity DESC NULLS LAST, person_key",
       path = unm_path, fmt = "(FORMAT CSV, HEADER, DELIMITER ',')"),
  list(sql = "SELECT * FROM capes_keys ORDER BY bucket, person_key",
       path = keys_path, fmt = "(FORMAT PARQUET, COMPRESSION ZSTD)"),
  list(sql = "SELECT * FROM capes_var_keys
              ORDER BY bucket, person_key, n_parts, csur",
       path = vars_path, fmt = "(FORMAT PARQUET, COMPRESSION ZSTD)"),
  list(sql = "SELECT * FROM rev_keys ORDER BY bucket, user_id",
       path = revk_path, fmt = "(FORMAT PARQUET, COMPRESSION ZSTD)")
)
for (w in writes) {
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO %s %s", w$sql, qp(paste0(w$path, ".part")), w$fmt
  )))
}

recheck <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM read_parquet(%s)", qp(paste0(out_path, ".part"))
))$n
stopifnot(recheck == xw_qa$pairs)

for (w in writes) {
  if (file.exists(w$path)) unlink(w$path)
  if (!file.rename(paste0(w$path, ".part"), w$path)) {
    stop("Nao foi possivel promover: ", w$path)
  }
}

####################################################################
### Escada de atrito -- o que cada posicao da chave custa
####################################################################

ladder <- dbGetQuery(con, "
  SELECT 'k1 primeiro nome' AS chave,
         (SELECT count(*) FROM capes_keys c
          WHERE EXISTS (SELECT 1 FROM rev_keys r
                        WHERE r.first_name = c.first_name))
           AS capes_alcancaveis,
         (SELECT count(*) FROM rev_keys r
          WHERE EXISTS (SELECT 1 FROM capes_keys c
                        WHERE c.first_name = r.first_name))
           AS users_alcancaveis
  UNION ALL
  SELECT 'k2 + anos de inicio',
         (SELECT count(*) FROM capes_keys c
          WHERE EXISTS (
            SELECT 1 FROM rev_keys r
            WHERE r.first_name = c.first_name
              AND r.msc_start_year IS NOT DISTINCT FROM c.msc_start_year
              AND r.phd_start_year IS NOT DISTINCT FROM c.phd_start_year)),
         (SELECT count(*) FROM rev_keys r
          WHERE EXISTS (
            SELECT 1 FROM capes_keys c
            WHERE c.first_name = r.first_name
              AND c.msc_start_year IS NOT DISTINCT FROM r.msc_start_year
              AND c.phd_start_year IS NOT DISTINCT FROM r.phd_start_year))
  UNION ALL
  SELECT 'k3 + openalex_id (chave cheia)',
         (SELECT count(*) FROM capes_keys c
          WHERE EXISTS (SELECT 1 FROM rev_keys r
                        WHERE r.key_string = c.key_string)),
         (SELECT count(*) FROM rev_keys r
          WHERE EXISTS (SELECT 1 FROM capes_keys c
                        WHERE c.key_string = r.key_string))")

slots <- dbGetQuery(con, "
  SELECT
    (SELECT count_if(msc_start_year IS NOT NULL) FROM capes_keys) AS c_msc_yr,
    (SELECT count_if(phd_start_year IS NOT NULL) FROM capes_keys) AS c_phd_yr,
    (SELECT count_if(msc_oa_id IS NOT NULL) FROM capes_keys) AS c_msc_oa,
    (SELECT count_if(phd_oa_id IS NOT NULL) FROM capes_keys) AS c_phd_oa,
    (SELECT count_if(msc_start_year IS NOT NULL) FROM rev_keys) AS r_msc_yr,
    (SELECT count_if(phd_start_year IS NOT NULL) FROM rev_keys) AS r_phd_yr,
    (SELECT count_if(msc_oa_id IS NOT NULL) FROM rev_keys) AS r_msc_oa,
    (SELECT count_if(phd_oa_id IS NOT NULL) FROM rev_keys) AS r_phd_oa")

# Pares comparados no nivel PESSOA x USER, e quantos deles jw_combo
# consegue pontuar (o resto e quem nao tem sobrenome no LinkedIn).
compared_qa <- dbGetQuery(con, "
  SELECT count(*) AS pares,
         count_if(r.name_sur IS NOT NULL) AS pontuaveis
  FROM (SELECT DISTINCT person_key, key_string FROM capes_var_keys) c
  JOIN rev_keys r ON c.key_string = r.key_string")
compared <- compared_qa$pares
if (!is.na(exp_pairs_compared) && compared != exp_pairs_compared) {
  warning("Pares comparados ", compared, " != ", exp_pairs_compared,
          " medido.")
}

n_key_capes <- dbGetQuery(
  con, "SELECT count(DISTINCT key_string) AS n FROM capes_keys")$n
n_key_rev <- dbGetQuery(
  con, "SELECT count(DISTINCT key_string) AS n FROM rev_keys")$n

summary_df <- data.frame(
  metrica = c(
    "capes_linhas", "capes_pessoas", "capes_pessoas_com_primeiro_nome",
    "capes_pessoas_multi_grafia", "capes_instituicoes",
    "capes_instituicoes_com_oa_id", "capes_variantes",
    "revelio_selecionados", "revelio_com_primeiro_nome",
    "buckets", "bucket_variantes_min", "bucket_variantes_mediana",
    "bucket_variantes_p99", "bucket_variantes_max",
    "chaves_distintas_capes", "chaves_distintas_revelio",
    "pares_comparados", "pares_pontuaveis_por_jw_combo",
    "users_sem_sobrenome", "pares_gravados_uniao",
    "combo_pares", "combo_pessoas", "combo_users",
    "combo_e_ultimo_sobrenome_pares", "combo_e_ultimo_sobrenome_pessoas",
    "regra_antiga_nome_inteiro_pares", "regra_antiga_nome_inteiro_pessoas",
    "capes_sem_par_com_colega_de_chave", "jw_cut"),
  valor = c(
    capes_qa$rows, capes_qa$persons, key_qa$capes_persons,
    capes_multi_name, capes_qa$institutions, oa_qa$rows, var_qa$variants,
    sel_qa$users, key_qa$rev_users,
    n_buckets, bucket_load$min_n, bucket_load$median_n,
    bucket_load$p99_n, bucket_load$max_n,
    n_key_capes, n_key_rev,
    compared, compared_qa$pontuaveis, sel_qa$no_surname, xw_qa$pairs,
    xw_qa$combo_pairs, xw_qa$combo_persons, xw_qa$combo_users,
    xw_qa$strict_pairs, xw_qa$strict_persons,
    xw_qa$legacy_pairs, xw_qa$legacy_persons,
    unm_qa$rows, jw_cut),
  stringsAsFactors = FALSE
)
write.csv(summary_df, paste0(sum_path, ".part"), row.names = FALSE)
if (file.exists(sum_path)) unlink(sum_path)
if (!file.rename(paste0(sum_path, ".part"), sum_path)) {
  stop("Nao foi possivel promover: ", sum_path)
}

####################################################################
### Relatorio
####################################################################

cat("=========== LADOS ===========\n")
cat("CAPES  linhas       :", capes_qa$rows, "\n")
cat("CAPES  pessoas      :", capes_qa$persons,
    " com primeiro nome:", key_qa$capes_persons, "\n")
cat("CAPES  variantes    :", var_qa$variants,
    sprintf("(%.2f por pessoa, max %d)", var_qa$per_person,
            var_qa$max_per_person), "\n")
cat("CAPES  multi-grafia :", capes_multi_name, "pessoas\n")
cat("Revelio selecionados:", sel_qa$users,
    " com primeiro nome:", key_qa$rev_users, "\n")

cat("\n=========== PREENCHIMENTO DAS POSICOES DA CHAVE ===========\n")
print(data.frame(
  posicao = c("msc_start_year", "phd_start_year", "msc_oa_id", "phd_oa_id"),
  capes = c(slots$c_msc_yr, slots$c_phd_yr, slots$c_msc_oa, slots$c_phd_oa),
  revelio = c(slots$r_msc_yr, slots$r_phd_yr, slots$r_msc_oa, slots$r_phd_oa)
), row.names = FALSE)

cat("\n=========== CARGA DOS", n_buckets, "BUCKETS (variantes) ===========\n")
print(bucket_load, row.names = FALSE)

cat("\n=========== ESCADA DE ATRITO ===========\n")
cat("(quantas pessoas de cada lado ainda ALCANCAM alguem do outro)\n")
print(ladder, row.names = FALSE)

cat("\n=========== RESULTADO ===========\n")
cat("pares comparados      :", compared,
    sprintf("(%d pontuaveis por jw_combo)", compared_qa$pontuaveis), "\n")
cat("pares gravados (uniao):", xw_qa$pairs, "\n")
cat("CAPES sem par mas com colega de chave:", unm_qa$rows, "\n")

cat("\n=========== AS TRES REGRAS, CORTE", jw_cut, "===========\n")
cat("(mesma juncao, mesmo corte -- so muda o que e comparado)\n")
print(data.frame(
  regra = c("jw_name  nome inteiro (antiga)",
            "jw_combo combinacoes s/ 1o nome",
            "  + jw_lastname tambem >= corte"),
  pares = c(xw_qa$legacy_pairs, xw_qa$combo_pairs, xw_qa$strict_pairs),
  pessoas = c(xw_qa$legacy_persons, xw_qa$combo_persons,
              xw_qa$strict_persons),
  stringsAsFactors = FALSE
), row.names = FALSE)
cat("\njw_combo pareia", xw_qa$combo_persons, "de", key_qa$capes_persons,
    sprintf("pessoas CAPES (%.3f%%) e",
            100 * xw_qa$combo_persons / key_qa$capes_persons),
    xw_qa$combo_users, "de", key_qa$rev_users,
    sprintf("users (%.3f%%)\n", 100 * xw_qa$combo_users / key_qa$rev_users))

if (xw_qa$combo_pairs > 0L) {
  cat("\n=========== O BALDE DE JULGAMENTO (nota 7) ===========\n")
  cat("jw_combo >= corte, separado pela concordancia do ULTIMO sobrenome\n")
  print(dbGetQuery(con, sprintf("
    SELECT CASE WHEN jw_lastname >= %1$.17g THEN 'ultimo sobrenome concorda'
                ELSE 'so nomes do meio -- JULGAR' END AS tipo,
           count(*) AS pares, count(DISTINCT person_key) AS pessoas,
           count(DISTINCT user_id) AS users,
           round(avg(jw_combo), 4) AS jw_medio
    FROM crosswalk WHERE jw_combo >= %1$.17g
    GROUP BY 1 ORDER BY pares DESC", jw_cut)), row.names = FALSE)

  cat("\n=========== DISTRIBUICAO DE jw_combo ===========\n")
  print(dbGetQuery(con, sprintf("
    SELECT CASE WHEN jw_combo = 1 THEN '1.00 exato'
                WHEN jw_combo >= 0.98 THEN '0.98-1.00'
                WHEN jw_combo >= 0.95 THEN '0.95-0.98'
                WHEN jw_combo >= 0.93 THEN '0.93-0.95'
                ELSE '0.90-0.93' END AS faixa,
           count(*) AS pares, count(DISTINCT person_key) AS pessoas
    FROM crosswalk WHERE jw_combo >= %.17g
    GROUP BY 1 ORDER BY 1 DESC", jw_cut)), row.names = FALSE)

  # n_users/n_persons contam as linhas do ARQUIVO, que e a uniao das
  # duas regras. O fan-out abaixo e recontado so sobre jw_combo >=
  # corte, senao o numero de manchete descreveria a regra antiga.
  cat("\n=========== FAN-OUT SOB jw_combo >= corte ===========\n")
  print(dbGetQuery(con, sprintf("
    WITH k AS (SELECT person_key, user_id FROM crosswalk
               WHERE jw_combo >= %.17g)
    SELECT 'user_id por pessoa CAPES' AS direcao, max(n) AS max_n,
           round(avg(n), 3) AS media, count_if(n > 1) AS mais_de_um
    FROM (SELECT person_key, count(*) AS n FROM k GROUP BY 1)
    UNION ALL
    SELECT 'pessoa CAPES por user_id', max(n), round(avg(n), 3),
           count_if(n > 1)
    FROM (SELECT user_id, count(*) AS n FROM k GROUP BY 1)", jw_cut)),
    row.names = FALSE)

  cat("\n=========== 20 PARES NO TOPO ===========\n")
  print(dbGetQuery(con, sprintf("
    SELECT capes_full_name, revelio_fullname, best_variant,
           revelio_surnames, round(jw_combo, 4) AS jw, n_users, n_persons
    FROM crosswalk WHERE jw_combo >= %.17g
    ORDER BY jw_combo DESC, person_key LIMIT 20", jw_cut)),
    row.names = FALSE)

  cat("\n=========== 20 PARES LOGO ACIMA DO CORTE ===========\n")
  print(dbGetQuery(con, sprintf("
    SELECT capes_full_name, revelio_fullname, best_variant,
           revelio_surnames, round(jw_combo, 4) AS jw, n_users, n_persons
    FROM crosswalk WHERE jw_combo >= %.17g
    ORDER BY jw_combo ASC, person_key LIMIT 20", jw_cut)),
    row.names = FALSE)

  cat("\n=========== 15 DO BALDE DE JULGAMENTO ===========\n")
  cat("(jw_combo passa, ultimo sobrenome NAO -- ver nota 7)\n")
  print(dbGetQuery(con, sprintf("
    SELECT capes_full_name, revelio_fullname, best_variant,
           revelio_surnames, round(jw_combo, 4) AS jw
    FROM crosswalk WHERE jw_combo >= %1$.17g AND jw_lastname < %1$.17g
    ORDER BY hash(person_key || user_id::VARCHAR) LIMIT 15", jw_cut)),
    row.names = FALSE)
}

cat("\nSaidas:\n")
for (p in c(out_path, unm_path, sum_path, keys_path, vars_path, revk_path)) {
  cat(sprintf("  %s  %.2f MB\n", p, file.size(p) / 1024^2))
}
if (!is.null(guarded_before)) {
  guarded_after <- file.info(guarded_files)[c("size", "mtime")]
  if (!identical(guarded_before, guarded_after)) {
    stop("A protected canonical product changed during this run. ",
         "This should never happen -- see the guard at the top.")
  }
  cat("[OK] protected canonical products intact (size and mtime checked)\n")
}

cat("\nTabela de CANDIDATOS, nao mapa 1:1. Trate n_users e n_persons\n")
cat("antes de qualquer join. Contem nome civil dos dois lados.\n")
if (!key_oa_ids) {
  cat("\n!!! VARIANTE SEM openalex_id NA CHAVE !!!\n")
  cat("Placebo medido: 57,6% dos pares sao reproduzidos dando a cada\n")
  cat("pessoa da CAPES o sobrenome de outro brasileiro. Isto e uma\n")
  cat("MEDICAO do que os openalex_id compram, nao uma tabela de\n")
  cat("pareamento. Nao consuma. Ver nota 9 do cabecalho.\n")
}
