####################################################################
###
### Full-name check on the US slice of the name-only candidates
###
### name_only_country_check.R found that only 0.6% of the 1,115,460
### name-only candidates have user_country = 'Brazil', against 96.4%
### for the corroborated group. The largest single destination was
### United States, 238,986 users (21.4%).
###
### That number is ambiguous where the others are not: a Brazilian who
### emigrated to the US shows user_country = 'United States' while
### being genuinely Brazilian -- the one case where name-only
### membership is CORRECT rather than contamination. First names
### cannot separate that from a Hispanic-American profile, because
### Maria / Jose / Ana are shared across the whole Iberian world.
### SURNAMES can, above all through the -es / -ez split:
###
###   Portuguese  Fernandes Rodrigues Goncalves Martins Nunes Lopes
###   Spanish     Fernandez Rodriguez Gonzalez  Martinez Nunez Lopez
###
### This draws 50 US name-only profiles and reads their full names,
### against a calibration set of 50 corroborated Brazilians located in
### Brazil, classified by the same rubric.
###
### Depends on:
###   prep/building_external_data/obmep_candidates_step_1.R
###   prep/building_external_data/name_only_country_check.R
###
### -----------------------------------------------------------------
### THIS SCRIPT DESCRIBES AN EARLIER VERSION OF THE TABLE
### -----------------------------------------------------------------
### It was run against obmep_candidates_step_1 as it stood under the
### exact-match criterion C, before C_norm widened it on 2026-08-25 --
### 6,845,775 rows with
### 1,115,460 name-only members. That table now has 6,849,674 rows
### and 1,113,654 name-only members: the widened institution match
### C_norm corroborates only 1,806 of the group this script sampled,
### so the findings below still describe it accurately.
###
### It was deliberately NOT re-run. The 100 surname classifications in
### name_only_us_fullname_class.csv are keyed to specific sampled
### user_ids, and note 7 below refuses to redraw for exactly that
### reason: re-running would fail the sample-reproduction assertion
### rather than drift silently, which is the correct behaviour. The
### findings below stand as a record of that name-only group.
### To redo it, delete the sample parquet and expect to reclassify all
### 100 by hand.
###
### -----------------------------------------------------------------
### ATTENTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. That is a deliberate exception: reading from Athena
###    is the whole point. It is a local prep/ script and must not be
###    sent to the offline SEDAP environment.
### 2. The calibration group B is what makes group A readable. Without
###    it "3 of 50 look Portuguese" says nothing, because the
###    false-negative rate of surname classification on real Brazilians
###    is unknown. Measured here: 66% of known Brazilians are
###    Portuguese-marked, so 66% is the ceiling, not 100%.
### 3. A NON-Iberian surname does NOT rule out Brazilian. Group B
###    contains Kim, Komazaki, Muller, Griebler, Feilstrecker,
###    Spilmann, Tonet, Trisch -- Brazil's Japanese, Korean, German
###    and Italian communities are large and their descendants are
###    fully Brazilian. 16% of the calibration set is non-Iberian.
### 4. P in group A is CONSISTENT WITH Brazilian, not proof. Portuguese
###    and Brazilian surnames are largely identical, so a
###    Portuguese-American profile also lands in P. This narrows the
###    question rather than closing it.
### 5. USING SAMPLE is deliberately avoided. In linkedin_br_name_audit.R
###    DuckDB pushed it BELOW the filter and returned 23 rows instead
###    of 500. A hash-ordered row_number() inside the partition is a
###    top-N over the FILTERED set and cannot be reordered that way.
### 6. Trino has no hash(). It is xxhash64(to_utf8(...)) here, whereas
###    the DuckDB-side scripts in this folder use hash(). Do not copy
###    one into the other.
### 7. The sample is NOT redrawn if it already exists. The stored
###    classification is keyed to these exact user_ids and must not
###    drift underneath. Delete the parquet to force a redraw, and
###    expect to reclassify.
###
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "RAthena", "arrow")) {
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

out_dir     <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
sample_path <- file.path(out_dir, "name_only_us_fullname_sample.parquet")
class_path  <- file.path(out_dir, "name_only_us_fullname_class.csv")

seed <- 20260824
n    <- 50

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"

athena_schema <- "revelio_database"
cand_table    <- "obmep_candidates_step_1"
user_table    <- "academic_individual_user"

py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

####################################################################
### Step 1: draw both samples in one scan
####################################################################

sample_sql <- sprintf("
SELECT grp, user_id, fullname, user_country, p_brazil, rn
FROM (
  SELECT grp, user_id, fullname, user_country, p_brazil,
         row_number() OVER (PARTITION BY grp
                            ORDER BY xxhash64(to_utf8(cast(user_id + %d AS varchar)))) AS rn
  FROM (
    SELECT CASE
             WHEN s.in_name_cohort = 1 AND s.in_country_cohort = 0
                  AND u.user_country = 'United States'  THEN 'A_us_name_only'
             WHEN s.in_name_cohort = 1 AND s.in_country_cohort = 1
                  AND u.user_country = 'Brazil'         THEN 'B_both_brazil'
           END AS grp,
           s.user_id, u.fullname, u.user_country, s.p_brazil
    FROM %s.%s s
    LEFT JOIN %s.%s u ON s.user_id = u.user_id
    WHERE u.fullname IS NOT NULL
  ) y
  WHERE grp IS NOT NULL
) x
WHERE rn <= %d
ORDER BY grp, rn",
  seed, athena_schema, cand_table, athena_schema, user_table, n)

if (file.exists(sample_path)) {
  cat("[skip] sample already exists:", sample_path, "\n")
  smp <- as.data.frame(arrow::read_parquet(sample_path))
} else {
  cat("=========== QUERY ===========\n")
  cat(sample_sql, "\n\n")
  con <- dbConnect(RAthena::athena(),
                   s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                   region_name    = s3_region,
                   schema_name    = athena_schema)
  on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

  cat("Running (one scan of ", user_table, ", incl. the fullname column)...\n",
      sep = "")
  t0 <- Sys.time()
  smp <- dbGetQuery(con, sample_sql)
  cat("  finished in",
      round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")

  # A seed that does not reproduce is worse than none: the stored
  # classification would silently stop matching the sample.
  s2 <- dbGetQuery(con, sample_sql)
  if (!identical(sort(as.character(smp$user_id)), sort(as.character(s2$user_id)))) {
    stop("Re-running the seeded query returned a DIFFERENT sample.")
  }
  cat("[OK] seed reproducible\n")
  arrow::write_parquet(smp, sample_path, compression = "snappy")
}

smp$rn      <- as.integer(as.character(smp$rn))
smp$user_id <- as.character(smp$user_id)

####################################################################
### Step 2: validation
####################################################################

cat("\n=========== SAMPLE VALIDATION ===========\n")
tb <- table(smp$grp)
if (!identical(sort(names(tb)), c("A_us_name_only", "B_both_brazil"))) {
  stop("Unexpected groups: ", paste(names(tb), collapse = ", "))
}
if (any(tb != n)) stop("Group sizes are ", paste(tb, collapse = "/"),
                       ", expected ", n, " each")
if (anyDuplicated(smp$user_id) != 0) stop("Duplicate user_id across the samples.")

# A mistake in the CASE would quietly sample the wrong population, so
# the group definitions are re-asserted from the returned rows.
a <- smp[smp$grp == "A_us_name_only", ]
b <- smp[smp$grp == "B_both_brazil", ]
if (!all(a$user_country == "United States")) stop("Group A is not all US.")
if (!all(b$user_country == "Brazil")) stop("Group B is not all Brazil.")
cat("[OK]", n, "rows per group, unique user_id, group definitions hold\n")

####################################################################
### Step 3: join the manual classification
####################################################################

stopifnot(file.exists(class_path))
cl <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
               colClasses = c(user_id = "character"))

cat("\n=========== CLASSIFICATION VALIDATION ===========\n")
if (anyDuplicated(cl$user_id) != 0) stop("Duplicate user_id in ", basename(class_path))
if (!all(cl$class %in% c("P", "S", "I", "N"))) {
  stop("Class values outside P/S/I/N: ",
       paste(sort(unique(cl$class[!cl$class %in% c("P","S","I","N")])), collapse = ", "))
}
miss <- setdiff(smp$user_id, cl$user_id)
if (length(miss)) stop(length(miss), " sampled user_id(s) unclassified.")
cat("[OK]", nrow(cl), "classified, one row each, all in P/S/I/N\n")

smp <- merge(smp, cl[, c("user_id", "class")], by = "user_id", all.x = TRUE)
stopifnot(nrow(smp) == 2 * n)

####################################################################
### Step 4: report
####################################################################

lab <- c(P = "P  Portuguese-marked surname",
         S = "S  Spanish-marked surname",
         I = "I  ambiguous Iberian / no surname",
         N = "N  non-Iberian")

cat("\n=========== SURNAME CLASSIFICATION ===========\n")
cat(sprintf("  %-34s %18s %18s\n", "",
            "A: US name-only", "B: known Brazilian"))
for (k in c("P", "S", "I", "N")) {
  na <- sum(smp$class == k & smp$grp == "A_us_name_only")
  nb <- sum(smp$class == k & smp$grp == "B_both_brazil")
  cat(sprintf("  %-34s %8d %8.0f%% %8d %8.0f%%\n", lab[[k]],
              na, 100 * na / n, nb, 100 * nb / n))
}

pa <- sum(smp$class == "P" & smp$grp == "A_us_name_only") / n
pb <- sum(smp$class == "P" & smp$grp == "B_both_brazil") / n
cat(sprintf("\n  Portuguese-marked rate, A / B          %.0f%% / %.0f%%\n",
            100 * pa, 100 * pb))
cat(sprintf("  implied Brazilian share of A (pa / pb)  %.0f%%\n", 100 * pa / pb))
cat("  (crude: it assumes surname marking is equally detectable in both\n")
cat("   groups, and it cannot separate Brazilian from Portuguese.)\n")

cat("\n=========== GROUP A, ALL 50 ===========\n")
a <- smp[smp$grp == "A_us_name_only", ]
a <- a[order(a$rn), ]
for (i in seq_len(nrow(a))) {
  cat(sprintf("  %s  %2d  %-40s p=%.3f\n", a$class[i], a$rn[i],
              substr(a$fullname[i], 1, 40), a$p_brazil[i]))
}

cat("\n=========== GROUP B, ALL 50 (calibration) ===========\n")
b <- smp[smp$grp == "B_both_brazil", ]
b <- b[order(b$rn), ]
for (i in seq_len(nrow(b))) {
  cat(sprintf("  %s  %2d  %-40s p=%.3f\n", b$class[i], b$rn[i],
              substr(b$fullname[i], 1, 40), b$p_brazil[i]))
}

cat("\n=========== SUMMARY ===========\n")
cat("  sample        :", sample_path, "\n")
cat("  classification:", class_path, "\n")
cat(sprintf("  verdict       : %d of %d US name-only profiles carry a\n",
            sum(smp$class == "P" & smp$grp == "A_us_name_only"), n))
cat("                  Portuguese-marked surname, against",
    sum(smp$class == "P" & smp$grp == "B_both_brazil"), "of", n, "\n")
cat("                  for known Brazilians.\n")
