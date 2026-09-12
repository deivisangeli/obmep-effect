####################################################################
### OpenAlex Brazilian-author candidates: affiliation OR name prior
###
### Local, offline pipeline. It unions the completed Brazilian-
### institution author product with STEM/2017+ authors whose given-name
### score is strictly above 0.5, deduplicates by author_id, rebuilds
### institution histories from the already-downloaded D:/OpenAlex works
### snapshot, and appends the full name-score evidence. No network access;
### this prep script is not SEDAP-bound.
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

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)
out_dir <- file.path(
  obmep_root, "Data", "intermediate", "openalex_authors"
)
br_name_dir <- file.path(out_dir, "br_name")

existing_override <- Sys.getenv(
  "OPENALEX_BR_OR_NAME_EXISTING_PATH", unset = ""
)
scores_override <- Sys.getenv(
  "OPENALEX_BR_OR_NAME_SCORES_PATH", unset = ""
)
cohort_override <- Sys.getenv(
  "OPENALEX_BR_OR_NAME_COHORT_PATH", unset = ""
)
histories_override <- Sys.getenv(
  "OPENALEX_BR_OR_NAME_HISTORIES_PATH", unset = ""
)
output_override <- Sys.getenv(
  "OPENALEX_BR_OR_NAME_OUTPUT_PATH", unset = ""
)

existing_path <- if (nzchar(existing_override)) existing_override else file.path(
  out_dir, "openalex_author_br_stem_2017plus_institutions.parquet"
)
scores_path <- if (nzchar(scores_override)) scores_override else file.path(
  br_name_dir, "openalex_author_stem_2017plus_br_name_scores.parquet"
)
cohort_path <- if (nzchar(cohort_override)) cohort_override else file.path(
  out_dir,
  "openalex_author_br_institution_or_name_stem_2017plus_cohort.parquet"
)
histories_path <- if (nzchar(histories_override)) histories_override else file.path(
  out_dir,
  "openalex_author_br_institution_or_name_stem_2017plus_institutions.parquet"
)
output_path <- if (nzchar(output_override)) output_override else file.path(
  out_dir, "openalex_author_br_institution_or_name_stem_2017plus.parquet"
)

output_partial <- paste0(output_path, ".partial")
output_previous <- paste0(output_path, ".previous")
cohort_partial <- paste0(cohort_path, ".partial")
cohort_previous <- paste0(cohort_path, ".previous")

production_mode <- !any(nzchar(c(
  existing_override, scores_override, cohort_override,
  histories_override, output_override,
  Sys.getenv("OPENALEX_WORKS_GLOB", unset = "")
)))

script_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
if (length(script_arg) != 1L) {
  stop("Could not identify this script's path.")
}
script_path <- normalizePath(
  sub("^--file=", "", script_arg), winslash = "/", mustWork = TRUE
)
extractor_path <- file.path(
  dirname(script_path),
  "openalex_author_br_stem_2017plus_institutions.R"
)

for (f in c(existing_path, scores_path, extractor_path)) {
  if (!file.exists(f) || file.info(f)$size <= 0) {
    stop("Required input is missing or empty: ", f)
  }
}
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(cohort_path), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(histories_path), recursive = TRUE, showWarnings = FALSE)
dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)

if (file.exists(output_path)) {
  cat("Final output already exists: ", output_path, "\n", sep = "")
  cat("Remove it explicitly before requesting a rebuild.\n")
  quit(save = "no", status = 0L)
}
if (file.exists(output_previous)) {
  stop("A .previous final output remains; inspect it before rerunning.")
}
if (file.exists(cohort_previous)) {
  stop("A .previous union cohort remains; inspect it before rerunning.")
}
if (file.exists(output_partial) && !file.remove(output_partial)) {
  stop("Could not remove stale final partial: ", output_partial)
}
if (file.exists(cohort_partial) && !file.remove(cohort_partial)) {
  stop("Could not remove stale cohort partial: ", cohort_partial)
}

memory_limit <- Sys.getenv(
  "OPENALEX_BR_OR_NAME_DUCKDB_MEMORY_LIMIT", unset = "12GB"
)
threads <- suppressWarnings(as.integer(Sys.getenv(
  "OPENALEX_BR_OR_NAME_DUCKDB_THREADS", unset = "8"
)))
if (is.na(threads) || threads < 1L) {
  stop("OPENALEX_BR_OR_NAME_DUCKDB_THREADS must be positive.")
}

