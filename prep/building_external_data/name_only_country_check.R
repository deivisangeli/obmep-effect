####################################################################
###
### user_country check on the name-only candidates
###
### Of the 6,849,674 rows in obmep_candidates_step_1, 1,113,654 got in
### on the NAME PRIOR ALONE: they are in obmep_br_name_cohort_user_ids
### (p_brazil > 0.5) but absent from obmep_br_cohort_user_ids, meaning
### no Brazilian job, no Brazilian university, no matched rsid and no
### OpenAlex Brazilian institution match. Their only evidence of being
### Brazilian is a first name.
###
### RE-RUN 2026-08-25 against the tables built under (A OR B OR
### C_norm). The name-only group is 1,113,654, essentially unmoved
### from the 1,115,460 measured under the exact-match criterion, so
### these figures are comparable to that run.
###
### Two intermediate builds used an rsid-propagation branch and are
### VOID: at match_share 0 it admitted 7,645,023 members on poisoned
### rsids and sent country_only to 27.3% Brazilian, and at 0.5 it
### added 12,023 at 6.3%. See revelio_br_cohort_user_ids.R note 11.
###
### academic_individual_user.user_country is a Brazil signal NEITHER
### cohort used, so it is an out-of-sample test of that group. This
### script reports how many of them have user_country = 'Brazil' and
### what their most common user_country values are, with the two
### corroborated groups as baselines.
###
### Depends on:
###   prep/building_external_data/obmep_candidates_step_1.R
###
### -----------------------------------------------------------------
### ATTENTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. This script REQUIRES INTERNET ACCESS, unlike the general rule in
###    AGENTS.md. That is a deliberate exception: reading from Athena
###    is the whole point. It is a local prep/ script and must not be
###    sent to the offline SEDAP environment.
### 2. user_country is NOT fully independent of the country cohort's
###    criterion A. Revelio derives it from profile location, which
###    correlates with where someone works. It IS new information --
###    these users have no Brazilian POSITION, so user_country =
###    'Brazil' here means the profile location says Brazil while no
###    job record does -- but a high Brazil share is reassuring rather
###    than conclusive. A LOW share would be strong evidence the
###    name-only group is contaminated.
### 3. LEFT JOIN, not inner: a candidate with no row in
###    academic_individual_user, or a NULL user_country, must surface
###    as '(missing)' rather than vanish. Dropping them would inflate
###    the Brazil share.
### 4. The three group totals are asserted against known values. That
###    doubles as the join-integrity check: if academic_individual_user
###    stopped being unique on user_id the LEFT JOIN would fan out and
###    the totals would exceed 6,845,775. This is free, whereas a
###    separate count(DISTINCT user_id) over that table would double
###    the scan.
### 5. The name audit (linkedin_br_name_audit.R) found 0 suspect names
###    in this population, but also that 57% of sampled profiles carry
###    names whose median IBGE frequency is 32x that of distinctively
###    Brazilian ones -- common in Brazil in absolute terms, not
###    specific to it. This script is the follow-up to that finding.
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

out_dir  <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
out_path <- file.path(out_dir, "name_only_user_country.parquet")

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"

athena_schema <- "revelio_database"
cand_table    <- "obmep_candidates_step_1"
user_table    <- "academic_individual_user"

# Measured when obmep_candidates_step_1 was built.
exp_total        <- 6849674
exp_name_only    <- 1113654
exp_both         <- 2665855
exp_country_only <- 3070165

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
### Step 1: one scan, all three groups at once
####################################################################

# The comparison groups are free in the same pass, and the headline
# number is uninterpretable without them: "X% of the name-only group is
# Brazilian" means nothing until you know what share of a known-Brazilian
# group carries the same field.
q <- sprintf("
SELECT CASE WHEN s.in_country_cohort = 1 AND s.in_name_cohort = 1 THEN 'both'
            WHEN s.in_country_cohort = 1                          THEN 'country_only'
            ELSE 'name_only' END             AS grp,
       coalesce(u.user_country, '(missing)') AS user_country,
       count(*)                              AS users
FROM %s.%s s
LEFT JOIN %s.%s u ON s.user_id = u.user_id
GROUP BY 1, 2", athena_schema, cand_table, athena_schema, user_table)

cat("=========== QUERY ===========\n")
cat(q, "\n\n")

con <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name    = s3_region,
                 schema_name    = athena_schema)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

cat("Running (one scan of ", user_table, ")...\n", sep = "")
t0 <- Sys.time()
r <- dbGetQuery(con, q)
cat("  finished in",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n\n")

r$users <- as.numeric(as.character(r$users))

####################################################################
### Step 2: validation
####################################################################

cat("=========== VALIDATION ===========\n")
tot <- tapply(r$users, r$grp, sum)
got <- c(name_only = 0, both = 0, country_only = 0)
got[names(tot)] <- tot

if (sum(got) != exp_total) {
  stop("Group totals sum to ", format(sum(got), scientific = FALSE),
       ", expected ", exp_total,
       " -- academic_individual_user is probably not unique on user_id ",
       "and the LEFT JOIN fanned out.")
}
if (got[["name_only"]] != exp_name_only ||
    got[["both"]] != exp_both ||
    got[["country_only"]] != exp_country_only) {
  stop("Group split changed: got ", got[["country_only"]], "/", got[["both"]],
       "/", got[["name_only"]], ", expected ", exp_country_only, "/",
       exp_both, "/", exp_name_only)
}
cat("[OK] totals reconcile to", format(exp_total, big.mark = ","),
    "and the group split is unchanged\n\n")

####################################################################
### Step 3: report
####################################################################

share <- function(g, ctry) {
  n <- sum(r$users[r$grp == g & r$user_country == ctry])
  100 * n / got[[g]]
}

cat("=========== user_country = 'Brazil', BY GROUP ===========\n")
for (g in c("name_only", "both", "country_only")) {
  n <- sum(r$users[r$grp == g & r$user_country == "Brazil"])
  cat(sprintf("  %-13s %10s of %10s   %5.1f%%\n", g,
              format(n, big.mark = ","), format(got[[g]], big.mark = ","),
              100 * n / got[[g]]))
}
cat("\n  ('both' and 'country_only' are the baselines: groups with an\n",
    "   observed Brazilian signal already, so they show what coverage\n",
    "   of this field looks like for people known to be Brazilian.)\n", sep = "")

cat("\n=========== MOST COMMON user_country, NAME-ONLY GROUP ===========\n")
no <- r[r$grp == "name_only", c("user_country", "users")]
no <- no[order(-no$users), ]
no$pct <- 100 * no$users / got[["name_only"]]
cat(sprintf("  %-28s %10s %7s\n", "user_country", "users", "%"))
for (i in seq_len(min(15, nrow(no)))) {
  cat(sprintf("  %-28s %10s %6.1f%%\n", no$user_country[i],
              format(no$users[i], big.mark = ","), no$pct[i]))
}
cat("  distinct user_country values in this group:", nrow(no), "\n")

cat("\n=========== '(missing)' SHARE ===========\n")
for (g in c("name_only", "both", "country_only")) {
  cat(sprintf("  %-13s %5.1f%%\n", g, share(g, "(missing)")))
}

####################################################################
### Step 4: persist
####################################################################

arrow::write_parquet(r, out_path, compression = "snappy")

cat("\n=========== SUMMARY ===========\n")
cat("  output        :", out_path,
    sprintf("(%.1f KB)\n", file.info(out_path)$size / 2^10))
cat("  rows          :", nrow(r), "(group x user_country)\n")
cat("  name-only Brazil share:",
    sprintf("%.1f%%\n", share("name_only", "Brazil")))
