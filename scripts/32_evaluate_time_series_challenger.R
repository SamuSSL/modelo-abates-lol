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
evaluation_config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation_config$structural_bayesian_round
dynamic_config <- evaluation_config$dynamic_team_round

maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "dynamic_structural_map_features.rds"
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
ratings <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "team_dynamic_ratings.rds"
))
tracking <- build_tracking_time_series(
  games,
  team_metrics,
  ratings,
  min_date = as.Date("2022-01-01")
)
maps <- attach_tracking_features_to_maps(maps, tracking)

rating_features <- c(
  "matchup_attack_league",
  "matchup_attack_global",
  "matchup_defense_league",
  "matchup_defense_global",
  "matchup_attack_defense_pressure_league",
  "matchup_attack_defense_pressure_global"
)
excluded_features <- c(
  rating_features,
  "matchup_momentum_attack",
  "matchup_momentum_mortality",
  "matchup_momentum_bloodiness",
  "matchup_aggression_ahead",
  "matchup_aggression_behind",
  "matchup_snowball_index",
  "matchup_snowball_imbalance"
)
base_features <- setdiff(
  dynamic_team_model_features(),
  excluded_features
)
behavior_features <- c(
  "matchup_aggression_ahead",
  "matchup_aggression_behind",
  "matchup_snowball_index",
  "matchup_snowball_imbalance"
)
feature_names <- c(
  base_features,
  rating_features,
  behavior_features,
  tracking_model_features()
)
candidate_id <- "ridge_plus_behavior_time_series"
parse_datetime <- function(value) {
  as.POSIXct(as.character(value), tz = "UTC")
}
folds <- do.call(rbind, lapply(
  evaluation_config$recency_sensitivity$folds,
  function(fold) {
    data.frame(
      fold_id = fold$id,
      validation_start = parse_datetime(fold$validation_start),
      validation_end = parse_datetime(fold$validation_end),
      stringsAsFactors = FALSE
    )
  }
))
development_end <- parse_datetime(round_config$development_end)
batches <- list()
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  validation_start <- fold$validation_start[[1L]]
  train_rows <- maps$series_cutoff >=
    as.POSIXct("2022-01-01", tz = "UTC") &
    maps$series_cutoff < validation_start
  validation_rows <- maps$game_datetime >= validation_start &
    maps$game_datetime < fold$validation_end[[1L]] &
    maps$game_datetime < development_end
  train <- maps[train_rows, , drop = FALSE]
  validation <- maps[validation_rows, , drop = FALSE]
  age_days <- as.numeric(difftime(
    validation_start,
    train$series_cutoff,
    units = "days"
  ))
  weights <- 0.5^(
    age_days / round_config$observation_half_life_days
  )
  fit <- fit_regularized_count_model(
    train,
    feature_names = feature_names,
    alpha = 0,
    weights = weights,
    inner_fraction =
      dynamic_config$inner_temporal_validation_fraction
  )
  predictions <- predict_regularized_count_model(fit, validation)
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    scored <- .score_count_map(
      validation[index, , drop = FALSE],
      predictions[[index]],
      candidate_id = candidate_id,
      distribution = "regularized_negative_binomial",
      feature_block = "time_series",
      fold = fold,
      training_games = nrow(train),
      effective_training_games = sum(weights)
    )
    scored$pmf <- I(list(predictions[[index]]$pmf))
    scored
  })
  batches[[fold_index]] <- do.call(rbind, rows)
}
development_metrics <- do.call(rbind, batches)
reference_development <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "dynamic_rating_ablation_map_metrics.rds"
))
reference_development <- reference_development[
  reference_development$candidate_id == "ridge_plus_behavior",
  ,
  drop = FALSE
]
development_comparison <- rbind(
  development_metrics,
  reference_development[names(development_metrics)]
)
development_summary <- .summarize_simple_metrics(
  development_comparison,
  c("candidate_id", "distribution", "feature_block")
)
development_by_fold <- .summarize_simple_metrics(
  development_comparison,
  c("candidate_id", "fold_id")
)
development_by_league <- .summarize_simple_metrics(
  development_comparison,
  c("candidate_id", "league_canonical")
)
development_bootstrap <- paired_block_bootstrap_crps(
  development_comparison[
    c("gameid", "candidate_id", "game_datetime", "crps")
  ],
  candidate_id = candidate_id,
  reference_id = "ridge_plus_behavior",
  replicates = 2000,
  seed = round_config$mcmc$seed
)

