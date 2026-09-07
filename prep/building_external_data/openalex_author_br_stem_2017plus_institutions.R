####################################################################
### Institution histories for the 2017+ Brazilian-affiliated STEM cohort
###
### Local, offline pipeline. It reads the already-downloaded OpenAlex
### works parquet snapshot from D:/OpenAlex, restricts extraction to the
### completed 843,232-author cohort, and writes a separate enriched final
### parquet into the OBMEP Dropbox. It does not use the network and is not
### SEDAP-bound.
####################################################################

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

openalex_root <- Sys.getenv("OPENALEX_ROOT", unset = "D:/OpenAlex")
obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)
out_dir <- file.path(
  obmep_root, "Data", "intermediate", "openalex_authors"
)
default_cohort_path <- file.path(
  out_dir, "openalex_author_br_stem_2017plus.parquet"
)
cohort_path <- Sys.getenv(
  "OPENALEX_COHORT_PATH", unset = default_cohort_path
)
default_output_path <- file.path(
  out_dir, "openalex_author_br_stem_2017plus_institutions.parquet"
)
output_path <- Sys.getenv(
  "OPENALEX_COHORT_INST_OUTPUT_PATH", unset = default_output_path
)
output_partial <- paste0(output_path, ".partial")
output_previous <- paste0(output_path, ".previous")

default_works_glob <- file.path(
  openalex_root, "works", "updated_date=*", "part_*.parquet"
)
works_glob_override <- Sys.getenv("OPENALEX_WORKS_GLOB", unset = "")
works_glob <- if (nzchar(works_glob_override)) {
  works_glob_override
} else {
  default_works_glob
}

local_app_data <- Sys.getenv(
  "LOCALAPPDATA", unset = "C:/Users/megaj/AppData/Local"
)
duckdb_tmp <- Sys.getenv(
  "OPENALEX_COHORT_INST_DUCKDB_TMP",
  unset = file.path(
    local_app_data, "OpenAlex",
    "duckdb_openalex_author_br_stem_2017plus_institutions"
  )
)
batch_size <- 5L
author_buckets <- 64L
cache_version <- Sys.getenv(
  "OPENALEX_COHORT_INST_CACHE_VERSION", unset = "v1_batch5_b64"
)
if (!grepl("^[A-Za-z0-9_.-]+$", cache_version)) {
  stop("OPENALEX_COHORT_INST_CACHE_VERSION contains unsafe characters.")
}
cache_dir <- file.path(duckdb_tmp, cache_version)
batch_dir <- file.path(cache_dir, "institution_batches")
pair_bucket_dir <- file.path(cache_dir, "author_pair_buckets")
spill_dir <- file.path(cache_dir, "spill")
institution_dim <- file.path(cache_dir, "institution_dimension.parquet")
history_path <- file.path(cache_dir, "author_histories.parquet")

memory_limit <- Sys.getenv(
  "OPENALEX_COHORT_INST_DUCKDB_MEMORY_LIMIT", unset = "22GB"
)
max_temp_size <- Sys.getenv(
  "OPENALEX_COHORT_INST_DUCKDB_MAX_TEMP", unset = "55GB"
)
threads <- suppressWarnings(as.integer(Sys.getenv(
  "OPENALEX_COHORT_INST_DUCKDB_THREADS", unset = "8"
)))
if (is.na(threads) || threads < 1L) {
  stop("OPENALEX_COHORT_INST_DUCKDB_THREADS must be a positive integer.")
}
require_br <- tolower(Sys.getenv(
  "OPENALEX_COHORT_INST_REQUIRE_BR", unset = "true"
))
if (!require_br %in% c("true", "false")) {
  stop("OPENALEX_COHORT_INST_REQUIRE_BR must be true or false.")
}
require_br <- identical(require_br, "true")
expected_authors <- suppressWarnings(as.numeric(Sys.getenv(
  "OPENALEX_COHORT_INST_EXPECTED_AUTHORS", unset = "843232"
)))
if (is.na(expected_authors) || expected_authors <= 0) {
  stop("OPENALEX_COHORT_INST_EXPECTED_AUTHORS must be positive.")
}

