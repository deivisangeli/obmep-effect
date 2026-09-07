####################################################################
###
### RUF and Shanghai degree flags via the SAFE rsid -> OpenAlex map
###                                                    [local only]
###
### The existing rd_ (script 20) and sh_ (script 16) flags match folded
### NAMES against university_raw and university_name. This script adds
### the arm they never had: Revelio's own school key. A person is
### flagged when their education row's rsid maps, through the
### one-to-one-safe map, to a ranked institution -- whatever they typed.
###
### It does NOT modify scripts 16 or 20 and does not touch their
### outputs. The new flags carry their own prefixes and are joined, so
### the widening is reversible with a WHERE.
###
### -----------------------------------------------------------------
### *** THE TWO LISTS ARE NOT EQUALLY SERVED. READ THIS FIRST. ***
### -----------------------------------------------------------------
### The safe map is built from openalex_institutions_br -- 1,947
### BRAZILIAN records. So it can only reach Brazilian institutions.
###
###   RUF      23 of 23 ranked institutions are in the map (45 rsids).
###            The rebuild is COMPLETE.
###   SHANGHAI 18 of 1,079 (1.7%) are in the map (37 rsids), and those
###            18 are exactly the Brazilian entries -- USP, Unesp,
###            UFMG, UFRGS, Unicamp, UFRJ, Unifesp, UFSC, UFPR, UnB,
###            UFSM, UFV, UFF, UFSCar, UFC, UFPE, UFG, UFPel.
###            The other 1,061 are not Brazilian, are absent from the
###            institution list by construction, and CANNOT be reached
###            this way at all.
###
### So sh_rsid_ is a BRAZILIAN-SLICE ARM, not a rebuilt Shanghai flag.
### Harvard, MIT and Cambridge are untouched by it. Anyone reading
### sh_rsid_any as "top-1000 degree by school key" would be wrong about
### 98.3% of the ranking. A global version needs a map built against the
### Shanghai list itself, which is a different build.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Reads local parquet, writes local parquet. Free.
###    Still prep/, still not for SEDAP.
### 2. THE EVIDENCE FLOOR IS NOT OPTIONAL. dom_share is blind to thin
###    evidence: one stray matched row gives dom_share 1.0 by
###    arithmetic. Measured on RUF, 35 of the 75 rsids passing
###    dom_share >= 0.90 rest on a SINGLE matched row and carry 5.65M
###    of the 9.67M rows they would flag -- UNAM, UCLA, Stanford, RMIT,
###    Montreal. min_evidence is what stops that, and the safe map's
###    verdicts are what stop the family case. Both are required; see
###    rsid_openalex_one_to_one.R note 7.
### 3. THE LEVEL CASCADE IS THE SHARED ONE. sql_shanghai_level from
###    br_degree_patterns.R, the same expression script 16 uses, so a
###    degree means here what it means there. Its order is load-bearing
###    (rx_notdeg first, so pos-doutorado is not read as a doctorate).
### 4. FLAGS ARE ADDITIVE AND REVERSIBLE. rd_rsid_* sits BESIDE rd_*
###    rather than replacing it, exactly as sh_raw_any preserves the
###    pre-name-arm definition. `rd_any_wide` is the union and is the
###    only column that changes the answer; drop it and nothing moves.
### 6. A ROW WHOSE OWN STRING NAMES ANOTHER INSTITUTION IS EXCLUDED.
###    See the comment above `str_oa`, which also records how NOT to
###    diagnose this -- the first check joined through user_id instead of
###    through the rsid and produced three false alarms.
###
###    ONE ERROR CLASS SURVIVES, and it is inherent to propagation: a
###    string that matched NOTHING, sitting under a good rsid, denoting a
###    different institution. Measured, the visible case is
###    "FAC UNICAMPS - Faculdade Unida de Campinas" (Goiania) attributed
###    to Unicamp, 671 users -- about 1% of the RUF gain. The guard
###    cannot catch it because there is no competing match to compare
###    against. This is the price of the coverage the arm buys.
### 5. THE ARM CANNOT BE MORE PRECISE THAN THE MAP. Every caveat in
###    rsid_openalex_one_to_one.R travels: 12 rsids are excluded as
###    FAMILY or WRONG_DOM, the verdicts behind that are LLM-written,
###    and AFFILIATE rsids are included, which means a teaching
###    hospital's rows count toward its medical school.
###
####################################################################

