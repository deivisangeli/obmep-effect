# SEDAP: execucao offline; apenas arquivos locais e pacotes ja instalados.
# Edite as selecoes e o bloco do nivel desejado. Execute o arquivo *_run.R.

# SELECOES COMUNS -------------------------------------------------------------
data_root <- "T:"
results_root <- file.path(data_root, "results")

run_settings <- list(
  selected_levels = c("I", "II", "III"),
  samples = c("b", "a"),          # b: balanceada; a: todas as escolas
  cohorts = c("f", "e"),          # f: mantem 2005-2006; e: exclui esses anos
  treatments = c("APROV", "PRES"), # ou apenas "APROV" / "PRES"
  selected_groups = c("ingresso", "conclusao", "migracao", "rais", "rais_alt", "placebo")
)
# Exemplo: somente balanceada, sem excluir 2005-2006:
# use samples = "b" e cohorts = "f" acima. As janelas de cada outcome continuam valendo.

# Cada nivel e independente: editar os nomes abaixo nao altera os demais niveis.
# treatment_years: PRIMEIRO TRATAMENTO, limites inclusivos; nunca tratados continuam fora.
# anticipations: anos de antecipacao; cada valor gera uma especificacao, por exemplo c(1, 3).
# As tabelas combinam as especificacoes na coluna anticipation; graficos/checkpoints ficam separados.
# upper_year_offset: soma apenas ao limite superior FINITO das janelas de outcomes.
# selected_outcomes = NULL: todos os nomes listados; ou c("outcome_1", "outcome_2").
# outcomes: nomes EXATOS das colunas no painel; b e a sao listas separadas.
# Para omitir um grupo em uma amostra, use character(0) no lugar de c(...).

