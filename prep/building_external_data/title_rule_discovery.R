####################################################################
###
### Descoberta de expressoes de title_raw para Finance e Engineering
###                                                    -> title_rules/
###
### Implementa o caminho ESSENCIAL de
### docs/finding_position_expressions.md: usa o job_category como
### rotulo de supervisao FRACA para achar expressoes interpretaveis em
### title_raw que depois viram regex.
###
### OFFLINE. Somente-leitura em relacao ao pipeline. Escreve so dentro
### de revelio_br_cohort/title_rules/. Nao mande para o SEDAP.
###
### Depende de:
###   revelio_br_cohort/obmep_candidates_selected_positions.parquet (21a)
###   revelio_br_cohort/obmep_candidates_step_1_position/           (10a)
###   revelio_br_cohort/field_manual_class.csv                      (10h)
###
### -----------------------------------------------------------------
### O QUE FOI CORTADO DO DOC, E POR QUE
### -----------------------------------------------------------------
### Pedido: so o essencial, sem multiplos metodos de inferencia.
###   FORA  secao 9 (LASSO) inteira
###   FORA  estatisticas opcionais da secao 4 (log odds, qui-quadrado,
###         z-score) -- ficam support/precision/recall/base rate/lift
###   FORA  os quatro limiares da secao 5; fica UM, support >= 50
###   FORA  a tabela agregada completa da secao 13; fica um resumo
###   FORA  listas separadas de "ambiguas" e "instaveis" da secao 15 --
###         as duas saem da tabela principal filtrando faixa de
###         precisao e precision_change
###   DENTRO os dois esquemas de peso da secao 10: como o pipeline
###         agrega por titulo unico carregando n_pos, posicao-ponderado
###         e titulo-unico sao a MESMA consulta com outro SUM. Nao
###         custa nada, e aqui os dois divergem: 67% das posicoes estao
###         em titulos que aparecem 10x ou mais.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. OFFLINE, sem rede, fora do SEDAP.
### 2. O job_category E ROTULO FRACO, E MEDIMOS O QUANTO. Contra a
###    classificacao manual de campo das 1.000 linhas (10h):
###      job_category='Engineer' -> campo engineering  67.4% precisao
###      job_category='Finance'  -> campo finance      61.0% precisao
###    Ou seja: uma regra com 99% de precisao contra o job_category
###    reproduz 99% bem um rotulo que acerta ~2/3 do campo. A
###    descoberta VAI aprender os erros do Revelio junto -- o ramo
###    Quality Assurance puxando laboratorio clinico, o Client
###    Services puxando vendas. Por isso existe o Step 9.
### 3. TRES CAMADAS DE VALIDACAO, e a terceira nao esta no doc.
###    1a descoberta (job_category), 2a validacao out-of-sample
###    (job_category), 3a as 1.000 linhas classificadas a mao por
###    CAMPO. A 3a e pequena (76 finance, 192 engineering): serve para
###    direcao e ordem de grandeza, NAO para precisao. Sem ela nao da
###    para separar "aprendeu o campo" de "aprendeu o Revelio".
### 4. AGREGA POR TITULO UNICO ANTES DE MINERAR. 7.275.957 posicoes
###    viram 1.840.304 titulos normalizados. Reduz 4x e faz a exigencia
###    da secao 2 -- titulo identico nunca nos dois lados -- valer
###    automaticamente.
### 5. ACENTO PRE-COMPOSTO x DECOMPOSTO. O texto mistura c cedilha
###    U+00E7 e c + U+0327. Conferido: o strip_accents do DuckDB
###    resolve os dois, e nfc_normalize roda antes por seguranca. Isso
###    ja quebrou o verificador de evidencia da 10h.
### 6. NAO USA title_translated. A traducao erra demais
###    ("Garconete" -> "boy") e envenenaria a descoberta.
### 7. '+' E '#' SOBREVIVEM A NORMALIZACAO, senao 'c++' e 'c#' viram
###    'c' e somem.
### 8. UM TITULO QUE CONTEM A MESMA EXPRESSAO DUAS VEZES CONTA UMA VEZ.
###    O DISTINCT do Step 3 e o que garante isso; sem ele o support
###    infla em silencio.
### 9. 1.626 POSICOES (0.022%) FICAM DE FORA: o titulo normaliza para
###    vazio. So-pontuacao e ESCRITA NAO-LATINA (chines, grego), que o
###    filtro [a-z0-9+#] apaga. Nao sao classificaveis por regex latina
###    de qualquer jeito, mas o Step 1 conta e declara a perda em vez
###    de deixar sumir.
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
out_dir <- file.path(coh_dir, "title_rules")

