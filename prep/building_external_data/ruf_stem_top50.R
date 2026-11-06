####################################################################
### RUF 2025 - top N dos 12 cursos de exatas e engenharias
###
### Recorte do parquet produzido por ruf_course_rankings.R (script 13).
### Seleciona as rank_cut primeiras colocadas de 12 cursos e grava dois
### parquets no Dropbox do OBMEP. Com rank_cut = 10:
###
###   ruf_stem_top10_2025.parquet               120 linhas
###       uma linha por CURSO x INSTITUICAO, com todas as colunas da
###       origem.
###   ruf_stem_top10_institutions_2025.parquet   23 linhas
###       uma linha por INSTITUICAO, com em quantos dos 12 cursos ela
###       entra no top N, melhor e pior posicao, e a lista de cursos.
###
### O CORTE E UM PARAMETRO, rank_cut. Com rank_cut = 50 este script
### reproduz os arquivos ruf_stem_top50_* que ja estao no disco,
### inclusive o nome da coluna n_courses_top50: os nomes de saida e o
### nome dessa coluna sao construidos a partir do corte. Logo trocar o
### corte ACRESCENTA arquivos, nao sobrescreve os do outro corte.
###
### O filtro e 'rank <= rank_cut' e nao a coluna top_50 da origem. As
### duas concordam exatamente onde a segunda existe - medido: nas
### 18.830 linhas da origem, top_50 <> (rank <= 50) em ZERO linhas -
### mas so a primeira generaliza. Nunca virar LIMIT: um empate em cima
### do corte perderia uma das colocadas ao acaso. Ver script 13.
###
### NAO USA REDE. Le parquet local, escreve parquet local. Ainda assim
### e local e nao pode ser copiado para scripts_sedap/, porque depende
### do script 13, que usa rede. Ver AGENTS.md -> Execution Environments.
###
### O CASAMENTO E POR SLUG, NUNCA POR NOME. A grafia do RUF diverge da
### usual: ele escreve 'Engenharia de controle e automacao' e
### 'Engenharia de producao' em caixa baixa. Slug e estavel, nome nao.
###
### Dois fatos deste recorte, medidos e nao supostos:
###
###  1. A USP esta em 11 dos 12, nao nos 12, nos DOIS cortes. Ela NAO
###     TEM LINHA NENHUMA em Engenharia de controle e automacao: esta
###     ausente do ranking daquele curso, e nao mal colocada nele.
###     Ausencia e posicao ruim sao coisas diferentes aqui, e o
###     relatorio no fim separa as duas justamente para nao deixar isso
###     passar como se fosse rank alto.
###
###  2. Empates dependem do corte. No top 50 tres dos doze tem empate
###     interno - Engenharia de controle e automacao no 48, Engenharia
###     de producao no 15 e Quimica no 43. No top 10 NAO HA EMPATE
###     NENHUM: os 12 cursos dao exatamente 10 linhas cada, posicoes 1
###     a 10. A checagem do script 13 e mantida nos dois casos: um
###     curso cujo total difira de min(rank_cut, disponiveis) e
###     REPORTADO, nao aborta. No conjunto completo Fisioterapia ja e
###     esse caso, com dois no 50 e ninguem no 51.
###
### Trocar a selecao e editar uma linha (cursos_sel) e remedir os
### exp_*. Trocar o corte e editar rank_cut; os valores medidos dos
### cortes 10 e 50 estao na tabela exp_medidos.
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

# Corte por curso. 50 reproduz os arquivos que ja estao no disco.
rank_cut <- 10L

out_dir <- file.path(obmep_root, "Data/intermediate/ruf_ranking")

src_path  <- file.path(out_dir, sprintf("ruf_course_ranking_%d.parquet", edition))
out_long  <- file.path(out_dir, sprintf("ruf_stem_top%d_%d.parquet",
                                        rank_cut, edition))
out_inst  <- file.path(out_dir, sprintf("ruf_stem_top%d_institutions_%d.parquet",
                                        rank_cut, edition))

# O nome da coluna carrega o corte, de proposito: renomear para algo
# generico mudaria em silencio o schema do arquivo do outro corte.
col_nc <- sprintf("n_courses_top%d", rank_cut)

