####################################################################
###
### Parent and lineage-root OpenAlex ids for the Shanghai top-1000
###                                                    [local only]
###
### Script 4 gives every ranked institution its OpenAlex display_name.
### It does NOT say whether that institution is a constituent school of
### a larger one. This script adds that: the immediate parent and the
### root of the lineage, for the 1,000 institutions in the band.
###
### Why it is needed. CAPES resolves "FUNDACAO GETULIO VARGAS (SP)" to
### I44202434; Revelio resolves "FGV EESP" to I4403928399 (Escola de
### Economia de Sao Paulo). Same university, parent record against
### constituent school. Anything joining the two sides on a bare
### openalex_id never compares them. Carrying the parent makes the
### roll-up available to a consumer without re-reading the snapshot.
###
### Outputs:
###   shanghai_ranking_oa_parents.parquet   1,000 rows, 20 columns:
###     the ranking's 13, renamed lowercase (note 11) with Rank ->
###     shanghai_rank as INT (note 10), plus oa_id_valid, in_snapshot
###     and the 5 lineage columns. This is the file script 4b uploads,
###     and its COLUMN ORDER is what 4b asserts -- Athena's Parquet
###     SerDe resolves by position, so reordering it silently changes
###     what the Athena table means.
###
### Depends on:
###   shanghai_ranking_openalex_names.R      (4)
###   the OpenAlex institutions snapshot under GT_ROOT
###
### NO NETWORK. Local gz snapshot in, local parquet out. Free.
### Still prep/, still not for SEDAP.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. THE PROJECTION IS MANDATORY. Snapshot records average ~21 KB
###    because of topics, topic_share and counts_by_year. The explicit
###    columns = {...} on read_ndjson makes the JSON reader skip them.
###    Do not read the full record "just to look" -- that is the
###    difference between seconds and minutes, and scripts 3 and 4 both
###    declare a projection for the same reason.
### 2. *** LINEAGE ORDER IS NOT RELIABLE. *** 105,846 institutions list
###    themselves first but 11,672 list themselves LAST. Neither
###    lineage[1] nor lineage[len(lineage)] is the root. The robust
###    rule, and the one used here, is
###
###      the ancestor whose OWN lineage has length 1
###
###    which is why the root map has to be built over all 120,658
###    records and not just over the 1,000 in the band. Depth reaches
###    30, so this is not a two-level tree and no single-step parent
###    lookup substitutes for it.
### 3. 3,227 INSTITUTIONS HAVE MORE THAN ONE ROOT, so the roll-up is
###    NOT a function for them. n_roots records how many were found and
###    root_openalex_id is left NULL when it is not 1. Taking a min()
###    or a first() there would invent an answer; a consumer who wants
###    one can read the ambiguity and decide. Same rule for n_parents.
### 4. `relationship` HAS THREE VALUES in this data -- 'parent',
###    'child' and 'related' -- and only 'parent' is read here. 'child'
###    is the same edge seen from the other end and would invert the
###    map; 'related' is not a hierarchy at all (FGV lists Escola
###    Brasileira de Economia e Financas as `related`, not `child`).
### 5. THE BAND IS Rank <= 901, exactly 1,000 rows, the same band as
###    scripts 16, 16a, 16b and 8g. Rank is a BAND START, not a
###    position: it runs exact to 98, then 101, 151, 201 ... 901. This
###    is asserted with stop() and not warning(): if the bands ever
###    move the arithmetic has to be re-derived, never silently
###    reinterpreted.
### 6. ONE ROW OF THE BAND CANNOT BE RESOLVED AT ALL, and it is an
###    upstream defect, not a bug here. Rank 701 carries the *name*
###    'RUTGERS UNIVERSITY - NEWARK' in its OA_key column instead of an
###    I-number. Every id is shape-tested against ^I[0-9]+$ and what
###    fails is counted and reported rather than propagated. The defect
###    is in shanghai_ranking_full_cleaned.xlsx and is still there.
### 7. ids ARE FULL URLs IN THE SNAPSHOT ('https://openalex.org/I123'),
###    in `lineage` and in `associated_institutions.id` as well as in
###    `id`. Everything is reduced to the short key with
###    regexp_extract(x, 'I[0-9]+') before it is compared, because the
###    ranking side carries the short form.
### 8. THE OUTPUT IS THE BAND, NOT THE WHOLE RANKING. shanghai_ranking_
###    oa.parquet has 1,079 rows; this has 1,000. The 79 rows with a
###    NULL Rank are outside every consumer of this folder.
### 9. Rank IS A DOUBLE in the parquet, not an integer, and so are
###    math_Rank, shanghai_Rank_2003, uni_ranking, top_50_uni and
###    has_top_50_uni. The band comparison uses %f for that reason.
### 10. *** THE OUTPUT RENAMES Rank TO shanghai_rank AND CASTS IT TO
###    INTEGER. *** Two separate reasons, and both bite in Athena, not
###    here:
###      a. `rank` is a window function in Trino and a SQL:2011
###         reserved word in Hive. A column called `rank` has to be
###         quoted in every DDL and every query that touches it, and
###         it only takes forgetting once.
###      b. it arrives as a DOUBLE. Verified integral on this band
###         (min 1, max 901), so the CAST is lossless, and an INT
###         column is what a consumer expects to compare against.
###    Everything else keeps its name, LOWERCASED -- see note 11.
### 11. ALL OUTPUT COLUMN NAMES ARE LOWERCASE, deliberately. The Glue
###    catalogue lowercases column names on registration, so a parquet
###    written with `OA_key` and `shanghai_Name` becomes `oa_key` and
###    `shanghai_name` in Athena regardless. Writing them lowercase
###    here means the local file and the Athena table have the SAME
###    names, instead of two spellings of one schema. It does mean this
###    file is not a drop-in for shanghai_ranking_oa.parquet, whose
###    consumers (16, 16a, 16b, 8g) keep reading that one unchanged.
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
library(duckdb)

