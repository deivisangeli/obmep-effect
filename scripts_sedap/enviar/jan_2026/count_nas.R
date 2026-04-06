percent_na_df <- data.frame(
  variavel = names(df),
  percentual_missing = sapply(df, function(x) mean(is.na(x)) * 100)
)

percent_na_df <- percent_na_df[order(-percent_na_df$percentual_missing), ]




percent_na_df <- df %>%
  summarise(across(everything(), ~ mean(is.na(.)) * 100)) %>%
  pivot_longer(cols = everything(),
               names_to = "variavel",
               values_to = "percentual_missing") %>%
  arrange(desc(percentual_missing))