####################################################################
### OpenAlex STEM 2017+ authors: Brazilian given-name score
###
### Local, offline pipeline. It filters the completed OpenAlex author
### products first, enriches the eligible authors with `full_name` from
### the local D:/OpenAlex/authors snapshot, and reproduces the exact
### IBGE/Bayes given-name method used by linkedin_br_name_flag.R.
###
### This is ranking evidence, not a nationality label. The assumed
### Brazilian share among eligible researchers is 2.5%. No network,
### S3, Athena, CRAN, or SEDAP runtime is involved.
####################################################################

for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)
library(duckdb)

####################################################################
### Paths, source manifest, and resources
####################################################################

openalex_root <- Sys.getenv("OPENALEX_ROOT", unset = "D:/OpenAlex")
obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)

author_dir <- file.path(openalex_root, "authors")
author_manifest <- file.path(author_dir, "manifest.json")
author_glob_override <- Sys.getenv("OPENALEX_BR_NAME_AUTHOR_GLOB", unset = "")

openalex_out <- file.path(
  obmep_root, "Data", "intermediate", "openalex_authors"
)
first_path <- file.path(
  openalex_out, "openalex_author_first_publication.parquet"
)
flags_path <- file.path(openalex_out, "openalex_author_flags.parquet")
ibge_path <- file.path(
  obmep_root, "Data", "intermediate", "ibge_names",
  "final_given_names_with_variants.parquet"
)

out_dir <- file.path(openalex_out, "br_name")
eligible_path <- file.path(out_dir, "eligible_authors.parquet")
ibge_long_path <- file.path(out_dir, "ibge_long.parquet")
counts_path <- file.path(out_dir, "firstname_counts.parquet")
matches_path <- file.path(out_dir, "firstname_matches.parquet")
final_path <- file.path(
  out_dir, "openalex_author_stem_2017plus_br_name_scores.parquet"
)

memory_limit <- Sys.getenv(
  "OPENALEX_BR_NAME_DUCKDB_MEMORY_LIMIT", unset = "16GB"
)
max_temp_size <- Sys.getenv(
  "OPENALEX_BR_NAME_DUCKDB_MAX_TEMP", unset = "50GB"
)
threads <- suppressWarnings(as.integer(Sys.getenv(
  "OPENALEX_BR_NAME_DUCKDB_THREADS", unset = "8"
)))
if (is.na(threads) || threads < 1L) {
  stop("OPENALEX_BR_NAME_DUCKDB_THREADS must be a positive integer.")
}

local_app_data <- Sys.getenv("LOCALAPPDATA", unset = tempdir())
duckdb_tmp <- Sys.getenv(
  "OPENALEX_BR_NAME_DUCKDB_TMP",
  unset = file.path(
    local_app_data, "OpenAlex", "duckdb_openalex_author_br_name"
  )
)
work_dir <- file.path(duckdb_tmp, "v1_full_name_comma")
eligible_core <- file.path(work_dir, "eligible_core.parquet")
full_name_matches <- file.path(work_dir, "full_name_matches.parquet")
full_name_matches_partial <- paste0(full_name_matches, ".partial")