# NIVEL I =====================================================================
nivel_I <- list(
  anticipations = c(1, 3),
  paths = list(
    balanced_schools = file.path(data_root, "8. Intermediário/matricula_escola",
                                 "positive_enroll_nivel_I_2005-2016_from1.csv"),
    treatment = file.path(data_root, "9. Processado/aux_treat_obmep_v2.RData"),
    panel = file.path(data_root, "9. Processado/painel_collapsed.parquet"),
    plots = file.path(results_root, "second_phase/nivel_1"),
    tables = file.path(results_root, "second_phase/tables/nivel_1"),
    checkpoints = file.path(results_root, "second_phase/checkpoints/nivel_1")
  ),
  treatment_years = c(2005, 2017),
  treatments = c(
    APROV = "ano_primeira_participacao_2A_APROV_I",
    PRES = "ano_primeira_participacao_2A_PRES_I"
  ),
  upper_year_offset = 0,
  selected_outcomes = NULL,
  outcomes = list(
    ingresso = list(
      b = c(
        "mean_ingressante_STEM",
        "count_ingressante_STEM",
        "mean_ingressante_hard_sci",
        "count_ingressante_hard_sci",
        "mean_ingressante_humanities",
        "count_ingressante_humanities",
        "mean_ingressante_any",
        "count_ingressante_any",
        "mean_INGRESSANTE_top10pct_avg20",
        "count_INGRESSANTE_top10pct_avg20",
        "mean_INGRESSANTE_top10pct_avg20_STEM",
        "count_INGRESSANTE_top10pct_avg20_STEM",
        "mean_particip_enem",
        "count_particip_enem",
        "mean_nota_stem",
        "mean_part_any",
        "count_part_any",
        "mean_part_e_0_1",
        "count_part_enem_e_0_1"
      ),
      a = c(
        "count_ingressante_STEM",
        "count_ingressante_hard_sci",
        "count_ingressante_humanities",
        "count_ingressante_any",
        "count_INGRESSANTE_top10pct_avg20",
        "count_INGRESSANTE_top10pct_avg20_STEM",
        "count_particip_enem",
        "count_part_any",
        "count_part_enem_e_0_1"
      )
    ),
    conclusao = list(
      b = c(
        "mean_STEM_CONCLUSAO",
        "count_STEM_CONCLUSAO",
        "mean_hard_sci_CONCLUSAO",
        "count_hard_sci_CONCLUSAO",
        "mean_humanities_CONCLUSAO",
        "count_humanities_CONCLUSAO",
        "mean_any_CONCLUSAO",
        "count_any_CONCLUSAO",
        "mean_CONCLUINTE_top10pct_avg20",
        "count_CONCLUINTE_top10pct_avg20",
        "mean_CONCLUINTE_top10pct_avg20_STEM",
        "count_CONCLUINTE_top10pct_avg20_STEM"
      ),
      a = c(
        "count_STEM_CONCLUSAO",
        "count_hard_sci_CONCLUSAO",
        "count_humanities_CONCLUSAO",
        "count_any_CONCLUSAO",
        "count_CONCLUINTE_top10pct_avg20",
        "count_CONCLUINTE_top10pct_avg20_STEM"
      )
    ),
    migracao = list(
      b = c(
        "mean_ever_private",
        "count_ever_private",
        "mean_school_diff",
        "count_school_diff"
      ),
      a = c(
        "count_ever_private",
        "count_school_diff"
      )
    ),
    rais = list(
      b = c(
        "mean_ever_stem_rais",
        "count_ever_stem_rais",
        "mean_ever_hard_science_rais",
        "count_ever_hard_science_rais",
        "mean_ever_research_rais",
        "count_ever_research_rais",
        "mean_ever_finance_core_rais",
        "count_ever_finance_core_rais",
        "mean_wage_5k",
        "count_wage_5k",
        "mean_wage_10k",
        "count_wage_10k",
        "mean_wage_15k",
        "count_wage_15k"
      ),
      a = c(
        "count_ever_stem_rais",
        "count_ever_hard_science_rais",
        "count_ever_research_rais",
        "count_ever_finance_core_rais",
        "count_wage_5k",
        "count_wage_10k",
        "count_wage_15k"
      )
    ),
    rais_alt = list(
      b = c(
        "mean_ever_stem_rais_alt",
        "count_ever_stem_rais_alt",
        "mean_ever_hard_science_rais_alt",
        "count_ever_hard_science_rais_alt",
        "mean_ever_research_rais_alt",
        "count_ever_research_rais_alt",
        "mean_ever_finance_core_rais_alt",
        "count_ever_finance_core_rais_alt",
        "mean_wage_5k_alt",
        "count_wage_5k_alt",
        "mean_wage_10k_alt",
        "count_wage_10k_alt",
        "mean_wage_15k_alt",
        "count_wage_15k_alt"
      ),
      a = c(
        "count_ever_stem_rais_alt",
        "count_ever_hard_science_rais_alt",
        "count_ever_research_rais_alt",
        "count_ever_finance_core_rais_alt",
        "count_wage_5k_alt",
        "count_wage_10k_alt",
        "count_wage_15k_alt"
      )
    ),
    placebo = list(
      b = c(
        "mean_rural",
        "count_rural",
        "mean_PPI",
        "count_PPI",
        "mean_female",
        "count_female",
        "student_count"
      ),
      a = c(
        "count_rural",
        "count_PPI",
        "count_female",
        "student_count"
      )
    )
  )
)

