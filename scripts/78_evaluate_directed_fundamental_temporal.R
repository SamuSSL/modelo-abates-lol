script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
evaluation <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation$directed_fundamental_temporal_round
maps <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "premap_ratio_map_features_series.rds"
))
maps <- maps[order(maps$game_datetime), , drop = FALSE]

parse_time <- function(value) {
  as.POSIXct(as.character(value), tz = "UTC")
}
folds <- do.call(rbind, lapply(
  evaluation$recency_sensitivity$folds,
  function(fold) {
    data.frame(
      fold_id = fold$id,
      validation_start = parse_time(fold$validation_start),
      validation_end = parse_time(fold$validation_end),
      stringsAsFactors = FALSE
    )
  }
))
development_start <- parse_time(round_config$development_start)
development_end <- parse_time(round_config$development_end)
half_life <- as.numeric(round_config$observation_half_life_days)
draws <- as.integer(round_config$monte_carlo_draws)
seed <- as.integer(round_config$prediction_seed)
alpha <- as.numeric(round_config$regularization_alpha)
inner_fraction <- as.numeric(
  round_config$inner_temporal_validation_fraction
)

score_predictions <- function(
  validation,
  predictions,
  candidate_id,
  feature_block,
  fold,
  train,
  weights
) {
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    .score_count_map(
      validation[index, , drop = FALSE],
      predictions[[index]],
      candidate_id,
      "negative_binomial",
      feature_block,
      fold,
      nrow(train),
      sum(weights)
    )
  })
  do.call(rbind, rows)
}

candidate_specs <- lapply(round_config$candidates, function(candidate) {
  list(
    id = as.character(candidate$id),
    windows = as.character(unlist(candidate$windows)),
    complexity = as.integer(candidate$complexity)
  )
})
names(candidate_specs) <- vapply(
  candidate_specs,
  `[[`,
  character(1L),
  "id"
)
complexity <- c(
  nb_pace = 2L,
  vapply(candidate_specs, `[[`, integer(1L), "complexity")
)

batches <- list()
batch_index <- 0L
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  train <- maps[
    maps$game_datetime >= development_start &
      maps$prediction_cutoff < fold$validation_start[[1L]],
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
  if (nrow(train) == 0L || nrow(validation) == 0L) {
    next
  }
  weights <- 0.5^(
    as.numeric(difftime(
      fold$validation_start[[1L]],
      train$prediction_cutoff,
      units = "days"
    )) / half_life
  )

  pace_fit <- fit_count_regression(
    train,
    distribution = "negative_binomial",
    feature_names = "pace",
    weights = weights
  )
  batch_index <- batch_index + 1L
  batches[[batch_index]] <- score_predictions(
    validation,
    predict_count_regression(pace_fit, validation),
    "nb_pace",
    "league_pace",
    fold,
    train,
    weights
  )

  for (candidate_id in names(candidate_specs)) {
    spec <- candidate_specs[[candidate_id]]
    fit <- fit_directed_joint_fundamental(
      train,
      windows = spec$windows,
      alpha = alpha,
      weights = weights,
      inner_fraction = inner_fraction,
      dispersion_mode = "global",
      seed = seed + fold_index
    )
    predictions <- predict_directed_joint_fundamental(
      fit,
      validation,
      draws = draws,
      seed = seed + fold_index
    )
    batch_index <- batch_index + 1L
    batches[[batch_index]] <- score_predictions(
      validation,
      predictions,
      candidate_id,
      paste(spec$windows, collapse = "+"),
      fold,
      train,
      weights
    )
  }
  cat(
    "Fold concluido:",
    fold$fold_id[[1L]],
    "mapas:",
    nrow(validation),
    "\n"
  )
}

metrics <- do.call(rbind, batches)
rownames(metrics) <- NULL
summary <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "distribution", "feature_block")
)
by_fold <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "fold_id")
)
by_league <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "league_canonical")
)
fold_se <- stats::aggregate(
  by_fold$mean_crps,
  list(candidate_id = by_fold$candidate_id),
  function(value) stats::sd(value) / sqrt(length(value))
)
names(fold_se)[[2L]] <- "crps_fold_se"
summary <- merge(summary, fold_se, by = "candidate_id", all.x = TRUE)
summary$complexity <- as.integer(complexity[summary$candidate_id])
best <- summary[which.min(summary$mean_crps), , drop = FALSE]
summary$within_one_se <- summary$mean_crps <=
  best$mean_crps + best$crps_fold_se
