# Constantes SQL compartilhadas pelo crosswalk CWUR -> OpenAlex e pelos
# seus testes. Nao escreve dado nenhum.
#
# As dobras e o bloqueio por pais. dobra() e a mesma do script 15a e do
# 16; dobra_dura() acrescenta a remocao do 'the ' inicial e manda toda
# pontuacao para espaco, SEM jamais encurtar o nome - encurtar e o que
# faria 'do Para' cair dentro de 'do Parana'. pais_igual() aceita a
# China por Hong Kong, Macau e Taiwan, que o CWUR lista como 'China'.
cwur_macros_sql <- c(
  "CREATE OR REPLACE MACRO dobra(x) AS lower(strip_accents(trim(x)))",

  "CREATE OR REPLACE MACRO dobra_dura(x) AS
     trim(regexp_replace(regexp_replace(regexp_replace(
       lower(strip_accents(x)), '^the ', ''), '[^a-z0-9]+', ' ', 'g'),
       ' +', ' ', 'g'))",

  "CREATE OR REPLACE MACRO pais_igual(a, b) AS
     (b IS NOT NULL AND (a = b OR (a = 'CN' AND b IN ('HK', 'MO', 'TW'))))",

  "CREATE OR REPLACE MACRO pais_ok(a, b) AS (b IS NULL OR pais_igual(a, b))")

# Os oito bracos, em ordem de precedencia. Cada um espera as tabelas c
# (CWUR dobrado), s (lista de Xangai dobrada), o (display_name do
# snapshot dobrado) e alt (nomes alternativos dobrados), e recebe por
# sprintf a lista dos world_rank ja resolvidos pelos bracos anteriores.
#
# count(DISTINCT oa_id) e a ASSERCAO de candidato unico, nao um criterio
# de desempate: o min() so existe para haver uma coluna, e a validacao
# aborta se n_cand > 1 em qualquer braco.
cwur_arms_sql <- c(
  # O primeiro braco nao tem braco anterior, mas carrega o mesmo %s para
  # que os oito sejam interpolados do mesmo jeito; ali ele recebe uma
  # lista vazia.
  a1 = "
  SELECT c.world_rank, min(s.oa_id) AS oa_id, count(DISTINCT s.oa_id) AS n_cand
  FROM c JOIN s ON c.f IN (s.f1, s.f2, s.f3)
                AND pais_ok(c.country_iso2, s.country_code)
  WHERE c.world_rank NOT IN (%s)
  GROUP BY 1",

  a2 = "
  SELECT c.world_rank, min(o.oa_id) AS oa_id, count(DISTINCT o.oa_id) AS n_cand
  FROM c JOIN o ON c.f = o.f AND pais_igual(c.country_iso2, o.country_code)
  WHERE c.world_rank NOT IN (%s)
  GROUP BY 1",

  a3 = "
  SELECT c.world_rank, min(a.oa_id) AS oa_id, count(DISTINCT a.oa_id) AS n_cand
  FROM c JOIN alt a ON c.f = a.f AND pais_igual(c.country_iso2, a.country_code)
  WHERE c.world_rank NOT IN (%s)
  GROUP BY 1",

  a4 = "
  SELECT c.world_rank, min(s.oa_id) AS oa_id, count(DISTINCT s.oa_id) AS n_cand
  FROM c JOIN s ON c.h IN (s.h1, s.h2)
                AND pais_ok(c.country_iso2, s.country_code)
  WHERE c.world_rank NOT IN (%s)
  GROUP BY 1",

  a5 = "
  SELECT c.world_rank, min(o.oa_id) AS oa_id, count(DISTINCT o.oa_id) AS n_cand
  FROM c JOIN o ON c.h = o.h AND pais_igual(c.country_iso2, o.country_code)
  WHERE c.world_rank NOT IN (%s)
  GROUP BY 1",

  a6 = "
  SELECT c.world_rank, min(a.oa_id) AS oa_id, count(DISTINCT a.oa_id) AS n_cand
  FROM c JOIN alt a ON c.h = a.h AND pais_igual(c.country_iso2, a.country_code)
  WHERE c.world_rank NOT IN (%s)
  GROUP BY 1",

  # Bracos 7 e 8: os 7.043 registros do OpenAlex sem country_code. Vem
  # depois dos seis primeiros de proposito - o pais e a evidencia mais
  # forte que este crosswalk tem, e quem nao tem pais nao pode competir
  # com quem tem. Ver armadilha 4 no cabecalho do crosswalk.
  a7 = "
  SELECT c.world_rank, min(o.oa_id) AS oa_id, count(DISTINCT o.oa_id) AS n_cand
  FROM c JOIN o ON c.f = o.f AND o.country_code IS NULL
  WHERE c.world_rank NOT IN (%s)
  GROUP BY 1",

  a8 = "
  SELECT c.world_rank, min(a.oa_id) AS oa_id, count(DISTINCT a.oa_id) AS n_cand
  FROM c JOIN alt a ON c.f = a.f AND a.country_code IS NULL
  WHERE c.world_rank NOT IN (%s)
  GROUP BY 1")

# O ajuste de Winkler do global_oa_hierarchy_sql.R - p = 0,1, prefixo
# <= 4, so quando Jaro > 0,7 - sobre a dobra dura, para que as duas
# rotinas ordenem candidato do mesmo jeito. SUGESTAO, NAO DECISAO: ver o
# paragrafo sobre o residuo no cabecalho do crosswalk. Recebe por
# sprintf quantos candidatos por linha entram na planilha.
cwur_worksheet_sql <- "
  WITH r AS (
    SELECT * FROM c WHERE world_rank NOT IN (SELECT world_rank FROM casados)
  ), pares AS (
    SELECT r.world_rank, r.institution, r.country_iso2,
           f.oa_id, x.display_name, x.type, x.works_count,
           jaro_similarity(r.h, f.h) AS jaro,
           least(4, length(r.h), length(f.h),
             CASE WHEN substr(r.h,1,1) <> substr(f.h,1,1) THEN 0
                  WHEN substr(r.h,2,1) <> substr(f.h,2,1) THEN 1
                  WHEN substr(r.h,3,1) <> substr(f.h,3,1) THEN 2
                  WHEN substr(r.h,4,1) <> substr(f.h,4,1) THEN 3
                  ELSE 4 END) AS prefixo
    FROM r JOIN o f ON pais_ok(r.country_iso2, f.country_code)
           JOIN oa x ON x.oa_id = f.oa_id
    WHERE f.country_code IS NOT NULL
  ), pontuado AS (
    SELECT *, jaro + CASE WHEN jaro > 0.7
                          THEN 0.1 * prefixo * (1 - jaro) ELSE 0 END AS jw
    FROM pares
  )
  SELECT world_rank, institution, country_iso2, candidato, oa_id,
         display_name, round(jw, 4) AS jw, type AS oa_type, works_count
  FROM (
    SELECT *, row_number() OVER (PARTITION BY world_rank
                                 ORDER BY jw DESC, works_count DESC) AS candidato
    FROM pontuado)
  WHERE candidato <= %d
  ORDER BY world_rank, candidato"
