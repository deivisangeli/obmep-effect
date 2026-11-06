####################################################################
###
### Matcher de university_raw -> OpenAlex, sem rsid          [local only]
###
### Casa a grafia livre university_raw contra o snapshot inteiro do
### OpenAlex (120.658 instituicoes) para a populacao que 8h/8i nao
### alcancam: 805.913 linhas sem rsid E sem university_name.
###
### O gabarito do dev vem de norsid_raw_match_sample.R (8k) e esta
### CONGELADO antes de qualquer braco existir. Este script so pontua.
###
### -----------------------------------------------------------------
### O TETO E 44%, E ISSO E O RESULTADO PRINCIPAL
### -----------------------------------------------------------------
### Rotulado o dev de 100 linhas contra o snapshot:
###
###   openalex_id real   44 linhas
###   NONE               51 linhas   <- nao existe no OpenAlex
###   AMBIGUOUS           5 linhas
###
### Mais da metade destas entradas nomeia instituicao que simplesmente
### NAO ESTA no snapshot -- faculdades privadas pequenas como FABAVI,
### Facid, Faneesp, PROMINAS, Pitagoras, Iteq. Nenhuma estrategia de
### casamento pode passar de 44% de recall aqui. A pergunta nao e
### "quanto da para alcancar" e sim "quanto do teto da para alcancar
### sem inventar casamento".
###
### As grafias mais frequentes da populacao (UNIP, UFRJ, Uninove) sao
### universidades grandes e resolviveis, mas o sorteio e por LINHA e a
### cauda domina: 224.643 das 293.940 grafias aparecem uma unica vez.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Le parquets e CSV locais. Ainda e prep/; nao SEDAP.
### 2. O GABARITO E CONGELADO. Este script RECUSA rodar se houver rotulo
###    em branco e NUNCA escreve no gabarito. Rotular depois de ver o
###    que o matcher diz seria ajustar o gabarito ao matcher.
### 3. HOLDOUT PONTUA UMA VEZ, com OBMEP_NORSID_MODE=holdout, e so
###    depois de a configuracao estar congelada. A diferenca dev-holdout
###    e a unica estimativa honesta de superajuste que este desenho tem.
### 4. NENHUM BRACO PODE EMITIR ID QUE NAO EXISTA no snapshot. Afirmado
###    contra oa_institution_cache.parquet, como no 8i.
### 5. A REGRA DE DONO UNICO (HAVING count(DISTINCT oa_id) = 1) governa
###    todos os bracos de igualdade. E o dispositivo padrao da pasta
###    (16a:196-218, 16b:179-213) e e o que impede "Ludwig Cancer
###    Research" -- SEIS registros homonimos em BE/GB/CH/SE/US/AU -- de
###    virar casamento arbitrario.
### 6. O BRACO DE SIGLA E DESLIGADO POR PADRAO. 16a mediu revisao a mao
###    de 209 siglas: 104 OK, 85 WRONG, 20 AMBIGUOUS -- errado em cerca
###    de metade das grafias. Falhas reais registradas la: unime ->
###    University of Messina (e faculdade da Bahia), unb -> "Nazi Boni
###    University", puc, unam, unisc, uea. Este braco existe, mede-se
###    em separado, e so liga com OBMEP_NORSID_ACRONYM=1.
### 7. SEM VETO DE PAIS. 16a testou e DESCARTOU: dispara 3 vezes em 209
###    e 2 das 3 estao erradas (README:4124-4130). university_country e
###    campo da Revelio e nao e confiavel.
### 8. O SEPARADOR '|' EXISTE E FOI DESCOBERTO NA ROTULAGEM. A grafia
###    "Centro Universitario Vale do Iguacu | Uniguacu" usa '|', que os
###    scripts 8a e 16 nao dividem. O braco de segmento aqui divide
###    '/', '(', ')', '|' e ' - '. Sem isso a grafia nao se parte.
### 20. TRAVESSAO NAO E HIFEN, e a rodada 1 nao dividia nele. A grafia
###    "Centro Universitario Geraldo di Biase - UGB" usa EN DASH
###    (U+2013), nao hifen, e por isso nao se partia. Normaliza-se
###    U+2013 e U+2014 para hifen ANTES de dividir, via chr(8211) e
###    chr(8212) para o arquivo seguir ASCII puro. Hifen SEM espaco
###    continua nao dividindo -- "Unilasalle-RJ" partido daria
###    "unilasalle", que casa a UniLaSalle francesa, e "Semi-Arido"
###    perderia o nome.
### 21. O BRACO core EXIGE DUAS PALAVRAS, e essa e a correcao mais
###    importante da rodada 2. Sem isso ele cai na mesma homonimia de
###    token unico que derrubou o braco idf na rodada 1: medido no dev2,
###    os QUATRO erros do braco vieram de chave de uma palavra --
###    "Asser", "Gamaliel", "Unilasalle-RJ" e "LS educacional". Uma
###    palavra sobrando depois de tirar as genericas nao e evidencia.
### 22. O BRACO mojibake TROCA u00XX PELA LETRA SEM ACENTO, nao pela
###    letra acentuada. Como a dobra ja passa strip_accents, decodificar
###    u00e1 para 'a' da o mesmo resultado com uma cadeia de replace()
###    em vez de uma tabela Unicode. Medido: 8.614 linhas e 1.892
###    grafias da populacao trazem essas sequencias.
### 23. O BRACO parent MAPEIA FACULDADE PARA A UNIVERSIDADE-MAE, e isso
###    e escolha semantica, nao acidente. Os rotulos da rodada 1 ja
###    tinham feito essa escolha (FEUP -> Universidade do Porto, FCT
###    NOVA -> Universidade Nova de Lisboa), entao o braco apenas
###    mecaniza o que o gabarito ja afirmava. 14.067 linhas da
###    populacao trazem a frase da universidade-mae.
### 24. O BRACO prefix TIRA RUIDO DA ESQUERDA. "Fundacao Universidade
###    Federal do Vale do Sao Francisco" e "cursando Administracao de
###    Empresas Faculdade de Itaituba" so casam depois de soltar
###    palavras iniciais. Exige resto com 2+ palavras e 10+ caracteres,
###    para nao virar casamento por sufixo generico.
### 9. jw NAO E RANKER, so desempate. Jaro-Winkler premia o prefixo
###    longo que todo nome brasileiro tem -- medido no 8i, custou a
###    resposta certa em Estacio de Sa, UNIASSELVI e UniFatecie. O
###    ranker e cobertura de token ponderada por IDF.
###
####################################################################

