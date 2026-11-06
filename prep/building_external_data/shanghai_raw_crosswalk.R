####################################################################
###
### Crosswalk university_raw -> instituicao do ranking de Xangai
###                                                    [local only]
###
### Os scripts 16, 16a e 8g reconstroem o casamento com o ranking cada
### um por sua conta e publicam SO flags por user_id. Nenhum publica o
### MAPA: qual string digitada corresponde a qual instituicao, e o que
### o university_name e o rsid do proprio Revelio dizem sobre ela.
###
### Este script publica esse mapa.
###
### Saida:
###   shanghai_raw_crosswalk.parquet   uma linha por
###                                    (university_raw, university_name, rsid)
###
### Depends on:
###   shanghai_ranking_openalex_names.R      (4)   nomes e siglas
###   shanghai_acronym_arm.R                 (16a) a revisao das siglas
###   obmep_candidates_step_1_education/     (10a) as strings observadas
###
### NO NETWORK. Le parquet e csv locais, escreve parquet local.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. ISTO E UM ARTEFATO DE CONSULTA, NAO UM PRODUTO DE FLAG. Ele
###    carrega evidencia e rotulo; quem consome decide no que confiar.
###    Em particular as linhas rotuladas WRONG e AMBIGUOUS FICAM na
###    tabela. Esconder o que foi rejeitado tornaria o arquivo inutil
###    para auditoria, que e metade do motivo de ele existir.
###
###    O FILTRO RECOMENDADO, para quem so quer o mapa confiavel:
###
###      WHERE by_acronym = 0 OR acr_label = 'OK'
###
### 2. O CASAMENTO E DE STRING INTEIRA, sobre a dobra padrao da pasta
###    lower(strip_accents(trim())). Nao ha braco de segmento aqui: o
###    grao e a string digitada, e um pedaco de string nao identifica
###    instituicao com a confianca que uma tabela de consulta precisa.
### 3. SO CHAVE DE DONO UNICO ENTRA. Uma grafia reivindicada por duas
###    instituicoes do ranking e descartada, sem desempate. E a mesma
###    regra da nota 2 do script 16a, e pelo mesmo motivo: 'UM' e
###    reivindicada por sete instituicoes, e escolher a melhor colocada
###    seria sorteio.
### 4. TRES BRACOS, E ELES NAO VALEM O MESMO:
###
###      name      display_name, cleaned_display_name, shanghai_Name
###      name_alt  display_name_alternatives do OpenAlex
###      acronym   display_name_acronyms do OpenAlex
###
###    by_name, by_name_alt e by_acronym dizem quais dispararam; uma
###    tripla que casa por dois bracos e UMA linha, nao duas.
###    match_arm guarda o melhor braco na ordem name > name_alt >
###    acronym, mas as tres colunas by_ preservam o quadro inteiro,
###    entao a precedencia nao esconde nada.
###
###    O braco name_alt e o MAIOR dos tres em linhas de educacao e e o
###    que resolve endonimo -- "Universita degli Studi di Torino" chega
###    a University of Turin por ele, nunca por display_name. Ele
###    tambem e o menos vigiado: nao passou por revisao. Some com
###    by_name_alt = 0 se nao quiser.
### 5. A REVISAO DAS SIGLAS NAO E REFEITA AQUI. Ela ja existe, em
###    shanghai_acronym_class.csv: 209 strings, 104 OK, 85 WRONG, 20
###    AMBIGUOUS, cada uma com o motivo escrito. Este script apenas a
###    carrega em acr_label/acr_note e ABORTA se alguma linha do braco
###    da sigla ficar sem rotulo -- isso significaria que o ranking ou
###    a faixa mudou e a revisao envelheceu.
### 6. A FAIXA E Rank <= 901, as mesmas 1.000 instituicoes dos scripts
###    16, 16a e 8g. Isso deixa de fora as 79 linhas do ranking com
###    Rank nulo, e a troca e deliberada: dentro da faixa a revisao das
###    siglas cobre o braco da sigla exatamente, sem casamento nao
###    revisado.
### 7. O MAPA E UMA FUNCAO HOJE, e a coluna existe para o dia em que
###    deixar de ser. n_institutions > 1 marcaria a tripla que alcanca
###    duas instituicoes diferentes por bracos diferentes. Medido
###    dentro da faixa: ZERO. Fora da faixa havia 2, o que e mais um
###    argumento para a nota 6. Se aparecer alguma, ela fica marcada em
###    vez de colapsada -- colapsar seria escolher por quem consome.
### 8. O GRAO E A GRAFIA, NAO A STRING DOBRADA. "USP" e "usp" sao duas
###    linhas, de proposito: quem consome junta por university_raw
###    exato, e uma tabela chaveada pela dobra obrigaria cada consumidor
###    a redobrar. 4.282 linhas para 1.950 grafias dobradas distintas.
###    raw_fold esta na tabela para quem preferir o grao dobrado.
### 9. O UNIVERSO E O EXTRATO DA COORTE, nao o Revelio inteiro. Uma
###    string que ninguem da coorte digitou nao aparece aqui, ainda que
###    case com o ranking.
####################################################################