####################################################################
### Parameters
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
gt_root    <- Sys.getenv("GT_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/GTAllocation")

oa_dir  <- file.path(gt_root, "Data/external/oa_snapshot/data/institutions")
oa_glob <- file.path(oa_dir, "updated_date=*/part_*.gz")

sh_dir   <- file.path(obmep_root, "Data/intermediate/shanghai_ranking")
sh_path  <- file.path(sh_dir, "shanghai_ranking_oa.parquet")
out_path <- file.path(sh_dir, "shanghai_ranking_oa_parents.parquet")

rank_cut  <- 901
mem_limit <- "8GB"

# Measured against the February/2026 snapshot and the current xlsx.
exp_band       <- 1000L
exp_snapshot   <- 120658L
exp_bad_oa_key <- 1L                            # note 6
exp_bad_names  <- "RUTGERS UNIVERSITY - NEWARK" # note 6

# The whole-snapshot lineage shape. These reproduce the figures the
# README records under TO-DO item 1, from different code, which is the
# strongest check in this script -- if they drift, the roll-up rule in
# note 2 is the first thing to re-derive.
exp_one_root   <- 117431L
exp_amb_roots  <- 3227L
exp_no_root    <- 0L
exp_max_depth  <- 30L

# The band's own lineage, measured 2026-09-07 on the first run.
exp_has_parent <- 126L
exp_has_root   <- 997L
exp_not_own_root <- 32L

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_shanghai_parents")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(file.exists(sh_path), dir.exists(oa_dir),
          length(Sys.glob(oa_glob)) > 0L)

con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# The spill must never land in a Dropbox-synced folder.
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))
fw <- function(p) gsub("\\\\", "/", p)

