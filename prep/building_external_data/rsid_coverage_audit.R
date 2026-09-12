####################################################################
###
### Coverage audit of C_norm_rsid against C and C_norm -> S3 + Athena
###
### Answers one question: of the university_raw that criteria C and
### C_norm left uncovered, how much does the gated rsid propagation
### now cover, and how much of the rest is still out of reach.
###
### Every education row is classified into six buckets:
###
###   1 C exact        the string matches criterion C
###   2 C_norm only    the string matches C_norm but not C
###   3 NEW rsid arm   NO string match, but its rsid SURVIVED the gate
###   4 rejected       NO string match, rsid matched but was rejected
###   5 never matched  NO string match, no string under that rsid ever
###                    matched anything
###   6 no rsid        NO string match, and rsid IS NULL
###
### Buckets 1-2 are what the string match already covered. Bucket 3 is
### the gain. Buckets 4-6 are the residual, and they are the to-do
### list: 4 is what the gate deliberately threw away, 5 is what a
### better institution list would have to reach, 6 is what no
### school-key criterion can ever reach.
###
### Output grain: coarse (one row per bucket, with exact distinct-user
### counts) AND fine (one row per bucket x rsid x university_raw, for
### buckets 3-6 only), in one table, distinguished by `lvl`. See
### note 4.
###
### Depends on:
###   prep/building_external_data/openalex_institutions_br_to_s3.R
###   prep/building_external_data/rsid_br_user_share.R
###
### Athena read/UNLOAD pattern reused from:
###   prep/building_external_data/rsid_br_user_share.R
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. Reading Athena and writing S3 is the whole point. It
###    is a local prep/ script and must not be sent to SEDAP.
### 2. THE MATCHER IS RE-RUN HERE, not looked up. inst_fold /
###    inst_exact / raws / seg / raw_cls are copied verbatim from
###    rsid_br_user_share.R, so m_exact is criterion C and m_norm is
###    C_norm exactly as the cohort defines them.
###
###    The cheaper alternative -- treating "matches C_norm" as
###    "appears in rsid_br_user_share" -- was REJECTED. That table only
###    holds pairs with a non-null rsid, so a C_norm-matching string
###    occurring only on NULL-rsid rows would be absent from it and
###    would be misclassified into bucket 6, inflating the "unreachable"
###    residual by an unmeasured amount. Re-running the matcher is what
###    makes bucket 6 mean what it says.
### 3. THE CASE ORDER IS LOAD-BEARING, twice over.
###    - exact before norm, because C is a subset of C_norm and the
###      buckets are meant to be disjoint;
###    - `rsid IS NULL` BEFORE the two rsid-membership tests. A NULL
###      rsid joins to nothing, so without an explicit arm it would
###      fall through to bucket 5 and be reported as "no string under
###      that school ever matched" when the truth is "there is no
###      school key at all". Those are different findings with
###      different fixes.
### 4. ONE PASS, VIA GROUPING SETS. The coarse and fine grains come
###    from GROUP BY GROUPING SETS ((bucket), (bucket, rsid,
###    university_raw)) in a single scan. `lvl` is grouping(rsid,
###    university_raw) and is what distinguishes them: education rows
###    with a NULL university_raw are real, so a NULL in that column
###    cannot be used to identify a coarse row.
###
###    The coarse rows carry the exact count(DISTINCT user_id) per
###    bucket. That CANNOT be recovered by summing the fine grain: a
###    user holds several education rows and can appear under many
###    (rsid, university_raw) pairs, so the fine counts overlap.
###    Rows and distinct strings do aggregate cleanly from the fine
###    grain; users do not. Do not "simplify" the coarse level away.
### 5. The fine grain is restricted to buckets 3-6 on purpose. Buckets
###    1-2 at pair grain are already published as
###    revelio_database.rsid_br_user_share; repeating them here would
###    double the output for nothing.
### 6. STORED WHOLE, NOT FILTERED. Same reasoning as the position-rcid
###    extract: filtering in Athena would scan identical bytes for
###    identical money, and the next coverage question would pay again.
###    Stored whole, every later question is offline and free.
### 7. Cost: two passes over the education table -- one for `raws`
###    (university_raw only) and one for the classification (rsid,
###    university_raw, user_id) -- plus the tiny institutions and gate
###    tables.
###
###    MEASURED 2026-09-04: 63.88 GB scanned (~$0.32) in 29.3 s, plus
###    ~5.6 GB (~$0.03) of diagnostic queries against the finished
###    table. That came in on the pre-run estimate, unlike
###    rsid_br_user_share.R which ran 1.7x over its own.
###
### 9. BUCKET 3 INCLUDES ROWS WITH NO university_raw AT ALL, and they
###    must be taken out before the gain is quoted. A row whose
###    university_raw is NULL cannot match any string, so it falls past
###    the two match arms and lands in bucket 3 whenever its school
###    survived -- but it is not "a previously uncovered string", there
###    is no string. Measured: 55,701 such rows in bucket 3.
###
###    This is not cosmetic. Folding them in was the first version's
###    definitional error, and the exp_bucket3_rows cross-check is what
###    caught it: bucket 3 came out 55,701 rows above the offline
###    subtraction, which had required university_raw IS NOT NULL.
###    bucket3 - null_rows reconciles to 11,679,832 exactly. Every
###    figure Step 5 reports is on str_rows for this reason.
### 10. THE "% OF PREVIOUSLY UNCOVERED" RATIO IS 1.9% AND MUST NEVER BE
###    QUOTED ALONE. Its denominator is buckets 4+5+6 = 595 million
###    rows, of which bucket 5 is 61.3% and bucket 6 is 27.0% -- the
###    education records of the rest of the world, schools that no
###    Brazilian institution name reaches and rows with no school key.
###    No Brazilian criterion should cover them, so the ratio measures
###    the size of the planet, not a failure of the criterion.
###
###    The figures that mean something: total coverage 1.80x on
###    string-bearing rows, 213,365 distinct university_raw newly
###    covered against 22,566 the string match reached (9.5x), and
###    54.2% -> 100% within the 667 schools the criterion reaches.
### 11. This script does NOT decide which openalex_id a newly covered
###    string belongs to. That is script 8d's dom_openalex_id, and it
###    must be read together with 8d's dom_share -- note 9 there
###    records why, and why an automatic name-plausibility rule was
###    tried and rejected. Step 6 here joins the two and reports the
###    concentration bands; it does not attribute ids row by row.
###
####################################################################

