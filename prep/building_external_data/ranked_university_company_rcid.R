####################################################################
### Ranked RUF/Shanghai universities -> Revelio company RCIDs
###                                                   -> Dropbox
###
### LOCAL, ONLINE PREPARATION. This script queries Athena and must
### never be sent to SEDAP. It resolves the canonical parent-adjusted
### ranking catalog against academic_company_ref.company only, using
### normalized whole-field equality. It then expands every matching
### reference row across rcid, child_rcid, and ultimate_parent_rcid.
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "RAthena", "arrow", "jsonlite")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(duckdb)

root <- Sys.getenv("OBMEP_ROOT",
                   unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh <- file.path(root, "Data/intermediate/revelio_br_cohort")
global_dir <- file.path(coh, "global_oa_hierarchy")
catalog_path <- file.path(global_dir, "catalog.parquet")
ranked_path <- file.path(global_dir, "global_oa_ranked_parent_catalog.parquet")
ruf_path <- file.path(root, "Data/intermediate/ruf_ranking",
                      "ruf_stem_top10_institutions_2025.parquet")
sh_path <- file.path(root, "Data/intermediate/shanghai_ranking",
                     "shanghai_ranking_oa_parents.parquet")

out_dir <- file.path(root, "Data/intermediate/ranked_university_company_rcid")
out_path <- file.path(out_dir, "ranked_university_company_rcid.parquet")
report_path <- file.path(out_dir, "ranked_university_company_rcid_report.json")
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

athena_schema <- "revelio_database"
ref_table <- "academic_company_ref"
s3_bucket <- "revelio-misc"
s3_region <- "us-east-2"
mem_limit <- Sys.getenv("OBMEP_DUCKDB_MEM", unset = "8GB")
tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_ranked_university_company_rcid")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

py_path <- Sys.getenv(
  "OBMEP_PYTHON",
  unset = "C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe")
if (Sys.getenv("RETICULATE_PYTHON") == "" && file.exists(py_path)) {
  Sys.setenv(RETICULATE_PYTHON = py_path)
}

inputs <- c(catalog_path, ranked_path, ruf_path, sh_path)
if (!all(file.exists(inputs))) {
  stop("Missing canonical ranked-university input(s): ",
       paste(inputs[!file.exists(inputs)], collapse = ", "))
}
fw <- function(p) gsub("\\\\", "/", p)

con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
dbExecute(con, sprintf("SET memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", fw(tmp_dir)))
dbExecute(con, "SET preserve_insertion_order=false")

cat("=========== CANONICAL RANKED NAME CATALOG ===========\n")
dbExecute(con, sprintf("
CREATE TABLE ranked AS
SELECT 'ruf' AS family, p.oa_id AS source_oa_id,
       p.canonical_id AS canonical_oa_id, CAST(p.rk AS INTEGER) AS rank,
       CAST(p.rid AS INTEGER) AS ruf_institution_id,
       r.institution_name AS supplied_name
FROM read_parquet('%s') p
JOIN read_parquet('%s') r ON p.rid = r.ruf_institution_id
WHERE p.family = 'rd'
UNION ALL
SELECT 'shanghai', p.oa_id, p.canonical_id, CAST(p.rk AS INTEGER),
       NULL::INTEGER, s.shanghai_name
FROM read_parquet('%s') p
JOIN read_parquet('%s') s ON p.oa_id = s.oa_key
WHERE p.family = 'sh'",
  fw(ranked_path), fw(ruf_path), fw(ranked_path), fw(sh_path)))

ranked_counts <- dbGetQuery(con, "
  SELECT family, count(*) AS rows, count(DISTINCT source_oa_id) AS institutions,
         count(DISTINCT canonical_oa_id) AS canonical_institutions
  FROM ranked GROUP BY family ORDER BY family")
print(ranked_counts, row.names = FALSE)
if (dbGetQuery(con, "SELECT count(*) n FROM ranked WHERE source_oa_id IS NULL
                     OR canonical_oa_id IS NULL OR supplied_name IS NULL")$n != 0) {
  stop("The canonical ranked catalog contains a missing ID or supplied name.")
}
if (dbGetQuery(con, "SELECT count(*) n FROM ranked WHERE family='ruf'")$n != 23L) {
  stop("The canonical RUF catalog no longer contains 23 source institutions.")
}

dbExecute(con, sprintf("
CREATE TABLE institution_names AS
WITH variants AS (
  SELECT r.*, 'source' AS name_scope, 'display_name' AS name_variant,
         s.display_name AS searched_name
  FROM ranked r JOIN read_parquet('%1$s') s ON r.source_oa_id=s.oa_id
  UNION ALL
  SELECT r.*, 'source', 'cleaned_display_name', s.cleaned_display_name
  FROM ranked r JOIN read_parquet('%1$s') s ON r.source_oa_id=s.oa_id
  UNION ALL
  SELECT r.*, 'parent', 'display_name', p.display_name
  FROM ranked r JOIN read_parquet('%1$s') p ON r.canonical_oa_id=p.oa_id
  UNION ALL
  SELECT r.*, 'parent', 'cleaned_display_name', p.cleaned_display_name
  FROM ranked r JOIN read_parquet('%1$s') p ON r.canonical_oa_id=p.oa_id
  UNION ALL
  SELECT r.*, 'ranking', 'supplied_name', r.supplied_name FROM ranked r
)
SELECT DISTINCT family, source_oa_id, canonical_oa_id, rank,
       ruf_institution_id, supplied_name, name_scope, name_variant,
       trim(searched_name) AS searched_name,
       lower(strip_accents(trim(searched_name))) AS searched_name_norm
FROM variants
WHERE searched_name IS NOT NULL AND length(trim(searched_name)) >= 3",
  fw(catalog_path)))

name_counts <- dbGetQuery(con, "
  SELECT family, count(*) AS provenance_rows,
         count(DISTINCT searched_name_norm) AS distinct_names
  FROM institution_names GROUP BY family ORDER BY family")
print(name_counts, row.names = FALSE)
names_to_query <- dbGetQuery(con, "
  SELECT DISTINCT searched_name_norm FROM institution_names
  ORDER BY searched_name_norm")$searched_name_norm
if (!length(names_to_query)) stop("No institution names were generated.")
quoted_names <- paste0("'", gsub("'", "''", names_to_query, fixed = TRUE), "'")
in_names <- paste(quoted_names, collapse = ",")

cat("\n=========== ATHENA REFERENCE LOOKUP ===========\n")
ath <- dbConnect(RAthena::athena(),
                 s3_staging_dir = paste0("s3://", s3_bucket, "/"),
                 region_name = s3_region,
                 schema_name = athena_schema)
on.exit(try(dbDisconnect(ath), silent = TRUE), add = TRUE)

required_schema <- data.frame(
  column_name = c("rcid", "company", "child_rcid", "ultimate_parent_rcid"),
  data_type = c("integer", "varchar", "integer", "integer"),
  stringsAsFactors = FALSE)
live_schema <- dbGetQuery(ath, sprintf("
  SELECT column_name, data_type
  FROM information_schema.columns
  WHERE table_schema='%s' AND table_name='%s'
    AND column_name IN ('rcid','company','child_rcid','ultimate_parent_rcid')
  ORDER BY column_name", athena_schema, ref_table))
live_schema <- live_schema[order(live_schema$column_name), , drop = FALSE]
required_schema <- required_schema[order(required_schema$column_name), , drop = FALSE]
schema_ok <- nrow(live_schema) == nrow(required_schema) &&
  identical(as.character(live_schema$column_name),
            as.character(required_schema$column_name)) &&
  identical(as.character(live_schema$data_type),
            as.character(required_schema$data_type))
if (!schema_ok) {
  print(live_schema, row.names = FALSE)
  stop("academic_company_ref schema drifted from the required contract.")
}

athena_fold <- "lower(regexp_replace(normalize(trim(company), NFD), '\\p{M}', ''))"
query_sql <- sprintf("
  SELECT %1$s AS company_norm, company,
         CAST(rcid AS BIGINT) AS reference_rcid,
         CAST(child_rcid AS BIGINT) AS reference_child_rcid,
         CAST(ultimate_parent_rcid AS BIGINT) AS reference_ultimate_parent_rcid
  FROM %2$s.%3$s
  WHERE company IS NOT NULL AND %1$s IN (%4$s)",
  athena_fold, athena_schema, ref_table, in_names)
refs <- dbGetQuery(ath, query_sql)
try(dbDisconnect(ath), silent = TRUE)
if (!nrow(refs)) stop("No academic_company_ref.company value matched the ranked names.")
id_cols <- c("reference_rcid", "reference_child_rcid",
             "reference_ultimate_parent_rcid")
for (cc in id_cols) refs[[cc]] <- as.numeric(refs[[cc]])
id_values <- unlist(as.data.frame(refs)[id_cols], use.names = FALSE)
id_values <- id_values[!is.na(id_values)]
if (!length(id_values) || any(id_values < 1) ||
    any(id_values != floor(id_values)) ||
    any(id_values > .Machine$integer.max)) {
  stop("RAthena returned an invalid RCID representation.")
}
cat("reference rows returned:", format(nrow(refs), big.mark = ","), "\n")
dbWriteTable(con, "reference_hits", refs, overwrite = TRUE)

dbExecute(con, "
CREATE TABLE crosswalk AS
SELECT DISTINCT n.family, n.source_oa_id, n.canonical_oa_id, n.rank,
       n.ruf_institution_id, n.supplied_name AS institution_name,
       n.name_scope, n.name_variant, n.searched_name, n.searched_name_norm,
       r.company AS reference_company,
       CAST(r.reference_rcid AS BIGINT) AS reference_rcid,
       CAST(r.reference_child_rcid AS BIGINT) AS reference_child_rcid,
       CAST(r.reference_ultimate_parent_rcid AS BIGINT) AS reference_ultimate_parent_rcid,
       CAST(x.expanded_rcid AS BIGINT) AS expanded_rcid, x.rcid_role
FROM institution_names n
JOIN reference_hits r ON n.searched_name_norm=r.company_norm
CROSS JOIN (VALUES
  (r.reference_rcid, 'rcid'),
  (r.reference_child_rcid, 'child_rcid'),
  (r.reference_ultimate_parent_rcid, 'ultimate_parent_rcid')
) x(expanded_rcid, rcid_role)
WHERE x.expanded_rcid IS NOT NULL")

missing_expansion <- dbGetQuery(con, "
WITH expected AS (
  SELECT DISTINCT n.family,n.source_oa_id,n.canonical_oa_id,n.searched_name_norm,
         r.company,x.expanded_rcid,x.rcid_role
  FROM institution_names n JOIN reference_hits r
    ON n.searched_name_norm=r.company_norm
  CROSS JOIN (VALUES
    (r.reference_rcid, 'rcid'),
    (r.reference_child_rcid, 'child_rcid'),
    (r.reference_ultimate_parent_rcid, 'ultimate_parent_rcid')
  ) x(expanded_rcid,rcid_role)
  WHERE x.expanded_rcid IS NOT NULL
)
SELECT count(*) n FROM expected e WHERE NOT EXISTS (
 SELECT 1 FROM crosswalk c WHERE c.family=e.family
 AND c.source_oa_id=e.source_oa_id AND c.canonical_oa_id=e.canonical_oa_id
 AND c.searched_name_norm=e.searched_name_norm
 AND c.reference_company=e.company AND c.expanded_rcid=e.expanded_rcid
 AND c.rcid_role=e.rcid_role)")$n
if (missing_expansion != 0) stop(missing_expansion, " expected RCID expansions are missing.")

bad <- dbGetQuery(con, "SELECT count(*) n FROM crosswalk WHERE expanded_rcid IS NULL
                        OR family NOT IN ('ruf','shanghai')")$n
if (bad != 0) stop("Invalid row in the expanded university RCID crosswalk.")

summary <- dbGetQuery(con, "
  SELECT family, count(*) AS provenance_rows,
         count(DISTINCT source_oa_id) AS matched_source_institutions,
         count(DISTINCT canonical_oa_id) AS matched_canonical_institutions,
         count(DISTINCT searched_name_norm) AS matched_names,
         count(DISTINCT reference_rcid) AS matched_reference_rows,
         count(DISTINCT expanded_rcid) AS expanded_rcids
  FROM crosswalk GROUP BY family ORDER BY family")
roles <- dbGetQuery(con, "
  SELECT family, rcid_role, count(DISTINCT expanded_rcid) AS rcids
  FROM crosswalk GROUP BY family,rcid_role ORDER BY family,rcid_role")
unmatched <- dbGetQuery(con, "
  SELECT r.family,r.source_oa_id,r.canonical_oa_id,r.rank,r.supplied_name
  FROM ranked r WHERE NOT EXISTS (SELECT 1 FROM crosswalk c
    WHERE c.family=r.family AND c.source_oa_id=r.source_oa_id)
  ORDER BY family,rank,source_oa_id")
collisions <- dbGetQuery(con, "
  SELECT family,expanded_rcid,count(DISTINCT canonical_oa_id) AS n_institutions,
         string_agg(DISTINCT institution_name,' | ' ORDER BY institution_name) AS institutions
  FROM crosswalk GROUP BY family,expanded_rcid
  HAVING count(DISTINCT canonical_oa_id)>1
  ORDER BY family,n_institutions DESC,expanded_rcid")
print(summary, row.names = FALSE)
print(roles, row.names = FALSE)
cat("unmatched ranked source institutions:", nrow(unmatched), "\n")
cat("RCIDs mapped to multiple canonical institutions:", nrow(collisions), "\n")

stage_path <- paste0(out_path, ".staging")
if (file.exists(stage_path)) unlink(stage_path)
dbExecute(con, sprintf("
  COPY (SELECT * FROM crosswalk
        ORDER BY family,rank,source_oa_id,expanded_rcid,rcid_role,
                 searched_name_norm,name_scope,name_variant)
  TO '%s' (FORMAT PARQUET,COMPRESSION ZSTD)", fw(stage_path)))
stage_ds <- arrow::open_dataset(stage_path, format = "parquet")
if (nrow(stage_ds) != dbGetQuery(con, "SELECT count(*) n FROM crosswalk")$n) {
  stop("Staged crosswalk row count changed on Parquet reread.")
}

report <- list(
  generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
  method = list(
    source = paste0(athena_schema, ".", ref_table),
    source_field = "company",
    match = "trim + lowercase + NFD accent removal + whole-field equality",
    name_set = c("source OpenAlex display/cleaned", "unique-parent OpenAlex display/cleaned",
                 "Shanghai/RUF supplied full name"),
    excluded = c("child_company matching", "alternative names", "acronyms",
                 "segments", "substrings", "fuzzy matching"),
    expanded_fields = c("rcid", "child_rcid", "ultimate_parent_rcid")),
  inputs = data.frame(path = inputs, md5 = unname(tools::md5sum(inputs))),
  ranked_catalog = ranked_counts,
  names = name_counts,
  reference_rows = nrow(refs),
  summary = summary,
  rcid_roles = roles,
  unmatched_institutions = unmatched,
  multi_institution_rcids = collisions,
  checks = list(schema_verified = TRUE, complete_rcid_expansion = TRUE,
                no_null_expanded_rcid = TRUE,
                staged_rows_verified = TRUE))
jsonlite::write_json(report, paste0(report_path, ".staging"),
                     pretty = TRUE, auto_unbox = TRUE, na = "null")

prior <- c(out_path, report_path)
if (any(file.exists(prior))) {
  backup_dir <- file.path(out_dir, "backups", format(Sys.time(), "%Y%m%dT%H%M%S"))
  dir.create(backup_dir, recursive = TRUE, showWarnings = FALSE)
  for (p in prior[file.exists(prior)]) {
    if (!file.copy(p, file.path(backup_dir, basename(p)), overwrite = FALSE)) {
      stop("Could not back up ", p)
    }
  }
}
if (!file.rename(stage_path, out_path)) stop("Could not publish ", out_path)
if (!file.rename(paste0(report_path, ".staging"), report_path)) {
  stop("Could not publish ", report_path)
}
cat("\nPublished:\n  ", out_path, "\n  ", report_path, "\n", sep = "")
