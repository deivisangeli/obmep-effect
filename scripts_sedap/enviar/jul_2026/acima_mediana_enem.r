######################################################################################

###Montar crosswalk ao nível do cpf masc com uma dummy indicando se o aluno já tirou
##uma nota acima da mediana em cn e mat, e quando fez isso pela primeira vez.

######################################################################################


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
###Enem
dir_enem   <- "B:/ENEM"

###Educação Superior
dir_alunos <- "B:/CENSO_SUPERIOR/SUP_ALUNO"



###Definir diretórios de saída
enem_bucket_dir   <- file.path(out, "enem_buckets")

dir_create(enem_bucket_dir)

con <- dbConnect(duckdb())
dbExecute(con, "PRAGMA memory_limit='15GB'")


################################################################################

###ENEM (2009-2023)

################################################################################

for (ano in 2009:2023) {
  
  message("Processando ENEM ", ano)
  
  enem_path <- file.path(dir_enem, as.character(ano), "*.csv")
  
  # 1. Ler schema (sem carregar dados)
  cols <- dbGetQuery(con, sprintf("
    SELECT *
    FROM read_csv('%s', encoding = 'latin-1', union_by_name = TRUE)
    LIMIT 0
  ", enem_path)) %>% names()
  
  # 2. Função auxiliar para escolher nome correto
  pick_var <- function(options) {
    found <- options[options %in% cols]
    if (length(found) == 0) {
      stop(paste("Nenhuma das colunas encontrada:", paste(options, collapse = ", ")))
    }
    return(found[1])
  }
  
  # 3. Detectar variáveis
  cn  <- pick_var(c("NU_NOTA_CN", "NOTA_CN", "NU_NT_CN"))
  ch  <- pick_var(c("NU_NOTA_CH", "NOTA_CH", "NU_NT_CH"))
  lc  <- pick_var(c("NU_NOTA_LC", "NOTA_LC", "NU_NT_LC"))
  mt  <- pick_var(c("NU_NOTA_MT", "NOTA_MT", "NU_NT_MT"))
  red <- pick_var(c("NU_NOTA_REDACAO", "NOTA_REDACAO"))
  
  # 4. Construir expressões SQL
  nota_expr <- glue("
    ({cn} + {ch} + {lc} + {mt} + {red}) / 5.0
  ")
  
  where_expr <- glue("
    {cn} IS NOT NULL AND
    {mt} IS NOT NULL
  ")
  
  # 5. Executar
  dbExecute(con, glue("
  COPY (
    SELECT
      CPF_MASC,
      {ano} AS ano_enem,
      {nota_expr} AS nota_enem,

      CASE
        WHEN ({cn} + {mt})
             >= median({cn} + {mt}) OVER ()
        THEN 1::TINYINT
        ELSE 0::TINYINT
      END AS acima_mediana_stem,

      (hash(CPF_MASC) % 128 + 1) AS bucket

    FROM read_csv(
      '{enem_path}',
      encoding = 'latin-1',
      union_by_name = TRUE
    )
    WHERE
      CPF_MASC IS NOT NULL
      AND {where_expr}
  )
  TO '{enem_bucket_dir}'
  (
    FORMAT PARQUET,
    PARTITION_BY bucket,
    APPEND
  )
"))
}

####Notas do enem para todos, adicionar ao painel final; Mediana definida sobre o painel final

###Montar variável ao colapsar por escola (maior ou igual a mediana)

#######################################################################################

###Dataset separado com alunos no censo superior que tiraram nota acima da mediana STEM no ENEM
##Ao nível do CPF_MASC, inclui o mínimo do ano de ingresso em que o aluno tirou nota acima da mediana STEM, e a variável binária acima_mediana_stem

#######################################################################################
out <- "T:/8. Intermediário"
dbExecute(con, sprintf("
  COPY(
  SELECT
    CPF_MASC,
    MIN(IF(acima_mediana_stem = 1, ano_enem, 9999)) AS primeiro_ano_acima_mediana_stem,
    MAX(COALESCE(acima_mediana_stem, 0)) AS acima_mediana_stem
  FROM read_parquet('%s')
  GROUP BY CPF_MASC)
  TO '%s/ingressantes_acima_mediana_stem.parquet' (FORMAT PARQUET)
", enem_bucket_dir, out))
