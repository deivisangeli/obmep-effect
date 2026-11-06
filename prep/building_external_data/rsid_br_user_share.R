####################################################################
###
### Per-rsid share of users located in Brazil -> S3 + Athena
###
### Publishes, for every Revelio school key (rsid) that the OpenAlex
### Brazilian institution list can reach through the free-text
### university_raw column, the share of the rsid's OWN USERS whose
### profile country is Brazil.
###
### Grain: one row per (rsid, university_raw) MATCHED pair, asserted
### unique. Matched means the raw string satisfies criterion C_norm as
### revelio_br_cohort_user_ids.R defines it -- the matcher CTEs here
### (inst_fold / inst_exact / raws / seg / raw_cls) are copied from
### that script unchanged, so m_exact is criterion C and m_norm is
### criterion C_norm and neither means anything new.
###
### The table exists to GATE an rsid-propagation criterion, which is
### the thing that failed once already:
###
###   G1  the rsid has at least one university_raw matching C or C_norm
###       (has_exact / has_norm)
###   G2  br_share_known > 0.5
###
### revelio_br_cohort_user_ids_alt.R consumes it. Nothing else does,
### and the current cohort is untouched by it.
###
### Depends on:
###   prep/building_external_data/openalex_institutions_br_to_s3.R
###   (table revelio_database.openalex_institutions_br)
###
### Athena read/UNLOAD pattern reused from:
###   prep/building_external_data/rsid_openalex_br_crosswalk.R
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. That is a deliberate exception: reading from Athena
###    and writing to S3 is the whole point. It is a local prep/ script
###    and must not be sent to the offline SEDAP environment.
### 2. *** THIS IS NOT THE BRAZIL SHARE THE README FORBIDS. *** The
###    README section "Do not filter on the Brazil share instead"
###    rejects
###      rsid_n_rows_br / rsid_n_rows
###    the share of an rsid's EDUCATION ROWS whose university_country
###    says Brazil. That one is near zero for institutions beyond any
###    doubt Brazilian -- Fundacao Getulio Vargas 0.0011, UFRGS 0.0006,
###    Centro Universitario Una 0.0003 -- precisely because a NULL or
###    non-Brazil university_country is the gap criterion C exists to
###    close. Filtering on it would discard the rows the criterion is
###    meant to recover.
###
###    What this script computes is a different quantity: the share of
###    the rsid's DISTINCT USERS whose academic_individual_user
###    .user_country is Brazil. It is a property of the people, not of
###    the education row's own country field, and it is high for USP
###    and FGV and low for Harvard and Phoenix. Do not collapse the two
###    in a later edit; they are not the same number and the README
###    warning does not transfer.
### 3. Two denominators are stored and only one is used:
###      br_share_known = rsid_n_users_br / rsid_n_users_known
###      br_share_all   = rsid_n_users_br / rsid_n_users
###    The KNOWN one is the cut, on the reasoning that dividing by
###    every user would sink an unmistakably Brazilian rsid purely on
###    coverage -- the same dilution mechanism that makes the
###    education-row share unusable (note 2).
###
###    MEASURED 2026-09-04: that reasoning is sound but the precaution
###    turns out to be UNNECESSARY here. user_country is populated on
###    99.79% of the 63,364,054 users under the matched rsids, no rsid
###    has it on under 90% of its users, and **0 of 975 rsids change
###    their keep/reject decision** if br_share_all is used instead.
###    So the denominator choice is not load-bearing on this snapshot.
###    Both still travel in the table: the coverage could degrade on a
###    later Revelio refresh, and then the choice would start to
###    matter. Do not simplify one of them away.
### 4. LEFT JOIN onto academic_individual_user, never inner (script
###    12 note 3). A user with no row there, or a NULL user_country,
###    must land in rsid_n_users and OUTSIDE rsid_n_users_known, not
###    vanish: dropping them would inflate the share and let a foreign
###    rsid through the gate.
### 5. "Known" means NOT NULL and not in ('', 'empty'). The 'empty'
###    sentinel is real in this schema -- country, region, state and
###    metro_area on academic_individual_position say 'empty' rather
###    than NULL (README trap 3 of the role/location section) -- so it
###    is excluded here defensively. Step 5 PRINTS the user_country
###    value distribution over the matched rsids, so the question of
###    which sentinels actually occur is answered by the run and not by
###    this comment.
###
###    MEASURED 2026-09-04: the modal known country of all 975 matched
###    rsids is an ordinary country name (Brazil 675, United States 79,
###    United Kingdom 21, ...) -- no third sentinel is masquerading as
###    a country, and no rsid came out with a NULL share, so the
###    ('', 'empty') guard fires on nothing in this snapshot. Keep it
###    anyway; it costs nothing and the position table proves the
###    convention exists in this schema.
### 6. Every user count is count(DISTINCT user_id), which makes a
###    fan-out on the user join harmless instead of silent. The
###    validation still asserts
###      rsid_n_users_br <= rsid_n_users_known <= rsid_n_users
###    because that is what breaks if the join ever fans out.
### 7. br_share_known is NULL when rsid_n_users_known = 0, guarded so
###    Trino does not raise "Division by zero". A NULL share fails
###    `> 0.5`, so an rsid whose users have no country at all is
###    REJECTED. That is the conservative direction and it is
###    deliberate.
### 8. rsid is `int` in Revelio, verified with DESCRIBE (script 6
###    note 8) -- not bigint. count() and sum() return bigint in Trino,
###    hence the BIGINT columns. A type mismatch between the parquet
###    and the DDL only surfaces on READ, never on write (README traps
###    5 and 6).
### 9. The education table is read THREE times -- once by `raws` (one
###    column), once by `pairs` and once by `rsid_ctry` -- and
###    academic_individual_user once, inside rsid_ctry. Trino INLINES a
###    CTE rather than materializing it, so each reference is its own
###    scan and there is no way to share one.
###
###    An earlier draft had pairs and rsid_ctry read a shared `base`
###    CTE aggregated to (rsid, university_raw, user_id,
###    user_country). DO NOT REINTRODUCE IT. Inlining would have
###    computed that hundreds-of-millions-group aggregation twice and
###    read the 191 GB user table twice, for no saving in scanned
###    bytes, and a shuffle that size is what returns "Query exhausted
###    resources at this scale factor" after the scan is already paid
###    for.
###
###    Sizes measured off S3: academic_individual_user_education is
###    89.83 GB over 16 columns, academic_individual_user 191.13 GB
###    over 23. Athena bills projected columns only, so those are
###    ceilings. Script 6, reading six education columns with a
###    doubly-referenced CTE, measured 58.50 GB.
###
###    MEASURED 2026-09-04: 106.55 GB scanned (~$0.53), 44.1 s of
###    engine time. That is roughly twice script 6 and about 1.7x what
###    was predicted before the run -- the education id and raw-string
###    columns are a larger share of that table than the estimate
###    assumed. Budget $0.53, not $0.30, for a rebuild.
###
###    Everything in Step 5 reads the finished small table, not the
###    source, so re-reporting is free.
### 10. Deliberately NOT built on revelio_database.rsid_openalex_br
###    (script 6). That table carries the EXACT arm only, never
###    C_norm; its statistics are education-row based, not user based;
###    and it is a snapshot from 2026-08-24. Re-deriving the match here
###    is what keeps m_exact / m_norm identical to the criteria the
###    cohort actually uses. Do not "simplify" this script away into a
###    join against script 6.
### 11. has_exact / has_norm are computed with a window over `pairs`
###    rather than by a second CTE grouping `pairs` by rsid. That is
###    not style: `pairs` is inlined, so grouping it again would be
###    another scan of the education table (note 9). The window runs
###    inside the existing plan and costs nothing.
###
####################################################################