sel_path   <- file.path(coh_dir, "obmep_candidates_selected_positions.parquet")
pos_dir    <- file.path(coh_dir, "obmep_candidates_step_1_position")
gold_path  <- file.path(coh_dir, "field_manual_class.csv")

min_support   <- 50L      # secao 5, limiar unico
disc_share    <- 7L       # 7 de 10 hashes vao para descoberta
max_ngram     <- 4L
pair_min_sup  <- 500L     # unigramas candidatos a combinacao
pair_lo       <- 0.15     # faixa ambigua para buscar pares
pair_hi       <- 0.85
n_rules_eval  <- 2000L    # teto de regras na fronteira; 400 truncava Engineer
mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")

# Medido na coorte selecionada, para conferir que nada se perdeu.
exp_positions <- 7275957
exp_fin       <- 498916
exp_eng       <- 1599940

for (f in c(sel_path, gold_path)) if (!file.exists(f)) stop("Nao encontrei ", f)
if (!dir.exists(pos_dir)) stop("Nao encontrei ", pos_dir)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_title_rules")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit)))
invisible(dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir)))
invisible(dbExecute(con, "SET preserve_insertion_order=false"))
fw <- function(p) gsub("\\\\", "/", p)
sel_src <- sprintf("read_parquet('%s')", fw(sel_path))
pos_src <- sprintf("read_parquet('%s/*')", fw(pos_dir))

t_start <- Sys.time()
cat("=========== 10j -- DESCOBERTA DE EXPRESSOES ===========\n")

####################################################################
### Step 1: normalizar e agregar por titulo unico  (secoes 1 e 10)
####################################################################

# Nota 5: nfc_normalize antes de strip_accents. Nota 7: + e # ficam.
norm_expr <- "trim(regexp_replace(
    regexp_replace(lower(strip_accents(nfc_normalize(p.title_raw))),
                   '[^a-z0-9+#]+', ' ', 'g'),
    ' +', ' ', 'g'))"

