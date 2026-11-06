####################################################################
###
### Revelio Brazilian cohort -> S3 + Athena
###
### Selects every Revelio user_id that satisfies
###
###   (A OR B OR C_norm) AND D AND E
###
###   A  some row in academic_individual_position with
###      country = 'Brazil'
###   B  some row in academic_individual_user_education with
###      university_country = 'Brazil'
###   C_norm  some row in academic_individual_user_education whose
###      university_raw matches a cleaned_display_name in
###      openalex_institutions_br, comparing with accents folded and
###      allowing the match to be on any '/', '-' or '( )' delimited
###      SEGMENT of the raw string rather than the whole of it. The
###      whole-string arm accepts any record type; the segment arm
###      only education records. See note 11.
###   D  the FIRST position (smallest startdate) starts in 2007 or later
###   E  the FIRST Bachelor starts in 2007 or later, where "Bachelor"
###      means degree = 'Bachelor' OR a bachelor pattern matched on
###      degree_raw -- see br_degree_patterns.R and note 8 below
###
### The result is written straight to S3 with UNLOAD and registered as
### an external table in Athena. The intent is to use this cohort later
### COMBINED with other criteria inside Athena -- in particular with
### revelio_database.linkedin_br_name_flag, which is a name prior and
### not a nationality.
###
### Depends on:
###   prep/building_external_data/openalex_institutions_br_to_s3.R
###   (table revelio_database.openalex_institutions_br)
###
### Athena read pattern reused from:
###   gtl/gtfounders/Cleaning and Gathering/1-Get_Founders_IDs.R
###   gtl/gtallocation/prep/linkedin_matching/prepare_predictors/2-get_predictors.R
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. That is a deliberate exception: reading from Athena
###    and writing to S3 is the whole point. It is a local prep/ script
###    and must not be sent to the offline SEDAP environment.
### 2. D and E are STRICT: anyone with no position at all, or no
###    Bachelor at all, or only null startdates in either one, is LEFT
###    OUT. The INNER JOIN between the two subqueries is what enforces
###    that -- switching it to a LEFT JOIN would change the definition
###    of the cohort, not just performance.
### 3. Accent folding happens AT QUERY TIME, never in the stored
###    artifact. openalex_br_institutions.R writes display_name and
###    cleaned_display_name untouched and asserts a non-ASCII count to
###    keep them that way, so the folding lives here -- exactly as the
###    lowercasing always has. Trino has no strip_accents(): the
###    expression is
###      regexp_replace(normalize(s, NFD), '\p{M}', '')
###    which decomposes each letter and drops the combining marks.
###    br_openalex still stores the OLD exact match, so the previous
###    cohort is recoverable in place; see note 5.
### 4. cleaned_display_name (rather than display_name) is the OpenAlex
###    side because it is the form without the parenthetical --
###    "Universidade Estadual de Campinas" instead of "Universidade
###    Estadual de Campinas (UNICAMP)" -- which is much closer to what
###    people type on LinkedIn. Both columns are in the table, so
###    widening the match later requires no re-upload.
### 5. br_position / br_educ_country / br_openalex / br_openalex_norm
###    all travel in the file alongside user_id, so the cut can be
###    TIGHTENED in Athena without regenerating anything and every
###    selected user_id is auditable back to what admitted it.
###    br_openalex is the OLD exact match and br_openalex_norm the
###    widened one; keeping both means
###      WHERE br_position = 1 OR br_educ_country = 1 OR br_openalex = 1
###    reproduces the pre-C_norm cohort exactly, with no re-scan.
### 6. The query aggregates BOTH Revelio individual tables in full. It
###    is a one-shot job, but it is not cheap.
### 7. startdate is stored differently in the two tables, verified with
###    DESCRIBE: string in academic_individual_position, date in
###    academic_individual_user_education. The two sides of the query
###    handle it differently on purpose. See the notes above
###    select_sql before touching either one.
### 8. Revelio's `degree` column is NOT trustworthy on Brazilian
###    records, which is why criterion E does not rely on it alone.
###    'bacharelado' is labelled High School on 489,815 rows and
###    Bachelor on 762,945 -- the same string, split
###    non-deterministically. 'graduacao' (634,542 rows) is always
###    'empty'. In a random sample of 1,000 Brazilian rows, ALL 93
###    rows labelled High School were bachelor's degrees; sample
###    recall of degree = 'Bachelor' was 58.4%. The union rule in
###    br_degree_patterns.R lifts the Brazilian bachelor row count
###    from 3,041,173 to 5,450,492 (1.79x).
###    The country literals WERE confirmed: country = 'Brazil'
###    (98,704,713 position rows) and university_country = 'Brazil'
###    (10,692,191 education rows).
### 10. min_bach_year_strict stores the year under the OLD
###    degree = 'Bachelor' rule, so the previous cohort definition is
###    recoverable in place with
###      WHERE min_bach_year_strict IS NOT NULL
###        AND min_bach_year_strict >= 2007
###    without rescanning anything.
### 9. There is no upper bound on the year, matching the stated
###    criteria. Education startdate does contain junk at the top end
###    (max is 2563-01-01), but since D and E take the EARLIEST record,
###    a stray future date only matters for someone whose single
###    Bachelor row carries one.
### 11. C_norm REPLACED an rsid-propagation branch (C_rsid) that was
###    tried and withdrawn on 2026-08-25. That branch admitted a user
###    when Revelio's school key (rsid) matched a Brazilian
###    institution anywhere, and it failed badly: a SINGLE stray
###    education row enrolled an entire foreign university -- somebody
###    whose rsid is Harvard typed "Universidade Federal do Rio de
###    Janeiro", 1 row of 562,968, and that admitted all of Harvard.
###    Even at its safest threshold it contributed 12,023 members of
###    whom 6.3% were located in Brazil.
###
###    C_norm attacks the same problem -- variant spellings -- at the
###    string, where it cannot amplify. Measured: it newly matches
###    1,251,551 users absent from the pool, 94.6% of them located in
###    Brazil, against criterion C's own 92.6%. The premise behind
###    C_rsid was also simply wrong: bare acronyms are 1.5-2.5% of an
###    institution's rows. What C missed was the full name DECORATED
###    with its acronym -- "USP - Universidade de Sao Paulo" (29,840
###    rows), "Universidade de Sao Paulo / USP" (23,237) -- which is a
###    formatting problem, not an abbreviation problem.
### 12. The SEGMENT arm is restricted to type = 'education' records on
###    purpose. The Brazilian institution list holds short company
###    names -- IBM, AES, Vale, Intel, Shell, Eaton, Nestle, Sanofi,
###    TOTVS -- and an entry reading "Curso de Ingles - Intel" would
###    otherwise match one. A name-LENGTH filter is not a substitute:
###    "Insper" is six characters and a real education record.
###    Measured, the excluded bucket is 11,091 education rows and is
###    itself mixed: British Council - Sri Lanka and Eaton (City of
###    Norwich) School sit in it, but so do Inteli and IBCCRIM.
###
###    The WHOLE-STRING arm still accepts any record type, which is
###    what keeps Estacio -- a `company` record with 7,237 works and no
###    education record of its own. That also means the whole-string
###    arm still matches "British Council" exactly, as criterion C
###    always has. That defect predates all of this and is untouched.
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
out_path <- file.path(out_dir, "obmep_br_cohort_user_ids.parquet")

