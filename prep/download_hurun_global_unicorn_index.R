################################################################################

## Download Hurun Global Unicorn Index, 2023-2026
## Local online prep pipeline: requires internet access and must not run in SEDAP.

################################################################################

rm(list = ls()); gc()

required_packages <- c("curl", "jsonlite", "readr")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]

if (length(missing_packages) > 0) {
  stop(
    "Install the required packages before running this script: ",
    paste(missing_packages, collapse = ", ")
  )
}

################################################################################

### Parameters

################################################################################

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)

output_dir <- Sys.getenv(
  "HURUN_UNICORN_OUTPUT_DIR",
  unset = file.path(
    obmep_root,
    "Data",
    "raw",
    "hurun_global_unicorn_index"
  )
)

page_limit <- 200L
max_attempts <- 5L
request_pause_seconds <- 0.5

editions <- data.frame(
  index_year = 2023:2026,
  rank_id = c("MKIUCQ1P", "E9W1YX99", "E9W16F3H", "E9A16F3H"),
  published_total = c(1361L, 1453L, 1523L, 1603L),
  expected_live_total = c(1361L, 1452L, 1522L, 1602L),
  report_id = c(
    "3OEJNGKGFPDS",
    "9K1G2SK5X7CX",
    "2DVQ51ORRGTH",
    "N5C7D1KGTE8G"
  ),
  stringsAsFactors = FALSE
)

editions$source_rank_url <- paste0(
  "https://www.hurun.net/en-US/Rank/HsRankDetails?num=",
  editions$rank_id,
  "&pagetype=unicorn"
)

editions$source_report_url <- paste0(
  "https://www.hurun.net/en-us/info/detail?num=",
  editions$report_id
)
editions$source_rank_inversions <- NA_integer_
editions$extracted_total <- NA_integer_
editions$output_path <- NA_character_

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

################################################################################

### Download annual live tables

################################################################################

annual_data <- vector("list", nrow(editions))
run_timestamp_utc <- format(
  Sys.time(),
  tz = "UTC",
  format = "%Y-%m-%dT%H:%M:%SZ"
)

