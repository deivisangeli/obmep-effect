####################################################################
### Auditoria das flags de Xangai, em 1.000 linhas sorteadas
###
### Mede o erro das DUAS decisoes que shanghai_top1000_degree_flags.R
### toma em cada linha de educacao:
###
###   NIVEL       a cascata rx_notdeg -> rx_phd -> rx_msc (menos
###               rx_lato) -> sql_is_bachelor, que diz se a linha e
###               bacharelado, mestrado, doutorado ou nada
###   INSTITUICAO o casamento do C_norm (braco de string inteira e
###               braco de segmento), que diz se university_raw
###               denota uma universidade do top 1000 de Xangai
###
### Ate aqui as duas foram validadas so por plausibilidade agregada:
### os totais cairam onde pareciam razoaveis e algumas strings foram
### olhadas a olho. Ninguem mediu a taxa de erro. Este script mede.
###
### OFFLINE. Nao usa rede, nao le Athena, nao escreve em S3, e NAO
### altera nenhuma flag -- e somente-leitura em relacao ao pipeline.
### Nao mande nada disto para o SEDAP.
###
### Depende de:
###   shanghai_ranking/shanghai_ranking_oa.parquet            (script 4)
###   revelio_br_cohort/obmep_candidates_step_1_education/    (script 10a)
###   br_degree_patterns.R                                    (script 7)
###   revelio_br_cohort/obmep_candidates_step_1_shanghai.parquet (script 16)
###
### -----------------------------------------------------------------
### RUBRICA 1 -- NIVEL, chaveada em (degree_raw minusculo, degree)
### -----------------------------------------------------------------
### O par, e nao so degree_raw: quando degree_raw esta em branco o
### rotulo degree do Revelio e a unica evidencia que resta.
###
###   bachelor  graduacao: bacharelado, licenciatura, BA/BS,
###             "graduacao", "ensino superior"
###   master    mestrado stricto sensu, MBA incluido: mestrado,
###             master's, M.Sc., MBA
###   phd       doutorado: doutorado, PhD, doctorate
###   other     o que nao e nenhum dos tres: lato sensu,
###             especializacao, tecnologo, tecnico, ensino medio,
###             intercambio, pos-doc, certificate, minor
###   unknown   a linha nao carrega evidencia NENHUMA de nivel
###             (degree_raw vazio E degree = 'empty')
###
### 'unknown' e um veredito sobre o dado, nao um "ainda nao
### classifiquei". As taxas principais sao calculadas sobre o
### subconjunto decidivel, e o numero de excluidos e impresso junto.
###
### -----------------------------------------------------------------
### RUBRICA 2 -- INSTITUICAO, chaveada em university_raw
### -----------------------------------------------------------------
### A afirmacao sob teste e "esta string denota a instituicao sh_inst
### do top 1000".
###
###   Y  correto -- a string denota aquela instituicao, incluindo suas
###      faculdades, institutos e campi.
###      "Faculdade de Medicina de Botucatu - UNESP" e Y.
###   A  ligada, mas nao e a universidade -- escola tecnica, colegio de
###      aplicacao ou hospital mantido por ela, onde a pessoa nao
###      estudou NA universidade.
###      "Colegio Tecnico Industrial - UNESP" e A.
###   N  errado -- outra instituicao, um homonimo, ou um segmento
###      espurio.
###      "Saint Louis University - Maryheights Campus, Baguio City" e N.
###
### A e mantido SEPARADO de N de proposito, pela mesma razao que o
### linkedin_br_name_audit.R mantem a classe 2 fora de SUSPECT: uma
### escola tecnica ligada a universidade e um tipo de falha diferente
### de um homonimo, e justamente a que o filtro de grau deveria pegar
### de qualquer forma. Juntar as duas atribuiria o erro ao lugar
### errado. A precisao principal e Y / (Y + A + N), com A e N tambem
### reportados a parte.
###
### -----------------------------------------------------------------
### ATENCAO / LIMITACOES
### -----------------------------------------------------------------
### 1. OFFLINE, como acima. Nada aqui vai para o SEDAP.
###
### 2. O GABARITO FOI ESCRITO POR UM LLM, NAO POR UMA PESSOA. Quem
###    classificou as 430 chaves de grau e as 269 strings de
###    instituicao foi o mesmo agente que escreveu os regex sob teste.
###    Isto e uma auto-avaliacao com conflito de interesse, e nenhuma
###    formatacao muda isso. Os numeros sao uma checagem de
###    CONSISTENCIA INTERNA dos padroes, NAO uma medicao independente.
###    Leia como "os padroes fazem o que o autor deles achava que
###    faziam", nao como "os padroes estao certos".
###
###    Os dois CSVs existem exatamente para serem corrigidos. Sao CSVs
###    comuns, chaveados na amostra estacionada, na mesma convencao dos
###    scripts 11 e 13. Corrija uma linha, rode de novo, e os numeros
###    saem corrigidos sem redesenhar a amostra. O script imprime
###    quantos rotulos ainda estao como o LLM os deixou, para que a
###    revisao humana seja visivel.
###
### 3. A amostra NAO e redesenhada se o parquet ja existir. Os dois
###    CSVs estao chaveados nesta amostra exata e nao podem derivar por
###    baixo dela. Apague o parquet para forcar um novo sorteio, e
###    conte com reclassificar tudo.
###
### 4. USING SAMPLE nao e usado. No DuckDB ele e empurrado para BAIXO
###    do filtro -- documentado no README, onde sortear 500 de 708M
###    perfis e so depois filtrar devolveu 23 linhas. ORDER BY hash(...)
###    LIMIT n e um top-N sobre o conjunto JA filtrado e nao pode ser
###    reordenado assim. As linhas de educacao nao tem chave unica,
###    entao o hash e sobre um resumo do conteudo da linha; as colunas
###    extras do ORDER BY sao desempate. Conferido: reproduz entre
###    conexoes novas e as 1.000 chaves de hash sao distintas, ou seja
###    o LIMIT nao esta resolvendo empate de forma arbitraria.
###
### 5. MEDE PRECISAO, NUNCA COBERTURA. A amostra sai das linhas que
###    CASARAM, entao nada aqui diz quantos ex-alunos do top 1000 o
###    casamento deixou passar. A lacuna das siglas soltas fica sem
###    medida por construcao. Dizer o contrario seria o mesmo erro de
###    ler ganho de linha como ganho de coorte que o README ja registra
###    contra o ramo C_rsid.
###
### 6. MEDE LINHA, NAO PESSOA. As flags sao por user_id e uma pessoa
###    com tres linhas casadas e marcada se qualquer uma delas
###    disparar. Erro de linha nao vira erro de pessoa na proporcao de
###    um para um.
###
### 7. A amostra e PONDERADA POR LINHA, entao 'mestrado' entra com o
###    peso que tem no dado real. Isso e o que faz a taxa ser uma
###    estimativa do erro de producao, e nao um retrato da cauda longa:
###    as 1.000 linhas cobrem so 430 grafias distintas de grau.
###
### -----------------------------------------------------------------
### RESULTADO -- depois das correcoes A1/B/C/D/E/F/G
### -----------------------------------------------------------------
###   acuracia do nivel (4 classes) : 935 / 943   99,2%  [98,3; 99,6]
###   precisao da instituicao       : 999 / 1.000 99,9%  [99,4; 100]
###     braco de string inteira     : 867 / 867  100,0%
###     braco de segmento apenas    : 132 / 133   99,2%
###   certo nas DUAS dimensoes      : 815 / 818   99,6%  [98,9; 99,9]
###   57 linhas 'unknown' excluidas do denominador do nivel.
###
### Antes das correcoes: 97,8% de nivel, 99,5% nas duas, 22 linhas com
### erro. Agora 99,2%, 99,6% e 9 linhas. Por classe, precisao/recall:
### bacharelado 100,0/99,1, mestrado 98,9/99,5, doutorado 100,0/100,0.
###
### Por padrao, fracao dos disparos que caem na classe que o padrao
### existe para marcar: rx_phd 100% (44), sql_is_bachelor 99,3% (583),
### rx_msc 98,9% (185), rx_notdeg 96,2% (26), rx_lato 82,9% (35).
### sql_is_bachelor e rx_lato nao se mexeram porque nao foram tocados.
###
### A cascata discorda do rotulo `degree` do Revelio em 266 linhas. Nessas,
### a cascata acerta 264 e o rotulo acerta 2 -- 99,2%. E este numero que
### justifica br_degree_patterns.R existir.
###
### -----------------------------------------------------------------
### ESTADO DOS DEFEITOS
### -----------------------------------------------------------------
### Os tamanhos sao medidos sobre as 1.368.227 linhas casadas.
###
###  A1 CORRIGIDO. 'extens[ao]o' saiu do rx_notdeg para o
###     rx_notdeg_weak, testado depois de rx_phd e rx_msc, porque e
###     tambem nome de area: "mestrado em extensao rural" e mestrado de
###     verdade. Recupera 33 linhas, custa ~8.
###
###  A2 RETIRADO -- NAO ERA DEFEITO. O RELATORIO ANTERIOR ESTAVA
###     ERRADO, E O ERRO ERA DO GABARITO, NAO DO REGEX.
###     Eu havia dito que 'exchange' no rx_notdeg engolia um mestrado,
###     com base em UMA linha da amostra: "master of business
###     administration - mba, international exchange program". Olhando
###     a populacao inteira, as 628 linhas em que uma palavra de
###     intercambio e uma de grau aparecem juntas sao dominadas por
###     "mba exchange program", "master's exchange", "master's degree
###     (exchange)" e "doctoral exchange" -- gente que fez INTERCAMBIO
###     naquela universidade estando matriculada em outra. Exclui-las e
###     o comportamento certo, e a "correcao" que eu havia proposto
###     teria piorado o script 16 em cerca de 600 linhas.
###     A linha continua no CSV com o rotulo 'master' que eu dei, e
###     continua aparecendo na lista de erros no fim. E de proposito:
###     apagar o rotulo esconderia a discordancia. Esta e exatamente a
###     falha que a nota 2 preve, e o melhor argumento que existe para
###     a revisao humana que ainda nao aconteceu.
###
###  B  CORRIGIDO. rx_msc ganhou 'mestrand' e '(^|[^a-z])mestr[ae]',
###     a mesma flexao que o rx_phd ja tinha ganho com 'doutorand' e
###     que nao havia sido propagada.            1.248 linhas -> 0
###
###  C  CORRIGIDO. 'master' virou 'm[a\u00e1]ster', pela convencao de
###     classe de dois elementos do arquivo -- e nao com strip_accents,
###     que o Trino nao tem.                     3.736 linhas -> 0
###
###  D  CORRIGIDO FORA DO rx_post, em rx_post16. "pos- graduacao" com
###     hifen E espaco escapava do rx_post e virava bacharelado.
###                                                269 linhas -> 0
###
###  E  CORRIGIDO FORA DO rx_b1/rx_b2, em rx_bach16: 'grado' e
###     'licenciad'.                    5.272 linhas -> 33 residuais,
###     que sao 'other' com razao (a palavra aparece dentro de uma
###     string de especializacao).
###
###  F  CORRIGIDO. rx_phd ganhou 'dnp' e 'dr[.]?-ing'.  44 linhas -> 0
###
###  G  ACHADO DURANTE A CORRECAO, NAO ESTAVA NO RELATORIO.
###     O braco de pos-doutorado do rx_notdeg estava escrito
###     'p[os]s[ -]?doc' e por isso so casava a grafia literal
###     "pos-doc"/"postdoc". NUNCA casou "pos-doutorado", que e como o
###     portugues escreve, entao 862 linhas -- 799 pessoas -- estavam
###     sendo contadas como DOUTORADO OBTIDO na universidade em vez de
###     estagio de pos-doutorado. O comentario do proprio arquivo
###     afirmava o contrario. Corrigido para 'do(c|ut)', com a
###     alternancia apertada o suficiente para NAO pegar
###     "pos-graduacao stricto sensu - doutorado" (822 linhas), que e
###     doutorado de verdade.
###
### D e E NAO foram levados para rx_post/rx_b1/rx_b2. Medido contra o
### extrato local, que reproduz o min_bach_year do pipeline para os
### 6.849.674 membros exatamente, isso tiraria 6.145 pessoas da coorte
### e obrigaria a refazer os scripts 8, 9, 10 e 10a. O criterio E ficou
### byte a byte igual; o bacharelado do script 16 e que passou a
### divergir dele, de forma medida.
###
### Do lado da INSTITUICAO nada mudou -- os padroes de grau nao a
### tocam. Continua um unico erro em 1.000 linhas: "Brigham Young
### University - Idaho" casou com "Brigham Young University" pelo braco
### de segmento. A BYU-Idaho e uma universidade propria, ex-Ricks
### College, nao um campus da BYU de Provo que esta no ranking. 132 das
### 133 linhas que so casam por segmento estao certas.
####################################################################

