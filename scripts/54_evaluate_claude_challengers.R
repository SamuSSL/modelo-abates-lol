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
maps <- build_claude_challenger_features(maps)
base <- c(
  "pace", "draft_frontline", "draft_burst",
  "draft_frontline_imbalance"
)
pair_features <- grep("^archetype_pair_", names(maps), value = TRUE)
blocks <- list(
  v1_regularized_reference = base,
  challenger_archetype_distance = c(
    base, "archetype_distance", "archetype_similarity", pair_features
  ),
  challenger_asymmetric_draft = c(
    base, "asym_engage_exposure", "asym_dive_exposure",
    "asym_poke_exposure", "asym_scaling_pressure"
  ),
  challenger_global_rw1 = c(base, "global_weekly_rw1")
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
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    result <- .score_count_map(
      validation[index, , drop = FALSE],
      predictions[[index]],
      candidate,
      "regularized_negative_binomial",
      candidate,
      fold,
      nrow(train),
      sum(weights)
    )
    result$pmf <- I(list(predictions[[index]]$pmf))
    result
  })
  do.call(rbind, rows)
}
batches <- list()
batch_index <- 0L
development_end <- parse_time(round_config$development_end)
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  train <- maps[
    maps$series_cutoff >= parse_time("2022-01-01") &
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
  weights <- 0.5^(as.numeric(difftime(
    fold$validation_start[[1L]], train$series_cutoff, units = "days"
  )) / round_config$observation_half_life_days)
  for (candidate in names(blocks)) {
    fit <- fit_regularized_count_model(
      train, blocks[[candidate]], alpha = 0, weights = weights,
      inner_fraction = round_config$inner_temporal_validation_fraction
    )
    batch_index <- batch_index + 1L
    batches[[batch_index]] <- score(
      validation,
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
crps_se <- stats::aggregate(
  by_fold$crps,
  list(candidate_id = by_fold$candidate_id),
  function(value) stats::sd(value) / sqrt(length(value))
)
names(crps_se)[[2L]] <- "crps_fold_se"
summary <- merge(summary, crps_se, by = "candidate_id")
best <- summary[which.min(summary$mean_crps), , drop = FALSE]
summary$within_one_se <- summary$mean_crps <=
  best$mean_crps + best$crps_fold_se
summary$feature_count <- vapply(
  summary$candidate_id,
  function(candidate) length(blocks[[candidate]]),
  integer(1L)
)
artifact_dir <- file.path(project_root, "artifacts", "evaluation")
saveRDS(
  metrics,
  file.path(artifact_dir, "claude_challenger_development_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "claude_challenger_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_fold,
  file.path(artifact_dir, "claude_challenger_by_fold.csv"),
  row.names = FALSE
)
print(summary[order(summary$mean_crps), ], row.names = FALSE)
