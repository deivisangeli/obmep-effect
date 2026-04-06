

library(tidyverse)
library(ggplot2)
library(did)



# OPTIONS
options(scipen = 999)



att_results <- att_gt(
  yname = "stem",               # variável dependente
  tname = "ano",            # tempo
  idname = "id",             # unidade
  gname = "treat_t",               # ano em que a unidade foi tratada
  xformla = ~ controle1 + controle2,
  data = df,
  est_method = "dr",         # ou "ipw", "reg"
  control_group = "notyettreated",   # ou nevertreated
  base_period = "universal"   # ano de ref t-1
)

# Gera o gráfico
agg_effects <- aggte(att_results, type = "dynamic", na.rm = T)  # ou "simple", "dynamic"

N <- nrow(df)   # ou número de unidades

ggdid(agg_effects) +
  ggplot2::annotate(
    "text",
    x = min(agg_effects$egt),
    y = max(agg_effects$att),
    label = paste0("N = ", N),
    hjust = 0
  )



ggsave("exemplo.png", width = 8, height = 6, dpi = 300)




