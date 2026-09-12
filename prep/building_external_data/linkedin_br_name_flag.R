####################################################################
###
### Flag de perfis possivelmente brasileiros no LinkedIn
### via match exato do primeiro nome contra a lista de nomes IBGE
###
### Metodo unico: match EXATO. O primeiro nome do campo `fullname` e
### extraido, tem acentos removidos e caracteres nao-alfabeticos
### descartados, e e comparado contra uma tabela longa de nomes IBGE
### que contem nomes canonicos E suas variantes de grafia.
###
### Todo o processamento e feito em DuckDB. Nao existe etapa de
### computacao em R e nao ha dependencia alem de duckdb + DBI, de modo
### que o script roda em ambiente sem internet.
###
### -----------------------------------------------------------------
### LIMITACOES CONHECIDAS (medidas nos dados reais)
### -----------------------------------------------------------------
### 1. Nomes invertidos por virgula: "de Souza, Joao" resulta em
###    "souza". Atinge 0,63% das linhas (4,47M). NAO tratado de
###    proposito: usar o trecho depois da virgula quebraria o padrao
###    muito mais comum de sufixo de credencial no LinkedIn
###    ("Jim Perry, MBA" -> "mba"), trocando um falso negativo por um
###    falso positivo.
### 2. Letras latinas sem decomposicao NFD (l/o/d/ss barrados) sao
###    removidas por strip_accents + [^a-z]: "Lukasz" -> "ukasz".
###    Irrelevante para nomes brasileiros.
### 3. Escritas nao-latinas (CJK, cirilico, arabe) resultam em nome
###    vazio -> NULL -> nunca sinalizadas. 41,0M linhas (5,8%). O
###    metodo e estruturalmente cego a brasileiros que escrevem o
###    nome em outro alfabeto.
### 4. O flag isolado NAO e discriminante: 50,4% de taxa base. A
###    expansao por variantes somou 7,5 p.p. de recall mas tambem
###    35.683 grafias raras (frequencia mediana 111), algumas delas
###    internacionalmente comuns. USE p_brazil / ratio para aplicar
###    corte; nao consuma flag_exact isoladamente.
### 5. Frequencias de variantes NUNCA podem ser somadas: uma variante
###    se liga a ate 15 nomes canonicos neste subconjunto (62 na fonte
###    bruta). A agregacao e max(), segura apenas porque a frequencia
###    e verificadamente consistente por token.
### 6. Sem tolerancia a erro de grafia alem da propria lista de
###    variantes do IBGE.
### 7. p_brazil e um ORDENAMENTO, nao uma probabilidade calibrada.
###
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb")) {
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
gt_root    <- Sys.getenv("GT_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/GTAllocation")

lk_dir    <- file.path(gt_root, "Data/intermediate/fuzzy_match/linkedin_names")
ibge_path <- file.path(obmep_root,
                       "Data/intermediate/ibge_names/final_given_names_with_variants.parquet")
out_dir   <- file.path(obmep_root, "Data/intermediate/linkedin_br_flags")
prof_dir  <- file.path(out_dir, "profiles")

path_counts  <- file.path(out_dir, "firstname_counts.parquet")
path_ibge    <- file.path(out_dir, "ibge_long.parquet")
path_matches <- file.path(out_dir, "firstname_matches.parquet")

n_chunks   <- 20L
mem_limit  <- "12GB"

# Parcela assumida do Brasil neste universo LinkedIn. Entra apenas em
# p_brazil, como P(BR) no teorema de Bayes. Alterar aqui reescala todos
# os scores de forma monotona, sem mudar o ordenamento.
p_br <- 0.09

# Valores medidos no planejamento contra os dados reais. Servem como
# teste de regressao: divergencia significa que a limpeza ou a tabela
# IBGE mudou.
exp_rows        <- 708365562
exp_ibge_tokens <- 48539L
exp_ibge_canon  <- 12856L
exp_ibge_var    <- 35683L
exp_flag_all    <- 357336323
exp_flag_canon  <- 304427855

dir.create(prof_dir, recursive = TRUE, showWarnings = FALSE)

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_linkedin_br")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(dir.exists(lk_dir), file.exists(ibge_path))

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# temp_directory explicito: um job de 708M linhas vai derramar para
# disco e o derrame nao pode cair em pasta sincronizada pelo Dropbox.
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))
dbExecute(con, "SET preserve_insertion_order=false")

