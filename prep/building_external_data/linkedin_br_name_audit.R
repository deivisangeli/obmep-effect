####################################################################
###
### Audit of the p_brazil > 0.5 name cut
###
### Draws a reproducible random sample of 500 PROFILES whose first
### name scores p_brazil > 0.5, joins a manual classification of the
### distinct names, and reports how many are suspect.
###
### Reads the per-profile output of
### prep/building_external_data/linkedin_br_name_flag.R -- the only
### place the names survive. linkedin_br_name_flag.parquet and the
### Athena table carry user_id + p_brazil ONLY, no names.
###
### Classification, assigned by hand and stored as data in
### name_audit_classification.csv so it can be inspected and overridden
### without touching this script:
###
###   1 clearly Brazilian-Portuguese, including Brazilian-specific
###     spellings and inventions (Wanderson, Kethellyn, Jeferson)
###   2 international / low Brazil-specificity: a real given name
###     equally at home in Spanish, Italian or English, or a global
###     biblical/classical name (Maria, Jose, Ana, Antonio)
###   3 not a personal name at all (company, word, initial, emoji)
###   4 clearly non-Brazilian (Anglo, Slavic, Asian, Arabic)
###
### SUSPECT = 3 + 4. Class 2 is reported separately: it is weak
### evidence, not an error, and merging the two would overstate the
### failure rate.
###
### -----------------------------------------------------------------
### ATTENTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script is OFFLINE, unlike its siblings in this folder. It
###    touches no network, no S3 and no Athena -- everything it needs
###    is local parquet under the OBMEP Dropbox.
### 2. The sample is PROFILE-WEIGHTED, drawn from the 39,450,441
###    profiles above the cut, so each name appears in proportion to
###    how often it actually occurs. It answers "what share of the
###    cohort is questionable". It says almost NOTHING about the tail
###    of the name list: only 31,502 distinct names clear 0.5, and a
###    name carried by 12 profiles has roughly one in three million the
###    chance of appearing that one carried by 40 million does. To
###    audit the name list instead, sample from
###    firstname_matches.parquet at the distinct-name level.
### 3. USING SAMPLE is deliberately NOT used. DuckDB pushed it BELOW
###    the p_brazil filter -- sampling 500 rows out of all 708M
###    profiles and only then filtering, which returned 23 rows (500 x
###    the 5.6% pass rate) instead of 500. Ordering by hash(user_id)
###    and taking the top N is a top-N over the FILTERED set and cannot
###    be reordered that way. It is deterministic rather than PRNG,
###    which is what makes it reproducible, and user_id is unrelated to
###    the name being audited, so it is effectively random with respect
###    to the measurement.
### 4. The sample file is NOT redrawn if it already exists. The stored
###    classification is keyed to this exact sample and must not drift
###    underneath it. Delete the parquet to force a redraw, and expect
###    to reclassify.
### 5. Brazilian and Portuguese given names overlap almost completely,
###    so a lusophone-but-not-Brazilian profile is largely undetectable
###    from a first name. This measures OBVIOUS failure, not national
###    precision.
###
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb")) {
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

flag_dir    <- file.path(obmep_root, "Data/intermediate/linkedin_br_flags")
prof_glob   <- file.path(flag_dir, "profiles/chunk_*.parquet")
sample_path <- file.path(flag_dir, "name_audit_sample.parquet")
class_path  <- file.path(flag_dir, "name_audit_classification.csv")
out_path    <- file.path(flag_dir, "name_audit_classified.parquet")

seed     <- 20260824
n_sample <- 500
p_cut    <- 0.5

# Measured in linkedin_br_flag_to_s3.R.
exp_pop <- 39450441

stopifnot(dir.exists(flag_dir))

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_name_audit")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
invisible(dbExecute(con, "PRAGMA memory_limit='8GB'"))
invisible(dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir)))

####################################################################
### Step 1: draw the sample (seeded, idempotent)
####################################################################