for (input_path in c(first_path, flags_path, ibge_path)) {
  if (!file.exists(input_path) || file.info(input_path)$size <= 0) {
    stop("Required completed input is missing or empty: ", input_path)
  }
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(work_dir, recursive = TRUE, showWarnings = FALSE)

manifest_date <- as.Date(NA)
manifest_records <- NA_real_
manifest_bytes <- NA_real_
manifest_files <- NA_integer_

if (!nzchar(author_glob_override)) {
  if (!dir.exists(author_dir) || !file.exists(author_manifest)) {
    stop("OpenAlex authors snapshot or manifest is missing: ", author_dir)
  }
  manifest_lines <- readLines(author_manifest, warn = FALSE)
  date_line <- grep('"date"[[:space:]]*:', manifest_lines)[1]
  record_line <- grep('"record_count"[[:space:]]*:', manifest_lines)[1]
  bytes_line <- grep('"content_length"[[:space:]]*:', manifest_lines)[1]
  if (!is.na(date_line)) {
    manifest_date <- as.Date(sub(
      '.*"date"[[:space:]]*:[[:space:]]*"([0-9-]+)".*',
      '\\1', manifest_lines[date_line]
    ))
  }
  if (!is.na(record_line)) {
    manifest_records <- as.numeric(sub(
      '.*"record_count"[[:space:]]*:[[:space:]]*([0-9]+).*',
      '\\1', manifest_lines[record_line]
    ))
  }
  if (!is.na(bytes_line)) {
    manifest_bytes <- as.numeric(sub(
      '.*"content_length"[[:space:]]*:[[:space:]]*([0-9]+).*',
      '\\1', manifest_lines[bytes_line]
    ))
  }
  manifest_urls <- grep(
    '"url"[[:space:]]*:[[:space:]]*".*part_[0-9]+[.]parquet"',
    manifest_lines, value = TRUE
  )
  manifest_urls <- sub(
    '.*"url"[[:space:]]*:[[:space:]]*"([^"]+)".*',
    '\\1', manifest_urls
  )
  source_parts <- file.path(
    openalex_root,
    sub("^s3://openalex/data/parquet/", "", manifest_urls)
  )
  source_parts <- gsub("\\\\", "/", source_parts)
  manifest_files <- length(source_parts)
  if (
    is.na(manifest_date) || is.na(manifest_records) || manifest_records <= 0 ||
    is.na(manifest_bytes) || manifest_bytes <= 0 || manifest_files <= 0L
  ) {
    stop("OpenAlex authors manifest is incomplete or malformed.")
  }
} else {
  source_parts <- Sys.glob(author_glob_override)
  if (!length(source_parts)) {
    stop("OPENALEX_BR_NAME_AUTHOR_GLOB matched no parquet files.")
  }
  source_parts <- gsub("\\\\", "/", source_parts)
  source_info <- file.info(source_parts)
  if (any(is.na(source_info$size)) || any(source_info$size <= 0)) {
    stop("An overridden OpenAlex author source file is missing or empty.")
  }
  manifest_files <- length(source_parts)
  manifest_bytes <- sum(source_info$size)
}

source_parts_sql <- gsub("'", "''", source_parts, fixed = TRUE)
author_relation <- paste0("['", paste(source_parts_sql, collapse = "','"), "']")

path_sql <- gsub(
  "'", "''",
  gsub("\\\\", "/", c(
    first_path, flags_path, ibge_path, eligible_path, ibge_long_path,
    counts_path, matches_path, final_path, eligible_core,
    full_name_matches, full_name_matches_partial
  )),
  fixed = TRUE
)
names(path_sql) <- c(
  "first", "flags", "ibge", "eligible", "ibge_long", "counts",
  "matches", "final", "eligible_core", "full_name_matches",
  "full_name_matches_partial"
)

cat("OpenAlex author files :", manifest_files, "\n")
cat("OpenAlex author bytes :", sprintf("%.2f GiB", manifest_bytes / 1024^3), "\n")
if (!is.na(manifest_records)) {
  cat("Manifest authors     :", format(manifest_records, scientific = FALSE), "\n")
  cat("Manifest date        :", format(manifest_date), "\n")
}
cat("First-publication    :", first_path, "\n")
cat("Author flags         :", flags_path, "\n")
cat("IBGE names           :", ibge_path, "\n")
cat("Output directory     :", out_dir, "\n")
cat("DuckDB spill         :", duckdb_tmp, "\n")
cat("DuckDB resources     :", memory_limit, "RAM,", max_temp_size,
    "spill cap,", threads, "threads\n\n")

####################################################################
### DuckDB connection and input contracts
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
dbExecute(con, sprintf("SET memory_limit = '%s'", memory_limit))
dbExecute(con, sprintf("SET threads = %d", threads))
dbExecute(con, sprintf("SET temp_directory = '%s'", gsub(
  "'", "''", gsub("\\\\", "/", duckdb_tmp), fixed = TRUE
)))
dbExecute(con, sprintf("SET max_temp_directory_size = '%s'", max_temp_size))
dbExecute(con, "SET preserve_insertion_order = false")

first_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", path_sql["first"]
))
flags_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", path_sql["flags"]
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

####################################################################
### Given-name extraction expressions and regression test
####################################################################

particles <- c(
  "de", "da", "do", "dos", "das", "di", "del", "dello", "della",
  "du", "van", "von", "der", "den", "ter", "la", "le", "el",
  "al", "bin", "ibn", "dr", "dra", "prof", "eng", "sr", "sra",
  "mr", "ms", "mrs"
)
particle_sql <- paste0("'", particles, "'", collapse = ",")

full_side_expr <- paste0(
  "CASE WHEN contains(openalex_full_name, ',') ",
  "THEN split_part(openalex_full_name, ',', 2) ",
  "ELSE openalex_full_name END"
)
full_clean_expr <- paste0(
  "trim(regexp_replace(regexp_replace(lower(strip_accents(",
  full_side_expr,
  ")), '[^a-z ]', ' ', 'g'), ' +', ' ', 'g'))"
)
display_clean_expr <- paste0(
  "trim(regexp_replace(regexp_replace(lower(strip_accents(",
  "author_display_name)), '[^a-z ]', ' ', 'g'), ' +', ' ', 'g'))"
)
raw_clean_expr <- paste0(
  "trim(regexp_replace(regexp_replace(lower(strip_accents(",
  "raw_author_name)), '[^a-z ]', ' ', 'g'), ' +', ' ', 'g'))"
)
full_first_expr <- sprintf(
  "list_filter(str_split(%s, ' '), x -> length(x) >= 2 AND x NOT IN (%s))[1]",
  full_clean_expr, particle_sql
)
display_first_expr <- sprintf(
  "list_filter(str_split(%s, ' '), x -> length(x) >= 2 AND x NOT IN (%s))[1]",
  display_clean_expr, particle_sql
)
raw_first_expr <- sprintf(
  "list_filter(str_split(%s, ' '), x -> length(x) >= 2 AND x NOT IN (%s))[1]",
  raw_clean_expr, particle_sql
)

