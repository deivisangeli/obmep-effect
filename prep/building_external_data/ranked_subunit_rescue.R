####################################################################
###
### Braco de resgate: subunidade e sigla das instituicoes ranqueadas
###                                           [local only, offline]
###
### O 8q deixou 2.380.198 linhas com diploma valido sem openalex_id.
### A medicao do 8s mostrou que essa pilha e DUAS populacoes:
###
###   a) ~2,33 M linhas de faculdades privadas que simplesmente NAO
###      EXISTEM no snapshot do OpenAlex (1.947 instituicoes BR, todas
###      com producao de pesquisa). Dez das doze maiores grafias nao
###      casadas estao ausentes do catalogo. Nao ha o que casar. Este
###      script NAO mexe nelas.
###
###   b) 48.020 linhas que citam instituicao JA PRESENTE no catalogo
###      ranqueado (CWUR BR 52 + Xangai <= 901) e mesmo assim falharam.
###      PUC-Campinas tem 10.781 works, PUC Minas 18.336, UFSJ 14.897,
###      UFSCar 78.408. Essas sao falhas de verdade, e sao o alvo aqui.
###
### O modo de falha e de NOME, nao de pontuacao: o 8q so pontua dentro
### de um conjunto de candidatos, e essas linhas chegaram com conjunto
### vazio. Tres formas observadas:
###
###   1. subunidade  "Escola Politecnica da UFRJ", "EESC-USP",
###                  "ECA-USP", "FMRP da USP", "IAG PUC-Rio"
###   2. sigla nua   "UFRJ", "UFSCar", "PUC-RS"
###   3. decoracao   "UFSCar - Alumni", "UFSJ OFICIAL", "POLI USP PRO"
###
### -----------------------------------------------------------------
### ESTE SCRIPT PROPOE, ELE NAO RESOLVE
### -----------------------------------------------------------------
### Igual ao shanghai_acronym_arm.R (16a): grava um arquivo de
### CANDIDATOS e PARA. Nenhuma flag e publicada, nenhuma decisao do 8q
### e sobrescrita. A precisao vem da revisao manual, nao de uma regra
### -- e a medicao abaixo mostra exatamente por que.
###
### -----------------------------------------------------------------
### OS FALSOS POSITIVOS QUE AS GUARDAS EXISTEM PARA MATAR
### -----------------------------------------------------------------
### Um rascunho sem guardas produziu, entre os 20 maiores:
###
###   PUC-Campinas -> PUC   ERRADO. PUC-Campinas, PUC Minas e PUC-RS
###     sao TRES universidades distintas, todas colapsadas na unica
###     dona da sigla nua 'puc'. 7.242 linhas de lixo.
###   Faculdade Nova Roma -> NOVA      ERRADO
###   Nova faculdade      -> NOVA      ERRADO
###   Faculdade Cancao Nova -> NOVA    ERRADO. 'nova' e adjetivo comum
###     em portugues; a Universidade NOVA de Lisboa nao tem nada a ver.
###   Strong Business School Conveniada FGV -> FGV   ERRADO, e escola
###     conveniada, nao a FGV.
###
### Guardas, nesta ordem:
###
### G1. DONO UNICO. Alias reivindicado por mais de uma instituicao
###     ranqueada e descartado sem desempate. Herdada do 16a nota 2.
### G2. PREFIXO DE FAMILIA. Se existe OUTRA instituicao ranqueada com
###     alias comecando pela sigla mais espaco, a sigla e um prefixo de
###     familia e cai fora. E o que mata 'puc': a dona da sigla nua e
###     I162148367, mas 'puc rio' e I2699952. Esta guarda e a razao de
###     PUC-Campinas nao virar PUC.
### G3. SO SIGLA DE VERDADE, COM 3+ CARACTERES, no braco de contencao.
###     Token de nome comum ('escola', 'universidade') nunca casa.
### G4. SEM PISO ALEM DISSO. Herdada do 16a nota 3: 'USP', 'UFC',
###     'UnB' tem tres letras e a revisao decide cada uma.
###
### O que as guardas NAO resolvem fica marcado em `risco`, para a
### revisao ver primeiro: sigla que tambem e palavra comum ('nova') e
### grafia com palavra de convenio ('conveniada', 'polo', 'parceria').
###
### Produtos (todos em Data/intermediate/revelio_br_cohort/):
###   degree_duration_ranked_subunit_rescue.parquet       candidatos
###   degree_duration_ranked_subunit_rescue_candidates.csv  para revisar
###   degree_duration_ranked_subunit_rescue.xlsx          o caderno
###   degree_duration_ranked_subunit_rescue_report.json   o relatorio
###
### Depends on:
###   global_oa_hierarchy.R (8q)
###   ranked_education_flags.R (8r) -- catalogo ranqueado
###
### Shape reused from:
###   shanghai_acronym_arm.R (16a) -- dobra, guarda de dono unico, dois
###   arquivos (candidatos + classificado), caderno openxlsx.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Le parquet local, escreve parquet/csv/xlsx/json.
###    E prep/; nao vai para o SEDAP.
### 2. NAO SOBRESCREVE O 8q. Os produtos da hierarquia entram em
###    protected_paths e o md5 deles e conferido no fim.
### 3. DOIS ARQUIVOS, NAO UM. O .csv de candidatos e reescrito a cada
###    execucao; o arquivo revisado a mao tem outro nome e nunca e
###    tocado. Uma re-execucao nao pode apagar revisao.
### 4. NENHUM ID E INVENTADO. Todo oa_id proposto vem do catalogo de
###    120.658 registros, e isso e conferido.
### 5. O DENOMINADOR E 48.020, NUNCA 2.380.198. Reportar recuperacao
###    contra a pilha inteira seria mentir sobre o teto.
### 6. TEXTO QUE COMECA COM = + - @ E FORMULA PARA O EXCEL: a assercao
###    final e de identidade no round trip.
###
####################################################################