cat("\n--- Step 1: agregando por titulo unico ---\n")
invisible(dbExecute(con, sprintf("
CREATE OR REPLACE TABLE titles AS
SELECT %s AS norm,
       count(*)                                              AS n_pos,
       sum(CASE WHEN r.job_category='Finance'  THEN 1 ELSE 0 END) AS n_fin,
       sum(CASE WHEN r.job_category='Engineer' THEN 1 ELSE 0 END) AS n_eng
FROM %s r
JOIN %s p ON r.position_id = p.position_id
WHERE p.title_raw IS NOT NULL AND trim(p.title_raw) <> ''
GROUP BY 1
HAVING length(trim(%s)) > 0", norm_expr, sel_src, pos_src, norm_expr)))

tot <- dbGetQuery(con, "SELECT count(*) n_titles, sum(n_pos) n_pos,
                        sum(n_fin) n_fin, sum(n_eng) n_eng FROM titles")
cat(sprintf("  titulos unicos : %s\n", format(tot$n_titles, big.mark = ",")))
cat(sprintf("  posicoes       : %s\n", format(tot$n_pos, big.mark = ",")))

# Verificacao 1: a agregacao nao pode perder posicao nenhuma.
# Nota 9: a diferenca contra o medido e CONHECIDA e contabilizada --
# titulo que normaliza para vazio. Duas causas, as duas verificadas:
# so-pontuacao (ponto, hifen, underscore) e ESCRITA NAO-LATINA (chines,
# grego), que o filtro [a-z0-9+#] apaga inteira. Sao 1.626 posicoes,
# 0.022%. Nao sao classificaveis por regex latina de qualquer forma,
# mas ficam declaradas em vez de sumirem caladas.
drop_pos <- exp_positions - tot$n_pos
cat(sprintf("  fora: %s posicoes (%.3f%%) cujo titulo normaliza para vazio\n",
            format(drop_pos, big.mark = ","), 100 * drop_pos / exp_positions))
if (drop_pos < 0 || drop_pos > 0.001 * exp_positions) {
  stop("Perda de ", drop_pos, " posicoes na agregacao, acima do previsto ",
       "(~1626). Algo mudou na normalizacao ou na fonte (nota 9).")
}
cat("  [OK] perda dentro do previsto e contabilizada\n")

####################################################################
### Step 2: separar descoberta e validacao  (secao 2)
####################################################################

# Nota 4: o split e por TITULO, entao titulo identico nunca cai nos
# dois lados.
invisible(dbExecute(con, sprintf("
CREATE OR REPLACE TABLE titles_s AS
SELECT *, CASE WHEN abs(hash(norm)) %% 10 < %d THEN 'disc' ELSE 'valid' END AS split
FROM titles", disc_share)))

sp <- dbGetQuery(con, "SELECT split, count(*) n_titles, sum(n_pos) n_pos,
                       sum(n_fin) n_fin, sum(n_eng) n_eng
                       FROM titles_s GROUP BY 1 ORDER BY 1")
print(sp, row.names = FALSE)
ov <- dbGetQuery(con, "SELECT count(*) n FROM (
  SELECT norm FROM titles_s WHERE split='disc'
  INTERSECT SELECT norm FROM titles_s WHERE split='valid')")
if (ov$n != 0) stop("Titulo em AMBAS as amostras: ", ov$n, " (secao 2 violada).")
cat("  [OK] nenhum titulo nas duas amostras\n")

base <- dbGetQuery(con, "
  SELECT sum(n_fin)/sum(n_pos) br_fin, sum(n_eng)/sum(n_pos) br_eng,
         sum(CASE WHEN split='disc' THEN n_fin END)/sum(CASE WHEN split='disc' THEN n_pos END) d_fin,
         sum(CASE WHEN split='disc' THEN n_eng END)/sum(CASE WHEN split='disc' THEN n_pos END) d_eng,
         sum(CASE WHEN split='valid' THEN n_fin END)/sum(CASE WHEN split='valid' THEN n_pos END) v_fin,
         sum(CASE WHEN split='valid' THEN n_eng END)/sum(CASE WHEN split='valid' THEN n_pos END) v_eng
  FROM titles_s")
cat(sprintf("  base rate  Finance %.2f%%   Engineer %.2f%%\n",
            100 * base$br_fin, 100 * base$br_eng))

####################################################################
### Step 3: n-gramas 1..4 com peso  (secoes 3 e 4)
####################################################################

cat("\n--- Step 3: extraindo n-gramas 1..", max_ngram, " ---\n", sep = "")
# Nota 8: DISTINCT por (titulo, expressao) -- um titulo que repete a
# expressao conta UMA vez.
invisible(dbExecute(con, sprintf("
CREATE OR REPLACE TABLE ng AS
WITH t AS (
  SELECT norm, split, n_pos, n_fin, n_eng, str_split(norm, ' ') AS w
  FROM titles_s
), pos AS (
  SELECT norm, split, n_pos, n_fin, n_eng, w,
         unnest(range(1, length(w) + 1)) AS i
  FROM t
), g AS (
  SELECT DISTINCT norm, split, n_pos, n_fin, n_eng, k AS n_words,
         array_to_string(w[i : i + k - 1], ' ') AS expr
  FROM pos, (SELECT unnest(range(1, %d)) AS k) ks
  WHERE i + k - 1 <= length(w)
)
SELECT expr, n_words, split,
       sum(n_pos)  AS support,
       sum(n_fin)  AS fin_sup,
       sum(n_eng)  AS eng_sup,
       count(*)    AS u_support,
       sum(CASE WHEN n_fin > 0 THEN 1 ELSE 0 END) AS u_fin,
       sum(CASE WHEN n_eng > 0 THEN 1 ELSE 0 END) AS u_eng
FROM g GROUP BY 1, 2, 3", max_ngram + 1L)))

cat(sprintf("  linhas de n-grama: %s\n",
            format(dbGetQuery(con, "SELECT count(*) n FROM ng")$n, big.mark = ",")))

####################################################################
### Step 4: estatisticas e expressoes unicas  (secoes 4, 5 e 6)
####################################################################

cat("\n--- Step 4: estatisticas por expressao ---\n")
invisible(dbExecute(con, sprintf("
CREATE OR REPLACE TABLE phrases AS
WITH d AS (SELECT * FROM ng WHERE split='disc'),
     v AS (SELECT expr, n_words, support, fin_sup, eng_sup FROM ng WHERE split='valid'),
     tg AS (SELECT unnest(['Finance','Engineer']) AS target)
SELECT tg.target, d.expr, d.n_words,
       d.support                                   AS d_support,
       CASE WHEN tg.target='Finance' THEN d.fin_sup ELSE d.eng_sup END AS d_target_support,
       CASE WHEN tg.target='Finance' THEN d.fin_sup ELSE d.eng_sup END * 1.0 / d.support AS d_precision,
       d.u_support,
       CASE WHEN tg.target='Finance' THEN d.u_fin ELSE d.u_eng END * 1.0 / d.u_support AS d_precision_uniq,
       coalesce(v.support, 0)                      AS v_support,
       CASE WHEN tg.target='Finance' THEN coalesce(v.fin_sup,0) ELSE coalesce(v.eng_sup,0) END AS v_target_support,
       CASE WHEN v.support > 0 THEN
         (CASE WHEN tg.target='Finance' THEN v.fin_sup ELSE v.eng_sup END) * 1.0 / v.support
         END                                       AS v_precision
FROM d CROSS JOIN tg
LEFT JOIN v ON v.expr = d.expr AND v.n_words = d.n_words
WHERE d.support >= %d", min_support)))

# base rates e derivadas (recall e lift) calculadas em R para clareza
bd <- dbGetQuery(con, "SELECT
   sum(CASE WHEN split='disc' THEN n_pos END) dp,
   sum(CASE WHEN split='disc' THEN n_fin END) df,
   sum(CASE WHEN split='disc' THEN n_eng END) de,
   sum(CASE WHEN split='valid' THEN n_pos END) vp,
   sum(CASE WHEN split='valid' THEN n_fin END) vf,
   sum(CASE WHEN split='valid' THEN n_eng END) ve FROM titles_s")
invisible(dbExecute(con, sprintf("
CREATE OR REPLACE TABLE phrases2 AS
SELECT *,
  CASE WHEN target='Finance' THEN %f ELSE %f END AS d_base_rate,
  d_target_support * 1.0 / CASE WHEN target='Finance' THEN %f ELSE %f END AS d_recall,
  d_precision      / CASE WHEN target='Finance' THEN %f ELSE %f END AS d_lift,
  CASE WHEN v_support > 0 THEN
    v_precision / CASE WHEN target='Finance' THEN %f ELSE %f END END AS v_lift,
  v_precision - d_precision AS precision_change
FROM phrases",
  bd$df/bd$dp, bd$de/bd$dp, bd$df, bd$de,
  bd$df/bd$dp, bd$de/bd$dp, bd$vf/bd$vp, bd$ve/bd$vp)))

nph <- dbGetQuery(con, "SELECT target, count(*) n FROM phrases2 GROUP BY 1")
cat(sprintf("  expressoes com support >= %d: Finance %s | Engineer %s\n", min_support,
            format(nph$n[nph$target=="Finance"], big.mark=","),
            format(nph$n[nph$target=="Engineer"], big.mark=",")))

cat("\n  -- top 10 por precisao de VALIDACAO, support >= 500 --\n")
for (tg in c("Finance", "Engineer")) {
  top <- dbGetQuery(con, sprintf("
    SELECT expr, d_support, round(d_precision,3) d_prec, round(v_precision,3) v_prec,
           round(d_lift,1) lift, round(d_recall,4) recall
    FROM phrases2 WHERE target='%s' AND d_support>=500 AND v_support>=50
    ORDER BY v_precision DESC, d_support DESC LIMIT 10", tg))
  cat("  [", tg, "]\n", sep = "")
  print(top, row.names = FALSE)
}

####################################################################
### Step 5: combinacoes A AND B e exclusoes A AND NOT B  (secoes 7 e 8)
####################################################################

cat("\n--- Step 5: pares (AND / AND NOT) ---\n")
# Busca limitada: unigramas frequentes e AMBIGUOS sozinhos sao os que
# ganham com combinacao (secao 7). Isso tambem limita o custo.
invisible(dbExecute(con, sprintf("
CREATE OR REPLACE TABLE seeds AS
SELECT DISTINCT expr FROM phrases2
WHERE n_words = 1 AND d_support >= %d
  AND d_precision BETWEEN %f AND %f", pair_min_sup, pair_lo, pair_hi)))
cat(sprintf("  unigramas semente: %s\n",
            dbGetQuery(con, "SELECT count(*) n FROM seeds")$n))

invisible(dbExecute(con, "
CREATE OR REPLACE TABLE tw AS
SELECT g.norm, g.split, g.n_pos, g.n_fin, g.n_eng, g.expr
FROM (SELECT DISTINCT t.norm, t.split, t.n_pos, t.n_fin, t.n_eng,
             unnest(str_split(t.norm,' ')) AS expr FROM titles_s t) g
JOIN seeds s ON s.expr = g.expr"))

invisible(dbExecute(con, sprintf("
CREATE OR REPLACE TABLE pairs AS
WITH cp AS (
  SELECT a.norm, a.split, a.n_pos, a.n_fin, a.n_eng,
         a.expr AS e1, b.expr AS e2
  FROM tw a JOIN tw b ON a.norm = b.norm AND a.expr < b.expr
), agg AS (
  SELECT e1, e2, split, sum(n_pos) support, sum(n_fin) fin_sup, sum(n_eng) eng_sup
  FROM cp GROUP BY 1,2,3
)
SELECT e1, e2,
  sum(CASE WHEN split='disc'  THEN support END) d_support,
  sum(CASE WHEN split='disc'  THEN fin_sup END) d_fin,
  sum(CASE WHEN split='disc'  THEN eng_sup END) d_eng,
  sum(CASE WHEN split='valid' THEN support END) v_support,
  sum(CASE WHEN split='valid' THEN fin_sup END) v_fin,
  sum(CASE WHEN split='valid' THEN eng_sup END) v_eng
FROM agg GROUP BY 1,2
HAVING sum(CASE WHEN split='disc' THEN support END) >= %d", min_support)))
cat(sprintf("  pares avaliados  : %s\n",
            format(dbGetQuery(con, "SELECT count(*) n FROM pairs")$n, big.mark=",")))

####################################################################
### Step 6: tabela de regras candidatas  (secao 12)
####################################################################

cat("\n--- Step 6: montando a tabela de regras ---\n")
mk <- function(tg) {
  fld <- if (tg == "Finance") "fin" else "eng"
  br_d <- if (tg == "Finance") bd$df/bd$dp else bd$de/bd$dp
  br_v <- if (tg == "Finance") bd$vf/bd$vp else bd$ve/bd$vp
  tot_d <- if (tg == "Finance") bd$df else bd$de
  tot_v <- if (tg == "Finance") bd$vf else bd$ve
  sprintf("
  SELECT '%s' AS target, expr AS expression_1, NULL AS expression_2,
         'single' AS rule_type, n_words AS ngram_length,
         d_support, d_precision, d_recall, d_lift,
         v_support, v_precision, v_lift,
         v_target_support * 1.0 / %f AS v_recall, precision_change
  FROM phrases2 WHERE target='%s'
  UNION ALL
  SELECT '%s', e1, e2, 'AND', 2,
         d_support, d_%s*1.0/d_support, d_%s*1.0/%f, (d_%s*1.0/d_support)/%f,
         v_support, v_%s*1.0/v_support, (v_%s*1.0/v_support)/%f,
         v_%s*1.0/%f, (v_%s*1.0/v_support) - (d_%s*1.0/d_support)
  FROM pairs WHERE v_support > 0",
  tg, tot_d, tg, tg, fld, fld, tot_d, fld, br_d, fld, fld, br_v, fld, tot_v, fld, fld)
}
invisible(dbExecute(con, sprintf(
  "CREATE OR REPLACE TABLE rules AS %s UNION ALL %s", mk("Finance"), mk("Engineer"))))
cat(sprintf("  regras candidatas: %s\n",
            format(dbGetQuery(con,"SELECT count(*) n FROM rules")$n, big.mark=",")))

####################################################################
### Step 7: fronteira cobertura-precisao  (secao 14)
####################################################################

cat("\n--- Step 7: fronteira cobertura x precisao (validacao) ---\n")
frontier <- list()
for (tg in c("Finance", "Engineer")) {
  fld <- if (tg == "Finance") "n_fin" else "n_eng"
  top <- dbGetQuery(con, sprintf("
    SELECT expression_1, expression_2, rule_type, v_precision, v_support
    FROM rules WHERE target='%s' AND v_support >= %d AND v_precision IS NOT NULL
    ORDER BY v_precision DESC, v_support DESC LIMIT %d", tg, min_support, n_rules_eval))
  vt <- dbGetQuery(con, sprintf(
    "SELECT norm, n_pos, %s AS n_tgt FROM titles_s WHERE split='valid'", fld))
  pad <- paste0(" ", vt$norm, " ")
  covered <- rep(FALSE, nrow(vt))
  rows <- list()
  for (i in seq_len(nrow(top))) {
    hit <- grepl(paste0(" ", top$expression_1[i], " "), pad, fixed = TRUE)
    if (!is.na(top$expression_2[i])) {
      hit <- hit & grepl(paste0(" ", top$expression_2[i], " "), pad, fixed = TRUE)
    }
    covered <- covered | hit
    rows[[i]] <- data.frame(
      target = tg, n_rules = i, rule = top$expression_1[i],
      cum_positions = sum(vt$n_pos[covered]),
      cum_target    = sum(vt$n_tgt[covered]),
      stringsAsFactors = FALSE)
  }
  f <- do.call(rbind, rows)
  f$cum_precision <- f$cum_target / f$cum_positions
  f$cum_coverage  <- f$cum_target / sum(vt$n_tgt)
  frontier[[tg]] <- f
  for (p in c(0.99, 0.95, 0.90)) {
    ok <- f[f$cum_precision >= p, ]
    if (nrow(ok)) {
      b <- ok[nrow(ok), ]
      cat(sprintf("  %-9s precisao >= %.0f%%: %3d regras, cobre %5.1f%% do alvo\n",
                  tg, 100*p, b$n_rules, 100*b$cum_coverage))
    } else {
      cat(sprintf("  %-9s precisao >= %.0f%%: nenhuma combinacao atinge\n", tg, 100*p))
    }
  }
}
front <- do.call(rbind, frontier)

####################################################################
### Step 8: relatorios de erro  (secao 15)
####################################################################

cat("\n--- Step 8: nao cobertos e falsos positivos ---\n")
unc <- list(); fps <- list()
for (tg in c("Finance", "Engineer")) {
  fld <- if (tg == "Finance") "n_fin" else "n_eng"
  top <- dbGetQuery(con, sprintf("
    SELECT expression_1, expression_2 FROM rules
    WHERE target='%s' AND v_support >= %d AND v_precision >= 0.90
    ORDER BY v_precision DESC LIMIT %d", tg, min_support, n_rules_eval))
  vt <- dbGetQuery(con, sprintf(
    "SELECT norm, n_pos, %s AS n_tgt FROM titles_s WHERE split='valid'", fld))
  pad <- paste0(" ", vt$norm, " ")
  cov <- rep(FALSE, nrow(vt))
  for (i in seq_len(nrow(top))) {
    h <- grepl(paste0(" ", top$expression_1[i], " "), pad, fixed = TRUE)
    if (!is.na(top$expression_2[i]))
      h <- h & grepl(paste0(" ", top$expression_2[i], " "), pad, fixed = TRUE)
    cov <- cov | h
  }
  u <- vt[!cov & vt$n_tgt > 0, ]; u <- u[order(-u$n_tgt), ]
  unc[[tg]] <- head(data.frame(target = tg, norm = u$norm, n_target = u$n_tgt,
                               n_pos = u$n_pos, stringsAsFactors = FALSE), 200)
  f <- vt[cov, ]; f$n_non <- f$n_pos - f$n_tgt; f <- f[order(-f$n_non), ]
  fps[[tg]] <- head(data.frame(target = tg, norm = f$norm, n_non_target = f$n_non,
                               n_pos = f$n_pos, stringsAsFactors = FALSE), 200)
  cat(sprintf("  %-9s cobertura do alvo por regras >=90%%: %.1f%%\n",
              tg, 100 * sum(vt$n_tgt[cov]) / sum(vt$n_tgt)))
}
uncovered <- do.call(rbind, unc); falsepos <- do.call(rbind, fps)

####################################################################
### Step 9: 3a camada -- as 1.000 linhas classificadas a mao (nota 3)
####################################################################

cat("\n--- Step 9: contra o padrao-ouro de CAMPO (1.000 linhas) ---\n")
gold <- read.csv(gold_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
                 colClasses = "character")
dbWriteTable(con, "gold", gold[, c("position_id", "verdict")], overwrite = TRUE)
gt <- dbGetQuery(con, sprintf("
  SELECT g.verdict, %s AS norm
  FROM gold g JOIN %s p ON CAST(p.position_id AS VARCHAR) = g.position_id
  WHERE p.title_raw IS NOT NULL AND trim(p.title_raw) <> ''", norm_expr, pos_src))
gpad <- paste0(" ", gt$norm, " ")
gold_rows <- list()
for (tg in c("Finance", "Engineer")) {
  fld <- if (tg == "Finance") "finance" else "engineering"
  truth <- gt$verdict == fld
  top <- dbGetQuery(con, sprintf("
    SELECT expression_1, expression_2 FROM rules
    WHERE target='%s' AND v_support >= %d AND v_precision >= 0.90
    ORDER BY v_precision DESC LIMIT %d", tg, min_support, n_rules_eval))
  cov <- rep(FALSE, length(gpad))
  for (i in seq_len(nrow(top))) {
    h <- grepl(paste0(" ", top$expression_1[i], " "), gpad, fixed = TRUE)
    if (!is.na(top$expression_2[i]))
      h <- h & grepl(paste0(" ", top$expression_2[i], " "), gpad, fixed = TRUE)
    cov <- cov | h
  }
  tp <- sum(cov & truth)
  gold_rows[[tg]] <- data.frame(
    target = tg, n_rules = nrow(top), n_gold_target = sum(truth),
    n_flagged = sum(cov), tp = tp,
    precision_field = if (sum(cov)) tp/sum(cov) else NA,
    recall_field = if (sum(truth)) tp/sum(truth) else NA,
    stringsAsFactors = FALSE)
  cat(sprintf("  %-9s regras >=90%% (contra job_category) valem no CAMPO: ", tg))
  cat(sprintf("prec %.1f%%  rec %.1f%%  (n_alvo=%d)\n",
              100*gold_rows[[tg]]$precision_field, 100*gold_rows[[tg]]$recall_field,
              sum(truth)))
}
goldchk <- do.call(rbind, gold_rows)
cat("  [!] n pequeno (76 finance / 192 engineering): direcao, nao precisao (nota 3)\n")

####################################################################
### Step 10: gravar
####################################################################

cat("\n--- Step 10: gravando em title_rules/ ---\n")
wp <- function(tbl, name) {
  f <- file.path(out_dir, name)
  invisible(dbExecute(con, sprintf(
    "COPY (SELECT * FROM %s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    tbl, fw(f))))
  cat("  ", name, "\n", sep = "")
}
wp("phrases2", "candidate_phrases.parquet")
wp("rules", "candidate_rules.parquet")
for (nm in c("front", "uncovered", "falsepos", "goldchk")) {
  dbWriteTable(con, paste0("t_", nm), get(nm), overwrite = TRUE)
}
wp("t_front", "coverage_precision_frontier.parquet")
wp("t_uncovered", "uncovered_titles.parquet")
wp("t_falsepos", "false_positive_titles.parquet")
wp("t_goldchk", "gold_standard_check.parquet")

cat("\n=========== FIM ===========\n")
cat(sprintf("  tempo: %.1f min\n",
            as.numeric(difftime(Sys.time(), t_start, units = "mins"))))
cat("  ", out_dir, "\n", sep = "")
