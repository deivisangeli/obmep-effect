####################################################################
###
### Resolving the unmatched rows by SCHOOL, not by string  [local only]
###
### 8h leaves 2,828,884 education rows with no OpenAlex id over 361,382
### distinct university_raw strings. Cleaning those strings with an LLM
### was measured at ~3.6M input tokens and is the wrong shape of work:
###
###   REVELIO ALREADY NAMED 71.5% OF THOSE ROWS.
###
###   has a Revelio university_name   2,022,578 rows   79,694 raw strings
###   no university_name, no rsid       808,218 rows  293,941 raw strings
###   has rsid, no name (anomalia)        1,353 rows       87 raw strings
###
### The named slice collapses from 79,694 strings to 27,432 SCHOOLS
### (27,828 rsids, 1,727,873 users). FMU absorbs 360 raw variants, IFSP
### 496, UNIASSELVI 286. Resolving a school once resolves every spelling.
###
### Row coverage by school:  100 -> 31.0%, 500 -> 54.0%,
###                        1,000 -> 66.6%, 2,500 -> 82.7%
###
### THE MATCH RUNS AGAINST THE FULL OPENALEX SNAPSHOT, 120,658
### institutions -- not openalex_institutions_br.parquet's 1,947.
### Measured, that is the difference between resolving 142 schools and
### resolving 7,659:
###
###   fold vs BR list only        142 escolas
###   fold vs full snapshot     7,659 escolas    669,638 linhas
###   ambiguous fold              218 escolas     28,602 linhas
###   sem dobra                19,555 escolas  1,324,338 linhas
###
### Whatever the fold cannot reach gets a CANDIDATE SHORTLIST drawn from
### real snapshot records, so a human or an LLM picks among institutions
### that exist and never authors an identifier.
###
### Three products:
###   oa_institution_fold_cache.parquet   folded name index, rebuilt on demand
###   unmatched_school_name_class.csv     the editable worksheet, top N
###   unmatched_school_openalex_map.parquet  published on the 2nd run
###
### Depends on:
###   unmatched_university_raw_openalex.R (8h)  the row-level parquet
###   the OpenAlex institutions snapshot under GT_ROOT (script 3's input)
###
### Shape reused from:
###   rsid_openalex_one_to_one.R (8f) and c_norm_coverage_audit.R (13a):
###   parked worksheet + editable CSV keyed to it, stop() until filled
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Reads the local snapshot and local parquet, writes a
###    cache, a CSV and a parquet. Still a prep/ script; not for SEDAP.
### 2. NOBODY MAY AUTHOR AN openalex_id, AND PHASE 2 ENFORCES IT AGAINST
###    THE SNAPSHOT ITSELF. Every non-empty openalex_id must exist among
###    the 120,658 institution records or the run stops. That is the real
###    guarantee: an invented identifier cannot pass, and neither can a
###    mistyped one.
###    Being among the row's own cand1..cand5 is a NARROWER test and is
###    only reported, never enforced, because three legitimate routes
###    land outside the shortlist: the deterministic fold (which has no
###    shortlist at all), a targeted lookup that found a record the token
###    blocking missed, and a deliberate parent-level mapping.
###    from_candidates in the published map records which ids came off
###    the shortlist, so the looser ones stay auditable.
### 3. REVELIO'S university_name IS NOT ALWAYS RIGHT. In
###    rsid_openalex_br.parquet, rsid 3800 carries university_raw =
###    "Universidade Federal do Rio de Janeiro" against university_name =
###    "Universite d'Aix-Marseille" -- DIFFERENT institutions. The
###    worksheet ships top_raw_variants, the strings users actually
###    typed, and every verdict must be checked against those, never
###    against Revelio's name alone. REVELIO_NAME_WRONG is an expected
###    verdict; zero of them across 1,000 schools means the check was
###    not really applied.
### 4. CANDIDATES ARE GENERATED FROM BOTH SIDES OF THE LANGUAGE GAP.
###    Revelio renders Brazilian schools in English ("University Centre
###    of United Metropolitan Faculties") while OpenAlex holds the
###    Portuguese ("Centro Universitario das Faculdades Metropolitanas
###    Unidas"). Token blocking on university_name alone fails there, so
###    the probe set is university_name PLUS the commonest raw variants,
###    which are in Portuguese and do match. Dropping the raw probes
###    collapses recall on exactly the rows that matter.
### 5. THE RANKER IS IDF-WEIGHTED TOKEN OVERLAP, NOT STRING SIMILARITY,
###    and that is load-bearing. Jaro-Winkler over the whole string ranks
###    "Universidade Estadual de Goias" above "Estacio (Brazil)" for the
###    probe "Universidade Estacio de Sa", because the shared prefix
###    "universidade esta" is long and the one distinctive token drowns.
###    Measured on the first draft, that cost the correct answer entirely
###    on Estacio de Sa, UNIASSELVI and UniFatecie. Scoring by the share
###    of the probe's INFORMATION that the candidate covers -- idf summed
###    over shared tokens, over idf summed over the probe's tokens --
###    puts the rare token first. jw survives only as a tiebreak.
### 5b. ACRONYMS ARE INDEXED FOR CANDIDATES BUT NOT FOR THE FOLD. 50,511
###    institutions carry display_name_acronyms, and UNIASSELVI is one of
###    them: it reaches Centro Universitario Leonardo da Vinci
###    (I4210097431), which no name match finds because Revelio calls the
###    school "Dante University Centre". But acronyms collide across
###    countries -- UNESA is an Indonesian university, not Estacio -- so
###    an acronym may PROPOSE a candidate and never silently resolve one.
### 5c. THE MAP IS PUBLISHED AT rsid GRAIN, NOT AT NAME GRAIN, AND THAT
###    IS NOT COSMETIC. Measured: rsid -> university_name IS a function
###    (27,828 rsids, every one with exactly one name), but the reverse
###    is NOT -- 350 names span 2-3 rsids and 11 span 4-10. A map keyed
###    on the name with mode(rsid) beside it therefore DROPS rsids: on
###    the published set that silently lost 24,069 of 747,109 rows over
###    18 schools. Exploding to one row per rsid is lossless precisely
###    because the rsid -> name direction is a function. Downstream code
###    (27, 8g) joins on rsid, so rsid is the grain it must ship in.
### 6. THE AMBIGUOUS FOLD IS NOT AUTO-ACCEPTED. One folded name reaching
###    two openalex_id goes to the worksheet with candidates like any
###    unresolved row, never silently to the first id.
### 7. THE VERDICTS WILL BE LLM-WRITTEN, NOT HUMAN. Same conflict of
###    interest 8f, 16a and 13a record for theirs: labels and rubric come
###    from the same place, so this is an internal-consistency pass and
###    NOT an independent measurement. `source` marks every row fold,
###    llm or human so a person can overrule.
### 8. TWO-PHASE. Run 1 writes the template and stop()s. Fill
###    openalex_id / verdict / note. Run 2 validates and publishes.
### 9. THE FOLD CACHE IS DERIVED, NOT SOURCE. Delete it to rebuild from
###    the snapshot; OBMEP_OA_REBUILD=1 forces it. Reading the 168 MB of
###    gzipped NDJSON takes a couple of minutes, the cache makes re-runs
###    instant.
###
####################################################################