rm(list = ls()); gc()

for (p in c("DBI", "duckdb", "arrow")) {
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

rank_dir  <- file.path(obmep_root, "Data/intermediate/shanghai_ranking")
sh_path   <- file.path(rank_dir, "shanghai_ranking_oa.parquet")
alt_path  <- file.path(rank_dir, "shanghai_ranking_oa_acronyms.parquet")

coh_dir    <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
ed_dir     <- file.path(coh_dir, "obmep_candidates_step_1_education")
class_path <- file.path(coh_dir, "shanghai_acronym_class.csv")
out_path   <- file.path(coh_dir, "shanghai_raw_crosswalk.parquet")

rank_cut  <- 901L
mem_limit <- "8GB"

# Medidos DENTRO da faixa Rank <= 901 (nota 6). Divergencia e sinal de
# entrada nova -- warning, nao stop.
#
# O braco da sigla reproduz o script 16a exatamente: 486 chaves, 209
# strings, 17.927 linhas de educacao. E a checagem cruzada mais forte
# que este script tem -- as duas contagens vem de codigos diferentes.
exp_keys      <- c(name = 1243L, name_alt = 2884L, acronym = 486L)
exp_arm_trip  <- c(name = 2573L, name_alt = 3661L, acronym = 481L)
exp_rows      <- 4282L
exp_strings   <- 1950L   # raw_fold distintos; as linhas sao por GRAFIA
exp_rsids     <- 1201L
exp_insts     <- 970L
exp_ambiguous <- 0L      # nenhuma tripla alcanca duas instituicoes

tmp_dir <- file.path(Sys.getenv("TEMP"), "duckdb_tmp_sh_crosswalk")
dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)

stopifnot(file.exists(sh_path), file.exists(alt_path), file.exists(class_path),
          dir.exists(ed_dir), length(Sys.glob(file.path(ed_dir, "*"))) > 0L)

####################################################################
### Conexao
####################################################################

con <- dbConnect(duckdb())
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

dbExecute(con, sprintf("PRAGMA memory_limit='%s'", mem_limit))
dbExecute(con, sprintf("SET temp_directory='%s'", tmp_dir))

# A dobra padrao da pasta, identica a dos scripts 16, 16a, 19 e 20.
dbExecute(con, "CREATE MACRO fs(s) AS lower(strip_accents(trim(s)))")

fw <- function(p) gsub("\\\\", "/", p)
rp <- function(p) sprintf("read_parquet('%s')", fw(p))
ed_src <- sprintf("read_parquet('%s/*')", fw(ed_dir))

cat("DuckDB   :", dbGetQuery(con, "SELECT version() AS v")$v, "\n")
cat("ranking  :", basename(sh_path), "\n")
cat("nomes alt:", basename(alt_path), "\n")
cat("revisao  :", basename(class_path), "\n")
cat("educacao :", ed_dir, "\n")
cat("saida    :", out_path, "\n\n")

####################################################################
### A -- a faixa e as chaves de casamento
####################################################################

n_top <- dbGetQuery(con, sprintf(
  "SELECT sum(CASE WHEN Rank <= %d THEN 1 ELSE 0 END) AS n FROM %s",
  rank_cut, rp(sh_path)))$n
if (n_top != 1000L) {
  stop("Rank <= ", rank_cut, " seleciona ", n_top, " linhas, nao 1000. ",
       "As faixas do ranking mudaram; refaca a aritmetica em vez de ",
       "reinterpretar o corte.")
}

