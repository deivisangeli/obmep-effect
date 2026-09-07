####################################################################
###
### Employer flags for the candidate pool               -> Dropbox
###
### One question for every cohort member: did this person ever hold a
### position at
###
###   a Hurun top-200 TECH UNICORN (2023-2026),
###   a top-200 TECH FIRM BY MARKET CAP,
###   a Brazilian university in the RUF 2025 TOP 10 of any of the 12
###   STEM courses, or
###   a university in the SHANGHAI TOP 1000?
###
### The first two are answered through Revelio's company key, rcid.
### The last two are answered by name, because a university is not on
### either company list and Revelio has no ranking of its own.
###
### Two outputs, both one grain apart:
###
###   obmep_candidates_step_1_firms_positions.parquet  one row per
###                                                    MATCHED POSITION
###   obmep_candidates_step_1_firms.parquet            one row per
###                                                    FLAGGED USER
###
### The position-level file exists so that every user-level flag is
### auditable back to the row that set it. It is not an intermediate.
###
### Depends on:
###   obmep_candidates_step_1_entries.R      (position extract, 10a)
###   obmep_candidates_step_1_position_rcid.R (rcid extract, 10b)
###   linkedin_company_rcid.R                (the resolved rcid list)
###   ruf_stem_top50.R                       (rank_cut = 10)
###   ruf_openalex_br_crosswalk.R            (the OpenAlex spellings)
###   shanghai_ranking_openalex_names.R      (the Shanghai top-1000, 4)
###
### NO NETWORK. Reads local parquet, writes local parquet. It is still
### a prep/ script and still must not be sent to SEDAP, because
### everything it depends on came from Athena. See AGENTS.md ->
### Execution Environments.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. THE FIRM SIDE IS A JOIN, NOT A MATCH. rcid is an identifier, so
###    the firm arms cannot be wrong about identity in the way a name
###    match can. Everything fragile about this script is on the RUF
###    side and in which rcids reached the list in the first place --
###    see linkedin_company_rcid.R notes 4 and 8.
### 2. rcid IS bigint ON THE POSITION SIDE AND WAS int ON
###    academic_company_ref. The list arrives already CAST to BIGINT;
###    the casts below are belt and braces and should stay.
### 3. THREE FIRM ARMS, AND THEY ARE STORED SEPARATELY ON PURPOSE.
###      exact  : position.rcid IS a listed rcid
###      parent : position.ultimate_parent_rcid is a listed rcid, so a
###               subsidiary counts for its parent
###      arm 3  : the listed LinkedIn URL that academic_company_ref did
###               not carry, recovered from the cohort's OWN positions
###    `_exact` and `_parent` sit side by side rather than being merged
###    because the folder stores the narrower version of every
###    widening: the rollup can be reversed with a WHERE clause instead
###    of a rebuild. Same reason `un_arm3` is its own column.
### 4. ARM 3 IS FREE, EXACT, AND LIMITED. 53 listed URLs resolve to
###    nothing in academic_company_ref, because LinkedIn lets a company
###    page carry a vanity slug beside its canonical one and the two
###    sources recorded different ones. The position extract carries
###    company_linkedin_url as scraped from the profile, so joining the
###    listed URL to it recovers the rcid Revelio actually uses. It is
###    still exact equality on a URL -- no name matching enters here.
###    A URL is accepted ONLY if it maps to exactly one rcid across the
###    whole cohort; more than one is reported and skipped, because
###    picking the commonest would be a threshold nobody chose.
###    It cannot recover a firm no cohort member ever worked at, which
###    is fine: such a firm could not have produced a match anyway.
### 5. THE UNIVERSITY SIDES ARE CRITERION C_NORM, the standard match
###    (README "C_norm"): fold accents, compare lowercased, accept the
###    whole string or any `/`, `(`, `)`, `" - "` delimited segment of
###    at least 3 characters. Same classifier as
###    shanghai_top1000_degree_flags.R, run once per source column so
###    the only difference between the two columns is which column
###    they read. classify() takes its institution tables as arguments
###    and is run FOUR times: two columns x two lists (RUF, Shanghai).
###    Its output columns are neutral -- m_rank / m_id / m_inst -- so
###    that nothing in the classifier knows which list it served.
### 6. THE SEGMENT ARM IS INERT ON company_cleaned, and that is not a
###    bug. Revelio has already stripped the punctuation the split
###    keys on -- `Secretaria Municipal de Saude - SESAU` arrives as
###    `secretaria municipal de saude sesau`. The arm is applied to
###    both columns anyway so the two get identical treatment; it just
###    only ever fires on company_raw.
### 7. THE ACRONYM ARM IS SEPARATE BECAUSE IT IS THE DANGEROUS ONE.
###    `rf_abbr` matches the bare abbreviation on WHOLE-STRING equality
###    only, never through a segment. USP is also United States
###    Pharmacopeia, FEI is also an unrelated manufacturer, ITA and UEM
###    and UFG are three letters. Keeping it in its own column means a
###    consumer who does not want it writes `WHERE rf_abbr = 0` rather
###    than asking for a rebuild. Read the strings it matched, printed
###    in full at the end, before using it. IT EXISTS ONLY ON THE RUF
###    SIDE -- see nota 12.
### 8. THE UNIVERSITY ARMS FLAG EMPLOYMENT, NOT STUDY. Here the person
###    had to have WORKED there -- which in Brazil mostly means
###    faculty, staff, or a scholarship-funded research post recorded
###    as a position. Each list is asked BOTH questions, in different
###    scripts, and the four prefixes are easy to confuse:
###
###      sh_  STUDIED at a Shanghai top-1000   shanghai_top1000_degree_flags.R
###      sw_  WORKED  at a Shanghai top-1000   HERE
###      rd_  STUDIED at a RUF top-10 STEM     obmep_candidates_step_1_ruf_degree.R
###      rf_  WORKED  at a RUF top-10 STEM     HERE
###
###    So someone with a USP degree is flagged by sh_ and rd_, not by
###    sw_ or rf_. This script writes only the two `worked` columns.
### 9. ONLY FLAGGED USERS ARE WRITTEN, as script 16 does. Left-joining
###    back to obmep_candidates_step_1 and treating a missing row as
###    zero is the consumer's job.
###10. startdate IS A STRING ON THE POSITION TABLE, not a DATE --
###    README trap 1. Years come from substr(), never from year().
###11. THE SCHOOL-PAGE DIAGNOSTIC AT THE END IS A FLOOR, NOT A
###    MEASUREMENT. It joins the linkedin.com/school/<slug> tail to the
###    folded ABBREVIATION, so it only sees institutions whose slug
###    happens to be their acronym -- 9 of the 23. The real recall gap
###    is larger than the number it prints. It is there to be a floor
###    that cannot be argued with, not an estimate. It is RUF-ONLY: it
###    joins the folded abbreviation, and there is no Shanghai
###    abbreviation table to join.
###12. THE SHANGHAI ARM HAS NO ACRONYM ARM, and that is a property of
###    the source, not a choice about risk. shanghai_ranking_oa.parquet
###    carries no abbreviation column -- there is nothing to fold. The
###    acronyms were reachable by joining OA_id to the OpenAlex
###    display_name_acronyms, and that was deliberately not done. The
###    line this draws is clean: an acronym arm exists exactly where
###    the source supplies acronyms. So the Shanghai list matches bare
###    acronyms on NEITHER side -- script 16 already carries the same
###    limitation for degrees, `MIT` or `Cambridge` alone is not found.
###    inst_ab_sh is created empty so classify() keeps ONE code path,
###    and the script aborts if the acronym arm ever fires on it.
###
###    THE HOMONYM EXPOSURE IS LARGER HERE than on the RUF side: 1,000
###    institutions worldwide against 23 Brazilian ones. Script 16
###    already documents a Philippine campus reaching the American
###    Saint Louis University through the segment arm. Teaching
###    hospitals and affiliated institutes are a second source of
###    near-misses. Both are reported, not fixed -- sw_by_raw, sw_rank
###    and sw_inst are what make a suspect match auditable.
###
### -----------------------------------------------------------------
### MEASURED, run of 2026-08-29 (four lists)
### -----------------------------------------------------------------
###   matched positions           737,682
###   FLAGGED USERS               436,813   -- 6.38% of the cohort
###
###     un_any   28,735    exact 24,465   parent 24,379
###     tc_any  159,638    exact 118,752  parent 145,188
###     rf_any  142,151    name  129,389  abbr    15,423
###     sw_any  233,290    (name only -- no acronym arm, nota 12)
###
###   THE THREE OLD ARMS DID NOT MOVE. classify() was refactored to
###   take its institution tables as arguments; un_/tc_/rf_ matching
###   to the digit against the 2026-08-28 run is what proves the
###   refactor was behaviour-preserving. If they ever move, the
###   refactor broke and no other number will tell you.
###
###   The Shanghai arm adds 116,541 users no other arm reached.
###     sw_only 116,541   sw_and_rf 109,400   rf_not_sw 32,751
###
###   rf_not_sw IS EXPLAINED AND IS NOT A LEAK. Only 14 of the 23 RUF
###   institutions are in the Shanghai top-1000, so 9 of them CANNOT
###   have an sw_ match: UTFPR (6,467 users), UFBA (4,206), UFU
###   (4,077), UFLA (3,136), UFABC (3,026), UEM (2,737), Maua (944),
###   FEI (805), ITA (561) -- 25,959 of the 32,751. Nearly all the
###   rest came in through the acronym arm, which sw_ does not have:
###   9,628 of the 32,751 have rf_name_any = 0, e.g. UFMG 1,609 of
###   1,619 and UFRGS 1,062 of 1,064. Do not "fix" this.
###
###   arm 3 recovered 13 of the 53 unresolved URLs -- Zoom, Cadence,
###   Coherent, Block, X, Mihoyo, Glean, Lambda Labs, Reify Health,
###   Dewu, JDT, Yangtze Memory, GTA Semiconductor -- worth 499
###   unicorn users and 717 market-cap users. Gen Digital was the one
###   rejection: its URL maps to 2 rcids in the cohort's positions.
###
###   The orderings are the check that matters, and they read right.
###   Unicorns: QuintoAndar 4,543, Creditas 3,730, Rappi 3,138,
###   Didi 2,964, SumUp 1,423, Kavak 1,132 -- a Brazilian cohort's
###   unicorn employers are Brazilian unicorns. Market cap: IBM
###   18,612, Amazon 17,188, Uber 11,458, Alphabet 8,436, Microsoft
###   7,571. RUF: USP 19,303, UFMG 12,521, UFRJ 12,294, Unicamp
###   10,846, which is the RUF ordering itself. Shanghai: USP 19,040,
###   UNESP 13,465, UFRJ 11,251, UFMG 10,740, Unicamp 10,575 -- a
###   Brazilian cohort's top-1000 employers are Brazilian, as they
###   should be, and the first non-Brazilian entry is University of
###   Florida at 1,344, an order of magnitude down.
###
###   THE ACRONYM ARM CAME OUT CLEAN, contrary to the worry in note 7.
###   Every one of the 30 strings it alone matched is an unambiguous
###   Brazilian university acronym typed as an employer -- UTFPR,
###   UFMG, UNESP, UFRGS, UFRJ, UFPE, UFPR, UFSCar, USP, FEI, ITA and
###   their case variants. No United States Pharmacopeia, no unrelated
###   FEI. That is a property of THIS cohort, which is Brazilian by
###   construction, and it would not survive being pointed at a
###   general population. The column stays separate anyway.
###
###   The school-page floor (note 11): 3,211 positions point at one of
###   9 institutions' LinkedIn school pages without any name arm
###   catching them, against ~200k matched. The name match is not
###   complete and was never going to be.
###
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

