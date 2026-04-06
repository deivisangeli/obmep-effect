################################################################################

###Esse script fará o merge entre os censos escolares para os participants com cpf
##

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

################################################################################

###Definir diretórios e listagem de arquivos

################################################################################

###Definir diretórios gerais
read <- "B:"
out <- "T:/8. Intermediário"


###Definir diretórios
###Básico
dir_ceb <- file.path(read, "CENSO_ESCOLAR/BAS_MATRICULA")

###Educação Superior
dir_ces <- file.path(read, "CENSO_SUPERIOR/SUP_ALUNO")

###Listar arquivos csv
files_ceb <- list.files(dir_ceb, pattern = "^BAS_MATRICULA_", full.names = T)
files_ces <- list.files(dir_ces, pattern = "^SUP_ALUNO_", full.names = T)

###Definir diretórios de saída
ces_buckets <- file.path(out, "matricula_ces")
dir.create(ces_buckets)

ceb_buckets <- file.path(out, "matricula_ceb")
dir.create(ceb_buckets)

################################################################################

###Montar dataset do arrow: Checar colunas disponíveis em cada dataset

################################################################################

ceb_ds <- open_delim_dataset(files_ceb, delim = ";")
colnames(ceb_ds)
ces_ds <- open_delim_dataset(files_ces, delim = ";")
colnames(ces_ds)


schema(ceb_ds)
###Open duckdb connection
con <- dbConnect(duckdb())

# data <- ceb_ds %>%  filter(!is.na(CPF_MASC)) %>% select(CPF_MASC) %>% collect()

dbExecute(con, "PRAGMA memory_limit = '15GB';")  # talvez possamos colocar 10-15 GB no sedap



################################################################################

###Montar datasets: Transformar CPF_MASC em hashes, montar 128 buckets e salvar 
##no diretório correspondente

################################################################################

###Educação superior

