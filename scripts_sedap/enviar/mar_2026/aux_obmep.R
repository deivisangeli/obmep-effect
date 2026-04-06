################################################################################

## Variável que indica o ano do primeiro tratamento no nível I da OBMEP  
## Porcentagem de escolas que começam a participar no nível I e param

################################################################################

###Carregar pacotes

rm(list = ls());gc()

library(tidyverse)


################################################################################

###Definir diretórios e listagem de arquivos

################################################################################

###Definir diretórios gerais
read_ext <- "T:/1. Bases_Externas/Bases_escolas_premiados"


###Definir diretórios

##OBMEP
dir_obmep <- file.path(read_ext, "Info_escolas_obmep_por_nivel_solicitacao_Deivis.csv")


################################################################################

###Análises

################################################################################

df <- df %>%
  mutate(participou = if_else(NR_INSCRITOS_1_FASE > 0, 1, 0, missing = 0))


primeira_participacao <- df %>%
  filter(nivel == "I", participou == 1) %>%
  group_by(CO_ENTIDADE) %>%
  summarise(ano_primeira_participacao_I = min(ano), .groups = "drop")


df <- df %>%
  left_join(primeira_participacao, by = "CO_ENTIDADE")


hist_escolas <- df %>%
  filter(nivel == "I") %>%
  arrange(CO_ENTIDADE, ano) %>%
  group_by(CO_ENTIDADE) %>%
  summarise(
    serie_participacao = list(participou),
    .groups = "drop"
  )



conta_paradas <- function(x) {
  sum(diff(x) == -1, na.rm = TRUE)
}


hist_escolas <- hist_escolas %>%
  mutate(n_paradas = purrr::map_int(serie_participacao, conta_paradas))


hist_escolas <- hist_escolas %>%
  mutate(ja_participou = purrr::map_lgl(serie_participacao, ~ any(.x == 1))) %>%
  filter(ja_participou)


resultado <- hist_escolas %>%
  summarise(
    total = n(),
    pct_parou_1_vez = mean(n_paradas >= 1),
    pct_parou_2_vezes = mean(n_paradas >= 2),
    pct_parou_3_vezes = mean(n_paradas >= 3)
  )









