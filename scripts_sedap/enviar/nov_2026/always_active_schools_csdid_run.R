# SEDAP: execucao offline; nao instala pacotes nem utiliza servicos externos.
# 1. Copie os tres scripts para a mesma pasta no SEDAP.
# 2. Ajuste scripts_dir e os caminhos por nivel no *_config.R (RData II/III provisorios).
# 3. Execute inteiro: source ou Rscript. Nao altera o diretorio atual.
# Edite run_settings no topo do config e selected_outcomes em cada bloco de nivel.
# anticipations em cada nivel define os valores; tabelas combinadas incluem anticipation.
scripts_dir <- "T:/"

# Carrega as escolhas do usuario e as funcoes; estes sources nao iniciam estimacoes.
source(file.path(scripts_dir, "always_active_schools_csdid_config.R"), local = TRUE,
       encoding = "UTF-8")
source(file.path(scripts_dir, "always_active_schools_csdid_functions.R"), local = TRUE,
       encoding = "UTF-8")

# Usa os pacotes ja instalados no SEDAP para ler dados, preparar paineis e estimar.
library(arrow)
library(dplyr)
library(tidyr)
library(ggplot2)
library(did)
options(scipen = 999)

# Confere as selecoes comuns antes de abrir arquivos ou criar resultados.
stopifnot(length(csdid_config$selected_levels) > 0L,
          !anyDuplicated(csdid_config$selected_levels),
          all(csdid_config$selected_levels %in% names(csdid_config$levels)),
          length(csdid_config$samples) > 0L, !anyDuplicated(csdid_config$samples),
          all(csdid_config$samples %in% c("b", "a")),
          length(csdid_config$cohorts) > 0L, !anyDuplicated(csdid_config$cohorts),
          all(csdid_config$cohorts %in% c("f", "e")),
          length(csdid_config$treatments) > 0L, !anyDuplicated(csdid_config$treatments),
          all(csdid_config$treatments %in% c("APROV", "PRES")),
          length(csdid_config$selected_groups) > 0L,
          !anyDuplicated(csdid_config$selected_groups),
          all(csdid_config$selected_groups %in% names(csdid_config$groups)))

# Preflight: valida parametros, outcomes e caminhos de TODOS os niveis selecionados.
required_by_level <- list()
output_paths <- list(plots = character(), tables = character(), checkpoints = character())
for (level_id in csdid_config$selected_levels) {
  level <- csdid_config$levels[[level_id]]
  if (!is.numeric(level$anticipations) || length(level$anticipations) == 0L ||
      any(!is.finite(level$anticipations)) || any(level$anticipations < 0) ||
      any(level$anticipations != floor(level$anticipations)) || anyDuplicated(level$anticipations)) {
    stop("Nivel ", level_id, ": anticipations requer valores inteiros, nao negativos e distintos (ex.: c(1, 3)).")
  }
  if (length(level$upper_year_offset) != 1L || !is.numeric(level$upper_year_offset) ||
      !is.finite(level$upper_year_offset) || level$upper_year_offset < 0) {
    stop("Nivel ", level_id, ": upper_year_offset deve ser um numero finito nao negativo.")
  }
  if (!is.numeric(level$treatment_years) || length(level$treatment_years) != 2L ||
      any(!is.finite(level$treatment_years)) || level$treatment_years[1] > level$treatment_years[2]) {
    stop("Nivel ", level_id, ": treatment_years requer limites inclusivos em ordem crescente.")
  }
  if (!all(csdid_config$treatments %in% names(level$treatments)) ||
      anyNA(level$treatments[csdid_config$treatments]) ||
      any(!nzchar(level$treatments[csdid_config$treatments]))) {
    stop("Nivel ", level_id, ": informe as colunas dos tratamentos selecionados.")
  }
  # Reune os outcomes das amostras escolhidas e aplica a selecao opcional do nivel.
  available_outcomes <- character()
  for (group_name in csdid_config$selected_groups) {
    if (!group_name %in% names(level$outcomes) ||
        !all(csdid_config$samples %in% names(level$outcomes[[group_name]]))) {
      stop("Nivel ", level_id, ": faltam listas de outcomes por amostra no grupo ", group_name, ".")
    }
    for (sample_type in csdid_config$samples) {
      outcomes <- level$outcomes[[group_name]][[sample_type]]
      if (!is.character(outcomes) || anyNA(outcomes) || any(!nzchar(outcomes)) || anyDuplicated(outcomes)) {
        stop("Nivel ", level_id, ": nomes de outcomes invalidos ou duplicados em ", group_name, "/", sample_type, ".")
      }
      available_outcomes <- union(available_outcomes, outcomes)
    }
  }
  if (!is.null(level$selected_outcomes) &&
      (!is.character(level$selected_outcomes) || length(level$selected_outcomes) == 0L ||
       anyNA(level$selected_outcomes) || !all(level$selected_outcomes %in% available_outcomes))) {
    stop("Nivel ", level_id, ": selected_outcomes deve conter nomes dos grupos e amostras selecionados.")
  }
  required_outcomes <- if (is.null(level$selected_outcomes)) available_outcomes else
    intersect(available_outcomes, level$selected_outcomes)
  # students2007 sera construido em prepare_panel; as demais colunas devem existir na entrada.
  required_panel <- unique(c("CO_ENTIDADE", "NU_ANO", "student_count", required_outcomes,
                              setdiff(all.vars(csdid_config$estimator$xformla), "students2007")))
  for (group_name in csdid_config$selected_groups) {
    if (csdid_config$groups[[group_name]]$exclude_private &&
        any(unlist(level$outcomes[[group_name]][csdid_config$samples]) %in% required_outcomes)) {
      required_panel <- union(required_panel, "TP_DEPENDENCIA")
    }
  }
  required_by_level[[level_id]] <- list(panel = required_panel, outcomes = required_outcomes)
  for (input_name in c("balanced_schools", "treatment", "panel")) {
    input_path <- level$paths[[input_name]]
    if (!is.character(input_path) || length(input_path) != 1L || is.na(input_path) ||
        !nzchar(input_path) || !file.exists(input_path)) {
      stop("Nivel ", level_id, ": arquivo ", input_name, " nao encontrado: ", input_path)
    }
  }
  for (output_name in names(output_paths)) {
    output_path <- level$paths[[output_name]]
    if (!is.character(output_path) || length(output_path) != 1L || is.na(output_path) || !nzchar(output_path)) {
      stop("Nivel ", level_id, ": informe a pasta completa de saida para ", output_name, ".")
    }
    output_paths[[output_name]] <- c(output_paths[[output_name]],
                                     normalizePath(output_path, winslash = "/", mustWork = FALSE))
  }
}
# Impede que niveis diferentes sobrescrevam os resultados na mesma pasta.
for (output_name in names(output_paths)) {
  if (anyDuplicated(tolower(gsub("\\\\", "/", sub("[/\\\\]+$", "", output_paths[[output_name]]))))) {
    stop("Os niveis selecionados precisam de pastas de ", output_name, " distintas.")
  }
}

