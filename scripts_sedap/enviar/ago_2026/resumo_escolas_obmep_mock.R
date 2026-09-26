################################################################################

## Resumo de escolas elegiveis e participantes da OBMEP
##
## AMBIENTE DE EXECUCAO: terminal offline do SEDAP.
## Este script nao usa internet e nao instala pacotes durante a execucao.
## Ele cria dados mock, calcula estatisticas descritivas e salva tabelas/graficos.

################################################################################

### Limpar o ambiente e carregar os pacotes usados no SEDAP

rm(list = ls())
gc()

library(tidyverse)


################################################################################

### Definir anos, outcomes e diretorio de saida

################################################################################

# Janela usada para definir "elegivel em todos os anos".
anos_analise <- 2007:2016

# Para usar os outcomes reais, alterar somente os nomes neste vetor.
outcome_vars <- c("outcome_1", "outcome_2")

# No SEDAP, os resultados serao gravados no caminho abaixo.
# A variavel de ambiente permite testar o mesmo script localmente sem edita-lo.
out_dir <- Sys.getenv(
  "OBMEP_RESUMO_OUT",
  unset = "T:/8. Intermediário/resumo_escolas_obmep_mock"
)

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)


################################################################################

### Construir o mock 1: painel completo de escola por ano

################################################################################

# O mock inclui escolas sempre elegiveis, elegiveis em parte dos anos e nunca
# elegiveis. Ele tambem inclui escolas que nunca participam, param, recomecam ou
# seguem participando ate o fim da janela.
mock_escola_ano <- crossing(
  CO_ENTIDADE = 1001:1008,
  ano = anos_analise
) %>%
  arrange(CO_ENTIDADE, ano) %>%
  mutate(
    matriculas_nivel_I = case_when(
      CO_ENTIDADE == 1001 ~ 20L + (ano - 2007L),
      CO_ENTIDADE == 1002 ~ 18L + ((ano - 2007L) %% 3L),
      CO_ENTIDADE == 1003 ~ 15L + ((ano - 2007L) %% 2L),
      CO_ENTIDADE == 1004 & ano >= 2010 ~ 14L + (ano - 2010L),
      CO_ENTIDADE == 1005 ~ 24L + ((ano - 2007L) %% 4L),
      CO_ENTIDADE == 1006 & ano <= 2012 ~ 12L + (ano - 2007L),
      CO_ENTIDADE == 1007 ~ 0L,
      CO_ENTIDADE == 1008 ~ 10L + ((ano - 2007L) %% 5L),
      TRUE ~ 0L
    ),
    participou_mock = case_when(
      CO_ENTIDADE == 1001 ~ 1L,
      CO_ENTIDADE == 1002 & ano %in% 2008:2010 ~ 1L,
      CO_ENTIDADE == 1004 & ano >= 2012 ~ 1L,
      CO_ENTIDADE == 1005 & (ano %in% 2007:2008 | ano >= 2011) ~ 1L,
      CO_ENTIDADE == 1006 & ano == 2009 ~ 1L,
      CO_ENTIDADE == 1008 & ano %in% 2009:2011 ~ 1L,
      TRUE ~ 0L
    ),
    NR_INSCRITOS_1_FASE = if_else(
      participou_mock == 1L,
      pmax(1L, as.integer(round(matriculas_nivel_I * 0.60))),
      0L
    ),
    TP_LOCALIZACAO = case_when(
      CO_ENTIDADE %in% c(1002L, 1004L, 1006L) ~ 2L,
      CO_ENTIDADE == 1008L & ano >= 2012L ~ 2L,
      TRUE ~ 1L
    )
  ) %>%
  select(-participou_mock)


################################################################################

### Construir o mock 2: alunos elegiveis ligados a escola e ao ano

################################################################################

# uncount() cria uma linha para cada aluno elegivel indicado por
# matriculas_nivel_I. Anos sem alunos elegiveis permanecem apenas no painel de
# escola por ano.
mock_aluno_ano <- mock_escola_ano %>%
  uncount(weights = matriculas_nivel_I, .id = "ordem_aluno") %>%
  mutate(
    ID_MATRICULA = paste(CO_ENTIDADE, ano, ordem_aluno, sep = "_"),

    # Codigos do Censo: 0 nao declarada, 1 branca, 2 preta, 3 parda,
    # 4 amarela/asiatica e 5 indigena.
    TP_COR_RACA = case_when(
      ordem_aluno %% 10L == 0L ~ 0L,
      ordem_aluno %% 7L == 0L ~ 4L,
      ordem_aluno %% 5L == 0L ~ 1L,
      ordem_aluno %% 3L == 0L ~ 2L,
      ordem_aluno %% 2L == 0L ~ 3L,
      TRUE ~ 5L
    ),

    # Dois outcomes ilustrativos. outcome_1 e binario; outcome_2 e continuo.
    outcome_1 = as.integer((CO_ENTIDADE + ano + ordem_aluno) %% 3L == 0L),
    outcome_2 = round(
      40 + 2 * (CO_ENTIDADE - 1000L) + 0.5 * (ano - 2007L) +
        ordem_aluno / 10,
      2
    ),

    # Inserir alguns NAs para verificar o tratamento de outcomes ausentes.
    outcome_1 = if_else(ordem_aluno %% 17L == 0L, NA_integer_, outcome_1),
    outcome_2 = if_else(ordem_aluno %% 19L == 0L, NA_real_, outcome_2)
  ) %>%
  select(
    ID_MATRICULA, CO_ENTIDADE, ano, TP_LOCALIZACAO, TP_COR_RACA,
    all_of(outcome_vars)
  )


