###################################################################################################################

###Fuzzy match between censuses

###################################################################################################################

rm(list = ls());gc()
###Carregar pacotes
library(tidyverse)
library(data.table)
library(duckdb)
library(readr)
library(glue)
library(arrow)
library(DBI)
library(bit64)

###################################################################################################################
### Connect DuckDB
###################################################################################################################

con <- dbConnect(duckdb())

# data <- ceb_ds %>%  filter(!is.na(CPF_MASC)) %>% select(CPF_MASC) %>% collect()

dbExecute(con, "PRAGMA memory_limit = '15GB';")  # talvez possamos colocar 10-15 GB no sedap
#dbExecute(con, "PRAGMA threads=8;")
#dbExecute(con, "PRAGMA enable_object_cache;")

###################################################################################################################

###Carregar e pre-processar nomes: Censo básico (Opcional, pq é mais pesado)

###################################################################################################################

cb_path <- ""
hes_path <- ""

cb <- open_dataset(cb_path, format = "csv")
batch_size <- 1e6
out_path <- "cb_clean.parquet"

if (file.exists(out_path)) file.remove(out_path)

cb |>
  mutate(row_id = row_number()) |>
  collect() |>
  split(ceiling(seq_len(n()) / batch_size)) |>
  walk(function(chunk) {

    dt <- as.data.table(chunk)

    dt[, name_clean := standardize_name(name)]

    write_parquet(
      dt,
      out_path,
      append = file.exists(out_path)
    )

    rm(dt); gc()
  })

####################################################################################################################
### Create cleaned copies (CTE to avoid recomputation) - Recomendado, se funcionar bem
###################################################################################################################

clean_sql <- "
  lower(
    trim(
      regexp_replace(
        regexp_replace(
          unaccent(name),
          '[^a-zA-Z ]',
          '',
          'g'
        ),
        '\\\\s+',
        ' ',
        'g'
      )
    )
  )
"

dbExecute(con, glue("
  CREATE OR REPLACE TABLE cb_clean AS
  WITH base AS (
    SELECT
      *,
      {clean_sql} AS name_clean
    FROM cb_raw
  )
  SELECT
    *,
    substr(split_part(name_clean, ' ', 1), 1, 1) AS first_initial
  FROM base;
"))

dbExecute(con, glue("
  CREATE OR REPLACE TABLE hes_clean AS
  WITH base AS (
    SELECT
      *,
      {clean_sql} AS name_clean
    FROM hes_raw
  )
  SELECT
    *,
    substr(split_part(name_clean, ' ', 1), 1, 1) AS first_initial
  FROM base;
"))

###################################################################################################################
### Blocking join: birth_date + UF + name initial (Vou ter que renomear as colunas, mas a logica está correta)
###################################################################################################################

dbExecute(con, "
  CREATE OR REPLACE TABLE candidates AS
  SELECT
    a.id AS id_cb,
    b.id AS id_hes,
    a.name_clean AS name_cb,
    b.name_clean AS name_hes
  FROM cb_clean a
  JOIN hes_clean b
    ON a.birth_date    = b.birth_date
   AND a.uf            = b.uf
   AND a.first_initial = b.first_initial;
")

###################################################################################################################
### Fuzzy match (Jaro similarity) - Vamos ver a qualidade do recall, pode ser bom evoluir para incluir um substring match com o que sobrar, ou tirar os buckets por nome
###################################################################################################################

dbExecute(con, "
  CREATE OR REPLACE TABLE scored AS
  SELECT *,
         jaro_similarity(name_cb, name_hes) AS sim
  FROM candidates
  WHERE jaro_similarity(name_cb, name_hes) >= 0.90;
")

###################################################################################################################
### Keep best match per CB id - Já mantém o melhor match, talvez seha interessante manter uns 5 para cada estudante no censo básico?
###################################################################################################################

dbExecute(con, "
  CREATE OR REPLACE TABLE best_match AS
  SELECT *
  FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY id_cb ORDER BY sim DESC) AS rn
    FROM scored
  )
  WHERE rn = 1;
")

###################################################################################################################
### Export result
###################################################################################################################

dbExecute(con, "
  COPY best_match TO 'best_match.parquet' (FORMAT PARQUET);
")







