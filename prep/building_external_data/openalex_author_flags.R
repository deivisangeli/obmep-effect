####################################################################
### OpenAlex author Brazilian-institution and STEM flags
###
### Local, offline pipeline. It reads the already-downloaded OpenAlex
### works parquet snapshot from D:/OpenAlex, reuses the completed author
### name dataset, and writes one final parquet into the OBMEP Dropbox.
### It does not use CRAN, S3, Athena, or any other network service, and
### it is not SEDAP-bound.
###
### Output:
###   openalex_author_flags.parquet
###     one row per identified author, with ever_br_institution and
###     ever_stem Boolean flags
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

default_works_glob <- file.path(
  openalex_root, "works", "updated_date=*", "part_*.parquet"
)
works_glob_override <- Sys.getenv("OPENALEX_WORKS_GLOB", unset = "")
works_glob <- if (nzchar(works_glob_override)) {
  works_glob_override
} else {
  default_works_glob
}

out_dir <- file.path(
  obmep_root, "Data", "intermediate", "openalex_authors"
)
default_author_base <- file.path(
  out_dir, "openalex_author_first_publication.parquet"
)
author_base <- Sys.getenv(
  "OPENALEX_AUTHOR_BASE", unset = default_author_base
)
flags_path <- file.path(out_dir, "openalex_author_flags.parquet")
flags_partial <- paste0(flags_path, ".partial")
flags_previous <- paste0(flags_path, ".previous")

local_app_data <- Sys.getenv(
  "LOCALAPPDATA", unset = "C:/Users/megaj/AppData/Local"
)
duckdb_tmp <- Sys.getenv(
  "OPENALEX_FLAGS_DUCKDB_TMP",
  unset = file.path(
    local_app_data, "OpenAlex", "duckdb_openalex_author_flags"
  )
)
batch_size <- 5L
author_buckets <- 64L
cache_version <- "v1_batch5_b64"
cache_dir <- file.path(duckdb_tmp, cache_version)
batch_dir <- file.path(cache_dir, "flag_batches")
bucket_dir <- file.path(cache_dir, "author_buckets")
spill_dir <- file.path(cache_dir, "spill")

memory_limit <- Sys.getenv(
  "OPENALEX_FLAGS_DUCKDB_MEMORY_LIMIT", unset = "22GB"
)
max_temp_size <- Sys.getenv(
  "OPENALEX_FLAGS_DUCKDB_MAX_TEMP", unset = "55GB"
)
threads <- suppressWarnings(as.integer(Sys.getenv(
  "OPENALEX_FLAGS_DUCKDB_THREADS", unset = "8"
)))
if (is.na(threads) || threads < 1L) {
  stop("OPENALEX_FLAGS_DUCKDB_THREADS must be a positive integer.")
}

