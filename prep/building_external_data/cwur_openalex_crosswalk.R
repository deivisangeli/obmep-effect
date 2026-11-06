####################################################################
### CWUR Global 2000 -> OpenAlex
###
### Da um openalex_id as 2.000 instituicoes da lista Global 2000 do
### CWUR e grava:
###
###   cwur_ranking/cwur_openalex_2026.parquet           2.000 linhas
###   cwur_ranking/cwur_openalex_unmatched_2026.csv       149 x 5 linhas
###
### Local e OFFLINE. Nao usa rede: le o parquet do script anterior, o
### shanghai_ranking_oa.parquet do script 4 e o snapshot global de
### institutions do OpenAlex sob GT_ROOT. Nao pode ser copiado para
### scripts_sedap/ porque o snapshot e o Dropbox sao locais.
###
### POR QUE ESTE ARQUIVO EXISTE. Todo o lado institucional desta pasta e
### chaveado em OpenAlex, e o family_catalog do global_oa_hierarchy junta
### familia de ranking por oa_id, NUNCA por nome. O CWUR nao traz id
### nenhum: so nome, pais e posicao. Sem este crosswalk o CWUR nao junta
### com nada.
###
### O script 15a (RUF -> OpenAlex) e o parente proximo, mas ele resolve
### 23 instituicoes brasileiras e este resolve 2.000 em 94 paises. Duas
### consequencias:
###
###   - O pais deixa de ser enfeite e vira BLOQUEIO. Medido: o braco 2
###     tem 0 ambiguidades com bloqueio por ISO2 e 10 sem ele.
###   - A conferencia linha a linha do 15a nao escala. O que substitui
###     ela e a INJETIVIDADE do mapa mais a lista nomeada de excecoes.
###
### OITO BRACOS, todos igualdade EXATA depois de dobrar o nome. Vence o
### menor numero de braco e DENTRO do braco vencedor exige-se candidato
### UNICO - assercao, nao desempate.
###
###   dobra simples  lower(strip_accents(trim(x))), a mesma do 15a e do 16
###   dobra dura     alem disso tira 'the ' inicial, troca toda corrida
###                  de nao-alfanumerico por espaco e colapsa espacos
###
###   1. nome CWUR = shanghai_Name | display_name | cleaned_display_name
###      do shanghai_ranking_oa, herdando o OA_key .............. 923
###   2. nome CWUR = display_name do snapshot .................... 712
###   3. nome CWUR = um display_name_alternatives do snapshot .... 155
###   4. braco 1 sob a dobra dura ................................. 26
###   5. braco 2 sob a dobra dura ................................. 23
###   6. braco 3 sob a dobra dura .................................. 5
###   7. braco 2 contra registro do OpenAlex SEM pais .............. 5
###   8. braco 3 contra registro do OpenAlex SEM pais .............. 2
###      atribuidas A MAO, todas brasileiras (armadilha 5) .......... 7
###                                                            -------
###   resolvidos                                            1.858/2.000
###   residuo para revisao manual                                   142
###
### Os bracos 1 a 6 exigem pais igual; 7 e 8 existem so para os
### registros sem pais. A coluna revisar marca 4 a 8 e as linhas a mao:
### elas resolvem por evidencia mais fraca que a igualdade de nome
### dentro do pais, ou foram escritas por uma pessoa, e quem auditar o
### arquivo deve comecar por elas - sao 68 linhas, que cabem em uma
### tela, como as 4 do script 15a. A coluna fonte separa 'braco' de
### 'manual'.
###
### O braco 1 existe porque e quase de graca e herda ids que ALGUEM JA
### CUROU a mao: custa a leitura de um parquet pequeno e resolve 46% da
### lista antes de o snapshot ser aberto.
###
### CINCO ARMADILHAS, todas medidas:
###
###  1. O BLOQUEIO POR PAIS VALE ATE NO BRACO 1. Sem ele, o CWUR 341
###     'Northeastern University' (EUA) casa com DUAS da lista de
###     Xangai: Northeastern Boston (I12912129) e Northeastern Shenyang
###     (I9224756), porque o OpenAlex da o mesmo display_name as duas.
###     Bloquear o braco 1 pelo country_code do proprio arquivo de
###     Xangai - tolerando as 6 linhas em que ele e nulo - mantem os 923
###     casamentos e zera a ambiguidade.
###
###  2. O BLOQUEIO PRECISA DA EXCECAO DA CHINA. O CWUR lista Hong Kong,
###     Macau e Taiwan como 'China', e o OpenAlex guarda HK, MO e TW.
###     Sem a equivalencia CN ~ {HK, MO, TW} o bloqueio REJEITA
###     casamentos verdadeiros, a Universidade de Hong Kong entre eles.
###
###  3. O BRACO 3 PRODUZ EXATAMENTE UM FALSO POSITIVO E ELE NAO PODE SER
###     ACEITO CALADO. 'CINVESTAV' cai em I68368234, o mesmo id que o
###     braco 1 deu a 'National Polytechnic Institute', porque a lista de
###     nomes alternativos do IPN contem CINVESTAV. Sao instituicoes
###     diferentes. Quem pega isso e a checagem de injetividade, e a
###     colisao conhecida esta nomeada abaixo justamente para que uma
###     colisao DIFERENTE aborte.
###
###  4. 7.043 DOS 120.658 REGISTROS DO OPENALEX NAO TEM country_code.
###     Exigir pais igual descarta 7 casamentos obviamente certos -
###     Institute of Science Tokyo, National Kaohsiung University of
###     Science and Technology, Changchun University of Technology,
###     Alborz University of Medical Sciences, IFP School e mais dois
###     por nome alternativo, todos 'education' com milhares de works.
###     Mas simplesmente TOLERAR o nulo dentro do braco 2 cria uma
###     ambiguidade: um nome que casa com um registro do pais certo E
###     com um registro sem pais passa a ter dois candidatos. Por isso os
###     registros sem pais tem bracos proprios, 7 e 8, que so veem o
###     residuo dos seis primeiros. Medido: assim os 7 entram e a
###     ambiguidade continua zero em todos os oito bracos.
###
###  5. O CWUR ESCREVE EM INGLES E O OPENALEX BRASILEIRO SO TEM
###     PORTUGUES. Essa e a causa INTEIRA do residuo brasileiro: as 7
###     que sobraram - UFJF, CBPF, INPE, UEL, INPA, IMPA e ITA - existem
###     todas no OpenAlex, mas sob 'Universidade Federal de Juiz de
###     Fora', 'Centro Brasileiro de Pesquisas Fisicas' e assim por
###     diante, sem nenhum nome alternativo em ingles. NAO EXISTE regra
###     de igualdade de nome que as alcance, e similaridade e pior que
###     inutil aqui: o primeiro colocado do ITA e uma empresa de
###     tratamento de superficie com 2 works, contra os 11.513 do
###     registro certo. Por isso os 7 ids estao escritos a mao em
###     ids_manuais, cada um lido no snapshot e conferido por
###     works_count, e o ITA ainda por cima bate com o id que o script
###     15a atribuiu por um caminho totalmente independente. Eles NAO
###     sobrepoem braco nenhum: o script aborta se uma linha a mao cair
###     sobre uma linha que um braco ja resolveu.
###
### O RESIDUO NAO E RESOLVIDO POR SIMILARIDADE, E A MEDICAO DIZ POR QUE.
### Pontuando as 149 com o ajuste de Winkler do global_oa_hierarchy_sql.R
### sobre candidatos do mesmo pais, o primeiro colocado fica em >=0,95 em
### 32 linhas, 0,90-0,95 em 48, 0,85-0,90 em 39, 0,80-0,85 em 16 e abaixo
### de 0,80 em 14 - e o primeiro colocado ERRA EM TODAS AS FAIXAS,
### inclusive na mais alta: 'Pavol Jozef Safarik University in Kosice'
### pontua melhor contra 'Slovak Organization for Space Activities', e
### 'China Medical University, Taiwan' tira 0,971 contra a 'China
### Medical University' do continente, que e outra instituicao. Nao ha
### corte que separe as duas populacoes. Por isso a similaridade aqui e
### GERADOR DE CANDIDATO, nao regra de decisao, e o residuo sai em CSV
### com os 5 melhores candidatos por linha para uma passada manual
### posterior - o mesmo caminho do capes_openalex_manual_crosswalk.R.
###
### type NAO E FILTRO. Dos 1.858 casados, 1.818 sao 'education' e 40 nao:
### facility (22), healthcare (8), nonprofit (4), funder (4), government
### (1) e other (1). O CWUR classifica institutos de pesquisa - no Brasil
### sozinho, INPE, IMPA, CBPF, INPA e Fiocruz, quatro deles entre os 7
### escritos a mao -, entao exigir type='education' como o 15a faz
### derrubaria instituicao legitima. A coluna vai no arquivo para quem
### consumir decidir.
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}
library(DBI)
library(duckdb)

