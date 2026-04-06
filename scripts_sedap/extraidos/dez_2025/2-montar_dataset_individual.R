################################################################################

###Montar painel com dados ao nível das matrículas

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
read_ids <- "T:/8. Intermediário/IDs/cpf_census_sub_bas"
out <- "T:/8. Intermediário/matched_matricula_cpf"
dir.create(out)

dir_ceb <- file.path(read, "CENSO_ESCOLAR/BAS_MATRICULA")




################################################################################

###Usar o duckdb para fazer join entre a tabela de ids e as tabelas de matricula

################################################################################

###Abrir conexão
con <- dbConnect(duckdb())

###Estabelecer limites de memória
dbExecute(con, "PRAGMA memory_limit = '15GB';")  # talvez possamos colocar 10-15 GB no sedap


###Criar views das tabelas de ids
dbExecute(con, sprintf("
  CREATE VIEW ids AS
  SELECT CPF_MASC
  FROM read_parquet('%s')
", read_ids)) 


###Criar views usando a tabela de 2007 como exemplo
dbExecute(con, sprintf("
  CREATE VIEW censo AS
  SELECT *
  FROM read_csv('%s/BAS_MATRICULA_2007.csv')
", dir_ceb)) 

###Fazer inner join, salvando os dados

dbExecute(con, sprintf("
  COPY (
    SELECT ids.CPF_MASC, censo.*
    FROM censo
    INNER JOIN ids
      ON ids.CPF_MASC = censo.CPF_MASC
      
    
  )
  TO '%s/cpf_matched_matricula_2007.parquet'
  (FORMAT PARQUET, OVERWRITE_OR_IGNORE);
", out)) ####34358499 cpf_masc



###Faremos um painel com cada um dos censos?
##Imagino que devamos juntar o censo da educação superior como uma "continuação"
#do censo da educação básica