sample_sql <- sprintf("
  SELECT user_id, first_name_clean, p_brazil, match_level, ibge_freq
  FROM read_parquet('%s')
  WHERE p_brazil > %.4f AND first_name_clean IS NOT NULL
  ORDER BY hash(user_id + %d)
  LIMIT %d", prof_glob, p_cut, seed, n_sample)

if (file.exists(sample_path)) {
  cat("[skip] sample already exists:", sample_path, "\n")
} else {
  cat("Drawing", n_sample, "profiles with p_brazil >", p_cut, "...\n")
  t0 <- Sys.time()
  invisible(dbExecute(con, sprintf(
    "COPY (%s) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    sample_sql, sample_path)))
  cat("  done in",
      round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
}

s <- dbGetQuery(con, sprintf("SELECT * FROM read_parquet('%s')", sample_path))

cat("\n=========== SAMPLE VALIDATION ===========\n")
if (nrow(s) != n_sample) stop("Sample has ", nrow(s), " rows, expected ", n_sample)
if (anyDuplicated(s$user_id) != 0) stop("Duplicate user_id in the sample.")
if (min(s$p_brazil) <= p_cut) {
  stop("A sampled row has p_brazil ", min(s$p_brazil), " <= the cut of ", p_cut)
}

# A seed that is not actually reproducible is worse than no seed: the
# stored classification would silently stop matching the sample.
s2 <- dbGetQuery(con, sample_sql)
if (!identical(sort(as.character(s$user_id)), sort(as.character(s2$user_id)))) {
  stop("Re-running the seeded query returned a DIFFERENT sample.")
}
cat("[OK] 500 rows, unique user_id, all above the cut, seed reproducible\n")

pop <- dbGetQuery(con, sprintf(
  "SELECT count(*) AS n FROM read_parquet('%s') WHERE p_brazil > %.4f",
  prof_glob, p_cut))
pop_n <- as.numeric(as.character(pop$n))
cat("population sampled from      :",
    format(pop_n, big.mark = ",", scientific = FALSE), "\n")
if (pop_n != exp_pop) {
  warning("Population is ", pop_n, ", expected ", exp_pop)
}

####################################################################
### Step 2: join the manual classification
####################################################################

stopifnot(file.exists(class_path))
cl <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8")

cat("\n=========== CLASSIFICATION VALIDATION ===========\n")
if (anyDuplicated(cl$first_name_clean) != 0) {
  stop("Duplicate names in ", basename(class_path))
}
if (!all(cl$class %in% 1:4)) {
  stop("Class values outside 1:4: ",
       paste(sort(unique(cl$class[!cl$class %in% 1:4])), collapse = ", "))
}
# A name missing a classification would drop out of the counts and
# silently understate the suspect rate, so this is a stop().
miss <- setdiff(unique(s$first_name_clean), cl$first_name_clean)
if (length(miss)) {
  stop(length(miss), " sampled name(s) have no classification: ",
       paste(head(miss, 20), collapse = ", "))
}
cat("[OK]", nrow(cl), "names classified, one row each, all in 1:4\n")

s <- merge(s, cl, by = "first_name_clean", all.x = TRUE)
stopifnot(nrow(s) == n_sample)

lab <- c("1 clearly Brazilian-Portuguese",
         "2 international / low BR-specificity",
         "3 not a personal name",
         "4 clearly non-Brazilian")

####################################################################
### Step 3: report
####################################################################

cat("\n=========== RESULT, PROFILE-WEIGHTED (n =", n_sample, ") ===========\n")
prof <- table(factor(s$class, levels = 1:4))
for (k in 1:4) {
  cat(sprintf("  %-38s %4d  %5.1f%%\n", lab[k], prof[k],
              100 * prof[k] / n_sample))
}

suspect <- sum(prof[3:4])
ci <- if (suspect == 0) {
  c(0, 1 - 0.05^(1 / n_sample))            # one-sided rule-of-three style bound
} else {
  as.numeric(binom.test(suspect, n_sample)$conf.int)
}
cat(sprintf("\n  SUSPECT (3 + 4)                        %4d  %5.1f%%\n",
            suspect, 100 * suspect / n_sample))
cat(sprintf("  95%% CI                                 [%.2f%%, %.2f%%]\n",
            100 * ci[1], 100 * ci[2]))

cat("\n=========== SAME SAMPLE, DISTINCT NAMES (n =",
    length(unique(s$first_name_clean)), ") ===========\n")
uq <- unique(s[, c("first_name_clean", "class")])
nmt <- table(factor(uq$class, levels = 1:4))
for (k in 1:4) {
  cat(sprintf("  %-38s %4d  %5.1f%%\n", lab[k], nmt[k],
              100 * nmt[k] / nrow(uq)))
}

# Not an assertion: a strong inversion here would suggest the manual
# classification is off rather than that the data is wrong. Class 1
# names should skew to higher IBGE frequency than class 3/4.
cat("\n=========== ibge_freq BY CLASS (sanity, not a test) ===========\n")
print(aggregate(ibge_freq ~ class, data = s,
                FUN = function(x) c(n = length(x),
                                    median = median(x, na.rm = TRUE))))

####################################################################
### Step 4: write the classified sample
####################################################################

dbWriteTable(con, "classified", s, overwrite = TRUE)
invisible(dbExecute(con, sprintf(
  "COPY classified TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", out_path)))

cat("\n=========== SUMMARY ===========\n")
cat("  sample        :", sample_path, "\n")
cat("  classification:", class_path, "\n")
cat("  classified    :", out_path, "\n")
cat("  suspect rate  :", sprintf("%d / %d (%.1f%%)", suspect, n_sample,
                                 100 * suspect / n_sample), "\n")
