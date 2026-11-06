####################################################################
###
### university_raw strings with NO OpenAlex id                [local only]
###
### README TO-DO item 2 ("Attribute an OpenAlex id to every remaining
### university_raw") records how big the gap is and never lists it.
### This script writes the list.
###
### There is NO openalex_id column on the education rows. "Matched" is
### always a LEFT JOIN onto a separate map, and FOUR maps exist with
### different keys and different coverage:
###
###   rsid_openalex_safe_map.parquet     (8f)  rsid, safe = 1
###   rsid_openalex_id_crosswalk.parquet (8d)  rsid + university_raw
###   shanghai_raw_crosswalk.parquet     (16b) university_raw
###   shanghai_rsid_name_map.parquet     (--)  rsid, keep = 1
###
### The safe map is BRAZIL-ONLY by construction (script 3 filters
### country_code = 'BR'), so under it every foreign university reads as
### unmatched even when its id is already on disk -- Complutense Madrid
### (I24354313), Politecnico di Torino (I99682543), Universita Cattolica,
### Granada, UCF are all resolved by 16b and missed by 8f. Measured, the
### three extra maps resolve 568,642 in-scope rows the safe map does not.
###
### Following the folder rule -- FLAGS ARE STORED, NOT FILTERED -- the
### row-level file carries every in-scope row the SAFE MAP missed, with
### openalex_id and oa_source naming whichever map won. Both readings are
### then a WHERE away:
###
###   the whole file        the README's safe-map baseline
###   oa_source IS NULL     genuinely unresolved by anything on disk
###
### Three products:
###   unmatched_openalex_education_rows.csv  row level, safe-map misses
###   unmatched_openalex_university_raw.csv  one row per string, the
###                                          worksheet the TO-DO needs
###   unmatched_openalex_coverage.csv        rows/users by lvl x source
###
### Depends on:
###   obmep_candidates_step_1_entries.R (10a)   the education directory
###   rsid_openalex_one_to_one.R (8f)
###   rsid_openalex_id_crosswalk.R (8d)
###   shanghai_raw_crosswalk.R (16b)
###   shanghai_rsid_name_map.R
###   br_degree_patterns.R (7)                  sql_shanghai_level, rx_mba
###
### Shape reused from:
###   shanghai_raw_crosswalk.R (parametros + exp_ constants + .part
###   staging); capes_obmep_candidates_name_match.R (the safe-map join)
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Reads one local directory and four local parquets,
###    writes three CSVs and one parquet. Free and re-runnable. Still a
###    prep/ script; not for SEDAP.
### 2. THE DEGREE SCOPE IS THE UNION OF TWO DEFINITIONS, deliberately.
###    Revelio's literal degree IN ('Bachelor','Master','Doctor') and
###    sql_shanghai_level IN ('bachelor','master','phd') with MBA out of
###    the master's arm. Measured on this dataset they disagree hard and
###    asymmetrically: 3,294,087 rows are in scope by level and NOT by
###    degree (797,822 of them unmatched), against 8,580 the other way.
###    Filtering on Revelio's degree alone would silently drop 797,822
###    unmatched rows -- the 58.4%-recall failure script 7 documents.
###    by_level and by_degree ship as columns so either view survives.
### 3. THE FOUR MAPS ARE APPLIED IN PRIORITY ORDER, safe -> 8d ->
###    shanghai_raw -> shanghai_name, and oa_source records the winner.
###    That order is not a quality ranking beyond the first entry; it
###    exists so openalex_id is a function. Only 8f carries the
###    one-to-one safety guarantee. Anything with oa_source <> 'safe_map'
###    is NOT safe-map quality and must not be fed to script 27's key
###    without its own review.
### 4. EACH MAP IS COLLAPSED TO ONE ROW PER KEY with any_value() before
###    the join. 8d is many-to-many on rsid (up to 95 ids on FGV, see its
###    note 9) and would otherwise fan the education rows out. any_value()
###    is arbitrary among the ids -- acceptable here because this script
###    only ever asks WHETHER an id exists, never which one, and the 8d
###    arm resolves 1,917 rows in total.
### 5. university_country IS REVELIO'S OWN FIELD AND IS NOT RELIABLE.
###    The README records University of Michigan reading "Bulgaria" on
###    2,759 rows. plausibly_br in the worksheet is a Revelio label, not
###    a country. Re-derive the country from the resolved OpenAlex record
###    before trusting it -- README TO-DO item 2, caveat 1.
### 6. THE PART FILES HAVE NO .parquet EXTENSION (Athena UNLOAD names
###    them <query-id>_<uuid>). read_parquet('<dir>/*'), never '*.parquet'
###    -- the latter silently matches nothing. See 10a note 5.
### 7. sql_shanghai_level IS TRINO SQL and calls regexp_like(). The
###    DuckDB shim below is mandatory, as in 16, 16a, 16b and 13a.
### 8. THE WORKSHEET DROPS BLANK university_raw, the row file keeps it.
###    university_raw is NULL or '' on a small tail of rows; there is no
###    string there to resolve, so those rows cannot become a worksheet
###    entry. Same predicate rsid_br_user_share.R and 16 use before
###    matching. They stay in the row-level file and are counted as
###    blank_rows in the report, so nothing disappears silently.
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

coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
ed_dir  <- file.path(coh_dir, "obmep_candidates_step_1_education")

safe_path <- file.path(coh_dir, "rsid_openalex_safe_map.parquet")
cw_path   <- file.path(coh_dir, "rsid_openalex_id_crosswalk.parquet")
shr_path  <- file.path(coh_dir, "shanghai_raw_crosswalk.parquet")
snm_path  <- file.path(coh_dir, "shanghai_rsid_name_map.parquet")
sel_path  <- file.path(coh_dir, "obmep_candidates_selected.parquet")

rows_csv <- file.path(coh_dir, "unmatched_openalex_education_rows.csv")
rows_pq  <- file.path(coh_dir, "unmatched_openalex_education_rows.parquet")
str_csv  <- file.path(coh_dir, "unmatched_openalex_university_raw.csv")
cov_csv  <- file.path(coh_dir, "unmatched_openalex_coverage.csv")

deg_path <- Sys.getenv("OBMEP_DEGREE_PATTERNS",
                       unset = file.path("prep", "building_external_data",
                                         "br_degree_patterns.R"))

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")
tmp_dir   <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_unmatched_oa")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

# Medidos nesta base. Divergencia e sinal de dado novo -- warning, nao stop,
# exceto onde a invariante e estrutural.
exp_in_scope  <- 8505225L   # linhas bachelor/master/phd pelas DUAS definicoes
exp_rowfile   <- 3400791L   # linhas que o safe map (8f) nao resolve
exp_unmatched <- 2832149L   # linhas que NENHUM dos quatro mapas resolve
exp_users     <- 2427991L
exp_strings   <- 361382L    # university_raw distintos ainda sem id (nao vazios)
exp_br_rows   <- 104388L    # dos nao resolvidos, rotulados Brazil por Revelio

# Regressao contra a tabela do TO-DO item 2 do README. E a checagem cruzada
# mais forte deste script: escopo por NIVEL apenas, candidatos SELECIONADOS
# apenas, safe map apenas -- as tres restricoes que produziram aqueles numeros.
exp_readme <- data.frame(
  lvl      = c("bachelor", "master", "phd"),
  rows     = c(1538367L, 401676L, 79968L),
  users    = c(1294203L, 354850L, 75536L),
  resolved = c(930509L, 150522L, 44096L),
  stringsAsFactors = FALSE
)
exp_readme_unmatched <- 894884L

stopifnot(dir.exists(ed_dir),
          length(Sys.glob(file.path(ed_dir, "*"))) > 0L,
          file.exists(safe_path), file.exists(cw_path),
          file.exists(shr_path), file.exists(snm_path),
          file.exists(sel_path), file.exists(deg_path))

source(deg_path)
stopifnot(exists("sql_shanghai_level"), exists("rx_mba"))

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

# Nota 7: sql_shanghai_level e SQL do Trino.
dbExecute(con, "CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)")

ed_src <- sprintf("read_parquet('%s/*')", ed_dir)

####################################################################
### Step 1 -- escopo e os quatro mapas
####################################################################

message("Step 1: montando escopo e juntando os quatro mapas ...")

