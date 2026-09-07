> **Folder scope.** Pipelines that build external datasets on this machine against Dropbox data.
> Everything here runs **locally, outside SEDAP**, and nothing here may be copied into
> `scripts_sedap/` — see `AGENTS.md` → *Execution Environments*.
>
> **Network use is mixed.** Some files need no network beyond having their snapshots already
> downloaded; the rest reach CRAN, S3 and Athena. The `Net` column is the source of truth, because
> the difference decides whether a file can run on a disconnected machine and what it costs to
> re-run. Deliberately do not maintain a second count here — it repeatedly went stale as stages were
> added.

| # | File | Net | Reads | Writes |
|---|---|---|---|---|
| | **LinkedIn name flag** | | | |
| 1 | `linkedin_br_name_flag.R` | — | GTAllocation LinkedIn names | OBMEP `linkedin_br_flags/` |
| 2 | `linkedin_br_flag_to_s3.R` | S3 + Athena | output of 1 | `linkedin_br_name_flag` |
| | **OpenAlex institutions** | | | |
| 3 | `openalex_br_institutions.R` | — | GTAllocation OpenAlex snapshot | OBMEP `openalex_institutions/` |
| 4 | `shanghai_ranking_openalex_names.R` | — | Shanghai xlsx + OpenAlex snapshot | OBMEP `shanghai_ranking/shanghai_ranking_oa{,_acronyms}.parquet` |
| 5 | `openalex_institutions_br_to_s3.R` | S3 + Athena | output of 3 | `openalex_institutions_br` |
| | **OpenAlex author histories** | | | |
| 5a | `openalex_author_history.R` | — | `D:/OpenAlex/works` parquet snapshot | OBMEP `openalex_authors/` |
| 5b | `openalex_author_flags.R` | — | works snapshot + output of 5a | OBMEP `openalex_authors/openalex_author_flags.parquet` |
| 5c | `openalex_author_br_stem_2017plus.R` | — | outputs of 5a and 5b | OBMEP `openalex_authors/openalex_author_br_stem_2017plus.parquet` |
| 5d | `openalex_author_br_stem_2017plus_institutions.R` | — | works snapshot + output of 5c | OBMEP `openalex_authors/openalex_author_br_stem_2017plus_institutions.parquet` |
| 5e | `openalex_author_stem_2017plus_br_name_scores.R` | — | `D:/OpenAlex/authors` + outputs of 5a and 5b + IBGE names | OBMEP `openalex_authors/br_name/` |
| 5f | `openalex_author_br_institution_or_name_stem_2017plus.R` | — | outputs of 5d and 5e + works snapshot | OBMEP `openalex_authors/openalex_author_br_institution_or_name_stem_2017plus.parquet` |
| | **Revelio rsid crosswalk** | | | |
| 6 | `rsid_openalex_br_crosswalk.R` | Athena | Revelio + 5 | `rsid_openalex_br` *(unused)* |
| | **OBMEP candidate cohorts** | | | |
| 7 | `br_degree_patterns.R` | — | *(nothing — sourced constants)* | *(nothing)* |
| 8 | `revelio_br_cohort_user_ids.R` | Athena | Revelio + 5 | `obmep_br_cohort_user_ids` |
| 9 | `revelio_br_name_cohort_user_ids.R` | Athena | Revelio + 2 + 5 | `obmep_br_name_cohort_user_ids` |
| 10 | `obmep_candidates_step_1.R` | Athena | 8 + 9 + 2 | `obmep_candidates_step_1` |
| | **The alternative cohort — rsid propagation, gated** | | | |
| 8a | `rsid_br_user_share.R` | Athena | Revelio + 5 | `rsid_br_user_share` + OBMEP `revelio_br_cohort/rsid_br_user_share{.parquet,_rejected.csv}` |
| 8b | `revelio_br_cohort_user_ids_alt.R` | Athena | Revelio + 5 + 8a | `obmep_br_cohort_user_ids_alt` |
| 10alt | `obmep_candidates_step_1_alt.R` | Athena | 8b + 9 + 2 | `obmep_candidates_step_1_alt` |
| 8d | `rsid_openalex_id_crosswalk.R` | — | 8a + 3 | OBMEP `revelio_br_cohort/rsid_openalex_id_crosswalk.parquet` |
| 8e | `rsid_coverage_audit.R` | Athena | Revelio + 3 + 8a | `rsid_coverage_audit` + OBMEP `revelio_br_cohort/rsid_coverage_audit.parquet` |
| 8f | `rsid_openalex_one_to_one.R` | — | 8d | OBMEP `revelio_br_cohort/rsid_openalex_safe_map.parquet` + `rsid_oa_link_{worksheet.parquet,class.csv}` |
| 8g | `ruf_shanghai_rsid_degree_flags.R` | — | 8f + 10a + 15 + 15a + 4 + 7 | OBMEP `revelio_br_cohort/obmep_candidates_step_1_rsid_degree.parquet` |
| 8m | `revelio_oa_crosswalk.R` | — | 10a + 8f + 8d + 16b + `shanghai_rsid_name_map` + 8i + the 8l arms | OBMEP `revelio_br_cohort/revelio_oa_crosswalk{,_by_raw}.parquet` + `revelio_oa_coverage.csv` |
| 8k | `norsid_raw_match_sample.R` | — | 8h | OBMEP `revelio_br_cohort/norsid_match_{dev,holdout}.parquet` + `norsid_match_labels{,_holdout}.csv` |
| 8l | `norsid_raw_match.R` | — | 8k + 8i's snapshot cache | scores only; no data product |
| 8j | `unmatched_school_audit_sample.R` | — | 8i | OBMEP `revelio_br_cohort/unmatched_school_audit_sample.{parquet,xlsx}` |
| 8i | `unmatched_school_name_worksheet.R` | — | 8h + the OpenAlex institutions snapshot under `GT_ROOT` | OBMEP `revelio_br_cohort/unmatched_school_{name_class.csv,openalex_map.parquet}` + `oa_institution_{cache,cand_names,fold_cache}.parquet` |
| 8h | `unmatched_university_raw_openalex.R` | — | 10a + 8f + 8d + 16b + `shanghai_rsid_name_map` + 7 | OBMEP `revelio_br_cohort/unmatched_openalex_{education_rows.csv,education_rows.parquet,university_raw.csv,coverage.csv}` |
| | **Candidate histories** | | | |
| 10a | `obmep_candidates_step_1_entries.R` | S3 + Athena | Revelio + 10 | `obmep_candidates_step_1_position`, `..._education` |
| 10b | `obmep_candidates_step_1_position_rcid.R` | S3 + Athena | Revelio + 10 | `obmep_candidates_step_1_position_rcid` |
| 10c | `obmep_candidates_step_1_position_role_loc.R` | S3 + Athena | Revelio + 10 + 10a | `obmep_candidates_step_1_position_role_loc` |
| 10d | `role_title_audit.R` | — | 21a + 10a | OBMEP `revelio_br_cohort/role_audit_*` |
| 10e | `role_audit_review.R` | — | 10d | OBMEP `revelio_br_cohort/role_audit_review.xlsx` |
| 10f | `role_jobcat_audit.R` | — | 21a + 10a | OBMEP `revelio_br_cohort/jobcat_audit_*` |
| 10g | `role_desc_audit.R` | — | 10d + 10a | OBMEP `revelio_br_cohort/role_desc_*` |
| 10h | `role_field_manual.R` | — | 21a + 10a | OBMEP `revelio_br_cohort/field_manual_*` |
| 10i | `field_manual_review.R` | — | 10h | OBMEP `revelio_br_cohort/field_manual_review.xlsx` |
| | **Validation** | | | |
| 11 | `linkedin_br_name_audit.R` | — | output of 1 | OBMEP `linkedin_br_flags/name_audit_*` |
| 12 | `name_only_country_check.R` | Athena | 10 + Revelio | OBMEP `revelio_br_cohort/name_only_user_country.parquet` |
| 13 | `name_only_us_fullname_check.R` | Athena | 10 + Revelio | OBMEP `revelio_br_cohort/name_only_us_fullname_*` |
| 13a | `c_norm_coverage_audit.R` | — | 3 + 10 + 10a | OBMEP `revelio_br_cohort/c_norm_coverage_*` |
| | **RUF course rankings and the OpenAlex crosswalk** | | | |
| 14 | `ruf_course_rankings.R` | ruf.folha.uol.com.br | RUF JSON API | OBMEP `ruf_ranking/ruf_course_ranking_2025.parquet` |
| 15 | `ruf_stem_top50.R` | — | output of 14 | OBMEP `ruf_ranking/ruf_stem_top<N>_2025.parquet` + `..._institutions_2025.parquet` |
| 15a | `ruf_openalex_br_crosswalk.R` | — | 15 + 3 | OBMEP `ruf_ranking/ruf_openalex_br_2025.parquet` |
| | **Top-1000 Shanghai degrees** | | | |
| 16 | `shanghai_top1000_degree_flags.R` | — | 4 + 10a + 7 | OBMEP `revelio_br_cohort/obmep_candidates_step_1_shanghai.parquet` |
| 16a | `shanghai_acronym_arm.R` | — | 4 + 10a + 7 | OBMEP `revelio_br_cohort/obmep_candidates_step_1_shanghai_acr.parquet` + `shanghai_acronym_{candidates,class}.csv` |
| 16b | `shanghai_raw_crosswalk.R` | — | 4 + 16a + 10a | OBMEP `revelio_br_cohort/shanghai_raw_crosswalk.parquet` |
| 17 | `shanghai_flag_audit.R` | — | 16 + 10a + 7 + 4 | OBMEP `revelio_br_cohort/shanghai_audit_*` |
| | **Employer flags** | | | |
| 18 | `linkedin_company_rcid.R` | Athena | the two company CSVs + Revelio | OBMEP `linkedin_company_urls/linkedin_company_rcid_2026.parquet` + `..._unresolved_...` |
| 19 | `obmep_candidates_step_1_firms.R` | — | 10a + 10b + 18 + 15 + 15a + 4 | OBMEP `revelio_br_cohort/obmep_candidates_step_1_firms{,_positions}.parquet` |
| | **Top-10 RUF degrees** | | | |
| 20 | `obmep_candidates_step_1_ruf_degree.R` | — | 10a + 15 + 15a + 7 | OBMEP `revelio_br_cohort/obmep_candidates_step_1_ruf_degree.parquet` |
| | **The selected candidates** | | | |
| 21 | `obmep_candidates_selected.R` | — | 16 + 19 + 20 + GTAllocation LinkedIn names | OBMEP `revelio_br_cohort/obmep_candidates_selected.parquet` |
| 21a | `obmep_candidates_selected_positions.R` | — | 21 + 10c | OBMEP `revelio_br_cohort/obmep_candidates_selected_positions.parquet` |
| 21alt | `obmep_candidates_selected_alt.R` | — | 16 + 19 + 20 + 8g + 16a + GTAllocation LinkedIn names | OBMEP `revelio_br_cohort/obmep_candidates_selected_alt.parquet` |
| 21a-alt | `obmep_candidates_selected_positions_alt.R` | — | 21alt + 10c | OBMEP `revelio_br_cohort/obmep_candidates_selected_positions_alt.parquet` |
| | **CAPES stricto sensu discentes** | | | |
| 22 | `download_capes_discentes.R` | dadosabertos.capes.gov.br | CAPES CKAN API | OBMEP `Data/raw/capes_discentes/` (21 xlsx, 1.1 GB) |
| 23 | `capes_discentes_panel.R` | — | output of 22 | OBMEP `capes_discentes/by_year/*.parquet` + `capes_discentes_2004_2024.parquet` |
| 24 | `capes_masters_doctorates_born_1988plus.R` | — | output of 23 | OBMEP `capes_discentes/capes_masters_doctorates_born_1988plus_2004_2024.csv` |
| 25 | `capes_openalex_br_crosswalk.R` | — | outputs of 24 + 3 | OBMEP `capes_discentes/capes_openalex_br_crosswalk{.parquet,_unmatched.csv}` |
| 26 | `capes_openalex_manual_crosswalk.R` | manual web | unmatched output of 25 + output of 3 | OBMEP `capes_discentes/capes_openalex_manual/` |
| | **CAPES x selected candidates** | | | |
| 27 | `capes_obmep_candidates_name_match.R` | — | 24 + 25 + 26 + 10a + 21 + 8f + 7 | OBMEP `capes_discentes/capes_obmep_match{,_noinst}/` — two variants, see `OBMEP_MATCH_KEY_OA` |
| 27a | `capes_obmep_match_sample.R` | — | 27 + 24 + 25 + 26 + 10a + 8f + 3 + 7 | OBMEP `capes_discentes/capes_obmep_match/capes_obmep_match_sample.{parquet,xlsx}` |
| 27b | `capes_obmep_match_placebo.R` | — | 27 | OBMEP `capes_discentes/capes_obmep_match/capes_obmep_match_placebo.parquet` |

## TO-DO

