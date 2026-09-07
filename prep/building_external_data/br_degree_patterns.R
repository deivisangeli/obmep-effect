####################################################################
###
### Regex patterns for Brazilian degree levels in degree_raw
###
### Sourced by revelio_br_cohort_user_ids.R,
### revelio_br_name_cohort_user_ids.R and
### shanghai_top1000_degree_flags.R. It defines CONSTANTS ONLY --
### no functions, no side effects, no connections. The two cohort
### scripts must use byte-identical patterns: if they drifted apart,
### the two cohorts would silently disagree about what a bachelor's
### degree is, and nothing would fail to signal it.
###
### -----------------------------------------------------------------
### WHY THESE EXIST AT ALL
### -----------------------------------------------------------------
### Revelio's own `degree` column is not merely sparse on Brazilian
### records, it is systematically WRONG. Measured over all 13,949,625
### education rows whose university_country = 'Brazil' or whose
### university_raw matches openalex_institutions_br:
###
###  - 'bacharelado' is labelled High School on 489,815 rows and
###    Bachelor on 762,945. Same string, split non-deterministically,
###    so no lookup table on degree_raw can repair it -- the label has
###    to be overridden. Same pattern for 'bacharelado em
###    administracao' (165,855 as High School), 'em engenharia'
###    (121,539), 'em direito' (105,065), 'bacharel' (64,413).
###  - 'graduacao', the third most common value at 634,542 rows, is
###    always 'empty'.
###  - In a random sample of 1,000 Brazilian rows, ALL 93 rows
###    labelled High School were bachelor's degrees (91 'bacharel*',
###    2 'licenciatura'). Not one was ensino medio.
###  - Sample recall of degree = 'Bachelor' was 58.4%.
###
### -----------------------------------------------------------------
### HOW THEY MUST BE USED
### -----------------------------------------------------------------
### 1. ORDER IS LOAD-BEARING. rx_post must be excluded FIRST, because
###    'pos-graduacao' contains 'graduacao' as a substring. Getting
###    this wrong promotes 656,833 postgraduate rows to bachelor --
###    a bigger error than the one being fixed.
### 2. NO BACKSLASHES appear in any pattern. Word boundaries are
###    written (^|[^a-z])...([^a-z]|$) and the dot is ph[.]?d. This is
###    deliberate: backslash escapes were mangled twice while these
###    were being developed, passing through R and shell quoting. Keep
###    it that way.
### 3. Every accented vowel is written as a two-element character
###    class holding the plain letter and the accented one -- so
###    "gradua", c-cedilla-or-c, a-tilde-or-a, "o". Trino has no
###    unaccent(), and the data carries the fully accented form, the
###    cedilla-only form and the bare ASCII form side by side. The
###    accented halves are written as \uXXXX
###    escapes, which keeps this file pure ASCII like the rest of the
###    folder; R resolves them at parse time.
### 4. Apply to lower(trim(coalesce(degree_raw, ''))), never to the
###    raw column.
###
####################################################################

# Postgraduate. Tested FIRST -- see note 1 above.
rx_post <- paste0(
  "p[o\u00f3]s[ -]?gradua|lato sensu|latu sensu|stricto sensu|",
  "especializa|especialista|mestrad|mestre|",
  "(^|[^a-z])mba([^a-z]|$)|master|doutorad|doutor|ph[.]?d|",
  "p[o\u00f3]s[ -]?doc|resid[e\u00ea]ncia")

# Tecnologo / CST: 2-3 year higher-education technology degrees,
# 486,803 rows. Closer to Associate than Bachelor, so they are
# EXCLUDED from the bachelor test by being matched here first.
rx_tech <- paste0(
  "tecn[o\u00f3]log|curso superior de tecnologia|",
  "(^|[^a-z])cst([^a-z]|$)")

# Secondary and technical schooling.
rx_hs <- paste0(
  "ensino m[e\u00e9]dio|m[e\u00e9]dio completo|colegial|high school|",
  "ensino fundamental|magist[e\u00e9]rio|curso t[e\u00e9]cnico|",
  "^t[e\u00e9]cnico")