# Uma chave por (grafia dobrada, braco). Nota 3: so dono unico. O
# HAVING e por braco, entao 'usp' pode ser chave de name e de acronym
# ao mesmo tempo -- que e o caso real e o que a nota 4 preserva.
dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE k AS
  SELECT nm_fold, arm,
         any_value(oid)  AS openalex_id,
         any_value(disp) AS oa_display_name,
         any_value(shn)  AS shanghai_name,
         any_value(cc)   AS country_code,
         CAST(min(rk) AS INTEGER) AS shanghai_rank
  FROM (
    SELECT fs(display_name)         AS nm_fold, 'name'     AS arm, OA_key AS oid,
           display_name AS disp, shanghai_Name AS shn, country_code AS cc,
           Rank AS rk FROM %1$s WHERE Rank <= %3$d
    UNION ALL
    SELECT fs(cleaned_display_name), 'name',     OA_key,
           display_name, shanghai_Name, country_code, Rank
      FROM %1$s WHERE Rank <= %3$d
    UNION ALL
    SELECT fs(shanghai_Name),        'name',     OA_key,
           display_name, shanghai_Name, country_code, Rank
      FROM %1$s WHERE Rank <= %3$d
    UNION ALL
    SELECT fs(a.alt_name),           'name_alt', a.OA_key,
           s.display_name, a.shanghai_Name, a.country_code, a.Rank
      FROM %2$s a JOIN %1$s s ON s.OA_key = a.OA_key
      WHERE a.kind = 'alternative' AND a.Rank <= %3$d
    UNION ALL
    SELECT fs(a.alt_name),           'acronym',  a.OA_key,
           s.display_name, a.shanghai_Name, a.country_code, a.Rank
      FROM %2$s a JOIN %1$s s ON s.OA_key = a.OA_key
      WHERE a.kind = 'acronym' AND a.Rank <= %3$d
        AND length(trim(a.alt_name)) >= 2
  )
  WHERE nm_fold IS NOT NULL AND length(nm_fold) >= 2
  GROUP BY nm_fold, arm
  HAVING count(DISTINCT oid) = 1", rp(sh_path), rp(alt_path), rank_cut))

kc <- dbGetQuery(con, "SELECT arm, count(*) AS chaves FROM k GROUP BY 1 ORDER BY 1")
cat("--- chaves de dono unico, por braco (nota 3) ---\n")
print(kc, right = FALSE, row.names = FALSE)

####################################################################
### B -- as triplas observadas na coorte
####################################################################

