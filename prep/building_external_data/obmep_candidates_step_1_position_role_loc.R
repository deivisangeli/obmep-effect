####################################################################
###
### Role, seniority and location for every position in the pool
###                                          -> S3 + Athena + Dropbox
###
### obmep_candidates_step_1_position (script 10a) carries 12 columns
### and 10b added 4 more. Between them they describe WHERE somebody
### worked and WHAT the employer is called. Neither says what the
### person actually DID, and neither says where the job was.
###
### This adds both blocks, and nothing else:
###
###   academic_individual_position
###       -> obmep_candidates_step_1_position_role_loc
###          (user_id, position_id,
###           job_category, role_k50 .. role_k1500,
###           seniority, position_number, onet_code, onet_title,
###           location_raw, country, region, state, metro_area)
###
### position_id is the join key back to 10a's and 10b's extracts. No
### new criterion, the same semi-join, the same cohort.
###
### Depends on:
###   prep/building_external_data/obmep_candidates_step_1.R
###   (table revelio_database.obmep_candidates_step_1)
###   prep/building_external_data/obmep_candidates_step_1_entries.R
###   (table revelio_database.obmep_candidates_step_1_position, whose
###    position_id set this one must reproduce exactly)
###
### Consumed by:
###   prep/building_external_data/obmep_candidates_selected_positions.R
###
### UNLOAD/DDL pattern reused from
### obmep_candidates_step_1_position_rcid.R.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. THIS SCRIPT REQUIRES INTERNET ACCESS, the same deliberate
###    exception to AGENTS.md that 10a and 10b are. Athena + S3 + the
###    AWS CLI are the whole point. Local prep/ script, must not be
###    sent to the offline SEDAP environment.
### 2. WHY A THIRD EXTRACT INSTEAD OF RE-RUNNING 10a. Cost is set by
###    which columns are read, not by how the filter is written -- see
###    10a note 4 and README "Measured cost". 10a's 12 columns were
###    MEASURED at 422.3 GB for $2.06, with `description` alone about
###    47% of it. Re-running 10a to add these 16 would pay that again.
###    PREDICTED from the parquet footers, the method README:1384 asks
###    for: 85.2 GB, about $0.42. The same method predicted 10b at
###    40.5 GB against an actual 40.43, so it is trustworthy here.
### 3. WHY THE EXTRACT IS COHORT-WIDE AND NOT CUT TO THE 1.3M SELECTED
###    USERS. Three reasons, in order of weight. (a) It would not save
###    a cent: user_id is scattered across row groups, so Athena prunes
###    none of them -- README:1365-1370 measures this three ways.
###    (b) obmep_candidates_selected.parquet is not in Athena at all;
###    script 21 is offline end to end, so cutting to it would mean
###    uploading and registering it first, for zero saving. (c) Keeping
###    10a's exact semi-join means this table shares 10a's position_id
###    keyspace, which is what makes the anti-join in note 5 a proof.
###    A cut can be tightened offline later; a scan cannot be un-paid.
### 4. seniority AND position_number ARE smallint, NOT int. Verified
###    against the Glue catalogue, not remembered. This matters because
###    the offline validator CANNOT catch it: validate_sql_syntax.R's
###    type_class() deliberately collapses every integer width into one
###    class (its note 3), so a wrong width here binds cleanly and then
###    breaks on read. The DDL below matches the source exactly.
### 5. THE POSITION_ID SETS MUST BE IDENTICAL. This extract and 10a's
###    are two separate scans of a live table. If Revelio refreshed
###    between them the two disagree and position_id is not a safe
###    join key. The anti-join in both directions is checked below and
###    ABORTS, because a silent partial join is worse than no join.
### 6. NULL ROLE AND LOCATION VALUES ARE EXPECTED AND NOT AN ERROR.
###    Revelio classifies a title or resolves a place only when it can.
###    No fill rate is asserted, because none has ever been measured --
###    nothing in this repo had read these columns before. Every rate
###    is REPORTED, and the first run is what establishes them.
### 7. THE LOCAL COPY IS A DOWNLOAD, NOT A RE-ENCODE, and the parts
###    have NO .parquet EXTENSION -- Athena UNLOAD names its objects
###    <query-id>_<uuid>. Read the directory with
###    arrow::open_dataset(dir, format = "parquet") or, in DuckDB,
###    read_parquet('<dir>/*') with a bare glob.
### 8. THIS CLOSES THE country GAP. README:1451 recorded that criterion
###    A_country reads academic_individual_position.country but that
###    the column was never unloaded, so anything needing position
###    level country locally had to go back to Athena. It does not any
###    more. The Brazil counts are reported below as a free
###    consistency check against criterion A; they do not gate the run.
### 9. country, region, state AND metro_area MARK MISSING WITH THE
###    STRING 'empty', NOT WITH NULL. Measured on the first run: they
###    contain zero NULLs and zero empty strings, but 430,327 rows say
###    'empty' in country and region, 1,759,640 in state, 512,800 in
###    metro_area. So `count(country)` reports 100% coverage and
###    `WHERE country IS NULL` returns nothing -- both wrong. The fill
###    report below excludes the sentinel explicitly.
###    location_raw and onet_code do NOT do this; they use real NULLs.
###    Two missingness conventions in one table, and only the derived
###    geography columns use the sentinel.
###
### -----------------------------------------------------------------
### SOURCE SCHEMA -- AWS Glue catalogue, revelio_database, 2026-08-31
### -----------------------------------------------------------------
### academic_individual_position has 47 columns. 10a took 12, 10b took
### 4 (2 of them shared keys), this one takes 18 (the same 2 keys).
### What is STILL not extracted after this script, and why:
###
###   description                  string   -- ~47% of 10a's bill, and
###                                            10a already has it
###   company_name                 string   -- academic_company_ref
###   ultimate_parent_company_name string      gives both per rcid at a
###   ticker, exchange, cusip      string      fraction of the cost
###   rics_k50, rics_k200, rics_k400        -- Revelio industry
###                                            clusters; naics_code is
###                                            already in 10a
###   ultimate_parent_factset_id   string
###   ultimate_parent_factset_name string
###   salary, start_salary, end_salary      -- the compensation block,
###   total_compensation                       left behind by choice.
###   additional_compensation                  A fourth scan if wanted.
###   weight, remote_suitability   float
###
### Listing them is the point. The reason rcid sat unnoticed in this
### table through every stage up to script 18 is that 10a's column
### list was read as though it were the table -- a partial listing
### does not fail on a missing column, it simply never offers it.
###
### -----------------------------------------------------------------
### MEASURED, run of 2026-08-31
### -----------------------------------------------------------------
###   scanned                     81.32 GB  (~$0.41)
###                               predicted 85.2 from the footers, so
###                               the method came in 4.8% high
###   UNLOAD engine time          24.2 s  (0.42 min wall)
###   rows                        30,389,044   == 10a, exactly
###   distinct users              6,849,674    == the whole cohort
###   position_id                 unique; anti-join to 10a is 0 both
###                               ways, so the two extracts saw the
###                               same snapshot (note 5)
###   on disk                     0.83 GB in 30 parts
###
###   job_category                100%, 7 distinct  -- this IS the k7
###                               level; there is no role_k7 column
###   role_k50 .. role_k1500      100%, and each has EXACTLY its
###                               nominal count: 50/150/300/500/
###                               1000/1500. A clean nested taxonomy.
###   seniority                   100%, 7 distinct, range 1..7
###   position_number             100%, range 1..128
###   onet_code / onet_title      99.3%, 383 distinct (real NULLs)
###   location_raw                99.9%, 863,897 distinct (real NULLs)
###   country                     98.6% once 'empty' is excluded,
###                               245 distinct incl. the sentinel
###   region                      98.6%, 16 distinct
###   state                       94.2%, 2,991 distinct
###   metro_area                  98.3%, 837 distinct
###
###   country = 'Brazil'          23,045,785 positions (75.8%),
###                               5,671,650 users -- criterion
###                               A_country, computable locally for
###                               the first time (note 8). The literal
###                               spelling IS 'Brazil', so criterion A
###                               transfers unchanged.
###
### -----------------------------------------------------------------
### ACCURACY -- COVERAGE ABOVE IS NOT CORRECTNESS
### -----------------------------------------------------------------
### role_title_audit.R (10d) auditou 500 destas linhas contra
### title_raw. Leia antes de usar qualquer coluna de papel:
###
###   job_category   84.2% correto  [80.5, 87.5]
###   role_k50       81.0%
###   role_k1500     63.7% correto  [59.0, 68.1]
###
### Em 14.0% das linhas o proprio job_category esta errado. E os 100%
### de preenchimento acima escondem o principal: quando o titulo nao
### diz ocupacao nenhuma o Revelio CHUTA em vez de devolver nulo, e
### chuta diferente a cada vez -- "estagiario" (178,093 posicoes) sai
### espalhado pelas 7 categorias e 467 rotulos de role_k1500. Sao
### 434,622 posicoes, 6.0% do arquivo, sem nada no dado que as marque.
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
out_root <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
athena_schema <- "revelio_database"

