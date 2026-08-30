script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
load_lolkills_project()

response <- bettingiscool_request(
  "/api/leagues",
  query = list(sport_id = 12L)
)
leagues <- .bettingiscool_as_data_frame(response$data)
searchable <- apply(leagues, 1L, paste, collapse = " ")
keep <- grepl(
  "TCL|Turk|Prime|PRM|Germany|DACH",
  searchable,
  ignore.case = TRUE
)
selected <- leagues[keep, , drop = FALSE]
print(selected, row.names = FALSE)
cat("quota_remaining=", response$quota_remaining, "\n", sep = "")
