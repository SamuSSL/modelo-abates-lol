script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
evaluation_config <- yaml::read_yaml(file.path(
  project_root, "config", "evaluation.yml"
))
round_config <- evaluation_config$kill_market_distribution_round
maps <- readRDS(file.path(
  project_root, "data", "interim", "kill_market_map_features.rds"
))
candidates <- list(
  simple_three = c("pace", "draft_frontline", "draft_burst"),
  simple_three_without_league = c(
    "pace", "draft_frontline", "draft_burst"
  ),
  simple_pace_frontline = c("pace", "draft_frontline"),
  simple_pace_frontline_without_league = c("pace", "draft_frontline"),
  simple_pace_burst = c("pace", "draft_burst")
)
parse_time <- function(value) as.POSIXct(as.character(value), tz = "UTC")
folds <- do.call(rbind, lapply(
  evaluation_config$recency_sensitivity$folds,
  function(fold) data.frame(
    fold_id = fold$id,
    validation_start = parse_time(fold$validation_start),
    validation_end = parse_time(fold$validation_end)
  )
))
score <- function(validation, predictions, candidate, fold, train, weights) {
  do.call(rbind, lapply(seq_len(nrow(validation)), function(index) {
    row <- .score_count_map(
      validation[index, , drop = FALSE],
      predictions[[index]],
      candidate,
      "regularized_negative_binomial",
      candidate,
      fold,
      nrow(train),
      sum(weights)
    )
    row$pmf <- I(list(predictions[[index]]$pmf))
    row
  }))
}
batches <- list()
batch_index <- 0L
development_end <- parse_time(round_config$development_end)
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  train_base <- maps[
    maps$series_cutoff >= parse_time("2022-01-01") &
      maps$series_cutoff < fold$validation_start[[1L]],
    ,
    drop = FALSE
  ]
  validation_base <- maps[
    maps$game_datetime >= fold$validation_start[[1L]] &
      maps$game_datetime < fold$validation_end[[1L]] &
      maps$game_datetime < development_end,
    ,
    drop = FALSE
  ]
  weights <- 0.5^(as.numeric(difftime(
    fold$validation_start[[1L]],
    train_base$series_cutoff,
    units = "days"
  )) / round_config$observation_half_life_days)
  for (candidate in names(candidates)) {
    train <- train_base
    validation <- validation_base
    if (candidate %in% c(
      "simple_three_without_league",
      "simple_pace_frontline_without_league"
    )) {
      train$league_canonical <- "GLOBAL"
      validation$league_canonical <- "GLOBAL"
    }
    fit <- fit_regularized_count_model(
      train,
      candidates[[candidate]],
      alpha = 0,
      weights = weights,
      inner_fraction = round_config$inner_temporal_validation_fraction
    )
    batch_index <- batch_index + 1L
    batches[[batch_index]] <- score(
      validation_base,
      predict_regularized_count_model(fit, validation),
      candidate,
      fold,
      train,
      weights
    )
  }
}
metrics <- do.call(rbind, batches)
summary <- .summarize_simple_metrics(
  metrics, c("candidate_id", "distribution", "feature_block")
)
by_fold <- stats::aggregate(
  metrics[c("crps", "log_score")],
  metrics[c("candidate_id", "fold_id")],
  mean
)
artifact_dir <- file.path(project_root, "artifacts", "evaluation")
saveRDS(
  metrics,
  file.path(artifact_dir, "iterative_simplification_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "iterative_simplification_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_fold,
  file.path(artifact_dir, "iterative_simplification_by_fold.csv"),
  row.names = FALSE
)
print(summary[order(summary$mean_crps), ], row.names = FALSE)
