################################################################################

## Painel mock 2005-2016 e event study de emprego formal STEM (OBMEP)
##
## Recria um painel colapsado escola x ano e aplica o mesmo estimador usado ao
## final de "11-reg_all_outcomes-new.R": DiD escalonado de Callaway & Sant'Anna
## (did::att_gt, est_method = "dr", control_group = "notyettreated",
## base_period = "universal"), agregado por tempo de evento (aggte "dynamic").
##
## Outcome: percentual de alunos da escola com emprego formal em areas STEM.
## O painel mock e simulado/salvo para 2005-2016, mas a estimacao do did e
## limitada aos anos 2005-2008 (est_years). Coortes de primeira participacao na
## OBMEP em 2005-2008. Como a janela comeca em 2005, a coorte 2005 nao tem
## periodo-base t-1 (2004) e e descartada pelo att_gt; os efeitos ficam
## estimaveis para as coortes 2006-2008. Pela janela curta, os tempos de evento
## vao de aproximadamente e = -3 a +2.

################################################################################

rm(list = ls()); gc()

required_packages <- c("arrow", "tidyverse", "ggplot2", "did")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
if (length(missing_packages) > 0) {
  stop(
    "Pacotes ausentes: ",
    paste(missing_packages, collapse = ", "),
    ". Instale-os antes de rodar este script."
  )
}

library(arrow)
library(tidyverse)
library(ggplot2)
library(did)

# OPTIONS
options(scipen = 999)
set.seed(20240713)

################################################################################

### Parametros

################################################################################

obmep_root <- Sys.getenv(
  "OBMEP_ROOT",
  unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP"
)

out_dir <- Sys.getenv(
  "MOCK_PANEL_OUTPUT_DIR",
  unset = file.path(obmep_root, "test", "mock_panel_stem_employment")
)
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

years <- 2005:2016
# Janela usada na estimacao do did (subconjunto do painel). O painel completo
# 2005-2016 e simulado e salvo; o att_gt considera apenas estes anos.
est_years <- 2005:2008
n_schools <- 1500L

# Coortes de tratamento (ano da primeira participacao na OBMEP) e proporcoes.
# 0 = never-treated (grupo de controle). Foco: 2005-2008.
cohort_years <- c(0, 2005, 2006, 2007, 2008)
cohort_probs <- c(0.40, 0.15, 0.15, 0.15, 0.15)

# Parametros do processo gerador do outcome (percentual, 0-100).
base_level     <- 12       # nivel medio do % de emprego formal STEM
sd_school      <- 3.0      # dispersao do efeito fixo de escola
year_trend     <- 0.30     # tendencia comum por ano (p.p./ano)
coef_baseline  <- 1.2      # efeito da matricula de baseline (padronizada)
att_per_year   <- 0.60     # efeito verdadeiro por ano desde a entrada (p.p.)
att_cap_years  <- 6L       # teto do tempo de evento para o crescimento do efeito
sd_noise       <- 1.5      # ruido idiossincratico escola x ano

################################################################################

### Simulacao do painel colapsado escola x ano

################################################################################

# Atributos invariantes no tempo por escola.
schools <- tibble(
  CO_ENTIDADE = 11000000L + seq_len(n_schools),
  ano_primeira_participacao_I = sample(
    cohort_years, n_schools, replace = TRUE, prob = cohort_probs
  ),
  school_fe = rnorm(n_schools, 0, sd_school),
  students2005 = as.integer(round(pmax(20, rlnorm(n_schools, log(220), 0.5))))
)

# Covariavel de baseline padronizada (entra no xformla).
schools <- schools %>%
  mutate(students2005_z = as.numeric(scale(students2005)))