for (edition_index in seq_len(nrow(editions))) {
  index_year <- editions$index_year[[edition_index]]
  rank_id <- editions$rank_id[[edition_index]]
  rank_url <- editions$source_rank_url[[edition_index]]

  cat("Opening Hurun ranking page for", index_year, "...\n")

  handle <- curl::new_handle()
  curl::handle_setopt(
    handle,
    useragent = paste(
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
      "AppleWebKit/537.36 Chrome/140.0 Safari/537.36"
    ),
    followlocation = TRUE,
    connecttimeout = 30,
    timeout = 90,
    cookiefile = ""
  )

  page_loaded <- FALSE
  for (attempt in seq_len(max_attempts)) {
    page_response <- try(
      curl::curl_fetch_memory(rank_url, handle = handle),
      silent = TRUE
    )

    if (
      !inherits(page_response, "try-error") &&
        page_response$status_code == 200L
    ) {
      page_loaded <- TRUE
      break
    }

    if (attempt < max_attempts) {
      Sys.sleep(2^(attempt - 1L))
    }
  }

  if (!page_loaded) {
    stop("Could not open Hurun ranking page for ", index_year)
  }

  curl::handle_setheaders(
    handle,
    Referer = rank_url,
    Accept = "application/json, text/javascript, */*; q=0.01",
    `X-Requested-With` = "XMLHttpRequest"
  )

  offset <- 0L
  reported_total <- NA_integer_
  year_pages <- list()

  repeat {
    api_url <- paste0(
      "https://www.hurun.net/en-US/Rank/HsRankDetailsList?num=",
      rank_id,
      "&offset=",
      offset,
      "&limit=",
      page_limit,
      "&search="
    )

    page_downloaded <- FALSE
    for (attempt in seq_len(max_attempts)) {
      api_response <- try(
        curl::curl_fetch_memory(api_url, handle = handle),
        silent = TRUE
      )

      if (
        !inherits(api_response, "try-error") &&
          api_response$status_code == 200L
      ) {
        response_content <- api_response$content
        illegal_control_bytes <- as.integer(response_content) < 32L
        if (any(illegal_control_bytes)) {
          response_content[illegal_control_bytes] <- as.raw(32L)
        }

        response_text <- iconv(
          rawToChar(response_content),
          from = "UTF-8",
          to = "UTF-8",
          sub = ""
        )

        parsed_response <- try(
          jsonlite::fromJSON(
            response_text,
            simplifyDataFrame = TRUE
          ),
          silent = TRUE
        )

        if (
          !inherits(parsed_response, "try-error") &&
            !is.null(parsed_response$total) &&
            !is.null(parsed_response$rows)
        ) {
          page_downloaded <- TRUE
          break
        }
      }

      if (attempt < max_attempts) {
        Sys.sleep(2^(attempt - 1L))
      }
    }

    if (!page_downloaded) {
      stop(
        "Could not download Hurun ",
        index_year,
        " records at offset ",
        offset
      )
    }

    current_total <- as.integer(parsed_response$total[[1]])
    if (is.na(reported_total)) {
      reported_total <- current_total
    } else if (!identical(reported_total, current_total)) {
      stop("Hurun total changed during the ", index_year, " download")
    }

    current_rows <- parsed_response$rows
    if (!is.data.frame(current_rows) || nrow(current_rows) == 0L) {
      stop("Hurun returned an empty page before completion for ", index_year)
    }

    year_pages[[length(year_pages) + 1L]] <- current_rows
    offset <- offset + nrow(current_rows)

    cat(
      "  downloaded ",
      offset,
      " of ",
      reported_total,
      " rows\n",
      sep = ""
    )

    if (offset >= reported_total) {
      break
    }

    Sys.sleep(request_pause_seconds)
  }

  source_rows <- do.call(rbind, year_pages)
  rownames(source_rows) <- NULL

  if (nrow(source_rows) != reported_total) {
    stop(
      "Downloaded row count does not match Hurun total for ",
      index_year,
      ": ",
      nrow(source_rows),
      " versus ",
      reported_total
    )
  }

  if (reported_total != editions$expected_live_total[[edition_index]]) {
    stop(
      "Hurun live total changed for ",
      index_year,
      ": expected ",
      editions$expected_live_total[[edition_index]],
      ", received ",
      reported_total
    )
  }

  year_data <- data.frame(
    index_year = as.integer(source_rows$hs_Rank_Unicorn_Year),
    source_row_number = seq_len(nrow(source_rows)),
    rank = as.integer(source_rows$hs_Rank_Unicorn_Ranking),
    rank_change = as.character(source_rows$hs_Rank_Unicorn_Ranking_Change),
    valuation_usd_bn = as.numeric(source_rows$hs_Rank_Unicorn_Wealth_USD),
    valuation_cny_100m = as.numeric(source_rows$hs_Rank_Unicorn_Wealth),
    valuation_change = as.character(source_rows$hs_Rank_Unicorn_Wealth_Change),
    company_name_en = as.character(source_rows$hs_Rank_Unicorn_ComName_En),
    company_name_cn = as.character(source_rows$hs_Rank_Unicorn_ComName_Cn),
    founders_en = as.character(source_rows$hs_Rank_Unicorn_ChaName_En),
    founders_cn = as.character(source_rows$hs_Rank_Unicorn_ChaName_Cn),
    headquarters_en = as.character(
      source_rows$hs_Rank_Unicorn_ComHeadquarters_En
    ),
    headquarters_cn = as.character(
      source_rows$hs_Rank_Unicorn_ComHeadquarters_Cn
    ),
    industry_en = as.character(source_rows$hs_Rank_Unicorn_Industry_En),
    industry_cn = as.character(source_rows$hs_Rank_Unicorn_Industry_Cn),
    source_record_id = as.integer(source_rows$hs_Rank_Unicorn_ID),
    source_list_id = as.integer(source_rows$hs_Rank_Unicorn_ListID),
    certificate_url = ifelse(
      is.na(source_rows$hs_Rank_Unicorn_Certificate) |
        source_rows$hs_Rank_Unicorn_Certificate == "",
      NA_character_,
      paste0(
        "https://www.hurun.net",
        source_rows$hs_Rank_Unicorn_Certificate
      )
    ),
    source_rank_url = rank_url,
    extracted_at_utc = run_timestamp_utc,
    stringsAsFactors = FALSE,
    check.names = FALSE
  )

  source_rank_inversions <- sum(diff(year_data$rank) < 0L)
  editions$source_rank_inversions[[edition_index]] <- source_rank_inversions
  year_data <- year_data[
    order(year_data$rank, year_data$source_row_number),
    ,
    drop = FALSE
  ]
  rownames(year_data) <- NULL

  if (any(year_data$index_year != index_year, na.rm = TRUE)) {
    stop("API payload year does not match requested edition: ", index_year)
  }

  if (
    anyNA(year_data$index_year) ||
      anyNA(year_data$rank) ||
      anyNA(year_data$company_name_en) ||
      any(year_data$company_name_en == "") ||
      anyNA(year_data$valuation_usd_bn)
  ) {
    stop("Required values are missing in the ", index_year, " table")
  }

  if (any(diff(year_data$rank) < 0L)) {
    stop("Ranks are not nondecreasing for ", index_year)
  }

  if (anyDuplicated(year_data$source_record_id)) {
    stop("Duplicate source record IDs found for ", index_year)
  }

  annual_path <- file.path(
    output_dir,
    paste0("hurun_global_unicorn_index_", index_year, ".csv")
  )

  readr::write_csv(year_data, annual_path, na = "")
  annual_data[[edition_index]] <- year_data
  editions$extracted_total[[edition_index]] <- nrow(year_data)
  editions$output_path[[edition_index]] <- normalizePath(
    annual_path,
    winslash = "/",
    mustWork = TRUE
  )

  cat("Saved:", editions$output_path[[edition_index]], "\n")
}

