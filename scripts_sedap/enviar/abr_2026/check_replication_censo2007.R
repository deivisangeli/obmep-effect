

dbGetQuery(con, "SELECT COUNT(*) FROM alunos_2007_clean")
dbGetQuery(con, "SELECT COUNT(*) FROM alunos_2006_final")
dbGetQuery(con, "SELECT COUNT(*) FROM alunos_2005_final")


dbGetQuery(con, "
SELECT 
  SUM(CO_ENTIDADE IS NULL) * 1.0 / COUNT(*) AS pct_missing
FROM alunos_2006_final
")


dbGetQuery(con, "
SELECT 
  AVG(NU_IDADE) AS idade_media_2007
FROM alunos_2007_clean
")

dbGetQuery(con, "
SELECT 
  AVG(NU_IDADE) AS idade_media_2006
FROM alunos_2006_final
")



dbGetQuery(con, "
SELECT NU_IDADE, COUNT(*) 
FROM alunos_2006_final
GROUP BY NU_IDADE
ORDER BY NU_IDADE
")



dbGetQuery(con, "
SELECT TP_ETAPA_ENSINO, COUNT(*) 
FROM alunos_2007_clean
GROUP BY TP_ETAPA_ENSINO
")

dbGetQuery(con, "
SELECT TP_ETAPA_ENSINO, COUNT(*) 
FROM alunos_2006_final
GROUP BY TP_ETAPA_ENSINO
")




dbGetQuery(con, "
SELECT 
  COUNT(*) AS inconsistencias
FROM alunos_2007_clean a
JOIN alunos_2006_final b
ON a.ID_ALUNO = b.ID_ALUNO
WHERE a.NU_IDADE != b.NU_IDADE + 1
")



dbGetQuery(con, "
SELECT 
  TP_ETAPA_ENSINO,
  AVG(CO_ENTIDADE IS NOT NULL) AS taxa_match
FROM alunos_2006
GROUP BY TP_ETAPA_ENSINO
")




dbGetQuery(con, "
SELECT 
  AVG(a.CO_ENTIDADE != b.CO_ENTIDADE) AS pct_mudou
FROM alunos_2007_clean a
JOIN alunos_2006_final b
USING (/* chave aluno */)
")




dbGetQuery(con, "
SELECT 
  AVG(a.CO_UF != b.CO_UF) AS pct_mudou_uf
FROM alunos_2007_clean a
JOIN alunos_2006_final b
USING (/* chave aluno */)
")



dbGetQuery(con, "
SELECT 
  AVG(CO_UF IS NULL) AS pct_missing
FROM alunos_2006_final
")



dbGetQuery(con, "
SELECT TP_DEPENDENCIA, COUNT(*) 
FROM alunos_2006_final
GROUP BY TP_DEPENDENCIA
") # comparar com 2007


dbGetQuery(con, "
SELECT CO_UF, COUNT(*) 
FROM alunos_2006_final
GROUP BY CO_UF
ORDER BY COUNT(*) DESC
") # comparar com 2007