Open work on the CAPES ↔ selected-candidate match (scripts 27, 27a, 27b), parked mid-2026-09-06.
Both items below were measured this session; the numbers are scope, not estimates. Full context in
[Matching CAPES people to the selected candidates](#matching-capes-people-to-the-selected-candidates).

### 1. Replace every OpenAlex id with its parent (root) id

**Why.** CAPES resolves `FUNDAÇÃO GETÚLIO VARGAS (SP)` to `I44202434`; Revelio resolves `FGV EESP`
to `I4403928399` (*Escola de Economia de São Paulo*). Same university, parent record against
constituent school, so the two key slots disagree and the pair is never compared. Rolling both sides
to the root of the lineage makes them agree.

**Feasible — the data is already in the snapshot.** `openalex_br_institutions.R` (3) declares seven
keys in its `read_ndjson` projection and these two are not among them:

```
lineage                  VARCHAR[]
associated_institutions  STRUCT(id, ror, display_name, country_code, type, relationship)[]
```

`I4403928399` carries `lineage [I4403928399, I44202434]` and an `associated_institutions` entry
naming `I44202434` with `relationship = 'parent'`. A root map over all **120,658** institutions
resolves to **117,431 unique roots, 0 with no root, 3,227 ambiguous**.

**Two traps.**

- **Lineage order is not reliable.** 105,846 institutions list themselves first, but **11,672 list
  themselves last**. Neither `lineage[1]` nor `lineage[len(lineage)]` is the root. The robust rule is
  *the ancestor whose own lineage has length 1*. Depth reaches **30**, so this is not a two-level
  tree.
- **3,227 institutions have more than one root** in their lineage. The roll-up is not a function for
  them and needs an explicit rule, not a `min()`.

**Measured payoff: 167 pairs, 0.2%.** Of the 94,737 conservative `_noinst` pairs whose master's ids
differ, only 167 share a root; 165 of those also match on name exactly. It is almost entirely FGV,
whose schools each hold their own OpenAlex record while CAPES names the foundation. **Do not
implement this expecting the match rate to move** — and note it would *not* have recovered the case
that prompted it, because that person's year also disagrees (CAPES 2023, LinkedIn 2022), so she is
not among the 167. The year discrepancy is the larger of the two problems and no institution work
addresses it.

### 2. Attribute an OpenAlex id to every remaining `university_raw`

**Scope** — Bachelor, Master and Doctorate rows of the selected candidates (MBA excluded from the
master's arm), classified by `sql_shanghai_level`:

| level | rows | users | resolved | share | distinct strings left |
|---|---|---|---|---|---|
| bachelor | 1,538,367 | 1,294,203 | 930,509 | 60.5% | 40,691 |
| master | 401,676 | 354,850 | 150,522 | 37.5% | 20,241 |
| doctorate | 79,968 | 75,536 | 44,096 | 55.1% | 5,306 |
| **unresolved total** | **894,884** | 571,921 | — | — | **53,090** |

**Order the work Brazilian-first.** Of the unresolved rows, **73,072 across 8,783 distinct strings
are plausibly Brazilian**; the rest are foreign institutions, which for CAPES matching can only
remove false positives, never add a match. The Brazilian tail is short — among the rows Revelio
labels `Brazil`, the top 25 strings cover 77.6% and the top 100 cover 93.3%.

**Both the list and the first pass now exist.** `unmatched_university_raw_openalex.R` (**8h**) writes
the list — see [The unmatched `university_raw` list](#the-unmatched-university_raw-list) — and
`unmatched_school_name_worksheet.R` (**8i**) works it at the school grain, which is the cheaper and
correct grain: see [Resolving the unmatched rows by school](#resolving-the-unmatched-rows-by-school).

**Do not start by cleaning strings.** Revelio already names 71.5% of these rows, and matching those
names against the **full** 120,658-institution snapshot (not the 1,947 Brazilian records) is what
moves the number. 8i has published **418 schools / 747,109 rows / 688,364 users** and parked a
deliberate `PENDING` tail of 491 schools whose median is 675 rows each.

**What is actually left**, in descending order of value:

1. The 491 `PENDING` schools in `unmatched_school_name_class.csv` — flat curve, resume any time.
2. The **293,941** strings with no `rsid` and no `university_name` (808,218 rows). This is the only
   slice where extracting a name from `university_raw` is genuinely the bottleneck, and it is the
   expensive, singleton-dominated one.
3. Widening 8i past the top 1,000 schools (`OBMEP_SCHOOL_TOP_N`); 2,500 would reach 82.7% of the
   named slice.

**Start from what is already on disk.** `rsid_openalex_id_crosswalk.parquet` (8d) is the
many-to-many `rsid → openalex_id` map *before* 8f's one-to-one safety filter;
`shanghai_rsid_name_map.parquet` reaches 895 rsids against 828 ranked institutions; the C_norm name
matcher lives in scripts 16/19/20; script 26's batch-research workflow is the pattern for the
hand-resolved tail. `openalex_br_institutions.R` (3) is Brazil-only by construction and needs a
sibling before any foreign institution can be resolved at all.

**Two caveats.**

- `university_country` is Revelio's own field and is not reliable — it is why the Brazilian figure
  above is a range rather than a count. Re-derive the country from the resolved OpenAlex record
  rather than trusting the column, and re-check the split once resolution is wider.
- Script 13a already measured C_norm recall at **51.6%**, so a name-matching route does not close
  this on its own.

---

## The unmatched `university_raw` list

Script **8h**, `unmatched_university_raw_openalex.R`, writes the list TO-DO item 2 asks for. Offline,
re-runnable, a few minutes over the education directory.

**Scope is all of `obmep_candidates_step_1_education`**, not the selected-candidate subset the TO-DO
table above is measured on, and a row is in scope if **either** degree definition accepts it —
`sql_shanghai_level IN ('bachelor','master','phd')` with MBA out of the master's arm, **or** Revelio's
literal `degree IN ('Bachelor','Master','Doctor')`. The two disagree hard and asymmetrically:

| scope | in scope | unmatched |
|---|---|---|
| both definitions agree | 5,202,558 | 2,026,894 |
| `sql_shanghai_level` only | 3,294,087 | 797,822 |
| Revelio `degree` only | 8,580 | 4,137 |

Filtering on Revelio's `degree` alone would silently drop 797,822 unmatched rows — the 58.4%-recall
failure script 7 documents. `by_level` and `by_degree` ship as columns, so either view survives.

**Four maps are consulted, not one**, in priority order, with `oa_source` recording the winner:

| `oa_source` | map | rows resolved |
|---|---|---|
| `safe_map` | `rsid_openalex_safe_map.parquet` (8f), `safe = 1`, on `rsid` | 5,104,434 |
| `shanghai_raw` | `shanghai_raw_crosswalk.parquet` (16b), on `university_raw` | 503,090 |
| `shanghai_name` | `shanghai_rsid_name_map.parquet`, `keep = 1`, on `rsid` | 63,635 |
| `crosswalk_8d` | `rsid_openalex_id_crosswalk.parquet` (8d), on `rsid` + `university_raw` | 1,917 |
| *(unmatched)* | — | **2,832,149** |

This matters because **the safe map is Brazil-only by construction** (script 3 filters
`country_code = 'BR'`), so under it alone every foreign university reads as unmatched even when its id
is already on disk — Complutense Madrid `I24354313`, Politecnico di Torino `I99682543`, Granada, UCF
are all resolved by 16b. The three extra maps resolve **568,642 in-scope rows the safe map does not**.

Only 8f carries the one-to-one safety guarantee. **Anything with `oa_source <> 'safe_map'` is not
safe-map quality** and must not be fed to script 27's key without its own review.

Flags are stored, not filtered: the row-level file holds every in-scope row the *safe map* missed, so
`oa_source IS NULL` gives the genuinely-unresolved set and the whole file gives the safe-map baseline.

**Outputs**, all in `revelio_br_cohort/`:

| file | rows | size |
|---|---|---|
| `unmatched_openalex_education_rows.csv` | 3,400,791 | 510 MB |
| `unmatched_openalex_education_rows.parquet` | 3,400,791 | 69 MB |
| `unmatched_openalex_university_raw.csv` | 361,382 | 24 MB |
| `unmatched_openalex_coverage.csv` | 19 | — |

The worksheet is the one to work: one row per unresolved string with `n_rows`, `n_users`, the
bachelor/master/phd split and blank `openalex_id` / `note` columns, sorted `plausibly_br DESC,
n_rows DESC`. 104,388 unresolved rows are Revelio-labelled Brazilian; `plausibly_br` is that label, and
per caveat 1 above it is not a country.

Two things the script asserts. It **reproduces the TO-DO table exactly** — re-running the scope under
the three restrictions that produced it (selected candidates, level scope, safe map only) returns
1,538,367 / 401,676 / 79,968 rows and 930,509 / 150,522 / 44,096 resolved, `stop()` on any drift; this
is the strongest cross-check available, since the two counts come from different code. And it
spot-checks that the named foreign institutions carry `oa_source = 'shanghai_raw'`, which is what
fails loudly if the union of maps ever stops being wired in.

`university_raw` is NULL or blank on 3,265 unresolved rows. There is no string there to resolve, so
they stay in the row-level file and are excluded from the worksheet — the same predicate 8a and 16
apply before matching.

---

## Resolving the unmatched rows by school

Script **8i**, `unmatched_school_name_worksheet.R`, works the gap 8h measures. It does **not** clean
`university_raw` strings, and the reason is the single most useful measurement in this section:

**Revelio has already named 71.5% of the unmatched rows.**

| | rows | share | distinct `university_raw` |
|---|---|---|---|
| has a Revelio `university_name` | **2,022,578** | 71.5% | 79,694 |
| no `university_name`, no `rsid` | 808,218 | 28.6% | 293,941 |
| has `rsid`, no name (anomaly) | 1,353 | <0.1% | 87 |

The named slice collapses from 79,694 strings to **27,432 schools** — FMU absorbs 360 spellings,
IFSP 496, UNIASSELVI 286 — so resolving a school once resolves every spelling of it. An LLM pass over
all 361,382 strings was costed at ~3.6M input tokens and would have re-derived names already in the
data. Working at the school grain instead: 100 schools reach 31.0% of the named slice, 500 reach
54.0%, 1,000 reach 66.6%.

**Match against the FULL snapshot, not the Brazilian list.** `openalex_institutions_br.parquet` holds
1,947 records; the snapshot under `GT_ROOT` holds **120,658**. Measured, that is the difference
between a fold resolving **142** schools and resolving **7,659** (669,638 rows). Script 8i caches the
snapshot as `oa_institution_cache.parquet` and a folded name index beside it; delete them or set
`OBMEP_OA_REBUILD=1` to rebuild.

**Two things the ranker had to learn**, both recorded as notes in the script because the first draft
got them wrong and it cost real recall:

- **IDF-weighted token overlap, not string similarity.** Jaro-Winkler over the whole string ranks
  `Universidade Estadual de Goiás` above `Estácio (Brazil)` for the probe `Universidade Estácio de
  Sá`, because the shared prefix is long and the one distinctive token drowns. That lost the correct
  answer outright on Estácio de Sá, UNIASSELVI and UniFatecie. Scoring by the share of the probe's
  *information* a candidate covers fixes it; jw survives only as a tiebreak.
- **Acronyms are indexed for candidates but never for the fold.** 50,511 institutions carry
  `display_name_acronyms`, and `UNIASSELVI` is one of them — it reaches
  `Centro Universitário Leonardo da Vinci` (`I4210097431`), which no name match finds because Revelio
  calls that school "Dante University Centre". But acronyms collide across countries: `UNESA` is an
  Indonesian university, not Estácio, and it still ranks first on that row. So an acronym may
  **propose** a candidate and never silently resolve one.

**Nobody may author an identifier, and phase 2 enforces that against the snapshot.** Every non-empty
`openalex_id` must exist among the 120,658 records or the run stops. Membership in the row's own
`cand1..cand5` is a narrower test and is only *reported* (`from_candidates` in the map), because three
legitimate routes land outside the shortlist: the deterministic fold, a targeted lookup that found a
record the token blocking missed, and a deliberate parent-level mapping.

**Result on the top 1,000 schools:**

| verdict | schools |
|---|---|
| `OK` | 416 |
| `NO_OPENALEX_RECORD` | 88 |
| `REVELIO_NAME_WRONG` | 2 |
| `AMBIGUOUS` | 3 |
| `PENDING` | 491 |

`unmatched_school_openalex_map.parquet` publishes **418 schools, 747,109 rows, 688,364 users** —
36.9% of the named slice — as **448 rows, one per `rsid`**. 410 of those rsids came from the fold
(`safe = 1`), the rest from review; `from_candidates` records which reviewed ids came off the
shortlist.

**The map is keyed on `rsid`, and that is not cosmetic.** Measured: `rsid -> university_name` **is** a
function (27,828 rsids, every one with exactly one name), but the reverse is **not** — 350 names span
2-3 rsids and 11 span 4-10. `American University` alone spans 5. A map keyed on the name with
`mode(rsid)` beside it therefore drops rsids, and on this set that silently lost **24,069 of 747,109
rows across 18 schools**. Exploding to one row per rsid is lossless precisely because the
`rsid -> name` direction is a function, and rsid is the key scripts 27 and 8g actually join on.
`n_rows` and `n_users` stay **per school**, so deduplicate on `university_name` before summing them.

### How a candidate is matched, and where judgement enters

`rsid` takes no part in the matching. The key is `university_name`, and steps 1-3 are entirely
mechanical:

1. **Fold** `lower(strip_accents(trim(name)))` against the same fold of every `display_name` and
   `display_name_alternatives` in the snapshot; accept only when the folded name reaches exactly one
   id. That is a lookup, not a second matcher — the string came out of the target table. **383 of the
   top 1,000 resolve here**, 7,659 across all 27,432 schools.
2. **Probe set** for the residue = `university_name` plus the 4 commonest raw spellings (nota 4).
3. **Block and score**: split both sides on non-alphanumerics, keep tokens of 4+ characters, discard
   any token carried by more than 3,000 institutions, join through an inverted token index, then rank
   by IDF-weighted coverage -- idf summed over shared tokens over idf summed over the probe's tokens,
   maximised across probes, with Jaro-Winkler as tiebreak only. Keep the top 5.

**Judgement enters only at step 4**, choosing among those 5 or answering `NO_OPENALEX_RECORD` /
`AMBIGUOUS`. That touched **38 rsids**; 28 were picked off the shortlist and 10 came from a targeted
lookup over the snapshot when all 5 candidates were wrong (`Universidade UNG` ->
`Guarulhos University` is one). Step 5 is mechanical again: the chosen id must exist among the 120,658
records or the run aborts. So **410 of 448 published rsids involved no judgement at all**, and 48 of
the 88 absences were established by an exhaustive automated token search rather than by opinion.

**`NO_OPENALEX_RECORD` is a verified absence, not a shrug.** 88 of these are small Brazilian private
colleges — UniFatecie, ENIAC, FACENS, UniFECAF, Doctum, UNIPLAN, UNILAGO — whose distinctive tokens
appear in *no* name among the 120,658 records. The note on each row records which tokens were
searched, so the check is auditable and re-runnable. 48 of the 88 were established by an exhaustive
automated version of exactly that search.

**`REVELIO_NAME_WRONG` fired twice and is why the worksheet ships `top_raw_variants`.** UNIASSELVI is
labelled "Dante University Centre"; a national SENAC grouping is labelled "SENAC Faculty of Caçador".
Both resolve correctly *from the spellings users typed*, and both would have been resolved wrongly
from Revelio's label alone. The independent evidence that the label is untrustworthy is in
`rsid_openalex_br.parquet`: rsid 3800 carries `university_raw = "Universidade Federal do Rio de
Janeiro"` against `university_name = "Université d'Aix-Marseille"`.

**The 491 `PENDING` rows are parked deliberately, and the curve says why.** After the 509 decided,
what remains is flat: median **675** rows per school against 7,600 for the first batch reviewed, max
1,908, and the smallest 291 schools together hold only 157,404 rows. The worksheet stays ordered by
`n_rows`, so resuming costs nothing — but the steep part is done.

**Two limits worth stating.** Parent-level mappings are deliberate where a faculty has no record of
its own: FEUP and FEP resolve to `Universidade do Porto`, FCT NOVA to `Universidade Nova de Lisboa`,
ISCAP to `Instituto Politécnico do Porto`. And the verdicts are **LLM-written, not human** — same
conflict of interest 8f, 16a and 13a record for theirs, so this is an internal-consistency pass and
not an independent measurement. `source` marks every row `fold`, `llm` or `human`.

### Auditing it — `unmatched_school_audit_sample.R` (8j)

Script **8j** draws 100 of the 448 published rsids into an openxlsx workbook for a person to check.
It follows the folder's review-workbook pattern (`Como ler` rubric, hidden `dominio` dropdown,
`saveWorkbook(overwrite = FALSE)`, annotation-preserving regeneration, round-trip assertion) from
27a, 10e and 10i.

**The draw is stratified, and reading a single error rate off it would be wrong.**

| stratum | drawn | population | coverage | weight |
|---|---|---|---|---|
| `judgement` (`safe = 0`) | 38 | 38 | 100% | 1.00 |
| `fold` (`safe = 1`) | 62 | 410 | 15% | 6.61 |

A simple random 100 of 448 would have drawn about 8 judgement rows — 8.5% of the sample on the only
stratum where a model exercised discretion, and 92% on exact string equality. So the risky stratum is
taken whole and is deliberately **6.6x over-represented**; the `Resumo` tab ships both populations and
the weight so the result can be pushed back to the map rather than read as one number.

**The workbook is built so the audit can actually be done.** `openalex_id` sits beside
`university_name` as asked, but an id is not auditable as a string, so the OpenAlex record's
`display_name`, `country_code`, `type` and `works_count` sit immediately next to it, and
`top_raw_variants` — the spellings users typed — carries the ground truth. The rubric says outright
to judge against those spellings and **not** against `university_name`, because that label is the
suspect: UNIASSELVI arrives labelled "Dante University Centre". `source`, `from_candidates` and the
LLM note travel along so a reviewer can see whether a row came from the mechanical fold, from the
generated shortlist, or from a targeted lookup. Judgement rows are tinted so they are worked first.

Reproducibility follows the folder rules: `seed <- 20260906L`, `ORDER BY hash(...) LIMIT n` over the
already-filtered stratum (never `USING SAMPLE`), the draw parked as parquet and skipped on re-run, and
the query re-run and `setequal`-asserted against what was parked. Verdict domain is `correto` /
`errado` / `duvidoso`. Nothing in the workbook flows back into the pipeline automatically.

---

## Matching `university_raw` where there is no `rsid`

Scripts **8k** (sampling) and **8l** (the matcher) attack the slice 8h and 8i cannot reach:
**805,913 education entries, 755,996 users, 293,940 distinct `university_raw` strings**, with no
`rsid` and no `university_name`. They fail structurally, not for being junk — three of the four
existing maps key on `rsid`. The frequent strings are ordinary universities: `UNIP` (4,640 entries),
`Uninove - Universidade Nove de Julho` (4,204), `UFRJ - Universidade Federal do Rio de Janeiro`
(3,844).

### The ceiling is 45%, and that is the headline

Hand-labelling the samples against the 120,658-record snapshot:

| | dev (100 entries) | holdout (200 entries) |
|---|---|---|
| a real `openalex_id` exists | 44 | 90 |
| **`NONE` — not in OpenAlex at all** | **51** | **101** |
| `AMBIGUOUS` | 5 | 9 |

**Over half of these entries name an institution that is not in OpenAlex under any name.** FABAVI,
Facid, Faneesp, PROMINAS, Pitagoras, Iteq, FACAM, FASIPE, UNIFIAN — small Brazilian private
faculties, absent. No matching strategy can exceed ~45% recall here, and the top-of-population
universities are a poor guide to the sample because 224,643 of the 293,940 strings occur exactly once.

### Measured result

Dev/holdout split, both drawn once (`seed 20260906`), **disjoint by construction**, holdout scored
**once** on the frozen configuration. Labels were frozen *before* any arm was written.

| | precision | recall of ceiling | entries covered |
|---|---|---|---|
| dev | 96.6% [82.8; 99.4] | 63.6% [48.9; 76.2] | 28.0% |
| **holdout** | **92.7% [82.7; 97.1]** | **56.7% [46.4; 66.4]** | **25.5% [20.0; 32.0]** |

The dev→holdout gap is −3.9pp precision and −6.9pp recall: modest, and it is the honest cost of
having tuned on dev. Projected over the full slice, ~**205,000 entries** resolved
[160,000; 258,000] at ~93% precision.

### The arms, and what each earned

| arm | rule | dev precision | holdout precision |
|---|---|---|---|
| `whole` | `fs(raw)` = folded `display_name` ∪ alternatives, single owner | 100% (8) | 91.3% (23) |
| `segment` | split on `/ ( ) |` and `" - "`, fold parts ≥3 chars, single owner | 92.9% (14) | 100% (21) |
| `core` | type-word-stripped, token-sorted key on both sides | 100% (5) | 80.0% (10) |
| `campus` | strip a trailing ` de <place>` / ` - <place>`, re-fold | 100% (2) | 100% (1) |
| `idf` | IDF token coverage, top-1 above a floor | 40.0% (5) | **19.0% (21)** |

`segment` is the workhorse, as script 16 also found. **The `idf` arm is stored, not accepted** — it
collapsed from 40% to 19% precision on the holdout, exactly the behaviour 16a records for its
acronym arm. Turning it on trades holdout precision 92.7% → 72.4% for recall 56.7% → 61.1%. The
acronym arm is likewise off by default (`OBMEP_NORSID_ACRONYM=1`), on 16a's measured evidence.

### Four things the iteration taught, all of them measured

1. **The IDF denominator must count probe tokens that are absent from the index.** Summing only over
   present tokens gives `Faculdade Promove` coverage 1.0 off its generic words alone — 19 of 26
   proposals wrong. Absent tokens now enter at maximum IDF, plus an absolute shared-IDF floor.
2. **Coverage has to be bidirectional.** `Faculdade Jardins` covers 100% of its own single
   distinctive token and matches `Jardins botaniques du Grand Nancy`, of which it covers 20%.
   Requiring the probe to cover the *candidate* too kills that and keeps `Sumaré` →
   `Faculdade Sumaré`, where both directions are 1.0. The candidate floor is deliberately lower
   (0.50) because OpenAlex names carry words the typed string does not.
3. **`core()` must be a sorted-token key, not a regex substitution.** Written as a multi-line regex
   literal the alternation swallowed newlines and indentation and matched nothing. Sorting tokens is
   also what makes `Centro Universitário Augusto Motta` and `University Center Augusto Motta` meet.
4. **A campus-suffix rule needs an explicit separator.** `( de | - | )[a-z ]{3,20}$` strips any tail:
   `Centro Universitário UNIRB` became `Centro Universitário` and matched a random centre, 4 wrong
   out of 6.

`'|'` as a segment separator was discovered during labelling (`Centro Universitário Vale do Iguaçu |
Uniguaçu`) and is in neither 8a nor 16.

**The labels are LLM-written, not human** — the same conflict of interest recorded for 17, 8i and
16a, so this is an internal-consistency measurement. Both label CSVs are editable and carry an
`evidence` column; 38 of the holdout's `NONE` verdicts were established by an exhaustive automated
token-absence search rather than by opinion.

### Round 2 — four disjoint slices of one hash order

`norsid_raw_match_sample.R` (8k) draws **four** sets as rank slices of a single total order
(`hash(row_key || '#20260906')`), so disjointness is *proved* rather than probable — a fresh seed
would only be probably disjoint. The script asserts that ranks 1-300 still reproduce round 1's parked
sets before touching anything.

| set | ranks | rows | strings | ceiling |
|---|---|---|---|---|
| `dev` | 1-100 | 100 | 98 | 44% |
| `holdout` | 101-300 | 200 | 197 | 45% |
| `dev2` | 301-500 | 200 | 200 | 38% |
| `holdout2` | 501-1000 | 500 | 476 | 42% |

**`holdout` is spent** — its score was reported in round 1, so it can no longer be a clean holdout.
Round 2 uses `dev` + `holdout` (300 rows) as a **regression set**: measured every iteration, never
optimised against. That distinction is what lets a regression set veto a change without laundering
the number.

**Across all 1,000 labelled entries only 42.2% (422) name an institution that exists in OpenAlex.**
Four independent samples agree on the ceiling, which is the most robust finding of both rounds.

### What round 2 changed, and why

Every change is a mechanical exact-match mechanism. No fuzzy arm was added.

1. **`core` now requires two distinctive tokens.** This was the most important fix. Without it the
   arm falls into the same single-token homonymy that killed the `idf` arm in round 1 — all four
   dev2 errors came from one-word keys: `Asser`, `Gamaliel`, `Unilasalle-RJ`, `LS educacional`. One
   word left after stripping generic type words is not evidence.
2. **En dash is not a hyphen.** `Centro Universitário Geraldo di Biase – UGB` uses U+2013 and never
   split. U+2013 and U+2014 are normalised to hyphen before splitting, via `chr(8211)`/`chr(8212)`
   so the file stays pure ASCII. Hyphen *without* spaces still does not split: `Unilasalle-RJ` would
   yield `unilasalle`, matching the French UniLaSalle, and `Semi-Árido` would lose its name.
3. **New `mojibake` arm.** 8,614 rows and 1,892 strings carry literal `u00e4`-style escapes. Because
   the fold already applies `strip_accents`, decoding `u00e1` to plain `a` gives the same answer as a
   Unicode table with a chain of `replace()` calls. Scored 3/3 on holdout2, 2/2 on regression.
4. **New `parent` arm.** 14,067 rows contain a parent-university phrase. This mechanises the
   faculty→parent choice the round-1 labels had already made (FEUP → Universidade do Porto).
5. **`prefix` arm built and left OFF.** Dropping leading words scored 2/2 on dev2 but 0/1 on
   regression: `ITEPA BIBLE COLLEGE` reduces to `bible college` and matches a Bible college. 2 of 3
   across 500 rows is nowhere near the bar the other arms set, and calibrating a floor against the
   regression set would be using the set that exists to veto. It is stored, off by default
   (`OBMEP_NORSID_PREFIX=1`).

### Measured result

| set | configuration | precision | recall of ceiling |
|---|---|---|---|
| regression (300) | round 1 | 94.0% [86.8; 97.4] | 59.0% |
| regression (300) | **round 2** | **95.2% [88.4; 98.1]** | **59.7%** |
| dev2 (200) | round 2 | 100.0% [92.9; 100] | 65.8% |
| **holdout2 (500)** | round 2 | **89.7% [83.7; 93.7]** | **61.8% [55.1; 68.1]** |
| holdout (200), round 1 | round 1 | 92.7% [82.7; 97.1] | 56.7% |

The like-for-like comparison is the regression set, where the same 300 rows under the two
configurations give **+1.2pp precision and +0.7pp recall**. holdout2 is the unbiased estimate of the
round-2 configuration on fresh data.

**The overfit gap is larger this round: dev2 100.0% → holdout2 89.7%, −10.3pp.** The dev2 100% was
an artefact of only 50 proposals — one error would have shown 98%. This is exactly why the holdout is
drawn and scored once, and it is the number to quote. Restricting holdout2 to the 479 rows whose
spelling never appeared in round 1 gives 90.1% precision and 59.6% recall, so the 15 carried-over
labels did not flatter the result.

The wider holdout paid for itself: the precision interval narrowed from roughly ±14pp (round 1, 55
proposals) to **±5pp** (round 2, 146 proposals).

Projected over the 805,913 no-`rsid` entries: **~211,000 entries resolved [181,000; 243,000]** at
~90% precision.

### A defect found in holdout2 and deliberately NOT fixed

The `parent` arm mapped `Pontifical Catholic University of Campinas` to **Universidade Estadual de
Campinas**: extracting `university of campinas` silently drops the `Catholic` qualifier, and the two
are different institutions. It is a real semantic flaw, not a tuning miss — the rule needs a guard
that the extracted parent is not preceded by a qualifying adjective.

It is recorded rather than fixed because the configuration was frozen before holdout2 was labelled.
Fixing it now and re-scoring would spend the holdout and make the 89.7% unquotable. It is the first
item for round 3. The arm's overall record is 5/6 across all three sets.

### Where the 15 holdout2 errors fall

| kind | n | examples |
|---|---|---|
| matched an institution that does not exist | 7 | `Fcv` → Fundación Cardiovascular de Colombia; `FPB` → Federal Planning Bureau; `IBES` → International Bureau for Environmental Studies; `Unimeta` → Corporación Universitaria del Meta |
| matched something labelled `AMBIGUOUS` | 4 | `Famesp`, `Ugv`, `Military Engineering Institute` |
| wrong institution | 4 | the `parent` flaw above; `Universidade Estadual de Santa Catarina` → UFSC instead of UDESC |

Every one of the seven false positives is a **short acronym** reaching a foreign homonym — the same
failure mode 16a measured at ~50% for its acronym arm, arriving here through the `whole` and
`segment` arms instead. A minimum-length or country-corroboration guard on acronym-shaped whole
strings is the second item for round 3.

---

## The unified Revelio → OpenAlex crosswalk — script 8m

Six matching strategies existed, each built as the residue of the last, and none was composed into a
consumable product: 8h composes four of them but only to *find what is missing*, and 8l had never run
over the full population at all. `revelio_oa_crosswalk.R` (**8m**) composes all six and reports the
coverage.

**The manually judged rsids are excluded.** 8i's map enters filtered to `source = 'fold'` — 410
mechanical fold rsids in, its 38 judgement rsids out, asserted.

### Two tables, because one key cannot carry six strategies

Three of the six strategies key on `rsid`, and a `university_raw` string routinely spans several
rsids. Measured over all education rows:

| a `university_raw` resolves to | strings | rows |
|---|---|---|
| 3+ distinct OA ids | 322 | 5,186,226 |
| 2 distinct OA ids | 740 | 1,829,184 |
| exactly 1 | 102,944 | 3,768,483 |
| nothing | 1,313,845 | 4,921,686 |

Generic strings cross many rsids and the rsid is what disambiguates them, so:

- **`revelio_oa_crosswalk.parquet`** — key `(university_raw, rsid)`, 1,478,502 rows. Faithful,
  nothing collapsed. **Every statistic comes from this one.**
- **`revelio_oa_crosswalk_by_raw.parquet`** — key `university_raw`, 1,417,851 rows, carrying
  `dom_openalex_id`, `n_ids`, `dom_share` and `is_ambiguous`. **3,275 strings are ambiguous** under
  the full six-strategy composition. The precedent for the extra columns is 8d's note 9: never
  consume `dom_openalex_id` without reading `dom_share` — the case on record is IFSP, 35 ids,
  `dom_share` 0.24, dominant rule picks *Petrobras*.

`rsid` is nullable, so both tables carry `rsid_key = coalesce(rsid, 2147483647)`, the sentinel 8h
already uses.

### What each strategy resolves, and which wins

One column and one `by_*` flag per strategy, so the composition stays reversible. Precedence follows
the historical build order, because each strategy was designed as the residue of the one before.

| strategy | pairs it can resolve | rows | rows where it *wins* |
|---|---|---|---|
| `safe_map` (8f) | 81,868 | 7,986,635 | **7,986,635** |
| `norsid_8l` | 159,449 | 8,143,770 | 1,544,445 |
| `shanghai_raw` (16b) | 4,070 | 1,352,674 | 680,584 |
| `school_fold_8i` | — | — | 502,682 |
| `shanghai_name` | 17,190 | 1,366,448 | 96,246 |
| `crosswalk_8d` | 9,840 | 4,622,327 | 9,936 |
| *(unmatched)* | — | — | 4,885,051 |

`norsid_8l` can reach more pairs than any other strategy but wins far fewer, because `safe_map` has
precedence wherever both fire. `crosswalk_8d` covers 4.6M rows but wins almost none, for the same
reason.

### Coverage

| block | entries | with an OA id | share | users | users with an id | share |
|---|---|---|---|---|---|---|
| **A. all entries** | 15,705,579 | **10,820,528** | **68.9%** | 6,848,058 | 6,083,077 | 88.8% |
| **B. degree entries only** | 9,104,928 | **7,446,073** | **81.8%** | 6,829,255 | 5,779,103 | 84.6% |
| C. bachelor | 7,659,939 | 6,257,872 | 81.7% | 6,820,369 | 5,662,580 | 83.0% |
| C. master | 1,333,676 | 1,088,683 | 81.6% | 1,160,160 | 974,320 | 84.0% |
| C. phd | 111,313 | 99,518 | **89.4%** | 105,186 | 94,906 | 90.2% |

Block B is `sql_shanghai_level IN ('bachelor','master','phd')` and block C is that same set split
three ways, so B's total is the sum of C by construction — asserted.

**Block B removes more than high school.** There is no "is high school" primitive in this folder:
`rx_hs` exists only as a *negative* inside `sql_is_bachelor`, and Revelio's `degree = 'High School'`
is useless as a positive signal — in a 1,000-row Brazilian sample, **all 93 rows so labelled were
bachelor's degrees** and not one was `ensino médio`. So the level cascade is the only usable filter,
and it also drops postdocs, exchanges, extension courses, tecnólogo/CST and unclassifiable rows.

The share rises from 68.9% to 81.8% once non-degree rows are out, and the doctorate level is the
best-covered at 89.4% — unsurprising, since PhDs concentrate in research universities, which is
exactly what OpenAlex indexes.

### Three things the build turned up

1. **A malformed id in 16b, traced upstream.** `shanghai_ranking_oa.parquet` rank 701 carries the
   *name* `RUTGERS UNIVERSITY - NEWARK` in its `OA_key` column instead of an `I`-number, and 16b
   propagated it faithfully into 248 education rows. 8m now shape-tests every incoming id against
   `^I[0-9]+$` and rejects what fails, counted and reported. **The defect is upstream and still
   there** — this only stops it entering the crosswalk.
2. **A string-keyed product cannot cover blank `university_raw`.** 7,158 education rows have no
   spelling at all, and 8h matched 2,354 of them through the rsid maps. Rather than paper over it,
   the regression against 8h **reconciles**: 8m's counts plus the blank-spelling rows plus the
   226 shape-rejected rows equal 8h's published figures exactly.
3. **Cross-strategy conflict is kept, not resolved.** 8,240 pairs have two strategies proposing
   *different* ids. Precedence decides what lands in `openalex_id`; `n_ids_distinct` and `conflict`
   record the disagreement, because it is a precision signal.

### Two caveats on the numbers

- **`norsid_8l`'s measured precision does not apply to the whole table.** Its 89.7% was measured on
  entries with no `rsid` and no `university_name`. `in_norsid_domain` separates that domain from the
  extrapolation; outside it the precision is unmeasured. It wins 1,544,445 rows, so this is the
  largest unquantified block in the product.
- **Strategy 3 still carries human judgement.** 16b's acronym arm is gated on 16a's hand review
  (`acr_label = 'OK'`), LLM-written like 8i's. It was kept because it is the documented recommended
  filter and predates this work, but `by_shraw_acronym` ships as its own flag so it can be dropped
  with a `WHERE`.

The 8l arms are **copied verbatim** into 8m, the arrangement 8a declares for the same situation. The
copy is pinned numerically: 8m re-scores 8l's frozen `dev2` and `holdout2` label sets through its own
copy and `stop()`s unless it reproduces 50/50 and 131/146.

---

## CAPES masters and doctorates born in 1988 or later

Script **24** is a local, offline derivative of the unified CAPES student panel. It writes a UTF-8
CSV with one row per person, CAPES program, institution and degree type. Its columns are
`person_id`, `full_name`, `birth_year`, `course_code`, `course_name`, `institution`, `course_area`,
`course_type`, and `course_start_year`. Reingressions in the same group retain the earliest start
year. Academic and professional degrees are included; the legacy `GRADUAÇÃO` level is excluded.

`ID_PESSOA` exists only from 2013 onward. For the 2004-2012 records, `person_id` is deliberately
empty: `NR_SEQUENCIAL_DISCENTE` has a different scope and must not be presented as the same person
identifier. Legacy people are therefore grouped by exact trimmed full name plus birth year. The
production constants are **733,879 rows**: 706,904 with `person_id` and 26,975 legacy rows without
it. The output contains full names and birth years and must be handled as personal data.

```powershell
Rscript prep/building_external_data/capes_masters_doctorates_born_1988plus.R
```

## The CAPES → OpenAlex institution candidate crosswalk

Script **25** is local and offline. It deduplicates the 733,879-row CAPES extract to its 915 exact
institution strings, compares them with all 1,947 Brazilian records from
`openalex_institutions_br.parquet`, and writes:

```
capes_openalex_br_crosswalk.parquet          every candidate pair at Jaro-Winkler >= 0.95
capes_openalex_br_crosswalk_unmatched.csv    best sub-threshold candidate(s) for each unmatched name
```

Both sides receive the same conservative cleaning before scoring: trim, lowercase, fold accents,
replace punctuation with spaces, then collapse whitespace. Text inside parentheses is retained.
Only OpenAlex `display_name` is scored — not `cleaned_display_name`, acronyms or aliases — and all
OpenAlex types are eligible. That last choice is deliberate: CAPES contains valid postgraduate
providers that OpenAlex labels `facility` or `government`, including Fiocruz and INPE.

**This is a candidate table, not a resolved identity map.** Every pair at or above the inclusive
0.95 cutoff is retained. On the current inputs that gives **1,399 pairs** over **438 CAPES names**;
258 names have one candidate and 180 have more than one (up to 16). The remaining **477 names** go
to the audit CSV; three have two candidates tied at their best sub-threshold score, so that file has
480 rows. The matched names account for **609,252 of 733,879** rows in the person-program extract.

Do not sum `capes_row_count` down the crosswalk or join it directly to the person-level CSV without
handling `n_candidates`: either operation fans a CAPES institution out once per candidate. Jaro-
Winkler also rewards the long shared prefixes in Brazilian institution names, so a score over 0.95
is not by itself proof of identity; `score_rank`, `n_candidates`, type, city and works count are
carried for review, not used as hidden tie-breakers.

```powershell
Rscript prep/building_external_data/capes_openalex_br_crosswalk.R
```

## Manually resolving the unmatched CAPES institutions

Script **26** turns the 477 distinct CAPES names left unmatched by script 25 into 48 auditable
research batches: 47 batches of ten and a last batch of seven. It rotates them across agents A, B
and C (160, 160 and 157 names) and never overwrites an existing result file.

```powershell
Rscript prep/building_external_data/capes_openalex_manual_crosswalk.R prepare
Rscript prep/building_external_data/capes_openalex_manual_crosswalk.R status
Rscript prep/building_external_data/capes_openalex_manual_crosswalk.R consolidate
```

The research is **online and manual** even though preparation and consolidation only read local
files. Each exact CAPES string is searched separately. A verified ID needs the OpenAlex entity plus
an official institution or ROR source; exact unit records win, with the degree-awarding parent used
only as an evidenced fallback. Agents may return `ambiguous` or `not_found` rather than forcing an
ID. A web-verified ID absent from the February 2026 Brazilian snapshot is preserved and flagged.

`consolidate` requires all 48 result files and joins strictly on `openalex_id`, never by name. It
writes the 477-row research record, a left-preserving enriched parquet, and an exceptions CSV under
`capes_discentes/capes_openalex_manual/`. The manual product complements the fuzzy candidate table;
it does not resolve script 25's 438 already-matched CAPES names.

Measured on 2026-09-04: **406 verified** and **71 not found**, covering all 477 names. The verified
relationships are 159 same-entity, 219 parent fallbacks and 28 renamed successors, collapsing to
173 distinct OpenAlex IDs because CAPES carries many spelling and campus variants. **405** verified
rows join to the local Brazilian snapshot, all with exact agreement between the researched and
snapshot `display_name`. The sole snapshot exception is Faculdade FIPECAFI (`I4405273733`), a live
OpenAlex/ROR record newer than the local snapshot. Two independent review passes checked exact-name
matches and all parent/successor or snapshot-exception cases; they corrected one false match where
Faculdade Sete Lagoas (FACSETE) had initially been conflated with the separately maintained UNIFEMM.

## Matching CAPES people to the selected candidates

Script **27**, `capes_obmep_candidates_name_match.R`, is local and offline. It is the first stage
that joins the CAPES side of 22–26 to the candidate side of 7–21, and it is a **pilot**: the yield
is the finding, so the script prints the attrition ladder next to the match table.

```
capes_masters_doctorates_born_1988plus_2004_2024.csv   (24)  733,879 rows ─┐
capes_openalex_br_crosswalk.parquet                    (25)               ─┤
capes_openalex_manual_br_crosswalk.parquet             (26)               ─┼─27─> capes_obmep_match/
obmep_candidates_step_1_education/                     (10a)              ─┤
obmep_candidates_selected.parquet                      (21)  1,297,109    ─┤
rsid_openalex_safe_map.parquet                         (8f)  667 rsids    ─┘
```

### The key is a blocking key, and the hash only shards the work

Each side is reduced to one row per person, then to a **seven-slot key** joined by `-`:

```
first_name - msc_start_year - msc_end_year - phd_start_year - phd_end_year - msc_oa_id - phd_oa_id
bucket = hash(key_string) % 128
```

A pair is compared **only when the two keys are byte-identical**. The bucket is therefore not a
blocking device — it is the unit of work, the same idiom as the 64 author hash buckets in 5a — and
the only thing left approximate is the name. The 128 buckets come out almost perfectly even
(20,266 / 21,467 / 22,916 / 23,295 variants at min / median / p99 / max), so no bucket dominates
the loop.

**`concat_ws` discards NULLs in DuckDB.** Every slot is `coalesce`d to the literal `'NA'` before it
reaches `concat_ws`; without that, one missing field shifts every later field one position left and
the key silently means something else. An assertion counts the `-`-delimited slots on both sides and
aborts if any row is not exactly 7. **Do not remove it.**

### Slots 3 and 5 are `'NA'` on both sides, and that is not an oversight

**The CSV from script 24 has no completion year.** Its nine columns stop at `course_start_year`.
The end-year slots exist so the key shape is stable, and the constant `key_end_years` — `FALSE` —
fills both with `'NA'` on both sides. Turning it on `stop()`s the script with the reason, because a
CAPES end year has to be derived first (`AN_SITUACAO_DISCENTE` where
`NM_SITUACAO_DISCENTE = 'TITULADO'`, in `capes_discentes_2004_2024.parquet`). The Revelio end years
are still computed and carried as **columns**, so widening the key later costs no rebuild of them.

### CAPES names are full, LinkedIn names are any subset of them

CAPES records a full civil name; LinkedIn carries some short form of it. So each CAPES person enters
with **every order-preserving combination of their surname tokens**, generated by bit mask:

```
JOAO FRANCISCO GOMES MARQUES        tokens after the first: francisco, gomes, marques

 mask  variant                        csur (what is actually compared)
    1  joao francisco                 francisco
    2  joao gomes                     gomes
    3  joao francisco gomes           francisco gomes
    4  joao marques                   marques
    5  joao francisco marques         francisco marques
    6  joao gomes marques             gomes marques
    7  joao francisco gomes marques   francisco gomes marques
```

The mask selects surname tokens left to right, so order comes for free — `joao gomes marques` is
generated, `joao marques gomes` is not. Particles are already gone (`JOAO DE SOUZA` → `joao souza`),
because they are dropped at tokenisation by script 1's list.

**2,755,694 variants over 567,270 people, 4.86 each, at most 127.** The power set is
2^(n-1)-1 per person, so a long name would explode the job silently; the real maximum is **8 tokens**
(10 people), and the script aborts above 12 as a guard. Note the count runs over **all** spellings of
a person's name, not just the canonical one — the 2,228 multi-spelling people add 15,415 variants,
and an alternative spelling is exactly what LinkedIn might have copied.

Variants are a **scoring** device, not a blocking one: every one starts with the same first token, so
they all land in their person's own bucket and the key is untouched. A fixture asserts the seven
combinations in mask order before the real data is read.

### The comparison drops the first name from both sides

This is the single most important thing in this section. **The block already forced the first name
to be identical**, so scoring it again measures a constant — and Winkler's prefix bonus rewards
exactly that constant, putting every pair near 0.85 before any evidence. So `csur` (the CAPES
combination without its first name) is compared against the LinkedIn name without *its* first token.

Measured over the 719,911 compared pairs: **84,722 pairs cleared 0.90 on the full-name comparison and
failed any surname comparison.** A 30-case random sample was 30 of 30 different people —
`MELISSA PEREIRA DOS SANTOS` / `Melissa Lima` at 0.900, `LEONARDO LEON LEITE MOREIRA` /
`Leonardo Capellaro` at 0.901.

Comparing only the **last** surname token also fixes that, and was rejected: of the 4,126 pairs it
uniquely admits, 27.7% match on `silva`, 10% `oliveira`, 8.7% `santos`, 4.7% `souza` and 2.6% on
`junior`, which is not a surname at all.

**29,615 users (2.3%) have a single usable token** and no surname, so `jw_combo` cannot score them.
They are not deleted — they stay eligible under `jw_name`, and the write gate is the union.

### Three scores, and the write gate is their union

| column | meaning |
|---|---|
| `jw_combo` | **the primary score** — best combination against the LinkedIn surnames |
| `jw_lastname` | best single CAPES surname against the LinkedIn **last** token |
| `jw_name` | the old full-name rule, kept so the change stays measurable |

All three come out of **one pass** over the same join: `n_parts = 1` selects the single-surname
combinations that feed `jw_lastname`, and `n_parts = 1 OR n_parts = n_sur` rebuilds exactly the
variant set the old rule used.

A pair is written when `jw_combo >= 0.90 OR jw_name >= 0.90` — **172,679 rows**. Keeping only what
`jw_combo` accepts would make the old rule unmeasurable from the file, and vice versa. Same reasoning
as `sh_master` / `sh_master_strict`: tightening later is a `WHERE`, never a re-run.

### Measured result

| rule at 0.90 | pairs | CAPES people |
|---|---|---|
| `jw_name` — full name, the old rule | 171,990 | 109,922 |
| **`jw_combo` — combinations, no first name** | **92,432** | **82,946** |
| `jw_combo` **and** `jw_lastname` | 87,110 | 79,764 |

`jw_combo` matches **82,946 of 567,270 CAPES people (14.6%)** and **87,056 of 1,295,794 users
(6.7%)**. Runtime is **19 s** total, 4.1 s of it the 128-bucket loop.

The score is now sharply bimodal, which is what a discriminating measure should look like:

| band | pairs | CAPES people |
|---|---|---|
| exactly 1.00 | **86,195** | 79,168 |
| 0.98–1.00 | 80 | 79 |
| 0.95–0.98 | 716 | 679 |
| 0.93–0.95 | 1,026 | 944 |
| 0.90–0.93 | 4,415 | 3,447 |

93.3% of accepted pairs are an **exact** surname-combination match. Under the old full-name rule the
same band structure had 78,707 exact and **75,585** in the noisy 0.90–0.93 tail; that tail is now
4,415. Fan-out collapses with it:

| direction | old rule | `jw_combo` |
|---|---|---|
| users per CAPES person | max 299, mean 1.565 | **max 30, mean 1.114** |
| CAPES people per user | max 67, mean 1.565 | **max 20, mean 1.062** |

### Compound given names are the known limit, and `jw_lastname` is where they show

The block keys on the **first token only**. In `Ana Carolina`, `Pedro Henrique`, `João Pedro`,
`Ana Clara` the *second* token is still a given name sitting in the surname position, and it agrees
for reasons that have nothing to do with identity. Splitting the accepted pairs by whether the final
surname also agrees:

| | pairs | CAPES people | users | mean `jw_combo` |
|---|---|---|---|---|
| final surname agrees | **87,110** | 79,764 | 84,299 | 0.9993 |
| only middle names agree | **5,322** | 4,255 | 3,765 | 0.9199 |

The second bucket is a **judgement call, not a bug**, and a 15-case sample ran roughly one-third
true. The true side is where the genuinely hard recoveries live:

```
BALTAZAR RUAS DE OLIVEIRA JUNIOR  / Baltazar Ruas Jr.                     0.927
ANA CAROLINA SILVA MENDONCA       / Ana Carolina Silva Mendonça Detomini  0.944   married name
MICHELLI VIANA AGLIARDI           / Michelli Viana Agliardi Hepper        0.933   married name
BARBARA FORMIGA GONCALVES DE QUEIROZ / Bárbara FG de Queiroz              0.900   initials
```

and the false side is the compound-name failure:

```
ANA CAROLINA GUSMAO MARCAL        / Ana Carolina Martins                  0.910
JOAO VITOR COSTA DE OLIVEIRA      / João Vítor Mota                       0.944
ANA BEATRIZ DE ALMEIDA LIMA       / Ana Beatriz Fasolai                   0.912
```

So `jw_combo >= 0.90 AND jw_lastname >= 0.90` is the **conservative** product at 87,110 pairs, and
the full 92,432 is the inclusive one. **Do not filter that bucket away silently** — decide which of
the two you want and say so. Widening the block key to the first *two* tokens would attack the cause
rather than the symptom, at the cost of splitting every one-token LinkedIn name away from its match.

### The second variant: what the institution ids are worth

`OBMEP_MATCH_KEY_OA=0` blanks slots 6 and 7 — the two OpenAlex institution ids — leaving the key as
`first_name + msc_start_year + phd_start_year`. It is a **toggle on script 27, not a fork**: the
scoring half is intricate enough that two copies would drift, and the README already records what
that costs when scripts that must agree are maintained separately. The variant writes to
`capes_obmep_match_noinst/` and a guard captures the canonical product's size and mtime at the start
and re-checks them at the end, the way 21alt does.

Dropping the ids is the widening this section previously named as the cheapest next lever. Measured,
it is not one.

| | with the ids | without |
|---|---|---|
| shared keys | 70,867 | 43,179 |
| CAPES people reachable | 166,086 | **451,331** |
| pairs compared | 719,911 | **51,645,722** (72×) |
| largest single block | 13,555 | **1,939,200** (`maria-2023-NA`) |
| conservative pairs | 87,110 | **282,769** |
| **conservative CAPES people** | **79,764** (14.1%) | **164,747** (29.0%) |
| conservative users | 84,299 | 117,644 |
| fan-out, CAPES people per user | max 20, mean 1.062 | **max 309, mean 2.404** |
| loop runtime | 4.1 s | 131 s |

Recall doubles. Then the placebo says what the doubling is made of:

| | real | placebo B | share |
|---|---|---|---|
| **with the ids** | 79,764 | 3,314 | **4.15%** |
| without, cut 0.90 | 164,747 | 94,949 | **57.6%** |
| without, cut 0.95 | 155,340 | 83,879 | 54.0% |
| without, cut 1.00 (exact surname) | 152,519 | 80,683 | **52.9%** |

**Tightening the name test does not rescue it.** Even demanding an exact surname match, more than
half the pairs come back when each CAPES person is handed a random other Brazilian's surname. The
year arm agrees: shifting the years leaves 16–50% of the matches standing without the ids, against
0.9–2.6% with them.

#### The number that actually compares them: excess over placebo

Subtracting arm B from each product leaves the part coincidence does **not** explain. Script 27b
writes it as `excedente_pares` / `excedente_pessoas` / `excedente_users`:

| | canonical | `_noinst` |
|---|---|---|
| conservative CAPES people, raw | 79,764 (14.1%) | **164,747 (29.0%)** |
| − placebo B | 3,314 | 94,949 |
| **= excess CAPES people** | **76,450 (13.5%)** | **69,798 (12.3%)** |
| excess users | 81,172 | 76,880 |
| excess pairs | 83,311 | 93,047 |

**The wide variant does not find fewer matches — it cannot.** Relaxing the key can only add candidate
pairs, and the name scores do not depend on the key, so every canonical pair survives with an
identical score. Asserted in 27b rather than deduced: **0 of the 87,110 canonical pairs are missing
from `_noinst`**, which adds 195,659 pairs and 84,983 people on top of them.

What falls is the **excess**, and it is not a count of matches. It estimates how many matches are
attributable to genuine name agreement rather than chance, and both of its terms grow when the key is
loosened — the placebo just grows faster (+91,635 against +84,983). Keeping the three quantities
apart is the whole point:

| | what it is | canonical | `_noinst` |
|---|---|---|---|
| conservative pairs | a **set** | 87,110 | 282,769 (superset) |
| CAPES people matched | a **set** | 79,764 | 164,747 (superset) |
| excess over placebo | an **estimate** of non-coincidental volume | 76,450 | 69,798 |

The first two can only grow. The third can fall, and does. So the 84,983 people the widening adds are
genuinely found — the evidence for them is simply worth nothing.

**Why it falls: block saturation.** `maria-2023-NA` holds 1,010 CAPES people against 1,920 users.
Among 1,920 Brazilian surname strings almost *any* surname finds a close match, so the true surname's
advantage over a randomly donated one collapses toward zero as blocks grow. Only the *pair* count
favours the wide variant, and that is inflated by exactly the fan-out this creates — 2.404 CAPES
people per user against 1.062.

**And the gap is not estimator noise.** Arm B runs at five permutation offsets:

| | placebo, offsets 1–5 | amplitude | excess range |
|---|---|---|---|
| canonical | 3,314 · 3,017 · 3,301 · 2,968 · 3,324 | 356 | 76,440 – 76,796 |
| `_noinst` | 94,949 · 94,927 · 94,959 · 94,930 · 94,788 | 171 | 69,788 – 69,959 |

The 6,650 gap is about twenty times the estimator's own spread. Offset 1 is the headline everywhere
else in this folder; the other four exist only to bound its precision.

**Practical consequence.** Inside the wide product, the canonical subset *is* the high-evidence
stratum — it is exactly the part where the institution ids also agreed. Anyone drawn to the extra
recall should simply use the canonical product, which is that stratum with the agreement still
enforced.

The excess is a **first-order estimator, not an identity**. It assumes the false-positive process has
the same magnitude in the real run as in the permuted one; arm B holds the blocks and the surname
distribution fixed, which makes that roughly true, but a genuine match can occupy a slot a false one
would otherwise have taken, so the two do not sum exactly. It also cannot validate the survivors — a
systematic error such as a mis-resolved institution is invisible to a name permutation. That is what
the 27a workbook is for.

Everything the widening adds is accounted for by coincidence. **The institution ids are what make
this linkage identifiable.** Without them the key is *first name + degree year*, which among 567,270
Brazilians is nowhere near unique — `maria-2023-NA` alone holds 1,010 CAPES people against 1,920
users.

So `capes_obmep_match_noinst/` is a **measurement, not a match table**. The script prints a banner
saying so on every run and note 9 of its header repeats it. Do not consume it. What it is good for is
exactly the question it answers: how much of script 27's result rests on the institution match.

```powershell
$env:OBMEP_MATCH_KEY_OA = "0"
Rscript prep/building_external_data/capes_obmep_candidates_name_match.R   # ~2.5 min
Rscript prep/building_external_data/capes_obmep_match_placebo.R
```

**One caveat on re-running the canonical variant.** Its outputs are *not* byte-reproducible, and that
predates this change: two consecutive runs of identical code give different parquet checksums,
because `arg_max(variant, jw_combo)` breaks its 125 ties non-deterministically under parallel
aggregation. Row counts and every reported statistic reproduce exactly. **Verify a re-run on content,
never on a checksum.**

### How much of the match rate is coincidence — script 27b

The rate is **14.1%** of CAPES people (79,764 of 567,270), not 10%. Dividing by 733,879 gives 10.9%,
but that is the *row* count of the CAPES extract — one row per person × programme × institution ×
degree type. The 733,879 rows collapse to 567,270 people, and the person count is the denominator
that means anything here.

Three ratios, all describing the same result:

| | | |
|---|---|---|
| matched / all CAPES people | 79,764 / 567,270 | **14.1%** |
| matched / CAPES people the key can reach at all | 79,764 / 166,086 | **48.0%** |
| matched users / users with a resolvable Brazilian graduate degree | 84,299 / 149,887 | **56.2%** |

The third is the plausibility check from the other side. CAPES accredits *every* stricto sensu
programme in Brazil, so a selected candidate born 1988 or later with a real Brazilian master's
**should** be in there — which makes 56% coverage a believable figure rather than a suspicious one.

The rate also is not flat. It is zero exactly where it must be and peaks where LinkedIn coverage
peaks:

| master's start year | matched | | birth year | matched |
|---|---|---|---|---|
| 2000–2009 | **0.0%** | | 1988 | 7.6% |
| 2010 | 0.8% | | 1990 | 14.5% |
| 2012 | 10.3% | | 1992–1994 | ~17% |
| 2016–2019 | **~17%** | | 1998 | 13.7% |
| 2024 | 9.4% | | 2002 | 8.1% |

CAPES here is born-1988+, so a master's starting before ~2010 means age under 22 — those rows are
noise, and **none of them matched**. A false-positive process driven by name collisions would be
roughly flat in the year and would scale with cohort size; this does neither.

#### The placebo

`capes_obmep_match_placebo.R` measures the false-positive contribution directly, by destroying the
true linkage and counting survivors. It is read-only with respect to the pipeline, reads only the
three products script 27 already wrote, and runs in **4 seconds**.

**Arm A — shift the CAPES years by K.** A true pair cannot survive: its year is now wrong. Anything
matching is coincidence at the same first name, the same shifted years, the same institution ids and
a surname combination over 0.90.

**Arm B — permute the surnames within each first name**, holding `key_string` byte-identical. The
block still agrees on everything it agreed on before; only the surnames now belong to somebody else.
This is the sharp one: *given all the key already knows, does the surname carry information?*

| arm | CAPES people matched | share of the real 79,764 |
|---|---|---|
| **real** (K = 0) | **79,764** | 100% |
| A, K = −7 | 959 | 1.20% |
| A, K = −5 | 1,542 | 1.93% |
| A, K = −3 | 2,082 | 2.61% |
| A, K = +3 | 1,766 | 2.21% |
| A, K = +5 | 1,220 | 1.53% |
| A, K = +7 | 752 | 0.94% |
| **B, surnames permuted** | **3,314** | **4.15%** |

So a random other Brazilian's surname, dropped into an otherwise perfectly matching block, matches
about **one twenty-fourth** as often as the real one. **Roughly 96% of the 14.1% is not explainable
as coincidence within the block.**

Four things limit that conclusion, and the script says all four in its header:

1. **The K = 0 sanity arm is load-bearing.** It must reproduce 87,110 pairs / 79,764 people / 84,299
   users exactly, and it `stop()`s if it does not — a placebo whose key construction has drifted
   from script 27 measures nothing. It is the most important check in the file.
2. **Shifting a year also changes block sizes.** The CAPES start-year distribution is nowhere near
   uniform (57,328 in 2024 against 1 in 2000), so each K is reported on its own line and the mean is
   indicative, not an estimator.
3. **Arm A isolates the year, arm B isolates the name. Neither isolates the institution**, and no
   arm here can.
4. **A low placebo bounds false positives; it does not prove the survivors are right.** Only the
   100-row workbook from 27a can say that, and it is still unfilled. The two are complements.

```powershell
Rscript prep/building_external_data/capes_obmep_match_placebo.R
```

The permutation is a hash-rank rotation, not `set.seed`, so the run is reproducible; 543,341 of
567,270 people are permutable and the 23,929 with a unique first name sit out.

### A parked 100-pair sample for manual review — script 27a

Nothing in this section is validated against ground truth. The precision statements above rest on
about 50 pairs judged by eye across two disagreement sets — enough to rank the scoring rules against
each other, not enough to certify the winner. `capes_obmep_match_sample.R` draws the missing
evidence: **100 pairs from the conservative product**, enriched with the institution and the course
from **both** sources, as a workbook to be filled in by hand.

```
capes_obmep_match_sample.parquet   100 rows, parked, never redrawn
capes_obmep_match_sample.xlsx      Como ler | Amostra | Resumo (+ a hidden dropdown sheet)
```

Seed **20260906**, drawn with `ORDER BY hash(person_key || '#' || user_id || '#<seed>') LIMIT 100` —
never `USING SAMPLE`, which DuckDB pushes below the filter. The draw gives 100 distinct people and
100 distinct users, and its composition tracks the population closely:

| | sample | population |
|---|---|---|
| master's only | 66 | 71.4% |
| master's + doctorate | 33 | 27.4% |
| doctorate only | 1 | 1.1% |
| `jw_combo` exactly 1.00 | 100 | 98.9% |

**What the reviewer must not waste time on.** The key forced first name, both start years and both
`openalex_id`s to be *equal by construction*, so checking that the years or the institutions agree
measures nothing. What is in play is the rest of the name and whether the **course** is plausible —
and the key never looked at a course, so `AGRONOMIA` against a materials-engineering master's is
genuine evidence. `university_raw`, what the person actually typed on LinkedIn, is more diagnostic
than Revelio's normalised `university_name`.

The degree rows are rebuilt with **script 27's own `row_number()` tie-breaks**, so the workbook shows
the exact diploma that produced the key rather than merely one of the person's diplomas. The script
`stop()`s — does not warn — if the two sides disagree on how many degrees they found (99 master's and
34 doctorate here), because that would mean the reconstruction had drifted and the workbook was
showing the wrong row.

Two rules travel with it. **The sample is parked**: a re-run skips the draw, because the reviewer's
verdicts are tied to this exact draw and must not slide underneath them. **The workbook is
regenerable without losing work**: `veredito`/`motivo` are read back, matched on `pair_id`, and the
script aborts if any row fails to match rather than silently discarding annotation. `user_id` is
`CAST(... AS VARCHAR)` at every read and asserted to survive as an exact integer string — the
scientific-notation trap that once corrupted 499 of 500 ids.

Nothing reads the workbook back automatically. Verdict vocabulary is `mesma_pessoa`,
`pessoa_diferente`, `ambiguo`, offered as an Excel dropdown from a hidden sheet (an inline list
silently exceeds Excel's size limit).

```powershell
Rscript prep/building_external_data/capes_obmep_match_sample.R
```

### This is a candidate table, not a resolved identity map

The same warning script 25 earned, for the same reason. `n_users` / `n_persons` and the two
`*_rank` columns count rows **in the file**, which is the union of the two rules — so a downstream
filter on `jw_combo` alone needs its own counts, as the fan-out table above does.
**Collapsing one direction without handling the other invents an identity.**

**This is the only artefact in the folder carrying civil names from two sources at once.** Every
output of script 27 — the unmatched audit CSV included — is personal data on both sides.

### Re-running

```powershell
Rscript prep/building_external_data/capes_obmep_candidates_name_match.R
```

The bucket loop is idempotent: a bucket whose `pairs/` and `best/` files both exist is skipped, so
an interrupted run resumes rather than restarting. Forcing a rebuild means deleting
`capes_obmep_match/pairs/` and `capes_obmep_match/best/` first. Everything upstream of the loop is
cheap enough to always rebuild. The DuckDB spill and the per-bucket cache live under
`%TEMP%/duckdb_tmp_capes_obmep`, never in a Dropbox-synced folder.

### What to do if the yield is not enough

The key is a single exact pass, so a self-reported masters year one off CAPES enrolment puts the
pair in different buckets permanently — there is no recovery inside this design. The cheapest next
step is a **second pass keyed on first name plus the two start years only**, unioned with this one:
the ladder says that pass would reach 451,331 CAPES people instead of 166,086, and the bucket
machinery and the variant table are reused unchanged.

**Both of those levers have since been measured, and neither is open.** That second pass is exactly
the `_noinst` variant — built, and 57.6% reproducible by chance. Widening the Revelio institution
side beyond the 667 safe rsids is worth about 2% and adds no recall, because 98.9% of the unresolved
graduate rows are foreign institutions that cannot be in CAPES. See *The second variant* above and
*Next step: resolve an OpenAlex id for every graduate education row* just below.


### Where the institution work stands

**The task was parked here**, and the two open items are written up as actionable work in
[TO-DO](#to-do) near the top of this file — roll every id up to its parent, and resolve the
remaining `university_raw` strings. This subsection keeps the measurements behind them.

The lever is the right one. **The payoff is not where it sounds like it is**, and the numbers below
exist so nobody implements it expecting the match rate to move.

#### Resolution is already near-complete for the rows that can match

Over the 481,644 graduate education rows belonging to selected candidates (master's with MBA
excluded, plus doctorate), across 369,839 users:

| | rows |
|---|---|
| total graduate rows | 481,644 |
| with an `rsid` | 460,785 (95.7%) |
| with a non-empty `university_raw` | 481,576 (99.99%) |
| **resolved to an OpenAlex id** | **194,618 (40.4%)** |
| labelled `university_country = 'Brazil'` | 146,241 |

40.4% looks like a large gap and, for this purpose, is not. Of the **287,026 unresolved rows only
3,053 — 1.1% — are labelled Brazilian**, spanning 44 rsids. The 667-rsid safe map from 8f therefore
already resolves **97.9% of the Brazilian-labelled graduate rows**: 143,188 of 146,241.

The unresolved mass is foreign, and the institution names corroborate the country column rather than
contradicting it. The largest unresolved institutions are the University of Bologna, New University
of Lisbon, KU Leuven, LSE, Complutense Madrid, TU Munich, Utrecht, Instituto Superior Técnico,
Padua, Groningen, King's College London.

**A master's at Bologna cannot appear in CAPES**, which contains only Brazilian stricto sensu
programmes. Resolving those rows adds **no CAPES recall at all**.

#### What it *would* buy, and the ceiling on it

One real thing. Today a foreign master's and an unresolved Brazilian master's both write `'NA'` into
the key and are indistinguishable, so a CAPES person whose institution failed to resolve can meet a
LinkedIn user who studied at Bologna — `'NA'` meets `'NA'` and the slot constrains nothing.
Resolving the foreign side separates those two cases and deletes that stratum of false matches.

Its size bounds the gain. Pairs where **neither** side has a master's id:

| | pairs | share of the conservative product | mean `jw_combo` |
|---|---|---|---|
| canonical | 1,683 of 87,110 | **1.9%** | 0.9917 |
| `_noinst` | 2,050 of 282,769 | 0.7% | 0.9912 |

So this is a **precision fix worth about 2% of the product, not a recall lever.** Do it for
correctness; do not expect the match rate to move.

#### And the noise in the `_noinst` sample has a different cause

That variant is noisy because it **removes the institution from the key entirely**, not because
institutions are unresolved — 33.5% of its conservative pairs have the two sources naming *different*
OpenAlex institutions, which the canonical key makes impossible. The fix for that noise already
exists and is the canonical product.

The canonical product also looks close to its structural ceiling: 84,299 users matched against the
149,887 holding a resolvable Brazilian graduate degree, **56%**. The ceiling itself is set by how
many selected candidates did a Brazilian graduate degree at all — roughly 40% of those holding any
graduate degree. This cohort was selected on elite universities and firms, so heavy international
mobility is the expected shape, not an anomaly.

#### Where the work would start

See [TO-DO item 2](#2-attribute-an-openalex-id-to-every-remaining-university_raw) for the starting
assets and the full three-level scope. One detail belongs here rather than there: script 3's country
filter is `country_code = 'BR' OR (country_code IS NULL AND geo.country = 'Brazil')`, and the
`coalesce` form that looks equivalent does nothing — see that script's own section before writing a
non-Brazilian sibling.

**A second, separate failure mode surfaced after this was written**: CAPES and Revelio resolving the
same university to a parent record and a constituent school. That is [TO-DO
item 1](#1-replace-every-openalex-id-with-its-parent-root-id), it is worth a further 0.2%, and the
~2% ceiling below does **not** bound it — the two fixes are independent.

**One caveat on the measurement above.** `university_country` is Revelio's own field and is known to
be imperfect — the resolved-id count exceeding the Brazil-labelled count elsewhere in this section is
direct evidence of that. The institution names corroborate it here, but anyone implementing this
should re-derive the country from the resolved OpenAlex record rather than trust the column, and
re-check the 1.1% figure once resolution is wider.

---

## Two institution lists, two questions, four prefixes

Two lists carry the selection, and each is asked both where someone **studied** and where they
**worked**. The four prefixes are the single easiest thing in this folder to misread:

| | **studied there** | **worked there** |
|---|---|---|
| **Shanghai top-1000** | `sh_` — script 16 | `sw_` — script 19 |
| **RUF top-10 STEM** | `rd_` — script 20 | `rf_` — script 19 |

`sh_`/`sw_` share a list and differ in the question; `rd_`/`rf_` likewise. So a USP graduate who
never worked there has `sh_` and `rd_` set and `sw_`/`rf_` clear. Script 21 unions all four into one
table, which is where the confusion would actually bite.

The two lists are **not** interchangeable: only 14 of the 23 RUF institutions are in the Shanghai
top-1000. The other nine — UTFPR, UFBA, UFU, UFLA, UFABC, UEM, Mauá, FEI and ITA — are invisible to
`sh_`, and they account for 122,628 of the 133,940 users `rd_` finds that `sh_` does not.

**`br_degree_patterns.R` is not a script.** It defines character constants and nothing else — no
functions, no side effects, no connection. Scripts 8, 9 and 16 `source()` it. Running it does
nothing.

Pipeline groups:

- **1–2** flag profiles by given name
  ([below](#flagging-possibly-brazilian-linkedin-profiles-by-given-name)).
- **3–5** build institution-name lists ([below](#openalex-institution-names)). 4 does not consume
  3's output; both read the snapshot directly. 5 exports 3's output to Athena.
- **5a–5f** build author first-publication years and author-level OpenAlex flags from the works
  snapshot ([below](#openalex-author-histories-and-flags)). The completed author/name output from
  5a is the author universe for 5b; 5c intersects the two completed products into the analysis
  cohort; 5d adds aligned institution histories to that cohort. 5e instead filters only on first
  publication year and STEM, enriches those authors from the separate authors snapshot, and scores
  their given names as Brazilian-name evidence. 5f unions the affiliation and strict name-score
  admission routes, deduplicates authors, and rebuilds histories over that larger union. All six
  are independent of 3–5.
- **6** maps Revelio's school key to the Brazilian institutions list
  ([below](#the-rsid-crosswalk)). Consumes 5. **Nothing consumes it** — the criterion built on it
  was withdrawn; see
  [C_norm](#c_norm-and-the-rsid-branch-that-was-withdrawn).
- **7–10** build the OBMEP candidate cohorts ([below](#obmep-candidate-cohorts)). This is the only
  chain where every stage consumes the previous one.
- **10a** pulls every position and education record belonging to the pool
  ([below](#candidate-position-and-education-histories)). Consumes 10; **10b** adds the one thing it
  left out, Revelio's company key `rcid`, in a narrow extract of its own. 10b is consumed by 19.
- **11–13** validate the name prior ([below](#validating-the-name-prior)). None of them writes to
  Athena or feeds anything downstream; they exist to be read.
- **13a** measures the RECALL of criterion C_norm — how many `university_raw` strings the matcher
  in 8/9 never reaches. It groups 10a's education rows by Revelio's school key `rsid`, samples 500
  schools C_norm matched, and classifies a row-weighted sample of their unmatched strings. It is
  the complement of **17**, which measures precision and says so in its own note 5; neither script
  alone characterises the matcher. Offline and read-only, like 11–13.
  **`rsid` is a measuring device here, never a criterion — this is not a revival of C_rsid.**
  Result: **recall 51.6%**, and the two largest causes are a *reference-list* gap (42%) and bare
  brand acronyms (34%). See [below](#how-much-of-c_norm-is-missing).
- **14–15a** download the RUF course rankings, cut 12 courses out of them
  ([below](#ruf-course-rankings)), and give the resulting institutions an `openalex_id`
  ([below](#the-ruf--openalex-crosswalk)). 15 consumes 14 and 15a consumes 15 and 3; **15a is what
  connects RUF to the OpenAlex side of 3–5**, which nothing did before. The cut in 15 is a
  parameter, `rank_cut`; 15a covers the 23 institutions of the top-10 cut.
- **16** flags cohort members holding a bachelor's, master's or PhD from a top-1000 Shanghai
  university ([below](#top-1000-shanghai-degrees)). Consumes 4, 10a and 7; nothing consumes it.
  The only stage that joins the institution side of 3–5 to the candidate side of 7–10a, and it
  does it entirely offline.
- **17** audits 16 on a random sample of 1,000 matched rows
  ([below](#auditing-the-shanghai-flags)). Read-only with respect to the pipeline: it measures the
  error rate of 16's two classifiers and changes nothing. Its ground truth was written by an LLM,
  not by hand — read the caveat before quoting its numbers.
- **18–19** flag cohort members by **where they worked**
  ([below](#employer-flags)), which nothing did before: 18 resolves the two hand-researched company
  lists to `rcid` against `academic_company_ref`, and 19 turns that plus the RUF top-10 institutions
  **and the Shanghai top-1000** into position-level and user-level flags, entirely offline. 19 is
  the only stage that consumes 10b, and the only one that joins the RUF side of 14–15a to the
  candidate side of 7–10a. Its two university arms, `rf_` and `sw_`, differ **only** in which
  institution list they read — `classify()` takes the tables as arguments and knows nothing about
  which list it is serving.
- **20** flags cohort members holding a bachelor's, master's or PhD from one of the 23 RUF top-10
  STEM universities. It is script 16's structure pointed at script 19's institution list; there is
  no new matching logic in it. It closes the last cell of the 2×2 above.
- **21** unions 16, 19 and 20 into **the selected candidates**, and is the only product in the
  folder that carries a person's name. The union *is* the selection: all three inputs write only
  flagged users, so there is no filter to write.

---

# Flagging possibly-Brazilian LinkedIn profiles by given name

Local, **online** pipeline. It reaches CRAN, S3 and Athena, so it is **not** SEDAP-bound —
see `AGENTS.md` → *Execution Environments*. Nothing here may be copied into `scripts_sedap/`.

## The problem

The LinkedIn profile table carries **only two columns**, `user_id` and `fullname`. There is no
country, location, headline or language field. So nationality cannot be filtered — it can only be
*inferred from the name string itself*. That constraint shapes everything below, and it is also
why the result is a **prior to be combined with other criteria**, never a nationality label.

## Flow

```
prep/ibge_names_frequency.r                     (step 0 — lives in prep/, not here)
    -> OBMEP/Data/intermediate/ibge_names/final_given_names_with_variants.parquet

linkedin_br_name_flag.R                         (step 1 — flag all 708.4M profiles)
    reads  GTAllocation/.../linkedin_names/linkedin_chunk_1..20.parquet
    writes OBMEP/Data/intermediate/linkedin_br_flags/
             ibge_long.parquet            48,539 IBGE tokens
             firstname_counts.parquet     10,025,393 distinct first names
             firstname_matches.parquet    name-level flags + score
             profiles/chunk_01..20.parquet  708,365,562 rows

linkedin_br_flag_to_s3.R                        (step 2 — export the crosswalk)
    writes linkedin_br_name_flag.parquet   140,263,729 rows, 0.77 GB
    uploads s3://revelio-misc/linkedin_br_name_flag/
    registers revelio_database.linkedin_br_name_flag
```

Step 1 is pure DuckDB SQL driven from R — no R-side compute, dependencies only `duckdb` + `DBI`,
and it is fully offline-capable. Only step 2 needs the network.

## Method

**Exact match only.** The first name is extracted from `fullname`, accents folded, non-letters
dropped, then joined to a long IBGE table of canonical given names **and their spelling variants**.

First-name extraction takes the first whitespace token with ≥2 letters that is not a particle or
title (`de`, `da`, `van`, `dr`, …). Non-letters become **spaces, not deletions** — deliberate, so
`Jim Perry-ECUMC` → `jim` rather than fusing into an unmatchable string. Uses DuckDB's
`strip_accents`; **not** `unaccent`, which does not exist in DuckDB.

## Measured results

Every figure below comes from a logged run against the real data.

| | |
|---|---|
| Input | 708,365,562 profiles, 20 files, ~14.1 GiB |
| IBGE long table | 48,539 tokens = 12,856 canonical + 35,683 variant-only |
| Distinct first names | 10,025,393 |
| First name NULL (non-Latin script, initials only) | 41,023,040 — 5.79% |
| **Flag rate** | **50.45%** (357,336,323) |
| — canonical | 42.98% (304,427,855) |
| — added by variants | 7.47% (52,908,468) |
| Exported at `p_brazil > 0.05` | 140,263,729 rows, 0.77 GB |
| Runtime | ~7 min (step 1), ~1 min (step 2) |

## The score, and what it is not

```
lk_share   = lk_n / <total non-null first names>
ibge_share = ibge_freq / 184,372,093
ratio      = lk_share / ibge_share
p_brazil   = min(1, p_br / ratio)          p_br = 0.09
```

From Bayes: `P(BR | name) = P(name | BR) · P(BR) / P(name)`, estimating `P(name|BR)` by the IBGE
census share and `P(name)` by the LinkedIn share.

**`p_brazil` is a ranking, not a calibrated probability.** The `p_br` prior is an assumption, and
the IBGE census share is a biased estimate of the Brazilian *LinkedIn* name distribution — LinkedIn
under-covers older, poorer and rural Brazilians, which inflates scores for names like `raimunda`
and `terezinha`. Treat it as an ordering.

Each variant carries **its own** frequency, never its parent's: `mariah` scores on 24,382, not
maria's 12,284,478. `maria` → 1.000 while `mariah` → 0.144 and `marya` → 0.265. Inheriting the
parent frequency would hand every rare variant a huge share and push `p_brazil` to 1 across the
board.

| cutoff | profiles | % of 708M |
|---|---|---|
| any match | 357,336,323 | 50.45% |
| **> 0.05** (exported) | **140,263,729** | **19.80%** |
| ≥ 0.25 | 65,139,260 | 9.20% |
| ≥ 0.50 | 39,450,441 | 5.57% |
| ≥ 0.90 | 15,733,329 | 2.22% |

## Why the flag alone is unusable

It flags **half the planet**. The IBGE list reaches down to frequency 529 (variants to 20), which
admits names that barely exist in Brazil but are everywhere on LinkedIn:

| token | Brazil freq | LinkedIn rows | ratio |
|---|---|---|---|
| rahul | 24 | 559,394 | 6439× |
| muhammad | 145 | 1,375,671 | 2621× |
| chris | 623 | 1,405,849 | 623× |
| matthew | 256 | 911,031 | 983× |
| steve | 663 | 948,881 | 395× |

935 names with ratio > 5 supply 51.4% of canonical matches. The variant expansion is
**92.5% high-ratio noise** (48.9M of the 52.9M rows it adds), versus 41.3% for canonical names.

**So: never consume `flag_exact` on its own. Threshold on `p_brazil` / `ratio`.**

---

## Two traps that must not be reintroduced

### 1. DuckDB's `least()` ignores NULLs

```sql
SELECT least(1.0, NULL);      -- returns 1.0, NOT NULL
```

This is the opposite of most SQL engines. Because `ratio` is NULL for unmatched names, the naive
`least(1.0, p_br / ratio)` silently scored **every unmatched name `p_brazil = 1.0`** — maximum
Brazil-indicativeness for `scott`, `md`, `ahmed`. The output looked entirely plausible.

It was caught only because the name-level and profile-level views disagreed (39.4M vs 349.5M rows
at `p_brazil ≥ 0.5`). The guard is now explicit:

```sql
CASE WHEN ratio IS NULL THEN NULL ELSE least(1.0, :p_br / ratio) END
```

plus two assertions that abort the script if `p_brazil` is ever non-NULL for a non-match, or NULL
for a match. **Do not remove either.**

### 2. Never `sum` IBGE variant frequencies

A `variant_text` attaches to up to **15** canonical parents in this subset (62 in the raw source).
Summing across the many-to-many join inflates the total to **2.63 billion** against a real
population of 190M.

Aggregate with `max`, which is safe *only* because frequency is verified consistent per token —
and that verification is itself an assertion in the script. The underlying facts, established from
the raw source:

- All 623,966 `name_variant` rows are **also** entries in `name_ranking` with an **identical**
  frequency (0 mismatches). A variant is an ordinary name cross-referenced as a spelling variant.
- `variant_frequency` is always consistent per `variant_text` (0 inconsistencies).
- Canonical `maria` (12,284,478) does **not** include its variants (34,991) — disjoint entries, so
  no double counting in the denominator.
- 8,166 tokens are both canonical and a variant of something else; these resolve to canonical.

---

## Why the fuzzy match was dropped

A `metaphonebr` + Jaro-Winkler ≥ 0.95 method was originally specified. It was installed, built and
measured — then abandoned, because **its two halves work against each other**: the phonetic code
collapses exactly the differences Jaro-Winkler penalises, and preserves exactly the ones it
tolerates.

| pair | same block? | JW | survives both? |
|---|---|---|---|
| marya / maria | yes | 0.9067 | no |
| luiz / luis | yes | 0.8833 | no |
| jessica / jessika | yes | 0.9429 | no |
| mariah / maria | no | 0.9667 | no |
| matheus / mateus | no | 0.9667 | no |
| gabriel / gabriell | yes | 0.9750 | **yes** |

Of 20 realistic Brazilian variant pairs, 11 shared a block and 9 passed JW ≥ 0.95 — but only **4
satisfied both, all of them mere letter-doubling**.

Compounding it, **JW ≥ 0.95 is arithmetically unreachable for a single mid-word substitution on
names shorter than 8 characters**: len 4 → 0.867, len 5 → 0.907, len 6 → 0.933, len 7 → 0.943,
len 8 → 0.950. Most Brazilian given names are 4–7 characters, so at that threshold the only
admissible edits are suffix additions. The step would also have cost ~34 min of pure-R regex over
10.35M distinct names.

**The IBGE variant list recovers more than the fuzzy match would have, as a pure join with no new
dependency** — `marya`, `mariah`, `luis`/`luiz`, `tiago`/`thiago` and `michelle` are all already
IBGE tokens. `metaphonebr` 0.0.5 remains installed but unused. If more tolerance is ever wanted,
lower JW to ~0.90 and block on first letter + length rather than on the phonetic code.

## Known limitations

- **Comma-inverted names** — `de Souza, João` yields `souza`. Affects 0.63% of rows (4.47M).
  Deliberately not special-cased: taking the post-comma segment would break the far more common
  LinkedIn credential suffix (`Jim Perry, MBA` → `mba`), trading a false negative for a false
  positive.
- **Non-decomposable Latin letters** — `strip_accents` uses NFD + combining-mark removal, so
  `ł ø đ ß æ` have no decomposition and are then dropped: `Łukasz` → `ukasz`. Negligible for
  Brazilian names.
- **Non-Latin scripts** — CJK/Cyrillic/Arabic names clean to empty and are never flagged (41.0M,
  5.8%). The method is structurally blind to Brazilians who write their name in another alphabet.
- **No spelling tolerance** beyond IBGE's own variant list.
- **Ambiguous-origin names cannot be resolved by first name alone** — `paola` (ratio 1.566,
  `p_brazil` 0.0575) barely clears the cutoff and is equally Italian or Spanish-American.

## Re-running

*(This subsection covers scripts 1-2 only. For the cohort pipeline see
[Re-running the cohorts](#re-running-the-cohorts).)*

Both scripts are idempotent — every expensive stage skips when its output already exists:

| stage | skip condition |
|---|---|
| counts pass (~3 min) | `firstname_counts.parquet` exists |
| profile writes | each `profiles/chunk_NN.parquet` exists |
| crosswalk parquet | `linkedin_br_name_flag.parquet` exists |
| S3 upload | remote `content-length` matches local byte size |

To force a rebuild, delete the relevant output first. Note that `firstname_matches.parquet` is
**not** cached — it is cheap and always rebuilt, so changing `p_br` takes effect on the next run
without touching the 3-minute scan.

### The `RAthena` / reticulate pin

`RAthena` talks to Athena through boto3 via `reticulate`. On this machine `python` on PATH is the
`WindowsApps` shim, which reticulate deliberately skips — so it discovers no interpreter and
`RAthena` reports *"Boto3 is not detected"*, even though boto3 1.42.39 and numpy 2.4.2 **are**
installed against the real interpreter at:

```
C:/Users/megaj/AppData/Local/Python/pythoncore-3.14-64/python.exe
```

Step 2 therefore pins `RETICULATE_PYTHON` to that path — but only when it is unset and the path
exists, so an interactive session that already resolves Python correctly is never overridden.
Override with the `OBMEP_PYTHON` environment variable. **No package install is needed**;
`RAthena::install_boto()` would build a redundant virtualenv beside a working interpreter.

The Athena step is wrapped in `tryCatch`: if it fails, the S3 upload is preserved and the DDL is
printed for manual execution, rather than losing a completed upload to a Python dependency.

## Downstream use

`revelio_database.linkedin_br_name_flag` — `user_id BIGINT`, `p_brazil DOUBLE`, 140,263,729 rows,
sorted by `user_id` so Athena can prune row groups on join.

The crosswalk covers **19.8% of all profiles**, well above Brazil's plausible ~8–11% share of
LinkedIn. It is intended to be **intersected with other criteria** — founder/CEO status, education,
firm. Tighten with `p_brazil` in Athena as needed; it cannot be loosened below 0.05 without
re-exporting.

Scripts 5 and 8-10 do exactly that intersecting; see
[OBMEP candidate cohorts](#obmep-candidate-cohorts).

---
---

# OpenAlex institution names

Two independent scripts, both reading the **local** OpenAlex institutions snapshot and writing
parquet into the OBMEP Dropbox. Pure DuckDB SQL driven from R; dependencies are `duckdb`, `DBI`,
`arrow` (plus `readxl` for script 4). **No network, no S3, no Athena** — unlike step 2 above.

```
GTAllocation/Data/external/oa_snapshot/data/institutions/updated_date=*/part_0000.gz

openalex_br_institutions.R                (every Brazilian institution)
    writes OBMEP/Data/intermediate/openalex_institutions/
             openalex_institutions_br.parquet    1,947 rows, 83 KB

shanghai_ranking_openalex_names.R         (OpenAlex name for the Shanghai ranking)
    reads  GTAllocation/Data/intermediate/shanghai_ranking_full_cleaned.xlsx
    writes OBMEP/Data/intermediate/shanghai_ranking/
             shanghai_ranking_oa.parquet         1,079 rows, 52 KB
```

Both are self-validating: they assert their invariants and `warning()` on drift from measured
counts, so a clean exit is the pass condition. Neither is cached — both are cheap (well under a
minute) and always rebuild.

## The snapshot

| | |
|---|---|
| Partitions | 19 `updated_date=` folders, `2026-02-06` and `2026-02-08`…`2026-02-25` |
| Files | one `part_0000.gz` each — gzipped **JSON Lines** — plus a `manifest` |
| Size | 175.5 MB, **120,658 records** |
| Shape | `2026-02-25` (80,065) and `2026-02-06` (30,399) are near-full dumps; the other 17 are daily deltas of 96–2,078 |

Four properties of this data that the scripts depend on:

**Records are ~21 KB each** because of `topics`, `topic_share` and `counts_by_year`. Both scripts
declare an explicit `columns = {...}` on `read_ndjson` so the JSON reader skips those fields
entirely. **Do not read the full record** — projection is what keeps these jobs cheap.

**`updated_date` inside a record is US-format** (`"02/25/2026 06:01:00"`), *not* ISO. Recency is
therefore taken from the **partition folder name**, which is ISO and sorts lexically. Parsing the
in-record field would need `%m/%d/%Y %H:%M:%S`.

**The partitions are disjoint in this copy** — 120,658 rows, 120,658 distinct ids. The dedupe by id
in both scripts is a **safeguard**, not a fix: it removes nothing today, but OpenAlex publishes
dump + deltas and nothing guarantees they stay disjoint. In script 4 it is load-bearing for a
different reason — a duplicated id would fan out the `LEFT JOIN` and silently multiply ranking rows.

**There is no `merged_ids/` tree**, and zero records carry `merge_into_id` or `is_deleted`. Merged
or redirected institution IDs cannot be resolved locally; OpenAlex ships those separately at
`s3://openalex/data/merged_ids/institutions/`, which was not downloaded here.

---

## 3. `openalex_br_institutions.R`

Every Brazilian institution with its OpenAlex ID, name, and a few useful extras.

**Columns:** `openalex_id` (short, `I17974374`), `openalex_url`, `display_name`,
`cleaned_display_name`, `ror`, `type`, `works_count`, `city`, `region`, `country_source`,
`snapshot_date`.

### The country filter is not `country_code = 'BR'`

This is the one thing to preserve. `country_code` is **NULL for 7,043 of 120,658 records**, and for
every one of those `geo.country_code` is **also** NULL. The only surviving country field is
`geo.country`, the name spelled out. So:

```sql
WHERE country_code = 'BR' OR (country_code IS NULL AND geo.country = 'Brazil')
```

A `coalesce(country_code, geo.country_code)` looks right and **does nothing** — that was the
original bug. The fallback recovers **127** institutions, including real federal universities:
UF do Agreste de Pernambuco, UF de Rondonópolis, UF do Delta do Parnaíba, UF do Norte do Tocantins,
UE de Alagoas. `country_source` records which field each row came from.

Where both fields exist they never disagree: all 1,820 `country_code='BR'` rows have
`geo.country='Brazil'` and vice versa. There is no conflict to arbitrate.

| | |
|---|---|
| Total | **1,947** |
| — via `country_code = 'BR'` | 1,820 |
| — via `geo.country = 'Brazil'` | 127 |

### Name cleaning

`cleaned_display_name` removes **only** parenthesised expressions. Accents, case and punctuation are
untouched — no `strip_accents`, no `lower()`.

```sql
trim(regexp_replace(
  regexp_replace(display_name, '\s*\([^()]*\)', '', 'g'),
  '\s+', ' ', 'g'))
```

`[^()]` cannot cross a parenthesis, so each group is matched exactly; the leading `\s*` absorbs the
space *before* the group (`Estácio (Brazil)` → `Estácio`, not `Estácio `); the `\s+` collapse covers
the one name where the group sits mid-string; `trim` closes the ends. Safe because all 501
parenthesised names have exactly one balanced, non-nested group, and there are no `[` or `{`
anywhere in the file.

**501 of 1,947 names change.** 495 of those are just a `(Brazil)`/`(Brasil)` tag, almost all on
`company` records. Only 6 hold anything else — `(UNICAMP)`, `(Unesp)`, `(FAM)`, `(LACOG)` and two
`(Portugal)`. So among the 542 `education` rows the cleaning alters **3**.

Three assertions guard it, and **none should be removed**:

| assertion | what it catches |
|---|---|
| non-ASCII count equal before and after (939 = 939) | someone adding `strip_accents` or `lower()` |
| duplicate-name group count equal before and after (4 = 4) | the cleaning merging two distinct institutions |
| no residual `(` or `)`, nothing empty, nothing untrimmed | a regex regression |

The 4 duplicate groups are **pre-existing** in OpenAlex — distinct ids sharing a name, mostly in
different cities (`Hospital de Base` in Brasília vs São José do Rio Preto). The cleaning creates no
new collisions.

### `type` is about ownership, not function — and OpenAlex has no public/private flag

**Filtering `type = 'education'` silently drops large for-profit universities.** Estácio's main
record is `Estácio (Brazil)`, typed **`company`**, ROR `02vej5573`, homepage `portal.estacio.br`,
**7,237 works** — enough to rank near the top 20 Brazilian institutions. There is no
`Universidade Estácio de Sá` record at all. Its two `education` rows are single campuses with 177
works between them, so a `type` filter keeps 2.4% of Estácio's output.

Anhanguera is fragmented four ways and needs rolling up for any institution-level figure:

| display_name | type | works |
|---|---|---|
| Anhanguera-Uniderp University | education | 3,000 |
| Centro Universitário Anhanguera | education | 1,472 |
| Anhanguera (Brazil) | company | 1,191 |
| Faculdade Anhanguera | education | 946 |

Cogna, Kroton, Ser Educacional and Pitágoras are absent entirely. Other large privates behave
normally — Mackenzie (14,001), Nove de Julho (13,431), the seven PUCs (39,327 down to 7,513),
Universidade Salvador (6,830, filed under its full name and **not** `UNIFACS`).

For an authoritative public/private split or a real list of IES, join to the Censo da Educação
Superior at `OBMEP/Data/raw/Censo Superior`. OpenAlex cannot supply it.

### Other things worth knowing

- **Type mix** of the 1,947: 542 education, 504 company, 241 nonprofit, 176 government, 169 other,
  164 healthcare, 127 facility, 16 archive, 8 funder.
- **Two `(Portugal)` records sit in the Brazil file** — both tagged `BR` by OpenAlex itself, geocoded
  to Fundão/ES and Belmonte/BA, real Brazilian municipalities that share names with Portuguese
  towns. Upstream geocoding collision, not an extraction bug. Both have 0 works.
- **1,947 is correct, not low.** OpenAlex institution coverage is heavily US/Europe-skewed — the US
  alone is 31,340 of 120,658.
- **`display_name_acronyms` is not carried into the parquet.** For UNICAMP and Unesp the acronym
  exists *only* in `display_name`, so after cleaning it is recoverable only from that column.

---

## 4. `shanghai_ranking_openalex_names.R`

Adds the OpenAlex `display_name` (and `cleaned_display_name`, same rule as above) to the Shanghai
ranking. **The join is by ID, not by name** — the xlsx already carries `OA_id` and `OA_key`, and
`OA_key` is the short OpenAlex id. Output is the 11 original columns plus the 2 new ones.

`LEFT JOIN` with the ranking driving, so no ranking row can be lost or duplicated. The script
asserts row count **and** distinct-key count both stay at 1,079 — that is what would catch a
snapshot-side duplicate fanning out.

| | |
|---|---|
| Rows | **1,079** — all with `OA_id`/`OA_key`, no duplicates |
| Matched | **1,076** |
| Unmatched | **3** (`display_name` NULL) |
| `shanghai_Name` already identical to `display_name` | 769 |
| **Differs** | **307** |
| Parenthesis cleaning altered | 3 |

### The 3 that do not match

Pinned in `exp_missing`, so a *different* id failing raises a warning instead of passing silently.

| OA_key | shanghai_Name | why |
|---|---|---|
| `RUTGERS UNIVERSITY - NEWARK` | Rutgers University - Newark | **`OA_id` and `OA_key` hold the institution *name*, not an id.** A defect in the source xlsx, fixable there |
| `I4408541918` | Ecole Polytechnique | Well-formed id, absent from the snapshot |
| `I4407990165` | Victor Segalen Bordeaux 2 University | Well-formed id, absent from the snapshot |

The latter two were most likely merged or deleted in OpenAlex after this dump — unresolvable
locally, since the snapshot ships no `merged_ids/` tree.

### Why the column is worth having

The 307 differences are systematic: Shanghai anglicises, OpenAlex uses the endonym.

| Rank | shanghai_Name | display_name |
|---|---|---|
| 15 | Paris-Saclay University | Université Paris-Saclay |
| 54 | Swiss Federal Institute of Technology Lausanne | École Polytechnique Fédérale de Lausanne |
| 59 | University of Munich | Ludwig-Maximilians-Universität München |
| 41 | PSL University | Université Paris Sciences et Lettres |
| 72 | The University of New South Wales | UNSW Sydney |

All **18 Brazilian** entries resolved, and there the gain is largest — every one comes back in
Portuguese with correct accents (`University of Sao Paulo` → `Universidade de São Paulo`,
`Federal University of Viçosa` → `Universidade Federal de Viçosa`).

### The second output: alternative names and acronyms

The script also writes **`shanghai_ranking_oa_acronyms.parquet`**, long — one row per
(`OA_key`, name) — from OpenAlex's `display_name_acronyms` and `display_name_alternatives`, with a
`kind` column separating the two.

| | |
|---|---|
| Rows | **3,824** |
| `kind = 'acronym'` | **701**, covering **662** institutions |
| `kind = 'alternative'` | **3,123** |
| Institutions with at least one | 1,076 of 1,079 |

Separate file, not a list column in `shanghai_ranking_oa.parquet`, for two reasons: scripts 16 and
20 assert that file's row and column counts, and the grain is different — 1,079 institutions against
thousands of names.

**`kind` is not decoration.** The two lists carry completely different collision risk. Acronyms
collide badly — `UM` is claimed by **seven** ranked institutions (Maastricht, Malaya, Montana,
Münster, Miami, Michigan, Macau), `UW` and `CMU` by five each. Full alternative names barely collide
at all. Anything consuming this file has to treat the two kinds under different rules; see 16a.


Two caveats on reading the numbers:

- **The 307 are not all substantive.** Rank 48 counts as differing only because Shanghai truncates
  `The University of Texas Southwestern Medical Center` and OpenAlex appends ` at Dallas`.
- **Parenthesis cleaning can destroy meaning here.** It fires on 3 rows, one of which is
  `China University of Geosciences (Beijing)` → `China University of Geosciences`. The `(Beijing)`
  distinguishes it from the Wuhan institution of the same name. Prefer `display_name` when
  disambiguating those two.

`country_code` agrees between xlsx and snapshot on 1,075 of 1,076. The single exception is
Osaka Metropolitan University, NULL in the xlsx and `JP` in the snapshot — absence, not conflict.

---
---

# OpenAlex author histories and flags

`openalex_author_history.R` is a local, **offline** DuckDB pipeline over the already-downloaded
official works parquet snapshot at `D:/OpenAlex/works`. It does not install packages or contact
CRAN, OpenAlex, S3, or Athena, and it is not SEDAP-bound. Its only R dependencies are `DBI` and
`duckdb`.

It writes two single-file, ZSTD-compressed parquet datasets under
`OBMEP/Data/intermediate/openalex_authors/`:

| file | grain | columns |
|---|---|---|
| `openalex_author_first_publication.parquet` | one row per identified author in the works snapshot | `author_id`, `author_url`, `author_display_name`, `raw_author_name`, `first_publication_year` |
| `openalex_author_institutions.parquet` | one row per identified author × normalized institution ever present in an authorship | `author_id`, `institution_id`, `institution_url`, `institution_display_name`, `country_code` |

The first-publication file has completed production validation. The much larger normalized
author–institution build remains resumable from its committed cache, but is superseded for the
current analysis by `openalex_author_flags.R`. The latter answers the two needed questions without
materializing every author–institution pair:

| file | grain | columns |
|---|---|---|
| `openalex_author_flags.parquet` | one row per identified author in the completed first-publication file | `author_id`, `author_url`, `author_display_name`, `raw_author_name`, `ever_br_institution`, `ever_stem` |

IDs are stored in compact form (`A…`, `I…`) and the corresponding full OpenAlex URL is retained.
`country_code` is OpenAlex's two-letter ISO code and remains NULL when OpenAlex has no country for
that institution. The institution file records only normalized entries in
`authorships.institutions`; it does not promote `raw_affiliation_strings` into institutions.

## Snapshot and inclusion rules

The 2026-06-26 works manifest contains **2,446 parquet parts**, **510,372,821 works**, and
724,970,323,127 bytes (675.18 GiB). The script reads the manifest instead of recursively statting
the entire Windows volume, then passes explicit groups of manifest-listed parts to DuckDB.

Every work is eligible, including records marked as paratext or retracted. Every authorship with a
well-formed `https://openalex.org/A[0-9]+` id contributes; unresolved authorships with a NULL or
malformed author id are counted in the source audit but cannot appear in either output.
`first_publication_year` is the minimum non-NULL `publication_year` across all of an author's works
and remains NULL only if all of that author's years are NULL.

Names can vary between works, so the two author name columns deliberately mean different things:

- `author_display_name` is the most frequent non-empty `authorships.author.display_name`.
- `raw_author_name` is the most frequent non-empty `authorships.raw_author_name`.

They are selected independently and weighted by authorship mentions. Ties use lexical order, which
makes reruns deterministic. Institution names and country codes use the same global modal-value,
lexical-tie rule across all mentions of an institution id. Do not use an arbitrary or latest row:
there is no author-update timestamp in a work authorship, and file order is not semantic.

## Bounded, resumable aggregation

A direct global `GROUP BY` over this snapshot exceeds practical local spill limits. The script
therefore aggregates author variants in 25-part source batches, partitions the result into 64
author hash buckets, reduces each bucket, and performs the institution extraction in 5-part slices
through outer batch 64. Manifest batches 65–98 are substantially denser, so they use one-part
slices to stay inside the same memory bound without changing any earlier cache interpretation.
Committed intermediates are cached below
`D:/OpenAlex/tmp/duckdb_openalex_author_history/v2_batch25_b64/`, so an interrupted run resumes at
the first missing batch or bucket rather than rescanning 675 GiB. The cache is removed only after
both final outputs validate and are promoted.

Defaults are 16 GB DuckDB memory, a 140 GB spill cap, and 8 threads. They can be overridden with
`OPENALEX_DUCKDB_MEMORY_LIMIT`, `OPENALEX_DUCKDB_MAX_TEMP`, and `OPENALEX_DUCKDB_THREADS`;
`OPENALEX_DUCKDB_TMP` moves the spill/cache root. `OPENALEX_ROOT`, `OBMEP_ROOT`, and
`OPENALEX_WORKS_GLOB` override the input root, output root, and source parquet selection. The last
is also the test hook: the known shard
`updated_date=2016-06-24/part_0000.parquet` must produce **1,152 authors** and **170 distinct
author–institution pairs**.

Outputs are first written as `.partial`. Before either is exposed, the script verifies schemas,
unique grains, id and URL consistency, non-empty selected names, country-code format, and that every
institution row's author exists in the author file. Promotion is coordinated across the two files;
if either rename fails, prior outputs are restored.

## Measured production result

The full author pass observed **1,404,168,937 authorship mentions**: 811,320,229 with valid author
ids and 592,848,708 unresolved. Those valid mentions reduce to **118,991,535 distinct authors**.
Final institution counts, output sizes, null rates, and wall time are printed by the script and are
recorded here after the two-file production validation completes.

## Author-level Brazilian-institution and STEM flags

`openalex_author_flags.R` is the replacement for analyses that only need to know whether an author
ever had a Brazilian affiliation or ever published in a STEM field. It reuses the IDs and the two
independently selected modal names from `openalex_author_first_publication.parquet`; it does not
rebuild names and does not copy `first_publication_year` into the flags file.

The flags are Boolean and non-NULL:

- `ever_br_institution` is true when any normalized institution embedded in any of the author's
  work authorships has `country_code = 'BR'`. It deliberately uses the country recorded in the
  works snapshot, not the separately curated list from `openalex_br_institutions.R`.
- `ever_stem` is true when any work's primary topic has domain `Physical Sciences` or `Life
  Sciences`, or field `Medicine`. A qualifying work flags every identified author on that work.
  Missing primary-topic data contributes false.

All works are eligible, including paratext and retracted records. The script does not unnest the
institution list: after unnesting authorships once, DuckDB tests the embedded country-code list and
aggregates both flags together with `bool_or`. This matters because exploding all normalized
institutions was the bottleneck in the superseded pair build.

The source scan is split into atomic five-part checkpoints and the global reduction into 64 stable
author hash buckets. An interrupted `.partial` checkpoint is discarded; a committed parquet is
reused. The default cache and DuckDB spill location is on the internal drive at
`%LOCALAPPDATA%/OpenAlex/duckdb_openalex_author_flags/v1_batch5_b64`, while the 675.18 GiB source
continues to be read from `D:/OpenAlex/works`. Defaults are 22 GB DuckDB memory, a 55 GB spill cap,
and 8 threads. Override them with `OPENALEX_FLAGS_DUCKDB_MEMORY_LIMIT`,
`OPENALEX_FLAGS_DUCKDB_MAX_TEMP`, `OPENALEX_FLAGS_DUCKDB_THREADS`, and
`OPENALEX_FLAGS_DUCKDB_TMP`.

Before promotion, the script asserts the six-column schema, one-to-one grain against all
118,991,535 completed authors, non-NULL flags, exact preservation of IDs and names, and no missing
or orphan flag records. The known test shard `updated_date=2016-06-24/part_0000.parquet` has 1,152
authors: 33 Brazilian-institution authors, 492 STEM authors, and 3 satisfying both. Production is
expected to take approximately 6–9 hours; both flags are computed in the same full snapshot pass.

Run locally with:

```powershell
Rscript prep/building_external_data/openalex_author_flags.R
```

## Brazilian-affiliated STEM authors first published in 2017 or later

`openalex_author_br_stem_2017plus.R` is a cheap, local derivation over the two completed author
products; it does not rescan `D:/OpenAlex/works`. It selects authors satisfying three independent
lifetime conditions:

```sql
ever_br_institution
AND ever_stem
AND first_publication_year >= 2017
```

The Brazilian affiliation and STEM article need not occur on the same work. The output is
`openalex_author_br_stem_2017plus.parquet`, at one row per author, with full provenance:
`author_id`, `author_url`, `author_display_name`, `raw_author_name`, `first_publication_year`,
`ever_br_institution`, and `ever_stem`.

The production result is **843,232 authors**, with no NULL IDs, names, years, or flags. First
publication ranges from 2017 through 2026: 85,854; 86,206; 90,691; 95,966; 91,809; 92,805; 83,796;
79,725; 52,781; and 83,599 authors respectively. The script writes `.partial`, validates schema,
grain, input agreement, flag values, year range, and the measured distribution, then promotes with
rollback protection.

Run locally with:

```powershell
Rscript prep/building_external_data/openalex_author_br_stem_2017plus.R
```

## Institution histories for the 2017+ author cohort

`openalex_author_br_stem_2017plus_institutions.R` returns to the works snapshot, but only retains
authorships belonging to the 843,232 authors selected by the preceding step. For each author it
collects every valid normalized institution in that author's own authorship entries across all
works. Coauthors' institutions are not propagated to the author.

The output is a separate ten-column parquet,
`openalex_author_br_stem_2017plus_institutions.parquet`. Its first seven columns are byte-for-byte
the 5c cohort fields; three aligned strings follow:

```
institution_display_names
institution_first_publication_years
institution_country_codes
```

Institution identity is the normalized OpenAlex `I…` ID, although the displayed token is its
modal non-empty name. Each author's distinct institutions are ordered by first publication year,
then display name, then institution ID; every string uses exactly that order. The institution year
is the minimum non-NULL work `publication_year` for that author–institution pair. Country and name
are global modal values across the selected cohort's mentions, with lexical tie-breaking.

The separator is `|`. A literal pipe inside an OpenAlex display name is replaced with `/`, and a
missing year or country is encoded as the literal `NA`; this prevents parsers from dropping an
empty final token and keeps the three columns positionally aligned. Authors without a valid
normalized institution are retained with `NA` in all three columns.

Institution-association years are required to be four-digit integers at least 2017, but are not
capped at the snapshot year. OpenAlex carries future-dated and online-first works: the production
checkpoints contain four distinct author-institution pairs whose first associated work is dated
2027. After the global minimum-year reduction, two final author-institution tokens remain dated
2027; the other two pairs also have earlier mentions in different checkpoints. The cohort's own
`first_publication_year` remains separately validated within 2017-2026; only the later institution
history is allowed to extend beyond 2026.

The 2,446 source files are extracted in atomic five-part checkpoints and globally reduced through
64 author hash buckets. The cache lives by default under
`%LOCALAPPDATA%/OpenAlex/duckdb_openalex_author_br_stem_2017plus_institutions/v1_batch5_b64`.
Defaults are 22 GB DuckDB memory, a 55 GB spill cap, and 8 threads; override them with the
`OPENALEX_COHORT_INST_DUCKDB_*` environment variables. Interrupted `.partial` checkpoints rebuild,
committed checkpoints resume, and the cache is removed only after the final parquet validates and
is promoted. Expected production runtime is approximately 3–5 hours.

The completed 2026-08-28 production run contains **843,232 authors**, **1,516,712 distinct
author-institution pairs**, and **30,037 distinct institutions**. All authors have a normalized
institution and all three history columns are positionally aligned. There are 30 pairs with an
unknown first association year and 638 institutions with an unknown country. The first seven
columns match the input cohort exactly, including its unique author IDs and URLs. The promoted
parquet is 31.09 MiB. Active processing time across the initial and resumed attempts was about
3 hours 39 minutes; successful promotion removed the resumable cache.

Run locally with:

```powershell
Rscript prep/building_external_data/openalex_author_br_stem_2017plus_institutions.R
```

## Given-name scores for all STEM authors first published in 2017 or later

`openalex_author_stem_2017plus_br_name_scores.R` is stage 5e: a local, **offline** DuckDB pipeline
that reproduces the given-name method from script 1 for OpenAlex authors, with an assumed Brazilian
researcher prior of **2.5%**. It never contacts OpenAlex, CRAN, S3 or Athena and is not SEDAP-bound.

This is deliberately a different cohort from 5c. It filters the completed 5a/5b products first:

```sql
ever_stem
AND first_publication_year >= 2017
```

It does **not** require `ever_br_institution`. The current completed products yield **31,899,019**
eligible authors before name matching, versus 843,232 in 5c. `ever_br_institution` remains in every
row as stored-but-not-filtering evidence, following the same provenance rule used by the candidate
cohort tables elsewhere in this folder.

### The authors snapshot adds a materially better name

`D:/OpenAlex` has no README and no Brazilian/nationality classification. Its `authors` manifest does
describe a 2026-06-26 parquet snapshot with **119,129,660 records** and **52,769,910,496 bytes**
(49.15 GiB). The useful additional field is `full_name`: it consolidates author-name variants and
often expands an initial-only display name (`L Wang` → `Lili Wang`).

The script reads the manifest instead of recursively stat'ing the drive, projects only `id` and
`full_name`, and joins those fields to the already-filtered 31.9M IDs. Name precedence is explicit:

1. `authors.full_name`;
2. the modal `author_display_name` produced by 5a;
3. the independently selected modal `raw_author_name` produced by 5a.

Bibliographic comma inversion is handled only on `full_name`: `NAGASAKA, Mou` yields `mou`. The
LinkedIn rule deliberately could not do this because commas there usually introduce credentials;
that ambiguity does not justify carrying its known false negative into a bibliographic author-name
field. The chosen source and a `name_was_comma_inverted` flag travel with every row.

All later cleaning is identical to script 1: `strip_accents`, nonletters to spaces, the first token
with at least two letters after excluding particles/titles, and an exact join to canonical IBGE
given names plus their recorded spelling variants. There is no fuzzy match.

### The score and output grain

The OpenAlex name distribution is calculated **after** the year/STEM filter, as requested:

```
openalex_name_share = openalex_name_count / <eligible authors with a non-NULL token>
ibge_name_share     = ibge_freq / 184,372,093
ratio               = openalex_name_share / ibge_name_share
p_brazil            = min(1, 0.025 / ratio)
```

The two script-1 traps remain load-bearing here: an unmatched token is guarded before DuckDB's
`least()` can turn NULL into 1, and IBGE variant frequencies are reduced with the verified `max`,
never summed across parents. A variant scores on its own census frequency.

Everything is written below `OBMEP/Data/intermediate/openalex_authors/br_name/`:

| file | grain | purpose |
|---|---|---|
| `eligible_authors.parquet` | one row per year/STEM-eligible author | expensive, reusable `full_name` enrichment plus 5a/5b provenance |
| `ibge_long.parquet` | one row per IBGE token | canonical/variant lookup with one safe frequency per token |
| `firstname_counts.parquet` | one row per selected OpenAlex given name | filtered-universe denominator; versioned so stale cleaning logic cannot be reused |
| `firstname_matches.parquet` | one row per selected OpenAlex given name | counts, IBGE evidence, ratio and 2.5% score |
| `openalex_author_stem_2017plus_br_name_scores.parquet` | one row per eligible author | all provenance and name evidence, sorted by `author_id` |

The final file keeps **all** eligible authors. It does not turn a score threshold into a nationality
label. Unmatched and unparseable names remain present with `flag_exact = false`; `p_brazil` is NULL.
The raw `ratio`, prior and score are stored together so downstream cuts stay auditable.

### Measured production result — 2026-09-01

The complete run retained **31,899,019 unique authors** and produced **28,845,624 parseable given
names** (90.43%) spanning **1,783,044 distinct tokens**. The remaining 3,053,395 authors (9.57%)
stay in the final file with a NULL score. `full_name` itself is present for 31,890,500 authors
(99.973%); presence is not parseability, since 3,053,190 unparseable rows still carry a `full_name`
written without a usable two-letter Latin token.

| selected name source | authors | share of cohort | comma-inverted |
|---|---:|---:|---:|
| enriched `openalex_full_name` | 28,289,992 | 88.686% | 2,098,559 |
| modal `author_display_name` fallback | 520,043 | 1.630% | — |
| modal `raw_author_name` fallback | 35,589 | 0.112% | — |
| unparseable after all three | 3,053,395 | 9.572% | — |

Exact IBGE matching finds 9,815,517 authors: 30.77% of the full cohort and 34.03% of parseable
names. Canonical tokens contribute 7,848,704 authors and variants 1,966,813. As in the LinkedIn
pipeline, raw match membership is far too broad to use as the Brazilian criterion.

| score rule | authors | share of all 31.9M |
|---|---:|---:|
| `p_brazil > 0.05` | 2,766,380 | 8.672% |
| `p_brazil >= 0.25` | 780,455 | 2.447% |
| `p_brazil >= 0.50` | 197,133 | 0.618% |
| `p_brazil >= 0.90` | 69,707 | 0.219% |

The stored-but-not-filtering affiliation flag provides a strong directional check without being
used to calibrate the score. Among the **843,232** authors ever observed at a Brazilian institution,
79,850 (9.47%) score at least 0.50 and the median non-NULL score is 0.1700. Among the other
31,055,787 authors, 117,283 (0.378%) clear 0.50 and the median is 0.0060. The affiliation-positive
count exactly reproduces 5c after applying its missing Brazil condition to this broader cohort.

First publication ranges from 2017 through 2039. The 267 records after 2026 are retained because
the requested rule has only a lower bound and OpenAlex contains future-dated/online-first records:
165 in 2027, 41 in 2028, 22 in 2029, 17 in 2030, 18 in 2031, and four across 2035, 2036 and 2039.

The first production run took **4 min 44 s** with 16 GB memory, a 50 GB spill cap and eight threads;
the sole 49.15 GiB authors-snapshot scan took about 1 min 48 s. Promoted sizes were 1,120.67 MiB for
`eligible_authors`, 0.43 MiB for `ibge_long`, 8.06 MiB for `firstname_counts`, 10.54 MiB for
`firstname_matches`, and **1,465.01 MiB** for the final author-level file.

### Validation and re-running

The script regression-tests ordinary, inverted, fallback, initial-only and non-Latin names before
touching production output. It then asserts input schemas, unique author grain, the year/STEM filter,
source-field preservation, the established 48,539-token IBGE contract, name-level/author-level
reconciliation, score range and exact NULL semantics. Outputs are built as `.partial` files and the
large author products use rollback-safe promotion.

The expensive `eligible_authors.parquet` is reused only when its schema, row count and source
snapshot date match. `firstname_counts.parquet` additionally carries a cleaning-version marker.
Name matches and the final score file rebuild on each run, so changing the prior cannot silently
reuse stale scores. To change the source snapshot or parsing precedence, remove the corresponding
cache deliberately; an incompatible cache aborts rather than overwriting itself.

Resource overrides are `OPENALEX_BR_NAME_DUCKDB_MEMORY_LIMIT`,
`OPENALEX_BR_NAME_DUCKDB_MAX_TEMP`, `OPENALEX_BR_NAME_DUCKDB_THREADS`, and
`OPENALEX_BR_NAME_DUCKDB_TMP`; defaults are 16 GB, 50 GB and eight threads, matching the measured
production run. `OPENALEX_BR_NAME_AUTHOR_GLOB` is the small-data test hook.

Run locally with:

```powershell
Rscript prep/building_external_data/openalex_author_stem_2017plus_br_name_scores.R
```

## Union of affiliation- and name-selected OpenAlex authors

`openalex_author_br_institution_or_name_stem_2017plus.R` is stage 5f. It is a local, offline
pipeline over the completed 5d/5e products and the already-downloaded works snapshot. It does not
contact OpenAlex or download anything. The raw history rebuild reads the 2,446 parquet parts already
stored on the SanDisk SSD at `D:/OpenAlex/works` (675.18 GiB).

The two admission routes are deliberately independent:

```sql
-- affiliation arm: every author already present in stage 5d
SELECT author_id FROM openalex_author_br_stem_2017plus_institutions
UNION ALL
-- name arm: the strict requested threshold, not >=
SELECT author_id FROM openalex_author_stem_2017plus_br_name_scores
WHERE p_brazil > 0.5
```

The `UNION ALL` is reduced by `author_id` immediately afterwards. The current inputs contain
843,232 affiliation-arm authors and 197,133 name-arm authors, with 79,850 in both. The deduplicated
union is therefore **960,515 unique authors**: 763,382 affiliation-only, 79,850 in both arms, and
117,283 name-only. No current score is exactly 0.5, so `>` and `>=` happen to produce the same count;
the implementation nevertheless stores and validates the strict rule. The cutoff applies only to
the name arm. An affiliation-selected author remains present with a low or NULL name score.

The cheap seven-column union is retained as
`openalex_author_br_institution_or_name_stem_2017plus_cohort.parquet`. Stage 5f then calls the
resumable stage-5d extractor with that union as its target and writes the ten-column checkpoint
`openalex_author_br_institution_or_name_stem_2017plus_institutions.parquet`. Histories are rebuilt
over the full union rather than splicing 117,283 independently derived histories into the old
file: institution names and countries are modal metadata over the selected cohort, so splicing
could give the same institution two representations. Authors genuinely lacking a normalized
institution remain in the result with the aligned literal `NA` in all three history fields.

The final 29-column parquet is
`openalex_author_br_institution_or_name_stem_2017plus.parquet`. It contains the identity and source
fields, `br_name = coalesce(p_brazil > 0.5, false)`, the three aligned institution histories, and
all stage-5e parsing, IBGE, ratio, prior, and score evidence. Every row satisfies:

```text
ever_stem AND first_publication_year >= 2017
AND (ever_br_institution OR br_name)
```

Both source files and the final file are asserted unique on `author_id`; all overlapping identity
and provenance fields must agree. The script also checks the exact arm counts, strict cutoff, score
formula and NULL semantics, history-token alignment, and the 29-column type contract. Its union
and final writes use `.partial`/`.previous` promotion. The history scan uses five-part checkpoints
and 64 author buckets; the cache name contains the union's row count and author-ID fingerprint, so
checkpoints from a different membership set cannot be reused silently. The stage-5d extractor now
accepts output, expected-count, Brazil-requirement and cache-version overrides for this controlled
reuse; its defaults preserve the original 843,232-author behavior.

The regression fixture is under `OBMEP/test/openalex_br_or_name_union`. It covers affiliation-only,
name-only and overlapping membership, a score exactly equal to 0.5, a future-dated author, an
author without a normalized institution, and a literal pipe in an institution name.

### Measured production result — 2026-09-02

The promoted final parquet contains **960,515 rows and 960,515 unique author IDs**. All 843,232
affiliation-selected authors and all 197,133 strict name-arm authors are present exactly once. The
file contains 96,443 NULL name scores, all in the affiliation-only arm; `br_name` is false for those
rows. First publication ranges from 2017 through 2029. The one 2029 record comes from the name arm
and is retained because the year rule has no upper bound.

The full works pass produced **1,565,017 distinct author-institution pairs** for 874,203 authors and
32,688 distinct normalized institutions. The other **86,312 authors** remain in the final product
with aligned `NA` history tokens. There are 35 author-institution pairs with an unknown first year,
743 institutions with unknown country, and a maximum of 261 institutions on one author. All three
history strings are positionally aligned. Recomputing modal metadata over the enlarged cohort
changed the institution display-name history of six existing authors and the country history of
three; association years did not change. This is the measured reason not to splice newly scanned
histories into the old 5d file.

The production run read all 675.18 GiB from the portable SSD in 490 atomic five-file checkpoints.
It was intentionally interrupted after batch 426 and resumed successfully: the 426 committed
checkpoints were reused, the one incomplete `.partial` was rebuilt, and processing continued at
427. Active wall time across both attempts was approximately 3 hours 42 minutes. The promoted
sizes are 26.76 MiB for the seven-column union cohort, 35.11 MiB for the history checkpoint, and
**60.24 MiB** for the final 29-column parquet. No `.partial`, `.previous`, or fingerprinted scan
cache remained after successful promotion.

Run locally with the OpenAlex SSD mounted as `D:`:

```powershell
Rscript prep/building_external_data/openalex_author_br_institution_or_name_stem_2017plus.R
```

---
---

# The rsid crosswalk

Local, **online**. One Athena `UNLOAD` → S3 → external table. Not SEDAP-bound.

`rsid_openalex_br_crosswalk.R` maps Revelio's normalized school key,
`academic_individual_user_education.rsid`, to the Brazilian institutions built by script 3 and
registered by script 5.

## Why

Criterion C in the cohorts (below) matches free text the user typed:

```sql
lower(university_raw) = lower(cleaned_display_name)
```

It only fires on the exact spelling. Someone who typed `USP` or `Universidade de São Paulo - USP`
fails it, even though Revelio has already resolved that row to the same `rsid` as the person who
typed the name in full. Publishing the matched pair **together with its rsid** makes that
propagation available.

```
openalex_institutions_br                (1,947 rows, from script 5)
academic_individual_user_education      (aggregated once, 58.50 GB scanned)

rsid_openalex_br_crosswalk.R
    uploads s3://revelio-misc/exports/rsid_openalex_br/
    registers revelio_database.rsid_openalex_br            5,446 rows, 725 rsid
    writes   OBMEP/.../revelio_br_cohort/rsid_openalex_br.parquet   189 KB
```

**Grain: (rsid, university_raw, openalex_id)**, asserted unique. 5,446 rows, 725 distinct `rsid`,
567 distinct `openalex_id`. The match rule is *identical* to criterion C — `lower()` on both sides,
accents and punctuation still significant, `cleaned_display_name` rather than `display_name` — so
the crosswalk is a strict superset of what C already finds, never a different definition of it.

All 1,947 OpenAlex rows are eligible, not just `type = 'education'`. That is what keeps
`Estácio (Brazil)` — typed `company`, with no `education` record of its own — in the mapping, and it
is the single largest legitimate match in the table.

## Never consume bare rsid membership

**This is the finding, and it is the reason the table stores counts.** A single education row is
enough to poison an rsid:

| Revelio `university_name` | matched `university_raw` | rows behind it | rsid total |
|---|---|---|---|
| Harvard University | Universidade Federal do Rio de Janeiro | **1** | 562,968 |
| University of Phoenix-Arizona | Universidade Nove de Julho | **1** | 1,109,267 |
| University of Delhi | Microsoft → `Microsoft (Brazil)` | **1** | 1,010,664 |
| Stanford University | Universidade Federal de Santa Catarina | **1** | 342,293 |

One person whose Revelio `rsid` is Harvard typed a Brazilian university name, and `rsid IN (...)`
then admits all of Harvard. The same mechanism drags in Buenos Aires, Toronto, UNAM, Cambridge,
Penn State, Arizona State and Berkeley.

So the 725 matched rsids reach **62,348,045** education rows of which only **10,034,240** carry
`university_country = 'Brazil'`.

### `match_share` is the statistic that separates them

Not a stored column — a pure function of the published ones, so any consumer can compute it and
script 6 prints the band table on every run:

```sql
match_share = sum(n_rows) over the rsid's rows / rsid_n_rows
```

| band | rsids | education rows reached | of which `country = 'Brazil'` |
|---|---|---|---|
| **≥ 0.5** | **234** | **12,343,509** | 8,546,212 |
| 0.1 – 0.5 | 94 | 2,476,119 | 1,031,635 |
| 0.01 – 0.1 | 60 | 2,294,125 | 13,964 |
| 0.001 – 0.01 | 48 | 2,552,648 | 340,120 |
| < 0.001 | 289 | 42,681,644 | 102,309 |

The bottom band is Harvard and friends. At **≥ 0.5** the mapping is right where it matters —
Estácio→Estácio, Paulista→Universidade Paulista, USP→USP, UNICAMP→UNICAMP, UFRJ→UFRJ, UERJ→UERJ,
FGV→FGV — and it still reaches ~1.1M education rows more than the string match alone (11,209,101).

### Do **not** filter on the Brazil share instead

`rsid_n_rows_br / rsid_n_rows` is near zero for institutions that are beyond any doubt Brazilian:

| rsid | institution | Brazil share |
|---|---|---|
| 53433 | Fundação Getulio Vargas | 0.0011 |
| 138707 | Universidade Federal do Rio Grande do Sul | 0.0006 |
| 43135 | Centro Universitário Una | 0.0003 |

Those rows carry a NULL or non-Brazil `university_country` — **which is the exact gap criterion C
exists to close**. Filtering on the Brazil share would discard the rows this step is meant to
recover. It is stored for diagnosis, not for cutting.

One consequence for reading that column: `rsid_n_rows` counts *all* the rsid's rows, including the
many with a NULL country, so the share is diluted rather than wrong. `rsid_top_country` is computed
over non-NULL countries only and is the better country read.

## Columns

`rsid`, `university_raw`, `university_name`, `openalex_id`, `openalex_display_name`,
`openalex_cleaned_display_name`, `openalex_type`, `openalex_works_count`, `ultimate_parent_rsid`,
`ultimate_parent_school_name`, `n_rows`, `n_rows_br`, `rsid_n_rows`, `rsid_n_rows_br`,
`rsid_n_raw`, `rsid_top_country`, `rsid_top_country_n`, `rsid_n_countries`, `rsid_name_constant`,
`rsid_parent_constant`.

- **`n_rows` / `n_rows_br`** are for the (rsid, university_raw) pair; the **`rsid_*`** ones are for
  the whole rsid, matched raw strings and unmatched alike. That asymmetry is deliberate: the
  unmatched rows are precisely the ones a widened criterion would newly admit, so they belong in the
  denominator.
- **`rsid_name_constant` / `rsid_parent_constant`** are 1 on all 725 rsids: `university_name` and
  `ultimate_parent_rsid` never vary within an rsid in this snapshot. They are flags rather than
  assertions because the key is `rsid` and the name is only an attribute.
- **`ultimate_parent_rsid` is carried but unused.** Revelio also resolves campuses to a parent
  school, so a wider propagation (matched rsid → its parent → every sibling campus) is available for
  free. It is deliberately not applied: it is a different criterion and needs its own measurement.

## Fan-out on `openalex_id` is expected

The grain allows one (rsid, university_raw) to reach several `openalex_id`s, and that is not an
error: OpenAlex ships 4 pre-existing duplicate-name groups — distinct ids sharing a name, e.g.
`Hospital de Base` in Brasília and in São José do Rio Preto. That is the whole of it: **1,947 records
→ 1,947 distinct ids → 1,943 distinct `cleaned_display_name` → 1,943 distinct `lower()` → 1,943
distinct accent-folded `lower()`**, measured 2026-09-04. Neither lowercasing nor folding collapses a
single additional name, so the number of ambiguous names is **4, not 8** — 1,947 → 1,943 *is* the
four native groups, and counting a further four for `lower()` double-counts them.

**Do not dedupe by keeping the largest `works_count`**; that silently picks a city. To read one
institution per rsid, rank by the matched row count:

```sql
row_number() OVER (PARTITION BY rsid ORDER BY sum(n_rows) DESC, openalex_id)
```

Aggregating with `max(openalex_display_name)` instead — alphabetically last — reads as if USP
mapped to `Universidade do Vale do Paraíba`. It does not; that is an artefact of aggregating a
table whose grain is finer than `rsid`.

## Cost and re-running

**58.50 GB scanned (~$0.29), 15.6 s of execution** for the one `UNLOAD`. That is four times the
README's "~16 GB for a full-column diagnostic over the education table" — that figure was a
*filtered* query and is not a guide for a full `GROUP BY`. Everything in the script's report step
reads the finished 5,446-row table instead of the source, so re-reporting costs nothing.

Guards match the cohort scripts: the destination prefix must be empty, `exp_rows = 5446` and
`exp_rsids = 725` warn on drift, and every structural check is a `stop()` — a clean exit is the pass
condition. Rebuilding needs `DROP TABLE` **and** clearing the S3 prefix first.

## Downstream use

**None.** Criterion C_rsid, which this table was built for, was measured and **withdrawn** on
2026-08-25: propagating a match from one education row to an entire school admitted 7,645,023 members
at 0.1% located in Brazil, and even at its safest threshold it added 12,023 at 6.3%. The replacement,
C_norm, works on the string instead and is documented under
[C_norm, and the rsid branch that was withdrawn](#c_norm-and-the-rsid-branch-that-was-withdrawn).

The table is kept because it is a correct, self-validating artifact and the analysis that killed the
criterion lives in it: `n_rows` and `rsid_n_rows` are what expose the single-row matches, and
`university_name` is what shows that the biggest matched rsids are Phoenix, Delhi, Buenos Aires and
Harvard. Anything reading it should apply a `match_share` floor, and should not be used to admit
cohort members.

---
---

# OBMEP candidate cohorts

Local, **online** pipeline: every stage reads from and writes to Athena. Not SEDAP-bound.

The goal is a pool of Revelio `user_id`s that are plausibly Brazilian *and* young enough for OBMEP
exposure. "Young enough" is two date criteria, identical in both cohorts; the cohorts differ only in
which Brazil signal admits a user.

## Flow

```
openalex_institutions_br_to_s3.R           (uploads the list built by openalex_br_institutions.R)
    reads  OBMEP/.../openalex_institutions/openalex_institutions_br.parquet   1,947 rows
    uploads s3://revelio-misc/openalex_institutions_br/
    registers revelio_database.openalex_institutions_br

br_degree_patterns.R                       (constants only — sourced by the two below)

revelio_br_cohort_user_ids.R               (A_country OR B OR C_norm) AND D AND E
    -> revelio_database.obmep_br_cohort_user_ids            5,736,020   (was 5,730,315)

revelio_br_name_cohort_user_ids.R          A_name AND D AND E
    -> revelio_database.obmep_br_name_cohort_user_ids       3,779,509   (unchanged, by design)

obmep_candidates_step_1.R                  union of the two, deduplicated on user_id
    -> revelio_database.obmep_candidates_step_1             6,849,674   (was 6,845,775)
         country-cohort only  3,070,165
         in both              2,665,855
         name-cohort only     1,113,654
```

## The criteria

| | Criterion | Source |
|---|---|---|
| **A_country** | any position with `country = 'Brazil'` | `academic_individual_position` |
| **A_name** | `user_id` in `linkedin_br_name_flag` with `p_brazil > 0.5` | crosswalk from script 2 |
| **B** | any education row with `university_country = 'Brazil'` | `academic_individual_user_education` |
| **C_norm** | `university_raw`, or any `/`, `-`, `( )` segment of it, equals a `cleaned_display_name` from `openalex_institutions_br` with accents folded | education × script 5 |
| **D** | earliest position `startdate` exists and its year `>= 2007` | position |
| **E** | earliest bachelor `startdate` exists and its year `>= 2007` | education |

`obmep_br_cohort_user_ids` is `(A_country OR B OR C_norm) AND D AND E`.
`obmep_br_name_cohort_user_ids` is `A_name AND D AND E` — B and C_norm are computed and stored there
but do **not** filter.

**Both forms of the institution match are stored.** `br_openalex` is the old exact comparison and
`br_openalex_norm` the widened one, so the pre-C_norm cohort is recoverable in place. C_norm sets the
flag on 20.4% more members but adds only 5,705 to the cohort — see
*[C_norm, and the rsid branch that was withdrawn](#c_norm-and-the-rsid-branch-that-was-withdrawn)*,
which is also the record of a propagation branch that was tried here and removed.

**D and E are strict.** No position, no bachelor, or only unparseable dates in either, means
excluded. The `INNER JOIN` between the two aggregate subqueries is what enforces it — switching it to
a `LEFT JOIN` changes the definition of the cohort, not just its performance.

**Criterion C matches case-insensitively but not accent-insensitively.** The OpenAlex scripts never
fold accents and their assertions depend on that, so folding happens at query time via `lower()`
only. `cleaned_display_name` rather than `display_name` because it is the de-parenthesised form —
`Universidade Estadual de Campinas` rather than `... (UNICAMP)` — which is closer to what people type
on LinkedIn. Both columns are in the table, so widening the match later needs no re-upload.

## C_norm, and the rsid branch that was withdrawn

Criterion C used to be an exact, accent-**sensitive**, whole-string comparison. C_norm widens it in
two ways and nothing else:

- **accents are folded** at query time — `regexp_replace(normalize(s, NFD), '\p{M}', '')`, since
  Trino has no `strip_accents()`;
- the match may land on any **segment** of `university_raw` delimited by `/`, `-` or `( )`, not only
  on the whole string.

The whole-string arm still accepts any record type; the segment arm accepts only `education` records.

### Why: bare acronyms were never the problem

The obvious hypothesis is that people type `USP`. They mostly do not — bare acronyms are **1.5–2.5%**
of an institution's rows (USP 1.5%, FGV 2.5%, UNICAMP 2.3%). What criterion C actually missed was the
full name *decorated* with its acronym:

| `university_raw` on USP's school | rows | old C |
|---|---|---|
| `Universidade de São Paulo` | 374,136 | matches |
| `USP - Universidade de São Paulo` | 29,840 | no |
| `Universidade de São Paulo / USP` | 23,237 | no |
| `USP` | 7,335 | no |
| `Universidade de São Paulo (USP)` | 1,810 | no |
| `Fundação Get**ú**lio Vargas` — the correct spelling | 21,187 | no; OpenAlex stores `Getulio` |

At institution level C_norm lifts coverage from 76.1% to 93.8% of FGV's education rows, 77.7% to
90.1% for USP, 78.9% to 92.9% for UNICAMP. Accent folding is worth ~3.4pp on FGV and ~0 on the other
two, so **segment splitting is nearly the whole effect**.

### The segment arm is restricted to `education` records, deliberately

The Brazilian institution list holds short **company** names — `IBM`, `AES`, `Vale`, `Intel`,
`Shell`, `Eaton`, `Nestlé`, `Sanofi`, `TOTVS`, `Folha` — and an entry reading `Curso de Inglês -
Intel` would otherwise match one. A name-**length** filter is not a substitute: `Insper` is six
characters and a real `education` record.

Measured, the excluded bucket is **11,091 education rows** and is itself mixed —
`British Council - Sri Lanka`, `The University of Texas at El Paso (UTEP)` and
`Eaton (City of Norwich) School` sit in it, but so do `Inteli`, `IBCCRIM` and `IBEU`. It is small
enough that the choice barely matters; the restriction is kept because it is the principled one.

The **whole-string** arm still accepts any type, which is what keeps Estácio — a `company` record
with 7,237 works and no `education` record of its own. That also means it still matches
`British Council` exactly, as criterion C always has. **That defect predates all of this** and is
untouched here.

### Measured

| | |
|---|---|
| members carrying the flag: C exact → C_norm | 2,862,213 → **3,446,186** (+20.4%) |
| cohort: `(A OR B OR C)` → `(A OR B OR C_norm)` | 5,730,315 → **5,736,020** |
| **members admitted by C_norm and nothing else** | **5,705** |
| those members located in Brazil | **32.5%** |

The flag moves 20 times more than membership does, and that is the important lesson: **almost
everyone C_norm newly matches was already admitted by A or B.** A row-level or match-level gain is
not a cohort gain. Criteria D and E do most of the filtering, and the people C_norm reaches fail them
at a much higher rate than the population already in the pool.

For scale, 32.5% is the **best precision of any education-only signal here**:

| admitted by | users | `user_country = 'Brazil'` |
|---|---|---|
| A — worked in Brazil | 5,671,650 | 95.5% |
| B — `university_country` = BR, no A | 38,782 | 26.7% |
| C — exact name match, no A/B | 19,883 | 10.3% |
| **C_norm — no A/B/C** | **5,705** | **32.5%** |
| name prior only | 1,113,654 | 0.5% |

**Do not read these against A's 95.5%.** Someone admitted for *working* in Brazil is nearly
guaranteed to be located there; someone admitted for *studying* in Brazil and since emigrated is not,
and that population is part of what this project is looking for.

### The rsid branch, and why it is gone

Between the exact match and C_norm, a different fix was tried: propagate a match through Revelio's
normalized school key, `rsid`. **It was built, measured and withdrawn**, and the crosswalk it used
survives as [script 6](#the-rsid-crosswalk) with nothing consuming it.

It failed because membership propagated from **one** education row to an entire school. Somebody
whose `rsid` is Harvard typed `Universidade Federal do Rio de Janeiro` — 1 row out of 562,968 — and
that admitted all of Harvard. University of Phoenix, Delhi (via `Microsoft` → `Microsoft (Brazil)`),
Stanford, Cambridge, Toronto, UNAM and Berkeley entered the same way. Across the crosswalk, 2,231 of
5,441 matched pairs rested on a single row: 0.02% of the matching evidence, controlling 73% of the
branch's reach.

| | cohort | admitted by the branch alone | of those, in Brazil |
|---|---|---|---|
| no `match_share` cut | 13,375,338 | 7,645,023 | **0.1%** |
| `match_share >= 0.5` | 5,742,338 | 12,023 | 6.3% |
| **C_norm instead** | **5,736,020** | **5,705** | **32.5%** |

Revelio is not at fault: Harvard's rsid holds 4,496 distinct raw strings and three of them are wrong,
an error rate of 0.07%. The criterion was at fault, because it amplified any non-zero error rate into
total contamination of a 562,968-row bucket. C_norm attacks the same variant-spelling problem at the
string, where it cannot amplify.

### Recovering the earlier definition

`br_openalex` still stores the **exact** match beside `br_openalex_norm`, so the pre-C_norm cohort is
reproducible in place with no re-scan:

```sql
-- exactly the old (A OR B OR C) cohort, 5,730,315 rows
WHERE br_position = 1 OR br_educ_country = 1 OR br_openalex = 1
```

Widening further — dropping the `education` restriction on the segment arm, say — needs a rebuild.

## The alternative cohort: the rsid branch, gated on where the school's people are

*Scripts 8a `rsid_br_user_share.R`, 8b `revelio_br_cohort_user_ids_alt.R`, 10alt
`obmep_candidates_step_1_alt.R`. Local, **online**, three `UNLOAD`s → S3 → external tables.*

**Nothing above this heading changes.** `obmep_br_cohort_user_ids`,
`obmep_br_name_cohort_user_ids` and `obmep_candidates_step_1` are untouched, and so is every stage
downstream of them. This is a parallel chain that ends in `_alt` tables, built to answer one
question: does the rsid propagation become usable if the *gate* is changed?

The withdrawn branch was cut with `match_share` — the share of an rsid's own education **rows** whose
raw string matched. The alternative cuts on a different statistic entirely:

> **`br_share_known`** — of the rsid's distinct **users** whose `academic_individual_user.user_country`
> is known, the share located in Brazil. Keep the rsid when it is above 0.5.

### This is not the Brazil share the README forbids

*[Do not filter on the Brazil share instead](#do-not-filter-on-the-brazil-share-instead)* rejects
`rsid_n_rows_br / rsid_n_rows`, and that warning stands. But it is a statement about a different
quantity — the share of **education rows** carrying `university_country = 'Brazil'`, which is near
zero for FGV (0.0011), UFRGS (0.0006) and Centro Universitário Una (0.0003) precisely because a NULL
or non-Brazil `university_country` **is the gap criterion C exists to close**. Filtering on it would
throw away the rows the criterion is meant to recover.

`br_share_known` is a property of the *people*, not of the education row's own country field. It is
high for USP and FGV and low for Harvard and Phoenix, which is the discrimination `match_share`
never had. The two must not be collapsed in a later edit.

### Two denominators, and why the cut uses the narrower one

Both travel in the table and only one is used:

```
br_share_known = rsid_n_users_br / rsid_n_users_known     <- the cut
br_share_all   = rsid_n_users_br / rsid_n_users           <- diagnosis only
```

The reasoning for the narrower one: if `user_country` were missing on a real share of profiles,
dividing by *every* user would sink an unmistakably Brazilian rsid purely on coverage — the same
dilution mechanism that makes the education-row share unusable. An rsid with no known country at all
gets a NULL share, fails `> 0.5`, and is rejected; that is the conservative direction and it is
deliberate.

**Measured, the precaution turns out to be inert.** `user_country` is populated on **99.79%** of the
63,364,054 users under the matched rsids, no rsid has it on under 90% of its users, and **0 of 975
rsids change their keep/reject decision** under `br_share_all`. So the denominator choice is not
load-bearing on this snapshot. Both columns still travel in the table — coverage could degrade on a
later Revelio refresh, and then it would start to matter — so neither should be simplified away.

The same run answers the sentinel question the design worried about: the modal known country of all
975 matched rsids is an ordinary country name (Brazil 675, United States 79, United Kingdom 21, …).
No third value is masquerading as missing, so the `('', 'empty')` guard fires on nothing here. It
stays, because the position table proves the convention exists in this schema.

### The criteria

| | Criterion | Definition | Column | Filters? |
|---|---|---|---|---|
| A | position in Brazil | `country = 'Brazil'` on some position | `br_position` | yes |
| B | Brazilian university country | `university_country = 'Brazil'` on some education row | `br_educ_country` | yes |
| C | exact institution name | unchanged from script 8 | `br_openalex` | no — stored |
| C_norm | normalised institution name | unchanged from script 8 | `br_openalex_norm` | yes |
| **C_rsid** | C propagated through a surviving rsid | **new** | `br_openalex_rsid` | no — stored |
| **C_norm_rsid** | C_norm propagated through a surviving rsid | **new** | `br_openalex_norm_rsid` | **yes** |
| D, E | first position / first bachelor `>= 2007` | unchanged from script 8 | `min_pos_year`, `min_bach_year` | yes |

"A surviving rsid" is one that (**G1**) has at least one `university_raw` matching C or C_norm and
(**G2**) passes `br_share_known > 0.5`. So:

```
obmep_br_cohort_user_ids_alt   (A OR B OR C_norm OR C_norm_rsid) AND D AND E
                                       5,736,020 -> 5,763,858   (+27,838, +0.49%)
obmep_candidates_step_1_alt    the above UNION the UNCHANGED name cohort
                                       6,849,674 -> 6,870,111   (+20,437, +0.30%)
                                         country-cohort only  3,090,602
                                         in both              2,673,256
                                         name-cohort only     1,106,253
```

**The pool grows by 20,437 while the cohort grows by 27,838, and the 7,401 difference is the most
interesting number in the run.** It is exactly the set of rsid-admitted members who were already in
the pool through the name cohort — `name_only` falls by the same 7,401, from 1,113,654 to 1,106,253.
Those users move from name-prior-only evidence, which is **0.5%** located in Brazil, to
institution-backed evidence. The identity is also a check: the 7,401 equal, necessarily, the
rsid-only group's `p_brazil > 0.5` count, and they did.

The matcher CTEs in 8a and 8b — `inst_fold`, `inst_exact`, `raws`, `seg`, `raw_cls` — are copied
verbatim from script 8. C and C_norm have to mean exactly what they mean in the original cohort or
the two tables are not comparable.

### Two properties that the assertions rest on

**The alt cohort is a strict superset of the original.** `C_norm` stays in the `WHERE` clause
*beside* `C_norm_rsid`, so a user whose only matched string sits under a rejected rsid is still
admitted by C_norm alone. That licenses `min_rows = 5736020` in 8b, and 8b also runs the anti-join
member by member: a superset cannot lose anybody. It is the sharpest check in the chain, because it
is what catches C_norm being *replaced* by C_norm_rsid rather than joined to it.

**`C_norm_rsid` is NOT a superset of `C_norm`, and nothing asserts that it is.** The gate can reject
an rsid that contains a genuinely matched string — that is the gate doing its job. The only
monotonicity that holds is `br_openalex_rsid = 1 ⟹ br_openalex_norm_rsid = 1`, because the surviving
exact rsids are a subset of the surviving normalised ones by construction. That one *is* asserted.

### What the gate actually did — measured 2026-09-04

24,276 matched (rsid, `university_raw`) pairs over **975** rsids. The bands are the result:

| `br_share_known` | rsids | users reached | of those in Brazil | education rows |
|---|---|---|---|---|
| **≥ 0.5 — KEPT** | **667** | **22,496,363** | **94.9%** | 25,483,075 |
| 0.1 – 0.5 | 18 | 216,610 | 20.7% | 273,351 |
| 0.01 – 0.1 | 73 | 5,021,168 | 2.7% | 5,592,060 |
| < 0.01 | 217 | 35,629,913 | **0.34%** | 40,604,214 |

The bottom band is Harvard and friends again, and it holds 56% of the raw reach on its own.
Measured shares of the institutions the withdrawn branch was poisoned by: Phoenix 0.0012, Delhi
0.0006, UNAM 0.0016, Toronto 0.0065, Berkeley 0.0076, Cambridge 0.0146, Stanford 0.0151, Harvard
0.0303 — with Harvard Law and Harvard Business rejected separately on their own rsids. Against the
survivors: USP 0.949, Estácio 0.970, Paulista 0.951, UERJ 0.933, FGV 0.910, UFRJ 0.891, UNICAMP
0.883. **Two orders of magnitude of separation**, against the ~10× that `match_share` managed.

For scale, the gate keeps 25.5M education rows where `match_share >= 0.5` kept 12.3M — roughly twice
the reach — while the rows it throws away are 0.3% Brazilian.

**An independent confirmation worth re-reading on any future run:** the exact arm reaches **725**
rsids, which is *precisely* the figure script 6 measured for the same criterion on 2026-08-24 by a
completely different query shape. That agreement is the strongest available evidence that C and
C_norm mean here what they mean in the cohort. C_norm reaches 975, i.e. 250 rsids more, and 667 of
the 975 survive the gate (495 of them also on the exact arm).

The survivors are also, pointedly, the institutions
*[How much of C_norm is missing](#how-much-of-c_norm-is-missing)* named as the biggest recall gaps:
ETEC, SENAI and SENAC units, UNINOVE, UniCesumar, Anhanguera, Pitágoras/Unopar, Estácio, Paulista.
That audit's two dominant miss causes — `no_candidate` 42.3% and `brand_acronym` 34.0% — are exactly
what a school key reaches and a string match cannot.

### The gate amplifies by design, so read the right number

A surviving rsid admits **every** user with an education row under it — foreign students at USP
included, and the minority of raw strings Revelio resolved wrongly included. That is the criterion,
not an oversight. What it means is that the number to read after a run is the one 8b prints: how many
members the rsid arm admits **alone**, and what share of them are located in Brazil, against the
benchmarks already measured on the original cohort:

| admitted by | users | in Brazil | mean `p_brazil` | `p_brazil > 0.5`, of those scored |
|---|---|---|---|---|
| A — worked in Brazil | 5,671,650 | 95.5% | 0.541 | 52.3% |
| B — `university_country`, no A | 38,782 | 26.7% | 0.485 | 44.6% |
| C — exact name, no A/B | 19,883 | 10.3% | 0.444 | 39.0% |
| C_norm only, no A/B/C | 5,705 | 32.5% | 0.506 | 47.5% |
| **C_norm_rsid only** | **27,838** | **22.5%** | **0.481** | **43.9%** |
| withdrawn C_rsid, `match_share >= 0.5` | 12,023 | 6.3% | — | — |
| name prior only *(original pool, 2026-08-25)* | 1,113,654 | 0.5% | — | — |

The first five rows are this run's own Step 5 output over the alt cohort — the A/B/C/C_norm groups
come out identical to the published figures for the original cohort, as they must, since nothing
about those criteria changed. The last two rows are the earlier measurements being judged against,
not re-measured here: the name-only group in the *alt* pool is 1,106,253, but its Brazil share was
not re-run, so the 0.5% is quoted against the count it was actually measured on.

**The criterion is adoptable.** It admits **27,838** members that `(A OR B OR C_norm)` does not —
4.9× C_norm's own contribution — at **22.5%** located in Brazil, against the withdrawn branch's
**6.3%** at less than half the volume. 22.5% is below C_norm's 32.5% and below criterion B's 26.7%,
but it is more than double criterion C's 10.3% and 45× the name-only floor. It did not reproduce the
withdrawn branch's failure.

That Brazil share is **partly circular** — the gate is built on `user_country` — so read it with the
last two columns, which come from the name prior and are independent of both the gate and the
criterion. On that independent evidence the rsid arm (mean `p_brazil` 0.481, 43.9% scoring above 0.5)
sits *inside the band of the corroborated signals*, between criterion C's 0.444 and C_norm's 0.506,
and nowhere near a contaminated population. Two readings that disagree would have been the warning;
these agree.

One caveat that belongs with the numbers: `p_brazil` is NULL for **39.5%** of the rsid-only group
against 33.3% of C_norm's and 10.6% of A's, so a larger share of them write their name in a non-Latin
alphabet. The percentages above are over the scored subset, as the column header says.

### `NULL` is not zero in the consolidated table

The name cohort was deliberately **not** rebuilt, so it does not carry the two rsid flags, and
`obmep_candidates_step_1_alt` takes them from the alt country cohort **without `coalesce`**. They are
therefore `NULL` for name-cohort-only members, meaning *never computed for this member* rather than
*computed and came out 0*. Writing 0 would assert something no run measured, which is the opposite of
the [stored-but-not-filtering](#stored-but-not-filtering-flags) convention the table exists to
uphold — `p_brazil` is already allowed to be NULL for the same reason. The script asserts the
alignment both ways: present for every `in_country_cohort = 1` row, NULL for every other.

### Recovering `openalex_id` — script 8d

8a links each accepted `university_raw` to an OpenAlex **name** (`oa_matched_name`) and not to an
`openalex_id`; the id was never propagated through that query. `rsid_openalex_id_crosswalk.R` (8d)
recovers it **offline and for free**, and needs no rebuild of the $0.53 job, because
`oa_matched_name` *is* a `cleaned_display_name` value — 8a sets it to `min(cleaned_display_name)`
inside `inst_fold`. Joining it back to `openalex_institutions_br` is therefore exact string equality
on a value that originated in the target column, not a second matcher.

```
rsid_openalex_id_crosswalk.parquet   grain (rsid, university_raw, openalex_id)
    24,288 rows over 24,276 pairs, 975 rsids, 621 institutions
```

Same grain as [script 6](#the-rsid-crosswalk), so the two read side by side — and a strict superset
in coverage, since script 6 covers criterion C only and this covers C_norm. `keep` is stored rather
than filtered on, so the 628 rejected pairs keep their ids, which is where an id is most useful:
auditing a rejection by hand.

Three measured properties worth knowing:

- **Every accepted string resolves** — 0 of 24,276 `oa_matched_name` values are missing from the
  institutions snapshot. That anti-join is also the **snapshot-drift detector**: re-running
  `openalex_br_institutions.R` against a newer OpenAlex dump without rebuilding 8a would surface a
  renamed or withdrawn institution here, and nowhere else, because a local join otherwise just drops
  the row.
- **The fan-out is 12 pairs, and it is named rather than counted.** Only two of OpenAlex's four
  duplicate-name groups are actually reached — Faculdades Nova Esperança (7 pairs) and Hospital Ana
  Nery (5) — so 24,264 of 24,276 pairs are strictly 1:1. Script 8d prints all 12 rows, and asserts
  that no pair fans out for any reason *other* than an OpenAlex duplicate name.
- **`company` is in there, and must stay.** By `openalex_type`: education 23,493 rows / 484
  institutions, then nonprofit 236, healthcare 167, **company 139**, government 93. Those 139 company
  rows carry 837,478 pair-users — the highest per-row user weight of any type — because Estácio's
  main record (`I4210131693`, 7,237 works) is typed `company` and has no `education` record of its
  own. See *[`type` is about ownership, not function](#type-is-about-ownership-not-function--and-openalex-has-no-publicprivate-flag)*.

### How much coverage the criterion actually buys — script 8e

*`rsid_coverage_audit.R`. One Athena pass, 63.88 GB (~$0.32), measured 2026-09-04.*

8e re-runs the matcher and classifies **every** education row into six buckets, so the gain has a
denominator rather than only a numerator:

| bucket | rows | % of all | distinct `university_raw` | users |
|---|---|---|---|---|
| 1 — C exact | 11,518,730 | 1.85% | — | 8,704,952 |
| 2 — C_norm only | 2,993,645 | 0.48% | — | 2,559,839 |
| **3 — NEW, rsid arm** | **11,735,533** | **1.88%** | **213,365** | 8,696,509 |
| 4 — no match, school **rejected** by the gate | 46,821,567 | 7.51% | 296,780 | 38,112,058 |
| 5 — no match, school never matched anything | 382,172,430 | 61.27% | 4,083,450 | 248,133,900 |
| 6 — no match, **no `rsid`** | 168,503,764 | 27.01% | 61,537,213 | 119,440,555 |

623,745,669 education rows in total. On rows that *have* a `university_raw`:

```
covered by C / C_norm before   14,512,375
NEWLY covered by the rsid arm  11,679,825      total coverage 1.80x
```

**In the units the question is usually asked in — distinct `university_raw` — the gain is 9.5×:**
**213,365** strings newly covered against the **22,566** the string match reached.

And the strings it recovers are exactly the ones
*[How much of C_norm is missing](#how-much-of-c_norm-is-missing)* named as the dominant miss causes
(`brand_acronym` 34.0%, `no_candidate` 42.3%). The top of bucket 3, by rows:

| `university_raw` | rows |
|---|---|
| `Anhanguera Educacional` | 683,744 |
| `UNINOVE` | 418,705 |
| `UNINTER Centro Universitário Internacional` | 340,199 |
| `Universidade Anhembi Morumbi` | 337,288 |
| `UNIASSELVI` | 294,512 |
| `UniCesumar` | 259,731 |
| `ETEC - Escola Técnica Estadual de São Paulo` | 222,160 |
| `Senac Brasil` / `Senai São Paulo` | 208,380 / 205,031 |

#### Two numbers not to quote, and why

**"1.9% of previously uncovered rows are now covered" is true and meaningless.** That denominator is
buckets 4+5+6 = 595 million rows, of which bucket 5 is 61.3% and bucket 6 is 27.0% — the education
records of the rest of the world, schools no Brazilian institution name reaches and rows with no
school key at all. No Brazilian criterion should cover them; the ratio measures the size of the
planet. The honest figures are the 1.80× above, the 9.5× on distinct strings, and 54.2% → 100% within
the 667 schools the criterion reaches.

**Bucket 3 contains 55,701 rows with no `university_raw` at all** and they are excluded from every
figure here. A NULL string cannot match either arm, so it falls through to bucket 3 whenever its
school survived — but it is not an uncovered *string*. Folding them in was the first version's
error, and `exp_bucket3_rows` is what caught it: bucket 3 came out exactly 55,701 rows above the
offline subtraction from the gate table, which had required `university_raw IS NOT NULL`.
`bucket3 − null_rows` reconciles to **11,679,832** to the row.

Two things bucket 4 and 5 say about where to go next. **Bucket 4 is the gate's deliberate cost**:
46.4M rows over 296,780 strings sit under the 308 rejected schools, reachable but thrown away —
correctly, since those schools run 0.34% Brazilian by user location. **Bucket 5's 4.08M distinct
strings are the institution-list problem**, not a matching problem, and only a better list (the
Censo da Educação Superior) reaches them.

#### How much of the gain carries a usable OpenAlex id

Joining 8d's `dom_openalex_id` and `dom_share`:

| `dom_share` | schools | newly covered rows | |
|---|---|---|---|
| ≥ 99% | 531 | 5,021,151 | 42.8% |
| 90–99% | 41 | 1,833,803 | 15.6% |
| 75–90% | 26 | 2,047,247 | 17.4% |
| 50–75% | 30 | 1,324,229 | 11.3% |
| **< 50%** | **21** | **1,509,103** | **12.9%** |

Weighted mean 81.4%. The bottom band is written to
`revelio_br_cohort/rsid_dom_id_class.csv` as a 21-row hand-review template, because it is the one
judgement this audit cannot make automatically — see
[Recovering `openalex_id`](#recovering-openalex_id--script-8d) note 9 for why the automatic
name-plausibility rule was rejected. The largest of them is
`SENAI Faculty of Technology of São Paulo`: 17 ids, `dom_share` 0.10, 383,888 newly covered rows.

### Making the rsid → OpenAlex map safe — script 8f

8d publishes the honest raw mapping, and it is **not one-to-one**: 305 of the 667 surviving rsids
reach more than one `openalex_id`, up to 95 on FGV. `rsid_openalex_one_to_one.R` decides per rsid
whether that key can stand for a single institution, and publishes the subset that can.

**Why it matters, measured.** A direct "flag if this rsid's OpenAlex id is in list X" is **20.5% wrong
on Shanghai and 22.5% wrong on RUF**, weighted by the rows such a flag would touch. The failure is the
Harvard mechanism in both directions: for RUF the sinks are foreign giants (Harvard 562,968 rows on
**3** matched, Berkeley 538,506 on 2, Cambridge 513,118 on 4); for Shanghai they are Brazilian giants
(Estácio 378,394 on 9, Anhanguera 260,598 on 2, FGV 144,707 on 16).

**A two-sided floor does most of the work.** A stray link counts only if it carries ≥ 5 rows **and**
≥ 1% of the rsid's matched rows. Both are needed: FGV has 94 stray ids over 666 rows — 0.09% of its
701,099, all noise — while IFSP has 34 strays over 1,923 rows, **75%** of its 2,546, all real. The
floor cuts **1,692 stray links to 73**, over 42 rsids, clearing 1,619 links with no judgement at all.

**Five verdicts, because the data has five cases:**

| verdict | rsids | meaning |
|---|---|---|
| `ONE_TO_ONE` | 641 | dominant id correct, strays immaterial |
| `AFFILIATE` | 12 | parent/child — a teaching hospital and its medical school (Sírio-Libanês, Santa Casa, Santa Marcelina), ESALQ under USP, EAESP under FGV |
| `OA_DUPLICATE` | 2 | the same institution under two OpenAlex ids — `Faculdade São Lucas` ↔ `Centro Universitário São Lucas`, `Jaraguá do Sul` ↔ `Católica de Santa Catarina` |
| `FAMILY` | 7 | genuinely distinct institutions pooled — **the Instituto Federal network is the whole story**, plus FMU, Unama and the Wyden group |
| `WRONG_DOM` | 5 | the dominant id is itself wrong — AGU Law School → ENAP, Dante → Leonardo da Vinci, UNG → Caratinga |

**655 of 667 rsids are safe (98.2%, 99.9% of matched rows).** The excluded 12 are small in volume but
are exactly where an id-keyed flag would be systematically wrong. IFSP's dominant id is **Petrobras**.

**What it buys, honestly stated.** On RUF the flag goes **22.5% → 4.11%** — and that drop comes from
the *gate*, not from these verdicts: none of the RUF-dominant rsids were excluded by them. Adding an
evidence floor of 25 matched rows takes it to **0.94%**. The verdicts' value is elsewhere: they
exclude the cases where the id is provably wrong or unassignable, which is what bites any broader or
global id-keyed flag rather than RUF's 23 Brazilian institutions.

**`dom_share` and the evidence floor guard different failures and both are required.** `dom_share`
catches the family case; it is blind to thin evidence, because one stray matched row gives
`dom_share = 1.0` by arithmetic. Measured on RUF, **35 of the 75 rsids passing `dom_share ≥ 0.90` rest
on a single matched row** and carry 5.65M of the 9.67M rows they would flag — UNAM, UCLA, Stanford,
RMIT, Montreal. That is the folder's original `match_share` returning under another name.

**The verdicts are LLM-written**, the same conflict of interest `shanghai_flag_audit.R` records for
its own gabarito. `rsid_oa_link_class.csv` is editable and every row carries `source`; the labels are
parked on disk, so unlike the Shanghai recall sample the result is reproducible.

### Rebuilding the degree flags on the safe map — script 8g

`rd_` (script 20) and `sh_` (script 16) match folded **names**. 8g adds the arm neither had —
Revelio's school key, through the one-to-one-safe map — without modifying either script or its output.

**The two lists are not equally served, and the asymmetry is structural.** The safe map is built from
`openalex_institutions_br`, so it reaches Brazilian institutions only:

| list | ranked institutions in the safe map | verdict |
|---|---|---|
| **RUF** | **23 of 23** (31 rsids after the evidence floor) | complete rebuild |
| **Shanghai** | **18 of 1,079 — 1.7%** (25 rsids) | **Brazilian slice only** |

The 18 are USP, Unesp, UFMG, UFRGS, Unicamp, UFRJ, Unifesp, UFSC, UFPR, UnB, UFSM, UFV, UFF, UFSCar,
UFC, UFPE, UFG, UFPel. The other 1,061 are not Brazilian, are absent from the institution list by
construction, and cannot be reached this way at all. **`sh_rsid_any` is not a rebuilt Shanghai flag**;
Harvard, MIT and Cambridge are untouched by it.

**Measured gain** (evidence floor `rsid_matched_rows >= 25`):

| | existing | rsid arm | **new users** | name-only |
|---|---|---|---|---|
| RUF `rd_` | 583,570 | 632,464 | **+62,735 (+10.8%)** | 13,374 |
| Shanghai `sh_` (BR slice) | 990,937 | 601,648 | **+25,855 (+2.6%)** | 415,144 |

The arm does **not** subsume the name arm — 13,374 RUF users are reachable by name and not by key — so
the union is the right flag and the two are kept side by side.

What it recovers is the faculty-and-variant class the name match structurally cannot reach:
`UNESP - Universidade Estadual Paulista "Júlio de Mesquita Filho"` (26,569 users), `Escola Politécnica
da USP` (6,639), `FEA da USP` (2,594), `ESALQ` (2,158), `Federal University of Technology - Parana`
(1,088), `Centro Universitário da FEI` (900), `UFSCar - Alumni` (849).

**Two guards, and one error class that survives both.** A row whose own string matched a *different*
institution is excluded (467 users). What that cannot catch is a string matching **nothing**, under a
good rsid, denoting another institution: `FAC UNICAMPS - Faculdade Unida de Campinas` (Goiânia)
attributed to Unicamp, **671 users, ~1% of the RUF gain**. There is no competing match to compare
against, so this is the price of the coverage the arm buys.

**A diagnostic warning worth more than the number.** The first plausibility check joined newly flagged
users to *all* their education rows and appeared to show Unesp pulling in `ETEC`, `MBA USP/Esalq` and
`Fundação Getulio Vargas`. All three were artefacts — those users hold those strings on other rows,
and their Unesp flag came from a legitimate Unesp row. **Restrict the check to the rows that actually
trigger the flag, joining through the rsid and not through the user**, or it will manufacture errors.

### Cost and re-running

Measured on the first full run, 2026-09-04:

| stage | scanned | cost | engine time |
|---|---|---|---|
| 8a `rsid_br_user_share` | **106.55 GB** | **$0.53** | 44 s |
| 8b `obmep_br_cohort_user_ids_alt` — `UNLOAD` | **90.17 GB** | **$0.45** | 58 s |
| 8b — the Step 5 precision report | 7.73 GB | $0.04 | 3 s |
| 10alt `obmep_candidates_step_1_alt` | 1.77 GB | $0.009 | — |
| 8e `rsid_coverage_audit` | 63.88 GB + ~5.6 GB of follow-ups | $0.32 + $0.03 | 29 s |
| **total** | **206.4 GB** | **$1.03** | |

Two of those beat their estimates badly and the estimates were mine, so they are recorded rather than
quietly corrected. 8a was predicted at $0.27–0.35: the education id and raw-string columns are a
larger share of that table than assumed. **8b's 90.17 GB is about twice the ~36–48 GB this README
publishes for the original cohort**, and that gap is *not* explained — the only deliberate additions
are the `rsid` column, on a projection already being read, and a join against a few-thousand-row
table, neither of which plausibly doubles a scan. The published cohort figure may predate a Revelio
refresh. Do not quote it for 8b.

Note also that 8b's precision report is not free: it reads `academic_individual_user` and
`linkedin_br_name_flag`.

8a is the expensive stage and it is paid **once**: 8b joins its few-thousand-row output rather than
re-deriving the per-rsid statistics, so the threshold can be re-tuned for the price of 8b alone. The
reason 8a costs what it does is that Trino **inlines** a CTE rather than materialising it, so `base`
being referenced twice is two scans; script 6, the same shape, measured 58.50 GB for two references
over six columns.

`rsid_br_user_share` is deliberately **not** built on top of script 6's `rsid_openalex_br`: that
table carries the exact arm only, never C_norm, its statistics are education-row based rather than
user based, and it is a snapshot from 2026-08-24.

Guards match every other stage — destination prefix must be empty, `exp_rows` NA on the first run
and pinned immediately after, every structural check a `stop()`. Two extra guards are specific to
this chain: 8b aborts if `rsid_br_user_share` is empty **or if no rsid survives the gate**, because
either would make the new disjunct vanish and 8b would silently reproduce the original cohort under a
different name while passing every other check. Rebuilding needs `DROP TABLE` **and** a cleared S3
prefix for each of the three tables, in dependency order.

### Reading it

The rejected pairs are written to
`OBMEP/Data/intermediate/revelio_br_cohort/rsid_br_user_share_rejected.csv` — one row per rejected
(rsid, `university_raw`) pair, with the matched OpenAlex name, the user counts, both shares and the
rsid's modal known country. CSV rather than parquet because it is read by hand.

**That file is the acceptance test for the gate.** Harvard, University of Phoenix, University of
Delhi, Stanford, Cambridge, Toronto, UNAM and Berkeley must be in it; USP, UNICAMP, UFRJ, FGV, UERJ,
Paulista and Estácio must be among the survivors 8a prints. If either fails, the gate is wrong and 8b
must not be run.

A spreadsheet form of the same thing sits beside it as `rsid_br_user_share_rejected.xlsx`: sheet
**Rejeitados** is the 628 rejected pairs, sheet **Mantidos** the 667 surviving schools one row each,
so a rejection can be read against the survivors instead of on its own. The two sheets are at
different grains on purpose — a rejection is judged per *string*, a survivor per *school*.

**No script produces that workbook.** It was built by hand on 2026-09-04 and deliberately left
without one, so it is the one artifact here that a rebuild does **not** refresh: regenerate
`rsid_br_user_share` and the `.xlsx` silently goes stale while the `.csv` beside it updates. Remake it
by hand, or check its date against the CSV's before trusting it.

It is already one file behind in one respect: it predates
[script 8d](#recovering-openalex_id--script-8d) and so carries `oa_matched_name` but **no
`openalex_id`**. To audit a rejection down to the institution record, join
`rsid_openalex_id_crosswalk.parquet` on (`rsid`, `university_raw`) rather than reading the workbook
alone — or rebuild the workbook from that crosswalk instead of from the gate table, which is what a
next version of it should do.

## How much of C_norm is missing

*Script 13a, `c_norm_coverage_audit.R`. Offline, read-only, changes nothing.*

Every C_norm number above is a **precision** or a **membership-gain** figure, and script 17 says in
its own note 5 that it measures precision and never coverage. So until this audit nobody had asked
the opposite question: of the strings that *do* denote a Brazilian institution, how many does the
matcher reach?

The method groups the education extract by Revelio's school key `rsid`, keeps the 744 schools where
C_norm matched at least one string, samples 500 of them, and pulls **every** `university_raw` under
each. **`rsid` is a measuring device here and never a criterion** — the withdrawn C_rsid branch
failed because propagating a match through a school key *amplifies* one stray row into a whole
university; counting with the same key amplifies nothing.

Coverage is bimodal, and the 54.8% total is the wrong headline:

| band (`match_share`) | schools | rows under | rows matched | coverage |
|---|---|---|---|---|
| a ≥ 0.5 | 359 | 4,877,828 | 4,496,762 | **92.2%** |
| b 0.1–0.5 | 64 | 523,597 | 107,573 | 20.5% |
| c 0.01–0.1 | 79 | 637,685 | 15,132 | 2.4% |
| d 0.001–0.01 | 107 | 842,715 | 2,365 | 0.3% |
| e < 0.001 | 135 | 1,559,728 | 493 | 0.03% |

Band e is the Harvard mechanism again — a foreign school pulled in by one stray Brazilian string.
A row-weighted sample of 1,200 unmatched rows (313 school–string pairs) separates the cases:

| | | |
|---|---|---|
| **M** true miss — C_norm should have matched | 1,081 | **90.1%** |
| **A** affiliated unit (technical school, colégio, hospital) | 12 | 1.0% |
| **X** a different institution — `rsid` noise | 44 | 3.7% |
| **N** correctly unmatched — the school is not Brazilian | 63 | 5.2% |

**Recall = matched / (matched + M) = 51.6%**, against a naive coverage of 49.0%. The two being so
close is itself the result: the `rsid` contamination everyone expects to dominate is only ~101,000
rows. **The misses are real.** C_norm reaches about half the rows it should.

Where the ~2.48M missing rows come from, and this is the to-do list:

| cause | share of misses | example |
|---|---|---|
| **`no_candidate`** — nothing in the institution list is reachable | **42.3%** | `ETEC - Escola Técnica Estadual de São Paulo` |
| **`brand_acronym`** | **34.0%** | `UNINOVE`, `UniCesumar`, `UNIP`, `FGV`, `UFRJ` |
| `campus_suffix` | 11.2% | `Faculdade Anhanguera de Sorocaba` |
| `type_word_form` | 7.0% | `Universidade Anhembi Morumbi` vs OpenAlex's `Anhembi Morumbi University` |
| `contains` | 5.0% | `Anhanguera Educacional` |
| `near_miss` | 0.5% | typos |

**The largest cause is not a matching problem.** `no_candidate` means no record in
`openalex_institutions_br` is reachable from the string at all — ETEC, SENAI and SENAC units and
many private faculdades are simply absent from OpenAlex. No change to the matching rule reaches
them; only a better institution list does, and the Censo da Educação Superior is the place to get
one.

### The acronym claim above is true only of the public universities it was measured on

The C_norm section says bare acronyms are 1.5–2.5% of an institution's rows. That was measured on
USP, FGV and UNICAMP. On private brand-name universities the acronym **is** the name people type:

| string | rows | share of its school's rows |
|---|---|---|
| `UNINOVE` | 170,151 | 83.5% |
| `UNIASSELVI` | 114,651 | 95.6% |
| `UniCesumar` | 103,519 | 89.0% |
| `Universidade Anhembi Morumbi` | 131,756 | 96.5% |
| `Anhanguera Educacional` | 243,125 | 93.3% |

### Two engine and data traps this audit turned up

**DuckDB's `trim()` strips U+00A0; Trino's does not.** Java's `Character.isWhitespace` deliberately
excludes the non-breaking space, so the obvious DuckDB transcription of the cohort query is *more
permissive* than the query that ran. Every `trim()` standing for a Trino one is therefore written
`trim(x, ' ')`, and the institution side is not trimmed at all. The audit's binding check against
`br_openalex_norm` is what caught it: 59 cohort members, one string,
`Universidade Federal do Acre` + U+00A0 + `(UFAC)`.

**163 distinct strings, 12,384 rows, arrive carrying U+FFFD** — `Universidade de Cuiab�`,
`UFSCar - Universidade Federal de S�o Carlos`. Their accents were destroyed upstream and nothing
downstream can match them.

### Reading it

`c_norm_coverage_by_rsid.parquet` carries all 744 schools with their row, string and user counts, so
any school's coverage can be looked up without rerunning. **The labels were written by an LLM, not
by a person** — the same conflict of interest script 17 records — so `c_norm_coverage_class.csv` is
an ordinary editable CSV keyed to the parked sample: fix a row, rerun, and the numbers move without
redrawing anything.

## Stored-but-not-filtering flags

Every cohort table carries the flags for criteria it does **not** filter on. `obmep_br_cohort_user_ids`
has no `br_name`, but the name cohort stores `br_position`; both store `br_educ_country`,
`br_openalex` and `br_openalex_norm`; the consolidated table stores all five plus the raw `p_brazil`.

`br_openalex` and `br_openalex_norm` are the **exact** and **widened** institution match, kept side
by side rather than collapsed into one. That is what makes the pre-C_norm cohort reproducible with a
`WHERE` clause instead of a rebuild, and it is the same reasoning that puts raw `p_brazil` next to
`br_name` and `min_bach_year_strict` next to `min_bach_year`.

The point is that a cut can be **tightened** in Athena without regenerating anything, and every
selected `user_id` is auditable back to what admitted it. It is the same reasoning that puts
`p_brazil` next to `user_id` in the upstream crosswalk.

`min_bach_year_strict` is the same idea applied to criterion E: it holds the year under the *old*
`degree = 'Bachelor'` rule, so the pre-correction definition is recoverable in place with
`WHERE min_bach_year_strict IS NOT NULL AND min_bach_year_strict >= 2007`, with no re-scan.

The `_alt` tables add the most literal instance of the rule yet: `br_openalex_rsid` is the exact-arm
propagation stored beside the widened `br_openalex_norm_rsid`. The cohort filters on the widened one
only, inside the same `OR` as `br_openalex_norm`, and never on the exact one. See
*[The alternative cohort](#the-alternative-cohort-the-rsid-branch-gated-on-where-the-schools-people-are)*.
One wrinkle sets them apart from every other flag in this list: in `obmep_candidates_step_1_alt` they
are **`NULL`, not `0`, for name-cohort-only members**, because the name cohort was deliberately not
rebuilt and never computed them. NULL there means *not measured*, and a consumer counting
rsid-admitted users must restrict to `in_country_cohort = 1` or `coalesce` on purpose.

## The consolidation

`obmep_candidates_step_1.R` is a `UNION` (not `UNION ALL` — that *is* the deduplication) of the two
`user_id` lists, `LEFT JOIN`ed back to both cohort tables and to the name crosswalk.

`COALESCE` across the two sources is safe because they **agree**: for all 2,664,049 users present in
both, every shared column is identical — zero discrepancies. No tie-breaking rule is needed.

`p_brazil` is backfilled across the whole union, so a country-only member carries its real name score
instead of NULL. It stays NULL only for profiles absent from the crosswalk entirely — non-Latin
alphabet names, which have NULL `p_brazil` upstream.

The script re-derives `br_name` from a **fresh** `p_brazil` lookup rather than copying it from the
name cohort, then asserts `br_name = in_name_cohort` on all 6,845,775 rows. Because the two are
derived by independent routes, agreement is a real check on both the backfill and the union rather
than a restatement of one of them.

---

## Traps that must not be reintroduced

### 1. `startdate` has a different type in the two Revelio tables

Verified with `DESCRIBE`:

| Table | `startdate` |
|---|---|
| `academic_individual_position` | `string` |
| `academic_individual_user_education` | `date` |

Calling `year()` on the position column fails outright:

```
FUNCTION_NOT_FOUND: Unexpected parameters (varchar) for function year.
Expected: year(date), year(interval year to month), ...
```

So the two sides of the query are asymmetric **on purpose** — the position side does
`min(try_cast(substr(startdate, 1, 4) AS integer))`, the education side `CAST(year(startdate) AS
integer)`. Do not "simplify" them into one form. The position strings are uniform: all 1,392,756,172
non-null values have length 10 in `YYYY-MM-DD`, from 1950-01-01 to 2029-04-01.

### 2. Revelio's `degree` is unreliable on Brazilian records

This is why `br_degree_patterns.R` exists. Measured over all 13,949,625 education rows whose
`university_country = 'Brazil'` or whose `university_raw` matches `openalex_institutions_br`:

| `degree_raw` | Revelio `degree` | rows |
|---|---|---|
| `bacharelado` | **Bachelor** | 762,945 |
| `bacharelado` | **High School** | 489,815 |
| `bacharelado em administração` | Bachelor | 258,511 |
| `bacharelado em administração` | **High School** | 165,855 |
| `graduação` | **empty** | 634,542 |

The same string lands in two different classes non-deterministically, so **no lookup table on
`degree_raw` can repair it** — the label has to be overridden. Criterion E therefore tests
`degree = 'Bachelor' OR <regex on degree_raw>`. The union lifts the Brazilian bachelor row count from
3,041,173 to 5,450,492.

### 3. Postgraduate must be excluded *before* matching `graduação`

`pós-graduação` contains `graduação` as a substring. A regex that matches `gradua` without excluding
postgraduate markers first promotes **656,833** postgraduate rows to bachelor — a larger error than
the one being fixed. The cascade order in `br_degree_patterns.R` is load-bearing:

```
postgraduate -> tecnólogo/CST -> high school -> bachelor
```

`tecnólogo` / CST (486,803 rows) is excluded from bachelor deliberately: 2–3 year degrees, closer to
`Associate`.

### 4. The patterns contain no backslashes, deliberately

`\b`, `\.` and `\uXXXX` were mangled repeatedly passing through R and shell quoting during
development. Word boundaries are written `(^|[^a-z])…([^a-z]|$)` and the dot as `ph[.]?d`. Accented
vowels are two-element character classes whose accented half is a `\uXXXX` escape, so the file stays
pure ASCII and R resolves it at parse time. **Do not tidy this back into conventional regex escapes.**

### 5. `year()` returns `bigint` in Trino

Without an explicit `CAST(... AS integer)` the `UNLOAD` parquet carries int64 where the `CREATE
EXTERNAL TABLE` declares `INT`. Athena's Parquet SerDe matches by position **and type**, so the
mismatch surfaces only on read, not on write. The offline validator catches it by running `DESCRIBE`
on the generated `SELECT` and comparing against the DDL.

### 6. Athena's Parquet SerDe resolves columns by ordinal position

Not by name. `openalex_institutions_br_to_s3.R` declares all 11 columns in file order and asserts
that order against the parquet **before** uploading, then re-checks after registration by comparing
a distinct-count computed locally and through Athena. A column reordering upstream would otherwise
produce a table that reads cleanly and means something else.

### 7. `UNLOAD` refuses a non-empty destination prefix

Every export script lists its prefix and stops with an explicit message if anything is there, rather
than letting Athena fail after the scan is already paid for. Rebuilding a cohort therefore needs
`DROP TABLE` **and** clearing the S3 prefix first.

## Re-running the cohorts

Every stage guards its own output, but the guards differ from scripts 1-2 because the destination is
Athena rather than a local file:

| stage | guard |
|---|---|
| institutions upload | S3 `content-length` matches local byte size -> skip |
| any `UNLOAD` | destination prefix must be **empty**, else the script stops |
| every cohort table | `exp_rows` constant; a mismatch aborts rather than writing |
| audit samples | sample parquet exists -> skip the redraw |

So rebuilding a cohort is not just re-running the script. It needs, in order:

```
DROP TABLE IF EXISTS revelio_database.<table>
aws s3 rm s3://revelio-misc/exports/<prefix>/ --recursive
Rscript <script>.R
```

Back up the local parquet first if the definition is changing — a cohort whose membership rule
changed cannot be reconstructed from the new table.

**Scan costs**, measured, since they are the real price of a re-run:

| job | scanned | approx |
|---|---|---|
| either cohort | ~36-48 GB | $0.19-0.24 |
| the rsid crosswalk (script 6) | 58.50 GB | $0.29 |
| `obmep_candidates_step_1` | ~0.85 GB | $0.004 |
| `name_only_country_check` | ~5 GB | $0.02 |
| `name_only_us_fullname_check` | ~10 GB | $0.05 |
| a full-column diagnostic over the education table | ~16 GB | $0.08 |
| the position `rcid` map (script 10b) | 40.43 GB | $0.20 |
| the company list → `rcid` (script 18) | ~5 GB | $0.03 |

The cohort scripts aggregate **both** Revelio individual tables in full. A `FUNCTION_NOT_FOUND` or
`TABLE_NOT_FOUND` costs nothing — Athena raises those during analysis, before reading any data — but
a query that runs and then fails validation has already been paid for. That is why the offline
validator exists.

### The offline validator

`scratchpad/validate_sql_syntax.R` builds empty DuckDB tables with the **real** column types, then
runs `EXPLAIN` on each generated `SELECT` and `DESCRIBE` to compare output types against each DDL. It
costs nothing and catches type errors before a single byte is scanned.

Its stub types must be kept in sync with the catalog. Declaring `startdate DATE` for *both* Revelio
tables is precisely what let the `year(varchar)` failure through to Athena — the stub encoded an
assumption instead of reality, so `EXPLAIN` bound cleanly against a schema that does not exist.

`academic_individual_user` was the last table stubbed from assumption rather than from the catalogue
— three columns, because nothing had ever needed more and the validator has no network to ask with.
It was replaced with **all 23 columns from a Glue read on 2026-09-03** rather than extended, on the
principle the position table already demonstrated: a partial stub does not fail on a missing column,
it just never offers it, which is how `rcid` sat unnoticed through the whole of 10a. Script 8a also
runs `DESCRIBE` on that table and prints it before its `UNLOAD`, so the stub can be re-checked
against reality on every run.

---

---
---

# Candidate position and education histories

Local, **online**. Two Athena `UNLOAD`s → S3 → external tables → `aws s3 sync` to Dropbox. Not
SEDAP-bound.

`obmep_candidates_step_1` carries only the flags and dates that admitted each user.
`obmep_candidates_step_1_entries.R` pulls the records behind them: **every** position and **every**
education entry those 6,849,674 people have, Brazilian or not. No new criterion, no filtering beyond
cohort membership.

```
revelio_database.obmep_candidates_step_1              6,849,674 users

obmep_candidates_step_1_entries.R
    -> revelio_database.obmep_candidates_step_1_position    30,389,044 rows   5.00 GB
    -> revelio_database.obmep_candidates_step_1_education   15,712,737 rows   0.91 GB
       s3://revelio-misc/exports/obmep_candidates_step_1_{position,education}/
       OBMEP/Data/intermediate/revelio_br_cohort/obmep_candidates_step_1_{position,education}/
```

**Both extracts contain exactly 6,849,674 distinct users** — every cohort member, and the script
asserts it. That is not luck: criterion D admits nobody without a position whose year parses and E
nobody without a bachelor, so a short count would mean the filter dropped members rather than that
the data is thin. It is the strongest check in the run.

## `naics` does not exist

The requested column list named `naics`; `academic_individual_position` has **`naics_code`**
(`naics_description` does exist). The extract uses `naics_code`. All other 22 requested columns are
present, verified with `DESCRIBE` before anything was scanned.

## The semi-join is for correctness, not cost

```sql
WHERE user_id IN (SELECT user_id FROM obmep_candidates_step_1)
```

`IN (SELECT …)` cannot multiply rows even if the cohort table stopped being unique on `user_id`; an
inner join could. But **it saves nothing on the bill**, and the intuition that 1.8% selectivity should
be cheap is wrong here. Measured three ways:

- a count query reading **only** `user_id` from both source tables scanned **12.83 GB** — essentially
  the full columns, nothing pruned;
- a source file's footer shows `user_id` **scattered**: one row group spanning 2.18×10⁹ of id range.
  With 6.85M cohort users spread across that space, every row group holds at least one, so Athena can
  skip none;
- `SHOW CREATE TABLE` confirms no partitioning, no bucketing and no sort order to exploit.

**Cost is set by which columns are read, not by how the filter is written.**

## Measured cost

Predicted from per-column compressed sizes in the parquet footers, then checked against the run:

| | source | predicted | **actual** |
|---|---|---|---|
| position | 685.0 GB / 2,625 objects | 444 GB (64.9% of columns) | **422.3 GB — $2.06**, 48 s |
| education | 89.8 GB / 378 objects | 77 GB (86.2%) | **72.9 GB — $0.36**, 12 s |
| | | 521 GB | **495 GB ≈ $2.42** |

The footer method landed within 5%; it is worth reusing before any wide extraction from these tables.

`description` is ~47% of that bill (226 + 22 GB) and was kept deliberately. A single column cannot be
scanned in isolation, so adding it later would mean paying the whole 495 GB again rather than an
increment.

**Script 10b is the same argument, measured a second time.** It reads four integer columns of the
same 685 GB table — `user_id, position_id, rcid, ultimate_parent_rcid` — and pays for four columns,
not for a table:

| | source | predicted | **actual** |
|---|---|---|---|
| position `rcid` (10b) | the same 685.0 GB table | — | **40.43 GB — $0.20**, 9 s |

That ratio, 40 GB against 422, is the whole reason `rcid` arrived as a second narrow extract joined
on `position_id` rather than as a thirteenth column on this one. Re-running 10a to add it would have
re-paid the 422 GB, `description` included. See [Employer flags](#employer-flags).

## The local copy is a directory, and the files have no extension

Every other script here ends with `arrow::write_parquet(arrow::Scanner$create(ds)$ToTable(), …)`.
**That pattern must not be used here.** It materialises the whole result in memory — fine at 6.8M
rows × 11 narrow columns, not fine at 30M rows carrying free text. `UNLOAD` already writes Snappy
parquet, so the local copy is a download:

```
aws s3 sync s3://revelio-misc/exports/obmep_candidates_step_1_position/ <dir>/
```

Two consequences for anyone reading these files:

- the artifact is a **directory of 30 parts**, not one parquet. Read it with
  `arrow::open_dataset(dir, format = "parquet")`, which also keeps `nrow()` cheap — it reads footers
  only.
- **Athena names UNLOAD objects `<query-id>_<uuid>` with no `.parquet` suffix.** Globbing for
  `*.parquet` finds nothing; passing `format = "parquet"` explicitly is what makes arrow read them.
  The script's own size report had this bug on the first run.

## Columns, and what they contain

```
position    user_id, position_id, company_raw, company_linkedin_url, company_cleaned,
            title_raw, title_translated, description, naics_code, naics_description,
            startdate, enddate

education   user_id, university_raw, university_name, rsid, degree_raw, degree,
            field_raw, field, university_country, description, startdate, enddate
```

`startdate`/`enddate` are **STRING** on position and **DATE** on education — README trap 1, and the
two DDLs differ accordingly. Do not harmonise them.

### These are 12 columns of 47, and two of the absences matter

`academic_individual_position` has **47 columns**. Reading the list above as though it were the
table is what let `rcid` — Revelio's own key for the employer — sit unnoticed in the source through
every stage from here to script 17. The 35 columns 10a did not take, grouped:

```
company / firm         location            role and seniority     pay and scores
rcid bigint            location_raw        job_category           salary float
company_name           country             role_k50               start_salary double
ultimate_parent_rcid   region              role_k150              end_salary double
ultimate_parent_       state               role_k300              total_compensation
  company_name         metro_area          role_k500              additional_
ticker                                     role_k1000               compensation
exchange                                   role_k1500             weight float
cusip                                      seniority smallint     remote_suitability
rics_k50/k200/k400                         position_number          float
ultimate_parent_                             smallint
  factset_id / _name                       onet_code, onet_title
```

(All `string` unless marked.) Everything above except `description` — which 10a *did* take — is a
column somebody will eventually want, and the list is written out in full precisely because a
partial listing is what caused the problem in the first place.

Two of them were live traps rather than curiosities, and **both are now closed:**

- **`rcid` was not here**, which is why script 10b exists. It unloads
  `user_id, position_id, rcid, ultimate_parent_rcid` and joins back on `position_id` for 40.43 GB
  rather than re-running this extract for 422. See [Employer flags](#employer-flags).
- **`country` was not here.** Criterion A_country reads `academic_individual_position.country`, and
  the column was never unloaded, so anything needing position-level country locally had to go back
  to Athena. **Script 10c has since unloaded it**, along with the rest of the location block and the
  whole role taxonomy — see
  [Role and location for the selected candidates](#role-and-location-for-the-selected-candidates).
What remains unextracted after 10a + 10b + 10c: the pay group (`salary`, `start_salary`,
`end_salary`, `total_compensation`, `additional_compensation`), the two scores (`weight`,
`remote_suitability`), the `rics_k*` industry clusters, the factset ids, and the company
name/ticker/exchange/cusip strings that `academic_company_ref` already serves per `rcid`. Wanting
any of them means a fourth scan; wanting several at once means one scan, so decide together.

`scratchpad/validate_sql_syntax.R` now declares all 47 with their real types. It previously declared
13, and a partial stub does not fail on a missing column — it simply never offers it, which is the
mechanism by which this went unnoticed. If that stub is ever refreshed, refresh it whole.

| | position | education |
|---|---|---|
| rows per member | 4.44 | 2.29 |
| `description` filled | 15,502,013 (51.0%) | 2,651,030 (16.9%) |
| distinct values | 6,689,766 `company_cleaned`, 1,013 `naics_code` | 55,906 `rsid`, 172 `university_country` |
| `startdate` range | **2007-01-01 … 2025-01-01** | 1900-01-01 … 2108-01-01 |

The two date ranges are worth reading together, because they confirm the cohort definition rather
than describing the source. **No member has a position before 2007** — criterion D requires the
*first* position to start in 2007 or later, so the floor is exact. Education has no such floor
because E constrains only the first *bachelor*: high-school rows reach back to 1900, and the
2108 tail is the junk already noted in `revelio_br_cohort_user_ids.R` note 9.

## Re-running

Guards match the rest of the folder: **both** destination prefixes are checked before **either**
`UNLOAD` runs, so a dirty second prefix cannot surface after the first extract has been paid for. The
`exp_rows` constants warn on drift; the distinct-user invariant aborts. Rebuilding needs

```
DROP TABLE IF EXISTS revelio_database.obmep_candidates_step_1_{position,education}
aws s3 rm s3://revelio-misc/exports/obmep_candidates_step_1_<name>/ --recursive
```

and about **$2.42**. The script also refuses to start if the AWS CLI is missing, since discovering
that after the scan would waste the whole run.

---
---

# Validating the name prior

Three read-only scripts. None writes to Athena, none feeds anything downstream — they exist to be
read. Findings live in each script's header, not here.

| Script | Net | Samples | Writes |
|---|---|---|---|
| `linkedin_br_name_audit.R` | — | 500 profiles with `p_brazil > 0.5` | `linkedin_br_flags/name_audit_*` |
| `name_only_country_check.R` | Athena | none — full aggregate | `revelio_br_cohort/name_only_user_country.parquet` |
| `name_only_us_fullname_check.R` | Athena | 50 + 50 profiles | `revelio_br_cohort/name_only_us_fullname_*` |

`linkedin_br_name_audit.R` draws 500 profiles (241 distinct first names) from the 39,450,441 above
the cut, and joins a hand-written classification of each name. It is **offline** — it reads the
per-profile chunks from script 1, which are the only place the names survive;
`linkedin_br_name_flag.parquet` and the Athena table carry `user_id` + `p_brazil` only.

`name_only_country_check.R` reports the `user_country` distribution from
`academic_individual_user`, broken out by which cohort admitted each candidate, with the corroborated
groups as baselines. **Re-run 2026-08-25 against the C_norm tables**: the name-only group is
1,113,654 (0.5% in Brazil), `both` 96.4% and `country_only` 93.2%. Two intermediate builds used the
withdrawn rsid branch and are void — one sent `country_only` to 27.3% — see
[C_norm](#c_norm-and-the-rsid-branch-that-was-withdrawn).

`name_only_us_fullname_check.R` was **not** re-run and describes the **pre-rsid**
`obmep_candidates_step_1` (6,845,775 rows, 1,115,460 name-only). Its 100 hand classifications are
keyed to user_ids sampled from that population, and its own guard refuses to redraw; re-running it
would fail its sample-reproduction assertion rather than silently drift. The group it sampled barely
moved — 1,113,654 today — so its findings still apply.

`name_only_us_fullname_check.R` draws 50 candidates admitted by the name prior alone whose
`user_country` is `United States`, plus 50 corroborated Brazilians located in Brazil as a calibration
set, and classifies both by surname morphology — chiefly the Portuguese `-es` versus Spanish `-ez`
split.

## Sampling conventions these three share

**The sample is drawn once and skipped on re-run.** The stored classification is keyed to that exact
sample; redrawing would leave it silently mismatched. Delete the sample parquet to force a redraw,
and expect to reclassify.

**Classifications are stored as editable CSVs, not buried in code** — they are judgment, so they
should be inspectable and overridable without touching a script.

**Each script re-runs its own sampling query and asserts it returns the identical `user_id`s.** A
seed that does not actually reproduce is worse than no seed at all.

### `USING SAMPLE` gets pushed below the filter

In DuckDB, `USING SAMPLE reservoir(500 ROWS)` combined with `WHERE p_brazil > 0.5` returned **23
rows**: the sample was applied to all 708M profiles first and the filter afterwards — 500 × the 5.6%
pass rate. Use a hash-ordered top-N over the *filtered* set instead, which cannot be reordered around
the predicate:

```sql
... WHERE p_brazil > 0.5 ORDER BY hash(user_id + <seed>) LIMIT 500
```

### Trino and DuckDB do not share function names

| DuckDB | Trino |
|---|---|
| `regexp_matches(s, p)` | `regexp_like(s, p)` |
| `hash(x)` | `xxhash64(to_utf8(cast(x AS varchar)))` |

Do not copy a query from an Athena script into a DuckDB one or the reverse. The offline validator
(`scratchpad/validate_sql_syntax.R`) carries a `CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)`
shim so the Athena SQL can bind against local stub tables — that proves the query parses and every
column resolves, **not** that the two regex engines agree.

---
---

# RUF course rankings

Local, **online** script. It reaches `ruf.folha.uol.com.br` over HTTP and writes parquet into the
OBMEP Dropbox. **No S3, no Athena.** Not SEDAP-bound; nothing here may be copied into
`scripts_sedap/`.

`ruf_course_rankings.R` downloads the **RUF 2025** (Ranking Universitário Folha, 11th edition)
ranking for all **40** careers and writes one row per **course × institution**, flagging the top 50
of each course in `top_50`. The full list is kept rather than just the 50, so the cut can be widened
later without re-downloading anything.

Why it exists: this folder had no Brazilian, course-level quality signal. Shanghai has 18 Brazilian
entries and no course dimension; OpenAlex has works counts but no ranking and no public/private
flag. RUF has both, for 2,232 institutions.

## It is an API, not a scrape

The course pages are a Vue shell — **the table is not in the HTML**. `/2025/ranking-de-cursos/` is a
403 and there is no index page. The data comes from three public JSON files:

```
https://ruf.folha.uol.com.br/2025/database/
    courses_ids_map.json              40 courses: id, name, slug
    cursos/<slug>/ranking.json        the full ranking for that course
    lista_cidades.json                1,061 cities: id -> name, uf
```

No auth, no pagination, no rate limit encountered. 42 requests, ~14 MB, ~1 min including a 0.5 s
courtesy pause between calls. The raw JSON is cached under `ruf_ranking/raw/2025/` and a re-run
downloads nothing.

The 40 slugs in `courses_ids_map.json` are identical to the 40 in the page nav — verified, not
assumed. The `<rankings … course-slug="…">` Vue tag in the page and the API base `/database/` were
both read out of `static.folha.uol.com.br/storybook/js/ruf-*.js`, which is also where the
`type` 1/2 → Pública/Privada decode and the indicator names come from.

## Measured results

Every figure comes from a logged run against the live API.

| | |
|---|---|
| Courses | **40** |
| Rows (course × institution) | **18,830** |
| Distinct institutions | **2,232** |
| Rows flagged `top_50` | **2,001** — see the tie below |
| Rows in a rank band | 11,467 (60.9%) |
| Smallest / largest course | Artes Plásticas e Visuais 84, Direito 1,434 |
| Public / private rows | 3,571 / 15,259 |
| Public / private inside the top 50s | **1,408 / 593** |
| Output | 525.7 KB parquet, 40 columns |
| Runtime | ~1 min first run, seconds cached |

USP is ranked **1st in 34 of the 40 courses**; the six it does not lead are Ciências Contábeis
(UFMG), Comunicação (UFSC), Engenharia Elétrica and Engenharia de controle e automação (Unicamp),
Propaganda e Marketing and Serviço Social (UFRJ). No course has two institutions at rank 1. Note
that USP's own press release says 33 of 40 — a one-course difference that was not run down.

## Three traps in this data

### 1. The array is not sorted by rank

It arrives in institution-id order. The **second** element of `administracao-de-empresas` is the 5th
place. Anything that takes "the first 50 rows" is silently wrong and looks entirely plausible. The
cut is a filter on rank, and `pior_rank_top50` is asserted to be 50 in every course precisely to
catch a regression into array order.

### 2. Above 200 the rank becomes a band

Individual positions run 1–200. From 201 on, `rank` is a **range string** — `"201-250"`,
`"501-600"`, …, `"1001+"` (395 rows share `"1001+"` in administração). `rank_clean` is the band's
**lower bound**, so above 200 it repeats and is **not an ordering**: administração's 1,395 rows have
a maximum `rank_clean` of 1001.

The parquet carries both — `rank` (int) and `rank_label` (the raw string) — plus **`is_banded`**,
defined as `rank_label <> CAST(rank AS VARCHAR)`, which is exactly true for banded rows and false
for individual ones. **Never sort, compare or average `rank` where `is_banded` is true.** The
top-50 cut sits far inside the individual region, and the script asserts no banded row appears
below 201; if that ever fires, the band floor has moved down toward the cut.

### 3. Ties are real, including one sitting on the cut

Ranking is competition-style (1, 2, 2, 4), so a tie normally pays for itself by skipping the next
number and `rank <= 50` returns 50 rows. **Fisioterapia is the exception**: two institutions at
position 50 (Universidade Católica de Pernambuco and UFRN) and nobody at 51, so its top 50 has
**51 rows** — which is correct, and why the total is 2,001 rather than 2,000. Direito has the same
kind of tie at position 17.

This is why the cut is a rank filter and never a `LIMIT 50`, and why the script **reports** a course
whose `n_top50` differs from `min(50, rows)` instead of aborting on it. A `LIMIT 50` would drop one
of the two 50th places at random.

## A type trap that breaks the read

Inside `pos`, the `*_clean` fields plus `mec` and `oab` alternate **integer and empty string in the
same column, row by row** — `pos.m_clean` is an int in 621 of administração's 1,395 rows and `""` in
the other 774. Declaring them `INTEGER` in the projection breaks the read.

So the whole `pos` struct is declared `VARCHAR` and converted in SQL with
`try_cast(nullif(x, '') AS INTEGER)`. For the same reason the script uses an explicit
`columns={...}` and **never `read_json_auto`**: a column that is all-null in one course would be
inferred with a different type than the same column in another, and the union of the 40 files would
fail.

## Columns

`edition`, `course_id`, `course_slug`, `course_name`, `rank`, `rank_label`, `rank_pp`, `top_50`,
`is_banded`, `ruf_institution_id`, `institution_name`, `abbr`, `uf`, `administration`, `type`,
`ruf_url`, `size`, `age`, `demand`, `n_campi`, `cities`, eleven `score_*` and eight `pos_*`.

- **`ruf_institution_id`** is extracted from the institution's fact-sheet URL
  (`…/universidade-de-sao-paulo-55.shtml` → `55`). It is the only stable key across courses — names
  are not join keys. The script asserts it is never null, never repeats within a course, and never
  carries two different names.
- **`rank_pp`** is the position *within* the public or private group, which is what the site's
  Pública/Privada filter shows.
- **`cities`** resolves the `locs` campus ids through `lista_cidades.json`; `n_campi` reaches 22.
- Indicator meanings, taken from the site's JS: `market` = avaliação de mercado, `teaching` =
  qualidade de ensino, `dm` = docentes com mestrado/doutorado, `nh` = regime de dedicação,
  plus `enade`, `retention`, `mec`, `oab`.

**Score fill rates**, of 18,830: `enade` and `teaching` 18,830, `dm` 18,745, `nh` 18,541,
`retention` 15,831, `market` 8,112, `mec` 2,109, `oab` 846 (direito only), and
**`evasion`, `rh` and `tn` are 0 — entirely null in this edition**. The three empty columns are kept
on purpose: dropping them would hide a future edition starting to populate them. The script prints
the fill table on every run.

## The 12-course cut — `ruf_stem_top50.R`

Script 15 is the reason 14 keeps every institution instead of only the cut: it takes the cut without
touching the network. It reads `ruf_course_ranking_2025.parquet` and writes two files.

**The cut is a parameter, `rank_cut`.** The output filenames and the `n_courses_top<N>` column name
are both built from it, so switching cuts *adds* files instead of overwriting the other cut's. Two
cuts are measured and both are on disk:

| file | rows | one row per |
|---|---|---|
| `ruf_stem_top10_2025.parquet` | **120** | course × institution, all 40 source columns |
| `ruf_stem_top10_institutions_2025.parquet` | **23** | institution, deduplicated |
| `ruf_stem_top50_2025.parquet` | **600** | course × institution, all 40 source columns |
| `ruf_stem_top50_institutions_2025.parquet` | **132** | institution, deduplicated |

The filter is `rank <= rank_cut`, **not** the source's `top_50` column. The two agree exactly where
the second exists — measured: across all 18,830 source rows, `top_50 <> (rank <= 50)` in **zero**
rows — but only the first generalises. Setting `rank_cut <- 50L` and re-running reproduces both
top-50 parquets **byte-identically**, verified by MD5, which is what proves the generalisation left
the existing cut alone.

The 12 courses, as slugs — **matching is by slug, never by name**, because RUF's own capitalisation
is not the usual one (`Engenharia de controle e automação`, `Engenharia de produção`):

```
biologia  computacao  fisica  matematica  quimica
engenharia-ambiental  engenharia-civil  engenharia-de-controle-e-automacao
engenharia-de-producao  engenharia-eletrica  engenharia-mecanica  engenharia-quimica
```

They are one editable constant at the top of the script. Changing the selection is a one-line edit
plus re-measuring `exp_rows` and `exp_inst`.

The institution file carries `n_courses_top<N>` (of 12), `best_rank`, `worst_rank`, `mean_rank` and
`courses` — the course names joined and ordered by rank. `n_campi` is deliberately **not** carried
over: it counts the campuses offering *that course*, so it is not an institution-level attribute.
The dedup uses `any_value()`, which is safe only because name/abbr/uf/administration are verified
constant per `ruf_institution_id` — and that verification is an assertion in the script, immediately
before the aggregate. `sum(n_courses_top<N>)` ties the two files to each other — 120 at the
top-10 cut, 600 at the top 50.

### Measured — the top-10 cut

All 12 give **exactly 10** rows, ranks 1–10, **no banded rows and no ties at all**: 120 rows and
**23 institutions**, of which only **two are private** — FEI (6th in Engenharia de controle e
automação) and Mauá (10th in the same course). Public / private rows: 118 / 2.

USP leads 10 of the 12; **Unicamp** leads Engenharia Elétrica and Engenharia de controle e
automação. **3 institutions make all 12** — Unicamp (mean rank 2.2), UFMG (3.8) and UFRJ (4.3). 5
make 11: USP at mean **1.1**, UFSC, UFRGS, Unesp and UFSCar. 8 appear in just one — FEI, UFV, UEM,
UFSM, UFG, UFLA, UFBA, Mauá — and the rest sit between: UFPR 5, UFPE 4, UnB and ITA 3, UFU, UTFPR
and UFABC 2.

This is the selective set. The top-50 cut below admits Uniasselvi, Unicesumar, Unip and Universidade
Paulista alongside USP, because reaching the top 50 of *one* course is enough to qualify.

### Measured — the top-50 cut

All 12 give **exactly 50** rows — the cut is well inside the individually-ranked region, so there
are **no banded rows** and ranks run 1–50. Three courses have interior ties (Engenharia de controle
e automação at 48, Engenharia de produção at 15, Química at 43) — **a property of this cut; the
top-10 cut has none**. None sits on 50, so the Fisioterapia case does not arise here. The guard is
kept anyway.

| course | evaluated | public | private | leader |
|---|---|---|---|---|
| Biologia | 316 | 45 | 5 | USP |
| Computação | 618 | 37 | 13 | USP |
| Engenharia Ambiental | 243 | 40 | 10 | USP |
| Engenharia Civil | 820 | 37 | 13 | USP |
| Engenharia Elétrica | 432 | 41 | 9 | **Unicamp** |
| Engenharia Mecânica | 437 | 40 | 10 | USP |
| Engenharia Química | 207 | 39 | 11 | USP |
| Engenharia de controle e automação | **142** | **24** | **26** | **Unicamp** |
| Engenharia de produção | 588 | 31 | 19 | USP |
| Física | 148 | 44 | 6 | USP |
| Matemática | 234 | 44 | 6 | USP |
| Química | 181 | 45 | 5 | USP |

Engenharia de controle e automação is the outlier twice over: the smallest field of the twelve (142
institutions ranked) and **the only one where private institutions are the majority of the top 50**.

**8 institutions make all 12 at this cut** — Unicamp, UFMG, UFSC, UFRJ, Unesp, UFRGS, UFBA and
PUCPR, the last the only private one. 12 make 11, 8 make 10, and 43 appear in just one. At the
top-10 cut only Unicamp, UFMG and UFRJ make all 12.

### Absence is not a bad rank

**USP is in 11 of the 12, not all 12.** It has **no row at all** in Engenharia de controle e
automação — it is absent from that ranking, not ranked below the cut. So are UnB, UFPR, UFC, UFF,
UFRN, UFSCar and UEM: that one course accounts for most of the near-misses among the strongest
institutions, and reading those as "ranked poorly" would be wrong.

The script's closing report makes the distinction explicit, printing `ausente do ranking` versus
`fora do top 50 (<rank_label>)` for every institution that reaches the top 50 in 10 or more of the
12. Where a real rank exists it is shown — PUC Rio misses Biologia at 86, UFSM misses Computação at
71, UFU misses Engenharia Civil at 54.

## Scope and re-running

**2025 only.** Editions 2012–2019 and 2023–2024 exist under the same URL scheme, but their schema
was not verified and the script does not touch them. `edition` is a parameter at the top, so
pointing it at another year is a one-line change followed by re-measuring every `exp_*` constant.

Re-running is cheap and safe:

| stage | guard |
|---|---|
| each JSON download | file exists and is non-empty → skip |
| a download that fails | non-200, unparseable JSON or empty array → `stop()`, and **nothing is written to disk**, so a truncated file can never masquerade as cache |
| the parquet | always rebuilt; it is a second of work |

To force a fresh download, delete `ruf_ranking/raw/2025/`. A clean exit is the pass condition —
`exp_courses = 40`, `exp_cities = 1061` and `exp_rows = 18830` are measured constants and any drift
raises a warning.

Script 15 needs no network at all and takes seconds; it always rebuilds both of its parquets and
stops with a pointer to script 14 if the source parquet is missing. Its constants are keyed to the
cut, in an `exp_medidos` table: `exp_courses = 12` for both cuts, then `exp_rows` / `exp_inst` of
**120 / 23** at `rank_cut = 10` and **600 / 132** at `rank_cut = 50`. A cut that has never been
measured runs *without* a regression guard and `warning()`s to say so — measure it and add the pair
to `exp_medidos` rather than letting it run bare.

The content is Folha de S.Paulo's and is copyrighted. This is an internal research input, not
material for redistribution.

---
---

# The RUF → OpenAlex crosswalk

Local, **offline**. `ruf_openalex_br_crosswalk.R` gives the 23 institutions of the top-10 cut an
`openalex_id`, which is what lets RUF join anything else in this folder.

```
ruf_openalex_br_crosswalk.R
    reads  ruf_ranking/ruf_stem_top10_institutions_2025.parquet     23 rows   (script 15)
           openalex_institutions/openalex_institutions_br.parquet 1,947 rows   (script 3)
    ->     ruf_ranking/ruf_openalex_br_2025.parquet                  23 rows   4.9 KB
```

Every other institution-side dataset here is keyed on OpenAlex — `openalex_institutions_br`,
`shanghai_ranking_oa`, `rsid_openalex_br`. RUF carries only `ruf_institution_id`, taken from its
Folha fact-sheet URL, and **names are not join keys**. Until this file existed, RUF joined to
nothing.

**Script 4 is not the model.** It joins **by id**, because the Shanghai xlsx already carried
`OA_key`. RUF has no OpenAlex id at all, so this matches on names — and the design problem is doing
that with no fuzzy match and no alias table, neither of which exists anywhere in this folder.

## Three arms, and why the order is structural

Each arm is exact equality or exact containment after folding with `lower(strip_accents(trim(x)))`,
the same fold [script 16](#the-match-is-criterion-c_norm-with-one-deliberate-departure) uses.

| arm | rule | resolves |
|---|---|---|
| **1** | RUF `institution_name` = OA `cleaned_display_name` **or** `display_name` | **19** |
| **2** | OA `cleaned_display_name` **contained in** RUF `institution_name`, `type='education'` | **3** — Unesp, UFABC, Mauá |
| **3** | RUF `abbr` as a whole word in OA `display_name`, `type='education'` | **1** — FEI |

Lowest arm number wins, and **within the winning arm exactly one candidate is required**. That is an
assertion, not a tie-break: silently picking a winner is precisely what would hide the failure.

Measured, running arm 2 over all 23 **without** arm 1 first:

```
UFPR   2 candidates   Universidade Federal do Paraná | Universidade Federal do Pará
UFRGS  2 candidates   ... do Rio Grande do Sul       | Universidade Federal do Rio Grande
```

`universidade federal do para` is a substring of `universidade federal do parana`, and
`… do rio grande` of `… do rio grande do sul`. **Those are different universities, not campuses of
one.** Arm 1 resolves both by equality, so arm 2 never sees them — which is the whole reason it is
safe.

Arm 3 has the mirrored property: alone it is ambiguous for **Unesp** (`Universidade Estadual
Paulista (Unesp)` against `Unesp de Marília`, 0 works) and **Mauá** (`Instituto Mauá de Tecnologia`
against `Centro Universitário Barão de Mauá`, a different institution in Ribeirão Preto). Arm 2 has
already claimed both.

**FEI is the one row resting on a single signal.** RUF calls it `Centro Universitário da Fundação
Educacional Inaciana Pe Sabóia de Medeiros`, OpenAlex `Centro Universitário FEI`. The two names
share no word of content, so the acronym is the only evidence — corroborated by city (São Bernardo
do Campo) and `works_count` 3,587. It is the row a snapshot change breaks first, and the one to read
by hand when the `stop()` fires.

Arm 2's `length >= 8` floor guards against a short OA name landing inside a long RUF one. **It is
inert today:** floors of 0, 4, 6, 8, 10 and 12 all give the same 3 resolved and 0 ambiguous, the
shortest real match being `instituto maua de tecnologia` at 28 characters. Do not read 8 as a
calibrated value.

## Measured

| | |
|---|---|
| RUF institutions in | **23** |
| OpenAlex BR rows scanned | 1,947 |
| resolved by arm 1 / 2 / 3 | **19 / 3 / 1** |
| **resolved total** | **23 of 23** |
| ambiguous within the winning arm | **0** |
| distinct `openalex_id` — the map is injective | **23** |
| `type <> 'education'` / NULL `ror` | **0 / 0** |
| OpenAlex snapshot | 2026-02-25 |

Every row is corroborated by city and `works_count`: USP 449,173 São Paulo; Unesp 193,181 São
Paulo; UFRJ 170,097 Rio de Janeiro; ITA 11,513 São José dos Campos; UFABC 22,779 Santo André; FEI
3,587 São Bernardo do Campo; Mauá 853 São Caetano do Sul.

**Independent confirmation against script 4.** 14 of the 23 are also in the Shanghai top 1000, and
on all 14 this crosswalk picks the *same* `openalex_id` that script 4's id-based join assigned —
including `UFPR → Federal University of Parana`, the case the arm ordering exists to protect. The
other 4 Brazilian Shanghai entries (Unifesp, UFF, UFC, UFPel) are simply not in the STEM top 10.

## Columns

```
ruf_institution_id        RUF's key, from the fact-sheet URL
abbr, institution_name, uf
match_arm                 1, 2 or 3 — which rule resolved it
openalex_id               the answer
display_name, cleaned_display_name, ror, oa_type
works_count               verification, not a filter
city, region
snapshot_date             which OpenAlex snapshot resolved it
ruf_cut                   10 — which RUF cut this crosswalk covers
```

`match_arm` is what makes the file auditable: the 19 rows at 1 need no thought, and the 4 rows at 2
and 3 are the ones to check. The script prints all 23 on every run, then the 4 again under a heading
saying they did not match by name — at 23 rows the whole crosswalk fits on one screen, and that is
the justification for allowing arms 2 and 3 at all.

## What aborts and what only warns

A wrong or missing answer `stop()`s: 23 rows in and 23 distinct `ruf_institution_id`; every row
resolved; no ambiguity inside the winning arm; the map **injective**, so two RUF institutions can
never collapse onto one OpenAlex id; every match `type = 'education'` with a non-NULL `ror`; and no
folded name duplicated among the OA rows arm 1 matches — vacuous today (the 4 duplicates are
`faculdades nova esperança`, `hospital ana nery`, `instituto de medicina avançada`, `hospital de
base`, none of them ours) but a future duplicate on a real university would fan the join out in
silence.

Drift only `warning()`s: the 19/3/1 arm split, the OA row count, and `snapshot_date`. If OpenAlex
renames Unesp to RUF's spelling, Unesp migrates from arm 2 to arm 1 — same answer, different route,
worth reporting and not worth aborting on. A separate check names the four: it is not enough that
four rows fall outside arm 1, it has to be *those* four with *those* ids.

## Known limitations

- **Only the 10-cut is measured.** Arms 2 and 3 are safe because their combined output is 4 rows,
  read in full. At the 50-cut, or over all 2,232 RUF institutions, they must be re-audited rather
  than trusted — the Paraná/Pará and Rio Grande/Rio Grande do Sul collisions are what that surface
  contains. The script `stop()`s if the input is not 23 rows, rather than quietly generalising.
- **The parent institution, never a campus.** OpenAlex carries `Unesp de Marília` as its own id with
  0 works; the crosswalk resolves Unesp to the parent, so campus-level ids are unreachable through
  it.
- **OpenAlex ids are not stable across merges.** Script 4 hit this — two Shanghai ids were
  well-formed but absent from the snapshot after a later merge, and this snapshot copy carries no
  `merged_ids/` tree. Here the direction is name → id off script 3's output, so a merge surfaces as
  a changed *name* and the `stop()` catches it instead of writing a NULL.
- **`works_count` and `city` are verification, not filters.** Nothing downstream should threshold on
  them; they are in the file so a person can confirm identity.

## Re-running

```powershell
Rscript prep/building_external_data/ruf_openalex_br_crosswalk.R
```

Seconds, no network, no guards on the destination — one parquet, overwritten. A clean exit is the
pass condition. It depends on script 15 having been run at `rank_cut = 10L`; if that file is
missing it stops with a pointer rather than reading the other cut.
---
---

# Top-1000 Shanghai degrees

Local, **offline**. `shanghai_top1000_degree_flags.R` is the only stage that joins the institution
side of this folder to the candidate side, and it needs no network at all: both of its inputs are
already on disk.

```
shanghai_top1000_degree_flags.R
    reads  shanghai_ranking/shanghai_ranking_oa.parquet             1,079 rows   (script 4)
           revelio_br_cohort/obmep_candidates_step_1_education/    15,712,737    (script 10a)
           br_degree_patterns.R                                                  (script 7)
    ->     revelio_br_cohort/obmep_candidates_step_1_shanghai.parquet  990,937   7 MB
```

It answers one question for every member of `obmep_candidates_step_1`: does this person hold a
**bachelor's, master's or PhD from a top-1000 Shanghai university?** That is the same question
criterion C_norm answers for Brazilian institutions, asked of a different institution list and
split by degree level.

**It costs nothing to run.** The education extract was already paid for once, at 72.9 GB of scan,
and the whole job is about a minute of DuckDB. Do not rebuild it in Athena without a reason —
the only reason would be wanting the flags for *all* Revelio users rather than for the 6.85M
cohort.

## `Rank` is a band, not a position

The ranking column is exact from 1 to 100 and then jumps: 101, 151, 201, 301, 401, …, 901, each
value being the **start of a band**. So "top 1000" is not `Rank <= 1000`, it is:

```sql
WHERE Rank <= 901
```

which selects **exactly 1,000 rows**. The other 79 rows in the xlsx have `Rank IS NULL` — they
carry a `math_Rank` or nothing at all. The script asserts the count is 1,000 *before* it scans
anything, and **aborts** rather than warns: if the bands ever change, the arithmetic has to be
re-derived, not silently reinterpreted.

## All three name columns, not just `cleaned_display_name`

The institution side is the union of `cleaned_display_name`, `display_name` and `shanghai_Name`
over those 1,000 rows, folded and deduplicated into **1,246 strings**.

`cleaned_display_name` alone is not enough. It is NULL on one of the top-1000 rows — one of the
three OpenAlex ids that do not resolve, [documented under script
4](#the-3-that-do-not-match) — and `shanghai_Name` is what covers it. Beyond that, the ranking's
own spelling differs from OpenAlex's on 307 of the 1,076 matched rows, and both spellings are
things people type.

## The match is criterion C_norm, with one deliberate departure

Same procedure as [C_norm](#c_norm-and-the-rsid-branch-that-was-withdrawn): fold accents, compare
lowercased, accept the match either on the whole string or on any `/`, `( )` or `" - "` delimited
**segment** of at least 3 characters. It runs over `SELECT DISTINCT university_raw` — 1,417,851
strings, not 15.7M rows — and both arms group by `university_raw`, so the join back is at most 1:1
and cannot multiply education rows.

**The segment arm here carries no `is_edu = 1` restriction.** In `revelio_br_cohort_user_ids.R`
that restriction is load-bearing, because the Brazilian OpenAlex list holds short *company* names
— `IBM`, `Vale`, `Intel`, `Shell` — and `Curso de Inglês - Intel` would match one. The Shanghai
list holds nothing but universities, and `shanghai_ranking_oa.parquet` has no `type` column to
filter on even if you wanted to.

Checked rather than assumed. The shortest institution string is `UNESP` at 5 characters, and all
710 raw strings that reach it only through the segment arm are genuinely UNESP —
`UNESP - Universidade Estadual Paulista`, `São Paulo State University (Unesp)`, and so on. The
visible noise is affiliated technical high schools (`Colégio Técnico Industrial - UNESP`), which
the degree filter drops anyway.

| | raw strings |
|---|---|
| whole-string arm | 1,725 |
| segment arm | 6,262 |
| **union** | **6,267** |

Segment splitting is again nearly the whole effect, exactly as it was for C_norm.

The script prints the 20 highest-volume matched institutions with the share of their rows that
came *only* from the segment arm, on every run, so this stays visible rather than buried:
`UNESP` 99.2%, `Universidade Federal de São Carlos` 73.8%, `Universidade Federal de São Paulo`
65.7%, `Universidade Federal do Rio de Janeiro` 52.3%, `Universidade de São Paulo` 7.6%.

## Two engine traps this script has to step around

### `strip_accents()` is better than the Trino expression, not a translation of it

The cohort scripts fold accents with `regexp_replace(normalize(s, NFD), '\p{M}', '')` because
Trino has no `strip_accents()`. That expression decomposes each letter and drops the combining
marks — but **ç is not a combining mark** and survives it, a caveat already noted in
`scratchpad/measure_c_norm.R`. DuckDB's `strip_accents()` has no such gap; verified,

```sql
strip_accents('Fundação Getúlio Vargas') = 'Fundacao Getulio Vargas'
```

This is a case where the two engines genuinely differ in behaviour rather than in spelling. **Do
not "fix" it back to the Trino form.**

### `sql_is_bachelor` is Trino SQL running inside DuckDB

Script 16 reuses `sql_is_bachelor` **verbatim** rather than restating it, which is the point:
it makes "bachelor" here mean byte-identically what criterion E means by it. But that string
calls `regexp_like()`, which DuckDB does not have. The shim is the one already documented in
`scratchpad/validate_sql_syntax.R`:

```sql
CREATE MACRO regexp_like(s, p) AS regexp_matches(s, p)
```

## The level cascade, and why its order is load-bearing

`br_degree_patterns.R` gained four constants and one SQL string for this — `rx_notdeg`, `rx_phd`,
`rx_msc`, `rx_lato`, `rx_mba` and `sql_shanghai_level`. The additions are strictly additive;
`rx_post`, `rx_tech`, `rx_hs`, `rx_b1`, `rx_b2` and `sql_is_bachelor` are untouched, because
criterion E and every measured constant in scripts 8 and 9 are defined by them.

`rx_post` deliberately lumps master's, doctorate, MBA and lato sensu into one "not a bachelor"
bucket — all criterion E ever needed. A script that has to say *which* postgraduate degree
somebody holds needs that bucket taken apart. Applied to
`dr = lower(trim(coalesce(degree_raw, '')))`:

```
1. rx_notdeg                                    -> other
2. degree = 'Doctor'  OR rx_phd                 -> phd
3. degree IN ('Master','MBA')
     OR (NOT rx_lato AND rx_msc)                -> master
4. sql_is_bachelor                              -> bachelor
5. otherwise                                    -> other
```

The four arms partition the matched rows, and the script asserts it.

**`rx_notdeg` must be tested first.** `pós-doutorado` contains `doutorado` and
`doutorado sanduíche` contains `doutorad`; both would otherwise read as a doctorate *earned* at
the host university. A stay is not a degree. It moves 5,105 bachelor rows, 1,623 doctorate rows
and 990 master's rows out of the flags, and it is also what keeps `exchange program`,
`exchange student` and `minor` out.

**PhD before master's**, so `Mestrado e Doutorado` resolves to the higher of the two rather than
to whichever alternative the engine tests first.

**`rx_lato` subtracted from the master's arm.** `pós-graduação lato sensu` is a Brazilian
postgraduate *certificate*, not a stricto sensu master's. It is a subset of `rx_post` by
construction, and it does not set any of the three flags — but `sh_lato` stores it anyway.

**MBA counts as a master's**, and `sh_master_strict` stores the version that excludes it.

### Enrolment, not graduation

`mestrando` and `doutorando` both set their flag. Revelio records enrolment and has no graduation
field, so this is the only thing the data supports — and it is the same property criterion E
already has, where an enrolled undergraduate satisfies it. The two were briefly inconsistent
during development, `mestrando` counting and `doutorando` not; `doutorand` was added to `rx_phd`
to fix it, worth 1,457 rows here. `pós-doutorando` is still excluded, because `rx_notdeg` is
tested before `rx_phd` ever runs.

## The second arm: `university_name`

The match reads **two** columns, not one. `university_raw` is what the person typed;
`university_name` is Revelio's own normalisation, and it carries the **English canonical name**.
Both go through the identical classifier — same two arms, same accent folding, same 3-character
floor — and `university_raw` takes precedence, so Revelio's name only decides when the raw string
does not match.

Precedence matters because Revelio is sometimes wrong: 1,922 rows reading `University of Sydney`
carry the `university_name` **Western Sydney University**, and ~300 reading `Seoul National
University` become **Gyeongsang National University**. Where both columns match, they agree on
institution *identity* (`OA_key`) on 1,170,964 of 1,173,310 rows — **0.2% disagreement**, almost
all of it those two defects.

| | `university_raw` only | + `university_name` |
|---|---|---|
| matched rows | 1,098,068 | **1,264,091** (+166,023) |
| users flagged | 885,665 | **990,937** (+105,272, **+11.9%**) |

The gain lands exactly where the coverage audit said it would — `Universität Wien` →
*University of Vienna*, `Università degli Studi di Torino` → *University of Turin*,
`Uniwersytet im. Adama Mickiewicza w Poznaniu` → *Adam Mickiewicz University in Poznań* — and by
country: Italy 24,364, Portugal 23,657, Germany 4,828, plus 82,661 with a blank country.

**`sh_raw_any` stores the previous definition**, so the widening reverses with a `WHERE` clause and
no rebuild — the same reasoning that puts `br_openalex` beside `br_openalex_norm`. It reproduces
885,665 exactly, and the script asserts `sh_any ⊇ sh_raw_any`.

### Why `rsid` is *not* used

The obvious alternative is Revelio's normalised school key. It was considered and rejected, on top
of the [reasons the cohort branch was withdrawn](#the-rsid-branch-and-why-it-is-gone), for a
reason specific to this problem: **`match_share` — the statistic that makes rsid safe — is computed
from the very string match being repaired.** For the institutions actually being missed it reads
0.005 (Politecnico di Torino), 0.014 (Padova), 0.020 (Torino), 0.048 (Poznań), 0.235 (Wien) — all
far below the 0.5 cut the README proved safe. Lowering the cut to reach them reopens exactly the
Harvard poisoning. It is circular.

Measured confirmation: `MBA USP/Esalq` resolves to **nine different rsids**, among them FGV,
Mackenzie, Anhembi Morumbi and Anhanguera; and one `Tilburg University` row carries **Nottingham's
rsid at `match_share` 0.967** — high confidence, wrong university. `university_name` acts at the
string, where it cannot amplify, which is the property the README credits C_norm with.

## Measured

| | |
|---|---|
| institution strings after folding | 1,246 (from 1,000 ranked rows × 3 name columns) |
| distinct `university_raw` scanned | 1,417,851 |
| strings matched: `university_raw` / `university_name` | 6,267 / 950 |
| matched education rows | 1,607,459 |
| **users written** | **990,937** |
| of which reachable by `university_raw` alone (`sh_raw_any`) | 885,665 |
| `sh_bachelor` | 856,076 |
| `sh_master` (incl. MBA) | 272,255 |
| `sh_master_strict` | 242,729 |
| `sh_phd` | 54,985 |
| rows by level: bachelor / master / phd / other | 917,409 / 289,767 / 56,915 / 343,368 |

## Columns

```
user_id
sh_any                                      1 on every row written
sh_bachelor, sh_master, sh_master_strict, sh_phd, sh_lato
sh_best_rank                                min band over the flagged levels
sh_bach_rank, sh_mast_rank, sh_phd_rank
sh_bach_inst, sh_mast_inst, sh_phd_inst     best-ranked matched institution per level
sh_bach_year, sh_mast_year, sh_phd_year     earliest startdate year per level
sh_n_rows                                   matched education rows behind the flags
```

`sh_master_strict` and `sh_lato` are [stored-but-not-filtering
flags](#stored-but-not-filtering-flags), the same reasoning that puts `min_bach_year_strict` next
to `min_bach_year`: the MBA decision reverses with a `WHERE` clause instead of a rebuild, and
every flagged `user_id` is auditable back to the institution and the year that flagged it.

## Known limitations

- **A bare acronym does not match.** `MIT`, `UCLA` or `Cambridge` on their own are not found
  unless the string also carries the full name. The README already measured that class at 1.5–2.5%
  of an institution's rows on the Brazilian list — see [*Why: bare acronyms were never the
  problem*](#why-bare-acronyms-were-never-the-problem) — which is why there is no alias table
  here. `UNESP` is found because it is in the OpenAlex `display_name` itself, not because
  acronyms are handled.
- **Homonyms match wrongly.** `Saint Louis University - Maryheights Campus, Baguio City`, in the
  Philippines, reaches the American Saint Louis University through the segment arm.
  Exact-after-normalization cannot separate the two, and the record of the [withdrawn rsid
  branch](#the-rsid-branch-and-why-it-is-gone) is the argument against reaching for something
  looser.
- **Revelio's `degree` label wins where it disagrees with `degree_raw`** — 649 rows read
  `graduação` but are labelled `Doctor` and land in `phd`. Inherited from `sql_is_bachelor`'s
  `degree = 'Bachelor' OR …` shape and kept for consistency with criterion E rather than repaired
  here.

## Re-running

```powershell
Rscript prep/building_external_data/shanghai_top1000_degree_flags.R
```

No guards on the destination — the output is a single parquet and the script overwrites it. It is
idempotent and costs nothing, so there is no prefix to clear first, unlike the `UNLOAD`-based
stages.

Drift on a measured quantity `warning()`s and names both numbers; a violated invariant `stop()`s.
The invariants are: the 1,000-row band, `user_id` unique and non-NULL, `sh_any = 1` everywhere,
at least one of the three flags on every row, `sh_master_strict <= sh_master`, every rank column
within the band, the four cascade arms partitioning the matched rows, and **every output
`user_id` present in `obmep_candidates_step_1`** — the extract was built from that cohort, so a
stray id means the wrong education directory was read.

---
---

# The Shanghai acronym arm

Local, **offline**, additive. `shanghai_acronym_arm.R` marks people who wrote **only the acronym**
of a top-1000 institution in `university_raw` — `UCL`, `UFSCar`, `UNSW` — which
[script 16](#top-1000-shanghai-degrees) cannot see, because a bare acronym shares no string with
"University College London".

It writes `obmep_candidates_step_1_shanghai_acr.parquet`, one row per marked `user_id` with
`sh_acr_*` columns. **Script 16 and its output are untouched.**

```
shanghai_ranking_openalex_names.R  (4)   -> shanghai_ranking_oa_acronyms.parquet
obmep_candidates_step_1_education  (10a)
br_degree_patterns.R               (7)
                                          -> shanghai_acronym_candidates.csv   (machine)
                                          -> shanghai_acronym_class.csv        (reviewed by hand)
                                          -> obmep_candidates_step_1_shanghai_acr.parquet
```

## The match is on `university_raw`, whole string

No segment arm and no `university_name` arm. `university_name` appears exactly once in this script,
as a **hint column in the review sheet** — never a join key, never a filter.

The fold is the folder's standard, `lower(strip_accents(trim(...)))`, identical to scripts 16, 19
and 20.

## Guard 1: an acronym with more than one owner is discarded

| | |
|---|---|
| Folded acronyms in the top-1000 | 554 |
| **Claimed by exactly one institution** | **486** |

`UM` is claimed by seven ranked institutions, `UW` and `CMU` by five each, `UC` by five. There is no
tie-break and none is attempted.

Script 20 resolves *its* abbreviation collisions with `arg_min(best_rank)`. That is safe there —
the RUF list is Brazilian and holds 23 schools. Here it would hand `UM` to whichever of the seven
happened to rank best, which is a draw, not a match.

## There is no length floor, deliberately

A draft of this script cut acronyms shorter than 4 characters. The review below makes that cut worse
than useless: `UCL` (2,715 people), `USP`, `UFC`, `UEA`, `PUC` and `UnB` are all three letters, and
the review decides each one individually. A blind cut throws away UCL's 2,715 people to avoid PUC's
196.

## Guard 2: the country veto was tried, measured, and dropped

`university_country` is null on most of these rows — `UNIME` carries a country on **3 of 1,188**.
With a 25-row evidence floor the veto fires **3 times out of 209**, and **two of the three are
wrong**: it places UnB in Argentina and UNAM in Iceland, because Revelio's country field for those
strings is itself corrupt. A guard that is wrong two-thirds of the times it speaks is worse than no
guard.

## Guard 3: the hand review, which is where the precision comes from

209 folded strings match. The script writes them to `shanghai_acronym_candidates.csv` with a
proposed label and **stops**; only `shanghai_acronym_class.csv`, reviewed by hand, releases the
flags. Two files and not one: the script is re-runnable, and writing over the reviewed file would
erase the review in silence.

The proposed label comes from Revelio's own `university_name` on the same rows, resolved against the
ranking's three spellings plus `display_name_alternatives`:

| bucket | strings | people | |
|---|---|---|---|
| `confirms` | 81 | 8,348 | resolves to the **same** ranked institution |
| `unresolved` | 99 | 8,337 | names something outside the top-1000 |
| `no_name` | 28 | 183 | no `university_name` at all |
| `contradicts` | 1 | 4 | resolves to a **different** ranked institution |

**`unresolved` is not a residual bucket — it holds both the biggest wins and the worst errors**, and
the hint makes each decidable at a glance:

| `university_raw` | acronym claims | Revelio's `university_name` | people | |
|---|---|---|---|---|
| `ucl` | University College London | UCL - University of London | 2,715 | ✓ |
| `ufscar` | Federal University of Sao Carlos | UFSCar - Alumni | 2,043 | ✓ |
| **`unime`** | University of Messina | **UNIFAS University Centre** | **1,109** | ✗ |
| `unesp` | UNESP | Júlio de Mesquita Filho São Paulo State Univ. | 368 | ✓ |
| **`unam`** | Nat. Autonomous Univ. of Mexico | **National University of Misiones** | **241** | ✗ |
| **`unisc`** | University of the Sunshine Coast | **University of Santa Cruz do Sul** | **216** | ✗ |
| **`uea`** | University of East Anglia | **Euro-African University** | **213** | ✗ |
| **`puc`** | Pontifical Catholic Univ. of Chile | **Premier University** | **196** | ✗ |
| **`unb`** | University of Brasília | **Nazi Boni University** | **169** | ✗ |

Several of the wrong ones are wrong *because the cohort is Brazilian*: `UNIME` is a Bahia college,
`UEA` is Amazonas, `PUC` is Rio/SP/Minas, `UPF` is Passo Fundo, `USF` is São Francisco, `UNC` is
Contestado. None of them is the ranked school that owns the acronym worldwide.

### The review's verdict

| label | strings | people |
|---|---|---|
| `OK` | **104** | 13,639 |
| `WRONG` | 85 | 2,936 |
| `AMBIGUOUS` | 20 | 297 |

`AMBIGUOUS` is a real answer, not a dodge. `UFC` is the clearest case: `university_name` says
"University of Continuing Education", but whoever writes `UFC` in Brazil almost always means the
Federal University of Ceará, which **is** the ranked school. The evidence contradicts itself, so the
string flags nobody.

Only `OK` flags. Everything else is written down and excluded.

## The hard fold, and what it is for

`fold_hard()` additionally strips commas, periods and apostrophes and drops a leading `"the "`. It
resolves **the hint only** — never an acronym. It is what lets `University of California Los
Angeles` meet `University of California, Los Angeles`, and `University of New South Wales` meet
`The University of New South Wales`. It moves **76** ranking names and lifted 11 strings out of
`unresolved` into `confirms`.

## Measured result

| | |
|---|---|
| Folded strings matched | 209 |
| Education rows | 17,927 |
| People, before review | 16,814 |
| People in `OK` strings | 14,498 |
| **People flagged**, after the degree filter | **10,907** (0.16% of the cohort) |
| Already flagged by script 16 | 6,010 |
| **New, invisible to `sh_any`** | **4,897** (+0.49% over 990,937) |

By level: 7,856 bachelor, 2,640 master, 480 PhD.

**Predicted before running, and confirmed: the arm moves the parked 500-record recall sample by
`0`.** That sample's misses are `MBA USP/Esalq`, `St Andrews`, `Wisconsin-Madison`, `Torino`,
`Tilburg` and a Sorbonne faculty — punctuation, endonym, level and faculty problems, not bare
acronyms. Stating the prediction first made the result a test instead of a rationalisation.

## The flags never enter `sh_any`

`sh_acr_*` lives in its own file and its own columns. A consumer who does not want the arm simply
omits the join — the same escape hatch `rd_abbr_any` gives in script 20, which is also where the
reason is recorded: `university_raw` is exactly where people write `USP` on its own, and USP is also
United States Pharmacopeia.

Precision for this arm comes from the 209-row review, **not** from script 16's measured 99.5%, which
was taken on name-matched rows and says nothing about acronyms.

## Re-running

```powershell
Rscript prep/building_external_data/shanghai_ranking_openalex_names.R   # if the snapshot changed
Rscript prep/building_external_data/shanghai_acronym_arm.R
```

The first run without `shanghai_acronym_class.csv` writes the candidates and `stop()`s. After that
the script `stop()`s on: a label outside `OK`/`WRONG`/`AMBIGUOUS`, a repeated `acr_fold`, a
candidate with no review line, a review line with no candidate, an accepted string that is not a
whole-string acronym, a repeated `user_id`, a marked row with no degree level, a rank outside the
band, and any marked `user_id` absent from `obmep_candidates_step_1`.

**A new ranking or a new OpenAlex snapshot invalidates the review.** The coverage check catches it
by refusing to run, which is the intended behaviour: new acronyms need new verdicts.


---
---

# The `university_raw` → Shanghai crosswalk

`shanghai_raw_crosswalk.R`, local and offline. Scripts 16, 16a and 8g each rebuild the match against
the ranking and each publish only `user_id` flags. None of them publishes **the map itself**. This
does.

**Grain: one row per (`university_raw`, `university_name`, `rsid`)** observed in the cohort
education extract that resolves to a ranked institution. The typed string is the key; Revelio's own
name and school key ride along as evidence about it.

| | |
|---|---|
| Rows | **4,282** |
| Distinct folded strings | 1,950 |
| Distinct `rsid` | 1,201 |
| Institutions reached | 970 of the 1,000 in the band |
| Triples reaching **two** institutions | **0** |

The grain is the **spelling, not the folded string** — `UCL`, `Ucl` and `ucl` are three rows on
purpose, so a consumer joins on `university_raw` exactly instead of re-folding. `raw_fold` is in the
table for anyone who wants the folded grain.

## Three arms, marked, never duplicating a row

Whole-string match on the folder's standard fold, `lower(strip_accents(trim(...)))`. No segment arm:
the grain is the typed string, and a fragment does not identify an institution with the confidence a
lookup table needs. Only keys claimed by **exactly one** ranked institution are used — the same rule
as 16a note 2, and for the same reason (`UM` is claimed by seven).

| arm | source | keys | rows | education rows | people |
|---|---|---|---|---|---|
| `name` | `display_name`, `cleaned_display_name`, `shanghai_Name` | 1,243 | 2,573 | 1,172,659 | 1,002,919 |
| `name_alt` | `display_name_alternatives` | 2,884 | 3,661 | 1,317,072 | 1,115,459 |
| `acronym` | `display_name_acronyms` | 486 | 481 | 17,927 | 16,935 |

A triple matching on two arms is **one row**: `by_name`, `by_name_alt` and `by_acronym` say which
fired, and `match_arm` names the best one under the precedence `name > name_alt > acronym`. The
`by_*` columns keep the whole picture, so the precedence hides nothing.

**`name_alt` is the arm that earns its keep on endonyms** — exactly the gap the coverage audit
predicted. It is also the least policed of the three: it has had no review.

| typed | resolves to | people |
|---|---|---|
| Universidade de Coimbra | University of Coimbra | 9,841 |
| Universidade do Minho | University of Minho | 7,267 |
| Universidade de Aveiro | University of Aveiro | 5,233 |
| Università degli Studi di Torino | University of Turin | 2,431 |
| Alma Mater Studiorum – Università di Bologna | University of Bologna | 2,756 |

None of these is reachable through `display_name`.

## The acronym review is carried, not redone

`shanghai_acronym_class.csv` already holds 209 hand-labelled strings — 104 `OK`, 85 `WRONG`, 20
`AMBIGUOUS`, each with its reason. The crosswalk joins it in as `acr_label` / `acr_note` and
**aborts** if any acronym-arm row comes back unlabelled, which would mean the ranking or the band
moved and the review had gone stale.

**Rejected rows stay in the table, labelled.** Hiding them would make the file useless for auditing,
which is half of why it exists. `UNIME` → University of Messina sits there as `WRONG`, visible.

The recommended filter, stated in the script header and worth repeating:

```sql
WHERE by_acronym = 0 OR acr_label = 'OK'
```

That keeps **4,071** of 4,282 rows and drops the 211 acronym rows the review rejected.

## The band, and the cross-check that matters

`Rank <= 901` — the same 1,000 institutions scripts 16, 16a and 8g use. This excludes the 79 ranking
rows with a NULL `Rank`, and the trade is deliberate: inside the band the acronym review covers the
acronym arm **exactly**, with no unreviewed match. (Outside the band there were 2 triples reaching
two institutions; inside there are none.)

The acronym arm reproduces script 16a independently: **486 keys, 209 strings, 17,927 education
rows**, all three identical to what 16a measured from different code. That is the strongest check in
the script.

## Re-running

```powershell
Rscript prep/building_external_data/shanghai_raw_crosswalk.R   # offline, seconds
```

It `stop()`s on: a band that is not 1,000 institutions, a row count that does not equal the distinct
triple count (an arm duplicating a triple), a row with no arm set, a `match_arm` whose `by_*` is 0, a
NULL `openalex_id`, an `acr_label` outside the acronym arm, and any unlabelled acronym row. Measured
quantities drift with a `warning()` naming both numbers.

---
---

# Auditing the Shanghai flags

Local, **offline**, and read-only with respect to the pipeline: `shanghai_flag_audit.R` measures
how often [script 16](#top-1000-shanghai-degrees) is right, and changes nothing.

```
shanghai_flag_audit.R
    reads  revelio_br_cohort/obmep_candidates_step_1_education/   (script 10a)
           shanghai_ranking/shanghai_ranking_oa.parquet           (script 4)
           br_degree_patterns.R                                   (script 7)
           revelio_br_cohort/obmep_candidates_step_1_shanghai.parquet (script 16)
    ->     revelio_br_cohort/shanghai_audit_sample.parquet      1,000 rows, immutable
           revelio_br_cohort/shanghai_audit_degree_class.csv      430 rows, editable
           revelio_br_cohort/shanghai_audit_inst_class.csv        269 rows, editable
           revelio_br_cohort/shanghai_audit_classified.parquet    the join
```

Script 16 makes two independent claims about every education row: that `university_raw` denotes a
top-1000 Shanghai university, and that the row is a bachelor's, master's or PhD. Until now both
had been checked only by aggregate plausibility. This draws 1,000 matched rows at random and
measures each.

## Read this before quoting any number below

**The ground truth was written by an LLM, not by a person** — by the same agent that wrote the
patterns under test. It is a self-assessment with a conflict of interest. The numbers say *the
patterns do what their author thought they did*; they do not say *the patterns are right*.

The two classification CSVs exist to be overridden. They are keyed to the parked sample in the
same convention as [scripts 11 and 13](#validating-the-name-prior): correct a row, re-run, and the
numbers change with no redraw. The script prints what share of labels is still as the LLM left it
— currently 699 of 699.

## What it measures, and what it cannot

The sample is row-weighted over the 1,368,227 matched rows, so `mestrado` enters with the weight
it really has. That makes the rate an estimate of **production error**, not a portrait of the long
tail: 1,000 rows cover only 430 distinct degree spellings.

It measures **precision, never coverage.** The sample is drawn from rows that *matched*, so
nothing here says how many top-1000 alumni the match missed. The bare-acronym gap is unmeasured by
construction. And it measures **rows, not people** — the flags are per-user, and a user is flagged
if any one of their rows fires.

The strongest check in the run is not an accuracy number at all: the audit recomputes the cascade
and asserts that every level it predicts is present in the flag script 16 actually wrote. That is
what proves the audit is testing the shipped classifier rather than a drifted copy of it.

## Result

Measured **after** the A1/B/C/D/E/F/G fixes were applied. The before-column is the run that found
them.

| | before | after | |
|---|---|---|---|
| degree level, 4-class accuracy | 97.8% | **99.2%** | 935 / 943, [98.3, 99.6] |
| institution precision, Y/(Y+A+N) | 99.9% | **99.9%** | 999 / 1,000, untouched by the fixes |
| — whole-string arm | 100.0% | 100.0% | 867 / 867 |
| — segment arm only | 99.2% | 99.2% | 132 / 133 |
| correct on **both** dimensions | 99.5% | **99.6%** | 815 / 818, [98.9, 99.9] |
| rows with at least one error | 22 | **9** | |

57 rows carry no evidence of level at all and are excluded from the level denominator.

Per class, precision / recall: bachelor **100.0 / 99.1**, master 98.9 / 99.5, PhD **100.0 / 100.0**.

Per pattern, the share of firings landing on the class the pattern exists to mark:

| pattern | fires | on target | |
|---|---|---|---|
| `rx_phd` | 44 | **100.0%** | |
| `sql_is_bachelor` | 583 | 99.3% | untouched — it is criterion E |
| `rx_msc` | 185 | 98.9% | |
| `rx_notdeg` | 26 | 96.2% | was 92.9% |
| `rx_lato` | 35 | 82.9% | untouched |

The patterns overlap deliberately — the cascade order is what breaks the ties — so these rows do
not sum to the sample.

### The number that justifies `br_degree_patterns.R`

The cascade disagrees with Revelio's own `degree` label on **266 of 943 rows**. On those, the
cascade is right 264 times and the label 2 times — **99.2%**. Overriding `degree` rather than
following it is worth almost exactly the disagreement.

## Defects found, and what was done

Footprints are over all 1,368,227 matched rows.

| | defect | rows | outcome |
|---|---|---|---|
| A1 | `rx_notdeg`'s bare `extensão` swallows `mestrado em extensão rural`, a real master's | 48 | **fixed** — moved to `rx_notdeg_weak`, tested *after* the degree arms |
| A2 | ~~`rx_notdeg`'s `exchange` swallows an MBA~~ | 628 | **retracted — not a defect**, see below |
| B | `rx_msc` has `mestrando`/`mestre` literal, so `mestranda` and `mestra` match nothing | 1,248 | **fixed** → 0 |
| C | degree patterns never fold accents, so Spanish `máster` misses while English `master` hits | 3,736 | **fixed** → 0 |
| D | `pós- graduação` (hyphen *then* space) escapes `rx_post`, promoted to **bachelor** | 269 | **fixed in `rx_post16`**, not in `rx_post` → 0 |
| E | Spanish `grado` (4,271) and `licenciad` (1,001) unrecognised | 5,272 | **fixed in `rx_bach16`**, not in `rx_b1`/`rx_b2` → 33 residuals, correctly `other` |
| F | doctorate abbreviations `dnp`, `dr.-ing.` match nothing | 44 | **fixed** → 0 |
| G | `rx_notdeg`'s postdoc arm never matched `pós-doutorado` | 862 | **fixed** → 0, found while testing |

### A2 was not a defect, and the audit's own label was the error

The first report claimed `rx_notdeg`'s `exchange` wrongly swallows a master's, on the strength of
one sampled row reading `master of business administration - mba, international exchange program`.

The population says otherwise. Of the 628 rows where an exchange word and a degree word co-occur,
the bulk are `mba exchange program`, `master's exchange`, `master's degree (exchange)` and
`doctoral exchange` — people who did an *exchange* at that university while enrolled in a degree
somewhere else. Excluding them is correct, and the proposed "fix" would have made script 16 worse
by roughly 600 rows.

**The row is still in the CSV with the label I gave it, and still appears in the error listing.**
Deleting it would hide the disagreement. This is precisely the failure mode the LLM-ground-truth
caveat predicts, and it is the strongest available argument for the human pass that has not
happened yet.

### G — a defect the file documented as already fixed

`rx_notdeg`'s postdoc arm was written `p[oó]s[ -]?doc`, so it only ever matched the literal
`pós-doc` / `postdoc` spellings. It never matched **`pós-doutorado`**, which is how Portuguese
actually writes it — so 862 rows, 799 people, were scored as a *doctorate earned at the host
university* rather than as a postdoctoral stay. The file's own comment asserted the opposite, and
so did an earlier line in this README.

The repair is `do(c|ut)`, kept tight enough that `pós-graduação stricto sensu - doutorado` (822
rows) is **not** caught — that one is a real doctorate.

### D and E were fixed *outside* the shared constants

`rx_post`, `rx_b1` and `rx_b2` feed `sql_is_bachelor`, which
[`revelio_br_cohort_user_ids.R`](#the-criteria) interpolates as **criterion E**. Repairing them at
source is the more correct thing in the abstract and the wrong thing here: measured against the
local education extract — which reproduces the pipeline's `min_bach_year` for all 6,849,674
members *exactly* — it would drop **6,145 of them from the cohort**, 4,581 from the `rx_post`
repair and 1,596 from the `rx_b1`/`rx_b2` one, plus an unknown number newly admitted that only
Athena could count. That is a redefinition of the cohort and a re-run of scripts 8, 9, 10 and 10a,
not a bug fix.

So the repairs live in `rx_post16` and `rx_bach16`, used only by `sql_shanghai_level`. **Criterion
E is byte-identical** — asserted directly, by capturing `sql_is_bachelor` before the edit and
comparing after. What changed is that script 16's "bachelor" is no longer identical to criterion
E's: it is widened by `rx_bach16` and narrowed by `rx_post16`, in that measured amount and no
other. `sql_is_bachelor` is still interpolated whole rather than restated, so the difference stays
readable.

### What the fixes did to the flags

| | before | after |
|---|---|---|
| users flagged | 881,566 | **885,665** |
| `sh_bachelor` | 757,274 | 760,336 |
| `sh_master` | 221,480 | 225,655 |
| `sh_master_strict` | 194,004 | 198,184 |
| `sh_phd` | 50,524 | **50,374** |

PhD is the only one that falls, and G is why: 862 postdoctoral stays stopped counting as
doctorates, which outweighs the 44 rows F added.

### What is left

Nine rows still miss, and none is a systematic class. One is the institution error (BYU-Idaho),
one is the retracted A2 row, two are Revelio label problems (`especialista em auditoria` labelled
`MBA`; `aluno especial - mestrado`), and five are a genuine long tail — `baccellierato`,
`contador publico nacional`, `degree in pharmacy`, `fonoaudióloga`, `graduando física`. Each is
one row in a thousand and would need its own literal, which is how a pattern file starts rotting.

## Coverage — the other half of the audit

The precision audit above answers "of the rows we flag, how many are right". It says nothing about
how many top-1000 degrees were **missed**, and by construction it cannot: its sample is drawn from
rows that already matched.

So a second sample was drawn — **500 rows that produced no flag**, row-weighted over the 14.6M
negatives, parked at `revelio_br_cohort/shanghai_recall_sample.parquet` (seed `20260826r`). Each
was labelled by identifying the institution and then **looking membership up in the ranking file**,
which makes this ground truth firmer than the precision audit's: the only judgement is "what
institution does this string denote", not "is it top-1000".

### The result that prompted the second arm

**484 of 500 correctly not flagged — but 16 false negatives, 3.2%** [1.8%, 5.1%]. Because the
negative class is 13× the positive class, that was severe in absolute terms: ~468,000 missed rows,
implying **recall of only ~70%** against precision of 99.6%.

The 16 broke down as: **8 non-English institution names**, 4 acronym-only strings, 2 punctuation
variants, 1 faculty without its parent, 1 level miss (`LLM`). Half the problem was one thing —
the institution list carries OpenAlex's single `display_name`, which is chosen inconsistently
(`TU Wien` in German, `University of Vienna` in English), so `Universität Wien` had nothing to
match against.

### After adding `university_name`

Re-evaluating the **same parked 500 rows** — no redraw, so the comparison is exact:

| | before | after |
|---|---|---|
| miss rate | 3.20% | **1.44%** [0.58%, 2.95%] |
| implied recall | ~70.1% | **~85.8%** [74.8%, 93.8%] |

Nine of the 16 false negatives are now caught (Wien ×2, Torino ×2, Padova, Amsterdam, Poznań,
UFRGS ×2). Seven remain: `MBA USP/Esalq` ×2 and the Sorbonne faculty (acronym / faculty-only),
`University of St. Andrews` and `University of Wisconsin-Madison` (punctuation — the list holds
`St Andrews` and an en-dash), `Politecnico di Torino`, and the Tilburg `LLM` level miss.

### What the second arm cost

The name arm was audited on its own: **200 name-only rows**, seed `nm20260826`, labelled the same
way. **193/200 = 96.5%** [92.9%, 98.6%] correct — materially worse than the raw arm's 99.9%,
because it inherits Revelio's own misassignments:

- `Faculdade de Tecnologia de São Paulo` → *University of Sao Paulo* — FATEC is Centro Paula
  Souza, not USP
- `Universidad de Palermo` → *University of Palermo* — Buenos Aires, not Sicily
- `Uri Campus de Erechim` → *Federal University of Paraná*
- `Faculdade de Educação e Ciências Gerenciais de Sumaré` → *University of Campinas*

Blended over both arms that is **99.5%** institution precision, ~5,800 wrong rows added against
166,023 gained. **The trade is roughly 25 points of recall for 0.4 points of precision**, and
`sh_raw_any` makes it reversible if a given analysis would rather not take it.

One caveat on the precision audit above: its sample predates the second arm, so its 99.9% figure
describes the **`university_raw` arm only**. The 96.5% here is the name arm's own measurement; the
two have not been combined into a single re-drawn sample.

## Re-running

```powershell
Rscript prep/building_external_data/shanghai_flag_audit.R
```

First run parks the sample and stops at the missing CSV; author it, then re-run for the report.
The sample is **not** redrawn if the parquet exists — the two CSVs are keyed to it and must not
drift underneath. Delete the parquet to force a redraw and expect to reclassify all 699 keys.

The seed reproduces: the sampling query re-runs on **every** invocation and the ids are compared,
because unlike script 13 this query is a free local scan. A seed that does not reproduce is worse
than no seed.

---
---

# Employer flags

Scripts 18 and 19. The question is **where a cohort member worked**, against four lists: the 341
Hurun tech unicorns of 2023–2026, the 200 largest tech firms by market cap, the 23 Brazilian
universities that reach the RUF 2025 top 10 in any of the 12 STEM courses, and the 1,000
universities of the Shanghai top-1000.

Nothing in this folder asked that question before. Script 16 asks where people *studied*; the
institutional side of 3–5 and 14–15a had never been joined to an employer.

The two company lists are answered through **`rcid`**, Revelio's company key. The universities are
answered by name, because no company list contains them and Revelio ranks nothing.

```
the two company CSVs ──18──> 468 rcids ─┐
                                        ├──19──> firms_positions  737,682 rows
obmep_candidates_step_1_position (10a) ─┤        firms            436,813 users
obmep_candidates_step_1_position_rcid ──┤
ruf_stem_top10_institutions (15, 15a) ──┤
shanghai_ranking_oa (4) ────────────────┘
```

### One classifier, two institution lists

`rf_` and `sw_` are the *same* arm reading different tables. `classify()` takes its institution
tables as arguments and returns neutral columns — `m_rank`, `m_id`, `m_inst` — so nothing in the
matcher knows which list produced a row. It runs four times: two source columns × two lists.

That refactor is the risky part of adding `sw_`, and the thing that proves it was
behaviour-preserving is that **all nine pre-existing arm counts are unchanged to the digit** against
the run before it. If they ever move, the refactor broke and no other number will say so.

**`sw_` has no acronym arm**, and that is a property of the source rather than a judgement about
risk: `shanghai_ranking_oa.parquet` carries no abbreviation column, so there is nothing to fold.
The acronyms were reachable by joining `OA_id` to OpenAlex's `display_name_acronyms`; that was
deliberately not done. The resulting line is clean — **an acronym arm exists exactly where the
source supplies acronyms**, so the Shanghai list matches bare acronyms on neither side, which is
the same limitation script 16 already carries for degrees. `inst_ab_sh` is created empty so
`classify()` keeps one code path, and the script aborts if the acronym arm ever fires on it.

The homonym exposure is larger here than on the RUF side — 1,000 institutions worldwide against 23
Brazilian ones, and teaching hospitals and affiliated institutes are a second source of near-misses.
Reported, not fixed: `sw_by_raw`, `sw_rank` and `sw_inst` are what make a suspect match auditable.

## `rcid` was never extracted, and that is why 10b exists

Script 10a unloaded 12 columns of `academic_individual_position` and none of them identifies a
company. It has `company_raw`, `company_cleaned` and `company_linkedin_url` — three strings.
`company_linkedin_url` is NULL on 28% of positions, so matching on it alone throws away more than a
quarter of the evidence before starting.

`academic_individual_position` actually has **47 columns**. The ones 10a left behind that matter
here:

```
rcid bigint   ultimate_parent_rcid bigint   company_name string
ticker string   exchange string   country string
```

Note that `country` is among them: **criterion A_country reads a column the local extract does not
carry.** Anything needing position-level country locally has to go back to Athena.

10b unloads four integer columns — `user_id, position_id, rcid, ultimate_parent_rcid` — and nothing
else. `position_id` joins it back to 10a. Re-running 10a to add `rcid` would re-scan the 422.3 GB it
measured; this scans **40.43 GB for about $0.20**, and cost is set by columns read, not by how the
filter is written.

It is stored **whole** rather than filtered to the ~500 firms of interest. Filtering in Athena would
scan identical bytes for identical money and the next change to the company lists would pay it
again. Stored whole, every later employer question is offline and free.

### The check that this extract rests on

10a and 10b are two separate scans of a live table. If Revelio refreshed between them, `position_id`
is not a safe join key and every downstream join is silently partial. So 10b anti-joins its
`position_id` set against 10a's **in both directions** and aborts on any difference. Both came back
0, and the row count (30,389,044) and distinct-user count (6,849,674) match 10a exactly.

`rcid` resolves on **78.7%** of positions (23,901,223 rows, 2,089,051 distinct firms). The missing
21.3% is not a defect — Revelio assigns a company key when it can and leaves the raw strings
otherwise.

## `academic_company_ref` is one row per company

The reference table was not in this repo's Glue stubs and its grain was not assumed. Measured:
**26,596,058 rows, 26,596,058 distinct `rcid`** — one row per company, and `count(*)` against
`count(DISTINCT rcid)` runs before any join so a future change to that shows up as a number rather
than as a fan-out.

It carries `linkedin_url` directly, which is why script 18 needs no name matching at all. Reading
the handful of columns it needs costs well under a cent against a 6.35 GB table.

**`rcid` is `int` here and `bigint` on the position table.** Cast on every join between them.

## Two arms, and the 10% that got away

| arm | rule | resolved |
|---|---|---|
| 1 | normalised `linkedin_url` = a listed URL | **468** |
| 2 | normalised `child_linkedin_url` = a listed URL → `child_rcid` | **0 new** |

Both sides are folded the same way — lowercase, drop the scheme, drop `www.`, drop query and
fragment, drop trailing slashes. Revelio stores its URLs as `http://linkedin.com/company/<slug>` and
the researched CSVs as `https://www.linkedin.com/company/<slug>/`; the fold is what makes those the
same string. The patterns contain **no backslashes** — `[.]`, not an escape — which is trap 4.

Arm 2 added nothing: every `child_linkedin_url` it matched was already matched by arm 1. It stays,
because its value is the guard, not the yield — precedence is structural, and two `rcid`s inside the
winning arm is an assertion failure rather than a tie to break.

Of 529 listed rows carrying a URL (521 distinct), **468 resolve and 53 do not**. The 53 are the real
limitation of this file, not the 12 with no URL at all. LinkedIn lets a company page carry a vanity
slug beside its canonical one, and the hand research and Revelio recorded different ones. **Zoom,
Cadence, Expedia, Gen Digital, Coherent, Block and X are all in this group** — they are not missing
from Revelio, they are missing from this join.

### Two rescue arms were measured and rejected

**Ticker.** Only 13 of the 53 carry a `Symbol` at all, and only 3 resolve to exactly one `rcid`
(Cadence `CDNS`, Coherent `COHR`, Expedia `EXPE`). Credo gives 2, Qnity 2, Gen Digital 5. Three
companies is not worth an arm, and the ambiguous ones would need hand adjudication anyway.

**Company name.** Actively harmful, and now measured on this data rather than argued from the
institution lists:

```
Block -> block-workspace | block
X     -> yakirox-cagri-hizmetleri | x_2
Labs  -> laboratoryofsales | 070301-labs | labsstudio
Cars  -> carsvtc | 2b-panzer-company
```

Short company names are exactly the false-positive surface the README already warns about for
institutions, and companies are worse than universities because the short names are real ones.

### Arm 3 recovers a quarter of the 53, for free

Script 19 has something script 18 does not: the cohort's own 30 million positions, each carrying
both `company_linkedin_url` and — via 10b — the `rcid` Revelio assigned it. Joining the unresolved
listed URL to that map recovers the key Revelio actually uses, still by exact URL equality, with no
name matching anywhere.

It recovered **13 of 53** — Zoom, Cadence, Coherent, Block, X, Mihoyo, Glean, Lambda Labs, Reify
Health, Dewu, JDT, Yangtze Memory, GTA Semiconductor — worth **499 unicorn users and 717 market-cap
users**. A URL is accepted only if it maps to **exactly one** `rcid` across the whole cohort; Gen
Digital was the single rejection, at 2. Taking the commonest instead would be a threshold nobody
chose.

Arm 3 cannot recover a firm no cohort member ever worked at, which costs nothing: such a firm could
not have produced a match either way. It does mean "the URL did not resolve" and "nobody worked
there" are only separable because 18 reports them separately.

## The university side is C_norm again

Same criterion as 16, on a different column. The institution side is three full spellings per
institution — the RUF `institution_name`, the OpenAlex `display_name`, and its de-parenthesised form
from 15a — folded and deduplicated into **29 strings**. Matched against `company_raw` and
`company_cleaned`, raw taking precedence, on the whole string or any `/`, `( )`, `" - "` delimited
segment of at least 3 characters.

**The segment arm is inert on `company_cleaned`, deliberately.** Revelio has already stripped the
punctuation the split keys on: `Secretaria Municipal de Saúde - SESAU` arrives as
`secretaria municipal de saude sesau`. The arm is applied to both columns anyway so that the only
difference between them is which column they read — the same discipline 16 uses.

### The acronym arm, and why it is its own column

`rf_abbr` matches the bare abbreviation — USP, Unicamp, UFRJ, ITA, FEI — on **whole-string equality
only**, never through a segment. It is the arm most likely to be wrong: USP is also United States
Pharmacopeia, FEI is also an unrelated manufacturer, and UEM, UFG and ITA are three letters. Keeping
it separate means a consumer who does not want it writes `WHERE rf_abbr = 0` instead of asking for a
rebuild. An abbreviation that ever folds to the same string as a full institution name would make
the two arms indistinguishable, so that collision is asserted against.

**It came out clean.** All 30 strings it alone matched are unambiguous Brazilian university
acronyms typed as an employer — UTFPR (3,371 users), UFMG (2,109), UNESP (1,609), UFRGS, UFRJ, UFPE,
UFPR, UFSCar, USP, FEI, ITA and their case variants. No Pharmacopeia. That is a property of **this**
cohort, which is Brazilian by construction, and it would not survive being pointed at a general
population.

### It flags employment, not study

Someone with a USP *degree* is flagged by 16. Here they had to have **worked** there — in Brazil
mostly faculty, staff, or a scholarship-funded research post recorded as a position.

## Measured

| | users | |
|---|---|---|
| **flagged, any list** | **436,813** | 6.38% of the cohort |
| unicorn | 28,735 | exact 24,465 · parent 24,379 |
| market cap | 159,638 | exact 118,752 · parent 145,188 |
| RUF top 10 | 142,151 | name 129,389 · abbr 15,423 |
| Shanghai top 1000 | 233,290 | name only — no acronym arm |

737,682 matched positions behind them. The Shanghai arm adds **116,541 users no other arm reached**;
it overlaps `rf_` on 109,400.

**`rf_` without `sw_` is 32,751 users, and that is explained rather than leaked.** Only 14 of the 23
RUF institutions are in the Shanghai top-1000, so nine of them *cannot* have an `sw_` match — UTFPR
6,467, UFBA 4,206, UFU 4,077, UFLA 3,136, UFABC 3,026, UEM 2,737, Mauá 944, FEI 805, ITA 561, which
is 25,959 of the 32,751. Nearly all the rest came in through the acronym arm `sw_` does not have:
9,628 of the 32,751 have `rf_name_any = 0`, for instance UFMG 1,609 of 1,619 and UFRGS 1,062 of
1,064. Do not "fix" this.

**The orderings are the check that matters, and they read right.** A Brazilian cohort's unicorn
employers are Brazilian unicorns — QuintoAndar 4,543, Creditas 3,730, Rappi 3,138, Didi 2,964,
SumUp 1,423, Kavak 1,132. Market cap goes IBM 18,612, Amazon 17,188, Uber 11,458, Alphabet 8,436,
Microsoft 7,571. RUF reproduces the RUF ordering itself: USP 19,303, UFMG 12,521, UFRJ 12,294,
Unicamp 10,846. Shanghai gives USP 19,040, UNESP 13,465, UFRJ 11,251, UFMG 10,740, Unicamp 10,575 —
a Brazilian cohort's top-1000 employers are Brazilian, as they should be, and the first
non-Brazilian entry is the University of Florida at 1,344, an order of magnitude down.

## What the name match misses

A floor, not an estimate: **3,211 positions** point at one of the 23 institutions' own
`linkedin.com/school/<slug>` pages without any name arm catching them, against ~200k matched. It is
a floor because the diagnostic joins the slug to the folded **acronym**, so it only sees the 9
institutions whose slug happens to be their acronym. The true gap is larger.

This is reported and is **not** a flag. Turning the school URL into a fourth arm would be a
defensible change; it has not been made, so the number stands as the honest measure of what
exact-after-normalisation leaves behind.

## Stored-but-not-filtering, again

Every widening ships beside its narrow version: `un_exact_any` beside `un_parent_any`, `rf_name_any`
beside `rf_abbr_any`, `un_arm3_any` marking whatever entered through arm 3, and `rf_raw_any` /
`sw_raw_any` recording whether `company_raw` alone was enough. Any of them reverses with a `WHERE`
clause.

Only **flagged** users are written, as 16 does. Left-joining back to `obmep_candidates_step_1` and
reading a missing row as zero is the consumer's job.

## Re-running

```powershell
Rscript prep/building_external_data/linkedin_company_rcid.R          # Athena, ~$0.03
Rscript prep/building_external_data/obmep_candidates_step_1_firms.R  # offline, free
```

Both just re-run; they overwrite their own parquet. **10b is the only stage that ever needs paying
for twice**, and rebuilding it needs the prefix cleared first, because `UNLOAD` refuses a non-empty
destination:

```
DROP TABLE IF EXISTS revelio_database.obmep_candidates_step_1_position_rcid
aws s3 rm s3://revelio-misc/exports/obmep_candidates_step_1_position_rcid/ --recursive
```

Changing either company list, or the RUF `rank_cut`, re-runs 18 and 19 only.

---

# Top-10 RUF degrees

Script 20. The last cell of the 2×2: **does this person hold a bachelor's, master's or PhD from one
of the 23 RUF top-10 STEM universities?**

There is no new logic in it. It is script 16's structure — the C_norm classifier over
`obmep_candidates_step_1_education`, then the level cascade from `br_degree_patterns.R` — pointed at
script 19's institution list, folded the same way from the same two files.

```
obmep_candidates_step_1_education (10a) ─┐
ruf_stem_top10_institutions (15, 15a) ───┼──20──> ruf_degree  583,570 users
br_degree_patterns.R (7) ────────────────┘                    750,309 matched rows
```

## Why it is not redundant with `sh_`

Because only **14 of the 23** RUF institutions are in the Shanghai top-1000. **133,940 of the
583,570 flagged users are absent from `obmep_candidates_step_1_shanghai.parquet`**, and they
concentrate exactly on the nine that Shanghai does not rank:

| | users found only by `rd_` |
|---|---|
| UTFPR | 26,988 |
| UFBA | 22,383 |
| UFU | 19,073 |
| UFABC | 15,195 |
| UEM | 13,741 |
| UFLA | 10,018 |
| FEI | 7,826 |
| Mauá | 5,407 |
| ITA | 1,997 |

That is 122,628 of the 133,940. Almost all the remainder is Unesp (9,056), whose RUF spelling
matches where its Shanghai spelling does not. Without this stage those degrees are invisible.

And even for the 14 in both lists, the two are different claims: RUF ranks **Brazilian institutions
per STEM course**, Shanghai ranks **research output globally**.

## Measured

| | users |
|---|---|
| **flagged** | **583,570** — 8.52% of the cohort |
| `rd_bachelor` | 515,608 |
| `rd_master` | 118,332 (strict 98,674) |
| `rd_phd` | 31,248 |
| `rd_lato` | 14,129 |
| by name arm | 576,040 |
| by acronym arm | 9,019 |

**The ordering is the validation** and it reads right: USP 93,367, UFRJ 50,310, UFMG 43,242, UnB
36,550, UFPR 31,815, UFSC 31,424, Unicamp 30,290, with ITA closing the list at 2,247 — what a small,
highly selective school should look like.

The **acronym arm came out small and clean**: 9,019 users, 1.5% of the total, against the 1.5–2.5%
the README measures for bare acronyms generally. The 30 strings it alone matched are all unambiguous
Brazilian acronyms — UFSCar 2,001, UTFPR 1,274, FEI 1,150 and case variants. No United States
Pharmacopeia. It stays in its own column, `rd_abbr_any`, so `WHERE rd_abbr_any = 0` reverses it.

It inherits every one of script 16's limitations unchanged: a bare acronym reaches only the acronym
arm, homonyms match wrongly, Revelio records enrolment rather than graduation so `mestrando` sets
the flag, and `degree` wins over `degree_raw` on disagreement.

---

# The selected candidates

Script 21. One row per user flagged by **any** of the three flag products, carrying each one's
headline columns plus the person's `fullname`.

```
obmep_candidates_step_1_shanghai   (16)  990,937 ─┐
obmep_candidates_step_1_ruf_degree (20)  583,570 ─┼──21──> selected  1,297,109 users
obmep_candidates_step_1_firms      (19)  436,813 ─┤                  47 columns
linkedin_names/linkedin_chunk_*.parquet ─────────┘
```

## The union *is* the selection

All three inputs write **only flagged users** — script 16 puts the literal `1` in `sh_any`, script 20
does the same in `rd_any`, script 19 in `firm_any`, and all three abort if a row disagrees. So "any
flag is 1" is not a `WHERE` capable of excluding anything: it *is* the contents of the files. Script
21 therefore writes a `FULL OUTER JOIN` and no filter at all.

| | users |
|---|---|
| **selected** | **1,297,109** — 18.94% of the cohort |
| with a `fullname` | 1,296,321 — **99.94%** |
| studied at either list | 1,124,877 |
| worked at any of the four | 436,813 |

The seven-way Venn: `sh_` only 418,557 · `sh_`+`rd_` 334,981 · firms only 172,232 · `sh_`+firms
122,750 · all three 114,649 · `rd_` only 106,758 · `rd_`+firms 27,182.

## Two things to know before reading a row

**Absent-side flags are `0`; absent-side ranks are `NULL`.** A user present in only one input has no
values for the others. The 0/1 flags get `coalesce(…, 0)` so that `sh_any = 1 OR rd_any = 1 OR
sw_any = 1` reads without NULL traps. Rank, institution, firm and year columns stay `NULL`, because
there is no zero for "no rank" — `0` would be the *best* possible rank and would poison any `min()`
downstream. `in_shanghai` / `in_ruf_deg` / `in_firms` are the authoritative presence markers.

**A `NULL` `fullname` means "absent from the names snapshot", not "no name".** The 20 name chunks are
dated 2025-07-01 against a cohort rebuilt in August 2026, so a coverage gap is expected. It turns out
to be 788 people. The join is `LEFT` on purpose: a user without a name keeps their flags and never
drops out of the selection.

## The trim, and what it costs

This is the one table in the folder that does **not** carry every narrow variant. It takes one
headline flag per concept plus rank, institution/firm and first year, and leaves behind the
`_exact` / `_parent` / `_arm3` / `_raw` variants, `_master_strict`, `_lato`, and every `n_*` count.

Nothing is lost — the three source products still hold all of it, keyed on `user_id` — but the
folder's usual promise is weaker here: **tightening a definition means re-joining rather than
filtering this table alone.**

It is also the only product in the folder carrying direct personal data. The others are `user_id`
and flags; this one has the civil name. Treat it accordingly.

## Re-running

```powershell
Rscript prep/building_external_data/obmep_candidates_step_1_ruf_degree.R  # offline, ~1 min
Rscript prep/building_external_data/obmep_candidates_selected.R           # offline, ~1 min
```

21 depends on 16, 19 and 20, so re-run it after any of them. The name scan reads all 15.2 GB of the
20 chunks — the files hold only `user_id` and `fullname`, so there is no column pruning to exploit —
but a `SEMI JOIN` against the ~1.3M-row build side keeps the other ~707M rows from materialising,
and it finishes in well under a minute.


---
---

# The alternative selected table: RUF replaced, Shanghai widened

Scripts **21alt** and **21a-alt**, local and offline. `obmep_candidates_selected_alt.R` is a copy of
script 21 with two definition changes. **Script 21 and `obmep_candidates_selected.parquet` are not
modified** — the two definitions live side by side, as `obmep_candidates_step_1_alt` does next to
`obmep_candidates_step_1`. `_alt` is a **parallel definition, not a successor**: script 21 remains
the canonical selected table until someone decides otherwise.

```
16  shanghai_top1000_degree_flags.R    sh_       990,937
20  obmep_candidates_step_1_ruf_degree.R  rd_    583,570   -> provenance only
19  obmep_candidates_step_1_firms.R    un_/tc_/rf_/sw_
8g  ruf_shanghai_rsid_degree_flags.R   _rsid_    729,347
16a shanghai_acronym_arm.R             sh_acr_    10,907
                                    -> obmep_candidates_selected_alt.parquet
                                       1,315,248 rows, 53 columns
                                    -> obmep_candidates_selected_positions_alt.parquet
                                       7,386,220 positions, 170.3 MB
```

## RUF is replaced, Shanghai is widened, and the asymmetry is forced

Both new arms come from the same safe `rsid → OpenAlex` map. That map was built from
`openalex_institutions_br` — **1,947 Brazilian records** — so what it can reach is decided by
geography, not by quality:

| | institutions reached | consequence |
|---|---|---|
| **RUF** | **23 of 23** | a complete rebuild of the concept, so `rd_` now comes from it |
| **Shanghai** | **18 of 1,079** (1.7%), exactly the Brazilian ones | Harvard, MIT and Cambridge have no row in that map |

Replacing `sh_` with the rsid arm would drop **413,557 people**. So `sh_` becomes the **union** of
script 16, the rsid arm and the acronym arm, and `rd_` becomes a **replacement**.

## What it costs and buys

| | canonical | `_alt` |
|---|---|---|
| `rd_any` | 583,570 | **632,464** |
| `sh_any` | 990,937 | **1,020,485** |
| rows | 1,297,109 | **1,315,248** |
| name coverage | 99.94% | 99.94% |

**20,278 people enter and 2,139 leave.** The script asserts that every one of the 2,139 had *only*
script 20's RUF name flag and nothing else — if anyone left for another reason it aborts rather than
publishing. They remain in `obmep_candidates_selected.parquet`, untouched.

Of the 13,406 who lose the `rd_` flag, 9,717 keep a Shanghai flag, 2,945 a firm flag and 1,104 the
acronym arm, so most stay in the table on other evidence.

`rd_name_any` sums to **581,431** here, not to script 20's 583,570 — the difference is exactly the
2,139 who are no longer selected. If those two numbers ever differ by anything else, something is
wrong.

## Provenance lives in columns, so any widening is a `WHERE`

| column | meaning |
|---|---|
| `sh_name_any` | script 16's definition — what `sh_any` means in the canonical table |
| `sh_rsid_any` | the rsid arm — **Brazilian slice only**, see above |
| `sh_acr_any` | the acronym arm |
| `rd_name_any` | script 20's definition, the one being replaced |
| `rd_abbr_any` | script 20's abbreviation arm |

`in_shanghai`, `in_firms`, `in_rsid_deg` and `in_sh_acr` are the four presence markers that **define
the selection**. `in_ruf_deg` is present but is *provenance, not criterion* — a user known only to
script 20 does not enter this table. The `bad_none` assertion checks the four, not the five.

## Per-level values are built by stacking, not by comparing columns

The three Shanghai arms are unpivoted into one row per (user, level, arm) and aggregated once with
`min(rank) FILTER` and `arg_min(inst, rank) FILTER` — the same idiom as scripts 16, 20 and 8g.

**Do not replace this with a three-way `CASE` over the rank columns.** DuckDB's `least()` ignores
NULLs (see *Two traps that must not be reintroduced*), which here would happen to give the right
answer — and depending on behaviour this README flags as a trap is exactly how the next person gets
hurt. Stacking makes the NULL handling explicit.

## What 8g and 16a had to grow first

Script 21 carries `rd_bach_inst`, `rd_bach_year` and their master/PhD counterparts. **8g emitted
none of them** — only `best_rank` and `best_inst` — so replacing RUF would have silently dropped six
columns of level detail. Both producers were extended before this table existed:

- **8g** now emits `{rd,sh}_rsid_{bach,mast,phd}_{rank,inst,year}`. Marked population unchanged at
  729,347 / 632,464 / 601,648.
- **16a** now emits `sh_acr_{bach,mast,phd}_year`. Marked population unchanged at 10,907.

Both changes are strictly additive — new columns, no row and no existing value altered.

`rank` and `inst` must agree with the level flag **in both directions**; `year` only in the
direction *value present ⇒ flag set*. A flagged level with no year is normal, because `year` comes
from `startdate` and `startdate` is sometimes missing. Measured: script 16 has 2,754 of 856,076
users with `sh_bachelor = 1` and `sh_bach_year` NULL; 8g's rates are the same order (1,847 of
559,491 for `rd_rsid_bach_year`).

## The two provenances are not equally trustworthy

**The acronym arm was reviewed by hand** — 209 strings, verdicts and reasons readable in
`shanghai_acronym_class.xlsx`.

**The rsid arms were not**, at that grain. They rest on the safe one-to-one map plus an evidence
floor of 25 rows. 8g's header records one error class it cannot eliminate: a string that matched
nothing, sitting under a good rsid, denoting a different institution. The measured case is
**"FAC UNICAMPS – Faculdade Unida de Campinas"** (Goiânia) attributed to Unicamp, **671 users, about
1% of the RUF gain**. That now rides inside `rd_any` in this table, not only in 8g's output.

Every caveat in `rsid_openalex_one_to_one.R` travels too: 12 rsids excluded as FAMILY or WRONG_DOM,
the verdicts behind that LLM-written, and AFFILIATE rsids included — so a teaching hospital's rows
count toward its medical school.

## Re-running

```powershell
Rscript prep/building_external_data/ruf_shanghai_rsid_degree_flags.R          # offline
Rscript prep/building_external_data/shanghai_acronym_arm.R                    # offline
Rscript prep/building_external_data/obmep_candidates_selected_alt.R           # offline, ~1 min
Rscript prep/building_external_data/obmep_candidates_selected_positions_alt.R # offline
```

The script refuses to write if `out_path` ever resolves to the canonical table, and it captures the
canonical file's size and mtime before running and re-checks them at the end — if that file moved,
it aborts instead of reporting success.

Beyond script 21's own invariants it also asserts: `sh_any` is exactly the union of the three arms;
`sh_name_any` is never 1 where `sh_any` is 0 (a widening that removes people is a bug); `rd_any`
equals the rsid arm exactly, with no residue of script 20; no Shanghai rank without a level flag and
no institution without a rank; and the departure check described above.

---
---

# Role and location for the selected candidates

Scripts **10c** and **21a**. 10c is local and **online** — one Athena `UNLOAD` → S3 → external
table → `aws s3 sync` to Dropbox. 21a is offline. Neither is SEDAP-bound.

Script 21 answers *who* was selected. Neither it nor 10a/10b answers what those people **do**: 10a
took 12 columns of 47 and 10b added 4, and between them they describe where somebody worked and what
the employer is called. Revelio's own classification of the job — and of the place — was left behind
silently, exactly the way `rcid` was.

```
academic_individual_position  (47 cols, 685 GB)
    --10c--> obmep_candidates_step_1_position_role_loc   30,389,044 rows
             s3://revelio-misc/exports/obmep_candidates_step_1_position_role_loc/
             OBMEP/Data/intermediate/revelio_br_cohort/obmep_candidates_step_1_position_role_loc/

obmep_candidates_selected  (21)  1,297,109 users ─┐
                                                  ├──21a──> selected_positions
obmep_candidates_step_1_position_role_loc  (10c) ─┘         7,285,037 rows, 18 cols
```

## Columns

```
user_id, position_id,
job_category, role_k50, role_k150, role_k300, role_k500, role_k1000, role_k1500,
seniority, position_number, onet_code, onet_title,
location_raw, country, region, state, metro_area
```

`seniority` and `position_number` are **`smallint`**, not `int`. That matters more than it looks:
`validate_sql_syntax.R`'s `type_class()` deliberately folds every integer width into one class (its
note 3), so the offline validator **cannot** catch a wrong width here — it binds cleanly and then
breaks on read. The DDL was set from the Glue catalogue directly, not from the stub.

The role ladder is `job_category` → `role_k50` → `k150` → `k300` → `k500` → `k1000` → `k1500`.
There is no `role_k7`; `job_category` is the top level.

## Why cohort-wide, and why not restricted to the 1.3M

10c applies 10a's semi-join unchanged — all 6,849,674 cohort users, all 30,389,044 positions — and
21a does the cut to the selected set offline. Three reasons, in order of weight:

- **It would not have saved a cent.** Cost is set by which columns are read, not by how the filter
  is written; `user_id` is scattered across row groups so Athena prunes none. Measured three ways in
  [The semi-join is for correctness, not cost](#the-semi-join-is-for-correctness-not-cost).
- **`obmep_candidates_selected.parquet` is not in Athena.** Script 21 is offline end to end, so
  cutting to it in SQL would mean uploading and registering it first, for zero saving.
- **The anti-join only works if the keyspaces match.** Sharing 10a's exact `WHERE` is what lets 10c
  prove, rather than assume, that its `position_id` set is identical to 10a's.

A cut can be tightened offline later. A scan cannot be un-paid.

## Predicted cost, and the footer method finally written down

[Measured cost](#measured-cost) says the parquet-footer method "is worth reusing before any wide
extraction from these tables" but never says how. For 10c it was run properly, and it is worth
recording because it is now calibrated:

| | predicted | actual |
|---|---|---|
| 10b, four integer columns | **40.5 GB** | 40.43 GB |
| 10a, position, 12 columns | 450.2 GB | 422.3 GB |
| **10c, 18 columns** | **85.2 GB ≈ $0.42** | **81.32 GB — $0.41**, 24.2 s |

10c came in **4.8% under** the prediction, the same direction and roughly the same magnitude as
10a's 6.6%. Two independent confirmations that the footer method is an upper bound, not a coin flip;
the next wide extraction from this table can be budgeted from it with confidence.

The recipe: `SHOW CREATE TABLE` for the source `LOCATION`
(`s3://revelio-data/academic_individual_position/`, 2,625 objects / 638.0 GiB), pull **one full-size
object** — sizes vary by more than 10×, and a small one skews the fractions — then

```sql
SELECT path_in_schema, sum(total_compressed_size)
FROM parquet_metadata('<file>') GROUP BY 1
```

and scale each column's share by 685 GB. **Use DuckDB, not arrow**: the R `ParquetFileReader`
(25.0.1) exposes `GetSchema`/`ReadRowGroup` but no metadata accessor, so per-column compressed sizes
are not reachable from R's arrow at all.

On the calibration above the method reproduced 10b to within 0.2% and over-predicted 10a by 6.6%, so
treat it as an upper bound. `location_raw` is the single fattest of the 18 (5.4% of the table, about
37 GB — roughly all six `role_k*` put together) and was kept anyway: at ~$0.18 it is not worth a
second scan later. `description`, for scale, is 32% of the table on its own.

## Traps

### 1. `country` is now local, and the old warning is stale

Criterion A_country reads `academic_individual_position.country`. Before 10c that column existed
only in Athena, and [These are 12 columns of 47](#these-are-12-columns-of-47-and-two-of-the-absences-matter)
said so. It no longer holds — the column is in 10c, and 10c reports the `country = 'Brazil'` position
and user counts on every run as a free consistency check against criterion A. It reports them; it
does not gate on them.

### 2. The 10c directory has no `.parquet` extension, so `*.parquet` matches nothing

Same as 10a and 10b: Athena `UNLOAD` names objects `<query-id>_<uuid>`. In DuckDB the glob is
**bare** — `read_parquet('<dir>/*')` — and in R it is
`arrow::open_dataset(dir, format = "parquet")` with `list.files()` called without a pattern. 21a
would otherwise abort saying the directory is empty.

### 3. `country`, `region`, `state` and `metro_area` say **`'empty'`**, not NULL

The single most dangerous thing in this extract, found on the first run. The four *derived*
geography columns mark a missing value with the **literal string `'empty'`**. They contain zero
NULLs and zero empty strings, so:

```sql
count(country)              -- reports 100% coverage.        WRONG
WHERE country IS NULL       -- returns nothing.              WRONG
WHERE country <> 'empty'    -- correct
```

Cohort-wide, the sentinel accounts for 430,327 rows in `country` and `region`, **1,759,640 in
`state`** (5.8%) and 512,800 in `metro_area`. It is also counted by `count(DISTINCT …)`, so the 245
distinct countries are really 244 plus a sentinel.

`location_raw` and `onet_code`/`onet_title` do **not** do this — they use real NULLs. Two
missingness conventions coexist in one table, split exactly along raw-versus-derived. Both scripts
now exclude the sentinel explicitly when reporting coverage, and 21a excludes it from its
most-common-values listing; nothing else in the repo does, because nothing else has read these
columns yet.

### 4. Nothing had ever read these columns, so no fill rate is asserted

Neither script asserts a fill rate for any role or location column — the repo had not touched them
before. Both **report** every rate. The first production run established the figures below, and
they are now recorded in both script headers.

### 5. 21a's output is position-grain

`position_id` is unique in it; `user_id` is not. Counting people means `DISTINCT user_id`; counting
rows counts jobs. The file deliberately carries no company, title or dates — those live in 10a, and
`rcid` in 10b. All three cover the same `position_id` set (10c aborts if they do not), so join on
`position_id`. Note that 10a's `startdate` is **STRING**, not DATE — README trap 1.

## Measured

Both run, 2026-08-31.

**10c** — 81.32 GB scanned, **$0.41**, UNLOAD 24.2 s, sync 0.35 min. 30,389,044 rows /
6,849,674 users, `position_id` unique, anti-join to 10a **0 both ways** — the two extracts saw the
same Revelio snapshot, so `position_id` is a safe key across 10a, 10b and 10c. 0.83 GB in 30 parts.

**21a** — 7,285,037 positions, **1,297,109 distinct users** (every selected user, asserted),
**5.62 positions per user** against the cohort's 4.44. Not noise: the selected are the ones with
Shanghai/RUF degrees or top-firm employment, and they have longer histories. 167.9 MB ZSTD.

Coverage, sentinel excluded (trap 3). Cohort-wide from 10c, then the selected subset from 21a:

| column | 10c (cohort) | 21a (selected) | distinct |
|---|---|---|---|
| `job_category` | 100% | 100% | **7** |
| `role_k50` … `role_k1500` | 100% | 100% | exactly 50 / 150 / 300 / 500 / 1000 / 1500 |
| `seniority` | 100% | 100% | 7, range **1..7** |
| `position_number` | 100% | 100% | range **1..128** |
| `onet_code` / `onet_title` | 99.3% | 99.5% | 383 |
| `location_raw` | 99.9% | 99.9% | 863,897 / 309,261 |
| `country` | 98.6% | 98.4% | 245 / 242 incl. sentinel |
| `region` | 98.6% | 98.4% | 16 / 15 |
| `state` | 94.2% | 93.3% | 2,991 / 2,498 |
| `metro_area` | 98.3% | 98.0% | 837 / 826 |

Three things worth carrying forward:

- **`job_category` is the k7 level.** It has exactly 7 values — Admin 24.7%, Engineer 22.0%,
  Sales 15.3%, Marketing 14.0%, Scientist 12.1%, Finance 6.9%, Operations 5.1% (selected subset).
  There is no `role_k7` column; this is it.
- **The role ladder is exact.** Every `role_k<N>` has precisely N distinct values and 100%
  coverage. It is a clean nested taxonomy, not a best-effort one, so a coarser level can always be
  derived and there is never a NULL to handle. **Coverage is not accuracy** — script 10d audited
  500 of these rows against `title_raw` and found `job_category` right 84.2% of the time and
  `role_k1500` 63.7%, with 6% of the file carrying a contentless title for which the label is a
  guess. Read
  [Do the role labels actually fit the title?](#do-the-role-labels-actually-fit-the-title)
  before using any of these columns.
- **`country = 'Brazil'` is the literal spelling**, so criterion A_country transfers to local code
  unchanged. Cohort-wide it is 23,045,785 positions (75.8%) over 5,671,650 users. **For the
  selected subset it drops to 60.1%** — the selected work abroad substantially more often than the
  cohort they were drawn from. That is a finding about the selection, not about the data.

5.62 against the cohort's 4.44 is not noise: the selected users are the ones with Shanghai or RUF
degrees or top-firm employment, and they have longer histories. The distinct-user count is the
assertion the whole script rests on — every selected user is a step_1 member, and criterion D admits
nobody without a parseable position date, so a short count means the join bound to the wrong column
rather than that the data is thin.

## Re-running

10c needs an empty prefix and about **$0.42**:

```
DROP TABLE IF EXISTS revelio_database.obmep_candidates_step_1_position_role_loc
aws s3 rm s3://revelio-misc/exports/obmep_candidates_step_1_position_role_loc/ --recursive
```

```powershell
Rscript prep/building_external_data/obmep_candidates_step_1_position_role_loc.R  # online, ~1 min
Rscript prep/building_external_data/obmep_candidates_selected_positions.R        # offline, ~1 min
```

21a depends on 21 and 10c, so re-run it after either. Its `exp_selected` aborts rather than warns —
if script 21 is rebuilt to a different size, that constant is meant to be updated deliberately, not
silently absorbed.

---
---

# Do the role labels actually fit the title?

Script **10d**, `role_title_audit.R`. Offline, read-only with respect to the pipeline.

10c measured that the role columns are **100% filled**. It did not measure whether they are
**right**. This does, on 500 positions drawn at random from the 7,285,037 in
`obmep_candidates_selected_positions.parquet`, judged against `title_raw`.

## The verdict is ordinal, because the ladder is a tree

Verified on every run, across all 7.28M rows: each `role_k50` has exactly one `job_category`,
each `role_k150` exactly one `role_k50`, and so on — **zero multi-parent nodes at any of the six
links**, each level at exactly its nominal cardinality. So a row carries one root-to-leaf path,
not seven independent labels, and the natural judgment is **the deepest level at which the path
still describes the title**. Every level's accuracy is derived from that one call, and the
results cannot contradict each other.

Judgments are made against `title_raw`, never `title_translated` — the translation is wrong often
enough to poison the exercise (`"Garçonete"` → `"boy"`, `"Presidente"` → `"resident"`).

## Measured — n=500, 2026-08-31

443 decidable; **57 (11.4%) undecidable**, held out of the denominator because the title carries
no occupation at all and a classifier cannot be charged for that.

| level | accuracy | exact 95% CI |
|---|---|---|
| `job_category` | **84.2%** | [80.5, 87.5] |
| `role_k50` | 81.0% | [77.1, 84.6] |
| `role_k150` | 74.3% | [69.9, 78.3] |
| `role_k300` | 71.3% | [66.9, 75.5] |
| `role_k500` | 68.2% | [63.6, 72.5] |
| `role_k1000` | 66.4% | [61.8, 70.8] |
| **`role_k1500`** | **63.7%** | [59.0, 68.1] |

In **14.0%** of rows the top-level `job_category` is already wrong — not a deep-taxonomy quibble
but a wholesale misfiling. By category, `job_category` accuracy runs from 94.1% (`Scientist`) down
to 76.9% (`Sales`), with `Marketing` 79.2% and `Admin` 80.0%; those subsets are small and the
intervals wide.

Of the 161 paths with an error somewhere, **31 (19%) had no better label available** — a limit of
the vocabulary, not of the classifier. The other 81% missed a label that existed.

## The finding that matters more than the rate

**100% coverage is not 100% knowledge.** When the title carries no occupation, Revelio does not
return null — it guesses, and it guesses differently every time. In the sample, `"estagiário"`
appears 8 times and receives **7 different paths**; `"trainee"` 4 times, 4 paths. Across the whole
file:

| `title_raw` | positions | distinct `job_category` | distinct `role_k50` | distinct `role_k1500` |
|---|---|---|---|---|
| `estagiário` | 178,093 | **7 of 7** | 47 | 467 |
| `estagiária` | 97,567 | **7 of 7** | 49 | 672 |
| `intern` | 68,943 | **7 of 7** | 49 | 764 |
| `trainee` | 34,771 | **7 of 7** | 50 | 651 |
| `bolsista` | 25,789 | **7 of 7** | 39 | 230 |

Summing the contentless titles: **434,622 positions, 6.0% of the file**, spread across all seven
categories. For those rows the label classifies nothing, and nothing in the data marks them —
they look exactly like the 94% that were classified from real evidence. Any model that conditions
on `job_category` is, for one row in sixteen, conditioning on a coin flip. Filter on `title_raw`
before trusting a role label, or accept the noise knowingly.

## Failure modes worth knowing

- **Occupations absent from the 1,500-label vocabulary**: dentist, psychologist, physiotherapist,
  veterinarian, nutritionist, agronomist, curator, illustrator. For a Brazilian STEM-graduate
  cohort these are not exotic. They get routed to the nearest available label — a dentist becomes
  `physician`, a physiotherapist `occupational therapist`, an agronomist `laboratory`.
- **No healthcare or education branch.** `Medical Rep` (under `Scientist`) is in practice the
  clinical bucket and `Corporate Trainer`/`Teacher` (under `Admin`) the teaching one. Both are
  misnamed for what they hold, which misleads anyone reading the vocabulary rather than the data.
- **False friends across languages.** `"Stage"` (French for internship) → theatre `Stage Manager`;
  a press office intern → `Press Operator`, a printing-machine role; `"MD Candidate"` → Managing
  Director rather than medical doctor.
- **Catastrophic single rows.** A logistics supervisor and a legal coordinator both landed on
  `unemployed`; a pharmacy resident on `nanny`; a petroleum flow-assurance intern on
  `sandwich artist`; an IT help-desk analyst on `escrow officer`.
- **The same title routed differently.** `"Farmacêutico"` appears three times in the sample and
  gets `pharmacist`, `laboratory` and `nanny`. `"Pesquisador"` → `researcher` but `"Pesquisadora"`
  → `journalist`, the feminine form alone changing the answer.

## How to use these columns

- `job_category` at 84.2% is usable as a coarse control. `role_k1500` at 63.7% is not usable as a
  ground-truth occupation for anything that turns on individual correctness.
- Deeper is not better. Each level costs roughly 3-7 points of accuracy, and `role_k1500` buys
  1,500 categories at the price of being wrong more than a third of the time.
- Drop or flag the contentless titles first; that alone removes 6% of pure noise.
- Precision only. This says nothing about occupations the taxonomy fails to *distinguish* — if one
  label covers two real jobs, both rows score correct here.

## Re-running

```powershell
Rscript prep/building_external_data/role_title_audit.R   # offline, ~1 min
```

First run parks the sample and writes the gabarito skeleton, then stops. Fill `verdict` on all 500
rows and run again for the report. The sample is **not** redrawn while
`role_audit_sample.parquet` exists — the gabarito is keyed to that exact draw. Delete it to force
a new one and expect to reclassify all 500. The seed is re-checked for reproducibility on every
invocation.

## Finance and Engineer, 250 each — `role_jobcat_audit.R` (10f)

The main audit's per-category cells were thin: `Finance` rested on **25** rows spanning a 29-point
interval. Script 10f draws 250 from each of the two categories and asks the binary question only —
does `job_category` describe `title_raw`?

| category | correct | decidable | undecidable | accuracy | exact 95% CI |
|---|---|---|---|---|---|
| **Finance** | 172 | 209 | 41 | **82.3%** | [76.4, 87.2] |
| **Engineer** | 191 | 222 | 28 | **86.0%** | [80.8, 90.3] |

Both landed **below** their small-n estimates (88.0% and 89.9%) while staying inside those wide
intervals — the regression you expect when an interval collapses from 29 points to 11. The practical
correction: **`Finance` is not the strong category the first pass suggested.** At 82.3% it is
indistinguishable from the 84.2% baseline.

`Finance` also carries far more contentless titles — **41 undecidable vs 28** — because finance job
titles (`Vice President`, `Associate Director`, `Business Consultant`, `Manager`) name a rank rather
than an occupation.

The 37 wrong `Finance` rows are spread across every branch (`Accountant` 10, `Investment Specialist`
9, `Client Services` 8, `Billing Specialist` 6, `Financial Advisor` 4) — **not clustered**, so no
single branch can be filtered out. Recurring leaks: Sales bleeding in through `Client Services`
(business development, account managers); bare `Research Assistant` landing under
`Investment Specialist → research analyst` on the word "research"; and statisticians filed as
Finance because `Statistician` sits under `Investment Specialist`.

**Two limits.** These rates are **conditional on the assigned label** and do not combine — Finance is
6.9% of the file and Engineer 22.0%, so a weighted average of the two is not an overall accuracy.
And this is **precision, not recall**: it counts how many rows labelled Finance really are Finance,
and cannot see finance work filed elsewhere. The main audit found an investment-banking intern
labelled `ambassador` and a receivables-product intern labelled `marketing analyst`; neither would
ever appear in a sample drawn from the `Finance` label. Measuring that needs a sample drawn by
**title**.

## Re-judged with `description` — the title-only rate was too generous

Script **10g**, `role_desc_audit.R`. `description` is in the same 10a extract and is populated on
**263 of the 500** sampled rows. The main audit judged against `title_raw` alone, which looked like
an unfairly thin standard. Re-judging **blind** — same ordinal rubric, worksheet reshuffled and
stripped of the earlier verdict — on every description-bearing row, not just the failures.

**The expectation was that accuracy would rise. It fell.**

| level | title only | title + description |
|---|---|---|
| `job_category` | 86.1% [81.0, 90.3] | **78.4%** [72.9, 83.2] |
| `role_k50` | 83.5% [78.1, 88.1] | **70.3%** [64.3, 75.8] |
| `role_k1500` | 68.0% [61.5, 73.9] | **61.4%** [55.2, 67.4] |

Movement went **both ways**, which is what says the blind held: 183 verdicts identical, **18 deeper**
(better), **34 shallower** (worse), 28 leaving `undecidable`, none entering it.

### Two mechanisms, and the first is a flaw in the original design

**1. `undecidable` was flattering the score.** 32 of the re-judged rows had been excluded from the
denominator because the title carried no occupation. With a description, **28 became decidable — and
36% of those are wrong at `job_category`**. They were disproportionately misclassified precisely
because Revelio had as little title signal as the auditor did. Holding them out removed the hardest
cases from the measurement. Any audit that excludes uninformative inputs is measuring an easier
problem than the one users face.

**2. A plausible title can hide a different job.** 15 rows went from fully correct to wrong at the
top level once the description was read:

- `"Global Planning"` → labelled `Engineer`. The description is S&OP, forecasting and monthly KPIs —
  supply planning, i.e. `Operations`.
- `"Analista de laboratório"` → labelled `Engineer`/industrial QA. The description is **clinical**
  exams in haematology, immunology and parasitology — healthcare.
- `"Repositor/Auxiliar"` → labelled `Sales`/retail stocker. The description is restocking parts for
  the **production line**.
- `"Gerente de projetos"` → labelled `Operations`. The description is electrical installation design
  and SPDA reports — engineering.

The reverse happened too: `"Estagiário no Laboratório de Habitação e Urbanismo"` went from `none` to
fully correct once the description revealed a pedagogical game built for architecture students, and
`"Sales Manager"` was vindicated by a description reading simply "Industrial Sales Management".

### The description-bearing rows were the *easier* ones

Measured on the original title-only verdicts, rows that have a description already scored higher
than those that do not — `job_category` 86.1% vs 82.1%, `role_k1500` 68.0% vs **59.0%**. So the
263 are a favourable subset, and they still fell once judged on fuller evidence. The 237 rows
without a description are both harder and unmeasurable at this standard.

### Which number to quote

| | `job_category` | `role_k1500` | basis |
|---|---|---|---|
| 500 rows, title only | 84.2% | 63.7% | one evidence standard, unstratified |
| 263 rows, title + description | **78.4%** | **61.4%** | fuller evidence, but a favourable subset |
| 500 blended | 80.0% | 60.3% | **mixes two standards — not a clean estimate** |

Use **84.2% / 63.7%** as the headline, since it rests on one consistent standard across an
unstratified sample. Read **78.4% / 61.4%** as the better estimate of what these labels are worth
when you actually know what the job was — and treat the gap between them as the size of the error
the title-only method hides.

This does **not** show that Revelio reads descriptions. Higher or lower accuracy on
description-bearing rows is equally consistent with those positions simply being better documented.

## Reviewing it — `role_audit_review.R` (10e)

Script 10e turns the gabarito into `role_audit_review.xlsx` and takes corrections back. Two modes,
chosen by whether the workbook exists: absent it exports, present it imports. Delete the file to
regenerate — it is never overwritten, because it may hold review work that exists nowhere else.

Five sheets: `Como ler` (the rubric), `Auditoria` (the 500 rows **sorted worst-first**, with a
validated dropdown on the editable `verdict_human` column), `Resumo`, `Titulos vazios`, and
`Vocabulario` — the last so "was a better label available" is checkable against the 1,557 labels
rather than guessed. Only rows with `verdict_human` filled are applied; blanks keep the LLM
verdict, so reviewing 30 rows is a valid result. `reviewer_note` is **appended** to the LLM's note,
never substituted, so disagreements stay legible. The CSV is written only after every check
passes, so a rejected import leaves the gabarito untouched.

### The int64 trap this uncovered, which was not Excel's fault

`position_id` is a **bigint**, and DuckDB hands it to R as a **double**. The values exceed 2^53, so
`as.character()` on them loses precision. 10d did exactly that, and **499 of the 500 gabarito ids
were wrong** — only 3 became visibly scientific (`9.107556275968e+18`); in the other 496 R printed
the double in full decimal and the last digits were silently incorrect
(`7701199284207410109` was stored as `…176`).

Two things are worth carrying forward:

- **Cast in SQL, not in R.** `CAST(position_id AS VARCHAR)` in the `SELECT`, in *both* the query
  that draws the sample and the one that reads the parked parquet back — a bare `SELECT *`
  reintroduces the double and the damage restarts.
- **Verify the invariant, not the agreement.** 10e's original round-trip check compared the xlsx
  against the CSV and passed, because both sides were equally corrupt. Equality between two
  endpoints proves nothing when a shared upstream step broke both. The check that works asserts
  every id matches `^-?[0-9]+$`, and it now runs at three points: reading the CSV, re-reading the
  freshly written xlsx, and importing.

The gabarito was repaired by matching positionally against the sample parquet, with the alignment
proven on nine columns (`title_raw` plus all seven ladder labels plus `seniority`) before a single
id was replaced. The audit rates are unaffected — verdicts are per row, and `position_id` was only
the key.

The current gabarito is **100% LLM-labelled** and the script prints that share on every run. The
rubric held together — across titles repeated in the sample, there is **no case** where Revelio
gave the same path and the gabarito gave different verdicts — but a human review pass would still
be worth having before these numbers are quoted outside the team.
