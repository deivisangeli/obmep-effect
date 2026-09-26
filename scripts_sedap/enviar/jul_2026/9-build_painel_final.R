
setwd("T:/")
###Carregar pacotes

rm(list = ls());gc()

library(tidyverse)
library(data.table)
library(duckdb)
library(readr)
library(glue)
library(arrow)
library(DBI)

con <- dbConnect(duckdb())
dbExecute(con, "PRAGMA memory_limit='25GB'")

dbExecute(con, "
COPY (
  WITH painel AS (
    SELECT *
    FROM read_parquet('T:/9. Processado/sample_raw_com_idcb_cpf.parquet')
  ),
  
  sup AS (
    SELECT *,
    FROM read_parquet('T:/9. Processado/sup_outcomes.parquet')
  ),
  -- Crosswalk com os participantes com a dummy de acima da mediana STEM, juntamente com o primeiro ano em que o participante tirou uma nota acima da mediana STEM
  sup_enem AS (
    SELECT *
    FROM read_parquet('T:/8. Intermediário/ingressantes_acima_mediana_stem.parquet')
  )
  ,
  RAIS AS (
  SELECT CPF_MASC, first(ever_stem) AS ever_stem, 
  first(ever_hard_science) AS ever_hard_science, 
  first(ever_research) AS ever_research,
  first(ever_finance_core) AS ever_finance_core, 
  MAX(max_wage_acum) AS max_wage
  FROM read_parquet('T:/9. Processado/rais_variables')
  GROUP BY (CPF_MASC)
  ),
  sit AS (
  SELECT *
  FROM read_parquet('T:/9. Processado/situation_variables')
  )

  SELECT * EXCLUDE (se.acima_mediana_stem), 
  COALESCE(se.acima_mediana_stem, 0) AS acima_mediana_stem
  FROM painel p
  LEFT JOIN sup s
    ON p.CPF_MASC_FINAL = s.CPF_MASC
  LEFT JOIN RAIS r
    ON p.CPF_MASC_FINAL = r.CPF_MASC
  LEFT JOIN sit st
  USING (id_cb)

  --Left join com a crosswalk de acima da mediana DTEM
  LEFT JOIN sup_enem se
    ON p.CPF_MASC_FINAL = se.CPF_MASC AND
    se.primeiro_ano_acima_mediana_stem IN (p.ULTIMO_ANO + 4,p.ULTIMO_ANO + 5, p.ULTIMO_ANO + 6)

) TO 'T:/9. Processado/painel_final_v2.parquet' (FORMAT PARQUET)
")


####ENEM no ultimo ano do ensino médio







