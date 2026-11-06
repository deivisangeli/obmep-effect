####################################################################
###
### Flags de campo por posicao e por usuario          -> revelio_br_cohort
###
### Duas definicoes concorrentes, lado a lado, para Finance e para
### Engineering:
###
###   _rule  a posicao casa alguma REGRA DE TITULO com precisao de
###          validacao >= 0.90 (descobertas pela 10j)
###   _jc    a posicao tem job_category = 'Finance' / 'Engineer'
###
### No nivel do usuario cada dummy e 1 se QUALQUER posicao daquela
### pessoa foi marcada.
###
### OFFLINE. Somente-leitura em relacao ao pipeline. Nao mande para o
### SEDAP.
###
### Depende de:
###   revelio_br_cohort/obmep_candidates_selected_positions.parquet (21a)
###   revelio_br_cohort/obmep_candidates_step_1_position/           (10a)
###   revelio_br_cohort/title_rules/candidate_rules.parquet         (10j)
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. OFFLINE, sem rede, fora do SEDAP.
### 2. AS DUAS DEFINICOES NAO SAO A MESMA COISA, e essa e a graca de
###    ter as duas. Medido contra a classificacao manual de campo das
###    1.000 linhas (10h):
###      job_category='Finance'  -> campo finance      61.0% precisao
###      job_category='Engineer' -> campo engineering  67.4% precisao
###      regras >=90% (Finance)  -> campo finance      92.6% precisao
###      regras >=90% (Engineer) -> campo engineering  88.9% precisao
###    As regras sao MAIS PRECISAS e MENOS abrangentes. _jc pega mais
###    gente e erra mais; _rule pega menos e erra menos. Qual usar
###    depende do que a estimativa a jusante tolera.
### 3. AS REGRAS FORAM DESCOBERTAS NA AMOSTRA DE DESCOBERTA e sao
###    aplicadas aqui na base INTEIRA, descoberta inclusive. Nos
###    titulos da descoberta a precisao e otimista por construcao. A
###    precisao honesta e a de VALIDACAO, que e o filtro usado
###    (v_precision >= 0.90 com v_support >= 50).
### 4. O CASAMENTO E POR TOKEN INTEIRO, nao por substring solta:
###    ' ' || titulo || ' ' LIKE '% expressao %'. Sem isso 'contador'
###    casaria dentro de outra palavra.
### 5. position_id E user_id SAO bigint. Tudo fica dentro do DuckDB e
###    nada e materializado em R como double. Ver nota 8 da
###    role_title_audit.R -- isso ja corrompeu 499 de 500 ids.
### 6. TITULO VAZIO NAO E FLAG. Posicao sem title_raw (9.080) nunca
###    casa regra nenhuma, entao entra com _rule = 0. Isso NAO
###    significa que a pessoa nao trabalha na area; significa que o
###    titulo nao diz. O _jc dessas linhas continua valendo.
### 7. UM USUARIO PODE TER OS DOIS DUMMIES = 1. Carreira muda de area,
###    e a regra e "qualquer posicao". Nao sao mutuamente exclusivos.
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

####################################################################
### Parametros
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

sel_path  <- file.path(coh_dir, "obmep_candidates_selected_positions.parquet")
pos_dir   <- file.path(coh_dir, "obmep_candidates_step_1_position")
rules_path <- file.path(coh_dir, "title_rules/candidate_rules.parquet")

out_pos  <- file.path(coh_dir, "position_field_flags.parquet")
out_user <- file.path(coh_dir, "user_field_flags.parquet")

min_prec    <- 0.90
min_v_sup   <- 50L
max_ngram   <- 4L
mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")

exp_positions <- 7285037
exp_users     <- 1297109

for (f in c(sel_path, rules_path)) if (!file.exists(f)) stop("Nao encontrei ", f)
if (!dir.exists(pos_dir)) stop("Nao encontrei ", pos_dir)

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_field_flags")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit)))
invisible(dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir)))
invisible(dbExecute(con, "SET preserve_insertion_order=false"))
fw <- function(p) gsub("\\\\", "/", p)
sel_src <- sprintf("read_parquet('%s')", fw(sel_path))
pos_src <- sprintf("read_parquet('%s/*')", fw(pos_dir))
rul_src <- sprintf("read_parquet('%s')", fw(rules_path))

t0 <- Sys.time()
cat("=========== FLAGS DE CAMPO ===========\n")

####################################################################
### Step 1: as regras que passam do limiar
####################################################################

