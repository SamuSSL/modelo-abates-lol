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
assert_development_period(
  maps[maps$game_datetime < development_end, , drop = FALSE],
  development_end
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
feature_names <- dynamic_team_model_features()
alphas <- as.numeric(unlist(dynamic_config$regularized_alphas))
names(alphas) <- names(dynamic_config$regularized_alphas)
batches <- list()
diagnostics <- list()
coefficients <- list()
batch_index <- 0L
diagnostic_index <- 0L
coefficient_index <- 0L
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  validation_start <- fold$validation_start[[1L]]
  validation_end <- fold$validation_end[[1L]]
  train_rows <- maps$series_cutoff >=
    as.POSIXct("2022-01-01", tz = "UTC") &
    maps$series_cutoff < validation_start
  validation_rows <- maps$game_datetime >= validation_start &
    maps$game_datetime < validation_end &
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
  for (candidate_id in names(alphas)) {
    fit <- fit_regularized_count_model(
      train,
      feature_names = feature_names,
      alpha = alphas[[candidate_id]],
      weights = weights,
      inner_fraction =
        dynamic_config$inner_temporal_validation_fraction
    )
    predictions <- predict_regularized_count_model(
      fit,
      validation,
      tail_tolerance =
        evaluation_config$simple_team_models$pmf_tail_tolerance
    )
    rows <- lapply(seq_len(nrow(validation)), function(index) {
      scored <- .score_count_map(
        validation[index, , drop = FALSE],
        predictions[[index]],
        candidate_id = candidate_id,
        distribution = "regularized_negative_binomial",
        feature_block = "dynamic_full",
        fold = fold,
        training_games = nrow(train),
        effective_training_games = sum(weights)
      )
      scored$pmf <- I(list(predictions[[index]]$pmf))
      scored
    })
    batch_index <- batch_index + 1L
    batches[[batch_index]] <- do.call(rbind, rows)
    diagnostic_index <- diagnostic_index + 1L
    diagnostics[[diagnostic_index]] <- data.frame(
      fold_id = as.character(fold$fold_id[[1L]]),
      candidate_id = candidate_id,
      alpha = fit$alpha,
      lambda = fit$lambda,
      theta = fit$theta,
      inner_loss = fit$inner_loss,
      training_games = fit$training_games,
      nonzero_coefficients = sum(
        as.numeric(stats::coef(fit$model)) != 0
      ),
      stringsAsFactors = FALSE
    )
    coefficient_matrix <- as.matrix(stats::coef(
      fit$model,
      s = fit$lambda
    ))
    coefficient_index <- coefficient_index + 1L
    coefficients[[coefficient_index]] <- data.frame(
      fold_id = as.character(fold$fold_id[[1L]]),
      candidate_id = candidate_id,
      term = rownames(coefficient_matrix),
      estimate = as.numeric(coefficient_matrix[, 1L]),
      standardized_estimate = as.numeric(
        coefficient_matrix[, 1L]
      ) * c(1, fit$x_scale),
      stringsAsFactors = FALSE
    )
  }
}
metrics <- do.call(rbind, batches)
diagnostic_table <- do.call(rbind, diagnostics)
coefficient_table <- do.call(rbind, coefficients)
summary <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "distribution", "feature_block")
)
summary$folds_completed <- vapply(
  summary$candidate_id,
  function(candidate) length(unique(
    metrics$fold_id[metrics$candidate_id == candidate]
  )),
  integer(1L)
)
summary <- summary[
  order(summary$mean_crps, summary$mean_log_score),
  ,
  drop = FALSE
]
by_fold <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "fold_id")
)
by_league <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "league_canonical")
)
line_summary <- evaluate_line_probabilities(
  metrics,
  lines = c(24.5, 27.5, 30.5)
)$summary
reference_metrics <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "all_development_model_metrics.rds"
))
reference_ids <- c("nb_v1_rebuilt", "nb_pca90")
reference_metrics <- reference_metrics[
  reference_metrics$candidate_id %in% reference_ids,
  ,
  drop = FALSE
]
bootstrap_columns <- c(
  "gameid",
  "candidate_id",
  "game_datetime",
  "crps"
)
comparison_metrics <- rbind(
  reference_metrics[bootstrap_columns],
  metrics[bootstrap_columns]
)
bootstrap <- do.call(rbind, lapply(names(alphas), function(candidate) {
  do.call(rbind, lapply(reference_ids, function(reference) {
    paired_block_bootstrap_crps(
      comparison_metrics,
      candidate_id = candidate,
      reference_id = reference,
      replicates = 2000,
      seed = round_config$mcmc$seed
    )
  }))
}))
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
saveRDS(
  metrics,
  file.path(artifact_dir, "regularized_dynamic_map_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "regularized_dynamic_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_fold,
  file.path(artifact_dir, "regularized_dynamic_by_fold.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(artifact_dir, "regularized_dynamic_by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  line_summary,
  file.path(artifact_dir, "regularized_dynamic_line_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  diagnostic_table,
  file.path(artifact_dir, "regularized_dynamic_diagnostics.csv"),
  row.names = FALSE
)
utils::write.csv(
  coefficient_table,
  file.path(
    artifact_dir,
    "regularized_dynamic_coefficients.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(artifact_dir, "regularized_dynamic_bootstrap_vs_v1.csv"),
  row.names = FALSE
)
print(summary, row.names = FALSE)
cat("\nBootstrap contra V1:\n")
print(bootstrap, row.names = FALSE)