test_data <- data.frame(
  id = 1:9,
  openalex_full_name = c(
    "NAGASAKA, Mou", "Lili Wang", NA, NA, "de Souza, Jo\u00e3o",
    "Jim Perry-ECUMC", "I A Aboian", "\u82cf\u5e86\u9f99", "A B C"
  ),
  author_display_name = c(
    "Mou Nagasaka", "L Wang", "Dr. Ana Paula", NA, "Jo\u00e3o de Souza",
    "Jim Perry", "Aboian Ia", "Li Wang", "A B C"
  ),
  raw_author_name = c(
    "Mou Nagasaka", "Lili Wang", "Ana Paula", "Jos\u00e9 da Silva",
    "Jo\u00e3o de Souza", "Jim Perry", "I A Aboian", "Li Wang", "A B C"
  ),
  stringsAsFactors = FALSE
)
expected_token <- c(
  "mou", "lili", "ana", "jose", "joao", "jim", "aboian", "li", NA
)
expected_source <- c(
  "openalex_full_name", "openalex_full_name", "author_display_name",
  "raw_author_name", "openalex_full_name", "openalex_full_name",
  "openalex_full_name", "author_display_name", NA
)
expected_inverted <- c(TRUE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE, FALSE)
dbWriteTable(con, "name_test", test_data, temporary = TRUE)
test_result <- dbGetQuery(con, sprintf("
  WITH tokens AS (
    SELECT id, openalex_full_name,
           %s AS full_fn, %s AS display_fn, %s AS raw_fn
    FROM name_test
  )
  SELECT
    coalesce(full_fn, display_fn, raw_fn) AS first_name_clean,
    CASE WHEN full_fn IS NOT NULL THEN 'openalex_full_name'
         WHEN display_fn IS NOT NULL THEN 'author_display_name'
         WHEN raw_fn IS NOT NULL THEN 'raw_author_name' END AS first_name_source,
    CASE WHEN full_fn IS NOT NULL
         THEN contains(openalex_full_name, ',') ELSE FALSE END
      AS name_was_comma_inverted
  FROM tokens ORDER BY id",
  full_first_expr, display_first_expr, raw_first_expr
))
if (
  !identical(is.na(test_result$first_name_clean), is.na(expected_token)) ||
  !identical(
    test_result$first_name_clean[!is.na(expected_token)],
    expected_token[!is.na(expected_token)]
  ) ||
  !identical(is.na(test_result$first_name_source), is.na(expected_source)) ||
  !identical(
    test_result$first_name_source[!is.na(expected_source)],
    expected_source[!is.na(expected_source)]
  ) ||
  !identical(test_result$name_was_comma_inverted, expected_inverted)
) {
  print(cbind(test_data, test_result))
  stop("Given-name extraction regression test failed.")
}
cat("Name extraction test : 9 cases passed\n\n")

####################################################################
### 1. Filter first, then enrich eligible authors from D:/OpenAlex
####################################################################

if (file.exists(eligible_core) && !file.remove(eligible_core)) {
  stop("Could not replace temporary eligible-author core.")
}
cat(format(Sys.time()), "filtering STEM authors first published 2017+\n")
dbExecute(con, sprintf("
  COPY (
    SELECT
      p.author_id,
      p.author_url,
      p.author_display_name,
      p.raw_author_name,
      p.first_publication_year,
      f.ever_br_institution,
      f.ever_stem
    FROM read_parquet('%s') AS p
    INNER JOIN read_parquet('%s') AS f USING (author_id)
    WHERE p.first_publication_year >= 2017 AND f.ever_stem
    ORDER BY p.author_id
  ) TO '%s' (
    FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
  )", path_sql["first"], path_sql["flags"], path_sql["eligible_core"]
))

core_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT author_id) AS distinct_ids,
    count_if(author_id IS NULL OR author_url IS NULL) AS null_ids,
    count_if(author_display_name IS NULL) AS null_display_names,
    count_if(raw_author_name IS NULL) AS null_raw_names,
    count_if(author_display_name IS NULL AND raw_author_name IS NULL) AS null_both_names,
    count_if(first_publication_year < 2017 OR first_publication_year IS NULL) AS bad_year,
    count_if(NOT ever_stem OR ever_stem IS NULL) AS bad_stem
  FROM read_parquet('%s')", path_sql["eligible_core"]
))
if (
  core_check$rows == 0 || core_check$rows != core_check$distinct_ids ||
  core_check$null_ids != 0 || core_check$null_both_names != 0 ||
  core_check$bad_year != 0 || core_check$bad_stem != 0
) {
  stop("Eligible author core failed grain, NULL, year, or STEM validation.")
}
if (!nzchar(author_glob_override) && core_check$rows != 31899019) {
  stop(
    "Eligible author count changed: expected 31,899,019, obtained ",
    format(core_check$rows, scientific = FALSE), "."
  )
}

eligible_snapshot_date_sql <- if (is.na(manifest_date)) {
  "CAST(NULL AS DATE)"
} else {
  paste0("DATE '", format(manifest_date), "'")
}

eligible_schema_names <- c(
  "author_id", "author_url", "author_display_name", "raw_author_name",
  "openalex_full_name", "openalex_authors_snapshot_date",
  "first_publication_year", "ever_br_institution", "ever_stem"
)
eligible_schema_types <- c(
  "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "DATE",
  "INTEGER", "BOOLEAN", "BOOLEAN"
)

reuse_eligible <- FALSE
if (file.exists(eligible_path) && file.info(eligible_path)$size > 0) {
  cached_schema <- dbGetQuery(con, sprintf(
    "DESCRIBE SELECT * FROM read_parquet('%s')", path_sql["eligible"]
  ))
  if (
    identical(cached_schema$column_name, eligible_schema_names) &&
    identical(cached_schema$column_type, eligible_schema_types)
  ) {
    cached_check <- dbGetQuery(con, sprintf("
      SELECT
        count(*) AS rows,
        count(DISTINCT author_id) AS distinct_ids,
        count(DISTINCT openalex_authors_snapshot_date) AS n_snapshot_dates,
        min(openalex_authors_snapshot_date) AS snapshot_date
      FROM read_parquet('%s')", path_sql["eligible"]
    ))
    same_snapshot <- if (is.na(manifest_date)) {
      is.na(cached_check$snapshot_date)
    } else {
      !is.na(cached_check$snapshot_date) &&
        identical(as.Date(cached_check$snapshot_date), manifest_date)
    }
    reuse_eligible <- cached_check$rows == core_check$rows &&
      cached_check$rows == cached_check$distinct_ids && same_snapshot
  }
  if (!reuse_eligible) {
    stop(
      "Existing eligible_authors.parquet is incompatible with the current ",
      "source or contract. Inspect and remove it before rebuilding."
    )
  }
}

