####################################################################
### 27c. Uniao deduplicada dos dois bracos por diploma do script 27
###
### Pipeline local e OFFLINE. Le SO o que os scripts 27 e 27b ja
### gravaram nos diretorios capes_obmep_match_msc/ e
### capes_obmep_match_phd/, mais o canonico para marcar o que e novo.
### Nao usa rede e NAO deve ser enviado nem executado no SEDAP.
###
### O PROBLEMA QUE OS BRACOS RESOLVEM
### A chave canonica do script 27 exige os DOIS diplomas de quem tem
### os dois: mesmo primeiro nome, os dois anos de inicio e os dois
### openalex_id. Se o LinkedIn lista so um dos diplomas, ou lista o
### outro com ano ou instituicao diferente, o par cai em outro bucket
### para sempre. 27,2% do produto conservador e gente com mestrado E
### doutorado, entao a superficie exposta e grande.
###
### Cada braco pede que UM diploma concorde, mantendo o openalex_id
### daquele diploma na chave -- e a instituicao que o placebo mostrou
### ser o que identifica esta ligacao. Medido em 2026-09-09:
###
###   produto conservador    pares  pessoas   users  placebo B  excedente
###   canonico              88.772   81.157  85.896      4,15%     76.450
###   braco msc            106.320   96.292  99.360      5,06%     91.424
###   braco phd             29.118   26.868  28.648      2,86%     26.100
###
### Diferente da variante _noinst (nota 9 do script 27), aqui o
### excedente SOBE: os pares comparados do braco msc crescem 9% sobre
### o canonico (841.641 contra 769.710), nao 72x, e o placebo fica
### perto dos 4,15% do canonico em vez dos 57,6% daquela variante.
### Este lever e real.
###
### CAUTION / LIMITATIONS
###   1. O PLACEBO DA UNIAO NAO E A SOMA DOS PLACEBOS DOS BRACOS. Uma
###      pessoa pode sobreviver a permutacao nos dois bracos e seria
###      contada duas vezes. Por isso o 27b grava o CONJUNTO de pares
###      do braco B (j=1) e aqui ele passa pela MESMA deduplicacao dos
###      pares reais. Somar as contagens superestimaria o placebo e
###      subestimaria o excedente.
###   2. Os user_rank / n_users / person_rank / n_persons dos bracos
###      NAO valem para a uniao: cada um conta linhas no seu proprio
###      arquivo. Sao recalculados aqui sobre a uniao deduplicada.
###      Colapsar uma direcao sem tratar a outra INVENTA identidade.
###   3. ESTA E UMA TABELA DE CANDIDATOS, nao um mapa 1:1, pela mesma
###      razao que a do script 27. Um person_key alcanca varios
###      user_id e vice-versa.
###   4. Um par pode entrar pelos dois bracos. Quando entra, os tres
###      escores TEM de ser identicos nos dois -- os escores nao
###      dependem da chave, so o conjunto de pares candidatos depende.
###      Isso e afirmado e aborta se falhar, porque seria sinal de que
###      a edicao da chave mexeu no que nao devia. best_variant pode
###      diferir: arg_max desempata de forma nao deterministica.
###   5. in_canonical marca o par que o produto canonico ja tinha.
###      E ele que diz quanto da uniao e NOVO, e e a coluna pela qual
###      um revisor estratifica a leitura do caderno do 27a.
###   6. DADO PESSOAL: carrega nome civil dos dois lados, como todo
###      produto do script 27. Trate como o script 21.
###
### Depends on:
###   prep/building_external_data/capes_obmep_candidates_name_match.R
###     rodado com OBMEP_MATCH_ARM = msc e = phd                  (27)
###   prep/building_external_data/capes_obmep_match_placebo.R
###     rodado com OBMEP_MATCH_ARM = msc e = phd                 (27b)
###
### Outputs (Data/intermediate/capes_discentes/capes_obmep_match_union/):
###   capes_obmep_match_candidates.parquet   a uniao deduplicada
###   capes_obmep_match_summary.csv          metrica,valor
###   capes_obmep_match_placebo.parquet      real x placebo x excedente
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
match_cohort <- Sys.getenv("OBMEP_MATCH_COHORT", unset = "legacy")
if (!match_cohort %in% c("legacy", "degree_duration")) {
  stop("OBMEP_MATCH_COHORT = '", match_cohort,
       "' does not exist. Use legacy or degree_duration.")
}
cohort_tag <- if (match_cohort == "degree_duration") "_degree_duration" else ""