dbExecute(con, sprintf("
  CREATE OR REPLACE TABLE trip AS
  SELECT fs(university_raw)      AS raw_fold,
         university_raw, university_name, rsid,
         count(*)                AS n_rows,
         count(DISTINCT user_id) AS n_users
  FROM %s
  WHERE university_raw IS NOT NULL AND trim(university_raw) <> ''
  GROUP BY 1, 2, 3, 4", ed_src))

cat("\ntriplas observadas   :",
    format(dbGetQuery(con, "SELECT count(*) n FROM trip")$n, big.mark = ","), "\n")

####################################################################
### C -- uma linha por tripla, bracos em coluna (nota 4)
####################################################################

dbExecute(con, "
  CREATE OR REPLACE TABLE hit AS
  SELECT t.raw_fold, t.university_raw, t.university_name, t.rsid,
         t.n_rows, t.n_users, k.arm, k.openalex_id, k.oa_display_name,
         k.shanghai_name, k.shanghai_rank, k.country_code
  FROM trip t JOIN k ON k.nm_fold = t.raw_fold")

arm_trip <- dbGetQuery(con, "
  SELECT arm, count(*) AS triplas, count(DISTINCT raw_fold) AS strings,
         count(DISTINCT rsid) AS rsids, sum(n_rows) AS linhas,
         sum(n_users) AS pessoas
  FROM hit GROUP BY 1 ORDER BY linhas DESC")
cat("\n--- casamento por braco ---\n")
print(arm_trip, right = FALSE, row.names = FALSE)

# A precedencia name > name_alt > acronym vira um numero para o arg_min.
# As colunas by_ abaixo guardam o quadro inteiro de qualquer forma.
dbExecute(con, "
  CREATE OR REPLACE TABLE xw AS
  SELECT university_raw, raw_fold, university_name, rsid, n_rows, n_users,
         arg_min(openalex_id,     pri) AS openalex_id,
         arg_min(oa_display_name, pri) AS oa_display_name,
         arg_min(shanghai_name,   pri) AS shanghai_name,
         arg_min(shanghai_rank,   pri) AS shanghai_rank,
         arg_min(country_code,    pri) AS country_code,
         arg_min(arm,             pri) AS match_arm,
         CAST(max(CASE WHEN arm = 'name'     THEN 1 ELSE 0 END) AS INTEGER) AS by_name,
         CAST(max(CASE WHEN arm = 'name_alt' THEN 1 ELSE 0 END) AS INTEGER) AS by_name_alt,
         CAST(max(CASE WHEN arm = 'acronym'  THEN 1 ELSE 0 END) AS INTEGER) AS by_acronym,
         CAST(count(DISTINCT openalex_id) AS INTEGER)                       AS n_institutions
  FROM (
    SELECT h.*, CASE arm WHEN 'name' THEN 1 WHEN 'name_alt' THEN 2 ELSE 3 END AS pri
    FROM hit h
  )
  GROUP BY university_raw, raw_fold, university_name, rsid, n_rows, n_users")

####################################################################
### D -- a revisao das siglas, carregada e nao refeita (nota 5)
####################################################################

cls <- read.csv(class_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8")
stopifnot(all(c("acr_fold", "label", "note") %in% names(cls)))
cls <- data.frame(acr_fold = trimws(cls$acr_fold),
                  acr_label = toupper(trimws(cls$label)),
                  acr_note  = cls$note,
                  stringsAsFactors = FALSE)
if (anyDuplicated(cls$acr_fold)) stop("acr_fold repetido na revisao.")
cat("\n--- revisao das siglas carregada ---\n")
print(table(cls$acr_label), right = FALSE)

dbWriteTable(con, "acr_cls", cls, overwrite = TRUE)

dbExecute(con, "
  CREATE OR REPLACE TABLE saida AS
  SELECT x.university_raw, x.raw_fold, x.university_name, x.rsid,
         x.n_rows, x.n_users,
         x.openalex_id, x.oa_display_name, x.shanghai_name,
         x.shanghai_rank, x.country_code,
         x.by_name, x.by_name_alt, x.by_acronym,
         x.match_arm,
         CASE WHEN x.by_acronym = 1 THEN c.acr_label END AS acr_label,
         CASE WHEN x.by_acronym = 1 THEN c.acr_note  END AS acr_note,
         x.n_institutions
  FROM xw x LEFT JOIN acr_cls c ON c.acr_fold = x.raw_fold")

####################################################################
### Validacao
####################################################################

cat("\n=========== VALIDACAO ===========\n")

v <- dbGetQuery(con, "
  SELECT count(*)                                            AS n_rows,
         count(DISTINCT (university_raw, university_name, rsid)) AS n_trip,
         count(DISTINCT raw_fold)                            AS n_strings,
         count(DISTINCT rsid)                                AS n_rsids,
         count(DISTINCT openalex_id)                         AS n_insts,
         sum(CASE WHEN by_name + by_name_alt + by_acronym = 0
                  THEN 1 ELSE 0 END)                         AS bad_noarm,
         sum(CASE WHEN (match_arm = 'name'     AND by_name     = 0)
                    OR (match_arm = 'name_alt' AND by_name_alt = 0)
                    OR (match_arm = 'acronym'  AND by_acronym  = 0)
                  THEN 1 ELSE 0 END)                         AS bad_arm,
         sum(CASE WHEN by_acronym = 1 AND acr_label IS NULL
                  THEN 1 ELSE 0 END)                         AS bad_unrev,
         sum(CASE WHEN by_acronym = 0 AND acr_label IS NOT NULL
                  THEN 1 ELSE 0 END)                         AS bad_stray,
         sum(CASE WHEN openalex_id IS NULL THEN 1 ELSE 0 END) AS bad_null,
         sum(CASE WHEN n_institutions > 1 THEN 1 ELSE 0 END)  AS n_ambig
  FROM saida")
print(as.data.frame(v), right = FALSE, row.names = FALSE)

if (v$n_rows != v$n_trip) {
  stop("A tabela tem ", v$n_rows, " linhas para ", v$n_trip, " triplas. ",
       "Um braco duplicou tripla; ver nota 4.")
}
if (v$bad_noarm != 0) stop(v$bad_noarm, " linhas sem nenhum braco ligado.")
if (v$bad_arm   != 0) stop(v$bad_arm, " linhas com match_arm sem o by_ correspondente.")
if (v$bad_null  != 0) stop(v$bad_null, " linhas sem openalex_id.")
if (v$bad_stray != 0) {
  stop(v$bad_stray, " linhas com acr_label fora do braco da sigla.")
}
# Nota 5: sigla sem rotulo significa revisao velha, e isso para o script.
if (v$bad_unrev != 0) {
  print(dbGetQuery(con, "
    SELECT DISTINCT raw_fold, oa_display_name FROM saida
    WHERE by_acronym = 1 AND acr_label IS NULL ORDER BY raw_fold LIMIT 20"),
    right = FALSE, row.names = FALSE)
  stop(v$bad_unrev, " linhas do braco da sigla sem rotulo em ",
       basename(class_path), ". A revisao envelheceu: o ranking ou a ",
       "faixa mudou. Revise as siglas novas antes de publicar.")
}

chk <- function(nome, obtido, esperado) {
  if (obtido != esperado) {
    warning(nome, ": ", format(obtido, big.mark = ","), " (esperado ",
            format(esperado, big.mark = ","), ")", call. = FALSE)
  }
}
for (a in names(exp_keys)) {
  chk(paste("chaves", a), kc$chaves[kc$arm == a], exp_keys[[a]])
  chk(paste("triplas", a), arm_trip$triplas[arm_trip$arm == a], exp_arm_trip[[a]])
}
chk("linhas",        v$n_rows,    exp_rows)
chk("strings",       v$n_strings, exp_strings)
chk("rsids",         v$n_rsids,   exp_rsids)
chk("instituicoes",  v$n_insts,   exp_insts)
chk("ambiguas",      v$n_ambig,   exp_ambiguous)

# Nota 7: as ambiguas ficam, marcadas, e sao impressas para inspecao.
if (v$n_ambig > 0) {
  cat("\n--- triplas que alcancam mais de uma instituicao (nota 7) ---\n")
  print(dbGetQuery(con, "
    SELECT university_raw, university_name, rsid, n_users,
           by_name, by_name_alt, by_acronym, match_arm, oa_display_name
    FROM saida WHERE n_institutions > 1 ORDER BY n_users DESC"),
    right = FALSE, row.names = FALSE)
}

####################################################################
### Escrita e releitura
####################################################################

dbExecute(con, sprintf(
  "COPY (SELECT * FROM saida ORDER BY n_users DESC, university_raw) TO '%s'
   (FORMAT PARQUET, COMPRESSION ZSTD)", fw(out_path)))

df <- arrow::read_parquet(out_path)
stopifnot(identical(names(df), c(
  "university_raw", "raw_fold", "university_name", "rsid",
  "n_rows", "n_users",
  "openalex_id", "oa_display_name", "shanghai_name", "shanghai_rank",
  "country_code",
  "by_name", "by_name_alt", "by_acronym", "match_arm",
  "acr_label", "acr_note", "n_institutions")))
stopifnot(nrow(df) == v$n_rows, ncol(df) == 18L)

####################################################################
### Relatorio
####################################################################

cat("\n=========== O MAPA, POR BRACO VENCEDOR ===========\n")
print(dbGetQuery(con, "
  SELECT match_arm, count(*) AS linhas, sum(n_rows) AS linhas_educacao,
         sum(n_users) AS pessoas
  FROM saida GROUP BY 1 ORDER BY linhas_educacao DESC"),
  right = FALSE, row.names = FALSE)

cat("\n=========== O BRACO DA SIGLA, PELO ROTULO (nota 5) ===========\n")
print(dbGetQuery(con, "
  SELECT acr_label, count(*) AS linhas, sum(n_users) AS pessoas
  FROM saida WHERE by_acronym = 1 GROUP BY 1 ORDER BY pessoas DESC"),
  right = FALSE, row.names = FALSE)

cat("\n=========== COM O FILTRO RECOMENDADO (nota 1) ===========\n")
print(dbGetQuery(con, "
  SELECT count(*) AS linhas, count(DISTINCT rsid) AS rsids,
         count(DISTINCT openalex_id) AS instituicoes,
         sum(n_rows) AS linhas_educacao, sum(n_users) AS pessoas
  FROM saida WHERE by_acronym = 0 OR acr_label = 'OK'"),
  right = FALSE, row.names = FALSE)

cat("\n=========== AS MAIORES ENTRADAS ===========\n")
print(dbGetQuery(con, "
  SELECT university_raw, university_name, rsid, oa_display_name,
         shanghai_rank, match_arm, n_users
  FROM saida WHERE by_acronym = 0 OR acr_label = 'OK'
  ORDER BY n_users DESC LIMIT 20"), right = FALSE, row.names = FALSE)

cat("\n=========== RESUMO ===========\n")
cat(sprintf("  %-40s %8s linhas  %5.1f KB\n", basename(out_path),
            format(v$n_rows, big.mark = ","), file.info(out_path)$size / 1024))
cat("  em ", coh_dir, "\n", sep = "")
cat("  filtro recomendado: WHERE by_acronym = 0 OR acr_label = 'OK'\n")
