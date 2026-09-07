####################################################################
### OpenAlex Brazilian-affiliated STEM authors first published 2017+
###
### Local, offline pipeline. It joins two completed OpenAlex author
### parquet products in the OBMEP Dropbox and writes one derived final
### parquet there. It does not read the works snapshot, use the network,
### or run inside SEDAP.
####################################################################

for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(duckdb)

####################################################################
### Paths and resources
####################################################################

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)
out_dir <- file.path(
  obmep_root, "Data", "intermediate", "openalex_authors"
)
first_path <- file.path(
  out_dir, "openalex_author_first_publication.parquet"
)
flags_path <- file.path(out_dir, "openalex_author_flags.parquet")
derived_path <- file.path(
  out_dir, "openalex_author_br_stem_2017plus.parquet"
)
derived_partial <- paste0(derived_path, ".partial")
derived_previous <- paste0(derived_path, ".previous")

memory_limit <- Sys.getenv(
  "OPENALEX_DERIVED_DUCKDB_MEMORY_LIMIT", unset = "4GB"
)
threads <- suppressWarnings(as.integer(Sys.getenv(
  "OPENALEX_DERIVED_DUCKDB_THREADS", unset = "4"
)))
if (is.na(threads) || threads < 1L) {
  stop("OPENALEX_DERIVED_DUCKDB_THREADS must be a positive integer.")
}

for (input_path in c(first_path, flags_path)) {
  if (!file.exists(input_path) || file.info(input_path)$size <= 0) {
    stop("Required completed input is missing or empty: ", input_path)
  }
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
if (file.exists(derived_previous)) {
  stop(
    "A .previous output remains from an interrupted promotion. ",
    "Inspect it before rerunning."
  )
}
if (file.exists(derived_partial) && !file.remove(derived_partial)) {
  stop("Could not remove stale partial output: ", derived_partial)
}

first_sql <- gsub(
  "'", "''", gsub("\\\\", "/", first_path), fixed = TRUE
)
flags_sql <- gsub(
  "'", "''", gsub("\\\\", "/", flags_path), fixed = TRUE
)
partial_sql <- gsub(
  "'", "''", gsub("\\\\", "/", derived_partial), fixed = TRUE
)

cat("First-publication input :", first_path, "\n")
cat("Author-flags input      :", flags_path, "\n")
cat("Derived output          :", derived_path, "\n")
cat("DuckDB resources        :", memory_limit, "RAM,", threads,
    "threads\n\n")

####################################################################
### Validate inputs and build the derived parquet
####################################################################

con <- dbConnect(duckdb())
dbExecute(con, sprintf("SET memory_limit = '%s'", memory_limit))
dbExecute(con, sprintf("SET threads = %d", threads))
dbExecute(con, "SET preserve_insertion_order = false")

first_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", first_sql
))
flags_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", flags_sql
))
expected_first_names <- c(
  "author_id", "author_url", "author_display_name", "raw_author_name",
  "first_publication_year"
)
expected_first_types <- c(
  "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "INTEGER"
)
expected_flag_names <- c(
  "author_id", "author_url", "author_display_name", "raw_author_name",
  "ever_br_institution", "ever_stem"
)
expected_flag_types <- c(
  "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "BOOLEAN", "BOOLEAN"
)
if (
  !identical(first_schema$column_name, expected_first_names) ||
  !identical(first_schema$column_type, expected_first_types)
) {
  stop("First-publication input schema does not match the contract.")
}
if (
  !identical(flags_schema$column_name, expected_flag_names) ||
  !identical(flags_schema$column_type, expected_flag_types)
) {
  stop("Author-flags input schema does not match the contract.")
}

cat(format(Sys.time()), "writing filtered author parquet\n")
dbExecute(con, sprintf("
  COPY (
    SELECT
      f.author_id,
      f.author_url,
      f.author_display_name,
      f.raw_author_name,
      p.first_publication_year,
      f.ever_br_institution,
      f.ever_stem
    FROM read_parquet('%s') AS f
    INNER JOIN read_parquet('%s') AS p USING (author_id)
    WHERE f.ever_br_institution
      AND f.ever_stem
      AND p.first_publication_year >= 2017
    ORDER BY f.author_id
  ) TO '%s' (
    FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
  )", flags_sql, first_sql, partial_sql))

####################################################################
### Validate and promote
####################################################################

derived_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", partial_sql
))
expected_derived_names <- c(
  "author_id", "author_url", "author_display_name", "raw_author_name",
  "first_publication_year", "ever_br_institution", "ever_stem"
)
expected_derived_types <- c(
  "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "INTEGER", "BOOLEAN",
  "BOOLEAN"
)
if (
  !identical(derived_schema$column_name, expected_derived_names) ||
  !identical(derived_schema$column_type, expected_derived_types)
) {
  stop("Derived output schema does not match the contract.")
}

