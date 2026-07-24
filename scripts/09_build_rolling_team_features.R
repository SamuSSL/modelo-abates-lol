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
team_metrics_path <- file.path(
  project_root,
  config$paths$interim,
  "team_map_metrics.rds"
)
if (!file.exists(team_metrics_path)) {
  stop("Execute primeiro o script 07_build_team_metrics.R.", call. = FALSE)
}
metric_names <- c(
  "combined_kills_per_minute",
  "damage_per_minute",
  "damage_taken_per_minute",
  "kills_per_minute",
  "deaths_per_minute"
)
half_life_days <- as.numeric(
  evaluation_config$approved_recency$half_life_days
)
prior_games <- as.numeric(
  evaluation_config$team_feature_research$default_prior_games
)
features <- build_team_rolling_features(
  readRDS(team_metrics_path),
  metric_names = metric_names,
  half_life_days = half_life_days,
  prior_games = prior_games
)

leakage <- !is.na(features$latest_history_datetime) &
  features$latest_history_datetime >= features$series_cutoff
if (any(leakage)) {
  stop("Rolling team features contain future information.", call. = FALSE)
}

interim_dir <- file.path(project_root, config$paths$interim)
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "research"
)
dir.create(interim_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
output_path <- file.path(
  interim_dir,
  paste0("team_rolling_features_prior", prior_games, ".rds")
)
saveRDS(features, output_path, version = 3L)

coverage <- data.frame(
  feature = paste0("hist_", metric_names),
  available = vapply(
    paste0("hist_", metric_names),
    function(feature) sum(is.finite(features[[feature]])),
    integer(1L)
  ),
  total = nrow(features),
  stringsAsFactors = FALSE
)
coverage$coverage <- coverage$available / coverage$total
sample_summary <- data.frame(
  rows = nrow(features),
  games = length(unique(features$gameid)),
  teams = length(unique(ifelse(
    !is.na(features$team_id),
    features$team_id,
    features$team_name
  ))),
  rows_without_team_history = sum(features$raw_team_games == 0L),
  leakage_rows = sum(leakage),
  half_life_days = half_life_days,
  prior_games = prior_games,
  stringsAsFactors = FALSE
)
utils::write.csv(
  coverage,
  file.path(artifact_dir, "rolling_team_feature_coverage.csv"),
  row.names = FALSE
)
utils::write.csv(
  sample_summary,
  file.path(artifact_dir, "rolling_team_feature_summary.csv"),
  row.names = FALSE
)
print(sample_summary, row.names = FALSE)
print(coverage, row.names = FALSE)
