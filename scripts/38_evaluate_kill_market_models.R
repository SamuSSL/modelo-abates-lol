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
all_features <- unique(c(
  team_features,
  draft_features,
  duration_features,
  intensity_features
))
missing_features <- setdiff(all_features, names(maps))
if (length(missing_features) > 0L) {
  stop(
    "Features ausentes na avaliacao: ",
    paste(missing_features, collapse = ", "),
    call. = FALSE
  )
}

score_predictions <- function(
  validation,
  predictions,
  candidate_id,
  distribution,
  feature_block,
  fold,
  training_games,
  effective_training_games
) {
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    prediction <- predictions[[index]]
    scored <- .score_count_map(
      validation[index, , drop = FALSE],
      prediction,
      candidate_id = candidate_id,
      distribution = distribution,
      feature_block = feature_block,
      fold = fold,
      training_games = training_games,
      effective_training_games = effective_training_games
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

metrics_batches <- list()
diagnostic_batches <- list()
coefficient_batches <- list()
metric_index <- 0L
diagnostic_index <- 0L
coefficient_index <- 0L
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
  if (nrow(train) == 0L || nrow(validation) == 0L) {
    next
  }
  age_days <- as.numeric(difftime(
    validation_start,
    train$series_cutoff,
    units = "days"
  ))
  weights <- 0.5^(
    age_days / round_config$observation_half_life_days
  )

  direct_candidates <- list(
    ridge_multiscale_team = team_features,
    ridge_multiscale_team_draft = unique(c(
      team_features,
      draft_features
    ))
  )
  for (candidate_id in names(direct_candidates)) {
    fit <- fit_regularized_count_model(
      train,
      feature_names = direct_candidates[[candidate_id]],
      alpha = round_config$regularization_alpha,
      weights = weights,
      inner_fraction =
        round_config$inner_temporal_validation_fraction
    )
    predictions <- predict_regularized_count_model(
      fit,
      validation,
      tail_tolerance =
        evaluation_config$simple_team_models$pmf_tail_tolerance
    )
    metric_index <- metric_index + 1L
    metrics_batches[[metric_index]] <- score_predictions(
      validation,
      predictions,
      candidate_id,
      "regularized_negative_binomial",
      candidate_id,
      fold,
      nrow(train),
      sum(weights)
    )
    diagnostic_index <- diagnostic_index + 1L
    diagnostic_batches[[diagnostic_index]] <- data.frame(
      fold_id = fold$fold_id[[1L]],
      candidate_id = candidate_id,
      lambda = fit$lambda,
      theta = fit$theta,
      inner_loss = fit$inner_loss,
      duration_residual_sd_log = NA_real_,
      duration_coupling = NA_real_,
      stringsAsFactors = FALSE
    )
    coefficient_matrix <- as.matrix(stats::coef(
      fit$model,
      s = fit$lambda
    ))
    coefficient_index <- coefficient_index + 1L
    coefficient_batches[[coefficient_index]] <- data.frame(
      fold_id = fold$fold_id[[1L]],
      candidate_id = candidate_id,
      component = "total_kills",
      term = rownames(coefficient_matrix),
      estimate = as.numeric(coefficient_matrix[, 1L]),
      stringsAsFactors = FALSE
    )
  }

  coupled_candidates <- c(
    coupled_kill_market = TRUE,
    coupled_no_duration_dependency = FALSE
  )
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
      seed = 20260726L + fold_index,
      tail_tolerance =
        evaluation_config$simple_team_models$pmf_tail_tolerance
    )
    metric_index <- metric_index + 1L
    metrics_batches[[metric_index]] <- score_predictions(
      validation,
      predictions,
      candidate_id,
      "coupled_negative_binomial_mixture",
      "duration_times_intensity",
      fold,
      nrow(train),
      sum(weights)
    )
    diagnostic_index <- diagnostic_index + 1L
    diagnostic_batches[[diagnostic_index]] <- data.frame(
      fold_id = fold$fold_id[[1L]],
      candidate_id = candidate_id,
      lambda = fit$lambda,
      theta = fit$theta,
      inner_loss = fit$inner_loss,
      duration_residual_sd_log = fit$duration$residual_sd_log,
      duration_coupling = fit$duration_coupling,
      stringsAsFactors = FALSE
    )
    intensity_coefficients <- as.matrix(stats::coef(
      fit$intensity_model,
      s = fit$lambda
    ))
    duration_coefficients <- as.matrix(stats::coef(
      fit$duration$model,
      s = fit$duration$lambda
    ))
    coefficient_index <- coefficient_index + 1L
    coefficient_batches[[coefficient_index]] <- rbind(
      data.frame(
        fold_id = fold$fold_id[[1L]],
        candidate_id = candidate_id,
        component = "intensity",
        term = rownames(intensity_coefficients),
        estimate = as.numeric(intensity_coefficients[, 1L]),
        stringsAsFactors = FALSE
      ),
      data.frame(
        fold_id = fold$fold_id[[1L]],
        candidate_id = candidate_id,
        component = "duration",
        term = rownames(duration_coefficients),
        estimate = as.numeric(duration_coefficients[, 1L]),
        stringsAsFactors = FALSE
      )
    )
  }
  cat(
    "Fold concluido:",
    as.character(fold$fold_id[[1L]]),
    "com",
    nrow(validation),
    "mapas.\n"
  )
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
new_metrics <- bind_rows_fill(metrics_batches)
diagnostics <- do.call(rbind, diagnostic_batches)
coefficients <- do.call(rbind, coefficient_batches)
reference_metrics <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "all_development_model_metrics.rds"
))
reference_metrics <- reference_metrics[
  reference_metrics$candidate_id == "nb_v1_rebuilt",
  ,
  drop = FALSE
]
shared_columns <- union(names(reference_metrics), names(new_metrics))
for (column in setdiff(shared_columns, names(reference_metrics))) {
  reference_metrics[[column]] <- NA
}
for (column in setdiff(shared_columns, names(new_metrics))) {
  new_metrics[[column]] <- NA
}
all_metrics <- rbind(
  reference_metrics[shared_columns],
  new_metrics[shared_columns]
)