cand_table <- "obmep_candidates_step_1"
pos_table  <- "obmep_candidates_step_1_position"

table      <- "obmep_candidates_step_1_position_role_loc"
src        <- "academic_individual_position"

cols     <- c("user_id", "position_id", "job_category",
              "role_k50", "role_k150", "role_k300",
              "role_k500", "role_k1000", "role_k1500",
              "seniority", "position_number", "onet_code", "onet_title",
              "location_raw", "country", "region", "state", "metro_area")

# Types are the Glue catalogue's own, verified not remembered. seniority
# and position_number are SMALLINT: note 4, and the validator cannot
# catch a mistake here.
ddl_cols <- c("user_id BIGINT", "position_id BIGINT", "job_category STRING",
              "role_k50 STRING", "role_k150 STRING", "role_k300 STRING",
              "role_k500 STRING", "role_k1000 STRING", "role_k1500 STRING",
              "seniority SMALLINT", "position_number SMALLINT",
              "onet_code STRING", "onet_title STRING",
              "location_raw STRING", "country STRING", "region STRING",
              "state STRING", "metro_area STRING")

# Measured on 10a's run. Both are asserted below; see note 5 and 10a
# note 6.
exp_rows  <- 30389044
exp_users <- 6849674

s3_prefix <- paste0("exports/", table)
s3_path   <- paste0("s3://", s3_bucket, "/", s3_prefix, "/")
local_dir <- file.path(out_root, table)

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