rm(list = ls()); gc()

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

out_dir  <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
out_path <- file.path(out_dir, "rsid_br_user_share.parquet")
rej_path <- file.path(out_dir, "rsid_br_user_share_rejected.csv")

# The gate. Deliberately NOT stored as a column in the table: the
# shares travel instead, so the threshold lives in exactly one place
# per script. revelio_br_cohort_user_ids_alt.R carries its own copy and
# the two must agree.
br_share_min <- 0.5

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
s3_prefix <- "exports/rsid_br_user_share"
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table  <- "rsid_br_user_share"

# Institutions table registered by openalex_institutions_br_to_s3.R.
inst_table <- "openalex_institutions_br"
educ_table <- "academic_individual_user_education"
user_table <- "academic_individual_user"

# Measured 2026-09-04 on the first run: 24,276 matched pairs over 975
# rsids. A Revelio refresh or a new OpenAlex snapshot legitimately
# moves these, so a mismatch warns rather than aborts.
#
# The exact arm alone reaches 725 rsids -- EXACTLY the figure script 6
# measured for the same criterion on 2026-08-24, by a different query
# shape. That agreement is the strongest evidence that criteria C and
# C_norm mean here what they mean in the cohort, and it is worth
# re-reading on any future run: C_norm reaches 975, i.e. 250 rsids
# more than C.
exp_rows  <- 24276
exp_rsids <- 975

