
################################################################################

## Seleção de amostra para primeiro exercício de Event Study       
## Painel de matrículas no 6º e 7º ano de escolas públicas

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
library(fs)

################################################################################

###Definir diretórios e listagem de arquivos

################################################################################

###Definir diretórios gerais
out  <- "T:/8. Intermediário"



con <- dbConnect(duckdb())
dbExecute(con, "PRAGMA memory_limit='15GB'")

################################################################################

###Checks
###Verificar a porcentagem de CO_PESSOA_FISICA que conclui cada ano em apenas uma escola

################################################################################

resultado_ano <- dbGetQuery(con, "
WITH base AS (
  SELECT
    CO_PESSOA_FISICA,
    NU_ANO,
    CO_ENTIDADE
  FROM read_csv(
    'B:/CENSO_ESCOLAR/BAS_MATRICULA/BAS_MATRICULA_*.csv',
    encoding = 'latin-1',
    union_by_name = TRUE
  )
  WHERE
    NU_ANO BETWEEN 2007 AND 2016
    AND TP_ETAPA_ENSINO IN (8,9,19,20)
    AND TP_DEPENDENCIA != 4
    AND CO_PESSOA_FISICA IS NOT NULL
),

contagem AS (
  SELECT
    CO_PESSOA_FISICA,
    NU_ANO,
    COUNT(DISTINCT CO_ENTIDADE) AS n_escolas
  FROM base
  GROUP BY CO_PESSOA_FISICA, NU_ANO
)

SELECT
  NU_ANO,
  COUNT(*) AS total_aluno_ano,
  AVG(CASE WHEN n_escolas = 1 THEN 1.0 ELSE 0 END) AS pct_uma_escola,
  AVG(CASE WHEN n_escolas > 1 THEN 1.0 ELSE 0 END) AS pct_multiplas_escolas
FROM contagem
GROUP BY NU_ANO
ORDER BY NU_ANO
")