rm(list = ls()); gc()
options(width = 200)

for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop(sprintf("Pacote ausente: %s", p), call. = FALSE)
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

coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
oa_dir  <- file.path(gt_root, "Data/external/oa_snapshot/data/institutions")
oa_glob <- file.path(oa_dir, "updated_date=*/part_*.gz")

rows_pq    <- file.path(coh_dir, "unmatched_openalex_education_rows.parquet")
cache_path <- file.path(coh_dir, "oa_institution_fold_cache.parquet")
inst_path  <- file.path(coh_dir, "oa_institution_cache.parquet")
cand_path  <- file.path(coh_dir, "oa_institution_cand_names.parquet")
class_path <- file.path(coh_dir, "unmatched_school_name_class.csv")
map_path   <- file.path(coh_dir, "unmatched_school_openalex_map.parquet")

top_n     <- as.integer(Sys.getenv("OBMEP_SCHOOL_TOP_N", unset = "1000"))
n_cand    <- 5L     # candidatos por escola
n_probe   <- 4L     # grafias raw usadas como sonda, alem do university_name
min_tok   <- 4L     # tamanho minimo do token de bloqueio
max_tok_df <- 3000L # token presente em mais instituicoes que isso nao bloqueia

rebuild <- nzchar(Sys.getenv("OBMEP_OA_REBUILD"))

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")
tmp_dir   <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_school_names")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

