##########################################################################################################################################################

### Arrumando variavel de part_2005

##########################################################################################################################################################
###Carregar pacotes

rm(list = ls());gc()

library(tidyverse)
library(data.table)
library(duckdb)
library(readr)
library(glue)
library(arrow)
library(DBI)
library(bit64)

################################################################################

###Definir diretórios e listagem de arquivos

################################################################################

###Definir diretórios gerais
read <- "B:"
read_ext <- "T:/1. Bases_Externas/Bases_escolas_premiados"
out <- "T:/8. Intermediário/match_escolas_obmep_censo"
dir.create(out)

###Abrir dataset
obmep <- fread(dir_obmep)

###################################################################################

###Montar part_2005 ao nivel da escola-nivel obmep

###################################################################################

###Normalizar colunas
sch_2005 <- obmep %>% rename(CO_ENTIDADE = CODIGO_INEP, NO_ESCOLA = NOME_ESCOLA, NU_ANO = EDICAO_ANO) %>%
  filter(TIPO_ESCOLA == "PUBLICA" & NU_ANO == 2005) %>% distinct(CO_ENTIDADE, NIVEL_OBMEP, NU_INSCRITOS_1_FASE)

###Montar dummy
sch_2005[, part_2005_nivel := fifelse(NU_INSCRITOS_1_FASE > 0 & !is.na(NU_INSCRITOS_1_FASE), 1, 0)]

###Merge com os dados finais
dir_panel <- "path do painel que você estava usando"

panel <- fread(dir_panel)

###Merge
panel <- merge(panel, sch_2005, by = c("CO_ENTIDADE", "NIVEL_OBMEP"))