rm(list = ls()); gc()

options(width = 200)

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

coh_dir  <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
out_path <- file.path(coh_dir, "rsid_coverage_audit.parquet")
xw_path  <- file.path(coh_dir, "rsid_openalex_id_crosswalk.parquet")
cls_path <- file.path(coh_dir, "rsid_dom_id_class.csv")

# The gate. MUST match br_share_min in rsid_br_user_share.R and
# revelio_br_cohort_user_ids_alt.R.
br_share_min <- 0.5

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
s3_prefix <- "exports/rsid_coverage_audit"
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")

athena_schema <- "revelio_database"
athena_table  <- "rsid_coverage_audit"

inst_table  <- "openalex_institutions_br"
educ_table  <- "academic_individual_user_education"
share_table <- "rsid_br_user_share"

# Measured 2026-09-04: 6 coarse rows + 66,220,799 fine rows. The fine
# grain is dominated by bucket 6, which alone holds 61.5M distinct
# strings -- rows with no school key at all. That is why the local
# parquet is ~1.9 GB.
exp_rows <- 66220805

# THE cross-check, and it is not negotiable: bucket 3's row count is
# derivable offline from rsid_br_user_share alone, because that table
# carries n_rows per matched pair and rsid_n_rows for the whole school,
# so the newly covered rows are the difference. Computed 2026-09-04:
#
#   sum(rsid_n_rows) - sum(n_rows) over the 667 surviving schools
#     = 25,483,075 - 13,803,243 = 11,679,832
#
# Two independent routes to one number. A mismatch means either this
# query or the gate table is wrong, and nothing gets published until it
# is resolved.
exp_bucket3_rows <- 11679832

py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

dir.create(coh_dir, recursive = TRUE, showWarnings = FALSE)

####################################################################
### Step 1: build the query
####################################################################

