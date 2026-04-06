
################################################################################

## Seleção de amostra para primeiro exercício de Event Study       
## Painel de matrículas no 6º e 7º ano

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

anos <- 2007:2016

for (ano in anos) {
  
  cat("Processando ano:", ano, "\n")
  
  path_mat <- glue("B:/CENSO_ESCOLAR/BAS_MATRICULA/BAS_MATRICULA_{ano}.csv")
  path_sit <- glue("B:/CENSO_ESCOLAR/BAS_SITUACAO/BAS_SITUACAO_{ano}.csv")
  
  # -------------------------------
  # 1. Matrícula (maio)
  # -------------------------------
  
  dbExecute(con, glue("
  CREATE OR REPLACE TABLE mat_{ano} AS
  SELECT *
  FROM read_csv('{path_mat}', encoding='latin-1', union_by_name=TRUE)
  WHERE TP_ETAPA_ENSINO IN (8, 19, 9, 20)
  "))
  
  
  # -------------------------------
  # 2. Tabela de escolas
  # -------------------------------
  
  dbExecute(con, glue("
  CREATE OR REPLACE TABLE escolas_{ano} AS
  SELECT DISTINCT
    CO_ENTIDADE,
    CO_REGIAO,
    CO_MESORREGIAO,
    CO_MICRORREGIAO,
    CO_UF,
    CO_MUNICIPIO,
    CO_DISTRITO,
    TP_DEPENDENCIA,
    TP_LOCALIZACAO,
    TP_CATEGORIA_ESCOLA_PRIVADA,
    IN_PODER_PUBLICO_PARCERIA,
    TP_PODER_PUBLICO_PARCERIA,
    IN_CONVENIADA_PP,
    TP_CONVENIO_PODER_PUBLICO,
    IN_MANT_ESCOLA_PRIVADA_EMP,
    IN_MANT_ESCOLA_PRIVADA_ONG,
    IN_MANT_ESCOLA_PRIVADA_OSCIP,
    IN_MANT_ESCOLA_PRIV_ONG_OSCIP,
    IN_MANT_ESCOLA_PRIVADA_SIND,
    IN_MANT_ESCOLA_PRIVADA_SIST_S,
    IN_MANT_ESCOLA_PRIVADA_S_FINS,
    TP_REGULAMENTACAO,
    TP_LOCALIZACAO_DIFERENCIADA,
    IN_EDUCACAO_INDIGENA
  FROM mat_{ano}
  "))
  
  
  # -------------------------------
  # 3. Situação
  # -------------------------------
  
  dbExecute(con, glue("
  CREATE OR REPLACE TABLE sit_{ano} AS
  SELECT 
    CO_PESSOA_FISICA,
    TP_ETAPA_ENSINO,
    CO_ENTIDADE AS CO_ENTIDADE_FIM_ANO,
    TP_SITUACAO
  FROM read_csv('{path_sit}', encoding='latin-1', union_by_name=TRUE)
  "))
  
  
  # -------------------------------
  # 4. Merge
  # -------------------------------
  
  dbExecute(con, glue("
  CREATE OR REPLACE TABLE base_{ano} AS
  SELECT
    m.* EXCLUDE (
      CO_ENTIDADE,
      CO_REGIAO,
      CO_MESORREGIAO,
      CO_MICRORREGIAO,
      CO_UF,
      CO_MUNICIPIO,
      CO_DISTRITO,
      TP_DEPENDENCIA,
      TP_LOCALIZACAO,
      TP_CATEGORIA_ESCOLA_PRIVADA,
      IN_PODER_PUBLICO_PARCERIA,
      TP_PODER_PUBLICO_PARCERIA,
      IN_CONVENIADA_PP,
      TP_CONVENIO_PODER_PUBLICO,
      IN_MANT_ESCOLA_PRIVADA_EMP,
      IN_MANT_ESCOLA_PRIVADA_ONG,
      IN_MANT_ESCOLA_PRIVADA_OSCIP,
      IN_MANT_ESCOLA_PRIV_ONG_OSCIP,
      IN_MANT_ESCOLA_PRIVADA_SIND,
      IN_MANT_ESCOLA_PRIVADA_SIST_S,
      IN_MANT_ESCOLA_PRIVADA_S_FINS,
      TP_REGULAMENTACAO,
      TP_LOCALIZACAO_DIFERENCIADA,
      IN_EDUCACAO_INDIGENA
    ),
    
    s.CO_ENTIDADE_FIM_ANO AS CO_ENTIDADE,
    s.TP_SITUACAO,
    
    e.CO_REGIAO,
    e.CO_MESORREGIAO,
    e.CO_MICRORREGIAO,
    e.CO_UF,
    e.CO_MUNICIPIO,
    e.CO_DISTRITO,
    e.TP_DEPENDENCIA,
    e.TP_LOCALIZACAO,
    e.TP_CATEGORIA_ESCOLA_PRIVADA,
    e.IN_PODER_PUBLICO_PARCERIA,
    e.TP_PODER_PUBLICO_PARCERIA,
    e.IN_CONVENIADA_PP,
    e.TP_CONVENIO_PODER_PUBLICO,
    e.IN_MANT_ESCOLA_PRIVADA_EMP,
    e.IN_MANT_ESCOLA_PRIVADA_ONG,
    e.IN_MANT_ESCOLA_PRIVADA_OSCIP,
    e.IN_MANT_ESCOLA_PRIV_ONG_OSCIP,
    e.IN_MANT_ESCOLA_PRIVADA_SIND,
    e.IN_MANT_ESCOLA_PRIVADA_SIST_S,
    e.IN_MANT_ESCOLA_PRIVADA_S_FINS,
    e.TP_REGULAMENTACAO,
    e.TP_LOCALIZACAO_DIFERENCIADA,
    e.IN_EDUCACAO_INDIGENA
    
  FROM mat_{ano} m
  
  LEFT JOIN sit_{ano} s
  ON m.CO_PESSOA_FISICA = s.CO_PESSOA_FISICA
     AND m.TP_ETAPA_ENSINO = s.TP_ETAPA_ENSINO
  
  LEFT JOIN escolas_{ano} e
  ON s.CO_ENTIDADE_FIM_ANO = e.CO_ENTIDADE
  "))
}

# -------------------------------
# 5. Empilhar tudo
# -------------------------------

queries <- paste0("SELECT *, ", anos, " AS ANO FROM base_", anos)
query_union <- paste(queries, collapse = " UNION ALL ")

dbExecute(con, glue("
CREATE OR REPLACE TABLE base_final AS
{query_union}
"))

# -------------------------------
# 6. Salvar
# -------------------------------

dbExecute(con, glue("
COPY base_final
TO '{out}/base_final.parquet'
(FORMAT PARQUET)
"))



# Porcentagem de alunos em cada situação dentro do ano
dist_situacao_prop <- dbGetQuery(con, "
SELECT 
  ANO,
  TP_SITUACAO,
  COUNT(*) * 1.0 / SUM(COUNT(*)) OVER (PARTITION BY ANO) AS share
FROM base_final
GROUP BY ANO, TP_SITUACAO
ORDER BY ANO, TP_SITUACAO
")



# Distribuição de duplicação por ano
dist_duplicacao <- dbGetQuery(con, "
WITH freq AS (
  SELECT 
    ANO,
    CO_PESSOA_FISICA,
    COUNT(*) AS n_linhas
  FROM base_final
  GROUP BY ANO, CO_PESSOA_FISICA
),

classificado AS (
  SELECT
    ANO,
    CASE 
      WHEN n_linhas = 1 THEN '1_unico'
      WHEN n_linhas = 2 THEN '2_vezes'
      ELSE '3+_vezes'
    END AS categoria
  FROM freq
)

SELECT
  ANO,
  categoria,
  COUNT(*) * 1.0 / SUM(COUNT(*)) OVER (PARTITION BY ANO) AS share
FROM classificado
GROUP BY ANO, categoria
ORDER BY ANO, categoria
")




duplicados <- dbGetQuery(con, "
WITH freq AS (
  SELECT 
    ANO,
    CO_PESSOA_FISICA,
    COUNT(*) AS n_linhas
  FROM base_final
  GROUP BY ANO, CO_PESSOA_FISICA
  HAVING COUNT(*) > 1
)

SELECT b.*
FROM base_final b
JOIN freq f
ON b.ANO = f.ANO
   AND b.CO_PESSOA_FISICA = f.CO_PESSOA_FISICA
ORDER BY b.ANO, b.CO_PESSOA_FISICA
")









