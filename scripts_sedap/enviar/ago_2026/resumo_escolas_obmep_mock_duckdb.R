################################################################################

## Resumo de escolas elegiveis e participantes da OBMEP - versao DuckDB
##
## AMBIENTE DE EXECUCAO: terminal offline do SEDAP.
## Toda a construcao das tabelas, validacoes e exportacoes CSV ocorre no DuckDB.
## O R e usado somente para abrir o banco, mostrar resultados e salvar graficos.

################################################################################

### Limpar o ambiente e carregar somente os pacotes necessarios

rm(list = ls())
gc()

library(DBI)
library(duckdb)
library(ggplot2)


################################################################################

### Definir diretorio de saida e abrir o DuckDB

################################################################################

# No SEDAP, os resultados serao gravados no caminho abaixo.
# A variavel de ambiente permite testar o mesmo script localmente sem edita-lo.
out_dir <- Sys.getenv(
  "OBMEP_RESUMO_OUT",
  unset = "T:/8. Intermediário/resumo_escolas_obmep_mock_duckdb"
)

# Criar a pasta quando necessario. Nao ocultar avisos, pois eles mostram se o
# drive T: nao esta montado ou se o usuario nao tem permissao de escrita.
if (!dir.exists(out_dir)) {
  dir.create(out_dir, recursive = TRUE, showWarnings = TRUE)
}

if (!dir.exists(out_dir)) {
  stop(
    paste0(
      "Nao foi possivel criar o diretorio de saida: ", out_dir,
      ". Altere out_dir ou defina OBMEP_RESUMO_OUT para uma pasta existente."
    )
  )
}

# DuckDB usa barras normais nos caminhos incluidos no SQL.
# mustWork = FALSE evita falhas de canonicalizacao em drives mapeados do SEDAP.
out_dir_sql <- normalizePath(
  out_dir,
  winslash = "/",
  mustWork = FALSE
)
out_dir_sql <- gsub("'", "''", out_dir_sql, fixed = TRUE)

con <- dbConnect(duckdb())
invisible(dbExecute(con, "PRAGMA memory_limit='15GB'"))


################################################################################

### Construir mocks, resultados, validacoes e CSVs em um unico bloco SQL

################################################################################

# Para usar outcomes reais, substituir outcome_1 e outcome_2 somente nas secoes
# marcadas abaixo. Nenhuma tabela analitica e construida no R.
sql <- "
BEGIN TRANSACTION;

-------------------------------------------------------------------------------
-- 1. Mock completo de escola por ano, 2007-2016
-------------------------------------------------------------------------------

CREATE OR REPLACE TABLE mock_escola_ano AS
WITH grade AS (
  SELECT
    CAST(escola AS INTEGER) AS CO_ENTIDADE,
    CAST(ano AS INTEGER) AS ano
  FROM generate_series(1001, 1008) AS e(escola)
  CROSS JOIN generate_series(2007, 2016) AS a(ano)
),
matriculas AS (
  SELECT
    CO_ENTIDADE,
    ano,
    CAST(
      CASE
        WHEN CO_ENTIDADE = 1001 THEN 20 + (ano - 2007)
        WHEN CO_ENTIDADE = 1002 THEN 18 + ((ano - 2007) % 3)
        WHEN CO_ENTIDADE = 1003 THEN 15 + ((ano - 2007) % 2)
        WHEN CO_ENTIDADE = 1004 AND ano >= 2010 THEN 14 + (ano - 2010)
        WHEN CO_ENTIDADE = 1005 THEN 24 + ((ano - 2007) % 4)
        WHEN CO_ENTIDADE = 1006 AND ano <= 2012 THEN 12 + (ano - 2007)
        WHEN CO_ENTIDADE = 1007 THEN 0
        WHEN CO_ENTIDADE = 1008 THEN 10 + ((ano - 2007) % 5)
        ELSE 0
      END AS INTEGER
    ) AS matriculas_nivel_I,
    CASE
      WHEN CO_ENTIDADE = 1001 THEN 1
      WHEN CO_ENTIDADE = 1002 AND ano BETWEEN 2008 AND 2010 THEN 1
      WHEN CO_ENTIDADE = 1004 AND ano >= 2012 THEN 1
      WHEN CO_ENTIDADE = 1005 AND
        (ano BETWEEN 2007 AND 2008 OR ano >= 2011) THEN 1
      WHEN CO_ENTIDADE = 1006 AND ano = 2009 THEN 1
      WHEN CO_ENTIDADE = 1008 AND ano BETWEEN 2009 AND 2011 THEN 1
      ELSE 0
    END AS participou_mock,
    CASE
      WHEN CO_ENTIDADE IN (1002, 1004, 1006) THEN 2
      WHEN CO_ENTIDADE = 1008 AND ano >= 2012 THEN 2
      ELSE 1
    END AS TP_LOCALIZACAO
  FROM grade
)
SELECT
  CO_ENTIDADE,
  ano,
  matriculas_nivel_I,
  CAST(
    CASE
      WHEN participou_mock = 1 THEN
        greatest(1, round(matriculas_nivel_I * 0.60))
      ELSE 0
    END AS INTEGER
  ) AS NR_INSCRITOS_1_FASE,
  CAST(TP_LOCALIZACAO AS INTEGER) AS TP_LOCALIZACAO
