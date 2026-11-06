####################################################################
### Ranked bachelor + residual-duration cohort fixtures (local/offline)
####################################################################

rm(list = ls()); gc()

if (!requireNamespace("DBI", quietly = TRUE) ||
    !requireNamespace("duckdb", quietly = TRUE)) {
  stop("Missing packages DBI/duckdb. Install them before running this test.")
}

patterns_file <- Sys.getenv(
  "OBMEP_DEGREE_PATTERNS",
  unset = paste0("C:/Users/megaj/repos/obmep_effect/prep/",
                 "building_external_data/br_degree_patterns.R"))
if (!file.exists(patterns_file)) patterns_file <- "br_degree_patterns.R"
stopifnot(file.exists(patterns_file))
source(patterns_file)

con <- DBI::dbConnect(duckdb::duckdb())
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
DBI::dbExecute(con,
  "CREATE MACRO regexp_like(s, p) AS regexp_matches(coalesce(s, ''), p)")

cases <- data.frame(
  case_id = c(
    "pt_bacharel", "en_bachelor", "es_grado", "es_licenciado",
    "spaced_postgrad", "master", "phd_precedence",
    "high_school_label", "high_school_raw", "technical_raw",
    "exchange", "postdoc", "associate", "blank_four_years",
    "unknown_three_years", "unknown_six_years", "unknown_two_years",
    "unknown_seven_years", "missing_start", "missing_end", "reversed_dates"
  ),
  degree = c(
    "empty", "Bachelor", "empty", "empty", "empty", "Master", "Doctor",
    "High School", "Bachelor", "empty", "empty", "empty", "Associate",
    "empty", "empty", "empty", "empty", "empty", "empty", "empty", "empty"
  ),
  degree_raw = c(
    "bacharelado", "bachelor of science", "grado", "licenciado en economia",
    "pos- graduacao lato sensu", "mestrado em economia", "doutorado",
    "", "ensino medio", "curso tecnico", "exchange program", "pos-doutorado",
    "associate degree", "", "economista", "formacao profissional", "economista",
    "economista", "economista", "economista", "economista"
  ),
  startdate = as.Date(c(
    "2010-01-01", "2010-01-01", "2010-01-01", "2010-01-01",
    "2010-01-01", "2010-01-01", "2010-01-01", "2010-01-01",
    "2010-01-01", "2010-01-01", "2010-01-01", "2010-01-01",
    "2010-01-01", "2010-01-01", "2010-01-01", "2010-01-01",
    "2010-01-01", "2010-01-01", NA, "2010-01-01", "2014-01-01"
  )),
  enddate = as.Date(c(
    "2014-01-01", "2014-01-01", "2014-01-01", "2014-01-01",
    "2014-01-01", "2014-01-01", "2014-01-01", "2014-01-01",
    "2014-01-01", "2014-01-01", "2014-01-01", "2014-01-01",
    "2014-01-01", "2014-01-01", "2013-01-01", "2016-01-01",
    "2012-01-01", "2017-01-01", "2014-01-01", NA, "2010-01-01"
  )),
  expected_level = c(
    "bachelor", "bachelor", "bachelor", "bachelor", "other", "master", "phd",
    "other", "other", "other", "other", "other", "other", "other", "other",
    "other", "other", "other", "other", "other", "other"
  ),
  expected_residual = c(
    FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE,
    FALSE, FALSE, FALSE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE
  ),
  expected_duration = c(
    FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE,
    FALSE, FALSE, FALSE, TRUE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE
  ),
  expected_accept = c(
    TRUE, TRUE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE,
    FALSE, FALSE, FALSE, TRUE, TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE
  ),
  stringsAsFactors = FALSE
)
cases <- rbind(cases, data.frame(
  case_id = "ranked_bachelor_missing_start",
  degree = "Bachelor",
  degree_raw = "bachelor of arts",
  startdate = as.Date(NA),
  enddate = as.Date("2014-01-01"),
  expected_level = "bachelor",
  expected_residual = FALSE,
  expected_duration = FALSE,
  expected_accept = FALSE,
  stringsAsFactors = FALSE
))
cases <- rbind(cases, data.frame(
  case_id = c("technical_residual_guard", "postgraduate_residual_guard"),
  degree = c("empty", "empty"),
  degree_raw = c("Ensino T\u00e9cnico", "Postgraduate Degree"),
  startdate = as.Date(c("2010-01-01", "2010-01-01")),
  enddate = as.Date(c("2014-01-01", "2014-01-01")),
  expected_level = c("other", "other"),
  expected_residual = c(FALSE, FALSE),
  expected_duration = c(FALSE, FALSE),
  expected_accept = c(FALSE, FALSE),
  stringsAsFactors = FALSE
))
DBI::dbWriteTable(con, "degree_cases", cases)

actual <- DBI::dbGetQuery(con, sprintf(
  "WITH classified AS (
     SELECT *, lower(trim(coalesce(degree_raw, ''))) AS dr
     FROM degree_cases
   ), scored AS (
     SELECT *, (%1$s) AS level, (%2$s) AS residual_other
     FROM classified
   )
   SELECT *,
          residual_other
            AND startdate IS NOT NULL AND enddate IS NOT NULL
            AND year(enddate) - year(startdate) IN (3, 4, 5, 6)
            AS duration_bachelor,
          (level = 'bachelor' AND startdate IS NOT NULL)
            OR (residual_other
                AND startdate IS NOT NULL AND enddate IS NOT NULL
                AND year(enddate) - year(startdate) IN (3, 4, 5, 6))
            AS accepted
   FROM scored ORDER BY case_id",
  sql_ranked_level, sql_is_residual_other))

expected <- cases[order(cases$case_id), ]
observed <- data.frame(
  case_id = actual$case_id,
  level = actual$level,
  expected_level = expected$expected_level,
  residual_other = actual$residual_other,
  expected_residual = expected$expected_residual,
  duration_bachelor = actual$duration_bachelor,
  expected_duration = expected$expected_duration,
  accepted = actual$accepted,
  expected_accept = expected$expected_accept
)
bad <- observed[
  observed$level != observed$expected_level |
  observed$residual_other != observed$expected_residual |
  observed$duration_bachelor != observed$expected_duration |
  observed$accepted != observed$expected_accept, ]
if (nrow(bad)) print(bad)
stopifnot(
  identical(actual$level, expected$expected_level),
  identical(actual$residual_other, expected$expected_residual),
  identical(actual$duration_bachelor, expected$expected_duration),
  identical(actual$accepted, expected$expected_accept)
)

cat("[OK] ranked-degree and duration fixtures passed:", nrow(actual), "cases\n")