# inst_fold / inst_exact / raws / seg / raw_cls are COPIED VERBATIM
# from rsid_br_user_share.R (note 2). Everything the original says
# about them still applies: the LEFT JOIN goes against distinct
# strings so it cannot multiply education rows, the UNNEST runs over
# distinct university_raw rather than every row, the whole-string arm
# reads inst_fold so a `company` record like Estacio still matches, the
# segment arm requires is_edu = 1, and length(trim(part)) >= 3 drops
# the fragments splitting produces.
#
# What is new is the bucket CASE (note 3) and the GROUPING SETS
# (note 4).
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
  FROM %s
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
),
kept AS (
  SELECT DISTINCT rsid FROM %s WHERE br_share_known > %.4f
),
matched AS (
  SELECT DISTINCT rsid FROM %s
),
tagged AS (
  SELECT CASE WHEN coalesce(c.m_exact, 0) = 1 THEN '1 C exact'
              WHEN coalesce(c.m_norm, 0)  = 1 THEN '2 C_norm only'
              WHEN e.rsid IS NULL             THEN '6 no rsid'
              WHEN k.rsid IS NOT NULL         THEN '3 NEW rsid arm'
              WHEN m.rsid IS NOT NULL         THEN '4 rejected school'
              ELSE '5 never matched' END AS bucket,
         e.rsid,
         e.university_raw,
         e.user_id
  FROM %s e
  LEFT JOIN raw_cls c ON e.university_raw = c.university_raw
  LEFT JOIN kept    k ON e.rsid = k.rsid
  LEFT JOIN matched m ON e.rsid = m.rsid
)
SELECT bucket,
       CAST(grouping(rsid, university_raw) AS integer) AS lvl,
       rsid,
       university_raw,
       count(*)                  AS n_rows,
       count(DISTINCT user_id)   AS n_users
FROM tagged
GROUP BY GROUPING SETS ((bucket), (bucket, rsid, university_raw))
HAVING grouping(rsid, university_raw) = 3
    OR bucket IN ('3 NEW rsid arm', '4 rejected school',
                  '5 never matched', '6 no rsid')",
  inst_table, inst_table, educ_table, share_table, br_share_min,
  share_table, educ_table)

unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')",
  select_sql, s3_path)

# lvl = 3 marks the coarse rows (both grouping columns aggregated
# away); lvl = 0 the fine ones. rsid is int in Revelio; count() is
# bigint in Trino.
ddl_txt <- sprintf(
"CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (
  bucket STRING,
  lvl INT,
  rsid INT,
  university_raw STRING,
  n_rows BIGINT,
  n_users BIGINT
)
STORED AS PARQUET
LOCATION '%s'", athena_schema, athena_table, s3_path)

cat("=========== GENERATED SQL ===========\n")
cat(unload_sql, "\n\n")
cat(ddl_txt, "\n\n")

####################################################################
### Step 2: check that the destination prefix is empty
####################################################################

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

pre <- dbGetQuery(con, sprintf("
  SELECT (SELECT count(*) FROM %s.%s) AS n_inst,
         (SELECT count(*) FROM %s.%s) AS n_share,
         (SELECT count(DISTINCT rsid) FROM %s.%s
           WHERE br_share_known > %.4f) AS n_keep",
  athena_schema, inst_table, athena_schema, share_table,
  athena_schema, share_table, br_share_min))
cat("BR institutions               :", format(pre$n_inst, big.mark = ","), "\n")
cat("gate table rows               :", format(pre$n_share, big.mark = ","), "\n")
cat("surviving rsids               :", format(pre$n_keep, big.mark = ","), "\n")
if (pre$n_inst == 0) stop("Table ", inst_table, " is empty.")
if (pre$n_share == 0) stop("Table ", share_table, " is empty. Run rsid_br_user_share.R first.")
if (pre$n_keep == 0) {
  stop("No rsid survives the gate: bucket 3 would be empty and the audit ",
       "would measure nothing.")
}