arms <- c("msc", "phd")
arm_dirs <- setNames(
  file.path(capes_dir, paste0("capes_obmep_match", cohort_tag, "_", arms)), arms
)
canon_dir <- file.path(capes_dir, paste0("capes_obmep_match", cohort_tag))
out_dir <- file.path(capes_dir, paste0("capes_obmep_match", cohort_tag, "_union"))

canon_file <- file.path(canon_dir, "capes_obmep_match_candidates.parquet")
out_path <- file.path(out_dir, "capes_obmep_match_candidates.parquet")
sum_path <- file.path(out_dir, "capes_obmep_match_summary.csv")
pla_path <- file.path(out_dir, "capes_obmep_match_placebo.parquet")

# Tem de bater com o script 27, ou a uniao deixa de ser a uniao dos
# produtos conservadores que ele escreveu.
jw_cut <- 0.90

mem_limit <- "10GB"
tmp_dir <- file.path(
  Sys.getenv("TEMP"), paste0("duckdb_tmp_capes_obmep_union", cohort_tag))

# Medidos em 2026-09-09 nos dois bracos. divergencia estrutural
# aborta, divergencia de contagem avisa.
exp_arm_pairs <- if (match_cohort == "degree_duration") {
  c(msc = 161823L, phd = 41873L)
} else c(msc = 106320L, phd = 29118L)
exp_canon_pairs <- if (match_cohort == "degree_duration") 135777L else 88772L

for (a in arms) {
  f <- file.path(arm_dirs[[a]], "capes_obmep_match_candidates.parquet")
  if (!file.exists(f)) {
    stop("Falta o braco ", a, ": ", f, "\n  Rode antes: ",
         "$env:OBMEP_MATCH_ARM = '", a, "'; Rscript ",
         "prep/building_external_data/capes_obmep_candidates_name_match.R")
  }
  g <- file.path(arm_dirs[[a]], "capes_obmep_match_placebo_pairs.parquet")
  if (!file.exists(g)) {
    stop("Falta o placebo do braco ", a, ": ", g, "\n  Rode antes: ",
         "$env:OBMEP_MATCH_ARM = '", a, "'; Rscript ",
         "prep/building_external_data/capes_obmep_match_placebo.R")
  }
}
stopifnot(file.exists(canon_file))

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

# Guarda do padrao 21alt: esta uniao nao escreve no canonico nem em
# nenhum dos bracos por nenhum caminho. Tamanho e mtime capturados
# aqui e reconferidos no fim.
guarded <- c(canon_file,
             file.path(arm_dirs, "capes_obmep_match_candidates.parquet"))
guard_before <- file.info(guarded)[c("size", "mtime")]
for (d in c(canon_dir, unname(arm_dirs))) {
  if (normalizePath(out_dir, mustWork = FALSE) ==
      normalizePath(d, mustWork = FALSE)) {
    stop("A uniao resolveu para um diretorio de entrada. Abortando.")
  }
}

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

cat("Uniao dos bracos por diploma do pareamento CAPES x selecionados\n")
cat("coorte    :", match_cohort, "\n")
for (a in arms) cat("braco", a, ":", arm_dirs[[a]], "\n")
cat("canonico  :", canon_dir, "\n")
cat("saida     :", out_dir, "\n")
cat("corte     : jw_combo >=", jw_cut, "E jw_lastname >=", jw_cut, "\n")
cat("DuckDB    :", dbGetQuery(con, "SELECT version() AS v")$v, "\n\n")

####################################################################
### Etapa A -- os dois bracos, no produto conservador, empilhados
####################################################################