# Os 12 cursos do recorte. Nomes de exibicao do RUF ao lado.
cursos_sel <- c(
  "biologia",                           # Biologia
  "computacao",                         # Computacao
  "fisica",                             # Fisica
  "matematica",                         # Matematica
  "quimica",                            # Quimica
  "engenharia-ambiental",               # Engenharia Ambiental
  "engenharia-civil",                   # Engenharia Civil
  "engenharia-de-controle-e-automacao", # Engenharia de controle e automacao
  "engenharia-de-producao",             # Engenharia de producao
  "engenharia-eletrica",                # Engenharia Eletrica
  "engenharia-mecanica",                # Engenharia Mecanica
  "engenharia-quimica")                 # Engenharia Quimica

# Valores medidos contra o parquet do RUF 2025, por corte. Sao medidas,
# nao contas: um corte ainda nao medido roda SEM guarda de regressao, e
# avisa que esta sem ela.
exp_courses <- 12L
exp_medidos <- list("10" = c(rows = 120L, inst =  23L),
                    "50" = c(rows = 600L, inst = 132L))

medido <- exp_medidos[[as.character(rank_cut)]]
if (is.null(medido)) {
  warning("Corte ", rank_cut, " nunca foi medido. Esta rodada nao tem ",
          "guarda de regressao; medir e acrescentar em exp_medidos.")
  exp_rows <- NA_integer_
  exp_inst <- NA_integer_
} else {
  exp_rows <- medido[["rows"]]
  exp_inst <- medido[["inst"]]
}

