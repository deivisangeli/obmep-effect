
ggplot(df, aes(ano, percentual, color = factor(nivel))) +
  geom_line(size = 1) +
  geom_point(size = 2) +
  scale_x_continuous(breaks = 2007:2016) +
  scale_color_brewer(palette = "Set1") +
  labs(
    x = "Ano",
    y = "Percentual de inscritos",
    color = "Nível"
  ) +
  theme_minimal()