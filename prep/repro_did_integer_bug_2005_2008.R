################################################################################

## REPRODUCAO do bug: event study restrito a 2005-2008 estima so e = 0 e e = 1
## (e = -2 e e = -1 saem NA)
##
## ATENCAO: este script NAO corrige o bug -- ele o reproduz de proposito.
##
## Contexto: escolas tratadas de forma escalonada entre 2005 e 2016, mas a
## analise e restrita a 2005-2008. No pipeline real, gname
## (ano_primeira_participacao_I, via min(ano)) e tname (NU_ANO) chegam ao att_gt
## como INTEGER. Internamente o did recodifica never-treated e coortes tratadas
## depois da janela para Inf; numa coluna integer isso vira NA (aviso de
## coercao) e apaga o grupo de comparacao. Sem controles, sobram so as coortes
## tratadas dentro de 2005-2008 (a de 2005 e descartada por nao ter base t-1),
## colapsando a dinamica para e = 0, 1 com pre-periodos NA.

################################################################################

rm(list = ls()); gc()

library(arrow)
library(tidyverse)
library(ggplot2)
library(did)

options(scipen = 999)
set.seed(20240713)

out_dir <- Sys.getenv(
  "MOCK_PANEL_OUTPUT_DIR",
  unset = file.path(
    Sys.getenv("OBMEP_ROOT", unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"),
    "test", "mock_panel_stem_employment"
  )
)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

years <- 2005:2016
est_years <- 2005:2008
n_schools <- 2000L

# Coortes escalonadas ao LONGO de 2005-2016 (como na aplicacao real) + never-
# treated (0). As coortes pos-2008 existem e DEVERIAM servir de controle na
# janela 2005-2008.
cohort_years <- c(0, 2005:2016)
cohort_probs <- c(0.30, rep(0.70 / 12, 12))

################################################################################

### Painel colapsado escola x ano (com efeito dinamico embutido)

################################################################################

schools <- tibble(
  CO_ENTIDADE = 11000000L + seq_len(n_schools),
  ano_primeira_participacao_I = sample(
    cohort_years, n_schools, replace = TRUE, prob = cohort_probs
  ),
  school_fe = rnorm(n_schools, 0, 3.0),
  students2005 = as.integer(round(pmax(20, rlnorm(n_schools, log(220), 0.5))))
) %>%
  mutate(students2005_z = as.numeric(scale(students2005)))

panel <- tidyr::crossing(
  CO_ENTIDADE = schools$CO_ENTIDADE,
  NU_ANO = years
) %>%
  left_join(schools, by = "CO_ENTIDADE") %>%
  mutate(
    treated = ano_primeira_participacao_I > 0,
    event_time = if_else(treated, NU_ANO - ano_primeira_participacao_I, NA_real_),
    att_dynamic = if_else(
      treated & event_time >= 0, 0.60 * pmin(event_time + 1, 6), 0
    ),
    pct_emprego_formal_stem = 12 + school_fe +
      0.30 * (NU_ANO - min(years)) +
      1.2 * students2005_z + att_dynamic + rnorm(n(), 0, 1.5),
    pct_emprego_formal_stem = pmin(100, pmax(0, pct_emprego_formal_stem))
  )

# ---- O BUG (mantido de proposito): gname e tname como INTEGER ----
# No pipeline real isso vem do cast em massa de merge_obmep_censo.R e do
# min(ano) sem as.numeric em aux_obmep_v2/v3.R.
panel <- panel %>%
  mutate(
    CO_ENTIDADE = as.integer(CO_ENTIDADE),
    NU_ANO = as.integer(NU_ANO),                                   # integer
    ano_primeira_participacao_I = as.integer(ano_primeira_participacao_I) # integer
  )

cat("Classe de gname:", class(panel$ano_primeira_participacao_I),
    "| classe de tname:", class(panel$NU_ANO), "\n")

################################################################################

### Restringe SO os anos a 2005-2008 (coortes pos-2008 permanecem no painel)

################################################################################

panel_est <- panel %>% filter(NU_ANO %in% est_years)
cat("Janela da estimacao (NU_ANO):",
    paste(range(panel_est$NU_ANO), collapse = "-"),
    "| obs:", nrow(panel_est), "\n")
cat("Coortes presentes na janela (unidades):\n")
print(panel_est %>% distinct(CO_ENTIDADE, ano_primeira_participacao_I) %>%
        count(ano_primeira_participacao_I))

################################################################################

### Estimador (mesmo do script 11) -- roda com o bug

################################################################################

att_results <- att_gt(
  yname = "pct_emprego_formal_stem",
  tname = "NU_ANO",
  idname = "CO_ENTIDADE",
  gname = "ano_primeira_participacao_I",
  xformla = ~students2005,
  data = panel_est,
  est_method = "dr",
  control_group = "notyettreated",
  base_period = "universal"
)

cat("\nGrupos (coortes) efetivamente estimados:\n")
print(sort(unique(att_results$group)))

agg_effects <- aggte(att_results, type = "dynamic", na.rm = TRUE)

es_table <- tibble(
  event_time = agg_effects$egt,
  att = agg_effects$att.egt,
  se = agg_effects$se.egt
)
cat("\nEvent study (o proprio erro): e = -2/-1 vem NA; so e = 0/1 estimados\n")
print(es_table)

write.csv(
  es_table,
  file.path(out_dir, "repro_bug_att_dynamic.csv"),
  row.names = FALSE
)

N <- length(unique(panel_est$CO_ENTIDADE))
ggdid(agg_effects) +
  ggplot2::labs(
    subtitle = "REPRODUCAO DO BUG: gname integer | tratadas 2005-2016 | janela 2005-2008"
  ) +
  ggplot2::annotate(
    "text",
    x = min(agg_effects$egt),
    y = max(agg_effects$att, na.rm = TRUE),
    label = paste0("N = ", N),
    hjust = 0
  )

ggsave(
  file.path(out_dir, "repro_bug_event_study_2005_2008.png"),
  width = 8, height = 6, dpi = 300
)

cat("\nSaidas salvas em:", normalizePath(out_dir, winslash = "/"), "\n")

################################################################################

###Versão corrigida: NU_ANO e ano_primeira_participacao_I como NUMERIC 

################################################################################

panel_est_fixed <- panel_est %>%
  mutate(
    NU_ANO = as.numeric(NU_ANO),
    ano_primeira_participacao_I = as.numeric(ano_primeira_participacao_I)
  )

### Versão corrigida: NU_ANO e ano_primeira_participacao_I como NUMERIC 

panel_est_fixed <- panel_est %>%
  mutate(
    NU_ANO = as.numeric(NU_ANO),
    ano_primeira_participacao_I = as.numeric(ano_primeira_participacao_I)
  )

### Rerodar event studies com gname e tname como NUMERIC (corrigido)

att_results_fixed <- att_gt(
  yname = "pct_emprego_formal_stem",
  tname = "NU_ANO",
  idname = "CO_ENTIDADE",
  gname = "ano_primeira_participacao_I",
  xformla = ~students2005,
  data = panel_est_fixed,
  est_method = "dr",
  control_group = "notyettreated",
  base_period = "universal"
)

cat("\nGrupos (coortes) efetivamente estimados (versão corrigida):\n")
print(sort(unique(att_results_fixed$group)))

agg_effects_fixed <- aggte(att_results_fixed, type = "dynamic", na.rm = TRUE)

es_table_fixed <- tibble(
  event_time = agg_effects_fixed$egt,
  att = agg_effects_fixed$att.egt,
  se = agg_effects_fixed$se.egt
)
cat("\nEvent study (versão corrigida): todos os e = -2, -1, 0, 1 estimados\n")
print(es_table_fixed)

write.csv(
  es_table_fixed,
  file.path(out_dir, "repro_bug_att_dynamic_fixed.csv"),
  row.names = FALSE
)

N_fixed <- length(unique(panel_est_fixed$CO_ENTIDADE))
ggdid(agg_effects_fixed) +
  ggplot2::labs(
    subtitle = "VERSÃO CORRIGIDA: gname numeric | tratadas 2005-2016 | janela 2005-2008"
  ) +
  ggplot2::annotate(
    "text",
    x = min(agg_effects_fixed$egt),
    y = max(agg_effects_fixed$att, na.rm = TRUE),
    label = paste0("N = ", N_fixed),
    hjust = 0
  )

ggsave(
  file.path(out_dir, "repro_bug_event_study_2005_2008_fixed.png"),
  width = 8, height = 6, dpi = 300
)

cat("\nSaidas corrigidas salvas em:", normalizePath(out_dir, winslash = "/"), "\n")