####################################################################
###
### Shanghai top-1000 <-> Revelio rsid crosswalk    -> S3 + Athena
###
### One row per (ranked institution, Revelio school key), carrying the
### names from BOTH datasets and the evidence behind the pair.
###
### Nothing in this folder publishes this object. What exists is:
###
###   shanghai_rsid_name_map.parquet   rsid -> ranked institution, keyed
###                                    on Revelio's university_name.
###                                    895 rsids, 828 of 1,000, and it
###                                    only sees the OBMEP cohort.
###   shanghai_raw_crosswalk (16b)     keyed on the TYPED STRING, not
###                                    the school. Cohort only.
###   revelio_oa_crosswalk (8m)        the unified six-strategy map, but
###                                    it carries no NAMES on either
###                                    side and is not restricted to the
###                                    ranking. Cohort only.
###   rsid_openalex_br_crosswalk (6)   the right SHAPE, and Athena-wide,
###                                    but it matches the BRAZILIAN
###                                    institution list, which reaches
###                                    18 of the 1,000 ranked.
###
### This is script 6's shape pointed at the ranking instead of the
### Brazilian list, over ALL of Revelio rather than the cohort.
###
### Outputs:
###   revelio_database.shanghai_rsid_oa_crosswalk
###   s3://revelio-misc/exports/shanghai_rsid_oa_crosswalk/
###   OBMEP/.../shanghai_ranking/shanghai_rsid_oa_crosswalk.parquet
###
### Depends on:
###   shanghai_ranking_oa_parents.R    (4a)  -> the 1,000-row band
###   shanghai_ranking_oa_to_s3.R      (4b)  -> revelio_database.shanghai_ranking_oa
###
### Athena read/UNLOAD pattern reused from:
###   prep/building_external_data/rsid_openalex_br_crosswalk.R
### The C_norm matcher is copied from:
###   prep/building_external_data/revelio_br_cohort_user_ids.R (lines ~284-315)
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. Reading from Athena and writing to S3 is the whole
###    point. Local prep/ script; must not be sent to SEDAP.
### 2. *** NEVER CONSUME BARE rsid MEMBERSHIP. *** This is script 6's
###    central finding and it applies here with full force. ONE
###    education row is enough to poison an rsid: someone whose Revelio
###    rsid is Harvard typed a Brazilian university name, 1 row out of
###    562,968, and `rsid IN (SELECT rsid FROM ...)` then admits all of
###    Harvard. The same mechanism drags in Phoenix, Delhi, Buenos
###    Aires, Toronto, UNAM, Cambridge and Berkeley.
###
###    The separating statistic is not stored, because it is a pure
###    function of two published columns and storing it would let it go
###    stale:
###
###      match_share = n_rows / rsid_n_rows
###
###    Step 5 prints the band table on every run. Apply a floor before
###    consuming anything from this table.
###
###    DO NOT substitute a country share for it. rsid_top_country is
###    published for diagnosis, not for cutting: the Brazil share is
###    near zero for institutions that are beyond any doubt Brazilian
###    (FGV 0.0011, UFRGS 0.0006), because those rows carry a NULL or
###    non-Brazil university_country -- which is the exact gap this
###    kind of matching exists to close.
### 3. THE MATCH IS ONE ARM: C_norm, copied from
###    revelio_br_cohort_user_ids.R and not re-derived. Fold both
###    sides, then accept the whole folded string OR any '/', '(', ')',
###    '|' or ' - ' delimited segment of >= 3 characters. No acronym
###    arm, no display_name_alternatives, no fuzzy matching, no
###    composition of 8m's six strategies. That is the requested scope.
### 4. THE SEGMENT ARM CARRIES NO is_edu = 1 RESTRICTION, and dropping
###    it is deliberate. In revelio_br_cohort_user_ids.R that
###    restriction is load-bearing because the Brazilian OpenAlex list
###    holds short COMPANY names -- IBM, Vale, Intel, Shell -- and
###    "Curso de Ingles - Intel" would match one. The ranking holds
###    nothing but universities and has no `type` column to filter on
###    even if you wanted to. This is the same departure script 16
###    already makes and documents.
###
###    It is not free of risk, only of THAT risk. With display_name and
###    cleaned_display_name as the name side, the shortest folded
###    institution string is 'tu wien' at 7 characters, then
###    'uclouvain' and 'ku leuven' at 9. Step 5 prints the pairs the
###    segment arm reaches ALONE, which is where a false positive would
###    show.
### 5. ONLY A NAME CLAIMED BY EXACTLY ONE RANKED INSTITUTION IS USED.
###    Three folded names inside the band are claimed by two:
###
###      northeastern university          Boston / Shenyang
###      china medical university         Taiwan / Shenyang
###      china university of geosciences  Beijing / Wuhan
###
###    The first two are genuine homonyms in OpenAlex's own
###    display_name and no name arm can separate them. The third is an
###    ARTEFACT of cleaned_display_name: OpenAlex spells the Beijing
###    institution 'China University of Geosciences (Beijing)' and the
###    paren-stripping cleaner deletes the disambiguator, colliding it
###    with Wuhan's plain display_name. All six institutions are
###    discarded rather than arbitrated -- picking the better-ranked one
###    would be a coin toss. Step 5 prints them.
###
###    *** SO THE CEILING IS 994, NOT 1,000. *** Six ranked
###    institutions cannot be matched by any name arm: those five plus
###    Rutgers-Newark, whose OA_key holds a name instead of an id so
###    both name columns are NULL (4a note 6). Read every coverage
###    number against 994.
### 6. THE NAME SIDE IS display_name + cleaned_display_name, BY
###    REQUEST, AND THAT LEAVES MEASURABLE RECALL ON THE TABLE.
###    shanghai_Name contributes 247 folded strings that appear in
###    NEITHER other column, and they are the anglicised spellings
###    people actually type:
###
###      The University of Edinburgh   vs  University of Edinburgh
###      Karolinska Institute          vs  Karolinska Institutet
###      Sorbonne University           vs  Sorbonne Universite
###      Paris-Saclay University       vs  Universite Paris-Saclay
###      University of Michigan-Ann Arbor vs University of Michigan
###
###    The arm is therefore BUILT and switched OFF, not absent: set
###    use_shanghai_arm <- TRUE to enable it. by_shanghai ships as its
###    own column either way, so the schema does not move and a
###    consumer can always restrict with
###
###      WHERE by_display = 1 OR by_cleaned = 1
###
###    Conversely, keeping shanghai_Name pools a third spelling into
###    the ambiguity device of note 5 and may retire more names.
### 7. cleaned_display_name COSTS ONE INSTITUTION AND BUYS TWO. It
###    contributes exactly two folded names display_name does not --
###    'universidade estadual paulista' (UNESP) and 'universidade
###    estadual de campinas' (UNICAMP), both spelled with the acronym
###    in parentheses by OpenAlex and almost never typed that way --
###    and it costs China University of Geosciences (Wuhan) through the
###    collision in note 5. Measured: display_name alone reaches 995
###    institutions, both columns pooled reach 994. by_display and
###    by_cleaned are separate columns so the trade is reversible with
###    a WHERE.
### 8. THE FOLD IS THE TRINO FORM AND THAT IS CORRECT HERE.
###    lower(regexp_replace(normalize(s, NFD), '\p{M}', '')) does NOT
###    strip a cedilla, because c-cedilla is a single codepoint and not
###    a combining mark. DuckDB's strip_accents() does. Do NOT "fix"
###    this to the DuckDB form: both sides of this comparison run the
###    IDENTICAL Trino expression, so the fold is symmetric and the
###    definition is the one the cohort scripts already use.
###
###    What it does cost is RECALL, invisibly, where the two sides
###    spell the same school differently: OpenAlex 'Bogazici
###    Universitesi' keeps its cedilla and a user typing 'Bogazici
###    University' does not, so they never meet. That produces NULL
###    rows, never wrong rows. Step 5 counts the ranked institutions
###    whose folded name still carries a cedilla, so the at-risk set is
###    named rather than guessed at. MEASURED ON THIS BAND: 0. Not one
###    of the 1,000 ranked display_names carries a cedilla, so the loss
###    is real in principle and empty in fact here. Do not delete the
###    check -- it is what will say so again after a snapshot refresh.
### 9. rsid IS NULLABLE, and the sentinel is rsid_key =
###    coalesce(rsid, 2147483647) -- INT_MAX, which fits because rsid
###    is INT and not bigint. Scripts 8h and 8m already use it. BOTH
###    columns ship: `rsid` stays nullable and honest, `rsid_key` is
###    the one to join on. On THIS table the two NULLs mean different
###    things and must not be conflated:
###
###      rsid NULL, rsid_key NULL         no rsid reached this
###                                       institution at all
###      rsid NULL, rsid_key 2147483647   reached, by rows whose own
###                                       rsid is NULL
###
###    *** THE SENTINEL IS NOT A SCHOOL, AND COVERAGE MUST NOT COUNT
###    IT. *** Every rsid-less education row in Revelio pools into that
###    single key -- measured at 168,952,845 rows -- against which no
###    pair's match_share can exceed 0.00017, so all of them land in the
###    bottom band automatically. On the first run 981 of the 10,730
###    pair rows were sentinel rows and 5 institutions were reached ONLY
###    that way, so the honest coverage figure is 983 institutions, not
###    988. Step 5 prints both and says which one to quote.
### 10. THE DENOMINATOR EXCLUDES BLANK SPELLINGS. base filters
###    university_raw IS NOT NULL AND trim() <> '', so rsid_n_rows
###    counts a school's rows THAT CARRY A SPELLING, not all of them. A
###    string-keyed matcher cannot reach a blank spelling, so including
###    those rows would deflate every match_share by a quantity nothing
###    can act on. Script 8m note 8b takes the same position.
### 11. n_users_approx IS HYPERLOGLOG, NOT AN EXACT COUNT, and it has
###    to be. count(DISTINCT user_id) at the (rsid, university_raw)
###    grain is NOT summable to this table's grain -- anyone who typed
###    two spellings of one school would be counted twice -- and adding
###    user_id to base's GROUP BY destroys the pre-aggregation that
###    makes the query affordable. approx_set/merge/cardinality
###    aggregates correctly across both roll-ups at ~2.3% standard
###    error. Consequence: n_users_approx can exceed n_rows by a couple
###    of percent, so that check is a warning with tolerance and never
###    a stop().
### 12. university_country SAYS THE LITERAL STRING 'empty', not NULL.
###    Script 6's rsid_country filters only IS NOT NULL and can
###    therefore return 'empty' as an rsid's modal country. That is a
###    latent bug in script 6; it is not copied here.
### 13. rsid_top_country IS A COUNTRY NAME, country_code IS ISO-2.
###    They are not comparable without countrycode::, and
###    shanghai_rsid_name_map.R note 6 records that converting the
###    wrong direction manufactured a FALSE VETO on Hong Kong --
###    countrycode renders 'Hong Kong SAR China' against Revelio's
###    'Hong Kong'. Both are published raw and NOTHING is vetoed here.
### 14. FAN-OUT IS EXPECTED IN BOTH DIRECTIONS. Several rsids per
###    institution is normal -- campuses, alumni keys, duplicates --
###    and resolving it is explicitly out of scope. One university_raw
###    can also reach two institutions (whole-string on one, segment on
###    another), so summing n_rows across an rsid's institutions can
###    exceed rsid_n_rows. Per (institution, rsid) it cannot, and that
###    IS asserted.
### 15. COST. One aggregate pass over academic_individual_user_education
###    reading 7 columns, plus a one-column DISTINCT pass, plus the
###    sizing probe. Trino INLINES CTEs, so a CTE referenced twice is
###    scanned twice: `base` is read by `pairs` and by `rsid_country`.
###    Script 6 measured 58.50 GB / ~$0.29 for the same topology on 6
###    columns. Budget ~$0.40-0.50 here. Deriving `raws` from `base`
###    would be WORSE, not better -- a third 7-column inline instead of
###    one 1-column scan.
### 16. UNLOAD REFUSES A NON-EMPTY DESTINATION PREFIX. Rebuilding needs
###    both, in this order:
###      DROP TABLE IF EXISTS revelio_database.shanghai_rsid_oa_crosswalk
###      aws s3 rm s3://revelio-misc/exports/shanghai_rsid_oa_crosswalk/ --recursive
###    Step 2 checks the prefix BEFORE the scan is paid for.
###
####################################################################

