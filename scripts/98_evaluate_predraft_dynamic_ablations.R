script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(file.path(project_root, "config", "default.yml"))
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

base_features <- c(
  "pace",
  "team_opponent_intensity",
  "matchup_intensity_imbalance",
  "duration_history",
  "duration_history_imbalance"
)
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

candidate_features <- list(
  predraft_dynamic_base = base_features,
  predraft_dynamic_ratings = c(base_features, rating_features),
  predraft_dynamic_momentum = c(
    base_features,
    rating_features,
    momentum_features
  ),
  predraft_dynamic_behavior = c(
    base_features,
    rating_features,
    behavior_features
  )
)

forbidden_pattern <- "draft|champion|patch|side|prior_series"
if (any(grepl(
  forbidden_pattern,
  unlist(candidate_features, use.names = FALSE),
  ignore.case = TRUE
))) {
  stop("Uma feature proibida entrou na rodada pre-draft.", call. = FALSE)
}

development_end <- as.POSIXct(round_config$development_end, tz = "UTC")
batches <- list()
batch_index <- 0L
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  validation_start <- fold$validation_start[[1L]]
  train_rows <- maps$series_cutoff >= as.POSIXct("2022-01-01", tz = "UTC") &
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
  weights <- 0.5^(age_days / round_config$observation_half_life_days)
  for (candidate_id in names(candidate_features)) {
    fit <- fit_regularized_count_model(
      train,
      feature_names = candidate_features[[candidate_id]],
      alpha = 0,
      weights = weights,
      inner_fraction = dynamic_config$inner_temporal_validation_fraction
    )
    predictions <- predict_regularized_count_model(fit, validation)
    rows <- lapply(seq_len(nrow(validation)), function(index) {
      scored <- .score_count_map(
        validation[index, , drop = FALSE],
        predictions[[index]],
        candidate_id = candidate_id,
        distribution = "regularized_negative_binomial",
        feature_block = "predraft_dynamic",
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
summary <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "distribution", "feature_block")
)
by_fold <- .summarize_simple_metrics(metrics, c("candidate_id", "fold_id"))
by_league <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "league_canonical")
)
line_summary <- evaluate_line_probabilities(
  metrics,
  lines = c(24.5, 27.5, 30.5)
)$summary
summary <- summary[order(summary$mean_crps, summary$mean_log_score), ]

bootstrap <- do.call(rbind, lapply(
  setdiff(names(candidate_features), "predraft_dynamic_base"),
  function(candidate_id) {
    paired_block_bootstrap_crps(
      metrics[c("gameid", "candidate_id", "game_datetime", "crps")],
      candidate_id = candidate_id,
      reference_id = "predraft_dynamic_base",
      replicates = 2000,
      seed = round_config$mcmc$seed
    )
  }
))

artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "modeling-research",
  "predraft-market-dynamic-duration"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(metrics, file.path(artifact_dir, "predraft_dynamic_metrics.rds"), version = 3L)
utils::write.csv(summary, file.path(artifact_dir, "predraft_dynamic_summary.csv"), row.names = FALSE)
utils::write.csv(by_fold, file.path(artifact_dir, "predraft_dynamic_by_fold.csv"), row.names = FALSE)
utils::write.csv(by_league, file.path(artifact_dir, "predraft_dynamic_by_league.csv"), row.names = FALSE)
utils::write.csv(line_summary, file.path(artifact_dir, "predraft_dynamic_line_summary.csv"), row.names = FALSE)
utils::write.csv(bootstrap, file.path(artifact_dir, "predraft_dynamic_bootstrap.csv"), row.names = FALSE)
print(summary, row.names = FALSE)
cat("\nBootstrap contra base pre-draft:\n")
print(bootstrap, row.names = FALSE)
