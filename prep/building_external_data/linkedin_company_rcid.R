####################################################################
###
### The two company lists -> Revelio rcid            -> Dropbox
###
### Resolves every company in
###
###   hurun_top200_tech_2023_2026_linkedin_company_master.csv   341
###   tech_companies_by_cap_top200_linkedin.csv                 200
###
### to Revelio's company key, by EXACT LinkedIn URL equality against
### academic_company_ref. Output is one row per rcid, with list
### membership as two flags, so a firm on both lists is not
### duplicated:
###
###   linkedin_company_rcid_2026.parquet          one row per rcid
###   linkedin_company_unresolved_2026.parquet    the ones that got
###                                               away, note 8
###
### Depends on:
###   prep/build_hurun_tech_unicorn_linkedin_dataset.R  (consolidate)
###   the hand-researched tech_companies_by_cap_top200_linkedin.csv
###
### Consumed by:
###   prep/building_external_data/obmep_candidates_step_1_firms.R
###
### Arm precedence copied from ruf_openalex_br_crosswalk.R.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. THIS SCRIPT REQUIRES INTERNET ACCESS -- it reads Athena. Same
###    deliberate exception to AGENTS.md as the rest of this folder.
###    It is cheap: academic_company_ref is 6.35 GB in 32 parquet
###    parts and only a handful of its 21 columns are read, so the
###    scan is well under a cent. Nothing is written to S3.
### 2. THE MATCH IS EXACT AFTER NORMALISATION, AND NOTHING ELSE.
###    No fuzzy matching and no alias table -- neither exists anywhere
###    in this folder, and both were considered and rejected; see
###    README "Why the fuzzy match was dropped". A LinkedIn URL is a
###    hard identifier and there is no reason to soften it.
### 3. TWO ARMS, LOWEST WINS, UNIQUE CANDIDATE REQUIRED.
###      1. linkedin_url       = a listed URL  -> rcid
###      2. child_linkedin_url = a listed URL  -> child_rcid
###    Arm 2 exists because academic_company_ref carries a parent and
###    a child side, and a listed firm can appear only as somebody's
###    child. Precedence is STRUCTURAL, not a tie-break: two rcids
###    inside the winning arm is an assertion failure. Picking one in
###    silence is exactly what would hide the failure.
### 4. 12 LISTED COMPANIES HAVE NO LINKEDIN URL AT ALL -- 5 of the 341
###    Hurun entries (linkedin_match_status = not_found) and 7 of the
###    200 market-cap entries (5 ambiguous + 2 not_found). They are
###    LEFT UNRESOLVED, by decision, and printed by name. For the
###    market-cap 7 the script also prints what their `Symbol` would
###    resolve to against academic_company_ref.ticker. That is a
###    REPORT, not a flag: promoting it to a third arm is a
###    deliberate choice somebody should make while looking at the
###    list, not a default.
### 5. rcid IS int HERE AND bigint ON academic_individual_position.
###    Cast on every join between them.
### 6. THE GRAIN OF academic_company_ref IS NOT ASSUMED. It carries
###    both rcid and child_rcid, which suggests one row per
###    parent-child edge rather than one per company, and 6.35 GB is
###    large for a plain company list. count(*) against
###    count(DISTINCT rcid) is measured and printed before any join,
###    and every arm aggregates rather than assuming uniqueness.
### 7. A COMPANY MAY BE ON BOTH LISTS. Hurun lists unicorns and the
###    other list is public firms by market cap, so an overlap means
###    something IPO'd. The output keeps ONE row per rcid with
###    in_unicorn and in_techcap side by side rather than two rows,
###    because a downstream join on rcid would otherwise fan out.
### 8. 10% OF THE VERIFIED URLs DO NOT RESOLVE, AND THAT IS THE REAL
###    LIMITATION OF THIS FILE -- not the 12 of note 4. LinkedIn lets
###    a company page carry a vanity slug beside its canonical one,
###    and where the hand research recorded one and Revelio recorded
###    the other, exact equality finds nothing. Measured: Zoom,
###    Cadence, Expedia, Gen Digital, Coherent, Block and X are all in
###    this group. They are NOT missing from Revelio; they are missing
###    from this join. obmep_candidates_step_1_firms.R recovers part
###    of the group offline and for free -- see its arm 3.
###
### -----------------------------------------------------------------
### MEASURED, 2026-08-28 -- scratchpad/diag_unresolved_company_urls.R
### -----------------------------------------------------------------
###   academic_company_ref  26,596,058 rows, 26,596,058 distinct rcid
###                         -> ONE ROW PER COMPANY, note 6 answered
###   listed with a URL     529 rows, 521 distinct URLs
###   arm 1 resolves        468 URLs
###   arm 2 adds            0 -- every child_linkedin_url it matched
###                         was already matched by arm 1, so arm 2 is
###                         kept for its guard value, not its yield
###   unresolved            53 URLs (54 listed rows)
###   output                468 rcids: 295 unicorn, 180 techcap, 7 both
###
### TWO ARMS WERE MEASURED AND REJECTED for the unresolved 53, and the
### numbers are the argument:
###
###   TICKER. Only 13 of the 53 carry a Symbol at all, and only 3 of
###   those resolve to exactly one rcid (Cadence CDNS, Coherent COHR,
###   Expedia EXPE). Credo gives 2, Qnity 2, Gen Digital 5. Three
###   companies is not worth an arm, and the ambiguous ones would need
###   hand adjudication anyway.
###
###   COMPANY NAME. Actively harmful, which is the folder's standing
###   position on name matching and is now measured on this data:
###     Block -> block-workspace | block
###     X     -> yakirox-cagri-hizmetleri | x_2
###     Labs  -> laboratoryofsales | 070301-labs | labsstudio
###     Cars  -> carsvtc | 2b-panzer-company
###   Short company names are exactly the false-positive surface the
###   README warns about for the institution lists, and companies are
###   worse than universities because the short names are real.
###
### -----------------------------------------------------------------
### SOURCE SCHEMA -- AWS Glue catalogue, revelio_database, 2026-08-28
### -----------------------------------------------------------------
### academic_company_ref, s3://revelio-data/academic_company_ref/,
### 6.35 GB in 32 parquet parts, 21 columns:
###
###   rcid int                        company string
###   primary_name string             factset_entity_id string
###   year_founded int                ticker string
###   exchange_name string            sedol string
###   isin string                     cusip string
###   cik string                      lei string
###   gvkey int                       url string
###   naics_code string               linkedin_url string
###   child_rcid int                  child_company string
###   child_linkedin_url string       ultimate_parent_rcid int
###   ultimate_parent_rcid_name string
###
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "RAthena", "arrow")) {
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

s3_bucket     <- "revelio-misc"
s3_region     <- "us-east-2"
athena_schema <- "revelio_database"
ref_table     <- "academic_company_ref"

un_path <- file.path(
  obmep_root,
  "Data/intermediate/hurun_global_unicorn_index/linkedin_top200_tech_2023_2026",
  "hurun_top200_tech_2023_2026_linkedin_company_master.csv")
tc_path <- file.path(
  obmep_root, "Data/intermediate/linkedin_company_urls",
  "tech_companies_by_cap_top200_linkedin.csv")

out_dir  <- file.path(obmep_root, "Data/intermediate/linkedin_company_urls")
out_path <- file.path(out_dir, "linkedin_company_rcid_2026.parquet")
unres_path <- file.path(out_dir, "linkedin_company_unresolved_2026.parquet")

# Measured against the two CSVs. Drift warns; it does not abort,
# because a re-researched list legitimately moves these.
exp_un_rows <- 341L
exp_tc_rows <- 200L
exp_un_urls <- 336L
exp_tc_urls <- 193L

for (f in c(un_path, tc_path)) {
  if (!file.exists(f)) stop("Nao encontrei ", f)
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_company_rcid")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

# The same expression is used on both engines. Every pattern is
# anchored, so it does not matter that DuckDB replaces the first match
# and Trino replaces all of them, and it contains NO BACKSLASHES --
# README trap 4. `[.]` not `\.`, `[/]` not an escape.
#
#   https://www.linkedin.com/company/nvidia/  ->  linkedin.com/company/nvidia
#   linkedin.com/company/nvidia               ->  linkedin.com/company/nvidia
norm_url <- function(col) {
  sprintf(
    "regexp_replace(regexp_replace(regexp_replace(regexp_replace(
       lower(trim(%s)), '^https?://', ''), '^www[.]', ''), '[?#].*$', ''), '/+$', '')",
    col)
}

