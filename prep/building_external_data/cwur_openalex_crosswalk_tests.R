####################################################################
### Testes offline do crosswalk CWUR -> OpenAlex
###
### Roda o MESMO SQL da producao - cwur_openalex_sql.R - contra tabelas
### sinteticas em DuckDB na memoria. Sem rede, sem Dropbox, sem tocar em
### nenhum arquivo do pipeline. Cada assercao aqui e a regressao de uma
### armadilha MEDIDA contra os dados reais e descrita no cabecalho do
### crosswalk.
###
### Rodar a partir da raiz do repositorio:
###   Rscript prep/building_external_data/cwur_openalex_crosswalk_tests.R
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}
library(DBI)
library(duckdb)

sql_path <- Sys.getenv("OBMEP_CWUR_SQL",
                       unset = "prep/building_external_data/cwur_openalex_sql.R")
if (!file.exists(sql_path)) {
  stop("Nao achei ", sql_path,
       ". Rode a partir da raiz do repositorio ou aponte OBMEP_CWUR_SQL.")
}
source(sql_path)

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

for (m in cwur_macros_sql) invisible(dbExecute(con, m))

####################################################################
### Fixtures
####################################################################

# Um caso por linha, e o comentario diz o que cada linha existe para
# provar. Os world_rank sao os numeros dos casos, nao posicoes reais.
invisible(dbExecute(con, "
  CREATE OR REPLACE TABLE cwur AS SELECT * FROM (VALUES
    (1,  'Northeastern University',               'US'),
    (2,  'The University of Tokyo',               'JP'),
    (3,  'University of Hong Kong',               'CN'),
    (4,  'Universidade Federal do Para',          'BR'),
    (5,  'Gemeas University',                     'ZZ'),
    (6,  'CINVESTAV',                             'MX'),
    (7,  'Institute of Science Tokyo',            'JP'),
    (8,  'Texas A&M University, College Station', 'US'),
    (9,  'Escola Politecnica',                    'BR'),
    (10, 'Universidade Federal do Parana',        'BR'),
    (11, 'Sem Par University',                    'PT'),
    (12, 'Instituto Politecnico Nacional',        'MX'),
    (13, 'Federal University of Juiz de Fora',    'BR')
  ) AS t(world_rank, institution, country_iso2)"))

# A lista de Xangai: os dois Northeastern com o MESMO display_name e
# paises diferentes, e uma linha sem pais para provar a tolerancia do
# braco 1.
invisible(dbExecute(con, "
  CREATE OR REPLACE TABLE shanghai AS SELECT * FROM (VALUES
    ('I12912129', 'US',  'Northeastern University (Boston)',   'Northeastern University', 'Northeastern University'),
    ('I9224756',  'CN',  'Northeastern University (Shenyang)', 'Northeastern University', 'Northeastern University'),
    ('I68368234', 'MX',  'National Polytechnic Institute',     'Instituto Politecnico Nacional', 'Instituto Politecnico Nacional'),
    ('I700',      NULL,  'Sem Par University',                 'Sem Par University', 'Sem Par University'),
    ('I800',      'BR',  'Escola Politecnica (USP)',           'Escola Politecnica', 'Escola Politecnica')
  ) AS t(oa_id, country_code, shanghai_name, display_name, cleaned_display_name)"))

# O snapshot do OpenAlex.
invisible(dbExecute(con, "
  CREATE OR REPLACE TABLE oa AS SELECT * FROM (VALUES
    ('I2000', 'JP',  'University of Tokyo',            'education', 100000),
    ('I2001', 'HK',  'University of Hong Kong',        'education',  80000),
    ('I2002', 'BR',  'Universidade Federal do Parana', 'education',  50000),
    ('I2003', 'BR',  'Universidade Federal do Para',   'education',  20000),
    ('I2004', 'US',  'Texas A&M University College Station', 'education', 90000),
    ('I2005', NULL,  'Institute of Science Tokyo',     'education',   3307),
    ('I2006', 'ZZ',  'Gemeas University',              'education',      5),
    ('I2007', 'ZZ',  'Gemeas University',              'facility',       9),
    -- Armadilha 5: o nome so existe em portugues, sem alternativa em
    -- ingles, entao nenhum braco alcanca a linha 13 do CWUR.
    ('I101100930','BR','Universidade Federal de Juiz de Fora','education',36475)
  ) AS t(oa_id, country_code, display_name, type, works_count)"))

# Nomes alternativos: CINVESTAV pendurado no IPN e uma sigla reivindicada
# por duas instituicoes do mesmo pais.
invisible(dbExecute(con, "
  CREATE OR REPLACE TABLE oa_alt AS SELECT * FROM (VALUES
    ('I68368234', 'MX', 'CINVESTAV'),
    ('I3001',     'BR', 'UM'),
    ('I3002',     'BR', 'UM')
  ) AS t(oa_id, country_code, nome)"))

# As mesmas quatro tabelas dobradas que a producao monta.
invisible(dbExecute(con, "
  CREATE OR REPLACE TABLE c AS
  SELECT world_rank, institution, country_iso2,
         dobra(institution) AS f, dobra_dura(institution) AS h FROM cwur"))
invisible(dbExecute(con, "
  CREATE OR REPLACE TABLE s AS
  SELECT oa_id, country_code,
         dobra(shanghai_name) AS f1, dobra(display_name) AS f2,
         dobra(cleaned_display_name) AS f3,
         dobra_dura(shanghai_name) AS h1, dobra_dura(display_name) AS h2
  FROM shanghai"))
invisible(dbExecute(con, "
  CREATE OR REPLACE TABLE o AS
  SELECT oa_id, country_code, dobra(display_name) AS f,
         dobra_dura(display_name) AS h FROM oa"))
invisible(dbExecute(con, "
  CREATE OR REPLACE TABLE alt AS
  SELECT oa_id, country_code, dobra(nome) AS f, dobra_dura(nome) AS h
  FROM oa_alt"))

####################################################################
### Os oito bracos, exatamente como a producao os roda
####################################################################

resolvidos <- function(ate) {
  if (ate < 1L) return("SELECT NULL::INTEGER AS world_rank WHERE FALSE")
  paste(sprintf("SELECT world_rank FROM a%d", seq_len(ate)), collapse = " UNION ")
}

for (i in seq_along(cwur_arms_sql)) {
  invisible(dbExecute(con, sprintf("CREATE OR REPLACE TABLE %s AS %s",
                         names(cwur_arms_sql)[i],
                         sprintf(cwur_arms_sql[[i]], resolvidos(i - 1L)))))
}

invisible(dbExecute(con, "
  CREATE OR REPLACE TABLE casados AS
  SELECT world_rank, oa_id, n_cand, 1 AS match_arm FROM a1
  UNION ALL SELECT world_rank, oa_id, n_cand, 2 FROM a2
  UNION ALL SELECT world_rank, oa_id, n_cand, 3 FROM a3
  UNION ALL SELECT world_rank, oa_id, n_cand, 4 FROM a4
  UNION ALL SELECT world_rank, oa_id, n_cand, 5 FROM a5
  UNION ALL SELECT world_rank, oa_id, n_cand, 6 FROM a6
  UNION ALL SELECT world_rank, oa_id, n_cand, 7 FROM a7
  UNION ALL SELECT world_rank, oa_id, n_cand, 8 FROM a8"))

# n_cand e match_arm voltam como BIGINT/INTEGER do DuckDB e viram double
# no R; sao convertidos aqui para que as assercoes possam usar identical.
r <- dbGetQuery(con, "
  SELECT c.world_rank, c.institution, m.match_arm, m.oa_id, m.n_cand
  FROM c LEFT JOIN casados m USING(world_rank) ORDER BY c.world_rank")
r$match_arm <- as.integer(r$match_arm)
r$n_cand    <- as.integer(r$n_cand)

falhas <- character(0)
checa <- function(nome, ok) {
  if (!isTRUE(ok)) falhas <<- c(falhas, nome)
  invisible(ok)
}

linha <- function(i) r[r$world_rank == i, ]

####################################################################
### 1. Nenhuma linha do CWUR pode ser reivindicada por dois bracos
####################################################################

checa("um braco por linha",
      nrow(r) == dbGetQuery(con, "SELECT count(*) n FROM cwur")$n &&
        dbGetQuery(con, "
          SELECT count(*) n FROM (
            SELECT world_rank FROM casados GROUP BY 1 HAVING count(*) > 1)")$n == 0L)

####################################################################
### 2. Armadilha 1: o bloqueio por pais desempata os dois Northeastern
####################################################################

# Sem bloqueio os dois candidatos entrariam e n_cand seria 2. Com ele, o
# de Boston vence porque o CWUR diz US.
checa("northeastern resolve por pais",
      identical(linha(1)$oa_id, "I12912129") &&
        identical(linha(1)$n_cand, 1L) &&
        identical(linha(1)$match_arm, 1L))

sem_bloqueio <- dbGetQuery(con, "
  SELECT count(DISTINCT s.oa_id) AS n
  FROM c JOIN s ON c.f IN (s.f1, s.f2, s.f3)
  WHERE c.world_rank = 1")$n
checa("sem bloqueio northeastern seria ambiguo", sem_bloqueio == 2L)

####################################################################
### 3. Armadilha 2: a China cobre Hong Kong
####################################################################

checa("hong kong casa sob CN", identical(linha(3)$oa_id, "I2001") &&
        identical(linha(3)$match_arm, 2L))
checa("a excecao nao e simetrica",
      dbGetQuery(con, "SELECT pais_igual('HK', 'CN') AS v")$v == FALSE)

####################################################################
### 4. Armadilha 4: registro sem pais entra, mas so no braco 7 ou 8
####################################################################

checa("institute of science tokyo entra pelo braco 7",
      identical(linha(7)$oa_id, "I2005") && identical(linha(7)$match_arm, 7L))

# E no braco 1 o nulo do lado de Xangai e tolerado desde sempre.
checa("xangai sem pais e tolerado no braco 1",
      identical(linha(11)$oa_id, "I700") && identical(linha(11)$match_arm, 1L))

####################################################################
### 5. A dobra dura junta pontuacao e 'the ', e NAO encurta nome
####################################################################

checa("the university of tokyo casa pela dobra dura",
      identical(linha(2)$oa_id, "I2000") && identical(linha(2)$match_arm, 5L))
checa("texas a&m casa pela dobra dura",
      identical(linha(8)$oa_id, "I2004") && identical(linha(8)$match_arm, 5L))

# O par que a continencia estragaria: 'do para' e substring de
# 'do parana'. Igualdade exata, dura ou nao, mantem os dois separados.
checa("para e parana nao se confundem",
      identical(linha(4)$oa_id, "I2003") &&
        identical(linha(10)$oa_id, "I2002"))

####################################################################
### 6. Dois donos no mesmo pais: sem resposta, e n_cand denuncia
####################################################################

checa("dois donos no mesmo pais dao n_cand = 2",
      identical(linha(5)$n_cand, 2L))

####################################################################
### 7. Armadilha 3: a colisao IPN/CINVESTAV APARECE, nao e escondida
####################################################################

# O braco 3 casa CINVESTAV com o id que o braco 1 ja deu ao IPN. O
# crosswalk nao pode resolver isso sozinho: o que ele faz e deixar a
# colisao visivel para a checagem de injetividade.
colisoes <- dbGetQuery(con, "
  SELECT oa_id, count(*) AS n FROM casados WHERE oa_id IS NOT NULL
  GROUP BY 1 HAVING count(*) > 1")
checa("a colisao do CINVESTAV e detectavel",
      nrow(colisoes) == 1L && identical(colisoes$oa_id, "I68368234"))

####################################################################
### 8. Sigla reivindicada por duas instituicoes nao resolve
####################################################################

# 'UM' pertence a duas no fixture, como na vida real pertence a sete do
# ranking de Xangai. Nenhuma linha do CWUR aqui se chama UM, entao o que
# se afirma e que a consulta nao inventa dono.
checa("sigla disputada nao vira casamento",
      dbGetQuery(con, "
        SELECT count(*) n FROM casados m JOIN alt a ON a.oa_id = m.oa_id
        WHERE a.f = 'um'")$n == 0L)

####################################################################
### 9. Acentos sobrevivem a dobra
####################################################################

acentos <- dbGetQuery(con, "
  SELECT dobra('Universidade de Sao Paulo') AS d1,
         dobra(chr(85)||chr(83)||chr(80)) AS d2,
         dobra_dura('Ecole Normale Superieure') AS d3")
checa("dobra baixa e tira espaco",
      identical(acentos$d1, "universidade de sao paulo") &&
        identical(acentos$d3, "ecole normale superieure"))

####################################################################
### 10. O ajuste de Winkler e o do global_oa_hierarchy_sql.R
####################################################################

# MARTHA/MARHTA: Jaro = 17/18, prefixo 3 -> JW = 173/180. Mesma conta que
# global_oa_hierarchy_tests.R fixa para o pipeline da hierarquia.
jw <- dbGetQuery(con, "
  WITH p AS (SELECT jaro_similarity('martha','marhta') AS jaro, 3 AS prefixo)
  SELECT jaro + CASE WHEN jaro > 0.7 THEN 0.1 * prefixo * (1 - jaro) ELSE 0 END AS jw
  FROM p")$jw
checa("winkler bate com 173/180", abs(jw - 173 / 180) < 1e-12)

####################################################################
### 11-13. As atribuicoes a mao e as tres guardas que as cercam
####################################################################

# A mesma verificacao que a producao faz antes de unir ids_manuais a
# casados. Reproduzida aqui porque e ela que impede que uma linha escrita
# a mao sobreponha um braco medido ou invente um identificador.
guardas <- function(manuais) {
  invisible(dbExecute(con, "DROP TABLE IF EXISTS manuais"))
  dbWriteTable(con, "manuais", manuais, overwrite = TRUE)
  list(
    fora_lista = dbGetQuery(con, "
      SELECT count(*) n FROM manuais m
      WHERE NOT EXISTS (SELECT 1 FROM c WHERE c.world_rank = m.world_rank)")$n,
    ja_resolvido = dbGetQuery(con, "
      SELECT count(*) n FROM manuais m
      WHERE EXISTS (SELECT 1 FROM casados b WHERE b.world_rank = m.world_rank)")$n,
    sem_snapshot = dbGetQuery(con, "
      SELECT count(*) n FROM manuais m
      WHERE NOT EXISTS (SELECT 1 FROM oa WHERE oa.oa_id = m.oa_id)")$n)
}

# 11. A linha 13 e a armadilha 5 em miniatura: o CWUR a escreve em ingles
# e o OpenAlex so tem o nome em portugues, entao nenhum braco a alcanca e
# ela chega aqui sem id. A atribuicao a mao passa pelas tres guardas.
residuo <- r$world_rank[is.na(r$oa_id)]
ok <- guardas(data.frame(world_rank = 13L, oa_id = "I101100930",
                         stringsAsFactors = FALSE))
checa("atribuicao a mao sobre linha nao resolvida passa as tres guardas",
      identical(residuo, 13L) &&
        ok$fora_lista == 0L && ok$ja_resolvido == 0L && ok$sem_snapshot == 0L)

# 12. Id que nao existe no snapshot e barrado - ninguem inventa
# identificador.
mau <- guardas(data.frame(world_rank = 13L, oa_id = "I999999999",
                          stringsAsFactors = FALSE))
checa("id ausente do snapshot e barrado", mau$sem_snapshot == 1L)

# 13. Linha a mao apontando para o que um braco ja resolveu e barrada: o
# bloco escrito a mao nunca sobrepoe uma regra medida.
sobrepoe <- guardas(data.frame(world_rank = 1L, oa_id = "I2006",
                               stringsAsFactors = FALSE))
checa("atribuicao a mao nao sobrepoe braco", sobrepoe$ja_resolvido == 1L)

# E world_rank fora da lista tambem para o run.
fora <- guardas(data.frame(world_rank = 99999L, oa_id = "I2006",
                           stringsAsFactors = FALSE))
checa("world_rank fora da lista e barrado", fora$fora_lista == 1L)

####################################################################
### Resultado
####################################################################

total <- 16L
if (length(falhas)) {
  cat("FALHOU:\n"); cat(paste0("  - ", falhas, collapse = "\n"), "\n")
  stop(length(falhas), " de ", total, " assercoes falharam.")
}

cat("cwur_openalex_crosswalk_tests: ", total, " assercoes, todas passaram\n",
    sep = "")