dbExecute(con, sprintf("
CREATE OR REPLACE TEMP TABLE j AS
WITH e AS (
  SELECT user_id, university_raw, university_name, rsid,
         degree, degree_raw, university_country, startdate, enddate,
         lower(trim(coalesce(degree_raw, ''))) AS dr
  FROM %s
),
lv AS (
  SELECT e.*, %s AS lvl,
         (degree = 'MBA' OR regexp_like(dr, '%s')) AS is_mba
  FROM e
),
g AS (
  SELECT *,
         (lvl IN ('bachelor','master','phd') AND NOT (lvl = 'master' AND is_mba)) AS by_level,
         (degree IN ('Bachelor','Master','Doctor'))                               AS by_degree
  FROM lv
  WHERE (lvl IN ('bachelor','master','phd') AND NOT (lvl = 'master' AND is_mba))
     OR degree IN ('Bachelor','Master','Doctor')
),
m_safe AS (
  SELECT rsid, any_value(openalex_id) AS oa
  FROM read_parquet('%s') WHERE safe = 1 GROUP BY rsid
),
m_cw AS (
  SELECT rsid, university_raw, any_value(openalex_id) AS oa
  FROM read_parquet('%s') GROUP BY rsid, university_raw
),
m_shr AS (
  SELECT university_raw, any_value(openalex_id) AS oa
  FROM read_parquet('%s')
  WHERE by_acronym = 0 OR acr_label = 'OK'
  GROUP BY university_raw
),
m_snm AS (
  SELECT rsid, any_value(openalex_id) AS oa
  FROM read_parquet('%s') WHERE keep = 1 GROUP BY rsid
)
SELECT g.user_id, g.university_raw, g.university_name, g.rsid,
       g.degree, g.degree_raw, g.lvl, g.is_mba, g.by_level, g.by_degree,
       g.university_country, g.startdate, g.enddate,
       s.oa AS oa_safe,
       coalesce(s.oa, c.oa, h.oa, n.oa) AS openalex_id,
       CASE WHEN s.oa IS NOT NULL THEN 'safe_map'
            WHEN c.oa IS NOT NULL THEN 'crosswalk_8d'
            WHEN h.oa IS NOT NULL THEN 'shanghai_raw'
            WHEN n.oa IS NOT NULL THEN 'shanghai_name'
       END AS oa_source
FROM g
LEFT JOIN m_safe s ON g.rsid = s.rsid
LEFT JOIN m_cw   c ON g.rsid = c.rsid AND g.university_raw = c.university_raw
LEFT JOIN m_shr  h ON g.university_raw = h.university_raw
LEFT JOIN m_snm  n ON g.rsid = n.rsid",
  ed_src, sql_shanghai_level, rx_mba,
  safe_path, cw_path, shr_path, snm_path))

