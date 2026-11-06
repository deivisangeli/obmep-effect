####################################################################
###
### openalex_id <-> accepted university_raw crosswalk  (local only)
###
### rsid_br_user_share.R links every C_norm-accepted university_raw to
### an OpenAlex NAME (oa_matched_name) and never to an openalex_id --
### the id was not propagated through that query. This script recovers
### it, offline and for free.
###
### Grain: one row per (rsid, university_raw, openalex_id), asserted
### unique. That is the SAME grain as script 6's rsid_openalex_br, so
### the two read side by side, and this one is a strict superset in
### coverage: script 6 covers criterion C only, this covers C_norm.
###
### Columns published:
###   rsid, university_raw, university_name,
###   openalex_id, openalex_display_name,
###   openalex_cleaned_display_name, openalex_type,
###   openalex_works_count, openalex_ror,
###   m_exact, m_norm, has_exact, has_norm,
###   keep, br_share_known, n_rows, n_users,
###   dom_openalex_id, dom_share, n_ids_rsid
###
### Depends on:
###   prep/building_external_data/rsid_br_user_share.R
###   (OBMEP .../revelio_br_cohort/rsid_br_user_share.parquet)
###   prep/building_external_data/openalex_br_institutions.R
###   (OBMEP .../openalex_institutions/openalex_institutions_br.parquet)
###
### Shape reused from:
###   prep/building_external_data/ruf_openalex_br_crosswalk.R
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Unlike 8a, 8b and 10alt, this script reads two
###    local parquets and writes a third. It costs nothing and can be
###    re-run freely. It is still a prep/ script and still must not be
###    sent to SEDAP, because its inputs are Dropbox artifacts of an
###    online pipeline.
### 2. *** THE JOIN IS NOT A NEW MATCH RULE. *** oa_matched_name is
###    itself a cleaned_display_name value: 8a sets it to
###    min(cleaned_display_name) inside inst_fold. So joining it back
###    to openalex_institutions_br is EXACT STRING EQUALITY on a value
###    that originated in the target table -- no folding, no lowering,
###    no re-matching. Criteria C and C_norm are not re-derived here
###    and no new definition of them is introduced. If a future edit
###    makes this join fuzzy in any way, it stops being a lookup and
###    becomes a second, silently different matcher.
### 3. FAN-OUT ON openalex_id IS EXPECTED AND MUST NOT BE DEDUPED.
###    OpenAlex ships 4 duplicate-name groups -- 8 records sharing 4
###    names: Faculdades Nova Esperanca, Hospital Ana Nery, Hospital de
###    Base, Instituto de Medicina Avancada. Measured, 12 of the 24,276
###    accepted pairs carry one of those names, so the output is 24,288
###    rows over 24,276 pairs: 1:1 on 24,264 of them. Step 4 PRINTS
###    those 12 rows rather than counting them.
###
###    Do NOT dedupe by keeping the largest works_count -- script 6
###    note 5 records why: that silently picks a city over a hospital.
### 4. FOLDING COLLAPSES NOTHING. Measured on the 2026 snapshot:
###    1,947 records -> 1,947 distinct openalex_id -> 1,943 distinct
###    cleaned_display_name -> 1,943 distinct lower() -> 1,943 distinct
###    ACCENT-FOLDED lower(). The 4 collisions above exist already at
###    the raw cleaned_display_name level; neither lowering nor folding
###    adds one. So the name -> id recovery here is exactly as good as
###    OpenAlex itself allows, and nothing was lost by 8a having
###    grouped on the folded name.
### 5. `keep` is STORED, NOT FILTERED ON. It is br_share_known > 0.5,
###    the gate 8a applied and 8b admits on, so "only the strings under
###    a surviving school" is `WHERE keep = 1` and the 628 rejected
###    pairs keep their ids -- which is exactly where an id is most
###    useful, when auditing a rejection by hand.
### 6. openalex_type TRAVELS ON PURPOSE. It is what shows that the
###    whole-string arm accepts any record type, so "Estacio (Brazil)"
###    -- typed `company`, 7,237 works, with no education record of its
###    own -- is in here. It is the single largest legitimate match in
###    the chain and the easiest thing for a later reader to "fix" by
###    adding a type filter. See README, "`type` is about ownership,
###    not function".
### 7. THE ANTI-JOIN IS A SNAPSHOT-DRIFT DETECTOR, not a formality.
###    Every oa_matched_name must be present in the CURRENT
###    institutions parquet. If openalex_br_institutions.R is re-run
###    against a newer OpenAlex snapshot while rsid_br_user_share is
###    not, a renamed or withdrawn institution shows up here as an
###    unresolved name -- which is the only place that disagreement
###    would surface, since a local join otherwise just drops the row.
### 9. *** dom_share IS NOT OPTIONAL DECORATION. *** An rsid pools many
###    university_raw strings, each matched independently, so one school
###    can reach many openalex_ids. Two causes, opposite consequences:
###
###    (a) long-tail stray strings. FGV (rsid 53433) reaches 95 ids, but
###        Fundacao Getulio Vargas holds 700,433 of its 701,099 matched
###        rows -- 99.9%. The other 94 hold 1 to 241 rows each, an FGV
###        school key with "Universidade Federal do Rio de Janeiro",
###        "Estacio", "Fundacao Oswaldo Cruz". Same single-stray-row
###        mechanism as Harvard. dom_openalex_id is right here.
###
###    (b) Revelio's key is a FAMILY, not a school. IFSP (rsid 74427)
###        reaches 35 ids over 2,546 matched rows and they are the whole
###        federal Instituto Federal network -- IF Sergipe 621, IF
###        Brasilia 323, IF Fluminense 203, IF Santa Catarina 178 -- plus
###        Petrobras at 623. No single id is correct, and the ranking
###        rule picks PETROBRAS. dom_openalex_id is wrong here and
###        dom_share (0.24) is the only thing that says so.
###
###    So: NEVER consume dom_openalex_id without reading dom_share.
###    n_ids_rsid alone does not separate the two cases -- FGV's 95 and
###    IFSP's 35 rank the wrong way round on it.
###
###    A name-plausibility check was tried and REJECTED: token overlap
###    between university_name and the dominant OpenAlex name flags
###    "Ninth of July University" vs "Universidade Nove de Julho" and
###    "ETEC" vs "Centro Paula Souza" as disagreements when both are
###    correct. Anglicisation and parent/child naming defeat it, the same
###    way they defeat name matching in ruf_openalex_br_crosswalk.R. Do
###    not reintroduce one; the low-dom_share tail needs hand review.
### 8. exp_rows is pinned from the start, not NA. Both inputs are fixed
###    files, so the count is deterministic and was measured before
###    this script was written. There is no legitimate first run that
###    needs the check disabled -- unlike the Athena stages, where the
###    number cannot be known until the scan is paid for.
###
####################################################################

