script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
if (!requireNamespace("xgboost", quietly = TRUE)) {
  stop("xgboost e necessario para este challenger.", call. = FALSE)
}
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
boost_config <- evaluation_config$structural_bayesian_round$boosting
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "kill_market_map_features.rds"
))
development_end <- as.POSIXct(
  round_config$development_end,
  tz = "UTC"
)
base_features <- c(
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
enriched_features <- unique(c(
  base_features,
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
))

fit_xgb_duration <- function(train, weights, seed) {
  prepared <- .prepare_regularized_numeric_features(
    train,
    enriched_features
  )
  data <- prepared$data
  league_levels <- sort(unique(as.character(data$league_canonical)))
  x <- .regularized_design_matrix(
    data,
    enriched_features,
    league_levels
  )
  observed <- log(data$game_length_minutes)
  inner_size <- max(50L, floor(nrow(data) * 0.2))
  split_index <- nrow(data) - inner_size
  inner_train <- seq_len(split_index)
  inner_validation <- seq.int(split_index + 1L, nrow(data))
  inner_model <- xgboost::xgb.train(
    params = list(
      objective = "reg:squarederror",
      eta = boost_config$eta,
      max_depth = boost_config$max_depth,
      min_child_weight = boost_config$min_child_weight,
      subsample = boost_config$subsample,
      colsample_bytree = boost_config$colsample_bytree,
      lambda = boost_config$lambda,
      alpha = boost_config$alpha,
      nthread = boost_config$nthread,
      seed = seed
    ),
    data = xgboost::xgb.DMatrix(
      x[inner_train, , drop = FALSE],
      label = observed[inner_train],
      weight = weights[inner_train]
    ),
    nrounds = boost_config$nrounds,
    verbose = 0
  )
  inner_prediction <- as.numeric(stats::predict(
    inner_model,
    x[inner_validation, , drop = FALSE]
  ))
  residual_sd_log <- sqrt(stats::weighted.mean(
    (observed[inner_validation] - inner_prediction)^2,
    weights[inner_validation]
  ))
  model <- xgboost::xgb.train(
    params = list(
      objective = "reg:squarederror",
      eta = boost_config$eta,
      max_depth = boost_config$max_depth,
      min_child_weight = boost_config$min_child_weight,
      subsample = boost_config$subsample,
      colsample_bytree = boost_config$colsample_bytree,
      lambda = boost_config$lambda,
      alpha = boost_config$alpha,
      nthread = boost_config$nthread,
      seed = seed
    ),
    data = xgboost::xgb.DMatrix(
      x,
      label = observed,
      weight = weights
    ),
    nrounds = boost_config$nrounds,
    verbose = 0
  )
  list(
    model = model,
    residual_sd_log = residual_sd_log,
    imputation = prepared$imputation,
    league_levels = league_levels,
    x_columns = colnames(x)
  )
}
predict_xgb_duration <- function(fit, validation) {
  prepared <- .prepare_regularized_numeric_features(
    validation,
    enriched_features,
    fit$imputation
  )$data
  x <- .regularized_design_matrix(
    prepared,
    enriched_features,
    fit$league_levels,
    fit$x_columns
  )
  log_mean <- as.numeric(stats::predict(fit$model, x))
  data.frame(
    prediction_mean = exp(
      log_mean + 0.5 * fit$residual_sd_log^2
    ),
    lower_90 = exp(
      log_mean + stats::qnorm(0.05) * fit$residual_sd_log
    ),
    upper_90 = exp(
      log_mean + stats::qnorm(0.95) * fit$residual_sd_log
    )
  )
}
score_duration <- function(
  validation,
  prediction,
  candidate_id,
  fold_id,
  period
) {
  data.frame(
    gameid = validation$gameid,
    league_canonical = validation$league_canonical,
    game_datetime = validation$game_datetime,
    fold_id = fold_id,
    period = period,
    candidate_id = candidate_id,
    observed = validation$game_length_minutes,
    prediction_mean = prediction$prediction_mean,
    lower_90 = prediction$lower_90,
    upper_90 = prediction$upper_90,
    stringsAsFactors = FALSE
  )
}
summarize_duration <- function(metrics) {
  do.call(rbind, lapply(
    split(metrics, interaction(
      metrics$period,
      metrics$candidate_id,
      drop = TRUE
    )),
    function(data) {
      error <- data$prediction_mean - data$observed
      data.frame(
        period = data$period[[1L]],
        candidate_id = data$candidate_id[[1L]],
        maps = nrow(data),
        mae_minutes = mean(abs(error)),
        rmse_minutes = sqrt(mean(error^2)),
        bias_minutes = mean(error),
        correlation = stats::cor(
          data$prediction_mean,
          data$observed
        ),
        coverage_90 = mean(
          data$observed >= data$lower_90 &
            data$observed <= data$upper_90
        ),
        stringsAsFactors = FALSE
      )
    }
  ))
}
ridge_prediction_frame <- function(predictions) {
  data.frame(
    prediction_mean = vapply(
      predictions,
      function(item) item$mean,
      numeric(1L)
    ),
    lower_90 = vapply(
      predictions,
      function(item) {
        stats::quantile(item$draws, 0.05, names = FALSE)
      },
      numeric(1L)
    ),
    upper_90 = vapply(
      predictions,
      function(item) {
        stats::quantile(item$draws, 0.95, names = FALSE)
      },
      numeric(1L)
    )
  )
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
batch_index <- 0L
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
  ridge_sets <- list(
    duration_ridge_base = base_features,
    duration_ridge_enriched = enriched_features
  )
  for (candidate_id in names(ridge_sets)) {
    fit <- fit_regularized_duration_model(
      train,
      ridge_sets[[candidate_id]],
      alpha = 0,
      weights = weights
    )
    prediction <- ridge_prediction_frame(
      predict_regularized_duration_model(
        fit,
        validation,
        draws = 250L,
        seed = 20260726L + fold_index
      )
    )
    batch_index <- batch_index + 1L
    batches[[batch_index]] <- score_duration(
      validation,
      prediction,
      candidate_id,
      fold$fold_id[[1L]],
      "development"
    )
  }
  xgb_fit <- fit_xgb_duration(
    train,
    weights,
    20260726L + fold_index
  )
  batch_index <- batch_index + 1L
  batches[[batch_index]] <- score_duration(
    validation,
    predict_xgb_duration(xgb_fit, validation),
    "duration_xgboost_enriched",
    fold$fold_id[[1L]],
    "development"
  )
}

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
ridge_sets <- list(
  duration_ridge_base = base_features,
  duration_ridge_enriched = enriched_features
)
for (candidate_id in names(ridge_sets)) {
  fit <- fit_regularized_duration_model(
    train,
    ridge_sets[[candidate_id]],
    alpha = 0,
    weights = weights
  )
  prediction <- ridge_prediction_frame(
    predict_regularized_duration_model(
      fit,
      validation,
      draws = 250L,
      seed = 20260726L
    )
  )
  batch_index <- batch_index + 1L
  batches[[batch_index]] <- score_duration(
    validation,
    prediction,
    candidate_id,
    "2026_secondary",
    "2026_secondary"
  )
}
xgb_fit <- fit_xgb_duration(train, weights, 20260726L)
batch_index <- batch_index + 1L
batches[[batch_index]] <- score_duration(
  validation,
  predict_xgb_duration(xgb_fit, validation),
  "duration_xgboost_enriched",
  "2026_secondary",
  "2026_secondary"
)

metrics <- do.call(rbind, batches)
summary <- summarize_duration(metrics)
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
saveRDS(
  metrics,
  file.path(artifact_dir, "duration_challenger_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "duration_challenger_summary.csv"),
  row.names = FALSE
)
print(
  summary[order(summary$period, summary$rmse_minutes), ],
  row.names = FALSE
)
