####################################################################
### 27b. Placebo do pareamento CAPES x candidatos selecionados
### Quanto dos 14,1% e coincidencia?
###
### Pipeline local e OFFLINE. Le SO os tres produtos que o script 27
### ja gravou -- nao reescaneia a educacao nem o CSV da CAPES, nao usa
### rede e NAO deve ser enviado nem executado no SEDAP. E READ-ONLY em
### relacao ao pipeline: nao altera nada, como o script 17.
###
### A PERGUNTA
### O produto conservador do 27 pareia 79.764 das 567.270 pessoas da
### CAPES (14,1%) e 84.299 dos 149.887 users que tem um diploma
### brasileiro resolvivel (56,2%). A taxa NAO e plana -- e zero antes
### de 2010, tem pico de ~17% em 2016-2019 e cai para 9,4% em 2024 --
### o que parece sinal e nao ruido. Mas ninguem MEDIU a taxa de falso
### positivo. Isto mede.
###
### O METODO: destruir o vinculo verdadeiro e contar sobreviventes.
###
###   BRACO A -- desloca os anos da CAPES em K.
###     Um par verdadeiro nao pode sobreviver: o ano ficou errado.
###     Quem casar e coincidencia -- mesmo primeiro nome, mesmos anos
###     (deslocados), mesmos openalex_id e um sobrenome >= 0,90.
###     Isola a contribuicao do ANO.
###
###   BRACO B -- permuta os sobrenomes DENTRO do mesmo primeiro nome.
###     A chave fica byte a byte igual; so muda de quem sao os
###     sobrenomes. Responde a pergunta que importa: dado tudo o que a
###     chave ja sabe, o sobrenome carrega informacao, ou o sobrenome
###     de um brasileiro qualquer teria casado tanto quanto?
###     Isola a contribuicao do NOME. E o braco mais afiado.
###
### CAUTION / LIMITATIONS
###   1. O BRACO K = 0 TEM de reproduzir o resultado real (87.110
###      pares, 79.764 pessoas). Se nao reproduzir, a construcao da
###      chave aqui divergiu do script 27 e TODO o resto da rodada
###      perde sentido. Por isso aborta, nao avisa. E a checagem mais
###      importante do script.
###   2. Deslocar o ano tambem muda o TAMANHO dos blocos: a
###      distribuicao de ano de inicio da CAPES esta longe de uniforme
###      (57.328 em 2024 contra 1 em 2000). Cada K sai em linha
###      propria e NUNCA e agregado numa manchete so.
###   3. O braco A mantem os openalex_id intactos, entao isola so o
###      ano. O braco B isola so o nome. NENHUM braco isola a
###      instituicao, e nenhum aqui consegue.
###   4. Placebo baixo LIMITA o falso positivo; nao prova que os
###      sobreviventes estao certos. So o caderno de 100 linhas do
###      script 27a fala disso, e ele ainda esta em branco. Os dois se
###      complementam: o placebo mede quanto dos 14,1% e coincidencia,
###      o caderno mede se o resto e mesmo a mesma pessoa.
###   5. Pessoas cujo primeiro nome e unico na CAPES nao podem ser
###      permutadas no braco B. Sao contadas e excluidas, e a taxa do
###      braco B e sobre a base permutavel.
###   6. O EXCEDENTE (real menos placebo) e estimador de primeira
###      ordem, NAO identidade. Supoe que o falso positivo tem a mesma
###      magnitude nas duas rodadas; o braco B segura bloco e
###      distribuicao de sobrenomes, o que aproxima isso, mas um
###      casamento verdadeiro pode ocupar a vaga de um falso, entao
###      nao somam exatamente. Tambem NAO valida os sobreviventes: um
###      erro sistematico -- uma instituicao resolvida errado, por
###      exemplo -- e invisivel para a permutacao. E nao e limitado
###      por baixo: se algum braco desse excedente negativo, isso sai
###      como esta, sem truncar, porque significaria que o braco esta
###      medindo algo quebrado.
###
### Depends on:
###   prep/building_external_data/capes_obmep_candidates_name_match.R (27)
###
### Outputs (Data/intermediate/capes_discentes/capes_obmep_match/):
###   capes_obmep_match_placebo.parquet
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
# A mesma chave do script 27: env OBMEP_MATCH_KEY_OA decide qual das
# duas variantes e medida. O placebo le so o que aquele script gravou,
# entao basta apontar para o diretorio certo.
key_oa_ids <- Sys.getenv("OBMEP_MATCH_KEY_OA", unset = "1") != "0"
variant_tag <- if (key_oa_ids) "" else "_noinst"

