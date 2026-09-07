####################################################################
###
### Making the OpenAlex <-> rsid match SAFE (one-to-one)   [local only]
###
### rsid_openalex_id_crosswalk.R (8d) maps a Revelio school key to
### EVERY OpenAlex institution any of its strings matched. That is the
### honest raw mapping, and it is not one-to-one: 305 of the 667
### surviving rsids reach more than one openalex_id, up to 95 on FGV.
###
### This script decides, per rsid, whether that key can safely stand
### for a SINGLE institution, and publishes the subset that can.
###
### Why it matters, measured: a direct "flag if this rsid's OpenAlex id
### is in list X" is 20.5% wrong on the Shanghai list and 22.5% wrong on
### RUF, weighted by the rows such a flag would touch. The safe map is
### what makes that kind of flag defensible.
###
### Three products:
###   rsid_oa_link_worksheet.parquet  every (rsid, openalex_id) link on
###                                   a surviving rsid, with evidence
###   rsid_oa_link_class.csv          the editable verdicts, one per rsid
###   rsid_openalex_safe_map.parquet  rsid -> ONE openalex_id, for the
###                                   rsids that earned it
###
### Depends on:
###   prep/building_external_data/rsid_openalex_id_crosswalk.R
###
### Shape reused from:
###   prep/building_external_data/c_norm_coverage_audit.R (parked
###   worksheet + editable CSV keyed to it, stop() until filled)
###
### -----------------------------------------------------------------
### CAUTION / LIMITATIONS
### -----------------------------------------------------------------
### 1. NO NETWORK. Reads one local parquet, writes two files and a CSV.
###    Free and re-runnable. Still a prep/ script; not for SEDAP.
### 2. THE VERDICTS ARE LLM-WRITTEN, NOT HUMAN. Same conflict of
###    interest shanghai_flag_audit.R and c_norm_coverage_audit.R record
###    for theirs: the labels and the rubric come from the same place,
###    so this is an internal-consistency pass and NOT an independent
###    measurement. The CSV is editable precisely so a person can
###    overrule it, and `source` marks every row llm or human.
### 3. ONLY SURVIVING rsids ARE COVERED (keep = 1). Measured: rejected
###    rsids hold 77 of the 1,769 stray links, 4%. A rejected rsid has
###    few matched strings by construction so it cannot accumulate ids
###    -- max 5, against 95 on FGV. Working the rejected-pairs file for
###    one-to-one safety would address 4% of the problem.
###
###    For a GLOBAL map -- Shanghai -- the rejected rsids are the
###    targets rather than the contaminants, and that is a different
###    build against a different list. Not this file.
### 4. THE FLOOR DOES MOST OF THE WORK, AND IT IS TWO-SIDED. A stray is
###    NOISE unless it carries at least `min_link_rows` rows AND at
###    least `min_link_share` of the rsid's matched rows. Both are
###    needed: FGV has 94 stray ids over 666 rows, 0.09% of its
###    701,099, all noise; IFSP has 34 strays over 1,923 rows, 75% of
###    its 2,546, all real. An absolute floor alone keeps FGV's tail; a
###    relative floor alone keeps tiny schools' single rows.
###    Measured at (5, 0.01): 1,692 stray links -> 73, over 42 rsids.
### 5. FIVE VERDICTS, because the data has five cases and collapsing
###    them would hide the one that matters:
###      ONE_TO_ONE   dominant id correct, strays immaterial -> SAFE
###      OA_DUPLICATE dominant and stray are the SAME institution under
###                   two OpenAlex ids (Centro Universitario Padre
###                   Anchieta vs "Padre Anchieta University Centre",
###                   11,731 rows) -> SAFE, and evidence of a duplicate
###                   in the OpenAlex list itself
###      AFFILIATE    parent/child, typically a teaching hospital and
###                   its medical school (Hospital Sirio-Libanes,
###                   Santa Casa, Santa Marcelina) -> safe for
###                   institution-level use, NOT for campus-level
###      FAMILY       the rsid pools genuinely DISTINCT institutions --
###                   the Instituto Federal network is the whole story
###                   here -> NOT SAFE AT ANY THRESHOLD
###      WRONG_DOM    the dominant id is itself wrong -> exclude
### 6. `safe` IS STORED, NOT FILTERED. Every rsid stays in the
###    worksheet with its verdict, so a consumer that wants to include
###    AFFILIATE, or exclude OA_DUPLICATE, does it with a WHERE and no
###    rebuild. Same convention as `keep` in 8d.
### 7. THE FLOOR IS `match_share` UNDER ANOTHER NAME. The README's
###    original statistic for the withdrawn C_rsid branch was the share
###    of an rsid's rows whose string matched. dom_share replaced it and
###    is better for the FAMILY case -- but dom_share is BLIND to thin
###    evidence: one stray matched row gives dom_share 1.0 by
###    arithmetic. Measured on the RUF list, 35 of the 75 rsids passing
###    dom_share >= 0.90 rest on a single matched row and carry 5.65M of
###    the 9.67M rows they would flag -- UNAM, UCLA, Stanford, RMIT.
###    The two guards catch different failures and BOTH are required.
###
####################################################################