################################################################################

### Preparar o painel anual e definir participacao

################################################################################

# complete() garante uma observacao para cada escola em cada ano. Ao adaptar o
# script aos dados reais, uma escola ausente em determinado ano sera tratada
# como nao elegivel e nao participante naquele ano.
painel_escola_ano <- mock_escola_ano %>%
  complete(
    CO_ENTIDADE,
    ano = anos_analise,
    fill = list(
      matriculas_nivel_I = 0L,
      NR_INSCRITOS_1_FASE = 0L
    )
  ) %>%
  group_by(CO_ENTIDADE) %>%
  fill(TP_LOCALIZACAO, .direction = "downup") %>%
  ungroup() %>%
  arrange(CO_ENTIDADE, ano) %>%
  mutate(
    participou = as.integer(NR_INSCRITOS_1_FASE > 0),
    elegivel_fase_I = as.integer(matriculas_nivel_I > 0)
  )

# Checagens simples para impedir resultados baseados em escola-ano duplicada ou
# em um painel incompleto.
stopifnot(
  nrow(painel_escola_ano) ==
    n_distinct(painel_escola_ano$CO_ENTIDADE) * length(anos_analise),
  nrow(distinct(painel_escola_ano, CO_ENTIDADE, ano)) ==
    nrow(painel_escola_ano),
  sum(painel_escola_ano$matriculas_nivel_I) == nrow(mock_aluno_ano)
)


################################################################################

### Calcular historico de elegibilidade e participacao de cada escola

################################################################################

# Identificar o primeiro ano de participacao. Escolas que nunca participaram
# nao aparecem nesta tabela e receberao NA no left_join().
primeira_participacao <- painel_escola_ano %>%
  filter(participou == 1L) %>%
  group_by(CO_ENTIDADE) %>%
  summarise(
    ano_primeira_participacao = min(ano),
    .groups = "drop"
  )

# A primeira parada e o primeiro ano com participou == 0 depois do inicio. A
# duracao do primeiro spell e a diferenca entre o inicio e essa parada.
historico_escolas <- painel_escola_ano %>%
  left_join(primeira_participacao, by = "CO_ENTIDADE") %>%
  group_by(CO_ENTIDADE) %>%
  summarise(
    total_alunos_elegiveis = sum(matriculas_nivel_I),
    numero_anos_participou = sum(participou),
    ano_primeira_participacao = first(ano_primeira_participacao),
    ano_primeira_parada = first(
      ano[
        !is.na(ano_primeira_participacao) &
          ano > ano_primeira_participacao &
          participou == 0L
      ],
      default = NA_integer_
    ),
    nunca_participou = as.integer(is.na(ano_primeira_participacao)),
    elegivel_todos_anos =
      n_distinct(ano) == length(anos_analise) & all(elegivel_fase_I == 1L),
    elegivel_algum_ano = any(elegivel_fase_I == 1L),
    .groups = "drop"
  ) %>%
  mutate(
    anos_participando_ate_primeira_parada = if_else(
      !is.na(ano_primeira_parada),
      ano_primeira_parada - ano_primeira_participacao,
      NA_integer_
    )
  )

# Validar casos conhecidos do mock: participacao sem parada, primeira parada,
# escola que nunca participa e escola que recomeca depois da primeira parada.
duracao_mock <- historico_escolas %>%
  select(CO_ENTIDADE, anos_participando_ate_primeira_parada) %>%
  deframe()

stopifnot(
  is.na(duracao_mock["1001"]),
  duracao_mock["1002"] == 3L,
  is.na(duracao_mock["1003"]),
  duracao_mock["1005"] == 2L,
  duracao_mock["1006"] == 1L
)


################################################################################

### Agregar localizacao, raca e outcomes dentro de cada escola

################################################################################

