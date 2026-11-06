####################################################################
###
### Revelio Brazilian-name cohort -> S3 + Athena
###
### Variant of revelio_br_cohort_user_ids.R. Same date criteria, but
### the first Brazil signal is the NAME PRIOR instead of an observed
### country. Selects every Revelio user_id that satisfies
###
###   A AND D AND E
###
###   A  user_id appears in revelio_database.linkedin_br_name_flag
###      with p_brazil > 0.5  (Brazilian-sounding given name)
###   D  the FIRST position (smallest startdate) starts in 2007 or later
###   E  the FIRST Bachelor starts in 2007 or later, where "Bachelor"
###      means degree = 'Bachelor' OR a bachelor pattern matched on
###      degree_raw -- see br_degree_patterns.R and note 11 below
###
### The Brazilian-education signals used by the sibling script --
### university_country = 'Brazil' (br_educ_country) and the OpenAlex
### institution-name match, stored twice as br_openalex (the exact
### rule) and br_openalex_norm (the normalized one, criterion C_norm
### in the sibling script) -- are still COMPUTED and STORED here, but
### they do
### NOT filter. Membership is the name prior alone.
###
### The sibling script revelio_br_cohort_user_ids.R uses
### country = 'Brazil' on academic_individual_position as criterion A.
### That flag is still COMPUTED and STORED here as br_position, but it
### does NOT filter -- so the two cohort definitions can be compared,
### or the old criterion re-imposed, without rescanning anything.
###
### Depends on:
###   prep/building_external_data/openalex_institutions_br_to_s3.R
###   (table revelio_database.openalex_institutions_br)
###   prep/building_external_data/linkedin_br_flag_to_s3.R
###   (table revelio_database.linkedin_br_name_flag)
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. That is a deliberate exception: reading from Athena
###    and writing to S3 is the whole point. It is a local prep/ script
###    and must not be sent to the offline SEDAP environment.
### 2. Criterion A is a PRIOR ON THE GIVEN NAME, not nationality. It
###    says nothing about where the person was born, studied or works.
###    A Portuguese or Angolan profile with a common Brazilian first
###    name scores high; a Brazilian named Yuki or Wolfgang does not.
###    This is exactly why linkedin_br_flag_to_s3.R says the crosswalk
###    is meant to be combined with other criteria. Here the ONLY other
###    criteria are the date filters D and E: the Brazilian-education
###    signals are stored but do not filter. Expect this cohort to be
###    less specific than the sibling country-based one, and read
###    br_educ_country / br_openalex to see how much corroboration any
###    given member actually has.
### 3. p_brazil is ORDERING, not a calibrated probability. The 0.5 cut
###    is a TIGHTENING of the 0.05 floor baked into the table, which is
###    allowed; it can be tightened further in Athena at any time but
###    can never be loosened below 0.05 without regenerating the
###    upstream crosswalk. Measured: 39,450,441 of the 140,263,729
###    user_ids in the table clear 0.5.
### 4. Profiles whose name is in a non-Latin alphabet have NULL
###    p_brazil upstream and are ABSENT from linkedin_br_name_flag
###    entirely. Since membership is criterion A alone, they can never
###    enter this cohort at all -- not even with a Brazilian degree.
### 5. D and E are STRICT: anyone with no position at all, or no
###    Bachelor at all, or only null startdates in either one, is LEFT
###    OUT. The INNER JOIN between the two subqueries is what enforces
###    that -- switching it to a LEFT JOIN would change the definition
###    of the cohort, not just performance.
### 6. The institution match is criterion C_norm, defined in
###    revelio_br_cohort_user_ids.R note 11: accents folded, and the
###    match allowed on any '/', '-' or '( )' delimited segment of
###    university_raw as well as on the whole string. Folding happens
###    at QUERY time; the OpenAlex artifacts are never folded and
###    their assertions depend on that. br_openalex keeps the old
###    exact semantics beside it so the earlier definition stays
###    recoverable in place.
### 7. cleaned_display_name (rather than display_name) is the OpenAlex
###    side because it is the form without the parenthetical --
###    "Universidade Estadual de Campinas" instead of "Universidade
###    Estadual de Campinas (UNICAMP)" -- which is much closer to what
###    people type on LinkedIn.
### 8. All flags plus the raw p_brazil travel in the file alongside
###    user_id. That way the cut can be TIGHTENED in Athena without
###    regenerating anything, and every selected user_id is auditable
###    back to the criterion that admitted it.
### 13. br_openalex_norm is computed exactly as in the sibling
###    script and, like every other education signal, does NOT filter
###    here. Because it cannot change membership, exp_rows stays at
###    3,779,509: if the rebuild returns any other number, the
###    widened match leaked into the WHERE clause. That is the
###    sharpest check in this rebuild -- do not 'update' the constant
###    to make it pass.
### 9. startdate is stored differently in the two tables, verified with
###    DESCRIBE: string in academic_individual_position, date in
###    academic_individual_user_education. The two sides of the query
###    handle it differently on purpose. See the notes above
###    select_sql before touching either one.
### 10. The query aggregates BOTH Revelio individual tables in full and
###    joins a 140M-row crosswalk. It is a one-shot job, but it is not
###    cheap: the sibling script measured 35.25 GB scanned.
### 11. Revelio's `degree` column is NOT trustworthy on Brazilian
###    records, which is why criterion E does not rely on it alone.
###    'bacharelado' is labelled High School on 489,815 rows and
###    Bachelor on 762,945 -- the same string, split
###    non-deterministically. 'graduacao' (634,542 rows) is always
###    'empty'. In a random sample of 1,000 Brazilian rows, ALL 93
###    rows labelled High School were bachelor's degrees; sample
###    recall of degree = 'Bachelor' was 58.4%. The union rule in
###    br_degree_patterns.R lifts the Brazilian bachelor row count
###    from 3,041,173 to 5,450,492 (1.79x).
### 12. min_bach_year_strict stores the year under the OLD
###    degree = 'Bachelor' rule, so the previous, stricter definition
###    of E is recoverable in place with
###      WHERE min_bach_year_strict IS NOT NULL
###        AND min_bach_year_strict >= 2007
###    without rescanning anything.
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
out_path <- file.path(out_dir, "obmep_br_name_cohort_user_ids.parquet")