# Valida um painel por vez para nao manter tres paineis completos em memoria.
# A estimacao relera os arquivos apos o preflight de todos os niveis.
for (level_id in csdid_config$selected_levels) {
  level <- csdid_config$levels[[level_id]]
  required_panel <- required_by_level[[level_id]]$panel
  required_outcomes <- required_by_level[[level_id]]$outcomes
  treatments <- unname(level$treatments[csdid_config$treatments])
  balanced_check <- read.csv(level$paths$balanced_schools)
  if (!"CO_ENTIDADE" %in% names(balanced_check) ||
      !is.numeric(balanced_check$CO_ENTIDADE) || anyNA(balanced_check$CO_ENTIDADE)) {
    stop("Nivel ", level_id, ": CSV de escolas balanceadas requer CO_ENTIDADE numerico sem missing.")
  }
  # Isola o RData e exige uma unica definicao dos tratamentos por escola.
  treatment_data <- new.env(parent = emptyenv())
  load(level$paths$treatment, envir = treatment_data)
  if (!exists("obmep", envir = treatment_data, inherits = FALSE) ||
      !is.data.frame(treatment_data$obmep)) {
    stop("Nivel ", level_id, ": RData deve conter o data.frame obmep.")
  }
  missing_columns <- setdiff(c("CODIGO_INEP", treatments), names(treatment_data$obmep))
  if (length(missing_columns) > 0L) {
    stop("Nivel ", level_id, ": colunas ausentes no RData: ", paste(missing_columns, collapse = ", "))
  }
  obmep_check <- treatment_data$obmep %>% select(CODIGO_INEP, all_of(treatments)) %>% distinct()
  if (!is.numeric(obmep_check$CODIGO_INEP) || anyNA(obmep_check$CODIGO_INEP) ||
      anyDuplicated(obmep_check$CODIGO_INEP)) {
    stop("Nivel ", level_id, ": CODIGO_INEP nao numerico, ausente ou com tratamentos conflitantes no RData.")
  }
  if (!all(vapply(obmep_check[treatments], is.numeric, logical(1)))) {
    stop("Nivel ", level_id, ": anos de tratamento devem ser numericos.")
  }
  # Verifica colunas, tipos e unicidade da chave escola/ano antes de estimar qualquer nivel.
  panel_check <- arrow::read_parquet(level$paths$panel)
  missing_columns <- setdiff(required_panel, names(panel_check))
  if (length(missing_columns) > 0L) {
    stop("Nivel ", level_id, ": colunas ausentes no painel: ", paste(missing_columns, collapse = ", "))
  }
  if (anyNA(panel_check$CO_ENTIDADE) || anyNA(panel_check$NU_ANO) ||
      anyDuplicated(panel_check[c("CO_ENTIDADE", "NU_ANO")])) {
    stop("Nivel ", level_id, ": chave CO_ENTIDADE/NU_ANO ausente ou duplicada no painel.")
  }
  numeric_columns <- unique(c("CO_ENTIDADE", "NU_ANO", "student_count", required_outcomes))
  if (!all(vapply(panel_check[numeric_columns], is.numeric, logical(1)))) {
    stop("Nivel ", level_id, ": identificador, ano, matriculas e outcomes devem ser numericos.")
  }
  if (length(intersect(treatments, names(panel_check))) > 0L || "students2007" %in% names(panel_check)) {
    stop("Nivel ", level_id, ": painel deve preceder a juncao dos tratamentos e de students2007.")
  }
  message("Preflight OK: nivel ", level_id)
  rm(panel_check, balanced_check, obmep_check, treatment_data)
}