rm(list = ls()); gc()
options(width = 200)

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
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

dev_pq   <- file.path(coh_dir, "norsid_match_dev.parquet")
hold_pq  <- file.path(coh_dir, "norsid_match_holdout.parquet")
lab_csv  <- file.path(coh_dir, "norsid_match_labels.csv")
hlab_csv <- file.path(coh_dir, "norsid_match_labels_holdout.csv")
inst_pq  <- file.path(coh_dir, "oa_institution_cache.parquet")
cand_pq  <- file.path(coh_dir, "oa_institution_cand_names.parquet")

# Nota 19: cinco modos. 'regression' junta os 300 da rodada 1 -- o
# holdout1 esta GASTO (a nota dele foi reportada) e por isso vale como
# regressao, medida a cada iteracao e nunca otimizada. 'dev2' e onde a
# rodada 2 itera; 'holdout2' pontua UMA vez, no fim.
mode <- tolower(Sys.getenv("OBMEP_NORSID_MODE", unset = "dev2"))
mode_sets <- list(
  dev        = "dev",
  holdout    = "holdout",
  regression = c("dev", "holdout"),
  dev2       = "dev2",
  holdout2   = "holdout2")
if (!mode %in% names(mode_sets)) {
  stop("OBMEP_NORSID_MODE: ", paste(names(mode_sets), collapse = ", "))
}
lab_file <- c(dev = "norsid_match_labels.csv",
              holdout = "norsid_match_labels_holdout.csv",
              dev2 = "norsid_match_labels_dev2.csv",
              holdout2 = "norsid_match_labels_holdout2.csv")

