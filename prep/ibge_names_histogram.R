library(arrow)
library(data.table)
library(ggplot2)

input_path <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/raw/ibge_names/name_ranking.parquet"
output_path <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/intermediate/ibge_names/name_frequency_distribution.png"

dt_ranking <- as.data.table(read_parquet(input_path))

stopifnot(
  all(c("name_type", "frequency") %in% names(dt_ranking)),
  all(dt_ranking$frequency > 0, na.rm = TRUE),
  !anyNA(dt_ranking[, .(name_type, frequency)])
)

dt_ranking[, name_type_label := factor(
  name_type,
  levels = c("given", "surname"),
  labels = c("Given names", "Surnames")
)]

frequency_histogram <- ggplot(
  dt_ranking,
  aes(x = frequency, fill = name_type_label)
) +
  geom_histogram(bins = 60, color = "white", linewidth = 0.15) +
  facet_wrap(vars(name_type_label), ncol = 1) +
  scale_x_log10(
    breaks = c(20, 100, 1000, 10000, 100000, 1000000, 10000000),
    labels = scales::label_number(big.mark = ",")
  ) +
  scale_fill_manual(values = c("Given names" = "#2878B5", "Surnames" = "#D97706")) +
  labs(
    title = "Distribution of name frequency in the IBGE ranking",
    subtitle = "The frequency axis uses a logarithmic scale",
    x = "Frequency (log scale)",
    y = "Number of names"
  ) +
  theme_minimal(base_size = 12) +
  theme(
    legend.position = "none",
    panel.grid.minor = element_blank(),
    strip.text = element_text(face = "bold"),
    plot.title.position = "plot"
  )

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
ggsave(output_path, frequency_histogram, width = 11, height = 7, dpi = 180)

print(dt_ranking[, .(
  names = .N,
  minimum_frequency = min(frequency),
  median_frequency = median(frequency),
  maximum_frequency = max(frequency)
), by = name_type])
