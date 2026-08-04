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
windows <- unlist(round_config$windows, use.names = FALSE)
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
  specifications <- list(
    duration_gamma = list(distribution = "gamma", regularized = FALSE),
    duration_lognormal = list(
      distribution = "lognormal",
      regularized = FALSE
    ),
    duration_regularized_lognormal = list(
      distribution = "lognormal",
      regularized = TRUE
    )
  )
  for (candidate_id in names(specifications)) {
    specification <- specifications[[candidate_id]]
    features <- if (isTRUE(specification$regularized)) {
      c("pace", paste0("duration_", windows))
    } else {
      c("pace", "duration_season", "duration_last10")
    }
    fit <- if (isTRUE(specification$regularized)) {
      fit_regularized_duration_model(
        train,
        features,
        alpha = 0,
        weights = weights
      )
    } else {
      fit_duration_regression(
        train,
        specification$distribution,
        features,
        weights
      )
    }
    predictions <- if (isTRUE(specification$regularized)) {
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
    batch_index <- batch_index + 1L
    batches[[batch_index]] <- data.frame(
      gameid = validation$gameid,
      league_canonical = validation$league_canonical,
      fold_id = fold$fold_id[[1L]],
      candidate_id = candidate_id,
      scored,
      stringsAsFactors = FALSE
    )
  }
}

metrics <- do.call(rbind, batches)
summary <- stats::aggregate(
  metrics[c(
    "crps",
    "log_score",
    "absolute_error",
    "error",
    "coverage_50",
    "coverage_80",
    "coverage_90"
  )],
  metrics["candidate_id"],
  mean
)
summary$maps <- as.integer(table(
  metrics$candidate_id
)[summary$candidate_id])
artifact_dir <- file.path(project_root, "artifacts", "premap_model")
saveRDS(
  metrics,
  file.path(artifact_dir, "duration_development_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary[order(summary$crps), ],
  file.path(artifact_dir, "duration_summary.csv"),
  row.names = FALSE
)
print(summary[order(summary$crps), ], row.names = FALSE)
