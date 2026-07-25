script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
taxonomy <- read_champion_taxonomy(file.path(
  project_root,
  "config",
  "taxonomy",
  "champions-2026.yml"
))
taxonomy$review_status <- "pending"
taxonomy$review_notes <- ""
output_path <- file.path(
  project_root,
  "reports",
  "champion-taxonomy-review.csv"
)
utils::write.csv(
  taxonomy,
  output_path,
  row.names = FALSE,
  na = ""
)
cat(normalizePath(output_path, winslash = "/", mustWork = TRUE), "\n")