arm_sql <- paste(vapply(arms, function(a) sprintf(
  "SELECT '%s' AS arm, * FROM read_parquet(%s)
   WHERE jw_combo >= %.17g AND jw_lastname >= %.17g",
  a,
  qp(file.path(arm_dirs[[a]], "capes_obmep_match_candidates.parquet")),
  jw_cut, jw_cut
), character(1)), collapse = "\n  UNION ALL\n  ")

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE arm_pairs AS
   SELECT arm, person_key, CAST(user_id AS VARCHAR) AS user_id,
          capes_full_name, birth_year, first_name,
          capes_msc_start_year, capes_msc_oa_id,
          capes_phd_start_year, capes_phd_oa_id,
          revelio_fullname, revelio_surnames,
          revelio_msc_start_year, revelio_msc_end_year, revelio_msc_oa_id,
          revelio_phd_start_year, revelio_phd_end_year, revelio_phd_oa_id,
          jw_combo, jw_lastname, jw_name, best_variant, key_string
   FROM (%s)", arm_sql
)))

arm_qa <- dbGetQuery(con, "
  SELECT arm, count(*) AS pares,
         count(DISTINCT person_key) AS pessoas,
         count(DISTINCT user_id) AS users
  FROM arm_pairs GROUP BY arm ORDER BY arm")
print(arm_qa, row.names = FALSE)
cat("\n")

for (a in arms) {
  got <- arm_qa$pares[arm_qa$arm == a]
  if (length(got) != 1L) stop("Braco ", a, " nao voltou do empilhamento.")
  if (!is.na(exp_arm_pairs[[a]]) && got != exp_arm_pairs[[a]]) {
    warning("Braco ", a, ": ", got, " pares != ", exp_arm_pairs[[a]],
            " medido.")
  }
}

# Limitacao 4. Os escores NAO dependem da chave, entao um par que
# entra pelos dois bracos tem de trazer os tres identicos. Se nao
# trouxer, a edicao da chave mexeu na pontuacao e nada abaixo vale.
score_drift <- dbGetQuery(con, "
  SELECT count(*) AS n FROM (
    SELECT person_key, user_id
    FROM arm_pairs
    GROUP BY person_key, user_id
    HAVING count(DISTINCT jw_combo) > 1
        OR count(DISTINCT jw_lastname) > 1
        OR count(DISTINCT jw_name) > 1)")$n
if (score_drift != 0L) {
  stop(score_drift, " par(es) pontuam diferente nos dois bracos. Os ",
       "escores nao podem depender da chave -- ver limitacao 4.")
}

####################################################################
### Etapa B -- a deduplicacao
###
### Um par que entra pelos dois bracos e UMA linha. Os atributos de
### pessoa e de user vem das mesmas tabelas nos dois bracos, entao
### max() sobre eles e escolha, nao agregacao com sentido; os escores
### acabaram de ser afirmados identicos. O que os bracos NAO
### compartilham e a key_string, e as duas saem em colunas separadas:
### a que esta preenchida e a que forcou a igualdade.
####################################################################

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE uni AS
   SELECT person_key, user_id,
          max(capes_full_name) AS capes_full_name,
          max(birth_year) AS birth_year,
          max(first_name) AS first_name,
          max(capes_msc_start_year) AS capes_msc_start_year,
          max(capes_msc_oa_id) AS capes_msc_oa_id,
          max(capes_phd_start_year) AS capes_phd_start_year,
          max(capes_phd_oa_id) AS capes_phd_oa_id,
          max(revelio_fullname) AS revelio_fullname,
          max(revelio_surnames) AS revelio_surnames,
          max(revelio_msc_start_year) AS revelio_msc_start_year,
          max(revelio_msc_end_year) AS revelio_msc_end_year,
          max(revelio_msc_oa_id) AS revelio_msc_oa_id,
          max(revelio_phd_start_year) AS revelio_phd_start_year,
          max(revelio_phd_end_year) AS revelio_phd_end_year,
          max(revelio_phd_oa_id) AS revelio_phd_oa_id,
          max(jw_combo) AS jw_combo,
          max(jw_lastname) AS jw_lastname,
          max(jw_name) AS jw_name,
          max(best_variant) AS best_variant,
          CASE WHEN bool_or(arm = 'msc') AND bool_or(arm = 'phd')
                 THEN 'msc+phd'
               WHEN bool_or(arm = 'msc') THEN 'msc'
               ELSE 'phd' END AS arms,
          max(key_string) FILTER (WHERE arm = 'msc') AS key_string_msc,
          max(key_string) FILTER (WHERE arm = 'phd') AS key_string_phd
   FROM arm_pairs
   GROUP BY person_key, user_id"
)))