# As medias abaixo sao ponderadas pelo numero de alunos elegiveis, pois cada
# linha de mock_aluno_ano representa um aluno elegivel em um ano.
composicao_escolas <- mock_aluno_ano %>%
  group_by(CO_ENTIDADE) %>%
  summarise(
    share_rural = mean(TP_LOCALIZACAO == 2L, na.rm = TRUE),

    # A categoria nao declarada (codigo 0) permanece no denominador e vale zero
    # no numerador, conforme a definicao escolhida.
    share_nonwhite_nonasian = mean(
      TP_COR_RACA %in% c(2L, 3L, 5L),
      na.rm = TRUE
    ),
    .groups = "drop"
  )

# Colocar os outcomes em formato longo permite alterar outcome_vars sem criar
# uma funcao auxiliar ou repetir o mesmo bloco para cada outcome.
media_outcomes_escolas <- mock_aluno_ano %>%
  select(CO_ENTIDADE, all_of(outcome_vars)) %>%
  pivot_longer(
    cols = all_of(outcome_vars),
    names_to = "outcome",
    values_to = "valor"
  ) %>%
  group_by(CO_ENTIDADE, outcome) %>%
  summarise(
    media_outcome = if (all(is.na(valor))) {
      NA_real_
    } else {
      mean(valor, na.rm = TRUE)
    },
    .groups = "drop"
  ) %>%
  mutate(outcome = paste0("media_", outcome)) %>%
  pivot_wider(
    names_from = outcome,
    values_from = media_outcome
  )

# Juntar historico, composicao e outcomes em uma linha por escola.
dados_escola <- historico_escolas %>%
  left_join(composicao_escolas, by = "CO_ENTIDADE") %>%
  left_join(media_outcomes_escolas, by = "CO_ENTIDADE")


################################################################################

### Criar as duas amostras solicitadas

################################################################################

# A primeira amostra esta contida na segunda; por isso cada escola da primeira
# aparece uma vez em cada grupo na base empilhada.
dados_duas_amostras <- bind_rows(
  dados_escola %>%
    filter(elegivel_todos_anos) %>%
    mutate(amostra = "elegiveis_todos_anos"),
  dados_escola %>%
    filter(elegivel_algum_ano) %>%
    mutate(amostra = "elegiveis_algum_ano")
)

# Checar os tamanhos esperados do mock: cinco escolas sempre elegiveis e sete
# escolas elegiveis em pelo menos um ano.
stopifnot(
  sum(dados_escola$elegivel_todos_anos) == 5L,
  sum(dados_escola$elegivel_algum_ano) == 7L
)


################################################################################

### Gerar estatisticas descritivas no nivel da escola

################################################################################

# As medias de dummies e shares podem ser interpretadas diretamente como
# proporcoes porque todas permanecem na escala de zero a um.
variaveis_resumo <- c(
  "total_alunos_elegiveis",
  "numero_anos_participou",
  "anos_participando_ate_primeira_parada",
  "nunca_participou",
  "share_rural",
  "share_nonwhite_nonasian",
  paste0("media_", outcome_vars)
)

tabela_resumo <- dados_duas_amostras %>%
  select(amostra, all_of(variaveis_resumo)) %>%
  pivot_longer(
    cols = all_of(variaveis_resumo),
    names_to = "variavel",
    values_to = "valor"
  ) %>%
  group_by(amostra, variavel) %>%
  summarise(
    media = if (all(is.na(valor))) NA_real_ else mean(valor, na.rm = TRUE),
    desvio_padrao = if (all(is.na(valor))) NA_real_ else sd(valor, na.rm = TRUE),
    minimo = if (all(is.na(valor))) NA_real_ else min(valor, na.rm = TRUE),
    maximo = if (all(is.na(valor))) NA_real_ else max(valor, na.rm = TRUE),
    N = sum(!is.na(valor)),
    .groups = "drop"
  ) %>%
  mutate(variavel = factor(variavel, levels = variaveis_resumo)) %>%
  arrange(amostra, variavel) %>%
  mutate(variavel = as.character(variavel))

# Separar as tabelas para facilitar exportacao e leitura no SEDAP.
tabela_elegiveis_todos_anos <- tabela_resumo %>%
  filter(amostra == "elegiveis_todos_anos") %>%
  select(-amostra)

tabela_elegiveis_algum_ano <- tabela_resumo %>%
  filter(amostra == "elegiveis_algum_ano") %>%
  select(-amostra)


################################################################################

### Construir as series acumuladas de participacao

################################################################################

# Manter somente identificador, grupo e primeiro ano de participacao.
membros_amostras <- bind_rows(
  dados_escola %>%
    filter(elegivel_todos_anos) %>%
    transmute(
      amostra = "elegiveis_todos_anos",
      CO_ENTIDADE,
      ano_primeira_participacao
    ),
  dados_escola %>%
    filter(elegivel_algum_ano) %>%
    transmute(
      amostra = "elegiveis_algum_ano",
      CO_ENTIDADE,
      ano_primeira_participacao
    )
)