out_dir <- file.path(
  obmep_root, "Data/intermediate/capes_discentes",
  paste0("capes_obmep_match", variant_tag))

canon_dir <- file.path(obmep_root,
                       "Data/intermediate/capes_discentes/capes_obmep_match")

keys_path <- file.path(out_dir, "capes_person_keys.parquet")
vars_path <- file.path(out_dir, "capes_name_variants.parquet")
revk_path <- file.path(out_dir, "revelio_user_keys.parquet")
out_path <- file.path(out_dir, "capes_obmep_match_placebo.parquet")
out_part <- paste0(out_path, ".part")

# Tem de bater com o script 27, ou o placebo deixa de ser comparavel
# com aquilo que ele mede.
jw_cut <- 0.90
n_buckets <- 128L

shifts <- c(-7L, -5L, -3L, 3L, 5L, 7L)
perm_offsets <- 1:5

# Medidos em 2026-09-06 sobre a rodada real do script 27.
if (key_oa_ids) {
  exp_real_pairs <- 87110L
  exp_real_people <- 79764L
  exp_real_users <- 84299L
} else {
  exp_real_pairs <- 282769L
  exp_real_people <- 164747L
  exp_real_users <- 117644L
}

mem_limit <- if (key_oa_ids) "10GB" else "16GB"
tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_capes_obmep_placebo")

stopifnot(
  file.exists(keys_path), file.exists(vars_path), file.exists(revk_path)
)
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
if (file.exists(out_part)) unlink(out_part)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

invisible(dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit)))
invisible(dbExecute(
  con, sprintf("SET temp_directory=%s",
               as.character(dbQuoteString(con, tmp_dir)))
))
invisible(dbExecute(con, "SET preserve_insertion_order=false"))

qp <- function(path) {
  as.character(dbQuoteString(con, gsub("\\\\", "/", path)))
}

cat("Placebo do pareamento CAPES x candidatos selecionados\n")
cat("entrada :", out_dir, "\n")
cat("corte   : jw_combo >=", jw_cut, "E jw_lastname >=", jw_cut, "\n")
cat("variante:", if (key_oa_ids) "canonica" else "SEM openalex_id", "\n")
cat("DuckDB  :", dbGetQuery(con, "SELECT version() AS v")$v, "\n\n")