dir.create(out_root, recursive = TRUE, showWarnings = FALSE)

# The AWS CLI does the download (note 7). Failing here beats failing
# after the scan has been paid for.
if (Sys.which("aws") == "") {
  stop("The AWS CLI is not on PATH. It is required for the local copy; ",
       "install it or run the `aws s3 sync` command printed below by hand.")
}

####################################################################
### Step 1: build the queries
####################################################################

# The SELECT lives in its own object so it can be validated on its own
# (scratchpad/validate_sql_syntax.R), whereas UNLOAD and DDL cannot.
select_sql <- sprintf(
  "SELECT %s\nFROM %s\nWHERE user_id IN (SELECT user_id FROM %s.%s)",
  paste(cols, collapse = ",\n       "), src, athena_schema, cand_table)

unload_sql <- sprintf("
UNLOAD (%s
)
TO '%s'
WITH (format = 'PARQUET', compression = 'SNAPPY')", select_sql, s3_path)

# STRING/BIGINT/SMALLINT (not VARCHAR) and in the exact SELECT order:
# Hive DDL, and the Athena Parquet SerDe resolves columns by POSITION
# and TYPE.
ddl_txt <- sprintf(
  "CREATE EXTERNAL TABLE IF NOT EXISTS %s.%s (\n  %s\n)\nSTORED AS PARQUET\nLOCATION '%s'",
  athena_schema, table, paste(ddl_cols, collapse = ",\n  "), s3_path)

cat("=========== GENERATED SQL ===========\n")
cat(unload_sql, "\n\n", ddl_txt, "\n\n", sep = "")

# A SELECT and a DDL of different widths would register a table whose
# columns are silently shifted, because Athena resolves by ordinal
# position. Free to check, so check it.
if (length(cols) != length(ddl_cols)) {
  stop("cols has ", length(cols), " entries and ddl_cols has ",
       length(ddl_cols), ". They are parallel vectors and must match.")
}

####################################################################
### Step 2: the destination prefix must be empty
####################################################################

# UNLOAD refuses a non-empty prefix (README trap 7).
cat("=========== CURRENT CONTENTS OF THE S3 PREFIX ===========\n")
existing <- tryCatch(
  get_bucket(bucket = s3_bucket, prefix = paste0(s3_prefix, "/"),
             region = s3_region, max = 100),
  error = function(e2) { cat("  [listing error]:", conditionMessage(e2), "\n"); NULL })
if (is.null(existing) || length(existing) == 0) {
  cat("  ", s3_path, " empty\n\n", sep = "")
} else {
  for (o in existing) cat("   ", o$Key, "(", o$Size, "bytes )\n")
  stop("Prefix ", s3_path, " is not empty. Athena UNLOAD requires an ",
       "empty destination: delete the objects above (and the table ",
       athena_schema, ".", table, ", if it exists) before regenerating.")
}

####################################################################
### Step 3: check the two tables this depends on, then unload
####################################################################

cat("=========== ATHENA ===========\n")
con <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name    = s3_region,
                 schema_name    = athena_schema)