use_acronym <- nzchar(Sys.getenv("OBMEP_NORSID_ACRONYM"))  # nota 6
idf_floor   <- as.numeric(Sys.getenv("OBMEP_NORSID_IDF_FLOOR", unset = "0.90"))
# Nota 12: o PISO ABSOLUTO de IDF compartilhado e o que separa casamento
# de coincidencia. Sem ele, uma grafia cujo token distintivo nao existe
# no OpenAlex ("Faculdade Promove") tira cobertura 1,0 dos tokens
# genericos que sobraram -- 19 de 26 propostas do braco idf estavam
# erradas assim. ln(120658/1) = 11,7, entao 8,0 exige ao menos um token
# genuinamente raro em comum.
idf_min_sh  <- as.numeric(Sys.getenv("OBMEP_NORSID_IDF_MINSH", unset = "8.0"))
# Nota 16: a COBERTURA E BIDIRECIONAL, e e ela que separa casamento de
# homonimia de um token. Com stoplist, "Faculdade Jardins" cobre 100%
# da propria sonda com o unico token 'jardins' -- e casa "Jardins
# botaniques du Grand Nancy", de que cobre 20%. Exigir que a sonda
# cubra tambem o CANDIDATO derruba esse caso e preserva "Sumare" ->
# "Faculdade Sumare", onde as duas coberturas sao 1,0. O piso do
# candidato e mais baixo de proposito: nomes do OpenAlex trazem palavra
# extra ("Community University of Chapeco Region - Unochapeco") que a
# grafia digitada nao tem.
idf_cand_floor <- as.numeric(Sys.getenv("OBMEP_NORSID_CAND_FLOOR",
                                        unset = "0.50"))

# Nota 13: a sonda do braco idf precisa de STOPLIST. Sem ela "centro" e
# "universitario" entram no denominador e diluem a cobertura, jogando
# casamento real abaixo do piso -- "Centro universitario edmundo ulson"
# e "Universidade Comunitaria da Regiao de Chapeco- Unochapeco" foram
# perdidos assim, apesar de 'ulson' e 'unochapeco' serem tokens raros e
# compartilhados. E a mesma lista que o auxiliar de rotulagem usa.
stop_tok <- c("faculdade","faculdades","centro","universitario","universitaria",
  "universidade","instituto","institute","ensino","superior","educacional",
  "educacao","university","college","school","schools","faculty","tecnologia",
  "ciencias","ciencia","estudos","integradas","integrado","unidas","grupo",
  "associacao","fundacao","sociedade","escola","curso","cursos","campus",
  "brasil","brasileira","brasileiro","santa","santo","sao","nossa","senhora",
  "estadual","federal","municipal","nacional","regional","metropolitana",
  "center","centre","virtual","online","distancia","unidade","polo")

min_seg <- 3L      # 8a e 16 usam 3
min_tok <- 4L      # 8i
max_df  <- 3000L   # 8i

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "10GB")
tmp_dir   <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_norsid_match")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(file.exists(dev_pq), file.exists(hold_pq), file.exists(inst_pq),
          file.exists(cand_pq))
fw <- function(z) gsub("'", "''", z)

####################################################################
### Step 0 -- o gabarito, congelado (nota 2)
####################################################################

if (mode == "holdout2") {
  cat("*** MODO HOLDOUT2: pontuar UMA vez, com a configuracao congelada.\n")
}
which_sets <- mode_sets[[mode]]
set_pq <- file.path(coh_dir, sprintf("norsid_match_%s.parquet", which_sets))
lab_str <- do.call(rbind, lapply(which_sets, function(nm) {
  f <- file.path(coh_dir, lab_file[[nm]])
  if (!file.exists(f)) {
    stop("Gabarito ausente: ", basename(f), ". Rode o 8k e rotule antes.")
  }
  x <- read.csv(f, stringsAsFactors = FALSE, fileEncoding = "UTF-8")
  x$label <- trimws(ifelse(is.na(x$label), "", x$label))
  x$label_name <- ifelse(is.na(x$label_name), "", x$label_name)
  if (!"seen_in_round1" %in% names(x)) x$seen_in_round1 <- 0L
  x[, c("university_raw", "label", "label_name", "seen_in_round1")]
}))
if (any(!nzchar(lab_str$label))) {
  n <- sum(!nzchar(lab_str$label))
  cat("\nFaltam rotular (as 10 maiores):\n")
  b <- lab_str[!nzchar(lab_str$label), ]
  print(head(b[, c("university_raw")], 10))
  stop(n, " grafia(s) do gabarito sem rotulo (nota 2).")
}

####################################################################
### Conexao e indices
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

# A dobra padrao da pasta, identica a de 16, 16a, 16b, 19, 20 e 8i.
dbExecute(con, "CREATE MACRO fs(s) AS lower(strip_accents(trim(s)))")