# RAthena talks to Athena through boto3/reticulate. On this machine the
# `python` on PATH is the WindowsApps shim, which reticulate ignores on
# purpose -- so py_discover_config() finds nothing and RAthena concludes
# boto3 is missing, when in fact a real Python with boto3 and numpy is
# already installed. Pointing reticulate at the real interpreter fixes
# it without installing anything.
#
# Only set when RETICULATE_PYTHON is empty: an interactive session that
# already resolves Python correctly is never overridden.
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
#  - inst_fold / inst_exact / raws / seg / raw_cls are COPIED from
#    revelio_br_cohort_user_ids.R with one addition: raw_cls also
#    returns oa_matched_name, the OpenAlex name the string matched, for
#    the rejected-pairs report. The whole-string arm's name wins over
#    the segment arm's, matching the precedence of the flags
#    themselves. inst_fold is unique on nm_fold by its own GROUP BY, so
#    joining it back cannot multiply rows.
#  - pairs and rsid_ctry each read the education table DIRECTLY. An
#    earlier draft had them both read a shared `base` CTE aggregated to
#    (rsid, university_raw, user_id, user_country) -- roughly one group
#    per education row. That was wrong twice over: Trino INLINES a CTE
#    instead of materializing it, so the giant shuffle would have been
#    computed TWICE and the 191 GB user table read twice, and a
#    hundreds-of-millions-group aggregation is the shape that returns
#    "Query exhausted resources at this scale factor" AFTER the scan is
#    already paid for. Two aggregations at their own natural grain cost
#    the same in scanned bytes and ask far less of the engine.
#  - pairs restricts to matched strings and is the published grain.
#    raw_cls is unique on university_raw, so the join is at most 1:1
#    and cannot multiply rows -- the same guarantee the cohort scripts
#    rely on. It needs no rsid filter beyond IS NOT NULL: the join to
#    raw_cls already drops NULL and blank university_raw.
#  - rsid_ctry covers ALL rsids rather than only matched ones.
#    Restricting it would mean joining `pairs`, i.e. another scan; the
#    INNER JOIN in the final SELECT does the restriction for free. It
#    is the only place the user table is touched, and the join is LEFT
#    (note 4).
#  - rsid_users then aggregates rsid_ctry, which is small. Because
#    user_country is functionally determined by user_id, a user falls
#    in exactly one (rsid, user_country) group, so summing n_users
#    across the groups of an rsid is the same as counting its distinct
#    users. That identity is what lets one aggregation serve both the
#    per-country profile and the per-rsid totals.
#  - rsid_top_country is the modal KNOWN country. The sentinel key 0 in
#    the max_by() sorts every unknown group below any known one, since
#    n_users >= 1 always. If an rsid has no known country at all, every
#    key is 0 and max_by returns an arbitrary row -- which is still
#    interpretable, because rsid_top_country_n comes out NULL in
#    exactly that case.
#  - the shares are guarded against a zero denominator (note 7) and
#    cast to double, matching the DOUBLE columns in the DDL.
select_sql <- sprintf("
WITH inst_fold AS (
  SELECT lower(regexp_replace(normalize(cleaned_display_name, NFD), '\\p{M}', '')) AS nm_fold,
         max(CASE WHEN type = 'education' THEN 1 ELSE 0 END) AS is_edu,
         min(cleaned_display_name) AS oa_name
  FROM %s
  GROUP BY lower(regexp_replace(normalize(cleaned_display_name, NFD), '\\p{M}', ''))
),
inst_exact AS (
  SELECT DISTINCT lower(cleaned_display_name) AS nm_exact FROM %s
),
raws AS (
  SELECT DISTINCT university_raw
  FROM %s
  WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''
),
seg AS (
  SELECT r.university_raw, 1 AS seg_edu, min(i.oa_name) AS seg_name
  FROM raws r
  CROSS JOIN UNNEST(split(regexp_replace(regexp_replace(
               r.university_raw, '[/()]', '|'), ' - ', '|'), '|')) AS t(part)
  JOIN inst_fold i
    ON lower(regexp_replace(normalize(trim(t.part), NFD), '\\p{M}', '')) = i.nm_fold
  WHERE length(trim(t.part)) >= 3 AND i.is_edu = 1
  GROUP BY r.university_raw
),
raw_cls AS (
  SELECT r.university_raw,
         CASE WHEN lower(trim(r.university_raw)) IN (SELECT nm_exact FROM inst_exact)
              THEN 1 ELSE 0 END AS m_exact,
         CASE WHEN lower(regexp_replace(normalize(trim(r.university_raw), NFD), '\\p{M}', ''))
                   IN (SELECT nm_fold FROM inst_fold)
               OR s.seg_edu = 1
              THEN 1 ELSE 0 END AS m_norm,
         coalesce(w.oa_name, s.seg_name) AS oa_matched_name
  FROM raws r
  LEFT JOIN seg s ON r.university_raw = s.university_raw
  LEFT JOIN inst_fold w
    ON lower(regexp_replace(normalize(trim(r.university_raw), NFD), '\\p{M}', '')) = w.nm_fold
),
pairs AS (
  SELECT e.rsid,
         e.university_raw,
         max(c.m_exact)            AS m_exact,
         max(c.m_norm)             AS m_norm,
         max(c.oa_matched_name)    AS oa_matched_name,
         count(*)                  AS n_rows,
         count(DISTINCT e.user_id) AS n_users
  FROM %s e
  JOIN raw_cls c ON e.university_raw = c.university_raw
  WHERE e.rsid IS NOT NULL AND c.m_norm = 1
  GROUP BY e.rsid, e.university_raw
),
rsid_ctry AS (
  SELECT e.rsid,
         u.user_country,
         count(DISTINCT e.user_id) AS n_users,
         count(*)                  AS n_rows,
         max(e.university_name)    AS university_name
  FROM %s e
  LEFT JOIN %s u ON e.user_id = u.user_id
  WHERE e.rsid IS NOT NULL AND e.university_raw IS NOT NULL
  GROUP BY e.rsid, u.user_country
),
rsid_users AS (
  SELECT rsid,
         max(university_name) AS university_name,
         sum(n_users)         AS rsid_n_users,
         sum(n_rows)          AS rsid_n_rows,
         sum(CASE WHEN user_country IS NOT NULL
                   AND user_country NOT IN ('', 'empty')
                  THEN n_users ELSE 0 END) AS rsid_n_users_known,
         sum(CASE WHEN user_country = 'Brazil'
                  THEN n_users ELSE 0 END) AS rsid_n_users_br,
         max_by(user_country,
                CASE WHEN user_country IS NOT NULL
                      AND user_country NOT IN ('', 'empty')
                     THEN n_users ELSE 0 END) AS rsid_top_country,
         max(CASE WHEN user_country IS NOT NULL
                   AND user_country NOT IN ('', 'empty')
                  THEN n_users END) AS rsid_top_country_n
  FROM rsid_ctry
  GROUP BY rsid
)
SELECT p.rsid,
       p.university_raw,
       r.university_name,
       p.oa_matched_name,
       p.m_exact,
       p.m_norm,
       max(p.m_exact) OVER (PARTITION BY p.rsid) AS has_exact,
       max(p.m_norm)  OVER (PARTITION BY p.rsid) AS has_norm,
       p.n_rows,
       p.n_users,
       r.rsid_n_rows,
       r.rsid_n_users,
       r.rsid_n_users_known,
       r.rsid_n_users_br,
       r.rsid_top_country,
       r.rsid_top_country_n,
       CASE WHEN r.rsid_n_users_known > 0
            THEN CAST(r.rsid_n_users_br AS double) / r.rsid_n_users_known
            END AS br_share_known,
       CASE WHEN r.rsid_n_users > 0
            THEN CAST(r.rsid_n_users_br AS double) / r.rsid_n_users
            END AS br_share_all
FROM pairs p
INNER JOIN rsid_users r
  ON p.rsid = r.rsid",
  inst_table, inst_table, educ_table, educ_table, educ_table, user_table)

unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')",
  select_sql, s3_path)

# STRING (not VARCHAR) and in the exact SELECT order: Hive DDL, and the
# Athena Parquet SerDe resolves columns by POSITION and TYPE. rsid is
# int in Revelio; count() and sum() are bigint in Trino (note 8).
ddl_txt <- sprintf(
"CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (
  rsid INT,
  university_raw STRING,
  university_name STRING,
  oa_matched_name STRING,
  m_exact INT,
  m_norm INT,
  has_exact INT,
  has_norm INT,
  n_rows BIGINT,
  n_users BIGINT,
  rsid_n_rows BIGINT,
  rsid_n_users BIGINT,
  rsid_n_users_known BIGINT,
  rsid_n_users_br BIGINT,
  rsid_top_country STRING,
  rsid_top_country_n BIGINT,
  br_share_known DOUBLE,
  br_share_all DOUBLE
)
STORED AS PARQUET
LOCATION '%s'", athena_schema, athena_table, s3_path)

cat("=========== GENERATED SQL ===========\n")
cat(unload_sql, "\n\n")
cat(ddl_txt, "\n\n")

####################################################################
### Step 2: check that the destination prefix is empty
####################################################################

# UNLOAD fails if the destination prefix is not empty. Failing here,
# with a clear message, beats spending the scan of the education and
# user tables only for Athena to refuse the write afterwards.
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
       athena_schema, ".", athena_table, ", if it exists) before regenerating.")
}