# Grade balanceada escola x ano e construcao do outcome.
panel <- tidyr::crossing(
  CO_ENTIDADE = schools$CO_ENTIDADE,
  NU_ANO = years
) %>%
  left_join(schools, by = "CO_ENTIDADE") %>%
  mutate(
    treated = ano_primeira_participacao_I > 0,
    event_time = if_else(treated, NU_ANO - ano_primeira_participacao_I, NA_real_),
    # ATT dinamico verdadeiro: 0 no pre-tratamento; crescente no pos (com teto).
    att_dynamic = if_else(
      treated & event_time >= 0,
      att_per_year * pmin(event_time + 1, att_cap_years),
      0
    ),
    pct_emprego_formal_stem = base_level +
      school_fe +
      year_trend * (NU_ANO - min(years)) +
      coef_baseline * students2005_z +
      att_dynamic +
      rnorm(n(), 0, sd_noise),
    # Outcome e um percentual: truncar em [0, 100].
    pct_emprego_formal_stem = pmin(100, pmax(0, pct_emprego_formal_stem))
  ) %>%
  select(
    CO_ENTIDADE, NU_ANO, ano_primeira_participacao_I,
    students2005, pct_emprego_formal_stem
  ) %>%
  arrange(CO_ENTIDADE, NU_ANO)

# did::att_gt exige idname/tname/gname numericos. gname e tname devem ser
# double (nao integer): internamente o did atribui Inf as unidades never-treated
# (gname == 0), o que viraria NA numa coluna integer e descartaria os controles.
panel <- panel %>%
  mutate(
    CO_ENTIDADE = as.integer(CO_ENTIDADE),
    NU_ANO = as.numeric(NU_ANO),
    ano_primeira_participacao_I = as.numeric(ano_primeira_participacao_I)
  )

cat("Escolas:", length(unique(panel$CO_ENTIDADE)), "\n")
cat("Observacoes escola x ano:", nrow(panel), "\n")
cat("Distribuicao das coortes (0 = never-treated):\n")
print(table(schools$ano_primeira_participacao_I))

write_parquet(
  panel,
  file.path(out_dir, "panel_stem_employment_2005_2016.parquet")
)

################################################################################

### Estimador (identico ao final de 11-reg_all_outcomes-new.R)

################################################################################

# Limita a estimacao aos anos 2005-2008 (o painel salvo continua 2005-2016).
panel_est <- panel %>% filter(NU_ANO %in% est_years)
cat("\nJanela da estimacao (NU_ANO):",
    paste(range(panel_est$NU_ANO), collapse = "-"),
    "| obs:", nrow(panel_est), "\n")

att_results <- att_gt(
  yname = "pct_emprego_formal_stem", # variavel dependente
  tname = "NU_ANO",                  # tempo
  idname = "CO_ENTIDADE",            # unidade
  gname = "ano_primeira_participacao_I", # ano em que a unidade foi tratada
  xformla = ~students2005,
  data = panel_est,                  # painel filtrado para 2005-2008
  est_method = "dr",                 # ou "ipw", "reg"
  control_group = "notyettreated",   # ou nevertreated
  base_period = "universal"          # ano de ref t-1
)

# Agregacao por tempo de evento (event study).
agg_effects <- aggte(att_results, type = "dynamic", na.rm = TRUE)

# ATT global (efeito medio do tratamento sobre os tratados).
agg_simple <- aggte(att_results, type = "simple", na.rm = TRUE)
cat("\nATT global (simple):", round(agg_simple$overall.att, 3),
    "(SE", round(agg_simple$overall.se, 3), ")\n")

# Numero de unidades (escolas) usadas na estimacao.
N <- length(unique(panel_est$CO_ENTIDADE))

ggdid(agg_effects) +
  ggplot2::annotate(
    "text",
    x = min(agg_effects$egt),
    y = max(agg_effects$att),
    label = paste0("N = ", N),
    hjust = 0
  )

ggsave(
  file.path(out_dir, "es_pct_emprego_formal_stem_dynamic_2005_2008.pdf"),
  width = 8, height = 6, dpi = 300
)
ggsave(
  file.path(out_dir, "es_pct_emprego_formal_stem_dynamic_2005_2008.png"),
  width = 8, height = 6, dpi = 300
)

# Estimativas por tempo de evento (para validacao).
es_table <- tibble(
  event_time = agg_effects$egt,
  att = agg_effects$att.egt,
  se = agg_effects$se.egt
)
write.csv(
  es_table,
  file.path(out_dir, "att_dynamic_estimates_2005_2008.csv"),
  row.names = FALSE
)

cat("\nEstimativas por tempo de evento:\n")
print(es_table)

cat("\nSaidas salvas em:", normalizePath(out_dir, winslash = "/"), "\n")

################################################################################
