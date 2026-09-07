################################################################################

## Build Hurun top-200 technology-unicorn LinkedIn datasets
## Local online prep pipeline: manual research requires internet and must not run
## in SEDAP.

################################################################################

rm(list = ls()); gc()

if (!requireNamespace("readr", quietly = TRUE)) {
  stop("Install the 'readr' package before running this script.")
}

args <- commandArgs(trailingOnly = TRUE)
mode <- if (length(args) > 0L) tolower(args[[1]]) else "prepare"

if (!mode %in% c("prepare", "consolidate")) {
  stop("Mode must be 'prepare' or 'consolidate'.")
}

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)

source_path <- file.path(
  obmep_root,
  "Data",
  "raw",
  "hurun_global_unicorn_index",
  "hurun_global_unicorn_index_2023_2026.csv"
)

prior_dir <- file.path(
  obmep_root,
  "Data",
  "intermediate",
  "hurun_global_unicorn_index",
  "linkedin_top200_2023_2026"
)

output_dir <- file.path(
  obmep_root,
  "Data",
  "intermediate",
  "hurun_global_unicorn_index",
  "linkedin_top200_tech_2023_2026"
)

inputs_dir <- file.path(output_dir, "inputs")
audits_dir <- file.path(output_dir, "audits")
results_dirs <- file.path(output_dir, paste0("results_", c("a", "b", "c")))

panel_stage_path <- file.path(output_dir, "top200_tech_annual_panel_prelinkedin.csv")
crosswalk_path <- file.path(output_dir, "entity_crosswalk.csv")
master_stage_path <- file.path(output_dir, "linkedin_entity_master_candidates.csv")
seed_path <- file.path(output_dir, "linkedin_seed_results.csv")
manifest_path <- file.path(output_dir, "bucket_manifest.csv")

master_final_path <- file.path(
  output_dir,
  "hurun_top200_tech_2023_2026_linkedin_company_master.csv"
)

panel_final_path <- file.path(
  output_dir,
  "hurun_top200_tech_2023_2026_linkedin_annual_panel.csv"
)

if (!file.exists(source_path)) {
  stop("Hurun combined source file not found: ", source_path)
}

original_columns <- c(
  "index_year",
  "source_row_number",
  "rank",
  "rank_change",
  "valuation_usd_bn",
  "valuation_cny_100m",
  "valuation_change",
  "company_name_en",
  "company_name_cn",
  "founders_en",
  "founders_cn",
  "headquarters_en",
  "headquarters_cn",
  "industry_en",
  "industry_cn",
  "source_record_id",
  "source_list_id",
  "certificate_url",
  "source_rank_url",
  "extracted_at_utc"
)

tech_industries <- c(
  "3d printing",
  "adtech",
  "analytics",
  "artificial intelligence",
  "aerospace",
  "aerospace and defence",
  "big data",
  "biotech",
  "blockchain",
  "climatetech",
  "cloud",
  "communication platform",
  "consumer electronics",
  "cyber security",
  "data & analytics",
  "data analytics",
  "digital technology",
  "e- scooters",
  "e-cars",
  "e-commerce",
  "e-scooters",
  "edtech",
  "enterprise services",
  "ev battery",
  "fintech",
  "gaming",
  "health tech",
  "hrtech",
  "insuretech",
  "legaltech",
  "life sciences",
  "new energy",
  "new retail",
  "on-demand delivery",
  "online retail",
  "quantum tech",
  "quantum technology",
  "real estate tech",
  "robotics",
  "saas",
  "semiconductor",
  "semiconductors",
  "shared economy",
  "smart chips",
  "social media",
  "telecommunications"
)

alias_map <- c(
  "FiveTran" = "Fivetran",
  "Fivetran" = "Fivetran",
  "JD Chanfa" = "JD Property",
  "JD Property" = "JD Property",
  "Xiaohongshu" = "Little Red Note",
  "Little Red Note" = "Little Red Note",
  "Envision Aesc" = "AESC",
  "Aesc" = "AESC",
  "Blockchain" = "Blockchain.com",
  "Blockchain.com" = "Blockchain.com",
  "wefox Group" = "wefox",
  "wefox" = "wefox",
  "Caris" = "Caris Life Sciences",
  "Caris Life Sciences" = "Caris Life Sciences",
  "TripActions" = "Navan",
  "Navan" = "Navan",
  "OYO" = "OYO",
  "Prism (OYO)" = "OYO"
)

