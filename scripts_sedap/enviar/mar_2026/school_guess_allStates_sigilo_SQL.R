
################################################################################

## Predição para alunos do 9º ano do Ensino Fundamental em 2009 
## usando Censo Básico

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


###Definir diretórios
###Educação Básica
path2009 <- "B:/CENSO_ESCOLAR/BAS_MATRICULA/BAS_MATRICULA_2009.csv"
path2008 <- "B:/CENSO_ESCOLAR/BAS_MATRICULA/BAS_MATRICULA_2008.csv"




con <- dbConnect(duckdb())
dbExecute(con, "PRAGMA memory_limit='15GB'")


################################################################################

###Faz a predição para 2008 com base na Moda

################################################################################

school_guess <- dbGetQuery(con, sprintf("

WITH

-- 9º ano em 2009
mat2009 AS (
    SELECT DISTINCT ON (FK_COD_ALUNO)
        FK_COD_ALUNO,
        FK_COD_ETAPA_ENSINO AS FK_COD_ETAPA_ENSINO_2009,
        PK_COD_ENTIDADE AS PK_COD_ENTIDADE_2009
    FROM read_csv('%s', encoding = 'latin-1', union_by_name = TRUE)
    WHERE FK_COD_ETAPA_ENSINO IN (11,41)
),

-- base 2008
mat2008 AS (
    SELECT DISTINCT ON (FK_COD_ALUNO)
        FK_COD_ALUNO,
        FK_COD_ETAPA_ENSINO AS FK_COD_ETAPA_ENSINO_2008,
        PK_COD_ENTIDADE AS PK_COD_ENTIDADE_2008
    FROM read_csv('%s', encoding = 'latin-1', union_by_name = TRUE)
),

-- join e filtros
df AS (
    SELECT
        a.FK_COD_ALUNO,
        a.PK_COD_ENTIDADE_2009,
        b.PK_COD_ENTIDADE_2008
    FROM mat2009 a
    LEFT JOIN mat2008 b
        ON a.FK_COD_ALUNO = b.FK_COD_ALUNO
    WHERE
        b.FK_COD_ETAPA_ENSINO_2008 NOT IN (11,41)
        AND b.PK_COD_ENTIDADE_2008 IS NOT NULL
),

-- contagem escola 2009 -> escola 2008
counts AS (
    SELECT
        PK_COD_ENTIDADE_2009,
        PK_COD_ENTIDADE_2008,
        COUNT(*) AS n
    FROM df
    GROUP BY
        PK_COD_ENTIDADE_2009,
        PK_COD_ENTIDADE_2008
),

-- escolher moda
ranked AS (
    SELECT *,
        ROW_NUMBER() OVER(
            PARTITION BY PK_COD_ENTIDADE_2009
            ORDER BY n DESC
        ) AS rn
    FROM counts
)

SELECT
PK_COD_ENTIDADE_2009,
PK_COD_ENTIDADE_2008
FROM ranked
WHERE rn = 1

", path2009, path2008))


save(school_guess, file = file.path(out, "school_guess_allStates_9EF.RData"))



################################################################################