rm(list = ls()); gc()
options(width = 200)

for (p in c("DBI", "duckdb", "openxlsx", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}
library(DBI)
library(duckdb)
library(openxlsx)
library(jsonlite)

####################################################################
### Parametros
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
hier_dir <- file.path(coh_dir, "global_oa_hierarchy")
edu_dir  <- file.path(hier_dir, "education_parts")

cat_path  <- file.path(hier_dir, "catalog.parquet")
alias_path <- file.path(hier_dir, "aliases.parquet")
rank_path <- file.path(hier_dir,
  "global_oa_degree_duration_ranked_parent_catalog.parquet")

out_parquet <- file.path(coh_dir,
  "degree_duration_ranked_subunit_rescue.parquet")
cands_path <- file.path(coh_dir,
  "degree_duration_ranked_subunit_rescue_candidates.csv")
class_path <- file.path(coh_dir,
  "degree_duration_ranked_subunit_rescue_class.csv")   # nota 3: so a mao
xlsx_path <- file.path(coh_dir,
  "degree_duration_ranked_subunit_rescue.xlsx")
report_path <- file.path(coh_dir,
  "degree_duration_ranked_subunit_rescue_report.json")

# Nota 5: o denominador honesto, medido em 2026-09-14 pelo 8s.
exp_target_rows <- 48020L     # linhas nao casadas que citam universidade grande
exp_resid_rows  <- 2380198L   # a pilha inteira, so para contexto

min_acr_len <- 3L             # G3

# Siglas que tambem sao palavra comum em portugues ou ingles. NAO sao
# descartadas -- sao marcadas, porque 'NOVA IMS' e legitimo e
# 'Faculdade Nova Roma' nao, e so a revisao separa os dois.
common_words <- c("nova", "novo", "santa", "santo", "sao", "central",
                  "nacional", "superior", "unida", "integrada", "brasil",
                  "strong", "alfa", "beta", "master", "global")

# Palavras que denunciam convenio, nao identidade.
affil_words <- c("conveniad", "credenciad", "parceri", "polo ", " polo",
                 "associad", "representant")

verdict_domain <- c("aceita", "rejeita", "duvidoso")

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "8GB")
tmp_dir   <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_dd_rescue")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(dir.exists(edu_dir), file.exists(cat_path), file.exists(alias_path),
          file.exists(rank_path))

lock_file <- file.path(dirname(xlsx_path), paste0("~$", basename(xlsx_path)))
if (file.exists(xlsx_path) && file.exists(lock_file)) {
  stop("O caderno esta ABERTO no Excel (existe ", basename(lock_file),
       "). Feche-o antes de rodar.")
}

fw <- function(z) gsub("'", "''", z)

# Nota 2: o 8q e intocavel. md5 antes e depois.
protected_paths <- c(cat_path, alias_path, rank_path,
  file.path(hier_dir, "global_oa_hierarchy_report.json"),
  list.files(edu_dir, pattern = "[.]parquet$", full.names = TRUE))
protected_paths <- protected_paths[file.exists(protected_paths)]
protected_before <- unname(tools::md5sum(protected_paths))
stopifnot(!anyNA(protected_before))

####################################################################
### Conexao e dobra
####################################################################

con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
dbExecute(con, "SET threads=4")
dbExecute(con, sprintf("SET temp_directory='%s'",
                       fw(gsub("\\\\", "/", tmp_dir))))

