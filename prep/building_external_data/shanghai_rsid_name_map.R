####################################################################
###
### Global rsid -> Shanghai institution map, keyed on the Revelio
### normalised school name                              [local only]
###
### Script 16 matches the Shanghai names against BOTH university_raw
### (free text) and university_name (Revelio's normalisation), per ROW.
### This script uses the second of those to key a map at the SCHOOL
### level, which is a different object and reaches different rows.
###
### Why university_name and not university_raw. Measured on the cohort
### extract:
###
###   distinct university_raw   1,417,852   free text, what people type
###   distinct university_name     54,955   Revelio's normalisation
###   distinct rsid                55,906
###   rsids with >1 name                0   <- university_name is
###                                            STRICTLY one per rsid
###
### So university_name is a controlled vocabulary 26x smaller than the
### free text and functionally determined by the school key. Folded and
### matched whole-string against the ranking's three name columns:
###
###   895 rsids match, reaching 828 of the 1,000 ranked institutions.
###
### For contrast, the Brazilian-list route (rsid_openalex_safe_map.R)
### reaches 18 of 1,000, because it is built from
### openalex_institutions_br and can only contain Brazilian records.
### THIS is the map a global sh_ arm needs.
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Local parquet in, local parquet out. Free.
###    Still prep/, still not for SEDAP.
### 2. *** PRECISION IS INHERITED AND THEN AMPLIFIED. *** The README
###    measures script 16's university_name arm at 96.5% precise per
###    row, against the university_raw arm's 99.9%, because Revelio
###    misassigns: "Faculdade de Tecnologia de Sao Paulo" carries
###    university_name "University of Sao Paulo" (FATEC is Centro Paula
###    Souza, not USP), "Universidad de Palermo" carries "University of
###    Palermo" (Buenos Aires, not Sicily), "Uri Campus de Erechim"
###    carries "Federal University of Parana".
###
###    Keying a MAP on that inherits every such error and multiplies
###    it, because one wrong name now claims every row under the rsid.
###    That is the central risk of this file and the reason for the two
###    guards below. Do not read the 96.5% as this map's precision; it
###    is an upper bound on the per-row arm, not a measurement of
###    propagation.
### 3. NAME -> rsid IS ONE-TO-MANY, AND THAT IS FINE. 814 names sit on
###    more than one rsid -- campuses, alumni keys, duplicates. The map
###    runs rsid -> name -> institution, so the many-to-one direction is
###    the one that matters and it is clean (note the 0 above). Several
###    rsids mapping to one institution is expected and correct.
### 4. THE EVIDENCE FLOOR IS NOT OPTIONAL, and it is a different guard
###    from concentration. A name supported by one row is as
###    "concentrated" as one supported by a million. Measured on the
###    Brazilian build, 35 of 75 rsids passing a 90% concentration bar
###    rested on a SINGLE matched row and would have flagged 5.65M rows
###    -- UNAM, UCLA, Stanford, RMIT, Montreal. min_rows is what stops
###    that; see rsid_openalex_one_to_one.R note 7.
### 5. THE COUNTRY VETO IS THE POINT OF THIS BUILD. The ranking carries
###    country_code and iso3c; script 16 uses NEITHER. The education
###    extract carries university_country. Where both are present and
###    disagree, the match is rejected. It is aimed squarely at the
###    cross-border homonyms the Shanghai audit found by hand:
###    "Saint Louis University - Maryheights Campus, Baguio City"
###    matching the American Saint Louis University, and the Palermo
###    case above.
###
###    VETO WHEN PRESENT, NEVER A REQUIREMENT. university_country is
###    populated on only 32% of ROWS -- but an rsid needs just one row
###    carrying it, so 731 of the 895 matched rsids (82%) can be
###    checked. The other 164 pass unchecked and are marked as such.
### 6. THE COMPARISON IS ISO2 TO ISO2. Revelio's country NAME is
###    converted to a code, not the other way round. The first version
###    converted the ranking's code to a name and compared strings,
###    which manufactured a false veto on Hong Kong -- countrycode
###    renders "Hong Kong SAR China" against Revelio's "Hong Kong".
###    Codes have one spelling; names do not.
### 8. THE COUNTRY SIDE HAS ITS OWN EVIDENCE FLOOR (min_ctry_rows), and
###    it is not the same guard as min_rows. Omitting it was the same
###    thin-evidence error this chain has hit three times: on the first
###    run Groningen was vetoed on ONE country row and Bari on one,
###    against thousands of name rows.
###
###    Even floored, the veto over-rejects where Revelio's
###    university_country is systematically wrong for a school -- e.g.
###    University of Michigan reads "Bulgaria" on 2,759 rows. That is
###    not a homonym and the veto cannot tell the difference. This is
###    why `ctry_ok` and `reason` are STORED (note 7): a consumer who
###    would rather keep those schools drops the veto with a WHERE.
### 7. `keep` IS STORED, NOT FILTERED. Every matched rsid stays in the
###    output with its reason, so a consumer can loosen the floor or
###    drop the veto with a WHERE and no rebuild -- the same convention
###    as `keep` in 8d and `safe` in 8f.
###
####################################################################

