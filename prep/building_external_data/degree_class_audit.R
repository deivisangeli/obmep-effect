####################################################################
###
### Auditoria da CLASSIFICACAO DE DIPLOMA -- coorte degree_duration
###                                           [local only, offline]
###
### Toda a participacao do coorte _degree_duration depende de UM
### classificador: a cascata ordenada de regex do br_degree_patterns.R
### mais o resgate por duracao de 3-6 anos. Nada nesta pasta mediu a
### acuracia dele sobre este coorte.
###
### A unica auditoria de nivel que existe, shanghai_flag_audit.R,
### reporta 99,2% de acuracia em 4 classes -- mas o README (secao
### "Auditando as flags de Xangai") declara que o gabarito dela "foi
### escrito por um LLM -- o mesmo agente que escreveu os padroes sob
### teste... uma auto-avaliacao com conflito de interesse". Este
### caderno e para uma PESSOA, e diz isso na primeira tela.
###
### Duas abas de 100: o que o pipeline chama de bachelor/master/phd, e
### o que ele chama de other.
###
### -----------------------------------------------------------------
### O BRACO VENCEDOR E RECONSTRUIVEL, E EXATAMENTE
### -----------------------------------------------------------------
### Nenhum artefato da pasta registra QUAL braco da cascata deu o nivel
### a uma linha. Decompor sql_ranked_level nos seus predicados
### ordenados e pegar o primeiro TRUE reproduz o ranked_level gravado
### com ZERO discrepancias nas 19.710.307 linhas. E isso que torna a
### precisao POR REGRA mensuravel, que e o ponto da auditoria.
###
###   braco  teste                                    ->        linhas
###   A0     rx_hs                                    other  1.567.296
###   A1     rx_notdeg                                other    109.463
###   A2     degree='Doctor' OU rx_phd                phd      128.651
###   A3     degree IN ('Master','MBA') OU            master 1.559.397
###          (NAO rx_lato E rx_msc)
###   A4     rx_notdeg_weak                           other     61.155
###   A5     rx_post16 E NAO rx_bach16                other  1.231.898
###   A6     sql_is_bachelor OU rx_bach16             bach   7.677.911
###   A7     ELSE terminal                            other  4.627.902
###   A7+dur A7 resgatado pela duracao                bach   2.746.634
###
### -----------------------------------------------------------------
### O RESGATE POR DURACAO TEM QUATRO CONDICOES, NAO DUAS
### -----------------------------------------------------------------
### Nao e so "degree vazio e 3-6 anos". De sql_is_residual_other:
###
###   coalesce(degree,'empty') = 'empty'    o rotulo da Revelio cala
###   E sql_ranked_level = 'other'          a cascata ja recusou
###   E NAO rx_explicit_non_bachelor        sem marca de pos, tecnico,
###                                         medio ou nao-diploma
###   E startdate E enddate nao nulos
###   E end_year - start_year IN (3,4,5,6)
###
### rx_explicit_non_bachelor e a uniao de rx_notdeg, rx_notdeg_weak,
### rx_post, rx_post16, rx_tech, rx_hs, 'post[ -]?grad' e 'tecnic'. E
### por isso que o resgate so alcanca o ELSE terminal e NUNCA os bracos
### A0, A1, A4 ou A5 -- confirmado: as 2.746.634 linhas resgatadas vem
### todas do A7.
###
### A aba "Como ler" repete essa regra na integra. Um revisor a quem se
### diga apenas "degree vazio + 3 a 6 anos" vai procurar linhas de
### Ensino Medio e Pos-graduacao resgatadas, nao achar, e marcar a
### ausencia como defeito.
###
### -----------------------------------------------------------------
### ONDE O RISCO ESTA DE VERDADE
### -----------------------------------------------------------------
### degree_raw -- o texto que a cascata le -- esta preenchido em 90,2%
### da classe negativa, entao aquelas recusas sao auditaveis. A
### exposicao esta do lado positivo: 805.902 linhas classificadas
### bachelor NAO TEM TEXTO NENHUM em degree_raw (mais 6.284 master e
### 583 phd). Sao inferencias puras de um intervalo de 3-6 anos. O
### braco A7+dur e 22,7% de todos os bachelors e nao repousa sobre
### nenhuma evidencia textual.
###
### Produtos (em Data/intermediate/revelio_br_cohort/):
###   degree_duration_degree_class_audit.parquet       o sorteio
###   degree_duration_degree_class_audit.xlsx          o caderno
###   degree_duration_degree_class_audit_report.json   o relatorio
###
### Depends on:
###   global_oa_hierarchy.R (8q) -- education_parts
###   br_degree_patterns.R (7) -- as constantes, so constantes
###
### Shape reused from:
###   unmatched_school_audit_sample.R (8j) e
###   unmatched_valid_degree_sample.R (8s).
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Le parquet local, escreve parquet/xlsx/json.
###    E prep/; nao vai para o SEDAP.
### 2. AS DUAS ABAS SAO ESTRATIFICADAS. Nao existe "a taxa" deste
###    caderno. O Resumo declara populacao e PESO de cada estrato; sem
###    ponderar, qualquer numero daqui esta errado por construcao.
### 3. NAO REESCREVER A CASCATA A MAO. O education_flags_audit_500.R
###    (linha 111) remonta a expressao em vez de usar a constante, e o
###    cabecalho do br_degree_patterns.R avisa que isso e deriva. Aqui
###    a decomposicao e inevitavel (e o que da o braco), entao a trava
###    e a assercao de que ela reproduz ranked_level com zero
###    discrepancia.
### 4. ORDER BY hash(...) LIMIT n por estrato, NUNCA USING SAMPLE.
### 5. user_id E int64: as.character ou vira 1.23457E+15.
### 6. CRLF E ENTIDADE XML sao representacao, nao perda. degree_raw e
###    texto livre do LinkedIn. Normalizar nos DOIS lados.
### 7. NAO SOBRESCREVE O CADERNO nem os produtos do 8q.
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
coh_dir  <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
hier_dir <- file.path(coh_dir, "global_oa_hierarchy")
edu_dir  <- file.path(hier_dir, "education_parts")

