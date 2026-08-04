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
team_features <- c(
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
  "matchup_snowball_imbalance"
)
draft_features <- c(
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
  "draft_scaling_imbalance"
)
intensity_features <- unique(c(team_features, draft_features))
v1_features <- c(
  "pace",
  "draft_frontline",
  "draft_burst",
  "draft_frontline_imbalance"
)
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
assert_development_period(train, development_end)
age_days <- as.numeric(difftime(
  development_end,
  train$series_cutoff,
  units = "days"
))
weights <- 0.5^(
  age_days / round_config$observation_half_life_days
)
fold <- data.frame(
  fold_id = "2026_secondary",
  validation_start = development_end,
  stringsAsFactors = FALSE
)
score_predictions <- function(
  predictions,
  candidate_id,
  distribution,
  feature_block
) {
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    prediction <- predictions[[index]]
    scored <- .score_count_map(
      validation[index, , drop = FALSE],
      prediction,
      candidate_id,
      distribution,
      feature_block,
      fold,
      nrow(train),
      sum(weights)
    )
    if (!is.null(prediction$duration_mean)) {
      scored$duration_observed <-
        validation$game_length_minutes[[index]]
      scored$duration_prediction_mean <- prediction$duration_mean
      scored$duration_prediction_sd <- prediction$duration_sd
      scored$duration_lower_90 <- prediction$duration_lower_90
      scored$duration_upper_90 <- prediction$duration_upper_90
      scored$intensity_per_minute <- prediction$intensity_per_minute
      scored$duration_coupling <- prediction$duration_coupling
    }
    scored$pmf <- I(list(prediction$pmf))
    scored
  })
  do.call(rbind, rows)
}
bind_rows_fill <- function(batches) {
  all_columns <- unique(unlist(lapply(batches, names)))
  prepared <- lapply(batches, function(data) {
    for (column in setdiff(all_columns, names(data))) {
      data[[column]] <- NA
    }
    data[all_columns]
  })
  do.call(rbind, prepared)
}

batches <- list()
v1 <- fit_count_regression(
  train,
  "negative_binomial",
  v1_features,
  weights
)
batches[[1L]] <- score_predictions(
  predict_count_regression(v1, validation),
  "nb_v1_rebuilt",
  "negative_binomial",
  "nb_v1_rebuilt"
)
direct_candidates <- list(
  ridge_multiscale_team = team_features,
  ridge_multiscale_team_draft = unique(c(
    team_features,
    draft_features
  ))
)
batch_index <- 1L
for (candidate_id in names(direct_candidates)) {
  fit <- fit_regularized_count_model(
    train,
    feature_names = direct_candidates[[candidate_id]],
    alpha = round_config$regularization_alpha,
    weights = weights,
    inner_fraction =
      round_config$inner_temporal_validation_fraction
  )
  batch_index <- batch_index + 1L
  batches[[batch_index]] <- score_predictions(
    predict_regularized_count_model(fit, validation),
    candidate_id,
    "regularized_negative_binomial",
    candidate_id
  )
}
coupled_candidates <- c(
  coupled_kill_market = TRUE,
  coupled_no_duration_dependency = FALSE
)
diagnostics <- list()
for (candidate_id in names(coupled_candidates)) {
  fit <- fit_coupled_kill_model(
    train,
    duration_features = duration_features,
    intensity_features = intensity_features,
    alpha_duration = round_config$regularization_alpha,
    alpha_intensity = round_config$regularization_alpha,
    weights = weights,
    inner_fraction =
      round_config$inner_temporal_validation_fraction,
    couple_duration = coupled_candidates[[candidate_id]]
  )
  predictions <- predict_coupled_kill_model(
    fit,
    validation,
    draws = round_config$monte_carlo_draws,
    seed = 20260726L,
    tail_tolerance =
      evaluation_config$simple_team_models$pmf_tail_tolerance
  )
  batch_index <- batch_index + 1L
  batches[[batch_index]] <- score_predictions(
    predictions,
    candidate_id,
    "coupled_negative_binomial_mixture",
    "duration_times_intensity"
  )
  diagnostics[[candidate_id]] <- data.frame(
    candidate_id = candidate_id,
    theta = fit$theta,
    duration_residual_sd_log = fit$duration$residual_sd_log,
    duration_coupling = fit$duration_coupling,
    stringsAsFactors = FALSE
  )
}
metrics <- bind_rows_fill(batches)
summary <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "distribution", "feature_block")
)
point_metrics <- do.call(rbind, lapply(
  split(metrics, metrics$candidate_id),
  function(data) {
    error <- data$prediction_mean - data$observed
    data.frame(
      candidate_id = data$candidate_id[[1L]],
      mae = mean(abs(error)),
      rmse = sqrt(mean(error^2)),
      correlation = stats::cor(
        data$prediction_mean,
        data$observed
      ),
      stringsAsFactors = FALSE
    )
  }
))
summary <- merge(summary, point_metrics, by = "candidate_id")
summary <- summary[
  order(summary$mean_crps, summary$mean_log_score),
  ,
  drop = FALSE
]
by_league <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "league_canonical")
)
line_summary <- evaluate_line_probabilities(
  metrics,
  lines = as.numeric(unlist(round_config$line_grid))
)$summary
duration_rows <- metrics[
  metrics$candidate_id %in% names(coupled_candidates),
  ,
  drop = FALSE
]
duration_summary <- do.call(rbind, lapply(
  split(duration_rows, duration_rows$candidate_id),
  function(data) {
    error <- data$duration_prediction_mean - data$duration_observed
    data.frame(
      candidate_id = data$candidate_id[[1L]],
      mae_minutes = mean(abs(error)),
      rmse_minutes = sqrt(mean(error^2)),
      bias_minutes = mean(error),
      correlation = stats::cor(
        data$duration_prediction_mean,
        data$duration_observed
      ),
      coverage_90 = mean(
        data$duration_observed >= data$duration_lower_90 &
          data$duration_observed <= data$duration_upper_90
      ),
      stringsAsFactors = FALSE
    )
  }
))
bootstrap <- do.call(rbind, lapply(
  setdiff(unique(metrics$candidate_id), "nb_v1_rebuilt"),
  function(candidate) {
    paired_block_bootstrap_crps(
      metrics,
      candidate_id = candidate,
      reference_id = "nb_v1_rebuilt",
      replicates = 2000L,
      seed = 20260726L
    )
  }
))

artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
saveRDS(
  metrics,
  file.path(artifact_dir, "kill_market_2026_map_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "kill_market_2026_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(artifact_dir, "kill_market_2026_by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  line_summary,
  file.path(artifact_dir, "kill_market_2026_line_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  duration_summary,
  file.path(artifact_dir, "kill_market_2026_duration_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  do.call(rbind, diagnostics),
  file.path(artifact_dir, "kill_market_2026_diagnostics.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(artifact_dir, "kill_market_2026_bootstrap_vs_v1.csv"),
  row.names = FALSE
)
print(summary, row.names = FALSE)
cat("\nDuracao:\n")
print(duration_summary, row.names = FALSE)
cat("\nBootstrap contra V1:\n")
print(bootstrap, row.names = FALSE)
