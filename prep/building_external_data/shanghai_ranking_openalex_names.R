####################################################################
### Nome OpenAlex para as instituicoes do ranking de Xangai
###
### Le shanghai_ranking_full_cleaned.xlsx (Dropbox GTAllocation), que
### ja traz OA_id e OA_key, busca o display_name correspondente no
### snapshot local de institutions do OpenAlex e grava um parquet no
### Dropbox do OBMEP com as colunas originais mais display_name e
### cleaned_display_name.
###
### O join e por ID, nao por nome: OA_key ja e o id curto do OpenAlex.
### A limpeza de nome reusa a mesma regra de
### prep/openalex_br_institutions.R (remove apenas expressoes entre
### parenteses, preserva acentos), para que os dois arquivos limpem
### nome do mesmo jeito.
###
### Pontos de atencao, verificados nos dados:
###
###  - O xlsx tem 1.079 linhas, todas com OA_id e OA_key preenchidos e
###    sem OA_key repetido. 1.076 casam com o snapshot; 3 nao casam e
###    ficam com display_name nulo:
###      * 'Rutgers University - Newark' tem o NOME repetido dentro de
###        OA_id e OA_key em vez de um id. E um defeito do arquivo de
###        origem, nao do join.
###      * 'Ecole Polytechnique' (I4408541918) e
###        'Victor Segalen Bordeaux 2 University' (I4407990165) tem id
###        bem formado mas ausente do snapshot. Provavel merge ou
###        exclusao no OpenAlex depois deste dump; esta copia do
###        snapshot nao traz a arvore merged_ids/, entao nao da para
###        resolver o redirecionamento aqui.
###  - O snapshot NAO e deduplicado por construcao mas nesta copia as
###    particoes sao disjuntas (120.658 linhas, 120.658 ids). A
###    deduplicacao por id abaixo e salvaguarda: sem ela um id repetido
###    em duas particoes multiplicaria linhas do ranking no join.
###  - country_code do xlsx e do snapshot concordam em 1.075 dos 1.076
###    casados. A unica divergencia e 'Osaka Metropolitan University',
###    nula no xlsx e 'JP' no snapshot, ou seja ausencia e nao conflito.
###  - 769 dos 1.076 shanghai_Name ja sao identicos ao display_name;
###    307 diferem. E para esses 307 que a coluna nova serve.
###
### 6. NOMES ALTERNATIVOS SAEM NUM SEGUNDO ARQUIVO, longo, uma linha
###    por (OA_key, nome), com a coluna kind separando as duas listas
###    do OpenAlex: display_name_acronyms e display_name_alternatives.
###
###    Dois motivos para o arquivo ser separado em vez de virar coluna
###    de lista em shanghai_ranking_oa.parquet. Primeiro, os scripts 16
###    e 20 afirmam o numero de linhas e de colunas daquele parquet, e
###    um arquivo novo nao mexe em nada que eles leem. Segundo, o grao
###    e outro: 1.079 instituicoes contra milhares de nomes.
###
###    A coluna kind e obrigatoria porque o risco das duas listas nao e
###    o mesmo. Sigla colide muito: 'UM' e reivindicada por SETE
###    instituicoes do ranking (Maastricht, Malaya, Montana, Muenster,
###    Miami, Michigan e Macau), 'UW' e 'CMU' por cinco cada. Nome
###    alternativo por extenso quase nao colide. Quem consumir este
###    arquivo tem de tratar os dois tipos com regras diferentes -- ver
###    shanghai_acronym_arm.R, que so aceita sigla reivindicada por uma
###    unica instituicao.
####################################################################

for (p in c("DBI", "duckdb", "arrow", "readxl")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Pacote ausente: ", p, ". Instale antes de rodar este script.")
  }
}
library(DBI)
library(duckdb)

####################################################################
### Parametros
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
gt_root    <- Sys.getenv("GT_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/GTAllocation")

