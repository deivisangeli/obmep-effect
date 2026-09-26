####################################################################
### Canonical publication orchestrator for RCID-based RUF/Shanghai
### employer flags. Local prep; the resolver step requires Athena.
####################################################################

rm(list=ls()); gc()
for (p in c("DBI","duckdb","arrow","jsonlite")) {
  if (!requireNamespace(p,quietly=TRUE)) stop("Missing package: ",p)
}
library(DBI); library(duckdb)

root <- Sys.getenv("OBMEP_ROOT",
                   unset="C:/Users/megaj/Globtalent Dropbox/OBMEP")
coh <- file.path(root,"Data/intermediate/revelio_br_cohort")
run_id <- Sys.getenv("OBMEP_RANKED_WORK_RUN_ID",unset=format(Sys.time(),"%Y%m%dT%H%M%S"))
stopifnot(grepl("^[0-9]{8}T[0-9]{6}$",run_id))
stage_dir <- Sys.getenv("OBMEP_RANKED_WORK_STAGE",
                        unset=file.path(coh,".ranked_university_work_staging",run_id))
backup_dir <- file.path(coh,"ranked_university_work_backups",run_id)
reuse_stage <- identical(Sys.getenv("OBMEP_RANKED_WORK_REUSE_STAGE"),"1")
repo <- normalizePath(".",winslash="/",mustWork=TRUE)
rscript <- file.path(R.home("bin"),"Rscript.exe")
if (!file.exists(rscript)) rscript <- Sys.which("Rscript")

dest <- c(
 firms_positions=file.path(coh,"obmep_candidates_step_1_firms_positions.parquet"),
 firms=file.path(coh,"obmep_candidates_step_1_firms.parquet"),
 firms_report=file.path(coh,"ranked_university_work_rebuild_report.json"),
 selected=file.path(coh,"obmep_candidates_selected.parquet"),
 selected_positions=file.path(coh,"obmep_candidates_selected_positions.parquet"))
stage <- file.path(stage_dir,basename(dest)); names(stage)<-names(dest)

if (!reuse_stage) {
  if (dir.exists(stage_dir) && length(list.files(stage_dir,all.files=TRUE,no..=TRUE))) {
    stop("Staging directory is not empty: ",stage_dir)
  }
  dir.create(stage_dir,recursive=TRUE,showWarnings=FALSE)
  status <- system2(rscript,file.path(repo,"prep/building_external_data/ranked_university_company_rcid.R"))
  if (status!=0) stop("ranked_university_company_rcid.R failed with status ",status)
  Sys.setenv(OBMEP_FIRMS_POS_OUT=stage["firms_positions"],
             OBMEP_FIRMS_USER_OUT=stage["firms"],
             OBMEP_FIRMS_REPORT_OUT=stage["firms_report"],
             OBMEP_FIRMS_OLD_POS=dest["firms_positions"],
             OBMEP_FIRMS_OLD_USER=dest["firms"])
  status <- system2(rscript,file.path(repo,"prep/building_external_data/obmep_candidates_step_1_firms.R"))
  Sys.unsetenv(c("OBMEP_FIRMS_POS_OUT","OBMEP_FIRMS_USER_OUT",
                 "OBMEP_FIRMS_REPORT_OUT","OBMEP_FIRMS_OLD_POS","OBMEP_FIRMS_OLD_USER"))
  if (status!=0) stop("obmep_candidates_step_1_firms.R failed with status ",status)
  Sys.setenv(OBMEP_SELECTED_FIRMS_PATH=stage["firms"],
             OBMEP_SELECTED_OUT=stage["selected"])
  status <- system2(rscript,file.path(repo,"prep/building_external_data/obmep_candidates_selected.R"))
  Sys.unsetenv(c("OBMEP_SELECTED_FIRMS_PATH","OBMEP_SELECTED_OUT"))
  if (status!=0) stop("obmep_candidates_selected.R failed with status ",status)
  Sys.setenv(OBMEP_SELECTED_PATH=stage["selected"],
             OBMEP_SELECTED_POSITIONS_OUT=stage["selected_positions"],
             OBMEP_EXPECTED_SELECTED="1468102")
  status <- system2(rscript,file.path(repo,"prep/building_external_data/obmep_candidates_selected_positions.R"))
  Sys.unsetenv(c("OBMEP_SELECTED_PATH","OBMEP_SELECTED_POSITIONS_OUT","OBMEP_EXPECTED_SELECTED"))
  if (status!=0) stop("obmep_candidates_selected_positions.R failed with status ",status)
}
if (!all(file.exists(stage))) stop("Missing staged artifact(s): ",paste(stage[!file.exists(stage)],collapse=", "))

