################################################################################

###Esse script é um exemplo de como fazer um join entre duas bases grande usando
##duckdb

##Eu uso os microdados de 2011, os quais são grandes o bastante para não caber na 
##minha ram

################################################################################

rm(list = ls());gc()
###Define path
db_path <- Sys.getenv("db_path") ###Dropbox path
gtl_path <- Sys.getenv("gtl_path") ###githb file path


gtalloc_path <- file.path(db_path, "GTAllocation") ###GT allocation folder path
##Load packages
pacman ::p_load(tidyverse, RAthena, DBI, readr, reticulate, readxl, writexl, 
                dbplyr, glue, arrow, aws.s3, bit64, shiny, stargazer, gt, httr,
                jsonlite, furrr, stringdist, tictoc, foreach, doParallel, stringr,
                fuzzyjoin, purrr, data.table, Hmisc, patchwork, progress, haven, rdrobust, 
                nprobust, openalexR, bit64, future, future.apply, pryr, duckdb, dtplyr)

###Abrir conexão do duckDB
con <- dbConnect(duckdb())

################################################################################

###Dividir microdados em buckets

################################################################################
dir_in  <- file.path(db_path, "OBMEP/data/raw/schoolcensus/microdados_2011/DADOS")
dir_out <- file.path(db_path, "OBMEP/test/microdados_test")
dir.create(dir_out)

con <- dbConnect(duckdb())
# define limite de memória
dbExecute(con, "PRAGMA memory_limit = '4GB';")  # talvez possamos colocar 10-15 GB no sedap

dbExecute(con, sprintf("
  COPY (
    SELECT *,
           (PK_COD_MATRICULA %% 100 + 1) AS bucket
    FROM read_parquet('%s/ts_matricula_*.parquet')
  )
  TO '%s/original_bucketed'
  (FORMAT PARQUET, PARTITION_BY bucket, OVERWRITE_OR_IGNORE);
", dir_in, dir_out))


###Fazer o mesmo para os dados amostrados
# Para os dados da amostra (supondo que já exista sample parquet)
sample_parquet <- file.path(db_path, "OBMEP/test/ts_matricula_sample20_full.parquet")
dir_out <- file.path(db_path, "OBMEP/test/sample_test")
dir.create(dir_out)

dbExecute(con, sprintf("
  COPY (
    SELECT *,
           (PK_COD_MATRICULA %% 100 + 1) AS bucket
    FROM read_parquet('%s')
  )
  TO '%s/sample_bucketed'
  (FORMAT PARQUET, PARTITION_BY bucket, OVERWRITE_OR_IGNORE);
", sample_parquet, dir_out))


################################################################################

###Preparar o inner join, utilizando a estrutuda particionada

################################################################################

dir_out <- file.path(db_path, "OBMEP/test")
orig_base    <- file.path(dir_out, "microdados_test/original_bucketed")  # onde os buckets do original estão
sample_base  <- file.path(dir_out, "sample_test/sample_bucketed")    # onde os buckets da sample estão
out_join_dir <- file.path(dir_out, "joined_by_bucket")

if (!dir.exists(out_join_dir)) dir.create(out_join_dir, recursive = TRUE)

for (b in 1:100) {
  message("Processing bucket ", b, " ...")
  
  orig_pattern   <- sprintf("%s/bucket=%d/*.parquet", orig_base, b)
  sample_pattern <- sprintf("%s/bucket=%d/*.parquet", sample_base, b)
  out_file       <- sprintf("%s/join_bucket_%03d.parquet", out_join_dir, b)
  
  sql <- sprintf("
    COPY (
      SELECT o.*, s.*
      FROM read_parquet('%s') AS o
      INNER JOIN read_parquet('%s') AS s
        ON o.PK_COD_MATRICULA = s.PK_COD_MATRICULA
    ) TO '%s' (FORMAT PARQUET);
  ", orig_pattern, sample_pattern, out_file)
  
  dbExecute(con, sql)
}

ds <- open_dataset(out_join_dir)
colnames(ds)
nrow(ds)

################################################################################

###No SEDAP, pretendo fazer o merge entre censo escolar e o censo da educação superior
##usando o CPF

################################################################################

###Key: CPF_Masc (Checar se realmente é valido, testar com CO_Pessoa_Fisica (ID_Inep))

###Separar censo escolar e censo da ES em buckets