# NIVEL II =====================================================================
nivel_II <- list(
  anticipations = 1,
  paths = list(
    balanced_schools = file.path(data_root, "8. Intermediário/matricula_escola",
                                 "positive_enroll_nivel_II_2005-2016_from1.csv"),
    # PROVISORIO: confirme o nome do RData e as colunas de tratamento no SEDAP.
    treatment = file.path(data_root, "9. Processado/aux_treat_obmep_v2_nivel_II.RData"),
    panel = file.path(data_root, "9. Processado/painel_collapsed_nivel_II.parquet"),
    plots = file.path(results_root, "second_phase/nivel_2"),
    tables = file.path(results_root, "second_phase/tables/nivel_2"),
    checkpoints = file.path(results_root, "second_phase/checkpoints/nivel_2")
  ),
  treatment_years = c(2005, 2017),
  treatments = c(
    APROV = "ano_primeira_participacao_2A_APROV_II",
    PRES = "ano_primeira_participacao_2A_PRES_II"
  ),
  upper_year_offset = 2,
  selected_outcomes = NULL,
  outcomes = list(
    ingresso = list(
      b = c(
        "mean_ingressante_STEM",
        "count_ingressante_STEM",
        "mean_ingressante_hard_sci",
        "count_ingressante_hard_sci",
        "mean_ingressante_humanities",
        "count_ingressante_humanities",
        "mean_ingressante_any",
        "count_ingressante_any",
        "mean_INGRESSANTE_top10pct_avg20",
        "count_INGRESSANTE_top10pct_avg20",
        "mean_INGRESSANTE_top10pct_avg20_STEM",
        "count_INGRESSANTE_top10pct_avg20_STEM",
        "mean_particip_enem",
        "count_particip_enem",
        "mean_nota_stem",
        "mean_part_any",
        "count_part_any",
        "mean_part_e_0_1",
        "count_part_enem_e_0_1"
      ),
      a = c(
        "count_ingressante_STEM",
        "count_ingressante_hard_sci",
        "count_ingressante_humanities",
        "count_ingressante_any",
        "count_INGRESSANTE_top10pct_avg20",
        "count_INGRESSANTE_top10pct_avg20_STEM",
        "count_particip_enem",
        "count_part_any",
        "count_part_enem_e_0_1"
      )
    ),
    conclusao = list(
      b = c(
        "mean_STEM_CONCLUSAO",
        "count_STEM_CONCLUSAO",
        "mean_hard_sci_CONCLUSAO",
        "count_hard_sci_CONCLUSAO",
        "mean_humanities_CONCLUSAO",
        "count_humanities_CONCLUSAO",
        "mean_any_CONCLUSAO",
        "count_any_CONCLUSAO",
        "mean_CONCLUINTE_top10pct_avg20",
        "count_CONCLUINTE_top10pct_avg20",
        "mean_CONCLUINTE_top10pct_avg20_STEM",
        "count_CONCLUINTE_top10pct_avg20_STEM"
      ),
      a = c(
        "count_STEM_CONCLUSAO",
        "count_hard_sci_CONCLUSAO",
        "count_humanities_CONCLUSAO",
        "count_any_CONCLUSAO",
        "count_CONCLUINTE_top10pct_avg20",
        "count_CONCLUINTE_top10pct_avg20_STEM"
      )
    ),
    migracao = list(
      b = c(
        "mean_ever_private",
        "count_ever_private",
        "mean_school_diff",
        "count_school_diff"
      ),
      a = c(
        "count_ever_private",
        "count_school_diff"
      )
    ),
    rais = list(
      b = c(
        "mean_ever_stem_rais",
        "count_ever_stem_rais",
        "mean_ever_hard_science_rais",
        "count_ever_hard_science_rais",
        "mean_ever_research_rais",
        "count_ever_research_rais",
        "mean_ever_finance_core_rais",
        "count_ever_finance_core_rais",
        "mean_wage_5k",
        "count_wage_5k",
        "mean_wage_10k",
        "count_wage_10k",
        "mean_wage_15k",
        "count_wage_15k"
      ),
      a = c(
        "count_ever_stem_rais",
        "count_ever_hard_science_rais",
        "count_ever_research_rais",
        "count_ever_finance_core_rais",
        "count_wage_5k",
        "count_wage_10k",
        "count_wage_15k"
      )
    ),
    rais_alt = list(
      b = c(
        "mean_ever_stem_rais_alt",
        "count_ever_stem_rais_alt",
        "mean_ever_hard_science_rais_alt",
        "count_ever_hard_science_rais_alt",
        "mean_ever_research_rais_alt",
        "count_ever_research_rais_alt",
        "mean_ever_finance_core_rais_alt",
        "count_ever_finance_core_rais_alt",
        "mean_wage_5k_alt",
        "count_wage_5k_alt",
        "mean_wage_10k_alt",
        "count_wage_10k_alt",
        "mean_wage_15k_alt",
        "count_wage_15k_alt"
      ),
      a = c(
        "count_ever_stem_rais_alt",
        "count_ever_hard_science_rais_alt",
        "count_ever_research_rais_alt",
        "count_ever_finance_core_rais_alt",
        "count_wage_5k_alt",
        "count_wage_10k_alt",
        "count_wage_15k_alt"
      )
    ),
    placebo = list(
      b = c(
        "mean_rural",
        "count_rural",
        "mean_PPI",
        "count_PPI",
        "mean_female",
        "count_female",
        "student_count"
      ),
      a = c(
        "count_rural",
        "count_PPI",
        "count_female",
        "student_count"
      )
    )
  )
)