rm(list = ls()); gc()

# The report tables in Steps 4 and 5 are wide; at the default width they
# wrap mid-row and become unreadable in a log.
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

coh_dir  <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
oa_dir   <- file.path(obmep_root, "Data/intermediate/openalex_institutions")

gate_path <- file.path(coh_dir, "rsid_br_user_share.parquet")
inst_path <- file.path(oa_dir,  "openalex_institutions_br.parquet")
out_path  <- file.path(coh_dir, "rsid_openalex_id_crosswalk.parquet")

# The gate, as rsid_br_user_share.R applied it and
# revelio_br_cohort_user_ids_alt.R admits on. Only used to derive the
# stored `keep` flag here -- nothing is filtered by it (note 5).
br_share_min <- 0.5

# Measured 2026-09-04 before this script was written (note 8).
exp_rows  <- 24288   # (rsid, university_raw, openalex_id)
exp_pairs <- 24276   # (rsid, university_raw) -- the gate table's grain
exp_rsids <- 975
exp_keep  <- 667
exp_fanout <- 12     # pairs landing on a duplicate-name group (note 3)

dir.create(coh_dir, recursive = TRUE, showWarnings = FALSE)

####################################################################
### Step 1: inputs
####################################################################

if (!file.exists(gate_path)) {
  stop("Missing ", gate_path, "\nRun rsid_br_user_share.R first: this ",
       "script only recovers the id, it cannot re-derive the match.")
}
if (!file.exists(inst_path)) {
  stop("Missing ", inst_path, "\nRun openalex_br_institutions.R first.")
}