derived_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT author_id) AS distinct_author_ids,
    count(DISTINCT author_url) AS distinct_author_urls,
    count_if(author_id IS NULL OR author_url IS NULL) AS null_ids,
    count_if(
      author_display_name IS NULL OR raw_author_name IS NULL
    ) AS null_names,
    count_if(first_publication_year IS NULL) AS null_years,
    min(first_publication_year) AS min_year,
    max(first_publication_year) AS max_year,
    count_if(
      ever_br_institution IS NULL OR ever_stem IS NULL
    ) AS null_flags,
    count_if(NOT ever_br_institution OR NOT ever_stem) AS false_flags
  FROM read_parquet('%s')", partial_sql))

expected_rows <- 843232
if (
  derived_check$rows != expected_rows ||
  derived_check$rows != derived_check$distinct_author_ids ||
  derived_check$rows != derived_check$distinct_author_urls ||
  derived_check$null_ids != 0 ||
  derived_check$null_names != 0 ||
  derived_check$null_years != 0 ||
  derived_check$min_year != 2017 ||
  derived_check$max_year != 2026 ||
  derived_check$null_flags != 0 ||
  derived_check$false_flags != 0
) {
  stop("Derived output failed row, grain, range, or NULL validation.")
}

source_mismatches <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n
  FROM read_parquet('%s') AS o
  INNER JOIN read_parquet('%s') AS f USING (author_id)
  INNER JOIN read_parquet('%s') AS p USING (author_id)
  WHERE o.author_url IS DISTINCT FROM f.author_url
     OR o.author_url IS DISTINCT FROM p.author_url
     OR o.author_display_name IS DISTINCT FROM f.author_display_name
     OR o.author_display_name IS DISTINCT FROM p.author_display_name
     OR o.raw_author_name IS DISTINCT FROM f.raw_author_name
     OR o.raw_author_name IS DISTINCT FROM p.raw_author_name
     OR o.first_publication_year IS DISTINCT FROM p.first_publication_year
     OR o.ever_br_institution IS DISTINCT FROM f.ever_br_institution
     OR o.ever_stem IS DISTINCT FROM f.ever_stem",
  partial_sql, flags_sql, first_sql
))$n
if (source_mismatches != 0) {
  stop("Derived IDs, names, year, or flags disagree with the inputs.")
}

year_counts <- dbGetQuery(con, sprintf("
  SELECT first_publication_year, count(*) AS authors
  FROM read_parquet('%s')
  GROUP BY first_publication_year
  ORDER BY first_publication_year", partial_sql))
expected_years <- 2017:2026
expected_year_counts <- c(
  85854, 86206, 90691, 95966, 91809,
  92805, 83796, 79725, 52781, 83599
)
if (
  !identical(as.integer(year_counts$first_publication_year), expected_years) ||
  !identical(as.numeric(year_counts$authors), expected_year_counts) ||
  sum(year_counts$authors) != expected_rows
) {
  stop("Derived first-publication-year distribution changed.")
}

print(derived_check, row.names = FALSE)
print(year_counts, row.names = FALSE)
cat("Validated partial size :",
    sprintf("%.2f MiB", file.info(derived_partial)$size / 1024^2), "\n")

had_previous <- file.exists(derived_path)
if (had_previous && !file.rename(derived_path, derived_previous)) {
  stop("Could not preserve the previous derived output.")
}
if (!file.rename(derived_partial, derived_path)) {
  if (had_previous && file.exists(derived_previous)) {
    file.rename(derived_previous, derived_path)
  }
  stop("Could not promote the validated derived output.")
}
if (had_previous && file.exists(derived_previous)) {
  if (!file.remove(derived_previous)) {
    warning("Derived output promoted, but .previous could not be removed.")
  }
}

dbDisconnect(con, shutdown = TRUE)

cat("\nPromoted final output :", derived_path, "\n")
cat("Final size           :",
    sprintf("%.2f MiB", file.info(derived_path)$size / 1024^2), "\n")
cat("Completed            :", format(Sys.time()), "\n")
