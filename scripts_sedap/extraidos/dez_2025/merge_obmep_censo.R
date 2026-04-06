################################################################################

###Match de escolas da OBMEP com as do censo

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
library(bit64)

################################################################################

###Definir diretórios e listagem de arquivos

################################################################################

###Definir diretórios gerais
read <- "B:"
read_ext <- "T:/1. Bases_Externas/Bases_escolas_premiados"
out <- "T:/8. Intermediário/match_escolas_obmep_censo"
dir.create(out)


###Definir diretórios
##Censo escolar
dir_ceb <- file.path(read, "CENSO_ESCOLAR/BAS_ESCOLA")

##OBMEP
dir_obmep <- file.path(read_ext, "Info_escolas_obmep_por_nivel_solicitacao_Deivis.csv")



###Carregar dados da obmep

obmep <- fread(dir_obmep)
colnames(obmep)
###Normalizar colunas
obmep <- obmep %>% rename(CO_ENTIDADE = CODIGO_INEP, NO_ESCOLA = NOME_ESCOLA, NU_ANO = EDICAO_ANO) %>%
  filter(TIPO_ESCOLA == "PUBLICA") 
colnames(obmep)
setDT(obmep)
yr <- 2007:2016

###Adicionar sufixo OBMEP

#Colunas para renomear

cols_rename_obmep <- setdiff(names(obmep), c("CO_ENTIDADE", "NU_ANO"))

###Renomear coluns
setnames(obmep, cols_rename_obmep, paste0(cols_rename_obmep, "_OBMEP"))


for(i in yr){
  census <- fread(file.path(dir_ceb, paste0("BAS_ESCOLA_", i, ".csv")))
  
  ed <- obmep %>% filter(NU_ANO == i)
  
  ###Renomear colunas
  
  dt <- merge(ed, census, by = c("CO_ENTIDADE", "NU_ANO"), all.y = T, all.x = T) ###Full join
  dt[, missing_census := fifelse(is.na(NO_ENTIDADE), 1, 0)]
  ###Adicionar dummy de participação na OBMEP
  dt[, participant := fifelse(!is.na(NO_ESCOLA_OBMEP), 1, 0)]
  
  write_csv(dt ,file.path(out, paste0("merged_obmep_census_", i, ".csv")))
  
  rm(census, ed, dt)
  
}


ds <- open_dataset(out, format = "csv")

ds %>% filter(missing_census == 0) %>% distinct(CO_ENTIDADE) %>% collect() %>% count()

###75866 escolas pareadas

dt <- data.table(Year = NA, CO_ENTIDADE = NA)
for(i in yr){
  ed <- obmep %>% filter(NU_ANO == i) %>% distinct(CO_ENTIDADE) 
  ed[, Year := i]
  
  dt <- rbind(dt, ed)
  
  
  
}





################################################################################

###Unir todos os datasets

################################################################################

merged <- list.files(out, full.names = T)

final <- list()
for(i in 1:length(merged)){
  dt <-  fread(merged[i])
  ###Converter todas as colunas logical para character
  #logi_cols <- names(which(sapply(dt, is.logical)))
  all_cols <- names(dt)
  dt[, (all_cols) :=  lapply(.SD, as.character), .SDcols = all_cols]
  
  final[[i]] <- dt
  rm(dt)
}
colnames(final[[1]])

final_dt <- bind_rows(final)

rm(final);gc()
################################################################################

###Arrumar formato de dados finais

################################################################################

##Selecionar colunas que são int64
census <- fread(file.path(dir_ceb, paste0("BAS_ESCOLA_", 2016, ".csv")))


int64_cols <- c(names(which(sapply(census, is.integer64))), 
                names(which(sapply(obmep, is.integer64))))
colnames(final_dt)
###Colunas para transformar em integer
int_cols <- setdiff(names(final_dt)[c(1:4, 10:12, 14:length(names(final_dt)))], 
                    int64_cols)
colnames(final_dt)
###Transformar colunas
final_dt[, (int_cols) := lapply(.SD, as.integer), .SDcols = int_cols]

str(final_dt)

################################################################################

###Adicionar duyummy para any_participation

################################################################################
final_dt[, any_participation := as.integer(any(participant == 1)), by = "CO_ENTIDADE"]

summary(final_dt$any_participation)

###Salvar dados finais
write_parquet(final_dt, "T:/8. Intermediário/escolas_obmep_censo.parquet")


################################################################################

###Adicionar dummy indicando se  a escola participou da obmep em 2005

################################################################################
###Abrir arquivo
final_dt <- read_parquet("T:/8. Intermediário/escolas_obmep_censo.parquet") 

obmep <- fread(dir_obmep) %>% rename(CO_ENTIDADE = CODIGO_INEP, NO_ESCOLA = NOME_ESCOLA, NU_ANO = EDICAO_ANO) %>%   
  filter(TIPO_ESCOLA == "PUBLICA")
colnames(obmep)
###Normalizar colunas
sch_2005 <- obmep %>% rename(CO_ENTIDADE = CODIGO_INEP, NO_ESCOLA = NOME_ESCOLA, NU_ANO = EDICAO_ANO) %>%
  filter(TIPO_ESCOLA == "PUBLICA" & NU_ANO == 2005) %>% distinct(CO_ENTIDADE) %>% pull()


###Dummy para o caso de já ter entrado em 2005
final_dt[, part_2005 := fifelse(CO_ENTIDADE %in% sch_2005, 1, 0 )]

###Salvar dados finais
write_parquet(final_dt, "T:/8. Intermediário/escolas_obmep_censo.parquet")

####Quantas escolas participaram da obmep, por ano
summary(final_dt$part_2005) ###37%

test <- final_dt %>%
  sample_n(50)


final_dt %>% filter(!is.na(GEO_REF_LATITUDE)) %>% head(10) %>% select(GEO_REF_LATITUDE)

str(final_dt$CO_ENTIDADE)

###SUmmarise per year



sch_by_year <- final_dt[participant == 1 & missing_census == 0, .(in_census = uniqueN(CO_ENTIDADE)), by = NU_ANO]

###Quantas escolas participantes estão fora do censo
missing_schools <- final_dt[participant == 1 & missing_census == 1, .(missing_census = uniqueN(CO_ENTIDADE)), by = NU_ANO]

###Juntar
sch_by_year <- left_join(sch_by_year, missing_schools, by = "NU_ANO")


###Save data
write_csv(sch_by_year,  "T:/8. Intermediário/escolas_participantes_no_censo.csv")













