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
full <- c(
  "pace", "draft_frontline", "draft_burst",
  "draft_frontline_imbalance"
)
candidates <- list(
  v1_full = full,
  without_league = full,
  without_pace = setdiff(full, "pace"),
  without_draft_frontline = setdiff(full, "draft_frontline"),
  without_draft_burst = setdiff(full, "draft_burst"),
  without_draft_frontline_imbalance = setdiff(
    full, "draft_frontline_imbalance"
  )
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
    if (candidate == "without_league") {
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
reference <- by_fold[by_fold$candidate_id == "v1_full", ]
paired <- do.call(rbind, lapply(
  setdiff(names(candidates), "v1_full"),
  function(candidate) {
    rows <- merge(
      by_fold[by_fold$candidate_id == candidate, ],
      reference,
      by = "fold_id",
      suffixes = c("_candidate", "_v1")
    )
    delta <- rows$crps_candidate - rows$crps_v1
    data.frame(
      candidate_id = candidate,
      mean_paired_crps_delta = mean(delta),
      paired_crps_delta_se = stats::sd(delta) / sqrt(length(delta)),
      folds_better_or_equal = sum(delta <= 0),
      folds = length(delta)
    )
  }
))
line_metrics <- evaluate_line_probabilities(
  metrics,
  as.numeric(unlist(round_config$line_grid))
)$summary
artifact_dir <- file.path(project_root, "artifacts", "evaluation")
saveRDS(
  metrics,
  file.path(artifact_dir, "v1_variable_ablation_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "v1_variable_ablation_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  paired,
  file.path(artifact_dir, "v1_variable_ablation_paired.csv"),
  row.names = FALSE
)
utils::write.csv(
  line_metrics,
  file.path(artifact_dir, "v1_variable_ablation_lines.csv"),
  row.names = FALSE
)
print(summary[order(summary$mean_crps), ], row.names = FALSE)
print(paired[order(paired$mean_paired_crps_delta), ], row.names = FALSE)