if (file.exists(output_path)) {
  cat("Final output already exists: ", output_path, "\n", sep = "")
  cat("Remove it explicitly before requesting a full rebuild.\n")
  quit(save = "no", status = 0L)
}
if (file.exists(output_previous)) {
  stop(
    "A .previous output remains from an interrupted promotion. ",
    "Inspect it before rerunning."
  )
}
if (!file.exists(cohort_path) || file.info(cohort_path)$size <= 0) {
  stop("Completed cohort is missing or empty: ", cohort_path)
}

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(duckdb_tmp, recursive = TRUE, showWarnings = FALSE)
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(batch_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(pair_bucket_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(spill_dir, recursive = TRUE, showWarnings = FALSE)
if (file.exists(output_partial) && !file.remove(output_partial)) {
  stop("Could not remove stale partial output: ", output_partial)
}

####################################################################
### Manifest and source parts
####################################################################

manifest_path <- file.path(openalex_root, "works", "manifest.json")
manifest_records <- NA_real_
manifest_files <- NA_integer_
manifest_bytes <- NA_real_

if (!nzchar(works_glob_override)) {
  stopifnot(
    dir.exists(file.path(openalex_root, "works")),
    file.exists(manifest_path)
  )
  manifest_lines <- readLines(manifest_path, warn = FALSE)
  record_line <- grep(
    '"record_count"[[:space:]]*:', manifest_lines
  )[1]
  bytes_line <- grep(
    '"content_length"[[:space:]]*:', manifest_lines
  )[1]
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
  manifest_files <- sum(grepl(
    '"url"[[:space:]]*:[[:space:]]*".*part_[0-9]+[.]parquet"',
    manifest_lines
  ))
  stopifnot(
    !is.na(manifest_records), manifest_records > 0,
    !is.na(manifest_bytes), manifest_bytes > 0,
    !is.na(manifest_files), manifest_files > 0L
  )
  if (
    manifest_files != 2446L ||
    manifest_records != 510372821 ||
    manifest_bytes != 724970323127
  ) {
    stop("The works manifest differs from the documented cohort snapshot.")
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
  part_count <- manifest_files
  input_bytes <- manifest_bytes
} else {
  parts <- Sys.glob(works_glob)
  stopifnot(length(parts) > 0L)
  part_info <- file.info(parts)
  stopifnot(!any(is.na(part_info$size)), all(part_info$size > 0))
  source_parts <- gsub("\\\\", "/", parts)
  part_count <- length(source_parts)
  input_bytes <- sum(part_info$size)
}

n_batches <- ceiling(length(source_parts) / batch_size)
batch_glob <- gsub(
  "'", "''",
  gsub("\\\\", "/", file.path(batch_dir, "batch_*.parquet")),
  fixed = TRUE
)
pair_bucket_glob <- gsub(
  "'", "''",
  gsub("\\\\", "/", file.path(pair_bucket_dir, "bucket_*.parquet")),
  fixed = TRUE
)
cohort_sql <- gsub(
  "'", "''", gsub("\\\\", "/", cohort_path), fixed = TRUE
)
output_partial_sql <- gsub(
  "'", "''", gsub("\\\\", "/", output_partial), fixed = TRUE
)
institution_dim_sql <- gsub(
  "'", "''", gsub("\\\\", "/", institution_dim), fixed = TRUE
)
history_path_sql <- gsub(
  "'", "''", gsub("\\\\", "/", history_path), fixed = TRUE
)

cat("OpenAlex works parts :", part_count, "\n")
cat("Input size           :", sprintf("%.2f GiB", input_bytes / 1024^3), "\n")
if (!is.na(manifest_records)) {
  cat("Manifest works       :", format(manifest_records, scientific = FALSE), "\n")
}
cat("Cohort input         :", cohort_path, "\n")
cat("Final output         :", output_path, "\n")
cat("Checkpoint root      :", cache_dir, "\n")
cat("Bounded aggregation  :", n_batches, "batches x",
    author_buckets, "author buckets\n")
cat("DuckDB resources     :", memory_limit, "RAM,", max_temp_size,
    "spill cap,", threads, "threads\n\n")

####################################################################
### DuckDB connection and cohort contract
####################################################################

con <- dbConnect(duckdb())
dbExecute(con, sprintf(
  "SET temp_directory = '%s'",
  gsub("'", "''", gsub("\\\\", "/", spill_dir), fixed = TRUE)
))
dbExecute(con, sprintf("SET memory_limit = '%s'", memory_limit))
dbExecute(con, sprintf(
  "SET max_temp_directory_size = '%s'", max_temp_size
))
dbExecute(con, sprintf("SET threads = %d", threads))
dbExecute(con, "SET preserve_insertion_order = false")

cohort_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", cohort_sql
))
expected_cohort_names <- c(
  "author_id", "author_url", "author_display_name", "raw_author_name",
  "first_publication_year", "ever_br_institution", "ever_stem"
)
expected_cohort_types <- c(
  "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "INTEGER", "BOOLEAN",
  "BOOLEAN"
)
if (
  !identical(cohort_schema$column_name, expected_cohort_names) ||
  !identical(cohort_schema$column_type, expected_cohort_types)
) {
  stop("Cohort input schema does not match the seven-column contract.")
}

cohort_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT author_id) AS distinct_author_ids,
    count(DISTINCT author_url) AS distinct_author_urls,
    count_if(author_id IS NULL OR author_url IS NULL) AS null_ids,
    count_if(
      NOT ever_stem OR
      (%s AND NOT ever_br_institution)
    ) AS false_flags,
    min(first_publication_year) AS min_year,
    max(first_publication_year) AS max_year
  FROM read_parquet('%s')",
  if (require_br) "true" else "false", cohort_sql
))
if (
  cohort_check$rows <= 0 ||
  cohort_check$rows != cohort_check$distinct_author_ids ||
  cohort_check$rows != cohort_check$distinct_author_urls ||
  cohort_check$null_ids != 0 ||
  cohort_check$false_flags != 0 ||
  cohort_check$min_year < 2017 ||
  (require_br && cohort_check$max_year > 2026)
) {
  stop("Cohort input failed grain, flag, or year validation.")
}
if (cohort_check$rows != expected_authors) {
  stop(
    "Expected ", format(expected_authors, scientific = FALSE),
    " authors in the requested cohort; found ",
    format(cohort_check$rows, scientific = FALSE), "."
  )
}