rm(list = ls()); gc()
options(width = 200)

for (p in c("DBI", "duckdb", "arrow", "countrycode")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}
library(DBI)

####################################################################
### Parameters
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")
sh_dir  <- file.path(obmep_root, "Data/intermediate/shanghai_ranking")

ed_dir   <- file.path(coh_dir, "obmep_candidates_step_1_education")
sh_path  <- file.path(sh_dir,  "shanghai_ranking_oa.parquet")
out_path <- file.path(coh_dir, "shanghai_rsid_name_map.parquet")

rank_cut <- 901L
min_rows      <- 25L  # note 4: rows supporting the NAME under that rsid
min_ctry_rows <- 25L  # note 8: rows supporting the COUNTRY under that rsid

# Measured 2026-09-05 before the script was written.
exp_rsid_many_names <- 0L
exp_matched_rsids   <- 895L
exp_reached         <- 828L

for (f in c(ed_dir, sh_path)) if (!file.exists(f)) stop("Missing input: ", f)

con <- dbConnect(duckdb::duckdb())
on.exit(try(dbDisconnect(con, shutdown = TRUE), silent = TRUE), add = TRUE)
invisible(dbExecute(con, "SET memory_limit='8GB'"))
fw <- function(p) gsub("\\\\", "/", p)

invisible(dbExecute(con, sprintf("CREATE VIEW e AS SELECT * FROM read_parquet('%s/*')",
                                 fw(ed_dir))))
invisible(dbExecute(con, sprintf(
  "CREATE VIEW s AS SELECT * FROM read_parquet('%s') WHERE Rank <= %d",
  fw(sh_path), rank_cut)))

####################################################################
### Step 1: the cardinality assertion (note 3)
####################################################################