coh_root  <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
pos_dir   <- file.path(coh_root, "obmep_candidates_step_1_position")
rcid_dir  <- file.path(coh_root, "obmep_candidates_step_1_position_rcid")
coh_path  <- file.path(coh_root, "obmep_candidates_step_1.parquet")

firm_path  <- file.path(obmep_root, "Data/intermediate/linkedin_company_urls",
                        "linkedin_company_rcid_2026.parquet")
unres_path <- file.path(obmep_root, "Data/intermediate/linkedin_company_urls",
                        "linkedin_company_unresolved_2026.parquet")

ruf_dir   <- file.path(obmep_root, "Data/intermediate/ruf_ranking")
ruf_inst  <- file.path(ruf_dir, "ruf_stem_top10_institutions_2025.parquet")
ruf_oa    <- file.path(ruf_dir, "ruf_openalex_br_2025.parquet")

sh_path   <- file.path(obmep_root,
                       "Data/intermediate/shanghai_ranking/shanghai_ranking_oa.parquet")

out_pos  <- file.path(coh_root, "obmep_candidates_step_1_firms_positions.parquet")
out_user <- file.path(coh_root, "obmep_candidates_step_1_firms.parquet")

mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "12GB")

# Corte do top 1000 do Shanghai. E o inicio da ultima faixa, nao 1000 --
# a mesma aritmetica do script 16, nota 1 de la. Ver nota 12.
rank_cut <- 901L