# As dobras, o bloqueio por pais, os oito bracos e a pontuacao da
# planilha vivem num arquivo de constantes, como no
# global_oa_hierarchy_sql.R, para que os testes exercitem o MESMO SQL que
# a producao.
sql_path <- Sys.getenv("OBMEP_CWUR_SQL",
                       unset = "prep/building_external_data/cwur_openalex_sql.R")
if (!file.exists(sql_path)) {
  stop("Nao achei ", sql_path,
       ". Rode a partir da raiz do repositorio ou aponte OBMEP_CWUR_SQL.")
}
source(sql_path)

####################################################################
### Parametros
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
gt_root    <- Sys.getenv("GT_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/GTAllocation")

edition <- 2026L

out_dir  <- file.path(obmep_root, "Data/intermediate/cwur_ranking")
cwur_path <- file.path(out_dir, sprintf("cwur_global_2000_%d.parquet", edition))
out_path  <- file.path(out_dir, sprintf("cwur_openalex_%d.parquet", edition))
unm_path  <- file.path(out_dir, sprintf("cwur_openalex_unmatched_%d.csv", edition))

sh_path <- file.path(obmep_root,
                     "Data/intermediate/shanghai_ranking/shanghai_ranking_oa.parquet")

oa_dir  <- file.path(gt_root, "Data/external/oa_snapshot/data/institutions")
oa_glob <- file.path(oa_dir, "updated_date=*/part_*.gz")

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "8GB")

