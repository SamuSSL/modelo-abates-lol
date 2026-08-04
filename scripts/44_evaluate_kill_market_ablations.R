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
base_features <- c(
  "pace",
  "draft_frontline",
  "draft_burst",
  "draft_frontline_imbalance"
)
multiscale_features <- c(
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
  "assist_activity_medium"
)
behavior_features <- c(
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
archetype_features <- c(
  "draft_difficulty",
  "draft_engage",
  "draft_poke_siege",
  "draft_dive",
  "draft_protect",
  "draft_skirmish",
  "draft_scaling",
  "draft_scaling_imbalance"
)
candidate_features <- list(
  ridge_v1_regularized = base_features,
  ridge_v1_plus_multiscale = unique(c(
    base_features,
    multiscale_features
  )),
  ridge_v1_plus_behavior = unique(c(
    base_features,
    behavior_features
  )),
  ridge_v1_plus_multiscale_behavior = unique(c(
    base_features,
    multiscale_features,
    behavior_features
  )),
  ridge_v1_plus_all_draft = unique(c(
    base_features,
    multiscale_features,
    behavior_features,
    archetype_features
  ))
)
score_predictions <- function(
  validation,
  predictions,
  candidate_id,
  fold,
  train,
  weights
) {
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    scored <- .score_count_map(
      validation[index, , drop = FALSE],
      predictions[[index]],
      candidate_id,
      "regularized_negative_binomial",
      candidate_id,
      fold,
      nrow(train),
      sum(weights)
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
  point <- do.call(rbind, lapply(
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
  merge(summary, point, by = "candidate_id")
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

development_batches <- list()
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
  for (candidate_id in names(candidate_features)) {
    fit <- fit_regularized_count_model(
      train,
      candidate_features[[candidate_id]],
      alpha = 0,
      weights = weights,
      inner_fraction =
        round_config$inner_temporal_validation_fraction
    )
    batch_index <- batch_index + 1L
    development_batches[[batch_index]] <- score_predictions(
      validation,
      predict_regularized_count_model(fit, validation),
      candidate_id,
      fold,
      train,
      weights
    )
  }
}
development_metrics <- do.call(rbind, development_batches)
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
secondary_batches <- list()
for (candidate_index in seq_along(candidate_features)) {
  candidate_id <- names(candidate_features)[[candidate_index]]
  fit <- fit_regularized_count_model(
    train,
    candidate_features[[candidate_id]],
    alpha = 0,
    weights = weights,
    inner_fraction =
      round_config$inner_temporal_validation_fraction
  )
  secondary_batches[[candidate_index]] <- score_predictions(
    validation,
    predict_regularized_count_model(fit, validation),
    candidate_id,
    secondary_fold,
    train,
    weights
  )
}
secondary_metrics <- do.call(rbind, secondary_batches)
secondary_summary <- summarize_metrics(secondary_metrics)

artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
saveRDS(
  development_metrics,
  file.path(artifact_dir, "kill_market_ablation_development_metrics.rds"),
  version = 3L
)
saveRDS(
  secondary_metrics,
  file.path(artifact_dir, "kill_market_ablation_2026_metrics.rds"),
  version = 3L
)
utils::write.csv(
  development_summary,
  file.path(artifact_dir, "kill_market_ablation_development_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  secondary_summary,
  file.path(artifact_dir, "kill_market_ablation_2026_summary.csv"),
  row.names = FALSE
)
cat("Desenvolvimento:\n")
print(
  development_summary[order(development_summary$mean_crps), ],
  row.names = FALSE
)
cat("\n2026 secundario:\n")
print(
  secondary_summary[order(secondary_summary$mean_crps), ],
  row.names = FALSE
)