# Measured upstream. Drift warns.
exp_pos_rows <- 30389044
exp_cohort   <- 6849674
exp_ruf_inst <- 23L
exp_sh_top   <- 1000L

for (f in c(firm_path, unres_path, ruf_inst, ruf_oa, sh_path, coh_path)) {
  if (!file.exists(f)) stop("Nao encontrei ", f)
}
for (d in c(pos_dir, rcid_dir)) {
  if (!dir.exists(d) || length(list.files(d)) == 0) {
    stop("Nao encontrei o diretorio de partes ", d)
  }
}

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_firms")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

fw <- function(p) gsub("\\\\", "/", p)
# Bare `*`: the Athena UNLOAD parts are named <query-id>_<uuid> with NO
# .parquet extension, so a glob on the extension finds nothing.
pos_src  <- sprintf("read_parquet('%s/*')", fw(pos_dir))
rcid_src <- sprintf("read_parquet('%s/*')", fw(rcid_dir))
# O ranking de Shanghai e um arquivo unico, nao um UNLOAD: glob normal.
sh_src   <- sprintf("read_parquet('%s')", fw(sh_path))

# The same URL folding linkedin_company_rcid.R used, so the two sides
# agree by construction. No backslashes -- README trap 4.
norm_url <- function(col) {
  sprintf(
    "regexp_replace(regexp_replace(regexp_replace(regexp_replace(
       lower(trim(%s)), '^https?://', ''), '^www[.]', ''), '[?#].*$', ''), '/+$', '')",
    col)
}

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# temp_directory explicito: o derrame para disco nao pode cair em pasta
# sincronizada pelo Dropbox.
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

cat("DuckDB    :", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("posicoes  :", pos_dir, "\n")
cat("rcid      :", rcid_dir, "\n")
cat("empresas  :", firm_path, "\n")
cat("RUF       :", ruf_inst, "\n")
cat("Shanghai  :", sh_path, "\n")
cat("saidas    :", basename(out_pos), "|", basename(out_user), "\n\n")

n_pos <- dbGetQuery(con, sprintf("SELECT count(*) n FROM %s", pos_src))$n
n_rc  <- dbGetQuery(con, sprintf("SELECT count(*) n FROM %s", rcid_src))$n
cat("linhas de posicao         :", format(n_pos, big.mark = ","), "\n")
cat("linhas do extrato de rcid :", format(n_rc, big.mark = ","), "\n")
if (n_pos != n_rc) {
  stop("The two position extracts have different row counts (", n_pos, " / ",
       n_rc, "). They must come from the same Revelio snapshot; see ",
       "obmep_candidates_step_1_position_rcid.R note 5.")
}
if (n_pos != exp_pos_rows) warning("Position rows: ", n_pos, ", expected ", exp_pos_rows)

####################################################################
### A -- o lado das empresas: a lista de rcid, mais o braco 3
####################################################################

cat("\n=========== EMPRESAS ===========\n")
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE firm0 AS SELECT * FROM read_parquet('%s')", fw(firm_path)))
n_firm0 <- dbGetQuery(con, "SELECT count(*) n FROM firm0")$n
cat("rcids resolvidos por URL  :", n_firm0, "\n")

# Braco 3, nota 4. A URL listada que academic_company_ref nao tinha,
# procurada nas proprias posicoes do cohort.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE cand3 AS
  WITH miss AS (SELECT * FROM read_parquet('%s')),
  urlmap AS (
    SELECT %s AS url_norm, r.rcid, count(*) AS n_pos
    FROM %s p JOIN %s r ON p.position_id = r.position_id
    WHERE p.company_linkedin_url IS NOT NULL AND r.rcid IS NOT NULL
    GROUP BY 1, 2
  )
  SELECT m.lst, m.ident, m.nm, m.url_norm,
         count(DISTINCT u.rcid) AS n_rcid,
         min(u.rcid)            AS rcid,
         sum(u.n_pos)           AS n_pos
  FROM miss m JOIN urlmap u ON m.url_norm = u.url_norm
  GROUP BY 1, 2, 3, 4",
  fw(unres_path), norm_url("p.company_linkedin_url"), pos_src, rcid_src))