cat("\nRunning UNLOAD (two passes over the education table)...\n")
t0 <- Sys.time()
dbExecute(con, unload_sql)
cat("  finished in",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n\n")

cat(ddl_txt, "\n")
dbExecute(con, ddl_txt)

####################################################################
### Step 4: validation
####################################################################

cat("\n=========== VALIDATION ===========\n")
v <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_rows,
         sum(CASE WHEN lvl = 3 THEN 1 ELSE 0 END) AS n_coarse,
         sum(CASE WHEN lvl = 0 THEN 1 ELSE 0 END) AS n_fine,
         sum(CASE WHEN lvl NOT IN (0, 3) THEN 1 ELSE 0 END) AS bad_lvl,
         sum(CASE WHEN lvl = 3 AND (rsid IS NOT NULL
                                    OR university_raw IS NOT NULL)
                  THEN 1 ELSE 0 END) AS bad_coarse,
         sum(CASE WHEN lvl = 0 AND bucket IN ('1 C exact', '2 C_norm only')
                  THEN 1 ELSE 0 END) AS bad_fine_bucket
  FROM %s.%s", athena_schema, athena_table))
print(v)
if (v$bad_lvl != 0) stop(v$bad_lvl, " rows have an unexpected lvl.")
if (v$bad_coarse != 0) {
  stop(v$bad_coarse, " coarse rows carry a non-NULL key column.")
}
# Note 5: the fine grain is restricted to buckets 3-6 by the HAVING.
if (v$bad_fine_bucket != 0) {
  stop(v$bad_fine_bucket, " fine rows belong to bucket 1 or 2; the HAVING ",
       "clause is not doing what note 5 claims.")
}
if (v$n_coarse != 6) {
  warning("Expected 6 coarse rows, got ", v$n_coarse,
          " -- a bucket came out empty, which is worth understanding.")
}

cov <- dbGetQuery(con, sprintf("
  SELECT bucket, n_rows, n_users
  FROM %s.%s WHERE lvl = 3 ORDER BY bucket", athena_schema, athena_table))
cov$n_rows  <- as.numeric(as.character(cov$n_rows))
cov$n_users <- as.numeric(as.character(cov$n_users))

# THE cross-check (see exp_bucket3_rows above), and note 9: it is only
# valid after the NO-STRING rows come out of bucket 3, because the
# offline subtraction it is checked against was computed over rows with
# a non-null university_raw.
nostr <- dbGetQuery(con, sprintf("
  SELECT bucket,
         sum(CASE WHEN university_raw IS NULL THEN n_rows ELSE 0 END) AS null_rows,
         sum(CASE WHEN university_raw IS NOT NULL AND trim(university_raw) = ''
                  THEN n_rows ELSE 0 END) AS blank_rows
  FROM %s.%s WHERE lvl = 0 GROUP BY bucket", athena_schema, athena_table))
nostr$null_rows  <- as.numeric(as.character(nostr$null_rows))
nostr$blank_rows <- as.numeric(as.character(nostr$blank_rows))

b3     <- cov$n_rows[cov$bucket == "3 NEW rsid arm"]
b3null <- nostr$null_rows[nostr$bucket == "3 NEW rsid arm"]
if (length(b3) != 1 || (b3 - b3null) != exp_bucket3_rows) {
  stop("Bucket 3 has ", format(b3, big.mark = ","), " rows, of which ",
       format(b3null, big.mark = ","), " carry a NULL university_raw, leaving ",
       format(b3 - b3null, big.mark = ","), " -- but rsid_br_user_share implies ",
       format(exp_bucket3_rows, big.mark = ","),
       ". Two independent routes disagree; resolve before publishing.")
}
cat("
[OK] bucket 3 =", format(b3, big.mark = ","), "rows, of which",
    format(b3null, big.mark = ","), "have no university_raw at all;
",
    "     the remaining", format(b3 - b3null, big.mark = ","),
    "match the offline subtraction from the gate table exactly
")

# Fine rows must reconcile with their own coarse row on rows and
# strings (not on users -- note 4).
rec <- dbGetQuery(con, sprintf("
  SELECT f.bucket, f.fine_rows, c.n_rows AS coarse_rows
  FROM (SELECT bucket, sum(n_rows) AS fine_rows FROM %s.%s
         WHERE lvl = 0 GROUP BY bucket) f
  JOIN (SELECT bucket, n_rows FROM %s.%s WHERE lvl = 3) c
    ON f.bucket = c.bucket
  WHERE f.fine_rows <> c.n_rows", athena_schema, athena_table,
  athena_schema, athena_table))
if (nrow(rec) != 0) {
  print(rec, row.names = FALSE)
  stop("Fine and coarse grains disagree on row counts for ", nrow(rec),
       " bucket(s).")
}
cat("[OK] fine grain reconciles with the coarse grain on rows\n")

if (!is.na(exp_rows) && v$n_rows != exp_rows) {
  warning("Expected ", exp_rows, " rows, got ", v$n_rows)
}
if (is.na(exp_rows)) {
  cat("\n[!] exp_rows is NA -- the drift check is DISABLED.\n",
      "    Fill in the measured value above.\n", sep = "")
}

####################################################################
### Step 5: the coverage table -- the answer
####################################################################

fine <- dbGetQuery(con, sprintf("
  SELECT bucket, count(DISTINCT university_raw) AS n_strings
  FROM %s.%s WHERE lvl = 0 GROUP BY bucket", athena_schema, athena_table))
s2 <- dbGetQuery(con, sprintf("
  SELECT count(DISTINCT university_raw) AS n
  FROM %s.%s WHERE m_norm = 1", athena_schema, share_table))

cov <- merge(cov, fine, by = "bucket", all.x = TRUE)
cov$pct_rows  <- 100 * cov$n_rows  / sum(cov$n_rows)
cov$pct_users <- 100 * cov$n_users / sum(cov$n_users)

cat("\n=========== COVERAGE OF university_raw, BY BUCKET ===========\n")
print(cov, right = FALSE, row.names = FALSE)
cat("\n  n_strings is blank for buckets 1-2: their pair grain lives in",
    share_table, "\n  (", format(s2$n, big.mark = ","),
    "distinct matched strings there).\n")

# Note 9: every figure below is on rows that HAVE a university_raw. A
# row with none is not an uncovered string, and folding it into the gain
# was the definitional error the cross-check above catches.
cov <- merge(cov, nostr, by = "bucket", all.x = TRUE)
cov$null_rows  <- ifelse(is.na(cov$null_rows), 0, cov$null_rows)
cov$blank_rows <- ifelse(is.na(cov$blank_rows), 0, cov$blank_rows)
cov$str_rows   <- cov$n_rows - cov$null_rows - cov$blank_rows

before <- sum(cov$str_rows[cov$bucket %in% c("1 C exact", "2 C_norm only")])
newly  <- cov$str_rows[cov$bucket == "3 NEW rsid arm"]
resid  <- sum(cov$str_rows[cov$bucket %in% c("4 rejected school",
                                             "5 never matched", "6 no rsid")])
cat("
--- the headline, on rows that have a university_raw ---
")
cat(sprintf("  covered by C / C_norm before : %15s rows
", format(before, big.mark = ",")))
cat(sprintf("  NEWLY covered by the rsid arm: %15s rows (total coverage %.2fx)
",
            format(newly, big.mark = ","), (before + newly) / before))
cat(sprintf("  still uncovered              : %15s rows
", format(resid, big.mark = ",")))

# Note 10: the raw ratio, and why it must never be quoted on its own.
cat(sprintf("
  newly covered / all previously uncovered = %.1f%%
",
            100 * newly / (newly + resid)))
cat("  *** THAT DENOMINATOR IS NOT A COVERAGE FAILURE. *** Buckets 5 and 6
",
    "  are the education records of the rest of the world: schools no
",
    "  Brazilian institution name reaches, and rows with no school key at
",
    "  all. No Brazilian criterion should cover them. The meaningful
",
    "  figures are the within-reach one and the distinct-string count.
", sep = "")
cat(sprintf("
  the gate's deliberate cost: %s rows under the rejected
",
            format(cov$str_rows[cov$bucket == "4 rejected school"], big.mark = ",")))
cat("  schools were reachable and were thrown away -- correctly, since
",
    "  those schools run 0.34% Brazilian by user location.
", sep = "")

cat("\n=========== TOP 50 NEWLY COVERED STRINGS ===========\n")
print(dbGetQuery(con, sprintf("
  SELECT rsid, university_raw, n_rows, n_users
  FROM %s.%s WHERE lvl = 0 AND bucket = '3 NEW rsid arm'
  ORDER BY n_rows DESC LIMIT 50", athena_schema, athena_table)),
  right = FALSE, row.names = FALSE)

####################################################################
### Step 6: how much of the gain carries a usable openalex_id
####################################################################

# Note 8: the id itself comes from 8d, and dom_share is what says
# whether it can be trusted. This only aggregates.
if (!file.exists(xw_path)) {
  cat("\n[!] ", basename(xw_path), " is missing; skipping the id report.\n",
      "    Run rsid_openalex_id_crosswalk.R to get it.\n", sep = "")
} else {
  xw <- as.data.frame(arrow::read_parquet(xw_path))
  xw <- unique(xw[xw$keep == 1, c("rsid", "university_name",
                                  "dom_openalex_id", "dom_share", "n_ids_rsid")])
  b3f <- dbGetQuery(con, sprintf("
    SELECT rsid, sum(n_rows) AS new_rows, sum(n_users) AS new_users
    FROM %s.%s WHERE lvl = 0 AND bucket = '3 NEW rsid arm'
    GROUP BY rsid", athena_schema, athena_table))
  b3f$new_rows <- as.numeric(as.character(b3f$new_rows))
  m <- merge(b3f, xw, by = "rsid", all.x = TRUE)
  if (any(is.na(m$dom_openalex_id))) {
    stop(sum(is.na(m$dom_openalex_id)), " bucket-3 schools are absent from ",
         basename(xw_path), ". Every surviving rsid is in it by ",
         "construction, so the join keys are wrong.")
  }
  m$band <- ifelse(m$dom_share >= 0.99, "a  >= 99%",
            ifelse(m$dom_share >= 0.90, "b  90-99%",
            ifelse(m$dom_share >= 0.75, "c  75-90%",
            ifelse(m$dom_share >= 0.50, "d  50-75%", "e  < 50%  HAND REVIEW"))))
  agg <- aggregate(cbind(new_rows = new_rows) ~ band, m, sum)
  agg$n_schools <- as.integer(table(m$band)[agg$band])
  agg$pct <- 100 * agg$new_rows / sum(agg$new_rows)
  cat("\n=========== NEWLY COVERED ROWS BY dom_share BAND ===========\n")
  print(agg[order(agg$band), c("band", "n_schools", "new_rows", "pct")],
        right = FALSE, row.names = FALSE)
  cat(sprintf("\n  weighted mean dom_share: %.1f%%\n",
              100 * sum(m$dom_share * m$new_rows) / sum(m$new_rows)))
  cat("  Band e is where dom_openalex_id must not be taken at face value.\n")

  # The hand-review template, keyed to the low-concentration schools.
  # Convention of c_norm_coverage_audit.R and shanghai_flag_audit.R: an
  # ordinary editable CSV, written once and never overwritten.
  low <- m[m$dom_share < 0.50, ]
  low <- low[order(-low$new_rows), ]
  if (!file.exists(cls_path)) {
    tpl <- low[, c("rsid", "university_name", "n_ids_rsid", "dom_share",
                   "dom_openalex_id", "new_rows")]
    tpl$verdict <- ""
    tpl$note <- ""
    write.csv(tpl, cls_path, row.names = FALSE, fileEncoding = "UTF-8")
    cat("\n[!] wrote an EMPTY hand-review template with ", nrow(tpl),
        " rows:\n  ", cls_path, "\n",
        "    Fill `verdict` per school: OK (the dominant id is right),\n",
        "    FAMILY (the rsid pools several institutions, no single id\n",
        "    applies) or WRONG (the dominant id is a contaminant).\n",
        "    Nothing downstream consumes it yet; it is the record of the\n",
        "    only judgement this audit cannot make automatically.\n", sep = "")
  } else {
    cat("\n  hand-review file exists:", cls_path, "\n")
  }
}

print(dbGetQuery(con, sprintf("SELECT * FROM %s.%s WHERE lvl = 3 ORDER BY bucket",
                              athena_schema, athena_table)))

####################################################################
### Step 7: local copy
####################################################################

cat("\n=========== LOCAL COPY ===========\n")
if (!arrow::arrow_with_s3()) {
  stop("This arrow build has no S3 support. Download from ", s3_path,
       " with the AWS CLI instead.")
}
ds <- arrow::open_dataset(s3_path, format = "parquet")
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
cat("  rows          :", format(v$n_rows, big.mark = ","),
    sprintf("(%d coarse + %s fine)\n", v$n_coarse,
            format(v$n_fine, big.mark = ",")))
cat("  gate          : br_share_known >", br_share_min, "\n")