invisible(dbExecute(con, sprintf("
CREATE OR REPLACE TABLE rules AS
SELECT target, expression_1 AS e1, expression_2 AS e2, rule_type,
       v_precision, v_support
FROM %s
WHERE v_precision >= %f AND v_support >= %d
  AND expression_1 IS NOT NULL", rul_src, min_prec, min_v_sup)))
rs <- dbGetQuery(con, "SELECT target, rule_type, count(*) n FROM rules
                       GROUP BY 1,2 ORDER BY 1,2")
cat("\n--- Step 1: regras com v_precision >= 0.90 e v_support >= 50 ---\n")
print(rs, row.names = FALSE)
if (nrow(rs) == 0) stop("Nenhuma regra passou do limiar.")

####################################################################
### Step 2: titulos unicos e seus n-gramas
####################################################################

# Nota 5: os ids ficam no DuckDB do inicio ao fim.
norm_expr <- "trim(regexp_replace(
    regexp_replace(lower(strip_accents(nfc_normalize(p.title_raw))),
                   '[^a-z0-9+#]+', ' ', 'g'),
    ' +', ' ', 'g'))"

cat("\n--- Step 2: normalizando e extraindo n-gramas ---\n")
invisible(dbExecute(con, sprintf("
CREATE OR REPLACE TABLE pos_norm AS
SELECT r.position_id, r.user_id, r.job_category,
       coalesce(%s, '') AS norm
FROM %s r
LEFT JOIN %s p ON r.position_id = p.position_id", norm_expr, sel_src, pos_src)))

chk <- dbGetQuery(con, "SELECT count(*) n, count(DISTINCT user_id) u,
                        sum(CASE WHEN norm='' THEN 1 ELSE 0 END) vazio FROM pos_norm")
cat(sprintf("  posicoes %s | usuarios %s | titulo vazio %s (nota 6)\n",
            format(chk$n, big.mark=","), format(chk$u, big.mark=","),
            format(chk$vazio, big.mark=",")))
if (chk$n != exp_positions) stop("Esperava ", exp_positions, " posicoes, veio ", chk$n)
if (chk$u != exp_users) stop("Esperava ", exp_users, " usuarios, veio ", chk$u)

# So os n-gramas que alguma regra usa -- filtrar cedo mantem isto pequeno.
invisible(dbExecute(con, "
CREATE OR REPLACE TABLE needed AS
SELECT DISTINCT e1 AS expr FROM rules
UNION SELECT DISTINCT e2 FROM rules WHERE e2 IS NOT NULL"))

invisible(dbExecute(con, sprintf("
CREATE OR REPLACE TABLE title_expr AS
WITH t AS (SELECT DISTINCT norm FROM pos_norm WHERE norm <> ''),
     w AS (SELECT norm, str_split(norm, ' ') AS ws FROM t),
     p AS (SELECT norm, ws, unnest(range(1, length(ws)+1)) AS i FROM w),
     g AS (SELECT DISTINCT norm,
                  array_to_string(ws[i : i + k - 1], ' ') AS expr
           FROM p, (SELECT unnest(range(1, %d)) AS k) ks
           WHERE i + k - 1 <= length(ws))
SELECT g.norm, g.expr FROM g JOIN needed n ON n.expr = g.expr",
  max_ngram + 1L)))
cat(sprintf("  pares titulo x expressao relevantes: %s\n",
    format(dbGetQuery(con,"SELECT count(*) n FROM title_expr")$n, big.mark=",")))

####################################################################
### Step 3: quais titulos casam alguma regra
####################################################################

# Nota 4: o casamento por n-grama JA e por token inteiro -- a
# expressao so existe na tabela se for uma sequencia de tokens do
# titulo. Regra AND exige as duas.
cat("\n--- Step 3: casando regras com titulos ---\n")
# Junta por igualdade, nao por EXISTS correlacionado dentro do ON --
# o DuckDB nao aceita aquela forma. Regra simples e um join; regra AND
# e um join duplo exigindo o MESMO titulo nos dois lados.
invisible(dbExecute(con, "
CREATE OR REPLACE TABLE title_flag AS
WITH singles AS (
  SELECT x.norm, r.target
  FROM rules r JOIN title_expr x ON x.expr = r.e1
  WHERE r.e2 IS NULL
), pairs AS (
  SELECT a.norm, r.target
  FROM rules r
  JOIN title_expr a ON a.expr = r.e1
  JOIN title_expr b ON b.expr = r.e2 AND b.norm = a.norm
  WHERE r.e2 IS NOT NULL
), u AS (SELECT * FROM singles UNION ALL SELECT * FROM pairs)
SELECT norm,
  max(CASE WHEN target='Finance'  THEN 1 ELSE 0 END) AS f_rule,
  max(CASE WHEN target='Engineer' THEN 1 ELSE 0 END) AS e_rule
FROM u GROUP BY 1"))

tf <- dbGetQuery(con, "SELECT count(*) n, sum(f_rule) f, sum(e_rule) e FROM title_flag")
cat(sprintf("  titulos distintos marcados: %s (Finance %s | Engineer %s)\n",
    format(tf$n,big.mark=","), format(tf$f,big.mark=","), format(tf$e,big.mark=",")))

####################################################################
### Step 4: nivel POSICAO -- as quatro dummies
####################################################################

cat("\n--- Step 4: flags por posicao ---\n")
invisible(dbExecute(con, sprintf("
COPY (
  SELECT p.position_id, p.user_id, p.job_category,
         coalesce(t.f_rule, 0) AS fin_rule,
         coalesce(t.e_rule, 0) AS eng_rule,
         CASE WHEN p.job_category='Finance'  THEN 1 ELSE 0 END AS fin_jc,
         CASE WHEN p.job_category='Engineer' THEN 1 ELSE 0 END AS eng_jc
  FROM pos_norm p LEFT JOIN title_flag t ON t.norm = p.norm
  ORDER BY p.user_id, p.position_id
) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_pos))))

ps <- dbGetQuery(con, sprintf("
  SELECT count(*) n, sum(fin_rule) fr, sum(eng_rule) er,
         sum(fin_jc) fj, sum(eng_jc) ej FROM read_parquet('%s')", fw(out_pos)))
cat(sprintf("  %s posicoes\n", format(ps$n, big.mark=",")))
cat(sprintf("    fin_rule %8s (%.2f%%)   fin_jc %8s (%.2f%%)\n",
    format(ps$fr,big.mark=","), 100*ps$fr/ps$n, format(ps$fj,big.mark=","), 100*ps$fj/ps$n))
cat(sprintf("    eng_rule %8s (%.2f%%)   eng_jc %8s (%.2f%%)\n",
    format(ps$er,big.mark=","), 100*ps$er/ps$n, format(ps$ej,big.mark=","), 100*ps$ej/ps$n))

####################################################################
### Step 5: nivel USUARIO -- qualquer posicao marcada  (nota 7)
####################################################################

cat("\n--- Step 5: flags por usuario ---\n")
invisible(dbExecute(con, sprintf("
COPY (
  SELECT user_id,
         count(*)               AS n_positions,
         max(fin_rule)          AS fin_rule,
         max(eng_rule)          AS eng_rule,
         max(fin_jc)            AS fin_jc,
         max(eng_jc)            AS eng_jc,
         sum(fin_rule)          AS n_pos_fin_rule,
         sum(eng_rule)          AS n_pos_eng_rule,
         sum(fin_jc)            AS n_pos_fin_jc,
         sum(eng_jc)            AS n_pos_eng_jc
  FROM read_parquet('%s')
  GROUP BY 1 ORDER BY 1
) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_pos), fw(out_user))))

us <- dbGetQuery(con, sprintf("
  SELECT count(*) n, sum(fin_rule) fr, sum(eng_rule) er,
         sum(fin_jc) fj, sum(eng_jc) ej,
         sum(CASE WHEN fin_rule=1 AND eng_rule=1 THEN 1 ELSE 0 END) both_rule,
         sum(CASE WHEN fin_jc=1 AND eng_jc=1 THEN 1 ELSE 0 END) both_jc
  FROM read_parquet('%s')", fw(out_user)))
if (us$n != exp_users) stop("Esperava ", exp_users, " usuarios, veio ", us$n)
cat(sprintf("  %s usuarios\n", format(us$n, big.mark=",")))
cat(sprintf("    fin_rule %8s (%.2f%%)   fin_jc %8s (%.2f%%)\n",
    format(us$fr,big.mark=","), 100*us$fr/us$n, format(us$fj,big.mark=","), 100*us$fj/us$n))
cat(sprintf("    eng_rule %8s (%.2f%%)   eng_jc %8s (%.2f%%)\n",
    format(us$er,big.mark=","), 100*us$er/us$n, format(us$ej,big.mark=","), 100*us$ej/us$n))
cat(sprintf("    com AMBAS (nota 7): rule %s | jc %s\n",
    format(us$both_rule,big.mark=","), format(us$both_jc,big.mark=",")))

cat("\n--- concordancia entre as duas definicoes (usuario) ---\n")
for (fld in c("fin", "eng")) {
  a <- dbGetQuery(con, sprintf("
    SELECT sum(CASE WHEN %1$s_rule=1 AND %1$s_jc=1 THEN 1 ELSE 0 END) both_,
           sum(CASE WHEN %1$s_rule=1 AND %1$s_jc=0 THEN 1 ELSE 0 END) rule_only,
           sum(CASE WHEN %1$s_rule=0 AND %1$s_jc=1 THEN 1 ELSE 0 END) jc_only
    FROM read_parquet('%2$s')", fld, fw(out_user)))
  cat(sprintf("  %s: ambos %s | so regra %s | so job_category %s\n", fld,
      format(a$both_,big.mark=","), format(a$rule_only,big.mark=","),
      format(a$jc_only,big.mark=",")))
}

cat("\n=========== FIM ===========\n")
cat(sprintf("  %.1f min\n", as.numeric(difftime(Sys.time(), t0, units="mins"))))
cat("  ", out_pos, "\n  ", out_user, "\n", sep = "")
