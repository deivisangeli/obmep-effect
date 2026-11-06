###################################################

###Assess name ranking

###################################################


rm(list = ls()); gc()
library(arrow)
library(data.table)

input_path <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/raw/ibge_names/name_ranking.parquet"
output_given_path <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/intermediate/ibge_names/top_percent_given_names.parquet"
output_surname_path <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/intermediate/ibge_names/top_percent_surnames.parquet"
output_final_given_without_variants_path <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/intermediate/ibge_names/final_given_names_without_variants.parquet"
output_final_surname_without_variants_path <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/intermediate/ibge_names/final_surnames_without_variants.parquet"
output_final_given_path <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/intermediate/ibge_names/final_given_names_with_variants.parquet"
output_final_surname_path <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/intermediate/ibge_names/final_surnames_with_variants.parquet"
percentile_cutoff <- 0.9

dt_ranking <- as.data.table(read_parquet(input_path))

# Rank 1 is the most frequent name. Calculate cumulative measures separately for
# given names and surnames because rank restarts within each name type.
setorder(dt_ranking, name_type, rank, name_text)

dt_ranking[, `:=`(
  cumulative_frequency = cumsum(frequency),
  cumulative_frequency_share = cumsum(frequency) / sum(frequency)
), by = name_type]

# Calculate the frequency cutoff separately for given names and surnames.
dt_ranking[, frequency_cutoff := quantile(
  frequency,
  probs = percentile_cutoff,
  na.rm = TRUE
), by = name_type]

dt_ranking[, top_percent := frequency >= frequency_cutoff]

dt_top_percent_names <- dt_ranking[
  top_percent == TRUE,
  .(
    name_text,
    name_type,
    frequency,
    percentage,
    rank,
    frequency_cutoff,
    cumulative_frequency,
    cumulative_frequency_share
  )
]

dt_top_percent_given_names <- dt_top_percent_names[
  name_type == "given"
]

dt_top_percent_surnames <- dt_top_percent_names[
  name_type == "surname"
]

# Explicit final versions containing only the cutoff-selected canonical names.
dt_final_given_names_without_variants <- copy(dt_top_percent_given_names)
dt_final_surnames_without_variants <- copy(dt_top_percent_surnames)

selection_summary <- dt_ranking[, .(
  total_names = .N,
  selected_names = sum(top_percent),
  selected_share_of_names = mean(top_percent),
  percentile_cutoff = percentile_cutoff,
  frequency_cutoff = first(frequency_cutoff)
), by = name_type]

dir.create(dirname(output_given_path), recursive = TRUE, showWarnings = FALSE)
write_parquet(dt_top_percent_given_names, output_given_path)
write_parquet(dt_top_percent_surnames, output_surname_path)
write_parquet(
  dt_final_given_names_without_variants,
  output_final_given_without_variants_path
)
write_parquet(
  dt_final_surnames_without_variants,
  output_final_surname_without_variants_path
)

print(selection_summary)



###################################################

###Assess name variant

###################################################

dt_variants <- as.data.table(read_parquet(
  "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/raw/ibge_names/name_variant.parquet"
))

dt_variants <- dt_variants[, .(
  name_text,
  name_type,
  variant_text,
  variant_frequency = frequency,
  variant_percentage = percentage
)]

# Keep every cutoff-selected canonical name and expand it to every variant
# available in the source data.
dt_final_given_names_with_variants <- merge(
  dt_top_percent_given_names,
  dt_variants[name_type == "given"],
  by = c("name_text", "name_type"),
  all.x = TRUE,
  sort = FALSE,
  allow.cartesian = TRUE
)

dt_final_surnames_with_variants <- merge(
  dt_top_percent_surnames,
  dt_variants[name_type == "surname"],
  by = c("name_text", "name_type"),
  all.x = TRUE,
  sort = FALSE,
  allow.cartesian = TRUE
)

dt_final_given_names_with_variants[, has_variant := !is.na(variant_text)]
dt_final_surnames_with_variants[, has_variant := !is.na(variant_text)]

write_parquet(dt_final_given_names_with_variants, output_final_given_path)
write_parquet(dt_final_surnames_with_variants, output_final_surname_path)

variant_summary <- rbind(
  dt_final_given_names_with_variants[, .(
    name_type = "given",
    output_rows = .N,
    selected_names = uniqueN(name_text),
    names_with_variants = uniqueN(name_text[has_variant]),
    variant_rows = sum(has_variant)
  )],
  dt_final_surnames_with_variants[, .(
    name_type = "surname",
    output_rows = .N,
    selected_names = uniqueN(name_text),
    names_with_variants = uniqueN(name_text[has_variant]),
    variant_rows = sum(has_variant)
  )]
)

print(variant_summary)
