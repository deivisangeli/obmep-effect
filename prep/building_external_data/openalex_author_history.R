####################################################################
### OpenAlex author first-publication years and institutions
###
### Local, offline pipeline. It reads the already-downloaded OpenAlex
### works parquet snapshot from D:/OpenAlex and writes two single-file
### parquet products into the OBMEP Dropbox. It does not use CRAN, S3,
### Athena, or any other network service, and it is not SEDAP-bound.
###
### Outputs:
###   openalex_author_first_publication.parquet
###     one row per identified OpenAlex author
###   openalex_author_institutions.parquet
###     one row per identified author x normalized institution
###
### Name fields can vary across works. The output keeps the most
### frequent non-empty value for each author/institution; ties are
### resolved lexicographically so a rerun is deterministic. All works
### count, including records flagged as paratext or retracted.
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
first_path <- file.path(
  out_dir, "openalex_author_first_publication.parquet"
)
inst_path <- file.path(
  out_dir, "openalex_author_institutions.parquet"
)
first_partial <- paste0(first_path, ".partial")
inst_partial <- paste0(inst_path, ".partial")
first_previous <- paste0(first_path, ".previous")
inst_previous <- paste0(inst_path, ".previous")

duckdb_tmp <- Sys.getenv(
  "OPENALEX_DUCKDB_TMP",
  unset = file.path(openalex_root, "tmp", "duckdb_openalex_author_history")
)
batch_size <- 25L
inst_subbatch_size <- 5L
inst_dense_subbatch_size <- 1L
inst_dense_from_batch <- 65L
author_buckets <- 64L
cache_version <- "v2_batch25_b64"
cache_dir <- file.path(duckdb_tmp, cache_version)
author_batch_dir <- file.path(cache_dir, "author_batches")
author_bucket_dir <- file.path(cache_dir, "author_buckets")
inst_batch_dir <- file.path(cache_dir, "institution_batches")
inst_bucket_dir <- file.path(cache_dir, "institution_buckets")
institution_dim <- file.path(cache_dir, "institution_dimension.parquet")