min_year <- 2007
p_cut    <- 0.5

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
s3_prefix <- "exports/obmep_br_name_cohort_user_ids"
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table  <- "obmep_br_name_cohort_user_ids"

# Upstream tables, registered by the sibling scripts.
inst_table <- "openalex_institutions_br"
name_table <- "linkedin_br_name_flag"

# Measured 2026-08-24 under the corrected criterion E and A-only
# membership. 1,240,292 of these are admitted only because criterion E
# now reads degree_raw. NA disables the check.
#
# UNCHANGED by design: the education signals are stored here and do
# not filter, so membership cannot move. See note 13.
exp_rows <- 3779509

# Measured in linkedin_br_flag_to_s3.R and re-checked below: the name
# crosswalk is unique on user_id, which is what makes the LEFT JOIN
# below 1:1 and keeps it from multiplying rows.
exp_name_rows <- 140263729

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

# Shared with revelio_br_cohort_user_ids.R: defines rx_* and
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
#  - the name crosswalk is joined with LEFT JOIN, not INNER JOIN,
#    because criterion A is one arm of an OR: a user who fails A must
#    still be able to enter through B or C. The filtering happens in
#    the WHERE clause, not in the join.
#  - p_brazil > %.4f is pushed INSIDE the subquery rather than left in
#    the WHERE. That way a user below the cut joins to nothing and gets
#    br_name = 0, instead of joining and then being dropped -- which
#    would also have silently killed their B/C eligibility.
#  - coalesce(n.br_name, 0): a non-match yields NULL, and NULL in the
#    output column would be indistinguishable from a real 0 for anyone
#    reading the parquet. p_brazil is deliberately left NULL on a
#    non-match, since "no value" is the honest answer there.
#  - br_position is computed but NEVER referenced in the WHERE. It is
#    carried so this cohort can be compared against the country-based
#    one without rescanning.
#  - the LEFT JOIN to the institutions list goes against
#    SELECT DISTINCT lower(...), not against the table. Lowercasing
#    collapses names that were distinct in the source, so a direct join
#    could MULTIPLY education rows. With the DISTINCT the join is at
#    most 1:1 and the question disappears.
#  - raw_cls classifies DISTINCT university_raw strings and the
#    education table joins to it, so the UNNEST runs over distinct
#    strings rather than over every education row. raw_cls is unique
#    on university_raw, so the join is at most 1:1 and cannot
#    multiply rows -- the same guarantee the old
#    SELECT DISTINCT lower(...) subquery gave. Identical to the
#    sibling script; the two must stay in sync.
#  - br_openalex keeps the OLD exact semantics and br_openalex_norm
#    the widened one. Neither is referenced in the WHERE: membership
#    here is criterion A alone.
#  - min(CASE WHEN degree = 'Bachelor' THEN ... END) gives the first
#    Bachelor, and returns NULL for anyone with none at all -- exactly
#    what criterion E has to reject.
#  - the two tables do NOT store startdate the same way, which is why
#    the two sides look different. Measured with DESCRIBE:
#      academic_individual_position.startdate       -> string
#      academic_individual_user_education.startdate -> date
#    So the position side takes the year off the front of the string
#    and the education side can call year() directly. Calling year()
#    on the position column raises
#    "FUNCTION_NOT_FOUND: Unexpected parameters (varchar) for function
#    year". Do not "simplify" the two sides into one form.
#  - the position strings are uniform: all 1,392,756,172 non-null
#    values have length 10 and look like YYYY-MM-DD, from 1950-01-01
#    to 2029-04-01. substr(startdate, 1, 4) is therefore always the
#    year. try_cast keeps a future malformed value from killing the
#    whole query -- it becomes NULL, min() ignores it, and a user whose
#    startdates are ALL unparseable drops out, which is the intended
#    conservative behaviour under the strict rule in note 5.
#  - both year columns end up as integer, matching the INT columns in
#    the DDL. year() on a date returns bigint in Trino, hence the
#    explicit CAST on the education side: without it the parquet would
#    carry int64 where the DDL declares INT, and the mismatch would
#    only surface on read.
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
       coalesce(n.br_name, 0) AS br_name,
       e.br_educ_country,
       e.br_openalex,
       e.br_openalex_norm,
       p.br_position,
       n.p_brazil,
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
         max(br_educ_country) AS br_educ_country,
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
LEFT JOIN (
  SELECT user_id, p_brazil, 1 AS br_name
  FROM %s
  WHERE p_brazil > %.4f
) n
  ON p.user_id = n.user_id
