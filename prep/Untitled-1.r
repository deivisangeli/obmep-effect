pacman::p_load(basedosdados, tidyverse, data.table)

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
    dados.id_municipio AS id_municipio,
    diretorio_id_municipio.nome AS id_municipio_nome,
    descricao_tipo_vinculo AS tipo_vinculo,
    descricao_vinculo_ativo_3112 AS vinculo_ativo_3112,
    descricao_tipo_admissao AS tipo_admissao,
    dados.valor_remuneracao_media as valor_remuneracao_media,
    dados.cbo_2002 AS cbo_2002,
    diretorio_cbo_2002.descricao AS cbo_2002_descricao,
    diretorio_cbo_2002.descricao_familia AS cbo_2002_descricao_familia,
    diretorio_cbo_2002.descricao_subgrupo AS cbo_2002_descricao_subgrupo,
    diretorio_cbo_2002.descricao_subgrupo_principal AS cbo_2002_descricao_subgrupo_principal,
    diretorio_cbo_2002.descricao_grande_grupo AS cbo_2002_descricao_grande_grupo,
    dados.cnae_2 as cnae_2,
    dados.idade as idade,
    descricao_sexo AS sexo,
    descricao_raca_cor AS raca_cor
FROM `basedosdados.br_me_rais.microdados_vinculos` AS dados
LEFT JOIN (SELECT DISTINCT sigla,nome  FROM `basedosdados.br_bd_diretorios_brasil.uf`) AS diretorio_sigla_uf
    ON dados.sigla_uf = diretorio_sigla_uf.sigla
LEFT JOIN (SELECT DISTINCT id_municipio,nome  FROM `basedosdados.br_bd_diretorios_brasil.municipio`) AS diretorio_id_municipio
    ON dados.id_municipio = diretorio_id_municipio.id_municipio
LEFT JOIN `dicionario_tipo_vinculo`
    ON dados.tipo_vinculo = chave_tipo_vinculo
LEFT JOIN `dicionario_vinculo_ativo_3112`
    ON dados.vinculo_ativo_3112 = chave_vinculo_ativo_3112
LEFT JOIN `dicionario_tipo_admissao`
    ON dados.tipo_admissao = chave_tipo_admissao
LEFT JOIN (SELECT DISTINCT cbo_2002,descricao,descricao_familia,descricao_subgrupo,descricao_subgrupo_principal,descricao_grande_grupo  FROM `basedosdados.br_bd_diretorios_brasil.cbo_2002`) AS diretorio_cbo_2002
    ON dados.cbo_2002 = diretorio_cbo_2002.cbo_2002
LEFT JOIN `dicionario_sexo`
    ON dados.sexo = chave_sexo
LEFT JOIN `dicionario_raca_cor`
    ON dados.raca_cor = chave_raca_cor
"

conn_br <- read_sql(query, billing_project_id = get_billing_id())
