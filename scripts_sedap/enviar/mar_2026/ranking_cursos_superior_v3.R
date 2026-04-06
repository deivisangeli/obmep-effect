
################################################################################

## Média das notas do ENEM para os ingressantes de cada curso do Ensino Superior  
## independente da entrada na faculdade ser via ENEM ou não

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
###Enem
dir_enem   <- "B:/ENEM"

###Educação Superior
dir_alunos <- "B:/CENSO_SUPERIOR/SUP_ALUNO"



###Definir diretórios de saída
enem_bucket_dir   <- file.path(out, "enem_buckets")
aluno_bucket_dir  <- file.path(out, "aluno_buckets")
match_bucket_dir  <- file.path(out, "matched_buckets")

dir_create(c(enem_bucket_dir,
             aluno_bucket_dir,
             match_bucket_dir))

con <- dbConnect(duckdb())
dbExecute(con, "PRAGMA memory_limit='15GB'")

################################################################################

###ENEM (2009-2022)

################################################################################

for (ano in 2009:2022) {
  
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
    {ch} IS NOT NULL AND
    {lc} IS NOT NULL AND
    {mt} IS NOT NULL AND
    {red} IS NOT NULL
  ")
  
  # 5. Executar
  dbExecute(con, glue("
    COPY (
      SELECT
        CPF_MASC,
        {ano} AS ano_enem,
        {nota_expr} AS nota_enem,
        (hash(CPF_MASC) % 128 + 1) AS bucket
      FROM read_csv('{enem_path}', encoding = 'latin-1', union_by_name = TRUE)
      WHERE
        CPF_MASC IS NOT NULL 
        AND {where_expr}
    )
    TO '{enem_bucket_dir}'
    (FORMAT PARQUET, PARTITION_BY bucket, OVERWRITE_OR_IGNORE)
  "))
}




################################################################################

###ALUNOS INGRESSANTES (2010-2023)

################################################################################

for (ano in 2010:2023) {
  
  message("Processando Alunos ", ano)
  
  alunos_path <- file.path(dir_alunos,
                           as.character(ano),
                           "*.csv")
  
  dbExecute(con, sprintf("
    COPY (
      SELECT
        CPF_MASC,
        NU_ANO_INGRESSO,
        NU_ANO,
        CO_IES,
        CO_CURSO,
        CO_CINE_ROTULO,
        IN_INGRESSO_ENEM,
        (hash(CPF_MASC) %% 128 + 1) AS bucket
      FROM read_csv('%s', encoding = 'latin-1', union_by_name = TRUE)
      WHERE 
        CPF_MASC IS NOT NULL AND
        NU_ANO_INGRESSO = NU_ANO
    )
    TO '%s'
    (FORMAT PARQUET, PARTITION_BY bucket, OVERWRITE_OR_IGNORE)
  ", alunos_path, aluno_bucket_dir))
}



################################################################################

###MATCH TEMPORAL POR BUCKET

################################################################################

for (b in 1:128) {
  
  message("Matching bucket ", b)
  
  enem_files  <- sprintf("%s/bucket=%d/*.parquet", enem_bucket_dir, b)
  aluno_files <- sprintf("%s/bucket=%d/*.parquet", aluno_bucket_dir, b)
  out_file    <- sprintf("%s/bucket_%d.parquet", match_bucket_dir, b)
  
  dbExecute(con, sprintf("
    COPY (
      SELECT *
      FROM (
        SELECT
          a.CPF_MASC,
          a.NU_ANO_INGRESSO,
          a.CO_IES,
          a.CO_CURSO,
          a.CO_CINE_ROTULO,
          a.IN_INGRESSO_ENEM,
          e.nota_enem,
          ROW_NUMBER() OVER (
            PARTITION BY a.CPF_MASC, a.NU_ANO_INGRESSO, a.CO_IES, a.CO_CURSO
            ORDER BY e.ano_enem DESC
          ) AS rn
        FROM read_parquet('%s') a
        LEFT JOIN read_parquet('%s') e
          ON a.CPF_MASC = e.CPF_MASC
         AND e.ano_enem < a.NU_ANO_INGRESSO
      )
      WHERE rn = 1 OR rn IS NULL
    )
    TO '%s' (FORMAT PARQUET)
  ", aluno_files, enem_files, out_file))
}



################################################################################

###AGREGAÇÃO FINAL

################################################################################

final_table <- dbGetQuery(con, sprintf("
  SELECT
    CO_IES,
    NU_ANO_INGRESSO,
    CO_CURSO,
    CO_CINE_ROTULO,
    AVG(nota_enem) AS media_nota_enem,
    COUNT(*) AS total_ingressantes,
    SUM(CASE WHEN IN_INGRESSO_ENEM = 1 THEN 1 ELSE 0 END)
      AS total_ingressantes_enem
  FROM read_parquet('%s/bucket_*.parquet')
  GROUP BY
    CO_IES,
    NU_ANO_INGRESSO,
    CO_CURSO,
    CO_CINE_ROTULO
", match_bucket_dir))


write_parquet(final_table,
              file.path(out,
                        "media_enem_por_curso_instituicao.parquet"))




################################################################################


