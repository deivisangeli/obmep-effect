################################################################################

###Adicionar numero de alunos por escola para cada nível da OBMEP e pib per capita

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

################################################################################

###Definir diretórios e listagem de arquivos

################################################################################

###Definir diretórios 
read_int <- "T:/9. Processado/escolas_obmep_censo.parquet"
census_dir <- "B:/CENSO_ESCOLAR/BAS_MATRICULA"
out <- "T:/8. Intermediário/matricula_escola"
dir.create(out)

################################################################################

###Estabelecer conexão com duckdb e carregar dados

################################################################################

###Abrir conexão
con <- dbConnect(duckdb())

###Estabelecer limites de memória
dbExecute(con, "PRAGMA memory_limit = '20GB';")  # talvez possamos colocar 10-15 GB no sedap





################################################################################

###Contar total de alunos por escola par a aamostra de interesse

################################################################################


year <- 2007:2016
schools_count <- list()
for(yr in year){
  ###Dados do censo
  dbExecute(con, sprintf("
  CREATE VIEW censo AS
  SELECT CO_ENTIDADE, ID_MATRICULA, TP_ETAPA_ENSINO, NU_ANO
  FROM read_csv('%s/BAS_MATRICULA_%s.csv')
  WHERE TP_DEPENDENCIA != 4 AND (TP_ETAPA_ENSINO BETWEEN 8 AND 11 OR TP_ETAPA_ENSINO BETWEEN 19 AND 38 OR TP_ETAPA_ENSINO == 41)
", census_dir, yr)) 
  
  
  
  ###Fazer inner join e contar quantos alunos temos de interesse temos por escola
  schools_count[[yr - 2006]] <- dbGetQuery(con, sprintf("

  SELECT CO_ENTIDADE, NU_ANO ,COUNT(DISTINCT ID_MATRICULA) AS total_matriculas
  FROM censo
  GROUP BY CO_ENTIDADE, NU_ANO

")) 
  
  ####Dropar view
  dbExecute(con, "DROP VIEW censo")
  
}    

###Bind_rows
total_alunos <- bind_rows(schools_count)

write_csv(total_alunos, file.path(out, "alunos_contagem_total.csv"))

################################################################################

###Contar total de alunos por escola que poderiam ter participado no nível 1

################################################################################

year <- 2007:2016
schools_count <- list()
for(yr in year){
  ###Dados do censo
  dbExecute(con, sprintf("
  CREATE VIEW censo AS
  SELECT CO_ENTIDADE, ID_MATRICULA, TP_ETAPA_ENSINO, NU_ANO
  FROM read_csv('%s/BAS_MATRICULA_%s.csv')
  WHERE TP_DEPENDENCIA != 4 AND (TP_ETAPA_ENSINO BETWEEN 8 AND 9 OR TP_ETAPA_ENSINO BETWEEN 19 AND 20)
", census_dir, yr)) 
  
  
  
  ###Fazer inner join e contar quantos alunos temos de interesse temos por escola
  schools_count[[yr - 2006]] <- dbGetQuery(con, sprintf("

  SELECT CO_ENTIDADE, NU_ANO ,COUNT(DISTINCT ID_MATRICULA) AS total_matriculas_nivel_I
  FROM censo
  GROUP BY CO_ENTIDADE, NU_ANO


")) 
  
  ####Dropar view
  dbExecute(con, "DROP VIEW censo")
  
}  


###Bind_rows
total_alunos <- bind_rows(schools_count)

write_csv(total_alunos, file.path(out, "alunos_contagem_nivel_I.csv"))



################################################################################

###Contar total de alunos por escola que poderiam ter participado no nível 2

################################################################################

year <- 2007:2016
schools_count <- list()
for(yr in year){
  ###Dados do censo
  dbExecute(con, sprintf("
  CREATE VIEW censo AS
  SELECT CO_ENTIDADE, ID_MATRICULA, TP_ETAPA_ENSINO, NU_ANO
  FROM read_csv('%s/BAS_MATRICULA_%s.csv')
  WHERE TP_DEPENDENCIA != 4 AND (TP_ETAPA_ENSINO BETWEEN 10 AND 11 OR TP_ETAPA_ENSINO == 21 or TP_ETAPA_ENSINO == 41)
", census_dir, yr)) 
  
  
  
  ###Fazer inner join e contar quantos alunos temos de interesse temos por escola
  schools_count[[yr - 2006]] <- dbGetQuery(con, sprintf("

  SELECT CO_ENTIDADE, NU_ANO ,COUNT(DISTINCT ID_MATRICULA) AS total_matriculas_nivel_II
  FROM censo
  GROUP BY CO_ENTIDADE, NU_ANO


")) 
  
  ####Dropar view
  dbExecute(con, "DROP VIEW censo")
  
}  


###Bind_rows
total_alunos <- bind_rows(schools_count)

write_csv(total_alunos, file.path(out, "alunos_contagem_nivel_II.csv"))


################################################################################

###Adicionar contagem aos dados finais

################################################################################

final_dt <- read_parquet("T:/8. Intermediário/escolas_obmep_censo.parquet")

###Abrir datasets com as contagens

files_contagem <- list.files(out, pattern = "^alunos_contagem_", full.names = T)

###Abrir arquivos
files <- list()
for( i in 1:length(files_contagem)){
  files[[i]] <- read.csv(files_contagem[i]) %>% as.data.table()
}

out <- Reduce(
  function(x,y) merge(x , y, by = c("CO_ENTIDADE", "NU_ANO"), all.x = T, all.y = T), files 
)

###Calcular nivel III
out[, total_matriculas_nivel_III := total_matriculas - 
      total_matriculas_nivel_II - total_matriculas_nivel_I]


###Juntar com final_dt
final_dt <- merge(final_dt, out, by = c("CO_ENTIDADE", "NU_ANO"), all.x = T)

###Remover escolas onde total_matriculas é NA
final_dt <- final_dt %>%
  filter(!is.na(total_matriculas) | participant == 1)


###Fazer tabela contando: Número de escolas elegiveis no ano, numero de escolas 
##participantes da obmep, share de escolas que partiparam por ano
sch <- final_dt[missing_census == 0, .(schools = uniqueN(CO_ENTIDADE)), by = NU_ANO]
sch_part <- final_dt[participant == 1 & missing_census == 0 , .(participants = uniqueN(CO_ENTIDADE)), by = NU_ANO]

sch <- left_join(sch, sch_part, by = "NU_ANO")

sch[, share := 100*participants/schools]

###Salvar csv
write_csv(sch, "T:/8. Intermediário/escolas_elegiveis_participantes.csv")

###Condicionar a missing_census == 0
final_dt <- final_dt %>%
  filter(missing_census == 0) %>% select(-missing_census)

table(is.na(final_dt$CO_MUNICIPIO))
head(final_dt$CO_MUNICIPIO)
################################################################################

###Adicionar dados de pib per capita

################################################################################
pib <- read.csv("T:/pib_per_capita_2002_2021.csv") %>% rename(NU_ANO = ANO) %>% as.data.table()
pib[, CODMUNIC := as.character(CODMUNIC)]
str(pib$CODMUNIC)
###Criar variável sem o ultimo digito do codigo do municipio
final_dt[, CO_MUNICIPIO := as.character(CO_MUNICIPIO)]
final_dt[, CODMUNIC := substr(CO_MUNICIPIO, 1, nchar(CO_MUNICIPIO) - 1)]

###Adicionar no final_dt 
final_dt <- merge(final_dt, pib %>% select(-Municipio), by = c("CODMUNIC", "NU_ANO"))


###Salvar dados finais
write_parquet(final_dt, "T:/9. Processado/painel_escolas.parquet")

length(unique(pib$Municipio))
####
final_dt <- read_parquet("T:/9. Processado/painel_escolas.parquet")
final_dt <- final_dt %>% distinct(CO_ENTIDADE, NU_ANO, .keep_all = T)
##Checar quantas escolas nunca deixam de ser tratadas
setorder(final_dt, NU_ANO, CO_ENTIDADE)


final_dt[, 
  {
  d <- .(monotone = any(participant == 1) && !any(diff(d) == -1), by = CO_ENTIDADE)
}]