# Nota 20: travessao para hifen antes de qualquer divisao.
dbExecute(con, "
CREATE MACRO dsh(s) AS replace(replace(s, chr(8211), '-'), chr(8212), '-')")

# Nota 22: u00XX vira a letra SEM acento -- a dobra ja tira acento.
dbExecute(con, "
CREATE MACRO mj(s) AS
  replace(replace(replace(replace(replace(replace(replace(replace(
  replace(replace(replace(replace(replace(replace(replace(replace(s,
    'u00e0','a'),'u00e1','a'),'u00e2','a'),'u00e3','a'),'u00e4','a'),
    'u00e7','c'),'u00e8','e'),'u00e9','e'),'u00ea','e'),'u00ec','i'),
    'u00ed','i'),'u00f3','o'),'u00f4','o'),'u00f5','o'),'u00fa','u'),
    'u00fc','u')")
# Nota 10: core() e CHAVE DE TOKENS ORDENADOS, nao regex. A primeira
# versao escreveu a alternancia em varias linhas e o literal levou
# quebra de linha e indentacao como alternativas -- o padrao casava
# espaco em branco e nada mais. Filtrar e ORDENAR tokens tambem faz
# "Centro Universitario Augusto Motta" e "University Center Augusto
# Motta" convergirem, que a substituicao textual nao fazia.
type_tok <- c("universidade","university","universidad","universitario",
  "universitaria","universitario","faculdade","faculdades","instituto",
  "institute","institucao","escola","school","college","centro","center",
  "centre","ensino","superior","educacional","educational","the","del",
  "estadual","federal","state","nacional","national",
  # Nota 14: grafias ERRADAS da propria palavra de tipo entram aqui, e
  # nao e caso particular: "Univercidade Candido Mendes" e "Federal
  # Universitiy of Goias" erram a palavra generica, nao o nome. Manter
  # curto e deliberado -- cada entrada nova e risco de superajuste.
  "univercidade","universitiy","univesidade","faculadade")
dbExecute(con, sprintf("
CREATE MACRO core_tok(s) AS list_sort(list_filter(
  string_split_regex(fs(s), '[^a-z0-9]+'),
  x -> length(x) >= 3 AND NOT list_contains(['%s'], x)))",
  paste(type_tok, collapse = "','")))
dbExecute(con, "CREATE MACRO core(s) AS array_to_string(core_tok(s), ' ')")
# Nota 21: quantas palavras distintivas sobraram. Uma nao basta.
dbExecute(con, "CREATE MACRO core_n(s) AS len(core_tok(s))")

dbExecute(con, sprintf(
  "CREATE OR REPLACE VIEW ins AS SELECT * FROM read_parquet('%s')", fw(inst_pq)))
dbExecute(con, sprintf(
  "CREATE OR REPLACE VIEW cand AS SELECT * FROM read_parquet('%s')", fw(cand_pq)))

# Nota 5: dono unico em todo indice de igualdade.
dbExecute(con, "
CREATE OR REPLACE TABLE ix_name AS
SELECT nm, any_value(oa_id) AS oa_id
FROM cand WHERE nm IS NOT NULL AND length(nm) >= 2
GROUP BY nm HAVING count(DISTINCT oa_id) = 1")

dbExecute(con, "
CREATE OR REPLACE TABLE ix_core AS
SELECT core(display_name) AS ck, any_value(oa_id) AS oa_id
FROM ins WHERE display_name IS NOT NULL AND length(core(display_name)) >= 4
GROUP BY core(display_name) HAVING count(DISTINCT oa_id) = 1")

dbExecute(con, "
CREATE OR REPLACE TABLE tokdf AS
SELECT tok, count(DISTINCT oa_id) AS df FROM (
  SELECT DISTINCT oa_id, unnest(string_split_regex(nm, '[^a-z0-9]+')) AS tok
  FROM cand
) WHERE length(tok) >= 4 GROUP BY tok")
n_inst <- dbGetQuery(con, "SELECT count(*) AS n FROM ins")$n

# Nota 18: A PONTUACAO E POR LINHA DE EDUCACAO, nos dois modos. O
# gabarito do dev ja e por linha (100 linhas, 98 grafias); o do holdout
# e por GRAFIA (197), entao expande-se para as 200 linhas antes de
# pontuar. Sem isso o dev sairia por linha e o holdout por grafia, e a
# diferenca dev-holdout -- o unico numero que mede superajuste --
# compararia coisas diferentes.
lab <- do.call(rbind, lapply(set_pq, function(f) dbGetQuery(con, sprintf(
  "SELECT university_raw FROM read_parquet('%s')", fw(f)))))
# Chave UNICA por grafia antes do join: o gabarito do dev ja tem uma
# linha por linha de educacao, entao juntar sem deduplicar multiplicaria
# as grafias repetidas (2 x 2 = 4). Um rotulo por grafia, por construcao.
key <- unique(lab_str[, c("university_raw", "label", "label_name",
                          "seen_in_round1")])
if (anyDuplicated(key$university_raw) > 0L) {
  stop("a mesma grafia tem rotulos diferentes no gabarito.")
}
lab <- merge(lab, key, by = "university_raw", all.x = TRUE)
if (any(is.na(lab$label))) {
  cat("Sem rotulo:\n"); print(unique(lab$university_raw[is.na(lab$label)]))
  stop(sum(is.na(lab$label)), " linha(s) sem rotulo apos a expansao.")
}
cat(sprintf("gabarito: %d grafias -> %d linhas de educacao\n",
            nrow(key), nrow(lab)))

####################################################################
### Step 1 -- as grafias a casar
####################################################################

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE s AS
SELECT DISTINCT university_raw, fs(university_raw) AS rf
FROM read_parquet(['%s'])", paste(fw(set_pq), collapse = "','")))

# Nota 8 e nota 20: separadores / ( ) | e ' - ', com travessao
# normalizado para hifen antes de dividir.
dbExecute(con, sprintf("
CREATE OR REPLACE TABLE seg AS
SELECT DISTINCT university_raw, trim(part) AS part FROM (
  SELECT university_raw, unnest(string_split_regex(
           regexp_replace(regexp_replace(dsh(rf), '[/()|]', '#', 'g'),
                          ' - ', '#', 'g'), '#')) AS part
  FROM s
) WHERE length(trim(part)) >= %d", min_seg))

# Nota 22: forma decodificada, so onde o decode mudou algo.
dbExecute(con, "
CREATE OR REPLACE TABLE mjs AS
SELECT university_raw, mj(rf) AS mf FROM s WHERE mj(rf) <> rf")

# Nota 23: a universidade-mae, extraida por frase.
dbExecute(con, "
CREATE OR REPLACE TABLE par AS
SELECT university_raw, base FROM (
  SELECT university_raw,
         CASE
           WHEN regexp_matches(rf, ' d[ao]s? universidade d[aeo]s? ')
             THEN 'universidade ' || regexp_extract(rf,
                  ' d[ao]s? universidade (d[aeo]s? .+)$', 1)
           WHEN regexp_matches(rf, '(^|[^a-z])university of ')
             THEN 'university of ' || regexp_extract(rf,
                  'university of (.+)$', 1)
           WHEN regexp_matches(rf, '(^|[^a-z])universidad de ')
             THEN 'universidad de ' || regexp_extract(rf,
                  'universidad de (.+)$', 1)
         END AS base
  FROM s
) WHERE base IS NOT NULL AND length(base) >= 12")

# Nota 24: sufixos, soltando 1..5 palavras da esquerda.
dbExecute(con, "
CREATE OR REPLACE TABLE pre AS
SELECT DISTINCT university_raw, base FROM (
  SELECT university_raw,
         array_to_string(t[i + 1 : len(t)], ' ') AS base
  FROM (SELECT university_raw, string_split_regex(dsh(rf), ' +') AS t FROM s),
       (SELECT unnest([1, 2, 3, 4, 5]) AS i)
  WHERE len(t) - i >= 2
)
WHERE length(base) >= 10")

# Sufixo de campus (13a: 11,2%). Nota 11: a primeira versao usava
# '( de | - | )[a-z ]{3,20}$', que arrancava QUALQUER cauda -- "Centro
# Universitario UNIRB" virava "Centro Universitario" e casava um centro
# qualquer, 4 erros em 6 propostas. Agora exige separador explicito
# (' de ' ou ' - ' ou '- '), UMA palavra de lugar, e base longa.
# Nota 15: o lugar pode ter DUAS palavras ("- Isabela Campus",
# "de Sao Paulo"), entao gera-se uma base por comprimento de cauda e o
# braco aceita qualquer uma que case -- mais longa primeiro.
dbExecute(con, "
CREATE OR REPLACE TABLE camp AS
SELECT university_raw, base FROM (
  SELECT university_raw,
         trim(regexp_replace(rf, '( de | -+ ?)[a-z]+$', '')) AS base FROM s
  UNION ALL
  SELECT university_raw,
         trim(regexp_replace(rf, '( de | -+ ?)[a-z]+ [a-z]+$', '')) AS base FROM s
) WHERE length(base) >= 6")

####################################################################
### Step 2 -- os bracos
####################################################################

arm_sql <- list(
  whole = "SELECT s.university_raw, i.oa_id FROM s JOIN ix_name i ON i.nm = s.rf",
  segment = "
    SELECT g.university_raw, any_value(i.oa_id) AS oa_id
    FROM seg g JOIN ix_name i ON i.nm = g.part
    GROUP BY g.university_raw HAVING count(DISTINCT i.oa_id) = 1",
  core = "
    SELECT s.university_raw, c.oa_id
    FROM s JOIN ix_core c ON c.ck = core(s.university_raw)
    WHERE length(core(s.university_raw)) >= 4
      AND core_n(s.university_raw) >= 2",
  mojibake = "
    SELECT m.university_raw, any_value(i.oa_id) AS oa_id
    FROM mjs m JOIN ix_name i ON i.nm = m.mf
    GROUP BY m.university_raw HAVING count(DISTINCT i.oa_id) = 1",
  parent = "
    SELECT p.university_raw, any_value(i.oa_id) AS oa_id
    FROM par p JOIN ix_name i ON i.nm = p.base
    GROUP BY p.university_raw HAVING count(DISTINCT i.oa_id) = 1",
  prefix = "
    SELECT university_raw, oa_id FROM (
      SELECT p.university_raw, i.oa_id,
             row_number() OVER (PARTITION BY p.university_raw
                                ORDER BY length(p.base) DESC) AS rk,
             count(DISTINCT i.oa_id) OVER (PARTITION BY p.university_raw) AS n_oa
      FROM pre p JOIN ix_name i ON i.nm = p.base
    ) WHERE rk = 1 AND n_oa = 1",
  campus = "
    SELECT c.university_raw, i.oa_id
    FROM camp c JOIN ix_name i ON i.nm = c.base
    WHERE length(c.base) >= 6
    QUALIFY row_number() OVER (PARTITION BY c.university_raw
                               ORDER BY length(c.base) DESC) = 1",
  idf = sprintf("
    WITH pt AS (
      SELECT DISTINCT university_raw, tok FROM (
        SELECT university_raw,
               unnest(string_split_regex(rf, '[^a-z0-9]+')) AS tok FROM s
      ) WHERE length(tok) >= %d AND tok NOT IN ('%s')
    ),
    w AS (SELECT p.university_raw, sum(ln(%f / coalesce(d.df, 1))) AS tot
          FROM pt p LEFT JOIN tokdf d USING (tok) GROUP BY 1),
    -- lado do candidato: por NOME, nao por instituicao, porque cada
    -- grafia alternativa tem o seu proprio conjunto de tokens.
    nmt AS (
      SELECT DISTINCT oa_id, nm, tok FROM (
        SELECT oa_id, nm, unnest(string_split_regex(nm, '[^a-z0-9]+')) AS tok
        FROM cand
      ) WHERE length(tok) >= %d AND tok NOT IN ('%s')
    ),
    nw AS (SELECT oa_id, nm, sum(ln(%f / coalesce(d.df, 1))) AS ntot
           FROM nmt LEFT JOIN tokdf d USING (tok) GROUP BY 1, 2),
    hit AS (SELECT p.university_raw, n.oa_id, n.nm,
                   sum(ln(%f / d.df)) AS sh
            FROM pt p JOIN nmt n USING (tok) JOIN tokdf d USING (tok)
            WHERE d.df <= %d GROUP BY 1, 2, 3),
    sc AS (SELECT h.university_raw, h.oa_id, h.sh,
                  h.sh / nullif(w.tot, 0)  AS cov,
                  h.sh / nullif(nw.ntot, 0) AS cov_cand
           FROM hit h JOIN w USING (university_raw)
                      JOIN nw ON nw.oa_id = h.oa_id AND nw.nm = h.nm)
    SELECT university_raw, oa_id FROM (
      SELECT university_raw, oa_id,
             row_number() OVER (PARTITION BY university_raw
               ORDER BY cov DESC, cov_cand DESC, sh DESC, oa_id) AS rk
      FROM (SELECT university_raw, oa_id, max(cov) AS cov,
                   max(cov_cand) AS cov_cand, max(sh) AS sh
            FROM sc WHERE cov >= %f AND sh >= %f AND cov_cand >= %f
            GROUP BY 1, 2)
    ) WHERE rk = 1", min_tok, paste(stop_tok, collapse = "','"),
       n_inst, min_tok, paste(stop_tok, collapse = "','"),
       n_inst, n_inst, max_df, idf_floor, idf_min_sh, idf_cand_floor)
)

# Nota 17: os bracos de IGUALDADE (whole/segment/core/campus) formam a
# configuracao CONSERVADORA e sao o padrao. O braco idf mediu 40% de
# precisao no dev -- compra 2 certos por 3 errados -- entao recebe o
# mesmo tratamento que o de sigla: proposta guardada, nao aceita por
# padrao. O script pontua as duas configuracoes e imprime as duas, para
# que a troca fique explicita em vez de escolhida em silencio.
# Nota 25: o braco prefix FICA FORA DO PADRAO. Mediu 2/2 no dev2 mas
# 0/1 na regressao -- "ITEPA BIBLE COLLEGE" solta as palavras iniciais,
# sobra "bible college", e casa um Bible College qualquer. 2 de 3 em 500
# linhas nao chega perto do que os outros bracos mostram (100%, 97%,
# 90%, 100%), e calibrar um piso contra o erro da REGRESSAO seria usar
# para escolher o conjunto que existe para vetar. Entao entra no grupo
# guardado-mas-nao-aceito, junto de idf e sigla, e liga com
# OBMEP_NORSID_PREFIX=1.
arm_cons <- c("whole", "segment", "core", "campus", "mojibake", "parent")
use_prefix <- nzchar(Sys.getenv("OBMEP_NORSID_PREFIX"))
arm_order <- arm_cons
if (use_prefix)  arm_order <- c(arm_order, "prefix")
if (use_acronym) arm_order <- c(arm_order, "acronym")
arm_order <- c(arm_order, "idf")

if (use_acronym) {
  dbExecute(con, "
  CREATE OR REPLACE TABLE ix_acr AS
  SELECT nm, any_value(oa_id) AS oa_id FROM cand
  WHERE nm IS NOT NULL AND length(nm) BETWEEN 2 AND 12
  GROUP BY nm HAVING count(DISTINCT oa_id) = 1")
  arm_sql$acronym <-
    "SELECT s.university_raw, a.oa_id FROM s JOIN ix_acr a ON a.nm = s.rf"
}

res <- list()
for (a in arm_order) {
  d <- dbGetQuery(con, arm_sql[[a]])
  d <- d[!is.na(d$oa_id), c("university_raw", "oa_id"), drop = FALSE]
  # Braco que nao dispara devolve 0 linhas, e atribuir escalar a
  # data.frame vazia e erro em R -- monta explicitamente.
  res[[a]] <- data.frame(university_raw = d$university_raw,
                         oa_id = d$oa_id,
                         arm = rep(a, nrow(d)),
                         stringsAsFactors = FALSE)
}
prop <- do.call(rbind, res)
if (nrow(prop) == 0L) stop("nenhum braco disparou -- verifique os indices.")

# Nota 4: nenhum id inventado.
known <- dbGetQuery(con, sprintf(
  "SELECT DISTINCT oa_id FROM ins WHERE oa_id IN ('%s')",
  paste(unique(prop$oa_id), collapse = "','")))$oa_id
ghost <- setdiff(unique(prop$oa_id), known)
if (length(ghost) > 0L) {
  stop(length(ghost), " id(s) propostos nao existem no snapshot (nota 4).")
}

####################################################################
### Step 3 -- pontuar contra o gabarito congelado
####################################################################

score_one <- function(sub) {
  fired <- !is.na(sub$oa_id)
  ok    <- fired & sub$oa_id == sub$label
  data.frame(
    proposto = sum(fired), correto = sum(ok), errado = sum(fired & !ok),
    precisao = ifelse(sum(fired) > 0, sum(ok) / sum(fired), NA_real_),
    stringsAsFactors = FALSE)
}

# Precedencia: primeiro braco que fala, ganha.
resolve <- function(arms) {
  q <- prop[prop$arm %in% arms, ]
  q$pri <- match(q$arm, arms)
  q <- q[order(q$pri), ]
  q <- q[!duplicated(q$university_raw), ]
  cols <- intersect(c("university_raw", "label", "label_name",
                      "seen_in_round1"), names(lab))
  merge(lab[, cols],
        q[, c("university_raw", "oa_id", "arm")],
        by = "university_raw", all.x = TRUE)
}

ev        <- resolve(arm_order)
ceiling_n <- sum(!ev$label %in% c("NONE", "AMBIGUOUS"))

tab <- do.call(rbind, lapply(arm_order, function(a) {
  s1 <- score_one(ev[!is.na(ev$arm) & ev$arm == a, ]); s1$braco <- a; s1
}))
tab$recall_marginal <- tab$correto / ceiling_n
tab <- tab[, c("braco", "proposto", "correto", "errado", "precisao",
               "recall_marginal")]

cfg <- list(conservadora = arm_cons,
            `+ prefix` = c(arm_cons, "prefix"),
            `com idf` = arm_order)
if (use_acronym) cfg[["com idf + sigla"]] <- arm_order
cmp <- do.call(rbind, lapply(names(cfg), function(k) {
  e <- resolve(cfg[[k]]); z <- score_one(e)
  data.frame(config = k, proposto = z$proposto, correto = z$correto,
             errado = z$errado,
             precisao = z$precisao, recall = z$correto / ceiling_n,
             stringsAsFactors = FALSE)
}))

# O padrao e a conservadora (nota 17).
ev  <- resolve(arm_cons)
tot <- score_one(ev)
tot_recall <- tot$correto / ceiling_n

# Onde os erros caem: id trocado, ou casou algo que era NONE?
err <- ev[!is.na(ev$oa_id) & ev$oa_id != ev$label, ]
err$tipo <- ifelse(err$label == "NONE", "casou o que nao existe",
                   ifelse(err$label == "AMBIGUOUS", "casou o ambiguo",
                          "id trocado"))

####################################################################
### Relatorio
####################################################################

cat("\n==================================================================\n")
cat(sprintf("Matcher university_raw -> OpenAlex, modo %s\n", toupper(mode)))
cat("==================================================================\n\n")
cat(sprintf("  linhas no conjunto  : %d (em %d grafias)\n",
            nrow(lab), nrow(lab_str)))
cat(sprintf("  TETO (resolviveis)  : %d de %d (%.0f%%)\n",
            ceiling_n, nrow(ev), 100 * ceiling_n / nrow(ev)))
cat(sprintf("  NONE                : %d\n", sum(ev$label == "NONE")))
cat(sprintf("  AMBIGUOUS           : %d\n", sum(ev$label == "AMBIGUOUS")))
cat(sprintf("  braco de sigla      : %s (nota 6)\n\n",
            if (use_acronym) "LIGADO" else "desligado"))

cat("Por braco, na ordem de precedencia (so o primeiro que fala conta):\n")
print(tab, row.names = FALSE, digits = 3)

cat("\nAs configuracoes, lado a lado (nota 17):\n")
print(cmp, row.names = FALSE, digits = 3)
cat("\nPADRAO = conservadora. O braco idf fica guardado, nao aceito.\n")

cat(sprintf("\n  TOTAL: %d propostos, %d corretos, %d errados\n",
            tot$proposto, tot$correto, tot$errado))
cat(sprintf("  precisao = %.1f%%   recall = %.1f%% do teto (%d/%d)\n",
            100 * tot$precisao, 100 * tot_recall, tot$correto, ceiling_n))
cat(sprintf("  cobertura bruta = %.1f%% das linhas do conjunto\n",
            100 * tot$correto / nrow(ev)))

# Nota 9: as grafias reaproveitadas da rodada 1 nao sao ineditas.
if ("seen_in_round1" %in% names(ev) && any(ev$seen_in_round1 == 1L)) {
  u <- ev[ev$seen_in_round1 == 0L, ]
  zu <- score_one(u)
  cu <- sum(!u$label %in% c("NONE", "AMBIGUOUS"))
  cat(sprintf("\n  So GRAFIA INEDITA (%d linhas, %d ja vistas fora):\n",
              nrow(u), sum(ev$seen_in_round1 == 1L)))
  cat(sprintf("    precisao = %.1f%%   recall = %.1f%% do teto (%d/%d)\n",
              100 * zu$precisao, 100 * zu$correto / cu, zu$correto, cu))
}

if (nrow(err) > 0L) {
  cat("\nErros, por tipo:\n")
  print(as.data.frame(table(tipo = err$tipo)), row.names = FALSE)
  cat("\nOs erros (ate 15):\n")
  e <- err[order(err$tipo), c("university_raw", "arm", "oa_id", "label",
                              "label_name")]
  print(head(e, 15), row.names = FALSE)
}

miss <- ev[is.na(ev$oa_id) & !ev$label %in% c("NONE", "AMBIGUOUS"), ]
if (nrow(miss) > 0L) {
  cat(sprintf("\nNao alcancados que TINHAM resposta (%d):\n", nrow(miss)))
  print(head(miss[, c("university_raw", "label", "label_name")], 15),
        row.names = FALSE)
}
cat("\n")