WHERE n.br_name = 1
  AND p.min_pos_year  IS NOT NULL AND p.min_pos_year  >= %d
  AND e.min_bach_year IS NOT NULL AND e.min_bach_year >= %d",
  inst_table, inst_table, sql_is_bachelor, name_table,
  p_cut, min_year, min_year)

unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')",
  select_sql, s3_path)

ddl_txt <- sprintf(
"CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (
  user_id BIGINT,
  br_name INT,
  br_educ_country INT,
  br_openalex INT,
  br_openalex_norm INT,
  br_position INT,
  p_brazil DOUBLE,
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
### Step 3: check the upstream tables
####################################################################

cat("=========== ATHENA ===========\n")
con <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name    = s3_region,
                 schema_name    = athena_schema)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

# Without the institutions table criterion C silently disappears and
# the cohort comes out smaller with no warning.
inst_n <- dbGetQuery(con, sprintf("SELECT count(*) AS n FROM %s.%s",
                                  athena_schema, inst_table))
cat("BR institutions available     :", format(inst_n$n, big.mark = ","), "\n")
if (inst_n$n == 0) {
  stop("Table ", athena_schema, ".", inst_table, " is empty. ",
       "Run openalex_institutions_br_to_s3.R first.")
}
# Uniqueness on user_id is what makes the LEFT JOIN 1:1. If this ever
# stopped holding, the cohort would silently gain duplicate rows.
nm <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_rows,
         count(DISTINCT user_id) AS n_users,
         sum(CASE WHEN p_brazil > %.4f THEN 1 ELSE 0 END) AS n_cut
  FROM %s.%s", p_cut, athena_schema, name_table))
cat("name-flag rows                :", format(nm$n_rows, big.mark = ","), "\n")
cat("  distinct user_id            :", format(nm$n_users, big.mark = ","), "\n")
cat(sprintf("  with p_brazil > %.2f        : %s\n",
            p_cut, format(nm$n_cut, big.mark = ",")))
if (nm$n_users != nm$n_rows) {
  stop("Table ", athena_schema, ".", name_table, " is not unique on ",
       "user_id: the LEFT JOIN would multiply rows.")
}
if (nm$n_rows != exp_name_rows) {
  warning("Name crosswalk has ", nm$n_rows, " rows, expected ", exp_name_rows)
}
if (nm$n_cut == 0) {
  stop("No user_id clears p_brazil > ", p_cut, " -- criterion A would be dead.")
}

####################################################################
### Step 4: run the UNLOAD and register the table
####################################################################

