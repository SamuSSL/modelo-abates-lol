script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "default.yml"
))

games <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "canonical_games.rds"
))
team_metrics <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "team_map_metrics.rds"
))
dynamic_ratings <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "team_dynamic_ratings.rds"
))

tracking <- build_tracking_time_series(
  games,
  team_metrics,
  dynamic_ratings,
  min_date = as.Date("2022-01-01")
)
numeric_columns <- names(tracking)[vapply(
  tracking,
  is.numeric,
  logical(1L)
)]
tracking[numeric_columns] <- lapply(
  tracking[numeric_columns],
  round,
  digits = 6
)

app_data_dir <- file.path(project_root, "app_data")
dir.create(app_data_dir, recursive = TRUE, showWarnings = FALSE)
output_path <- file.path(
  app_data_dir,
  "time_series_tracking.csv.gz"
)
connection <- gzfile(output_path, open = "wt")
utils::write.csv(
  tracking,
  connection,
  row.names = FALSE,
  na = ""
)
close(connection)

latest <- do.call(rbind, lapply(
  split(
    tracking,
    interaction(
      tracking$entity_type,
      tracking$league_canonical,
      tracking$entity_name,
      tracking$metric,
      drop = TRUE
    )
  ),
  function(group) group[nrow(group), , drop = FALSE]
))
latest <- latest[
  order(
    latest$entity_type,
    latest$league_canonical,
    latest$entity_name,
    latest$metric
  ),
  ,
  drop = FALSE
]
report_path <- file.path(
  project_root,
  config$paths$reports,
  "time-series-tracking-current.csv"
)
utils::write.csv(latest, report_path, row.names = FALSE, na = "")

cat(
  nrow(tracking),
  "pontos temporais gravados em",
  output_path,
  "\n"
)