rm(list = ls()); gc()

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

sh_path   <- file.path(obmep_root,
                       "Data/intermediate/shanghai_ranking/shanghai_ranking_oa.parquet")
coh_dir   <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
ed_dir    <- file.path(coh_dir, "obmep_candidates_step_1_education")
flag_path <- file.path(coh_dir, "obmep_candidates_step_1_shanghai.parquet")

sample_path <- file.path(coh_dir, "shanghai_audit_sample.parquet")
deg_class   <- file.path(coh_dir, "shanghai_audit_degree_class.csv")
inst_class  <- file.path(coh_dir, "shanghai_audit_inst_class.csv")
out_path    <- file.path(coh_dir, "shanghai_audit_classified.parquet")

patterns_path <- Sys.getenv(
  "OBMEP_DEGREE_PATTERNS",
  unset = file.path("prep", "building_external_data", "br_degree_patterns.R"))

seed     <- 20260826L
n_sample <- 1000L
rank_cut <- 901L

# Medidos no sorteio com este seed. Divergencia significa que a amostra
# nao e a mesma, e ai os CSVs nao valem mais.
exp_deg_keys  <- 430L
exp_inst_keys <- 269L
exp_seg_only  <- 133L

# Populacao de onde a amostra sai, medida em shanghai_top1000_degree_flags.R.
exp_pop <- 1368227L