dedup_qa <- dbGetQuery(con, "
  SELECT count(*) AS pares,
         count(DISTINCT person_key || '#' || user_id) AS pares_distintos,
         count_if(arms = 'msc' AND key_string_msc IS NULL) AS msc_sem_chave,
         count_if(arms = 'phd' AND key_string_phd IS NULL) AS phd_sem_chave,
         count_if(arms = 'msc+phd'
                  AND (key_string_msc IS NULL
                       OR key_string_phd IS NULL)) AS ambos_sem_chave,
         count_if(arms = 'msc' AND key_string_phd IS NOT NULL)
           AS msc_com_chave_phd,
         count_if(arms = 'phd' AND key_string_msc IS NOT NULL)
           AS phd_com_chave_msc
  FROM uni")
stopifnot(
  dedup_qa$pares == dedup_qa$pares_distintos,
  dedup_qa$msc_sem_chave == 0L, dedup_qa$phd_sem_chave == 0L,
  dedup_qa$ambos_sem_chave == 0L,
  dedup_qa$msc_com_chave_phd == 0L, dedup_qa$phd_com_chave_msc == 0L
)

####################################################################
### Etapa C -- in_canonical e os ranks da UNIAO
###
### Limitacao 2: os ranks dos bracos contam linhas nos arquivos dos
### bracos. Aqui eles sao refeitos sobre a uniao.
####################################################################

invisible(dbExecute(con, sprintf(
  "CREATE TEMP TABLE crosswalk AS
   SELECT u.person_key, u.capes_full_name, u.birth_year, u.first_name,
          u.capes_msc_start_year, u.capes_msc_oa_id,
          u.capes_phd_start_year, u.capes_phd_oa_id,
          u.user_id, u.revelio_fullname,
          u.revelio_msc_start_year, u.revelio_msc_end_year,
          u.revelio_msc_oa_id,
          u.revelio_phd_start_year, u.revelio_phd_end_year,
          u.revelio_phd_oa_id,
          u.jw_combo, u.jw_lastname, u.jw_name, u.best_variant,
          u.revelio_surnames,
          u.arms, u.key_string_msc, u.key_string_phd,
          (c.person_key IS NOT NULL) AS in_canonical,
          dense_rank() OVER (PARTITION BY u.person_key
                             ORDER BY u.jw_combo DESC) AS user_rank,
          count(*) OVER (PARTITION BY u.person_key) AS n_users,
          dense_rank() OVER (PARTITION BY u.user_id
                             ORDER BY u.jw_combo DESC) AS person_rank,
          count(*) OVER (PARTITION BY u.user_id) AS n_persons
   FROM uni u
   LEFT JOIN (
     SELECT DISTINCT person_key, CAST(user_id AS VARCHAR) AS user_id
     FROM read_parquet(%1$s)
     WHERE jw_combo >= %2$.17g AND jw_lastname >= %2$.17g) c
     USING (person_key, user_id)",
  qp(canon_file), jw_cut
)))

xw_qa <- dbGetQuery(con, sprintf("
  SELECT count(*) AS pares,
         count(DISTINCT person_key) AS pessoas,
         count(DISTINCT user_id) AS users,
         count_if(in_canonical) AS pares_no_canonico,
         count_if(NOT in_canonical) AS pares_novos,
         count(DISTINCT person_key) FILTER (WHERE NOT in_canonical)
           AS pessoas_com_par_novo,
         count_if(arms = 'msc') AS so_msc,
         count_if(arms = 'phd') AS so_phd,
         count_if(arms = 'msc+phd') AS ambos,
         count_if(jw_combo < %1$.17g OR jw_lastname < %1$.17g) AS bad_gate,
         max(n_users) AS max_users_por_pessoa,
         max(n_persons) AS max_pessoas_por_user,
         avg(n_users) AS media_users_por_pessoa,
         avg(n_persons) AS media_pessoas_por_user
  FROM crosswalk", jw_cut))
stopifnot(xw_qa$bad_gate == 0L)

# A CONTENCAO DO CANONICO, e o que dela NAO vale.
#
# Cada braco e superconjunto do canonico NO SEU DIPLOMA, entao todo par
# canonico com ao menos um diploma resolvido -- ano E instituicao --
# tem de reaparecer aqui. Isso e afirmado e aborta.
#
# Mas a uniao NAO contem o canonico inteiro, e isso e por construcao,
# nao defeito. Os bracos exigem instituicao resolvida; o canonico nao,
# porque quando os dois lados escrevem 'NA' nas quatro posicoes de
# instituicao a chave passa a ser primeiro nome + ano e ainda casa.
# Medido em 2026-09-09: 892 dos 88.772 pares conservadores do canonico
# (1,0%) nao tem NENHUM diploma resolvido, e as chaves deles sao
# 'joao-2021-NA-NA-NA-NA-NA' e parentes -- exactamente a configuracao
# que o placebo da variante _noinst mostrou ser mais da metade
# coincidencia. Eles ficam fora da uniao, sao CONTADOS aqui e saem no
# resumo e no relatorio. Nao filtre esse balde em silencio: se voce
# quer o canonico junto, e uma uniao a mais, feita de proposito.
canon_qa <- dbGetQuery(con, sprintf("
  WITH canon AS (
    SELECT DISTINCT person_key, CAST(user_id AS VARCHAR) AS user_id,
           (capes_msc_start_year IS NOT NULL
            AND capes_msc_oa_id IS NOT NULL) AS msc_ok,
           (capes_phd_start_year IS NOT NULL
            AND capes_phd_oa_id IS NOT NULL) AS phd_ok
    FROM read_parquet(%1$s)
    WHERE jw_combo >= %2$.17g AND jw_lastname >= %2$.17g)
  SELECT (SELECT count(*) FROM canon) AS canonicos,
         (SELECT count(*) FROM canon WHERE NOT msc_ok AND NOT phd_ok)
           AS canonicos_sem_instituicao,
         (SELECT count(*) FROM canon c
          WHERE (c.msc_ok OR c.phd_ok)
            AND NOT EXISTS (SELECT 1 FROM crosswalk x
                            WHERE x.person_key = c.person_key
                              AND x.user_id = c.user_id))
           AS canonicos_perdidos,
         (SELECT count(*) FROM canon c
          WHERE NOT c.msc_ok AND NOT c.phd_ok
            AND NOT EXISTS (SELECT 1 FROM crosswalk x
                            WHERE x.person_key = c.person_key
                              AND x.user_id = c.user_id))
           AS canonicos_fora_por_falta_de_id",
  qp(canon_file), jw_cut))
if (!is.na(exp_canon_pairs) && canon_qa$canonicos != exp_canon_pairs) {
  warning("Canonico conservador ", canon_qa$canonicos, " != ",
          exp_canon_pairs, " medido.")
}
if (canon_qa$canonicos_perdidos != 0L) {
  stop(canon_qa$canonicos_perdidos, " par(es) do canonico conservador COM ",
       "diploma resolvido nao estao na uniao. Cada braco tinha de ser ",
       "superconjunto do canonico no seu diploma -- a edicao da chave ",
       "quebrou algo.")
}
cat(sprintf(
  "[OK] a uniao contem os %d pares canonicos com diploma resolvido\n",
  canon_qa$canonicos - canon_qa$canonicos_sem_instituicao))
cat(sprintf(
  "     %d par(es) canonico(s) SEM instituicao resolvida ficam fora\n\n",
  canon_qa$canonicos_fora_por_falta_de_id))

####################################################################
### Etapa D -- o placebo da uniao
###
### Limitacao 1: os pares do braco B de cada braco passam pela MESMA
### deduplicacao, nunca pela soma das contagens.
####################################################################

pla_sql <- paste(vapply(arms, function(a) sprintf(
  "SELECT person_key, CAST(user_id AS VARCHAR) AS user_id
   FROM read_parquet(%s)",
  qp(file.path(arm_dirs[[a]], "capes_obmep_match_placebo_pairs.parquet"))
), character(1)), collapse = "\n  UNION\n  ")

pla_qa <- dbGetQuery(con, sprintf("
  SELECT count(*) AS pares, count(DISTINCT person_key) AS pessoas,
         count(DISTINCT user_id) AS users
  FROM (%s)", pla_sql))

pla_per_arm <- do.call(rbind, lapply(arms, function(a) {
  q <- dbGetQuery(con, sprintf("
    SELECT count(*) AS pares, count(DISTINCT person_key) AS pessoas,
           count(DISTINCT user_id) AS users
    FROM read_parquet(%s)",
    qp(file.path(arm_dirs[[a]],
                 "capes_obmep_match_placebo_pairs.parquet"))))
  data.frame(arm = a, q, stringsAsFactors = FALSE)
}))
pla_sum <- data.frame(
  pares = sum(pla_per_arm$pares),
  pessoas = sum(pla_per_arm$pessoas),
  users = sum(pla_per_arm$users)
)

placebo <- data.frame(
  medida = c("real", "placebo_B_deduplicado", "excedente",
             "placebo_B_soma_dos_bracos"),
  pares = c(xw_qa$pares, pla_qa$pares, xw_qa$pares - pla_qa$pares,
            pla_sum$pares),
  pessoas = c(xw_qa$pessoas, pla_qa$pessoas,
              xw_qa$pessoas - pla_qa$pessoas, pla_sum$pessoas),
  users = c(xw_qa$users, pla_qa$users, xw_qa$users - pla_qa$users,
            pla_sum$users),
  stringsAsFactors = FALSE
)
placebo$pct_do_real <- round(100 * placebo$pessoas / xw_qa$pessoas, 2)

####################################################################
### Escrita atomica
####################################################################

writes <- list(
  list(sql = "SELECT * FROM crosswalk
              ORDER BY person_key, jw_combo DESC, user_id",
       path = out_path, fmt = "(FORMAT PARQUET, COMPRESSION ZSTD)"),
  list(sql = "SELECT * FROM placebo_out ORDER BY medida",
       path = pla_path, fmt = "(FORMAT PARQUET, COMPRESSION ZSTD)")
)
dbWriteTable(con, "placebo_out", placebo, temporary = TRUE, overwrite = TRUE)

for (w in writes) {
  if (file.exists(paste0(w$path, ".part"))) unlink(paste0(w$path, ".part"))
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO %s %s", w$sql, qp(paste0(w$path, ".part")), w$fmt
  )))
}

recheck <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM read_parquet(%s)", qp(paste0(out_path, ".part"))
))$n
stopifnot(recheck == xw_qa$pares)

