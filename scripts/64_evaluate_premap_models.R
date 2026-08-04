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
round_config <- evaluation$premap_multiplicative_round
maps <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "premap_ratio_map_features_series.rds"
))
parse_time <- function(value) as.POSIXct(as.character(value), tz = "UTC")
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
windows <- unlist(round_config$windows, use.names = FALSE)

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
    result <- .score_count_map(
      validation[index, , drop = FALSE],
      predictions[[index]],
      candidate_id,
      "negative_binomial",
      feature_block,
      fold,
      nrow(train),
      sum(weights)
    )
    result$pmf <- I(list(predictions[[index]]$pmf))
    result
  })
  do.call(rbind, rows)
}

metric_batches <- list()
duration_batches <- list()
batch_index <- 0L
duration_index <- 0L
candidate_complexity <- c(
  nb_league = 1L,
  nb_pace = 2L
)

for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  train <- maps[
    maps$series_cutoff >= development_start &
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
  if (nrow(train) == 0L || nrow(validation) == 0L) {
    next
  }
  weights <- 0.5^(as.numeric(difftime(
    fold$validation_start[[1L]],
    train$series_cutoff,
    units = "days"
  )) / round_config$observation_half_life_days)

  for (baseline in list(
    list(id = "nb_league", features = character()),
    list(id = "nb_pace", features = "pace")
  )) {
    fit <- fit_count_regression(
      train,
      "negative_binomial",
      baseline$features,
      weights
    )
    predictions <- predict_count_regression(fit, validation)
    batch_index <- batch_index + 1L
    metric_batches[[batch_index]] <- score_predictions(
      validation,
      predictions,
      baseline$id,
      baseline$id,
      fold,
      train,
      weights
    )
  }

  for (expectation in c("count", "rate")) {
    for (window in windows) {
      candidate_id <- paste(
        "multiplicative",
        expectation,
        window,
        sep = "_"
      )
      fit <- fit_premap_multiplicative_model(
        train,
        expectation = expectation,
        windows = windows,
        combination = "single",
        selected_window = window
      )
      predictions <- predict_premap_multiplicative_model(fit, validation)
      batch_index <- batch_index + 1L
      metric_batches[[batch_index]] <- score_predictions(
        validation,
        predictions,
        candidate_id,
        paste(expectation, window, sep = "_"),
        fold,
        train,
        weights
      )
      candidate_complexity[[candidate_id]] <- if (expectation == "count") {
        3L
      } else {
        4L
      }
    }

    for (combination in c("equal", "optimized")) {
      candidate_id <- paste(
        "multiplicative",
        expectation,
        combination,
        sep = "_"
      )
      fit <- fit_premap_multiplicative_model(
        train,
        expectation = expectation,
        windows = windows,
        combination = combination,
        weights = weights
      )
      predictions <- predict_premap_multiplicative_model(fit, validation)
      batch_index <- batch_index + 1L
      metric_batches[[batch_index]] <- score_predictions(
        validation,
        predictions,
        candidate_id,
        candidate_id,
        fold,
        train,
        weights
      )
      candidate_complexity[[candidate_id]] <- if (combination == "equal") {
        5L
      } else {
        9L
      }
    }

    candidate_id <- paste(
      "multiplicative",
      expectation,
      "optimized_pace",
      sep = "_"
    )
    fit <- fit_premap_multiplicative_model(
      train,
      expectation = expectation,
      windows = windows,
      combination = "optimized",
      calibrated = TRUE,
      correction_features = "pace",
      weights = weights
    )
    predictions <- predict_premap_multiplicative_model(fit, validation)
    batch_index <- batch_index + 1L
    metric_batches[[batch_index]] <- score_predictions(
      validation,
      predictions,
      candidate_id,
      candidate_id,
      fold,
      train,
      weights
    )
    candidate_complexity[[candidate_id]] <- 10L

    candidate_id <- paste(
      "multiplicative",
      expectation,
      "regularized_exponents",
      sep = "_"
    )
    fit <- fit_regularized_multiplicative_exponents(
      train,
      expectation = expectation,
      windows = windows,
      alpha = 0,
      weights = weights
    )
    predictions <- predict_regularized_multiplicative_exponents(
      fit,
      validation
    )
    batch_index <- batch_index + 1L
    metric_batches[[batch_index]] <- score_predictions(
      validation,
      predictions,
      candidate_id,
      candidate_id,
      fold,
      train,
      weights
    )
    candidate_complexity[[candidate_id]] <- if (expectation == "count") {
      12L
    } else {
      17L
    }
  }

  duration_specs <- list(
    duration_gamma = list(type = "gamma", regularized = FALSE),
    duration_lognormal = list(type = "lognormal", regularized = FALSE),
    duration_regularized_lognormal = list(
      type = "lognormal",
      regularized = TRUE
    )
  )
  for (candidate_id in names(duration_specs)) {
    spec <- duration_specs[[candidate_id]]
    duration_features <- if (isTRUE(spec$regularized)) {
      c("pace", paste0("duration_", windows))
    } else {
      c("pace", "duration_season", "duration_last10")
    }
    fit <- if (isTRUE(spec$regularized)) {
      fit_regularized_duration_model(
        train,
        duration_features,
        alpha = 0,
        weights = weights
      )
    } else {
      fit_duration_regression(
        train,
        distribution = spec$type,
        feature_names = duration_features,
        weights = weights
      )
    }
    predictions <- if (isTRUE(spec$regularized)) {
      predict_regularized_duration_model(
        fit,
        validation,
        draws = 500,
        seed = 20260729L + fold_index
      )
    } else {
      predict_duration_regression(
        fit,
        validation,
        draws = 500,
        seed = 20260729L + fold_index
      )
    }
    scored <- score_duration_distributions(
      predictions,
      validation$game_length_minutes
    )$map_scores
    duration_index <- duration_index + 1L
    duration_batches[[duration_index]] <- data.frame(
      gameid = validation$gameid,
      league_canonical = validation$league_canonical,
      fold_id = fold$fold_id[[1L]],
      candidate_id = candidate_id,
      scored,
      stringsAsFactors = FALSE
    )
  }
}