FROM matriculas
ORDER BY CO_ENTIDADE, ano;


-------------------------------------------------------------------------------
-- 2. Mock de alunos elegiveis ligado a escola e ao ano
-------------------------------------------------------------------------------

CREATE OR REPLACE TABLE mock_aluno_ano AS
SELECT
  concat_ws('_', CO_ENTIDADE, ano, ordem_aluno) AS ID_MATRICULA,
  CO_ENTIDADE,
  ano,
  TP_LOCALIZACAO,
  CAST(
    CASE
      WHEN ordem_aluno % 10 = 0 THEN 0
      WHEN ordem_aluno % 7 = 0 THEN 4
      WHEN ordem_aluno % 5 = 0 THEN 1
      WHEN ordem_aluno % 3 = 0 THEN 2
      WHEN ordem_aluno % 2 = 0 THEN 3
      ELSE 5
    END AS INTEGER
  ) AS TP_COR_RACA,

  -- OUTCOMES: substituir estes dois campos pelos outcomes reais.
  CASE
    WHEN ordem_aluno % 17 = 0 THEN NULL
    ELSE CAST((CO_ENTIDADE + ano + ordem_aluno) % 3 = 0 AS INTEGER)
  END AS outcome_1,
  CASE
    WHEN ordem_aluno % 19 = 0 THEN NULL
    ELSE round(
      40 + 2 * (CO_ENTIDADE - 1000) + 0.5 * (ano - 2007) +
        ordem_aluno / 10.0,
      2
    )
  END AS outcome_2
FROM mock_escola_ano
CROSS JOIN LATERAL range(1, matriculas_nivel_I + 1) AS a(ordem_aluno)
ORDER BY CO_ENTIDADE, ano, ordem_aluno;


-------------------------------------------------------------------------------
-- 3. Painel anual com dummies de participacao e elegibilidade
-------------------------------------------------------------------------------

CREATE OR REPLACE TABLE painel_escola_ano AS
WITH escolas AS (
  SELECT DISTINCT CO_ENTIDADE FROM mock_escola_ano
),
anos AS (
  SELECT CAST(ano AS INTEGER) AS ano
  FROM generate_series(2007, 2016) AS a(ano)
)
SELECT
  e.CO_ENTIDADE,
  a.ano,
  coalesce(m.matriculas_nivel_I, 0) AS matriculas_nivel_I,
  coalesce(m.NR_INSCRITOS_1_FASE, 0) AS NR_INSCRITOS_1_FASE,
  m.TP_LOCALIZACAO,
  CAST(coalesce(m.NR_INSCRITOS_1_FASE, 0) > 0 AS INTEGER) AS participou,
  CAST(coalesce(m.matriculas_nivel_I, 0) > 0 AS INTEGER) AS elegivel_fase_I
FROM escolas AS e
CROSS JOIN anos AS a
LEFT JOIN mock_escola_ano AS m
  ON e.CO_ENTIDADE = m.CO_ENTIDADE
 AND a.ano = m.ano
ORDER BY e.CO_ENTIDADE, a.ano;


-------------------------------------------------------------------------------
-- 4. Historico de elegibilidade, participacao e primeira parada
-------------------------------------------------------------------------------