# Valores medidos contra a edicao 2026 e o snapshot de fevereiro/2026.
exp_rows     <- 2000L
exp_sh_rows  <- 1079L
exp_oa_rows  <- 120658L
exp_arms     <- c(`1` = 923L, `2` = 712L, `3` = 155L, `4` = 26L,
                  `5` = 23L, `6` = 5L, `7` = 5L, `8` = 2L)
exp_manual   <- 7L
exp_matched  <- 1858L
exp_residue  <- 142L
exp_br_total <- 52L
exp_br_match <- 52L

# Ver armadilha 3. A unica colisao conhecida do mapa, nomeada para que
# uma colisao diferente aborte em vez de se esconder atras desta.
exp_collisions <- "I68368234"

# As 7 brasileiras que os oito bracos nao alcancam. Ver armadilha 5: o
# CWUR as escreve em INGLES e o OpenAlex so guarda o nome em PORTUGUES,
# sem alternativa em ingles, entao NAO EXISTE regra de nome que as pegue.
# Os ids foram lidos a mao no snapshot, conferidos por works_count, e a
# chave e o world_rank porque e o que nao muda de grafia.
ids_manuais <- c(
  "1102" = "I101100930",   # Universidade Federal de Juiz de Fora         36.475
  "1214" = "I4210125245",  # Centro Brasileiro de Pesquisas Fisicas       11.511
  "1382" = "I80849659",    # Instituto Nacional de Pesquisas Espaciais    20.338
  "1601" = "I127110123",   # Universidade Estadual de Londrina            41.034
  "1632" = "I187079419",   # Instituto Nacional de Pesquisas da Amazonia  24.131
  "1952" = "I141883831",   # Instituto Nacional de Matematica Pura e Apl.  4.483
  "2000" = "I107428990"    # Instituto Tecnologico de Aeronautica         11.513
)