# PENDING = cauda ainda nao revisada. Fica na planilha, ordenada por
# n_rows, e NAO entra no mapa. Permite publicar a cabeca sem fingir que
# a cauda foi decidida -- e sem apagar o que resta a fazer.
ok_verdicts <- c("OK", "NO_OPENALEX_RECORD", "AMBIGUOUS",
                 "REVELIO_NAME_WRONG", "OVERRIDE", "PENDING")

# Medidos. Divergencia e sinal de dado novo -- warning, nao stop.
exp_named_rows  <- 2022578L
exp_schools     <- 27432L
exp_raw_strings <- 79694L
exp_inst        <- 120658L
exp_fold_ok     <- 7659L
exp_fold_amb    <- 218L

stopifnot(file.exists(rows_pq), !is.na(top_n), top_n > 0L)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

# A dobra padrao da pasta, identica a de 16, 16a, 16b, 19 e 20.
dbExecute(con, "CREATE MACRO fs(s) AS lower(strip_accents(trim(s)))")

####################################################################
### Step 0 -- o indice de nomes do OpenAlex (cache)
####################################################################

if (rebuild || !file.exists(cache_path) || !file.exists(inst_path) ||
    !file.exists(cand_path)) {

  if (length(Sys.glob(oa_glob)) == 0L) {
    stop(sprintf("Snapshot do OpenAlex nao encontrado em:\n  %s", oa_glob),
         call. = FALSE)
  }
  message("Step 0: lendo o snapshot do OpenAlex (so na primeira vez) ...")

  dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE oa AS
  SELECT regexp_extract(id, 'I[0-9]+') AS oa_id,
         display_name, country_code, type, works_count,
         display_name_alternatives, display_name_acronyms
  FROM read_ndjson('%s', columns = {
        id: 'VARCHAR', display_name: 'VARCHAR', country_code: 'VARCHAR',
        type: 'VARCHAR', works_count: 'BIGINT',
        display_name_alternatives: 'VARCHAR[]',
        display_name_acronyms: 'VARCHAR[]' })
  WHERE id IS NOT NULL", oa_glob))

  dbExecute(con, sprintf("
  COPY (SELECT oa_id, display_name, country_code, type, works_count FROM oa)
  TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", inst_path))

  # A DOBRA usa so nome e alternativas (nota 5b): siglas colidem.
  dbExecute(con, sprintf("
  COPY (
    WITH a AS (
      SELECT fs(display_name) AS nm, oa_id FROM oa
      UNION ALL
      SELECT fs(unnest(display_name_alternatives)) AS nm, oa_id FROM oa
    )
    SELECT nm, any_value(oa_id) AS oa_id, count(DISTINCT oa_id) AS n_oa
    FROM a WHERE nm IS NOT NULL AND nm <> '' GROUP BY nm
  ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", cache_path))

  # Os CANDIDATOS usam tambem as siglas -- so para propor, nunca resolver.
  dbExecute(con, sprintf("
  COPY (
    SELECT DISTINCT nm, oa_id FROM (
      SELECT fs(display_name) AS nm, oa_id FROM oa
      UNION ALL
      SELECT fs(unnest(display_name_alternatives)) AS nm, oa_id FROM oa
      UNION ALL
      SELECT fs(unnest(display_name_acronyms)) AS nm, oa_id FROM oa
    ) WHERE nm IS NOT NULL AND nm <> ''
  ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", cand_path))
}

dbExecute(con, sprintf(
  "CREATE OR REPLACE VIEW oa_names AS SELECT * FROM read_parquet('%s')", cache_path))
dbExecute(con, sprintf(
  "CREATE OR REPLACE VIEW oa_inst AS SELECT * FROM read_parquet('%s')", inst_path))
dbExecute(con, sprintf(
  "CREATE OR REPLACE VIEW oa_cand_names AS SELECT * FROM read_parquet('%s')", cand_path))

inst_n <- dbGetQuery(con, "SELECT count(*) AS n FROM oa_inst")$n

####################################################################
### Step 1 -- a fatia nomeada, agregada por ESCOLA
####################################################################

message("Step 1: agregando a fatia nomeada por escola ...")

dbExecute(con, sprintf("
CREATE OR REPLACE TEMP TABLE named AS
SELECT user_id, university_raw, university_name, rsid, lvl, university_country
FROM read_parquet('%s')
WHERE oa_source IS NULL
  AND university_name IS NOT NULL AND trim(university_name) <> ''", rows_pq))

base <- dbGetQuery(con, "
SELECT count(*) AS rows, count(DISTINCT university_name) AS schools,
       count(DISTINCT university_raw) AS raw_strings,
       count(DISTINCT user_id) AS users
FROM named")

# As grafias mais comuns por escola: servem de sonda (nota 4) e de prova
# para o veredito (nota 3).
dbExecute(con, sprintf("
CREATE OR REPLACE TEMP TABLE rawvar AS
WITH u AS (
  SELECT university_name, university_raw, count(*) AS n
  FROM named GROUP BY university_name, university_raw
)
SELECT *, row_number() OVER (PARTITION BY university_name
                             ORDER BY n DESC, university_raw) AS r
FROM u QUALIFY r <= %d", n_probe))

dbExecute(con, "
CREATE OR REPLACE TEMP TABLE schools AS
SELECT n.university_name,
       mode(n.rsid)                     AS rsid,
       count(DISTINCT n.rsid)           AS n_rsid,
       count(*)                         AS n_rows,
       count(DISTINCT n.user_id)        AS n_users,
       count(DISTINCT n.university_raw) AS n_raw_variants,
       mode(n.university_country)       AS top_country,
       max(CASE WHEN n.university_country = 'Brazil' THEN 1 ELSE 0 END) AS plausibly_br,
       sum(CASE WHEN n.lvl = 'bachelor' THEN 1 ELSE 0 END) AS n_bachelor,
       sum(CASE WHEN n.lvl = 'master'   THEN 1 ELSE 0 END) AS n_master,
       sum(CASE WHEN n.lvl = 'phd'      THEN 1 ELSE 0 END) AS n_phd
FROM named n GROUP BY n.university_name")

dbExecute(con, "
CREATE OR REPLACE TEMP TABLE variants AS
SELECT university_name,
       string_agg(university_raw || ' (' || n || ')', ' | ' ORDER BY r)
         AS top_raw_variants
FROM rawvar GROUP BY university_name")

####################################################################
### Step 2 -- a dobra contra o snapshot INTEIRO
####################################################################

message("Step 2: dobra contra as ", format(inst_n, big.mark = ","),
        " instituicoes do snapshot ...")

dbExecute(con, "
CREATE OR REPLACE TEMP TABLE folded AS
SELECT s.*,
       CASE WHEN i.n_oa = 1 THEN i.oa_id END AS fold_openalex_id,
       CASE WHEN i.n_oa = 1 THEN 'fold'
            WHEN i.n_oa > 1 THEN 'fold_ambiguous' END AS fold_status
FROM schools s
LEFT JOIN oa_names i ON fs(s.university_name) = i.nm")

fold_rep <- dbGetQuery(con, "
SELECT coalesce(fold_status, '(sem dobra)') AS status,
       count(*) AS schools, sum(n_rows) AS rows
FROM folded GROUP BY 1 ORDER BY rows DESC")

####################################################################
### Step 3 -- candidatos reais para o que a dobra nao alcancou
####################################################################

message("Step 3: gerando candidatos para o residuo do top ", top_n, " ...")

# O residuo do corte: sem dobra, ou com dobra ambigua (nota 5).
dbExecute(con, sprintf("
CREATE OR REPLACE TEMP TABLE cut AS
SELECT * FROM folded ORDER BY n_rows DESC, university_name LIMIT %d", top_n))

dbExecute(con, "
CREATE OR REPLACE TEMP TABLE residue AS
SELECT * FROM cut WHERE fold_openalex_id IS NULL")

# Sondas: o nome da Revelio MAIS as grafias que as pessoas digitaram.
dbExecute(con, "
CREATE OR REPLACE TEMP TABLE probes AS
SELECT university_name, university_name AS probe FROM residue
UNION
SELECT r.university_name, v.university_raw AS probe
FROM residue r JOIN rawvar v USING (university_name)")

# Indice invertido de tokens, com corte de frequencia (max_tok_df).
dbExecute(con, sprintf("
CREATE OR REPLACE TEMP TABLE oa_tok AS
WITH t AS (
  SELECT DISTINCT oa_id, unnest(string_split_regex(nm, '[^a-z0-9]+')) AS tok
  FROM oa_cand_names
)
SELECT tok, oa_id FROM t
WHERE length(tok) >= %d
  AND tok IN (SELECT tok FROM t WHERE length(tok) >= %d
              GROUP BY tok HAVING count(DISTINCT oa_id) <= %d)",
  min_tok, min_tok, max_tok_df))

dbExecute(con, sprintf("
CREATE OR REPLACE TEMP TABLE prob_tok AS
SELECT DISTINCT university_name, probe, tok FROM (
  SELECT university_name, probe,
         unnest(string_split_regex(fs(probe), '[^a-z0-9]+')) AS tok
  FROM probes
) WHERE length(tok) >= %d", min_tok))

# idf sobre o indice de tokens: token raro pesa, "universidade" nao.
dbExecute(con, sprintf("
CREATE OR REPLACE TEMP TABLE tok_idf AS
SELECT tok, ln(%d.0 / count(DISTINCT oa_id)) AS idf
FROM oa_tok GROUP BY tok", inst_n))

dbExecute(con, "
CREATE OR REPLACE TEMP TABLE cand AS
WITH probe_w AS (
  SELECT p.university_name, p.probe, sum(i.idf) AS tot_idf
  FROM prob_tok p JOIN tok_idf i USING (tok)
  GROUP BY 1, 2
),
hit AS (
  SELECT p.university_name, p.probe, o.oa_id,
         sum(i.idf) AS shared_idf, count(*) AS shared
  FROM prob_tok p
  JOIN oa_tok o USING (tok)
  JOIN tok_idf i USING (tok)
  GROUP BY 1, 2, 3
),
cov AS (
  SELECT h.university_name, h.probe, h.oa_id, h.shared,
         h.shared_idf / nullif(w.tot_idf, 0) AS coverage
  FROM hit h JOIN probe_w w USING (university_name, probe)
),
sc AS (
  SELECT c.university_name, c.oa_id,
         max(c.coverage) AS score,
         max(c.shared)   AS shared,
         max(jaro_winkler_similarity(fs(c.probe), n.nm)) AS jw
  FROM cov c JOIN oa_cand_names n ON c.oa_id = n.oa_id
  GROUP BY 1, 2
)
SELECT sc.*, row_number() OVER (PARTITION BY university_name
                                ORDER BY score DESC, jw DESC, shared DESC, oa_id) AS rk
FROM sc")

dbExecute(con, sprintf("
CREATE OR REPLACE TEMP TABLE cand_txt AS
SELECT c.university_name, c.rk,
       c.oa_id || ' | ' || i.display_name
         || ' | ' || coalesce(i.country_code, '??')
         || ' | ' || coalesce(i.type, '?')
         || ' | ' || coalesce(i.works_count, 0) || ' works'
         || ' | cov ' || printf('%%.2f', c.score)
         || ' jw ' || printf('%%.3f', c.jw) AS txt
FROM cand c JOIN oa_inst i ON c.oa_id = i.oa_id
WHERE c.rk <= %d", n_cand))

cand_rep <- dbGetQuery(con, sprintf("
SELECT CASE WHEN n IS NULL THEN 'sem candidato' ELSE 'com candidato' END AS status,
       count(*) AS schools, sum(r.n_rows) AS rows
FROM residue r
LEFT JOIN (SELECT university_name, count(*) AS n FROM cand_txt GROUP BY 1) c
  USING (university_name)
GROUP BY 1 ORDER BY rows DESC"))

####################################################################
### Step 4 -- planilha (fase 1) ou mapa (fase 2)
####################################################################

if (!file.exists(class_path)) {

  message("Step 4: escrevendo o template (fase 1) ...")

  tpl <- dbGetQuery(con, "
    SELECT c.university_name, c.rsid, c.n_rsid, c.n_rows, c.n_users,
           c.n_raw_variants, v.top_raw_variants, c.top_country, c.plausibly_br,
           c.n_bachelor, c.n_master, c.n_phd,
           max(CASE WHEN t.rk = 1 THEN t.txt END) AS cand1,
           max(CASE WHEN t.rk = 2 THEN t.txt END) AS cand2,
           max(CASE WHEN t.rk = 3 THEN t.txt END) AS cand3,
           max(CASE WHEN t.rk = 4 THEN t.txt END) AS cand4,
           max(CASE WHEN t.rk = 5 THEN t.txt END) AS cand5,
           coalesce(c.fold_openalex_id, '') AS openalex_id,
           CASE WHEN c.fold_openalex_id IS NOT NULL THEN 'OK' ELSE '' END AS verdict,
           ''                               AS note,
           coalesce(c.fold_status, '')      AS source
    FROM cut c
    LEFT JOIN variants v USING (university_name)
    LEFT JOIN cand_txt t USING (university_name)
    GROUP BY c.university_name, c.rsid, c.n_rsid, c.n_rows, c.n_users,
             c.n_raw_variants, v.top_raw_variants, c.top_country, c.plausibly_br,
             c.n_bachelor, c.n_master, c.n_phd, c.fold_openalex_id, c.fold_status
    ORDER BY c.n_rows DESC, c.university_name")

  cut_rows <- sum(tpl$n_rows)

  write.csv(tpl, paste0(class_path, ".part"), row.names = FALSE,
            fileEncoding = "UTF-8")
  if (!file.rename(paste0(class_path, ".part"), class_path)) {
    stop("Falha ao renomear o template.", call. = FALSE)
  }

  cat("\n==================================================================\n")
  cat("Fatia nomeada pela Revelio, agregada por escola\n")
  cat("==================================================================\n\n")
  cat(sprintf("  instituicoes no snapshot                    : %s\n",
              format(inst_n, big.mark = ",")))
  cat(sprintf("  linhas sem openalex_id, com university_name : %s\n",
              format(base$rows, big.mark = ",")))
  cat(sprintf("  escolas distintas                           : %s\n",
              format(base$schools, big.mark = ",")))
  cat(sprintf("  grafias university_raw distintas            : %s\n",
              format(base$raw_strings, big.mark = ",")))
  cat(sprintf("  usuarios                                    : %s\n\n",
              format(base$users, big.mark = ",")))

  cat("Dobra contra o snapshot inteiro (de graca):\n")
  print(fold_rep, row.names = FALSE)
  cat("\nCandidatos para o residuo do corte:\n")
  print(cand_rep, row.names = FALSE)

  cat(sprintf("\nTemplate: %s escolas maiores, %s linhas (%.1f%% da fatia)\n",
              format(nrow(tpl), big.mark = ","), format(cut_rows, big.mark = ","),
              100 * cut_rows / base$rows))
  cat(sprintf("  %s\n\n", class_path))
  cat(sprintf("Preenchidas pela dobra: %d de %d. Faltam %d.\n",
              sum(tpl$verdict != ""), nrow(tpl), sum(tpl$verdict == "")))
  cat("\nNas linhas em branco, COPIE o openalex_id de um dos cand1..cand5.\n")
  cat("Nao escreva um id que nao esteja ali -- a fase 2 rejeita (nota 2).\n")
  cat(sprintf("verdict aceita: %s\n", paste(ok_verdicts, collapse = ", ")))
  cat("Confira SEMPRE contra top_raw_variants, nunca so contra\n")
  cat("university_name -- nota 3. Depois rode este script de novo.\n\n")

  stop("Planilha parada para preenchimento (fase 1 concluida).", call. = FALSE)
}

message("Step 4: validando a planilha preenchida (fase 2) ...")

cls <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8")

need <- c("university_name", "openalex_id", "verdict", "note", "source",
          "n_rows", "n_users", "rsid", paste0("cand", 1:n_cand))
if (!all(need %in% names(cls))) {
  stop(sprintf("Planilha sem colunas: %s",
               paste(setdiff(need, names(cls)), collapse = ", ")), call. = FALSE)
}

cls$verdict     <- trimws(as.character(cls$verdict))
cls$openalex_id <- trimws(as.character(cls$openalex_id))
cls$note        <- as.character(cls$note)
cls$source      <- trimws(as.character(cls$source))

blank <- which(cls$verdict == "")
if (length(blank) > 0L) {
  cat("\nLinhas sem verdict (as 10 maiores):\n")
  print(head(cls[blank[order(-cls$n_rows[blank])],
                 c("university_name", "n_rows", "cand1")], 10), row.names = FALSE)
  stop(sprintf("%d de %d linhas ainda sem verdict.", length(blank), nrow(cls)),
       call. = FALSE)
}

bad <- setdiff(unique(cls$verdict), ok_verdicts)
if (length(bad) > 0L) {
  stop(sprintf("verdict invalido: %s", paste(bad, collapse = ", ")), call. = FALSE)
}

miss_id <- cls$verdict %in% c("OK", "OVERRIDE") & cls$openalex_id == ""
if (any(miss_id)) {
  stop(sprintf("%d linhas com verdict OK/OVERRIDE e openalex_id vazio.",
               sum(miss_id)), call. = FALSE)
}
# REVELIO_NAME_WRONG PODE trazer id: o rotulo da Revelio esta errado mas as
# grafias resolvem a instituicao. O mapeamento e correto, so o nome nao e.
has_id <- cls$verdict %in% c("NO_OPENALEX_RECORD", "AMBIGUOUS", "PENDING") &
          cls$openalex_id != ""
if (any(has_id)) {
  stop(sprintf("%d linhas com openalex_id preenchido e verdict que nao o admite.",
               sum(has_id)), call. = FALSE)
}
if (anyDuplicated(cls$university_name) > 0L) {
  stop("university_name duplicado na planilha.", call. = FALSE)
}

# Nota 2, parte dura: o id TEM de existir no snapshot. Nada inventado nem
# digitado errado passa daqui.
ids <- unique(cls$openalex_id[cls$openalex_id != ""])
if (length(ids) > 0L) {
  known <- dbGetQuery(con, sprintf(
    "SELECT DISTINCT oa_id FROM oa_inst WHERE oa_id IN ('%s')",
    paste(ids, collapse = "','")))$oa_id
  ghost <- setdiff(ids, known)
  if (length(ghost) > 0L) {
    cat("\nIds que NAO existem no snapshot do OpenAlex:\n")
    print(cls[cls$openalex_id %in% ghost,
              c("university_name", "openalex_id", "verdict")], row.names = FALSE)
    stop(sprintf("%d openalex_id inexistentes (nota 2).", length(ghost)),
         call. = FALSE)
  }
}

# Nota 2, parte mole: estar entre os candidatos da linha e so um relato.
cand_ids <- apply(cls[, paste0("cand", 1:n_cand)], 1, function(z) {
  paste(na.omit(z), collapse = " ")
})
cls$from_candidates <- as.integer(mapply(
  function(id, pool) id != "" && grepl(id, pool, fixed = TRUE),
  cls$openalex_id, cand_ids))
ovr <- cls$verdict == "OVERRIDE" & trimws(cls$note) == ""
if (any(ovr)) {
  stop(sprintf("%d linhas OVERRIDE sem note explicando.", sum(ovr)), call. = FALSE)
}

# Nota 3: uma planilha sem nenhum REVELIO_NAME_WRONG e suspeita.
if (!any(cls$verdict == "REVELIO_NAME_WRONG") && nrow(cls) >= 500L) {
  warning("Nenhum REVELIO_NAME_WRONG em ", nrow(cls),
          " escolas -- a checagem contra top_raw_variants foi mesmo aplicada?",
          call. = FALSE)
}

cls$source[cls$source == ""] <- "llm"

# Nota 5c: explode para UM rsid por linha. mode(rsid) perderia rsids.
sch_rsid <- dbGetQuery(con, "
  SELECT DISTINCT university_name, rsid FROM named WHERE rsid IS NOT NULL")

pub <- cls[cls$verdict %in% c("OK", "OVERRIDE", "REVELIO_NAME_WRONG") &
             cls$openalex_id != "",
           c("university_name", "openalex_id", "verdict", "source",
             "n_rows", "n_users", "from_candidates")]
n_sch <- nrow(pub)
pub <- merge(pub, sch_rsid, by = "university_name", all.x = TRUE)
pub$safe <- as.integer(pub$source == "fold")
if (anyDuplicated(pub$rsid) > 0L) {
  stop("rsid repetido no mapa: a direcao rsid -> nome nao e funcao aqui.",
       call. = FALSE)
}
pub <- pub[, c("rsid", "university_name", "openalex_id", "verdict", "source",
               "safe", "from_candidates", "n_rows", "n_users")]

dbWriteTable(con, "pub", pub, overwrite = TRUE)
dbExecute(con, sprintf("
COPY (SELECT * FROM pub) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  paste0(map_path, ".part")))
if (!file.rename(paste0(map_path, ".part"), map_path)) {
  stop("Falha ao renomear o mapa.", call. = FALSE)
}

####################################################################
### Relatorio
####################################################################

cat("\n==================================================================\n")
cat("Mapa escola -> openalex_id publicado\n")
cat("==================================================================\n\n")
print(as.data.frame(table(verdict = cls$verdict)), row.names = FALSE)
cat(sprintf("\n  escolas resolvidas : %s\n", format(n_sch, big.mark = ",")))
cat(sprintf("  linhas no mapa     : %s (um rsid por linha, nota 5c)\n",
            format(nrow(pub), big.mark = ",")))
# n_rows/n_users sao POR ESCOLA; somar no grain de rsid conta em dobro
# as 18 escolas com mais de um rsid. Deduplica antes de somar.
pub_sch  <- unique(pub[, c("university_name", "n_rows", "n_users")])
hit_rows <- sum(pub_sch$n_rows)
cat(sprintf("  linhas alcancadas  : %s de %s da fatia nomeada (%.1f%%)\n",
            format(hit_rows, big.mark = ","),
            format(base$rows, big.mark = ","),
            100 * hit_rows / base$rows))
cat(sprintf("  usuarios           : %s\n",
            format(sum(pub_sch$n_users), big.mark = ",")))
cat(sprintf("  destas, pela dobra : %s rsids (safe = 1)\n",
            format(sum(pub$safe), big.mark = ",")))
cat(sprintf("  escolhidas na lista: %s de %s decididas a mao\n",
            format(sum(pub$from_candidates), big.mark = ","),
            format(sum(pub$source != "fold"), big.mark = ",")))
cat(sprintf("\n  %s\n\n", map_path))

drift <- function(nm, got, exp) {
  if (got != exp) {
    warning(sprintf("%s: esperado %d, obtido %d", nm, exp, got), call. = FALSE)
  }
}
drift("fatia nomeada", base$rows, exp_named_rows)
drift("escolas", base$schools, exp_schools)
drift("grafias", base$raw_strings, exp_raw_strings)
drift("instituicoes", inst_n, exp_inst)