CREATE OR REPLACE TABLE historico_escolas AS
WITH painel_primeira_participacao AS (
  SELECT
    *,
    min(ano) FILTER (WHERE participou = 1)
      OVER (PARTITION BY CO_ENTIDADE) AS ano_primeira_participacao
  FROM painel_escola_ano
),
historico AS (
  SELECT
    CO_ENTIDADE,
    sum(matriculas_nivel_I) AS total_alunos_elegiveis,
    sum(participou) AS numero_anos_participou,
    min(ano_primeira_participacao) AS ano_primeira_participacao,
    min(ano) FILTER (
      WHERE ano_primeira_participacao IS NOT NULL
        AND ano > ano_primeira_participacao
        AND participou = 0
    ) AS ano_primeira_parada,
    CAST(min(ano_primeira_participacao) IS NULL AS INTEGER) AS nunca_participou,
    count(DISTINCT ano) = 10 AND bool_and(elegivel_fase_I = 1)
      AS elegivel_todos_anos,
    bool_or(elegivel_fase_I = 1) AS elegivel_algum_ano
  FROM painel_primeira_participacao
  GROUP BY CO_ENTIDADE
)
SELECT
  *,
  CAST(
    CASE
      WHEN ano_primeira_parada IS NOT NULL
        THEN ano_primeira_parada - ano_primeira_participacao
      ELSE NULL
    END AS INTEGER
  ) AS anos_participando_ate_primeira_parada
FROM historico
ORDER BY CO_ENTIDADE;


-------------------------------------------------------------------------------
-- 5. Composicao e media dos outcomes dentro da escola
-------------------------------------------------------------------------------

CREATE OR REPLACE TABLE composicao_outcomes_escolas AS
SELECT
  CO_ENTIDADE,
  avg(CAST(TP_LOCALIZACAO = 2 AS INTEGER)) AS share_rural,

  -- TP_COR_RACA = 0 permanece no denominador e vale zero no numerador.
  avg(CAST(TP_COR_RACA IN (2, 3, 5) AS INTEGER))
    AS share_nonwhite_nonasian,

  -- OUTCOMES: substituir estes nomes junto com a secao de criacao do mock.
  avg(outcome_1) AS media_outcome_1,
  avg(outcome_2) AS media_outcome_2
FROM mock_aluno_ano
GROUP BY CO_ENTIDADE;

CREATE OR REPLACE TABLE dados_escola AS
SELECT
  h.*,
  c.share_rural,
  c.share_nonwhite_nonasian,
  c.media_outcome_1,
  c.media_outcome_2
FROM historico_escolas AS h
LEFT JOIN composicao_outcomes_escolas AS c USING (CO_ENTIDADE)
ORDER BY CO_ENTIDADE;


-------------------------------------------------------------------------------
-- 6. Duas amostras solicitadas
-------------------------------------------------------------------------------

CREATE OR REPLACE TABLE dados_duas_amostras AS
SELECT 'elegiveis_todos_anos' AS amostra, *
FROM dados_escola
WHERE elegivel_todos_anos

UNION ALL

SELECT 'elegiveis_algum_ano' AS amostra, *
FROM dados_escola
WHERE elegivel_algum_ano;


-------------------------------------------------------------------------------
-- 7. Estatisticas descritivas no nivel da escola
-------------------------------------------------------------------------------

CREATE OR REPLACE TABLE tabela_resumo AS
SELECT
  d.amostra,
  v.ordem,
  v.variavel,
  avg(v.valor) AS media,
  stddev_samp(v.valor) AS desvio_padrao,
  min(v.valor) AS minimo,
  max(v.valor) AS maximo,
  count(v.valor) AS N
FROM dados_duas_amostras AS d
CROSS JOIN LATERAL (
  VALUES
    (1, 'total_alunos_elegiveis',
      CAST(d.total_alunos_elegiveis AS DOUBLE)),
    (2, 'numero_anos_participou',
      CAST(d.numero_anos_participou AS DOUBLE)),
    (3, 'anos_participando_ate_primeira_parada',
      CAST(d.anos_participando_ate_primeira_parada AS DOUBLE)),
    (4, 'nunca_participou',
      CAST(d.nunca_participou AS DOUBLE)),
    (5, 'share_rural',
      CAST(d.share_rural AS DOUBLE)),
    (6, 'share_nonwhite_nonasian',
      CAST(d.share_nonwhite_nonasian AS DOUBLE)),
    (7, 'media_outcome_1',
      CAST(d.media_outcome_1 AS DOUBLE)),
    (8, 'media_outcome_2',
      CAST(d.media_outcome_2 AS DOUBLE))
) AS v(ordem, variavel, valor)
GROUP BY d.amostra, v.ordem, v.variavel
ORDER BY d.amostra, v.ordem;


-------------------------------------------------------------------------------
-- 8. Numero acumulado de escolas que ja participaram ate cada ano
-------------------------------------------------------------------------------