existing_sql <- gsub(
  "'", "''", gsub("\\\\", "/", existing_path), fixed = TRUE
)
scores_sql <- gsub(
  "'", "''", gsub("\\\\", "/", scores_path), fixed = TRUE
)
cohort_sql <- gsub(
  "'", "''", gsub("\\\\", "/", cohort_path), fixed = TRUE
)
cohort_partial_sql <- gsub(
  "'", "''", gsub("\\\\", "/", cohort_partial), fixed = TRUE
)
histories_sql <- gsub(
  "'", "''", gsub("\\\\", "/", histories_path), fixed = TRUE
)
output_partial_sql <- gsub(
  "'", "''", gsub("\\\\", "/", output_partial), fixed = TRUE
)

cat("Existing author file :", existing_path, "\n")
cat("Name scores          :", scores_path, "\n")
cat("Union cohort         :", cohort_path, "\n")
cat("Union histories      :", histories_path, "\n")
cat("Final output         :", output_path, "\n\n")

####################################################################
### 1. Source contracts and deduplicated membership union
####################################################################

con <- dbConnect(duckdb())
dbExecute(con, sprintf("SET memory_limit = '%s'", memory_limit))
dbExecute(con, sprintf("SET threads = %d", threads))
dbExecute(con, "SET preserve_insertion_order = false")

existing_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", existing_sql
))
expected_existing_names <- c(
  "author_id", "author_url", "author_display_name", "raw_author_name",
  "first_publication_year", "ever_br_institution", "ever_stem",
  "institution_display_names",
  "institution_first_publication_years",
  "institution_country_codes"
)
expected_existing_types <- c(
  "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "INTEGER", "BOOLEAN",
  "BOOLEAN", "VARCHAR", "VARCHAR", "VARCHAR"
)
if (
  !identical(existing_schema$column_name, expected_existing_names) ||
  !identical(existing_schema$column_type, expected_existing_types)
) {
  stop("Existing author file does not match the ten-column contract.")
}

scores_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", scores_sql
))
expected_scores_names <- c(
  "author_id", "author_url", "author_display_name", "raw_author_name",
  "openalex_full_name", "openalex_authors_snapshot_date",
  "first_publication_year", "ever_br_institution", "ever_stem",
  "first_name_clean", "first_name_source", "name_was_comma_inverted",
  "flag_exact", "match_level", "ibge_freq", "canon_rank", "n_parents",
  "primary_canonical", "openalex_name_count", "openalex_name_share",
  "ibge_name_share", "ratio", "log10_ratio", "p_brazil_prior",
  "p_brazil"
)
expected_scores_types <- c(
  rep("VARCHAR", 5L), "DATE", "INTEGER", "BOOLEAN", "BOOLEAN",
  "VARCHAR", "VARCHAR", "BOOLEAN", "BOOLEAN", "VARCHAR", "INTEGER",
  "INTEGER", "BIGINT", "VARCHAR", "BIGINT", rep("DOUBLE", 6L)
)
if (
  !identical(scores_schema$column_name, expected_scores_names) ||
  !identical(scores_schema$column_type, expected_scores_types)
) {
  stop("Name-score file does not match the 25-column contract.")
}

