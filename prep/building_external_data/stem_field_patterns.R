####################################################################
###
### Regex patterns for STEM field from title_raw and description
###
### Sourced by stem_field_classify.R. It defines CONSTANTS ONLY --
### no functions, no side effects, no connections. Same contract as
### br_degree_patterns.R, and for the same reason: if two consumers
### drifted apart, they would silently disagree about what counts as
### engineering and nothing would fail to signal it.
###
### Four fields, three languages (English, Portuguese, Spanish):
###   rx_math   matematica PURA -- ensino e pesquisa
###   rx_appl   matematica APLICADA -- estatistica, atuaria, dados
###   rx_other_stem  outras areas STEM -- quimica, biologia, fisica,
###                 geologia, farmacologia, bancada de laboratorio
###   rx_eng    engenharia -- inclui computacao, software e TI
###
### -----------------------------------------------------------------
### HOW THEY MUST BE USED
### -----------------------------------------------------------------
### 1. O TEXTO E NORMALIZADO ANTES: minuscula, nfc_normalize,
###    strip_accents, pontuacao virando espaco. Por isso NAO ha acento
###    em padrao nenhum aqui. 'matematica' casa 'Matemática'.
### 2. NENHUM PADRAO TEM BARRA INVERTIDA. Fronteira de palavra se
###    escreve (^|[^a-z])termo([^a-z]|$). Isso e deliberado e vem da
###    br_degree_patterns.R: escapes foram mangled duas vezes passando
###    por R e pelo shell. Mantenha assim.
### 3. A ORDEM E CARREGADA DE SENTIDO. Avalie NESTA sequencia e pare
###    no primeiro que casar:
###         rx_appl  ->  rx_math  ->  rx_other_stem  ->  rx_eng
###    Do mais estreito para o mais largo. Motivos concretos:
###      - 'matematica aplicada' e 'bioestatistica' tem que cair em
###        rx_appl, nao em rx_math.
###      - 'bioinformatics' e 'biostatistics' tem 'bio' mas nao os
###        radicais de other_stem; caem em rx_appl, que vem antes.
###      - 'ciencia da computacao' tem 'cienc': tem que cair em rx_eng,
###        por isso rx_other_stem carrega rx_other_stem_not.
###      - 'machine learning engineer' tem 'engineer': cai em rx_appl
###        porque appl vem antes. Isso e deliberado.
###      - 'engenheiro quimico' tem 'quimic' E 'engenheir'. other_stem
###        vem antes, entao SEM excecao viraria other_stem. Por isso
###        rx_other_stem_not lista as engenharias de disciplina.
### 4. CADA CATEGORIA TEM SEU rx_*_not, e a exclusao vale ANTES da
###    inclusao. Sao casos medidos nas auditorias, nao hipoteses:
###      - 'business developer' tem precisao 0.107 para engenharia.
###      - 'programador de producao' e programacao de PRODUCAO, nao de
###        computador; 'programador cultural/musical' idem.
###      - 'educacao fisica' casaria 'fisic' e viraria other_stem.
###      - 'ciencias contabeis' e 'ciencias economicas' casariam
###        'cienc' e virariam other_stem.
### 5. TITULO E DESCRICAO SAO AVALIADOS SEPARADAMENTE. O titulo e
###    sinal muito mais forte; a descricao recupera casos mas tambem
###    traz falso positivo (uma descricao de marketing citando 'equipe
###    de engenharia'). O consumidor decide se usa so titulo ou os
###    dois -- por isso as flags saem separadas.
###
####################################################################

### -----------------------------------------------------------------
### 1. MATEMATICA APLICADA -- avaliada PRIMEIRO (nota 3)
### -----------------------------------------------------------------
### estatistica, atuaria, quantitativo, ciencia de dados,
### econometria, pesquisa operacional.

rx_appl <- paste0(
  # EN
  "statistic|biostatistic|econometric|actuar|psychometric|",
  "quantitative analy|quant analy|quantitative research|",
  "data scien|data analy|machine learning|operations research|",
  "(^|[^a-z])biostat([^a-z]|$)|",
  # PT
  "estatistic|bioestatistic|econometri|atuari|",
  "analista quantitativ|cientista de dados|ciencia de dados|",
  "analise de dados|aprendizado de maquina|pesquisa operacional|",
  # ES
  "estadistic|actuari|cientifico de datos|ciencia de datos|",
  "analisis de datos|aprendizaje automatico|investigacion operativa")

# Excecoes: 'analise de dados' aparece em vaga administrativa; exigir
# que nao seja claramente outra coisa.
rx_appl_not <- paste0(
  "analista de dados cadastrais|",
  "data entry|entrada de dados|captura de dados")

### -----------------------------------------------------------------
### 2. MATEMATICA PURA -- ensino e pesquisa
### -----------------------------------------------------------------