if (reuse_eligible) {
  cat(format(Sys.time()), "eligible author/full_name cache validated and reused\n")
} else {
  for (stale in c(full_name_matches, full_name_matches_partial)) {
    if (file.exists(stale) && !file.remove(stale)) {
      stop("Could not remove stale generated file: ", stale)
    }
  }
  cat(format(Sys.time()), "scanning author snapshot for enriched full_name\n")
  dbExecute(con, sprintf("
    COPY (
      WITH author_names AS (
        SELECT
          regexp_extract(id, 'A[0-9]+$') AS author_id,
          nullif(trim(full_name), '') AS openalex_full_name
        FROM read_parquet(%s, hive_partitioning = false)
        WHERE regexp_full_match(id, 'https://openalex[.]org/A[0-9]+')
      )
      SELECT a.author_id, a.openalex_full_name
      FROM author_names AS a
      INNER JOIN read_parquet('%s') AS e USING (author_id)
      ORDER BY a.author_id
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", author_relation, path_sql["eligible_core"],
    path_sql["full_name_matches_partial"]
  ))

  full_name_check <- dbGetQuery(con, sprintf("
    SELECT
      count(*) AS rows,
      count(DISTINCT author_id) AS distinct_ids,
      count(openalex_full_name) AS nonnull_full_names
    FROM read_parquet('%s')", path_sql["full_name_matches_partial"]
  ))
  if (
    full_name_check$rows != full_name_check$distinct_ids ||
    full_name_check$rows > core_check$rows
  ) {
    stop("OpenAlex full_name extraction has duplicate or excess author IDs.")
  }
  if (!file.rename(full_name_matches_partial, full_name_matches)) {
    stop("Could not commit the validated full_name extraction.")
  }

  eligible_partial <- paste0(eligible_path, ".partial")
  eligible_previous <- paste0(eligible_path, ".previous")
  if (file.exists(eligible_previous)) {
    stop("A previous eligible-author output remains; inspect it before rerunning.")
  }
  if (file.exists(eligible_partial) && !file.remove(eligible_partial)) {
    stop("Could not remove stale eligible-author partial.")
  }
  eligible_partial_sql <- gsub(
    "'", "''", gsub("\\\\", "/", eligible_partial), fixed = TRUE
  )
  dbExecute(con, sprintf("
    COPY (
      SELECT
        e.author_id,
        e.author_url,
        e.author_display_name,
        e.raw_author_name,
        n.openalex_full_name,
        %s AS openalex_authors_snapshot_date,
        e.first_publication_year,
        e.ever_br_institution,
        e.ever_stem
      FROM read_parquet('%s') AS e
      LEFT JOIN read_parquet('%s') AS n USING (author_id)
      ORDER BY e.author_id
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", eligible_snapshot_date_sql, path_sql["eligible_core"],
    path_sql["full_name_matches"], eligible_partial_sql
  ))

  eligible_schema <- dbGetQuery(con, sprintf(
    "DESCRIBE SELECT * FROM read_parquet('%s')", eligible_partial_sql
  ))
  eligible_check <- dbGetQuery(con, sprintf("
    SELECT
      count(*) AS rows,
      count(DISTINCT author_id) AS distinct_ids,
      count(openalex_full_name) AS full_name_rows,
      count_if(first_publication_year < 2017 OR NOT ever_stem) AS bad_filter
    FROM read_parquet('%s')", eligible_partial_sql
  ))
  if (
    !identical(eligible_schema$column_name, eligible_schema_names) ||
    !identical(eligible_schema$column_type, eligible_schema_types) ||
    eligible_check$rows != core_check$rows ||
    eligible_check$rows != eligible_check$distinct_ids ||
    eligible_check$bad_filter != 0
  ) {
    stop("Eligible-author cache failed schema, grain, or filter validation.")
  }

  had_previous <- file.exists(eligible_path)
  if (had_previous && !file.rename(eligible_path, eligible_previous)) {
    stop("Could not preserve the previous eligible-author output.")
  }
  if (!file.rename(eligible_partial, eligible_path)) {
    if (had_previous && file.exists(eligible_previous)) {
      file.rename(eligible_previous, eligible_path)
    }
    stop("Could not promote the eligible-author output.")
  }
  if (file.exists(eligible_previous)) file.remove(eligible_previous)
  if (file.exists(full_name_matches)) file.remove(full_name_matches)
  cat(format(Sys.time()), "eligible author/full_name cache promoted\n")
}

####################################################################
### 2. IBGE canonical names and variants
####################################################################

dbExecute(con, sprintf("
  CREATE OR REPLACE TEMP TABLE ibge_long AS
  WITH u AS (
    SELECT name_text AS token, frequency AS freq, TRUE AS is_canon,
           name_text AS parent, frequency AS parent_freq, rank AS canon_rank
    FROM read_parquet('%s')
    UNION ALL
    SELECT variant_text, variant_frequency, FALSE,
           name_text, frequency, NULL
    FROM read_parquet('%s')
    WHERE variant_text IS NOT NULL
  )
  SELECT
    token,
    max(freq) AS ibge_freq,
    max(is_canon) AS is_canonical,
    max(canon_rank) AS canon_rank,
    count(DISTINCT CASE WHEN NOT is_canon THEN parent END) AS n_parents,
    CASE WHEN max(is_canon) THEN token
         ELSE arg_max(parent, parent_freq) END AS primary_canonical
  FROM u
  GROUP BY token", path_sql["ibge"], path_sql["ibge"]
))

ibge_check <- dbGetQuery(con, "
  SELECT
    count(*) AS rows,
    count(DISTINCT token) AS distinct_tokens,
    sum(is_canonical::INTEGER) AS canonical_tokens,
    count_if(NOT is_canonical) AS variant_tokens,
    min(length(token)) AS min_length,
    max(length(token)) AS max_length,
    count_if(token IS NULL OR token <> lower(token)) AS bad_text,
    count_if(contains(token, ' ') OR regexp_matches(token, '[^a-z]')) AS bad_token,
    sum(ibge_freq) AS ibge_total
  FROM ibge_long
")
ibge_frequency_conflicts <- dbGetQuery(con, sprintf("
  WITH u AS (
    SELECT name_text AS token, frequency AS freq FROM read_parquet('%s')
    UNION ALL
    SELECT variant_text, variant_frequency FROM read_parquet('%s')
    WHERE variant_text IS NOT NULL
  )
  SELECT count(*) AS n FROM (
    SELECT token FROM u GROUP BY token HAVING count(DISTINCT freq) > 1
  )", path_sql["ibge"], path_sql["ibge"]
))$n
ibge_name_types <- dbGetQuery(con, sprintf(
  "SELECT count(DISTINCT name_type) AS n FROM read_parquet('%s')",
  path_sql["ibge"]
))$n
if (
  ibge_check$rows != 48539 || ibge_check$rows != ibge_check$distinct_tokens ||
  ibge_check$canonical_tokens != 12856 || ibge_check$variant_tokens != 35683 ||
  ibge_check$min_length < 2 || ibge_check$max_length > 13 ||
  ibge_check$bad_text != 0 || ibge_check$bad_token != 0 ||
  ibge_check$ibge_total != 184372093 || ibge_frequency_conflicts != 0 ||
  ibge_name_types != 1
) {
  stop("IBGE long table failed its established invariants.")
}

ibge_long_partial <- paste0(ibge_long_path, ".partial")
if (file.exists(ibge_long_partial)) file.remove(ibge_long_partial)
ibge_long_partial_sql <- gsub(
  "'", "''", gsub("\\\\", "/", ibge_long_partial), fixed = TRUE
)
dbExecute(con, sprintf("
  COPY (SELECT * FROM ibge_long ORDER BY token)
  TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", ibge_long_partial_sql
))
if (file.exists(ibge_long_path) && !file.remove(ibge_long_path)) {
  stop("Could not replace the prior IBGE long output.")
}
if (!file.rename(ibge_long_partial, ibge_long_path)) {
  stop("Could not promote the IBGE long output.")
}

####################################################################
### 3. Selected first-name counts over the filtered universe
####################################################################

cleaning_version <- "v1_full_name_comma_display_raw"
eligible_rows <- as.numeric(core_check$rows)
snapshot_date_literal <- if (is.na(manifest_date)) {
  "CAST(NULL AS DATE)"
} else {
  paste0("DATE '", format(manifest_date), "'")
}

reuse_counts <- FALSE
if (file.exists(counts_path) && file.info(counts_path)$size > 0) {
  counts_schema <- dbGetQuery(con, sprintf(
    "DESCRIBE SELECT * FROM read_parquet('%s')", path_sql["counts"]
  ))
  expected_counts_names <- c(
    "first_name_clean", "openalex_name_count", "cleaning_version",
    "eligible_author_count", "openalex_authors_snapshot_date"
  )
  expected_counts_types <- c(
    "VARCHAR", "BIGINT", "VARCHAR", "BIGINT", "DATE"
  )
  if (
    identical(counts_schema$column_name, expected_counts_names) &&
    identical(counts_schema$column_type, expected_counts_types)
  ) {
    counts_cache_check <- dbGetQuery(con, sprintf("
      SELECT
        count(*) AS names,
        count(DISTINCT first_name_clean) AS distinct_names,
        sum(openalex_name_count) AS named_authors,
        count(DISTINCT cleaning_version) AS versions,
        min(cleaning_version) AS version,
        count(DISTINCT eligible_author_count) AS eligible_values,
        min(eligible_author_count) AS eligible_count,
        min(openalex_authors_snapshot_date) AS snapshot_date
      FROM read_parquet('%s')", path_sql["counts"]
    ))
    same_snapshot <- if (is.na(manifest_date)) {
      is.na(counts_cache_check$snapshot_date)
    } else {
      !is.na(counts_cache_check$snapshot_date) &&
        identical(as.Date(counts_cache_check$snapshot_date), manifest_date)
    }
    reuse_counts <- counts_cache_check$names > 0 &&
      counts_cache_check$names == counts_cache_check$distinct_names &&
      counts_cache_check$versions == 1 &&
      counts_cache_check$version == cleaning_version &&
      counts_cache_check$eligible_values == 1 &&
      counts_cache_check$eligible_count == eligible_rows && same_snapshot
  }
}

if (reuse_counts) {
  cat(format(Sys.time()), "first-name counts cache validated and reused\n")
} else {
  counts_partial <- paste0(counts_path, ".partial")
  counts_previous <- paste0(counts_path, ".previous")
  if (file.exists(counts_previous)) {
    stop("A previous first-name count output remains; inspect it first.")
  }
  if (file.exists(counts_partial) && !file.remove(counts_partial)) {
    stop("Could not remove stale first-name count partial.")
  }
  counts_partial_sql <- gsub(
    "'", "''", gsub("\\\\", "/", counts_partial), fixed = TRUE
  )
  cat(format(Sys.time()), "counting selected first names\n")
  dbExecute(con, sprintf("
    COPY (
      WITH tokens AS (
        SELECT
          %s AS full_fn,
          %s AS display_fn,
          %s AS raw_fn
        FROM read_parquet('%s')
      ), selected AS (
        SELECT coalesce(full_fn, display_fn, raw_fn) AS first_name_clean
        FROM tokens
      )
      SELECT
        first_name_clean,
        CAST(count(*) AS BIGINT) AS openalex_name_count,
        '%s' AS cleaning_version,
        CAST(%.0f AS BIGINT) AS eligible_author_count,
        %s AS openalex_authors_snapshot_date
      FROM selected
      WHERE first_name_clean IS NOT NULL
      GROUP BY first_name_clean
      ORDER BY first_name_clean
    ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
    full_first_expr, display_first_expr, raw_first_expr,
    path_sql["eligible"], cleaning_version, eligible_rows,
    snapshot_date_literal, counts_partial_sql
  ))

  counts_check <- dbGetQuery(con, sprintf("
    SELECT
      count(*) AS names,
      count(DISTINCT first_name_clean) AS distinct_names,
      sum(openalex_name_count) AS named_authors,
      min(openalex_name_count) AS min_count
    FROM read_parquet('%s')", counts_partial_sql
  ))
  if (
    counts_check$names == 0 || counts_check$names != counts_check$distinct_names ||
    counts_check$named_authors > eligible_rows || counts_check$min_count < 1
  ) {
    stop("First-name counts failed grain or total validation.")
  }
  had_previous <- file.exists(counts_path)
  if (had_previous && !file.rename(counts_path, counts_previous)) {
    stop("Could not preserve the previous first-name counts.")
  }
  if (!file.rename(counts_partial, counts_path)) {
    if (had_previous && file.exists(counts_previous)) {
      file.rename(counts_previous, counts_path)
    }
    stop("Could not promote first-name counts.")
  }
  if (file.exists(counts_previous)) file.remove(counts_previous)
}

name_totals <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS distinct_names,
    sum(openalex_name_count) AS named_authors
  FROM read_parquet('%s')", path_sql["counts"]
))

####################################################################
### 4. Name-level evidence and score; always rebuilt
####################################################################

p_brazil_prior <- 0.025
matches_partial <- paste0(matches_path, ".partial")
matches_previous <- paste0(matches_path, ".previous")
if (file.exists(matches_previous)) {
  stop("A previous first-name match output remains; inspect it first.")
}
if (file.exists(matches_partial) && !file.remove(matches_partial)) {
  stop("Could not remove stale first-name match partial.")
}
matches_partial_sql <- gsub(
  "'", "''", gsub("\\\\", "/", matches_partial), fixed = TRUE
)

cat(format(Sys.time()), "building name-level Brazilian score\n")
dbExecute(con, sprintf("
  COPY (
    WITH evidence AS (
      SELECT
        c.first_name_clean,
        c.openalex_name_count,
        i.token IS NOT NULL AS flag_exact,
        CASE WHEN i.token IS NULL THEN NULL
             WHEN i.is_canonical THEN 'canonical'
             ELSE 'variant' END AS match_level,
        i.ibge_freq,
        i.canon_rank,
        i.n_parents,
        i.primary_canonical,
        c.openalex_name_count::DOUBLE / %.1f AS openalex_name_share,
        i.ibge_freq::DOUBLE / %.1f AS ibge_name_share
      FROM read_parquet('%s') AS c
      LEFT JOIN ibge_long AS i ON c.first_name_clean = i.token
    ), ratios AS (
      SELECT *, openalex_name_share / ibge_name_share AS ratio
      FROM evidence
    )
    SELECT
      *,
      log10(ratio) AS log10_ratio,
      %.10f::DOUBLE AS p_brazil_prior,
      CASE WHEN ratio IS NULL THEN NULL
           ELSE least(1.0, %.10f / ratio) END AS p_brazil
    FROM ratios
    ORDER BY first_name_clean
  ) TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)",
  as.numeric(name_totals$named_authors), as.numeric(ibge_check$ibge_total),
  path_sql["counts"], p_brazil_prior, p_brazil_prior,
  matches_partial_sql
))

matches_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS names,
    count(DISTINCT first_name_clean) AS distinct_names,
    sum(openalex_name_count) AS named_authors,
    count_if(NOT flag_exact AND p_brazil IS NOT NULL) AS bad_unmatched_score,
    count_if(flag_exact AND p_brazil IS NULL) AS bad_matched_score,
    count_if(p_brazil < 0 OR p_brazil > 1) AS bad_score_range,
    count_if(p_brazil_prior != %.10f) AS bad_prior
  FROM read_parquet('%s')", p_brazil_prior, matches_partial_sql
))
if (
  matches_check$names != name_totals$distinct_names ||
  matches_check$names != matches_check$distinct_names ||
  matches_check$named_authors != name_totals$named_authors ||
  matches_check$bad_unmatched_score != 0 ||
  matches_check$bad_matched_score != 0 ||
  matches_check$bad_score_range != 0 || matches_check$bad_prior != 0
) {
  stop("Name-level matches failed grain, NULL, prior, or score validation.")
}