if (file.exists(flags_path)) {
  cat("Final output already exists: ", flags_path, "\n", sep = "")
  cat("Remove it explicitly before requesting a full rebuild.\n")
  quit(save = "no", status = 0L)
}
if (file.exists(flags_previous)) {
  stop(
    "A .previous output remains from an interrupted promotion. ",
    "Inspect it before rerunning."
  )
}
if (!file.exists(author_base) || file.info(author_base)$size <= 0) {
  stop("Completed author base is missing or empty: ", author_base)
}

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(duckdb_tmp, recursive = TRUE, showWarnings = FALSE)
dir.create(cache_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(batch_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(bucket_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(spill_dir, recursive = TRUE, showWarnings = FALSE)

if (file.exists(flags_partial) && !file.remove(flags_partial)) {
  stop("Could not remove stale partial output: ", flags_partial)
}

####################################################################
### Manifest and source parts
####################################################################

manifest_path <- file.path(openalex_root, "works", "manifest.json")
manifest_records <- NA_real_
manifest_files <- NA_integer_
manifest_bytes <- NA_real_
known_test_shard <- FALSE

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

  expected_manifest_files <- 2446L
  expected_manifest_records <- 510372821
  expected_manifest_bytes <- 724970323127
  if (
    manifest_files != expected_manifest_files ||
    manifest_records != expected_manifest_records ||
    manifest_bytes != expected_manifest_bytes
  ) {
    stop(
      "The works manifest differs from the snapshot used to build ",
      "openalex_author_first_publication.parquet. Refusing to combine ",
      "incompatible snapshots."
    )
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
  known_test_shard <- length(parts) == 1L && grepl(
    "updated_date=2016-06-24[/\\\\]part_0000[.]parquet$", parts
  )
}

n_batches <- ceiling(length(source_parts) / batch_size)
batch_glob <- gsub(
  "'", "''", gsub("\\\\", "/", file.path(batch_dir, "batch_*.parquet")),
  fixed = TRUE
)
bucket_glob <- gsub(
  "'", "''", gsub("\\\\", "/", file.path(bucket_dir, "bucket_*.parquet")),
  fixed = TRUE
)
author_base_sql <- gsub(
  "'", "''", gsub("\\\\", "/", author_base), fixed = TRUE
)
flags_partial_sql <- gsub(
  "'", "''", gsub("\\\\", "/", flags_partial), fixed = TRUE
)

cat("OpenAlex works parts :", part_count, "\n")
cat("Input size           :", sprintf("%.2f GiB", input_bytes / 1024^3), "\n")
if (!is.na(manifest_records)) {
  cat("Manifest works       :", format(manifest_records, scientific = FALSE), "\n")
}
cat("Author base          :", author_base, "\n")
cat("Final output         :", flags_path, "\n")
cat("Checkpoint root      :", cache_dir, "\n")
cat("Bounded aggregation  :", n_batches, "batches x",
    author_buckets, "author buckets\n")
cat("DuckDB resources     :", memory_limit, "RAM,", max_temp_size,
    "spill cap,", threads, "threads\n\n")

####################################################################
### DuckDB connection
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

####################################################################
### 1. Resumable source batches
####################################################################

cat(format(Sys.time()), "building author flag batches\n")

for (batch_id in seq_len(n_batches)) {
  batch_path <- file.path(
    batch_dir, sprintf("batch_%04d.parquet", batch_id)
  )
  batch_partial <- paste0(batch_path, ".partial")

  if (file.exists(batch_path) && file.info(batch_path)$size > 0) {
    cat(format(Sys.time()), "flag batch", batch_id, "/", n_batches,
        "cached\n")
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
      WITH work_flags AS (
        SELECT
          authorships,
          coalesce(
            primary_topic.domain.display_name IN (
              'Physical Sciences', 'Life Sciences'
            ) OR primary_topic.field.display_name = 'Medicine',
            false
          ) AS work_is_stem
        FROM read_parquet(%s, hive_partitioning = false)
      ),
      author_mentions AS (
        SELECT
          a.author.id AS author_url,
          coalesce(
            list_contains(
              list_transform(a.institutions, i -> i.country_code),
              'BR'
            ),
            false
          ) AS mention_is_br,
          work_is_stem AS mention_is_stem
        FROM work_flags, UNNEST(authorships) AS u(a)
      )
      SELECT
        CAST(hash(author_url) %% %d AS INTEGER) AS author_bucket,
        author_url,
        bool_or(mention_is_br) AS ever_br_institution,
        bool_or(mention_is_stem) AS ever_stem
      FROM author_mentions
      WHERE coalesce(
        regexp_full_match(author_url, 'https://openalex[.]org/A[0-9]+'),
        false
      )
      GROUP BY author_url
      ORDER BY author_bucket
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", batch_relation, author_buckets, batch_partial_sql))

  batch_check <- dbGetQuery(con, sprintf("
    SELECT
      count(*) AS rows,
      count(DISTINCT author_url) AS distinct_authors,
      count_if(author_url IS NULL) AS null_authors,
      count_if(ever_br_institution IS NULL OR ever_stem IS NULL)
        AS null_flags,
      min(author_bucket) AS min_bucket,
      max(author_bucket) AS max_bucket
    FROM read_parquet('%s')", batch_partial_sql))
  if (
    batch_check$rows <= 0 ||
    batch_check$rows != batch_check$distinct_authors ||
    batch_check$null_authors != 0 ||
    batch_check$null_flags != 0 ||
    batch_check$min_bucket < 0 ||
    batch_check$max_bucket >= author_buckets
  ) {
    stop("Validation failed for batch checkpoint: ", batch_partial)
  }
  if (!file.rename(batch_partial, batch_path)) {
    stop("Could not commit batch checkpoint: ", batch_path)
  }
  cat(format(Sys.time()), "flag batch", batch_id, "/", n_batches,
      "complete;", format(batch_check$rows, scientific = FALSE),
      "authors\n")
}

####################################################################
### 2. Global reduction by author hash bucket
####################################################################

cat(format(Sys.time()), "reducing author buckets\n")

for (bucket_id in 0:(author_buckets - 1L)) {
  bucket_path <- file.path(
    bucket_dir, sprintf("bucket_%02d.parquet", bucket_id)
  )
  bucket_partial <- paste0(bucket_path, ".partial")

  if (file.exists(bucket_path) && file.info(bucket_path)$size > 0) {
    cat(format(Sys.time()), "author bucket", bucket_id + 1L, "/",
        author_buckets, "cached\n")
    next
  }
  if (file.exists(bucket_path) && !file.remove(bucket_path)) {
    stop("Could not remove invalid bucket checkpoint: ", bucket_path)
  }
  if (file.exists(bucket_partial) && !file.remove(bucket_partial)) {
    stop("Could not remove incomplete bucket checkpoint: ", bucket_partial)
  }

  bucket_partial_sql <- gsub(
    "'", "''", gsub("\\\\", "/", bucket_partial), fixed = TRUE
  )
  dbExecute(con, sprintf("
    COPY (
      SELECT
        author_url,
        bool_or(ever_br_institution) AS ever_br_institution,
        bool_or(ever_stem) AS ever_stem
      FROM read_parquet('%s')
      WHERE author_bucket = %d
      GROUP BY author_url
      ORDER BY author_url
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", batch_glob, bucket_id, bucket_partial_sql))

  bucket_check <- dbGetQuery(con, sprintf("
    SELECT
      count(*) AS rows,
      count(DISTINCT author_url) AS distinct_authors,
      count_if(author_url IS NULL) AS null_authors,
      count_if(ever_br_institution IS NULL OR ever_stem IS NULL)
        AS null_flags
    FROM read_parquet('%s')", bucket_partial_sql))
  if (
    bucket_check$rows <= 0 ||
    bucket_check$rows != bucket_check$distinct_authors ||
    bucket_check$null_authors != 0 ||
    bucket_check$null_flags != 0
  ) {
    stop("Validation failed for author bucket: ", bucket_partial)
  }
  if (!file.rename(bucket_partial, bucket_path)) {
    stop("Could not commit author bucket: ", bucket_path)
  }
  cat(format(Sys.time()), "author bucket", bucket_id + 1L, "/",
      author_buckets, "complete;",
      format(bucket_check$rows, scientific = FALSE), "authors\n")
}

####################################################################
### 3. Join flags to the completed author/name universe
####################################################################

base_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT author_id) AS distinct_author_ids,
    count(DISTINCT author_url) AS distinct_author_urls,
    count_if(author_id IS NULL OR author_url IS NULL) AS null_ids
  FROM read_parquet('%s')", author_base_sql))
if (
  base_check$rows <= 0 ||
  base_check$rows != base_check$distinct_author_ids ||
  base_check$rows != base_check$distinct_author_urls ||
  base_check$null_ids != 0
) {
  stop("The completed author base failed its uniqueness checks.")
}
if (!nzchar(works_glob_override) && base_check$rows != 118991535) {
  stop(
    "Expected 118,991,535 authors in the completed production base; found ",
    format(base_check$rows, scientific = FALSE), "."
  )
}

flag_dimension_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT author_url) AS distinct_authors,
    count_if(author_url IS NULL) AS null_authors,
    count_if(ever_br_institution IS NULL OR ever_stem IS NULL)
      AS null_flags
  FROM read_parquet('%s')", bucket_glob))
if (
  flag_dimension_check$rows != flag_dimension_check$distinct_authors ||
  flag_dimension_check$null_authors != 0 ||
  flag_dimension_check$null_flags != 0
) {
  stop("The reduced author flag dimension failed validation.")
}

missing_flags <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n
  FROM read_parquet('%s') AS b
  LEFT JOIN read_parquet('%s') AS f USING (author_url)
  WHERE f.author_url IS NULL", author_base_sql, bucket_glob))$n
orphan_flags <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n
  FROM read_parquet('%s') AS f
  LEFT JOIN read_parquet('%s') AS b USING (author_url)
  WHERE b.author_url IS NULL", bucket_glob, author_base_sql))$n
if (missing_flags != 0 || orphan_flags != 0) {
  stop(
    "Author universe mismatch: ", format(missing_flags, scientific = FALSE),
    " base authors lack flags and ",
    format(orphan_flags, scientific = FALSE),
    " flag authors are absent from the base."
  )
}

cat(format(Sys.time()), "writing final author flags parquet\n")
dbExecute(con, sprintf("
  COPY (
    SELECT
      b.author_id,
      b.author_url,
      b.author_display_name,
      b.raw_author_name,
      coalesce(f.ever_br_institution, false) AS ever_br_institution,
      coalesce(f.ever_stem, false) AS ever_stem
    FROM read_parquet('%s') AS b
    LEFT JOIN read_parquet('%s') AS f USING (author_url)
  ) TO '%s' (
    FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
  )", author_base_sql, bucket_glob, flags_partial_sql))

####################################################################
### 4. Validate and promote
####################################################################

expected_names <- c(
  "author_id", "author_url", "author_display_name", "raw_author_name",
  "ever_br_institution", "ever_stem"
)
expected_types <- c(
  "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "BOOLEAN", "BOOLEAN"
)
flags_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", flags_partial_sql
))
if (
  !identical(flags_schema$column_name, expected_names) ||
  !identical(flags_schema$column_type, expected_types)
) {
  stop("Final author flags schema does not match the contract.")
}

flags_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT author_id) AS distinct_author_ids,
    count(DISTINCT author_url) AS distinct_author_urls,
    count_if(author_id IS NULL OR author_url IS NULL) AS null_ids,
    count_if(ever_br_institution IS NULL OR ever_stem IS NULL)
      AS null_flags,
    count_if(ever_br_institution) AS br_authors,
    count_if(ever_stem) AS stem_authors,
    count_if(ever_br_institution AND ever_stem) AS both_authors
  FROM read_parquet('%s')", flags_partial_sql))
if (
  flags_check$rows != base_check$rows ||
  flags_check$rows != flags_check$distinct_author_ids ||
  flags_check$rows != flags_check$distinct_author_urls ||
  flags_check$null_ids != 0 ||
  flags_check$null_flags != 0
) {
  stop("Final author flags output failed grain or NULL validation.")
}

name_mismatches <- dbGetQuery(con, sprintf("
  SELECT count(*) AS n
  FROM read_parquet('%s') AS o
  JOIN read_parquet('%s') AS b USING (author_url)
  WHERE o.author_id IS DISTINCT FROM b.author_id
     OR o.author_display_name IS DISTINCT FROM b.author_display_name
     OR o.raw_author_name IS DISTINCT FROM b.raw_author_name",
  flags_partial_sql, author_base_sql
))$n
if (name_mismatches != 0) {
  stop("Final IDs or names differ from the completed author base.")
}

if (known_test_shard) {
  expected_test <- c(
    rows = 1152,
    br_authors = 33,
    stem_authors = 492,
    both_authors = 3
  )
  observed_test <- c(
    rows = flags_check$rows,
    br_authors = flags_check$br_authors,
    stem_authors = flags_check$stem_authors,
    both_authors = flags_check$both_authors
  )
  if (!identical(as.numeric(observed_test), as.numeric(expected_test))) {
    stop(
      "Known-shard counts changed. Expected ",
      paste(names(expected_test), expected_test, collapse = ", "),
      "; observed ",
      paste(names(observed_test), observed_test, collapse = ", "), "."
    )
  }
}

print(flags_check, row.names = FALSE)
cat("Validated partial size :",
    sprintf("%.2f GiB", file.info(flags_partial)$size / 1024^3), "\n")

had_previous <- file.exists(flags_path)
if (had_previous && !file.rename(flags_path, flags_previous)) {
  stop("Could not preserve the previous final output.")
}
if (!file.rename(flags_partial, flags_path)) {
  if (had_previous && file.exists(flags_previous)) {
    file.rename(flags_previous, flags_path)
  }
  stop("Could not promote the validated author flags output.")
}
if (had_previous && file.exists(flags_previous)) {
  if (!file.remove(flags_previous)) {
    warning("Validated output promoted, but .previous could not be removed.")
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

cat("\nPromoted final output :", flags_path, "\n")
cat("Final size           :",
    sprintf("%.2f GiB", file.info(flags_path)$size / 1024^3), "\n")
cat("Completed            :", format(Sys.time()), "\n")