source_check <- dbGetQuery(con, sprintf("
  WITH existing AS (
    SELECT * FROM read_parquet('%s')
  ), scores AS (
    SELECT * FROM read_parquet('%s')
  )
  SELECT
    (SELECT count(*) FROM existing) AS existing_rows,
    (SELECT count(DISTINCT author_id) FROM existing) AS existing_ids,
    (SELECT count(*) FROM scores) AS score_rows,
    (SELECT count(DISTINCT author_id) FROM scores) AS score_ids,
    (SELECT count(*) FROM scores WHERE p_brazil > 0.5) AS name_rows,
    (SELECT count(*) FROM scores WHERE p_brazil = 0.5) AS equal_half,
    (SELECT count(*) FROM existing AS e
       INNER JOIN scores AS s USING (author_id)
       WHERE s.p_brazil > 0.5) AS overlap_rows,
    (SELECT count(*) FROM existing AS e
       LEFT JOIN scores AS s USING (author_id)
       WHERE s.author_id IS NULL) AS existing_without_score,
    (SELECT count(*) FROM existing AS e
       INNER JOIN scores AS s USING (author_id)
       WHERE e.author_url IS DISTINCT FROM s.author_url
          OR e.author_display_name IS DISTINCT FROM s.author_display_name
          OR e.raw_author_name IS DISTINCT FROM s.raw_author_name
          OR e.first_publication_year IS DISTINCT FROM s.first_publication_year
          OR e.ever_br_institution IS DISTINCT FROM s.ever_br_institution
          OR e.ever_stem IS DISTINCT FROM s.ever_stem) AS provenance_mismatches,
    (SELECT count(*) FROM existing
       WHERE author_id IS NULL OR author_url IS NULL OR
             NOT ever_br_institution OR NOT ever_stem OR
             first_publication_year < 2017) AS invalid_existing,
    (SELECT count(*) FROM scores
       WHERE author_id IS NULL OR author_url IS NULL OR
             NOT ever_stem OR first_publication_year < 2017) AS invalid_scores
  ", existing_sql, scores_sql))

if (
  source_check$existing_rows != source_check$existing_ids ||
  source_check$score_rows != source_check$score_ids ||
  source_check$existing_without_score != 0 ||
  source_check$provenance_mismatches != 0 ||
  source_check$invalid_existing != 0 ||
  source_check$invalid_scores != 0
) {
  stop("Source files failed grain, coverage, provenance, or filter checks.")
}

union_rows <- source_check$existing_rows + source_check$name_rows -
  source_check$overlap_rows
if (production_mode && (
  source_check$existing_rows != 843232 ||
  source_check$name_rows != 197133 ||
  source_check$overlap_rows != 79850 ||
  source_check$equal_half != 0 ||
  union_rows != 960515
)) {
  stop("Production membership counts differ from the measured contract.")
}

cat("Existing arm         :", format(source_check$existing_rows, big.mark = ","), "\n")
cat("Name arm, > 0.5      :", format(source_check$name_rows, big.mark = ","), "\n")
cat("Overlap              :", format(source_check$overlap_rows, big.mark = ","), "\n")
cat("Deduplicated union   :", format(union_rows, big.mark = ","), "\n\n")

dbExecute(con, sprintf("
  COPY (
    WITH membership_rows AS (
      SELECT author_id, true AS in_existing, false AS in_name
      FROM read_parquet('%s')
      UNION ALL
      SELECT author_id, false AS in_existing, true AS in_name
      FROM read_parquet('%s')
      WHERE p_brazil > 0.5
    ), membership AS (
      SELECT
        author_id,
        bool_or(in_existing) AS in_existing,
        bool_or(in_name) AS in_name
      FROM membership_rows
      GROUP BY author_id
    )
    SELECT
      s.author_id,
      s.author_url,
      s.author_display_name,
      s.raw_author_name,
      s.first_publication_year,
      s.ever_br_institution,
      s.ever_stem
    FROM membership AS m
    INNER JOIN read_parquet('%s') AS s USING (author_id)
    ORDER BY s.author_id
  ) TO '%s' (
    FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
  )", existing_sql, scores_sql, scores_sql, cohort_partial_sql))

cohort_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT c.author_id) AS distinct_ids,
    count(DISTINCT c.author_url) AS distinct_urls,
    count_if(c.author_id IS NULL OR c.author_url IS NULL) AS null_ids,
    count_if(NOT c.ever_stem OR c.first_publication_year < 2017) AS bad_filter,
    count_if(
      NOT c.ever_br_institution AND NOT coalesce(s.p_brazil > 0.5, false)
    )
      AS bad_membership,
    CAST(bit_xor(hash(c.author_id)) AS VARCHAR) AS id_fingerprint
  FROM read_parquet('%s') AS c
  INNER JOIN read_parquet('%s') AS s USING (author_id)
  ", cohort_partial_sql, scores_sql))
if (
  cohort_check$rows != union_rows ||
  cohort_check$rows != cohort_check$distinct_ids ||
  cohort_check$rows != cohort_check$distinct_urls ||
  cohort_check$null_ids != 0 ||
  cohort_check$bad_filter != 0 ||
  cohort_check$bad_membership != 0
) {
  stop("Deduplicated union cohort failed validation.")
}

had_cohort <- file.exists(cohort_path)
if (had_cohort && !file.rename(cohort_path, cohort_previous)) {
  stop("Could not preserve the previous union cohort.")
}
if (!file.rename(cohort_partial, cohort_path)) {
  if (had_cohort && file.exists(cohort_previous)) {
    file.rename(cohort_previous, cohort_path)
  }
  stop("Could not promote the validated union cohort.")
}
if (had_cohort && file.exists(cohort_previous) &&
    !file.remove(cohort_previous)) {
  warning("Union cohort promoted, but .previous could not be removed.")
}

dbDisconnect(con, shutdown = TRUE)

####################################################################
### 2. Rebuild histories consistently over the full union
####################################################################

cache_version <- paste0(
  "v1_n", format(cohort_check$rows, scientific = FALSE, trim = TRUE),
  "_x", cohort_check$id_fingerprint, "_batch5_b64"
)

if (!file.exists(histories_path) || file.info(histories_path)$size <= 0) {
  child_keys <- c(
    "OPENALEX_COHORT_PATH",
    "OPENALEX_COHORT_INST_OUTPUT_PATH",
    "OPENALEX_COHORT_INST_REQUIRE_BR",
    "OPENALEX_COHORT_INST_EXPECTED_AUTHORS",
    "OPENALEX_COHORT_INST_CACHE_VERSION"
  )
  child_old <- Sys.getenv(child_keys, unset = NA_character_)
  Sys.setenv(
    OPENALEX_COHORT_PATH = cohort_path,
    OPENALEX_COHORT_INST_OUTPUT_PATH = histories_path,
    OPENALEX_COHORT_INST_REQUIRE_BR = "false",
    OPENALEX_COHORT_INST_EXPECTED_AUTHORS = format(
      cohort_check$rows, scientific = FALSE, trim = TRUE
    ),
    OPENALEX_COHORT_INST_CACHE_VERSION = cache_version
  )
  cat(format(Sys.time()), "starting resumable works-snapshot scan\n")
  child_status <- system2(
    file.path(R.home("bin"), "Rscript.exe"),
    args = shQuote(extractor_path)
  )
  for (i in seq_along(child_keys)) {
    if (is.na(child_old[[i]])) {
      Sys.unsetenv(child_keys[[i]])
    } else {
      do.call(Sys.setenv, setNames(list(child_old[[i]]), child_keys[[i]]))
    }
  }
  if (!identical(child_status, 0L)) {
    stop("The resumable institution-history extraction failed with status ",
         child_status, ".")
  }
}
if (!file.exists(histories_path) || file.info(histories_path)$size <= 0) {
  stop("Institution-history extraction did not produce: ", histories_path)
}

####################################################################
### 3. Append complete score evidence and validate the final product
####################################################################

con <- dbConnect(duckdb())
dbExecute(con, sprintf("SET memory_limit = '%s'", memory_limit))
dbExecute(con, sprintf("SET threads = %d", threads))
dbExecute(con, "SET preserve_insertion_order = false")

histories_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", histories_sql
))
if (
  !identical(histories_schema$column_name, expected_existing_names) ||
  !identical(histories_schema$column_type, expected_existing_types)
) {
  stop("Union history file does not match the ten-column contract.")
}

history_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT h.author_id) AS distinct_ids,
    count_if(c.author_id IS NULL) AS ids_outside_union,
    count_if(
      h.author_url IS DISTINCT FROM c.author_url OR
      h.author_display_name IS DISTINCT FROM c.author_display_name OR
      h.raw_author_name IS DISTINCT FROM c.raw_author_name OR
      h.first_publication_year IS DISTINCT FROM c.first_publication_year OR
      h.ever_br_institution IS DISTINCT FROM c.ever_br_institution OR
      h.ever_stem IS DISTINCT FROM c.ever_stem
    ) AS provenance_mismatches
  FROM read_parquet('%s') AS h
  LEFT JOIN read_parquet('%s') AS c USING (author_id)
  ", histories_sql, cohort_sql))