# Quantos candidatos por linha do residuo vao para a planilha.
n_cand <- 5L

stopifnot(file.exists(cwur_path), file.exists(sh_path),
          dir.exists(oa_dir), length(Sys.glob(oa_glob)) > 0L)

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_cwur_oa")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

cat("CWUR", edition, "-> OpenAlex\n")
cat("cwur    :", cwur_path, "\n")
cat("xangai  :", sh_path, "\n")
cat("snapshot:", oa_dir, "\n")
cat("saida   :", out_path, "\n\n")

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

nul <- dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# temp_directory explicito: o derrame para disco nao pode cair em pasta
# sincronizada pelo Dropbox.
nul <- dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))
cat("DuckDB:", dbGetQuery(con, "SELECT version() AS v")$v, "\n")

####################################################################
### Entradas
####################################################################

nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE cwur AS SELECT * FROM read_parquet('%s')",
  gsub("\\\\", "/", cwur_path)))

nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE sh AS SELECT * FROM read_parquet('%s')",
  gsub("\\\\", "/", sh_path)))

# Projecao explicita, como no script 4: o leitor JSON ignora topics e
# counts_by_year, que respondem por quase todo o tamanho do registro.
# Deduplicacao por id mantendo a particao mais recente - o nome da pasta
# e ISO e ordena lexicograficamente.
nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE oa AS
  SELECT
    regexp_extract(id, 'I[0-9]+') AS oa_id,
    display_name, country_code, type, works_count,
    display_name_alternatives
  FROM (
    SELECT *, row_number() OVER (PARTITION BY id ORDER BY filename DESC) AS rn
    FROM read_ndjson('%s', filename = true, columns = {
      id: 'VARCHAR',
      display_name: 'VARCHAR',
      country_code: 'VARCHAR',
      type: 'VARCHAR',
      works_count: 'BIGINT',
      display_name_alternatives: 'VARCHAR[]'
    })
  ) WHERE rn = 1", gsub("\\\\", "/", oa_glob)))

n_cwur <- dbGetQuery(con, "SELECT count(*) n FROM cwur")$n
n_sh   <- dbGetQuery(con, "SELECT count(*) n FROM sh")$n
n_oa   <- dbGetQuery(con, "SELECT count(*) n FROM oa")$n

cat("cwur    :", n_cwur, "linhas\n")
cat("xangai  :", n_sh, "linhas\n")
cat("snapshot:", n_oa, "linhas\n\n")

stopifnot(n_cwur > 0L, n_sh > 0L, n_oa > 0L)
if (n_cwur != exp_rows) {
  stop("O parquet do CWUR tem ", n_cwur, " linhas e nao ", exp_rows,
       ". Rode cwur_global_2000.R de novo antes deste.")
}
if (n_sh != exp_sh_rows) {
  warning("shanghai_ranking_oa mudou de tamanho: ", n_sh, " linhas, esperado ",
          exp_sh_rows, ".")
}
if (n_oa != exp_oa_rows) {
  warning("O snapshot tem ", n_oa, " instituicoes, esperado ", exp_oa_rows,
          ". Snapshot novo?")
}

snapshot_date <- dbGetQuery(con, sprintf("
  SELECT max(regexp_extract(f, 'updated_date=([0-9-]+)', 1)) AS d
  FROM (SELECT unnest(['%s']) AS f)",
  paste(gsub("\\\\", "/", Sys.glob(oa_glob)), collapse = "','")))$d
cat("snapshot_date:", snapshot_date, "\n\n")