# Para cada ano, contar escolas cujo primeiro ano de participacao ja ocorreu.
# NAs, correspondentes a escolas que nunca participaram, nao entram na soma.
serie_participacao <- crossing(
  membros_amostras,
  ano = anos_analise
) %>%
  group_by(amostra, ano) %>%
  summarise(
    numero_escolas_participaram_ate_ano = sum(
      !is.na(ano_primeira_participacao) &
        ano_primeira_participacao <= ano
    ),
    .groups = "drop"
  ) %>%
  arrange(amostra, ano)

serie_elegiveis_todos_anos <- serie_participacao %>%
  filter(amostra == "elegiveis_todos_anos") %>%
  select(-amostra)

serie_elegiveis_algum_ano <- serie_participacao %>%
  filter(amostra == "elegiveis_algum_ano") %>%
  select(-amostra)

# Uma contagem acumulada nunca pode diminuir de um ano para o seguinte.
stopifnot(
  all(diff(serie_elegiveis_todos_anos$numero_escolas_participaram_ate_ano) >= 0L),
  all(diff(serie_elegiveis_algum_ano$numero_escolas_participaram_ate_ano) >= 0L),
  tail(serie_elegiveis_todos_anos$numero_escolas_participaram_ate_ano, 1L) ==
    sum(
      dados_escola$elegivel_todos_anos &
        !is.na(dados_escola$ano_primeira_participacao)
    ),
  tail(serie_elegiveis_algum_ano$numero_escolas_participaram_ate_ano, 1L) ==
    sum(
      dados_escola$elegivel_algum_ano &
        !is.na(dados_escola$ano_primeira_participacao)
    )
)


################################################################################

### Criar os dois graficos

################################################################################

grafico_elegiveis_todos_anos <- ggplot(
  serie_elegiveis_todos_anos,
  aes(x = ano, y = numero_escolas_participaram_ate_ano)
) +
  geom_line(linewidth = 1, color = "#1B6CA8") +
  geom_point(size = 2, color = "#1B6CA8") +
  scale_x_continuous(breaks = anos_analise) +
  scale_y_continuous(breaks = scales::pretty_breaks()) +
  labs(
    title = "Escolas sempre elegiveis que ja participaram da OBMEP",
    subtitle = "Elegiveis para a Fase I em todos os anos, 2007-2016",
    x = "Ano",
    y = "Numero acumulado de escolas"
  ) +
  theme_minimal(base_size = 12)

grafico_elegiveis_algum_ano <- ggplot(
  serie_elegiveis_algum_ano,
  aes(x = ano, y = numero_escolas_participaram_ate_ano)
) +
  geom_line(linewidth = 1, color = "#B44C43") +
  geom_point(size = 2, color = "#B44C43") +
  scale_x_continuous(breaks = anos_analise) +
  scale_y_continuous(breaks = scales::pretty_breaks()) +
  labs(
    title = "Escolas elegiveis que ja participaram da OBMEP",
    subtitle = "Elegiveis para a Fase I em pelo menos um ano, 2007-2016",
    x = "Ano",
    y = "Numero acumulado de escolas"
  ) +
  theme_minimal(base_size = 12)


################################################################################

### Salvar tabelas, series e graficos

################################################################################

write_csv(
  tabela_elegiveis_todos_anos,
  file.path(out_dir, "resumo_elegiveis_todos_anos.csv")
)

write_csv(
  tabela_elegiveis_algum_ano,
  file.path(out_dir, "resumo_elegiveis_algum_ano.csv")
)

write_csv(
  serie_elegiveis_todos_anos,
  file.path(out_dir, "serie_elegiveis_todos_anos.csv")
)

write_csv(
  serie_elegiveis_algum_ano,
  file.path(out_dir, "serie_elegiveis_algum_ano.csv")
)

ggsave(
  filename = file.path(out_dir, "serie_elegiveis_todos_anos.png"),
  plot = grafico_elegiveis_todos_anos,
  width = 9,
  height = 5.5,
  dpi = 300
)

ggsave(
  filename = file.path(out_dir, "serie_elegiveis_algum_ano.png"),
  plot = grafico_elegiveis_algum_ano,
  width = 9,
  height = 5.5,
  dpi = 300
)


################################################################################

### Mostrar os principais resultados no console

################################################################################

cat("\n=== ELEGIVEIS EM TODOS OS ANOS ===\n")
print(tabela_elegiveis_todos_anos)

cat("\n=== ELEGIVEIS EM PELO MENOS UM ANO ===\n")
print(tabela_elegiveis_algum_ano)

cat("\nArquivos gravados em:\n", out_dir, "\n")