tot <- dbGetQuery(con, "
SELECT count(*) AS in_scope,
       sum(CASE WHEN oa_safe     IS NULL THEN 1 ELSE 0 END) AS rowfile_rows,
       sum(CASE WHEN openalex_id IS NULL THEN 1 ELSE 0 END) AS unmatched_rows,
       count(DISTINCT CASE WHEN openalex_id IS NULL THEN user_id END)        AS unmatched_users,
       count(DISTINCT CASE WHEN openalex_id IS NULL AND university_raw IS NOT NULL
                            AND trim(university_raw) <> ''
                           THEN university_raw END) AS strings,
       sum(CASE WHEN openalex_id IS NULL AND university_country = 'Brazil'
                THEN 1 ELSE 0 END) AS br_rows,
       sum(CASE WHEN openalex_id IS NULL AND (university_raw IS NULL
                                              OR trim(university_raw) = '')
                THEN 1 ELSE 0 END) AS blank_rows
FROM j")

####################################################################
### Step 2 -- CSV linha a linha (o que o safe map nao resolveu)
####################################################################

message("Step 2: exportando o arquivo linha a linha ...")

sel_cols <- "user_id, university_raw, university_name, rsid,
             degree, degree_raw, lvl, is_mba, by_level, by_degree,
             university_country, startdate, enddate, openalex_id, oa_source"

dbExecute(con, sprintf("
COPY (SELECT %s FROM j WHERE oa_safe IS NULL
      ORDER BY openalex_id IS NULL DESC, university_raw, user_id)
TO '%s' (FORMAT CSV, HEADER, DELIMITER ',')", sel_cols, paste0(rows_csv, ".part")))

dbExecute(con, sprintf("
COPY (SELECT %s FROM j WHERE oa_safe IS NULL)
TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", sel_cols, paste0(rows_pq, ".part")))

####################################################################
### Step 3 -- a planilha: uma linha por university_raw sem id
####################################################################

message("Step 3: agregando por university_raw ...")

dbExecute(con, sprintf("
COPY (
  SELECT university_raw,
         mode(university_name)                             AS university_name,
         count(DISTINCT university_name)                   AS n_names,
         mode(rsid)                                        AS rsid,
         count(DISTINCT rsid)                              AS n_rsid,
         count(*)                                          AS n_rows,
         count(DISTINCT user_id)                           AS n_users,
         sum(CASE WHEN lvl = 'bachelor' THEN 1 ELSE 0 END) AS n_bachelor,
         sum(CASE WHEN lvl = 'master'   THEN 1 ELSE 0 END) AS n_master,
         sum(CASE WHEN lvl = 'phd'      THEN 1 ELSE 0 END) AS n_phd,
         mode(university_country)                          AS top_country,
         max(CASE WHEN university_country = 'Brazil' THEN 1 ELSE 0 END) AS plausibly_br,
         ''  AS openalex_id,
         ''  AS note
  FROM j
  WHERE openalex_id IS NULL
    AND university_raw IS NOT NULL AND trim(university_raw) <> ''
  GROUP BY university_raw
  ORDER BY plausibly_br DESC, n_rows DESC, university_raw
) TO '%s' (FORMAT CSV, HEADER, DELIMITER ',')", paste0(str_csv, ".part")))

####################################################################
### Step 4 -- cobertura por nivel x mapa
####################################################################

message("Step 4: tabela de cobertura ...")

dbExecute(con, sprintf("
COPY (
  SELECT lvl, coalesce(oa_source, '(unmatched)') AS oa_source,
         count(*) AS n_rows, count(DISTINCT user_id) AS n_users
  FROM j GROUP BY lvl, oa_source ORDER BY lvl, n_rows DESC
) TO '%s' (FORMAT CSV, HEADER, DELIMITER ',')", paste0(cov_csv, ".part")))

####################################################################
### Validacao
####################################################################

message("Validacao ...")

# Regressao contra o README: escopo por nivel, selecionados, safe map.
readme <- dbGetQuery(con, sprintf("
WITH e AS (
  SELECT x.user_id, x.rsid, x.degree,
         lower(trim(coalesce(x.degree_raw, ''))) AS dr
  FROM %s x
  JOIN read_parquet('%s') s USING (user_id)
),
lv AS (SELECT e.*, %s AS lvl,
              (degree = 'MBA' OR regexp_like(dr, '%s')) AS is_mba FROM e),
m AS (SELECT rsid, any_value(openalex_id) AS oa
      FROM read_parquet('%s') WHERE safe = 1 GROUP BY rsid)
SELECT lv.lvl AS lvl, count(*) AS rows, count(DISTINCT lv.user_id) AS users,
       sum(CASE WHEN m.oa IS NOT NULL THEN 1 ELSE 0 END) AS resolved
FROM lv LEFT JOIN m ON lv.rsid = m.rsid
WHERE lv.lvl IN ('bachelor','master','phd') AND NOT (lv.lvl = 'master' AND lv.is_mba)
GROUP BY lv.lvl ORDER BY lv.lvl",
  ed_src, sel_path, sql_shanghai_level, rx_mba, safe_path))

got <- readme[match(exp_readme$lvl, readme$lvl), ]
if (!isTRUE(all.equal(got[, c("rows", "users", "resolved")],
                      exp_readme[, c("rows", "users", "resolved")],
                      check.attributes = FALSE))) {
  print(readme); print(exp_readme)
  stop("Regressao do README quebrou: a tabela do TO-DO item 2 nao reproduz.",
       call. = FALSE)
}
readme_unmatched <- sum(got$rows) - sum(got$resolved)
if (readme_unmatched != exp_readme_unmatched) {
  stop(sprintf("README: esperado %d nao resolvidos, obtido %d",
               exp_readme_unmatched, readme_unmatched), call. = FALSE)
}

# Invariantes estruturais deste script.
by_src <- dbGetQuery(con, "
SELECT coalesce(oa_source, '(unmatched)') AS src, count(*) AS n
FROM j GROUP BY 1")
stopifnot(sum(by_src$n) == tot$in_scope)

chk <- dbGetQuery(con, "
SELECT sum(CASE WHEN oa_source IS NULL AND openalex_id IS NOT NULL THEN 1 ELSE 0 END) AS a,
       sum(CASE WHEN oa_source IS NOT NULL AND openalex_id IS NULL THEN 1 ELSE 0 END) AS b,
       sum(CASE WHEN oa_source = 'safe_map' AND oa_safe IS NULL THEN 1 ELSE 0 END)     AS c
FROM j")
if (any(unlist(chk) != 0L)) {
  stop("openalex_id e oa_source discordam.", call. = FALSE)
}

# Nota 3: estrangeiras que o safe map perde e o 16b resolve.
spot <- dbGetQuery(con, "
SELECT university_raw, any_value(openalex_id) AS oa, any_value(oa_source) AS src
FROM j
WHERE university_raw IN ('Universidad Complutense de Madrid',
                         'Politecnico di Torino',
                         'Universidad de Granada',
                         'University of Central Florida')
GROUP BY university_raw")
if (nrow(spot) > 0L && (any(is.na(spot$oa)) || any(spot$src == "safe_map"))) {
  print(spot)
  stop("Uniao dos mapas nao esta ligada: instituicao estrangeira sem id.",
       call. = FALSE)
}

# Deriva -- warning, nao stop.
drift <- function(nm, got, exp) {
  if (got != exp) {
    warning(sprintf("%s: esperado %d, obtido %d", nm, exp, got), call. = FALSE)
  }
}
drift("in_scope",     tot$in_scope,        exp_in_scope)
drift("rowfile_rows", tot$rowfile_rows,    exp_rowfile)
drift("unmatched",    tot$unmatched_rows,  exp_unmatched)
drift("users",        tot$unmatched_users, exp_users)
drift("strings",      tot$strings,         exp_strings)
drift("br_rows",      tot$br_rows,         exp_br_rows)

# So agora os .part viram definitivos.
for (p in list(c(rows_csv, "rows CSV"), c(rows_pq, "rows parquet"),
               c(str_csv, "worksheet"), c(cov_csv, "coverage"))) {
  if (!file.rename(paste0(p[1], ".part"), p[1])) {
    stop(sprintf("Falha ao renomear %s", p[2]), call. = FALSE)
  }
}

# A planilha nao pode sair com id preenchido -- ela e o pedido, nao a resposta.
ws_n <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n,
          sum(CASE WHEN openalex_id IS NOT NULL AND openalex_id <> ''
                   THEN 1 ELSE 0 END) AS filled
   FROM read_csv('%s', header = TRUE, all_varchar = TRUE)", str_csv))
if (!identical(as.integer(ws_n$filled), 0L)) {
  stop("Planilha saiu com openalex_id preenchido.", call. = FALSE)
}
if (ws_n$n != tot$strings) {
  stop(sprintf("Planilha tem %d linhas, esperado %d", ws_n$n, tot$strings),
       call. = FALSE)
}

####################################################################
### Relatorio
####################################################################

cat("\n==================================================================\n")
cat("university_raw sem openalex_id -- obmep_candidates_step_1_education\n")
cat("==================================================================\n\n")

cat(sprintf("Linhas no escopo (bachelor/master/phd, uniao das duas definicoes): %s\n",
            format(tot$in_scope, big.mark = ",")))
cat(sprintf("  nao resolvidas pelo safe map (8f)     : %s   <- arquivo linha a linha\n",
            format(tot$rowfile_rows, big.mark = ",")))
cat(sprintf("  nao resolvidas por NENHUM dos 4 mapas : %s\n",
            format(tot$unmatched_rows, big.mark = ",")))
cat(sprintf("  usuarios atingidos                    : %s\n",
            format(tot$unmatched_users, big.mark = ",")))
cat(sprintf("  university_raw distintos sem id       : %s\n",
            format(tot$strings, big.mark = ",")))
cat(sprintf("  destes, rotulados Brazil pela Revelio : %s linhas (nota 5)\n",
            format(tot$br_rows, big.mark = ",")))
cat(sprintf("  destes, university_raw vazio          : %s linhas (nota 8, fora da planilha)\n\n",
            format(tot$blank_rows, big.mark = ",")))

cat("Cobertura por mapa:\n")
print(by_src[order(-by_src$n), ], row.names = FALSE)

cat("\nRegressao do README (TO-DO item 2) -- reproduz:\n")
print(got, row.names = FALSE)

cat("\nArquivos:\n")
for (p in c(rows_csv, rows_pq, str_csv, cov_csv)) {
  cat(sprintf("  %-52s %8.1f MB\n", basename(p), file.size(p) / 1024^2))
}
cat("\nA planilha esta ordenada Brazilian-first (plausibly_br, n_rows):\n")
cat("preencha openalex_id e note, e volte por ela.\n\n")
