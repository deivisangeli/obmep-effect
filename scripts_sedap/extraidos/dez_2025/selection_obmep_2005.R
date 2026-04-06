
################################################################################

###Script para estudar os preditores da entrada na OBMEP em 2005

################################################################################

###Carregar pacotes

rm(list = ls());gc()

library(tidyverse)
library(data.table)
library(duckdb)
library(readr)
library(glue)
library(arrow)
library(DBI)
library(dtplyr)
library(Hmisc)

################################################################################

painel.escolas <- read_parquet("T:9. Processado/painel_escolas.parquet")

inscritos.nivel.ano <-
  painel.escolas %>% 
  select(NU_ANO, CO_ENTIDADE, NIVEL_OBMEP, NR_ALUNOS_INSCRITOS_1A_FASE_OBMEP) %>% 
  mutate(NR_ALUNOS_INSCRITOS_1A_FASE_OBMEP = replace_na(NR_ALUNOS_INSCRITOS_1A_FASE_OBMEP, 0)) %>% 
  filter(NR_ALUNOS_INSCRITOS_1A_FASE_OBMEP > 0) %>% 
  group_by(NU_ANO, NIVEL_OBMEP) %>% 
  summarise(total_escolas_inscritas = n())

  
  
escolas.nivel.ano <- 
  painel.escolas %>% 
  select(NU_ANO, CO_ENTIDADE, total_matriculas_nivel_I, total_matriculas_nivel_II, total_matriculas_nivel_III) %>%
  distinct(NU_ANO, CO_ENTIDADE, .keep_all = T) %>% 
  pivot_longer(cols = starts_with("total_matriculas"), names_to = "nivel", values_to = "total_matriculas") %>% 
  mutate(total_matriculas = replace_na(total_matriculas, 0)) %>% 
  filter(total_matriculas > 0) %>% 
  group_by(NU_ANO, nivel) %>% 
  summarise(total_escolas = n())
  