secondary_start <- parse_datetime(
  round_config$secondary_comparison_start
)
train <- maps[
  maps$series_cutoff >= as.POSIXct("2022-01-01", tz = "UTC") &
    maps$series_cutoff < secondary_start,
  ,
  drop = FALSE
]
secondary <- maps[
  maps$game_datetime >= secondary_start,
  ,
  drop = FALSE
]
age_days <- as.numeric(difftime(
  secondary_start,
  train$series_cutoff,
  units = "days"
))
weights <- 0.5^(
  age_days / round_config$observation_half_life_days
)
fit <- fit_regularized_count_model(
  train,
  feature_names = feature_names,
  alpha = 0,
  weights = weights,
  inner_fraction =
    dynamic_config$inner_temporal_validation_fraction
)
predictions <- predict_regularized_count_model(fit, secondary)
secondary_fold <- data.frame(
  fold_id = "secondary_2026",
  validation_start = secondary_start,
  validation_end = max(secondary$game_datetime) + 1,
  stringsAsFactors = FALSE
)
secondary_rows <- lapply(seq_len(nrow(secondary)), function(index) {
  scored <- .score_count_map(
    secondary[index, , drop = FALSE],
    predictions[[index]],
    candidate_id = candidate_id,
    distribution = "regularized_negative_binomial",
    feature_block = "time_series",
    fold = secondary_fold,
    training_games = nrow(train),
    effective_training_games = sum(weights)
  )
  scored$pmf <- I(list(predictions[[index]]$pmf))
  scored
})
secondary_metrics <- do.call(rbind, secondary_rows)
reference_secondary <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "regularized_dynamic_2026_map_metrics.rds"
))
reference_secondary <- reference_secondary[
  reference_secondary$candidate_id == "ridge_plus_behavior",
  ,
  drop = FALSE
]
secondary_comparison <- rbind(
  secondary_metrics,
  reference_secondary[names(secondary_metrics)]
)
secondary_summary <- .summarize_simple_metrics(
  secondary_comparison,
  c("candidate_id", "distribution", "feature_block")
)
secondary_by_league <- .summarize_simple_metrics(
  secondary_comparison,
  c("candidate_id", "league_canonical")
)
secondary_bootstrap <- paired_block_bootstrap_crps(
  secondary_comparison[
    c("gameid", "candidate_id", "game_datetime", "crps")
  ],
  candidate_id = candidate_id,
  reference_id = "ridge_plus_behavior",
  replicates = 2000,
  seed = round_config$mcmc$seed
)

artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
saveRDS(
  development_metrics,
  file.path(artifact_dir, "time_series_challenger_map_metrics.rds"),
  version = 3L
)
saveRDS(
  secondary_metrics,
  file.path(
    artifact_dir,
    "time_series_challenger_2026_map_metrics.rds"
  ),
  version = 3L
)
outputs <- list(
  time_series_challenger_summary = development_summary,
  time_series_challenger_by_fold = development_by_fold,
  time_series_challenger_by_league = development_by_league,
  time_series_challenger_bootstrap = development_bootstrap,
  time_series_challenger_2026_summary = secondary_summary,
  time_series_challenger_2026_by_league = secondary_by_league,
  time_series_challenger_2026_bootstrap = secondary_bootstrap
)
for (name in names(outputs)) {
  utils::write.csv(
    outputs[[name]],
    file.path(artifact_dir, paste0(name, ".csv")),
    row.names = FALSE
  )
}
print(development_summary, row.names = FALSE)
cat("\nBootstrap de desenvolvimento:\n")
print(development_bootstrap, row.names = FALSE)
cat("\nComparação secundária de 2026:\n")
print(secondary_summary, row.names = FALSE)
cat("\nBootstrap secundário:\n")
print(secondary_bootstrap, row.names = FALSE)