# A dobra dura da pasta, mais hifen e barra virando espaco: e o que faz
# "EESC-USP" e "PUC-RS" virarem tokens separaveis. Sem barra invertida
# em lugar nenhum, de proposito (armadilha registrada no README).
dbExecute(con, "CREATE MACRO fold_hard(s) AS
  trim(regexp_replace(regexp_replace(
    replace(replace(replace(replace(replace(replace(replace(replace(
      lower(strip_accents(trim(s))),
      chr(13), ' '), chr(10), ' '), chr(9), ' '),
      ',', ''), '.', ''), '''', ''), '-', ' '), '/', ' '),
    '^the ', ''), ' +', ' ', 'g'))")

# `spellings` e coluna de EXIBICAO, nao chave. O texto livre do
# LinkedIn traz quebra de linha, tabulacao e U+FFFC (o marcador
# "adicionar uma foto", que nao carrega informacao nenhuma). O Excel
# normaliza tudo isso ao gravar, o que fazia a assercao de round trip
# falhar por representacao. Limpar na origem deixa o caderno legivel E
# a assercao exata. A chave rf nao passa por aqui.
dbExecute(con, "CREATE MACRO clean_disp(s) AS
  trim(regexp_replace(
    replace(replace(replace(replace(s, chr(65532), ''),
      chr(13), ' '), chr(10), ' '), chr(9), ' '),
    ' +', ' ', 'g'))")

edu_glob <- gsub("\\\\", "/", file.path(edu_dir, "*.parquet"))
dbExecute(con, sprintf("CREATE VIEW edu AS SELECT *,
  CASE WHEN coalesce(degree,'empty')='empty' AND degree_matches_laxed=1
       THEN 'bachelor' ELSE ranked_level END AS lvl
  FROM read_parquet('%s')", fw(edu_glob)))
dbExecute(con, sprintf("CREATE VIEW rk  AS SELECT * FROM read_parquet('%s')",
                       fw(rank_path)))
dbExecute(con, sprintf("CREATE VIEW al  AS SELECT * FROM read_parquet('%s')",
                       fw(alias_path)))
dbExecute(con, sprintf("CREATE VIEW cat AS SELECT * FROM read_parquet('%s')",
                       fw(cat_path)))

cat("DuckDB  :", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("educacao:", edu_dir, "\n\n")

####################################################################
### A -- os aliases das instituicoes ranqueadas, com G1 e G2
####################################################################

dbExecute(con, "CREATE TABLE rank_ids AS
  SELECT DISTINCT canonical_id AS oa_id FROM rk WHERE canonical_id IS NOT NULL")
n_rank <- dbGetQuery(con, "SELECT count(*) n FROM rank_ids")$n

dbExecute(con, "CREATE TABLE alias_all AS
  SELECT fold_hard(a.alias) AS af, r.oa_id, a.alias AS alias_ex,
         a.alias_kind AS kind,
         len(string_split(fold_hard(a.alias), ' ')) AS ntok
  FROM al a JOIN rank_ids r ON a.oa_id = r.oa_id
  WHERE a.alias IS NOT NULL AND length(trim(a.alias)) >= 2
    AND length(fold_hard(a.alias)) > 0")

# G1: sobrevive so o alias de dono unico.
dbExecute(con, "CREATE TABLE alias_u AS
  SELECT af, any_value(oa_id) AS oa_id, any_value(alias_ex) AS alias_ex,
         string_agg(DISTINCT kind, '/') AS kinds, max(ntok) AS ntok
  FROM alias_all GROUP BY af HAVING count(DISTINCT oa_id) = 1")

n_alias_all <- dbGetQuery(con, "SELECT count(DISTINCT af) n FROM alias_all")$n
n_alias_u   <- dbGetQuery(con, "SELECT count(*) n FROM alias_u")$n

# G1, reafirmada: se alguem trocar o HAVING por um arg_min, isto para.
g1 <- dbGetQuery(con, "SELECT count(*) n FROM (
  SELECT a.af FROM alias_all a JOIN alias_u u USING(af)
  GROUP BY a.af HAVING count(DISTINCT a.oa_id) > 1)")$n
if (g1 != 0) stop(g1, " alias aceitos com mais de um dono. Ver G1.")

# G2: prefixo de familia. Uma sigla cuja dona nua e X, mas que abre o
# nome de OUTRA instituicao ranqueada, nao identifica ninguem.
dbExecute(con, "CREATE TABLE family_pref AS
  SELECT DISTINCT u.af FROM alias_u u JOIN alias_all a
    ON a.af LIKE u.af || ' %' AND a.oa_id <> u.oa_id
  WHERE u.ntok = 1")
n_family <- dbGetQuery(con, "SELECT count(*) n FROM family_pref")$n
fam_list <- dbGetQuery(con, "SELECT af FROM family_pref ORDER BY af")$af

cat("instituicoes ranqueadas      :", n_rank, "\n")
cat("aliases dobrados             :", n_alias_all, "\n")
cat("com dono unico (G1)          :", n_alias_u, "\n")
cat("siglas mortas por familia(G2):", n_family,
    if (n_family > 0) paste0(" [", paste(head(fam_list, 12), collapse = ", "), "]") else "", "\n\n")

####################################################################
### B -- as grafias nao casadas com diploma valido
####################################################################

dbExecute(con, "CREATE TABLE raws AS
  SELECT fold_hard(university_raw) AS rf,
         string_agg(DISTINCT clean_disp(university_raw), ' | ') AS spellings,
         count(DISTINCT university_raw) AS n_spellings,
         count(*) AS n_rows, count(DISTINCT user_id) AS n_users,
         string_agg(DISTINCT global_oa_match_route, '/') AS rota,
         count(*) FILTER (WHERE lvl='bachelor') AS n_bachelor,
         count(*) FILTER (WHERE lvl='master')   AS n_master,
         count(*) FILTER (WHERE lvl='phd')      AS n_phd
  FROM edu
  WHERE lvl IN ('bachelor','master','phd') AND global_oa_selected_count = 0
    AND university_raw IS NOT NULL AND trim(university_raw) <> ''
    AND length(fold_hard(university_raw)) > 0
  GROUP BY 1")
pop <- dbGetQuery(con, "SELECT count(*) grafias, sum(n_rows) linhas,
  sum(n_users) usuarios FROM raws")
cat("grafias nao casadas :", pop$grafias, "| linhas:", pop$linhas, "\n\n")

####################################################################
### C -- os tres bracos
####################################################################

# Braco 1: igualdade exata da dobra. Nao precisa de guarda alem de G1.
dbExecute(con, "CREATE TABLE hit_exato AS
  SELECT r.rf, a.oa_id, a.alias_ex, a.kinds, 'exato' AS braco
  FROM raws r JOIN alias_u a ON r.rf = a.af")

# Braco 2: decoracao. Sufixos que a pessoa acrescenta e que nao fazem
# parte do nome. Tira e tenta de novo a igualdade exata.
dbExecute(con, "CREATE MACRO strip_decor(s) AS
  trim(regexp_replace(s, ' (alumni|oficial|official|pro|ex aluno|ex alunos|egresso|egressos|campus|online|ead|virtual)$', '', 'g'))")
dbExecute(con, "CREATE TABLE hit_decor AS
  SELECT r.rf, a.oa_id, a.alias_ex, a.kinds, 'decorado' AS braco
  FROM raws r JOIN alias_u a ON strip_decor(r.rf) = a.af
  WHERE r.rf NOT IN (SELECT rf FROM hit_exato) AND strip_decor(r.rf) <> r.rf")

# Braco 3: sigla contida. G2 e G3 aplicadas aqui, que e onde o risco
# esta. Equi-join por token: nada de produto cartesiano com regex.
dbExecute(con, "CREATE TABLE tok AS
  SELECT rf, unnest(string_split(rf, ' ')) AS w FROM raws")
dbExecute(con, sprintf("CREATE TABLE hit_sigla AS
  SELECT t.rf, any_value(a.oa_id) AS oa_id, any_value(a.alias_ex) AS alias_ex,
         any_value(a.kinds) AS kinds, 'sigla_contida' AS braco,
         count(DISTINCT a.oa_id) AS n_donos
  FROM tok t JOIN alias_u a ON a.af = t.w
  WHERE a.ntok = 1
    AND a.kinds LIKE '%%acronym%%'                       -- G3
    AND length(a.af) >= %d                               -- G3
    AND a.af NOT IN (SELECT af FROM family_pref)         -- G2
    AND t.rf NOT IN (SELECT rf FROM hit_exato)
    AND t.rf NOT IN (SELECT rf FROM hit_decor)
  GROUP BY t.rf", min_acr_len))
n_amb <- dbGetQuery(con, "SELECT count(*) n FROM hit_sigla WHERE n_donos > 1")$n
dbExecute(con, "DELETE FROM hit_sigla WHERE n_donos > 1")

cat("braco exato        :", dbGetQuery(con, "SELECT count(*) n FROM hit_exato")$n, "grafias\n")
cat("braco decorado     :", dbGetQuery(con, "SELECT count(*) n FROM hit_decor")$n, "grafias\n")
cat("braco sigla contida:", dbGetQuery(con, "SELECT count(*) n FROM hit_sigla")$n,
    "grafias (", n_amb, "descartadas por ambiguidade no texto )\n\n")

####################################################################
### D -- a tabela de candidatos
####################################################################

cw_list <- paste(sprintf("'%s'", common_words), collapse = ",")
af_like <- paste(sprintf("lower(r.spellings) LIKE '%%%s%%'",
                         gsub("'", "''", affil_words)), collapse = " OR ")

dbExecute(con, sprintf("CREATE TABLE cand AS
  SELECT r.rf, r.spellings, r.n_spellings, r.n_rows, r.n_users, r.rota,
         r.n_bachelor, r.n_master, r.n_phd,
         h.braco, h.oa_id, h.alias_ex, h.kinds,
         c.display_name AS oa_display_name,
         coalesce(c.country_code, '??') AS oa_country,
         coalesce(c.type, '?') AS oa_type,
         coalesce(c.works_count, 0) AS oa_works,
         k.fam AS rank_family, k.rk AS rank_pos, k.inst AS rank_inst,
         CASE
           WHEN h.braco = 'sigla_contida'
                AND lower(h.alias_ex) IN (%s) THEN 'alto: sigla e palavra comum'
           WHEN h.braco = 'sigla_contida' AND (%s) THEN 'alto: grafia de convenio'
           WHEN h.braco = 'sigla_contida' THEN 'medio: sigla contida'
           WHEN h.braco = 'decorado' THEN 'baixo: decoracao removida'
           ELSE 'baixo: igualdade exata'
         END AS risco
  FROM (SELECT rf, oa_id, alias_ex, kinds, braco FROM hit_exato
        UNION ALL SELECT rf, oa_id, alias_ex, kinds, braco FROM hit_decor
        UNION ALL SELECT rf, oa_id, alias_ex, kinds, braco FROM hit_sigla) h
  JOIN raws r USING(rf)
  LEFT JOIN cat c ON c.oa_id = h.oa_id
  LEFT JOIN (SELECT q.canonical_id, any_value(q.\"family\") AS fam,
                    min(q.rk) AS rk, any_value(q.inst) AS inst
             FROM rk q GROUP BY q.canonical_id) k
    ON k.canonical_id = h.oa_id", cw_list, af_like))

# Nota 4: nenhum id inventado.
orf <- dbGetQuery(con, "SELECT count(*) n FROM cand WHERE oa_display_name IS NULL")$n
if (orf != 0) stop(orf, " candidatos com oa_id fora do catalogo. Ver nota 4.")
# uma grafia, uma proposta
dup <- dbGetQuery(con, "SELECT count(*) n FROM (SELECT rf FROM cand GROUP BY rf HAVING count(*)>1)")$n
if (dup != 0) stop(dup, " grafias com mais de uma proposta; os bracos deveriam ser disjuntos.")

tot <- dbGetQuery(con, "SELECT count(*) grafias, sum(n_rows) linhas,
  sum(n_users) usuarios FROM cand")
por_braco <- dbGetQuery(con, "SELECT braco, count(*) grafias, sum(n_rows) linhas,
  sum(n_users) usuarios FROM cand GROUP BY 1 ORDER BY 3 DESC")
por_risco <- dbGetQuery(con, "SELECT risco, count(*) grafias, sum(n_rows) linhas
  FROM cand GROUP BY 1 ORDER BY 3 DESC")
# O alvo de 48.020 foi medido SO sobre grafias que citam universidade
# grande brasileira. Os bracos aqui tambem alcancam instituicao
# ranqueada estrangeira (Technion, PSL, NOVA de Lisboa), entao somar as
# duas contra aquele denominador daria taxa acima de 100% -- que e
# exatamente o tipo de numero que esta pasta existe para nao publicar.
por_pais <- dbGetQuery(con, "SELECT
  CASE WHEN oa_country = 'BR' THEN 'instituicao ranqueada BR'
       ELSE 'instituicao ranqueada estrangeira' END AS onde,
  count(*) grafias, sum(n_rows) linhas, sum(n_users) usuarios
  FROM cand GROUP BY 1 ORDER BY 3 DESC")
linhas_br <- sum(por_pais$linhas[por_pais$onde == "instituicao ranqueada BR"])

cat("=== candidatos propostos ===\n")
print(tot, row.names = FALSE)
cat("\n"); print(por_braco, row.names = FALSE)
cat("\n"); print(por_risco, row.names = FALSE)
cat("\n"); print(por_pais, row.names = FALSE)

invisible(dbExecute(con, sprintf(
  "COPY (SELECT * FROM cand ORDER BY n_rows DESC, rf) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_parquet))))

cand <- dbGetQuery(con, "SELECT * FROM cand ORDER BY n_rows DESC, rf")

####################################################################
### E -- os dois arquivos de revisao (nota 3)
####################################################################

rev <- cand[, c("rf", "spellings", "n_spellings", "n_rows", "n_users", "rota",
                "braco", "risco", "alias_ex", "oa_id", "oa_display_name",
                "oa_country", "oa_type", "oa_works", "rank_family",
                "rank_pos", "rank_inst")]
rev$veredito <- ""
rev$motivo   <- ""

write.csv(rev, cands_path, row.names = FALSE, fileEncoding = "UTF-8")
cat("\ncandidatos gravados :", cands_path, "\n")
if (file.exists(class_path)) {
  cat("revisao existente   :", class_path, " (NAO tocada, nota 3)\n")
} else {
  cat("revisao a fazer     :", class_path, " (copie o csv acima e preencha)\n")
}

####################################################################
### F -- o caderno
####################################################################

resgatados <- 0L
if (file.exists(xlsx_path)) {
  old <- openxlsx::read.xlsx(xlsx_path, sheet = "Candidatos")
  if (!all(c("rf", "veredito", "motivo") %in% names(old))) {
    stop("O caderno existente nao tem rf/veredito/motivo. Nao regravo por cima.")
  }
  k <- match(rev$rf, old$rf)
  rev$veredito <- ifelse(is.na(k) | is.na(old$veredito[k]), "", old$veredito[k])
  rev$motivo   <- ifelse(is.na(k) | is.na(old$motivo[k]),   "", old$motivo[k])
  resgatados <- sum(trimws(rev$veredito) != "")
  cat("caderno anterior lido:", resgatados, "veredito(s) preservado(s)\n")
  invisible(file.remove(xlsx_path))
}

for (cl in names(rev)) if (is.character(rev[[cl]])) {
  rev[[cl]] <- ifelse(is.na(rev[[cl]]), "", rev[[cl]])
}
n_col <- ncol(rev)

leia <- data.frame(c(
  "RESGATE DE SUBUNIDADE E SIGLA -- instituicoes ranqueadas apenas",
  "",
  "O QUE ESTA AQUI",
  sprintf("  %d grafias nao casadas que parecem citar uma das %d",
          nrow(rev), n_rank),
  "  instituicoes dos catalogos ranqueados (CWUR BR 52 + Xangai <= 901).",
  "",
  "POR QUE SO AS RANQUEADAS",
  sprintf("  A pilha nao casada tem %s linhas, mas a maior parte dela e de",
          formatC(exp_resid_rows, format = "d", big.mark = ".", decimal.mark = ",")),
  "  faculdades privadas AUSENTES do OpenAlex -- 10 das 12 maiores nao",
  "  existem no snapshot. Nao ha id para atribuir. Alargar este braco",
  "  para elas nao recupera nada e fabrica casamento falso.",
  sprintf("  O alvo legitimo e ~%s linhas: instituicoes que JA estao no",
          formatC(exp_target_rows, format = "d", big.mark = ".", decimal.mark = ",")),
  "  catalogo, com milhares de works, e mesmo assim falharam.",
  "",
  "COMO JULGAR",
  "  Compare spellings (o que a pessoa escreveu) contra oa_display_name",
  "  (o que o id proposto E). O rotulo da Revelio nao entra aqui.",
  "  Aceite quando a grafia for a instituicao ou uma SUBUNIDADE dela",
  "  (faculdade, escola, instituto interno). Rejeite quando for outra",
  "  instituicao, uma conveniada, ou um curso.",
  "",
  "LEIA A COLUNA risco PRIMEIRO",
  "  alto: sigla e palavra comum   'NOVA' casa 'Faculdade Nova Roma' e",
  "     tambem 'NOVA IMS'. O primeiro e lixo, o segundo e legitimo.",
  "  alto: grafia de convenio      'Strong Business School Conveniada",
  "     FGV' NAO e a FGV.",
  "  medio: sigla contida          subunidade provavel, confira.",
  "  baixo                         igualdade exata ou decoracao.",
  "",
  "O QUE AS GUARDAS JA MATARAM, PARA VOCE NAO PROCURAR",
  "  G1 dono unico: alias de duas instituicoes cai fora sem desempate.",
  sprintf("  G2 prefixo de familia: %d sigla(s) mortas. E o que impede", n_family),
  "     PUC-Campinas, PUC Minas e PUC-RS de virarem todas a mesma 'PUC'.",
  "  G3 so sigla de verdade, 3+ caracteres, no braco de contencao.",
  "",
  "VEREDITO",
  "  aceita     o id proposto e a instituicao (ou o pai da subunidade)",
  "  rejeita    o id e de outra instituicao",
  "  duvidoso   a grafia nao permite decidir",
  "",
  "NADA DAQUI VIRA FLAG SOZINHO. Este script propoe; a publicacao e",
  "uma decisao separada, depois da revisao."),
  stringsAsFactors = FALSE)
names(leia) <- "Como ler este caderno"

wb <- createWorkbook()
hdr <- createStyle(textDecoration = "bold", fgFill = "#E8E8E8",
                   border = "bottom", valign = "top", wrapText = TRUE)
wrap  <- createStyle(wrap = TRUE, valign = "top")
txt   <- createStyle(numFmt = "TEXT", valign = "top")
oasty <- createStyle(fgFill = "#F3EFF7", valign = "top")
yours <- createStyle(fgFill = "#FFF7D6", border = "TopBottomLeftRight",
                     borderColour = "#C9A227", valign = "top")

addWorksheet(wb, "Como ler")
writeData(wb, "Como ler", leia)
addStyle(wb, "Como ler", hdr, rows = 1, cols = 1)
setColWidths(wb, "Como ler", cols = 1, widths = 80)

addWorksheet(wb, "Candidatos")
writeData(wb, "Candidatos", rev, withFilter = TRUE)
freezePane(wb, "Candidatos", firstActiveRow = 2, firstActiveCol = 3)
addStyle(wb, "Candidatos", hdr, rows = 1, cols = 1:n_col, gridExpand = TRUE)
rr <- 2:(nrow(rev) + 1)
addStyle(wb, "Candidatos", txt, rows = rr, cols = 10, gridExpand = TRUE)
addStyle(wb, "Candidatos", oasty, rows = rr, cols = 9:17, gridExpand = TRUE)
addStyle(wb, "Candidatos", yours, rows = rr, cols = 18:19, gridExpand = TRUE)
addStyle(wb, "Candidatos", wrap, rows = rr, cols = c(1, 2, 11, 17, 19),
         gridExpand = TRUE, stack = TRUE)
setColWidths(wb, "Candidatos", cols = 1:n_col,
             widths = c(40, 56, 8, 9, 9, 22, 15, 28, 18, 14, 40,
                        10, 12, 10, 8, 8, 34, 12, 40))
# O olho vai para o risco alto.
conditionalFormatting(wb, "Candidatos", cols = 1:n_col, rows = rr,
                      rule = 'LEFT($H2,4)="alto"', type = "expression",
                      style = createStyle(bgFill = "#FBE6E6"))

addWorksheet(wb, "dominio")
writeData(wb, "dominio", data.frame(veredito = verdict_domain))
sheetVisibility(wb)[which(names(wb) == "dominio")] <- "hidden"
dataValidation(wb, "Candidatos", col = 18, rows = rr, type = "list",
               value = sprintf("'dominio'!$A$2:$A$%d", length(verdict_domain) + 1L))

addWorksheet(wb, "Resumo")
writeData(wb, "Resumo", "Candidatos por braco", startRow = 1)
writeData(wb, "Resumo", por_braco, startRow = 2)
r2 <- nrow(por_braco) + 5
writeData(wb, "Resumo", "Candidatos por risco", startRow = r2)
writeData(wb, "Resumo", por_risco, startRow = r2 + 1)
r3 <- r2 + nrow(por_risco) + 4
writeData(wb, "Resumo", data.frame(
  medida = c("instituicoes ranqueadas", "aliases com dono unico (G1)",
             "siglas mortas por familia (G2)", "grafias nao casadas na pilha",
             "alvo legitimo (linhas, 8s)", "pilha inteira (linhas, 8s)",
             "grafias propostas", "linhas cobertas", "usuarios cobertos"),
  valor = c(n_rank, n_alias_u, n_family, pop$grafias, exp_target_rows,
            exp_resid_rows, tot$grafias, tot$linhas, tot$usuarios)),
  startRow = r3)
addStyle(wb, "Resumo", hdr, rows = c(2, r2 + 1, r3), cols = 1:4,
         gridExpand = TRUE)
setColWidths(wb, "Resumo", cols = 1:4, widths = c(32, 12, 12, 12))

saveWorkbook(wb, xlsx_path, overwrite = FALSE)

####################################################################
### Validacao
####################################################################

chk <- openxlsx::read.xlsx(xlsx_path, sheet = "Candidatos")
if (nrow(chk) != nrow(rev) || ncol(chk) != n_col) {
  stop(sprintf("releitura com %dx%d, esperado %dx%d",
               nrow(chk), ncol(chk), nrow(rev), n_col))
}
if (!all(grepl("^I[0-9]+$", chk$oa_id))) {
  stop("oa_id nao sobreviveu como ^I[0-9]+$ no xlsx.")
}
# Duas normalizacoes, ambas de REPRESENTACAO e nunca de conteudo,
# aplicadas aos DOIS lados para que mangling de verdade continue
# falhando:
#   CRLF -> LF     o Excel normaliza quebra de linha ao gravar, e
#                  university_raw do LinkedIn tem quebra embutida (e
#                  ate U+FFFC, o "adicionar uma foto").
#   entidade XML   o LinkedIn escapa aspas como &quot;, o openxlsx
#                  grava isso literal e o leitor XML do Excel
#                  decodifica de volta para ". Grafia real encontrada:
#                  UNESP ... &quot;Julio de Mesquita Filho&quot;.
nl <- function(z) {
  z <- ifelse(is.na(z), "", as.character(z))
  z <- gsub("\r\n", "\n", z, fixed = TRUE)
  z <- gsub("&quot;", "\"", z, fixed = TRUE)
  z <- gsub("&apos;", "'", z, fixed = TRUE)
  z <- gsub("&lt;", "<", z, fixed = TRUE)
  z <- gsub("&gt;", ">", z, fixed = TRUE)
  gsub("&amp;", "&", z, fixed = TRUE)
}
rt <- function(a, b, nm) {
  a <- nl(a); b <- nl(b)
  if (!identical(a, b)) stop(sum(a != b), " celula(s) de ", nm,
                             " nao sobreviveram ao round trip.")
}
rt(chk$rf, rev$rf, "rf")
rt(chk$spellings, rev$spellings, "spellings")
rt(chk$oa_display_name, rev$oa_display_name, "oa_display_name")

# Nota 2: o 8q continua byte a byte igual.
protected_after <- unname(tools::md5sum(protected_paths))
if (!identical(protected_before, protected_after)) {
  stop("PRODUTO DO 8q ALTERADO. Isto nunca deveria acontecer.")
}

####################################################################
### Relatorio
####################################################################

write_json(list(
  completed_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
  scope = list(
    population = "Unmatched valid-degree education rows, degree_duration cohort",
    restricted_to = "Institutions already in the CWUR BR 52 + Shanghai <=901 catalogs",
    not_attempted = paste("The ~2.33M-row private-institution residue:",
                          "absent from the OpenAlex snapshot, unmatchable"),
    target_rows = exp_target_rows, residue_rows = exp_resid_rows),
  guards = list(
    G1_unique_owner = "alias claimed by >1 ranked institution discarded",
    G2_family_prefix = list(n = n_family, acronyms = fam_list),
    G3_acronym_only = sprintf("containment arm: acronym kind, >= %d chars", min_acr_len),
    ambiguous_in_text = n_amb),
  inputs = data.frame(path = protected_paths, md5 = protected_before),
  population = pop, totals = tot, by_arm = por_braco, by_risk = por_risco,
  by_country = por_pais, br_rows_covered = linhas_br,
  outputs = data.frame(
    path = c(out_parquet, cands_path, xlsx_path),
    md5 = unname(tools::md5sum(c(out_parquet, cands_path, xlsx_path)))),
  published_flags = FALSE,
  note = "Proposals only. Nothing here reaches a flag without the hand review."),
  report_path, pretty = TRUE, auto_unbox = TRUE, dataframe = "rows",
  digits = 16, na = "null")

cat("\n==================================================================\n")
cat("Resgate de subunidade e sigla -- candidatos, NAO flags\n")
cat("==================================================================\n\n")
print(por_braco, row.names = FALSE)
cat("\n")
print(por_risco, row.names = FALSE)
print(por_pais, row.names = FALSE)
cat(sprintf("\n  grafias propostas : %d\n  linhas cobertas   : %d (usuarios: %d)\n",
            tot$grafias, tot$linhas, tot$usuarios))
cat(sprintf("  em instituicao ranqueada BR : %d\n", linhas_br))
cat(sprintf("  alvo BR medido pelo 8s      : %d (%.1f%% coberto)\n",
            exp_target_rows, 100 * linhas_br / exp_target_rows))
if (resgatados > 0L) cat(sprintf("  resgatados        : %d veredito(s)\n", resgatados))
cat(sprintf("\n  %s\n  %s\n  %s\n  %s\n\n",
            out_parquet, cands_path, xlsx_path, report_path))
cat("Nenhuma flag foi publicada. Revise o caderno antes de qualquer passo.\n")
cat("Leia a coluna risco primeiro: 'alto' e onde estao os falsos positivos.\n\n")