alias_evidence <- c(
  "Fivetran" = "https://www.fivetran.com/about",
  "JD Property" = "https://ir.jd.com/static-files/bc903e5f-f2bc-4458-be67-6bd5041b31e9",
  "Little Red Note" = "https://www.xiaohongshu.com/",
  "AESC" = "https://us.aesc-group.com/about-us/",
  "Blockchain.com" = "https://www.blockchain.com/blog/posts/blockchains-got-a-brand-new-look",
  "wefox" = "https://www.wefox.com/about",
  "Caris Life Sciences" = "https://www.carislifesciences.com/",
  "Navan" = "https://investors.navan.com/news-releases/news-release-details/tripactions-rebrands-navan",
  "OYO" = "https://www.prismhq.com/"
)

expected_result_columns <- c(
  "entity_id",
  "linkedin_company_url",
  "linkedin_match_status",
  "verification_source_url",
  "research_notes"
)

allowed_statuses <- c("verified", "probable", "ambiguous", "not_found")
all_character <- readr::cols(.default = readr::col_character())

################################################################################

### Prepare the top-200-per-year technology panel and research buckets

################################################################################

if (mode == "prepare") {
  dir.create(inputs_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(audits_dir, recursive = TRUE, showWarnings = FALSE)
  for (result_dir in results_dirs) {
    dir.create(result_dir, recursive = TRUE, showWarnings = FALSE)
  }

  source_data <- readr::read_csv(
    source_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )

  if (!identical(names(source_data), original_columns)) {
    stop("Unexpected Hurun combined source schema.")
  }

  panel_parts <- vector("list", 4L)
  selected_years <- 2023:2026

  for (year_index in seq_along(selected_years)) {
    index_year <- selected_years[[year_index]]
    year_data <- source_data[as.integer(source_data$index_year) == index_year, ]
    normalized_industry <- tolower(trimws(year_data$industry_en))
    year_data <- year_data[normalized_industry %in% tech_industries, ]
    year_data <- year_data[
      order(
        as.integer(year_data$rank),
        as.integer(year_data$source_row_number)
      ),
      ,
      drop = FALSE
    ]

    if (nrow(year_data) < 200L) {
      stop("Fewer than 200 technology companies for ", index_year)
    }

    panel_parts[[year_index]] <- year_data[seq_len(200L), , drop = FALSE]
  }

  panel <- do.call(rbind, panel_parts)
  rownames(panel) <- NULL
  normalized_panel_industry <- tolower(trimws(panel$industry_en))

  if (
    nrow(panel) != 800L ||
      any(table(panel$index_year) != 200L) ||
      any(!normalized_panel_industry %in% tech_industries) ||
      anyDuplicated(paste(panel$index_year, panel$source_record_id, sep = "|"))
  ) {
    stop("Top-200 technology annual panel validation failed.")
  }

  occurrence_name <- trimws(panel$company_name_en)
  canonical_name <- occurrence_name
  alias_hit <- occurrence_name %in% names(alias_map)
  canonical_name[alias_hit] <- unname(alias_map[occurrence_name[alias_hit]])

  canonical_values <- sort(unique(canonical_name))
  best_rank <- vapply(
    canonical_values,
    function(value) min(as.integer(panel$rank[canonical_name == value])),
    integer(1)
  )
  canonical_values <- canonical_values[order(best_rank, canonical_values)]
  entity_ids <- sprintf("HT%04d", seq_along(canonical_values))
  names(entity_ids) <- canonical_values

  panel$entity_id <- unname(entity_ids[canonical_name])
  panel$canonical_company_name <- canonical_name

  if (length(unique(panel$entity_id)) != 341L) {
    stop("Expected 341 entities after confirmed alias merges.")
  }

  entity_rows <- split(seq_len(nrow(panel)), panel$entity_id)
  master <- vector("list", length(entity_rows))
  crosswalk <- vector("list", nrow(panel))
  crosswalk_index <- 0L

  for (entity_index in seq_along(entity_rows)) {
    row_indexes <- entity_rows[[entity_index]]
    entity_data <- panel[row_indexes, , drop = FALSE]
    entity_data <- entity_data[order(as.integer(entity_data$index_year)), ]
    entity_id <- entity_data$entity_id[[1]]
    canonical <- entity_data$canonical_company_name[[1]]
    aliases_en <- unique(trimws(entity_data$company_name_en))
    aliases_cn <- unique(trimws(entity_data$company_name_cn))
    alias_group <- length(aliases_en) > 1L
    latest_row <- which.max(as.integer(entity_data$index_year))

    year_ranks <- setNames(rep(NA_character_, 4L), paste0("rank_", 2023:2026))
    for (year_value in 2023:2026) {
      rank_value <- entity_data$rank[as.integer(entity_data$index_year) == year_value]
      if (length(rank_value) == 1L) {
        year_ranks[[paste0("rank_", year_value)]] <- rank_value
      }
    }

    evidence_url <- if (canonical %in% names(alias_evidence)) {
      unname(alias_evidence[[canonical]])
    } else {
      NA_character_
    }

    master[[entity_index]] <- data.frame(
      entity_id = entity_id,
      canonical_company_name = canonical,
      company_name_aliases = paste(aliases_en, collapse = "|"),
      company_name_cn_aliases = paste(aliases_cn, collapse = "|"),
      years_in_top200_tech = paste(entity_data$index_year, collapse = "|"),
      industries_en = paste(unique(entity_data$industry_en), collapse = "|"),
      rank_2023 = year_ranks[["rank_2023"]],
      rank_2024 = year_ranks[["rank_2024"]],
      rank_2025 = year_ranks[["rank_2025"]],
      rank_2026 = year_ranks[["rank_2026"]],
      best_rank = as.character(min(as.integer(entity_data$rank))),
      latest_index_year = entity_data$index_year[[latest_row]],
      latest_headquarters_en = entity_data$headquarters_en[[latest_row]],
      latest_industry_en = entity_data$industry_en[[latest_row]],
      source_record_ids = paste(entity_data$source_record_id, collapse = "|"),
      dedup_rule = if (alias_group) "confirmed_alias" else "exact_name",
      dedup_evidence_url = evidence_url,
      stringsAsFactors = FALSE,
      check.names = FALSE
    )

    for (row_index in row_indexes) {
      crosswalk_index <- crosswalk_index + 1L
      crosswalk[[crosswalk_index]] <- data.frame(
        entity_id = entity_id,
        index_year = panel$index_year[[row_index]],
        source_record_id = panel$source_record_id[[row_index]],
        company_name_en = panel$company_name_en[[row_index]],
        company_name_cn = panel$company_name_cn[[row_index]],
        canonical_company_name = canonical,
        dedup_rule = if (alias_group) "confirmed_alias" else "exact_name",
        dedup_evidence_url = evidence_url,
        stringsAsFactors = FALSE,
        check.names = FALSE
      )
    }
  }

  master <- do.call(rbind, master)
  master <- master[order(as.integer(master$best_rank), master$canonical_company_name), ]
  rownames(master) <- NULL
  crosswalk <- do.call(rbind, crosswalk)
  crosswalk <- crosswalk[
    order(as.integer(crosswalk$index_year), as.integer(crosswalk$source_record_id)),
  ]
  rownames(crosswalk) <- NULL

  prior_master_path <- file.path(prior_dir, "linkedin_entity_master_candidates.csv")
  prior_manifest_path <- file.path(prior_dir, "bucket_manifest.csv")
  if (any(!file.exists(c(prior_master_path, prior_manifest_path)))) {
    stop("Prior LinkedIn research staging files are missing.")
  }

  prior_master <- readr::read_csv(
    prior_master_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )
  prior_manifest <- readr::read_csv(
    prior_manifest_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )

  prior_parts <- vector("list", nrow(prior_manifest))
  for (prior_index in seq_len(nrow(prior_manifest))) {
    prior_result_path <- prior_manifest$result_path[[prior_index]]
    if (!file.exists(prior_result_path)) {
      stop("Prior result file is missing: ", prior_result_path)
    }
    prior_parts[[prior_index]] <- readr::read_csv(
      prior_result_path,
      col_types = all_character,
      progress = FALSE,
      name_repair = "minimal",
      na = "",
      trim_ws = FALSE
    )
  }
  prior_results <- do.call(rbind, prior_parts)
  rownames(prior_results) <- NULL

  infinite_row <- prior_master$canonical_company_name == "Infinite Reality"
  infinite_id <- prior_master$entity_id[infinite_row]
  prior_results$linkedin_company_url[
    prior_results$entity_id == infinite_id
  ] <- "https://www.linkedin.com/company/napstercorp/"
  prior_results$linkedin_match_status[
    prior_results$entity_id == infinite_id
  ] <- "verified"
  prior_results$verification_source_url[
    prior_results$entity_id == infinite_id
  ] <- "https://www.linkedin.com/company/napstercorp/"
  prior_results$research_notes[
    prior_results$entity_id == infinite_id
  ] <- paste(
    "Independent audit confirmed the current continuation:",
    "Napster Corp states that Infinite Reality is now Napster."
  )

  prior_lookup <- match(master$canonical_company_name, prior_master$canonical_company_name)
  prior_entity_id <- prior_master$entity_id[prior_lookup]
  result_lookup <- match(prior_entity_id, prior_results$entity_id)
  seeded_url <- prior_results$linkedin_company_url[result_lookup]
  has_seed <- !is.na(seeded_url) & seeded_url != ""

  seed <- data.frame(
    entity_id = master$entity_id[has_seed],
    linkedin_company_url = seeded_url[has_seed],
    linkedin_match_status = prior_results$linkedin_match_status[result_lookup][has_seed],
    verification_source_url = prior_results$verification_source_url[result_lookup][has_seed],
    research_notes = prior_results$research_notes[result_lookup][has_seed],
    stringsAsFactors = FALSE,
    check.names = FALSE
  )

  research_needed <- master[!has_seed, , drop = FALSE]

  if (
    nrow(master) != 341L ||
      nrow(crosswalk) != 800L ||
      nrow(seed) != 308L ||
      nrow(research_needed) != 33L
  ) {
    stop("Prepared entity, seed, or research-needed count is incorrect.")
  }

  readr::write_csv(panel, panel_stage_path, na = "")
  readr::write_csv(crosswalk, crosswalk_path, na = "")
  readr::write_csv(master, master_stage_path, na = "")
  readr::write_csv(seed, seed_path, na = "")

  bucket_count <- ceiling(nrow(research_needed) / 10L)
  agent_rotation <- c("a", "b", "c")
  manifest <- data.frame(
    bucket = sprintf("%02d", seq_len(bucket_count)),
    start_research_row = seq(1L, by = 10L, length.out = bucket_count),
    end_research_row = pmin(
      seq(10L, by = 10L, length.out = bucket_count),
      nrow(research_needed)
    ),
    agent = agent_rotation[((seq_len(bucket_count) - 1L) %% 3L) + 1L],
    input_path = NA_character_,
    result_path = NA_character_,
    stringsAsFactors = FALSE
  )

  for (bucket_index in seq_len(nrow(manifest))) {
    bucket <- manifest$bucket[[bucket_index]]
    input_path <- file.path(inputs_dir, paste0("bucket_", bucket, ".csv"))
    result_path <- file.path(
      output_dir,
      paste0("results_", manifest$agent[[bucket_index]]),
      paste0("bucket_", bucket, "_linkedin.csv")
    )
    input_rows <- manifest$start_research_row[[bucket_index]]:
      manifest$end_research_row[[bucket_index]]

    readr::write_csv(research_needed[input_rows, , drop = FALSE], input_path, na = "")
    manifest$input_path[[bucket_index]] <- normalizePath(
      input_path,
      winslash = "/",
      mustWork = TRUE
    )
    manifest$result_path[[bucket_index]] <- result_path
  }

  readr::write_csv(manifest, manifest_path, na = "")

  panel_round_trip <- readr::read_csv(
    panel_stage_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )
  for (column_name in original_columns) {
    if (!identical(panel_round_trip[[column_name]], panel[[column_name]])) {
      stop("Original panel field changed during CSV round trip: ", column_name)
    }
  }

  cat("Preparation complete.\n")
  cat("Annual panel rows:", nrow(panel), "\n")
  cat("Unique entities:", nrow(master), "\n")
  cat("Seeded LinkedIn results:", nrow(seed), "\n")
  cat("Entities requiring research:", nrow(research_needed), "\n")
  cat("Research buckets:", nrow(manifest), "\n")
  cat("Output directory:", normalizePath(output_dir, winslash = "/"), "\n")
}

################################################################################

### Consolidate seeded and newly researched LinkedIn results

################################################################################

if (mode == "consolidate") {
  required_paths <- c(
    panel_stage_path,
    master_stage_path,
    seed_path,
    manifest_path
  )
  if (any(!file.exists(required_paths))) {
    stop("Preparation outputs are missing; run prepare mode first.")
  }

  panel <- readr::read_csv(
    panel_stage_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )
  master <- readr::read_csv(
    master_stage_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )
  seed <- readr::read_csv(
    seed_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )
  manifest <- readr::read_csv(
    manifest_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )

  if (!identical(names(seed), expected_result_columns)) {
    stop("Unexpected seeded-result schema.")
  }

  result_parts <- vector("list", nrow(manifest))
  for (bucket_index in seq_len(nrow(manifest))) {
    result_path <- manifest$result_path[[bucket_index]]
    if (!file.exists(result_path)) {
      stop("Missing result file: ", result_path)
    }

    result_data <- readr::read_csv(
      result_path,
      col_types = all_character,
      progress = FALSE,
      name_repair = "minimal",
      na = "",
      trim_ws = FALSE
    )
    if (!identical(names(result_data), expected_result_columns)) {
      stop("Unexpected result schema: ", result_path)
    }

    expected_rows <- as.integer(manifest$end_research_row[[bucket_index]]) -
      as.integer(manifest$start_research_row[[bucket_index]]) + 1L
    if (nrow(result_data) != expected_rows) {
      stop("Unexpected result row count: ", result_path)
    }
    result_parts[[bucket_index]] <- result_data
  }

  researched <- do.call(rbind, result_parts)
  results <- rbind(seed, researched)
  rownames(results) <- NULL

  if (
    nrow(results) != nrow(master) ||
      anyDuplicated(results$entity_id) ||
      !setequal(results$entity_id, master$entity_id) ||
      any(!results$linkedin_match_status %in% allowed_statuses)
  ) {
    stop("Combined LinkedIn result validation failed.")
  }

  has_url <- !is.na(results$linkedin_company_url) &
    results$linkedin_company_url != ""
  needs_url <- results$linkedin_match_status %in% c("verified", "probable")
  canonical_pattern <- "^https://www\\.linkedin\\.com/company/[^/?#]+/$"

  if (any(has_url != needs_url)) {
    stop("LinkedIn URL/status consistency check failed.")
  }
  if (any(has_url & !grepl(canonical_pattern, results$linkedin_company_url))) {
    stop("A LinkedIn URL is not canonical.")
  }
  if (anyDuplicated(results$linkedin_company_url[has_url])) {
    stop("Duplicate LinkedIn URLs require adjudication before consolidation.")
  }
  if (any(needs_url & (
    is.na(results$verification_source_url) |
      results$verification_source_url == ""
  ))) {
    stop("Verified/probable record lacks a verification source.")
  }

  master_index <- match(master$entity_id, results$entity_id)
  result_columns <- expected_result_columns[-1L]
  master_final <- master
  for (column_name in result_columns) {
    master_final[[column_name]] <- results[[column_name]][master_index]
  }

  panel_index <- match(panel$entity_id, results$entity_id)
  if (anyNA(panel_index)) {
    stop("Not all annual panel rows map to a researched entity.")
  }
  panel_final <- panel
  for (column_name in result_columns) {
    panel_final[[column_name]] <- results[[column_name]][panel_index]
  }

  readr::write_csv(master_final, master_final_path, na = "")
  readr::write_csv(panel_final, panel_final_path, na = "")

  master_round_trip <- readr::read_csv(
    master_final_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )
  panel_round_trip <- readr::read_csv(
    panel_final_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )

  if (
    nrow(master_round_trip) != 341L ||
      nrow(panel_round_trip) != 800L ||
      any(table(panel_round_trip$index_year) != 200L)
  ) {
    stop("Final output row-count validation failed.")
  }
  for (column_name in original_columns) {
    if (!identical(panel_round_trip[[column_name]], panel[[column_name]])) {
      stop("Original Hurun panel field changed: ", column_name)
    }
  }

  cat("Consolidation complete.\n")
  cat("Master rows:", nrow(master_round_trip), "\n")
  cat("Annual panel rows:", nrow(panel_round_trip), "\n")
  cat("Master:", normalizePath(master_final_path, winslash = "/"), "\n")
  cat("Panel:", normalizePath(panel_final_path, winslash = "/"), "\n")
}