memory_limit <- Sys.getenv(
  "OPENALEX_DUCKDB_MEMORY_LIMIT", unset = "16GB"
)
max_temp_size <- Sys.getenv(
  "OPENALEX_DUCKDB_MAX_TEMP", unset = "140GB"
)
threads <- suppressWarnings(as.integer(Sys.getenv(
  "OPENALEX_DUCKDB_THREADS", unset = "8"
)))
if (is.na(threads) || threads < 1L) {
  stop("OPENALEX_DUCKDB_THREADS must be a positive integer.")
}

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(duckdb_tmp, recursive = TRUE, showWarnings = FALSE)
dir.create(author_batch_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(author_bucket_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(inst_batch_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(inst_bucket_dir, recursive = TRUE, showWarnings = FALSE)

# The full tree is deliberately not enumerated with Sys.glob/file.info:
# on this 725 GB Windows volume, stat'ing every part is much slower than
# reading the snapshot manifest. DuckDB validates the glob while scanning.
# Test runs can point OPENALEX_WORKS_GLOB at one or more explicit shards.
manifest_path <- file.path(openalex_root, "works", "manifest.json")
manifest_records <- NA_real_
manifest_files <- NA_integer_
manifest_bytes <- NA_real_
known_test_shard <- FALSE
if (!nzchar(works_glob_override)) {
  stopifnot(dir.exists(file.path(openalex_root, "works")),
            file.exists(manifest_path))
  manifest_lines <- readLines(manifest_path, warn = FALSE)
  record_line <- grep('"record_count"[[:space:]]*:', manifest_lines)[1]
  bytes_line <- grep('"content_length"[[:space:]]*:', manifest_lines)[1]
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
  stopifnot(!is.na(manifest_records), manifest_records > 0,
            !is.na(manifest_bytes), manifest_bytes > 0,
            !is.na(manifest_files), manifest_files > 0L)
  manifest_urls <- grep(
    '"url"[[:space:]]*:[[:space:]]*".*part_[0-9]+[.]parquet"',
    manifest_lines, value = TRUE
  )
  manifest_urls <- sub('.*"url"[[:space:]]*:[[:space:]]*"([^"]+)".*',
                       '\\1', manifest_urls)
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
  part_count <- length(parts)
  input_bytes <- sum(part_info$size)
  source_parts <- gsub("\\\\", "/", parts)
  known_test_shard <- length(parts) == 1L && grepl(
    "updated_date=2016-06-24[/\\\\]part_0000[.]parquet$", parts
  )
}

for (stale in c(
  file.path(duckdb_tmp, "author_variants.stage.parquet"),
  file.path(duckdb_tmp, "author_institutions.stage.parquet"),
  first_partial, inst_partial
)) {
  if (file.exists(stale) && !file.remove(stale)) {
    stop("Could not remove stale generated file: ", stale)
  }
}
if (file.exists(first_previous) || file.exists(inst_previous)) {
  stop("A .previous output remains from an interrupted promotion. ",
       "Inspect it before rerunning.")
}

author_batch_glob <- gsub(
  "'", "''", gsub("\\\\", "/", file.path(author_batch_dir, "batch_*.parquet")),
  fixed = TRUE
)
author_bucket_glob <- gsub(
  "'", "''", gsub("\\\\", "/", file.path(author_bucket_dir, "bucket_*.parquet")),
  fixed = TRUE
)
inst_batch_glob <- gsub(
  "'", "''", gsub("\\\\", "/", file.path(inst_batch_dir, "batch_*.parquet")),
  fixed = TRUE
)
inst_bucket_glob <- gsub(
  "'", "''", gsub("\\\\", "/", file.path(inst_bucket_dir, "bucket_*.parquet")),
  fixed = TRUE
)
institution_dim_sql <- gsub(
  "'", "''", gsub("\\\\", "/", institution_dim), fixed = TRUE
)
first_partial_sql <- gsub("'", "''", gsub("\\\\", "/", first_partial), fixed = TRUE)
inst_partial_sql <- gsub("'", "''", gsub("\\\\", "/", inst_partial), fixed = TRUE)

cat("OpenAlex works parts :", part_count, "\n")
cat("Input size           :",
    sprintf("%.2f GiB", input_bytes / 1024^3), "\n")
if (!is.na(manifest_records)) {
  cat("Manifest works       :", format(manifest_records, scientific = FALSE), "\n")
}
cat("Input glob           :", works_glob, "\n")
cat("Output directory     :", out_dir, "\n")
cat("DuckDB spill         :", duckdb_tmp, "\n")
cat("Bounded aggregation  :", ceiling(part_count / batch_size), "batches x",
    author_buckets, "author buckets\n")
cat("Institution fallback :", inst_subbatch_size,
    "source parts per missing batch slice through batch",
    inst_dense_from_batch - 1L, ";", inst_dense_subbatch_size,
    "part from batch", inst_dense_from_batch, "onward\n")
cat("DuckDB resources     :", memory_limit, "RAM,", max_temp_size,
    "spill cap,", threads, "threads\n\n")

####################################################################
### DuckDB connection
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA threads=%d", threads))
dbExecute(con, sprintf("PRAGMA memory_limit='%s'", memory_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", gsub(
  "'", "''", gsub("\\\\", "/", duckdb_tmp), fixed = TRUE
)))
dbExecute(con, sprintf("SET max_temp_directory_size='%s'", max_temp_size))
dbExecute(con, "SET preserve_insertion_order=false")

cat("DuckDB version       :", dbGetQuery(con, "SELECT version() AS v")$v,
    "\n\n")

####################################################################
### 1. Author names and first publication year
####################################################################

cat(format(Sys.time()), "building bounded author/name batches\n")

n_batches <- ceiling(length(source_parts) / batch_size)
for (batch_id in seq_len(n_batches)) {
  batch_path <- file.path(
    author_batch_dir, sprintf("batch_%04d.parquet", batch_id)
  )
  if (file.exists(batch_path) && file.info(batch_path)$size > 0) {
    cat(format(Sys.time()), "author batch", batch_id, "/", n_batches,
        "cached\n")
    next
  }
  if (file.exists(batch_path)) file.remove(batch_path)

  lo <- (batch_id - 1L) * batch_size + 1L
  hi <- min(batch_id * batch_size, length(source_parts))
  batch_parts <- gsub("'", "''", source_parts[lo:hi], fixed = TRUE)
  batch_relation <- paste0("['", paste(batch_parts, collapse = "','"), "']")
  batch_path_sql <- gsub(
    "'", "''", gsub("\\\\", "/", batch_path), fixed = TRUE
  )

  sql_author_batch <- sprintf("
    COPY (
      WITH raw_mentions AS (
        SELECT
          w.publication_year,
          a.author.id           AS author_url_source,
          a.author.display_name AS author_display_name_source,
          a.raw_author_name     AS raw_author_name_source
        FROM read_parquet(%s, hive_partitioning = false) AS w,
             UNNEST(w.authorships) AS u(a)
      ),
      classified AS (
        SELECT
          CASE
            WHEN author_url_source IS NULL THEN 'null'
            WHEN regexp_full_match(
              author_url_source, 'https://openalex[.]org/A[0-9]+'
            ) THEN 'valid'
            ELSE 'malformed'
          END AS id_status,
          CASE WHEN regexp_full_match(
            author_url_source, 'https://openalex[.]org/A[0-9]+'
          ) THEN CAST(hash(author_url_source) %% %d AS INTEGER)
          ELSE -1 END AS author_bucket,
          CASE WHEN regexp_full_match(
            author_url_source, 'https://openalex[.]org/A[0-9]+'
          ) THEN author_url_source END AS author_url_raw,
          CASE WHEN regexp_full_match(
            author_url_source, 'https://openalex[.]org/A[0-9]+'
          ) AND trim(coalesce(author_display_name_source, '')) <> ''
            THEN author_display_name_source END AS author_display_name,
          CASE WHEN regexp_full_match(
            author_url_source, 'https://openalex[.]org/A[0-9]+'
          ) AND trim(coalesce(raw_author_name_source, '')) <> ''
            THEN raw_author_name_source END AS raw_author_name,
          publication_year
        FROM raw_mentions
      )
      SELECT
        id_status,
        author_bucket,
        author_url_raw,
        author_display_name,
        raw_author_name,
        CAST(min(publication_year) AS INTEGER) AS first_publication_year,
        CAST(count(*) AS BIGINT) AS mention_count
      FROM classified
      GROUP BY
        id_status, author_bucket, author_url_raw,
        author_display_name, raw_author_name
      ORDER BY author_bucket
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", batch_relation, author_buckets, batch_path_sql)

  dbExecute(con, sql_author_batch)
  cat(format(Sys.time()), "author batch", batch_id, "/", n_batches,
      "complete\n")
}

author_audit <- dbGetQuery(con, sprintf("
  SELECT
    id_status,
    CAST(sum(mention_count) AS BIGINT) AS authorship_mentions,
    count(*) AS batch_variant_groups
  FROM read_parquet('%s')
  GROUP BY id_status
  ORDER BY id_status", author_batch_glob))
print(author_audit, row.names = FALSE)

cat(format(Sys.time()), "reducing", author_buckets, "author buckets\n")
for (bucket_id in 0:(author_buckets - 1L)) {
  bucket_path <- file.path(
    author_bucket_dir, sprintf("bucket_%03d.parquet", bucket_id)
  )
  if (file.exists(bucket_path) && file.info(bucket_path)$size > 0) {
    cat(format(Sys.time()), "author bucket", bucket_id + 1L, "/",
        author_buckets, "cached\n")
    next
  }
  if (file.exists(bucket_path)) file.remove(bucket_path)
  bucket_path_sql <- gsub(
    "'", "''", gsub("\\\\", "/", bucket_path), fixed = TRUE
  )

  sql_author_bucket <- sprintf("
    COPY (
      WITH variants AS (
        SELECT
          author_url_raw,
          author_display_name,
          raw_author_name,
          min(first_publication_year) AS first_publication_year,
          sum(mention_count) AS mention_count
        FROM read_parquet('%s')
        WHERE id_status = 'valid' AND author_bucket = %d
        GROUP BY
          author_url_raw, author_display_name, raw_author_name
      ),
      authors AS (
        SELECT
          author_url_raw,
          min(first_publication_year) AS first_publication_year
        FROM variants
        GROUP BY author_url_raw
      ),
      display_counts AS (
        SELECT
          author_url_raw,
          author_display_name,
          sum(mention_count) AS n
        FROM variants
        WHERE author_display_name IS NOT NULL
        GROUP BY author_url_raw, author_display_name
      ),
      display_winners AS (
        SELECT author_url_raw, author_display_name
        FROM display_counts
        QUALIFY row_number() OVER (
          PARTITION BY author_url_raw
          ORDER BY n DESC, author_display_name ASC
        ) = 1
      ),
      raw_counts AS (
        SELECT
          author_url_raw,
          raw_author_name,
          sum(mention_count) AS n
        FROM variants
        WHERE raw_author_name IS NOT NULL
        GROUP BY author_url_raw, raw_author_name
      ),
      raw_winners AS (
        SELECT author_url_raw, raw_author_name
        FROM raw_counts
        QUALIFY row_number() OVER (
          PARTITION BY author_url_raw
          ORDER BY n DESC, raw_author_name ASC
        ) = 1
      )
      SELECT
        regexp_extract(a.author_url_raw, 'A[0-9]+') AS author_id,
        a.author_url_raw AS author_url,
        d.author_display_name,
        r.raw_author_name,
        CAST(a.first_publication_year AS INTEGER) AS first_publication_year
      FROM authors AS a
      LEFT JOIN display_winners AS d USING (author_url_raw)
      LEFT JOIN raw_winners AS r USING (author_url_raw)
      ORDER BY author_id
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", author_batch_glob, bucket_id, bucket_path_sql)

  dbExecute(con, sql_author_bucket)
  cat(format(Sys.time()), "author bucket", bucket_id + 1L, "/",
      author_buckets, "complete\n")
}

valid_authors <- as.numeric(dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM read_parquet('%s')", author_bucket_glob))$n)

cat(format(Sys.time()), "combining first-publication parquet\n")
dbExecute(con, sprintf("
  COPY (
    SELECT * FROM read_parquet('%s') ORDER BY author_id
  ) TO '%s' (
    FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
  )", author_bucket_glob, first_partial_sql))
cat(format(Sys.time()), "first-publication parquet complete\n\n")

####################################################################
### 2. Author x institution associations
####################################################################

cat(format(Sys.time()), "building bounded author/institution batches\n")

for (batch_id in seq_len(n_batches)) {
  batch_path <- file.path(
    inst_batch_dir, sprintf("batch_%04d.parquet", batch_id)
  )
  if (file.exists(batch_path) && file.info(batch_path)$size > 0) {
    cat(format(Sys.time()), "institution batch", batch_id, "/", n_batches,
        "cached\n")
    next
  }
  if (file.exists(batch_path)) file.remove(batch_path)

  lo <- (batch_id - 1L) * batch_size + 1L
  hi <- min(batch_id * batch_size, length(source_parts))
  outer_parts <- source_parts[lo:hi]
  current_inst_subbatch_size <- if (batch_id >= inst_dense_from_batch) {
    inst_dense_subbatch_size
  } else {
    inst_subbatch_size
  }
  n_subbatches <- ceiling(
    length(outer_parts) / current_inst_subbatch_size
  )

  for (subbatch_id in seq_len(n_subbatches)) {
    subbatch_path <- file.path(
      inst_batch_dir,
      sprintf("batch_%04d_%02d.parquet", batch_id, subbatch_id)
    )
    if (file.exists(subbatch_path) && file.info(subbatch_path)$size > 0) {
      cat(format(Sys.time()), "institution batch", batch_id, ".",
          subbatch_id, "/", n_batches, "cached\n")
      next
    }
    if (file.exists(subbatch_path)) file.remove(subbatch_path)

    sub_lo <- (subbatch_id - 1L) * current_inst_subbatch_size + 1L
    sub_hi <- min(
      subbatch_id * current_inst_subbatch_size, length(outer_parts)
    )
    batch_parts <- gsub(
      "'", "''", outer_parts[sub_lo:sub_hi], fixed = TRUE
    )
    batch_relation <- paste0(
      "['", paste(batch_parts, collapse = "','"), "']"
    )
    subbatch_path_sql <- gsub(
      "'", "''", gsub("\\\\", "/", subbatch_path), fixed = TRUE
    )

    sql_inst_batch <- sprintf("
    COPY (
      WITH raw_associations AS (
        SELECT
          a.author.id    AS author_url_source,
          i.id           AS institution_url_source,
          i.display_name AS institution_display_name_source,
          i.country_code AS country_code_source
        FROM read_parquet(%s, hive_partitioning = false) AS w,
             UNNEST(w.authorships) AS u(a),
             UNNEST(a.institutions) AS ui(i)
      ),
      flags AS (
        SELECT
          *,
          coalesce(regexp_full_match(
            author_url_source, 'https://openalex[.]org/A[0-9]+'
          ), false) AS valid_author,
          coalesce(regexp_full_match(
            institution_url_source, 'https://openalex[.]org/I[0-9]+'
          ), false) AS valid_institution
        FROM raw_associations
      ),
      classified AS (
        SELECT
          CASE
            WHEN valid_author AND valid_institution THEN 'valid'
            WHEN NOT valid_author AND NOT valid_institution THEN 'invalid_both'
            WHEN NOT valid_author THEN 'invalid_author'
            ELSE 'invalid_institution'
          END AS association_status,
          CASE WHEN valid_author AND valid_institution
            THEN CAST(hash(author_url_source) %% %d AS INTEGER)
            ELSE -1 END AS author_bucket,
          CASE WHEN valid_author AND valid_institution
            THEN author_url_source END AS author_url_raw,
          CASE WHEN valid_author AND valid_institution
            THEN institution_url_source END AS institution_url_raw,
          CASE WHEN valid_author AND valid_institution AND
                    trim(coalesce(institution_display_name_source, '')) <> ''
            THEN institution_display_name_source END
            AS institution_display_name,
          CASE WHEN valid_author AND valid_institution AND
                    trim(coalesce(country_code_source, '')) <> ''
            THEN country_code_source END AS country_code
        FROM flags
      )
      SELECT
        association_status,
        author_bucket,
        author_url_raw,
        institution_url_raw,
        institution_display_name,
        country_code,
        CAST(count(*) AS BIGINT) AS association_mentions
      FROM classified
      GROUP BY
        association_status, author_bucket, author_url_raw,
        institution_url_raw, institution_display_name, country_code
      ORDER BY author_bucket
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", batch_relation, author_buckets, subbatch_path_sql)

    dbExecute(con, sql_inst_batch)
    cat(format(Sys.time()), "institution batch", batch_id, ".",
        subbatch_id, "/", n_batches, "complete\n")
  }
  cat(format(Sys.time()), "institution batch", batch_id, "/", n_batches,
      "complete\n")
}

inst_audit <- dbGetQuery(con, sprintf("
  SELECT
    association_status,
    CAST(sum(association_mentions) AS BIGINT) AS association_mentions,
    count(*) AS batch_metadata_groups
  FROM read_parquet('%s')
  GROUP BY association_status
  ORDER BY association_status", inst_batch_glob))
print(inst_audit, row.names = FALSE)

if (!file.exists(institution_dim) || file.info(institution_dim)$size == 0) {
  if (file.exists(institution_dim)) file.remove(institution_dim)
  cat(format(Sys.time()), "building global institution dimension\n")
  dbExecute(con, sprintf("
    COPY (
      WITH valid AS (
        SELECT * FROM read_parquet('%s')
        WHERE association_status = 'valid'
      ),
      institutions AS (
        SELECT DISTINCT institution_url_raw FROM valid
      ),
      name_counts AS (
        SELECT
          institution_url_raw,
          institution_display_name,
          sum(association_mentions) AS n
        FROM valid
        WHERE institution_display_name IS NOT NULL
        GROUP BY institution_url_raw, institution_display_name
      ),
      name_winners AS (
        SELECT institution_url_raw, institution_display_name
        FROM name_counts
        QUALIFY row_number() OVER (
          PARTITION BY institution_url_raw
          ORDER BY n DESC, institution_display_name ASC
        ) = 1
      ),
      country_counts AS (
        SELECT
          institution_url_raw,
          country_code,
          sum(association_mentions) AS n
        FROM valid
        WHERE country_code IS NOT NULL
        GROUP BY institution_url_raw, country_code
      ),
      country_winners AS (
        SELECT institution_url_raw, country_code
        FROM country_counts
        QUALIFY row_number() OVER (
          PARTITION BY institution_url_raw
          ORDER BY n DESC, country_code ASC
        ) = 1
      )
      SELECT
        i.institution_url_raw,
        n.institution_display_name,
        c.country_code
      FROM institutions AS i
      LEFT JOIN name_winners AS n USING (institution_url_raw)
      LEFT JOIN country_winners AS c USING (institution_url_raw)
      ORDER BY institution_url_raw
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", inst_batch_glob, institution_dim_sql))
}

cat(format(Sys.time()), "reducing", author_buckets, "institution buckets\n")
for (bucket_id in 0:(author_buckets - 1L)) {
  bucket_path <- file.path(
    inst_bucket_dir, sprintf("bucket_%03d.parquet", bucket_id)
  )
  if (file.exists(bucket_path) && file.info(bucket_path)$size > 0) {
    cat(format(Sys.time()), "institution bucket", bucket_id + 1L, "/",
        author_buckets, "cached\n")
    next
  }
  if (file.exists(bucket_path)) file.remove(bucket_path)
  bucket_path_sql <- gsub(
    "'", "''", gsub("\\\\", "/", bucket_path), fixed = TRUE
  )

  dbExecute(con, sprintf("
    COPY (
      WITH pairs AS (
        SELECT DISTINCT author_url_raw, institution_url_raw
        FROM read_parquet('%s')
        WHERE association_status = 'valid' AND author_bucket = %d
      )
      SELECT
        regexp_extract(p.author_url_raw, 'A[0-9]+') AS author_id,
        regexp_extract(p.institution_url_raw, 'I[0-9]+') AS institution_id,
        p.institution_url_raw AS institution_url,
        d.institution_display_name,
        d.country_code
      FROM pairs AS p
      LEFT JOIN read_parquet('%s') AS d USING (institution_url_raw)
      ORDER BY author_id, institution_id
    ) TO '%s' (
      FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
    )", inst_batch_glob, bucket_id, institution_dim_sql, bucket_path_sql))

  cat(format(Sys.time()), "institution bucket", bucket_id + 1L, "/",
      author_buckets, "complete\n")
}

valid_pairs <- as.numeric(dbGetQuery(con, sprintf("
  SELECT count(*) AS n FROM read_parquet('%s')", inst_bucket_glob))$n)

cat(format(Sys.time()), "combining author/institution parquet\n")
dbExecute(con, sprintf("
  COPY (
    SELECT * FROM read_parquet('%s') ORDER BY author_id, institution_id
  ) TO '%s' (
    FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
  )", inst_bucket_glob, inst_partial_sql))
cat(format(Sys.time()), "author/institution parquet complete\n\n")

####################################################################
### Validation
####################################################################

first_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT author_id) AS distinct_authors,
    sum(NOT regexp_full_match(author_id, 'A[0-9]+')) AS bad_author_id,
    sum(author_url <> 'https://openalex.org/' || author_id) AS bad_author_url,
    sum(author_display_name = '') AS empty_display_name,
    sum(raw_author_name = '') AS empty_raw_name,
    sum(first_publication_year IS NULL) AS null_first_year,
    min(first_publication_year) AS min_first_year,
    max(first_publication_year) AS max_first_year
  FROM read_parquet('%s')", first_partial_sql))

inst_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT (author_id, institution_id)) AS distinct_pairs,
    count(DISTINCT institution_id) AS distinct_institutions,
    sum(NOT regexp_full_match(author_id, 'A[0-9]+')) AS bad_author_id,
    sum(NOT regexp_full_match(institution_id, 'I[0-9]+')) AS bad_institution_id,
    sum(institution_url <> 'https://openalex.org/' || institution_id)
      AS bad_institution_url,
    sum(institution_display_name = '') AS empty_institution_name,
    sum(country_code IS NULL) AS null_country,
    sum(country_code IS NOT NULL AND
        NOT regexp_full_match(country_code, '[A-Z]{2}')) AS bad_country
  FROM read_parquet('%s')", inst_partial_sql))

missing_author <- as.numeric(dbGetQuery(con, sprintf("
  SELECT count(*) AS n
  FROM read_parquet('%s') AS i
  ANTI JOIN read_parquet('%s') AS a USING (author_id)",
  inst_partial_sql, first_partial_sql))$n)

first_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", first_partial_sql
))
inst_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", inst_partial_sql
))

expected_first_names <- c(
  "author_id", "author_url", "author_display_name", "raw_author_name",
  "first_publication_year"
)
expected_first_types <- c(
  "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "INTEGER"
)
expected_inst_names <- c(
  "author_id", "institution_id", "institution_url",
  "institution_display_name", "country_code"
)
expected_inst_types <- rep("VARCHAR", 5L)

print(first_check, row.names = FALSE)
print(inst_check, row.names = FALSE)
cat("institution rows without author output:", missing_author, "\n")

stopifnot(
  as.numeric(first_check$rows) == valid_authors,
  as.numeric(first_check$rows) == as.numeric(first_check$distinct_authors),
  as.numeric(first_check$bad_author_id) == 0,
  as.numeric(first_check$bad_author_url) == 0,
  as.numeric(first_check$empty_display_name) == 0,
  as.numeric(first_check$empty_raw_name) == 0,
  as.numeric(inst_check$rows) == valid_pairs,
  as.numeric(inst_check$rows) == as.numeric(inst_check$distinct_pairs),
  as.numeric(inst_check$bad_author_id) == 0,
  as.numeric(inst_check$bad_institution_id) == 0,
  as.numeric(inst_check$bad_institution_url) == 0,
  as.numeric(inst_check$empty_institution_name) == 0,
  as.numeric(inst_check$bad_country) == 0,
  missing_author == 0,
  identical(first_schema$column_name, expected_first_names),
  identical(first_schema$column_type, expected_first_types),
  identical(inst_schema$column_name, expected_inst_names),
  identical(inst_schema$column_type, expected_inst_types)
)

if (known_test_shard) {
  stopifnot(
    as.numeric(first_check$rows) == 1152,
    as.numeric(inst_check$rows) == 170
  )
  cat("Known-shard regression counts passed (1,152 authors; 170 pairs).\n")
}

####################################################################
### Promote both validated outputs together
####################################################################

first_had_previous <- file.exists(first_path)
inst_had_previous <- file.exists(inst_path)

if (first_had_previous && !file.rename(first_path, first_previous)) {
  stop("Could not stage the previous first-publication output.")
}
if (inst_had_previous && !file.rename(inst_path, inst_previous)) {
  if (first_had_previous) file.rename(first_previous, first_path)
  stop("Could not stage the previous institution output.")
}

first_promoted <- file.rename(first_partial, first_path)
inst_promoted <- FALSE
if (first_promoted) {
  inst_promoted <- file.rename(inst_partial, inst_path)
}

if (!first_promoted || !inst_promoted) {
  if (first_promoted && file.exists(first_path)) {
    file.rename(first_path, first_partial)
  }
  if (inst_promoted && file.exists(inst_path)) {
    file.rename(inst_path, inst_partial)
  }
  if (first_had_previous && file.exists(first_previous)) {
    file.rename(first_previous, first_path)
  }
  if (inst_had_previous && file.exists(inst_previous)) {
    file.rename(inst_previous, inst_path)
  }
  stop("Could not promote both outputs; previous outputs were restored.")
}

if (file.exists(first_previous)) file.remove(first_previous)
if (file.exists(inst_previous)) file.remove(inst_previous)
if (dir.exists(cache_dir)) unlink(cache_dir, recursive = TRUE, force = TRUE)

cat("\nFinal outputs\n")
cat(" ", first_path, "\n")
cat("    rows:", format(first_check$rows, scientific = FALSE),
    " size:", sprintf("%.2f GiB", file.info(first_path)$size / 1024^3), "\n")
cat(" ", inst_path, "\n")
cat("    rows:", format(inst_check$rows, scientific = FALSE),
    " size:", sprintf("%.2f GiB", file.info(inst_path)$size / 1024^3), "\n")
cat("Completed:", format(Sys.time()), "\n")