for (w in writes) {
  if (file.exists(w$path)) unlink(w$path)
  if (!file.rename(paste0(w$path, ".part"), w$path)) {
    stop("Nao foi possivel promover: ", w$path)
  }
}

resumo <- data.frame(
  metrica = c(
    "braco_msc_pares", "braco_phd_pares",
    "uniao_pares", "uniao_pessoas", "uniao_users",
    "pares_so_msc", "pares_so_phd", "pares_pelos_dois_bracos",
    "canonico_pares", "canonico_sem_instituicao_fora_da_uniao",
    "pares_no_canonico", "pares_novos",
    "pessoas_com_par_novo",
    "placebo_b_pares", "placebo_b_pessoas", "placebo_b_users",
    "excedente_pares", "excedente_pessoas", "excedente_users",
    "max_users_por_pessoa", "max_pessoas_por_user",
    "media_users_por_pessoa", "media_pessoas_por_user",
    "jw_cut"
  ),
  valor = c(
    arm_qa$pares[arm_qa$arm == "msc"], arm_qa$pares[arm_qa$arm == "phd"],
    xw_qa$pares, xw_qa$pessoas, xw_qa$users,
    xw_qa$so_msc, xw_qa$so_phd, xw_qa$ambos,
    canon_qa$canonicos, canon_qa$canonicos_fora_por_falta_de_id,
    xw_qa$pares_no_canonico, xw_qa$pares_novos,
    xw_qa$pessoas_com_par_novo,
    pla_qa$pares, pla_qa$pessoas, pla_qa$users,
    xw_qa$pares - pla_qa$pares, xw_qa$pessoas - pla_qa$pessoas,
    xw_qa$users - pla_qa$users,
    xw_qa$max_users_por_pessoa, xw_qa$max_pessoas_por_user,
    round(xw_qa$media_users_por_pessoa, 4),
    round(xw_qa$media_pessoas_por_user, 4),
    jw_cut
  ),
  stringsAsFactors = FALSE
)
write.csv(resumo, paste0(sum_path, ".part"), row.names = FALSE)
if (file.exists(sum_path)) unlink(sum_path)
if (!file.rename(paste0(sum_path, ".part"), sum_path)) {
  stop("Nao foi possivel promover: ", sum_path)
}