cat("\nRunning UNLOAD (scans both individual tables)...\n")
t0 <- Sys.time()
dbExecute(con, unload_sql)
cat("  finished in",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n\n")

cat(ddl_txt, "\n")
dbExecute(con, ddl_txt)

####################################################################
### Step 5: validation through Athena
####################################################################

cat("\n=========== VALIDATION ===========\n")
v <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_rows,
         count(DISTINCT user_id) AS n_users,
         sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS uid_null,
         min(min_pos_year)  AS pos_year_min,  max(min_pos_year)  AS pos_year_max,
         min(min_bach_year) AS bach_year_min, max(min_bach_year) AS bach_year_max,
         sum(br_name)         AS n_br_name,
         sum(br_educ_country) AS n_br_educ_country,
         sum(br_openalex)      AS n_br_openalex,
         sum(br_openalex_norm) AS n_br_openalex_norm,
         sum(br_position)     AS n_br_position,
         sum(CASE WHEN br_position = 0 AND br_educ_country = 0
                   AND br_openalex_norm = 0
                  THEN 1 ELSE 0 END) AS n_no_corroboration,
         min(CASE WHEN br_name = 1 THEN p_brazil END) AS p_min_flagged,
         sum(CASE WHEN br_name = 1 AND p_brazil IS NULL THEN 1 ELSE 0 END) AS bad_null,
         sum(CASE WHEN br_name = 0 AND p_brazil IS NOT NULL THEN 1 ELSE 0 END) AS bad_set,
         sum(CASE WHEN min_bach_year_strict IS NULL
                    OR min_bach_year_strict < %d THEN 1 ELSE 0 END) AS n_new_by_degree_fix,
         sum(CASE WHEN min_bach_year_strict < min_bach_year THEN 1 ELSE 0 END) AS bad_strict,
         sum(CASE WHEN br_name = 0 THEN 1 ELSE 0 END) AS not_flagged
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
# Membership is criterion A alone, so EVERY row must carry br_name = 1.
# br_educ_country and br_openalex are stored but never filter.
if (v$not_flagged != 0) {
  stop(v$not_flagged, " rows have br_name = 0 but membership is A-only.")
}
# Strict rows are a SUBSET of union rows, so their minimum can never be
# earlier. If it is, the two aggregates disagree and the predicate is wrong.
if (v$bad_strict != 0) {
  stop(v$bad_strict, " rows have min_bach_year_strict < min_bach_year.")
}
# br_name and p_brazil must agree: flagged rows carry a value above the
# cut, unflagged rows carry none.
if (v$bad_null != 0 || v$bad_set != 0) {
  stop("br_name and p_brazil disagree: ", v$bad_null, " flagged rows with ",
       "NULL p_brazil, ", v$bad_set, " unflagged rows with a value.")
}
if (v$p_min_flagged <= p_cut) {
  stop("A flagged row has p_brazil ", v$p_min_flagged, " <= the cut of ", p_cut)
}
if (!is.na(exp_rows) && v$n_rows != exp_rows) {
  warning("Expected ", exp_rows, " rows, got ", v$n_rows)
}

cat("\nrows in the cohort            :", format(v$n_rows, big.mark = ","), "\n")
cat(sprintf("  A: name p_brazil > %.2f     : %s\n",
            p_cut, format(v$n_br_name, big.mark = ",")))
cat("  (stored, not filtered) B: university_country:",
    format(v$n_br_educ_country, big.mark = ","), "\n")
cat("  (stored, not filtered) C_norm: institution name:",
    format(v$n_br_openalex_norm, big.mark = ","), "\n")
cat("  admitted only by the degree_raw fix        :",
    format(v$n_new_by_degree_fix, big.mark = ","), "\n")
cat("  (stored, not filtered) worked in Brazil:",
    format(v$n_br_position, big.mark = ","), "\n")
# Note 2: a member of this cohort has no observed Brazil signal at
# all unless one of the stored education or position flags fires.
# How far that group shrinks is the honest measure of what the
# widened institution match adds as EVIDENCE, as opposed to what
# it adds as membership in the sibling cohort.
# EVIDENCE, as opposed to what it adds as membership.
cat("  NO corroboration at all (name prior only):",
    format(v$n_no_corroboration, big.mark = ","),
    sprintf("(%.1f%%)\n", 100 * as.numeric(v$n_no_corroboration) /
                          as.numeric(v$n_rows)))

print(dbGetQuery(con, sprintf("SELECT * FROM %s.%s LIMIT 10",
                              athena_schema, athena_table)))
cat("[OK] all validations passed\n\n")

####################################################################
### Step 6: bring the result back to Dropbox
####################################################################

# arrow reads the whole prefix: UNLOAD writes several files.
cat("=========== LOCAL COPY ===========\n")
if (!arrow::arrow_with_s3()) {
  stop("This arrow build has no S3 support. Download the files from ",
       s3_path, " with the AWS CLI and read them from disk, or reinstall ",
       "arrow with S3 enabled.")
}
ds <- arrow::open_dataset(s3_path, format = "parquet")
# write_parquet does not take a Dataset: materialize a Table first.
# Eight narrow columns, so it fits in memory even with tens of millions
# of rows.
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
cat(sprintf("  criterion A   : name prior p_brazil > %.2f\n", p_cut))
cat("  cutoff        : first position and first Bachelor >=",
    min_year, "\n")