selected <- summary[
  summary$within_one_se,
  ,
  drop = FALSE
]
selected <- selected[
  order(selected$complexity, selected$mean_crps),
  ,
  drop = FALSE
][1L, , drop = FALSE]

pace_league <- by_league[
  by_league$candidate_id == "nb_pace",
  c("league_canonical", "mean_crps"),
  drop = FALSE
]
names(pace_league)[[2L]] <- "pace_crps"
league_comparison <- merge(
  by_league,
  pace_league,
  by = "league_canonical",
  all.x = TRUE
)
league_comparison$degradation_vs_pace <- (
  league_comparison$mean_crps - league_comparison$pace_crps
) / league_comparison$pace_crps
maximum_degradation <- stats::aggregate(
  league_comparison$degradation_vs_pace,
  list(candidate_id = league_comparison$candidate_id),
  max,
  na.rm = TRUE
)
names(maximum_degradation)[[2L]] <-
  "maximum_league_degradation_vs_pace"
summary <- merge(summary, maximum_degradation, by = "candidate_id")

bootstrap <- do.call(rbind, lapply(
  names(candidate_specs),
  function(candidate_id) {
    paired_block_bootstrap_crps(
      metrics,
      candidate_id,
      "nb_pace",
      replicates = as.integer(round_config$bootstrap_replicates),
      seed = as.integer(round_config$bootstrap_seed)
    )
  }
))
pace <- summary[summary$candidate_id == "nb_pace", , drop = FALSE]
best_challenger <- summary[
  summary$candidate_id != "nb_pace",
  ,
  drop = FALSE
]
best_challenger <- best_challenger[
  which.min(best_challenger$mean_crps),
  ,
  drop = FALSE
]
best_bootstrap <- bootstrap[
  bootstrap$candidate_id == best_challenger$candidate_id,
  ,
  drop = FALSE
]
promotion_checks <- data.frame(
  check = c(
    "challenger_crps_improves",
    "challenger_log_score_not_worse",
    "no_league_worse_than_one_percent",
    "coverage_90_inside_guardrail",
    "bootstrap_interval_below_zero"
  ),
  passed = c(
    best_challenger$mean_crps < pace$mean_crps,
    best_challenger$mean_log_score <= pace$mean_log_score,
    best_challenger$maximum_league_degradation_vs_pace <=
      as.numeric(
        round_config$maximum_league_crps_degradation_fraction
      ),
    best_challenger$coverage_90 >=
      as.numeric(round_config$coverage_90_minimum) &&
      best_challenger$coverage_90 <=
        as.numeric(round_config$coverage_90_maximum),
    best_bootstrap$ci_upper < 0
  ),
  stringsAsFactors = FALSE
)
decision <- data.frame(
  research_id = as.character(round_config$research_id),
  selected_by_one_standard_error = selected$candidate_id,
  best_challenger = best_challenger$candidate_id,
  all_promotion_checks_passed = all(promotion_checks$passed),
  decision = if (all(promotion_checks$passed)) {
    "promote_directed_fundamental"
  } else {
    "retain_nb_pace"
  },
  stringsAsFactors = FALSE
)

artifact_dir <- file.path(
  project_root,
  "artifacts",
  "premap_joint_fundamental_temporal"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(
  metrics,
  file.path(artifact_dir, "map_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary[order(summary$mean_crps), ],
  file.path(artifact_dir, "summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_fold,
  file.path(artifact_dir, "by_fold.csv"),
  row.names = FALSE
)
utils::write.csv(
  league_comparison,
  file.path(artifact_dir, "by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(artifact_dir, "bootstrap_vs_pace.csv"),
  row.names = FALSE
)
utils::write.csv(
  promotion_checks,
  file.path(artifact_dir, "promotion_checks.csv"),
  row.names = FALSE
)
utils::write.csv(
  decision,
  file.path(artifact_dir, "decision.csv"),
  row.names = FALSE
)
print(summary[order(summary$mean_crps), ], row.names = FALSE)
print(bootstrap, row.names = FALSE)
print(promotion_checks, row.names = FALSE)
print(decision, row.names = FALSE)