had_previous <- file.exists(matches_path)
if (had_previous && !file.rename(matches_path, matches_previous)) {
  stop("Could not preserve the previous first-name matches.")
}
if (!file.rename(matches_partial, matches_path)) {
  if (had_previous && file.exists(matches_previous)) {
    file.rename(matches_previous, matches_path)
  }
  stop("Could not promote first-name matches.")
}
if (file.exists(matches_previous)) file.remove(matches_previous)

####################################################################
### 5. Author-level scored output; all eligible authors retained
####################################################################

final_partial <- paste0(final_path, ".partial")
final_previous <- paste0(final_path, ".previous")
if (file.exists(final_previous)) {
  stop("A previous final score output remains; inspect it first.")
}
if (file.exists(final_partial) && !file.remove(final_partial)) {
  stop("Could not remove stale final score partial.")
}
final_partial_sql <- gsub(
  "'", "''", gsub("\\\\", "/", final_partial), fixed = TRUE
)

cat(format(Sys.time()), "writing all eligible author scores\n")
dbExecute(con, sprintf("
  COPY (
    WITH tokens AS (
      SELECT
        *,
        %s AS full_fn,
        %s AS display_fn,
        %s AS raw_fn
      FROM read_parquet('%s')
    ), selected AS (
      SELECT
        *,
        coalesce(full_fn, display_fn, raw_fn) AS first_name_clean,
        CASE WHEN full_fn IS NOT NULL THEN 'openalex_full_name'
             WHEN display_fn IS NOT NULL THEN 'author_display_name'
             WHEN raw_fn IS NOT NULL THEN 'raw_author_name' END
          AS first_name_source,
        CASE WHEN full_fn IS NOT NULL
             THEN contains(openalex_full_name, ',') ELSE FALSE END
          AS name_was_comma_inverted
      FROM tokens
    )
    SELECT
      s.author_id,
      s.author_url,
      s.author_display_name,
      s.raw_author_name,
      s.openalex_full_name,
      s.openalex_authors_snapshot_date,
      s.first_publication_year,
      s.ever_br_institution,
      s.ever_stem,
      s.first_name_clean,
      s.first_name_source,
      s.name_was_comma_inverted,
      coalesce(m.flag_exact, FALSE) AS flag_exact,
      m.match_level,
      m.ibge_freq,
      m.canon_rank,
      m.n_parents,
      m.primary_canonical,
      m.openalex_name_count,
      m.openalex_name_share,
      m.ibge_name_share,
      m.ratio,
      m.log10_ratio,
      %.10f::DOUBLE AS p_brazil_prior,
      m.p_brazil
    FROM selected AS s
    LEFT JOIN read_parquet('%s') AS m USING (first_name_clean)
    ORDER BY s.author_id
  ) TO '%s' (
    FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
  )", full_first_expr, display_first_expr, raw_first_expr,
  path_sql["eligible"], p_brazil_prior, path_sql["matches"],
  final_partial_sql
))

