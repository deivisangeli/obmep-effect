####################################################################
### RUF -> OpenAlex: as 23 instituicoes do top 10 dos 12 cursos
###
### Le o recorte por instituicao do script 15 e a lista brasileira do
### OpenAlex do script 3, e grava um crosswalk chaveado por
### ruf_institution_id:
###
###   ruf_openalex_br_2025.parquet               23 linhas
###
### POR QUE ESTE ARQUIVO EXISTE. Todo o lado institucional desta pasta
### e chaveado em OpenAlex - openalex_institutions_br (3),
### shanghai_ranking_oa (4), rsid_openalex_br (6). O RUF nao traz id do
### OpenAlex nenhum, so ruf_institution_id, tirado da URL da ficha na
### Folha. Sem este crosswalk o RUF nao junta com nada, e NOME NAO E
### CHAVE DE JOIN.
###
### O script 4 NAO serve de modelo aqui: ele casa POR ID, porque o xlsx
### de Xangai ja vinha com OA_key. Aqui o casamento e por nome, e o
### problema de projeto e fazer isso SEM match aproximado e SEM tabela
### de apelidos - nao existe nem um nem outro em nenhum arquivo desta
### pasta, e nao e aqui que vao aparecer.
###
### TRES BRACOS, cada um igualdade ou continencia EXATA depois de dobrar
### com lower(strip_accents(trim(x))), a mesma dobra do script 16:
###
###   1. nome RUF = cleaned_display_name OU display_name do OA .... 19
###   2. cleaned_display_name do OA CONTIDO no nome RUF ............ 3
###      (Unesp, UFABC, Maua)
###   3. sigla RUF como palavra inteira no display_name do OA ...... 1
###      (FEI)
###
### Bracos 2 e 3 exigem type = 'education' no lado OA.
###
### A PRECEDENCIA E ESTRUTURAL, NAO COSMETICA. Vence o menor numero de
### braco, e DENTRO do braco vencedor exige-se candidato UNICO - isso e
### assercao, nao criterio de desempate. Escolher um vencedor em
### silencio e exatamente o que esconderia a falha que se quer pegar.
###
### Medido: rodando o braco 2 sobre as 23 SEM o braco 1 antes,
###
###   UFPR   2 candidatos  Universidade Federal do Parana | ... do Para
###   UFRGS  2 candidatos  ... do Rio Grande do Sul       | ... do Rio Grande
###
### porque 'universidade federal do para' e substring de
### 'universidade federal do parana', e '... do rio grande' de
### '... do rio grande do sul'. Sao UNIVERSIDADES DIFERENTES, nao campi
### da mesma. O braco 1 resolve as duas por igualdade, entao o braco 2
### nunca as ve - e e so por isso que ele e seguro.
###
### O braco 3 tem a propriedade espelhada: sozinho ele e ambiguo para
### Unesp ('Universidade Estadual Paulista (Unesp)' contra 'Unesp de
### Marilia', com 0 works) e para Maua ('Instituto Maua de Tecnologia'
### contra 'Centro Universitario Barao de Maua', outra instituicao, em
### Ribeirao Preto). O braco 2 ja tomou as duas.
###
### A FEI E A UNICA LINHA APOIADA EM UM SINAL SO. O RUF a chama de
### 'Centro Universitario da Fundacao Educacional Inaciana Pe Saboia de
### Medeiros' e o OpenAlex de 'Centro Universitario FEI': os dois nomes
### nao compartilham nenhuma palavra de conteudo, entao a sigla e a
### unica evidencia, corroborada por cidade (Sao Bernardo do Campo) e
### works_count 3.587. E a linha que uma troca de snapshot quebra
### primeiro, e a que se deve ler a mao quando o stop() disparar.
###
### O piso length(f_clean) >= 8 do braco 2 e guarda contra um nome curto
### do OA cair dentro de um nome longo do RUF. HOJE ELE NAO FAZ NADA:
### medido, pisos 0, 4, 6, 8, 10 e 12 dao as mesmas 3 resolvidas e 0
### ambiguas, e o menor casamento real e 'instituto maua de tecnologia',
### com 28 caracteres. Fica como guarda; nao leia como valor calibrado.
###
### SO O CORTE 10 FOI MEDIDO. Alargar para o corte 50, ou para as 2.232
### instituicoes do RUF, exige reauditar os bracos 2 e 3 A MAO em vez de
### confiar neles: a colisao Parana/Para acima e a cara dessa
### superficie.
###
### NAO USA REDE. Le dois parquets locais, escreve um. Ainda assim e
### local e nao pode ser copiado para scripts_sedap/, porque depende do
### script 14, que usa rede. Ver AGENTS.md -> Execution Environments.
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