cat("=========== FINAL STAGED VALIDATION ===========\n")
con <- dbConnect(duckdb())
on.exit(try(dbDisconnect(con,shutdown=TRUE),silent=TRUE),add=TRUE)
fw <- function(p) gsub("\\\\","/",p)
v <- dbGetQuery(con,sprintf("
SELECT
 (SELECT count(*) FROM read_parquet('%1$s')) firm_positions,
 (SELECT count(DISTINCT position_id) FROM read_parquet('%1$s')) firm_position_ids,
 (SELECT count(*) FROM read_parquet('%2$s')) firms,
 (SELECT count(DISTINCT user_id) FROM read_parquet('%2$s')) firm_users,
 (SELECT count(*) FROM read_parquet('%3$s')) selected,
 (SELECT count(DISTINCT user_id) FROM read_parquet('%3$s')) selected_users,
 (SELECT count(*) FROM read_parquet('%4$s')) selected_positions,
 (SELECT count(DISTINCT position_id) FROM read_parquet('%4$s')) selected_position_ids,
 (SELECT count(DISTINCT user_id) FROM read_parquet('%4$s')) selected_position_users",
 fw(stage["firms_positions"]),fw(stage["firms"]),fw(stage["selected"]),fw(stage["selected_positions"])))
print(v,row.names=FALSE)
if (v$firm_positions!=v$firm_position_ids || v$firms!=v$firm_users ||
    v$selected!=v$selected_users || v$selected_positions!=v$selected_position_ids ||
    v$selected!=v$selected_position_users) stop("A staged grain invariant failed.")
if (v$firms!=484890L || v$selected!=1468102L || v$selected_positions!=8219165L) {
  stop("Staged measured counts differ from the validated production run.")
}
bad_union <- dbGetQuery(con,sprintf("
 SELECT count(*) n FROM read_parquet('%s')
 WHERE ranked_university_work_any<>greatest(rf_any,sw_any)",fw(stage["selected"])))$n
join_diff <- dbGetQuery(con,sprintf("
 SELECT count(*) n FROM read_parquet('%1$s') s
 LEFT JOIN read_parquet('%2$s') f USING(user_id)
 WHERE s.in_firms=1 AND (f.user_id IS NULL OR s.rf_any<>f.rf_any OR s.sw_any<>f.sw_any
 OR s.ranked_university_work_any<>f.ranked_university_work_any)",
 fw(stage["selected"]),fw(stage["firms"])))$n
if (bad_union!=0 || join_diff!=0) stop("Staged downstream flag propagation failed.")

source_files <- c(
 list.files(file.path(coh,"obmep_candidates_step_1_position"),full.names=TRUE),
 list.files(file.path(coh,"obmep_candidates_step_1_position_rcid"),full.names=TRUE),
 list.files(file.path(coh,"obmep_candidates_step_1_position_role_loc"),full.names=TRUE),
 file.path(coh,"obmep_candidates_step_1.parquet"),
 file.path(coh,"obmep_candidates_step_1_shanghai.parquet"),
 file.path(coh,"obmep_candidates_step_1_ruf_degree.parquet"))
source_files <- source_files[file.exists(source_files)]
source_before <- unname(tools::md5sum(source_files))

dir.create(backup_dir,recursive=TRUE,showWarnings=FALSE)
for (nm in names(dest)) {
  if (file.exists(dest[nm])) {
    ok <- file.copy(dest[nm],file.path(backup_dir,basename(dest[nm])),overwrite=FALSE)
    if (!ok) stop("Could not back up ",dest[nm])
  }
}
backup_files <- list.files(backup_dir,full.names=TRUE)
if (length(backup_files)!=sum(file.exists(dest))) stop("Backup completeness check failed.")

stage_md5 <- unname(tools::md5sum(stage))
for (nm in names(dest)) {
  if (!file.copy(stage[nm],dest[nm],overwrite=TRUE,copy.date=TRUE)) {
    stop("Could not publish ",dest[nm])
  }
}
published_md5 <- unname(tools::md5sum(dest))
if (!identical(tolower(stage_md5),tolower(published_md5))) stop("Published checksums differ from staging.")
source_after <- unname(tools::md5sum(source_files))
if (!identical(tolower(source_before),tolower(source_after))) stop("An immutable source changed during publication.")

publication <- list(run_id=run_id,published_at=format(Sys.time(),"%Y-%m-%dT%H:%M:%S%z"),
 staging_directory=stage_dir,backup_directory=backup_dir,
 artifacts=data.frame(name=names(dest),path=unname(dest),md5=published_md5),
 counts=v,checks=list(staged_grains=TRUE,measured_counts=TRUE,union_flag=TRUE,
 downstream_flags=TRUE,backups_complete=TRUE,published_checksums=TRUE,
 immutable_sources=TRUE))
jsonlite::write_json(publication,file.path(coh,"ranked_university_work_publication_report.json"),
 pretty=TRUE,auto_unbox=TRUE,na="null")
cat("Published five canonical artifacts.\nBackup: ",backup_dir,"\n",sep="")
