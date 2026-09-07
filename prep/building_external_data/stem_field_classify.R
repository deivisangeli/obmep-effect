####################################################################
###
### Classificacao de campo STEM so por regex     -> revelio_br_cohort
###
### Alternativa que NAO usa job_category nem as regras aprendidas da
### 10j. So expressoes regulares escritas a mao, aplicadas a
### title_raw E a description, em ingles, portugues e espanhol.
###
### Quatro campos, na ordem de precedencia da stem_field_patterns.R:
###   applied_math -> mathematics -> other_stem -> engineering
###
### OFFLINE. Somente-leitura em relacao ao pipeline. Nao mande para o
### SEDAP.
###
### Depende de:
###   stem_field_patterns.R                                  (padroes)
###   revelio_br_cohort/obmep_candidates_selected_positions.parquet (21a)
###   revelio_br_cohort/obmep_candidates_step_1_position/           (10a)
###   revelio_br_cohort/field_manual_class.csv                      (10h)
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. OFFLINE, sem rede, fora do SEDAP.
### 2. OS PADROES NAO FORAM AJUSTADOS NUMERICAMENTE AO PADRAO-OURO.
###    Foram escritos a partir de conhecimento de dominio e das
###    armadilhas QUALITATIVAS que as auditorias mostraram (business
###    developer, programador de producao, educacao fisica, ciencias
###    contabeis). Isso e vazamento LEVE: a avaliacao do Step 4 nao e
###    totalmente independente, ainda que nenhum numero do
###    padrao-ouro tenha entrado no ajuste. Se os padroes forem
###    iterados contra o Step 4, as taxas viram otimistas e isso tem
###    de ser dito junto.
### 3. n PEQUENO NAS DUAS CATEGORIAS DE MATEMATICA. No padrao-ouro sao
###    8 math_academic e 17 math_applied em 1.000. Precisao e recall
###    dessas duas sao direcao, nao medida.
### 4. TITULO E DESCRICAO SAO SEPARADOS DE PROPOSITO. field_title usa
###    so o titulo; field_any cai para a descricao quando o titulo nao
###    decide. A descricao amplia cobertura e traz falso positivo --
###    as duas colunas saem para o consumidor escolher.
### 5. A PRECEDENCIA E EXCLUDENTE: cada posicao recebe UM campo. Um
###    'machine learning engineer' e applied_math, nao engineering,
###    porque applied vem antes. Se o consumidor quiser
###    engenharia+matematica aplicada junta, e uma uniao das duas.
### 6. position_id E user_id SAO bigint. Tudo dentro do DuckDB.
###
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(duckdb)

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
gtl_root <- Sys.getenv("OBMEP_REPO", unset = "C:/Users/megaj/repos/obmep_effect")
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

pat_file  <- file.path(gtl_root, "prep/building_external_data/stem_field_patterns.R")
sel_path  <- file.path(coh_dir, "obmep_candidates_selected_positions.parquet")
pos_dir   <- file.path(coh_dir, "obmep_candidates_step_1_position")
gold_path <- file.path(coh_dir, "field_manual_class.csv")

out_pos  <- file.path(coh_dir, "stem_field_regex_positions.parquet")
out_user <- file.path(coh_dir, "stem_field_regex_users.parquet")

exp_positions <- 7285037
exp_users     <- 1297109

if (!file.exists(pat_file)) stop("Nao encontrei ", pat_file)
source(pat_file)   # constantes apenas, sem efeito colateral

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")
tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_stem_regex")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit)))
invisible(dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir)))
invisible(dbExecute(con, "SET preserve_insertion_order=false"))
fw <- function(p) gsub("\\\\", "/", p)
sq <- function(x) paste0("'", x, "'")

t0 <- Sys.time()
cat("=========== CLASSIFICACAO POR REGEX ===========\n")

####################################################################
### Step 1: a expressao CASE, montada da ordem de precedencia
####################################################################

# Nota 2 da stem_field_patterns.R: os padroes nao tem barra invertida
# nem aspas, entao entram direto em string SQL sem escapar nada.
case_for <- function(col) {
  br <- vapply(stem_field_order, function(f) {
    r <- stem_field_rx[[f]]
    sprintf("WHEN regexp_matches(%s, %s) AND NOT regexp_matches(%s, %s) THEN %s",
            col, sq(r$yes), col, sq(r$no), sq(f))
  }, character(1))
  paste0("CASE ", paste(br, collapse = " "), " ELSE 'none' END")
}