cat("DuckDB:", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("temp_directory:", tmp_dir, "\n\n")

####################################################################
### Expressoes de limpeza do nome
####################################################################

# Particulas, titulos e conectivos que nao podem ser tomados como
# primeiro nome quando aparecem na frente da string.
particles <- c("de", "da", "do", "dos", "das", "di", "del", "dello", "della",
               "du", "van", "von", "der", "den", "ter", "la", "le", "el",
               "al", "bin", "ibn", "dr", "dra", "prof", "eng", "sr", "sra",
               "mr", "ms", "mrs")
plist <- paste0("'", particles, "'", collapse = ",")

# strip_accents e a funcao correta do DuckDB. NAO usar unaccent(): ela
# nao existe no DuckDB, e por isso fuzzy_match_script.r (fev_2026) esta
# quebrado como escrito.
#
# Caracteres nao-alfabeticos viram ESPACO, nao sao deletados. Isso e
# deliberado: "Jim Perry-ECUMC" -> "jim" e "THIAGO_FERREIRA 2024" ->
# "thiago", enquanto a delecao fundiria tokens em strings impossiveis
# de casar.
clean_expr <- paste0(
  "trim(regexp_replace(regexp_replace(",
  "lower(strip_accents(fullname)), '[^a-z ]', ' ', 'g'), ' +', ' ', 'g'))"
)

# Primeiro token com 2+ letras que nao seja particula/titulo. Lista
# vazia indexa para NULL. O corte em 2 letras descarta iniciais sem
# custo, pois todo token IBGE tem 2+ caracteres.
first_expr <- sprintf(
  "list_filter(str_split(%s, ' '), x -> length(x) >= 2 AND x NOT IN (%s))[1]",
  clean_expr, plist
)

####################################################################
### Teste de regressao da limpeza
####################################################################

# Escapes \u em vez de literais para que o teste nao dependa da
# codificacao do arquivo.
test_in <- c(
  "M\u00e1rio - Ueti", "Jim Perry-ECUMC", "Dr. Ana Paula Souza",
  "J. Carlos de Oliveira", "JOS\u00c9 DA SILVA", "Jean-Pierre Dubois",
  "MONIKA ZI\u0118\u0106", "Zuzana Turo\u010dekov\u00e1",
  "THI\u00c1GO_FERREIRA 2024", "\u82cf\u5e86\u9f99",
  "\u041c\u0430\u043a\u0441\u0438\u043c \u041c\u0443\u0440\u0435\u0435\u0432",
  "A B C", "de Souza, Jo\u00e3o", "\u0141ukasz Nowak"
)
test_exp <- c("mario", "jim", "ana", "carlos", "jose", "jean", "monika",
              "zuzana", "thiago", NA, NA, NA, "souza", "ukasz")

# ORDER BY id explicito: preserve_insertion_order=false permite que o
# DuckDB devolva as linhas fora de ordem, o que silenciosamente
# invalidaria a comparacao posicional abaixo.
dbWriteTable(con, "clean_test",
             data.frame(id = seq_along(test_in), fullname = test_in),
             temporary = TRUE)
got <- dbGetQuery(con, sprintf(
  "SELECT %s AS fn FROM clean_test ORDER BY id", first_expr))$fn

if (!identical(is.na(got), is.na(test_exp)) ||
    !identical(got[!is.na(got)], test_exp[!is.na(test_exp)])) {
  print(data.frame(fullname = test_in, esperado = test_exp, obtido = got))
  stop("Teste de regressao da limpeza falhou.")
}
cat("[OK] teste de regressao da limpeza:", length(test_in), "casos\n\n")

####################################################################
### Tabela longa de nomes IBGE (canonicos + variantes)
####################################################################

# Semantica verificada na fonte bruta, nao re-derivar:
#  - Todas as 623.966 linhas de name_variant tambem existem em
#    name_ranking com frequencia IDENTICA (0 divergencias). Variante
#    nao e objeto separado: e um nome comum referenciado como grafia
#    alternativa. Logo a frequencia e propriedade do token sozinho.
#  - Uma variante se liga a ate 15 pais canonicos neste subconjunto,
#    mas variant_frequency e sempre consistente por variant_text
#    (0 inconsistencias). Por isso max() e correto e sum() seria
#    catastrofico (a soma bruta infla para 2,63 bilhoes contra uma
#    populacao real de 190M).
#  - A frequencia canonica de "maria" (12.284.478) NAO inclui suas
#    variantes (34.991): sao entradas disjuntas, sem dupla contagem.
#
# GROUP BY token e o que garante UMA linha por token, e e isso que
# impede o join de 708M linhas de estourar em fan-out.
dbExecute(con, sprintf("
CREATE OR REPLACE TABLE ibge_long AS
WITH u AS (
  SELECT name_text AS token, frequency AS freq, TRUE AS is_canon,
         name_text AS parent, frequency AS parent_freq, rank AS canon_rank
  FROM read_parquet('%s')
  UNION ALL
  SELECT variant_text, variant_frequency, FALSE,
         name_text, frequency, NULL
  FROM read_parquet('%s')
  WHERE variant_text IS NOT NULL
)
SELECT token,
       max(freq)       AS ibge_freq,
       max(is_canon)   AS is_canonical,
       max(canon_rank) AS canon_rank,
       count(DISTINCT CASE WHEN NOT is_canon THEN parent END) AS n_parents,
       CASE WHEN max(is_canon) THEN token
            ELSE arg_max(parent, parent_freq) END AS primary_canonical
FROM u
GROUP BY token", ibge_path, ibge_path))

chk <- dbGetQuery(con, "
  SELECT count(*) AS n_rows, count(DISTINCT token) AS n_tokens,
         sum(is_canonical::INT) AS n_canon,
         sum(CASE WHEN NOT is_canonical THEN 1 ELSE 0 END) AS n_var,
         min(length(token)) AS len_min, max(length(token)) AS len_max,
         sum(CASE WHEN token <> lower(token) THEN 1 ELSE 0 END) AS not_lower,
         sum(CASE WHEN contains(token, ' ') THEN 1 ELSE 0 END) AS has_space,
         sum(CASE WHEN regexp_matches(token, '[^a-z]') THEN 1 ELSE 0 END) AS non_az,
         sum(CASE WHEN token IS NULL THEN 1 ELSE 0 END) AS n_null,
         sum(ibge_freq) AS ibge_total, max(n_parents) AS max_parents
  FROM ibge_long")
print(chk)

# Consistencia de frequencia por token na fonte: se falhar, max() deixa
# de ser uma escolha segura e o score fica arbitrario.
conf <- dbGetQuery(con, sprintf("
  WITH u AS (
    SELECT name_text AS token, frequency AS freq FROM read_parquet('%s')
    UNION ALL
    SELECT variant_text, variant_frequency FROM read_parquet('%s')
    WHERE variant_text IS NOT NULL)
  SELECT count(*) AS n FROM (
    SELECT token FROM u GROUP BY token HAVING count(DISTINCT freq) > 1)",
  ibge_path, ibge_path))$n

n_type <- dbGetQuery(con, sprintf(
  "SELECT count(DISTINCT name_type) AS n FROM read_parquet('%s')", ibge_path))$n

if (chk$n_rows != chk$n_tokens) stop("ibge_long: token duplicado -> risco de fan-out.")
if (chk$n_rows != exp_ibge_tokens) stop("ibge_long: esperado ", exp_ibge_tokens,
                                        " tokens, obtido ", chk$n_rows)
if (chk$n_canon != exp_ibge_canon) stop("ibge_long: canonicos != ", exp_ibge_canon)
if (chk$n_var   != exp_ibge_var)   stop("ibge_long: variantes != ", exp_ibge_var)
if (conf != 0)        stop("ibge_long: ", conf, " tokens com frequencia conflitante.")
if (n_type != 1L)     stop("Fonte IBGE deveria conter apenas name_type='given'.")
if (chk$len_min < 2 || chk$len_max > 13) stop("ibge_long: comprimento fora de 2-13.")
if (chk$not_lower || chk$has_space || chk$non_az || chk$n_null) {
  stop("ibge_long: invariantes de texto do token violadas.")
}

ibge_total <- chk$ibge_total
cat("[OK] ibge_long:", chk$n_rows, "tokens (",
    chk$n_canon, "canonicos +", chk$n_var, "variantes ), soma freq =",
    format(ibge_total, big.mark = ","), "\n\n")

dbExecute(con, sprintf(
  "COPY ibge_long TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", path_ibge))

####################################################################
### Passo 1: primeiros nomes distintos + contagem (uma varredura)
####################################################################

lk_glob <- file.path(lk_dir, "linkedin_chunk_*.parquet")

if (file.exists(path_counts)) {
  cat("[skip] firstname_counts.parquet ja existe\n")
} else {
  cat("Varrendo os 20 arquivos para contar primeiros nomes distintos...\n")
  t0 <- Sys.time()
  dbExecute(con, sprintf("
    COPY (SELECT fn, count(*) AS lk_n
          FROM (SELECT %s AS fn FROM read_parquet('%s'))
          WHERE fn IS NOT NULL
          GROUP BY fn)
    TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    first_expr, lk_glob, path_counts))
  cat("  concluido em",
      round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
}

# Totais usados na reconciliacao e no denominador de lk_share.
# count(*) em parquet le so o metadado, entao nao custa varredura; e o
# numero de primeiros nomes NULL sai por subtracao, ja que lk_total soma
# exatamente as linhas com primeiro nome nao-nulo. Isso evita uma
# segunda varredura completa de 708M linhas (~2 min).
lk_total <- dbGetQuery(con, sprintf(
  "SELECT sum(lk_n) AS s FROM read_parquet('%s')", path_counts))$s
n_distinct <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM read_parquet('%s')", path_counts))$n
n_rows <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM read_parquet('%s')", lk_glob))$n
n_null_fn <- n_rows - lk_total

if (n_rows != exp_rows) {
  warning("Total de linhas ", format(n_rows, big.mark = ","),
          " difere do esperado ", format(exp_rows, big.mark = ","))
}
cat(sprintf("Linhas: %s | primeiro nome NULL: %s (%.2f%%) | nomes distintos: %s\n\n",
            format(n_rows, big.mark = ","),
            format(n_null_fn, big.mark = ","),
            100 * n_null_fn / n_rows,
            format(n_distinct, big.mark = ",")))

####################################################################
### Passo 2: tabela de match no nivel do nome
####################################################################

# ibge_share usa a frequencia PROPRIA do token, nunca a do pai
# canonico: "mariah" pontua sobre 24.382 e nao sobre os 12.284.478 de
# "maria". Herdar a frequencia do pai daria a toda variante rara um
# ibge_share enorme e empurraria p_brazil para 1 em bloco.
#
# p_brazil vem de Bayes: P(BR|nome) = P(nome|BR) * P(BR) / P(nome),
# estimando P(nome|BR) por ibge_share e P(nome) por lk_share.
# CONFUNDIMENTO: o LinkedIn sub-representa brasileiros mais velhos,
# mais pobres e rurais, logo ibge_share superestima
# P(nome | brasileiro NO LINKEDIN). Isso infla p_brazil para nomes
# como "raimunda" e "terezinha". Trate como ORDENAMENTO, nao como
# probabilidade calibrada.
#
# ATENCAO: least() no DuckDB IGNORA NULL -- least(1.0, NULL) devolve
# 1.0, nao NULL. Sem o guarda CASE abaixo, todo nome NAO casado (ratio
# NULL) receberia p_brazil = 1.0, ou seja, indicatividade brasileira
# MAXIMA justamente para quem nao casou ("scott", "md", "ahmed").
# O guarda e obrigatorio, nao cosmetico.
dbExecute(con, sprintf("
CREATE OR REPLACE TABLE firstname_matches AS
SELECT *,
       log10(ratio) AS log10_ratio,
       CASE WHEN ratio IS NULL THEN NULL
            ELSE least(1.0, %.10f / ratio) END AS p_brazil
FROM (
  SELECT *, lk_share / ibge_share AS ratio
  FROM (
    SELECT f.fn                      AS first_name_clean,
           f.lk_n,
           (i.token IS NOT NULL)     AS flag_exact,
           CASE WHEN i.token IS NULL   THEN NULL
                WHEN i.is_canonical    THEN 'canonical'
                ELSE 'variant' END   AS match_level,
           i.ibge_freq, i.canon_rank, i.n_parents, i.primary_canonical,
           f.lk_n::DOUBLE / %.1f     AS lk_share,
           i.ibge_freq::DOUBLE / %.1f AS ibge_share
    FROM read_parquet('%s') f
    LEFT JOIN ibge_long i ON f.fn = i.token
  )
)", p_br, lk_total, ibge_total, path_counts))

nm <- dbGetQuery(con, "
  SELECT count(*) AS n, count(DISTINCT first_name_clean) AS d,
         sum(CASE WHEN NOT flag_exact AND p_brazil IS NOT NULL THEN 1 ELSE 0 END) AS bad_p,
         sum(CASE WHEN flag_exact AND p_brazil IS NULL THEN 1 ELSE 0 END) AS miss_p
  FROM firstname_matches")
if (nm$n != nm$d) stop("firstname_matches: nome duplicado -> risco de fan-out.")
# p_brazil precisa ser NULL exatamente quando nao houve match. Protege
# contra a semantica de least() com NULL descrita acima.
if (nm$bad_p != 0)  stop("p_brazil preenchido em ", nm$bad_p, " nomes sem match.")
if (nm$miss_p != 0) stop("p_brazil nulo em ", nm$miss_p, " nomes com match.")

dbExecute(con, sprintf(
  "COPY firstname_matches TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", path_matches))
cat("[OK] firstname_matches:", format(nm$n, big.mark = ","), "nomes distintos\n\n")

####################################################################
### Passo 3: diagnostico
####################################################################

cat("=========== TAXA DE SINALIZACAO (nivel linha) ===========\n")
rate <- dbGetQuery(con, sprintf("
  SELECT sum(CASE WHEN flag_exact THEN lk_n ELSE 0 END) AS flag_all,
         sum(CASE WHEN match_level='canonical' THEN lk_n ELSE 0 END) AS flag_canon,
         sum(CASE WHEN match_level='variant'   THEN lk_n ELSE 0 END) AS flag_var
  FROM firstname_matches"))
cat(sprintf("  qualquer match : %s (%.2f%% de %s)\n",
            format(rate$flag_all, big.mark = ","),
            100 * rate$flag_all / n_rows, format(n_rows, big.mark = ",")))
cat(sprintf("  canonico       : %s (%.2f%%)\n", format(rate$flag_canon, big.mark = ","),
            100 * rate$flag_canon / n_rows))
cat(sprintf("  variante       : %s (%.2f%%)\n", format(rate$flag_var, big.mark = ","),
            100 * rate$flag_var / n_rows))

for (v in list(c("qualquer", rate$flag_all, exp_flag_all),
               c("canonico", rate$flag_canon, exp_flag_canon))) {
  d <- abs(as.numeric(v[2]) - as.numeric(v[3])) / as.numeric(v[3])
  cat(sprintf("  regressao %-8s: esperado %s, obtido %s, desvio %.4f%% %s\n",
              v[1], format(as.numeric(v[3]), big.mark = ","),
              format(as.numeric(v[2]), big.mark = ","), 100 * d,
              ifelse(d < 0.01, "[OK]", "[DESVIO]")))
  if (d >= 0.01) warning("Taxa de match ", v[1], " divergiu mais de 1% do medido.")
}

cat("\n=========== MAIS SUPER-REPRESENTADOS NO LINKEDIN (ratio) ===========\n")
cat("(nomes globalmente comuns que inflam o flag; min 200k linhas)\n")
print(dbGetQuery(con, "
  SELECT first_name_clean AS nome, lk_n, ibge_freq, match_level,
         round(ratio, 1) AS ratio, round(p_brazil, 6) AS p_brazil
  FROM firstname_matches
  WHERE flag_exact AND lk_n >= 200000
  ORDER BY ratio DESC LIMIT 40"), row.names = FALSE)

cat("\n=========== MAIORES MOTORES ABSOLUTOS DO FLAG (excesso) ===========\n")
print(dbGetQuery(con, sprintf("
  SELECT first_name_clean AS nome, lk_n, ibge_freq, match_level,
         round(ratio, 1) AS ratio,
         round((lk_n - ibge_share * %.1f) / 1e6, 2) AS excesso_M
  FROM firstname_matches WHERE flag_exact
  ORDER BY (lk_n - ibge_share * %.1f) DESC LIMIT 30", lk_total, lk_total)),
  row.names = FALSE)

cat("\n=========== MAIS DISTINTIVAMENTE BRASILEIROS ===========\n")
print(dbGetQuery(con, "
  SELECT first_name_clean AS nome, lk_n, ibge_freq, match_level,
         round(ratio, 4) AS ratio, round(p_brazil, 4) AS p_brazil
  FROM firstname_matches
  WHERE flag_exact AND ibge_freq >= 50000
  ORDER BY ratio ASC LIMIT 25"), row.names = FALSE)

cat("\n=========== CONCENTRACAO ===========\n")
print(dbGetQuery(con, sprintf("
  WITH o AS (SELECT lk_n, row_number() OVER (ORDER BY lk_n DESC) AS rn
             FROM firstname_matches WHERE flag_exact)
  SELECT round(100.0 * sum(CASE WHEN rn <= 10  THEN lk_n ELSE 0 END) / %.1f, 1) AS top10_pct,
         round(100.0 * sum(CASE WHEN rn <= 100 THEN lk_n ELSE 0 END) / %.1f, 1) AS top100_pct,
         round(100.0 * sum(CASE WHEN rn <= 500 THEN lk_n ELSE 0 END) / %.1f, 1) AS top500_pct
  FROM o", rate$flag_all, rate$flag_all, rate$flag_all)), row.names = FALSE)

cat("\n=========== A EXPANSAO POR VARIANTES SE JUSTIFICOU? ===========\n")
cat("(quanto do acrescimo de variantes e ruido de ratio alto vs grafia BR legitima)\n")
print(dbGetQuery(con, "
  SELECT match_level,
         count(*)      AS n_tokens,
         sum(lk_n)     AS linhas,
         sum(CASE WHEN ratio > 5 THEN lk_n ELSE 0 END) AS linhas_ratio_gt5,
         round(100.0 * sum(CASE WHEN ratio > 5 THEN lk_n ELSE 0 END)
               / nullif(sum(lk_n), 0), 1) AS pct_ruido,
         round(median(ratio), 2) AS ratio_mediano
  FROM firstname_matches WHERE flag_exact
  GROUP BY match_level ORDER BY match_level"), row.names = FALSE)

cat("\n=========== SANIDADE DO SCORE ===========\n")
print(dbGetQuery(con, "
  SELECT first_name_clean AS nome, match_level, lk_n, ibge_freq,
         round(ratio, 4) AS ratio, round(p_brazil, 6) AS p_brazil
  FROM firstname_matches
  WHERE first_name_clean IN ('raimunda','terezinha','eloa','maria','marya',
                             'mariah','chris','steve','mark')
  ORDER BY p_brazil DESC"), row.names = FALSE)

####################################################################
### Passo 4: saida no nivel do perfil (loop pelos 20 arquivos)
####################################################################

# Um arquivo de saida por arquivo de entrada: limita memoria, espelha o
# layout de origem e torna o job reinicializavel apos interrupcao --
# mesmo raciocinio do loop de buckets em 1-merge_cpf_masc.R.
#
# Sem coluna com o nome casado: no match exato o token casado e igual a
# first_name_clean sempre que flag_exact e TRUE, e carregar a copia
# duplicaria uma coluna de texto por 708M linhas sem ganho.
cat("\n=========== ESCREVENDO SAIDA NO NIVEL DO PERFIL ===========\n")
for (i in seq_len(n_chunks)) {
  fin  <- file.path(lk_dir, sprintf("linkedin_chunk_%d.parquet", i))
  fout <- file.path(prof_dir, sprintf("chunk_%02d.parquet", i))
  if (file.exists(fout)) { cat(sprintf("  [skip] chunk_%02d\n", i)); next }
  if (!file.exists(fin)) stop("Arquivo de entrada ausente: ", fin)

  t0 <- Sys.time()
  dbExecute(con, sprintf("
    COPY (
      SELECT l.user_id,
             l.fn AS first_name_clean,
             coalesce(m.flag_exact, FALSE) AS flag_exact,
             m.match_level, m.ibge_freq, m.canon_rank, m.p_brazil
      FROM (SELECT user_id, %s AS fn FROM read_parquet('%s')) l
      LEFT JOIN read_parquet('%s') m ON l.fn = m.first_name_clean
    ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    first_expr, fin, path_matches, fout))
  cat(sprintf("  chunk_%02d escrito em %.1f s\n", i,
              as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}

####################################################################
### Passo 5: reconciliacao final
####################################################################

cat("\n=========== RECONCILIACAO ===========\n")
rec <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_rows, count(DISTINCT user_id) AS n_users,
         sum(flag_exact::INT) AS n_flag
  FROM read_parquet('%s/chunk_*.parquet')", prof_dir))
cat(sprintf("  linhas na saida : %s (esperado %s) %s\n",
            format(rec$n_rows, big.mark = ","), format(exp_rows, big.mark = ","),
            ifelse(rec$n_rows == exp_rows, "[OK]", "[FALHA]")))
cat(sprintf("  user_id unicos  : %s %s\n", format(rec$n_users, big.mark = ","),
            ifelse(rec$n_users == rec$n_rows, "[OK]", "[FALHA - fan-out]")))
cat(sprintf("  sinalizados     : %s (%.2f%%)\n", format(rec$n_flag, big.mark = ","),
            100 * rec$n_flag / rec$n_rows))

if (rec$n_rows != exp_rows) stop("Reconciliacao falhou: contagem de linhas.")
if (rec$n_users != rec$n_rows) stop("Reconciliacao falhou: fan-out no join.")

cat("\nSaidas em:", out_dir, "\n")