if (
  history_check$rows != cohort_check$rows ||
  history_check$rows != history_check$distinct_ids ||
  history_check$ids_outside_union != 0 ||
  history_check$provenance_mismatches != 0
) {
  stop("Union histories do not match the current deduplicated cohort.")
}

dbExecute(con, sprintf("
  COPY (
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
      coalesce(s.p_brazil > 0.5, false) AS br_name,
      h.institution_display_names,
      h.institution_first_publication_years,
      h.institution_country_codes,
      s.first_name_clean,
      s.first_name_source,
      s.name_was_comma_inverted,
      s.flag_exact,
      s.match_level,
      s.ibge_freq,
      s.canon_rank,
      s.n_parents,
      s.primary_canonical,
      s.openalex_name_count,
      s.openalex_name_share,
      s.ibge_name_share,
      s.ratio,
      s.log10_ratio,
      s.p_brazil_prior,
      s.p_brazil
    FROM read_parquet('%s') AS c
    INNER JOIN read_parquet('%s') AS h USING (author_id)
    INNER JOIN read_parquet('%s') AS s USING (author_id)
    ORDER BY s.author_id
  ) TO '%s' (
    FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 983040
  )", cohort_sql, histories_sql, scores_sql, output_partial_sql))

expected_output_names <- c(
  "author_id", "author_url", "author_display_name", "raw_author_name",
  "openalex_full_name", "openalex_authors_snapshot_date",
  "first_publication_year", "ever_br_institution", "ever_stem", "br_name",
  "institution_display_names", "institution_first_publication_years",
  "institution_country_codes", "first_name_clean", "first_name_source",
  "name_was_comma_inverted", "flag_exact", "match_level", "ibge_freq",
  "canon_rank", "n_parents", "primary_canonical", "openalex_name_count",
  "openalex_name_share", "ibge_name_share", "ratio", "log10_ratio",
  "p_brazil_prior", "p_brazil"
)
expected_output_types <- c(
  rep("VARCHAR", 5L), "DATE", "INTEGER", "BOOLEAN", "BOOLEAN", "BOOLEAN",
  rep("VARCHAR", 5L), "BOOLEAN", "BOOLEAN", "VARCHAR", "INTEGER", "INTEGER",
  "BIGINT", "VARCHAR", "BIGINT", rep("DOUBLE", 6L)
)
output_schema <- dbGetQuery(con, sprintf(
  "DESCRIBE SELECT * FROM read_parquet('%s')", output_partial_sql
))
if (
  !identical(output_schema$column_name, expected_output_names) ||
  !identical(output_schema$column_type, expected_output_types)
) {
  stop("Final output does not match the 29-column contract.")
}

output_check <- dbGetQuery(con, sprintf("
  SELECT
    count(*) AS rows,
    count(DISTINCT author_id) AS distinct_ids,
    count(DISTINCT author_url) AS distinct_urls,
    count_if(author_id IS NULL OR author_url IS NULL) AS null_ids,
    count_if(NOT ever_stem OR first_publication_year < 2017) AS bad_filter,
    count_if(NOT ever_br_institution AND NOT br_name) AS bad_membership,
    count_if(br_name IS DISTINCT FROM coalesce(p_brazil > 0.5, false))
      AS bad_br_name,
    count_if(p_brazil IS NOT NULL AND (p_brazil < 0 OR p_brazil > 1))
      AS bad_score_range,
    count_if(p_brazil_prior IS DISTINCT FROM 0.025) AS bad_prior,
    count_if(
      p_brazil IS NOT NULL AND abs(
        p_brazil - least(1.0, p_brazil_prior / ratio)
      ) > 1e-12
    ) AS bad_formula,
    count_if((p_brazil IS NULL) IS DISTINCT FROM (NOT flag_exact))
      AS bad_score_nulls,
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
    count_if(ever_br_institution AND br_name) AS both_arms,
    count_if(ever_br_institution AND NOT br_name) AS affiliation_only,
    count_if(NOT ever_br_institution AND br_name) AS name_only,
    count_if(p_brazil IS NULL) AS null_scores
  FROM read_parquet('%s')", output_partial_sql))
if (
  output_check$rows != cohort_check$rows ||
  output_check$rows != output_check$distinct_ids ||
  output_check$rows != output_check$distinct_urls ||
  output_check$null_ids != 0 ||
  output_check$bad_filter != 0 ||
  output_check$bad_membership != 0 ||
  output_check$bad_br_name != 0 ||
  output_check$bad_score_range != 0 ||
  output_check$bad_prior != 0 ||
  output_check$bad_formula != 0 ||
  output_check$bad_score_nulls != 0 ||
  output_check$null_histories != 0 ||
  output_check$misaligned_histories != 0
) {
  stop("Final output failed grain, selection, score, or history validation.")
}
if (production_mode && (
  output_check$both_arms != 79850 ||
  output_check$affiliation_only != 763382 ||
  output_check$name_only != 117283
)) {
  stop("Final production arm counts differ from the measured contract.")
}

print(source_check, row.names = FALSE)
print(output_check, row.names = FALSE)
cat("Validated partial size:",
    sprintf("%.2f MiB", file.info(output_partial)$size / 1024^2), "\n")

had_output <- file.exists(output_path)
if (had_output && !file.rename(output_path, output_previous)) {
  stop("Could not preserve the previous final output.")
}
if (!file.rename(output_partial, output_path)) {
  if (had_output && file.exists(output_previous)) {
    file.rename(output_previous, output_path)
  }
  stop("Could not promote the validated final output.")
}
if (had_output && file.exists(output_previous) &&
    !file.remove(output_previous)) {
  warning("Final output promoted, but .previous could not be removed.")
}

dbDisconnect(con, shutdown = TRUE)

cat("\nPromoted final output:", output_path, "\n")
cat("Final size           :",
    sprintf("%.2f MiB", file.info(output_path)$size / 1024^2), "\n")
cat("Completed            :", format(Sys.time()), "\n")