dbExecute(con, sprintf("
  COPY (
    SELECT DISTINCT CO_PESSOA_FISICA, CPF_MASC, CO_MUNICIPIO_NASCIMENTO, DT_NASCIMENTO,
           (hash(CPF_MASC) %% 128 + 1) AS bucket
    FROM read_csv('%s/SUP_ALUNO_*.csv')
    WHERE CPF_MASC is not NULL
  )
  TO '%s/matricula_ces'
  (FORMAT PARQUET, PARTITION_BY bucket, OVERWRITE_OR_IGNORE);
", dir_ces, out)) ####34358499 cpf_masc

####Test
ds <- open_dataset(file.path(out, "matricula_ces"))
colnames(ds)

ds %>% head() %>% collect()


###Extrair coluna de cpf_masc do censo básico e salvar como vários parquet para cada edição

###Amostra de interesse: Alunos que fizeram do 6 ao 3 ano do ensino médio em escolas públicas

yr <- 2007:2024
for(i in yr){
  dbExecute(con, sprintf("
  COPY (
    SELECT CO_PESSOA_FISICA, ID_MATRICULA ,CPF_MASC, DT_NASCIMENTO, CO_MUNICIPIO_NASC , NU_ANO 
    FROM read_csv('%s/BAS_MATRICULA_%s.csv')
    WHERE TP_DEPENDENCIA != 4 AND (TP_ETAPA_ENSINO BETWEEN 8 AND 11 OR TP_ETAPA_ENSINO BETWEEN 19 AND 38 OR TP_ETAPA_ENSINO == 41)
  )
  TO '%s/cpf_masc_censo_basico/cpf_bas_%s.parquet'
  (FORMAT PARQUET, OVERWRITE_OR_IGNORE);
", dir_ceb, i ,out, i))
} 





##Definir novo diretório
cpf_bas_dir <- file.path(out, "cpf_masc_censo_basico")

####Contar quantos alunos temos
count_entries <- dbGetQuery(con, sprintf("

    SELECT COUNT(DISTINCT CO_PESSOA_FISICA ) AS count_inep_code,
    COUNT(DISTINCT ID_MATRICULA) AS count_id_matricula,
    COUNT(DISTINCT CPF_MASC ) AS count_cpf_masc
    FROM read_parquet('%s/cpf_bas_*.parquet')
    WHERE NU_ANO BETWEEN 2007 AND 2016

", cpf_bas_dir))

###Calculate share 
print(count_entries$count_cpf_masc/count_entries$count_inep_code) ###63% têm cpf


###Total de código INEP:	53245460
###Total de ID Matrícula: 142218055
###Total com CPF: 33640128

##Number of rows
count_row <- dbGetQuery(con, sprintf("


    SELECT COUNT(DISTINCT CO_PESSOA_FISICA) AS count_id_matricula

    FROM read_parquet('%s/cpf_bas_*.parquet')
    WHERE NU_ANO BETWEEN 2007 AND 2016 AND CPF_MASC is NULL

", cpf_bas_dir))


####Sem entradas onde CO_PESSOA_FISICA é nula
##Co_PESSOA_FISICA - Pode ter missing
##ID_MATRICULA

###Contar quantos possuem cpf


###Obter percentual com cpf por ano

###Contar missing de CO_PESSOA_FISICA, ID_MATRICULA e CPF_MASC para cada ano

###Prosseguir para o match





test <- open_dataset(file.path(out, "cpf_masc_censo_basico/cpf_bas_2007.parquet" ))

test %>% head() %>% collect()


###Montar hashes e separar em bucket
##Definir novo diretório
cpf_bas_dir <- file.path(out, "cpf_masc_censo_basico")

dbExecute(con, sprintf("
  COPY (
    SELECT CPF_MASC, DT_NASCIMENTO, CO_MUNICIPIO_NASC , MIN(NU_ANO) AS min_ANO, CO_PESSOA_FISICA,
           (hash(CPF_MASC) %% 128 + 1) AS bucket
    FROM read_parquet('%s/cpf_bas_*.parquet')
        WHERE CPF_MASC is not NULL
    GROUP BY CPF_MASC, bucket, DT_NASCIMENTO, CO_MUNICIPIO_NASC, bucket, CO_PESSOA_FISICA

  )
  TO '%s/matricula_ceb'
  (FORMAT PARQUET, PARTITION_BY bucket, OVERWRITE_OR_IGNORE);
", cpf_bas_dir, out)) ####45602024 cpf_masc


test <- open_dataset(file.path(out, "matricula_ceb"))
test %>% head() %>% collect()
################################################################################

###Fazer inner join

################################################################################

###Definir diretórios
#Educação básica
cpf_ceb <- file.path(out, "matricula_ceb")
#Educação superior
cpf_ces <- file.path(out, "matricula_ces")

#Diretório final
matched_cpf_dir <- file.path(out, "matched_cpf")
dir.create(matched_cpf_dir)


###Fazer inner join por buckets
for (b in 1:128){
  message("Processing bucket ", b, " ...")
  
  bas_pattern   <- sprintf("%s/bucket=%d/*.parquet", cpf_ceb, b)
  sup_pattern <- sprintf("%s/bucket=%d/*.parquet", cpf_ces, b)
  out_file       <- sprintf("%s/bucket_%d.parquet", matched_cpf_dir, b)
  
  sql <- sprintf("
    COPY (
      SELECT o.*, s.*
      FROM read_parquet('%s') AS o
      INNER JOIN read_parquet('%s') AS s
        ON o.CPF_MASC = s.CPF_MASC
    ) TO '%s' (FORMAT PARQUET);
  ", bas_pattern, sup_pattern, out_file)
  
  dbExecute(con, sql)
  
  
}

###test
check <- open_dataset(matched_cpf_dir)

colnames(check)
###Quantos matches nós temos?

count_row <- dbGetQuery(con, sprintf("


    SELECT COUNT(DISTINCT CPF_MASC) AS count_cpf

    FROM read_parquet('%s/bucket_*.parquet')
    WHERE min_ANO BETWEEN 2007 AND 2016

", matched_cpf_dir)) ###11966517 ###22.5%

###Total de código INEP:	53245460



###Check how many unique cpf_masc have distinct values for birth dates


birth <- dbGetQuery(con, sprintf("


    SELECT COUNT(DISTINCT CPF_MASC) AS count_cpf

    FROM read_parquet('%s/bucket_*.parquet')
    WHERE min_ANO BETWEEN 2007 AND 2016 AND DT_NASCIMENTO != DT_NASCIMENTO_1

", matched_cpf_dir)) ###233160 discrepancies in birth dates

city <- dbGetQuery(con, sprintf("


    SELECT COUNT(DISTINCT CPF_MASC) AS count_cpf

    FROM read_parquet('%s/bucket_*.parquet')
    WHERE min_ANO BETWEEN 2007 AND 2016 AND CO_MUNICIPIO_NASC != CO_MUNICIPIO_NASCIMENTO

", matched_cpf_dir)) ###2527213 discrepancies in birth dates

###Check discrepancies on CO_PESSOA_FISICA
id_inep <- dbGetQuery(con, sprintf("


    SELECT COUNT(DISTINCT CPF_MASC) AS count_cpf

    FROM read_parquet('%s/bucket_*.parquet')
    WHERE min_ANO BETWEEN 2007 AND 2016 AND CO_PESSOA_FISICA != CO_PESSOA_FISICA_1

", matched_cpf_dir)) ###11966517 - Ninguem tém códigos INEP batendo


################################################################################

###Save unique CPFs on a separate folder

################################################################################
unique_ids <- file.path(out, "IDs")
dir.create(unique_cpfs)



dbExecute(con, sprintf("
  COPY (
    SELECT DISTINCT CPF_MASC,
           (hash(CPF_MASC) %% 128 + 1) AS bucket
    FROM read_parquet('%s/bucket_*.parquet')
    WHERE min_ANO BETWEEN 2007 AND 2016
  )
  TO '%s/cpf_census_sub_bas'
  (FORMAT PARQUET, PARTITION_BY bucket, OVERWRITE_OR_IGNORE);
", matched_cpf_dir, unique_ids)) ####11966517



