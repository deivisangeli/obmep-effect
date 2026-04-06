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



duracao_primeiro_spell <- function(x) {
  
  # encontrar primeira participação
  start <- which(x == 1)[1]
  
  if (is.na(start)) return(NA_integer_)
  
  # pegar a série a partir da entrada
  sub <- x[start:length(x)]
  
  # contar quantos 1 consecutivos até o primeiro 0
  # (ou até o fim)
  dur <- rle(sub)$lengths[1]
  
  return(dur)
}



hist_escolas <- hist_escolas %>%
  mutate(
    duracao_spell = purrr::map_int(serie_participacao, duracao_primeiro_spell)
  )


hist_escolas <- hist_escolas %>%
  left_join(primeira_participacao, by = "CO_ENTIDADE")


hist_escolas <- hist_escolas %>%
  mutate(
    grupo_duracao = case_when(
      duracao_spell == 1 ~ "1_ano",
      duracao_spell == 2 ~ "2_anos",
      duracao_spell >= 3 ~ "3+_anos"
    )
  )


resultado_coorte <- hist_escolas %>%
  filter(!is.na(ano_primeira_participacao_I)) %>%
  group_by(ano_primeira_participacao_I) %>%
  summarise(
    total = n(),
    share_1_ano = mean(duracao_spell == 1),
    share_2_anos = mean(duracao_spell == 2),
    share_3_ou_mais = mean(duracao_spell >= 3),
    .groups = "drop"
  )



df <- df %>%
  mutate(
    tem_nivel_I = if_else(!is.na(matriculas_nivel_I) & matriculas_nivel_I > 0, 1, 0)
  )


escolas_2007_2016 <- df %>%
  filter(ano >= 2007, ano <= 2016, tem_nivel_I == 1) %>%
  distinct(CO_ENTIDADE)


hist_2007_2016 <- hist_escolas %>%
  semi_join(escolas_2007_2016, by = "CO_ENTIDADE")