####################################################################
### Step 1: read the two lists and normalise their URLs
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

cat("=========== THE TWO LISTS ===========\n")
cat("unicorns  :", un_path, "\n")
cat("market cap:", tc_path, "\n\n")

# all_varchar: the Hurun file has embedded newlines in quoted notes and
# Chinese aliases, and the market-cap file has a column literally named
# `price (USD)`. Nothing here needs a type, and a guessed one would
# only be something to get wrong.
csv_src <- function(p) {
  sprintf("read_csv('%s', all_varchar = true, header = true)",
          gsub("\\\\", "/", p))
}

dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE un_raw AS SELECT * FROM %s", csv_src(un_path)))
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE tc_raw AS SELECT * FROM %s", csv_src(tc_path)))

n_un <- dbGetQuery(con, "SELECT count(*) n FROM un_raw")$n
n_tc <- dbGetQuery(con, "SELECT count(*) n FROM tc_raw")$n
if (n_un != exp_un_rows) warning("Hurun list has ", n_un, " rows, expected ", exp_un_rows)
if (n_tc != exp_tc_rows) warning("Market-cap list has ", n_tc, " rows, expected ", exp_tc_rows)

# One row per listed company, with the URL folded to Revelio's form.
# best_rank on the Hurun side is the minimum across the four index
# years and is already computed in the master.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE listed AS
  SELECT 'unicorn' AS lst,
         entity_id                          AS ident,
         canonical_company_name             AS nm,
         try_cast(best_rank AS INTEGER)     AS rnk,
         CAST(NULL AS VARCHAR)              AS sym,
         linkedin_match_status              AS status,
         nullif(%s, '')                     AS url_norm
  FROM un_raw
  UNION ALL
  SELECT 'techcap',
         Rank,
         Name,
         try_cast(Rank AS INTEGER),
         Symbol,
         linkedin_match_status,
         nullif(%s, '')
  FROM tc_raw", norm_url("linkedin_company_url"), norm_url("linkedin_company_url")))