amb3 <- dbGetQuery(con, "SELECT * FROM cand3 WHERE n_rcid > 1 ORDER BY nm")
cat("\n--- braco 3: URLs recuperadas das posicoes do cohort (nota 4) ---\n")
ok3 <- dbGetQuery(con, "
  SELECT lst, nm, url_norm, rcid, n_pos FROM cand3 WHERE n_rcid = 1 ORDER BY lst, nm")
if (nrow(ok3)) print(ok3, row.names = FALSE) else cat("  (nenhuma)\n")
if (nrow(amb3)) {
  cat("\n  DESCARTADAS -- a mesma URL aponta para mais de um rcid:\n")
  print(amb3[, c("lst", "nm", "url_norm", "n_rcid")], row.names = FALSE)
}

# A lista final. arm3 fica numa coluna propria (nota 3).
dbExecute(con, "
  CREATE OR REPLACE TABLE firm AS
  SELECT rcid, in_unicorn, in_techcap, un_canonical_name, un_best_rank,
         tc_rank, tc_name, ref_primary_name, 0 AS arm3
  FROM firm0
  UNION ALL
  SELECT CAST(c.rcid AS BIGINT),
         CASE WHEN c.lst = 'unicorn' THEN 1 ELSE 0 END,
         CASE WHEN c.lst = 'techcap' THEN 1 ELSE 0 END,
         CASE WHEN c.lst = 'unicorn' THEN c.nm END,
         NULL,
         CASE WHEN c.lst = 'techcap' THEN try_cast(c.ident AS INTEGER) END,
         CASE WHEN c.lst = 'techcap' THEN c.nm END,
         NULL, 1
  FROM cand3 c
  WHERE c.n_rcid = 1
    AND NOT EXISTS (SELECT 1 FROM firm0 f WHERE f.rcid = CAST(c.rcid AS BIGINT))")

dup <- dbGetQuery(con, "
  SELECT rcid, count(*) n FROM firm GROUP BY 1 HAVING count(*) > 1")
if (nrow(dup)) {
  print(dup, row.names = FALSE)
  stop("The firm list is not unique on rcid; a join on it would fan out.")
}

fsum <- dbGetQuery(con, "
  SELECT arm3, sum(in_unicorn) AS unicorn, sum(in_techcap) AS techcap,
         count(*) AS rcids FROM firm GROUP BY 1 ORDER BY 1")
cat("\n")
print(fsum, row.names = FALSE)

####################################################################
### B -- o lado das universidades: as grafias das 23 do RUF
####################################################################

cat("\n=========== RUF ===========\n")
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE ruf AS
  SELECT i.ruf_institution_id, i.institution_name, i.abbr, i.uf,
         i.best_rank, i.n_courses_top10,
         o.display_name, o.cleaned_display_name
  FROM read_parquet('%s') i
  LEFT JOIN read_parquet('%s') o USING (ruf_institution_id)",
  fw(ruf_inst), fw(ruf_oa)))

n_ruf <- dbGetQuery(con, "SELECT count(*) n FROM ruf")$n
if (n_ruf != exp_ruf_inst) {
  warning("RUF top-10 tem ", n_ruf, " instituicoes, esperava ", exp_ruf_inst)
}
miss_oa <- dbGetQuery(con, "SELECT count(*) n FROM ruf WHERE display_name IS NULL")$n
if (miss_oa > 0) {
  warning(miss_oa, " RUF institutions have no OpenAlex spelling; the name arm ",
          "runs on the RUF name alone for those.")
}

# Tres grafias completas por instituicao, dobradas e deduplicadas --
# a mesma construcao do script 16. A sigla NAO entra aqui: ela tem o
# seu proprio braco, com regra diferente (nota 7).
dbExecute(con, "
  CREATE OR REPLACE TABLE inst AS
  SELECT lower(strip_accents(trim(nm)))       AS nm_fold,
         min(best_rank)                       AS best_rank,
         arg_min(ruf_institution_id, best_rank) AS rid,
         arg_min(abbr, best_rank)             AS inst_name
  FROM (
    SELECT institution_name     AS nm, best_rank, ruf_institution_id, abbr FROM ruf
    UNION ALL
    SELECT display_name,         best_rank, ruf_institution_id, abbr FROM ruf
    UNION ALL
    SELECT cleaned_display_name, best_rank, ruf_institution_id, abbr FROM ruf
  )
  WHERE nm IS NOT NULL AND length(trim(nm)) >= 3
  GROUP BY 1")

dbExecute(con, "
  CREATE OR REPLACE TABLE inst_ab AS
  SELECT lower(strip_accents(trim(abbr)))     AS nm_fold,
         min(best_rank)                       AS best_rank,
         arg_min(ruf_institution_id, best_rank) AS rid,
         arg_min(abbr, best_rank)             AS inst_name
  FROM ruf
  WHERE abbr IS NOT NULL AND length(trim(abbr)) >= 2
  GROUP BY 1")

cat("grafias completas         :", dbGetQuery(con, "SELECT count(*) n FROM inst")$n, "\n")
cat("siglas                    :", dbGetQuery(con, "SELECT count(*) n FROM inst_ab")$n, "\n")

# Uma instituicao cuja sigla dobrada colida com o nome completo de
# outra tornaria os dois bracos indistinguiveis. Nao acontece hoje;
# a checagem existe para o dia em que a lista mudar.
clash <- dbGetQuery(con, "
  SELECT a.nm_fold FROM inst_ab a JOIN inst i ON a.nm_fold = i.nm_fold")
if (nrow(clash)) {
  print(clash, row.names = FALSE)
  stop("An abbreviation folds to the same string as a full institution name.")
}

####################################################################
### B2 -- o lado das universidades: as 1000 do Shanghai (nota 12)
####################################################################

cat("\n=========== SHANGHAI ===========\n")

# Conferencia da faixa ANTES de qualquer varredura, identica a do
# script 16: Rank <= 901 tem de selecionar exatamente 1000 linhas.
n_top <- dbGetQuery(con, sprintf(
  "SELECT sum(CASE WHEN Rank <= %d THEN 1 ELSE 0 END) AS n_top,
          sum(CASE WHEN Rank IS NULL THEN 1 ELSE 0 END) AS n_null,
          count(*) AS n_all
   FROM %s", rank_cut, sh_src))
cat("linhas do ranking         :", n_top$n_all, "\n")
cat("com Rank <=", rank_cut, "        :", n_top$n_top, "\n")
if (n_top$n_top != exp_sh_top) {
  stop("Rank <= ", rank_cut, " seleciona ", n_top$n_top, " linhas, nao ",
       exp_sh_top, ". As faixas do ranking mudaram; refaca a aritmetica ",
       "em vez de reinterpretar o corte.")
}

# As tres grafias, dobradas e deduplicadas -- a mesma construcao de
# `inst` acima e do script 16. O identificador aqui e o OA_id, que e
# VARCHAR: por isso classify() nao faz CAST no id (nota 12).
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE inst_sh AS
  SELECT lower(strip_accents(trim(nm))) AS nm_fold,
         min(Rank)                      AS best_rank,
         arg_min(OA_id, Rank)           AS rid,
         arg_min(trim(nm), Rank)        AS inst_name
  FROM (
    SELECT cleaned_display_name AS nm, Rank, OA_id FROM %1$s WHERE Rank <= %2$d
    UNION ALL
    SELECT display_name,        Rank, OA_id FROM %1$s WHERE Rank <= %2$d
    UNION ALL
    SELECT shanghai_Name,       Rank, OA_id FROM %1$s WHERE Rank <= %2$d
  )
  WHERE nm IS NOT NULL AND length(trim(nm)) >= 3
  GROUP BY 1", sh_src, rank_cut))

# Nao ha braco de sigla do lado do Shanghai: a fonte nao tem coluna de
# sigla para dobrar (nota 12). A tabela e criada VAZIA, com o mesmo
# esquema, para que classify() tenha UM caminho de codigo em vez de
# dois. O `WHERE FALSE` e o que garante esquema identico.
dbExecute(con, "CREATE OR REPLACE TABLE inst_ab_sh AS
                SELECT * FROM inst_sh WHERE FALSE")

n_isb <- dbGetQuery(con, "SELECT count(*) n FROM inst_ab_sh")$n
if (n_isb != 0) stop("inst_ab_sh deveria estar vazia; tem ", n_isb, " linhas.")

cat("grafias completas         :",
    dbGetQuery(con, "SELECT count(*) n FROM inst_sh")$n, "\n")
cat("siglas                    : 0 (sem braco de sigla -- nota 12)\n")

####################################################################
### C -- o classificador C_norm, uma vez por coluna de origem
####################################################################

# Identico ao do script 16, com uma linha a mais: o braco da sigla,
# que e SO igualdade de string inteira (nota 7). As duas colunas de
# origem recebem exatamente o mesmo tratamento.
#
# As tabelas de instituicao chegam como ARGUMENTO porque a funcao serve
# duas listas -- RUF e Shanghai (nota 12). Por isso as colunas de saida
# sao neutras (m_rank / m_id / m_inst) em vez de rf_*: elas nao sabem
# qual lista as produziu.
#
# m_id NAO leva CAST aqui. O id do RUF e INTEGER e o do Shanghai e o
# OA_id, VARCHAR; cada lista faz o seu proprio cast em `hits`.
classify <- function(col, tbl, itab, iatab) {
  dbExecute(con, sprintf("
    CREATE OR REPLACE TABLE %1$s AS
    WITH r AS (
      SELECT DISTINCT %2$s AS s FROM %3$s
      WHERE %2$s IS NOT NULL AND trim(%2$s) <> ''
    ),
    whole AS (
      SELECT r.s, i.best_rank, i.rid, i.inst_name
      FROM r JOIN %4$s i ON lower(strip_accents(trim(r.s))) = i.nm_fold
    ),
    seg AS (
      SELECT r.s,
             min(i.best_rank)                  AS best_rank,
             arg_min(i.rid, i.best_rank)       AS rid,
             arg_min(i.inst_name, i.best_rank) AS inst_name
      FROM r
      CROSS JOIN UNNEST(str_split(regexp_replace(regexp_replace(
                   r.s, '[/()]', '|', 'g'), ' - ', '|', 'g'), '|')) AS t(part)
      JOIN %4$s i ON lower(strip_accents(trim(t.part))) = i.nm_fold
      WHERE length(trim(t.part)) >= 3
      GROUP BY r.s
    ),
    ab AS (
      SELECT r.s, a.best_rank, a.rid, a.inst_name
      FROM r JOIN %5$s a ON lower(strip_accents(trim(r.s))) = a.nm_fold
    )
    SELECT s,
           CAST(min(best_rank) AS INTEGER)  AS m_rank,
           arg_min(rid, best_rank)          AS m_id,
           arg_min(inst_name, best_rank)    AS m_inst,
           CAST(max(is_whole) AS INTEGER)   AS m_whole,
           CAST(max(is_seg)   AS INTEGER)   AS m_seg,
           CAST(max(is_ab)    AS INTEGER)   AS m_ab
    FROM (
      SELECT s, best_rank, rid, inst_name, 1 AS is_whole, 0 AS is_seg, 0 AS is_ab FROM whole
      UNION ALL
      SELECT s, best_rank, rid, inst_name, 0, 1, 0                                FROM seg
      UNION ALL
      SELECT s, best_rank, rid, inst_name, 0, 0, 1                                FROM ab
    )
    GROUP BY s", tbl, col, pos_src, itab, iatab))
  dbGetQuery(con, sprintf("
    SELECT count(*) AS n_strings, sum(m_whole) AS n_whole,
           sum(m_seg) AS n_seg, sum(m_ab) AS n_ab FROM %s", tbl))
}

cat("\n--- RUF: classificando company_raw ---\n")
print(classify("company_raw",     "cls_raw", "inst", "inst_ab"), row.names = FALSE)
cat("--- RUF: classificando company_cleaned (nota 6) ---\n")
print(classify("company_cleaned", "cls_cln", "inst", "inst_ab"), row.names = FALSE)

cat("\n--- Shanghai: classificando company_raw ---\n")
sh_r <- classify("company_raw",     "cls_raw_sh", "inst_sh", "inst_ab_sh")
print(sh_r, row.names = FALSE)
cat("--- Shanghai: classificando company_cleaned (nota 6) ---\n")
sh_c <- classify("company_cleaned", "cls_cln_sh", "inst_sh", "inst_ab_sh")
print(sh_c, row.names = FALSE)

# O braco da sigla nao existe do lado do Shanghai (nota 12). inst_ab_sh
# esta vazia, entao n_ab TEM de ser 0 nas duas passagens. Se nao for, a
# tabela errada foi passada e sw_ estaria casando por sigla em silencio.
if (sum(sh_r$n_ab, na.rm = TRUE) != 0 || sum(sh_c$n_ab, na.rm = TRUE) != 0) {
  stop("O braco da sigla disparou do lado do Shanghai; inst_ab_sh nao esta vazia.")
}

####################################################################
### D -- as posicoes que casam, por qualquer braco
####################################################################

cat("\n=========== POSICOES CASADAS ===========\n")

# Precedencia raw > cleaned, com coalesce, como no script 16: o que a
# pessoa escreveu decide, e a normalizacao do Revelio so entra quando
# o texto cru nao casa.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE hits AS
  SELECT
    p.position_id,
    p.user_id,
    r.rcid,
    r.ultimate_parent_rcid,
    CAST(CASE WHEN fe.rcid IS NOT NULL AND fe.in_unicorn = 1 THEN 1 ELSE 0 END AS INTEGER) AS un_exact,
    CAST(CASE WHEN fp.rcid IS NOT NULL AND fp.in_unicorn = 1 THEN 1 ELSE 0 END AS INTEGER) AS un_parent,
    CAST(CASE WHEN fe.rcid IS NOT NULL AND fe.in_techcap = 1 THEN 1 ELSE 0 END AS INTEGER) AS tc_exact,
    CAST(CASE WHEN fp.rcid IS NOT NULL AND fp.in_techcap = 1 THEN 1 ELSE 0 END AS INTEGER) AS tc_parent,
    CAST(coalesce(fe.arm3, fp.arm3, 0) AS INTEGER)                                         AS firm_arm3,
    CAST(CASE WHEN coalesce(c.m_whole, n.m_whole, 0) = 1
                OR coalesce(c.m_seg,   n.m_seg,   0) = 1 THEN 1 ELSE 0 END AS INTEGER)     AS rf_name,
    CAST(CASE WHEN coalesce(c.m_ab, n.m_ab, 0) = 1 THEN 1 ELSE 0 END AS INTEGER)           AS rf_abbr,
    coalesce(fe.un_canonical_name, fp.un_canonical_name)                                   AS un_firm,
    CAST(coalesce(fe.un_best_rank, fp.un_best_rank) AS INTEGER)                            AS un_rank,
    coalesce(fe.tc_name, fp.tc_name)                                                       AS tc_firm,
    CAST(coalesce(fe.tc_rank, fp.tc_rank) AS INTEGER)                                      AS tc_rank,
    CAST(coalesce(c.m_id, n.m_id) AS INTEGER)                                              AS ruf_institution_id,
    coalesce(c.m_inst, n.m_inst)                                                           AS rf_inst,
    CAST(coalesce(c.m_rank, n.m_rank) AS INTEGER)                                          AS rf_rank,
    CAST(CASE WHEN c.s IS NOT NULL THEN 1 ELSE 0 END AS INTEGER)                           AS rf_by_raw,
    CAST(CASE WHEN coalesce(cs.m_whole, ns.m_whole, 0) = 1
                OR coalesce(cs.m_seg,   ns.m_seg,   0) = 1 THEN 1 ELSE 0 END AS INTEGER)   AS sw_name,
    coalesce(cs.m_id, ns.m_id)                                                             AS sw_oa_id,
    coalesce(cs.m_inst, ns.m_inst)                                                         AS sw_inst,
    CAST(coalesce(cs.m_rank, ns.m_rank) AS INTEGER)                                        AS sw_rank,
    CAST(CASE WHEN cs.s IS NOT NULL THEN 1 ELSE 0 END AS INTEGER)                          AS sw_by_raw,
    p.company_raw,
    p.company_cleaned,
    p.company_linkedin_url,
    p.startdate,
    p.enddate,
    CAST(try_cast(substr(p.startdate, 1, 4) AS INTEGER) AS INTEGER)                        AS start_year
  FROM %1$s p
  JOIN %2$s r        ON p.position_id = r.position_id
  LEFT JOIN firm fe  ON r.rcid = fe.rcid
  LEFT JOIN firm fp  ON r.ultimate_parent_rcid = fp.rcid
  LEFT JOIN cls_raw c ON p.company_raw = c.s
  LEFT JOIN cls_cln n ON p.company_cleaned = n.s
  LEFT JOIN cls_raw_sh cs ON p.company_raw = cs.s
  LEFT JOIN cls_cln_sh ns ON p.company_cleaned = ns.s
  WHERE fe.rcid IS NOT NULL OR fp.rcid IS NOT NULL
     OR c.s IS NOT NULL OR n.s IS NOT NULL
     OR cs.s IS NOT NULL OR ns.s IS NOT NULL", pos_src, rcid_src))

hs <- dbGetQuery(con, "
  SELECT count(*) AS n_rows, count(DISTINCT user_id) AS n_users,
         sum(un_exact) AS un_exact, sum(un_parent) AS un_parent,
         sum(tc_exact) AS tc_exact, sum(tc_parent) AS tc_parent,
         sum(firm_arm3) AS arm3,
         sum(rf_name) AS rf_name, sum(rf_abbr) AS rf_abbr,
         sum(sw_name) AS sw_name
  FROM hits")
print(as.data.frame(hs), row.names = FALSE)

####################################################################
### E -- uma linha por usuario
####################################################################

dbExecute(con, "
  CREATE OR REPLACE TABLE saida AS
  SELECT
    user_id,
    CAST(max(greatest(un_exact, un_parent)) AS INTEGER)          AS un_any,
    CAST(max(un_exact) AS INTEGER)                               AS un_exact_any,
    CAST(max(un_parent) AS INTEGER)                              AS un_parent_any,
    CAST(max(CASE WHEN greatest(un_exact, un_parent) = 1
                  THEN firm_arm3 ELSE 0 END) AS INTEGER)         AS un_arm3_any,
    CAST(min(un_rank) AS INTEGER)                                AS un_best_rank,
    arg_min(un_firm, un_rank)                                    AS un_best_firm,
    CAST(min(start_year) FILTER (WHERE greatest(un_exact, un_parent) = 1) AS INTEGER) AS un_first_year,
    CAST(count(DISTINCT rcid) FILTER (WHERE greatest(un_exact, un_parent) = 1) AS INTEGER) AS n_un_firms,
    CAST(sum(greatest(un_exact, un_parent)) AS INTEGER)          AS n_un_positions,

    CAST(max(greatest(tc_exact, tc_parent)) AS INTEGER)          AS tc_any,
    CAST(max(tc_exact) AS INTEGER)                               AS tc_exact_any,
    CAST(max(tc_parent) AS INTEGER)                              AS tc_parent_any,
    CAST(max(CASE WHEN greatest(tc_exact, tc_parent) = 1
                  THEN firm_arm3 ELSE 0 END) AS INTEGER)         AS tc_arm3_any,
    CAST(min(tc_rank) AS INTEGER)                                AS tc_best_rank,
    arg_min(tc_firm, tc_rank)                                    AS tc_best_firm,
    CAST(min(start_year) FILTER (WHERE greatest(tc_exact, tc_parent) = 1) AS INTEGER) AS tc_first_year,
    CAST(count(DISTINCT rcid) FILTER (WHERE greatest(tc_exact, tc_parent) = 1) AS INTEGER) AS n_tc_firms,
    CAST(sum(greatest(tc_exact, tc_parent)) AS INTEGER)          AS n_tc_positions,

    CAST(max(greatest(rf_name, rf_abbr)) AS INTEGER)             AS rf_any,
    CAST(max(rf_name) AS INTEGER)                                AS rf_name_any,
    CAST(max(rf_abbr) AS INTEGER)                                AS rf_abbr_any,
    CAST(max(CASE WHEN greatest(rf_name, rf_abbr) = 1
                  THEN rf_by_raw ELSE 0 END) AS INTEGER)         AS rf_raw_any,
    CAST(min(rf_rank) AS INTEGER)                                AS rf_best_rank,
    arg_min(rf_inst, rf_rank)                                    AS rf_best_inst,
    CAST(min(start_year) FILTER (WHERE greatest(rf_name, rf_abbr) = 1) AS INTEGER) AS rf_first_year,
    CAST(count(DISTINCT ruf_institution_id) FILTER (WHERE greatest(rf_name, rf_abbr) = 1) AS INTEGER) AS n_rf_inst,
    CAST(sum(greatest(rf_name, rf_abbr)) AS INTEGER)             AS n_rf_positions,

    CAST(max(sw_name) AS INTEGER)                                AS sw_any,
    CAST(max(CASE WHEN sw_name = 1
                  THEN sw_by_raw ELSE 0 END) AS INTEGER)         AS sw_raw_any,
    CAST(min(sw_rank) AS INTEGER)                                AS sw_best_rank,
    arg_min(sw_inst, sw_rank)                                    AS sw_best_inst,
    CAST(min(start_year) FILTER (WHERE sw_name = 1) AS INTEGER)  AS sw_first_year,
    CAST(count(DISTINCT sw_oa_id) FILTER (WHERE sw_name = 1) AS INTEGER) AS n_sw_inst,
    CAST(sum(sw_name) AS INTEGER)                                AS n_sw_positions,

    CAST(1 AS INTEGER)                                           AS firm_any,
    CAST(count(*) AS INTEGER)                                    AS n_matched_positions
  FROM hits
  GROUP BY user_id")

####################################################################
### F -- relatorio: numeros que so servem se forem lidos
####################################################################

cat("\n=========== USUARIOS SINALIZADOS ===========\n")
print(as.data.frame(dbGetQuery(con, "
  SELECT count(*) AS users,
         sum(un_any) AS un_any, sum(un_exact_any) AS un_exact, sum(un_parent_any) AS un_parent,
         sum(tc_any) AS tc_any, sum(tc_exact_any) AS tc_exact, sum(tc_parent_any) AS tc_parent,
         sum(rf_any) AS rf_any, sum(rf_name_any) AS rf_name, sum(rf_abbr_any) AS rf_abbr,
         sum(sw_any) AS sw_any
  FROM saida")), row.names = FALSE)

cat("\n--- quanto o braco 3 acrescenta (nota 4) ---\n")
print(dbGetQuery(con, "
  SELECT sum(un_arm3_any) AS un_users_via_arm3,
         sum(tc_arm3_any) AS tc_users_via_arm3 FROM saida"), row.names = FALSE)

cat("\n--- 20 maiores unicornios por usuarios sinalizados ---\n")
print(dbGetQuery(con, "
  SELECT un_firm, count(DISTINCT user_id) AS users
  FROM hits WHERE greatest(un_exact, un_parent) = 1 AND un_firm IS NOT NULL
  GROUP BY 1 ORDER BY users DESC LIMIT 20"), row.names = FALSE)

cat("\n--- 20 maiores empresas de mercado por usuarios sinalizados ---\n")
print(dbGetQuery(con, "
  SELECT tc_firm, count(DISTINCT user_id) AS users
  FROM hits WHERE greatest(tc_exact, tc_parent) = 1 AND tc_firm IS NOT NULL
  GROUP BY 1 ORDER BY users DESC LIMIT 20"), row.names = FALSE)

cat("\n--- as 23 do RUF, todas ---\n")
print(dbGetQuery(con, "
  SELECT r.abbr, r.institution_name, r.best_rank,
         coalesce(h.users, 0) AS users, coalesce(h.by_abbr_only, 0) AS by_abbr_only
  FROM ruf r
  LEFT JOIN (
    SELECT ruf_institution_id AS rid, count(DISTINCT user_id) AS users,
           count(DISTINCT CASE WHEN rf_name = 0 THEN user_id END) AS by_abbr_only
    FROM hits WHERE greatest(rf_name, rf_abbr) = 1 GROUP BY 1) h
    ON r.ruf_institution_id = h.rid
  ORDER BY users DESC"), row.names = FALSE, max = 1000)

cat("\n--- 30 strings que SO o braco da sigla casou (nota 7) ---\n")
cat("    Leia esta lista antes de usar rf_abbr.\n")
print(dbGetQuery(con, "
  SELECT company_raw, rf_inst, count(*) AS positions, count(DISTINCT user_id) AS users
  FROM hits WHERE rf_abbr = 1 AND rf_name = 0
  GROUP BY 1, 2 ORDER BY users DESC LIMIT 30"), row.names = FALSE, max = 1000)

cat("\n--- 20 strings que o braco de nome casou (para conferir) ---\n")
print(dbGetQuery(con, "
  SELECT company_raw, rf_inst, count(DISTINCT user_id) AS users
  FROM hits WHERE rf_name = 1
  GROUP BY 1, 2 ORDER BY users DESC LIMIT 20"), row.names = FALSE, max = 1000)

cat("\n--- 20 maiores universidades do Shanghai por usuarios (nota 12) ---\n")
print(dbGetQuery(con, "
  SELECT sw_inst, count(DISTINCT user_id) AS users
  FROM hits WHERE sw_name = 1 AND sw_inst IS NOT NULL
  GROUP BY 1 ORDER BY users DESC LIMIT 20"), row.names = FALSE, max = 1000)

cat("\n--- 20 strings que o braco Shanghai casou (para conferir) ---\n")
print(dbGetQuery(con, "
  SELECT company_raw, sw_inst, count(DISTINCT user_id) AS users
  FROM hits WHERE sw_name = 1
  GROUP BY 1, 2 ORDER BY users DESC LIMIT 20"), row.names = FALSE, max = 1000)

# As 23 do RUF sao quase um subconjunto das brasileiras do top-1000 do
# Shanghai, entao sw_ deveria CONTER rf_ em grande parte. Um residuo
# rf_not_sw grande significa que a dobra do Shanghai esta errada -- e
# nenhuma contagem de linhas mostraria isso.
cat("\n--- o que o braco Shanghai acrescenta, e a sobreposicao com o RUF ---\n")
print(dbGetQuery(con, "
  SELECT count(*) FILTER (WHERE sw_any = 1)                        AS sw_users,
         count(*) FILTER (WHERE sw_any = 1 AND rf_any = 0
                            AND un_any = 0 AND tc_any = 0)         AS sw_only,
         count(*) FILTER (WHERE sw_any = 1 AND rf_any = 1)         AS sw_and_rf,
         count(*) FILTER (WHERE rf_any = 1 AND sw_any = 0)         AS rf_not_sw
  FROM saida"), row.names = FALSE)

# Nota 8 do plano: um diagnostico, nao um flag. Quantas posicoes
# apontam para a PAGINA da universidade no LinkedIn sem que nenhum
# braco de nome as tenha pego.
cat("\n--- diagnostico: paginas linkedin.com/school das 23, NAO pegas ---\n")
cat("    (nao vira flag; mede o que o casamento por nome deixa passar)\n")
print(dbGetQuery(con, sprintf("
  WITH sch AS (
    SELECT p.position_id, p.company_linkedin_url,
           lower(strip_accents(trim(p.company_raw))) AS f
    FROM %s p
    WHERE p.company_linkedin_url IS NOT NULL
      AND p.company_linkedin_url LIKE '%%linkedin.com/school/%%'
  )
  SELECT a.nm_fold AS abbr_fold,
         count(*) AS positions,
         count(*) FILTER (WHERE h.position_id IS NULL) AS not_flagged
  FROM sch s
  JOIN inst_ab a
    ON regexp_replace(s.company_linkedin_url, '^.*linkedin[.]com/school/', '') = a.nm_fold
  LEFT JOIN hits h ON s.position_id = h.position_id
  GROUP BY 1 ORDER BY not_flagged DESC LIMIT 25", pos_src)), row.names = FALSE)

####################################################################
### G -- validacao e escrita
####################################################################

cat("\n=========== VALIDACAO ===========\n")

v <- dbGetQuery(con, sprintf("
  SELECT
    (SELECT count(*) FROM saida) AS users,
    (SELECT count(DISTINCT user_id) FROM saida) AS users_d,
    (SELECT count(*) FROM hits) AS pos_rows,
    (SELECT count(DISTINCT position_id) FROM hits) AS pos_d,
    (SELECT count(*) FROM saida s
       WHERE NOT EXISTS (SELECT 1 FROM read_parquet('%s') c
                         WHERE c.user_id = s.user_id)) AS orphan_users,
    (SELECT count(*) FROM saida WHERE firm_any = 0) AS unflagged",
  fw(coh_path)))
print(as.data.frame(v), row.names = FALSE)

if (v$users != v$users_d) stop("A saida por usuario nao e unica em user_id.")
if (v$pos_rows != v$pos_d) stop("A saida por posicao nao e unica em position_id.")
if (v$orphan_users != 0) {
  stop(v$orphan_users, " user_ids sinalizados nao estao em ",
       basename(coh_path), ".")
}
if (v$unflagged != 0) stop("Linha de usuario sem nenhum flag ligado.")
if (v$users == 0) stop("Nenhum usuario sinalizado -- isso nao e plausivel.")

# O rollup recomputado a partir das posicoes tem de bater com o que
# foi escrito, coluna a coluna. Se a agregacao e a escrita divergirem,
# e aqui que aparece.
rc <- dbGetQuery(con, "
  SELECT count(*) AS n_diff FROM (
    SELECT user_id,
           max(greatest(un_exact, un_parent)) AS un_any,
           max(greatest(tc_exact, tc_parent)) AS tc_any,
           max(greatest(rf_name, rf_abbr))    AS rf_any,
           max(sw_name)                       AS sw_any,
           count(*)                           AS n
    FROM hits GROUP BY user_id) x
  JOIN saida s USING (user_id)
  WHERE x.un_any <> s.un_any OR x.tc_any <> s.tc_any
     OR x.rf_any <> s.rf_any OR x.sw_any <> s.sw_any
     OR x.n <> s.n_matched_positions")
if (rc$n_diff != 0) stop(rc$n_diff, " usuarios divergem do rollup recomputado.")
cat("rollup recomputado confere.\n")

dbExecute(con, sprintf(
  "COPY (SELECT * FROM hits ORDER BY user_id, position_id) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_pos)))
dbExecute(con, sprintf(
  "COPY (SELECT * FROM saida ORDER BY user_id) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_user)))

up <- arrow::open_dataset(out_user, format = "parquet")
hp <- arrow::open_dataset(out_pos,  format = "parquet")
stopifnot(identical(names(up), c(
  "user_id",
  "un_any", "un_exact_any", "un_parent_any", "un_arm3_any", "un_best_rank",
  "un_best_firm", "un_first_year", "n_un_firms", "n_un_positions",
  "tc_any", "tc_exact_any", "tc_parent_any", "tc_arm3_any", "tc_best_rank",
  "tc_best_firm", "tc_first_year", "n_tc_firms", "n_tc_positions",
  "rf_any", "rf_name_any", "rf_abbr_any", "rf_raw_any", "rf_best_rank",
  "rf_best_inst", "rf_first_year", "n_rf_inst", "n_rf_positions",
  "sw_any", "sw_raw_any", "sw_best_rank", "sw_best_inst", "sw_first_year",
  "n_sw_inst", "n_sw_positions",
  "firm_any", "n_matched_positions")))
stopifnot(nrow(up) == v$users, nrow(hp) == v$pos_rows)

cat("\n=========== RESUMO ===========\n")
cat(sprintf("  %-46s %10s linhas  %6.1f MB\n", basename(out_pos),
            format(v$pos_rows, big.mark = ","), file.info(out_pos)$size / 2^20))
cat(sprintf("  %-46s %10s linhas  %6.1f MB\n", basename(out_user),
            format(v$users, big.mark = ","), file.info(out_user)$size / 2^20))
cat("  em ", coh_root, "\n", sep = "")
cat(sprintf("  cohort de %s; %.2f%% dele fica sinalizado\n",
            format(exp_cohort, big.mark = ","), 100 * v$users / exp_cohort))
