####################################################################
### CAPES -> OpenAlex: pesquisa manual dos nomes sem fuzzy match
###
### Workflow local com pesquisa ONLINE feita por agentes. O script em
### si prepara os lotes e consolida arquivos locais; os agentes usam a
### web entre essas duas etapas. Nao deve ser enviado ao SEDAP.
###
### Uso:
###   Rscript prep/building_external_data/capes_openalex_manual_crosswalk.R prepare
###   Rscript prep/building_external_data/capes_openalex_manual_crosswalk.R status
###   Rscript prep/building_external_data/capes_openalex_manual_crosswalk.R consolidate
####################################################################

for (p in c("readr", "arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}

args <- commandArgs(trailingOnly = TRUE)
mode <- if (length(args)) tolower(args[[1]]) else "status"
if (!mode %in% c("prepare", "status", "consolidate")) {
  stop("Modo deve ser prepare, status ou consolidate.")
}

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)

capes_dir <- file.path(obmep_root, "Data/intermediate/capes_discentes")
unmatched_path <- file.path(
  capes_dir,
  "capes_openalex_br_crosswalk_unmatched.csv"
)
oa_path <- file.path(
  obmep_root,
  "Data/intermediate/openalex_institutions/openalex_institutions_br.parquet"
)

manual_dir <- file.path(capes_dir, "capes_openalex_manual")
inputs_dir <- file.path(manual_dir, "inputs")
results_dirs <- file.path(manual_dir, paste0("results_", c("a", "b", "c")))
master_path <- file.path(manual_dir, "manual_master_input.csv")
manifest_path <- file.path(manual_dir, "batch_manifest.csv")
protocol_path <- file.path(manual_dir, "research_protocol.md")

research_path <- file.path(manual_dir, "capes_openalex_manual_research.csv")
crosswalk_path <- file.path(manual_dir, "capes_openalex_manual_br_crosswalk.parquet")
exceptions_path <- file.path(manual_dir, "capes_openalex_manual_exceptions.csv")

exp_unmatched_file_rows <- 480L
exp_names <- 477L
exp_source_rows <- 124627L
batch_size <- 10L
exp_batches <- 48L

expected_result_columns <- c(
  "record_id", "capes_institution", "match_status", "relationship",
  "openalex_id", "openalex_display_name_web", "openalex_url",
  "alternative_openalex_ids", "verification_source_url", "research_notes"
)
allowed_statuses <- c("verified", "ambiguous", "not_found")
allowed_relationships <- c("same_entity", "parent_fallback", "renamed_successor")

stopifnot(file.exists(unmatched_path), file.exists(oa_path))

####################################################################
### PREPARE: universo, lotes de 10 e manifesto A/B/C
####################################################################

if (mode == "prepare") {
  dir.create(inputs_dir, recursive = TRUE, showWarnings = FALSE)
  for (result_dir in results_dirs) {
    dir.create(result_dir, recursive = TRUE, showWarnings = FALSE)
  }

  existing_results <- unlist(lapply(
    results_dirs,
    list.files,
    pattern = "_openalex[.]csv$",
    full.names = TRUE
  ))
  if (length(existing_results)) {
    stop(
      "Ja existem resultados manuais. PREPARE nao sobrescreve pesquisa: ",
      paste(existing_results, collapse = ", ")
    )
  }

  all_character <- readr::cols(.default = readr::col_character())
  unmatched <- readr::read_csv(
    unmatched_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )
  if (nrow(unmatched) != exp_unmatched_file_rows) {
    stop("Arquivo fuzzy sem match mudou: ", nrow(unmatched), " linhas.")
  }

  master <- unique(unmatched[c(
    "capes_institution", "capes_name_clean", "capes_row_count"
  )])
  master$capes_row_count <- as.integer(master$capes_row_count)
  master <- master[order(master$capes_name_clean, master$capes_institution), ]
  rownames(master) <- NULL
  master$record_id <- sprintf("COA%04d", seq_len(nrow(master)))
  master <- master[c(
    "record_id", "capes_institution", "capes_name_clean", "capes_row_count"
  )]

  stopifnot(
    nrow(master) == exp_names,
    !anyDuplicated(master$record_id),
    !anyDuplicated(master$capes_institution),
    sum(master$capes_row_count) == exp_source_rows,
    !anyNA(master)
  )

  n_batches <- ceiling(nrow(master) / batch_size)
  stopifnot(n_batches == exp_batches)
  agents <- c("a", "b", "c")
  manifest <- data.frame(
    batch_id = sprintf("%03d", seq_len(n_batches)),
    agent = agents[((seq_len(n_batches) - 1L) %% length(agents)) + 1L],
    start_row = seq(1L, by = batch_size, length.out = n_batches),
    end_row = pmin(
      seq(batch_size, by = batch_size, length.out = n_batches),
      nrow(master)
    ),
    n_records = NA_integer_,
    input_path = NA_character_,
    result_path = NA_character_,
    stringsAsFactors = FALSE
  )

  for (i in seq_len(nrow(manifest))) {
    rows <- manifest$start_row[[i]]:manifest$end_row[[i]]
    batch_id <- manifest$batch_id[[i]]
    agent <- manifest$agent[[i]]
    input_path <- file.path(inputs_dir, paste0("batch_", batch_id, ".csv"))
    result_path <- file.path(
      manual_dir,
      paste0("results_", agent),
      paste0("batch_", batch_id, "_openalex.csv")
    )
    readr::write_csv(master[rows, ], input_path, na = "")
    manifest$n_records[[i]] <- length(rows)
    manifest$input_path[[i]] <- normalizePath(
      input_path,
      winslash = "/",
      mustWork = TRUE
    )
    manifest$result_path[[i]] <- normalizePath(
      result_path,
      winslash = "/",
      mustWork = FALSE
    )
  }

  readr::write_csv(master, master_path, na = "")
  readr::write_csv(manifest, manifest_path, na = "")

  writeLines(c(
    "# CAPES → OpenAlex manual research protocol",
    "",
    "Research every input row separately. Search OpenAlex and the general web;",
    "verify identity on the OpenAlex entity/API page and an official institution",
    "or ROR page. Prefer the exact entity. If no unit/campus entity exists, use",
    "the degree-awarding parent only with authoritative evidence.",
    "",
    "Allowed match_status: verified, ambiguous, not_found.",
    "Allowed verified relationship: same_entity, parent_fallback, renamed_successor.",
    "Verified rows require one I-number, https://openalex.org/I..., a display name,",
    "verification URL, and notes. Ambiguous rows leave the primary fields blank and",
    "put at least two semicolon-separated I-numbers in alternative_openalex_ids.",
    "Not-found rows leave all ID fields blank and document the searches attempted.",
    "Do not accept the old fuzzy suggestion without independent web verification.",
    "",
    paste(expected_result_columns, collapse = ",")
  ), protocol_path, useBytes = TRUE)

  master_roundtrip <- readr::read_csv(
    master_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )
  manifest_roundtrip <- readr::read_csv(
    manifest_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )
  stopifnot(
    nrow(master_roundtrip) == exp_names,
    nrow(manifest_roundtrip) == exp_batches,
    sum(as.integer(manifest_roundtrip$n_records)) == exp_names,
    all(file.exists(manifest_roundtrip$input_path)),
    table(manifest_roundtrip$agent)[["a"]] == 16L,
    table(manifest_roundtrip$agent)[["b"]] == 16L,
    table(manifest_roundtrip$agent)[["c"]] == 16L
  )

  cat("Preparacao concluida.\n")
  cat("Nomes CAPES:", nrow(master), "\n")
  cat("Lotes:", nrow(manifest), "(47 x 10; 1 x 7)\n")
  cat("Agentes: A=160, B=160, C=157 nomes\n")
  cat("Manifesto:", manifest_path, "\n")
  quit(save = "no", status = 0L)
}

####################################################################
### STATUS / CONSOLIDATE: validar cada arquivo de resultado
####################################################################

if (!file.exists(master_path) || !file.exists(manifest_path)) {
  stop("Arquivos de preparacao ausentes. Rode prepare primeiro.")
}

all_character <- readr::cols(.default = readr::col_character())
master <- readr::read_csv(
  master_path,
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
oa_status <- as.data.frame(arrow::read_parquet(oa_path))

stopifnot(
  nrow(master) == exp_names,
  nrow(manifest) == exp_batches,
  !anyDuplicated(master$record_id),
  !anyDuplicated(master$capes_institution),
  nrow(oa_status) == 1947L,
  !anyDuplicated(oa_status$openalex_id)
)

result_parts <- vector("list", nrow(manifest))
missing_batches <- character()
complete_records <- 0L

for (i in seq_len(nrow(manifest))) {
  result_path <- manifest$result_path[[i]]
  if (!file.exists(result_path)) {
    missing_batches <- c(missing_batches, manifest$batch_id[[i]])
    next
  }

  result <- readr::read_csv(
    result_path,
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )
  if (!identical(names(result), expected_result_columns)) {
    stop("Schema de resultado inesperado: ", result_path)
  }

  input <- readr::read_csv(
    manifest$input_path[[i]],
    col_types = all_character,
    progress = FALSE,
    name_repair = "minimal",
    na = "",
    trim_ws = FALSE
  )
  if (
    nrow(result) != as.integer(manifest$n_records[[i]]) ||
      anyDuplicated(result$record_id) ||
      !identical(result$record_id, input$record_id) ||
      !identical(result$capes_institution, input$capes_institution)
  ) {
    stop("Linhas/chaves nao batem com o lote ", manifest$batch_id[[i]], ".")
  }

  result$match_status <- tolower(trimws(result$match_status))
  result$relationship <- tolower(trimws(result$relationship))
  if (any(is.na(result$match_status) | !result$match_status %in% allowed_statuses)) {
    stop("Status invalido no lote ", manifest$batch_id[[i]], ".")
  }
  if (any(is.na(result$research_notes) | !nzchar(trimws(result$research_notes)))) {
    stop("Toda linha precisa de research_notes: lote ", manifest$batch_id[[i]], ".")
  }

  for (j in seq_len(nrow(result))) {
    verified <- result$match_status[[j]] == "verified"
    ambiguous <- result$match_status[[j]] == "ambiguous"
    not_found <- result$match_status[[j]] == "not_found"

    primary_fields <- c(
      result$openalex_id[[j]],
      result$openalex_display_name_web[[j]],
      result$openalex_url[[j]]
    )
    primary_present <- !is.na(primary_fields) & nzchar(trimws(primary_fields))

    if (verified) {
      if (
        is.na(result$relationship[[j]]) ||
          !result$relationship[[j]] %in% allowed_relationships ||
          !all(primary_present) ||
          !grepl("^I[0-9]+$", result$openalex_id[[j]]) ||
          result$openalex_url[[j]] != paste0(
            "https://openalex.org/", result$openalex_id[[j]]
          ) ||
          is.na(result$verification_source_url[[j]]) ||
          !grepl("^https?://", result$verification_source_url[[j]])
      ) {
        stop("Resultado verified invalido: ", result$record_id[[j]], ".")
      }
      if (!is.na(result$alternative_openalex_ids[[j]]) &&
          nzchar(trimws(result$alternative_openalex_ids[[j]]))) {
        stop("Verified nao pode ter IDs alternativos: ", result$record_id[[j]], ".")
      }

      local_index <- match(result$openalex_id[[j]], oa_status$openalex_id)
      cited_ror <- grepl(
        "^https://ror[.]org/",
        result$verification_source_url[[j]]
      )
      if (!is.na(local_index) && cited_ror &&
          result$verification_source_url[[j]] != oa_status$ror[[local_index]]) {
        stop(
          "ID e ROR citado divergem no snapshot local: ",
          result$record_id[[j]], " -> ", result$openalex_id[[j]], " / ",
          result$verification_source_url[[j]], "."
        )
      }
    }

    if (ambiguous) {
      if (any(primary_present) ||
          (!is.na(result$relationship[[j]]) &&
           nzchar(trimws(result$relationship[[j]]))) ||
          is.na(result$alternative_openalex_ids[[j]])) {
        stop("Resultado ambiguous invalido: ", result$record_id[[j]], ".")
      }
      alt <- trimws(strsplit(
        result$alternative_openalex_ids[[j]],
        ";",
        fixed = TRUE
      )[[1]])
      if (length(unique(alt)) < 2L || any(!grepl("^I[0-9]+$", alt))) {
        stop("IDs alternativos invalidos: ", result$record_id[[j]], ".")
      }
    }

    if (not_found) {
      other_fields <- c(primary_fields, result$alternative_openalex_ids[[j]])
      if (any(!is.na(other_fields) & nzchar(trimws(other_fields))) ||
          (!is.na(result$relationship[[j]]) &&
           nzchar(trimws(result$relationship[[j]])))) {
        stop("Resultado not_found contem ID/relacao: ", result$record_id[[j]], ".")
      }
    }
  }

  result$batch_id <- manifest$batch_id[[i]]
  result$agent <- manifest$agent[[i]]
  result_parts[[i]] <- result
  complete_records <- complete_records + nrow(result)
}

cat("Lotes completos:", nrow(manifest) - length(missing_batches), "de",
    nrow(manifest), "\n")
cat("Registros completos:", complete_records, "de", nrow(master), "\n")
if (length(missing_batches)) {
  cat("Lotes ausentes:", paste(missing_batches, collapse = ", "), "\n")
}

if (mode == "status") {
  quit(save = "no", status = 0L)
}
if (length(missing_batches)) {
  stop("Consolidacao exige os 48 lotes completos.")
}

####################################################################
### CONSOLIDATE: uma linha por nome e join estrito por openalex_id
####################################################################

results <- do.call(rbind, result_parts)
rownames(results) <- NULL
results <- results[match(master$record_id, results$record_id), ]
stopifnot(
  nrow(results) == exp_names,
  !anyNA(match(master$record_id, results$record_id)),
  !anyDuplicated(results$record_id),
  identical(results$capes_institution, master$capes_institution)
)

verified_rows <- results$match_status == "verified"
clean_name <- master$capes_name_clean
for (name in unique(clean_name[verified_rows])) {
  ids <- unique(results$openalex_id[verified_rows & clean_name == name])
  if (length(ids) > 1L) {
    stop(
      "Variantes do mesmo nome normalizado receberam IDs diferentes: ",
      name, " -> ", paste(ids, collapse = ", ")
    )
  }
}

oa <- oa_status
expected_oa_columns <- c(
  "openalex_id", "openalex_url", "display_name", "cleaned_display_name",
  "ror", "type", "works_count", "city", "region", "country_source",
  "snapshot_date"
)
stopifnot(
  identical(names(oa), expected_oa_columns),
  nrow(oa) == 1947L,
  !anyDuplicated(oa$openalex_id)
)

oa_index <- match(results$openalex_id, oa$openalex_id)
in_br_snapshot <- verified_rows & !is.na(oa_index)

final <- data.frame(
  record_id = master$record_id,
  batch_id = results$batch_id,
  agent = results$agent,
  capes_institution = master$capes_institution,
  capes_name_clean = master$capes_name_clean,
  capes_row_count = as.integer(master$capes_row_count),
  match_status = results$match_status,
  relationship = results$relationship,
  openalex_id = results$openalex_id,
  openalex_display_name_web = results$openalex_display_name_web,
  openalex_url = results$openalex_url,
  alternative_openalex_ids = results$alternative_openalex_ids,
  verification_source_url = results$verification_source_url,
  research_notes = results$research_notes,
  in_br_snapshot = in_br_snapshot,
  oa_display_name = oa$display_name[oa_index],
  oa_cleaned_display_name = oa$cleaned_display_name[oa_index],
  oa_ror = oa$ror[oa_index],
  oa_type = oa$type[oa_index],
  oa_works_count = oa$works_count[oa_index],
  oa_city = oa$city[oa_index],
  oa_region = oa$region[oa_index],
  oa_country_source = oa$country_source[oa_index],
  oa_snapshot_date = oa$snapshot_date[oa_index],
  stringsAsFactors = FALSE
)

research <- final[c(
  "record_id", "batch_id", "agent", "capes_institution", "capes_name_clean",
  "capes_row_count", "match_status", "relationship", "openalex_id",
  "openalex_display_name_web", "openalex_url", "alternative_openalex_ids",
  "verification_source_url", "research_notes"
)]
exceptions <- final[
  final$match_status != "verified" | !final$in_br_snapshot,
  ,
  drop = FALSE
]

research_part <- paste0(research_path, ".part")
crosswalk_part <- paste0(crosswalk_path, ".part")
exceptions_part <- paste0(exceptions_path, ".part")
for (part in c(research_part, crosswalk_part, exceptions_part)) {
  if (file.exists(part)) unlink(part)
}

readr::write_csv(research, research_part, na = "")
arrow::write_parquet(final, crosswalk_part, compression = "zstd")
readr::write_csv(exceptions, exceptions_part, na = "")

research_check <- readr::read_csv(
  research_part,
  col_types = all_character,
  progress = FALSE,
  name_repair = "minimal",
  na = "",
  trim_ws = FALSE
)
crosswalk_check <- as.data.frame(arrow::read_parquet(crosswalk_part))
exceptions_check <- readr::read_csv(
  exceptions_part,
  col_types = all_character,
  progress = FALSE,
  name_repair = "minimal",
  na = "",
  trim_ws = FALSE
)

personal_columns <- c("person_id", "full_name", "birth_year")
stopifnot(
  nrow(research_check) == exp_names,
  nrow(crosswalk_check) == exp_names,
  nrow(exceptions_check) == nrow(exceptions),
  !anyDuplicated(research_check$record_id),
  !anyDuplicated(crosswalk_check$record_id),
  !any(names(crosswalk_check) %in% personal_columns),
  all(crosswalk_check$in_br_snapshot == in_br_snapshot)
)

for (path in c(research_path, crosswalk_path, exceptions_path)) {
  if (file.exists(path)) unlink(path)
}
if (!file.rename(research_part, research_path)) stop("Falha ao promover pesquisa.")
if (!file.rename(exceptions_part, exceptions_path)) stop("Falha ao promover excecoes.")
if (!file.rename(crosswalk_part, crosswalk_path)) stop("Falha ao promover parquet.")

cat("\nConsolidacao concluida.\n")
print(table(final$match_status, useNA = "ifany"))
cat("Verified no snapshot BR:", sum(final$in_br_snapshot), "\n")
cat("Verified fora do snapshot BR:", sum(verified_rows & !final$in_br_snapshot), "\n")
cat("Excecoes:", nrow(exceptions), "\n")
cat("Pesquisa:", research_path, "\n")
cat("Crosswalk:", crosswalk_path, "\n")
cat("Excecoes:", exceptions_path, "\n")