invisible(dbExecute(con, sprintf(
  "CREATE TABLE ck AS SELECT person_key, first_name, msc_start_year,
          msc_oa_id, phd_start_year, phd_oa_id, key_string AS key_real
   FROM read_parquet(%s)", qp(keys_path))))
invisible(dbExecute(con, sprintf(
  "CREATE TABLE cvraw AS SELECT person_key, csur, n_parts, n_sur
   FROM read_parquet(%s)", qp(vars_path))))
invisible(dbExecute(con, sprintf(
  "CREATE TABLE rev AS SELECT CAST(user_id AS VARCHAR) AS user_id,
          key_string, name_sur, name_last
   FROM read_parquet(%s)", qp(revk_path))))

base_qa <- dbGetQuery(con, "
  SELECT (SELECT count(*) FROM ck) AS capes_pessoas,
         (SELECT count(*) FROM cvraw) AS variantes,
         (SELECT count(*) FROM rev) AS users")
cat("pessoas CAPES:", base_qa$capes_pessoas, " variantes:", base_qa$variantes,
    " users:", base_qa$users, "\n\n")

####################################################################
### A chave, identica a do script 27
###
### concat_ws() DESCARTA NULL: todo campo e coalesce()-ado para 'NA'
### ANTES de entrar. As posicoes 3 e 5 sao os anos de fim, sempre 'NA'
### -- ver limitacao 2 do script 27.
####################################################################

key_tpl <- sprintf(paste0(
  "concat_ws('-',
     coalesce(first_name, 'NA'),
     coalesce(CAST(%%s AS VARCHAR), 'NA'),
     'NA',
     coalesce(CAST(%%s AS VARCHAR), 'NA'),
     'NA',
     %s,
     %s)"),
  if (key_oa_ids) "coalesce(msc_oa_id, 'NA')" else "'NA'",
  if (key_oa_ids) "coalesce(phd_oa_id, 'NA')" else "'NA'")

####################################################################
### Uma passada de pontuacao. cvar tem (person_key, key_string, csur,
### n_parts). O resto e copia literal da agregacao do script 27.
####################################################################

score_one <- function(label, param) {
  invisible(dbExecute(con, sprintf(
    "CREATE OR REPLACE TABLE res AS
     SELECT person_key, user_id,
            coalesce(max(jw_c), 0) AS jw_combo,
            coalesce(max(jw_l) FILTER (WHERE n_parts = 1), 0) AS jw_lastname
     FROM (
       SELECT c.person_key, r.user_id, c.n_parts,
              jaro_winkler_similarity(c.csur, r.name_sur)  AS jw_c,
              jaro_winkler_similarity(c.csur, r.name_last) AS jw_l
       FROM cvar c JOIN rev r ON c.key_string = r.key_string)
     GROUP BY person_key, user_id")))
  q <- dbGetQuery(con, sprintf(
    "SELECT count(*) AS pares,
            count(DISTINCT person_key) AS pessoas,
            count(DISTINCT user_id) AS users
     FROM res WHERE jw_combo >= %1$.17g AND jw_lastname >= %1$.17g", jw_cut))
  data.frame(braco = label, parametro = param, pares = q$pares,
             pessoas = q$pessoas, users = q$users, stringsAsFactors = FALSE)
}

####################################################################
### Braco de sanidade: K = 0 tem de reproduzir a rodada real
### Limitacao 1.
####################################################################

build_shift <- function(k) {
  ke <- sprintf(key_tpl,
                if (k == 0L) "msc_start_year" else
                  sprintf("msc_start_year + %d", k),
                if (k == 0L) "phd_start_year" else
                  sprintf("phd_start_year + %d", k))
  invisible(dbExecute(con, sprintf(
    "CREATE OR REPLACE TABLE cvar AS
     SELECT k.person_key, k.key_new AS key_string, v.csur, v.n_parts, v.n_sur
     FROM (SELECT person_key, %s AS key_new FROM ck) k
     JOIN cvraw v USING (person_key)", ke)))
}

cat("=========== BRACO DE SANIDADE (K = 0) ===========\n")
build_shift(0L)

# A chave reconstruida tem de ser byte a byte a que o script 27 gravou.
drift <- dbGetQuery(con, "
  SELECT count(*) AS divergentes FROM (
    SELECT DISTINCT c.person_key, c.key_string FROM cvar c) x
  JOIN ck k USING (person_key)
  WHERE x.key_string IS DISTINCT FROM k.key_real")$divergentes
if (drift != 0L) {
  stop("A chave reconstruida diverge da gravada pelo script 27 em ",
       drift, " pessoa(s). O placebo nao mede o que deveria -- nota 1.")
}
bucket_bad <- dbGetQuery(con, sprintf(
  "SELECT count_if(CAST(hash(key_string) %% %d AS INTEGER) NOT BETWEEN 0 AND %d)
     AS bad FROM cvar", n_buckets, n_buckets - 1L))$bad
stopifnot(bucket_bad == 0L)

real <- score_one("real", "K = 0")
cat("pares:", real$pares, " pessoas:", real$pessoas, " users:", real$users,
    "\n")
if (real$pares != exp_real_pairs || real$pessoas != exp_real_people ||
    real$users != exp_real_users) {
  stop("K = 0 devolveu ", real$pares, "/", real$pessoas, "/", real$users,
       " e a rodada real foi ", exp_real_pairs, "/", exp_real_people, "/",
       exp_real_users, ". A construcao da chave divergiu do script 27 e ",
       "nenhum numero desta rodada vale -- nota 1.")
}
cat("[OK] o placebo reproduz a rodada real; os bracos abaixo sao ",
    "comparaveis\n\n", sep = "")

####################################################################
### Braco A -- deslocar os anos
####################################################################

cat("=========== BRACO A: ANOS DESLOCADOS ===========\n")
arm_a <- do.call(rbind, lapply(shifts, function(k) {
  build_shift(k)
  r <- score_one("A_ano_deslocado", sprintf("K = %+d", k))
  cat(sprintf("  K = %+d  pares %6d  pessoas %6d  users %6d  (%.2f%% do real)\n",
              k, r$pares, r$pessoas, r$users,
              100 * r$pessoas / real$pessoas))
  r
}))

####################################################################
### Braco B -- permutar sobrenomes dentro do mesmo primeiro nome
###
### A rotacao por posto de hash e deterministica: nao usa set.seed e
### reproduz igual em toda rodada. Grupos de tamanho 1 nao permutam.
####################################################################

cat("\n=========== BRACO B: SOBRENOMES PERMUTADOS ===========\n")

invisible(dbExecute(con, "
  CREATE OR REPLACE TABLE rk AS
  SELECT person_key, first_name,
         row_number() OVER (PARTITION BY first_name
                            ORDER BY hash(person_key || '#perm'),
                                     person_key) AS r,
         count(*) OVER (PARTITION BY first_name) AS n
  FROM ck"))

# a fica com a PROPRIA chave e recebe os nomes de b, o vizinho na
# rotacao j. n >= 2 e b.r <> a.r garantem que ninguem doa para si.
#
# CINCO DESLOCAMENTOS, nao um. Um placebo pontual nao diz nada sobre a
# propria precisao, e a comparacao entre variantes da chave depende
# justamente de saber se a diferenca entre elas e maior que o ruido do
# estimador. O deslocamento 1 e a MANCHETE -- e o numero que todos os
# outros artefatos citam -- e os outros quatro existem para limita-lo.
build_perm <- function(j) {
  invisible(dbExecute(con, sprintf(
    "CREATE OR REPLACE TABLE perm AS
     SELECT a.person_key AS person_key, b.person_key AS donor_key
     FROM rk a JOIN rk b
       ON a.first_name = b.first_name
      AND b.r = ((a.r - 1 + %d) %% a.n) + 1
     WHERE a.n >= 2 AND b.r <> a.r", j)))
  invisible(dbExecute(con, sprintf(
    "CREATE OR REPLACE TABLE cvar AS
     SELECT p.person_key, k.key_new AS key_string, v.csur, v.n_parts, v.n_sur
     FROM perm p
     JOIN (SELECT person_key, %s AS key_new FROM ck) k
       ON k.person_key = p.person_key
     JOIN cvraw v ON v.person_key = p.donor_key",
    sprintf(key_tpl, "msc_start_year", "phd_start_year"))))
}

build_perm(perm_offsets[1])

perm_qa <- dbGetQuery(con, "
  SELECT (SELECT count(*) FROM perm) AS permutaveis,
         (SELECT count(*) FROM ck) AS total,
         (SELECT count_if(person_key = donor_key) FROM perm) AS auto_doacao")
stopifnot(perm_qa$auto_doacao == 0L)
cat("permutaveis:", perm_qa$permutaveis, "de", perm_qa$total,
    sprintf("(%.1f%%); %d com primeiro nome unico, fora do braco\n",
            100 * perm_qa$permutaveis / perm_qa$total,
            perm_qa$total - perm_qa$permutaveis))

# A chave TEM de continuar byte a byte igual: a permutacao so pode ter
# tocado nos nomes.
key_moved <- dbGetQuery(con, "
  SELECT count(*) AS n FROM (SELECT DISTINCT person_key, key_string FROM cvar) x
  JOIN ck k USING (person_key)
  WHERE x.key_string IS DISTINCT FROM k.key_real")$n
if (key_moved != 0L) {
  stop("A permutacao mexeu na chave de ", key_moved, " pessoa(s). O braco B ",
       "so pode trocar nomes.")
}

arm_b_all <- do.call(rbind, lapply(perm_offsets, function(j) {
  build_perm(j)
  r <- score_one("B_sobrenome_permutado", sprintf("rotacao j=%d", j))
  cat(sprintf("  j = %d  pares %7d  pessoas %7d  users %7d  (%.2f%% do real)\n",
              j, r$pares, r$pessoas, r$users, 100 * r$pessoas / real$pessoas))
  r
}))

# O deslocamento 1 e a manchete; os outros limitam a precisao dele.
arm_b <- arm_b_all[1, ]
cat(sprintf("  manchete (j=1): %d pessoas; amplitude entre os %d ",
            arm_b$pessoas, length(perm_offsets)))
cat(sprintf("deslocamentos: %d\n", max(arm_b_all$pessoas) - min(arm_b_all$pessoas)))

# A base do braco B e a permutavel, nao as 567.270.
real_perm <- dbGetQuery(con, sprintf("
  SELECT count(DISTINCT person_key) AS n FROM (
    SELECT person_key FROM perm) p
  WHERE EXISTS (SELECT 1 FROM ck k WHERE k.person_key = p.person_key)"))$n

####################################################################
### O produto largo CONTEM o canonico
###
### Toda a leitura correta do excedente depende disto: afrouxar a
### chave so pode ACRESCENTAR pares candidatos, e os escores de nome
### nao dependem da chave, entao nenhum par canonico pode se perder.
### Se algum se perdesse, "excedente menor" viraria mesmo "menos
### pareamentos", que e outra coisa. Confere-se de fato, na variante
### larga, em vez de deduzir.
####################################################################

if (!key_oa_ids) {
  canon_cand <- file.path(canon_dir, "capes_obmep_match_candidates.parquet")
  wide_cand <- file.path(out_dir, "capes_obmep_match_candidates.parquet")
  if (file.exists(canon_cand) && file.exists(wide_cand)) {
    sup <- dbGetQuery(con, sprintf("
      WITH a AS (SELECT person_key, CAST(user_id AS VARCHAR) AS user_id
                 FROM read_parquet(%1$s)
                 WHERE jw_combo >= %3$.17g AND jw_lastname >= %3$.17g),
           b AS (SELECT person_key, CAST(user_id AS VARCHAR) AS user_id
                 FROM read_parquet(%2$s)
                 WHERE jw_combo >= %3$.17g AND jw_lastname >= %3$.17g)
      SELECT (SELECT count(*) FROM a) AS canonicos,
             (SELECT count(*) FROM a ANTI JOIN b USING (person_key, user_id))
               AS perdidos,
             (SELECT count(*) FROM b ANTI JOIN a USING (person_key, user_id))
               AS acrescentados",
      qp(canon_cand), qp(wide_cand), jw_cut))
    if (sup$perdidos != 0L) {
      stop("A variante larga perdeu ", sup$perdidos, " pares canonicos. ",
           "Isso e impossivel se a chave so foi afrouxada -- ha um bug.")
    }
    cat("
[OK] o produto largo contem os ", sup$canonicos,
        " pares canonicos (0 perdidos) e acrescenta ", sup$acrescentados,
        "
", sep = "")
  }
}

####################################################################
### Saida
####################################################################

res_all <- rbind(real, arm_a, arm_b_all)
res_all$pct_do_real <- round(100 * res_all$pessoas / real$pessoas, 2)

# EXCEDENTE SOBRE O PLACEBO -- o que sobra depois de descontar a
# coincidencia. Na linha 'real' e a propria contagem; em cada braco e
# real menos o braco, ou seja: a estimativa daquele braco para o que o
# produto vale liquido de acaso. E o numero que compara duas variantes
# da chave, porque a contagem bruta premia justamente o leque que a
# chave mais frouxa cria.
#
# ESTIMADOR DE PRIMEIRA ORDEM, NAO IDENTIDADE -- ver nota 6.
is_real <- res_all$braco == "real"
res_all$excedente_pares <- ifelse(is_real, res_all$pares,
                                  real$pares - res_all$pares)
res_all$excedente_pessoas <- ifelse(is_real, res_all$pessoas,
                                    real$pessoas - res_all$pessoas)
res_all$excedente_users <- ifelse(is_real, res_all$users,
                                  real$users - res_all$users)

# Guarda barata contra a subtracao estar ligada na linha errada.
stopifnot(
  identical(res_all$excedente_pessoas[is_real], real$pessoas),
  all(res_all$excedente_pessoas[!is_real] ==
        real$pessoas - res_all$pessoas[!is_real]),
  all(res_all$excedente_pares[!is_real] ==
        real$pares - res_all$pares[!is_real])
)

dbWriteTable(con, "res_all", res_all, temporary = TRUE, overwrite = TRUE)
invisible(dbExecute(con, sprintf(
  "COPY (SELECT * FROM res_all ORDER BY braco, parametro)
   TO %s (FORMAT PARQUET, COMPRESSION ZSTD)", qp(out_part))))
if (file.exists(out_path)) unlink(out_path)
if (!file.rename(out_part, out_path)) {
  stop("Nao foi possivel promover: ", out_path)
}

####################################################################
### Relatorio
####################################################################

cat("\n=========== RESULTADO ===========\n")
print(res_all, row.names = FALSE)

fdr_a <- 100 * mean(arm_a$pessoas) / real$pessoas
fdr_b <- 100 * arm_b$pessoas / real$pessoas

cat("\n=========== LEITURA ===========\n")
cat(sprintf("Real                        : %6d pessoas CAPES pareadas\n",
            real$pessoas))
cat(sprintf("Braco A (ano errado), media : %6.0f  = %5.2f%% do real\n",
            mean(arm_a$pessoas), fdr_a))
cat(sprintf("Braco B (sobrenome de outro): %6d  = %5.2f%% do real\n",
            arm_b$pessoas, fdr_b))
cat(sprintf("  amplitude nos %d deslocamentos: %d pessoas\n",
            length(perm_offsets),
            max(arm_b_all$pessoas) - min(arm_b_all$pessoas)))
cat("\nCada K sai em linha propria de proposito: deslocar o ano tambem\n")
cat("muda o tamanho do bloco, entao a media do braco A e indicativa e\n")
cat("nao um estimador -- nota 2.\n")
cat("\nO braco B e o mais afiado: a chave fica identica e so o\n")
cat("sobrenome muda de dono. Se ele se aproximasse do real, os 14,1%\n")
cat("seriam artefato do bloco e nao do nome.\n")
cat("\n=========== EXCEDENTE SOBRE O PLACEBO ===========\n")
cat("(o que sobra depois de descontar a coincidencia -- e este o\n")
cat(" numero que compara duas variantes da chave, nao a contagem bruta)\n")
exc_p <- real$pessoas - arm_b_all$pessoas
cat(sprintf("  pares   : %7d  de %7d brutos\n",
            real$pares - arm_b$pares, real$pares))
cat(sprintf("  pessoas : %7d  de %7d brutas  (faixa nos %d\n",
            real$pessoas - arm_b$pessoas, real$pessoas, length(perm_offsets)))
cat(sprintf("             deslocamentos: %d a %d)\n", min(exc_p), max(exc_p)))
cat(sprintf("  users   : %7d  de %7d brutos\n",
            real$users - arm_b$users, real$users))
cat("\nA FAIXA e o que torna a comparacao entre variantes da chave\n")
cat("legitima: uma diferenca menor que ela nao seria distinguivel do\n")
cat("ruido do proprio estimador.\n")

cat("\nPlacebo baixo LIMITA o falso positivo; nao prova que os\n")
cat("sobreviventes estao certos -- nota 4. Para isso, o caderno do 27a.\n")
cat("\nO excedente e ESTIMADOR DE PRIMEIRA ORDEM, nao identidade:\n")
cat("supoe que o processo de falso positivo tem a mesma magnitude na\n")
cat("rodada real e na permutada. O braco B segura os blocos e a\n")
cat("distribuicao de sobrenomes, o que torna isso aproximadamente\n")
cat("verdade, mas um casamento verdadeiro pode ocupar a vaga que um\n")
cat("falso ocuparia, entao os dois nao somam exatamente -- nota 6.\n")
cat("\nSaida:", out_path, "\n")