# NIVEL III =====================================================================
nivel_III <- list(
  anticipations = 2,
  paths = list(
    balanced_schools = file.path(data_root, "8. Intermediário/matricula_escola",
                                 "positive_enroll_nivel_III_2005-2016_from1.csv"),
    # PROVISORIO: confirme o nome do RData e as colunas de tratamento no SEDAP.
    treatment = file.path(data_root, "9. Processado/aux_treat_obmep_v2_nivel_III.RData"),
    panel = file.path(data_root, "9. Processado/painel_collapsed_nivel_III.parquet"),
    plots = file.path(results_root, "second_phase/nivel_3"),
    tables = file.path(results_root, "second_phase/tables/nivel_3"),
    checkpoints = file.path(results_root, "second_phase/checkpoints/nivel_3")
  ),
  treatment_years = c(2005, 2017),
  treatments = c(
    APROV = "ano_primeira_participacao_2A_APROV_III",
    PRES = "ano_primeira_participacao_2A_PRES_III"
  ),
  upper_year_offset = 3,
  selected_outcomes = NULL,
  outcomes = list(
    ingresso = list(
      b = c(
        "mean_ingressante_STEM",
        "count_ingressante_STEM",
        "mean_ingressante_hard_sci",
        "count_ingressante_hard_sci",
        "mean_ingressante_humanities",
        "count_ingressante_humanities",
        "mean_ingressante_any",
        "count_ingressante_any",
        "mean_INGRESSANTE_top10pct_avg20",
        "count_INGRESSANTE_top10pct_avg20",
        "mean_INGRESSANTE_top10pct_avg20_STEM",
        "count_INGRESSANTE_top10pct_avg20_STEM",
        "mean_particip_enem",
        "count_particip_enem",
        "mean_nota_stem",
        "mean_part_any",
        "count_part_any",
        "mean_part_e_0_1",
        "count_part_enem_e_0_1"
      ),
      a = c(
        "count_ingressante_STEM",
        "count_ingressante_hard_sci",
        "count_ingressante_humanities",
        "count_ingressante_any",
        "count_INGRESSANTE_top10pct_avg20",
        "count_INGRESSANTE_top10pct_avg20_STEM",
        "count_particip_enem",
        "count_part_any",
        "count_part_enem_e_0_1"
      )
    ),
    conclusao = list(
      b = c(
        "mean_STEM_CONCLUSAO",
        "count_STEM_CONCLUSAO",
        "mean_hard_sci_CONCLUSAO",
        "count_hard_sci_CONCLUSAO",
        "mean_humanities_CONCLUSAO",
        "count_humanities_CONCLUSAO",
        "mean_any_CONCLUSAO",
        "count_any_CONCLUSAO",
        "mean_CONCLUINTE_top10pct_avg20",
        "count_CONCLUINTE_top10pct_avg20",
        "mean_CONCLUINTE_top10pct_avg20_STEM",
        "count_CONCLUINTE_top10pct_avg20_STEM"
      ),
      a = c(
        "count_STEM_CONCLUSAO",
        "count_hard_sci_CONCLUSAO",
        "count_humanities_CONCLUSAO",
        "count_any_CONCLUSAO",
        "count_CONCLUINTE_top10pct_avg20",
        "count_CONCLUINTE_top10pct_avg20_STEM"
      )
    ),
    migracao = list(
      b = c(
        "mean_ever_private",
        "count_ever_private",
        "mean_school_diff",
        "count_school_diff"
      ),
      a = c(
        "count_ever_private",
        "count_school_diff"
      )
    ),
    rais = list(
      b = c(
        "mean_ever_stem_rais",
        "count_ever_stem_rais",
        "mean_ever_hard_science_rais",
        "count_ever_hard_science_rais",
        "mean_ever_research_rais",
        "count_ever_research_rais",
        "mean_ever_finance_core_rais",
        "count_ever_finance_core_rais",
        "mean_wage_5k",
        "count_wage_5k",
        "mean_wage_10k",
        "count_wage_10k",
        "mean_wage_15k",
        "count_wage_15k"
      ),
      a = c(
        "count_ever_stem_rais",
        "count_ever_hard_science_rais",
        "count_ever_research_rais",
        "count_ever_finance_core_rais",
        "count_wage_5k",
        "count_wage_10k",
        "count_wage_15k"
      )
    ),
    rais_alt = list(
      b = c(
        "mean_ever_stem_rais_alt",
        "count_ever_stem_rais_alt",
        "mean_ever_hard_science_rais_alt",
        "count_ever_hard_science_rais_alt",
        "mean_ever_research_rais_alt",
        "count_ever_research_rais_alt",
        "mean_ever_finance_core_rais_alt",
        "count_ever_finance_core_rais_alt",
        "mean_wage_5k_alt",
        "count_wage_5k_alt",
        "mean_wage_10k_alt",
        "count_wage_10k_alt",
        "mean_wage_15k_alt",
        "count_wage_15k_alt"
      ),
      a = c(
        "count_ever_stem_rais_alt",
        "count_ever_hard_science_rais_alt",
        "count_ever_research_rais_alt",
        "count_ever_finance_core_rais_alt",
        "count_wage_5k_alt",
        "count_wage_10k_alt",
        "count_wage_15k_alt"
      )
    ),
    placebo = list(
      b = c(
        "mean_rural",
        "count_rural",
        "mean_PPI",
        "count_PPI",
        "mean_female",
        "count_female",
        "student_count"
      ),
      a = c(
        "count_rural",
        "count_PPI",
        "count_female",
        "student_count"
      )
    )
  )
)