sh_path <- file.path(gt_root,
                     "Data/intermediate/shanghai_ranking_full_cleaned.xlsx")
oa_dir  <- file.path(gt_root, "Data/external/oa_snapshot/data/institutions")
oa_glob <- file.path(oa_dir, "updated_date=*/part_*.gz")

out_dir  <- file.path(obmep_root, "Data/intermediate/shanghai_ranking")
out_path <- file.path(out_dir, "shanghai_ranking_oa.parquet")

# Segundo arquivo, longo: uma linha por (OA_key, nome alternativo). Ver
# nota 6. Fica separado para nao mexer na forma de out_path, cujo
# numero de linhas e de colunas os scripts 16 e 20 afirmam.
alt_path <- file.path(out_dir, "shanghai_ranking_oa_acronyms.parquet")

mem_limit <- "8GB"

# Valores medidos contra o xlsx atual e o snapshot de fevereiro/2026.
exp_rows      <- 1079L
exp_matched   <- 1076L
exp_unmatched <- 3L

# Os 3 ids que nao casam. Ficam explicitos para que um numero de
# ausencias diferente do esperado aponte quais mudaram.
exp_missing <- c("I4408541918", "I4407990165", "RUTGERS UNIVERSITY - NEWARK")

# Tabela longa de nomes alternativos. Preenchidos apos a primeira
# rodada; divergencia aqui e sinal de snapshot novo, nao de erro.
exp_alt_acr  <- 701L
exp_alt_alt  <- 3123L
exp_alt_inst <- 1076L

dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_openalex")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(file.exists(sh_path), dir.exists(oa_dir),
          length(Sys.glob(oa_glob)) > 0L)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
# temp_directory explicito: o derrame para disco nao pode cair em
# pasta sincronizada pelo Dropbox.
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

cat("DuckDB:", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("ranking:", sh_path, "\n")
cat("saida  :", out_path, "\n\n")

####################################################################
### Ranking de Xangai
####################################################################

sh <- readxl::read_excel(sh_path)
sh <- as.data.frame(sh, stringsAsFactors = FALSE)

cat("linhas do xlsx:", nrow(sh), "| colunas:", ncol(sh), "\n")
stopifnot(nrow(sh) > 0L, "OA_key" %in% names(sh))

# OA_key tem de ser unico: e a chave do join.
stopifnot(!any(duplicated(sh$OA_key)))

dbWriteTable(con, "sh", sh, overwrite = TRUE)

####################################################################
### Nomes do snapshot OpenAlex
####################################################################

# Apenas id, display_name e as duas listas de nome alternativo sao
# lidos. A projecao explicita faz o leitor JSON ignorar topics,
# topic_share e counts_by_year, que respondem por quase todo o tamanho
# dos registros. Ver nota sobre nomes alternativos no cabecalho.
sql_read <- sprintf("
  read_ndjson(
    '%s',
    filename = true,
    columns = {
      id: 'VARCHAR',
      display_name: 'VARCHAR',
      display_name_acronyms: 'VARCHAR[]',
      display_name_alternatives: 'VARCHAR[]'
    }
  )", oa_glob)

# Deduplicacao por id, mantendo a particao mais recente. O nome da
# pasta e ISO e ordena lexicograficamente; o updated_date de dentro do
# registro vem em formato americano e nao serve para ordenar.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE oa AS
  SELECT
    regexp_extract(id, 'I[0-9]+') AS oa_key,
    display_name,
    display_name_acronyms,
    display_name_alternatives
  FROM (
    SELECT
      id,
      display_name,
      display_name_acronyms,
      display_name_alternatives,
      regexp_extract(filename, 'updated_date=([0-9]{4}-[0-9]{2}-[0-9]{2})', 1)
        AS snapshot_date
    FROM %s
  )
  QUALIFY row_number() OVER (PARTITION BY id ORDER BY snapshot_date DESC) = 1",
  sql_read))

cat("instituicoes no snapshot:",
    dbGetQuery(con, "SELECT count(*) n FROM oa")$n, "\n\n")

