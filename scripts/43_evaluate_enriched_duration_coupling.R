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
round_config <- evaluation_config$kill_market_distribution_round
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "kill_market_map_features.rds"
))
development_end <- as.POSIXct(
  round_config$development_end,
  tz = "UTC"
)
intensity_features <- c(
  "kill_intensity_short",
  "kill_intensity_medium",
  "kill_intensity_long",
  "kill_intensity_trend",
  "kill_intensity_imbalance_medium",
  "early_pace_medium",
  "early_pace_trend",
  "post_15_pace_medium",
  "post_15_pace_trend",
  "damage_pressure_long",
  "damage_pressure_trend",
  "objective_activity_medium",
  "objective_activity_trend",
  "assist_activity_medium",
  "matchup_attack_defense_pressure_league",
  "matchup_attack_defense_pressure_global",
  "matchup_momentum_attack",
  "matchup_momentum_mortality",
  "matchup_momentum_bloodiness",
  "matchup_aggression_ahead",
  "matchup_aggression_behind",
  "matchup_snowball_index",
  "matchup_snowball_imbalance",
  "draft_frontline",
  "draft_frontline_imbalance",
  "draft_burst",
  "draft_difficulty",
  "draft_engage",
  "draft_poke_siege",
  "draft_dive",
  "draft_protect",
  "draft_skirmish",
  "draft_scaling",
  "draft_scaling_imbalance"
)
duration_features <- c(
  "duration_level_short",
  "duration_level_medium",
  "duration_level_long",
  "duration_trend",
  "duration_imbalance_medium",
  "close_speed_medium",
  "stall_capacity_medium",
  "close_stall_balance_medium",
  "lead_conversion_medium",
  "early_lead_size_medium",
  "objective_activity_medium",
  "objective_activity_trend",
  "damage_pressure_long",
  "matchup_attack_defense_pressure_global",
  "matchup_snowball_index",
  "matchup_snowball_imbalance",
  "draft_frontline",
  "draft_difficulty",
  "draft_poke_siege",
  "draft_protect",
  "draft_scaling",
  "draft_scaling_imbalance",
  "kill_intensity_short",
  "kill_intensity_medium",
  "kill_intensity_long",
  "kill_intensity_imbalance_short",
  "kill_intensity_imbalance_medium",
  "kill_intensity_imbalance_long",
  "matchup_attack_defense_pressure_league",
  "matchup_aggression_ahead",
  "matchup_aggression_behind",
  "matchup_momentum_mortality",
  "draft_magic",
  "draft_burst",
  "draft_engage",
  "draft_dive",
  "draft_skirmish"
)
score_predictions <- function(
  validation,
  predictions,
  fold,
  train,
  weights
) {
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    prediction <- predictions[[index]]
    scored <- .score_count_map(
      validation[index, , drop = FALSE],
      prediction,
      "coupled_enriched_duration",
      "coupled_negative_binomial_mixture",
      "enriched_duration_times_intensity",
      fold,
      nrow(train),
      sum(weights)
    )
    scored$duration_observed <-
      validation$game_length_minutes[[index]]
    scored$duration_prediction_mean <- prediction$duration_mean
    scored$duration_prediction_sd <- prediction$duration_sd
    scored$duration_lower_90 <- prediction$duration_lower_90
    scored$duration_upper_90 <- prediction$duration_upper_90
    scored$duration_coupling <- prediction$duration_coupling
    scored$pmf <- I(list(prediction$pmf))
    scored
  })
  do.call(rbind, rows)
}
fit_and_score <- function(
  train,
  validation,
  fold,
  weights,
  seed
) {
  fit <- fit_coupled_kill_model(
    train,
    duration_features,
    intensity_features,
    alpha_duration = 0,
    alpha_intensity = 0,
    weights = weights,
    inner_fraction =
      round_config$inner_temporal_validation_fraction,
    couple_duration = TRUE
  )
  predictions <- predict_coupled_kill_model(
    fit,
    validation,
    draws = round_config$monte_carlo_draws,
    seed = seed
  )
  list(
    metrics = score_predictions(
      validation,
      predictions,
      fold,
      train,
      weights
    ),
    coupling = fit$duration_coupling
  )
}
summarize_metrics <- function(metrics) {
  summary <- .summarize_simple_metrics(
    metrics,
    c("candidate_id", "distribution", "feature_block")
  )
  error <- metrics$prediction_mean - metrics$observed
  summary$mae <- mean(abs(error))
  summary$rmse <- sqrt(mean(error^2))
  summary$correlation <- stats::cor(
    metrics$prediction_mean,
    metrics$observed
  )
  summary
}

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
batches <- list()
couplings <- numeric(nrow(folds))
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  train <- maps[
    maps$series_cutoff >= as.POSIXct("2022-01-01", tz = "UTC") &
      maps$series_cutoff < fold$validation_start[[1L]],
    ,
    drop = FALSE
  ]
  validation <- maps[
    maps$game_datetime >= fold$validation_start[[1L]] &
      maps$game_datetime < fold$validation_end[[1L]] &
      maps$game_datetime < development_end,
    ,
    drop = FALSE
  ]
  age_days <- as.numeric(difftime(
    fold$validation_start[[1L]],
    train$series_cutoff,
    units = "days"
  ))
  weights <- 0.5^(
    age_days / round_config$observation_half_life_days
  )
  result <- fit_and_score(
    train,
    validation,
    fold,
    weights,
    20260726L + fold_index
  )
  batches[[fold_index]] <- result$metrics
  couplings[[fold_index]] <- result$coupling
}
development_metrics <- do.call(rbind, batches)
development_summary <- summarize_metrics(development_metrics)

train <- maps[
  maps$series_cutoff >= as.POSIXct("2022-01-01", tz = "UTC") &
    maps$series_cutoff < development_end,
  ,
  drop = FALSE
]
validation <- maps[
  maps$game_datetime >= development_end,
  ,
  drop = FALSE
]
age_days <- as.numeric(difftime(
  development_end,
  train$series_cutoff,
  units = "days"
))
weights <- 0.5^(
  age_days / round_config$observation_half_life_days
)
secondary_fold <- data.frame(
  fold_id = "2026_secondary",
  validation_start = development_end,
  stringsAsFactors = FALSE
)
secondary_result <- fit_and_score(
  train,
  validation,
  secondary_fold,
  weights,
  20260726L
)
secondary_metrics <- secondary_result$metrics
secondary_summary <- summarize_metrics(secondary_metrics)

artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
saveRDS(
  development_metrics,
  file.path(
    artifact_dir,
    "coupled_enriched_duration_development_metrics.rds"
  ),
  version = 3L
)
saveRDS(
  secondary_metrics,
  file.path(
    artifact_dir,
    "coupled_enriched_duration_2026_metrics.rds"
  ),
  version = 3L
)
utils::write.csv(
  rbind(
    cbind(period = "development", development_summary),
    cbind(period = "2026_secondary", secondary_summary)
  ),
  file.path(
    artifact_dir,
    "coupled_enriched_duration_summary.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  data.frame(
    period = c(rep("development_fold", length(couplings)), "2026"),
    fold_id = c(folds$fold_id, "2026_secondary"),
    duration_coupling = c(
      couplings,
      secondary_result$coupling
    )
  ),
  file.path(
    artifact_dir,
    "coupled_enriched_duration_diagnostics.csv"
  ),
  row.names = FALSE
)
cat("Desenvolvimento:\n")
print(development_summary, row.names = FALSE)
cat("\n2026 secundario:\n")
print(secondary_summary, row.names = FALSE)