####################################################################
### Step 3: run the UNLOAD and register the table
####################################################################

cat("=========== ATHENA ===========\n")
con <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name    = s3_region,
                 schema_name    = athena_schema)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

# Without the institutions table nothing matches and the gate would
# reject every rsid with no warning at all.
inst_n <- dbGetQuery(con, sprintf("SELECT count(*) AS n FROM %s.%s",
                                  athena_schema, inst_table))
cat("BR institutions available     :", format(inst_n$n, big.mark = ","), "\n")
if (inst_n$n == 0) {
  stop("Table ", athena_schema, ".", inst_table, " is empty. ",
       "Run openalex_institutions_br_to_s3.R first.")
}

# DESCRIBE is metadata only and costs nothing. It is here because the
# whole gate rests on one column of a table no cohort script has ever
# read, and because the offline validator's stub for it has to be kept
# in sync with what this prints (validate_sql_syntax.R note 1).
cat("\n--- DESCRIBE", paste0(athena_schema, ".", user_table), "---\n")
u_desc <- dbGetQuery(con, sprintf("DESCRIBE %s.%s", athena_schema, user_table))
print(u_desc, right = FALSE)
if (!any(grepl("user_country", as.character(u_desc[[1]])))) {
  stop("Column user_country is absent from ", athena_schema, ".", user_table,
       " -- the gate has no location source and this script cannot run.")
}