####################################################################
### Join e limpeza do nome
####################################################################

# LEFT JOIN: o ranking manda. Nenhuma linha do xlsx pode ser perdida
# nem duplicada, mesmo que o id nao exista no snapshot.
dbExecute(con, "
  CREATE OR REPLACE TABLE sh_oa AS
  SELECT
    s.*,
    o.display_name,
    -- Mesma regra de prep/openalex_br_institutions.R: remove apenas
    -- expressoes entre parenteses, sem tocar em acento nem caixa.
    trim(regexp_replace(
      regexp_replace(o.display_name, '\\s*\\([^()]*\\)', '', 'g'),
      '\\s+', ' ', 'g'))          AS cleaned_display_name
  FROM sh s
  LEFT JOIN oa o ON o.oa_key = s.OA_key
  ORDER BY s.Rank")

dbExecute(con, sprintf(
  "COPY sh_oa TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", out_path))

####################################################################
### Tabela longa de nomes alternativos
####################################################################

# Uma linha por (OA_key, nome alternativo), com kind separando as duas
# listas do OpenAlex. Ver nota 6: sigla e nome alternativo tem risco de
# colisao muito diferente e nao podem ser consumidos como se fossem a
# mesma coisa, entao a coluna kind e obrigatoria e nao ha deduplicacao
# entre os dois tipos.
dbExecute(con, "
  CREATE OR REPLACE TABLE sh_alt AS
  SELECT OA_key, shanghai_Name, Rank, country_code, kind, alt_name
  FROM (
    SELECT s.OA_key, s.shanghai_Name, s.Rank, s.country_code,
           'acronym' AS kind, trim(a) AS alt_name
    FROM sh s
    JOIN oa o ON o.oa_key = s.OA_key,
         unnest(o.display_name_acronyms) t(a)
    UNION ALL
    SELECT s.OA_key, s.shanghai_Name, s.Rank, s.country_code,
           'alternative' AS kind, trim(a) AS alt_name
    FROM sh s
    JOIN oa o ON o.oa_key = s.OA_key,
         unnest(o.display_name_alternatives) t(a)
  )
  WHERE alt_name IS NOT NULL AND alt_name <> ''
  ORDER BY Rank, OA_key, kind, alt_name")

dbExecute(con, sprintf(
  "COPY sh_alt TO '%s' (FORMAT PARQUET, COMPRESSION ZSTD)", alt_path))

####################################################################
### Validacao
####################################################################

res <- dbGetQuery(con, "
  SELECT
    count(*)                                    AS linhas,
    count(DISTINCT OA_key)                      AS chaves,
    sum(display_name IS NOT NULL)               AS casadas,
    sum(display_name IS NULL)                   AS sem_match,
    sum(display_name IS NOT NULL
        AND shanghai_Name = display_name)       AS nome_igual,
    sum(display_name IS NOT NULL
        AND shanghai_Name <> display_name)      AS nome_diferente,
    sum(cleaned_display_name IS NOT NULL
        AND (cleaned_display_name LIKE '%('
          OR cleaned_display_name LIKE '%)'))   AS sobra_paren,
    sum(display_name IS NOT NULL
        AND display_name <> cleaned_display_name) AS limpeza_alterou
  FROM sh_oa")

cat("linhas gravadas      :", res$linhas, "\n")
cat("chaves distintas     :", res$chaves, "\n")
cat("com display_name     :", res$casadas, "\n")
cat("sem display_name     :", res$sem_match, "\n")
cat("nome igual ao shangai:", res$nome_igual, "\n")
cat("nome diferente       :", res$nome_diferente, "\n")
cat("limpeza alterou      :", res$limpeza_alterou, "\n\n")

# O LEFT JOIN nao pode ter criado nem perdido linha. Esta e a checagem
# que pega um id repetido no snapshot virando fan-out no ranking.
stopifnot(res$linhas == nrow(sh),
          res$chaves == nrow(sh),
          res$sobra_paren == 0L,
          res$casadas + res$sem_match == res$linhas)

# Regressao contra os valores medidos.
if (res$linhas != exp_rows || res$casadas != exp_matched ||
    res$sem_match != exp_unmatched) {
  warning("Cobertura diverge do esperado (", exp_matched, " de ", exp_rows,
          ", ", exp_unmatched, " sem match). O xlsx ou o snapshot mudou?")
}

faltantes <- dbGetQuery(con, "
  SELECT OA_key, shanghai_Name, Rank, country_code
  FROM sh_oa WHERE display_name IS NULL ORDER BY shanghai_Name")

cat("Sem correspondencia no snapshot:\n")
print(faltantes, right = FALSE)

novos <- setdiff(faltantes$OA_key, exp_missing)
if (length(novos)) {
  warning("Ids sem match nao previstos: ", paste(novos, collapse = ", "))
}

# Releitura com arrow: confirma que o parquet e legivel fora do DuckDB.
df <- arrow::read_parquet(out_path)
cat("\nreleitura arrow:", nrow(df), "linhas,", ncol(df), "colunas\n")
cat("colunas:", paste(names(df), collapse = ", "), "\n")
stopifnot(nrow(df) == nrow(sh),
          all(c("display_name", "cleaned_display_name") %in% names(df)))

cat("\nAmostra onde o nome do ranking difere do OpenAlex:\n")
dif <- df[!is.na(df$display_name) & df$shanghai_Name != df$display_name,
          c("Rank", "shanghai_Name", "display_name")]
print(head(dif[order(dif$Rank), ], 15), right = FALSE)

cat("\nGravado:", out_path, "\n")
cat("tamanho:", round(file.size(out_path) / 1024, 1), "KB\n")

####################################################################
### Validacao da tabela longa
####################################################################

alt <- dbGetQuery(con, "
  SELECT
    sum(CASE WHEN kind = 'acronym'     THEN 1 ELSE 0 END) AS n_acr,
    sum(CASE WHEN kind = 'alternative' THEN 1 ELSE 0 END) AS n_alt,
    count(DISTINCT OA_key)                                AS n_inst,
    count(DISTINCT CASE WHEN kind = 'acronym'
                        THEN OA_key END)                  AS n_inst_acr,
    count(*)                                              AS n_all
  FROM sh_alt")

cat("\nnomes alternativos     :", alt$n_all, "linhas\n")
cat("  siglas               :", alt$n_acr, "em", alt$n_inst_acr, "instituicoes\n")
cat("  nomes alternativos   :", alt$n_alt, "\n")
cat("  instituicoes cobertas:", alt$n_inst, "de", nrow(sh), "\n")

# Nenhuma linha da tabela longa pode citar um OA_key fora do ranking.
orfaos <- dbGetQuery(con, "
  SELECT count(*) AS n FROM sh_alt a
  WHERE NOT EXISTS (SELECT 1 FROM sh s WHERE s.OA_key = a.OA_key)")$n
if (orfaos != 0L) stop(orfaos, " linhas de sh_alt com OA_key fora do ranking.")

stopifnot(alt$n_acr + alt$n_alt == alt$n_all, alt$n_inst <= nrow(sh))

if (alt$n_acr != exp_alt_acr || alt$n_alt != exp_alt_alt ||
    alt$n_inst != exp_alt_inst) {
  warning("Tabela longa diverge do esperado (", exp_alt_acr, " siglas, ",
          exp_alt_alt, " alternativos, ", exp_alt_inst, " instituicoes). ",
          "O snapshot mudou?")
}

df_alt <- arrow::read_parquet(alt_path)
stopifnot(nrow(df_alt) == alt$n_all,
          all(c("OA_key", "kind", "alt_name") %in% names(df_alt)))

cat("\nGravado:", alt_path, "\n")
cat("tamanho:", round(file.size(alt_path) / 1024, 1), "KB\n")