rm(list = ls()); gc()
options(width = 200)

for (p in c("DBI", "duckdb", "arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)

####################################################################
### Parameters
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
ruf_dir <- file.path(obmep_root, "Data/intermediate/ruf_ranking")
sh_dir  <- file.path(obmep_root, "Data/intermediate/shanghai_ranking")

ed_dir    <- file.path(coh_dir, "obmep_candidates_step_1_education")
map_path  <- file.path(coh_dir, "rsid_openalex_safe_map.parquet")
xw_path   <- file.path(coh_dir, "rsid_openalex_id_crosswalk.parquet")
ruf_xw    <- file.path(ruf_dir, "ruf_openalex_br_2025.parquet")
ruf_inst  <- file.path(ruf_dir, "ruf_stem_top10_institutions_2025.parquet")
sh_path   <- file.path(sh_dir,  "shanghai_ranking_oa.parquet")
rd_old    <- file.path(coh_dir, "obmep_candidates_step_1_ruf_degree.parquet")
sh_old    <- file.path(coh_dir, "obmep_candidates_step_1_shanghai.parquet")
out_path  <- file.path(coh_dir, "obmep_candidates_step_1_rsid_degree.parquet")

# Note 2. A safe rsid still needs enough matched evidence behind it.
min_evidence <- 25L
rank_cut     <- 901L

patterns_path <- Sys.getenv(
  "OBMEP_DEGREE_PATTERNS",
  unset = file.path("prep", "building_external_data", "br_degree_patterns.R"))
if (!file.exists(patterns_path)) {
  patterns_path <- file.path("prep", "building_external_data",
                             "br_degree_patterns.R")
}
stopifnot(file.exists(patterns_path))
source(patterns_path)

for (f in c(ed_dir, map_path, xw_path, ruf_xw, ruf_inst, sh_path, rd_old, sh_old)) {
  if (!file.exists(f)) stop("Missing input: ", f)
}

con <- dbConnect(duckdb::duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
invisible(dbExecute(con, "SET memory_limit='8GB'"))
# Trino spelling DuckDB does not share; same shim scripts 16 and 20 use.
invisible(dbExecute(con, "CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)"))

fw <- function(p) gsub("\\\\", "/", p)
ed_src <- sprintf("read_parquet('%s/*')", fw(ed_dir))

####################################################################
### Step 1: rsid -> ranked institution, per list
####################################################################

invisible(dbExecute(con, sprintf(
  "CREATE TABLE map AS SELECT * FROM read_parquet('%s')
     WHERE safe = 1 AND rsid_matched_rows >= %d", fw(map_path), min_evidence)))
# best_rank is in the institutions file, not the crosswalk; the two are
# keyed on ruf_institution_id and both are asserted 23 rows upstream.
invisible(dbExecute(con, sprintf(
  "CREATE TABLE ruf AS
   SELECT x.openalex_id, x.abbr, x.institution_name, i.best_rank
   FROM read_parquet('%s') x
   JOIN read_parquet('%s') i USING (ruf_institution_id)",
  fw(ruf_xw), fw(ruf_inst))))
invisible(dbExecute(con, sprintf(
  "CREATE TABLE shr AS SELECT OA_key AS openalex_id, shanghai_Name AS nm, Rank AS rk
     FROM read_parquet('%s') WHERE Rank <= %d", fw(sh_path), rank_cut)))

# One row per rsid per list. The map is one-to-one by construction, so
# an rsid cannot reach two ranked institutions on the same list.
invisible(dbExecute(con, "
  CREATE TABLE rd_rsid AS
  SELECT m.rsid, m.openalex_id, r.abbr AS inst, r.best_rank AS rk, m.university_name, m.dom_share,
         m.rsid_matched_rows, m.verdict
  FROM map m JOIN ruf r ON m.openalex_id = r.openalex_id"))
invisible(dbExecute(con, "
  CREATE TABLE sh_rsid AS
  SELECT m.rsid, m.openalex_id, s.nm AS inst, s.rk, m.university_name, m.dom_share,
         m.rsid_matched_rows, m.verdict
  FROM map m JOIN shr s ON m.openalex_id = s.openalex_id"))

cat("=========== rsid -> RANKED INSTITUTION ===========\n")
q <- function(s) dbGetQuery(con, s)
cat("safe map after the evidence floor (>=", min_evidence, "matched rows):",
    q("SELECT count(*) n FROM map")$n, "rsids\n")
cat("  RUF     :", q("SELECT count(*) n FROM rd_rsid")$n, "rsids ->",
    q("SELECT count(DISTINCT inst) n FROM rd_rsid")$n, "of 23 institutions\n")
cat("  SHANGHAI:", q("SELECT count(*) n FROM sh_rsid")$n, "rsids ->",
    q("SELECT count(DISTINCT inst) n FROM sh_rsid")$n,
    "of 1,000 ranked institutions  <-- BRAZILIAN SLICE ONLY, see header\n")
stopifnot(q("SELECT count(*) n FROM rd_rsid")$n > 0)

####################################################################
### Step 2: level the education rows, then flag per user
####################################################################

# Same projection scripts 16 and 20 use, plus rsid -- the column they
# both read and neither uses.
# Note 6. A row whose OWN string matched a DIFFERENT institution must
# not be attributed to the school's dominant one, or the arm propagates
# one level down the amplification the safe map exists to stop.
# Measured: this removes 467 users, a small number, and it is kept
# because it is the principled guard rather than because it is large.
#
# A WARNING ABOUT DIAGNOSING THIS. The first attempt to check it joined
# newly flagged users to ALL of their education rows and appeared to
# show Unesp pulling in "ETEC", "MBA USP/Esalq" and "Fundacao Getulio
# Vargas". That was an artefact: those users hold those strings on
# OTHER rows, and their Unesp flag came from a legitimate Unesp row.
# The check must restrict to the rows that actually TRIGGER the flag --
# join through the rsid map, not through the user. Done properly, the
# top of the newly flagged population is clean.
invisible(dbExecute(con, sprintf(
  "CREATE TABLE str_oa AS
   SELECT DISTINCT university_raw, openalex_id
   FROM read_parquet('%s')", fw(xw_path))))

invisible(dbExecute(con, sprintf("
  CREATE TABLE lvl AS
  SELECT e.user_id, e.rsid,
         CAST(year(e.startdate) AS INTEGER) AS yr,
         (%s) AS lvl,
         (e.degree = 'MBA' OR regexp_like(e.dr, '%s')) AS is_mba,
         e.university_raw
  FROM (SELECT user_id, rsid, startdate, degree, university_raw,
               lower(trim(coalesce(degree_raw, ''))) AS dr
        FROM %s WHERE rsid IS NOT NULL) e", sql_shanghai_level, rx_mba, ed_src)))

mk <- function(tag, src) dbExecute(con, sprintf("
  CREATE TABLE out_%1$s AS
  SELECT l.user_id,
         1 AS %1$s_rsid_any,
         CAST(max(CASE WHEN l.lvl='bachelor' THEN 1 ELSE 0 END) AS INTEGER) AS %1$s_rsid_bachelor,
         CAST(max(CASE WHEN l.lvl='master'   THEN 1 ELSE 0 END) AS INTEGER) AS %1$s_rsid_master,
         CAST(max(CASE WHEN l.lvl='master' AND NOT l.is_mba THEN 1 ELSE 0 END) AS INTEGER) AS %1$s_rsid_master_strict,
         CAST(max(CASE WHEN l.lvl='phd'      THEN 1 ELSE 0 END) AS INTEGER) AS %1$s_rsid_phd,
         min(s.rk) FILTER (WHERE l.lvl IN ('bachelor','master','phd'))      AS %1$s_rsid_best_rank,
         arg_min(s.inst, s.rk) FILTER (WHERE l.lvl IN ('bachelor','master','phd')) AS %1$s_rsid_best_inst,
         min(s.rk)             FILTER (WHERE l.lvl = 'bachelor') AS %1$s_rsid_bach_rank,
         min(s.rk)             FILTER (WHERE l.lvl = 'master')   AS %1$s_rsid_mast_rank,
         min(s.rk)             FILTER (WHERE l.lvl = 'phd')      AS %1$s_rsid_phd_rank,
         arg_min(s.inst, s.rk) FILTER (WHERE l.lvl = 'bachelor') AS %1$s_rsid_bach_inst,
         arg_min(s.inst, s.rk) FILTER (WHERE l.lvl = 'master')   AS %1$s_rsid_mast_inst,
         arg_min(s.inst, s.rk) FILTER (WHERE l.lvl = 'phd')      AS %1$s_rsid_phd_inst,
         min(l.yr)             FILTER (WHERE l.lvl = 'bachelor') AS %1$s_rsid_bach_year,
         min(l.yr)             FILTER (WHERE l.lvl = 'master')   AS %1$s_rsid_mast_year,
         min(l.yr)             FILTER (WHERE l.lvl = 'phd')      AS %1$s_rsid_phd_year,
         CAST(count(*) AS INTEGER) AS %1$s_rsid_n_rows
  FROM lvl l
  JOIN %2$s s ON l.rsid = s.rsid
  LEFT JOIN str_oa x ON l.university_raw = x.university_raw
  WHERE x.openalex_id IS NULL OR x.openalex_id = s.openalex_id
  GROUP BY l.user_id
  HAVING max(CASE WHEN l.lvl IN ('bachelor','master','phd') THEN 1 ELSE 0 END) = 1",
  tag, src))
invisible(mk("rd", "rd_rsid")); invisible(mk("sh", "sh_rsid"))

####################################################################
### Step 3: what the arm adds over the existing name-matched flags
####################################################################

invisible(dbExecute(con, sprintf(
  "CREATE TABLE rd_o AS SELECT user_id, rd_any FROM read_parquet('%s')", fw(rd_old))))
invisible(dbExecute(con, sprintf(
  "CREATE TABLE sh_o AS SELECT user_id, sh_any FROM read_parquet('%s')", fw(sh_old))))

cat("\n=========== WHAT THE rsid ARM ADDS ===========\n")
for (tg in c("rd", "sh")) {
  r <- q(sprintf("
    SELECT (SELECT count(*) FROM %1$s_o)                       AS old_users,
           (SELECT count(*) FROM out_%1$s)                     AS rsid_users,
           (SELECT count(*) FROM out_%1$s n
              LEFT JOIN %1$s_o o USING(user_id) WHERE o.user_id IS NULL) AS new_users,
           (SELECT count(*) FROM %1$s_o o
              LEFT JOIN out_%1$s n USING(user_id) WHERE n.user_id IS NULL) AS only_old", tg))
  lab <- if (tg == "rd") "RUF  rd_" else "SHANGHAI sh_ (Brazilian slice only)"
  cat(sprintf("  %-36s existing %8s | rsid arm %8s | NEW %7s (+%.1f%%) | name-only %8s\n",
      lab, format(r$old_users, big.mark=","), format(r$rsid_users, big.mark=","),
      format(r$new_users, big.mark=","), 100*r$new_users/r$old_users,
      format(r$only_old, big.mark=",")))
}

cat("\n=========== TOP INSTITUTIONS THE rsid ARM NEWLY REACHES (RUF) ===========\n")
print(q("
  SELECT n.rd_rsid_best_inst AS inst, count(*) AS new_users
  FROM out_rd n LEFT JOIN rd_o o USING(user_id)
  WHERE o.user_id IS NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 12"),
  right = FALSE, row.names = FALSE)

####################################################################
### Step 4: write, joined into one user-level table
####################################################################

invisible(dbExecute(con, sprintf("
  COPY (SELECT coalesce(r.user_id, s.user_id) AS user_id,
               coalesce(r.rd_rsid_any,0) AS rd_rsid_any,
               r.rd_rsid_bachelor, r.rd_rsid_master, r.rd_rsid_master_strict,
               r.rd_rsid_phd, r.rd_rsid_best_rank, r.rd_rsid_best_inst,
               r.rd_rsid_bach_rank, r.rd_rsid_mast_rank, r.rd_rsid_phd_rank,
               r.rd_rsid_bach_inst, r.rd_rsid_mast_inst, r.rd_rsid_phd_inst,
               r.rd_rsid_bach_year, r.rd_rsid_mast_year, r.rd_rsid_phd_year,
               r.rd_rsid_n_rows,
               coalesce(s.sh_rsid_any,0) AS sh_rsid_any,
               s.sh_rsid_bachelor, s.sh_rsid_master, s.sh_rsid_master_strict,
               s.sh_rsid_phd, s.sh_rsid_best_rank, s.sh_rsid_best_inst,
               s.sh_rsid_bach_rank, s.sh_rsid_mast_rank, s.sh_rsid_phd_rank,
               s.sh_rsid_bach_inst, s.sh_rsid_mast_inst, s.sh_rsid_phd_inst,
               s.sh_rsid_bach_year, s.sh_rsid_mast_year, s.sh_rsid_phd_year,
               s.sh_rsid_n_rows
        FROM out_rd r FULL OUTER JOIN out_sh s USING(user_id)
        ORDER BY user_id) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_path))))

d <- arrow::read_parquet(out_path)
stopifnot(nrow(d) > 0, !anyDuplicated(d$user_id))

# As colunas por nivel tem de acompanhar a flag do nivel.
#
# rank e inst: correspondencia nos DOIS sentidos. O rank vem do mapa e
# existe sempre que houver linha daquele nivel, entao um NULL com flag 1
# seria agregacao errada, e um valor com flag 0 seria flag fantasma.
#
# year: SO no sentido "valor presente => flag 1". O ano vem de
# year(startdate) e startdate falta em parte das linhas, entao flag 1
# com ano NULL e normal, nao defeito. Medido no script 16: 2.754 de
# 856.076 usuarios com sh_bachelor = 1 nao tem sh_bach_year.
lvl_nm <- c(bach = "bachelor", mast = "master", phd = "phd")
for (tg in c("rd", "sh")) {
  for (lv in names(lvl_nm)) {
    fl <- ifelse(is.na(d[[paste0(tg, "_rsid_", lvl_nm[[lv]])]]), 0L,
                 d[[paste0(tg, "_rsid_", lvl_nm[[lv]])]])
    for (sfx in c("rank", "inst")) {
      cl  <- d[[paste0(tg, "_rsid_", lv, "_", sfx)]]
      bad <- sum(fl == 1L & is.na(cl)) + sum(fl != 1L & !is.na(cl))
      if (bad != 0L) {
        stop(bad, " linhas com ", tg, "_rsid_", lv, "_", sfx,
             " discordando de ", tg, "_rsid_", lvl_nm[[lv]], ".")
      }
    }
    yr_col <- d[[paste0(tg, "_rsid_", lv, "_year")]]
    orf    <- sum(fl != 1L & !is.na(yr_col))
    if (orf != 0L) {
      stop(orf, " linhas com ", tg, "_rsid_", lv, "_year preenchido e ",
           tg, "_rsid_", lvl_nm[[lv]], " diferente de 1.")
    }
    sem <- sum(fl == 1L & is.na(yr_col))
    if (sem > 0L) {
      cat(sprintf("  %s_rsid_%s_year ausente em %s de %s (startdate nulo)\n",
                  tg, lv, format(sem, big.mark = ","),
                  format(sum(fl == 1L), big.mark = ",")))
    }
  }
}
cat("\n=========== SUMMARY ===========\n")
cat("  output       :", out_path,
    sprintf("(%.2f MB, %s users)\n", file.info(out_path)$size/2^20,
            format(nrow(d), big.mark = ",")))
cat("  evidence floor: rsid_matched_rows >=", min_evidence, "\n")
cat("  rd_rsid_any  :", format(sum(d$rd_rsid_any), big.mark = ","), "users\n")
cat("  sh_rsid_any  :", format(sum(d$sh_rsid_any), big.mark = ","),
    "users  <-- Brazilian slice of the ranking ONLY\n")