cov <- dbGetQuery(con, "
  SELECT lst, count(*) AS n, count(url_norm) AS n_url
  FROM listed GROUP BY 1 ORDER BY 1")
print(cov)
if (cov$n_url[cov$lst == "unicorn"] != exp_un_urls) {
  warning("Hurun list has ", cov$n_url[cov$lst == "unicorn"],
          " URLs, expected ", exp_un_urls)
}
if (cov$n_url[cov$lst == "techcap"] != exp_tc_urls) {
  warning("Market-cap list has ", cov$n_url[cov$lst == "techcap"],
          " URLs, expected ", exp_tc_urls)
}

# Note 4. Named, not counted.
cat("\n--- listed with no LinkedIn URL (left unresolved, note 4) ---\n")
no_url <- dbGetQuery(con, "
  SELECT lst, ident, nm, sym, status FROM listed
  WHERE url_norm IS NULL ORDER BY lst, ident")
print(no_url, row.names = FALSE)

cat("\n--- a sample of the normalised URLs going to Athena ---\n")
print(dbGetQuery(con, "
  SELECT lst, nm, url_norm FROM listed WHERE url_norm IS NOT NULL
  ORDER BY lst, ident LIMIT 6"), row.names = FALSE)

urls <- dbGetQuery(con,
  "SELECT DISTINCT url_norm FROM listed WHERE url_norm IS NOT NULL ORDER BY 1")$url_norm
cat("\ndistinct normalised URLs to resolve:", length(urls), "\n\n")
if (length(urls) == 0) stop("No LinkedIn URLs to resolve.")

in_urls <- paste0("'", paste(gsub("'", "''", urls), collapse = "','"), "'")

####################################################################
### Step 2: Athena -- grain of the reference table, then the two arms
####################################################################

cat("=========== ATHENA ===========\n")
ath <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name    = s3_region,
                 schema_name    = athena_schema)
on.exit(try(dbDisconnect(ath), silent = TRUE), add = TRUE)

# Note 6. Reads rcid and child_rcid only.
grain <- dbGetQuery(ath, sprintf("
  SELECT count(*) AS n_rows,
         count(DISTINCT rcid) AS n_rcid,
         count(child_rcid) AS n_child,
         count(DISTINCT child_rcid) AS n_child_rcid
  FROM %s.%s", athena_schema, ref_table))
cat("academic_company_ref grain\n")
cat("  rows                :", format(as.numeric(grain$n_rows), big.mark = ","), "\n")
cat("  distinct rcid       :", format(as.numeric(grain$n_rcid), big.mark = ","), "\n")
cat("  child_rcid filled   :", format(as.numeric(grain$n_child), big.mark = ","), "\n")
cat("  distinct child_rcid :", format(as.numeric(grain$n_child_rcid), big.mark = ","), "\n")
cat(sprintf("  rows per rcid       : %.2f%s\n",
            as.numeric(grain$n_rows) / as.numeric(grain$n_rcid),
            if (as.numeric(grain$n_rows) > as.numeric(grain$n_rcid))
              "  -- NOT one row per company; every arm below aggregates"
            else "  -- one row per company"))

# Arm 1: the company's own page. GROUP BY rather than DISTINCT so a
# parent repeated once per child collapses, and so n_ref_rows records
# how many rows stood behind the match.
cat("\n--- arm 1: linkedin_url ---\n")
a1 <- dbGetQuery(ath, sprintf("
  SELECT %s AS url_norm,
         rcid,
         company,
         primary_name,
         ticker,
         exchange_name,
         ultimate_parent_rcid,
         count(*) AS n_ref_rows
  FROM %s.%s
  WHERE %s IN (%s)
  GROUP BY 1, 2, 3, 4, 5, 6, 7",
  norm_url("linkedin_url"), athena_schema, ref_table,
  norm_url("linkedin_url"), in_urls))
cat("  rows returned:", nrow(a1), "  distinct URLs:", length(unique(a1$url_norm)), "\n")

# Arm 2: the listed firm appears only as somebody's child.
cat("\n--- arm 2: child_linkedin_url ---\n")
a2 <- dbGetQuery(ath, sprintf("
  SELECT %s AS url_norm,
         child_rcid AS rcid,
         child_company AS company,
         child_company AS primary_name,
         CAST(NULL AS VARCHAR) AS ticker,
         CAST(NULL AS VARCHAR) AS exchange_name,
         rcid AS ultimate_parent_rcid,
         count(*) AS n_ref_rows
  FROM %s.%s
  WHERE %s IN (%s) AND child_rcid IS NOT NULL
  GROUP BY 1, 2, 3, 4, 5, 6, 7",
  norm_url("child_linkedin_url"), athena_schema, ref_table,
  norm_url("child_linkedin_url"), in_urls))
cat("  rows returned:", nrow(a2), "  distinct URLs:", length(unique(a2$url_norm)), "\n")

# Note 4: the ticker diagnostic, for the market-cap entries with no URL.
syms <- dbGetQuery(con, "
  SELECT DISTINCT upper(trim(sym)) AS s FROM listed
  WHERE url_norm IS NULL AND sym IS NOT NULL AND trim(sym) <> ''")$s
tick <- NULL
if (length(syms)) {
  in_syms <- paste0("'", paste(gsub("'", "''", syms), collapse = "','"), "'")
  tick <- dbGetQuery(ath, sprintf("
    SELECT upper(trim(ticker)) AS sym, rcid, company, primary_name,
           exchange_name, linkedin_url
    FROM %s.%s
    WHERE upper(trim(ticker)) IN (%s)
    GROUP BY 1, 2, 3, 4, 5, 6", athena_schema, ref_table, in_syms))
}

try(dbDisconnect(ath), silent = TRUE)

####################################################################
### Step 3: precedence, and the assertion inside the winning arm
####################################################################

arms <- rbind(cbind(a1, match_arm = 1L), cbind(a2, match_arm = 2L))
if (nrow(arms) == 0) {
  stop("Neither arm matched anything. The normalisation almost certainly ",
       "disagrees with academic_company_ref.linkedin_url -- compare the ",
       "sample printed above against the table before changing anything else.")
}
dbWriteTable(con, "arms", arms, overwrite = TRUE)

# Note 3. Lowest arm wins; inside it the candidate must be unique.
dbExecute(con, "
  CREATE OR REPLACE TABLE won AS
  SELECT a.*
  FROM arms a
  JOIN (SELECT url_norm, min(match_arm) AS match_arm
        FROM arms GROUP BY 1) w
    ON a.url_norm = w.url_norm AND a.match_arm = w.match_arm")

amb <- dbGetQuery(con, "
  SELECT url_norm, match_arm, count(DISTINCT rcid) AS n_rcid,
         string_agg(DISTINCT company, ' | ') AS companies
  FROM won GROUP BY 1, 2 HAVING count(DISTINCT rcid) > 1 ORDER BY 1")
if (nrow(amb)) {
  print(amb, row.names = FALSE)
  stop(nrow(amb), " LinkedIn URL(s) resolve to more than one rcid inside ",
       "their winning arm. Precedence is structural and does not break ties: ",
       "adjudicate these by hand before rerunning.")
}

# Which listed companies got nothing. Distinguished from note 4's
# no-URL cases, which never reached Athena.
cat("\n--- listed WITH a URL that resolved to no rcid ---\n")
unres <- dbGetQuery(con, "
  SELECT l.lst, l.ident, l.nm, l.status, l.url_norm
  FROM listed l LEFT JOIN won w ON l.url_norm = w.url_norm
  WHERE l.url_norm IS NOT NULL AND w.url_norm IS NULL
  ORDER BY l.lst, l.ident")
if (nrow(unres)) print(unres, row.names = FALSE) else cat("  (none)\n")

if (!is.null(tick) && nrow(tick)) {
  cat("\n--- ticker diagnostic for the no-URL market-cap entries (note 4) ---\n")
  cat("    REPORTED ONLY. These are not resolved and not flagged.\n")
  dbWriteTable(con, "tick", tick, overwrite = TRUE)
  print(dbGetQuery(con, "
    SELECT l.nm AS listed_name, l.sym, t.rcid, t.primary_name AS ref_name,
           t.exchange_name, t.linkedin_url
    FROM listed l JOIN tick t ON upper(trim(l.sym)) = t.sym
    WHERE l.url_norm IS NULL ORDER BY l.nm"), row.names = FALSE)
}

####################################################################
### Step 4: collapse to one row per rcid
####################################################################

# Note 7. Two listed companies landing on one rcid is reported, not
# fatal -- it is a real possibility (a rename, a holding company) and
# the collapse below keeps the better rank from each list.
dbExecute(con, "
  CREATE OR REPLACE TABLE hit AS
  SELECT l.lst, l.ident, l.nm, l.rnk, l.sym, w.*
  FROM listed l JOIN won w ON l.url_norm = w.url_norm")

coll <- dbGetQuery(con, "
  SELECT rcid, count(DISTINCT nm) AS n_names,
         string_agg(DISTINCT nm, ' | ') AS names
  FROM hit GROUP BY 1 HAVING count(DISTINCT nm) > 1 ORDER BY 1")
cat("\n--- rcids claimed by more than one listed company ---\n")
if (nrow(coll)) print(coll, row.names = FALSE) else cat("  (none)\n")

dbExecute(con, "
  CREATE OR REPLACE TABLE saida AS
  SELECT
    CAST(rcid AS BIGINT)                                          AS rcid,
    CAST(max(CASE WHEN lst = 'unicorn' THEN 1 ELSE 0 END) AS INTEGER) AS in_unicorn,
    CAST(max(CASE WHEN lst = 'techcap' THEN 1 ELSE 0 END) AS INTEGER) AS in_techcap,
    min(ident)   FILTER (WHERE lst = 'unicorn')                   AS un_entity_id,
    arg_min(nm, rnk) FILTER (WHERE lst = 'unicorn')               AS un_canonical_name,
    CAST(min(rnk) FILTER (WHERE lst = 'unicorn') AS INTEGER)      AS un_best_rank,
    CAST(min(rnk) FILTER (WHERE lst = 'techcap') AS INTEGER)      AS tc_rank,
    arg_min(nm, rnk) FILTER (WHERE lst = 'techcap')               AS tc_name,
    min(sym)     FILTER (WHERE lst = 'techcap')                   AS tc_symbol,
    min(url_norm)                                                 AS linkedin_url_norm,
    min(company)                                                  AS ref_company,
    min(primary_name)                                             AS ref_primary_name,
    min(ticker)                                                   AS ref_ticker,
    CAST(min(ultimate_parent_rcid) AS BIGINT)                     AS ref_ultimate_parent_rcid,
    CAST(min(match_arm) AS INTEGER)                               AS match_arm,
    CAST(sum(n_ref_rows) AS INTEGER)                              AS n_ref_rows
  FROM hit
  GROUP BY rcid")

####################################################################
### Step 5: read every resolution before trusting any of it
####################################################################

cat("\n=========== RESOLUTIONS ===========\n")
cat("Every row, listed name -> what Revelio calls it. There is no\n")
cat("assertion that replaces reading these.\n\n")
res <- dbGetQuery(con, "
  SELECT CASE WHEN in_unicorn = 1 AND in_techcap = 1 THEN 'both'
              WHEN in_unicorn = 1 THEN 'unicorn' ELSE 'techcap' END AS lst,
         coalesce(un_canonical_name, tc_name) AS listed_name,
         ref_primary_name, ref_company, rcid, match_arm
  FROM saida ORDER BY lst, listed_name")
print(res, row.names = FALSE, max = 6 * nrow(res))

####################################################################
### Step 6: validation and write
####################################################################

cat("\n=========== VALIDATION ===========\n")
n_out <- dbGetQuery(con, "SELECT count(*) n, count(DISTINCT rcid) nd FROM saida")
if (n_out$n != n_out$nd) stop("The output is not unique on rcid.")
if (n_out$n == 0) stop("Nothing resolved.")

sm <- dbGetQuery(con, "
  SELECT lst,
         count(*) AS listed,
         count(l.url_norm) AS with_url,
         count(DISTINCT CASE WHEN w.url_norm IS NOT NULL THEN l.url_norm END) AS resolved
  FROM listed l LEFT JOIN (SELECT DISTINCT url_norm FROM won) w
    ON l.url_norm = w.url_norm
  GROUP BY lst ORDER BY lst")
print(sm, row.names = FALSE)

cat("\n  rows written (distinct rcid):", n_out$n, "\n")
print(dbGetQuery(con, "
  SELECT in_unicorn, in_techcap, count(*) AS n FROM saida
  GROUP BY 1, 2 ORDER BY 1, 2"), row.names = FALSE)
print(dbGetQuery(con, "
  SELECT match_arm, count(*) AS n FROM saida GROUP BY 1 ORDER BY 1"),
  row.names = FALSE)

dbExecute(con, sprintf(
  "COPY (SELECT * FROM saida ORDER BY rcid) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", gsub("\\\\", "/", out_path)))

# Note 8. Written as its own file rather than as NULL rows in the main
# output, which is one row per rcid and has no rcid to give these.
# obmep_candidates_step_1_firms.R reads it as the input to its arm 3.
dbExecute(con, sprintf(
  "COPY (SELECT lst, ident, nm, sym, status, url_norm
         FROM listed l
         WHERE url_norm IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM won w WHERE w.url_norm = l.url_norm)
         ORDER BY lst, ident) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", gsub("\\\\", "/", unres_path)))

chk <- arrow::read_parquet(out_path)
stopifnot(identical(names(chk), c(
  "rcid", "in_unicorn", "in_techcap", "un_entity_id", "un_canonical_name",
  "un_best_rank", "tc_rank", "tc_name", "tc_symbol", "linkedin_url_norm",
  "ref_company", "ref_primary_name", "ref_ticker", "ref_ultimate_parent_rcid",
  "match_arm", "n_ref_rows")))
stopifnot(nrow(chk) == n_out$n, !anyDuplicated(chk$rcid), !anyNA(chk$rcid))

cat("\n=========== SUMMARY ===========\n")
cat("  ", out_path, "\n", sep = "")
cat("  ", nrow(chk), " rcids  |  unicorn ", sum(chk$in_unicorn),
    "  techcap ", sum(chk$in_techcap), "\n", sep = "")
cat("  unresolved: ", nrow(no_url), " with no URL (note 4) + ",
    nrow(unres), " whose URL matched nothing\n", sep = "")
cat("      (note 8) ", unres_path, "\n", sep = "")
cat("      -> obmep_candidates_step_1_firms.R arm 3 recovers part of it\n")