CREATE OR REPLACE TABLE serie_participacao AS
WITH membros_amostras AS (
  SELECT
    'elegiveis_todos_anos' AS amostra,
    CO_ENTIDADE,
    ano_primeira_participacao
  FROM dados_escola
  WHERE elegivel_todos_anos

  UNION ALL

  SELECT
    'elegiveis_algum_ano' AS amostra,
    CO_ENTIDADE,
    ano_primeira_participacao
  FROM dados_escola
  WHERE elegivel_algum_ano
),
anos AS (
  SELECT CAST(ano AS INTEGER) AS ano
  FROM generate_series(2007, 2016) AS a(ano)
)
SELECT
  m.amostra,
  a.ano,
  count(*) FILTER (
    WHERE m.ano_primeira_participacao IS NOT NULL
      AND m.ano_primeira_participacao <= a.ano
  ) AS numero_escolas_participaram_ate_ano
FROM membros_amostras AS m
CROSS JOIN anos AS a
GROUP BY m.amostra, a.ano
ORDER BY m.amostra, a.ano;


-------------------------------------------------------------------------------
-- 9. Validacoes: interromper o script se alguma regra mudar
-------------------------------------------------------------------------------

SELECT CASE
  WHEN
    (SELECT count(*) FROM painel_escola_ano) = 80
    AND (
      SELECT count(*)
      FROM (
        SELECT DISTINCT CO_ENTIDADE, ano FROM painel_escola_ano
      )
    ) = 80
    AND (SELECT sum(matriculas_nivel_I) FROM painel_escola_ano) =
        (SELECT count(*) FROM mock_aluno_ano)
  THEN TRUE
  ELSE error('Falha na validacao do painel escola-ano')
END;

SELECT CASE
  WHEN
    (SELECT count(*) FROM dados_escola WHERE elegivel_todos_anos) = 5
    AND (SELECT count(*) FROM dados_escola WHERE elegivel_algum_ano) = 7
  THEN TRUE
  ELSE error('Falha na validacao dos tamanhos das amostras')
END;

SELECT CASE
  WHEN
    (SELECT anos_participando_ate_primeira_parada
     FROM historico_escolas WHERE CO_ENTIDADE = 1001) IS NULL
    AND (SELECT anos_participando_ate_primeira_parada
         FROM historico_escolas WHERE CO_ENTIDADE = 1002) = 3
    AND (SELECT anos_participando_ate_primeira_parada
         FROM historico_escolas WHERE CO_ENTIDADE = 1003) IS NULL
    AND (SELECT anos_participando_ate_primeira_parada
         FROM historico_escolas WHERE CO_ENTIDADE = 1005) = 2
    AND (SELECT anos_participando_ate_primeira_parada
         FROM historico_escolas WHERE CO_ENTIDADE = 1006) = 1
  THEN TRUE
  ELSE error('Falha na validacao da primeira parada')
END;

SELECT CASE
  WHEN NOT EXISTS (
    SELECT 1
    FROM (
      SELECT
        amostra,
        ano,
        numero_escolas_participaram_ate_ano,
        lag(numero_escolas_participaram_ate_ano)
          OVER (PARTITION BY amostra ORDER BY ano) AS valor_anterior
      FROM serie_participacao
    )
    WHERE numero_escolas_participaram_ate_ano < valor_anterior
  )
  THEN TRUE
  ELSE error('A serie acumulada diminui entre dois anos')
END;

SELECT CASE
  WHEN
    (SELECT numero_escolas_participaram_ate_ano
     FROM serie_participacao
     WHERE amostra = 'elegiveis_todos_anos' AND ano = 2016) =
    (SELECT count(*) FROM dados_escola
     WHERE elegivel_todos_anos AND ano_primeira_participacao IS NOT NULL)
    AND
    (SELECT numero_escolas_participaram_ate_ano
     FROM serie_participacao
     WHERE amostra = 'elegiveis_algum_ano' AND ano = 2016) =
    (SELECT count(*) FROM dados_escola
     WHERE elegivel_algum_ano AND ano_primeira_participacao IS NOT NULL)
  THEN TRUE
  ELSE error('Falha no total final das series acumuladas')
END;


-------------------------------------------------------------------------------
-- 10. Exportar as quatro tabelas diretamente pelo DuckDB
-------------------------------------------------------------------------------

COPY (
  SELECT variavel, media, desvio_padrao, minimo, maximo, N
  FROM tabela_resumo
  WHERE amostra = 'elegiveis_todos_anos'
  ORDER BY ordem
) TO '__OUT_DIR__/resumo_elegiveis_todos_anos.csv'
  (HEADER, DELIMITER ',');