norm <- function(src) sprintf("trim(regexp_replace(
    regexp_replace(lower(strip_accents(nfc_normalize(coalesce(%s,'')))),
                   '[^a-z0-9+#]+', ' ', 'g'), ' +', ' ', 'g'))", src)

####################################################################
### Step 2: aplicar a toda a base
####################################################################

cat("\n--- Step 2: classificando ", format(exp_positions, big.mark=","),
    " posicoes ---\n", sep="")
invisible(dbExecute(con, sprintf("
CREATE OR REPLACE TABLE cls AS
WITH t AS (
  SELECT r.position_id, r.user_id, r.job_category,
         %s AS tt, %s AS dd
  FROM read_parquet(%s) r
  LEFT JOIN read_parquet(%s) p ON r.position_id = p.position_id
)
SELECT position_id, user_id, job_category,
       %s AS field_title,
       %s AS field_desc
FROM t",
  norm("p.title_raw"), norm("p.description"),
  sq(fw(sel_path)), sq(fw(paste0(pos_dir, "/*"))),
  case_for("tt"), case_for("dd"))))

invisible(dbExecute(con, "
ALTER TABLE cls ADD COLUMN field_any VARCHAR;
UPDATE cls SET field_any =
  CASE WHEN field_title <> 'none' THEN field_title ELSE field_desc END"))

chk <- dbGetQuery(con, "SELECT count(*) n, count(DISTINCT user_id) u FROM cls")
if (chk$n != exp_positions) stop("Esperava ", exp_positions, " posicoes, veio ", chk$n)
if (chk$u != exp_users) stop("Esperava ", exp_users, " usuarios, veio ", chk$u)
cat(sprintf("  [OK] %s posicoes, %s usuarios\n",
            format(chk$n, big.mark=","), format(chk$u, big.mark=",")))

cat("\n  distribuicao (nota 4):\n")
d <- dbGetQuery(con, "
  SELECT field_title AS campo,
         count(*) FILTER (WHERE 1=1) AS por_titulo
  FROM cls GROUP BY 1")
d2 <- dbGetQuery(con, "SELECT field_any AS campo, count(*) AS por_titulo_ou_desc
                       FROM cls GROUP BY 1")
m <- merge(d, d2, by="campo", all=TRUE)
m$pct_titulo <- round(100*m$por_titulo/chk$n, 2)
m$pct_any    <- round(100*m$por_titulo_ou_desc/chk$n, 2)
print(m[order(-m$por_titulo), ], row.names = FALSE)

####################################################################
### Step 3: gravar posicao e usuario
####################################################################

cat("\n--- Step 3: gravando ---\n")
invisible(dbExecute(con, sprintf("
COPY (SELECT * FROM cls ORDER BY user_id, position_id)
TO %s (FORMAT PARQUET, COMPRESSION ZSTD)", sq(fw(out_pos)))))
invisible(dbExecute(con, sprintf("
COPY (
  SELECT user_id, count(*) AS n_positions,
    max(CASE WHEN field_any='engineering'  THEN 1 ELSE 0 END) AS eng_rx,
    max(CASE WHEN field_any='mathematics'  THEN 1 ELSE 0 END) AS math_rx,
    max(CASE WHEN field_any='applied_math' THEN 1 ELSE 0 END) AS applmath_rx,
    max(CASE WHEN field_any='other_stem'   THEN 1 ELSE 0 END) AS othstem_rx,
    max(CASE WHEN field_title='engineering' THEN 1 ELSE 0 END) AS eng_rx_title,
    max(CASE WHEN field_title='mathematics' THEN 1 ELSE 0 END) AS math_rx_title,
    max(CASE WHEN field_title='applied_math' THEN 1 ELSE 0 END) AS applmath_rx_title,
    max(CASE WHEN field_title='other_stem'   THEN 1 ELSE 0 END) AS othstem_rx_title
  FROM cls GROUP BY 1 ORDER BY 1
) TO %s (FORMAT PARQUET, COMPRESSION ZSTD)", sq(fw(out_user)))))
u <- dbGetQuery(con, sprintf("
  SELECT count(*) n, sum(eng_rx) e, sum(math_rx) m, sum(applmath_rx) a,
         sum(othstem_rx) s FROM read_parquet(%s)", sq(fw(out_user))))
cat(sprintf("  usuarios %s | engineering %s | mathematics %s | applied %s | other_stem %s\n",
    format(u$n,big.mark=","), format(u$e,big.mark=","), format(u$m,big.mark=","),
    format(u$a,big.mark=","), format(u$s,big.mark=",")))

####################################################################
### Step 4: contra o padrao-ouro de 1.000 linhas  (notas 2 e 3)
####################################################################

cat("\n--- Step 4: precisao e recall contra as 1.000 linhas a mao ---\n")
gold <- read.csv(gold_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
                 colClasses = "character")
dbWriteTable(con, "gold", gold[, c("position_id", "verdict")], overwrite = TRUE)
g <- dbGetQuery(con, "
  SELECT g.verdict, c.field_title, c.field_desc, c.field_any
  FROM gold g JOIN cls c ON CAST(c.position_id AS VARCHAR) = g.position_id")
map <- c(applied_math = "math_applied", mathematics = "math_academic",
         other_stem = "science", engineering = "engineering")
ci <- function(k, n) if (n == 0) "      n/a      " else {
  r <- binom.test(k, n)$conf.int; sprintf("[%4.1f,%4.1f]", 100*r[1], 100*r[2]) }
cat("  campo         n_ouro   |  so TITULO            |  TITULO + DESCRICAO\n")
for (f in stem_field_order) {
  truth <- g$verdict == map[[f]]
  for (nm in c("field_title", "field_any")) {
    pred <- g[[nm]] == f
    tp <- sum(pred & truth)
    p <- if (sum(pred)) tp/sum(pred) else NA
    r <- if (sum(truth)) tp/sum(truth) else NA
    if (nm == "field_title") {
      line <- sprintf("  %-13s %4d     |  P %5.1f%% R %5.1f%% n=%3d",
                      f, sum(truth), 100*p, 100*r, sum(pred))
    } else {
      cat(sprintf("%s  |  P %5.1f%% R %5.1f%% n=%3d %s\n", line,
                  100*p, 100*r, sum(pred), ci(tp, max(sum(pred),1))))
    }
  }
}
cat("\n  [!] mathematics n=8 e applied_math n=17 no ouro: direcao, nao medida (nota 3)\n")

cat("\n  -- comparacao com as alternativas ja existentes --\n")
# UMA consulta so: verdict e job_category tem de vir na MESMA linha.
# Duas consultas sem ORDER BY voltam em ordens diferentes e a
# comparacao vira lixo. Foi o que aconteceu na primeira versao: ela
# reportou 13.5% e depois 17.2% para o mesmo job_category, medido em
# 67.4% -- o numero MUDAR entre rodadas foi o que denunciou o bug.
g2 <- dbGetQuery(con, "
  SELECT g.verdict, c.field_title, c.field_any, c.job_category
  FROM gold g JOIN cls c ON CAST(c.position_id AS VARCHAR) = g.position_id")
stopifnot(nrow(g2) == nrow(g))
pr2 <- function(pred, truth, lbl) {
  tp <- sum(pred & truth)
  cat(sprintf("    %-34s P %5.1f%%  R %5.1f%%  n=%d\n", lbl,
      100*tp/max(sum(pred),1), 100*tp/max(sum(truth),1), sum(pred)))
}
te <- g2$verdict == "engineering"; ts <- g2$verdict == "science"
cat("  [engineering]\n")
pr2(g2$field_title == "engineering", te, "regex, so titulo")
pr2(g2$field_any == "engineering", te, "regex, titulo + descricao")
pr2(g2$job_category == "Engineer", te, "job_category = Engineer")
cat("  [other_stem]\n")
pr2(g2$field_title == "other_stem", ts, "regex, so titulo")
pr2(g2$field_any == "other_stem", ts, "regex, titulo + descricao")
pr2(g2$job_category == "Scientist", ts, "job_category = Scientist")

cat("\n=========== FIM ===========\n")
cat(sprintf("  %.1f min\n", as.numeric(difftime(Sys.time(), t0, units="mins"))))
cat("  ", out_pos, "\n  ", out_user, "\n", sep="")