rx_math <- paste0(
  # EN
  "mathematic|(^|[^a-z])maths([^a-z]|$)|(^|[^a-z])math([^a-z]|$)|",
  "calculus|(^|[^a-z])algebra|topology|number theory|",
  "(^|[^a-z])geometry([^a-z]|$)|",
  # PT
  "matematic|(^|[^a-z])calculo([^a-z]|$)|",
  "(^|[^a-z])geometria([^a-z]|$)|topologia|",
  # ES
  "(^|[^a-z])algebra|(^|[^a-z])geometria([^a-z]|$)")

# REMOVIDO: "olympiad", "olimpiada de matematica", "olimpiada
# matematica". O termo estava SOZINHO, sem fronteira e sem
# qualificador de matematica, e pegava: "assistente de rh olimpiadas
# 2016" (Olimpiada do Rio), "obr olimpiada brasileira de robotica",
# "physics olympiad teacher", "coordenador de olimpiadas
# cientificas", "team tutor in brazilian satellite olympiad".
# Numa coorte de olimpiada de matematica isso e especialmente
# perigoso: olimpiada escolar nao e ocupacao em matematica.

# 'calculo' sozinho em portugues e muito ambiguo: 'calculo de folha',
# 'calculo estrutural', 'calculo de rescisao' nao sao matematica.
rx_math_not <- paste0(
  "calculo de folha|calculo de rescis|calculo estrutural|",
  "calculo de frete|calculo trabalhista|calculo de imposto|",
  "calculo de custo|calculo renal|geometria descritiva")

### -----------------------------------------------------------------
### 3. OUTRAS AREAS STEM -- quimica, biologia, fisica, laboratorio
### -----------------------------------------------------------------
### O nome e other_stem, NAO 'science', e isso e deliberado. O que
### sobrou aqui e um balde de DISCIPLINAS especificas -- quimica,
### biologia, fisica, geologia, farmacologia, trabalho de bancada --
### e nao "gente que faz pesquisa". Chamar de 'science' convida
### exatamente a leitura que colocou 'research assistant' dentro do
### conjunto na primeira versao.

rx_other_stem <- paste0(
  # Compostos de laboratorio e pos-doutorado
  "laboratory technician|laboratory analyst|laboratory assistant|",
  "(^|[^a-z])lab technician|(^|[^a-z])lab assistant|",
  "clinical research|post[ -]?doc|doctoral researc|",
  "pos[ -]?doutorad|tecnico de laboratorio|tecnico em laboratorio|",
  "analista de laboratorio|auxiliar de laboratorio|",
  "estagiario de laboratorio|estagiaria de laboratorio|",
  # Radicais de DISCIPLINA (EN/PT/ES juntos: os radicais coincidem)
  "(^|[^a-z])biolog|(^|[^a-z])quimic|chemist|chemistry|",
  "(^|[^a-z])physic|(^|[^a-z])fisic|geolog|microbiolog|",
  "biochem|bioquimic|biotech|biotecnolog|pharmacolog|farmacolog|",
  "neuroscien|neurocienc|immunolog|imunolog|",
  "ecolog|zoolog|botanic|astronom|(^|[^a-z])laborator")

# REMOVIDO: TODA a familia generica de pesquisa, tanto solta quanto
# em forma composta -- "research", "researcher", "research fellow",
# "research assistant", "research intern", "research scientist",
# "scientist", "scientific", "cientista", "cientific", "scientific
# initiation", "iniciacao cientifica", "bolsista de iniciacao",
# "pesquisa cientifica", "pesquisador", "assistente de pesquisa",
# "bolsista de pesquisa", "investigador", "asistente de
# investigacion", "molecular", "genetic".
#
# Medido no padrao-ouro: os compostos disparam em 17 linhas e 14 NAO
# sao ciencia (82% de erro). O motivo e semantico, nao estatistico:
# essas expressoes nomeiam um ARRANJO DE BOLSA OU DE EMPREGO, nao uma
# disciplina. 'Iniciacao cientifica' e uma modalidade do CNPq que
# cobre agronomia, musica e linguistica igualmente. Casos reais:
#   'Bolsista de iniciacao cientifica'  -> agricultura familiar
#   'Pesquisa de Iniciacao Cientifica'  -> criacao sonora na musica
#   'Narrative Research Intern'         -> historia das mulheres
#   'Pesquisador de Iniciacao Cientifica' -> terminologia gastronomica
#   'Engineering Research Assistant'    -> engenharia
# A disciplina mora no substantivo AO LADO, ou so na descricao.
#
# CUSTO: other_stem perde 51 das 59 linhas de ciencia do ouro.
# 'Pesquisador', 'Visiting Researcher', 'Academic Researcher',
# 'PHD Candidate', 'Aluno pesquisador' nao tem palavra de disciplina
# e caem em 'none'. Recall ~28.8% e a troca pretendida, nao defeito.
#
# ATENCAO METODOLOGICA (nota 2): estes radicais foram ESCOLHIDOS
# medindo precisao por radical nas mesmas 1.000 linhas do ouro contra
# as quais other_stem e depois avaliada. A precisao reportada dessa
# categoria e otimista em grau desconhecido. mathematics, applied_math
# e engineering continuam independentes: nada nelas foi ajustado
# contra a amostra.

