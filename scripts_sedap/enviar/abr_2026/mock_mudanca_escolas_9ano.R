################################################################################

## Mock para mapear mudanca de escola no 9o ano
## Universo de alunos no 6o ano

################################################################################

###Carregar pacotes

rm(list = ls());gc()

library(duckdb)
library(DBI)
library(readr)

################################################################################

###Definir diretorios

################################################################################

test_root <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/test/mock_mudanca_escolas_9ano"

dir_mat <- file.path(test_root, "BAS_MATRICULA")
dir_sit <- file.path(test_root, "BAS_SITUACAO")
out <- file.path(test_root, "output")

dir.create(dir_mat, recursive = TRUE, showWarnings = FALSE)
dir.create(dir_sit, recursive = TRUE, showWarnings = FALSE)
dir.create(out, recursive = TRUE, showWarnings = FALSE)

path_mat_2007 <- normalizePath(
  file.path(dir_mat, "BAS_MATRICULA_2007.csv"),
  winslash = "/",
  mustWork = FALSE
)

path_sit_2010 <- normalizePath(
  file.path(dir_sit, "BAS_SITUACAO_2010.csv"),
  winslash = "/",
  mustWork = FALSE
)

path_out_parquet <- normalizePath(
  file.path(out, "outcome_mudanca_escola_9ano.parquet"),
  winslash = "/",
  mustWork = FALSE
)

path_out_csv <- normalizePath(
  file.path(out, "outcome_mudanca_escola_9ano.csv"),
  winslash = "/",
  mustWork = FALSE
)

################################################################################

###Criar dados mock

################################################################################

mat_2007 <- data.frame(
  NU_ANO = c(2007, 2007, 2007, 2007, 2007, 2007, 2007),
  ID_MATRICULA = c(7001, 7002, 7003, 7004, 7005, 7006, 7007),
  CO_PESSOA_FISICA = c(1001, 1002, 1003, 1004, 1005, 1006, 1007),
  TP_ETAPA_ENSINO = c(19, 19, 19, 19, 8, 19, 8),
  CO_ENTIDADE = c(101, 102, 103, 104, 105, 106, 107),
  TP_DEPENDENCIA = c(2, 2, 3, 3, 2, 3, 2)
)

sit_2010 <- data.frame(
  NU_ANO = c(2010, 2010, 2010, 2010, 2010, 2010, 2010),
  ID_MATRICULA = c(10001, 10002, 10003, 10004, 10006, 10007, 10999),
  CO_PESSOA_FISICA = c(1001, 1002, 1003, 1004, 1006, 1007, 1999),
  TP_ETAPA_ENSINO = c(41, 41, 41, 41, 41, 11, 41),
  CO_ENTIDADE = c(101, 202, 203, 104, 206, 107, 999),
  TP_SITUACAO = c(5, 5, 4, 2, 9, 3, 5),
  IN_CONCLUINTE = c(1, 1, 0, 0, 0, 0, 1),
  IN_TRANSFERIDO = c(0, 1, 1, 0, 1, 0, 0)
)

write_delim(mat_2007, path_mat_2007, delim = ";")
write_delim(sit_2010, path_sit_2010, delim = ";")

################################################################################

###Abrir conexao DuckDB

################################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, "PRAGMA memory_limit='15GB'")

################################################################################

###Ler matricula do 6o ano

################################################################################

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE mat_2007 AS
SELECT
  NU_ANO,
  ID_MATRICULA,
  CO_PESSOA_FISICA,
  TP_ETAPA_ENSINO,
  CO_ENTIDADE,
  TP_DEPENDENCIA
FROM read_csv('%s', delim=';', header=TRUE, union_by_name=TRUE)
WHERE
  NU_ANO = 2007
  AND TP_ETAPA_ENSINO IN (8, 19)
", path_mat_2007))

################################################################################

###Ler tabela de situacao do 9o ano

################################################################################

dbExecute(con, sprintf("
CREATE OR REPLACE TABLE sit_2010 AS
SELECT
  NU_ANO,
  ID_MATRICULA,
  CO_PESSOA_FISICA,
  TP_ETAPA_ENSINO,
  CO_ENTIDADE AS CO_ENTIDADE_9_FIM_ANO,
  TP_SITUACAO,
  IN_CONCLUINTE,
  IN_TRANSFERIDO
FROM read_csv('%s', delim=';', header=TRUE, union_by_name=TRUE)
WHERE
  NU_ANO = 2010
  AND TP_ETAPA_ENSINO IN (11, 41)
", path_sit_2010))

################################################################################

###Construir outcome

################################################################################

dbExecute(con, "
CREATE OR REPLACE TABLE outcome_mudanca_escola_9ano AS
SELECT
  m.CO_PESSOA_FISICA,
  2007 AS ANO_6,
  2010 AS ANO_9,
  m.ID_MATRICULA AS ID_MATRICULA_6,
  m.TP_ETAPA_ENSINO AS TP_ETAPA_ENSINO_6,
  m.CO_ENTIDADE AS CO_ENTIDADE_6,
  m.TP_DEPENDENCIA AS TP_DEPENDENCIA_6,
  s.ID_MATRICULA AS ID_MATRICULA_9,
  s.TP_ETAPA_ENSINO AS TP_ETAPA_ENSINO_9,
  s.CO_ENTIDADE_9_FIM_ANO,
  s.TP_SITUACAO AS TP_SITUACAO_9,
  s.IN_CONCLUINTE AS IN_CONCLUINTE_9,
  s.IN_TRANSFERIDO AS IN_TRANSFERIDO_9,
  CASE
    WHEN s.CO_PESSOA_FISICA IS NULL THEN NULL
    WHEN s.CO_ENTIDADE_9_FIM_ANO <> m.CO_ENTIDADE THEN 1
    ELSE 0
  END AS mudou_escola_9ano
FROM mat_2007 m
LEFT JOIN sit_2010 s
ON m.CO_PESSOA_FISICA = s.CO_PESSOA_FISICA
ORDER BY m.CO_PESSOA_FISICA
")

################################################################################

###Salvar resultado

################################################################################

if (file.exists(path_out_parquet)) file.remove(path_out_parquet)
if (file.exists(path_out_csv)) file.remove(path_out_csv)

dbExecute(con, sprintf("
COPY outcome_mudanca_escola_9ano
TO '%s'
(FORMAT PARQUET)
", path_out_parquet))

dbExecute(con, sprintf("
COPY outcome_mudanca_escola_9ano
TO '%s'
(FORMAT CSV, HEADER TRUE, DELIMITER ';')
", path_out_csv))

################################################################################

###Checks

################################################################################

total_universo <- dbGetQuery(con, "
SELECT COUNT(*) AS total_alunos_6ano
FROM outcome_mudanca_escola_9ano
")

dist_mudanca <- dbGetQuery(con, "
SELECT
  mudou_escola_9ano,
  COUNT(*) AS n
FROM outcome_mudanca_escola_9ano
GROUP BY mudou_escola_9ano
ORDER BY mudou_escola_9ano
")

dist_situacao <- dbGetQuery(con, "
SELECT
  TP_SITUACAO_9,
  COUNT(*) AS n
FROM outcome_mudanca_escola_9ano
GROUP BY TP_SITUACAO_9
ORDER BY TP_SITUACAO_9
")

resultado_final <- dbGetQuery(con, "
SELECT *
FROM outcome_mudanca_escola_9ano
ORDER BY CO_PESSOA_FISICA
")

print(total_universo)
print(dist_mudanca)
print(dist_situacao)
print(resultado_final)