on.exit(try(dbDisconnect(con), silent = TRUE), add = TRUE)

# Without the cohort the semi-join matches nothing and the extract
# comes out empty after a full scan has been paid for.
cn <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n, count(DISTINCT user_id) AS n_users
  FROM %s.%s", athena_schema, cand_table))
cat("cohort rows                   :", format(cn$n, big.mark = ","), "\n")
if (cn$n == 0) {
  stop("Table ", athena_schema, ".", cand_table, " is empty. ",
       "Run obmep_candidates_step_1.R first.")
}
if (cn$n != cn$n_users) stop("Cohort table is not unique on user_id.")
if (cn$n != exp_users) {
  warning("Cohort has ", cn$n, " rows, expected ", exp_users,
          " -- exp_users is stale.")
}

# 10a's extract is what this one has to line up with (note 5). If it
# is not there the position_id cross-check cannot run, and running
# without it would produce a table nobody can safely join.
pn <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM %s.%s", athena_schema, pos_table))
cat("10a position rows             :", format(pn$n, big.mark = ","), "\n")
if (pn$n == 0) {
  stop("Table ", athena_schema, ".", pos_table, " is empty. ",
       "Run obmep_candidates_step_1_entries.R first -- this extract is ",
       "only useful joined to it.")
}

cat("\n--- UNLOAD (scans the whole source table) ---\n")
t0 <- Sys.time()
dbExecute(con, unload_sql)
cat("  finished in",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
dbExecute(con, ddl_txt)
cat("  registered ", athena_schema, ".", table, "\n", sep = "")

####################################################################
### Step 4: validation through Athena
####################################################################

cat("\n=========== VALIDATION ===========\n")
v <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n_rows,
         count(DISTINCT user_id) AS n_users,
         count(DISTINCT position_id) AS n_pos,
         sum(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END) AS uid_null,
         sum(CASE WHEN position_id IS NULL THEN 1 ELSE 0 END) AS pid_null,
         sum(CASE WHEN country = 'Brazil' THEN 1 ELSE 0 END) AS n_br_pos,
         count(DISTINCT CASE WHEN country = 'Brazil' THEN user_id END) AS n_br_users
  FROM %s.%s", athena_schema, table))
print(v)

n_rows  <- as.numeric(v$n_rows)
n_users <- as.numeric(v$n_users)
n_pos   <- as.numeric(v$n_pos)

if (n_rows == 0) stop("The extract is empty.")
if (v$uid_null != 0) stop("NULL user_id in the extract.")
if (v$pid_null != 0) stop("NULL position_id in the extract.")

# position_id is the join key to 10a. If it is not unique here the
# join fans out.
if (n_pos != n_rows) {
  stop("position_id is not unique: ", format(n_pos, big.mark = ","),
       " distinct values over ", format(n_rows, big.mark = ","), " rows. ",
       "It is the join key back to ", pos_table, " and a fan-out would be ",
       "silent.")
}

# The invariant from 10a note 6: criterion D admits nobody without a
# position, so every cohort member must be here.
if (n_users != exp_users) {
  stop(format(n_users, big.mark = ","), " distinct users, expected ",
       format(exp_users, big.mark = ","),
       ". Every cohort member must have at least one position.")
}

# Note 5 -- the check this whole extract rests on. Two separate scans
# of a live table have to have seen the same rows.
xw <- dbGetQuery(con, sprintf("
  SELECT
    (SELECT count(*) FROM %1$s.%2$s n
      LEFT JOIN %1$s.%3$s p ON n.position_id = p.position_id
      WHERE p.position_id IS NULL) AS only_new,
    (SELECT count(*) FROM %1$s.%3$s p
      LEFT JOIN %1$s.%2$s n ON p.position_id = n.position_id
      WHERE n.position_id IS NULL) AS only_10a",
  athena_schema, table, pos_table))
cat("position_id only in this extract :", format(xw$only_new, big.mark = ","), "\n")
cat("position_id only in 10a's extract:", format(xw$only_10a, big.mark = ","), "\n")
if (xw$only_new != 0 || xw$only_10a != 0) {
  stop("The two position extracts do not cover the same position_ids (",
       xw$only_new, " / ", xw$only_10a, "). Revelio refreshed between the ",
       "two scans; position_id is not a safe join key until both are ",
       "rebuilt from the same snapshot.")
}

# A Revelio refresh legitimately moves the row count, so this warns
# rather than aborting -- unlike the invariants above.
if (n_rows != exp_rows) {
  warning("Expected ", exp_rows, " rows, got ", n_rows)
}

# Note 6: no fill rate is asserted, because none has ever been
# measured. Reported here, and written into the README afterwards.
cat("\n--- fill rates, first measurement (note 6) ---\n")
fill_cols <- c("job_category", "role_k50", "role_k150", "role_k300",
               "role_k500", "role_k1000", "role_k1500", "seniority",
               "position_number", "onet_code", "onet_title",
               "location_raw", "country", "region", "state", "metro_area")

# Nota 9: as quatro colunas DERIVADAS de local marcam ausencia com a
# STRING 'empty', nunca com NULL. count() sozinho as daria como 100%
# preenchidas, que e falso. location_raw e onet_code usam NULL de
# verdade -- as duas convencoes convivem na mesma tabela.
sentinel_cols <- c("country", "region", "state", "metro_area")
miss <- ifelse(fill_cols %in% sentinel_cols,
               sprintf("(%1$s IS NULL OR %1$s = 'empty')", fill_cols),
               sprintf("%s IS NULL", fill_cols))
fq <- paste(sprintf(
  "sum(CASE WHEN NOT %2$s THEN 1 ELSE 0 END) AS f_%1$s,
          count(DISTINCT CASE WHEN NOT %2$s THEN %1$s END) AS d_%1$s",
  fill_cols, miss), collapse = ",\n         ")
fv <- dbGetQuery(con, sprintf("SELECT %s\n  FROM %s.%s", fq, athena_schema, table))
for (cc in fill_cols) {
  cat(sprintf("  %-16s filled %12s (%5.1f%%)  distinct %10s%s\n", cc,
              format(as.numeric(fv[[paste0("f_", cc)]]), big.mark = ","),
              100 * as.numeric(fv[[paste0("f_", cc)]]) / n_rows,
              format(as.numeric(fv[[paste0("d_", cc)]]), big.mark = ","),
              if (cc %in% sentinel_cols) "  -- 'empty' excluido, nota 9" else ""))
}

cat("\n")
cat("  rows                        :", format(n_rows, big.mark = ","), "\n")
cat("  distinct users              :", format(n_users, big.mark = ","), "\n")
cat(sprintf("  rows per member             : %.2f\n", n_rows / n_users))

# Note 8, reported not asserted: criterion A_country's own predicate,
# computable locally for the first time.
cat(sprintf("  country = 'Brazil'          : %s positions (%.1f%%)\n",
            format(as.numeric(v$n_br_pos), big.mark = ","),
            100 * as.numeric(v$n_br_pos) / n_rows))
cat("  users behind them           :",
    format(as.numeric(v$n_br_users), big.mark = ","),
    " -- criterion A_country\n")
cat("\n[OK] all validations passed\n\n")

####################################################################
### Step 5: bring the result down to Dropbox
####################################################################

# aws s3 sync, NOT arrow -- 10a note 5. The local artifact is a
# DIRECTORY of parts with no file extension.
cat("=========== LOCAL COPY ===========\n")
dir.create(local_dir, recursive = TRUE, showWarnings = FALSE)
cat("syncing to ", local_dir, "\n", sep = "")
t0 <- Sys.time()
st <- system2("aws", c("s3", "sync", s3_path, shQuote(local_dir),
                       "--region", s3_region, "--only-show-errors"))
cat("  finished in",
    round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 2), "min\n")