################################################################################

### Combined output and manifest

################################################################################

combined_data <- do.call(rbind, annual_data)
rownames(combined_data) <- NULL

combined_path <- file.path(
  output_dir,
  "hurun_global_unicorn_index_2023_2026.csv"
)

readr::write_csv(combined_data, combined_path, na = "")

editions$published_minus_extracted <-
  editions$published_total - editions$extracted_total
editions$extracted_at_utc <- run_timestamp_utc

manifest <- editions[c(
  "index_year",
  "rank_id",
  "source_rank_url",
  "source_report_url",
  "published_total",
    "expected_live_total",
    "extracted_total",
    "published_minus_extracted",
    "source_rank_inversions",
    "extracted_at_utc",
  "output_path"
)]

manifest_path <- file.path(
  output_dir,
  "hurun_global_unicorn_index_manifest.csv"
)

readr::write_csv(manifest, manifest_path, na = "")

################################################################################

### Round-trip validation

################################################################################

column_types <- readr::cols(
  index_year = readr::col_integer(),
  source_row_number = readr::col_integer(),
  rank = readr::col_integer(),
  rank_change = readr::col_character(),
  valuation_usd_bn = readr::col_double(),
  valuation_cny_100m = readr::col_double(),
  valuation_change = readr::col_character(),
  company_name_en = readr::col_character(),
  company_name_cn = readr::col_character(),
  founders_en = readr::col_character(),
  founders_cn = readr::col_character(),
  headquarters_en = readr::col_character(),
  headquarters_cn = readr::col_character(),
  industry_en = readr::col_character(),
  industry_cn = readr::col_character(),
  source_record_id = readr::col_integer(),
  source_list_id = readr::col_integer(),
  certificate_url = readr::col_character(),
  source_rank_url = readr::col_character(),
  extracted_at_utc = readr::col_character()
)

for (edition_index in seq_len(nrow(editions))) {
  annual_round_trip <- readr::read_csv(
    editions$output_path[[edition_index]],
    col_types = column_types,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )

  expected_data <- annual_data[[edition_index]]
  if (!identical(names(annual_round_trip), names(expected_data))) {
    stop("Annual CSV column mismatch for ", editions$index_year[[edition_index]])
  }

  for (column_name in names(expected_data)) {
    if (!identical(annual_round_trip[[column_name]], expected_data[[column_name]])) {
      stop(
        "Annual CSV round-trip mismatch for ",
        editions$index_year[[edition_index]],
        ", column ",
        column_name
      )
    }
  }
}

combined_round_trip <- readr::read_csv(
  combined_path,
  col_types = column_types,
  progress = FALSE,
  name_repair = "minimal",
  na = "",
  trim_ws = FALSE
)

if (!identical(names(combined_round_trip), names(combined_data))) {
  stop("Combined CSV column mismatch")
}

for (column_name in names(combined_data)) {
  if (!identical(combined_round_trip[[column_name]], combined_data[[column_name]])) {
    stop("Combined CSV round-trip mismatch in column ", column_name)
  }
}

if (nrow(combined_round_trip) != sum(editions$expected_live_total)) {
  stop("Combined row count does not match expected live totals")
}

cat("\nDownload and validation complete.\n")
cat("Combined rows:", nrow(combined_round_trip), "\n")
cat(
  "Combined file:",
  normalizePath(combined_path, winslash = "/", mustWork = TRUE),
  "\n"
)
cat(
  "Manifest:",
  normalizePath(manifest_path, winslash = "/", mustWork = TRUE),
  "\n"
)