summary <- .summarize_simple_metrics(
  all_metrics,
  c("candidate_id", "distribution", "feature_block")
)
point_metrics <- do.call(rbind, lapply(
  split(all_metrics, all_metrics$candidate_id),
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
summary$folds_completed <- vapply(
  summary$candidate_id,
  function(candidate) length(unique(
    all_metrics$fold_id[all_metrics$candidate_id == candidate]
  )),
  integer(1L)
)
summary <- summary[
  order(summary$mean_crps, summary$mean_log_score),
  ,
  drop = FALSE
]
by_fold <- .summarize_simple_metrics(
  all_metrics,
  c("candidate_id", "fold_id")
)
by_league <- .summarize_simple_metrics(
  all_metrics,
  c("candidate_id", "league_canonical")
)
line_evaluation <- evaluate_line_probabilities(
  all_metrics,
  lines = as.numeric(unlist(round_config$line_grid))
)
duration_rows <- new_metrics[
  new_metrics$candidate_id %in% c(
    "coupled_kill_market",
    "coupled_no_duration_dependency"
  ),
  ,
  drop = FALSE
]
duration_summary <- do.call(rbind, lapply(
  split(duration_rows, duration_rows$candidate_id),
  function(data) {
    error <- data$duration_prediction_mean - data$duration_observed
    data.frame(
      candidate_id = data$candidate_id[[1L]],
      maps = nrow(data),
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
      mean_prediction_sd = mean(data$duration_prediction_sd),
      stringsAsFactors = FALSE
    )
  }
))
bootstrap <- do.call(rbind, lapply(
  unique(new_metrics$candidate_id),
  function(candidate) {
    paired_block_bootstrap_crps(
      all_metrics,
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
  new_metrics,
  file.path(artifact_dir, "kill_market_development_map_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "kill_market_development_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_fold,
  file.path(artifact_dir, "kill_market_development_by_fold.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(artifact_dir, "kill_market_development_by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  line_evaluation$summary,
  file.path(artifact_dir, "kill_market_development_line_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  duration_summary,
  file.path(artifact_dir, "kill_market_duration_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  diagnostics,
  file.path(artifact_dir, "kill_market_model_diagnostics.csv"),
  row.names = FALSE
)
utils::write.csv(
  coefficients,
  file.path(artifact_dir, "kill_market_model_coefficients.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(artifact_dir, "kill_market_bootstrap_vs_v1.csv"),
  row.names = FALSE
)
print(summary, row.names = FALSE)
cat("\nDuracao:\n")
print(duration_summary, row.names = FALSE)
cat("\nBootstrap contra V1:\n")
print(bootstrap, row.names = FALSE)