expected_final_names <- c(
  "author_id", "author_url", "author_display_name", "raw_author_name",
  "openalex_full_name", "openalex_authors_snapshot_date",
  "first_publication_year", "ever_br_institution", "ever_stem",
  "first_name_clean", "first_name_source", "name_was_comma_inverted",
  "flag_exact", "match_level", "ibge_freq", "canon_rank", "n_parents",
  "primary_canonical", "openalex_name_count", "openalex_name_share",
  "ibge_name_share", "ratio", "log10_ratio", "p_brazil_prior",
  "p_brazil"
)
expected_final_types <- c(
  "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "DATE",
  "INTEGER", "BOOLEAN", "BOOLEAN", "VARCHAR", "VARCHAR", "BOOLEAN",
  "BOOLEAN", "VARCHAR", "INTEGER", "INTEGER", "BIGINT", "VARCHAR",
  "BIGINT", "DOUBLE", "DOUBLE", "DOUBLE", "DOUBLE", "DOUBLE", "DOUBLE"
)
final_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", final_partial_sql
))
if (
  !identical(final_schema$column_name, expected_final_names) ||
  !identical(final_schema$column_type, expected_final_types)
) {
  stop("Final author score schema does not match the contract.")
}

final_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT author_id) AS distinct_ids,
    count_if(first_publication_year < 2017 OR NOT ever_stem) AS bad_filter,
    count_if(first_name_clean IS NULL) AS null_tokens,
    count_if(first_name_clean IS NOT NULL AND openalex_name_count IS NULL)
      AS missing_name_evidence,
    count_if(NOT flag_exact AND p_brazil IS NOT NULL) AS bad_unmatched_score,
    count_if(flag_exact AND p_brazil IS NULL) AS bad_matched_score,
    count_if(p_brazil < 0 OR p_brazil > 1) AS bad_score_range,
    count_if(p_brazil_prior != %.10f) AS bad_prior,
    count_if(
      p_brazil IS NOT NULL AND
      abs(p_brazil - least(1.0, p_brazil_prior / ratio)) > 1e-12
    ) AS bad_formula,
    count_if(ever_br_institution) AS observed_br_affiliation
  FROM read_parquet('%s')", p_brazil_prior, final_partial_sql
))
if (
  final_check$rows != eligible_rows ||
  final_check$rows != final_check$distinct_ids ||
  final_check$bad_filter != 0 || final_check$missing_name_evidence != 0 ||
  final_check$bad_unmatched_score != 0 ||
  final_check$bad_matched_score != 0 ||
  final_check$bad_score_range != 0 || final_check$bad_prior != 0 ||
  final_check$bad_formula != 0 ||
  final_check$observed_br_affiliation <= 0 ||
  final_check$observed_br_affiliation >= final_check$rows
) {
  stop("Final author scores failed grain, filter, evidence, or score validation.")
}

