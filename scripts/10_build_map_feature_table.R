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
evaluation_config <- yaml::read_yaml(
  file.path(project_root, "config", "evaluation.yml")
)
prior_games <- evaluation_config$team_feature_research$
  default_prior_games
games <- readRDS(
  file.path(
    project_root,
    config$paths$interim,
    "canonical_games.rds"
  )
)
team_features <- readRDS(
  file.path(
    project_root,
    config$paths$interim,
    paste0("team_rolling_features_prior", prior_games, ".rds")
  )
)
map_features <- assemble_map_feature_table(team_features, games)
output_path <- file.path(
  project_root,
  config$paths$interim,
  paste0("map_features_prior", prior_games, ".rds")
)
saveRDS(map_features, output_path, version = 3L)

feature_columns <- grep(
  "^(blue|red)_hist_",
  names(map_features),
  value = TRUE
)
summary <- data.frame(
  maps = nrow(map_features),
  complete_feature_maps = sum(stats::complete.cases(
    map_features[feature_columns]
  )),
  first_cutoff = min(map_features$series_cutoff),
  last_cutoff = max(map_features$series_cutoff),
  prior_games = prior_games,
  stringsAsFactors = FALSE
)
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "research"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  summary,
  file.path(artifact_dir, "map_feature_summary.csv"),
  row.names = FALSE
)
print(summary, row.names = FALSE)