# Unambiguous bachelor's.
rx_b1 <- "bacharel|licenciatur|bachelor"

# Generic undergraduate markers. Only safe once rx_post, rx_tech and
# rx_hs have already been excluded. 'engenheir' matches the
# professional title (Engenheiro Civil) but deliberately NOT the bare
# field name (Engenharia Civil), which stays in the unprovable
# field-name-only bucket.
rx_b2 <- paste0(
  "gradua[c\u00e7][a\u00e3]o|ensino superior|curso superior|",
  "superior completo|n[i\u00ed]vel superior|",
  "forma[c\u00e7][a\u00e3]o superior|engenheir|^superior$")

# The union rule, as a Trino boolean over a column alias `dr` holding
# lower(trim(coalesce(degree_raw, ''))) and a `degree` column.
#
# Measured: 3,041,173 rows under degree='Bachelor' alone, 5,372,074
# under the regex alone, 5,450,492 under the union (1.79x). The
# degree='Bachelor' arm is what recovers the 78,418 rows where Revelio
# read the degree off `field` or `description` rather than degree_raw,
# including 15,038 with a blank degree_raw.
sql_is_bachelor <- sprintf(
  "degree = 'Bachelor'
                 OR (    NOT regexp_like(dr, '%s')
                     AND NOT regexp_like(dr, '%s')
                     AND NOT regexp_like(dr, '%s')
                     AND (    regexp_like(dr, '%s')
                           OR regexp_like(dr, '%s')))",
  rx_post, rx_tech, rx_hs, rx_b1, rx_b2)

####################################################################
###
### LEVEL SPLIT -- added for shanghai_top1000_degree_flags.R
###
### Everything above is UNTOUCHED and must stay that way: criterion E
### in both cohort scripts is defined by sql_is_bachelor, and the
### measured constants in those scripts are only valid against these
### exact strings.
###
### What follows is ADDITIVE. rx_post deliberately lumps master's,
### doctorate, MBA and lato sensu into a single "not a bachelor"
### bucket, because that is all criterion E ever needed to know. A
### script that has to say WHICH postgraduate degree somebody holds
### needs that bucket taken apart, and that is what rx_phd, rx_msc and
### rx_lato do. They are not a repartition of rx_post -- they also
### carry the English and Spanish forms, because the education extract
### they run against is international (669k Brazilian matched rows,
### but also 99k US, 47k Spanish, 31k UK and 25k Argentine).
###
### The same three rules from the header apply. No backslashes; word
### boundaries as (^|[^a-z])...([^a-z]|$); the dot as [.]?; accented
### vowels as two-element classes with the accented half a \uXXXX
### escape, so this file stays pure ASCII.
###
### ORDER IS AGAIN LOAD-BEARING, for the same kind of reason:
###
###   rx_notdeg -> rx_phd -> rx_msc (minus rx_lato) -> sql_is_bachelor
###
###  - rx_notdeg first, because "pos-doutorado" contains "doutorado"
###    and "doutorado sanduiche" contains "doutorad". Both would
###    otherwise read as a doctorate EARNED at the host university.
###  - rx_phd before rx_msc, so "Mestrado e Doutorado" resolves to the
###    higher of the two rather than to whichever alternative the
###    engine happens to test first.
###  - rx_lato subtracted from the master's arm, because
###    "pos-graduacao lato sensu" is a Brazilian postgraduate
###    CERTIFICATE, not a stricto sensu master's. It is a subset of
###    rx_post by construction.
###
####################################################################

# Not a degree at all: a stay, an exchange, a secondary subject. Tested
# FIRST.
#
# 'do(c|ut)' rather than 'doc': the arm was written 'p[os]s[ -]?doc' and
# so only ever matched the literal "pos-doc" / "postdoc" spellings. It
# never matched "pos-doutorado", which is how Portuguese actually writes
# it, so 862 rows over the Shanghai matches -- 799 people -- were being
# counted as a DOCTORATE EARNED at the host university instead of as a
# postdoctoral stay. The comment here used to assert the opposite.
#
# The alternation is deliberately tight: 'dout' has to follow within one
# separator of 'pos', so "pos-graduacao stricto sensu - doutorado" (822
# rows) is NOT caught. That one is a real doctorate and must stay one.
rx_notdeg <- paste0(
  "p[o\u00f3]s[ -]?do(c|ut)|post[ -]?do(c|ut)|sandu[i\u00ed]che|sandwich|",
  "interc[a\u00e2]mbio|exchange|visiting|summer school|",
  "(^|[^a-z])minor([^a-z]|$)")