invisible(dbExecute(con, "
  CREATE TABLE pair AS
  SELECT rsid, university_name, count(*) AS n_rows
  FROM e WHERE rsid IS NOT NULL AND university_name IS NOT NULL
  GROUP BY 1, 2"))

card <- dbGetQuery(con, "
  SELECT (SELECT count(*) FROM (SELECT rsid FROM pair GROUP BY rsid HAVING count(*) > 1))
           AS rsid_many_names,
         (SELECT count(*) FROM (SELECT university_name FROM pair
                                 GROUP BY university_name HAVING count(DISTINCT rsid) > 1))
           AS name_many_rsids,
         count(DISTINCT rsid) AS rsids
  FROM pair")
cat("=========== CARDINALITY ===========\n")
print(card, row.names = FALSE)
if (card$rsid_many_names != exp_rsid_many_names) {
  stop("university_name is no longer functionally determined by rsid: ",
       card$rsid_many_names, " rsids carry more than one name. The map's ",
       "whole shape assumes one, so stop and re-derive it.")
}
cat("[OK] university_name is strictly one per rsid; name -> rsid is ",
    "one-to-many (", card$name_many_rsids, " names), which is expected (note 3)\n", sep = "")

####################################################################
### Step 2: match the vocabulary to the ranking
####################################################################

# Institution side: the ranking's three name columns, folded. arg_min on
# Rank picks the better-ranked institution when a folded name is shared,
# and n_inst records that it was shared at all.
invisible(dbExecute(con, "
  CREATE TABLE inst AS
  SELECT lower(strip_accents(trim(nm))) AS nm_fold,
         arg_min(OA_key, Rank)       AS oa,
         min(Rank)                   AS rk,
         arg_min(country_code, Rank) AS cc,
         arg_min(shanghai_Name, Rank) AS oa_name,
         count(DISTINCT OA_key)      AS n_inst
  FROM (SELECT cleaned_display_name AS nm, OA_key, Rank, country_code, shanghai_Name FROM s
        UNION ALL SELECT display_name, OA_key, Rank, country_code, shanghai_Name FROM s
        UNION ALL SELECT shanghai_Name, OA_key, Rank, country_code, shanghai_Name FROM s)
  WHERE nm IS NOT NULL AND length(trim(nm)) >= 3
  GROUP BY 1"))

invisible(dbExecute(con, "
  CREATE TABLE m AS
  SELECT p.rsid, p.university_name, p.n_rows, i.oa, i.rk, i.cc, i.oa_name, i.n_inst
  FROM pair p
  JOIN inst i ON lower(strip_accents(trim(p.university_name))) = i.nm_fold"))

hit <- dbGetQuery(con, "SELECT count(*) AS rsids, count(DISTINCT oa) AS reached,
                               sum(CASE WHEN n_inst > 1 THEN 1 ELSE 0 END) AS ambiguous_name
                        FROM m")
cat("\n=========== MATCH ===========\n")
print(hit, row.names = FALSE)
if (hit$rsids != exp_matched_rsids || hit$reached != exp_reached) {
  warning("Match moved: ", hit$rsids, " rsids / ", hit$reached,
          " institutions, expected ", exp_matched_rsids, " / ", exp_reached)
}

####################################################################
### Step 3: the country veto (notes 5 and 6)
####################################################################

# The rsid's modal KNOWN university_country, and how much evidence backs it.
invisible(dbExecute(con, "
  CREATE TABLE rc AS
  SELECT rsid, arg_max(ctry, n) AS top_ctry, sum(n) AS known_rows
  FROM (SELECT rsid, university_country AS ctry, count(*) AS n
        FROM e WHERE rsid IS NOT NULL AND university_country IS NOT NULL
          AND university_country <> 'empty' AND trim(university_country) <> ''
        GROUP BY 1, 2)
  GROUP BY 1"))

mm <- dbGetQuery(con, "
  SELECT m.*, r.top_ctry, r.known_rows
  FROM m LEFT JOIN rc r ON m.rsid = r.rsid")

# Note 6: convert the CLEAN side (ISO2) to a name and compare folded.
# Note 6, CORRECTED. Compare ISO2 to ISO2, converting Revelio's country
# NAME to a code -- not the ranking's code to a name. The first version
# did the latter and manufactured a false veto on Hong Kong, where
# countrycode renders "Hong Kong SAR China" against Revelio's
# "Hong Kong". Codes have one spelling; names do not.
mm$rank_country <- suppressWarnings(
  countrycode::countrycode(mm$cc, origin = "iso2c", destination = "country.name"))
mm$rev_cc <- suppressWarnings(
  countrycode::countrycode(mm$top_ctry, origin = "country.name", destination = "iso2c"))

# Note 8. THE COUNTRY SIDE NEEDS ITS OWN EVIDENCE FLOOR, and forgetting
# it was the same thin-evidence error this chain has now hit three
# times. min_rows guards the NAME side; without min_ctry_rows a single
# stray country row vetoes an entire school. Measured on the first run:
# Groningen was vetoed on 1 country row, Bari on 1, Copenhagen on 2,
# Maastricht on 2, UC San Diego on 2 -- against thousands of name rows.
mm$ctry_ok <- ifelse(is.na(mm$rev_cc) | is.na(mm$cc) |
                       mm$known_rows < min_ctry_rows, NA,
                     mm$rev_cc == mm$cc)

cat("\n=========== COUNTRY VETO ===========\n")
cat("  matched rsids                 :", nrow(mm), "\n")
cat("  with country evidence         :", sum(!is.na(mm$ctry_ok)),
    sprintf("(%.0f%%)\n", 100 * mean(!is.na(mm$ctry_ok))))
cat("  agree                         :", sum(mm$ctry_ok %in% TRUE), "\n")
cat("  DISAGREE -> vetoed            :", sum(mm$ctry_ok %in% FALSE), "\n")
cat("  no evidence -> passes unchecked:", sum(is.na(mm$ctry_ok)), "\n")

if (sum(mm$ctry_ok %in% FALSE)) {
  cat("\n  the biggest vetoes (this is the homonym class, note 5):\n")
  v <- mm[mm$ctry_ok %in% FALSE, c("rsid","university_name","oa_name","rank_country",
                                   "top_ctry","n_rows")]
  print(head(v[order(-v$n_rows), ], 12), right = FALSE, row.names = FALSE)
}

####################################################################
### Step 4: the floor, the verdict, and the output
####################################################################

mm$enough_rows <- mm$n_rows >= min_rows
mm$keep <- as.integer(mm$enough_rows & !(mm$ctry_ok %in% FALSE))
mm$reason <- ifelse(!mm$enough_rows, "THIN_EVIDENCE",
             ifelse(mm$ctry_ok %in% FALSE, "COUNTRY_MISMATCH",
             ifelse(is.na(mm$ctry_ok), "OK_COUNTRY_UNCHECKED", "OK")))

cat("\n=========== VERDICT ===========\n")
print(as.data.frame(table(reason = mm$reason)), row.names = FALSE)
cat("\n  kept rsids                    :", sum(mm$keep),
    sprintf("(%.0f%% of matched)\n", 100 * mean(mm$keep)))
cat("  ranked institutions retained  :", length(unique(mm$oa[mm$keep == 1])),
    "of", hit$reached, "\n")

out <- mm[, c("rsid","university_name","oa","oa_name","rk","cc","rank_country",
              "top_ctry","known_rows","n_rows","n_inst","ctry_ok","keep","reason")]
names(out)[names(out) == "oa"] <- "openalex_id"
names(out)[names(out) == "rk"] <- "shanghai_rank"
out <- out[order(-out$n_rows), ]
stopifnot(!anyDuplicated(out$rsid))
arrow::write_parquet(out, out_path, compression = "snappy")

cat("\n=========== TOP KEPT SCHOOLS ===========\n")
print(head(out[out$keep == 1, c("rsid","university_name","oa_name","shanghai_rank",
                                "rank_country","n_rows")], 12),
      right = FALSE, row.names = FALSE)

cat("\n=========== SUMMARY ===========\n")
cat("  output      :", out_path,
    sprintf("(%.0f KB, %d rsids)\n", file.info(out_path)$size/2^10, nrow(out)))
cat("  floor       : n_rows >=", min_rows, "\n")
cat("  veto        : rsid modal university_country vs the ranking's country_code\n")
cat("  kept        :", sum(out$keep), "rsids ->",
    length(unique(out$openalex_id[out$keep == 1])), "ranked institutions\n")
