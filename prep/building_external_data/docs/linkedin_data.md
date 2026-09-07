# Building the LinkedIn data

How a snapshot of 708 million LinkedIn profile names becomes a pool of 6.85 million plausibly
Brazilian candidates with their full career histories, a flag for degrees from top-ranked
universities, and a flag for the firms and universities they worked for. Each section below is one process in that chain, in the order it runs, and names the
script that performs it.

This is the narrative companion to [`../README.md`](../README.md), which stays the reference for
assertions, engine pitfalls and re-run guards. Every figure here comes from a logged run against the
real data.

1. [What the source is, and the constraint it imposes](#what-the-source-is-and-the-constraint-it-imposes)
2. [Building the reference list of Brazilian given names](#building-the-reference-list-of-brazilian-given-names)
3. [Extracting the first name from a free-text profile name](#extracting-the-first-name-from-a-free-text-profile-name)
4. [Matching names against the reference list](#matching-names-against-the-reference-list)
5. [Scoring a match: from a flag to `p_brazil`](#scoring-a-match-from-a-flag-to-p_brazil)
6. [Publishing the name crosswalk to Athena](#publishing-the-name-crosswalk-to-athena)
7. [Checking the name prior against hand-classified samples](#checking-the-name-prior-against-hand-classified-samples)
8. [Assembling the institution reference lists](#assembling-the-institution-reference-lists)
9. [Selecting the candidate cohorts](#selecting-the-candidate-cohorts)
10. [Extracting the cohort's position and education histories](#extracting-the-cohorts-position-and-education-histories)
11. [Flagging degrees from top-ranked universities](#flagging-degrees-from-top-ranked-universities)
12. [Flagging the firms and universities people worked for](#flagging-the-firms-and-universities-people-worked-for)
13. [Reading and re-running the outputs](#reading-and-re-running-the-outputs)

---

## What the source is, and the constraint it imposes

The LinkedIn profile-name snapshot carries **exactly two columns**: `user_id` and `fullname`. There
is no country, no location, no headline, no language field. Nationality therefore cannot be
*filtered* — it can only be *inferred from the name string itself*.

That single constraint shapes everything downstream. It is why the first product of this pipeline is
a **prior to be intersected with other evidence**, never a nationality label, and it is why the
pipeline does not stop there: the later stages exist to corroborate the name signal against where
someone actually worked and studied.

| | |
|---|---|
| Profiles | **708,365,562** |
| Files | 20 parquet chunks, ~14.1 GiB |
| Columns available | `user_id`, `fullname` |

The richer career data lives in Revelio's Athena tables (`academic_individual_position`,
`academic_individual_user_education`), which key on the **same `user_id`**. That shared key is what
lets a name-based score built locally be joined to employment and education history later.

---

## Building the reference list of Brazilian given names

*Script: `prep/ibge_names_frequency.r` — step 0, which lives one level up in `prep/`, not in this
folder.*

The reference is the IBGE census name ranking. The top decile of canonical given names by frequency
is selected, then expanded to **every spelling variant** IBGE records for those names, producing one
row per token with its own census frequency.

| | |
|---|---|
| Tokens in the final list | **48,539** |
| — canonical names | 12,856 |
| — variant-only spellings | 35,683 |

Two properties of this list are load-bearing:

**Each variant carries its own frequency, never its parent's.** `mariah` scores on its own 24,382,
not on maria's 12,284,478. Inheriting the parent frequency would hand every rare variant an enormous
census share and push the score of every one of them to the maximum.

**Frequencies are aggregated with `max`, never `sum`.** A single variant spelling attaches to as many
as 15 canonical parents, so summing across that many-to-many relationship inflates the population
total to 2.63 billion against a real 190 million. `max` is safe only because frequency is verified
consistent per token, and that verification is an assertion in the consuming script.

---

## Extracting the first name from a free-text profile name

*Script: `linkedin_br_name_flag.R`, cleaning stage.*

`fullname` is free text — it holds credentials, emoji, employers, punctuation and every alphabet.
The first name is extracted by a fixed rule:

1. lowercase and fold accents (DuckDB's `strip_accents`);
2. replace every non-letter with a **space**;
3. take the first whitespace token of at least 2 letters that is not a particle or title
   (`de`, `da`, `do`, `van`, `von`, `dr`, `prof`, …).

**Step 2 replaces rather than deletes, and that is deliberate.** `Jim Perry-ECUMC` becomes `jim`;
deleting the hyphen instead would fuse the tokens into `jimperryecumc`, which can never match
anything. The 2-letter floor discards bare initials at no cost, since every token in the reference
list is at least 2 characters.

A 14-case regression test of this rule runs before any data is read, and the script aborts if any
case drifts.

| | |
|---|---|
| Distinct first names extracted | **10,025,393** |
| Profiles yielding no first name | **41,023,040 — 5.79%** |

Those 41 million are overwhelmingly non-Latin scripts (CJK, Cyrillic, Arabic), which clean to an
empty string, plus initials-only names. The method is structurally blind to Brazilians who write
their name in another alphabet.

---

## Matching names against the reference list

*Script: `linkedin_br_name_flag.R`, join stage.*

The extracted first name is joined to the 48,539-token reference list by **exact equality**. There is
no fuzzy matching: a phonetic-plus-Jaro-Winkler method was specified, built and measured, then
dropped, because its two halves cancel each other out — the phonetic code collapses exactly the
differences the string distance penalises. The IBGE variant list recovers more than the fuzzy match
would have, as a pure join with no new dependency.

The whole stage is DuckDB SQL driven from R, with no R-side computation and no dependency beyond
`duckdb` and `DBI`, so it runs fully offline in about **7 minutes** over 708M rows.

| | |
|---|---|
| **Flag rate** | **50.45%** (357,336,323 profiles) |
| — matched a canonical name | 42.98% (304,427,855) |
| — added by variant spellings | 7.47% (52,908,468) |

Half the planet. Which is the point of the next section.

---

## Scoring a match: from a flag to `p_brazil`

A binary flag at a 50% base rate carries almost no information, so each matched name gets a score
that says how *distinctively* Brazilian it is:

```
lk_share   = lk_n / <total non-null first names>
ibge_share = ibge_freq / 184,372,093
ratio      = lk_share / ibge_share
p_brazil   = min(1, p_br / ratio)          p_br = 0.09
```

This is Bayes — `P(BR | name) = P(name | BR) · P(BR) / P(name)` — estimating `P(name | BR)` by the
IBGE census share and `P(name)` by the name's share of LinkedIn. A name that is far more common on
LinkedIn than in the Brazilian census has a high `ratio` and a low score.

**`p_brazil` is a ranking, not a calibrated probability.** The `p_br` prior is an assumption, and the
census share is a biased estimate of the Brazilian *LinkedIn* name distribution — LinkedIn
under-covers older, poorer and rural Brazilians, which inflates the scores of names like `raimunda`
and `terezinha`. Treat it as an ordering.

### Why the bare flag is unusable

The reference list reaches down to census frequency 529 for canonical names and 20 for variants,
which admits names that barely exist in Brazil but are everywhere on LinkedIn:

| token | Brazil frequency | LinkedIn profiles | ratio |
|---|---|---|---|
| `rahul` | 24 | 559,394 | 6439× |
| `muhammad` | 145 | 1,375,671 | 2621× |
| `chris` | 623 | 1,405,849 | 623× |

935 names with a ratio above 5 supply **51.4% of all canonical matches**, and the variant expansion
is **92.5% high-ratio noise** by volume.

**So: never consume the raw match flag on its own. Always threshold on `p_brazil` or `ratio`.**

| cutoff | profiles | % of 708M |
|---|---|---|
| any match | 357,336,323 | 50.45% |
| **> 0.05** (what gets exported) | **140,263,729** | **19.80%** |
| ≥ 0.25 | 65,139,260 | 9.20% |
| ≥ 0.50 | 39,450,441 | 5.57% |
| ≥ 0.90 | 15,733,329 | 2.22% |

---

## Publishing the name crosswalk to Athena

*Script: `linkedin_br_flag_to_s3.R`.*

Every profile scoring above 0.05 is written to a single parquet of `user_id` + `p_brazil`, uploaded
to S3, and registered as `revelio_database.linkedin_br_name_flag`. This is the **only stage of the
LinkedIn chain that needs the network**; everything before it is offline.

The file is written **sorted by `user_id`**. That is not cosmetic: it gives each row group narrow
min/max statistics on the join key, so Athena can prune row groups when the crosswalk is joined to
Revelio by `user_id`, which is its entire intended use.

| | |
|---|---|
| Rows | **140,263,729** |
| Size | 0.77 GB |
| Coverage | 19.8% of all profiles |
| Runtime | ~1 min |

19.8% is far above Brazil's plausible ~8–11% share of LinkedIn, and that gap is the warning: **this
table does not say "these people are Brazilian."** It is meant to be intersected with employment,
education and firm evidence, which is what the cohort stage does.

Because `p_brazil` travels with each row, the cut can be **tightened** in Athena at no cost. It
cannot be loosened below 0.05 without re-exporting.

---

## Checking the name prior against hand-classified samples

*Scripts: `linkedin_br_name_audit.R`, `name_only_country_check.R`, `name_only_us_fullname_check.R`.*

Three read-only checks. None writes to Athena and none feeds anything downstream; they exist to be
read, and their findings are recorded in each script's own header rather than here.

- **`linkedin_br_name_audit.R`** draws 500 profiles scoring above 0.5 and joins a hand-written
  classification of each distinct name — clearly Brazilian-Portuguese, internationally ambiguous, not
  a personal name at all, or clearly non-Brazilian. It is offline, reading the per-profile chunks,
  which are the only place the names survive: the exported crosswalk carries `user_id` and
  `p_brazil` only.
- **`name_only_country_check.R`** reports where candidates admitted by the name prior alone are
  actually located, against corroborated groups as a baseline.
- **`name_only_us_fullname_check.R`** classifies a sample of name-only candidates located in the
  United States by surname morphology.

Three conventions hold across all three: **the sample is drawn once and never redrawn**, because the
stored classification is keyed to that exact sample; **classifications live in editable CSVs** rather
than in code, because they are judgment and should be inspectable; and **each script re-runs its own
sampling query and asserts it returns identical `user_id`s**, since a seed that does not reproduce is
worse than no seed.

The one number worth carrying forward: candidates admitted by the **name prior alone are 0.5% located
in Brazil**. That is the empirical basis for never using the name signal by itself.

---

## Assembling the institution reference lists

*Scripts: `openalex_br_institutions.R`, `shanghai_ranking_openalex_names.R`,
`openalex_institutions_br_to_s3.R`.*

Two lists of institution names, both built offline from a local OpenAlex snapshot. They are inputs
to the two matching steps that follow — the cohort's Brazilian-university criterion, and the
top-university degree flags.

| list | rows | used by |
|---|---|---|
| Brazilian institutions | **1,947** | cohort criterion C_norm |
| Shanghai ranking with OpenAlex names | **1,079** (1,076 resolved) | top-university degree flags |

The Brazilian list is not built with `country_code = 'BR'` alone. That column is NULL for 7,043 of
the snapshot's 120,658 records, so the filter falls back to the spelled-out country name, which
recovers **127 institutions** including real federal universities. Both a raw and a de-parenthesised
name are stored, since the de-parenthesised form (`Universidade Estadual de Campinas` rather than
`… (UNICAMP)`) is closer to what people type on LinkedIn.

One trap worth knowing before reusing these lists: **`type = 'education'` is not a usable filter.**
OpenAlex types large for-profit universities by ownership, so Estácio's main record — 7,237 works —
is typed `company` and has no `education` record at all. Both matching steps downstream therefore
accept records of any type on the whole-string arm.

---

## Selecting the candidate cohorts

*Scripts: `br_degree_patterns.R`, `revelio_br_cohort_user_ids.R`,
`revelio_br_name_cohort_user_ids.R`, `obmep_candidates_step_1.R`.*

The goal is a pool of Revelio `user_id`s that are plausibly Brazilian **and** young enough to have
been exposed to OBMEP. "Young enough" is two date criteria, identical in both cohorts; the cohorts
differ only in which Brazil signal admits a user.

| | Criterion | Source |
|---|---|---|
| **A_country** | any position with `country = 'Brazil'` | position table |
| **A_name** | `p_brazil > 0.5` in the name crosswalk | the crosswalk built above |
| **B** | any education row with `university_country = 'Brazil'` | education table |
| **C_norm** | `university_raw`, or any `/`, `( )` or `" - "` delimited segment of it, equals a Brazilian institution name with accents folded | education × institution list |
| **D** | earliest position `startdate` exists and its year is ≥ 2007 | position table |
| **E** | earliest bachelor `startdate` exists and its year is ≥ 2007 | education table |

Two cohorts are built and then merged:

```
(A_country OR B OR C_norm) AND D AND E   ->  obmep_br_cohort_user_ids        5,736,020
A_name                     AND D AND E   ->  obmep_br_name_cohort_user_ids   3,779,509

UNION, deduplicated on user_id           ->  obmep_candidates_step_1         6,849,674
                                                country-cohort only  3,070,165
                                                in both              2,665,855
                                                name-cohort only     1,113,654
```

**D and E are strict.** No position, no bachelor, or only unparseable dates in either means excluded;
the inner join between the two date aggregates is what enforces it. Criteria D and E, not the Brazil
signal, do most of the filtering.

The merge is a `UNION` rather than `UNION ALL` — that *is* the deduplication. Where a user appears in
both cohorts every shared column agrees exactly, so no tie-breaking rule is needed, and `p_brazil` is
backfilled across the whole union so a country-admitted member still carries its real name score.

### What each signal is worth

Measured by where members actually say they are located:

| admitted by | users | located in Brazil |
|---|---|---|
| A — worked in Brazil | 5,671,650 | 95.5% |
| B — studied at a Brazilian-country university, no A | 38,782 | 26.7% |
| C — exact institution-name match, no A/B | 19,883 | 10.3% |
| C_norm — normalised match, no A/B/C | 5,705 | **32.5%** |
| name prior only | 1,113,654 | **0.5%** |

**Do not read these against A's 95.5%.** Someone admitted for *working* in Brazil is nearly
guaranteed to be located there. Someone admitted for *studying* in Brazil and since emigrated is not
— and that population is part of what this project is looking for.

### Why matching on name segments was needed

The obvious hypothesis is that people type bare acronyms like `USP`. They mostly do not: bare
acronyms are only 1.5–2.5% of an institution's rows. What the original exact match missed was the
full name *decorated* with its acronym.

| `university_raw` on USP's school | rows | matched by exact C? |
|---|---|---|
| `Universidade de São Paulo` | 374,136 | yes |
| `USP - Universidade de São Paulo` | 29,840 | no |
| `Universidade de São Paulo / USP` | 23,237 | no |
| `USP` | 7,335 | no |
| `Universidade de São Paulo (USP)` | 1,810 | no |

Allowing the match to land on a **segment** of the string lifts institution-level coverage from 77.7%
to 90.1% of USP's education rows, 76.1% to 93.8% for FGV, and 78.9% to 92.9% for UNICAMP. Accent
folding was added at the same time but accounts for almost none of that — **segment splitting is
nearly the whole effect.**

The split replaces `/`, `(` and `)` with a delimiter, and does the same for `" - "` — **space,
hyphen, space**, not a bare hyphen. So `USP - Universidade de São Paulo` splits into two candidate
segments, while a hyphenated institution name such as `Anhanguera-Uniderp` stays intact. A segment
must be at least 3 characters to be matched.

The segment arm accepts only `education` records, because the Brazilian institution list contains
short company names (`IBM`, `Vale`, `Intel`, `Shell`) and an entry reading `Curso de Inglês - Intel`
would otherwise match one.

Note that the flag moves far more than membership does: C_norm sets the institution flag on 20.4%
more members but adds only **5,705** people to the cohort. Almost everyone it newly matches was
already admitted by A or B. A row-level or match-level gain is not a cohort gain.

### The school-key branch that was withdrawn

Before C_norm, a different fix was tried: propagate a match through Revelio's normalised school key,
so that anyone resolved to the same school as a matched row would be admitted. It was built, measured
and **withdrawn**.

It failed because a single education row poisons an entire school. One person whose school key is
Harvard typed `Universidade Federal do Rio de Janeiro` — 1 row out of 562,968 — and that admitted all
of Harvard. Phoenix, Delhi, Stanford, Cambridge, Toronto, UNAM and Berkeley entered the same way.
Without a safeguard the branch admitted 7,645,023 people at **0.1%** located in Brazil; C_norm admits
5,705 at 32.5%. Revelio is not at fault — Harvard's key holds 4,496 distinct raw strings and three of
them are wrong, an error rate of 0.07%. The criterion was at fault, because it amplified any non-zero
error rate into total contamination. C_norm attacks the same variant-spelling problem at the string,
where it cannot amplify.

The crosswalk that branch used survives as `rsid_openalex_br_crosswalk.R`, with nothing consuming it.

### Trying the school key again, with a different question

*Scripts: `rsid_br_user_share.R`, `revelio_br_cohort_user_ids_alt.R`,
`obmep_candidates_step_1_alt.R` — a parallel chain ending in `_alt` tables. The cohort above is not
modified.*

The branch failed on its safeguard, not on its idea. It was cut on `match_share`, the share of a
school's education *rows* whose typed string matched — and one stray row out of 562,968 is enough to
leave Harvard's share respectable-looking on a large denominator. So the alternative asks a question
about the school's **people** instead: of the users under this school whose profile country is known,
what share are in Brazil? Keep the school above 0.5.

That is a different statistic from the one this chain already rejected. The forbidden one is
`university_country` aggregated over education rows, which sits near zero for FGV and UFRGS *because
that column being empty is the very gap the institution match exists to fill*. Where the users
actually live is not that column, and it separates the cases the old cut could not: USP's people are
in Brazil, Harvard's are not.

The criterion keeps every disjunct it had and adds one, so the alternative cohort is a strict
superset of the original and the anti-join asserts it member by member. Two things about it are worth
carrying:

**It amplifies on purpose.** A surviving school admits everyone under it — foreign students at USP,
and the minority of strings Revelio resolved wrongly. That is what a school-key criterion *is*, and
it is why the only number worth reading is how many members the arm admits alone and what share of
them are in Brazil, against C_norm's 5,705 at 32.5% and the withdrawn branch's 12,023 at 6.3%.

**That share is only half a test.** The gate is built on `user_country`, so a good result there is
partly guaranteed by construction. The independent read is `p_brazil`, which knows nothing about
either the gate or the criterion, and the script reports both side by side. Quote them together or
not at all.

The schools the gate throws out are written to a CSV rather than counted, one row per rejected
school–string pair with both shares and the school's modal country, because that file is how the
gate is judged: Harvard, Phoenix, Delhi, Stanford, Cambridge, Toronto, UNAM and Berkeley belong in
it, and USP, UNICAMP, UFRJ, FGV and Estácio belong among the survivors.

Run 2026-09-04, and they did. Of 975 schools reached, 667 survive at 94.9% of their users in Brazil;
the 217 in the bottom band reach 35.6M users at **0.34%** and are thrown out. Harvard lands at 0.030,
Phoenix at 0.0012, Delhi at 0.0006, against USP 0.949 and Estácio 0.970 — two orders of magnitude of
separation, where `match_share` managed about one. The criterion adds **27,838** members at 22.5%
located in Brazil, against the withdrawn branch's 12,023 at 6.3%, and the independent name prior
agrees with that reading rather than contradicting it.

### How much C_norm still misses

*Script: `c_norm_coverage_audit.R`.*

Everything above is about what C_norm *adds*. The opposite question — of the strings that really do
name a Brazilian institution, how many does it reach — went unasked until this audit, because the
only other check on the matcher measures precision and says so.

Group the education extract by Revelio's school key, keep the 744 schools where C_norm matched at
least one string, sample 500, and read every string under them. Coverage splits in two: on the 359
schools where the match is dominant it reaches **92.2%** of rows, and on the rest it collapses. Hand
classifying a row-weighted sample of the unmatched rows, and removing the schools that are foreign
(where not matching is correct) and the strings that belong to a different institution, leaves

> **recall ≈ 51.6%. C_norm reaches about half the rows it should.**

The tempting explanation — that the school key is contaminated and the gap is an artefact of
measuring this way — is wrong, and the audit is built to show it: contamination accounts for about
101,000 rows out of 2.76 million unmatched. The misses are real.

Two causes account for three quarters of them, and **the larger one is not a matching problem at
all**. 42% of missed rows are strings for which *no record in the OpenAlex Brazilian list is
reachable* — ETEC, SENAI and SENAC units and many private faculdades are simply not in OpenAlex, a
gap only a better institution list can close. The next 34% are bare brand acronyms, and here the
audit contradicts a claim made earlier in this chain: bare acronyms are 1.5–2.5% of an
institution's rows **for USP, FGV and UNICAMP**, which is where that was measured. For the private
brand-name universities the acronym is the name people actually type — `UNINOVE` is 83.5% of its
school's rows, `UniCesumar` 89.0%, `UNIASSELVI` 95.6%.

None of this changes the cohort. C_norm added only 5,705 members, so even a large recall gain would
move membership very little — the same row-gain-is-not-cohort-gain lesson as above. What it changes
is the `br_openalex_norm` flag, which is much less complete than it looks.

---

## Extracting the cohort's position and education histories

*Script: `obmep_candidates_step_1_entries.R`.*

The cohort table carries only the flags and dates that admitted each user. This step pulls the
records behind them: **every** position and **every** education entry those 6,849,674 people have,
Brazilian or not. No new criterion, no filtering beyond cohort membership.

| | rows | size | per member |
|---|---|---|---|
| position | **30,389,044** | 5.00 GB | 4.44 |
| education | **15,712,737** | 0.91 GB | 2.29 |

**Both extracts contain exactly 6,849,674 distinct users** — every cohort member — and the script
asserts it. That is not luck: criterion D admits nobody without a parseable position and E nobody
without a bachelor, so a short count would mean the filter dropped members rather than that the data
is thin. It is the strongest check in the run.

The position `startdate` range confirms the cohort definition rather than describing the source: **no
member has a position before 2007-01-01**, which is exactly what criterion D requires. Education has
no such floor, because E constrains only the first *bachelor* — high-school rows reach back to 1900.

Two things a reader of these files needs to know:

- **`startdate` is a STRING on position and a DATE on education.** This is a genuine type difference
  in the source tables, the two DDLs differ accordingly, and they must not be harmonised.
- **The local copy is a directory of parts, and the files have no `.parquet` extension.** Athena
  names unloaded objects `<query-id>_<uuid>`, so globbing for `*.parquet` finds nothing. Read them
  with `arrow::open_dataset(dir, format = "parquet")`, passing the format explicitly.

At 495 GB scanned (≈ $2.42) this is the most expensive stage in the chain, and the `description`
column is about 47% of that bill. It was kept deliberately: a single column cannot be scanned in
isolation, so adding it later would mean paying the whole amount again rather than an increment.

---

## Flagging degrees from top-ranked universities

*Script: `shanghai_top1000_degree_flags.R` — the endpoint of the chain.*

One question for every cohort member: **does this person hold a bachelor's, master's or PhD from a
top-1000 Shanghai-ranked university?** It is the same question criterion C_norm answers for Brazilian
institutions, asked of a different institution list and split by degree level.

It is offline and costs nothing — about a minute of DuckDB — because the education extract was
already paid for once.

**The ranking column is a band, not a position.** It is exact from 1 to 100, then jumps: 101, 151,
201, 301, …, 901, each value being the start of a band. So "top 1000" is `Rank <= 901`, which selects
exactly 1,000 rows. The script asserts that count *before* scanning anything and aborts rather than
warns, because if the bands ever change the arithmetic must be re-derived, not silently
reinterpreted.

The institution side is the union of all three available name spellings — the OpenAlex display name,
its de-parenthesised form, and the ranking's own name — folded and deduplicated into 1,246 strings.
One spelling is not enough: the ranking anglicises where OpenAlex uses the endonym, and both are
things people type.

The match itself is criterion C_norm again — fold accents, compare lowercased, accept the match on
the whole string or on any `/`, `( )` or `" - "` delimited segment of at least 3 characters — with
one departure: **the segment arm carries no `education`-only restriction here**, because the
Shanghai list contains nothing but universities.

It reads **two** columns, not one. `university_raw` is what the person typed; `university_name` is
Revelio's normalisation, which carries the English canonical name. Raw takes precedence, so the
normalised name only decides when the raw string does not match — precedence matters because Revelio
is occasionally wrong about identity. Adding the second column is worth **+105,272 flagged users
(+11.9%)**, landing exactly where expected: `Universität Wien` → *University of Vienna*,
`Università degli Studi di Torino` → *University of Turin*.

Degree level is assigned by a four-arm cascade whose **order is load-bearing**:

```
1. not a degree at all        -> other      (tested FIRST)
2. doctorate                  -> phd
3. master's or MBA            -> master
4. bachelor                   -> bachelor
5. otherwise                  -> other
```

The not-a-degree arm runs first because `pós-doutorado` contains `doutorado` and would otherwise read
as a doctorate *earned* at the host university. A post-doctoral stay is not a degree. Doctorate is
tested before master's so that `Mestrado e Doutorado` resolves to the higher of the two. Enrolment
counts, not graduation — `mestrando` and `doutorando` set their flags — because Revelio records
enrolment and has no graduation field, which is the same property criterion E already has.

| | |
|---|---|
| Institution strings after folding | 1,246 (1,000 ranked rows × 3 name columns) |
| Distinct `university_raw` scanned | 1,417,851 |
| Matched education rows | 1,607,459 |
| **Users flagged** | **990,937** |
| — reachable from `university_raw` alone | 885,665 |
| `sh_bachelor` | 856,076 |
| `sh_master` (including MBA) | 272,255 |
| `sh_phd` | 54,985 |

Two limitations to carry: **a bare acronym does not match** — `MIT` or `Cambridge` alone is not found
unless the string also carries the full name — and **homonyms match wrongly**, as when a Philippine
campus reaches the American Saint Louis University through the segment arm. Exact-after-normalisation
cannot separate those, and the withdrawn school-key branch is the argument against reaching for
anything looser.

---

## Flagging the firms and universities people worked for

*Scripts: `obmep_candidates_step_1_position_rcid.R`, `linkedin_company_rcid.R`,
`obmep_candidates_step_1_firms.R` — the second endpoint of the chain.*

The Shanghai stage asks where a cohort member **studied**. This one asks where they **worked**,
against four lists: 341 Hurun tech unicorns, the 200 largest tech firms by market cap, the 23
Brazilian universities in the RUF 2025 top 10 of any of the 12 STEM courses, and the 1,000
universities of the Shanghai top-1000.

The Shanghai list appears on both sides, which is where the four prefixes come from: `sh_` studied
at a Shanghai top-1000 and `sw_` worked at one; `rd_` studied at a RUF top-10 and `rf_` worked at
one. `rf_` and `sw_` are the same arm reading different institution tables — `classify()` takes them
as arguments and returns neutral `m_rank` / `m_id` / `m_inst` columns, so the matcher never knows
which list it served. `sw_` has no acronym arm, because the Shanghai source carries no abbreviation
column to fold.

The difference between the two questions is the join key. A degree has only a typed string to go on,
so the Shanghai stage matches names and lives with what that costs. An employer has an identifier —
Revelio's `rcid` — and where an identifier exists there is no reason to match strings at all.

### The key was never extracted

`academic_individual_position` has 47 columns. The position extract took 12 of them, and not one
identifies a company: `company_raw`, `company_cleaned` and `company_linkedin_url` are three strings,
and the URL is NULL on 28% of positions.

So a fourth extract was needed, and the design question was how little it could read. Cost is set by
columns, so `user_id, position_id, rcid, ultimate_parent_rcid` — four integers, joined back on
`position_id` — is **40.43 GB and about $0.20**, against the 444 GB it would take to re-run the
original extract with one column added.

| | |
|---|---|
| Rows | **30,389,044** — identical to the position extract |
| Distinct users | **6,849,674** — the whole cohort |
| `rcid` resolved | 23,901,223 — **78.7%** |
| Distinct firms | 2,089,051 |

**The strongest check here is that the two extracts saw the same table.** They are separate scans of
live data; if Revelio refreshed between them, `position_id` stops being a join key and every
downstream join goes silently partial. The anti-join runs in both directions and aborts on any
difference. It came back 0 and 0.

The extract is stored **whole**, not filtered to the few hundred firms of interest. Filtering in
Athena would have scanned identical bytes for identical money, and the next change to the company
lists would have paid it again. Stored whole, every later employer question is offline and free.

### Resolving the lists: 468 of 521

`academic_company_ref` turns out to be one row per company — 26,596,058 rows, 26,596,058 distinct
`rcid` — and it carries `linkedin_url`. So resolving the two hand-researched CSVs is exact URL
equality after folding both sides to the same shape, and no name matching enters anywhere.

Of 521 distinct listed URLs, **468 resolve**. The 53 that do not are the interesting part, and they
are not the companies you would guess: **Zoom, Cadence, Expedia, Coherent, Block and X** are all in
the group. They are not missing from Revelio. LinkedIn lets a company page carry a vanity slug
beside its canonical one, and the hand research recorded one while Revelio recorded the other.

Two ways out were measured and both rejected. **Ticker** reaches only 3 of the 53 unambiguously.
**Company name** is worse than useless:

```
Block -> block-workspace | block
X     -> yakirox-cagri-hizmetleri | x_2
Cars  -> carsvtc | 2b-panzer-company
```

This is the same lesson the institution lists taught, sharpened: short company names are real names
belonging to other companies, which is not true of universities.

The way out that worked costs nothing. The cohort's own 30 million positions carry
`company_linkedin_url` *and* the `rcid` Revelio assigned — so the listed URL can be looked up in the
data itself. Still exact equality on a URL. It recovered **13 of the 53**, worth 1,216 flagged
users, and rejected the one URL that mapped to two firms rather than picking the commoner.

### What it flags

| | users | |
|---|---|---|
| **any list** | **436,813** | 6.38% of the cohort |
| unicorn | 28,735 | |
| market cap | 159,638 | |
| RUF top 10 | 142,151 | |
| Shanghai top 1000 | 233,290 | name only, no acronym arm |

**The orderings are the validation.** Nothing asserts that a Brazilian cohort's unicorn employers
should be Brazilian unicorns, but they are: QuintoAndar, Creditas, Rappi, Didi, SumUp, Kavak, in
that order. The market-cap list gives IBM, Amazon, Uber, Alphabet, Microsoft. The RUF list
reproduces the RUF ranking — USP, UFMG, UFRJ, Unicamp.

The university side is criterion C_norm once more, with one addition: a **bare-acronym arm** in its
own column, whole-string equality only. It is the arm most likely to be wrong — USP is also United
States Pharmacopeia — and it came out clean, every one of its 30 matched strings an unambiguous
Brazilian university acronym typed as an employer. That is a property of this cohort, not of the
method, and the column stays separate so anyone who does not want it can drop it with a `WHERE`.

And the honest limit, reported rather than fixed: **3,211 positions** point at one of these
universities' own LinkedIn school pages without any name arm catching them. That is a floor, since
the measurement only sees the 9 institutions whose page slug is their acronym.

---

## Reading and re-running the outputs

| product | grain | rows |
|---|---|---|
| `revelio_database.linkedin_br_name_flag` | one row per profile scoring > 0.05 | 140,263,729 |
| `revelio_database.obmep_br_cohort_user_ids` | one row per user | 5,736,020 |
| `revelio_database.obmep_br_name_cohort_user_ids` | one row per user | 3,779,509 |
| `revelio_database.obmep_candidates_step_1` | one row per user | 6,849,674 |
| `obmep_candidates_step_1_position` | one row per position | 30,389,044 |
| `obmep_candidates_step_1_education` | one row per education entry | 15,712,737 |
| `obmep_candidates_step_1_shanghai.parquet` | one row per flagged user | 990,937 |
| `obmep_candidates_step_1_position_rcid` | one row per position | 30,389,044 |
| `linkedin_company_rcid_2026.parquet` | one row per resolved firm | 468 |
| `obmep_candidates_step_1_firms_positions.parquet` | one row per matched position | 737,682 |
| `obmep_candidates_step_1_firms.parquet` | one row per flagged user | 436,813 |
| `obmep_candidates_step_1_ruf_degree.parquet` | one row per flagged user | 583,570 |
| `obmep_candidates_selected.parquet` | one row per selected user | 1,297,109 |
| `revelio_database.rsid_br_user_share` | one row per matched (rsid, `university_raw`) pair | 24,276 over 975 rsids |
| `revelio_database.obmep_br_cohort_user_ids_alt` | one row per user | 5,763,858 |
| `revelio_database.obmep_candidates_step_1_alt` | one row per user | 6,870,111 |

### Every cut can be tightened without a rebuild

A convention runs through all of these: **each table stores the flags for criteria it does not filter
on, and stores the narrower version of every definition that was widened.** `br_openalex` sits beside
`br_openalex_norm`, `sh_raw_any` beside `sh_any`, `min_bach_year_strict` beside `min_bach_year`, and
the raw `p_brazil` beside the `br_name` flag.

The consequence is that a cut can be tightened, or a widening reversed, with a `WHERE` clause in
Athena instead of regenerating anything — and every selected `user_id` is auditable back to whatever
admitted it. Loosening a definition still needs a rebuild.

### What a rebuild costs

| job | scanned | approx |
|---|---|---|
| name flag (steps 1–2) | local only | ~8 min, no scan cost |
| either cohort | ~36–48 GB | $0.19–0.24 |
| `obmep_candidates_step_1` | ~0.85 GB | $0.004 |
| position + education histories | 495 GB | **$2.42** |
| top-university degree flags | local only | ~1 min, free |
| position `rcid` map | 40.43 GB | **$0.20** |
| company list -> `rcid` | ~5 GB | $0.03 |
| employer flags | local only | ~2 min, free |

Rebuilding an Athena-backed stage is not just re-running the script: every unload guards its
destination, so the table must be dropped and the S3 prefix cleared first. The local stages are
idempotent and skip any output that already exists — delete the output to force a rebuild.

For the assertions each script enforces, the engine-specific traps that must not be reintroduced,
and the full re-run procedure, see [`../README.md`](../README.md).