source_mismatches <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n
  FROM read_parquet('%s') AS o
  INNER JOIN read_parquet('%s') AS e USING (author_id)
  WHERE o.author_url IS DISTINCT FROM e.author_url
     OR o.author_display_name IS DISTINCT FROM e.author_display_name
     OR o.raw_author_name IS DISTINCT FROM e.raw_author_name
     OR o.openalex_full_name IS DISTINCT FROM e.openalex_full_name
     OR o.first_publication_year IS DISTINCT FROM e.first_publication_year
     OR o.ever_br_institution IS DISTINCT FROM e.ever_br_institution
     OR o.ever_stem IS DISTINCT FROM e.ever_stem",
  final_partial_sql, path_sql["eligible"]
))$n
if (source_mismatches != 0) {
  stop("Final author provenance disagrees with the eligible-author cache.")
}

author_bands <- dbGetQuery(con, sprintf("
  SELECT
    count_if(flag_exact) AS any_match,
    count_if(match_level = 'canonical') AS canonical_match,
    count_if(match_level = 'variant') AS variant_match,
    count_if(p_brazil > 0.05) AS score_gt_005,
    count_if(p_brazil >= 0.25) AS score_ge_025,
    count_if(p_brazil >= 0.50) AS score_ge_050,
    count_if(p_brazil >= 0.90) AS score_ge_090
  FROM read_parquet('%s')", final_partial_sql
))
name_weighted_bands <- dbGetQuery(con, sprintf("
  SELECT
    sum(CASE WHEN flag_exact THEN openalex_name_count ELSE 0 END) AS any_match,
    sum(CASE WHEN match_level = 'canonical' THEN openalex_name_count ELSE 0 END)
      AS canonical_match,
    sum(CASE WHEN match_level = 'variant' THEN openalex_name_count ELSE 0 END)
      AS variant_match,
    sum(CASE WHEN p_brazil > 0.05 THEN openalex_name_count ELSE 0 END)
      AS score_gt_005,
    sum(CASE WHEN p_brazil >= 0.25 THEN openalex_name_count ELSE 0 END)
      AS score_ge_025,
    sum(CASE WHEN p_brazil >= 0.50 THEN openalex_name_count ELSE 0 END)
      AS score_ge_050,
    sum(CASE WHEN p_brazil >= 0.90 THEN openalex_name_count ELSE 0 END)
      AS score_ge_090
  FROM read_parquet('%s')", path_sql["matches"]
))
if (!identical(
  as.numeric(unlist(author_bands[1, ], use.names = FALSE)),
  as.numeric(unlist(name_weighted_bands[1, ], use.names = FALSE))
)) {
  stop("Name-level weighted score bands disagree with author-level bands.")
}
name_source_diagnostic <- dbGetQuery(con, sprintf("
  SELECT
    coalesce(first_name_source, 'unparseable') AS first_name_source,
    count(*) AS authors,
    count_if(openalex_full_name IS NOT NULL) AS has_openalex_full_name,
    count_if(name_was_comma_inverted) AS comma_inverted,
    count_if(flag_exact) AS exact_matches,
    coalesce(count_if(p_brazil >= 0.50), 0) AS score_ge_050
  FROM read_parquet('%s')
  GROUP BY first_name_source
  ORDER BY first_name_source", final_partial_sql
))
affiliation_diagnostic <- dbGetQuery(con, sprintf("
  SELECT
    ever_br_institution,
    count(*) AS authors,
    count_if(first_name_clean IS NULL) AS null_tokens,
    count_if(flag_exact) AS exact_matches,
    count_if(p_brazil >= 0.50) AS score_ge_050,
    median(p_brazil) FILTER (WHERE p_brazil IS NOT NULL) AS median_score
  FROM read_parquet('%s')
  GROUP BY ever_br_institution
  ORDER BY ever_br_institution", final_partial_sql
))

print(core_check, row.names = FALSE)
print(final_check, row.names = FALSE)
print(author_bands, row.names = FALSE)
print(name_source_diagnostic, row.names = FALSE)
print(affiliation_diagnostic, row.names = FALSE)
cat("Final partial size    :",
    sprintf("%.2f GiB", file.info(final_partial)$size / 1024^3), "\n")

had_previous <- file.exists(final_path)
if (had_previous && !file.rename(final_path, final_previous)) {
  stop("Could not preserve the previous final score output.")
}
if (!file.rename(final_partial, final_path)) {
  if (had_previous && file.exists(final_previous)) {
    file.rename(final_previous, final_path)
  }
  stop("Could not promote the final author score output.")
}
if (file.exists(final_previous)) file.remove(final_previous)

if (file.exists(eligible_core)) file.remove(eligible_core)
if (file.exists(full_name_matches)) file.remove(full_name_matches)

cat("\nFinal outputs\n")
for (output_path in c(
  eligible_path, ibge_long_path, counts_path, matches_path, final_path
)) {
  cat(" ", output_path, "\n")
  cat("    size:", sprintf("%.2f MiB", file.info(output_path)$size / 1024^2), "\n")
}
cat("Completed:", format(Sys.time()), "\n")
