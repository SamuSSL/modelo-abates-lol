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
rating_features <- c(
  "matchup_attack_league",
  "matchup_attack_global",
  "matchup_defense_league",
  "matchup_defense_global",
  "matchup_attack_defense_pressure_league",
  "matchup_attack_defense_pressure_global"
)
momentum_features <- c(
  "matchup_momentum_attack",
  "matchup_momentum_mortality",
  "matchup_momentum_bloodiness"
)
behavior_features <- c(
  "matchup_aggression_ahead",
  "matchup_aggression_behind",
  "matchup_snowball_index",
  "matchup_snowball_imbalance"
)
base_features <- setdiff(
  dynamic_team_model_features(),
  c(rating_features, momentum_features, behavior_features)
)
candidate_features <- list(
  ridge_structural_base = base_features,
  ridge_plus_ratings = c(base_features, rating_features),
  ridge_plus_momentum = c(
    base_features,
    rating_features,
    momentum_features
  ),
  ridge_plus_behavior = c(
    base_features,
    rating_features,
    behavior_features
  )
)
batches <- list()
batch_index <- 0L
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
  for (candidate_id in names(candidate_features)) {
    fit <- fit_regularized_count_model(
      train,
      feature_names = candidate_features[[candidate_id]],
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
        feature_block = "dynamic_ablation",
        fold = fold,
        training_games = nrow(train),
        effective_training_games = sum(weights)
      )
      scored$pmf <- I(list(predictions[[index]]$pmf))
      scored
    })
    batch_index <- batch_index + 1L
    batches[[batch_index]] <- do.call(rbind, rows)
  }
}
metrics <- do.call(rbind, batches)
rownames(metrics) <- NULL
full_metrics <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "regularized_dynamic_map_metrics.rds"
))
full_metrics <- full_metrics[
  full_metrics$candidate_id == "ridge",
  ,
  drop = FALSE
]
all_metrics <- rbind(
  metrics,
  full_metrics[names(metrics)]
)
summary <- .summarize_simple_metrics(
  all_metrics,
  c("candidate_id", "distribution", "feature_block")
)
by_fold <- .summarize_simple_metrics(
  all_metrics,
  c("candidate_id", "fold_id")
)
by_league <- .summarize_simple_metrics(
  all_metrics,
  c("candidate_id", "league_canonical")
)
line_summary <- evaluate_line_probabilities(
  all_metrics,
  lines = c(24.5, 27.5, 30.5)
)$summary
summary <- summary[
  order(summary$mean_crps, summary$mean_log_score),
  ,
  drop = FALSE
]
bootstrap_columns <- c(
  "gameid",
  "candidate_id",
  "game_datetime",
  "crps"
)
bootstrap_metrics <- all_metrics[bootstrap_columns]
bootstrap <- do.call(rbind, lapply(
  names(candidate_features),
  function(candidate) {
    paired_block_bootstrap_crps(
      bootstrap_metrics,
      candidate_id = candidate,
      reference_id = "ridge",
      replicates = 2000,
      seed = round_config$mcmc$seed
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
  file.path(
    artifact_dir,
    "dynamic_rating_ablation_map_metrics.rds"
  ),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(
    artifact_dir,
    "dynamic_rating_ablation_summary.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(
    artifact_dir,
    "dynamic_rating_ablation_bootstrap_vs_full.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  by_fold,
  file.path(
    artifact_dir,
    "dynamic_rating_ablation_by_fold.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(
    artifact_dir,
    "dynamic_rating_ablation_by_league.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  line_summary,
  file.path(
    artifact_dir,
    "dynamic_rating_ablation_line_summary.csv"
  ),
  row.names = FALSE
)
print(summary, row.names = FALSE)
cat("\nAblações contra Ridge completo:\n")
print(bootstrap, row.names = FALSE)