cat("\nRunning UNLOAD (aggregates the education and user tables)...\n")
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
  SELECT count(*) AS n_rows,
         count(DISTINCT rsid) AS n_rsids,
         count(DISTINCT (rsid, university_raw)) AS n_grain,
         sum(CASE WHEN rsid IS NULL OR university_raw IS NULL
                  THEN 1 ELSE 0 END) AS n_key_null,
         sum(CASE WHEN m_norm <> 1 THEN 1 ELSE 0 END) AS bad_unmatched,
         sum(CASE WHEN m_exact = 1 AND m_norm = 0 THEN 1 ELSE 0 END) AS bad_not_superset,
         sum(CASE WHEN m_exact = 1 AND has_exact = 0 THEN 1 ELSE 0 END) AS bad_arm_exact,
         sum(CASE WHEN m_norm  = 1 AND has_norm  = 0 THEN 1 ELSE 0 END) AS bad_arm_norm,
         sum(CASE WHEN rsid_n_users_br > rsid_n_users_known THEN 1 ELSE 0 END) AS bad_br,
         sum(CASE WHEN rsid_n_users_known > rsid_n_users THEN 1 ELSE 0 END) AS bad_known,
         sum(CASE WHEN n_users > rsid_n_users THEN 1 ELSE 0 END) AS bad_nest,
         sum(CASE WHEN n_rows > rsid_n_rows THEN 1 ELSE 0 END) AS bad_nest_rows,
         sum(CASE WHEN rsid_top_country_n > rsid_n_users THEN 1 ELSE 0 END) AS bad_top,
         sum(CASE WHEN br_share_known IS NULL THEN 1 ELSE 0 END) AS n_share_null
  FROM %s.%s", athena_schema, athena_table))
print(v)

if (v$n_rows == 0) {
  stop("The table is empty -- the gate would reject every rsid.")
}
if (v$n_grain != v$n_rows) {
  stop("Grain violated: ", v$n_rows, " rows but ", v$n_grain,
       " distinct (rsid, university_raw).")
}
if (v$n_key_null != 0) stop("NULL in a key column.")
# Only matched strings are published, by the WHERE inside `pairs`.
if (v$bad_unmatched != 0) {
  stop(v$bad_unmatched, " rows carry m_norm <> 1 -- the restriction in ",
       "`pairs` is not doing what it claims.")
}
# C_norm is a strict superset of C at the STRING level: folding accents
# and accepting segment matches can only add strings, never remove one.
if (v$bad_not_superset != 0) {
  stop(v$bad_not_superset, " rows have m_exact = 1 but m_norm = 0. ",
       "C_norm must be a superset of C.")
}
# The window that computes has_exact / has_norm must dominate the
# per-pair flags it aggregates. If it does not, the PARTITION BY is
# wrong and the gate would be applied to the wrong arm.
if (v$bad_arm_exact != 0 || v$bad_arm_norm != 0) {
  stop("has_* does not dominate m_*: ", v$bad_arm_exact, " exact and ",
       v$bad_arm_norm, " norm rows disagree.")
}
# The three user counts come out of one aggregate, so a violation here
# means the LEFT JOIN onto the user table fanned out (note 6).
if (v$bad_br != 0 || v$bad_known != 0) {
  stop("User counts disagree: ", v$bad_br, " rows with ",
       "rsid_n_users_br > rsid_n_users_known, ", v$bad_known,
       " with rsid_n_users_known > rsid_n_users. The join to ",
       user_table, " probably fanned out.")
}
if (v$bad_nest != 0 || v$bad_nest_rows != 0) {
  stop("Aggregation levels disagree: ", v$bad_nest, " pairs with ",
       "n_users > rsid_n_users, ", v$bad_nest_rows,
       " with n_rows > rsid_n_rows.")
}
if (v$bad_top != 0) {
  stop(v$bad_top, " rows where the modal country covers more users ",
       "than the rsid has.")
}

# Every pair flagged m_exact must satisfy criterion C against the
# STORED strings. Checked here rather than assumed, so it verifies the
# match instead of restating it.
sup <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n
  FROM %s.%s t
  WHERE t.m_exact = 1
    AND lower(trim(t.university_raw)) NOT IN (
          SELECT lower(cleaned_display_name) FROM %s.%s)",
  athena_schema, athena_table, athena_schema, inst_table))
if (sup$n != 0) {
  stop(sup$n, " rows are flagged m_exact = 1 but their university_raw does ",
       "not equal any lower(cleaned_display_name) -- the match is not the ",
       "criterion it claims to be.")
}

if (!is.na(exp_rows) && v$n_rows != exp_rows) {
  warning("Expected ", exp_rows, " rows, got ", v$n_rows)
}
if (!is.na(exp_rsids) && v$n_rsids != exp_rsids) {
  warning("Expected ", exp_rsids, " rsids, got ", v$n_rsids)
}
if (is.na(exp_rows) || is.na(exp_rsids)) {
  cat("\n[!] exp_rows / exp_rsids are NA -- the drift check is DISABLED.\n",
      "    Fill in the measured values above before relying on this table.\n",
      sep = "")
}

