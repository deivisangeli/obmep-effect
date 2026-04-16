############################################################################################################

###Get unique higher education census course codes and classify them in stem or non-stem

############################################################################################################
rm(list = ls());gc()
###Define path
db_path <- Sys.getenv("db_path") ###Dropbox path
gtl_path <- Sys.getenv("gtl_path") ###githb file path


gtalloc_path <- file.path(db_path, "GTAllocation") ###GT allocation folder path
gtobmep_path <- file.path(db_path, "OBMEP") ###GT Obmep folder path

pacman ::p_load(tidyverse, RAthena, DBI, readr, reticulate, readxl, writexl, 
                dbplyr, glue, arrow, aws.s3, bit64, shiny, stargazer, gt, httr,
                jsonlite, furrr, stringdist, tictoc, foreach, doParallel, stringr,
                purrr, data.table, Hmisc, patchwork, progress, haven, rdrobust, 
                nprobust, openalexR, bit64, future, future.apply, dtplyr, countrycode)


############################################################################################################

###Loop across each edition between 2009 and 2024 and get unique NO_CINE_ROTULO entries to classify them in STEM or non-STEM

############################################################################################################

###Fix path
courses_dir <- file.path(gtobmep_path, "Data/raw/Censo Superior/cadastro_cursos")

##Loop across each year and rbind all unique NO_CINE_ROTULO entries
all_courses <- list()

for (year in 2009:2024){
    
    cat("Processing year:", year, "\n")
    
    # Read the CSV file for the current year
    file_path <- file.path(courses_dir, paste0("cadastro_cursos_", year, ".CSV"))
    courses_data <- fread(file_path, encoding = "Latin-1") %>%
        select(NU_ANO_CENSO ,course_name = NO_CURSO, course_code = CO_CURSO, TP_GRAU_ACADEMICO, NO_CINE_ROTULO:NO_CINE_AREA_DETALHADA) %>%
        distinct(NO_CINE_ROTULO, .keep_all = TRUE)
    
    # Append to the list
    all_courses[[as.character(year)]] <- courses_data
}

###Combine all years into a single data frame
combined_courses <- bind_rows(all_courses) %>%
    distinct(NO_CINE_ROTULO, .keep_all = TRUE)

###Save combined courses data
write_csv(combined_courses, file.path(gtobmep_path, "Data/intermediate/Censo Superior/unique_courses_2009_2024.csv"))


############################################################################################################

###Use gpt 5 nano to classify courses into stem or not

############################################################################################################
###Source api file and prompt funtion
source(file.path(gtl_path, "APIs/gpt_api.R"))
source(file.path(gtl_path, "utilities/prompt_functions.R"))
###Apply prompt
combined_courses <- combined_courses %>%
    mutate(prompt_field = map_chr(NO_CINE_ROTULO, ~prompt_course_area(.x)))

###Apply prompt for field classification
plan(multisession, workers = 20)
combined_courses <- combined_courses %>%
    mutate(field_area = future_map_chr(prompt_field, ~chatGPT(.x)))

table(combined_courses$field_area)

###Check a random sample of 20 responses
set.seed(1914)
check <- combined_courses %>%
    sample_n(50) %>%
    select(NO_CINE_ROTULO, field_area)
###Move NO_CINE_ROTULO and field_area side by side
combined_courses_final <- combined_courses %>%
    select(NO_CINE_ROTULO, field_area, everything())





###Save combined courses data
write_csv(combined_courses, file.path(gtobmep_path, "Data/intermediate/Censo Superior/courses_field.csv"))


check <- read.csv(file.path(gtobmep_path, "Data/intermediate/Censo Superior/courses_field.csv"))
view(check)