dbExecute(con, sprintf("
  CREATE TEMP TABLE target_authors AS
  SELECT author_id, author_url
  FROM read_parquet('%s')", cohort_sql))

####################################################################
### 1. Resumable source extraction
####################################################################

cat(format(Sys.time()), "building targeted institution batches\n")

for (batch_id in seq_len(n_batches)) {
  batch_path <- file.path(
    batch_dir, sprintf("batch_%04d.parquet", batch_id)
  )
  batch_partial <- paste0(batch_path, ".partial")
  if (file.exists(batch_path) && file.info(batch_path)$size > 0) {
    cat(format(Sys.time()), "institution batch", batch_id, "/",
        n_batches, "cached\n")
    next
  }
  if (file.exists(batch_path) && !file.remove(batch_path)) {
    stop("Could not remove invalid batch checkpoint: ", batch_path)
  }
  if (file.exists(batch_partial) && !file.remove(batch_partial)) {
    stop("Could not remove incomplete batch checkpoint: ", batch_partial)
  }

  lo <- (batch_id - 1L) * batch_size + 1L
  hi <- min(batch_id * batch_size, length(source_parts))
  batch_parts <- gsub("'", "''", source_parts[lo:hi], fixed = TRUE)
  batch_relation <- paste0(
    "['", paste(batch_parts, collapse = "','"), "']"
  )
  batch_partial_sql <- gsub(
    "'", "''", gsub("\\\\", "/", batch_partial), fixed = TRUE
  )

  dbExecute(con, sprintf("
    COPY (
      WITH matched_mentions AS (
        SELECT
          t.author_id,
          t.author_url,
          i.id AS institution_url,
          CASE
            WHEN trim(coalesce(i.display_name, '')) <> ''
            THEN i.display_name
          END AS institution_display_name,
          CASE
            WHEN trim(coalesce(i.country_code, '')) <> ''
            THEN i.country_code
          END AS country_code,
          w.publication_year
        FROM read_parquet(%s, hive_partitioning = false) AS w,
             UNNEST(w.authorships) AS u(a)
        INNER JOIN target_authors AS t
          ON a.author.id = t.author_url,
             UNNEST(a.institutions) AS ui(i)
        WHERE coalesce(
          regexp_full_match(i.id, 'https://openalex[.]org/I[0-9]+'),
          false
        )
      )
      SELECT
        CAST(hash(author_url) %% %d AS INTEGER) AS author_bucket,
        author_id,
        author_url,
        institution_url,
        institution_display_name,
        country_code,
        CAST(min(publication_year) AS INTEGER) AS first_publication_year,
        CAST(count(*) AS BIGINT) AS association_mentions
      FROM matched_mentions
      GROUP BY
        author_id, author_url, institution_url,
        institution_display_name, country_code
      ORDER BY author_bucket
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", batch_relation, author_buckets, batch_partial_sql))

  batch_check <- dbGetQuery(con, sprintf("
    SELECT
      count(*) AS rows,
      coalesce(count_if(author_id IS NULL OR author_url IS NULL OR
               institution_url IS NULL), 0) AS null_ids,
      coalesce(count_if(NOT regexp_full_match(
        institution_url, 'https://openalex[.]org/I[0-9]+'
      )), 0) AS bad_institution_ids,
      coalesce(count_if(author_bucket < 0 OR author_bucket >= %d), 0)
        AS bad_buckets,
      coalesce(count_if(association_mentions <= 0), 0) AS bad_counts
    FROM read_parquet('%s')",
    author_buckets, batch_partial_sql
  ))
  if (
    batch_check$null_ids != 0 ||
    batch_check$bad_institution_ids != 0 ||
    batch_check$bad_buckets != 0 ||
    batch_check$bad_counts != 0
  ) {
    stop("Validation failed for batch checkpoint: ", batch_partial)
  }
  if (!file.rename(batch_partial, batch_path)) {
    stop("Could not commit batch checkpoint: ", batch_path)
  }
  cat(format(Sys.time()), "institution batch", batch_id, "/",
      n_batches, "complete;",
      format(batch_check$rows, scientific = FALSE), "groups\n")
}

####################################################################
### 2. Stable institution metadata
####################################################################

if (!file.exists(institution_dim) || file.info(institution_dim)$size <= 0) {
  institution_dim_partial <- paste0(institution_dim, ".partial")
  if (file.exists(institution_dim)) file.remove(institution_dim)
  if (
    file.exists(institution_dim_partial) &&
    !file.remove(institution_dim_partial)
  ) {
    stop("Could not remove incomplete institution dimension.")
  }
  institution_dim_partial_sql <- gsub(
    "'", "''",
    gsub("\\\\", "/", institution_dim_partial), fixed = TRUE
  )
  cat(format(Sys.time()), "building institution dimension\n")
  dbExecute(con, sprintf("
    COPY (
      WITH institutions AS (
        SELECT DISTINCT institution_url
        FROM read_parquet('%s')
      ),
      name_counts AS (
        SELECT
          institution_url,
          institution_display_name,
          sum(association_mentions) AS n
        FROM read_parquet('%s')
        WHERE institution_display_name IS NOT NULL
        GROUP BY institution_url, institution_display_name
      ),
      name_winners AS (
        SELECT institution_url, institution_display_name
        FROM name_counts
        QUALIFY row_number() OVER (
          PARTITION BY institution_url
          ORDER BY n DESC, institution_display_name ASC
        ) = 1
      ),
      country_counts AS (
        SELECT
          institution_url,
          country_code,
          sum(association_mentions) AS n
        FROM read_parquet('%s')
        WHERE country_code IS NOT NULL
        GROUP BY institution_url, country_code
      ),
      country_winners AS (
        SELECT institution_url, country_code
        FROM country_counts
        QUALIFY row_number() OVER (
          PARTITION BY institution_url
          ORDER BY n DESC, country_code ASC
        ) = 1
      )
      SELECT
        regexp_extract(institution_url, 'I[0-9]+') AS institution_id,
        institution_url,
        n.institution_display_name,
        c.country_code
      FROM institutions AS i
      LEFT JOIN name_winners AS n USING (institution_url)
      LEFT JOIN country_winners AS c USING (institution_url)
      ORDER BY institution_id
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", batch_glob, batch_glob, batch_glob,
    institution_dim_partial_sql))
  if (!file.rename(institution_dim_partial, institution_dim)) {
    stop("Could not commit the institution dimension.")
  }
}

institution_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS institutions,
    count(DISTINCT institution_id) AS distinct_institutions,
    count_if(institution_display_name IS NULL) AS null_names,
    count_if(institution_display_name LIKE '%%|%%') AS names_with_pipe,
    count_if(country_code IS NULL) AS null_countries,
    count_if(country_code IS NOT NULL AND NOT regexp_full_match(
      country_code, '[A-Z]{2}'
    )) AS bad_countries
  FROM read_parquet('%s')", institution_dim_sql))
if (
  institution_check$institutions !=
    institution_check$distinct_institutions ||
  institution_check$bad_countries != 0
) {
  stop("Institution dimension failed uniqueness or country validation.")
}

####################################################################
### 3. One row per author x normalized institution
####################################################################

cat(format(Sys.time()), "reducing author/institution pairs\n")

for (bucket_id in 0:(author_buckets - 1L)) {
  bucket_path <- file.path(
    pair_bucket_dir, sprintf("bucket_%02d.parquet", bucket_id)
  )
  bucket_partial <- paste0(bucket_path, ".partial")
  if (file.exists(bucket_path) && file.info(bucket_path)$size > 0) {
    cat(format(Sys.time()), "pair bucket", bucket_id + 1L, "/",
        author_buckets, "cached\n")
    next
  }
  if (file.exists(bucket_path) && !file.remove(bucket_path)) {
    stop("Could not remove invalid pair bucket: ", bucket_path)
  }
  if (file.exists(bucket_partial) && !file.remove(bucket_partial)) {
    stop("Could not remove incomplete pair bucket: ", bucket_partial)
  }
  bucket_partial_sql <- gsub(
    "'", "''", gsub("\\\\", "/", bucket_partial), fixed = TRUE
  )
  dbExecute(con, sprintf("
    COPY (
      SELECT
        author_id,
        author_url,
        institution_url,
        CAST(min(first_publication_year) AS INTEGER)
          AS first_publication_year
      FROM read_parquet('%s')
      WHERE author_bucket = %d
      GROUP BY author_id, author_url, institution_url
      ORDER BY author_id, institution_url
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", batch_glob, bucket_id, bucket_partial_sql))
  bucket_check <- dbGetQuery(con, sprintf("
    SELECT
      count(*) AS rows,
      count(DISTINCT (author_id, institution_url)) AS distinct_pairs,
      coalesce(count_if(author_id IS NULL OR author_url IS NULL OR
               institution_url IS NULL), 0) AS null_ids,
      coalesce(count_if(first_publication_year IS NOT NULL AND
               first_publication_year < 2017), 0) AS bad_years
    FROM read_parquet('%s')", bucket_partial_sql))
  if (
    bucket_check$rows != bucket_check$distinct_pairs ||
    bucket_check$null_ids != 0 ||
    bucket_check$bad_years != 0
  ) {
    stop("Validation failed for pair bucket: ", bucket_partial)
  }
  if (!file.rename(bucket_partial, bucket_path)) {
    stop("Could not commit pair bucket: ", bucket_path)
  }
  cat(format(Sys.time()), "pair bucket", bucket_id + 1L, "/",
      author_buckets, "complete;",
      format(bucket_check$rows, scientific = FALSE), "pairs\n")
}

####################################################################
### 4. Positionally aligned institution-history strings
####################################################################

if (!file.exists(history_path) || file.info(history_path)$size <= 0) {
  history_partial <- paste0(history_path, ".partial")
  if (file.exists(history_path)) file.remove(history_path)
  if (file.exists(history_partial) && !file.remove(history_partial)) {
    stop("Could not remove incomplete author histories file.")
  }
  history_partial_sql <- gsub(
    "'", "''", gsub("\\\\", "/", history_partial), fixed = TRUE
  )
  cat(format(Sys.time()), "building aligned author histories\n")
  dbExecute(con, sprintf("
    COPY (
      SELECT
        p.author_id,
        any_value(p.author_url) AS author_url,
        string_agg(
          replace(coalesce(d.institution_display_name, 'NA'), '|', '/'),
          '|' ORDER BY
            p.first_publication_year NULLS LAST,
            replace(coalesce(d.institution_display_name, 'NA'), '|', '/'),
            d.institution_id
        ) AS institution_display_names,
        string_agg(
          coalesce(CAST(p.first_publication_year AS VARCHAR), 'NA'),
          '|' ORDER BY
            p.first_publication_year NULLS LAST,
            replace(coalesce(d.institution_display_name, 'NA'), '|', '/'),
            d.institution_id
        ) AS institution_first_publication_years,
        string_agg(
          coalesce(d.country_code, 'NA'),
          '|' ORDER BY
            p.first_publication_year NULLS LAST,
            replace(coalesce(d.institution_display_name, 'NA'), '|', '/'),
            d.institution_id
        ) AS institution_country_codes
      FROM read_parquet('%s') AS p
      LEFT JOIN read_parquet('%s') AS d USING (institution_url)
      GROUP BY p.author_id
      ORDER BY p.author_id
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", pair_bucket_glob, institution_dim_sql, history_partial_sql))
  if (!file.rename(history_partial, history_path)) {
    stop("Could not commit the aligned author histories.")
  }
}

history_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS authors,
    count(DISTINCT author_id) AS distinct_authors,
    count_if(
      institution_display_names IS NULL OR
      institution_first_publication_years IS NULL OR
      institution_country_codes IS NULL
    ) AS null_histories,
    count_if(
      length(institution_display_names) -
        length(replace(institution_display_names, '|', '')) <>
      length(institution_first_publication_years) -
        length(replace(institution_first_publication_years, '|', '')) OR
      length(institution_display_names) -
        length(replace(institution_display_names, '|', '')) <>
      length(institution_country_codes) -
        length(replace(institution_country_codes, '|', ''))
    ) AS misaligned_histories
  FROM read_parquet('%s')", history_path_sql))
if (
  history_check$authors != history_check$distinct_authors ||
  history_check$null_histories != 0 ||
  history_check$misaligned_histories != 0
) {
  stop("Aligned author histories failed validation.")
}

####################################################################
### 5. Preserve the cohort and append three columns
####################################################################

cat(format(Sys.time()), "writing enriched cohort parquet\n")
dbExecute(con, sprintf("
  COPY (
    SELECT
      c.author_id,
      c.author_url,
      c.author_display_name,
      c.raw_author_name,
      c.first_publication_year,
      c.ever_br_institution,
      c.ever_stem,
      coalesce(h.institution_display_names, 'NA')
        AS institution_display_names,
      coalesce(h.institution_first_publication_years, 'NA')
        AS institution_first_publication_years,
      coalesce(h.institution_country_codes, 'NA')
        AS institution_country_codes
    FROM read_parquet('%s') AS c
    LEFT JOIN read_parquet('%s') AS h USING (author_id)
    ORDER BY c.author_id
  ) TO '%s' (
    FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
  )", cohort_sql, history_path_sql, output_partial_sql))

expected_output_names <- c(
  expected_cohort_names,
  "institution_display_names",
  "institution_first_publication_years",
  "institution_country_codes"
)
expected_output_types <- c(expected_cohort_types, rep("VARCHAR", 3L))
output_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", output_partial_sql
))
if (
  !identical(output_schema$column_name, expected_output_names) ||
  !identical(output_schema$column_type, expected_output_types)
) {
  stop("Enriched output schema does not match the ten-column contract.")
}

output_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT author_id) AS distinct_author_ids,
    count(DISTINCT author_url) AS distinct_author_urls,
    count_if(author_id IS NULL OR author_url IS NULL) AS null_ids,
    count_if(
      institution_display_names IS NULL OR
      institution_first_publication_years IS NULL OR
      institution_country_codes IS NULL
    ) AS null_histories,
    count_if(
      length(institution_display_names) -
        length(replace(institution_display_names, '|', '')) <>
      length(institution_first_publication_years) -
        length(replace(institution_first_publication_years, '|', '')) OR
      length(institution_display_names) -
        length(replace(institution_display_names, '|', '')) <>
      length(institution_country_codes) -
        length(replace(institution_country_codes, '|', ''))
    ) AS misaligned_histories,
    count_if(institution_display_names = 'NA') AS authors_without_institution
  FROM read_parquet('%s')", output_partial_sql))
if (
  output_check$rows != cohort_check$rows ||
  output_check$rows != output_check$distinct_author_ids ||
  output_check$rows != output_check$distinct_author_urls ||
  output_check$null_ids != 0 ||
  output_check$null_histories != 0 ||
  output_check$misaligned_histories != 0
) {
  stop("Enriched output failed row, grain, NULL, or alignment validation.")
}

source_mismatches <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n
  FROM read_parquet('%s') AS o
  INNER JOIN read_parquet('%s') AS c USING (author_id)
  WHERE o.author_url IS DISTINCT FROM c.author_url
     OR o.author_display_name IS DISTINCT FROM c.author_display_name
     OR o.raw_author_name IS DISTINCT FROM c.raw_author_name
     OR o.first_publication_year IS DISTINCT FROM c.first_publication_year
     OR o.ever_br_institution IS DISTINCT FROM c.ever_br_institution
     OR o.ever_stem IS DISTINCT FROM c.ever_stem",
  output_partial_sql, cohort_sql
))$n
if (source_mismatches != 0) {
  stop("Original cohort columns changed during enrichment.")
}

token_check <- dbGetQuery(con, sprintf("
  WITH tokens AS (
    SELECT
      unnest(string_split(institution_first_publication_years, '|'))
        AS year_token,
      unnest(string_split(institution_country_codes, '|'))
        AS country_token
    FROM read_parquet('%s')
  )
  SELECT
    count_if(
      year_token <> 'NA' AND (
        NOT regexp_full_match(year_token, '[0-9]{4}') OR
        try_cast(year_token AS INTEGER) < 2017
      )
    ) AS bad_year_tokens,
    count_if(
      country_token <> 'NA' AND
      NOT regexp_full_match(country_token, '[A-Z]{2}')
    ) AS bad_country_tokens
  FROM tokens", output_partial_sql))
if (
  token_check$bad_year_tokens != 0 ||
  token_check$bad_country_tokens != 0
) {
  stop("An institution history contains an invalid year or country token.")
}

pair_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS author_institution_pairs,
    count(DISTINCT author_id) AS authors_with_institution,
    count(DISTINCT institution_url) AS distinct_institutions,
    count_if(first_publication_year IS NULL) AS null_year_pairs
  FROM read_parquet('%s')", pair_bucket_glob))

print(output_check, row.names = FALSE)
print(pair_check, row.names = FALSE)
print(institution_check, row.names = FALSE)
cat("Validated partial size :",
    sprintf("%.2f MiB", file.info(output_partial)$size / 1024^2), "\n")

had_previous <- file.exists(output_path)
if (had_previous && !file.rename(output_path, output_previous)) {
  stop("Could not preserve the previous enriched output.")
}
if (!file.rename(output_partial, output_path)) {
  if (had_previous && file.exists(output_previous)) {
    file.rename(output_previous, output_path)
  }
  stop("Could not promote the validated enriched output.")
}
if (had_previous && file.exists(output_previous)) {
  if (!file.remove(output_previous)) {
    warning("Enriched output promoted, but .previous could not be removed.")
  }
}

dbDisconnect(con, shutdown = TRUE)

cache_norm <- normalizePath(cache_dir, winslash = "/", mustWork = TRUE)
tmp_norm <- normalizePath(duckdb_tmp, winslash = "/", mustWork = TRUE)
if (
  !startsWith(cache_norm, paste0(tmp_norm, "/")) ||
  basename(cache_norm) != cache_version
) {
  stop("Refusing to clean an unexpected checkpoint path: ", cache_norm)
}
unlink(cache_norm, recursive = TRUE, force = TRUE)
if (dir.exists(cache_norm)) {
  warning("Final output is valid, but the checkpoint cache was not removed.")
}

cat("\nPromoted final output :", output_path, "\n")
cat("Final size           :",
    sprintf("%.2f MiB", file.info(output_path)$size / 1024^2), "\n")
cat("Completed            :", format(Sys.time()), "\n")
