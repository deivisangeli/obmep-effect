# SEDAP: funcoes offline. Este arquivo nao carrega dados nem executa estimacoes.
# Os pacotes sao carregados pelo *_run.R.

baseline_mean <- function(o, data, d) {
  data %>%
    filter(!is.na(.data[[d]]), .data[[d]] > 0, NU_ANO == .data[[d]] - 1) %>%
    pull(.data[[o]]) %>%
    mean(na.rm = TRUE)
}

prepare_panel <- function(panel, obmep, balanced_schools, sample_type,
                          cohort_type, treatment, config) {
  panel <- panel %>%
    left_join(obmep, by = c("CO_ENTIDADE" = "CODIGO_INEP")) %>%
    mutate(!!sym(treatment) := replace_na(.data[[treatment]], 0)) %>%
    filter(.data[[treatment]] != 0,
           .data[[treatment]] >= config$treatment_years[1],
           .data[[treatment]] <= config$treatment_years[2])

  if (sample_type == "b") {
    panel <- panel %>%
      semi_join(balanced_schools, by = "CO_ENTIDADE") %>%
      filter(!is.na(NU_ANO))
  } else {
    panel <- panel %>% complete(CO_ENTIDADE, NU_ANO) %>% arrange(CO_ENTIDADE, NU_ANO)
    first_ds <- panel %>%
      filter(!is.na(.data[[treatment]])) %>%
      distinct(CO_ENTIDADE, .data[[treatment]])
    panel <- panel %>%
      select(-all_of(treatment)) %>%
      left_join(first_ds, by = "CO_ENTIDADE")
  }

  students2007 <- panel %>%
    filter(NU_ANO == 2007) %>%
    select(student_count, CO_ENTIDADE) %>%
    rename(students2007 = student_count)
  panel <- panel %>%
    left_join(students2007, by = "CO_ENTIDADE") %>%
    mutate(NU_ANO = as.numeric(NU_ANO), !!sym(treatment) := as.numeric(.data[[treatment]]))

  if (cohort_type == "e") {
    panel <- panel %>% filter(!NU_ANO %in% config$excluded_years)
  }
  # Preserva a imputacao do original para todas as colunas da amostra a.
  if (sample_type == "a") panel[is.na(panel)] <- 0
  panel
}

run_event_study <- function(data, baseline_data, outcome, treatment, config,
                            output_dir, include_wald) {
  set.seed(config$inference$seed)
  att_results <- do.call(did::att_gt, c(
    list(yname = outcome, tname = "NU_ANO", idname = "CO_ENTIDADE",
         gname = treatment, data = data), config$estimator
  ))

  set.seed(config$inference$seed)
  agg_effects <- did::aggte(att_results, type = "dynamic", na.rm = config$inference$na.rm)
  N <- length(agg_effects$DIDparams$time_invariant_data$CO_ENTIDADE)
  dynamic_plot <- did::ggdid(agg_effects) +
    ggplot2::annotate("text", x = min(agg_effects$egt), y = max(agg_effects$att),
                      label = paste0("N = ", N), hjust = 0)

  cohort_df <- att_results$DIDparams$data
  idname <- att_results$DIDparams$idname
  gname <- att_results$DIDparams$gname
  cohort_size <- cohort_df %>%
    group_by(.data[[gname]]) %>%
    summarize(size = n_distinct(.data[[idname]]), .groups = "drop")
  colnames(cohort_size)[1] <- "cohort"

  cohort_coefs <- data.frame(
    outcome = outcome, Year = att_results$t, cohort = att_results$group,
    att = att_results$att, se = att_results$se
  ) %>%
    mutate(e = Year - cohort,
           ci_low_95 = att - att_results$c * se,
           ci_high_95 = att + att_results$c * se,
           period = ifelse(e < 0, "Pre", "Post"), overall = 0) %>%
    left_join(cohort_size, by = "cohort")

  set.seed(config$inference$seed)
  aggt_cohort <- did::aggte(att_results, type = "group", na.rm = config$inference$na.rm)
  overall_cohort <- data.frame(
    outcome = outcome, cohort = aggt_cohort$egt,
    att = aggt_cohort$att.egt, se = aggt_cohort$se.egt
  ) %>%
    mutate(ci_low_95 = att - aggt_cohort$crit.val.egt * se,
           ci_high_95 = att + aggt_cohort$crit.val.egt * se, overall = 1) %>%
    left_join(cohort_size, by = "cohort")
  cohort_coefs <- bind_rows(cohort_coefs, overall_cohort) %>%
    select(outcome, cohort, e, period, att, se, ci_low_95, ci_high_95, overall, size) %>%
    arrange(cohort, e, overall)

  cohort_plot <- did::ggdid(att_results)

  bs_mean <- round(baseline_mean(o = outcome, data = baseline_data, d = treatment), 3)
  set.seed(config$inference$seed)
  aggt_90 <- did::aggte(att_results, type = "dynamic", na.rm = config$inference$na.rm,
                       alp = config$inference$alpha_90)
  set.seed(config$inference$seed)
  aggt_99 <- did::aggte(att_results, type = "dynamic", na.rm = config$inference$na.rm,
                       alp = config$inference$alpha_99, biter = config$inference$biter_99)

  coefs <- data.frame(
    outcome = outcome, N = N, e = agg_effects$egt, att = agg_effects$att.egt,
    se_95 = agg_effects$se.egt, se_90 = aggt_90$se.egt, se_99 = aggt_99$se.egt
  )
  if (include_wald) {
    coefs$W_test <- att_results$W[[1]]
    coefs$W_pval <- att_results$Wpval[[1]]
  }
  coefs <- coefs %>%
    mutate(ci_low_95 = att - agg_effects$crit.val.egt * se_95,
           ci_high_95 = att + agg_effects$crit.val.egt * se_95,
           ci_low_90 = att - aggt_90$crit.val.egt * se_90,
           ci_high_90 = att + aggt_90$crit.val.egt * se_90,
           ci_low_99 = att - aggt_99$crit.val.egt * se_99,
           ci_high_99 = att + aggt_99$crit.val.egt * se_99,
           period = ifelse(e < 0, "Pre", "Post"), overall = 0)

  # Preserva o intervalo t do original para o ATT agregado.
  overall_df <- data.frame(outcome = outcome, att = agg_effects$overall.att,
                           se_95 = agg_effects$overall.se, N = N) %>%
    mutate(overall = 1,
           ci_low_95 = att - qt(config$inference$overall_probability, N) * se_95,
           ci_high_95 = att + qt(config$inference$overall_probability, N) * se_95)
  coefs <- bind_rows(coefs, overall_df) %>%
    arrange(e, overall) %>% mutate(baseline_mean = bs_mean)
  # Exporta somente apos concluir todas as agregacoes deste outcome.
  ggplot2::ggsave(file.path(output_dir, paste0(treatment, "_", outcome, ".pdf")),
                  plot = dynamic_plot, width = config$plots$dynamic_width,
                  height = config$plots$dynamic_height, dpi = config$plots$dpi)
  ggplot2::ggsave(file.path(output_dir, "byG", paste0(treatment, "_", outcome, ".pdf")),
                  plot = cohort_plot, width = config$plots$cohort_width,
                  height = config$plots$cohort_height, dpi = config$plots$dpi)
  list(coefs = coefs, cohort_coefs = cohort_coefs)
}