if (!file.exists(src_path)) {
  stop("Nao encontrei ", src_path,
       "\nRode antes prep/building_external_data/ruf_course_rankings.R.")
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

cat("RUF", edition, "- recorte de", length(cursos_sel), "cursos, top",
    rank_cut, "de cada\n")
cat("origem:", src_path, "\n")
cat("saidas:", basename(out_long), "|", basename(out_inst), "\n\n")

in_list <- paste0("'", paste(cursos_sel, collapse = "','"), "'")

nul <- dbExecute(con, sprintf(
  "CREATE OR REPLACE TABLE fonte AS SELECT * FROM read_parquet('%s')",
  gsub("\\\\", "/", src_path)))

# Todo slug pedido tem de existir na origem. Um slug renomeado la em
# cima sumiria em silencio de um IN (...), entao a checagem e explicita.
disponiveis <- dbGetQuery(con, "SELECT DISTINCT course_slug FROM fonte")$course_slug
ausentes <- setdiff(cursos_sel, disponiveis)
if (length(ausentes)) {
  stop("Slugs nao encontrados em ", basename(src_path), ": ",
       paste(ausentes, collapse = ", "))
}

####################################################################
### Recorte longo: curso x instituicao
####################################################################

# Filtro em rank, nunca LIMIT. Ver nota do cabecalho.
nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE sel AS
  SELECT * FROM fonte
  WHERE course_slug IN (%s) AND rank <= %d
  ORDER BY course_name, rank, institution_name", in_list, rank_cut))

####################################################################
### Recorte por instituicao
####################################################################

# any_value() so e legitimo porque os atributos sao constantes por id,
# e isso e verificado logo abaixo antes de qualquer uso do resultado.
conflitos <- dbGetQuery(con, "
  SELECT
    sum(CASE WHEN n_nome > 1 THEN 1 ELSE 0 END) AS nomes,
    sum(CASE WHEN n_abbr > 1 THEN 1 ELSE 0 END) AS abbrs,
    sum(CASE WHEN n_uf   > 1 THEN 1 ELSE 0 END) AS ufs,
    sum(CASE WHEN n_adm  > 1 THEN 1 ELSE 0 END) AS adms
  FROM (
    SELECT ruf_institution_id,
           count(DISTINCT institution_name) AS n_nome,
           count(DISTINCT abbr)             AS n_abbr,
           count(DISTINCT uf)               AS n_uf,
           count(DISTINCT administration)   AS n_adm
    FROM sel GROUP BY 1)")

stopifnot(conflitos$nomes == 0L, conflitos$abbrs == 0L,
          conflitos$ufs == 0L, conflitos$adms == 0L)

# n_campi fica de fora de proposito: conta os campi que oferecem AQUELE
# curso, entao nao e atributo da instituicao.
nul <- dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE inst AS
  SELECT
    ruf_institution_id,
    any_value(institution_name)                              AS institution_name,
    any_value(abbr)                                          AS abbr,
    any_value(uf)                                            AS uf,
    any_value(administration)                                AS administration,
    any_value(type)                                          AS type,
    count(*)                                                 AS %1$s,
    min(rank)                                                AS best_rank,
    max(rank)                                                AS worst_rank,
    round(avg(rank), 1)                                      AS mean_rank,
    string_agg(course_name, '; ' ORDER BY rank, course_name) AS courses
  FROM sel
  GROUP BY 1
  ORDER BY %1$s DESC, best_rank, institution_name", col_nc))

####################################################################
### Validacao
####################################################################

chk <- dbGetQuery(con, "
  SELECT
    count(*)                    AS linhas,
    count(DISTINCT course_slug) AS cursos,
    count(DISTINCT ruf_institution_id) AS inst,
    min(rank)                   AS rank_min,
    max(rank)                   AS rank_max,
    sum(is_banded::INT)         AS em_faixa
  FROM sel")

n_inst    <- dbGetQuery(con, "SELECT count(*) n FROM inst")$n
soma_inst <- dbGetQuery(con, sprintf("SELECT sum(%s) n FROM inst", col_nc))$n

cat("linhas selecionadas   :", chk$linhas, "\n")
cat("cursos                :", chk$cursos, "\n")
cat("instituicoes distintas:", chk$inst, "\n")
cat("faixa de posicoes     :", chk$rank_min, "a", chk$rank_max, "\n\n")

stopifnot(chk$cursos == length(cursos_sel),
          chk$rank_min == 1L,
          chk$rank_max == rank_cut,
          # O corte esta com folga dentro da regiao de posicao
          # individual; nenhuma linha em faixa pode ter entrado.
          chk$em_faixa == 0L,
          n_inst == chk$inst,
          # Amarra os dois arquivos um ao outro.
          soma_inst == chk$linhas)

if (!is.na(exp_rows) &&
    (chk$linhas != exp_rows || chk$cursos != exp_courses || n_inst != exp_inst)) {
  warning("Recorte com ", chk$linhas, " linhas / ", chk$cursos, " cursos / ",
          n_inst, " instituicoes, medido ", exp_rows, " / ", exp_courses,
          " / ", exp_inst, " no corte ", rank_cut, ". A edicao ", edition,
          " mudou?")
}

# Cobertura por curso, com o lider de cada um.
por_curso <- dbGetQuery(con, "
  SELECT
    s.course_name,
    count(*)                                                    AS n_top,
    sum(CASE WHEN s.administration = 'Publica' THEN 1 ELSE 0 END) AS publicas,
    sum(CASE WHEN s.administration = 'Privada' THEN 1 ELSE 0 END) AS privadas,
    max(CASE WHEN s.rank = 1 THEN s.abbr END)                   AS lider,
    (SELECT count(*) FROM fonte f WHERE f.course_slug = s.course_slug) AS avaliadas
  FROM sel s GROUP BY 1, s.course_slug ORDER BY 1")

cat("Top ", rank_cut, " por curso:\n", sep = "")
print(por_curso, right = FALSE)

# Mesma guarda do script 13: um curso fora de min(rank_cut, disponiveis)
# e reportado, nao aborta. Empate exatamente no corte devolve uma linha
# a mais.
estranhos <- por_curso[por_curso$n_top != pmin(rank_cut, por_curso$avaliadas), ]
if (nrow(estranhos)) {
  cat("\nCursos cujo top ", rank_cut, " nao tem exatamente ", rank_cut,
      " linhas:\n", sep = "")
  print(estranhos, right = FALSE)
  cat("Empates dentro do corte:\n")
  print(dbGetQuery(con, sprintf("
    SELECT course_name, rank, count(*) AS n
    FROM sel WHERE course_name IN ('%s')
    GROUP BY 1, 2 HAVING count(*) > 1 ORDER BY 1, 2",
    paste(estranhos$course_name, collapse = "','"))), right = FALSE)
} else {
  cat("\nTodos os ", nrow(por_curso), " cursos: exatamente min(", rank_cut,
      ", avaliadas) linhas.\n", sep = "")
}

cat("\nEmpates internos ao top ", rank_cut,
    " (nenhum em cima do corte):\n", sep = "")
print(dbGetQuery(con, "
  SELECT course_name, rank, count(*) AS n
  FROM sel GROUP BY 1, 2 HAVING count(*) > 1 ORDER BY 1, 2"), right = FALSE)

cat("\nInstituicoes por numero de cursos em que entram no top ",
    rank_cut, ":\n", sep = "")
print(dbGetQuery(con, sprintf("
  SELECT %1$s, count(*) AS n_instituicoes
  FROM inst GROUP BY 1 ORDER BY 1 DESC", col_nc)), right = FALSE)

cat("\nPresentes no top ", rank_cut, " de todos os ", chk$cursos,
    " cursos:\n", sep = "")
print(dbGetQuery(con, sprintf("
  SELECT abbr, institution_name, uf, administration, best_rank, mean_rank
  FROM inst WHERE %s = %d
  ORDER BY best_rank, institution_name", col_nc, chk$cursos)), right = FALSE)

# O que falta as quase-completas, separando AUSENTE DO RANKING de
# apenas fora do top N. Sao coisas diferentes e a USP e o caso: ela nao
# tem linha em Engenharia de controle e automacao. O piso e relativo ao
# numero de cursos, nao ao corte.
n_min_rel <- chk$cursos - 2L
cat("\nO que falta as instituicoes presentes em ", n_min_rel,
    " cursos ou mais:\n", sep = "")
print(dbGetQuery(con, sprintf("
  SELECT
    i.abbr,
    i.%1$s,
    c.course_name,
    CASE WHEN f.ruf_institution_id IS NULL
         THEN 'ausente do ranking'
         ELSE 'fora do top %2$d (' || f.rank_label || ')' END AS situacao
  FROM inst i
  CROSS JOIN (SELECT DISTINCT course_slug, course_name FROM sel) c
  LEFT JOIN sel s  ON s.ruf_institution_id = i.ruf_institution_id
                  AND s.course_slug = c.course_slug
  LEFT JOIN fonte f ON f.ruf_institution_id = i.ruf_institution_id
                   AND f.course_slug = c.course_slug
  WHERE i.%1$s >= %3$d AND s.ruf_institution_id IS NULL
  ORDER BY i.%1$s DESC, i.abbr, c.course_name",
  col_nc, rank_cut, n_min_rel)), right = FALSE)

####################################################################
### Escrita
####################################################################

nul <- dbExecute(con, sprintf(
  "COPY sel TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", gsub("\\\\", "/", out_long)))
nul <- dbExecute(con, sprintf(
  "COPY inst TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", gsub("\\\\", "/", out_inst)))

# Releitura com arrow: confirma que os parquets sao legiveis fora do
# DuckDB e que os acentos sobreviveram.
df_long <- arrow::read_parquet(out_long)
df_inst <- arrow::read_parquet(out_inst)

cat("\nreleitura arrow:\n")
cat("  ", basename(out_long), ":", nrow(df_long), "linhas,", ncol(df_long), "colunas\n")
cat("  ", basename(out_inst), ":", nrow(df_inst), "linhas,", ncol(df_inst), "colunas\n")

stopifnot(nrow(df_long) == chk$linhas,
          nrow(df_inst) == n_inst,
          sum(grepl("[^\x01-\x7f]", df_long$institution_name)) > 0L,
          sum(df_inst[[col_nc]]) == nrow(df_long))

cat("\nGravado:\n")
cat("  ", out_long, "(", round(file.size(out_long) / 1024, 1), "KB )\n")
cat("  ", out_inst, "(", round(file.size(out_inst) / 1024, 1), "KB )\n")