rm(list = ls()); gc()
options(width = 220)

for (p in c("DBI", "aws.s3", "RAthena", "arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(aws.s3)

####################################################################
### Parameters
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")

out_dir  <- file.path(obmep_root, "Data/intermediate/shanghai_ranking")
out_path <- file.path(out_dir, "shanghai_rsid_oa_crosswalk.parquet")

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
# Note 16: exports/, because this is an UNLOAD destination. Contrast
# script 4b, a put_object upload, which uses a bare prefix.
s3_prefix <- "exports/shanghai_rsid_oa_crosswalk"
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table  <- "shanghai_rsid_oa_crosswalk"

inst_table <- "shanghai_ranking_oa"                   # registered by 4b
educ_table <- "academic_individual_user_education"

# Note 6. FALSE is the requested scope; TRUE adds the ranking's own
# anglicised spelling as a third folded name source.
use_shanghai_arm <- FALSE

# Note 9.
rsid_sentinel <- 2147483647L

# The band, from 4a. A stop(), not a warning: everything downstream
# reads coverage against it.
exp_inst <- 1000L

# Note 5. Measured locally off shanghai_ranking_oa_parents.parquet.
exp_folds        <- 999L   # distinct folded names, both columns pooled
exp_shared_folds <- 3L     # folds claimed by two institutions
exp_matchable    <- 994L   # institutions any name arm could reach

# NA until the first run measures them, then pinned. A Revelio refresh
# legitimately moves these, so they warn rather than abort.
# Measured on the first full run, 2026-09-07.
exp_rows      <- 10730L
exp_rsids     <- 3964L
exp_reached   <- 988L   # counting the sentinel; 983 by a real rsid
exp_educ_rows <- 623745669

# RAthena talks to Athena through boto3/reticulate. On this machine the
# `python` on PATH is the WindowsApps shim, which reticulate ignores on
# purpose -- so py_discover_config() finds nothing and RAthena concludes
# boto3 is missing, when in fact a real Python with boto3 and numpy is
# already installed. Pointing reticulate at the real interpreter fixes
# it without installing anything.
py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

####################################################################
### Step 1: build the query
####################################################################

# The SELECT body lives in its own variable for two reasons: it is
# reused inside the UNLOAD, and it can be validated on its own (see
# scratchpad/validate_sql_syntax.R), whereas UNLOAD and DDL cannot.
#
# Notes on the shape of the query:
#
#  - `tf` is written out at every site rather than factored into a
#    macro, because Athena has no CREATE MACRO and a helper string
#    substituted by sprintf() would hide the one expression this whole
#    script turns on. It is note 8's fold, verbatim from
#    revelio_br_cohort_user_ids.R.
#  - `raws` is its OWN one-column pass over the education table, not a
#    SELECT DISTINCT off `base`. Trino inlines CTEs, so reusing `base`
#    would add a third seven-column scan where this adds a one-column
#    one (note 15).
#  - the CROSS JOIN UNNEST runs over DISTINCT university_raw, never
#    over education rows. That is what makes the segment arm
#    affordable, and it is why `raws` exists at all.
#  - raw_oa is GROUPed to (university_raw, oa_key), so it is unique on
#    that pair and the join to `pairs` cannot multiply an education
#    row. A raw reaching TWO institutions gives two rows, which is
#    correct and is note 14.
#  - `base` is the only place education rows are counted, and it groups
#    by university_country so the per-rsid country profile costs no
#    extra scan -- script 6's arrangement.
#  - min()/max() over a column compared with IS NOT DISTINCT FROM tests
#    constancy far more cheaply than count(DISTINCT). Both ignore
#    NULLs, so "constant" means constant among the non-null values.
#  - the final join is a LEFT JOIN driven by `inst`, so all 1,000
#    ranked institutions survive whether or not any rsid reached them.
#    An institution nobody attended is a NULL row, not an absent one.

tf <- function(x) {
  sprintf("lower(regexp_replace(normalize(trim(%s), NFD), '\\p{M}', ''))", x)
}

# Note 6: the third arm, present or absent, never changing the schema.
shanghai_branch <- if (use_shanghai_arm) sprintf("
    UNION ALL
    SELECT %s, oa_key, 0, 0, 1 FROM inst
      WHERE oa_id_valid = 1 AND shanghai_name IS NOT NULL
        AND length(trim(shanghai_name)) >= 3", tf("shanghai_name")) else ""

select_sql <- sprintf("
WITH inst AS (
  SELECT oa_key, shanghai_rank, shanghai_name, display_name,
         cleaned_display_name, country_code, iso3c, oa_id_valid,
         parent_openalex_id, n_parents, root_openalex_id, n_roots
  FROM %1$s.%2$s
),
nm AS (
  SELECT %4$s AS nm_fold, oa_key, 1 AS f_disp, 0 AS f_clean, 0 AS f_shang
  FROM inst
    WHERE oa_id_valid = 1 AND display_name IS NOT NULL
      AND length(trim(display_name)) >= 3
  UNION ALL
  SELECT %5$s, oa_key, 0, 1, 0 FROM inst
    WHERE oa_id_valid = 1 AND cleaned_display_name IS NOT NULL
      AND length(trim(cleaned_display_name)) >= 3%6$s
),
-- Note 5: a fold claimed by two ranked institutions is discarded, not
-- arbitrated. Picking the better-ranked one would be a coin toss.
nm_own AS (
  SELECT nm_fold FROM nm GROUP BY nm_fold HAVING count(DISTINCT oa_key) = 1
),
inst_fold AS (
  SELECT n.nm_fold,
         max(n.oa_key)  AS oa_key,
         max(n.f_disp)  AS f_disp,
         max(n.f_clean) AS f_clean,
         max(n.f_shang) AS f_shang
  FROM nm n JOIN nm_own o ON n.nm_fold = o.nm_fold
  GROUP BY n.nm_fold
),
raws AS (
  SELECT DISTINCT university_raw
  FROM %3$s
  WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''
),
whole AS (
  SELECT r.university_raw, i.oa_key, i.f_disp, i.f_clean, i.f_shang,
         1 AS m_whole, 0 AS m_seg
  FROM raws r
  JOIN inst_fold i ON %7$s = i.nm_fold
),
seg AS (
  SELECT r.university_raw, i.oa_key,
         max(i.f_disp) AS f_disp, max(i.f_clean) AS f_clean,
         max(i.f_shang) AS f_shang,
         0 AS m_whole, 1 AS m_seg
  FROM raws r
  CROSS JOIN UNNEST(split(regexp_replace(regexp_replace(
               r.university_raw, '[/()]', '|'), ' - ', '|'), '|')) AS t(part)
  JOIN inst_fold i ON %8$s = i.nm_fold
  WHERE length(trim(t.part)) >= 3
  GROUP BY r.university_raw, i.oa_key
),
raw_oa AS (
  SELECT university_raw, oa_key,
         CAST(max(m_whole) AS INTEGER) AS by_whole,
         CAST(max(m_seg)   AS INTEGER) AS by_segment,
         CAST(max(f_disp)  AS INTEGER) AS by_display,
         CAST(max(f_clean) AS INTEGER) AS by_cleaned,
         CAST(max(f_shang) AS INTEGER) AS by_shanghai
  FROM (SELECT * FROM whole UNION ALL SELECT * FROM seg) u
  GROUP BY university_raw, oa_key
),
base AS (
  SELECT coalesce(rsid, %9$d)          AS rsid_key,
         university_raw,
         university_country,
         count(*)                      AS n,
         approx_set(user_id)           AS hll,
         max(university_name)          AS un_max,
         min(university_name)          AS un_min,
         max(ultimate_parent_rsid)     AS up_max,
         min(ultimate_parent_rsid)     AS up_min,
         max(ultimate_parent_school_name) AS upn_max
  FROM %3$s
  WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''
  GROUP BY coalesce(rsid, %9$d), university_raw, university_country
),
pairs AS (
  SELECT rsid_key, university_raw,
         sum(n)            AS n_rows,
         merge(hll)        AS hll,
         max(un_max)       AS university_name,
         min(un_min)       AS un_min,
         max(up_max)       AS ultimate_parent_rsid,
         min(up_min)       AS up_min,
         max(upn_max)      AS ultimate_parent_school_name
  FROM base
  GROUP BY rsid_key, university_raw
),
rsid_stats AS (
  SELECT rsid_key,
         sum(n_rows)                 AS rsid_n_rows,
         cardinality(merge(hll))     AS rsid_n_users_approx,
         count(*)                    AS rsid_n_raw,
         max(university_name)        AS un_max,
         min(un_min)                 AS un_min,
         max(ultimate_parent_rsid)   AS up_max,
         min(up_min)                 AS up_min
  FROM pairs
  GROUP BY rsid_key
),
-- Note 12: 'empty' is a value in this column, not an absence.
rsid_country AS (
  SELECT rsid_key,
         max_by(university_country, n_c) AS rsid_top_country,
         max(n_c)                        AS rsid_top_country_n,
         count(*)                        AS rsid_n_countries
  FROM (
    SELECT rsid_key, university_country, sum(n) AS n_c
    FROM base
    WHERE university_country IS NOT NULL
      AND university_country <> 'empty'
      AND trim(university_country) <> ''
    GROUP BY rsid_key, university_country
  ) c
  GROUP BY rsid_key
),
matched AS (
  SELECT m.oa_key,
         p.rsid_key,
         sum(p.n_rows)                  AS n_rows,
         cardinality(merge(p.hll))      AS n_users_approx,
         count(*)                       AS n_raw,
         CAST(max(m.by_whole)    AS INTEGER) AS by_whole,
         CAST(max(m.by_segment)  AS INTEGER) AS by_segment,
         CAST(max(m.by_display)  AS INTEGER) AS by_display,
         CAST(max(m.by_cleaned)  AS INTEGER) AS by_cleaned,
         CAST(max(m.by_shanghai) AS INTEGER) AS by_shanghai,
         max(p.university_name)         AS university_name,
         max(p.ultimate_parent_rsid)    AS ultimate_parent_rsid,
         max(p.ultimate_parent_school_name) AS ultimate_parent_school_name
  FROM pairs p
  JOIN raw_oa m ON p.university_raw = m.university_raw
  GROUP BY m.oa_key, p.rsid_key
)
SELECT i.oa_key,
       i.shanghai_rank,
       i.shanghai_name,
       i.display_name,
       i.cleaned_display_name,
       i.country_code,
       i.iso3c,
       i.oa_id_valid,
       i.parent_openalex_id,
       i.n_parents,
       i.root_openalex_id,
       i.n_roots,
       CASE WHEN mt.rsid_key = %9$d THEN NULL ELSE mt.rsid_key END AS rsid,
       mt.rsid_key,
       mt.university_name,
       mt.ultimate_parent_rsid,
       mt.ultimate_parent_school_name,
       mt.n_rows,
       mt.n_users_approx,
       mt.n_raw,
       mt.by_whole,
       mt.by_segment,
       mt.by_display,
       mt.by_cleaned,
       mt.by_shanghai,
       s.rsid_n_rows,
       s.rsid_n_users_approx,
       s.rsid_n_raw,
       c.rsid_top_country,
       c.rsid_top_country_n,
       c.rsid_n_countries,
       CAST(CASE WHEN s.un_min IS NOT DISTINCT FROM s.un_max
                 THEN 1 ELSE 0 END AS INTEGER) AS rsid_name_constant,
       CAST(CASE WHEN s.up_min IS NOT DISTINCT FROM s.up_max
                 THEN 1 ELSE 0 END AS INTEGER) AS rsid_parent_constant
FROM inst i
LEFT JOIN matched      mt ON i.oa_key    = mt.oa_key
LEFT JOIN rsid_stats   s  ON mt.rsid_key = s.rsid_key
LEFT JOIN rsid_country c  ON mt.rsid_key = c.rsid_key",
  athena_schema, inst_table, educ_table,
  tf("display_name"), tf("cleaned_display_name"), shanghai_branch,
  tf("r.university_raw"), tf("t.part"),
  rsid_sentinel)

unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')", select_sql, s3_path)

# STRING (not VARCHAR) and in the exact SELECT order: Hive DDL, and the
# Athena Parquet SerDe resolves columns by POSITION AND TYPE. rsid and
# ultimate_parent_rsid are int in Revelio; count(), sum() and
# cardinality() are bigint in Trino.
ddl_txt <- sprintf(
"CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (
  oa_key STRING,
  shanghai_rank INT,
  shanghai_name STRING,
  display_name STRING,
  cleaned_display_name STRING,
  country_code STRING,
  iso3c STRING,
  oa_id_valid INT,
  parent_openalex_id STRING,
  n_parents INT,
  root_openalex_id STRING,
  n_roots INT,
  rsid INT,
  rsid_key INT,
  university_name STRING,
  ultimate_parent_rsid INT,
  ultimate_parent_school_name STRING,
  n_rows BIGINT,
  n_users_approx BIGINT,
  n_raw BIGINT,
  by_whole INT,
  by_segment INT,
  by_display INT,
  by_cleaned INT,
  by_shanghai INT,
  rsid_n_rows BIGINT,
  rsid_n_users_approx BIGINT,
  rsid_n_raw BIGINT,
  rsid_top_country STRING,
  rsid_top_country_n BIGINT,
  rsid_n_countries BIGINT,
  rsid_name_constant INT,
  rsid_parent_constant INT
)
STORED AS PARQUET
LOCATION '%s'", athena_schema, athena_table, s3_path)

cat("=========== GENERATED SQL ===========\n")
cat(select_sql, "\n\n")
cat(ddl_txt, "\n\n")
cat("shanghai_Name arm (note 6):",
    ifelse(use_shanghai_arm, "ON", "OFF"), "\n\n")

####################################################################
### Step 2: check that the destination prefix is empty (note 16)
####################################################################

# UNLOAD fails if the destination prefix is not empty. Failing here,
# with a clear message, beats spending the scan of the education table
# only for Athena to refuse the write afterwards.
cat("=========== CURRENT CONTENTS OF THE S3 PREFIX ===========\n")
existing <- tryCatch(
  get_bucket(bucket = s3_bucket, prefix = paste0(s3_prefix, "/"),
             region = s3_region, max = 100),
  error = function(e) { cat("  [listing error]:", conditionMessage(e), "\n"); NULL })
if (is.null(existing) || length(existing) == 0) {
  cat("  prefix is empty\n\n")
} else {
  for (o in existing) cat("  ", o$Key, " (", o$Size, " bytes )\n")
  stop("Prefix ", s3_path, " is not empty. Athena UNLOAD requires an ",
       "empty destination: delete the objects above (and the table ",
       athena_schema, ".", athena_table, ", if it exists) before ",
       "regenerating. See note 16.")
}

####################################################################
### Step 3: preflight, then the UNLOAD
####################################################################

cat("=========== ATHENA ===========\n")
con <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name    = s3_region,
                 schema_name    = athena_schema)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

# Without the ranking table the join returns nothing and the crosswalk
# comes out as 0 rows with no warning at all.
inst <- dbGetQuery(con, sprintf("
  SELECT CAST(count(*) AS INTEGER)              AS n,
         CAST(count(DISTINCT oa_key) AS INTEGER)  AS n_keys,
         CAST(sum(CASE WHEN oa_id_valid = 0 THEN 1 ELSE 0 END) AS INTEGER)
           AS bad_key
  FROM %s.%s", athena_schema, inst_table))
cat("ranked institutions available :", format(inst$n, big.mark = ","), "\n")
cat("  unusable oa_key (4a note 6) :", inst$bad_key, "\n")
if (inst$n == 0) {
  stop("Table ", athena_schema, ".", inst_table, " is empty. ",
       "Run shanghai_ranking_oa_to_s3.R (4b) first.")
}
if (inst$n != exp_inst || inst$n_keys != exp_inst) {
  stop("The ranking table holds ", inst$n, " rows / ", inst$n_keys,
       " distinct oa_key, expected ", exp_inst, " of each. Coverage is ",
       "read against this number, so it cannot be allowed to drift.")
}

# The institution side is 1,000 rows: measuring it costs nothing and it
# is where notes 5, 6 and 7 are either true or stale.
fold_sql <- sprintf("
WITH inst AS (SELECT * FROM %1$s.%2$s),
nm AS (
  SELECT %3$s AS nm_fold, oa_key FROM inst
    WHERE oa_id_valid = 1 AND display_name IS NOT NULL
      AND length(trim(display_name)) >= 3
  UNION ALL
  SELECT %4$s, oa_key FROM inst
    WHERE oa_id_valid = 1 AND cleaned_display_name IS NOT NULL
      AND length(trim(cleaned_display_name)) >= 3%5$s
),
-- d is already DISTINCT on (nm_fold, oa_key), so a plain count(*)
-- per fold IS its number of owning institutions. Trino does not allow
-- DISTINCT inside a window function, so the ownership count is a
-- GROUP BY rather than an OVER.
d AS (SELECT DISTINCT nm_fold, oa_key FROM nm),
o AS (SELECT nm_fold, count(*) AS owners FROM d GROUP BY nm_fold)
SELECT CAST(count(DISTINCT d.nm_fold) AS INTEGER) AS folds,
       CAST(count(DISTINCT CASE WHEN o.owners = 1 THEN d.nm_fold END)
            AS INTEGER) AS own_folds,
       CAST(count(DISTINCT CASE WHEN o.owners > 1 THEN d.nm_fold END)
            AS INTEGER) AS shared_folds,
       CAST(count(DISTINCT CASE WHEN o.owners = 1 THEN d.oa_key END)
            AS INTEGER) AS matchable
FROM d JOIN o ON d.nm_fold = o.nm_fold",
  athena_schema, inst_table,
  tf("display_name"), tf("cleaned_display_name"), shanghai_branch)
fo <- dbGetQuery(con, fold_sql)
cat("\n--- the institution name side (notes 5, 6, 7) ---\n")
print(fo, row.names = FALSE)
if (!use_shanghai_arm &&
    (fo$folds != exp_folds || fo$shared_folds != exp_shared_folds ||
     fo$matchable != exp_matchable)) {
  warning("The name side moved: ", fo$folds, " folds / ", fo$shared_folds,
          " shared / ", fo$matchable, " matchable, expected ", exp_folds,
          " / ", exp_shared_folds, " / ", exp_matchable)
}

cat("\n  folds claimed by two institutions -- discarded, note 5:\n")
print(dbGetQuery(con, sprintf("
WITH inst AS (SELECT * FROM %1$s.%2$s),
nm AS (
  SELECT %3$s AS nm_fold, oa_key FROM inst
    WHERE oa_id_valid = 1 AND display_name IS NOT NULL
  UNION ALL
  SELECT %4$s, oa_key FROM inst
    WHERE oa_id_valid = 1 AND cleaned_display_name IS NOT NULL%5$s
)
SELECT nm_fold, array_join(array_agg(DISTINCT oa_key), ', ') AS oa_keys
FROM (SELECT DISTINCT nm_fold, oa_key FROM nm)
GROUP BY nm_fold HAVING count(DISTINCT oa_key) > 1 ORDER BY nm_fold",
  athena_schema, inst_table,
  tf("display_name"), tf("cleaned_display_name"), shanghai_branch)),
  right = FALSE, row.names = FALSE)

# Note 8. Names the at-risk set instead of guessing at it.
# chr(231) is c-cedilla, written as a code point rather than as a
# literal: the character would otherwise have to survive this file's
# encoding, sprintf, the driver and Athena intact, and a backslash-u
# regex escape is Java syntax that Trino's RE2J does not read.
ced <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM %s.%s
  WHERE oa_id_valid = 1 AND strpos(%s, chr(231)) > 0",
  athena_schema, inst_table, tf("display_name")))
cat("\n  ranked names whose fold still carries a cedilla (note 8):",
    ced$n, "\n")

# Sizing probe. ~1-2 columns, cheap next to the UNLOAD, and it turns
# the report's denominators into measured numbers instead of absent
# ones. It also says how big the UNNEST in `seg` will be before the
# expensive query commits to it.
cat("\n--- sizing probe over the education table ---\n")
t0 <- Sys.time()
pr <- dbGetQuery(con, sprintf("
  SELECT count(*) AS educ_rows,
         count(DISTINCT university_raw) AS educ_raws,
         sum(CASE WHEN university_raw IS NULL OR trim(university_raw) = ''
                  THEN 1 ELSE 0 END) AS blank_raw
  FROM %s", educ_table))
print(pr, row.names = FALSE)
cat("  probe took",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
if (!is.na(exp_educ_rows) && pr$educ_rows != exp_educ_rows) {
  warning("Education table moved: ", pr$educ_rows, " rows, expected ",
          exp_educ_rows)
}

# EXPLAIN is the preflight this folder has wanted a network version of.
# Athena plans the query -- binding every column, resolving every
# function, checking every type -- and reads NO data, so it costs
# nothing. A query that fails analysis is free; a query that runs and
# then fails validation has already been paid for. This catches what
# scratchpad/validate_sql_syntax.R cannot, because half of what is
# below is Trino-only (normalize/NFD, approx_set, merge, max_by) and
# would not bind in DuckDB at all.
cat("\n--- EXPLAIN preflight (free: plans, scans nothing) ---\n")
ex <- tryCatch({
  dbGetQuery(con, paste("EXPLAIN", select_sql))
  TRUE
}, error = function(e) {
  cat("[EXPLAIN FAILED]", conditionMessage(e), "\n")
  FALSE
})
if (!ex) {
  stop("The SELECT does not plan. Nothing was scanned and nothing was ",
       "charged. Fix the query above before re-running.")
}
cat("[OK] the query plans; the UNLOAD below is the first paid step\n")

cat("\nRunning UNLOAD (aggregates the education table)...\n")
t0 <- Sys.time()
dbExecute(con, unload_sql)
cat("  finished in",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n\n")

cat(ddl_txt, "\n")
dbExecute(con, ddl_txt)

####################################################################
### Step 4: validation through Athena
####################################################################

cat("\n=========== VALIDATION ===========\n")
v <- dbGetQuery(con, sprintf("
  SELECT CAST(count(*) AS INTEGER)                     AS n_rows,
         CAST(count(DISTINCT oa_key) AS INTEGER)       AS n_inst,
         CAST(count(DISTINCT (oa_key, rsid_key)) AS INTEGER) AS n_grain,
         CAST(count(DISTINCT rsid_key) AS INTEGER)     AS n_rsids,
         CAST(sum(CASE WHEN rsid_key IS NOT NULL THEN 1 ELSE 0 END)
              AS INTEGER)                              AS n_matched,
         CAST(count(DISTINCT CASE WHEN rsid_key IS NOT NULL
                                  THEN oa_key END) AS INTEGER) AS n_reached,
         CAST(count(DISTINCT CASE WHEN rsid IS NOT NULL
                                  THEN oa_key END) AS INTEGER) AS n_reached_real,
         CAST(sum(CASE WHEN rsid_key IS NOT NULL AND rsid IS NULL
                       THEN 1 ELSE 0 END) AS INTEGER)          AS n_sentinel,
         CAST(sum(CASE WHEN oa_key IS NULL THEN 1 ELSE 0 END)
              AS INTEGER)                              AS n_key_null,
         sum(CASE WHEN rsid_key IS NULL AND n_rows IS NOT NULL
                  THEN 1 ELSE 0 END)                  AS n_half_null,
         sum(CASE WHEN n_rows > rsid_n_rows THEN 1 ELSE 0 END)  AS bad_nest,
         sum(CASE WHEN rsid_top_country_n > rsid_n_rows
                  THEN 1 ELSE 0 END)                  AS bad_country,
         sum(CASE WHEN rsid_key IS NOT NULL AND by_whole = 0
                   AND by_segment = 0 THEN 1 ELSE 0 END) AS no_arm,
         sum(CASE WHEN rsid_key IS NOT NULL AND by_display = 0
                   AND by_cleaned = 0 AND by_shanghai = 0
                  THEN 1 ELSE 0 END)                  AS no_name_source,
         sum(CASE WHEN n_users_approx > n_rows THEN 1 ELSE 0 END) AS hll_over,
         sum(CASE WHEN rsid_name_constant = 0 THEN 1 ELSE 0 END) AS name_varies,
         sum(CASE WHEN rsid_top_country = 'empty' THEN 1 ELSE 0 END) AS ctry_empty
  FROM %s.%s", athena_schema, athena_table))
print(v, row.names = FALSE)

if (v$n_rows == 0) stop("The crosswalk is empty.")
if (v$n_grain != v$n_rows) {
  stop("Grain violated: ", v$n_rows, " rows but ", v$n_grain,
       " distinct (oa_key, rsid_key).")
}
# The LEFT JOIN is the whole point of the shape: it may not lose an
# institution and it may not invent one.
if (v$n_inst != exp_inst) {
  stop("The output holds ", v$n_inst, " institutions, expected ", exp_inst,
       " -- the LEFT JOIN lost or duplicated one.")
}
if (v$n_key_null != 0) stop("NULL oa_key in the output.")
if (v$n_half_null != 0) {
  stop(v$n_half_null, " rows carry evidence with no rsid_key -- a ",
       "half-populated unmatched row.")
}
if (v$bad_nest != 0) {
  stop(v$bad_nest, " rows where n_rows > rsid_n_rows. Per (institution, ",
       "rsid) that cannot happen (note 14): the aggregation levels ",
       "disagree.")
}
if (v$bad_country != 0) {
  stop(v$bad_country, " rows where the modal country covers more rows ",
       "than the rsid has.")
}
if (v$no_arm != 0) {
  stop(v$no_arm, " matched rows with neither by_whole nor by_segment set.")
}
if (v$no_name_source != 0) {
  stop(v$no_name_source, " matched rows with no name source set.")
}
# Note 12: this is the bug that is NOT copied from script 6.
if (v$ctry_empty != 0) {
  stop(v$ctry_empty, " rows whose rsid_top_country is the literal string ",
       "'empty' -- the note 12 filter is not doing its job.")
}
# Every institution must come from the ranking table. If the Parquet
# SerDe had resolved columns at the wrong position this is what breaks.
orph <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n
  FROM (SELECT DISTINCT oa_key FROM %s.%s) x
  LEFT JOIN %s.%s r ON x.oa_key = r.oa_key
  WHERE r.oa_key IS NULL",
  athena_schema, athena_table, athena_schema, inst_table))
if (orph$n != 0) {
  stop(orph$n, " oa_key values are absent from ", inst_table,
       " -- columns out of position?")
}
# Note 11: HyperLogLog can overshoot. A warning with tolerance, never a
# stop, and never silence either.
if (v$hll_over != 0) {
  warning(v$hll_over, " rows where n_users_approx exceeds n_rows. ",
          "Expected on a few: note 11.")
}
if (!is.na(exp_rows)    && v$n_rows   != exp_rows)  warning("rows: ", v$n_rows)
if (!is.na(exp_rsids)   && v$n_rsids  != exp_rsids) warning("rsids: ", v$n_rsids)
if (!is.na(exp_reached) && v$n_reached != exp_reached) {
  warning("institutions reached: ", v$n_reached, ", expected ", exp_reached)
}
cat("\n[OK] all structural validations passed\n\n")

####################################################################
### Step 5: reports -- this is how the crosswalk gets judged
####################################################################

cat("=========== 1. COVERAGE ===========\n")
cat("  ranked institutions           :", exp_inst, "\n")
cat("  of which matchable at all     :", fo$matchable,
    "(note 5: the rest have no unshared name)\n")
cat("  REACHED by a real rsid        :", v$n_reached_real,
    sprintf("(%.1f%% of matchable)
", 100 * v$n_reached_real / fo$matchable))
cat("  reached counting the sentinel :", v$n_reached,
    "-- do NOT quote this one, see below
")
cat("  distinct rsids                :", format(v$n_rsids, big.mark = ","), "\n")
cat("  pair rows                     :", format(v$n_matched, big.mark = ","), "\n")
cat("
  Of those pair rows,", v$n_sentinel, "carry the NULL-rsid sentinel
")
cat("  (note 9). Those are education rows with NO school key, pooled
")
cat("  into one pseudo-school, so they are not school pairs at all and
")
cat("  their match_share is meaningless by construction: the pool is
")
cat("  ~169M rows, which pins every one of them in the bottom band.
")
cat("  ", v$n_reached - v$n_reached_real,
    "institution(s) are reached ONLY that way, so they are not
")
cat("  really reached. Quote n_reached_real.", "
")
cat("\n  For contrast, both cohort-only and with more arms than this:\n")
cat("    shanghai_rsid_name_map        895 rsids, 828 institutions\n")
cat("    shanghai_raw_crosswalk (16b) 1202 rsids, 970 institutions\n")

cat("\n=========== 2. THE INSTITUTIONS NOBODY REACHED ===========\n")
cat("This list is the acceptance test. A small non-English university\n")
cat("is plausible; Harvard would mean the query is wrong.\n\n")
unre <- dbGetQuery(con, sprintf("
  SELECT shanghai_rank, oa_key, shanghai_name, display_name, country_code,
         oa_id_valid
  FROM %s.%s WHERE rsid_key IS NULL ORDER BY shanghai_rank, shanghai_name",
  athena_schema, athena_table))
cat("unreached:", nrow(unre), "\n")
print(unre, right = FALSE, row.names = FALSE)

cat("\n=========== 3. THE BIGGEST SCHOOLS, AND WHO THEY MAP TO ===========\n")
cat("Must read USP -> USP and Harvard -> Harvard.\n\n")
print(dbGetQuery(con, sprintf("
  SELECT display_name, shanghai_rank, university_name, rsid, n_rows,
         round(CAST(n_rows AS double) / rsid_n_rows, 3) AS match_share
  FROM (SELECT *, row_number() OVER (PARTITION BY oa_key
                                     ORDER BY n_rows DESC) AS rk
        FROM %s.%s WHERE rsid_key IS NOT NULL) t
  WHERE rk = 1 ORDER BY n_rows DESC LIMIT 25",
  athena_schema, athena_table)), right = FALSE, row.names = FALSE)

cat("\n=========== 4. match_share BANDS (note 2) ===========\n")
cat("The bottom band is the Harvard-typed-a-Brazilian-name class.\n")
cat("It is STORED, not filtered. Apply a floor before consuming.\n\n")
print(dbGetQuery(con, sprintf("
  SELECT CASE WHEN ms >= 0.5   THEN '1. >= 0.5'
              WHEN ms >= 0.1   THEN '2. 0.1 - 0.5'
              WHEN ms >= 0.01  THEN '3. 0.01 - 0.1'
              WHEN ms >= 0.001 THEN '4. 0.001 - 0.01'
              ELSE                  '5. < 0.001' END AS band,
         count(*) AS pairs, count(DISTINCT oa_key) AS institutions,
         sum(n_rows) AS education_rows
  FROM (SELECT oa_key, n_rows,
               CAST(n_rows AS double) / nullif(rsid_n_rows, 0) AS ms
        FROM %s.%s WHERE rsid_key IS NOT NULL) t
  GROUP BY 1 ORDER BY 1", athena_schema, athena_table)), row.names = FALSE)

cat("\n=========== 5. THE SEGMENT ARM ALONE (note 4) ===========\n")
cat("Where a false positive would show. Read these.\n\n")
print(dbGetQuery(con, sprintf("
  SELECT display_name, university_name, rsid, n_rows,
         round(CAST(n_rows AS double) / rsid_n_rows, 3) AS match_share
  FROM %s.%s
  WHERE by_segment = 1 AND by_whole = 0
  ORDER BY n_rows DESC LIMIT 20", athena_schema, athena_table)),
  right = FALSE, row.names = FALSE)

cat("\n=========== 6. WHAT EACH NAME COLUMN EARNED (notes 6, 7) ===========\n")
print(dbGetQuery(con, sprintf("
  SELECT sum(CASE WHEN by_display  = 1 THEN 1 ELSE 0 END) AS by_display,
         sum(CASE WHEN by_cleaned  = 1 THEN 1 ELSE 0 END) AS by_cleaned,
         sum(CASE WHEN by_shanghai = 1 THEN 1 ELSE 0 END) AS by_shanghai,
         sum(CASE WHEN by_cleaned = 1 AND by_display = 0
                  THEN 1 ELSE 0 END) AS cleaned_only,
         count(DISTINCT CASE WHEN by_cleaned = 1 AND by_display = 0
                             THEN oa_key END) AS cleaned_only_inst
  FROM %s.%s WHERE rsid_key IS NOT NULL", athena_schema, athena_table)),
  row.names = FALSE)

####################################################################
### Step 6: the local copy
####################################################################

cat("\n=========== LOCAL COPY ===========\n")
if (!arrow::arrow_with_s3()) {
  cat("[skip] this arrow build has no S3 support; the Athena table and\n",
      "       the S3 objects are complete. Download them separately.\n", sep = "")
} else {
  ds <- arrow::open_dataset(s3_path, format = "parquet")
  # write_parquet does not take a Dataset: materialize a Table first.
  arrow::write_parquet(arrow::Scanner$create(ds)$ToTable(), out_path,
                       compression = "snappy")
  local_n <- nrow(arrow::open_dataset(out_path, format = "parquet"))
  cat("rows in the local parquet     :", format(local_n, big.mark = ","), "\n")
  if (local_n != v$n_rows) {
    stop("Local parquet has ", local_n, " rows, Athena reported ", v$n_rows)
  }
}

cat("\n=========== SUMMARY ===========\n")
cat("  Athena table  :", paste0(athena_schema, ".", athena_table), "\n")
cat("  S3 LOCATION   :", s3_path, "\n")
if (file.exists(out_path)) {
  cat("  local parquet :", out_path,
      sprintf("(%.0f KB)\n", file.info(out_path)$size / 2^10))
}
cat("  grain         : (oa_key, rsid_key), one row per institution-school pair\n")
cat("  rows          :", format(v$n_rows, big.mark = ","), "\n")
cat("  institutions  :", v$n_inst, "of which", v$n_reached, "reached\n")
cat("  rsids         :", format(v$n_rsids, big.mark = ","), "\n")
cat("  shanghai arm  :", ifelse(use_shanghai_arm, "ON", "OFF (note 6)"), "\n")
cat("\n  Pin these into exp_rows / exp_rsids / exp_reached / exp_educ_rows.\n")