if (st != 0) {
  stop("`aws s3 sync` exited with status ", st,
       ". The S3 copy is intact -- rerun the sync by hand:\n  aws s3 sync ",
       s3_path, " \"", local_dir, "\" --region ", s3_region)
}

files <- list.files(local_dir, full.names = TRUE)
bytes <- sum(file.info(files)$size)
cat("  files                       :", length(files), "\n")
cat(sprintf("  on disk                     : %.2f GB\n", bytes / 2^30))

# nrow() on a Dataset reads footers only, so this stays cheap.
local_n <- nrow(arrow::open_dataset(local_dir, format = "parquet"))
cat("  rows in the local dataset   :", format(local_n, big.mark = ","), "\n")
if (local_n != n_rows) {
  stop("Local dataset has ", local_n, " rows, Athena reported ", n_rows,
       " -- the download is incomplete.")
}

cat("\n=========== SUMMARY ===========\n")
cat(sprintf("  %14s rows  %6.2f GB  %s\n",
            format(n_rows, big.mark = ","), bytes / 2^30, local_dir))
cat("  Athena: ", athena_schema, ".", table, "\n", sep = "")
cat("  S3    : ", s3_path, "\n", sep = "")
cat("  join to ", pos_table, " on position_id; the two cover the same set\n",
    sep = "")