# WEAK tier of the same idea, tested only AFTER rx_phd and rx_msc.
# 'extensao' used to sit in rx_notdeg above and was moved out, because
# unlike every alternative left there it is ALSO a field name:
# "mestrado em extensao rural" and "doutorado em extensao rural" are
# real stricto sensu degrees in agricultural extension, and rx_notdeg
# being tested FIRST made them unrecoverable. Demoting it recovers 33
# such rows and costs about 8 -- "extensao - mba", "curso de extensao
# do mestrado em ..." -- which are extension courses OF a degree.
#
# NARROWING it instead, to 'curso de extensao', was measured and
# rejected: it would lose 2,259 correctly excluded rows, of which the
# bare word "extensao" alone is 1,404.
rx_notdeg_weak <- "extens[a\u00e3]o"

# Doctorate. 'doctorat' also covers 'doctorate'; 'doctorad' covers the
# Spanish 'doctorado'. 'doutorand' is in for the same reason rx_msc
# carries 'mestrando': Revelio records ENROLMENT, not graduation, so an
# enrolled doctoral student sets the flag exactly as criterion E lets an
# enrolled undergraduate set its own. It is 1,457 rows over the Shanghai
# top-1000 matches. The bare 'doutor' stays bounded on both sides so it
# does not fire on unrelated words. 'pos-doutorando' and 'pos-doutorado'
# are caught by rx_notdeg before this pattern is ever tested -- but only
# since the 'do(c|ut)' repair above; before it they reached here and were
# scored as doctorates.
rx_phd <- paste0(
  "doutorad|doutorand|doutoramento|(^|[^a-z])doutor([^a-z]|$)|",
  "ph[.]?[ ]?d|doctorad|doctorat|doctoral|",
  "(^|[^a-z])dphil([^a-z]|$)|doktor|dottorat|",
  "(^|[^a-z])d[.]?sc([^a-z]|$)|(^|[^a-z])dnp([^a-z]|$)|",
  "dr[.]?[ ]?-[ ]?ing")

# Master's. 'm[.]?sc' covers both 'msc' and 'm.sc'. MBA is included
# here on purpose -- see sql_shanghai_level below and the sh_master /
# sh_master_strict pair, which keeps that call reversible.
rx_msc <- paste0(
  "mestrad|mestrand|(^|[^a-z])mestr[ae]([^a-z]|$)|",
  "m[a\u00e1]ster|(^|[^a-z])m[.]?sc([^a-z]|$)|magister|maestr|",
  "(^|[^a-z])mba([^a-z]|$)")

# Lato sensu: a postgraduate certificate, NOT a master's. Subtracted
# from the master's arm. Every alternative here already appears inside
# rx_post, so this is a strict subset of it.
rx_lato <- "especializa|especialista|lato sensu|latu sensu"

# MBA on its own, so sh_master_strict can be built beside sh_master and
# the "MBA counts as a master's" decision stays a WHERE clause away
# from being reversed, with no rebuild.
rx_mba <- "(^|[^a-z])mba([^a-z]|$)"

####################################################################
###
### THE TWO PATCHES THAT DO NOT BELONG IN THE SHARED CONSTANTS
###
### Both of these repair a real defect in rx_post / rx_b1 / rx_b2, and
### both are kept OUT of them on purpose. Those three feed
### sql_is_bachelor, which IS criterion E in revelio_br_cohort_user_ids.R
### and revelio_br_name_cohort_user_ids.R. Folding the repairs in would
### be the more correct thing in the abstract and the wrong thing here:
### measured against the local education extract, which reproduces the
### pipeline's min_bach_year for all 6.849.674 members exactly, it would
### drop 6.145 of them from the cohort -- 4.581 from the rx_post repair
### and 1.596 from the rx_b1/rx_b2 one -- plus an unknown number newly
### admitted that only Athena could count. That is a re-run of scripts
### 8, 9, 10 and 10a and a redefinition of the cohort, not a bug fix.
###
### So the two live here and are used ONLY by sql_shanghai_level. The
### price is that script 16's "bachelor" is no longer byte-identical to
### criterion E's; it is a strict SUPERSET of it, widened by rx_bach16
### and narrowed by rx_post16. Script 16's header says so.
###
####################################################################