####################################################################
### Dobras e bloqueio por pais
####################################################################

for (m in cwur_macros_sql) nul <- dbExecute(con, m)

nul <- dbExecute(con, "
  CREATE OR REPLACE TABLE c AS
  SELECT world_rank, institution, country_iso2, cwur_slug,
         dobra(institution) AS f, dobra_dura(institution) AS h
  FROM cwur")

nul <- dbExecute(con, "
  CREATE OR REPLACE TABLE s AS
  SELECT OA_key AS oa_id, country_code,
         dobra(shanghai_Name) AS f1, dobra(display_name) AS f2,
         dobra(cleaned_display_name) AS f3,
         dobra_dura(shanghai_Name) AS h1, dobra_dura(display_name) AS h2
  FROM sh WHERE OA_key IS NOT NULL")

nul <- dbExecute(con, "
  CREATE OR REPLACE TABLE o AS
  SELECT oa_id, country_code, dobra(display_name) AS f,
         dobra_dura(display_name) AS h
  FROM oa")

nul <- dbExecute(con, "
  CREATE OR REPLACE TABLE alt AS
  SELECT oa_id, country_code, dobra(nome) AS f, dobra_dura(nome) AS h
  FROM (SELECT oa_id, country_code, unnest(display_name_alternatives) AS nome
        FROM oa)
  WHERE nome IS NOT NULL AND trim(nome) <> ''")

####################################################################
### Os seis bracos
####################################################################

# Cada braco so ve o que os anteriores nao resolveram, e devolve o
# numero de candidatos distintos junto com o id - e esse numero que a
# validacao usa para exigir candidato unico.
braco <- function(nome, sql) {
  dbExecute(con, sprintf("CREATE OR REPLACE TABLE %s AS %s", nome, sql))
  n <- dbGetQuery(con, sprintf("SELECT count(*) n FROM %s", nome))$n
  cat(sprintf("  braco %s: %5d\n", sub("^a", "", nome), n))
  invisible(n)
}

resolvidos <- function(ate) {
  if (ate < 1L) return("SELECT NULL::INTEGER AS world_rank WHERE FALSE")
  paste(sprintf("SELECT world_rank FROM a%d", seq_len(ate)), collapse = " UNION ")
}

cat("Bracos:\n")

for (i in seq_along(cwur_arms_sql)) {
  braco(names(cwur_arms_sql)[i], sprintf(cwur_arms_sql[[i]], resolvidos(i - 1L)))
}

nul <- dbExecute(con, "
  CREATE OR REPLACE TABLE bracos AS
  SELECT world_rank, oa_id, n_cand, 1 AS match_arm FROM a1
  UNION ALL SELECT world_rank, oa_id, n_cand, 2 FROM a2
  UNION ALL SELECT world_rank, oa_id, n_cand, 3 FROM a3
  UNION ALL SELECT world_rank, oa_id, n_cand, 4 FROM a4
  UNION ALL SELECT world_rank, oa_id, n_cand, 5 FROM a5
  UNION ALL SELECT world_rank, oa_id, n_cand, 6 FROM a6
  UNION ALL SELECT world_rank, oa_id, n_cand, 7 FROM a7
  UNION ALL SELECT world_rank, oa_id, n_cand, 8 FROM a8")

####################################################################
### As atribuicoes a mao
####################################################################

manuais <- data.frame(world_rank = as.integer(names(ids_manuais)),
                      oa_id      = unname(ids_manuais),
                      stringsAsFactors = FALSE)

# Nada aqui pode ser aceito de olhos fechados so porque foi escrito a
# mao. O id tem de existir no snapshot - id que ninguem resolve e pior
# que id nenhum -, o world_rank tem de existir na lista, e a linha NAO
# pode ja ter sido resolvida por um braco: o bloco escrito a mao nunca
# sobrepoe uma regra medida em silencio.
stopifnot(!any(duplicated(manuais$world_rank)),
          !any(duplicated(manuais$oa_id)),
          all(grepl("^I[0-9]+$", manuais$oa_id)))

dbWriteTable(con, "manuais", manuais, overwrite = TRUE)

fora_lista <- dbGetQuery(con, "
  SELECT count(*) n FROM manuais m
  WHERE NOT EXISTS (SELECT 1 FROM c WHERE c.world_rank = m.world_rank)")$n
ja_resolvido <- dbGetQuery(con, "
  SELECT count(*) n FROM manuais m
  WHERE EXISTS (SELECT 1 FROM bracos b WHERE b.world_rank = m.world_rank)")$n
sem_snapshot <- dbGetQuery(con, "
  SELECT count(*) n FROM manuais m
  WHERE NOT EXISTS (SELECT 1 FROM oa WHERE oa.oa_id = m.oa_id)")$n

if (fora_lista)   stop(fora_lista, " atribuicao(oes) a mao apontam para um ",
                       "world_rank que nao existe na lista CWUR ", edition, ".")
if (ja_resolvido) stop(ja_resolvido, " atribuicao(oes) a mao repetem uma linha ",
                       "que um braco ja resolveu. Confira antes de sobrepor.")
if (sem_snapshot) stop(sem_snapshot, " atribuicao(oes) a mao usam um oa_id ",
                       "ausente do snapshot. Ninguem inventa identificador.")

nul <- dbExecute(con, "
  CREATE OR REPLACE TABLE casados AS
  SELECT world_rank, oa_id, n_cand, match_arm, 'braco' AS fonte FROM bracos
  UNION ALL
  SELECT world_rank, oa_id, 1 AS n_cand, NULL::INTEGER AS match_arm, 'manual'
  FROM manuais")

cat("  a mao  :", nrow(manuais), "\n")

####################################################################
### Validacao
####################################################################

# As linhas escritas a mao entram como 'manual' em vez de um numero de
# braco, para que a divisao por braco continue comparavel com o medido.
arm_split <- dbGetQuery(con, "
  SELECT coalesce(CAST(match_arm AS VARCHAR), fonte) AS braco,
         count(*) AS n, sum((n_cand > 1)::INT) AS ambiguos
  FROM casados GROUP BY 1 ORDER BY 1")

cat("\n")
print(arm_split, right = FALSE)

n_match <- sum(arm_split$n)
n_resid <- n_cwur - n_match
cat("\ncasados:", n_match, "de", n_cwur,
    sprintf("(%.1f%%)", 100 * n_match / n_cwur), "| residuo:", n_resid, "\n")

# Estrutural: aborta. Nenhuma linha do CWUR pode ser reivindicada por
# dois bracos, e dentro do braco vencedor o candidato tem de ser unico -
# escolher um vencedor em silencio e exatamente a falha que se quer pegar.
dupes <- dbGetQuery(con, "
  SELECT count(*) n FROM (
    SELECT world_rank FROM casados GROUP BY 1 HAVING count(*) > 1)")$n
ambiguos <- sum(arm_split$ambiguos)
mal_formado <- dbGetQuery(con, "
  SELECT count(*) n FROM casados WHERE oa_id IS NULL
     OR NOT regexp_matches(oa_id, '^I[0-9]+$')")$n
fora_snapshot <- dbGetQuery(con, "
  SELECT count(*) n FROM casados m
  WHERE NOT EXISTS (SELECT 1 FROM oa WHERE oa.oa_id = m.oa_id)")$n

stopifnot(dupes == 0L, ambiguos == 0L, mal_formado == 0L, fora_snapshot == 0L)

# Injetividade. Duas instituicoes do CWUR nunca deveriam colapsar no
# mesmo id; a unica colisao conhecida e a do IPN/CINVESTAV (armadilha 3),
# e ela esta nomeada para que uma colisao DIFERENTE aborte.
colisoes <- dbGetQuery(con, "
  SELECT oa_id, count(*) AS n FROM casados GROUP BY 1 HAVING count(*) > 1
  ORDER BY oa_id")

if (nrow(colisoes)) {
  cat("\nIds reivindicados por mais de uma instituicao do CWUR:\n")
  print(dbGetQuery(con, sprintf("
    SELECT m.oa_id, m.match_arm, c.world_rank, c.institution, c.country_iso2,
           o.display_name
    FROM casados m JOIN c USING(world_rank) JOIN oa o ON o.oa_id = m.oa_id
    WHERE m.oa_id IN ('%s')
    ORDER BY m.oa_id, c.world_rank",
    paste(colisoes$oa_id, collapse = "','"))), right = FALSE)
}

if (!identical(sort(colisoes$oa_id), sort(exp_collisions))) {
  stop("Colisao de id fora da lista conhecida: ",
       paste(setdiff(colisoes$oa_id, exp_collisions), collapse = ", "),
       ". Ver armadilha 3 no cabecalho antes de mexer em qualquer braco.")
}

# Deriva: reporta.
medido <- setNames(arm_split$n, arm_split$braco)
n_manual <- sum(arm_split$n[arm_split$braco == "manual"])
if (n_manual != exp_manual) {
  warning("Atribuicoes a mao: ", n_manual, ", esperado ", exp_manual, ".")
}
if (!identical(as.integer(medido[names(exp_arms)]), as.integer(exp_arms))) {
  warning("Divisao por braco mudou: ",
          paste(sprintf("%s=%d", names(medido), medido), collapse = ", "),
          "; esperado ",
          paste(sprintf("%s=%d", names(exp_arms), exp_arms), collapse = ", "))
}
if (n_match != exp_matched || n_resid != exp_residue) {
  warning("Casados ", n_match, " e residuo ", n_resid, ", esperado ",
          exp_matched, " e ", exp_residue, ".")
}

tipos <- dbGetQuery(con, "
  SELECT o.type, count(*) AS n FROM casados m JOIN oa o ON o.oa_id = m.oa_id
  GROUP BY 1 ORDER BY 2 DESC")
cat("\ntype das instituicoes casadas (nao e filtro; ver cabecalho):\n")
print(tipos, right = FALSE)

br <- dbGetQuery(con, "
  SELECT count(*) AS total,
         sum((c.world_rank IN (SELECT world_rank FROM casados))::INT) AS casadas
  FROM c WHERE c.country_iso2 = 'BR'")
cat("\nBrasil:", br$casadas, "de", br$total, "\n")
if (br$total != exp_br_total || br$casadas != exp_br_match) {
  warning("Brasil: ", br$casadas, " de ", br$total, ", esperado ",
          exp_br_match, " de ", exp_br_total, ".")
}

####################################################################
### Produto
####################################################################

# Todas as 2.000 linhas saem, com oa_id nulo no residuo: o arquivo e o
# retrato da lista inteira, e nao so da parte resolvida. Quem consome
# filtra por 'casada'.
nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE produto AS
  SELECT
    %d                          AS edition,
    c.world_rank,
    c.institution,
    c.country_iso2,
    c.cwur_slug,
    m.oa_id IS NOT NULL         AS casada,
    m.match_arm,
    m.fonte,
    -- Bracos 4 a 8 resolvem por evidencia mais fraca que igualdade de
    -- nome dentro do pais, e as linhas a mao sao justamente as que uma
    -- pessoa escreveu. As duas publicam, marcadas para leitura.
    coalesce(m.match_arm >= 4, m.fonte = 'manual', FALSE) AS revisar,
    m.oa_id,
    o.display_name,
    o.type                      AS oa_type,
    o.country_code              AS oa_country_code,
    o.works_count,
    '%s'                        AS snapshot_date
  FROM c
  LEFT JOIN casados m USING(world_rank)
  LEFT JOIN oa o ON o.oa_id = m.oa_id
  ORDER BY c.world_rank", edition, snapshot_date))

stopifnot(dbGetQuery(con, "SELECT count(*) n FROM produto")$n == n_cwur)

nul <- dbExecute(con, sprintf(
  "COPY produto TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  gsub("\\\\", "/", out_path)))

####################################################################
### Planilha do residuo
####################################################################

# Jaro mais o ajuste de Winkler do global_oa_hierarchy_sql.R - p=0,1,
# prefixo <= 4, so quando Jaro > 0,7 -, para que as duas rotinas ordenem
# candidato do mesmo jeito. SUGESTAO, NAO DECISAO: ver o paragrafo sobre
# o residuo no cabecalho.
nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE residuo AS %s", sprintf(cwur_worksheet_sql, n_cand)))

res_stats <- dbGetQuery(con, "
  SELECT count(DISTINCT world_rank) AS linhas, count(*) AS candidatos
  FROM residuo")

cat("\nresiduo:", res_stats$linhas, "instituicoes,", res_stats$candidatos,
    "candidatos\n")

if (res_stats$linhas != n_resid) {
  warning("O residuo tem ", n_resid, " instituicoes mas so ",
          res_stats$linhas, " receberam candidato do mesmo pais.")
}

faixas <- dbGetQuery(con, "
  SELECT CASE WHEN jw >= 0.95 THEN '>=0.95'
              WHEN jw >= 0.90 THEN '0.90-0.95'
              WHEN jw >= 0.85 THEN '0.85-0.90'
              WHEN jw >= 0.80 THEN '0.80-0.85'
              ELSE '<0.80' END AS faixa,
         count(*) AS n
  FROM residuo WHERE candidato = 1 GROUP BY 1 ORDER BY 1 DESC")
cat("Melhor candidato por faixa de jw (sugestao, nao decisao):\n")
print(faixas, right = FALSE)

nul <- dbExecute(con, sprintf("
  COPY residuo TO '%s' (FORMAT CSV, HEADER, DELIMITER ',')",
  gsub("\\\\", "/", unm_path)))

####################################################################
### Releitura
####################################################################

df <- arrow::read_parquet(out_path)
cat("\nreleitura arrow:", nrow(df), "linhas,", ncol(df), "colunas\n")
stopifnot(nrow(df) == n_cwur,
          sum(df$casada) == n_match,
          sum(df$fonte == "manual", na.rm = TRUE) == nrow(manuais),
          all(c("oa_id", "match_arm", "fonte", "casada", "revisar", "world_rank")
              %in% names(df)))

# Ancoras nomeadas, no espirito do script 15a: assim uma mudanca diz QUAL
# instituicao se mexeu, e nao so que um total mudou.
ancoras <- c("Harvard University"      = "I136199984",
             "University of São Paulo" = "I17974374",
             "Tsinghua University"     = "I99065089")
for (nm in names(ancoras)) {
  got <- df$oa_id[df$institution == nm]
  if (length(got) != 1L || !identical(got, unname(ancoras[nm]))) {
    stop("Ancora ", nm, " resolveu para ", paste(got, collapse = ", "),
         " e nao ", ancoras[nm], ".")
  }
}
cat("ancoras conferidas:", paste(names(ancoras), collapse = ", "), "\n")

# As linhas escritas a mao saem inteiras: sao 7, cabem na tela, e a
# conferencia delas e olhar o nome em ingles ao lado do nome em
# portugues do OpenAlex com o works_count do lado.
cat("\nAtribuidas a mao (ver armadilha 5):\n")
print(df[!is.na(df$fonte) & df$fonte == "manual",
         c("world_rank", "institution", "oa_id", "display_name",
           "oa_type", "works_count")], right = FALSE, row.names = FALSE)

cat("\nBrasil, as 10 primeiras:\n")
brdf <- df[df$country_iso2 == "BR", ]
print(head(brdf[order(brdf$world_rank),
                c("world_rank", "institution", "match_arm", "oa_id",
                  "display_name")], 10), right = FALSE)

cat("\nGravado:", out_path, "\n")
cat("tamanho:", round(file.size(out_path) / 1024, 1), "KB\n")
cat("residuo:", unm_path, "\n")