COPY (
  SELECT variavel, media, desvio_padrao, minimo, maximo, N
  FROM tabela_resumo
  WHERE amostra = 'elegiveis_algum_ano'
  ORDER BY ordem
) TO '__OUT_DIR__/resumo_elegiveis_algum_ano.csv'
  (HEADER, DELIMITER ',');

COPY (
  SELECT ano, numero_escolas_participaram_ate_ano
  FROM serie_participacao
  WHERE amostra = 'elegiveis_todos_anos'
  ORDER BY ano
) TO '__OUT_DIR__/serie_elegiveis_todos_anos.csv'
  (HEADER, DELIMITER ',');

COPY (
  SELECT ano, numero_escolas_participaram_ate_ano
  FROM serie_participacao
  WHERE amostra = 'elegiveis_algum_ano'
  ORDER BY ano
) TO '__OUT_DIR__/serie_elegiveis_algum_ano.csv'
  (HEADER, DELIMITER ',');

COMMIT;
"

# Inserir o diretorio no SQL uma unica vez e executar todo o fluxo.
sql <- gsub("__OUT_DIR__", out_dir_sql, sql, fixed = TRUE)
invisible(dbExecute(con, sql))


################################################################################

### Ler somente os dois resultados finais necessarios no R

################################################################################

tabela_resumo <- dbGetQuery(con, "
  SELECT amostra, variavel, media, desvio_padrao, minimo, maximo, N
  FROM tabela_resumo
  ORDER BY amostra, ordem
")

serie_participacao <- dbGetQuery(con, "
  SELECT amostra, ano, numero_escolas_participaram_ate_ano
  FROM serie_participacao
  ORDER BY amostra, ano
")


################################################################################

### Criar os dois graficos no R

################################################################################

serie_todos_anos <- subset(
  serie_participacao,
  amostra == "elegiveis_todos_anos"
)

serie_algum_ano <- subset(
  serie_participacao,
  amostra == "elegiveis_algum_ano"
)

grafico_elegiveis_todos_anos <- ggplot(
  serie_todos_anos,
  aes(x = ano, y = numero_escolas_participaram_ate_ano)
) +
  geom_line(linewidth = 1, color = "#1B6CA8") +
  geom_point(size = 2, color = "#1B6CA8") +
  scale_x_continuous(breaks = 2007:2016) +
  scale_y_continuous(breaks = scales::pretty_breaks()) +
  labs(
    title = "Escolas sempre elegiveis que ja participaram da OBMEP",
    subtitle = "Elegiveis para a Fase I em todos os anos, 2007-2016",
    x = "Ano",
    y = "Numero acumulado de escolas"
  ) +
  theme_minimal(base_size = 12)

grafico_elegiveis_algum_ano <- ggplot(
  serie_algum_ano,
  aes(x = ano, y = numero_escolas_participaram_ate_ano)
) +
  geom_line(linewidth = 1, color = "#B44C43") +
  geom_point(size = 2, color = "#B44C43") +
  scale_x_continuous(breaks = 2007:2016) +
  scale_y_continuous(breaks = scales::pretty_breaks()) +
  labs(
    title = "Escolas elegiveis que ja participaram da OBMEP",
    subtitle = "Elegiveis para a Fase I em pelo menos um ano, 2007-2016",
    x = "Ano",
    y = "Numero acumulado de escolas"
  ) +
  theme_minimal(base_size = 12)

ggsave(
  filename = file.path(out_dir, "serie_elegiveis_todos_anos.png"),
  plot = grafico_elegiveis_todos_anos,
  width = 9,
  height = 5.5,
  dpi = 300
)

ggsave(
  filename = file.path(out_dir, "serie_elegiveis_algum_ano.png"),
  plot = grafico_elegiveis_algum_ano,
  width = 9,
  height = 5.5,
  dpi = 300
)


################################################################################

### Mostrar resultados e encerrar o DuckDB

################################################################################

cat("\n=== ELEGIVEIS EM TODOS OS ANOS ===\n")
print(
  subset(tabela_resumo, amostra == "elegiveis_todos_anos", -amostra),
  row.names = FALSE
)

cat("\n=== ELEGIVEIS EM PELO MENOS UM ANO ===\n")
print(
  subset(tabela_resumo, amostra == "elegiveis_algum_ano", -amostra),
  row.names = FALSE
)

dbDisconnect(con, shutdown = TRUE)

cat("\nArquivos gravados em:\n", out_dir, "\n")