min_year <- 2007

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
s3_prefix <- "exports/obmep_br_cohort_user_ids"
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table  <- "obmep_br_cohort_user_ids"

# Institutions table registered by
# openalex_institutions_br_to_s3.R.
inst_table <- "openalex_institutions_br"



# Measured 2026-08-25 under (A OR B OR C_norm). The exact-match
# criterion (A OR B OR C) gave 5,730,315, so widening the string match
# adds 5,705 members: C_norm sets the flag on 20.4% MORE members
# (2,862,213 -> 3,446,186), but nearly all of them were already
# admitted by A or B. The withdrawn C_rsid branch gave 5,742,338 at
# match_share 0.5 and 13,375,338 at 0.
# NA disables the check.
exp_rows <- 5736020

# Membership floor: C_norm is a strict SUPERSET of C -- folding
# accents and admitting segment matches can only add strings, never
# remove one -- so everyone admitted by (A OR B OR C) is still
# admitted. A smaller cohort means the normalization dropped a match
# it should have kept.
min_rows <- 5730315

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

# Shared with revelio_br_name_cohort_user_ids.R: defines rx_* and
# sql_is_bachelor. Constants only -- no functions, no side effects.
# Both cohorts MUST use the same patterns; see that file's header.
patterns_file <- Sys.getenv(
  "OBMEP_DEGREE_PATTERNS",
  unset = paste0("C:/Users/megaj/repos/obmep_effect/prep/",
                 "building_external_data/br_degree_patterns.R"))
if (!file.exists(patterns_file)) patterns_file <- "br_degree_patterns.R"
stopifnot(file.exists(patterns_file))
source(patterns_file)