con <- dbConnect(duckdb::duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)

tmp <- dbExecute(con, sprintf(
  "CREATE VIEW gate AS SELECT * FROM read_parquet('%s')",
  gsub("\\\\", "/", gate_path)))
tmp <- dbExecute(con, sprintf(
  "CREATE VIEW inst AS SELECT * FROM read_parquet('%s')",
  gsub("\\\\", "/", inst_path)))

src <- dbGetQuery(con, "
  SELECT (SELECT count(*) FROM gate) AS gate_rows,
         (SELECT count(DISTINCT (rsid, university_raw)) FROM gate) AS gate_pairs,
         (SELECT count(*) FROM inst) AS inst_rows,
         (SELECT count(DISTINCT openalex_id) FROM inst) AS inst_ids,
         (SELECT count(DISTINCT cleaned_display_name) FROM inst) AS inst_names")
cat("=========== INPUTS ===========\n")
cat("gate table rows               :", format(src$gate_rows, big.mark = ","), "\n")
cat("  distinct (rsid, raw)        :", format(src$gate_pairs, big.mark = ","), "\n")
cat("institutions rows             :", format(src$inst_rows, big.mark = ","), "\n")
cat("  distinct openalex_id        :", format(src$inst_ids, big.mark = ","), "\n")
cat("  distinct cleaned_display_name:", format(src$inst_names, big.mark = ","),
    sprintf("(%d duplicate-name groups, note 3)\n",
            src$inst_rows - src$inst_names))
if (src$gate_rows != src$gate_pairs) {
  stop("The gate table is not unique on (rsid, university_raw). Its own ",
       "validation asserts that it is, so one of the two is wrong.")
}

####################################################################
### Step 2: the lookup, and the drift check that must precede it
####################################################################

# Note 7: this is the load-bearing check. An oa_matched_name absent
# from the current institutions parquet means the two snapshots have
# drifted apart, and a plain inner join would silently drop the row
# instead of saying so.
orph <- dbGetQuery(con, "
  SELECT g.oa_matched_name, count(*) AS n_pairs
  FROM gate g
  LEFT JOIN (SELECT DISTINCT cleaned_display_name FROM inst) i
    ON g.oa_matched_name = i.cleaned_display_name
  WHERE i.cleaned_display_name IS NULL
  GROUP BY 1 ORDER BY 2 DESC")
if (nrow(orph) != 0) {
  print(orph, row.names = FALSE)
  stop(nrow(orph), " oa_matched_name values are absent from ",
       basename(inst_path), ", covering ", sum(orph$n_pairs), " pairs. ",
       "The gate table and the OpenAlex snapshot have drifted apart: ",
       "rebuild rsid_br_user_share.R against the current institutions ",
       "list, or restore the snapshot it was built on. See note 7.")
}
cat("\n[OK] every oa_matched_name resolves in the current snapshot\n")

# Note 2: exact equality on a value that came from the target column.
# No lower(), no accent folding, no LIKE -- deliberately.
cw_sql <- sprintf("
SELECT g.rsid,
       g.university_raw,
       g.university_name,
       i.openalex_id,
       i.display_name         AS openalex_display_name,
       i.cleaned_display_name AS openalex_cleaned_display_name,
       i.type                 AS openalex_type,
       i.works_count          AS openalex_works_count,
       i.ror                  AS openalex_ror,
       g.m_exact,
       g.m_norm,
       g.has_exact,
       g.has_norm,
       CASE WHEN g.br_share_known > %.4f THEN 1 ELSE 0 END AS keep,
       g.br_share_known,
       g.n_rows,
       g.n_users
FROM gate g
JOIN inst i ON g.oa_matched_name = i.cleaned_display_name", br_share_min)

tmp <- dbExecute(con, paste("CREATE TABLE cw0 AS", cw_sql))

# Note 9: the dominant id, and the concentration WITHOUT which it must
# not be used. Ranking rule copied from script 6 -- rank an rsid's ids
# by the matched rows pointing at them.
#
# dom_share's denominator is the rsid's TRUE matched rows, taken from
# DISTINCT pairs, not sum(n_rows) over this table: the 12 fan-out pairs
# appear twice here, and dividing by the inflated total would understate
# every share on those schools. oa_rows on the numerator still carries
# that duplication for the fan-out ids, which is what script 6's rule
# does and is immaterial at 12 pairs of 24,276.
tmp <- dbExecute(con, "
CREATE TABLE cw AS
WITH pair AS (SELECT DISTINCT rsid, university_raw, n_rows FROM cw0),
rtot AS (SELECT rsid, sum(n_rows) AS rsid_matched_rows FROM pair GROUP BY 1),
agg  AS (SELECT rsid, openalex_id, sum(n_rows) AS oa_rows FROM cw0 GROUP BY 1, 2),
rk   AS (SELECT a.rsid, a.openalex_id, a.oa_rows, t.rsid_matched_rows,
                row_number() OVER (PARTITION BY a.rsid
                                   ORDER BY a.oa_rows DESC, a.openalex_id) AS rk,
                count(*) OVER (PARTITION BY a.rsid) AS n_ids_rsid
         FROM agg a JOIN rtot t ON a.rsid = t.rsid),
dom  AS (SELECT rsid, openalex_id AS dom_openalex_id, n_ids_rsid,
                CAST(oa_rows AS double) / rsid_matched_rows AS dom_share
         FROM rk WHERE rk = 1)
SELECT c.*, d.dom_openalex_id, d.dom_share, d.n_ids_rsid
FROM cw0 c JOIN dom d ON c.rsid = d.rsid")

####################################################################
### Step 3: validation
####################################################################

cat("\n=========== VALIDATION ===========\n")
v <- dbGetQuery(con, "
  SELECT count(*) AS n_rows,
         count(DISTINCT (rsid, university_raw, openalex_id)) AS n_grain,
         count(DISTINCT (rsid, university_raw)) AS n_pairs,
         count(DISTINCT rsid) AS n_rsids,
         count(DISTINCT openalex_id) AS n_ids,
         count(DISTINCT CASE WHEN keep = 1 THEN rsid END) AS n_keep_rsid,
         sum(CASE WHEN rsid IS NULL OR university_raw IS NULL
                    OR openalex_id IS NULL THEN 1 ELSE 0 END) AS n_key_null,
         sum(CASE WHEN m_exact = 1 AND m_norm = 0 THEN 1 ELSE 0 END) AS bad_superset,
         sum(CASE WHEN has_exact = 1 AND has_norm = 0 THEN 1 ELSE 0 END) AS bad_arm,
         sum(CASE WHEN m_norm <> 1 THEN 1 ELSE 0 END) AS bad_unmatched
  FROM cw")
print(v)

if (v$n_grain != v$n_rows) {
  stop("Grain violated: ", v$n_rows, " rows but ", v$n_grain,
       " distinct (rsid, university_raw, openalex_id).")
}
if (v$n_key_null != 0) stop("NULL in a key column.")
# Every accepted pair must have come through the lookup. The drift
# check above proves the names resolve; this proves the join did not
# lose a pair for some other reason.
if (v$n_pairs != src$gate_pairs) {
  stop(v$n_pairs, " pairs survived the join but the gate table has ",
       src$gate_pairs, ". No pair may be lost -- see note 7.")
}
if (v$bad_unmatched != 0) {
  stop(v$bad_unmatched, " rows carry m_norm <> 1. The gate table publishes ",
       "only C_norm matches, so this is impossible by construction.")
}
if (v$bad_superset != 0 || v$bad_arm != 0) {
  stop("C_norm must be a superset of C: ", v$bad_superset, " rows with ",
       "m_exact = 1 and m_norm = 0, ", v$bad_arm, " with has_exact = 1 and ",
       "has_norm = 0.")
}
# Every id must exist upstream. True by construction via the JOIN, so a
# failure here means the join keys are not what they claim to be.
oid <- dbGetQuery(con, "
  SELECT count(*) AS n FROM (SELECT DISTINCT openalex_id FROM cw) x
  LEFT JOIN inst i ON x.openalex_id = i.openalex_id
  WHERE i.openalex_id IS NULL")
if (oid$n != 0) stop(oid$n, " openalex_id values are absent from ", basename(inst_path))

if (v$n_rows != exp_rows) {
  stop("Expected ", exp_rows, " rows, got ", v$n_rows,
       ". Both inputs are fixed files, so this is deterministic (note 8): ",
       "an input changed underneath this script.")
}
if (v$n_pairs != exp_pairs || v$n_rsids != exp_rsids ||
    v$n_keep_rsid != exp_keep) {
  stop("Shape changed: pairs/rsids/keep-rsids came out ", v$n_pairs, "/",
       v$n_rsids, "/", v$n_keep_rsid, ", expected ", exp_pairs, "/",
       exp_rsids, "/", exp_keep, ".")
}
cat("\nrows                          :", format(v$n_rows, big.mark = ","), "\n")
cat("  distinct (rsid, raw) pairs  :", format(v$n_pairs, big.mark = ","), "\n")
cat("  distinct rsid               :", format(v$n_rsids, big.mark = ","),
    sprintf("(%s surviving the gate)\n", format(v$n_keep_rsid, big.mark = ",")))
cat("  distinct openalex_id        :", format(v$n_ids, big.mark = ","), "\n")
cat("[OK] all validations passed\n")

####################################################################
### Step 4: the fan-out, named rather than counted
####################################################################

# Note 3. These are the only pairs where the id is ambiguous, so they
# are printed in full: a reader deciding what to do about one of them
# needs to see both candidates, not a count.
cat("\n=========== FAN-OUT ON openalex_id (note 3) ===========\n")
fan <- dbGetQuery(con, "
  SELECT rsid, university_raw, openalex_cleaned_display_name AS oa_name,
         openalex_id, openalex_type, openalex_works_count, keep
  FROM cw
  WHERE (rsid, university_raw) IN (
    SELECT rsid, university_raw FROM cw
    GROUP BY rsid, university_raw HAVING count(*) > 1)
  ORDER BY oa_name, rsid, openalex_id")
print(fan, right = FALSE, row.names = FALSE)
n_fan_pairs <- length(unique(paste(fan$rsid, fan$university_raw)))
cat("\nambiguous pairs:", n_fan_pairs, "of",
    format(v$n_pairs, big.mark = ","),
    sprintf("(%d rows); the rest are 1:1\n", nrow(fan)))
if (n_fan_pairs != exp_fanout) {
  stop("Expected ", exp_fanout, " ambiguous pairs, got ", n_fan_pairs,
       ". The duplicate-name groups in the OpenAlex snapshot changed.")
}
# The ambiguity must come from OpenAlex's own duplicate names and from
# nothing else. If a pair fans out for any other reason the join is not
# the lookup note 2 claims it is.
oth <- dbGetQuery(con, "
  SELECT count(*) AS n FROM (
    SELECT openalex_cleaned_display_name AS nm
    FROM cw GROUP BY rsid, university_raw, openalex_cleaned_display_name
    HAVING count(*) > 1) f
  WHERE nm NOT IN (
    SELECT cleaned_display_name FROM inst
    GROUP BY cleaned_display_name HAVING count(*) > 1)")
if (oth$n != 0) {
  stop(oth$n, " pairs fan out on a name that is NOT a duplicate in the ",
       "institutions list. The join is not the exact lookup it claims ",
       "to be (note 2).")
}
cat("[OK] every fan-out traces to an OpenAlex duplicate-name group\n")

####################################################################
### Step 4b: the dominant id, and why dom_share must travel with it
####################################################################

dv <- dbGetQuery(con, "
  SELECT sum(CASE WHEN dom_openalex_id IS NULL OR dom_share IS NULL
                    OR n_ids_rsid IS NULL THEN 1 ELSE 0 END) AS n_null,
         sum(CASE WHEN dom_share <= 0 OR dom_share > 1 THEN 1 ELSE 0 END) AS bad_share,
         sum(CASE WHEN n_ids_rsid < 1 THEN 1 ELSE 0 END) AS bad_n,
         sum(CASE WHEN n_ids_rsid = 1 AND dom_share < 0.999 THEN 1 ELSE 0 END) AS bad_single
  FROM cw")
if (dv$n_null != 0) stop(dv$n_null, " rows have a NULL dominant-id column.")
if (dv$bad_share != 0) stop(dv$bad_share, " rows have dom_share outside (0, 1].")
if (dv$bad_n != 0) stop(dv$bad_n, " rows have n_ids_rsid < 1.")
# A school with exactly one id must have all of its matched rows on it.
# If not, the denominator is not the rsid's matched rows (note 9).
if (dv$bad_single != 0) {
  stop(dv$bad_single, " rows have n_ids_rsid = 1 but dom_share < 1. The ",
       "dom_share denominator is wrong.")
}

cat("
=========== dom_share BANDS (note 9) ===========
")
print(dbGetQuery(con, "
  SELECT CASE WHEN dom_share >= 0.99 THEN 'a  >= 99%'
              WHEN dom_share >= 0.90 THEN 'b  90-99%'
              WHEN dom_share >= 0.75 THEN 'c  75-90%'
              WHEN dom_share >= 0.50 THEN 'd  50-75%'
              ELSE 'e  < 50%  HAND REVIEW' END AS band,
         count(DISTINCT rsid) AS n_rsid,
         count(DISTINCT CASE WHEN keep = 1 THEN rsid END) AS n_rsid_kept,
         count(*) AS n_rows
  FROM cw GROUP BY 1 ORDER BY 1"), right = FALSE, row.names = FALSE)
cat("
  Band e is where dom_openalex_id must NOT be taken at face value:
",
    "  Revelio has pooled a family of institutions into one key. See note 9.
", sep = "")

cat("
=========== SURVIVING SCHOOLS WITH dom_share < 0.5 ===========
")
print(dbGetQuery(con, "
  SELECT DISTINCT rsid, university_name, n_ids_rsid,
         round(dom_share, 3) AS dom_share, dom_openalex_id
  FROM cw WHERE keep = 1 AND dom_share < 0.5
  ORDER BY dom_share, rsid"), right = FALSE, row.names = FALSE)

####################################################################
### Step 5: reports
####################################################################

cat("\n=========== BY openalex_type (note 6) ===========\n")
print(dbGetQuery(con, "
  SELECT openalex_type, count(*) AS n_rows,
         count(DISTINCT openalex_id) AS n_inst,
         count(DISTINCT rsid) AS n_rsid,
         sum(n_users) AS pair_users
  FROM cw GROUP BY 1 ORDER BY 2 DESC"), right = FALSE, row.names = FALSE)
cat("\n  `company` is not an error: see note 6. Estacio lives there.\n")

cat("\n=========== TOP 20 INSTITUTIONS BY MATCHED PAIRS ===========\n")
print(dbGetQuery(con, "
  SELECT openalex_id, openalex_cleaned_display_name AS oa_name,
         openalex_type, count(*) AS n_pairs,
         count(DISTINCT rsid) AS n_rsid,
         sum(CASE WHEN keep = 1 THEN 1 ELSE 0 END) AS n_kept_pairs
  FROM cw GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 20"),
  right = FALSE, row.names = FALSE)

####################################################################
### Step 6: write, then read it back
####################################################################

n_written <- dbExecute(con, sprintf(
  "COPY (SELECT * FROM cw ORDER BY rsid, university_raw, openalex_id)
   TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", gsub("\\\\", "/", out_path)))

# COPY returns the number of rows it wrote, so the write itself is
# checked rather than assumed before the file is even reopened.
if (n_written != v$n_rows) {
  stop("COPY reported ", n_written, " rows written but the table has ",
       v$n_rows, ".")
}

back <- arrow::read_parquet(out_path)
if (nrow(back) != v$n_rows) {
  stop("Wrote ", v$n_rows, " rows but read back ", nrow(back), ".")
}
if (length(unique(back$openalex_id)) != v$n_ids) {
  stop("openalex_id did not survive the write.")
}

cat("\n=========== SUMMARY ===========\n")
cat("  output        :", out_path,
    sprintf("(%.1f KB)\n", file.info(out_path)$size / 2^10))
cat("  grain         : (rsid, university_raw, openalex_id)\n")
cat("  rows          :", format(v$n_rows, big.mark = ","), "over",
    format(v$n_pairs, big.mark = ","), "pairs and",
    format(v$n_ids, big.mark = ","), "institutions\n")
cat("  scope         : all C_norm matches; `keep` stored, not filtered (note 5)\n")
cat("  join          : oa_matched_name = cleaned_display_name, exact (note 2)\n")