metrics <- do.call(rbind, metric_batches)
rownames(metrics) <- NULL
reference_path <- file.path(
  project_root,
  "artifacts",
  "evaluation",
  "all_development_model_metrics.rds"
)
shadow_path <- file.path(
  project_root,
  "artifacts",
  "evaluation",
  "kill_market_development_map_metrics.rds"
)
if (file.exists(reference_path) && file.exists(shadow_path)) {
  references <- readRDS(reference_path)
  v1 <- references[
    references$candidate_id == "nb_v1_rebuilt",
    ,
    drop = FALSE
  ]
  shadow_components <- readRDS(shadow_path)
  ridge_draft <- shadow_components[
    shadow_components$candidate_id == "ridge_multiscale_team_draft",
    ,
    drop = FALSE
  ]
  ensemble_input <- rbind(
    v1[intersect(names(v1), names(ridge_draft))],
    ridge_draft[intersect(names(v1), names(ridge_draft))]
  )
  shadow <- build_pmf_ensemble(
    ensemble_input,
    c("nb_v1_rebuilt", "ridge_multiscale_team_draft"),
    c(0.5, 0.5),
    "shadow_ensemble_current"
  )
  reference_rows <- rbind(
    v1[intersect(names(v1), names(shadow))],
    shadow[intersect(names(v1), names(shadow))]
  )
  common <- intersect(names(metrics), names(reference_rows))
  metrics <- rbind(metrics[common], reference_rows[common])
  candidate_complexity[["nb_v1_rebuilt"]] <- 5L
  candidate_complexity[["shadow_ensemble_current"]] <- 20L
}

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
summary$complexity <- as.integer(candidate_complexity[summary$candidate_id])
best <- summary[which.min(summary$mean_crps), , drop = FALSE]
summary$within_one_se <- summary$mean_crps <=
  best$mean_crps + best$crps_fold_se
best_league <- by_league[
  by_league$candidate_id == best$candidate_id,
  c("league_canonical", "mean_crps"),
  drop = FALSE
]
names(best_league)[[2L]] <- "best_league_crps"
league_guardrail <- merge(
  by_league,
  best_league,
  by = "league_canonical",
  all.x = TRUE
)
league_guardrail$degradation <- (
  league_guardrail$mean_crps -
    league_guardrail$best_league_crps
) / league_guardrail$best_league_crps
maximum_degradation <- stats::aggregate(
  league_guardrail$degradation,
  list(candidate_id = league_guardrail$candidate_id),
  max,
  na.rm = TRUE
)
names(maximum_degradation)[[2L]] <- "maximum_league_degradation"
summary <- merge(summary, maximum_degradation, by = "candidate_id")
summary$league_guardrail_passed <-
  summary$maximum_league_degradation <= 0.01
summary$log_score_guardrail_passed <-
  summary$mean_log_score <= best$mean_log_score + 0.005
eligible <- summary[
  summary$within_one_se &
    summary$league_guardrail_passed &
    summary$log_score_guardrail_passed,
  ,
  drop = FALSE
]
selected <- eligible[
  order(eligible$complexity, eligible$mean_crps),
  ,
  drop = FALSE
][1L, , drop = FALSE]

duration_metrics <- do.call(rbind, duration_batches)
duration_summary <- stats::aggregate(
  duration_metrics[c(
    "crps",
    "log_score",
    "absolute_error",
    "error",
    "coverage_50",
    "coverage_80",
    "coverage_90"
  )],
  duration_metrics["candidate_id"],
  mean
)
duration_summary$maps <- as.integer(table(
  duration_metrics$candidate_id
)[duration_summary$candidate_id])

artifact_dir <- file.path(project_root, "artifacts", "premap_model")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(
  metrics,
  file.path(artifact_dir, "development_map_metrics.rds"),
  version = 3L
)
saveRDS(
  duration_metrics,
  file.path(artifact_dir, "duration_development_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary[order(summary$mean_crps), ],
  file.path(artifact_dir, "development_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_fold,
  file.path(artifact_dir, "development_by_fold.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(artifact_dir, "development_by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  duration_summary[order(duration_summary$crps), ],
  file.path(artifact_dir, "duration_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  selected,
  file.path(artifact_dir, "selected_fundamental_model.csv"),
  row.names = FALSE
)
print(summary[order(summary$mean_crps), ], row.names = FALSE)
print(selected, row.names = FALSE)
print(duration_summary[order(duration_summary$crps), ], row.names = FALSE)
