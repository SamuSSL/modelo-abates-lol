script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(file.path(project_root, "config", "default.yml"))
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "kill_market_map_features.rds"
))

summarize_period <- function(path, period) {
  metrics <- readRDS(file.path(artifact_dir, path))
  required <- c(
    "blue_prediction_mean",
    "red_prediction_mean"
  )
  if (!all(required %in% names(metrics))) {
    return(data.frame())
  }
  observed <- maps[
    match(metrics$gameid, maps$gameid),
    c("blue_kills", "red_kills"),
    drop = FALSE
  ]
  metrics$blue_observed <- observed$blue_kills
  metrics$red_observed <- observed$red_kills
  do.call(rbind, lapply(split(metrics, metrics$candidate_id), function(data) {
    blue_error <- data$blue_prediction_mean - data$blue_observed
    red_error <- data$red_prediction_mean - data$red_observed
    data.frame(
      period = period,
      candidate_id = data$candidate_id[[1L]],
      maps = nrow(data),
      blue_mae = mean(abs(blue_error)),
      red_mae = mean(abs(red_error)),
      blue_rmse = sqrt(mean(blue_error^2)),
      red_rmse = sqrt(mean(red_error^2)),
      blue_bias = mean(blue_error),
      red_bias = mean(red_error),
      observed_team_kill_correlation = stats::cor(
        data$blue_observed,
        data$red_observed
      ),
      predicted_team_mean_correlation = stats::cor(
        data$blue_prediction_mean,
        data$red_prediction_mean
      ),
      stringsAsFactors = FALSE
    )
  }))
}

development <- summarize_period(
  "joint_team_monte_carlo_development_metrics.rds",
  "development_2022_2025"
)
result <- development
utils::write.csv(
  result,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_team_diagnostics.csv"
  ),
  row.names = FALSE
)
print(result, row.names = FALSE)