####################################################################
### Step 1: build the query
####################################################################

# The SELECT body lives in its own variable for two reasons: it is
# reused inside the UNLOAD, and it can be validated on its own (see
# validate_sql_syntax.R), whereas UNLOAD and DDL cannot.
#
# Notes on the shape of the query:
#
#  - the LEFT JOIN goes against SELECT DISTINCT lower(...), not against
#    the table. Lowercasing collapses names that were distinct in the
#    source, so a direct join could MULTIPLY education rows. With the
#    DISTINCT the join is at most 1:1 and the question disappears.
#  - raw_cls classifies DISTINCT university_raw strings and the
#    education table joins to it, so the UNNEST runs over distinct
#    strings rather than over every education row. That is what makes
#    the segment arm affordable.
#  - raw_cls is unique on university_raw: it is built from
#    SELECT DISTINCT and LEFT JOINed to a `seg` that is itself grouped
#    by university_raw. The join to the education table is therefore
#    at most 1:1 and cannot multiply rows -- the same guarantee the
#    old SELECT DISTINCT lower(...) subquery gave.
#  - the WHOLE-STRING arm reads inst_fold, which carries every record
#    type, so Estacio (a `company` with no education record of its
#    own) still matches. The SEGMENT arm requires is_edu = 1. Note 12
#    explains why the two arms differ.
#  - length(trim(part)) >= 3 drops the empty and single-character
#    fragments splitting produces; the shortest real name in the
#    institution list is 3 characters.
#  - br_openalex keeps the OLD exact semantics, br_openalex_norm the
#    widened one. Storing both is what makes the pre-C_norm cohort
#    recoverable in place, and norm is a superset of exact by
#    construction -- asserted in the validation.
#  - min(CASE WHEN degree = 'Bachelor' THEN ... END) gives the first
#    Bachelor, and returns NULL for anyone with none at all -- exactly
#    what criterion E has to reject.
#  - the two tables do NOT store startdate the same way, which is why
#    the two sides look different. Measured with DESCRIBE:
#      academic_individual_position.startdate       -> string
#      academic_individual_user_education.startdate -> date
#    So the position side takes the year off the front of the string
#    and the education side can call year() directly. Calling year()
#    on the position column is what raised
#    "FUNCTION_NOT_FOUND: Unexpected parameters (varchar) for function
#    year". Do not "simplify" the two sides into one form.
#  - the position strings are uniform: all 1,392,756,172 non-null
#    values have length 10 and look like YYYY-MM-DD, from 1950-01-01
#    to 2029-04-01. substr(startdate, 1, 4) is therefore always the
#    year. try_cast keeps a future malformed value from killing the
#    whole query -- it becomes NULL, min() ignores it, and a user whose
#    startdates are ALL unparseable drops out, which is the intended
#    conservative behaviour under the strict rule in note 2.
#  - both sides end up as integer, matching the INT columns in the DDL.
#    year() on a date returns bigint in Trino, hence the explicit CAST
#    on the education side: without it the parquet would carry int64
#    where the DDL declares INT, and the mismatch would only surface on
#    read.
select_sql <- sprintf("
WITH inst_fold AS (
  SELECT lower(regexp_replace(normalize(cleaned_display_name, NFD), '\\p{M}', '')) AS nm_fold,
         max(CASE WHEN type = 'education' THEN 1 ELSE 0 END) AS is_edu
  FROM %s
  GROUP BY lower(regexp_replace(normalize(cleaned_display_name, NFD), '\\p{M}', ''))
),
inst_exact AS (
  SELECT DISTINCT lower(cleaned_display_name) AS nm_exact FROM %s
),
raws AS (
  SELECT DISTINCT university_raw
  FROM academic_individual_user_education
  WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''
),
seg AS (
  SELECT r.university_raw, 1 AS seg_edu
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
              THEN 1 ELSE 0 END AS m_norm
  FROM raws r
  LEFT JOIN seg s ON r.university_raw = s.university_raw
)
SELECT p.user_id,
       p.br_position,
       e.br_educ_country,
       e.br_openalex,
       e.br_openalex_norm,
       p.min_pos_year,
       e.min_bach_year,
       e.min_bach_year_strict
FROM (
  SELECT user_id,
         min(try_cast(substr(startdate, 1, 4) AS integer)) AS min_pos_year,
         max(CASE WHEN country = 'Brazil' THEN 1 ELSE 0 END) AS br_position
  FROM academic_individual_position
  GROUP BY user_id
) p
INNER JOIN (
  SELECT user_id,
         min(CASE WHEN is_bach   THEN bach_year END) AS min_bach_year,
         min(CASE WHEN is_strict THEN bach_year END) AS min_bach_year_strict,
         max(br_educ_country)  AS br_educ_country,
         max(br_openalex)      AS br_openalex,
         max(br_openalex_norm) AS br_openalex_norm
  FROM (
    SELECT e.user_id,
           CAST(year(e.startdate) AS integer) AS bach_year,
           (%s) AS is_bach,
           (e.degree = 'Bachelor') AS is_strict,
           CASE WHEN e.university_country = 'Brazil' THEN 1 ELSE 0 END AS br_educ_country,
           coalesce(c.m_exact, 0) AS br_openalex,
           coalesce(c.m_norm, 0)  AS br_openalex_norm
    FROM (
      SELECT user_id, startdate, degree, university_country, university_raw,
             lower(trim(coalesce(degree_raw, ''))) AS dr
      FROM academic_individual_user_education
    ) e
    LEFT JOIN raw_cls c
      ON e.university_raw = c.university_raw
  ) x
  GROUP BY user_id
) e
  ON p.user_id = e.user_id
WHERE (p.br_position = 1 OR e.br_educ_country = 1 OR e.br_openalex_norm = 1)
  AND p.min_pos_year  IS NOT NULL AND p.min_pos_year  >= %d
  AND e.min_bach_year IS NOT NULL AND e.min_bach_year >= %d",
  inst_table, inst_table, sql_is_bachelor, min_year, min_year)

unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')",
  select_sql, s3_path)

ddl_txt <- sprintf(
"CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (
  user_id BIGINT,
  br_position INT,
  br_educ_country INT,
  br_openalex INT,
  br_openalex_norm INT,
  min_pos_year INT,
  min_bach_year INT,
  min_bach_year_strict INT
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
# with a clear message, beats spending the scan of both individual
# tables only for Athena to refuse the write afterwards.
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

# The institutions table has to exist first: without it criterion C
# silently disappears and the cohort comes out smaller with no warning.
inst_n <- dbGetQuery(con, sprintf("SELECT count(*) AS n FROM %s.%s",
                                  athena_schema, inst_table))
cat("BR institutions available     :", format(inst_n$n, big.mark = ","), "\n")
if (inst_n$n == 0) {
  stop("Table ", athena_schema, ".", inst_table, " is empty. ",
       "Run openalex_institutions_br_to_s3.R first.")
}

cat("\nRunning UNLOAD (scans both individual tables)...\n")
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
         count(DISTINCT user_id) AS n_users,
         sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS uid_null,
         min(min_pos_year)  AS pos_year_min,  max(min_pos_year)  AS pos_year_max,
         min(min_bach_year) AS bach_year_min, max(min_bach_year) AS bach_year_max,
         sum(CASE WHEN min_bach_year_strict IS NULL
                    OR min_bach_year_strict < %d THEN 1 ELSE 0 END) AS n_new_by_degree_fix,
         sum(CASE WHEN min_bach_year_strict < min_bach_year THEN 1 ELSE 0 END) AS bad_strict,
         sum(br_position)     AS n_br_position,
         sum(br_educ_country) AS n_br_educ_country,
         sum(br_openalex)      AS n_br_openalex,
         sum(br_openalex_norm) AS n_br_openalex_norm,
         sum(CASE WHEN br_openalex_norm = 1 AND br_position = 0
                   AND br_educ_country = 0 AND br_openalex = 0
                  THEN 1 ELSE 0 END) AS n_norm_only,
         sum(CASE WHEN br_openalex = 1 AND br_openalex_norm = 0
                  THEN 1 ELSE 0 END) AS bad_not_superset
  FROM %s.%s", min_year, athena_schema, athena_table))
print(v)

if (v$n_users != v$n_rows) stop("Duplicate user_id in the cohort.")
if (v$uid_null != 0) stop("NULL user_id in the cohort.")
if (v$pos_year_min < min_year) {
  stop("min_pos_year ", v$pos_year_min, " is below the cutoff of ", min_year)
}
if (v$bach_year_min < min_year) {
  stop("min_bach_year ", v$bach_year_min, " is below the cutoff of ", min_year)
}
# br_openalex_norm, not br_openalex: the WIDENED flag is the one the
# WHERE clause uses, so summing the exact one would let a member
# admitted only by a segment match fail this check spuriously.
if (v$n_br_position + v$n_br_educ_country +
    v$n_br_openalex_norm < v$n_rows) {
  stop("There is a row with no Brazil flag set.")
}
# Membership is monotone in the new OR branch: everyone admitted by
# (A OR B OR C) is still admitted by (A OR B OR C_rsid OR C). A
# smaller cohort than the pre-rsid one is impossible by construction.
# C_norm is a strict superset of C: folding accents and accepting
# segment matches can only ADD strings, never remove one. A row
# matching the old exact rule but not the new one means the
# normalization is dropping matches, which would silently shrink the
# cohort while every other check still passed.
if (v$bad_not_superset != 0) {
  stop(v$bad_not_superset, " rows have br_openalex = 1 but ",
       "br_openalex_norm = 0. C_norm must be a superset of C.")
}
if (!is.na(min_rows) && v$n_rows < min_rows) {
  stop("Cohort has ", v$n_rows, " rows, fewer than the pre-rsid ",
       min_rows, ". Adding a disjunct cannot shrink membership -- the ",
       "criterion is wrong.")
}
# Strict rows are a SUBSET of union rows, so their minimum can never be
# earlier. If it is, the two aggregates disagree and the predicate is wrong.
if (v$bad_strict != 0) {
  stop(v$bad_strict, " rows have min_bach_year_strict < min_bach_year.")
}
if (!is.na(exp_rows) && v$n_rows != exp_rows) {
  warning("Expected ", exp_rows, " rows, got ", v$n_rows)
}

cat("\nrows in the cohort            :", format(v$n_rows, big.mark = ","), "\n")
cat("  A: by position in Brazil    :", format(v$n_br_position, big.mark = ","), "\n")
cat("  B: by university_country    :", format(v$n_br_educ_country, big.mark = ","), "\n")
cat("  C_norm: by institution name :",
    format(v$n_br_openalex_norm, big.mark = ","), "\n")
cat("  admitted only by the degree_raw fix:",
    format(v$n_new_by_degree_fix, big.mark = ","), "\n")

cat("\n--- what the normalization recovers ---\n")
# The number to read. Members admitted by the widened match and by
# nothing else: no Brazilian job, no Brazilian university_country, no
# EXACT name match. This is C_norm's own contribution. The retired
# C_rsid branch delivered 12,023 here, 6.3% of them located in
# Brazil; see note 11.
cat("  admitted ONLY by C_norm     :", format(v$n_norm_only, big.mark = ","),
    sprintf("(%.1f%% of the cohort)\n",
            100 * as.numeric(v$n_norm_only) / as.numeric(v$n_rows)))
cat("  gained over the exact-match cohort:",
    format(v$n_rows - min_rows, big.mark = ","), "\n")
cat("  C exact / C_norm            :",
    format(v$n_br_openalex, big.mark = ","), "/",
    format(v$n_br_openalex_norm, big.mark = ","),
    sprintf("(+%.1f%%)\n",
            100 * (as.numeric(v$n_br_openalex_norm) /
                   as.numeric(v$n_br_openalex) - 1)))

print(dbGetQuery(con, sprintf("SELECT * FROM %s.%s LIMIT 10",
                              athena_schema, athena_table)))
cat("[OK] all validations passed\n\n")

####################################################################
### Step 5: bring the result back to Dropbox
####################################################################

# arrow reads the whole prefix: UNLOAD writes several files.
cat("=========== LOCAL COPY ===========\n")
if (!arrow::arrow_with_s3()) {
  stop("This arrow build has no S3 support. Download the files from ",
       s3_path, " with the AWS CLI and read them from disk, or reinstall ",
       "arrow with S3 enabled.")
}
ds <- arrow::open_dataset(s3_path, format = "parquet")
# write_parquet does not take a Dataset: materialize a Table first. Six
# narrow columns, so it fits in memory even with tens of millions of
# rows.
arrow::write_parquet(arrow::Scanner$create(ds)$ToTable(), out_path,
                     compression = "snappy")

local_n <- nrow(arrow::open_dataset(out_path, format = "parquet"))
cat("rows in the local parquet     :", format(local_n, big.mark = ","), "\n")
if (local_n != v$n_rows) {
  stop("Local parquet has ", local_n, " rows, Athena reported ", v$n_rows)
}

cat("\n=========== SUMMARY ===========\n")
cat("  local parquet :", out_path,
    sprintf("(%.2f MB)\n", file.info(out_path)$size / 2^20))
cat("  S3 prefix     :", s3_path, "\n")
cat("  Athena table  :", paste0(athena_schema, ".", athena_table), "\n")
cat("  rows          :", format(v$n_rows, big.mark = ","), "\n")
cat("  cutoff        : first position and first Bachelor >=",
    min_year, "\n")