####################################################################
### Relatorio
####################################################################

cat("=========== A UNIAO ===========\n")
cat(sprintf("pares  : %d\npessoas: %d\nusers  : %d\n",
            xw_qa$pares, xw_qa$pessoas, xw_qa$users))
cat("\n=========== DE ONDE VEM CADA PAR ===========\n")
print(data.frame(
  origem = c("so pelo braco msc", "so pelo braco phd",
             "pelos dois bracos"),
  pares = c(xw_qa$so_msc, xw_qa$so_phd, xw_qa$ambos),
  stringsAsFactors = FALSE
), row.names = FALSE)

cat("\n=========== O QUE E NOVO ===========\n")
print(data.frame(
  situacao = c("ja estava no canonico", "novo na uniao"),
  pares = c(xw_qa$pares_no_canonico, xw_qa$pares_novos),
  pct = round(100 * c(xw_qa$pares_no_canonico, xw_qa$pares_novos) /
                xw_qa$pares, 1),
  stringsAsFactors = FALSE
), row.names = FALSE)
cat(sprintf("pessoas CAPES que ganharam ao menos um par novo: %d\n",
            xw_qa$pessoas_com_par_novo))
cat(sprintf(
  "\n%d par(es) do canonico ficam FORA da uniao: nenhum diploma com\n",
  canon_qa$canonicos_fora_por_falta_de_id))
