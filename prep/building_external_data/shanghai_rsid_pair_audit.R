# Local prep only. Sampling/calibration are offline; manual identity research uses
# the internet. Never send this workflow to SEDAP. No flags are overwritten.
# Run from the repository root. Review blind_pairs.json before creating labels.
library(DBI)
library(duckdb)
library(jsonlite)
options(stringsAsFactors = FALSE)
obmep_root <- Sys.getenv("OBMEP_ROOT", "C:/Users/megaj/Globtalent Dropbox/OBMEP")
audit_dir <- Sys.getenv("OBMEP_SHANGHAI_AUDIT_DIR",
                       "outputs/shanghai-pair-audit-20260907")
dir.create(audit_dir, recursive = TRUE, showWarnings = FALSE)
src <- file.path(obmep_root, "Data/intermediate/shanghai_ranking/shanghai_rsid_oa_crosswalk.parquet")
checksum <- unname(tools::md5sum(src))
con <- dbConnect(duckdb())
x <- dbGetQuery(con, sprintf("SELECT *, CAST(rsid AS VARCHAR)||':'||oa_key AS pair_id,
  n_rows*1.0/rsid_n_rows AS match_share FROM read_parquet('%s')
  WHERE rsid IS NOT NULL AND rsid<>2147483647 AND n_rows>0
  ORDER BY rsid, oa_key", src))
stopifnot(nrow(x)==9737L, !anyDuplicated(x$pair_id), all(x$rsid_n_rows>0))
RNGkind("Mersenne-Twister", "Inversion", "Rejection")
set.seed(20260907)
draw <- sample.int(nrow(x), 1000L, replace=FALSE)
s <- x[draw, ]
s$sample_id <- seq_len(nrow(s))
split_ids <- sample.int(1000L, 700L, replace=FALSE)
s$split <- ifelse(s$sample_id %in% split_ids, "calibration", "holdout")
meta <- list(seed=20260907, input_md5=checksum, population=nrow(x),
             sample_size=nrow(s), calibration=700L, holdout=300L,
             source=basename(src), r_version=R.version.string,
             rng=RNGkind(), sampling="Uniform pairs without replacement; sorted rsid, oa_key")
sample_path <- file.path(audit_dir,"sample.rds")
if (file.exists(sample_path)) {
  prior <- readRDS(sample_path)
  stopifnot(identical(prior$meta, meta), identical(prior$sample, s))
} else {
  saveRDS(list(meta=meta,sample=s), sample_path)
  write_json(meta,file.path(audit_dir,"metadata.json"),auto_unbox=TRUE,pretty=TRUE)
  write_json(s,file.path(audit_dir,"sample.json"),dataframe="rows",na="null",auto_unbox=TRUE)
  blind <- s[c("sample_id","pair_id","shanghai_name","display_name","country_code",
               "university_name","rsid_top_country","ultimate_parent_school_name")]
  write_json(blind,file.path(audit_dir,"blind_pairs.json"),dataframe="rows",na="null",auto_unbox=TRUE)
}
cat("Sample frozen:", nrow(s), "pairs. MD5:",checksum,"\n")
labels_path <- file.path(audit_dir,"labels.json")
if (file.exists(labels_path)) {
  labels <- fromJSON(labels_path)
  stopifnot(nrow(labels)==1000L,!anyDuplicated(labels$sample_id),
            setequal(labels$sample_id,s$sample_id))
  labels <- labels[match(s$sample_id,labels$sample_id),]
  stopifnot(identical(labels$pair_id,s$pair_id),
            all(labels$verdict %in% c("correct","incorrect","unclear")),
            all(nzchar(labels$reason)), all(nzchar(labels$evidence)))
  s$verdict <- labels$verdict
  s$reason <- labels$reason
  s$evidence <- labels$evidence
  s$evidence_url <- labels$evidence_url
  cal <- s[s$split=="calibration",]
  floors <- sort(unique(c(0,0.5,cal$match_share)),decreasing=TRUE)
  rows <- vector("list",length(floors))
  for (i in seq_along(floors)) {
    f <- floors[i]
    a <- cal[cal$match_share>=f,]
    h <- s[s$split=="holdout" & s$match_share>=f,]
    all_keep <- x[x$match_share>=f,]
    rows[[i]] <- data.frame(floor=f,cal_n=nrow(a),cal_correct=sum(a$verdict=="correct"),
      cal_incorrect=sum(a$verdict=="incorrect"),cal_unclear=sum(a$verdict=="unclear"),
      hold_n=nrow(h),hold_correct=sum(h$verdict=="correct"),
      hold_incorrect=sum(h$verdict=="incorrect"),hold_unclear=sum(h$verdict=="unclear"),
      population_pairs=nrow(all_keep),population_rsids=length(unique(all_keep$rsid)),
      population_institutions=length(unique(all_keep$oa_key)),
      conflicting_rsids=sum(table(all_keep$rsid)>1L))
  }
  t <- do.call(rbind,rows)
  t$cal_precision <- ifelse(t$cal_n>0,t$cal_correct/t$cal_n,NA_real_)
  t$cal_recall <- t$cal_correct/sum(cal$verdict=="correct")
  t$hold_precision <- ifelse(t$hold_n>0,t$hold_correct/t$hold_n,NA_real_)
  eligible <- which(t$cal_n>0 & t$cal_precision>=0.95)
  best <- NA_integer_
  if (length(eligible)) {
    best <- eligible[order(-t$cal_correct[eligible],-t$cal_precision[eligible],-t$floor[eligible])][1]
  }
  # Wilson intervals are descriptive: repeated rsids and threshold selection
  # prevent interpreting the calibration interval as independent validation.
  for (part in c("cal","hold")) {
    n <- t[[paste0(part,"_n")]]
    p <- t[[paste0(part,"_precision")]]
    z <- qnorm(0.975)
    mid <- (p+z^2/(2*n))/(1+z^2/n)
    half <- z*sqrt(p*(1-p)/n+z^2/(4*n^2))/(1+z^2/n)
    t[[paste0(part,"_lower")]] <- ifelse(n>0,pmax(0,mid-half),NA_real_)
    t[[paste0(part,"_upper")]] <- ifelse(n>0,pmin(1,mid+half),NA_real_)
  }
  baseline <- which(t$floor==0.5)
  recommendation <- if (!is.na(best)) t[best,] else NULL
  result <- list(meta=meta,correct=sum(s$verdict=="correct"),
    incorrect=sum(s$verdict=="incorrect"),unclear=sum(s$verdict=="unclear"),
    calibration_correct=sum(cal$verdict=="correct"),
    holdout_correct=sum(s$verdict[s$split=="holdout"]=="correct"),
    recommendation=recommendation,baseline=t[baseline,])
  write_json(s,file.path(audit_dir,"reviewed_pairs.json"),dataframe="rows",na="null",auto_unbox=TRUE,digits=17)
  write_json(t,file.path(audit_dir,"thresholds.json"),dataframe="rows",na="null",auto_unbox=TRUE,digits=17)
  write_json(result,file.path(audit_dir,"analysis.json"),dataframe="rows",na="null",auto_unbox=TRUE,pretty=TRUE,digits=17)
  # A school is ambiguous at a floor iff its second-largest pair share passes it.
  multiple_ids <- names(which(table(x$rsid)>1L))
  registry <- vector("list",length(multiple_ids))
  for (i in seq_along(multiple_ids)) {
    links <- x[x$rsid==multiple_ids[i],]
    links <- links[order(-links$match_share,links$oa_key),]
    registry[[i]] <- data.frame(rsid=as.character(links$rsid[1]),
      university_name=links$university_name[1],
      conflict_ceiling=links$match_share[2],
      candidate_links=paste(sprintf("%s [%s]: %.6f%%",links$shanghai_name,
        links$oa_key,100*links$match_share),collapse="; "))
  }
  registry <- do.call(rbind,registry)
  registry <- registry[order(-registry$conflict_ceiling,registry$rsid),]
  write_json(registry,file.path(audit_dir,"conflict_registry.json"),dataframe="rows",na="null",auto_unbox=TRUE,digits=17)
  if (!is.na(best)) {
    keep <- x[x$match_share>=t$floor[best],]
    conflict <- keep[keep$rsid %in% names(which(table(keep$rsid)>1)),]
    write_json(conflict,file.path(audit_dir,"conflicting_pairs.json"),dataframe="rows",na="null",auto_unbox=TRUE)
  }
  print(result[c("correct","incorrect","unclear","recommendation","baseline")])
}
dbDisconnect(con,shutdown=TRUE)