# CONFIGURACAO AVANCADA E MONTAGEM --------------------------------------------
# Normalmente nao e necessario editar abaixo.
# years: janelas de observacao do nivel I, limites inclusivos (nao sao anos de tratamento).
# Nivel II: +2 no limite superior finito; nivel III: +3. Inferiores e Inf nao mudam.
# Janelas curtas podem nao permitir agregacao, dependendo da antecipacao e da opcao de coorte.
# O runner registra essas falhas e continua os demais outcomes/niveis.
# baseline: painel completo (full) ou filtrado do grupo (group).
# wald_cohorts: opcoes de coorte que registram W e Wpval, conforme o original.
csdid_config <- list(
  selected_levels = run_settings$selected_levels,
  samples = run_settings$samples,
  cohorts = run_settings$cohorts,
  treatments = run_settings$treatments,
  selected_groups = run_settings$selected_groups,
  levels = list(I = nivel_I, II = nivel_II, III = nivel_III),
  excluded_years = c(2005, 2006),
  estimator = list(
    xformla = ~students2007,
    est_method = "dr",
    control_group = "notyettreated",
    base_period = "universal"
  ),
  inference = list(seed = 1234, na.rm = TRUE, alpha_90 = 0.1, alpha_99 = 0.01,
                   biter_99 = 1e4, overall_probability = 0.975),
  plots = list(dynamic_width = 8, dynamic_height = 6,
               cohort_width = 4, cohort_height = 25, dpi = 300),
  groups = list(
    ingresso = list(
      years = c(2005, 2013), exclude_private = TRUE, baseline = "full",
      wald_cohorts = c("f", "e")
    ),
    conclusao = list(
      years = c(2005, 2008), exclude_private = TRUE, baseline = "group",
      wald_cohorts = "f"
    ),
    migracao = list(
      years = c(2007, Inf), exclude_private = TRUE, baseline = "group",
      wald_cohorts = c("f", "e")
    ),
    rais = list(
      years = c(2005, 2009), exclude_private = TRUE, baseline = "group",
      wald_cohorts = c("f", "e")
    ),
    rais_alt = list(
      years = c(-Inf, 2008), exclude_private = TRUE, baseline = "group",
      wald_cohorts = character(0)
    ),
    placebo = list(
      years = c(-Inf, Inf), exclude_private = TRUE, baseline = "full",
      wald_cohorts = c("f", "e")
    )
  )
)