cat("\nrows (rsid x university_raw)  :", format(v$n_rows, big.mark = ","), "\n")
cat("  distinct rsid               :", format(v$n_rsids, big.mark = ","), "\n")
cat("  br_share_known NULL (no known country at all):",
    format(v$n_share_null, big.mark = ","), "\n")
cat("[OK] all validations passed\n\n")

####################################################################
### Step 5: reports -- this is how the gate gets judged
####################################################################

# One row per rsid. Everything below reads this, not the source, so it
# is free to re-run.
rsid_sql <- sprintf("
  SELECT rsid,
         max(university_name)    AS university_name,
         max(has_exact)          AS has_exact,
         max(has_norm)           AS has_norm,
         count(*)                AS n_raw,
         max(rsid_n_rows)        AS rsid_n_rows,
         max(rsid_n_users)       AS rsid_n_users,
         max(rsid_n_users_known) AS rsid_n_users_known,
         max(rsid_n_users_br)    AS rsid_n_users_br,
         max(rsid_top_country)   AS rsid_top_country,
         max(br_share_known)     AS br_share_known,
         max(br_share_all)       AS br_share_all
  FROM %s.%s
  GROUP BY rsid", athena_schema, athena_table)

# 1. The sentinel question of note 5, answered by the data. If a value
#    other than NULL and 'empty' is acting as a missing marker, it
#    shows up here and the `known` predicate has to be revised.
cat("=========== user_country OVER THE MATCHED rsids ===========\n")
ctry <- dbGetQuery(con, sprintf("
  SELECT coalesce(rsid_top_country, '(null)') AS rsid_top_country,
         count(*) AS n_rsid,
         sum(rsid_n_users) AS users
  FROM (%s) r
  GROUP BY 1 ORDER BY 3 DESC LIMIT 20", rsid_sql))
print(ctry, right = FALSE, row.names = FALSE)
cat("\n  (modal KNOWN country per rsid; '(null)' means the rsid has no\n",
    "   user with a usable user_country at all -- see notes 5 and 7.)\n", sep = "")

# 2. The band table. This is the number the criterion lives on: how
#    much of the reach sits above the gate and how much below it.
cat("\n=========== br_share_known BANDS ===========\n")
bands <- dbGetQuery(con, sprintf("
  SELECT CASE WHEN br_share_known IS NULL   THEN 'z  no known country'
              WHEN br_share_known >= 0.5    THEN 'a  >= 0.5  (KEPT)'
              WHEN br_share_known >= 0.1    THEN 'b  0.1 - 0.5'
              WHEN br_share_known >= 0.01   THEN 'c  0.01 - 0.1'
              ELSE 'd  < 0.01' END AS band,
         count(*)             AS n_rsid,
         sum(rsid_n_users)    AS users_reached,
         sum(rsid_n_users_br) AS users_br,
         sum(rsid_n_rows)     AS educ_rows
  FROM (%s) r GROUP BY 1 ORDER BY 1", rsid_sql))
print(bands, right = FALSE, row.names = FALSE)
cat("\nBand a is what criterion C_norm_rsid propagates through. Everything\n",
    "below it is what the withdrawn C_rsid branch admitted anyway -- see\n",
    "revelio_br_cohort_user_ids.R note 11.\n", sep = "")

# 3. Plausibility of the survivors. The ordering IS the validation:
#    nothing asserts that the biggest surviving schools should be the
#    obvious Brazilian universities, but they should be.
cat("\n=========== TOP 25 SURVIVING rsids ===========\n")
top <- dbGetQuery(con, sprintf("
  SELECT rsid, university_name, has_exact, has_norm, n_raw,
         rsid_n_users, rsid_n_users_known, rsid_n_users_br,
         br_share_known, br_share_all, rsid_top_country
  FROM (%s) r
  WHERE br_share_known > %.4f
  ORDER BY rsid_n_users DESC
  LIMIT 25", rsid_sql, br_share_min))
print(top, right = FALSE, row.names = FALSE)

# 4. The rejections that matter: the biggest schools the gate throws
#    out. These are exactly the rsids the withdrawn branch was poisoned
#    by, so Harvard, Phoenix, Delhi, Stanford, Cambridge, Toronto, UNAM
#    and Berkeley belong HERE and not in the table above. If they do
#    not appear here, the gate is not working and the cohort script
#    must not be run.
cat("\n=========== TOP 40 REJECTED rsids ===========\n")
rej_top <- dbGetQuery(con, sprintf("
  SELECT rsid, university_name, has_exact, has_norm, n_raw,
         rsid_n_users, rsid_n_users_known, rsid_n_users_br,
         br_share_known, br_share_all, rsid_top_country
  FROM (%s) r
  WHERE br_share_known IS NULL OR br_share_known <= %.4f
  ORDER BY rsid_n_users DESC
  LIMIT 40", rsid_sql, br_share_min))
print(rej_top, right = FALSE, row.names = FALSE)

print(dbGetQuery(con, sprintf("SELECT * FROM %s.%s LIMIT 10",
                              athena_schema, athena_table)))

####################################################################
### Step 6: bring the result back to Dropbox, and write the rejects
####################################################################

# arrow reads the whole prefix: UNLOAD writes several files.
cat("\n=========== LOCAL COPY ===========\n")
if (!arrow::arrow_with_s3()) {
  stop("This arrow build has no S3 support. Download the files from ",
       s3_path, " with the AWS CLI and read them from disk, or reinstall ",
       "arrow with S3 enabled.")
}
ds <- arrow::open_dataset(s3_path, format = "parquet")
# write_parquet does not take a Dataset: materialize a Table first. A
# few thousand narrow rows, so it fits in memory easily.
tb <- arrow::Scanner$create(ds)$ToTable()
arrow::write_parquet(tb, out_path, compression = "snappy")

local_n <- nrow(arrow::open_dataset(out_path, format = "parquet"))
cat("rows in the local parquet     :", format(local_n, big.mark = ","), "\n")
if (local_n != v$n_rows) {
  stop("Local parquet has ", local_n, " rows, Athena reported ", v$n_rows)
}

# The rejected pairs, at the PAIR grain rather than the rsid grain: the
# question a reader has is "which string did this school match, and was
# that match real?", and that is a property of the pair. CSV because
# this file is read by hand, which is the folder's rule -- parquet for
# machine-consumed artifacts, UTF-8 CSV for anything a human opens.
d <- as.data.frame(tb)
rej <- d[is.na(d$br_share_known) | d$br_share_known <= br_share_min,
         c("rsid", "university_name", "university_raw", "oa_matched_name",
           "m_exact", "m_norm", "has_exact", "has_norm",
           "n_rows", "n_users", "rsid_n_rows", "rsid_n_users",
           "rsid_n_users_known", "rsid_n_users_br",
           "br_share_known", "br_share_all", "rsid_top_country")]
rej <- rej[order(-as.numeric(rej$rsid_n_users), rej$rsid, rej$university_raw), ]
write.csv(rej, rej_path, row.names = FALSE, fileEncoding = "UTF-8")

kept_rsid <- unique(d$rsid[!is.na(d$br_share_known) &
                           d$br_share_known > br_share_min])

cat("\n=========== SUMMARY ===========\n")
cat("  local parquet :", out_path,
    sprintf("(%.2f MB)\n", file.info(out_path)$size / 2^20))
cat("  rejected pairs:", rej_path,
    sprintf("(%.1f KB)\n", file.info(rej_path)$size / 2^10))
cat("  S3 prefix     :", s3_path, "\n")
cat("  Athena table  :", paste0(athena_schema, ".", athena_table), "\n")
cat("  rows          :", format(v$n_rows, big.mark = ","),
    "over", format(v$n_rsids, big.mark = ","), "rsids\n")
cat("  gate          : br_share_known >", br_share_min,
    "on distinct users, user_country from", user_table, "\n")
cat("  rejected pairs:", format(nrow(rej), big.mark = ","),
    "of", format(nrow(d), big.mark = ","), "\n")
cat("  surviving rsid:", format(length(kept_rsid), big.mark = ","), "\n")