cat("instituicao resolvida, chave = primeiro nome + ano. E a mesma\n")
cat("configuracao que o placebo do _noinst reprovou. Contados aqui de\n")
cat("proposito -- decida se quer o canonico unido tambem, e diga.\n")

cat("\n=========== PLACEBO E EXCEDENTE DA UNIAO ===========\n")
print(placebo, row.names = FALSE)
cat("\nA linha placebo_B_soma_dos_bracos existe para mostrar o erro que\n")
cat("ela seria: somar as contagens conta duas vezes quem sobrevive nos\n")
cat("dois bracos -- ver limitacao 1. O numero valido e o deduplicado.\n")

cat("\n=========== FAN-OUT ===========\n")
cat(sprintf("users por pessoa CAPES: max %d, media %.3f\n",
            xw_qa$max_users_por_pessoa, xw_qa$media_users_por_pessoa))
cat(sprintf("pessoas CAPES por user: max %d, media %.3f\n",
            xw_qa$max_pessoas_por_user, xw_qa$media_pessoas_por_user))

cat("\nSaidas:\n")
for (p in c(out_path, pla_path, sum_path)) {
  cat(sprintf("  %s  %.2f MB\n", p, file.size(p) / 1024^2))
}

guard_after <- file.info(guarded)[c("size", "mtime")]
if (!identical(guard_before, guard_after)) {
  stop("Uma entrada mudou durante a uniao. Isso nunca deveria acontecer ",
       "-- ver a guarda no topo.")
}
cat("[OK] canonico e os dois bracos intactos (tamanho e mtime)\n")

cat("\nTabela de CANDIDATOS, nao mapa 1:1 -- limitacao 3. Trate\n")
cat("n_users e n_persons antes de qualquer join. Contem nome civil\n")
cat("dos dois lados.\n")