# D. rx_post admits exactly ONE character between 'pos' and 'gradua'
#    ([ -]?), so "pos- graduacao" -- hyphen THEN space -- walks straight
#    past it and lands in rx_b2's 'graduacao', turning a lato sensu
#    course into a BACHELOR. 269 rows of the Shanghai matches, 12.378 of
#    the cohort's education rows. It is the same failure the README
#    calls load-bearing under "Postgraduate must be excluded before
#    matching graduacao"; only the spacing is new.
rx_post16 <- "p[o\u00f3]s[ -]*gradua"

# E. Spanish first-degree words that rx_b1 and rx_b2 do not carry:
#    'grado' (4.271 rows) and 'licenciado'/'licenciada' (1.001). rx_b1
#    has 'licenciatur', which does not reach 'licenciado'. 'grado' is
#    bounded on both sides so it cannot fire inside 'posgrado' or
#    'grados'.
rx_bach16 <- "(^|[^a-z])grado([^a-z]|$)|licenciad"

# The cascade, as a SQL CASE over a column alias `dr` holding
# lower(trim(coalesce(degree_raw, ''))) and a `degree` column. Returns
# 'phd', 'master', 'bachelor' or 'other', and the arms partition the
# input by construction.
#
# ORDER IS LOAD-BEARING at every step:
#
#   1 rx_notdeg       a stay is not a degree, and these BEAT a degree
#                     word: "pos-doutorado" contains "doutorado",
#                     "doutorado sanduiche" contains "doutorad", and
#                     "mba exchange program" is an exchange done while
#                     enrolled in an MBA somewhere else.
#   2 rx_phd          before master's, so "Mestrado e Doutorado"
#                     resolves to the higher of the two.
#   3 rx_msc          minus rx_lato, so "pos-graduacao lato sensu" is
#                     not promoted to a master's.
#   4 rx_notdeg_weak  AFTER 2 and 3, because 'extensao' is also a field
#                     name -- see the constant.
#   5 rx_post16       before the bachelor arm, for exactly the reason
#                     the README gives: "pos-graduacao" contains
#                     "graduacao". The NOT rx_bach16 guard stops a
#                     Spanish 'grado' being swallowed by it.
#   6 bachelor        sql_is_bachelor OR rx_bach16.
#
# NOTE: this interpolates sql_is_bachelor, which is TRINO SQL and calls
# regexp_like(). DuckDB spells that regexp_matches(), so a DuckDB
# consumer has to install the shim documented in
# scratchpad/validate_sql_syntax.R before using this string:
#
#   CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)
#
# sql_is_bachelor is still interpolated VERBATIM rather than restated,
# so criterion E's definition of a bachelor is visible inside this one
# rather than duplicated. What arm 6 adds to it is rx_bach16 and
# nothing else, and arm 5 is what it takes away.
sql_shanghai_level <- sprintf(
  "CASE
     WHEN regexp_like(dr, '%s') THEN 'other'
     WHEN degree = 'Doctor' OR regexp_like(dr, '%s') THEN 'phd'
     WHEN degree IN ('Master', 'MBA')
          OR (NOT regexp_like(dr, '%s') AND regexp_like(dr, '%s')) THEN 'master'
     WHEN regexp_like(dr, '%s') THEN 'other'
     WHEN regexp_like(dr, '%s') AND NOT regexp_like(dr, '%s') THEN 'other'
     WHEN (%s) OR regexp_like(dr, '%s') THEN 'bachelor'
     ELSE 'other'
   END",
  rx_notdeg, rx_phd, rx_lato, rx_msc, rx_notdeg_weak,
  rx_post16, rx_bach16, sql_is_bachelor, rx_bach16)
