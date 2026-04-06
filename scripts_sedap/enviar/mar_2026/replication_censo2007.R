
################################################################################

## Replicação para 2006 e 2005 do Censo Básico 2007 (Base Matrícula) para os    
## alunos que estavam no 9º e 8º ano 

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
dir_alunos <- "B:/CENSO_ESCOLAR/BAS_MATRICULA/BAS_MATRICULA_2007.csv"




con <- dbConnect(duckdb())
dbExecute(con, "PRAGMA memory_limit='15GB'")

################################################################################

###Ler Censo 2007 e filtrar 8º e 9º ano

################################################################################

dbExecute(con, sprintf("
CREATE TABLE alunos_2007 AS
SELECT *
FROM read_csv('%s', encoding = 'latin-1', union_by_name = TRUE)
WHERE TP_ETAPA_ENSINO IN (41,11,21,10)
", censo_2007_path))


################################################################################

###Remover variáveis de turma

################################################################################

turma_vars <- c(
  "ID_TURMA","CO_CURSO_EDUC_PROFISSIONAL","TP_MEDIACAO_DIDATICO_PEDAGO",
  "NU_DURACAO_TURMA","NU_DUR_ATIV_COMP_MESMA_REDE","NU_DUR_ATIV_COMP_OUTRAS_REDES",
  "NU_DUR_AEE_MESMA_REDE","NU_DUR_AEE_OUTRAS_REDES","NU_DUR_ITINERARIO_MESMA_REDE",
  "NU_DUR_ITINERARIO_OUTRAS_REDES","NU_DIAS_ATIVIDADE","NU_DUR_SEMANA_TURMA",
  "NU_DUR_SEMANA_TURMA_AC_IT","NU_DUR_SEMANA_TURMA_AC_AEE_IT","TP_UNIFICADA",
  "TP_TIPO_TURMA","TP_TIPO_ATENDIMENTO_TURMA","TP_ESTRUTURA_CURRICULAR",
  "IN_UNIDADE_ELETIVAS","IN_UNIDADE_LIBRAS","IN_UNIDADE_LINGUA_INDIGENA",
  "IN_UNIDADE_LINGUA_ESPANHOL","IN_UNIDADE_LINGUA_FRANCES","IN_UNIDADE_LINGUA_OUTRA",
  "IN_UNIDADE_PROJETO_VIDA","IN_UNIDADE_TRILHAS","IN_UNIDADE_OUTRA",
  "IN_DISC_PROJETO_DE_VIDA","TP_TIPO_LOCAL_TURMA","TP_ORGANIZACAO_ENSINO",
  "IN_FORMACAO_ALTERNANCIA","IN_LIBRAS"
)

cols <- dbGetQuery(con, "
SELECT column_name
FROM information_schema.columns
WHERE table_name='alunos_2007'
")$column_name

keep_cols <- setdiff(cols, turma_vars)

query <- paste("CREATE TABLE alunos_2007_clean AS SELECT",
               paste(keep_cols, collapse=","),
               "FROM alunos_2007")

dbExecute(con, query)



################################################################################

###Criar tabela de características das escolas (2007)

################################################################################

dbExecute(con, "
CREATE TABLE escolas_2007 AS
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
FROM alunos_2007
")



################################################################################

###Carregar school_guess

################################################################################

load("school_guess.RData")
dbWriteTable(con, "school_guess", school_guess, overwrite=TRUE)



################################################################################

###Criar base simulada 2006

################################################################################

dbExecute(con, "
CREATE TABLE alunos_2006 AS
SELECT
a.* EXCLUDE (CO_ENTIDADE, NU_IDADE, NU_IDADE_REFERENCIA, TP_ETAPA_ENSINO, NU_ANO),

2006 AS NU_ANO,
NU_IDADE_REFERENCIA - 1 AS NU_IDADE_REFERENCIA,
NU_IDADE - 1 AS NU_IDADE,

CASE
WHEN TP_ETAPA_ENSINO = 41 THEN 21
WHEN TP_ETAPA_ENSINO = 11 THEN 10
WHEN TP_ETAPA_ENSINO = 21 THEN 20
WHEN TP_ETAPA_ENSINO = 10 THEN 9
END AS TP_ETAPA_ENSINO,

g.CO_ENTIDADE_2006 AS CO_ENTIDADE

FROM alunos_2007_clean a
LEFT JOIN school_guess g
ON a.CO_ENTIDADE = g.CO_ENTIDADE_2007
")



################################################################################

###Criar base simulada 2005

################################################################################

dbExecute(con, "
CREATE TABLE alunos_2005 AS
SELECT
a.* EXCLUDE (CO_ENTIDADE, NU_IDADE, NU_IDADE_REFERENCIA, TP_ETAPA_ENSINO, NU_ANO),

2005 AS NU_ANO,
NU_IDADE_REFERENCIA - 2 AS NU_IDADE_REFERENCIA,
NU_IDADE - 2 AS NU_IDADE,

CASE
WHEN TP_ETAPA_ENSINO = 41 THEN 20
WHEN TP_ETAPA_ENSINO = 11 THEN 9
WHEN TP_ETAPA_ENSINO = 21 THEN 19
WHEN TP_ETAPA_ENSINO = 10 THEN 8
END AS TP_ETAPA_ENSINO,

g.CO_ENTIDADE_2006 AS CO_ENTIDADE

FROM alunos_2007_clean a
LEFT JOIN school_guess g
ON a.CO_ENTIDADE = g.CO_ENTIDADE_2007
")


################################################################################

###Trazer características da escola predita

################################################################################

dbExecute(con, "
CREATE TABLE alunos_2006_final AS
SELECT
a.* EXCLUDE (
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

FROM alunos_2006 a
LEFT JOIN escolas_2007 e
ON a.CO_ENTIDADE = e.CO_ENTIDADE
")


dbExecute(con, "
CREATE TABLE alunos_2005_final AS
SELECT
a.* EXCLUDE (
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

FROM alunos_2005 a
LEFT JOIN escolas_2007 e
ON a.CO_ENTIDADE = e.CO_ENTIDADE
")


################################################################################

###Salvar resultados

################################################################################

dbExecute(con, sprintf("
COPY alunos_2006_final
TO '%s/censo_basico_2006.parquet'
(FORMAT PARQUET)
", out))


dbExecute(con, sprintf("
COPY alunos_2005_final
TO '%s/censo_basico_2005.parquet'
(FORMAT PARQUET)
", out))



################################################################################