patterns_path <- Sys.getenv("OBMEP_DEGREE_PATTERNS",
  unset = "prep/building_external_data/br_degree_patterns.R")

sample_path <- file.path(coh_dir, "degree_duration_degree_class_audit.parquet")
xlsx_path   <- file.path(coh_dir, "degree_duration_degree_class_audit.xlsx")
report_path <- file.path(coh_dir,
  "degree_duration_degree_class_audit_report.json")

seed <- 20260914L

# Nota 2: estrato -> quantas sortear. Populacao e peso saem medidos.
strata_pos <- c(
  "P1 bachelor A6 regex ranqueada"      = 25L,
  "P2 bachelor A7+dur (sem texto)"      = 25L,
  "P3 master A3"                        = 30L,
  "P4 phd A2"                           = 20L)
strata_neg <- c(
  "N1 other A7 ELSE terminal"           = 30L,
  "N2 other A0 rx_hs"                   = 20L,
  "N3 other A5 rx_post16"               = 20L,
  "N4 other A1 rx_notdeg"               = 15L,
  "N5 other A4 rx_notdeg_weak"          = 15L)

level_domain <- c("bachelor", "master", "phd", "other", "indeterminado")

# Medidos em 2026-09-14. Travas: 8q reconstruido para o sorteio.
exp_arm <- c(A0_rx_hs = 1567296L, A1_rx_notdeg = 109463L, A2_phd = 128651L,
             A3_master = 1559397L, A4_rx_notdeg_weak = 61155L,
             A5_rx_post16 = 1231898L, A6_bachelor = 7677911L,
             A7_else = 7374536L)          # 4.627.902 other + 2.746.634 dur
exp_total <- 19710307L

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "8GB")
tmp_dir   <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_dd_class_audit")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(dir.exists(edu_dir), file.exists(patterns_path))

lock_file <- file.path(dirname(xlsx_path), paste0("~$", basename(xlsx_path)))
if (file.exists(xlsx_path) && file.exists(lock_file)) {
  stop("O caderno esta ABERTO no Excel (existe ", basename(lock_file),
       "). Feche-o antes de rodar.")
}

fw <- function(z) gsub("'", "''", z)

# Nota 7: os produtos do 8q sao intocaveis.
protected_paths <- c(patterns_path,
  list.files(edu_dir, pattern = "[.]parquet$", full.names = TRUE))
protected_before <- unname(tools::md5sum(protected_paths))
stopifnot(!anyNA(protected_before))

####################################################################
### As constantes. So constantes -- o arquivo nao tem efeito colateral.
####################################################################

source(patterns_path)
stopifnot(exists("sql_is_bachelor"), exists("rx_hs"), exists("rx_phd"),
          exists("rx_msc"), exists("rx_lato"), exists("rx_notdeg"),
          exists("rx_notdeg_weak"), exists("rx_post16"), exists("rx_bach16"),
          exists("rx_b1"), exists("rx_b2"), exists("rx_post"), exists("rx_tech"))

con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
dbExecute(con, "SET threads=4")
dbExecute(con, sprintf("SET temp_directory='%s'",
                       fw(gsub("\\\\", "/", tmp_dir))))
