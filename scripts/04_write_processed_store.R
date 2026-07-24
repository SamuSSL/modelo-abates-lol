script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(
  file.path(project_root, "config", "default.yml")
)

interim_dir <- file.path(project_root, config$paths$interim)
processed_dir <- file.path(project_root, config$paths$processed)
games_path <- file.path(interim_dir, "canonical_games.rds")
events_path <- file.path(interim_dir, "game_quality_events.rds")
excluded_path <- file.path(interim_dir, "excluded_games.rds")

if (
  !file.exists(games_path) ||
  !file.exists(events_path) ||
  !file.exists(excluded_path)
) {
  stop(
    "Execute primeiro o script 03_build_canonical_games.R.",
    call. = FALSE
  )
}

paths <- write_processed_store(
  readRDS(games_path),
  readRDS(events_path),
  processed_dir,
  file.path(processed_dir, "lolkills.duckdb"),
  excluded_games = readRDS(excluded_path)
)
print(unlist(paths), quote = FALSE)
