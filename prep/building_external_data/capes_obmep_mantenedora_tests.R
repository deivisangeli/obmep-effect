####################################################################
### Structural regression tests for the degree-duration maintainer match
###
### Local, OFFLINE validation. Reads only local products; does not mutate them.
####################################################################

for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) stop("Missing package: ", p)
}
library(DBI)
library(duckdb)

obmep_root <- Sys.getenv(
  "OBMEP_ROOT", unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
capes_dir <- file.path(obmep_root, "Data/intermediate/capes_discentes")
co_ies_version <- Sys.getenv("OBMEP_MATCH_CO_IES_VERSION", unset = "base")
if (!co_ies_version %in% c("base", "regex_v1")) stop("Bad CO_IES version")
version_tag <- if (co_ies_version == "regex_v1") "_regex_v1" else ""
sidecar_path <- file.path(
  capes_dir,
  "capes_masters_doctorates_born_1988plus_2004_2024_emec_mantenedora.parquet")
msc_dir <- file.path(
  capes_dir, paste0("capes_obmep_match_degree_duration_mantenedora",
                    version_tag, "_msc"))
phd_dir <- file.path(
  capes_dir, paste0("capes_obmep_match_degree_duration_mantenedora",
                    version_tag, "_phd"))
union_dir <- file.path(
  capes_dir, paste0("capes_obmep_match_union_degree_duration_mantenedora",
                    version_tag))
msc_path <- file.path(msc_dir, "capes_obmep_match_candidates.parquet")
phd_path <- file.path(phd_dir, "capes_obmep_match_candidates.parquet")
union_path <- file.path(union_dir, "capes_obmep_match_candidates.parquet")
placebo_path <- file.path(union_dir, "capes_obmep_match_placebo.parquet")
sample_path <- file.path(union_dir, "capes_obmep_match_audit_sample.parquet")
xlsx_path <- file.path(union_dir, "capes_obmep_match_audit_sample.xlsx")
stopifnot(all(file.exists(c(sidecar_path, msc_path, phd_path, union_path,
                            placebo_path, sample_path, xlsx_path))))

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
sidecar_sql <- as.character(dbQuoteString(con, gsub("\\\\", "/", sidecar_path)))
msc_sql <- as.character(dbQuoteString(con, gsub("\\\\", "/", msc_path)))
phd_sql <- as.character(dbQuoteString(con, gsub("\\\\", "/", phd_path)))
union_sql <- as.character(dbQuoteString(con, gsub("\\\\", "/", union_path)))
placebo_sql <- as.character(dbQuoteString(con, gsub("\\\\", "/", placebo_path)))
sample_sql <- as.character(dbQuoteString(con, gsub("\\\\", "/", sample_path)))

sidecar <- dbGetQuery(con, sprintf("
  SELECT count(*) AS rows, count(DISTINCT person_key) AS internal_people,
         count_if(CO_IES IS NOT NULL) AS with_co_ies,
         count_if(CO_MANTENEDORA IS NOT NULL) AS with_mantenedora,
         count_if(institution_bucket LIKE 'M:%%') AS bucket_m,
         count_if(institution_bucket LIKE 'I:%%') AS bucket_i,
         count_if(institution_bucket IS NULL) AS bucket_null,
         min(birth_year) AS min_birth_year
  FROM read_parquet(%s)", sidecar_sql))
stopifnot(
  sidecar$rows == 733879L,
  sidecar$with_co_ies == 701862L,
  sidecar$with_mantenedora == 693252L,
  sidecar$bucket_m == 693252L,
  sidecar$bucket_i == 8610L,
  sidecar$bucket_null == 32017L,
  sidecar$min_birth_year >= 1988L
)

arm_expected <- if (co_ies_version == "base") {
  list(msc = c(msc_sql, 144987L, 130556L, 136650L),
       phd = c(phd_sql, 37951L, 34872L, 37431L))
} else {
  list(msc = c(msc_sql, 163699L, 147047L, 154296L),
       phd = c(phd_sql, 43393L, 39772L, 42799L))
}
for (x in arm_expected) {
  q <- dbGetQuery(con, sprintf("
    SELECT count(*) FILTER (WHERE jw_combo >= 0.90 AND jw_lastname >= 0.90)
             AS pairs,
           count(DISTINCT person_key) FILTER
             (WHERE jw_combo >= 0.90 AND jw_lastname >= 0.90) AS people,
           count(DISTINCT user_id) FILTER
             (WHERE jw_combo >= 0.90 AND jw_lastname >= 0.90) AS users
    FROM read_parquet(%s)", x[[1]]))
  stopifnot(q$pairs == as.integer(x[[2]]),
            q$people == as.integer(x[[3]]),
            q$users == as.integer(x[[4]]))
  schema <- names(dbGetQuery(con, sprintf(
    "SELECT * FROM read_parquet(%s) LIMIT 0", x[[1]])))
  stopifnot(!any(grepl("_oa_id$", schema)),
            all(c("capes_msc_institution_bucket",
                  "capes_phd_institution_bucket",
                  "revelio_msc_institution_bucket",
                  "revelio_phd_institution_bucket") %in% schema))
}

union <- dbGetQuery(con, sprintf("
  SELECT count(*) AS pairs,
         count(DISTINCT (person_key, user_id)) AS distinct_pairs,
         count(DISTINCT person_key) AS people,
         count(DISTINCT user_id) AS users,
         count_if(in_msc AND NOT in_phd) AS msc_only,
         count_if(in_phd AND NOT in_msc) AS phd_only,
         count_if(in_msc AND in_phd) AS both,
         count_if(in_msc AND capes_msc_institution_bucket IS DISTINCT FROM
                   revelio_msc_institution_bucket) AS bad_msc_bucket,
         count_if(in_phd AND capes_phd_institution_bucket IS DISTINCT FROM
                   revelio_phd_institution_bucket) AS bad_phd_bucket,
         count_if(NOT in_msc AND NOT in_phd) AS bad_arm
  FROM read_parquet(%s)", union_sql))
union_expected <- if (co_ies_version == "base") {
  c(pairs=153786L, people=138368L, users=144860L,
    msc_only=115835L, phd_only=8799L, both=29152L)
} else {
  c(pairs=172444L, people=154729L, users=162360L,
    msc_only=129051L, phd_only=8745L, both=34648L)
}
stopifnot(
  union$pairs == union_expected[["pairs"]], union$distinct_pairs == union$pairs,
  union$people == union_expected[["people"]],
  union$users == union_expected[["users"]],
  union$msc_only == union_expected[["msc_only"]],
  union$phd_only == union_expected[["phd_only"]],
  union$both == union_expected[["both"]], union$bad_msc_bucket == 0L,
  union$bad_phd_bucket == 0L, union$bad_arm == 0L
)

placebo <- dbGetQuery(con, sprintf("
  SELECT pares, pessoas, users
  FROM read_parquet(%s) WHERE medida = 'placebo_B_deduplicado'", placebo_sql))
placebo_expected <- if (co_ies_version == "base") c(7427L, 6772L, 5730L) else
  c(8438L, 7649L, 6480L)
stopifnot(nrow(placebo) == 1L, placebo$pares == placebo_expected[[1]],
          placebo$pessoas == placebo_expected[[2]],
          placebo$users == placebo_expected[[3]])

sample <- dbGetQuery(con, sprintf("
  SELECT count(*) AS rows, count(DISTINCT pair_id) AS pairs,
         count_if(in_msc AND capes_msc_bucket IS DISTINCT FROM
                   linkedin_msc_bucket) AS bad_msc_bucket,
         count_if(in_phd AND capes_phd_bucket IS DISTINCT FROM
                   linkedin_phd_bucket) AS bad_phd_bucket
  FROM read_parquet(%s)", sample_sql))
stopifnot(sample$rows == 100L, sample$pairs == 100L,
          sample$bad_msc_bucket == 0L, sample$bad_phd_bucket == 0L,
          file.size(xlsx_path) > 10000)

cat("[OK] CAPES maintainer sidecar coverage\n")
cat("[OK] master and PhD arm counts and public schemas\n")
cat("[OK] union deduplication, arm flags and bucket equality\n")
cat("[OK] deduplicated placebo and 100-row audit sample\n")
