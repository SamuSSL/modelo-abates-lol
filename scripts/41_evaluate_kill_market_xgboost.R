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
feature_names <- c(
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

fit_boost <- function(train, weights, seed) {
  prepared <- .prepare_regularized_numeric_features(
    train,
    feature_names
  )
  data <- prepared$data
  league_levels <- sort(unique(as.character(data$league_canonical)))
  x <- .regularized_design_matrix(
    data,
    feature_names,
    league_levels
  )
  dtrain <- xgboost::xgb.DMatrix(
    x,
    label = data$total_kills_game,
    weight = weights
  )
  model <- xgboost::xgb.train(
    params = list(
      objective = boost_config$objective,
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
    data = dtrain,
    nrounds = boost_config$nrounds,
    verbose = 0
  )
  fitted <- as.numeric(stats::predict(model, x))
  list(
    model = model,
    theta = .estimate_nb_theta(
      data$total_kills_game,
      fitted,
      weights
    ),
    imputation = prepared$imputation,
    league_levels = league_levels,
    x_columns = colnames(x)
  )
}
predict_boost <- function(fit, validation) {
  prepared <- .prepare_regularized_numeric_features(
    validation,
    feature_names,
    fit$imputation
  )$data
  x <- .regularized_design_matrix(
    prepared,
    feature_names,
    fit$league_levels,
    fit$x_columns
  )
  means <- as.numeric(stats::predict(fit$model, x))
  lapply(means, function(mean) {
    distribution <- make_count_pmf(
      mean,
      "negative_binomial",
      theta = fit$theta
    )
    c(list(mean = mean), distribution)
  })
}
score_boost <- function(
  validation,
  predictions,
  fold,
  training_games,
  effective_training_games
) {
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    scored <- .score_count_map(
      validation[index, , drop = FALSE],
      predictions[[index]],
      "xgboost_kill_market",
      "xgboost_negative_binomial",
      "kill_market_rich",
      fold,
      training_games,
      effective_training_games
    )
    scored$pmf <- I(list(predictions[[index]]$pmf))
    scored
  })
  do.call(rbind, rows)
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
  fit <- fit_boost(train, weights, 20260726L + fold_index)
  batches[[fold_index]] <- score_boost(
    validation,
    predict_boost(fit, validation),
    fold,
    nrow(train),
    sum(weights)
  )
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
secondary_fit <- fit_boost(train, weights, 20260726L)
secondary_fold <- data.frame(
  fold_id = "2026_secondary",
  validation_start = development_end,
  stringsAsFactors = FALSE
)
secondary_metrics <- score_boost(
  validation,
  predict_boost(secondary_fit, validation),
  secondary_fold,
  nrow(train),
  sum(weights)
)
secondary_summary <- summarize_metrics(secondary_metrics)

development_reference <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "all_development_model_metrics.rds"
))
development_reference <- development_reference[
  development_reference$candidate_id == "nb_v1_rebuilt",
  ,
  drop = FALSE
]
secondary_reference <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "kill_market_2026_map_metrics.rds"
))
secondary_reference <- secondary_reference[
  secondary_reference$candidate_id == "nb_v1_rebuilt",
  ,
  drop = FALSE
]
bootstrap_development <- paired_block_bootstrap_crps(
  rbind(
    development_reference[
      c("gameid", "candidate_id", "game_datetime", "crps")
    ],
    development_metrics[
      c("gameid", "candidate_id", "game_datetime", "crps")
    ]
  ),
  "xgboost_kill_market",
  "nb_v1_rebuilt",
  replicates = 2000L,
  seed = 20260726L
)
bootstrap_secondary <- paired_block_bootstrap_crps(
  rbind(
    secondary_reference[
      c("gameid", "candidate_id", "game_datetime", "crps")
    ],
    secondary_metrics[
      c("gameid", "candidate_id", "game_datetime", "crps")
    ]
  ),
  "xgboost_kill_market",
  "nb_v1_rebuilt",
  replicates = 2000L,
  seed = 20260726L
)

artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
saveRDS(
  development_metrics,
  file.path(artifact_dir, "kill_market_xgboost_development_metrics.rds"),
  version = 3L
)
saveRDS(
  secondary_metrics,
  file.path(artifact_dir, "kill_market_xgboost_2026_metrics.rds"),
  version = 3L
)
utils::write.csv(
  development_summary,
  file.path(artifact_dir, "kill_market_xgboost_development_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  secondary_summary,
  file.path(artifact_dir, "kill_market_xgboost_2026_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap_development,
  file.path(artifact_dir, "kill_market_xgboost_development_bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap_secondary,
  file.path(artifact_dir, "kill_market_xgboost_2026_bootstrap.csv"),
  row.names = FALSE
)
cat("Desenvolvimento:\n")
print(development_summary, row.names = FALSE)
cat("\n2026 secundario:\n")
print(secondary_summary, row.names = FALSE)