cat("DuckDB  :", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("ranking :", sh_path, "\n")
cat("snapshot:", oa_dir, "\n")
cat("output  :", out_path, "\n\n")

####################################################################
### Step 1: the band (note 5)
####################################################################

dbExecute(con, sprintf(
  "CREATE TABLE band AS SELECT * FROM read_parquet('%s') WHERE Rank <= %f",
  fw(sh_path), rank_cut))

n_band <- dbGetQuery(con, "SELECT count(*) AS n FROM band")$n
cat("=========== BAND ===========\n")
cat("  Rank <=", rank_cut, ":", n_band, "institutions\n")
if (n_band != exp_band) {
  stop("The band is ", n_band, " rows, not ", exp_band, ". Rank is a band ",
       "start, not a position -- if the bands moved, the arithmetic has to ",
       "be re-derived, not reinterpreted.")
}

# Note 6. Shape-test before anything joins on it.
bad <- dbGetQuery(con, "
  SELECT OA_key, shanghai_Name, Rank FROM band
  WHERE OA_key IS NULL OR NOT regexp_full_match(OA_key, 'I[0-9]+')")
cat("  malformed OA_key            :", nrow(bad), "\n")
if (nrow(bad)) print(bad, row.names = FALSE)
if (nrow(bad) != exp_bad_oa_key || !setequal(bad$OA_key, exp_bad_names)) {
  warning("The malformed-id set moved: ", nrow(bad), " row(s), [",
          paste(bad$OA_key, collapse = "; "), "], expected ", exp_bad_oa_key,
          " [", paste(exp_bad_names, collapse = "; "), "]. Note 6.")
}

####################################################################
### Step 2: the snapshot, projected (note 1)
####################################################################

sql_read <- sprintf("
  read_ndjson(
    '%s',
    filename = true,
    columns = {
      id: 'VARCHAR',
      display_name: 'VARCHAR',
      country_code: 'VARCHAR',
      lineage: 'VARCHAR[]',
      associated_institutions: 'STRUCT(id VARCHAR, ror VARCHAR,
                                       display_name VARCHAR,
                                       country_code VARCHAR, type VARCHAR,
                                       relationship VARCHAR)[]'
    }
  )", fw(oa_glob))

# Dedupe by id keeping the most recent partition. The folder name is
# ISO and sorts lexically; the updated_date INSIDE the record is
# US-format and does not sort. Today the partitions are disjoint, so
# this removes nothing -- it is a safeguard, because OpenAlex ships a
# dump plus deltas and nothing guarantees they stay disjoint.
dbExecute(con, sprintf("
  CREATE TABLE oa AS
  SELECT regexp_extract(id, 'I[0-9]+') AS oa_key,
         display_name,
         country_code,
         lineage,
         associated_institutions
  FROM (
    SELECT id, display_name, country_code, lineage, associated_institutions,
           regexp_extract(filename, 'updated_date=([0-9]{4}-[0-9]{2}-[0-9]{2})', 1)
             AS snapshot_date
    FROM %s
  )
  QUALIFY row_number() OVER (PARTITION BY id ORDER BY snapshot_date DESC) = 1",
  sql_read))

n_oa <- dbGetQuery(con, "SELECT count(*) AS n FROM oa")$n
cat("\n=========== SNAPSHOT ===========\n")
cat("  institutions                :", format(n_oa, big.mark = ","), "\n")
if (n_oa != exp_snapshot) {
  warning("Snapshot moved: ", n_oa, " institutions, expected ", exp_snapshot)
}

####################################################################
### Step 3: the root map, over ALL institutions (notes 2 and 3)
####################################################################

# Every (institution, ancestor) edge, short keys on both sides.
dbExecute(con, "
  CREATE TABLE lin AS
  SELECT oa_key, regexp_extract(anc, 'I[0-9]+') AS anc_key
  FROM oa, UNNEST(lineage) AS t(anc)
  WHERE anc IS NOT NULL")

# Note 2: a root is an institution whose OWN lineage has length 1.
# Order within the array is not used anywhere.
dbExecute(con, "
  CREATE TABLE is_root AS
  SELECT oa_key FROM oa WHERE len(lineage) = 1")

dbExecute(con, "
  CREATE TABLE rootmap AS
  SELECT l.oa_key,
         count(*) AS n_roots,
         CASE WHEN count(*) = 1 THEN any_value(l.anc_key) END AS root_openalex_id
  FROM lin l JOIN is_root r ON l.anc_key = r.oa_key
  GROUP BY l.oa_key")

rstat <- dbGetQuery(con, "
  SELECT (SELECT count(*) FROM oa)                            AS institutions,
         (SELECT count(*) FROM rootmap)                       AS with_a_root,
         (SELECT count(*) FROM rootmap WHERE n_roots = 1)     AS one_root,
         (SELECT count(*) FROM rootmap WHERE n_roots > 1)     AS ambiguous,
         (SELECT count(*) FROM oa
           WHERE oa_key NOT IN (SELECT oa_key FROM rootmap))  AS no_root,
         (SELECT max(len(lineage)) FROM oa)                   AS max_depth")
cat("\n=========== ROOT MAP (all institutions) ===========\n")
print(rstat, row.names = FALSE)

# These four reproduce the README's TO-DO item 1 figures from different
# code. no_root is a stop(): the rule in note 2 says every institution
# has at least one ancestor whose own lineage has length 1, and a
# counterexample means the rule is wrong, not the data.
if (rstat$no_root != exp_no_root) {
  stop(rstat$no_root, " institutions have no root at all, expected ",
       exp_no_root, ". The rule in note 2 -- 'the ancestor whose own lineage ",
       "has length 1' -- does not hold on this snapshot and has to be ",
       "re-derived before anything consumes root_openalex_id.")
}
if (rstat$one_root != exp_one_root || rstat$ambiguous != exp_amb_roots ||
    rstat$max_depth != exp_max_depth) {
  warning("Lineage shape moved: ", rstat$one_root, " single-root / ",
          rstat$ambiguous, " ambiguous / depth ", rstat$max_depth,
          ", expected ", exp_one_root, " / ", exp_amb_roots, " / ",
          exp_max_depth)
}

####################################################################
### Step 4: the immediate parent (note 4)
####################################################################

dbExecute(con, "
  CREATE TABLE parmap AS
  SELECT oa_key,
         count(*) AS n_parents,
         CASE WHEN count(*) = 1
              THEN any_value(regexp_extract(a.id, 'I[0-9]+')) END
           AS parent_openalex_id
  FROM oa, UNNEST(associated_institutions) AS t(a)
  WHERE a.relationship = 'parent' AND a.id IS NOT NULL
  GROUP BY oa_key")

cat("\n=========== PARENT MAP (all institutions) ===========\n")
print(dbGetQuery(con, "
  SELECT count(*)                                       AS with_a_parent,
         sum(CASE WHEN n_parents = 1 THEN 1 ELSE 0 END) AS one_parent,
         sum(CASE WHEN n_parents > 1 THEN 1 ELSE 0 END) AS ambiguous
  FROM parmap"), row.names = FALSE)

####################################################################
### Step 5: attach to the band and write
####################################################################

# LEFT JOIN with the band driving: no ranked row may be lost or
# duplicated, including the malformed one from note 6, which simply
# gets NULLs. oa is unique on oa_key after the QUALIFY, so the join
# cannot fan out.
dbExecute(con, "
  CREATE TABLE out AS
  SELECT b.OA_key                             AS oa_key,
         CAST(b.Rank AS INTEGER)              AS shanghai_rank,
         b.shanghai_Name                      AS shanghai_name,
         b.OA_id                              AS oa_id,
         b.display_name,
         b.cleaned_display_name,
         b.country_code,
         b.iso3c,
         CAST(b.math_Rank          AS DOUBLE) AS math_rank,
         CAST(b.shanghai_Rank_2003 AS DOUBLE) AS shanghai_rank_2003,
         CAST(b.uni_ranking        AS DOUBLE) AS uni_ranking,
         CAST(b.top_50_uni         AS DOUBLE) AS top_50_uni,
         CAST(b.has_top_50_uni     AS DOUBLE) AS has_top_50_uni,
         -- Note 6: the shape test travels as a column, so 6a asserts on
         -- it instead of re-deriving the regex against a defect it did
         -- not introduce.
         CAST(CASE WHEN b.OA_key IS NOT NULL
                    AND regexp_full_match(b.OA_key, 'I[0-9]+')
                   THEN 1 ELSE 0 END          AS INTEGER) AS oa_id_valid,
         CAST(CASE WHEN o.oa_key IS NOT NULL
                   THEN 1 ELSE 0 END          AS INTEGER) AS in_snapshot,
         p.parent_openalex_id,
         CAST(coalesce(p.n_parents, 0)        AS INTEGER) AS n_parents,
         r.root_openalex_id,
         CAST(coalesce(r.n_roots, 0)          AS INTEGER) AS n_roots,
         CAST(coalesce(len(o.lineage), 0)     AS INTEGER) AS lineage_depth
  FROM band b
  LEFT JOIN oa      o ON o.oa_key = b.OA_key
  LEFT JOIN parmap  p ON p.oa_key = b.OA_key
  LEFT JOIN rootmap r ON r.oa_key = b.OA_key")

# Note 10b: the CAST is lossless only if Rank really is integral.
frac <- dbGetQuery(con,
  "SELECT count(*) AS n FROM band WHERE Rank <> floor(Rank)")$n
if (frac != 0L) {
  stop(frac, " rows carry a fractional Rank, so CAST(Rank AS INTEGER) ",
       "would lose information. Note 10b assumed the band is integral.")
}

n_out <- dbGetQuery(con, "SELECT count(*) AS n FROM out")$n
if (n_out != exp_band) {
  stop("The join changed the row count: ", n_out, " out, ", exp_band,
       " in. oa must be unique on oa_key.")
}
if (dbGetQuery(con, "SELECT count(DISTINCT oa_key) AS n FROM out")$n != exp_band) {
  stop("oa_key is not unique in the output.")
}

cat("\n=========== THE BAND'S LINEAGE ===========\n")
bl <- dbGetQuery(con, "
  SELECT sum(CASE WHEN parent_openalex_id IS NOT NULL THEN 1 ELSE 0 END) AS has_parent,
         sum(CASE WHEN n_parents > 1 THEN 1 ELSE 0 END)                  AS parent_ambiguous,
         sum(CASE WHEN root_openalex_id IS NOT NULL THEN 1 ELSE 0 END)   AS has_root,
         sum(CASE WHEN n_roots  > 1 THEN 1 ELSE 0 END)                   AS root_ambiguous,
         sum(CASE WHEN root_openalex_id IS NOT NULL
                   AND root_openalex_id <> oa_key THEN 1 ELSE 0 END)     AS root_is_someone_else,
         max(lineage_depth)                                              AS max_depth
  FROM out")
print(bl, row.names = FALSE)
if (bl$has_parent != exp_has_parent || bl$has_root != exp_has_root ||
    bl$root_is_someone_else != exp_not_own_root) {
  warning("The band's lineage moved: ", bl$has_parent, " with a parent / ",
          bl$has_root, " with a root / ", bl$root_is_someone_else,
          " not their own root, expected ", exp_has_parent, " / ",
          exp_has_root, " / ", exp_not_own_root)
}

cat("\n  ranked institutions that are NOT their own root:\n")
print(dbGetQuery(con, "
  SELECT oa_key, display_name, root_openalex_id, parent_openalex_id,
         shanghai_rank
  FROM out
  WHERE root_openalex_id IS NOT NULL AND root_openalex_id <> oa_key
  ORDER BY shanghai_rank LIMIT 20"), right = FALSE, row.names = FALSE)

# Write through .part so an interrupted run never leaves a truncated
# file behind pretending to be a finished one.
part <- paste0(out_path, ".part")
dbExecute(con, sprintf(
  "COPY out TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", fw(part)))
if (file.exists(out_path)) file.remove(out_path)
file.rename(part, out_path)

cat("\n=========== SUMMARY ===========\n")
cat("  output :", out_path,
    sprintf("(%.0f KB, %d rows)\n", file.info(out_path)$size / 2^10, n_out))
cat("  columns:", paste(dbListFields(con, "out"), collapse = ", "), "\n")