# Sem isto, 'ciencia da computacao', 'ciencias contabeis',
# 'educacao fisica' e 'ciencias sociais' cairiam aqui (nota 4).
#
# E, pela precedencia da nota 3, as ENGENHARIAS DE DISCIPLINA:
# other_stem e avaliada antes de rx_eng, entao sem estas linhas
# 4.128 posicoes da coorte sairiam de engenharia para other_stem,
# quase todas engenharia quimica -- "estagiario de engenharia
# quimica" (354), "engenheiro quimico" (268), "engenheira
# quimica" (149), "engineering geologist" (49), "engenheiro
# geologo" (20). Engenheiro quimico e ocupacao de ENGENHARIA.
rx_other_stem_not <- paste0(
  "engenh[a-z]* quimic|chemical engineer|ingenier[a-z]* quimic|",
  "engenh[a-z]* geolog|geological engineer|engineering geologist|",
  "engenh[a-z]* ambient|environmental engineer|",
  "engenh[a-z]* biomedic|biomedical engineer|",
  "engenh[a-z]* de materia|materials engineer|",
  "engenh[a-z]* de bioprocess|bioprocess engineer|",
  "engenh[a-z]* fisic|physical design engineer|",
  "engenh[a-z]* de petroleo|petroleum engineer|",
  "engenh[a-z]* de biotecnolog|biotechnology engineer|",
  "laboratory engineer|(^|[^a-z])lab engineer|",
  "computer scien|ciencia da computacao|ciencias de la computacion|",
  "cienc[a-z]* contabe|cienc[a-z]* economic|cienc[a-z]* sociai|",
  "cienc[a-z]* juridic|cienc[a-z]* politic|political scien|social scien|",
  "educacao fisica|educacion fisica|physical education|",
  "terapia fisica|fisioterap|physiotherap|",
  "cientista de dados|data scien|",
  "market research|pesquisa de mercado|investigacion de mercado|",
  "pesquisa de satisfacao|pesquisa de clima|pesquisa salarial")

### -----------------------------------------------------------------
### 4. ENGENHARIA -- inclui computacao, software e TI
### -----------------------------------------------------------------

rx_eng <- paste0(
  # EN
  "engineer|engineering|(^|[^a-z])software|developer|programmer|",
  "devops|full[ -]?stack|front[ -]?end|back[ -]?end|",
  "web develop|database admin|sysadmin|system admin|",
  "(^|[^a-z])it support|information technology|computer scien|",
  "cyber ?security|network admin|qa tester|test engineer|",
  "solutions architect|data engineer|",
  # PT
  "engenheir|engenharia|desenvolvedor|programador|programadora|",
  "analista de sistemas|suporte tecnico|tecnologia da informacao|",
  "ciencia da computacao|arquiteto de software|",
  "seguranca da informacao|desenvolvimento de software|",
  "analista de suporte|tecnico em informatica|",
  # ES
  "ingenier|desarrollador|desarrolladora|analista de sistemas|",
  "soporte tecnico|tecnologia de la informacion|",
  "ciencias de la computacion|seguridad de la informacion")

# Casos medidos (nota 4): 'business developer' com precisao 0.107,
# 'programador de producao' que e PCP, 'programador cultural' que e
# curadoria. Nenhum destes e engenharia.
rx_eng_not <- paste0(
  "business develop|desenvolvimento de negocio|desarrollo de negocio|",
  "desenvolvedor de negocio|business developer|",
  "market develop|desenvolvimento de mercado|",
  "content develop|curriculum develop|project developer|",
  "people develop|desenvolvimento de pessoas|desenvolvimento humano|",
  "programador de producao|programadora de producao|",
  "programador cultural|programadora cultural|",
  "programador musical|programadora musical|",
  "programador visual|programadora visual|",
  "cultural programmer|film programmer|music programmer|",
  "programacao cultural|programacao musical|",
  "engenheiro de vendas|sales engineer|",
  "desenvolvimento infantil|desenvolvimento social|",
  "desenvolvimento sustentavel|desenvolvimento rural")

### -----------------------------------------------------------------
### A ordem, exportada para o consumidor nao ter que reinventa-la
### -----------------------------------------------------------------
### Nomes na ordem de precedencia da nota 3.

stem_field_order <- c("applied_math", "mathematics", "other_stem", "engineering")

stem_field_rx <- list(
  applied_math = list(yes = rx_appl, no = rx_appl_not),
  mathematics  = list(yes = rx_math, no = rx_math_not),
  other_stem   = list(yes = rx_other_stem, no = rx_other_stem_not),
  engineering  = list(yes = rx_eng,  no = rx_eng_not))