lvl_dom  <- c("bachelor", "master", "phd", "other", "unknown")
inst_dom <- c("Y", "A", "N")

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_sh_audit")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(file.exists(sh_path), dir.exists(ed_dir), file.exists(flag_path),
          file.exists(patterns_path))

source(patterns_path)
stopifnot(exists("sql_shanghai_level"), exists("rx_notdeg"), exists("rx_phd"),
          exists("rx_msc"), exists("rx_lato"), exists("sql_is_bachelor"))

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(dbExecute(con, "PRAGMA memory_limit='8GB'"))
invisible(dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir)))
invisible(dbExecute(con, "CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)"))

sh_src <- sprintf("read_parquet('%s')", sh_path)
ed_src <- sprintf("read_parquet('%s/*')", ed_dir)

####################################################################
### Step 1: reconstruir o casamento, exatamente como no script 16
####################################################################

# Mesmas tres colunas de nome, mesmo corte de faixa, mesmos dois
# bracos. Se isto divergir do script 16, a auditoria mede outra coisa
# que nao o que foi gravado -- a checagem no fim do Step 2 e o que
# prende os dois.
invisible(dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE inst AS
  SELECT lower(strip_accents(trim(nm))) AS nm_fold,
         min(Rank)                      AS best_rank,
         arg_min(trim(nm), Rank)        AS sh_inst
  FROM (
    SELECT cleaned_display_name AS nm, Rank FROM %1$s WHERE Rank <= %2$d
    UNION ALL
    SELECT display_name,        Rank FROM %1$s WHERE Rank <= %2$d
    UNION ALL
    SELECT shanghai_Name,       Rank FROM %1$s WHERE Rank <= %2$d
  )
  WHERE nm IS NOT NULL AND length(trim(nm)) >= 3
  GROUP BY 1", sh_src, rank_cut)))

invisible(dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE raws AS
  SELECT DISTINCT university_raw FROM %s
  WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''", ed_src)))

invisible(dbExecute(con, "
  CREATE OR REPLACE TABLE cls AS
  WITH whole AS (
    SELECT r.university_raw, i.best_rank, i.sh_inst
    FROM raws r
    JOIN inst i ON lower(strip_accents(trim(r.university_raw))) = i.nm_fold
  ),
  seg AS (
    SELECT r.university_raw,
           min(i.best_rank)                AS best_rank,
           arg_min(i.sh_inst, i.best_rank) AS sh_inst
    FROM raws r
    CROSS JOIN UNNEST(str_split(regexp_replace(regexp_replace(
                 r.university_raw, '[/()]', '|', 'g'),
                 ' - ', '|', 'g'), '|')) AS t(part)
    JOIN inst i ON lower(strip_accents(trim(t.part))) = i.nm_fold
    WHERE length(trim(t.part)) >= 3
    GROUP BY r.university_raw
  )
  SELECT university_raw,
         CAST(min(best_rank) AS INTEGER) AS sh_rank,
         arg_min(sh_inst, best_rank)     AS sh_inst,
         CAST(max(is_whole) AS INTEGER)  AS m_whole,
         CAST(max(is_seg)   AS INTEGER)  AS m_seg
  FROM (
    SELECT university_raw, best_rank, sh_inst, 1 AS is_whole, 0 AS is_seg FROM whole
    UNION ALL
    SELECT university_raw, best_rank, sh_inst, 0, 1                       FROM seg
  )
  GROUP BY university_raw"))

# field_raw, university_country e yr viajam so como CONTEXTO para
# julgar. Nenhum dos dois classificadores os le.
sample_sql <- sprintf("
  SELECT e.user_id,
         e.university_raw,
         c.sh_inst,
         c.sh_rank,
         c.m_whole,
         c.m_seg,
         e.degree,
         coalesce(e.degree_raw, '')            AS degree_raw,
         coalesce(e.field_raw, '')             AS field_raw,
         coalesce(e.university_country, '')    AS university_country,
         CAST(year(e.startdate) AS INTEGER)    AS yr,
         hash(concat_ws('|', e.user_id, e.university_raw,
                        coalesce(e.degree_raw, ''), coalesce(e.degree, ''),
                        coalesce(CAST(e.startdate AS VARCHAR), ''),
                        coalesce(e.field_raw, '')) || '#%d') AS hk
  FROM %s e
  JOIN cls c ON e.university_raw = c.university_raw
  ORDER BY hk, e.user_id, e.university_raw, e.degree_raw
  LIMIT %d", seed, ed_src, n_sample)

if (file.exists(sample_path)) {
  cat("[skip] amostra ja existe:", sample_path, "\n")
} else {
  cat("Sorteando", n_sample, "linhas casadas...\n")
  t0 <- Sys.time()
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    sample_sql, sample_path)))
  cat("  pronto em",
      round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
}

# A amostra e sempre RELIDA do parquet. O arquivo e a fonte da verdade,
# nunca o resultado da consulta.
s <- dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s')", sample_path))
s$user_id <- as.character(s$user_id)
s$dr <- tolower(trimws(s$degree_raw))

####################################################################
### Step 2: validacao da amostra
####################################################################

cat("\n=========== VALIDACAO DA AMOSTRA ===========\n")

if (nrow(s) != n_sample) {
  stop("A amostra tem ", nrow(s), " linhas, esperado ", n_sample)
}
if (anyDuplicated(s$hk) != 0) {
  stop("Chave de hash repetida na amostra: o LIMIT esta desempatando ",
       "de forma arbitraria e o sorteio nao e reproduzivel.")
}

# Um seed que nao reproduz e pior do que nenhum: os CSVs parariam de
# casar com a amostra em silencio. A consulta e local e gratuita, entao
# esta checagem roda em TODA invocacao, nao so no sorteio.
s2 <- dbGetQuery(con, sample_sql)
s2$user_id <- as.character(s2$user_id)
key <- function(d) paste(d$user_id, d$university_raw, d$degree_raw, d$hk, sep = "\r")
if (!identical(sort(key(s)), sort(key(s2)))) {
  stop("Rodar a consulta com o mesmo seed devolveu uma amostra DIFERENTE.")
}

# Qualquer que fosse o predicado que definiu a populacao, ele e
# re-afirmado em R contra as linhas devolvidas.
if (any(is.na(s$sh_rank)) || max(s$sh_rank) > rank_cut) {
  stop("Ha linha amostrada com sh_rank acima de ", rank_cut, " ou nula.")
}
if (any(s$m_whole == 0 & s$m_seg == 0)) {
  stop("Ha linha amostrada que nao casou por nenhum dos dois bracos.")
}
cat("[OK] ", n_sample, " linhas, hash unico, seed reproduzivel, ",
    "todas dentro da faixa e casadas\n", sep = "")

pop <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM %s e JOIN cls c ON e.university_raw = c.university_raw",
  ed_src))$n
cat("populacao amostrada  :", format(pop, big.mark = ","), "\n")
if (pop != exp_pop) {
  warning("Populacao e ", pop, ", esperado ", exp_pop, call. = FALSE)
}

s$deg_key <- paste0(s$dr, "###", s$degree)
n_deg  <- length(unique(s$deg_key))
n_inst <- length(unique(s$university_raw))
cat("chaves de grau       :", n_deg, "\n")
cat("university_raw       :", n_inst, "\n")
cat("linhas so por segmento:", sum(s$m_whole == 0), "\n")
if (n_deg != exp_deg_keys)  warning("Chaves de grau: ", n_deg, call. = FALSE)
if (n_inst != exp_inst_keys) warning("university_raw: ", n_inst, call. = FALSE)

####################################################################
### Step 3: o que a cascata prediz, e a amarra com o script 16
####################################################################

invisible(dbWriteTable(con, "samp", s[, c("user_id", "university_raw", "dr",
                                          "degree", "hk")],
                       overwrite = TRUE))

pred <- dbGetQuery(con, sprintf("
  SELECT hk,
         (%s)                        AS pred,
         regexp_like(dr, '%s')       AS f_notdeg,
         regexp_like(dr, '%s')       AS f_phd,
         regexp_like(dr, '%s')       AS f_msc,
         regexp_like(dr, '%s')       AS f_lato,
         (%s)                        AS f_bach
  FROM samp",
  sql_shanghai_level, rx_notdeg, rx_phd, rx_msc, rx_lato, sql_is_bachelor))

s <- merge(s, pred, by = "hk", all.x = TRUE)
stopifnot(nrow(s) == n_sample, !any(is.na(s$pred)))

# ESTA e a checagem que vale mais do que qualquer numero de acuracia
# abaixo: ela prova que a auditoria esta testando a cascata QUE FOI
# GRAVADA, e nao uma copia que derivou. Para cada usuario amostrado, um
# nivel predito aqui tem de aparecer na flag correspondente do parquet
# do script 16.
fl <- dbGetQuery(con, sprintf("
  SELECT CAST(user_id AS VARCHAR) AS user_id, sh_bachelor, sh_master, sh_phd
  FROM read_parquet('%s')", flag_path))
chk <- merge(s[s$pred %in% c("bachelor", "master", "phd"),
                c("user_id", "pred")], fl, by = "user_id", all.x = TRUE)
bad <- sum(is.na(chk$sh_bachelor)) +
       sum(chk$pred == "bachelor" & chk$sh_bachelor %in% 0) +
       sum(chk$pred == "master"   & chk$sh_master   %in% 0) +
       sum(chk$pred == "phd"      & chk$sh_phd      %in% 0)
if (bad != 0) {
  stop(bad, " linhas predizem um nivel que a flag gravada nao tem. ",
       "A cascata desta auditoria nao e a que o script 16 rodou.")
}
cat("[OK] a cascata auditada reproduz as flags gravadas pelo script 16\n")

####################################################################
### Step 4: ler os dois gabaritos
####################################################################

read_class <- function(path, key_cols, verdict, domain, universe, label) {
  if (!file.exists(path)) {
    stop("Gabarito ausente: ", path, "\n  Rode uma vez para estacionar a ",
         "amostra, classifique, e rode de novo.")
  }
  cl <- read.csv(path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
                 colClasses = "character")
  if (!all(c(key_cols, verdict) %in% names(cl))) {
    stop(basename(path), " nao tem as colunas ",
         paste(c(key_cols, verdict), collapse = ", "))
  }
  k <- do.call(paste, c(cl[key_cols], sep = "###"))
  if (anyDuplicated(k) != 0) {
    stop("Chave repetida em ", basename(path), ": ",
         paste(head(unique(k[duplicated(k)]), 10), collapse = " | "))
  }
  # Um veredito em branco cai AQUI, no dominio, e nao na checagem de
  # arquivo -- o desenho supoe o CSV ausente ou completo, sem meio termo.
  off <- setdiff(cl[[verdict]], domain)
  if (length(off)) {
    stop("Vereditos fora de {", paste(domain, collapse = ", "), "} em ",
         basename(path), ": ", paste(sort(off), collapse = ", "))
  }
  # Uma chave sem classificacao sumiria das contagens e subestimaria o
  # erro em silencio, entao isto e stop() e a mensagem E a lista de
  # trabalho.
  miss <- setdiff(unique(universe), k)
  if (length(miss)) {
    stop(length(miss), " chave(s) de ", label, " sem classificacao: ",
         paste(head(miss, 20), collapse = " | "))
  }
  cat("[OK]", nrow(cl), label, "classificadas, uma linha cada, dominio valido\n")
  cl$.k <- k
  cl
}

cat("\n=========== VALIDACAO DOS GABARITOS ===========\n")

dc <- read_class(deg_class, c("degree_raw_lower", "degree"), "true_level",
                 lvl_dom, s$deg_key, "grau")
ic <- read_class(inst_class, c("university_raw"), "inst_class",
                 inst_dom, s$university_raw, "instituicao")

s <- merge(s, dc[, c(".k", "true_level")], by.x = "deg_key", by.y = ".k",
           all.x = TRUE)
stopifnot(nrow(s) == n_sample)
s <- merge(s, ic[, c(".k", "inst_class")], by.x = "university_raw", by.y = ".k",
           all.x = TRUE)
stopifnot(nrow(s) == n_sample, !any(is.na(s$true_level)),
          !any(is.na(s$inst_class)))

# Quanto do gabarito ainda esta como o LLM deixou. Serve para tornar a
# revisao humana visivel; nao e assercao.
n_llm <- sum(dc$source == "llm", na.rm = TRUE) + sum(ic$source == "llm", na.rm = TRUE)
n_lab <- nrow(dc) + nrow(ic)
cat("rotulos ainda como o LLM os deixou:", n_llm, "de", n_lab,
    sprintf("(%.0f%%)", 100 * n_llm / n_lab), "\n")

####################################################################
### Step 5: relatorio
####################################################################

# CI binomial exato. binom.test(0, n) devolve intervalo degenerado,
# entao o zero recebe o limite estilo regra-dos-tres, como no
# linkedin_br_name_audit.R.
ci_txt <- function(k, n) {
  if (n == 0) return("     n/a      ")
  ci <- if (k == 0) c(0, 1 - 0.05^(1 / n)) else
    as.numeric(binom.test(k, n)$conf.int)
  sprintf("[%5.1f%%, %5.1f%%]", 100 * ci[1], 100 * ci[2])
}
rate <- function(k, n, lab) {
  cat(sprintf("  %-42s %4d / %4d  %5.1f%%  %s\n", lab, k, n,
              if (n) 100 * k / n else NA_real_, ci_txt(k, n)))
}

d <- s[s$true_level != "unknown", ]
n_dec <- nrow(d)

cat("\n=========== NIVEL: MATRIZ DE CONFUSAO ===========\n")
cat("linhas = predito pela cascata, colunas = gabarito\n")
cat("(", n_sample - n_dec, "linhas 'unknown' excluidas: sem evidencia de nivel)\n\n")
cm <- table(factor(d$pred, levels = c("bachelor", "master", "phd", "other")),
            factor(d$true_level, levels = c("bachelor", "master", "phd", "other")))
print(cm)

cat("\n=========== NIVEL: PRECISAO E RECALL POR CLASSE ===========\n")
cat(sprintf("  %-10s %8s %8s %8s %7s %7s\n",
            "classe", "TP", "predito", "real", "prec", "recall"))
for (k in c("bachelor", "master", "phd", "other")) {
  tp <- sum(d$pred == k & d$true_level == k)
  np <- sum(d$pred == k)
  nt <- sum(d$true_level == k)
  cat(sprintf("  %-10s %8d %8d %8d %6.1f%% %6.1f%%\n", k, tp, np, nt,
              if (np) 100 * tp / np else NA_real_,
              if (nt) 100 * tp / nt else NA_real_))
}
acc <- sum(d$pred == d$true_level)
cat("\n")
rate(acc, n_dec, "acuracia da cascata (4 classes)")

cat("\n=========== POR PADRAO ===========\n")
cat("quando o padrao dispara, o gabarito diz o que?\n\n")
pats <- list(
  rx_notdeg       = list(col = "f_notdeg", want = "other"),
  rx_phd          = list(col = "f_phd",    want = "phd"),
  rx_msc          = list(col = "f_msc",    want = "master"),
  rx_lato         = list(col = "f_lato",   want = "other"),
  sql_is_bachelor = list(col = "f_bach",   want = "bachelor"))
cat(sprintf("  %-16s %7s %8s %8s %8s %8s %7s\n",
            "padrao", "dispara", "bachelor", "master", "phd", "other", "acerto"))
for (nm in names(pats)) {
  f <- d[[pats[[nm]]$col]]
  tb <- table(factor(d$true_level[f], levels = c("bachelor", "master", "phd", "other")))
  hit <- tb[[pats[[nm]]$want]]
  cat(sprintf("  %-16s %7d %8d %8d %8d %8d %6.1f%%\n", nm, sum(f),
              tb[["bachelor"]], tb[["master"]], tb[["phd"]], tb[["other"]],
              if (sum(f)) 100 * hit / sum(f) else NA_real_))
}
cat("\n  'acerto' e a fracao dos disparos cujo gabarito e a classe que o\n")
cat("  padrao existe para marcar. Para rx_notdeg e rx_lato essa classe e\n")
cat("  'other', porque eles existem para EXCLUIR. Os padroes se sobrepoem\n")
cat("  de proposito -- e a ordem da cascata que os desempata --, entao\n")
cat("  estas linhas nao somam a amostra.\n")

cat("\n=========== A CASCATA CONTRA O ROTULO degree DO REVELIO ===========\n")
rev_lvl <- c(Bachelor = "bachelor", Master = "master", MBA = "master",
             Doctor = "phd")
d$rev <- unname(rev_lvl[d$degree]); d$rev[is.na(d$rev)] <- "other"
dis <- d[d$rev != d$pred, ]
cat("linhas onde a cascata discorda do rotulo degree:", nrow(dis), "\n")
if (nrow(dis)) {
  rate(sum(dis$pred == dis$true_level), nrow(dis), "  nessas, a CASCATA acerta")
  rate(sum(dis$rev  == dis$true_level), nrow(dis), "  nessas, o rotulo degree acerta")
  cat("\n  Este e o numero que justifica br_degree_patterns.R existir: o\n")
  cat("  arquivo so se paga se sobrescrever `degree` acertar mais do que\n")
  cat("  segui-lo, e so nas linhas onde os dois divergem.\n")
}

cat("\n=========== INSTITUICAO ===========\n")
tb <- table(factor(s$inst_class, levels = inst_dom))
lab_i <- c(Y = "Y  correto",
           A = "A  ligada, mas nao e a universidade",
           N = "N  errado (homonimo ou segmento espurio)")
for (k in inst_dom) {
  cat(sprintf("  %-42s %4d  %5.1f%%\n", lab_i[[k]], tb[[k]],
              100 * tb[[k]] / n_sample))
}
cat("\n")
rate(tb[["Y"]], n_sample, "precisao do casamento, Y / (Y+A+N)")
w <- s[s$m_whole == 1, ]; g <- s[s$m_whole == 0, ]
rate(sum(w$inst_class == "Y"), nrow(w), "  braco de string inteira")
rate(sum(g$inst_class == "Y"), nrow(g), "  braco de segmento apenas")

cat("\n=========== CONJUNTO ===========\n")
cat("A linha so esta certa se a instituicao E o nivel estiverem certos.\n")
cat("E isso que o parquet do script 16 afirma de cada linha marcada.\n\n")
fl_rows <- d[d$pred %in% c("bachelor", "master", "phd"), ]
ok <- sum(fl_rows$inst_class == "Y" & fl_rows$pred == fl_rows$true_level)
rate(ok, nrow(fl_rows), "linhas marcadas corretas nas duas dimensoes")

cat("\n=========== ERROS, UM A UM ===========\n")
err <- s[(s$true_level != "unknown" & s$pred != s$true_level) |
         s$inst_class != "Y", ]
err <- err[order(err$inst_class, err$pred, err$dr), ]
cat(nrow(err), "linhas com pelo menos um erro:\n\n")
if (nrow(err)) {
  for (i in seq_len(nrow(err))) {
    cat(sprintf("  [%s] %-9s vs %-9s | %-34s | %-34s -> %s\n",
                err$inst_class[i], err$pred[i], err$true_level[i],
                substr(err$dr[i], 1, 34),
                substr(err$university_raw[i], 1, 34),
                substr(err$sh_inst[i], 1, 30)))
  }
}

####################################################################
### Step 6: persistir e resumir
####################################################################

invisible(dbWriteTable(con, "classified", s, overwrite = TRUE))
invisible(dbExecute(con, sprintf(
  "COPY classified TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", out_path)))

cat("\n=========== SUMMARY ===========\n")
cat("  amostra          :", sample_path, "\n")
cat("  gabarito grau    :", deg_class, "\n")
cat("  gabarito instit. :", inst_class, "\n")
cat("  classificado     :", out_path, "\n")
cat(sprintf("  acuracia do nivel: %d / %d (%.1f%%)\n",
            acc, n_dec, 100 * acc / n_dec))
cat(sprintf("  precisao instit. : %d / %d (%.1f%%)\n",
            tb[["Y"]], n_sample, 100 * tb[["Y"]] / n_sample))
cat(sprintf("  correto nas duas : %d / %d (%.1f%%)\n",
            ok, nrow(fl_rows), 100 * ok / nrow(fl_rows)))
cat("\n  O gabarito foi escrito por um LLM, nao por uma pessoa -- ver a\n")
cat("  nota 2 no cabecalho. Trate como consistencia interna, nao como\n")
cat("  medicao independente.\n")