edition <- 2025L

# Corte do RUF que este crosswalk cobre. So o 10 foi medido; ver o
# cabecalho antes de mexer.
rank_cut <- 10L

ruf_dir <- file.path(obmep_root, "Data/intermediate/ruf_ranking")
oa_dir  <- file.path(obmep_root, "Data/intermediate/openalex_institutions")

ri_path <- file.path(ruf_dir, sprintf("ruf_stem_top%d_institutions_%d.parquet",
                                      rank_cut, edition))
oa_path <- file.path(oa_dir, "openalex_institutions_br.parquet")
out_path <- file.path(ruf_dir, sprintf("ruf_openalex_br_%d.parquet", edition))

# Piso de tamanho do braco 2. Guarda, nao calibragem: hoje e inerte.
min_contido <- 8L

# Valores medidos contra o recorte top 10 de 2025 e o snapshot do
# OpenAlex de 2026-02-25.
exp_inst    <- 23L
exp_oa_rows <- 1947L
exp_arms    <- c("1" = 19L, "2" = 3L, "3" = 1L)
exp_snapshot <- "2026-02-25"

# As 4 que NAO casam por nome, com o id esperado. Ficam explicitas para
# que uma mudanca aponte qual instituicao mudou, e nao so um total.
exp_nao_nome <- c(Unesp = "I879563668", UFABC = "I71715416",
                  "Mau\u00e1" = "I155501849", FEI = "I139221136")

if (!file.exists(ri_path)) {
  stop("Nao encontrei ", ri_path,
       "\nRode antes prep/building_external_data/ruf_stem_top50.R com ",
       "rank_cut <- ", rank_cut, "L.")
}
if (!file.exists(oa_path)) {
  stop("Nao encontrei ", oa_path,
       "\nRode antes prep/building_external_data/openalex_br_institutions.R.")
}

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_ruf")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# temp_directory explicito: o derrame para disco nao pode cair em pasta
# sincronizada pelo Dropbox.
nul <- dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

cat("RUF", edition, "- crosswalk para o OpenAlex, corte top", rank_cut, "\n")
cat("RUF     :", ri_path, "\n")
cat("OpenAlex:", oa_path, "\n")
cat("saida   :", out_path, "\n\n")

####################################################################
### Os dois lados, com os nomes dobrados
####################################################################

nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE ri AS
  SELECT *,
         lower(strip_accents(trim(institution_name))) AS fr,
         lower(strip_accents(trim(abbr)))             AS fa
  FROM read_parquet('%s')", gsub("\\\\", "/", ri_path)))

nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE oa AS
  SELECT *,
         lower(strip_accents(trim(cleaned_display_name))) AS f_clean,
         lower(strip_accents(trim(display_name)))         AS f_disp
  FROM read_parquet('%s')", gsub("\\\\", "/", oa_path)))

n_ri <- dbGetQuery(con, "SELECT count(*) n, count(DISTINCT ruf_institution_id) d FROM ri")
n_oa <- dbGetQuery(con, "SELECT count(*) n, count(DISTINCT openalex_id) d FROM oa")

cat("instituicoes RUF   :", n_ri$n, "( ids distintos", n_ri$d, ")\n")
cat("instituicoes OpenAlex:", n_oa$n, "( ids distintos", n_oa$d, ")\n\n")

stopifnot(n_ri$n == n_ri$d, n_oa$n == n_oa$d)

if (n_ri$n != exp_inst) {
  stop("O recorte tem ", n_ri$n, " instituicoes, medido ", exp_inst,
       ". Este crosswalk foi auditado a mao sobre ", exp_inst,
       " linhas; um conjunto diferente exige reauditar os bracos 2 e 3.")
}
if (n_oa$n != exp_oa_rows) {
  warning("Lista do OpenAlex com ", n_oa$n, " linhas, medido ", exp_oa_rows,
          ". O snapshot mudou?")
}

####################################################################
### Os tres bracos
####################################################################

nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE cand AS
  -- Braco 1: igualdade do nome, contra as duas colunas de nome do OA.
  SELECT r.ruf_institution_id, o.openalex_id, 1 AS arm
  FROM ri r JOIN oa o ON r.fr IN (o.f_clean, o.f_disp)
  UNION ALL
  -- Braco 2: nome do OA contido no nome do RUF.
  SELECT r.ruf_institution_id, o.openalex_id, 2
  FROM ri r JOIN oa o
    ON o.type = 'education'
   AND length(o.f_clean) >= %d
   AND position(o.f_clean IN r.fr) > 0
  UNION ALL
  -- Braco 3: sigla do RUF como palavra inteira no nome do OA.
  SELECT r.ruf_institution_id, o.openalex_id, 3
  FROM ri r JOIN oa o
    ON o.type = 'education'
   AND regexp_matches(o.f_disp,
         '(^|[^a-z0-9])' || r.fa || '([^a-z0-9]|$)')", min_contido))

# Vence o menor braco. Dentro dele, candidato unico e ASSERCAO: n_cand
# fica na tabela justamente para poder ser conferido, e nao resolvido
# por desempate silencioso.
nul <- dbExecute(con, "
  CREATE OR REPLACE TABLE xw AS
  WITH vencedor AS (
    SELECT ruf_institution_id, min(arm) AS arm FROM cand GROUP BY 1
  )
  SELECT c.ruf_institution_id,
         v.arm                        AS match_arm,
         count(*)                     AS n_cand,
         min(c.openalex_id)           AS openalex_id
  FROM cand c JOIN vencedor v USING (ruf_institution_id)
  WHERE c.arm = v.arm
  GROUP BY 1, 2")

####################################################################
### Montagem da saida
####################################################################

# LEFT JOIN a partir do RUF: o recorte manda. Nenhuma das 23 pode ser
# perdida nem duplicada, mesmo que nao resolva.
nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE saida AS
  SELECT
    r.ruf_institution_id,
    r.abbr,
    r.institution_name,
    r.uf,
    x.match_arm,
    x.n_cand,
    o.openalex_id,
    o.display_name,
    o.cleaned_display_name,
    o.ror,
    o.type                          AS oa_type,
    o.works_count,
    o.city,
    o.region,
    o.snapshot_date,
    %d                              AS ruf_cut
  FROM ri r
  LEFT JOIN xw x ON x.ruf_institution_id = r.ruf_institution_id
  LEFT JOIN oa o ON o.openalex_id = x.openalex_id
  ORDER BY r.best_rank, r.mean_rank, r.ruf_institution_id", rank_cut))

####################################################################
### Validacao
####################################################################

res <- dbGetQuery(con, "
  SELECT
    count(*)                                        AS linhas,
    count(DISTINCT ruf_institution_id)              AS ruf_ids,
    sum(openalex_id IS NOT NULL)                    AS resolvidas,
    sum(openalex_id IS NULL)                        AS sem_match,
    sum(coalesce(n_cand, 1) > 1)                    AS ambiguas,
    count(DISTINCT openalex_id)                     AS oa_ids,
    sum(oa_type IS NOT NULL AND oa_type <> 'education') AS nao_education,
    sum(openalex_id IS NOT NULL AND ror IS NULL)    AS sem_ror
  FROM saida")

cat("linhas         :", res$linhas, "\n")
cat("resolvidas     :", res$resolvidas, "de", res$linhas, "\n")
cat("sem match      :", res$sem_match, "\n")
cat("ambiguas       :", res$ambiguas, "\n")
cat("ids OA distintos:", res$oa_ids, "\n\n")

# O LEFT JOIN nao pode ter criado nem perdido linha, e o mapa tem de ser
# INJETIVO: duas instituicoes do RUF caindo no mesmo id do OpenAlex nao
# e ambiguidade de braco, e colapso de identidade.
stopifnot(res$linhas == exp_inst,
          res$ruf_ids == exp_inst,
          res$resolvidas == exp_inst,
          res$sem_match == 0L,
          res$ambiguas == 0L,
          res$oa_ids == exp_inst,
          res$nao_education == 0L,
          res$sem_ror == 0L)

# Fan-out do braco 1: um nome dobrado repetido no OA multiplicaria a
# linha do RUF. Vacuo hoje - os 4 repetidos sao 'faculdades nova
# esperanca', 'hospital ana nery', 'instituto de medicina avancada' e
# 'hospital de base', nenhum deles universidade nossa - mas um repetido
# futuro em nome de universidade passaria calado sem esta checagem.
dup_oa <- dbGetQuery(con, "
  SELECT o.f_clean, count(*) AS n
  FROM oa o
  WHERE o.f_clean IN (SELECT lower(strip_accents(trim(institution_name))) FROM ri)
  GROUP BY 1 HAVING count(*) > 1")

if (nrow(dup_oa)) {
  stop("Nome dobrado repetido no OpenAlex batendo com o RUF: ",
       paste(dup_oa$f_clean, collapse = ", "),
       ". O braco 1 faria fan-out.")
}

# Distribuicao por braco: deriva, nao erro. Se o OpenAlex renomear a
# Unesp para a grafia do RUF, ela migra do braco 2 para o 1 - mesma
# resposta, outro caminho.
por_arm <- dbGetQuery(con,
  "SELECT match_arm, count(*) AS n FROM saida GROUP BY 1 ORDER BY 1")
obs_arms <- setNames(as.integer(por_arm$n), as.character(por_arm$match_arm))

if (!identical(obs_arms[names(exp_arms)], exp_arms)) {
  warning("Distribuicao por braco ",
          paste(sprintf("%s=%s", names(obs_arms), obs_arms), collapse = " "),
          ", medido ",
          paste(sprintf("%s=%s", names(exp_arms), exp_arms), collapse = " "),
          ". A grafia de algum nome mudou?")
}

snaps <- dbGetQuery(con, "SELECT DISTINCT snapshot_date FROM saida ORDER BY 1")$snapshot_date
if (!identical(as.character(snaps), exp_snapshot)) {
  warning("snapshot_date do OpenAlex: ", paste(snaps, collapse = ", "),
          ", medido ", exp_snapshot, ".")
}

####################################################################
### Escrita
####################################################################

nul <- dbExecute(con, sprintf(
  "COPY (SELECT ruf_institution_id, abbr, institution_name, uf, match_arm,
                openalex_id, display_name, cleaned_display_name, ror, oa_type,
                works_count, city, region, snapshot_date, ruf_cut
         FROM saida
         ORDER BY match_arm, works_count DESC)
   TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", gsub("\\\\", "/", out_path)))

####################################################################
### Relatorio
####################################################################

# 23 linhas cabem numa tela, e e exatamente por isso que os bracos 2 e 3
# sao aceitaveis: a saida deles tem 4 linhas e da para conferir todas.
cat("Crosswalk completo:\n")
print(dbGetQuery(con, "
  SELECT match_arm, abbr, openalex_id, display_name, works_count, city, ror
  FROM saida ORDER BY match_arm, works_count DESC"), right = FALSE)

cat("\nNAO casaram por nome - LEIA ESTAS:\n")
nao_nome <- dbGetQuery(con, "
  SELECT match_arm, abbr, institution_name, openalex_id, display_name,
         works_count, city
  FROM saida WHERE match_arm > 1 ORDER BY match_arm, works_count DESC")
print(nao_nome, right = FALSE)

# Conferencia nominal: nao basta serem 4, tem de ser AS 4, com os
# mesmos ids.
obs_nao_nome <- setNames(nao_nome$openalex_id, nao_nome$abbr)
if (!identical(obs_nao_nome[names(exp_nao_nome)], exp_nao_nome)) {
  warning("As instituicoes resolvidas fora do braco 1 mudaram. Esperado ",
          paste(sprintf("%s->%s", names(exp_nao_nome), exp_nao_nome),
                collapse = " "),
          "; obtido ",
          paste(sprintf("%s->%s", names(obs_nao_nome), obs_nao_nome),
                collapse = " "), ".")
}

# Releitura com arrow: confirma que o parquet e legivel fora do DuckDB e
# que os acentos sobreviveram.
df <- arrow::read_parquet(out_path)
cat("\nreleitura arrow:", nrow(df), "linhas,", ncol(df), "colunas\n")
cat("colunas:", paste(names(df), collapse = ", "), "\n")
stopifnot(nrow(df) == exp_inst,
          !any(is.na(df$openalex_id)),
          length(unique(df$openalex_id)) == exp_inst,
          sum(grepl("[^\x01-\x7f]", df$institution_name)) > 0L)

cat("\nGravado:", out_path, "\n")
cat("tamanho:", round(file.size(out_path) / 1024, 1), "KB\n")
