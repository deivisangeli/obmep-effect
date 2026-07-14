pacman::p_load(basedosdados, bigrquery, data.table, arrow, duckdb, DBI)

# Defina o seu projeto no Google Cloud
set_billing_id("comp-proj-457701")

# Para carregar o dado direto no R
query <- "
WITH 
dicionario_tipo_vinculo AS (
    SELECT
        chave AS chave_tipo_vinculo,
        valor AS descricao_tipo_vinculo
    FROM `basedosdados.br_me_rais.dicionario`
    WHERE
        TRUE
        AND nome_coluna = 'tipo_vinculo'
        AND id_tabela = 'microdados_vinculos'
),
dicionario_vinculo_ativo_3112 AS (
    SELECT
        chave AS chave_vinculo_ativo_3112,
        valor AS descricao_vinculo_ativo_3112
    FROM `basedosdados.br_me_rais.dicionario`
    WHERE
        TRUE
        AND nome_coluna = 'vinculo_ativo_3112'
        AND id_tabela = 'microdados_vinculos'
),
dicionario_tipo_admissao AS (
    SELECT
        chave AS chave_tipo_admissao,
        valor AS descricao_tipo_admissao
    FROM `basedosdados.br_me_rais.dicionario`
    WHERE
        TRUE
        AND nome_coluna = 'tipo_admissao'
        AND id_tabela = 'microdados_vinculos'
),
dicionario_sexo AS (
    SELECT
        chave AS chave_sexo,
        valor AS descricao_sexo
    FROM `basedosdados.br_me_rais.dicionario`
    WHERE
        TRUE
        AND nome_coluna = 'sexo'
        AND id_tabela = 'microdados_vinculos'
),
dicionario_raca_cor AS (
    SELECT
        chave AS chave_raca_cor,
        valor AS descricao_raca_cor
    FROM `basedosdados.br_me_rais.dicionario`
    WHERE
        TRUE
        AND nome_coluna = 'raca_cor'
        AND id_tabela = 'microdados_vinculos'
)
SELECT
    dados.ano as ano,
    dados.sigla_uf AS sigla_uf,
    diretorio_sigla_uf.nome AS sigla_uf_nome,
    descricao_tipo_vinculo AS tipo_vinculo,
    descricao_vinculo_ativo_3112 AS vinculo_ativo_3112,
    descricao_tipo_admissao AS tipo_admissao,
    dados.id_municipio_trabalho AS id_municipio_trabalho,
    diretorio_id_municipio_trabalho.nome AS id_municipio_trabalho_nome,
    dados.valor_remuneracao_media as valor_remuneracao_media,
    dados.cbo_2002 AS cbo_2002,
    diretorio_cbo_2002.descricao AS cbo_2002_descricao,
    diretorio_cbo_2002.descricao_familia AS cbo_2002_descricao_familia,
    diretorio_cbo_2002.descricao_subgrupo AS cbo_2002_descricao_subgrupo,
    diretorio_cbo_2002.descricao_subgrupo_principal AS cbo_2002_descricao_subgrupo_principal,
    diretorio_cbo_2002.descricao_grande_grupo AS cbo_2002_descricao_grande_grupo,
    dados.cnae_2_subclasse AS cnae_2_subclasse,
    diretorio_cnae_2_subclasse.descricao_subclasse AS cnae_2_subclasse_descricao_subclasse,
    diretorio_cnae_2_subclasse.descricao_classe AS cnae_2_subclasse_descricao_classe,
    diretorio_cnae_2_subclasse.descricao_grupo AS cnae_2_subclasse_descricao_grupo,
    diretorio_cnae_2_subclasse.descricao_divisao AS cnae_2_subclasse_descricao_divisao,
    diretorio_cnae_2_subclasse.descricao_secao AS cnae_2_subclasse_descricao_secao,
    dados.idade as idade,
    descricao_sexo AS sexo,
    descricao_raca_cor AS raca_cor
FROM `basedosdados.br_me_rais.microdados_vinculos` AS dados
LEFT JOIN (SELECT DISTINCT sigla,nome  FROM `basedosdados.br_bd_diretorios_brasil.uf`) AS diretorio_sigla_uf
    ON dados.sigla_uf = diretorio_sigla_uf.sigla
LEFT JOIN `dicionario_tipo_vinculo`
    ON dados.tipo_vinculo = chave_tipo_vinculo
LEFT JOIN `dicionario_vinculo_ativo_3112`
    ON dados.vinculo_ativo_3112 = chave_vinculo_ativo_3112
LEFT JOIN `dicionario_tipo_admissao`
    ON dados.tipo_admissao = chave_tipo_admissao
LEFT JOIN (SELECT DISTINCT id_municipio,nome  FROM `basedosdados.br_bd_diretorios_brasil.municipio`) AS diretorio_id_municipio_trabalho
    ON dados.id_municipio_trabalho = diretorio_id_municipio_trabalho.id_municipio
LEFT JOIN (SELECT DISTINCT cbo_2002,descricao,descricao_familia,descricao_subgrupo,descricao_subgrupo_principal,descricao_grande_grupo  FROM `basedosdados.br_bd_diretorios_brasil.cbo_2002`) AS diretorio_cbo_2002
    ON dados.cbo_2002 = diretorio_cbo_2002.cbo_2002
LEFT JOIN (SELECT DISTINCT subclasse,descricao_subclasse,descricao_classe,descricao_grupo,descricao_divisao,descricao_secao  FROM `basedosdados.br_bd_diretorios_brasil.cnae_2`) AS diretorio_cnae_2_subclasse
    ON dados.cnae_2_subclasse = diretorio_cnae_2_subclasse.subclasse
LEFT JOIN `dicionario_sexo`
    ON dados.sexo = chave_sexo
LEFT JOIN `dicionario_raca_cor`
    ON dados.raca_cor = chave_raca_cor
WHERE
    dados.ano = 2023
    AND dados.vinculo_ativo_3112 = '1'
"

dt <- read_sql(query, billing_project_id = get_billing_id())

setDT(dt)
dbExecute(con, "PRAGMA threads=12")
dbExecute(con, "PRAGMA memory_limit='25GB'")
con <- dbConnect(duckdb())

dbExecute(con, "PRAGMA threads=12")
dbExecute(con, "PRAGMA memory_limit='25GB'")

write_parquet(dt, "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/raw/RAIS/rais_2023.parquet")

duckdb_register(con, "dt_view", dt)


dt <- read_parquet("C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/raw/RAIS/rais_2023.parquet")
path <- "C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/raw/RAIS/rais_2023.parquet"

dbExecute(con, sprintf("
COPY(
SELECT *,
from read_parquet('%s'))
TO 'C:/Users/megaj/Globtalent Dropbox/OBMEP/Data/raw/RAIS/rais_2023.csv' (FORMAT CSV, HEADER TRUE)




", path))


'