rm(list = ls()); gc()
options(width = 200)

for (p in c("arrow")) {
  if (!requireNamespace(p, quietly = TRUE)) {
    stop("Missing package: ", p, ". Install it before running this script.")
  }
}

####################################################################
### Parameters
####################################################################

obmep_root <- Sys.getenv("OBMEP_ROOT",
                         unset = "C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh_dir <- file.path(obmep_root, "Data/intermediate/revelio_br_cohort")

xw_path  <- file.path(coh_dir, "rsid_openalex_id_crosswalk.parquet")
ws_path  <- file.path(coh_dir, "rsid_oa_link_worksheet.parquet")
cls_path <- file.path(coh_dir, "rsid_oa_link_class.csv")
map_path <- file.path(coh_dir, "rsid_openalex_safe_map.parquet")

# The two-sided floor (note 4). Both must be met for a stray to count.
min_link_rows  <- 5
min_link_share <- 0.01

# Verdicts that make an rsid usable as a one-to-one key (note 5, 6).
safe_verdicts <- c("ONE_TO_ONE", "OA_DUPLICATE", "AFFILIATE")
all_verdicts  <- c(safe_verdicts, "FAMILY", "WRONG_DOM")

# Measured 2026-09-05 before the script was written; deterministic from
# one fixed input.
exp_kept_rsids <- 667
exp_links      <- 2359
exp_stray      <- 1692
exp_live       <- 73
exp_live_rsids <- 42

if (!file.exists(xw_path)) {
  stop("Missing ", xw_path, "\nRun rsid_openalex_id_crosswalk.R first.")
}

####################################################################
### Step 1: the link worksheet
####################################################################

x <- as.data.frame(arrow::read_parquet(xw_path))
x <- x[x$keep == 1, ]

agg <- function(f, d, by) {
  r <- aggregate(f, d, sum); r
}
lnk <- aggregate(cbind(link_rows = n_rows) ~ rsid + openalex_id +
                   openalex_cleaned_display_name + openalex_type, x, sum)
nstr <- aggregate(university_raw ~ rsid + openalex_id, x,
                  function(v) length(unique(v)))
names(nstr)[3] <- "link_strings"
# one example string per link, the one with the most rows behind it
ex <- x[order(x$rsid, x$openalex_id, -x$n_rows), ]
ex <- ex[!duplicated(ex[, c("rsid", "openalex_id")]),
         c("rsid", "openalex_id", "university_raw")]
names(ex)[3] <- "example_string"

# the rsid's TRUE matched rows: DISTINCT pairs, so the 12 fan-out pairs
# are not double counted (8d note 3).
tot <- aggregate(cbind(rsid_matched_rows = n_rows) ~ rsid,
                 unique(x[, c("rsid", "university_raw", "n_rows")]), sum)
meta <- unique(x[, c("rsid", "university_name", "dom_openalex_id",
                     "dom_share", "n_ids_rsid")])
domn <- unique(x[, c("openalex_id", "openalex_cleaned_display_name")])
names(domn) <- c("dom_openalex_id", "dom_name")

w <- merge(merge(merge(merge(merge(lnk, nstr), ex), tot), meta), domn)
w$is_dominant <- as.integer(w$openalex_id == w$dom_openalex_id)
w$link_share  <- w$link_rows / w$rsid_matched_rows
w$live_stray  <- as.integer(w$is_dominant == 0 &
                            w$link_rows  >= min_link_rows &
                            w$link_share >= min_link_share)
w <- w[order(w$rsid, -w$link_rows), ]

cat("=========== WORKSHEET ===========\n")
cat("surviving rsids               :", length(unique(w$rsid)), "\n")
cat("(rsid, openalex_id) links     :", nrow(w), "\n")
cat("  dominant                    :", sum(w$is_dominant), "\n")
cat("  stray                       :", sum(w$is_dominant == 0), "\n")
cat(sprintf("  stray surviving the floor   : %d  (rows >= %d AND share >= %.2f)\n",
            sum(w$live_stray), min_link_rows, min_link_share))
cat("  rsids with a live stray     :",
    length(unique(w$rsid[w$live_stray == 1])), "\n")

if (length(unique(w$rsid)) != exp_kept_rsids || nrow(w) != exp_links ||
    sum(w$is_dominant == 0) != exp_stray) {
  warning("Worksheet shape moved: ", length(unique(w$rsid)), " rsids / ",
          nrow(w), " links / ", sum(w$is_dominant == 0), " stray, expected ",
          exp_kept_rsids, " / ", exp_links, " / ", exp_stray)
}
if (sum(w$live_stray) != exp_live) {
  warning("Live strays: ", sum(w$live_stray), ", expected ", exp_live)
}
arrow::write_parquet(w, ws_path, compression = "snappy")

# What the floor cleared without any judgement (note 4).
nz <- w[w$is_dominant == 0 & w$live_stray == 0, ]
cat(sprintf("\nfloor cleared %d stray links carrying %s rows, no judgement needed\n",
            nrow(nz), format(sum(nz$link_rows), big.mark = ",")))

####################################################################
### Step 2: the verdict file, one row per rsid that needs one
####################################################################

need <- unique(w$rsid[w$live_stray == 1])
tpl <- unique(w[w$rsid %in% need,
                c("rsid", "university_name", "dom_openalex_id", "dom_name",
                  "dom_share", "n_ids_rsid", "rsid_matched_rows")])
sr <- aggregate(cbind(live_stray_rows = link_rows) ~ rsid,
                w[w$live_stray == 1, ], sum)
sn <- aggregate(cbind(live_strays = link_rows) ~ rsid,
                w[w$live_stray == 1, ], length)
# the biggest live stray, which is what a reviewer reads first
top <- w[w$live_stray == 1, ]
top <- top[order(top$rsid, -top$link_rows), ]
top <- top[!duplicated(top$rsid),
           c("rsid", "openalex_cleaned_display_name", "link_rows")]
names(top) <- c("rsid", "top_stray_name", "top_stray_rows")
tpl <- merge(merge(merge(tpl, sr), sn), top)
tpl <- tpl[order(-tpl$live_stray_rows), ]

if (!file.exists(cls_path)) {
  out <- tpl[, c("rsid", "university_name", "dom_name", "top_stray_name",
                 "dom_share", "n_ids_rsid", "live_strays",
                 "live_stray_rows", "rsid_matched_rows")]
  out$verdict <- ""
  out$source  <- "todo"
  out$note    <- ""
  write.csv(out, cls_path, row.names = FALSE, fileEncoding = "UTF-8")
  stop("Wrote an EMPTY verdict template with ", nrow(out), " rows:\n  ",
       cls_path, "\nFill `verdict` on every row with one of: ",
       paste(all_verdicts, collapse = ", "),
       ".\nSet `source` to llm or human. See note 5 for the rubric, and ",
       "note 2 before trusting an llm row. Re-run when filled.")
}

####################################################################
### Step 3: read the verdicts back and check them
####################################################################

cl <- read.csv(cls_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8",
               colClasses = "character")
if (!all(c("rsid", "verdict", "source") %in% names(cl))) {
  stop(basename(cls_path), " must carry rsid, verdict and source.")
}
cl$rsid <- as.integer(cl$rsid)
if (anyDuplicated(cl$rsid) != 0) {
  stop("Repeated rsid in ", basename(cls_path), ".")
}
off <- setdiff(cl$verdict, all_verdicts)
if (length(off)) {
  stop("Verdicts outside the domain: ", paste(unique(off), collapse = ", "),
       ". Allowed: ", paste(all_verdicts, collapse = ", "))
}
miss <- setdiff(need, cl$rsid)
if (length(miss)) {
  stop(length(miss), " rsids need a verdict and are absent from ",
       basename(cls_path), ": ", paste(head(miss, 5), collapse = ", "))
}

cat("\n=========== VERDICTS ===========\n")
v <- merge(cl[, c("rsid", "verdict", "source")], tpl, by = "rsid")
tb <- aggregate(cbind(rsids = rsid) ~ verdict, v, length)
rr <- aggregate(cbind(matched_rows = rsid_matched_rows) ~ verdict, v, sum)
print(merge(tb, rr), row.names = FALSE)
cat("\n  by source:", paste(names(table(cl$source)), table(cl$source),
                            sep = "=", collapse = "  "), "\n")

####################################################################
### Step 4: the safe map
####################################################################

# An rsid is safe if it needed no verdict (no live stray at all) or its
# verdict says so. Stored, not filtered: the verdict travels (note 6).
base <- unique(w[, c("rsid", "university_name", "dom_openalex_id", "dom_name",
                     "dom_share", "n_ids_rsid", "rsid_matched_rows")])
base <- merge(base, cl[, c("rsid", "verdict", "source")], all.x = TRUE)
base$verdict[is.na(base$verdict)] <- "ONE_TO_ONE"
base$source[is.na(base$source)]   <- "floor"
base <- merge(base, sr, all.x = TRUE)
base$live_stray_rows[is.na(base$live_stray_rows)] <- 0
base$safe <- as.integer(base$verdict %in% safe_verdicts)
names(base)[names(base) == "dom_openalex_id"] <- "openalex_id"
base <- base[order(-base$rsid_matched_rows), ]

stopifnot(!anyDuplicated(base$rsid), !any(is.na(base$openalex_id)))
arrow::write_parquet(base, map_path, compression = "snappy")

cat("\n=========== SAFE MAP ===========\n")
cat("rsids in the map              :", nrow(base), "\n")
cat("  safe (one-to-one usable)    :", sum(base$safe),
    sprintf("(%.1f%% of rsids, %.1f%% of matched rows)\n",
            100 * mean(base$safe),
            100 * sum(base$rsid_matched_rows[base$safe == 1]) /
                  sum(base$rsid_matched_rows)))
cat("  excluded                    :", sum(base$safe == 0), "\n")
print(aggregate(cbind(rsids = rsid) ~ verdict + safe, base, length),
      row.names = FALSE)

cat("\n=========== ACCEPTANCE CHECK ===========\n")
# The rubric is wrong if these come out otherwise (plan, Verification).
chk <- function(rs, want, who) {
  got <- base$verdict[base$rsid == rs]
  ok <- length(got) == 1 && ((want == "safe") == (got %in% safe_verdicts))
  cat(sprintf("  %-46s %-12s %s\n", who, if (length(got)) got else "ABSENT",
              if (ok) "OK" else "*** FAILS ***"))
  ok
}
a1 <- chk(74427, "unsafe", "IFSP (pools the Instituto Federal network)")
a2 <- chk(53433, "safe",   "FGV")
a3 <- chk(4419,  "safe",   "Estacio")
a4 <- chk(137330, "safe",  "USP")
if (!all(a1, a2, a3, a4)) {
  stop("The acceptance check failed. The rubric or the verdicts are wrong; ",
       "do not publish this map.")
}

cat("\n=========== SUMMARY ===========\n")
cat("  worksheet :", ws_path,
    sprintf("(%.0f KB, %d links)\n", file.info(ws_path)$size / 2^10, nrow(w)))
cat("  verdicts  :", cls_path, sprintf("(%d rsids)\n", nrow(cl)))
cat("  safe map  :", map_path, sprintf("(%d rsids, %d safe)\n",
                                       nrow(base), sum(base$safe)))
cat("  floor     : link_rows >=", min_link_rows,
    "AND link_share >=", min_link_share, "\n")
