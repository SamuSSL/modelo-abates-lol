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
windows <- unlist(round_config$windows, use.names = FALSE)
for (window in windows) {
  maps[[paste0("log_count_", window)]] <- log(
    maps[[paste0("total_mu_count_", window)]]
  )
  maps[[paste0("log_rate_", window)]] <- log(
    maps[[paste0("total_mu_rate_", window)]]
  )
}
count_features <- paste0("log_count_", windows)
rate_features <- paste0("log_rate_", windows)
blocks <- list(
  nb_pace = "pace",
  ridge_pace = "pace"
)
for (window in windows) {
  blocks[[paste0("ridge_pace_count_", window)]] <- c(
    "pace",
    paste0("log_count_", window)
  )
  blocks[[paste0("ridge_pace_rate_", window)]] <- c(
    "pace",
    paste0("log_rate_", window)
  )
}
blocks$ridge_pace_count_all <- c("pace", count_features)
blocks$ridge_pace_rate_all <- c("pace", rate_features)
blocks$ridge_pace_all_ratios <- c(
  "pace",
  count_features,
  rate_features
)
blocks$ridge_all_ratios_no_pace <- c(count_features, rate_features)

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
batches <- list()
batch_index <- 0L

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
  weights <- 0.5^(as.numeric(difftime(
    fold$validation_start[[1L]],
    train$series_cutoff,
    units = "days"
  )) / round_config$observation_half_life_days)
  for (candidate_id in names(blocks)) {
    is_reference <- candidate_id == "nb_pace"
    fit <- if (is_reference) {
      fit_count_regression(
        train,
        distribution = "negative_binomial",
        feature_names = blocks[[candidate_id]],
        weights = weights
      )
    } else {
      fit_regularized_count_model(
        train,
        blocks[[candidate_id]],
        alpha = 0,
        weights = weights
      )
    }
    predictions <- if (is_reference) {
      predict_count_regression(fit, validation)
    } else {
      predict_regularized_count_model(fit, validation)
    }
    rows <- lapply(seq_len(nrow(validation)), function(index) {
      result <- .score_count_map(
        validation[index, , drop = FALSE],
        predictions[[index]],
        candidate_id,
        if (is_reference) {
          "negative_binomial"
        } else {
          "regularized_negative_binomial"
        },
        candidate_id,
        fold,
        nrow(train),
        sum(weights)
      )
      result$pmf <- I(list(predictions[[index]]$pmf))
      result
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
summary <- merge(summary, fold_se, by = "candidate_id")
summary$feature_count <- vapply(
  summary$candidate_id,
  function(candidate_id) length(blocks[[candidate_id]]),
  integer(1L)
)
best <- summary[which.min(summary$mean_crps), , drop = FALSE]
summary$within_one_se <- summary$mean_crps <=
  best$mean_crps + best$crps_fold_se
best_league <- by_league[
  by_league$candidate_id == best$candidate_id,
  c("league_canonical", "mean_crps"),
  drop = FALSE
]
names(best_league)[[2L]] <- "best_league_crps"
league_comparison <- merge(
  by_league,
  best_league,
  by = "league_canonical",
  all.x = TRUE
)
league_comparison$degradation <- (
  league_comparison$mean_crps -
    league_comparison$best_league_crps
) / league_comparison$best_league_crps
maximum_degradation <- stats::aggregate(
  league_comparison$degradation,
  list(candidate_id = league_comparison$candidate_id),
  max
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
  order(eligible$feature_count, eligible$mean_crps),
  ,
  drop = FALSE
][1L, , drop = FALSE]

line_grid <- unlist(
  evaluation$kill_market_distribution_round$line_grid,
  use.names = FALSE
)
line_metrics <- evaluate_line_probabilities(metrics, line_grid)
variable_catalog <- do.call(rbind, lapply(names(blocks), function(candidate_id) {
  data.frame(
    candidate_id = candidate_id,
    feature = blocks[[candidate_id]],
    selected = candidate_id == selected$candidate_id,
    stringsAsFactors = FALSE
  )
}))
artifact_dir <- file.path(project_root, "artifacts", "premap_model")
saveRDS(
  metrics,
  file.path(artifact_dir, "ratio_ablation_map_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary[order(summary$mean_crps), ],
  file.path(artifact_dir, "ratio_ablation_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_fold,
  file.path(artifact_dir, "ratio_ablation_by_fold.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(artifact_dir, "ratio_ablation_by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  line_metrics$summary,
  file.path(artifact_dir, "ratio_ablation_line_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  variable_catalog,
  file.path(artifact_dir, "ratio_variable_catalog.csv"),
  row.names = FALSE
)
utils::write.csv(
  selected,
  file.path(artifact_dir, "selected_ratio_model.csv"),
  row.names = FALSE
)
print(summary[order(summary$mean_crps), ], row.names = FALSE)
print(selected, row.names = FALSE)