# O shim documentado no br_degree_patterns.R: as expressoes sao Trino.
dbExecute(con, "CREATE MACRO regexp_like(s,p) AS regexp_matches(s,p)")

edu_glob <- gsub("\\\\", "/", file.path(edu_dir, "*.parquet"))
dbExecute(con, sprintf("CREATE VIEW edu AS
  SELECT *, lower(trim(coalesce(degree_raw,''))) AS dr
  FROM read_parquet('%s')", fw(edu_glob)))

####################################################################
### A -- o braco vencedor, na ordem da cascata
####################################################################

arm_sql <- sprintf("CASE
   WHEN regexp_like(dr,'%s') THEN 'A0_rx_hs'
   WHEN regexp_like(dr,'%s') THEN 'A1_rx_notdeg'
   WHEN degree='Doctor' OR regexp_like(dr,'%s') THEN 'A2_phd'
   WHEN degree IN ('Master','MBA')
        OR (NOT regexp_like(dr,'%s') AND regexp_like(dr,'%s')) THEN 'A3_master'
   WHEN regexp_like(dr,'%s') THEN 'A4_rx_notdeg_weak'
   WHEN regexp_like(dr,'%s') AND NOT regexp_like(dr,'%s') THEN 'A5_rx_post16'
   WHEN (%s) OR regexp_like(dr,'%s') THEN 'A6_bachelor'
   ELSE 'A7_else' END",
  rx_hs, rx_notdeg, rx_phd, rx_lato, rx_msc, rx_notdeg_weak,
  rx_post16, rx_bach16, sql_is_bachelor, rx_bach16)

# Sub-braco do A6, na ordem interna de sql_is_bachelor.
sub_sql <- sprintf("CASE
   WHEN degree='Bachelor' THEN '6a degree=Bachelor'
   WHEN NOT regexp_like(dr,'%s') AND NOT regexp_like(dr,'%s')
        AND NOT regexp_like(dr,'%s') AND regexp_like(dr,'%s') THEN '6b rx_b1'
   WHEN NOT regexp_like(dr,'%s') AND NOT regexp_like(dr,'%s')
        AND NOT regexp_like(dr,'%s') AND regexp_like(dr,'%s') THEN '6c rx_b2'
   WHEN regexp_like(dr,'%s') THEN '6d rx_bach16'
   ELSE '' END",
  rx_post, rx_tech, rx_hs, rx_b1, rx_post, rx_tech, rx_hs, rx_b2, rx_bach16)

dbExecute(con, sprintf("CREATE VIEW a AS SELECT *,
  (%s) AS arm,
  CASE WHEN coalesce(degree,'empty')='empty' AND degree_matches_laxed=1
       THEN 'bachelor' ELSE ranked_level END AS lvl,
  CASE WHEN (%s)='A6_bachelor' THEN (%s) ELSE '' END AS sub_arm,
  CASE WHEN startdate IS NOT NULL AND enddate IS NOT NULL
       THEN year(enddate) - year(startdate) END AS anos
  FROM edu", arm_sql, arm_sql, sub_sql))

cat("Reconciliando o braco contra o ranked_level gravado.\n")
recon <- dbGetQuery(con, "SELECT count(*) AS total,
  count(*) FILTER (WHERE
    (CASE WHEN arm='A2_phd' THEN 'phd' WHEN arm='A3_master' THEN 'master'
          WHEN arm='A6_bachelor' THEN 'bachelor' ELSE 'other' END)
    <> ranked_level) AS discrepancias FROM a")
print(recon, row.names = FALSE)
# Nota 3: a trava que substitui chamar sql_ranked_level direto.
stopifnot(recon$total == exp_total, recon$discrepancias == 0L)

arms <- dbGetQuery(con, "SELECT arm, count(*) AS n_rows,
  count(DISTINCT user_id) AS n_users,
  count(*) FILTER (WHERE lvl='bachelor') AS n_bachelor,
  count(*) FILTER (WHERE lvl='master')   AS n_master,
  count(*) FILTER (WHERE lvl='phd')      AS n_phd,
  count(*) FILTER (WHERE lvl='other')    AS n_other,
  count(*) FILTER (WHERE dr='')          AS n_sem_texto
  FROM a GROUP BY 1 ORDER BY 1")
cat("\n=== braco vencedor ===\n"); print(arms, row.names = FALSE)

got <- setNames(arms$n_rows, arms$arm)
for (k in names(exp_arm)) {
  if (!identical(as.integer(got[[k]]), exp_arm[[k]])) {
    stop(sprintf("braco %s tem %s linhas, esperado %d. O 8q mudou por baixo.",
                 k, format(got[[k]]), exp_arm[[k]]))
  }
}

####################################################################
### B -- os estratos
####################################################################

# Cada estrato e um predicado sobre (lvl, arm). Um so, disjunto.
stratum_sql <- "CASE
  WHEN lvl='bachelor' AND arm='A6_bachelor' THEN 'P1 bachelor A6 regex ranqueada'
  WHEN lvl='bachelor' AND arm='A7_else'     THEN 'P2 bachelor A7+dur (sem texto)'
  WHEN lvl='master'   AND arm='A3_master'   THEN 'P3 master A3'
  WHEN lvl='phd'      AND arm='A2_phd'      THEN 'P4 phd A2'
  WHEN lvl='other'    AND arm='A7_else'           THEN 'N1 other A7 ELSE terminal'
  WHEN lvl='other'    AND arm='A0_rx_hs'          THEN 'N2 other A0 rx_hs'
  WHEN lvl='other'    AND arm='A5_rx_post16'      THEN 'N3 other A5 rx_post16'
  WHEN lvl='other'    AND arm='A1_rx_notdeg'      THEN 'N4 other A1 rx_notdeg'
  WHEN lvl='other'    AND arm='A4_rx_notdeg_weak' THEN 'N5 other A4 rx_notdeg_weak'
  ELSE '' END"
dbExecute(con, sprintf("CREATE VIEW s AS SELECT *, (%s) AS estrato FROM a",
                       stratum_sql))

fora <- dbGetQuery(con, "SELECT count(*) n FROM s WHERE estrato=''")$n
if (fora != 0L) {
  print(dbGetQuery(con, "SELECT lvl, arm, count(*) n FROM s WHERE estrato=''
    GROUP BY 1,2 ORDER BY 3 DESC"))
  stop(fora, " linha(s) fora de todo estrato; os estratos deveriam cobrir tudo.")
}

pops <- dbGetQuery(con, "SELECT estrato, count(*) AS populacao,
  count(DISTINCT user_id) AS usuarios, count(*) FILTER (WHERE dr='') AS sem_texto
  FROM s GROUP BY 1 ORDER BY 1")
alloc <- c(strata_pos, strata_neg)
pops$sorteadas <- as.integer(alloc[pops$estrato])
stopifnot(!anyNA(pops$sorteadas))
pops$peso <- round(pops$populacao / pops$sorteadas)
pops$lado <- ifelse(startsWith(pops$estrato, "P"), "positivo", "negativo")
cat("\n=== estratos, populacao e peso (nota 2) ===\n")
print(pops, row.names = FALSE)
stopifnot(sum(pops$sorteadas[pops$lado == "positivo"]) == 100L,
          sum(pops$sorteadas[pops$lado == "negativo"]) == 100L,
          all(pops$populacao >= pops$sorteadas))

####################################################################
### C -- o sorteio (nota 4)
####################################################################

draw_sql <- paste(sprintf(
  "(SELECT '%s' AS estrato, source_file, source_row,
     hash(source_file || chr(31) || CAST(source_row AS VARCHAR) || chr(31) || '%d') AS hk
    FROM s WHERE estrato='%s' ORDER BY hk, source_file, source_row LIMIT %d)",
  names(alloc), seed, names(alloc), as.integer(alloc)), collapse = " UNION ALL ")

if (file.exists(sample_path)) {
  cat("\n[skip] sorteio ja estacionado:", basename(sample_path), "\n")
} else {
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    draw_sql, fw(sample_path))))
  cat("\nsorteadas 100 positivas e 100 negativas com seed", seed, "\n")
}

keys <- dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s')",
                                fw(sample_path)))
k2 <- dbGetQuery(con, draw_sql)
id_of <- function(d) paste(d$source_file, d$source_row, sep = "\u001f")
if (!setequal(id_of(keys), id_of(k2))) {
  stop("O mesmo seed devolveu sorteio DIFERENTE do estacionado. ",
       "O 8q mudou por baixo do sorteio.")
}
stopifnot(nrow(keys) == 200L, !anyDuplicated(id_of(keys)))
tab <- table(keys$estrato)
stopifnot(identical(as.integer(tab[names(alloc)]), as.integer(alloc)))
if (anyDuplicated(keys$hk) > 0L) {
  warning("hk com colisao: o LIMIT pode ter desempatado arbitrariamente.",
          call. = FALSE)
}

####################################################################
### D -- a evidencia de cada linha sorteada
####################################################################

dbWriteTable(con, "k", keys[, c("estrato", "source_file", "source_row")],
             overwrite = TRUE)

# clean_disp: o texto livre traz quebra de linha, tabulacao e U+FFFC (o
# "adicionar uma foto"). Isso e ruido de exibicao e faz o Excel
# normalizar na leitura. Limpar aqui deixa o caderno legivel e a
# assercao de round trip exata. Nao altera nenhuma chave.
dbExecute(con, "CREATE MACRO clean_disp(s) AS
  trim(regexp_replace(
    replace(replace(replace(replace(coalesce(s,''), chr(65532), ''),
      chr(13), ' '), chr(10), ' '), chr(9), ' '), ' +', ' ', 'g'))")

dat <- dbGetQuery(con, "
SELECT k.estrato,
       CAST(v.user_id AS VARCHAR)        AS user_id,
       v.source_file, v.source_row,
       clean_disp(v.degree_raw)          AS degree_raw,
       coalesce(v.degree,'')             AS degree,
       clean_disp(v.field_raw)           AS field_raw,
       coalesce(v.field,'')              AS field,
       clean_disp(v.description)         AS description,
       CAST(v.startdate AS VARCHAR)      AS startdate,
       CAST(v.enddate AS VARCHAR)        AS enddate,
       v.anos,
       clean_disp(v.university_raw)      AS university_raw,
       coalesce(v.university_country,'') AS university_country,
       v.lvl, v.arm, v.sub_arm,
       v.degree_match_route, v.degree_duration_years, v.degree_matches_laxed
FROM s v JOIN k ON v.source_file=k.source_file AND v.source_row=k.source_row
ORDER BY k.estrato, v.source_file, v.source_row")

stopifnot(nrow(dat) == 200L, all(grepl("^[0-9]+$", dat$user_id)))
for (cl in names(dat)) if (is.character(dat[[cl]])) {
  dat[[cl]] <- ifelse(is.na(dat[[cl]]), "", dat[[cl]])
}
dat$nivel_correto <- ""
dat$motivo        <- ""

col_order <- c("estrato", "degree_raw", "degree", "field_raw", "field",
               "description", "startdate", "enddate", "anos",
               "university_raw", "university_country",
               "lvl", "arm", "sub_arm", "degree_match_route",
               "degree_duration_years", "degree_matches_laxed",
               "user_id", "source_file", "source_row",
               "nivel_correto", "motivo")
dat <- dat[, col_order]
n_col <- ncol(dat)
stopifnot(n_col == 22L)

pos <- dat[startsWith(dat$estrato, "P"), ]
neg <- dat[startsWith(dat$estrato, "N"), ]
stopifnot(nrow(pos) == 100L, nrow(neg) == 100L,
          all(pos$lvl %in% c("bachelor", "master", "phd")),
          all(neg$lvl == "other"))

####################################################################
### E -- resgatar anotacao de um caderno anterior (nota 7)
####################################################################

resgatados <- 0L
if (file.exists(xlsx_path)) {
  op <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra_positivos")
  on_ <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra_negativos")
  need <- c("source_file", "source_row", "nivel_correto", "motivo")
  if (!all(need %in% names(op)) || !all(need %in% names(on_))) {
    stop("O caderno existente nao tem as colunas de chave e anotacao. ",
         "Nao vou regravar por cima.")
  }
  old <- rbind(op[, need], on_[, need])
  ko <- paste(old$source_file, old$source_row, sep = "\u001f")
  fill <- function(d) {
    i <- match(paste(d$source_file, d$source_row, sep = "\u001f"), ko)
    if (anyNA(i)) {
      stop(sum(is.na(i)), " linha(s) do caderno anterior nao casaram por ",
           "chave fisica; a anotacao seria perdida em silencio.")
    }
    d$nivel_correto <- ifelse(is.na(old$nivel_correto[i]), "",
                              old$nivel_correto[i])
    d$motivo <- ifelse(is.na(old$motivo[i]), "", old$motivo[i])
    d
  }
  pos <- fill(pos); neg <- fill(neg)
  resgatados <- sum(trimws(c(pos$nivel_correto, neg$nivel_correto)) != "")
  cat("caderno anterior lido:", resgatados, "nivel(is) preservado(s)\n")
  invisible(file.remove(xlsx_path))
}

####################################################################
### F -- o caderno
####################################################################

mil <- function(x) formatC(as.numeric(x), format = "d", big.mark = ".",
                           decimal.mark = ",")
pr <- function(e) pops$populacao[pops$estrato == e]

leia <- data.frame(c(
  "AUDITORIA DA CLASSIFICACAO DE DIPLOMA -- coorte degree_duration",
  "",
  "O QUE VOCE ESTA JULGANDO",
  "  Para cada linha, qual e o NIVEL VERDADEIRO do registro de",
  "  educacao: bachelor, master, phd ou other. Voce preenche a coluna",
  "  nivel_correto (fundo amarelo). A coluna lvl diz o que o pipeline",
  "  decidiu -- e o palpite sob teste, nao o gabarito.",
  "",
  "  Julgue principalmente por degree_raw, que e o texto que a pessoa",
  "  digitou e o unico insumo da cascata. field, description, as datas",
  "  e a instituicao estao ali como contexto.",
  "",
  "POR QUE ESTE CADERNO EXISTE",
  "  A unica auditoria de nivel que a pasta tem (shanghai_flag_audit.R)",
  "  reporta 99,2% de acuracia, mas o gabarito dela foi escrito por um",
  "  LLM -- o mesmo agente que escreveu os padroes sob teste. O README",
  "  chama isso de 'auto-avaliacao com conflito de interesse'. Este",
  "  caderno e a verificacao humana disso.",
  "",
  "AS DUAS ABAS SAO ESTRATIFICADAS -- NAO LEIA UMA TAXA UNICA",
  "  Cada estrato foi sorteado com um peso diferente, de proposito,",
  "  para que os bracos raros e arriscados da cascata tenham cobertura.",
  "  Para qualquer taxa, PONDERE pela coluna peso da aba Resumo. Uma",
  "  contagem crua destas 200 linhas esta errada por construcao.",
  sprintf("  Seed %d. Sorteio hash-ordenado, sem USING SAMPLE.", seed),
  "",
  "A COLUNA arm -- QUAL REGRA DECIDIU",
  "  A cascata e ORDENADA e para no primeiro teste que da verdadeiro.",
  "  arm diz qual foi. Isto e o que permite medir precisao POR REGRA.",
  "",
  sprintf("  A0 rx_hs            -> other   %s linhas  ensino medio, tecnico", mil(pr("N2 other A0 rx_hs"))),
  sprintf("  A1 rx_notdeg        -> other   %s linhas  pos-doc, sanduiche,", mil(pr("N4 other A1 rx_notdeg"))),
  "                                          intercambio, visiting, minor",
  sprintf("  A2 phd              -> phd     %s linhas  degree='Doctor' ou rx_phd", mil(pr("P4 phd A2"))),
  sprintf("  A3 master           -> master  %s linhas  degree Master/MBA, ou", mil(pr("P3 master A3"))),
  "                                          rx_msc sem lato sensu",
  sprintf("  A4 rx_notdeg_weak   -> other   %s linhas  'extensao'", mil(pr("N5 other A4 rx_notdeg_weak"))),
  sprintf("  A5 rx_post16        -> other   %s linhas  'pos-graduacao'", mil(pr("N3 other A5 rx_post16"))),
  sprintf("  A6 bachelor         -> bach    %s linhas  criterio E (sub_arm diz", mil(pr("P1 bachelor A6 regex ranqueada"))),
  "                                          se foi o rotulo, rx_b1, rx_b2",
  "                                          ou rx_bach16)",
  sprintf("  A7 ELSE terminal    -> other   %s linhas  nao classificado", mil(pr("N1 other A7 ELSE terminal"))),
  sprintf("  A7 + duracao        -> bach    %s linhas  resgatado pela duracao", mil(pr("P2 bachelor A7+dur (sem texto)"))),
  "",
  "O RESGATE POR DURACAO TEM QUATRO CONDICOES, NAO DUAS",
  "  Nao e apenas 'degree vazio + 3 a 6 anos'. A regra completa e:",
  "",
  "     coalesce(degree,'empty') = 'empty'",
  "     E o ranked_level ja era 'other'",
  "     E o texto NAO casa rx_explicit_non_bachelor, que e a uniao de",
  "       rx_notdeg, rx_notdeg_weak, rx_post, rx_post16, rx_tech,",
  "       rx_hs, 'post-grad' e 'tecnic'",
  "     E startdate e enddate existem",
  "     E end_year - start_year esta em (3,4,5,6)",
  "",
  "  A terceira condicao e a razao de o resgate so alcancar o ELSE",
  "  terminal e NUNCA os bracos A0, A1, A4 ou A5. Se voce procurar uma",
  "  linha de Ensino Medio ou de Pos-graduacao resgatada por duracao,",
  "  nao vai achar -- e isso e o desenho funcionando, nao um defeito.",
  "",
  "  O estrato P2 e o de maior risco do caderno: sao bachelors sem",
  "  NENHUM texto em degree_raw, inferidos so pelo intervalo de anos.",
  sprintf("  Na base inteira sao 805.902 linhas assim (22,7%% dos bachelors)."),
  "  Julgue-os pela instituicao, pelo campo e pela duracao. Se nao der",
  "  para decidir, 'indeterminado' e a resposta honesta.",
  "",
  "NIVEL_CORRETO",
  "  bachelor / master / phd / other   o nivel verdadeiro do registro",
  "  indeterminado                     a evidencia nao permite decidir",
  "",
  "  MBA conta como master (decisao da pasta, reversivel via rx_mba).",
  "  Pos-graduacao lato sensu / especializacao NAO e master: e other.",
  "  Tecnologo, CST e curso tecnico sao other. Matricula em curso",
  "  ainda nao concluido conta pelo nivel do curso, nao como other.",
  "",
  "Nada deste caderno volta para o pipeline automaticamente."),
  stringsAsFactors = FALSE)
names(leia) <- "Como ler este caderno"

wb <- createWorkbook()
hdr <- createStyle(textDecoration = "bold", fgFill = "#E8E8E8",
                   border = "bottom", valign = "top", wrapText = TRUE)
wrap  <- createStyle(wrap = TRUE, valign = "top")
txt   <- createStyle(numFmt = "TEXT", valign = "top")
evid  <- createStyle(fgFill = "#F3EFF7", valign = "top")
pipe  <- createStyle(fgFill = "#EEF4FB", valign = "top")
yours <- createStyle(fgFill = "#FFF7D6", border = "TopBottomLeftRight",
                     borderColour = "#C9A227", valign = "top")

addWorksheet(wb, "Como ler")
writeData(wb, "Como ler", leia)
addStyle(wb, "Como ler", hdr, rows = 1, cols = 1)
setColWidths(wb, "Como ler", cols = 1, widths = 82)

add_sheet <- function(nm, d, risky_rule) {
  addWorksheet(wb, nm)
  writeData(wb, nm, d, withFilter = TRUE)
  freezePane(wb, nm, firstActiveRow = 2, firstActiveCol = 3)
  addStyle(wb, nm, hdr, rows = 1, cols = 1:n_col, gridExpand = TRUE)
  rr <- 2:(nrow(d) + 1)
  addStyle(wb, nm, evid, rows = rr, cols = 2:11, gridExpand = TRUE)
  addStyle(wb, nm, pipe, rows = rr, cols = 12:17, gridExpand = TRUE)
  addStyle(wb, nm, txt,  rows = rr, cols = 18, gridExpand = TRUE)
  addStyle(wb, nm, yours, rows = rr, cols = 21:22, gridExpand = TRUE)
  addStyle(wb, nm, wrap, rows = rr, cols = c(1, 2, 5, 6, 10, 22),
           gridExpand = TRUE, stack = TRUE)
  setColWidths(wb, nm, cols = 1:n_col,
               widths = c(30, 42, 12, 26, 22, 46, 12, 12, 6, 34, 14,
                          10, 18, 20, 18, 8, 8, 18, 30, 10, 16, 40))
  conditionalFormatting(wb, nm, cols = 1:n_col, rows = rr,
    rule = risky_rule, type = "expression",
    style = createStyle(bgFill = "#FBE6E6"))
  dataValidation(wb, nm, col = 21, rows = rr, type = "list",
    value = sprintf("'dominio'!$A$2:$A$%d", length(level_domain) + 1L))
}

addWorksheet(wb, "dominio")
writeData(wb, "dominio", data.frame(nivel_correto = level_domain))

add_sheet("Amostra_positivos", pos, 'LEFT($A2,2)="P2"')   # o estrato sem texto
add_sheet("Amostra_negativos", neg, 'LEFT($A2,2)="N1"')   # o ELSE terminal
sheetVisibility(wb)[which(names(wb) == "dominio")] <- "hidden"

addWorksheet(wb, "Resumo")
writeData(wb, "Resumo",
          "Estratos, populacao e PESO -- pondere por aqui (nota 2)",
          startRow = 1)
writeData(wb, "Resumo", pops[, c("lado", "estrato", "populacao", "usuarios",
                                 "sem_texto", "sorteadas", "peso")],
          startRow = 2)
r2 <- nrow(pops) + 5
writeData(wb, "Resumo", "Braco vencedor na base inteira", startRow = r2)
writeData(wb, "Resumo", arms, startRow = r2 + 1)
r3 <- r2 + nrow(arms) + 4
writeData(wb, "Resumo", data.frame(
  medida = c("linhas de educacao", "reconciliacao braco vs ranked_level",
             "positivos sorteados", "negativos sorteados", "seed"),
  valor = c(exp_total, recon$discrepancias, 100L, 100L, seed)),
  startRow = r3)
addStyle(wb, "Resumo", hdr, rows = c(2, r2 + 1, r3), cols = 1:8,
         gridExpand = TRUE)
setColWidths(wb, "Resumo", cols = 1:8,
             widths = c(12, 32, 12, 12, 11, 11, 11, 11))

saveWorkbook(wb, xlsx_path, overwrite = FALSE)

####################################################################
### Validacao (nota 5 e nota 6)
####################################################################

cp <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra_positivos")
cn <- openxlsx::read.xlsx(xlsx_path, sheet = "Amostra_negativos")
if (nrow(cp) != 100L || nrow(cn) != 100L ||
    ncol(cp) != n_col || ncol(cn) != n_col) {
  stop(sprintf("releitura com %dx%d e %dx%d, esperado 100x%d cada",
               nrow(cp), ncol(cp), nrow(cn), ncol(cn), n_col))
}

# Nota 6: CRLF e entidade XML sao representacao, nao perda. Normalizar
# nos DOIS lados para que mangling de verdade continue falhando.
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
rt(cp$degree_raw, pos$degree_raw, "positivos/degree_raw")
rt(cn$degree_raw, neg$degree_raw, "negativos/degree_raw")
rt(cp$university_raw, pos$university_raw, "positivos/university_raw")
rt(cn$description, neg$description, "negativos/description")

# Nota 5: os inteiros grandes sobreviveram legiveis?
if (!all(grepl("^[0-9]+$", as.character(cp$user_id))) ||
    !all(grepl("^[0-9]+$", as.character(cn$user_id)))) {
  stop("O xlsx gravou user_id em notacao cientifica (nota 5).")
}
if (!all(cp$lvl %in% c("bachelor", "master", "phd")) ||
    !all(cn$lvl == "other")) {
  stop("aba com nivel fora do lado que lhe corresponde.")
}
if (anyDuplicated(paste(c(cp$source_file, cn$source_file),
                        c(cp$source_row, cn$source_row))) > 0L) {
  stop("chave fisica repetida entre as abas.")
}
gp <- table(cp$estrato); gn <- table(cn$estrato)
stopifnot(identical(as.integer(gp[names(strata_pos)]), as.integer(strata_pos)),
          identical(as.integer(gn[names(strata_neg)]), as.integer(strata_neg)))

# Nota 7: o 8q e o arquivo de padroes continuam byte a byte iguais.
if (!identical(protected_before, unname(tools::md5sum(protected_paths)))) {
  stop("ENTRADA ALTERADA (8q ou br_degree_patterns.R). Nunca deveria ocorrer.")
}

####################################################################
### Relatorio
####################################################################

write_json(list(
  completed_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
  purpose = paste("Human audit of the degree-level classifier",
                  "(br_degree_patterns.R cascade + duration fallback)",
                  "on the degree_duration cohort"),
  caveat = paste("Both sheets are stratified: weight by the per-stratum",
                 "population before quoting any rate. The existing 99.2%",
                 "figure from shanghai_flag_audit.R is an LLM self-assessment;",
                 "this workbook is the human check on it."),
  duration_rule = paste("degree empty AND ranked_level='other' AND NOT",
                        "rx_explicit_non_bachelor AND dates present AND",
                        "end_year-start_year IN (3,4,5,6); reaches only the",
                        "terminal ELSE arm"),
  seed = seed, total_rows = exp_total,
  arm_reconciliation = list(discrepancies = recon$discrepancias, passed = TRUE),
  arms = arms, strata = pops,
  inputs = data.frame(path = protected_paths, md5 = protected_before),
  outputs = data.frame(path = c(sample_path, xlsx_path),
                       md5 = unname(tools::md5sum(c(sample_path, xlsx_path)))),
  reviewed = FALSE,
  note = "Accuracy is not recorded here; fill in nivel_correto first."),
  report_path, pretty = TRUE, auto_unbox = TRUE, dataframe = "rows",
  digits = 16, na = "null")

cat("\n==================================================================\n")
cat("Auditoria da classificacao de diploma -- 100 positivos, 100 negativos\n")
cat("==================================================================\n\n")
print(pops[, c("lado", "estrato", "populacao", "sem_texto", "sorteadas", "peso")],
      row.names = FALSE)
cat(sprintf("\n  reconciliacao braco vs ranked_level : %d discrepancia(s)\n",
            recon$discrepancias))
cat(sprintf("  linhas                              : %d\n", exp_total))
cat(sprintf("  colunas por aba                     : %d\n", n_col))
cat(sprintf("  seed                                : %d\n", seed))
if (resgatados > 0L) cat(sprintf("  resgatados                          : %d\n", resgatados))
cat(sprintf("\n  %s\n  %s\n  %s\n\n", sample_path, xlsx_path, report_path))
cat("Pondere pela coluna peso do Resumo. Nao existe 'a taxa' deste caderno.\n")
cat("O estrato P2 (bachelor sem texto) e o de maior risco -- comece por ele.\n\n")