# Com todas as entradas validadas, carrega e processa um nivel por vez.
for (level_id in csdid_config$selected_levels) {
  level <- csdid_config$levels[[level_id]]
  level_config <- csdid_config
  level_config$treatment_years <- level$treatment_years
  treatments <- unname(level$treatments[csdid_config$treatments])
  balanced_schools <- read.csv(level$paths$balanced_schools)
  treatment_data <- new.env(parent = emptyenv())
  load(level$paths$treatment, envir = treatment_data)
  obmep <- treatment_data$obmep %>% select(CODIGO_INEP, all_of(treatments)) %>% distinct()
  panel <- arrow::read_parquet(level$paths$panel)
  rm(treatment_data)
  table_dir <- level$paths$tables
  dir.create(table_dir, recursive = TRUE, showWarnings = FALSE)
  # Acumuladores do nivel: combinam antecipacoes, amostras, coortes e tratamentos.
  # Mantem cabecalhos nas tabelas mesmo quando todos os outcomes falham.
  full_coef <- data.frame(
    outcome = character(), N = integer(), e = numeric(), att = numeric(),
    se_95 = numeric(), se_90 = numeric(), se_99 = numeric(), W_test = numeric(), W_pval = numeric(),
    ci_low_95 = numeric(), ci_high_95 = numeric(), ci_low_90 = numeric(), ci_high_90 = numeric(),
    ci_low_99 = numeric(), ci_high_99 = numeric(), period = character(), overall = numeric(),
    baseline_mean = numeric(), treatment = character(), cohort_type = character(), sample_type = character(),
    anticipation = numeric())
  full_coef_cohort <- data.frame(
    outcome = character(), cohort = numeric(), e = numeric(), period = character(),
    att = numeric(), se = numeric(), ci_low_95 = numeric(), ci_high_95 = numeric(),
    overall = numeric(), size = integer(), treatment = character(),
    cohort_type = character(), sample_type = character(), anticipation = numeric())
  failures <- data.frame(level = character(), sample = character(), cohort_option = character(),
                          treatment = character(), outcome = character(), error_message = character(),
                          anticipation = numeric())
  failure_path <- file.path(table_dir, paste0("estimation_failures_nivel_", level_id, ".csv"))
  readr::write_csv(failures, failure_path)

  # Repete a analise para cada antecipacao, separando suas pastas de graficos/checkpoints.
  for (anticipation in level$anticipations) {
    level_config$estimator$anticipation <- anticipation
    anticipation_folder <- paste0("anticipation_", anticipation)
    checkpoint_dir <- file.path(level$paths$checkpoints, anticipation_folder)
    dir.create(checkpoint_dir, recursive = TRUE, showWarnings = FALSE)

    # b: escolas da lista balanceada; a: todas as elegiveis, com painel completado.
    for (type in csdid_config$samples) {
      sample_folder <- if (type == "b") "balanced" else "unbalanced"
      sample_label <- if (type == "b") "balanced" else "all_schools"
      # f: mantem todos os anos; e: remove 2005-2006, alem das janelas de cada grupo.
      for (cohorts in csdid_config$cohorts) {
        cohort_folder <- if (cohorts == "f") "full_cohort" else "non-synthetic"
        cohort_label <- if (cohorts == "f") "all" else "non_synthetic"
        cohort_dir <- file.path(level$paths$plots, anticipation_folder, sample_folder, cohort_folder)

        # Cada definicao de tratamento recebe acumuladores e pasta proprios.
        for (d in treatments) {
          es_path <- file.path(cohort_dir, d)
          dir.create(file.path(es_path, "byG"), recursive = TRUE, showWarnings = FALSE)
          coefs <- data.frame()
          coefs_cohort <- data.frame()
          # Junta tratamentos, restringe anos de primeiro tratamento e prepara students2007.
          # A funcao tambem aplica as regras de amostra, exclusao de anos e imputacao.
          panel.analysis <- prepare_panel(panel, obmep, balanced_schools, type, cohorts, d, level_config)

          # Usa os nomes de outcomes especificos deste nivel e desta amostra.
          for (group_name in csdid_config$selected_groups) {
            group <- csdid_config$groups[[group_name]]
            outcomes <- level$outcomes[[group_name]][[type]]
            if (!is.null(level$selected_outcomes)) {
              outcomes <- outcomes[outcomes %in% level$selected_outcomes]
            }
            if (length(outcomes) == 0L) next
            # Ajusta somente o limite superior finito e aplica a exclusao de observacoes privadas.
            years <- group$years
            if (is.finite(years[2])) years[2] <- years[2] + level$upper_year_offset
            group_panel <- panel.analysis %>% filter(NU_ANO >= years[1], NU_ANO <= years[2])
            if (group$exclude_private) group_panel <- group_panel %>% filter(TP_DEPENDENCIA != 4)
            # Define apenas a media descritiva em g-1; a referencia do estimador depende de base_period/anticipation.
            # full usa o painel anterior aos filtros do grupo; group usa o painel ja filtrado.
            baseline_panel <- if (group$baseline == "full") panel.analysis else group_panel

            for (o in outcomes) {
              message("Nivel: ", level_id, "; antecipacao: ", anticipation,
                      "; amostra: ", type, "; coortes: ", cohorts,
                      "; tratamento: ", d, "; grupo: ", group_name, "; outcome: ", o)
              # Estima ATT, agrega efeitos, calcula intervalos e salva os graficos deste outcome.
              result <- tryCatch(
                run_event_study(group_panel, baseline_panel, o, d, level_config,
                                es_path, cohorts %in% group$wald_cohorts),
                error = identity
              )
              # Registra falhas com a especificacao completa e segue para o proximo outcome.
              if (inherits(result, "error")) {
                failures <- bind_rows(failures, data.frame(
                  level = level_id, sample = type, cohort_option = cohorts,
                  treatment = d, outcome = o, error_message = conditionMessage(result),
                  anticipation = anticipation))
                readr::write_csv(failures, failure_path)
                message("FALHA registrada (nivel ", level_id, ", antecipacao ", anticipation,
                        "): ", conditionMessage(result))
                next
              }
              coefs <- bind_rows(coefs, result$coefs)
              coefs_cohort <- bind_rows(coefs_cohort, result$cohort_coefs)
            }
          }

          # Rotula antes de acumular, evitando misturar tratamentos ou antecipacoes.
          if (nrow(coefs) > 0L) {
            coefs <- coefs %>%
              mutate(treatment = d, cohort_type = cohort_label, sample_type = sample_label,
                     anticipation = .env$anticipation)
            coefs_cohort <- coefs_cohort %>%
              mutate(treatment = d, cohort_type = cohort_label, sample_type = sample_label,
                     anticipation = .env$anticipation)
            full_coef <- bind_rows(full_coef, coefs)
            full_coef_cohort <- bind_rows(full_coef_cohort, coefs_cohort)
          }
          # Salva o progresso apos cada tratamento; o checkpoint inclui so esta antecipacao.
          readr::write_csv(full_coef[full_coef$anticipation == anticipation, ],
                           file.path(checkpoint_dir, paste0("checkpoint_coefs", type, cohorts)))
        }
      }
    }
  }

  # Exporta as tabelas finais do nivel, combinando as especificacoes na coluna anticipation.
  readr::write_csv(full_coef, file.path(table_dir, paste0("event_studies_nivel_", level_id, ".csv")))
  readr::write_csv(full_coef_cohort,
                   file.path(table_dir, paste0("event_studies_cohort_nivel_", level_id, ".csv")))
  message("Nivel ", level_id, ": ", nrow(failures), " falhas; tabelas em ", table_dir)
  # Libera os paineis temporarios antes de carregar o proximo nivel.
  rm(panel, panel.analysis, group_panel, baseline_panel)
}
