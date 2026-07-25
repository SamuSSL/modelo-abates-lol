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
if (!requireNamespace("cmdstanr", quietly = TRUE)) {
  stop("cmdstanr is required for Bayesian folds.", call. = FALSE)
}
cmdstan_path <- file.path(
  Sys.getenv("USERPROFILE"),
  ".cmdstan",
  "cmdstan-2.37.0"
)
cmdstanr::set_cmdstan_path(cmdstan_path)
model <- cmdstanr::cmdstan_model(file.path(
  project_root,
  "stan",
  "hierarchical_intensity_duration.stan"
))
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "structural_map_features.rds"
))
for (column in c(
  "blue_team_id",
  "blue_team_name",
  "red_team_id",
  "red_team_name"
)) {
  if (!column %in% names(maps)) {
    canonical_column <- paste0(column, ".x")
    maps[[column]] <- maps[[canonical_column]]
  }
}
maps$game_length_minutes <- maps$game_length_seconds / 60
development_end <- as.POSIXct(
  round_config$development_end,
  tz = "UTC"
)
intensity_features <- c(
  "team_opponent_intensity",
  "matchup_intensity_imbalance",
  "draft_engage",
  "draft_dive",
  "draft_skirmish",
  "player_champion_conflict_delta"
)
duration_features <- c(
  "duration_history",
  "duration_history_imbalance",
  "draft_scaling",
  "draft_poke_siege",
  "draft_protect"
)
required <- unique(c(
  "gameid",
  "game_datetime",
  "series_cutoff",
  "league_canonical",
  "blue_team_id",
  "blue_team_name",
  "red_team_id",
  "red_team_name",
  "blue_kills",
  "red_kills",
  "total_kills_game",
  "game_length_minutes",
  intensity_features,
  duration_features
))
folds <- do.call(rbind, lapply(
  evaluation_config$recency_sensitivity$folds,
  function(fold) {
    data.frame(
      fold_id = fold$id,
      validation_start = as.POSIXct(
        fold$validation_start,
        tz = "UTC"
      ),
      validation_end = as.POSIXct(
        fold$validation_end,
        tz = "UTC"
      ),
      stringsAsFactors = FALSE
    )
  }
))
bayes_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "bayesian"
)
dir.create(bayes_dir, recursive = TRUE, showWarnings = FALSE)
fold_metrics <- list()
fold_diagnostics <- list()
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  fold_dir <- file.path(
    bayes_dir,
    as.character(fold$fold_id[[1L]])
  )
  dir.create(fold_dir, recursive = TRUE, showWarnings = FALSE)
  metric_path <- file.path(fold_dir, "map_metrics.rds")
  diagnostic_path <- file.path(fold_dir, "diagnostics.csv")
  if (file.exists(metric_path) && file.exists(diagnostic_path)) {
    fold_metrics[[fold_index]] <- readRDS(metric_path)
    fold_diagnostics[[fold_index]] <- utils::read.csv(
      diagnostic_path,
      stringsAsFactors = FALSE
    )
    next
  }
  train_rows <- maps$series_cutoff <
    fold$validation_start[[1L]]
  validation_rows <- maps$game_datetime >=
    fold$validation_start[[1L]] &
    maps$game_datetime < fold$validation_end[[1L]] &
    maps$game_datetime < development_end
  train <- maps[train_rows, required, drop = FALSE]
  validation <- maps[validation_rows, required, drop = FALSE]
  train <- train[stats::complete.cases(train), , drop = FALSE]
  validation <- validation[
    stats::complete.cases(validation),
    ,
    drop = FALSE
  ]
  age_days <- as.numeric(difftime(
    fold$validation_start[[1L]],
    train$series_cutoff,
    units = "days"
  ))
  weights <- 0.5^(
    age_days / round_config$observation_half_life_days
  )
  prepared <- prepare_bayesian_fold_data(
    train,
    validation,
    intensity_features,
    duration_features,
    weights = weights,
    development_end = development_end
  )
  fit <- model$sample(
    data = prepared$data,
    seed = round_config$mcmc$seed + fold_index,
    chains = round_config$mcmc$chains,
    parallel_chains = round_config$mcmc$parallel_chains,
    iter_warmup = round_config$mcmc$iter_warmup,
    iter_sampling = round_config$mcmc$iter_sampling,
    adapt_delta = round_config$mcmc$adapt_delta,
    max_treedepth = round_config$mcmc$max_treedepth,
    output_dir = fold_dir,
    refresh = 200
  )
  counts <- fit$draws("y_pred", format = "matrix")
  metrics <- score_bayesian_predictions(
    counts,
    prepared$metadata$validation,
    fold,
    candidate_id = "bayesian_hierarchical"
  )
  duration_draws <- fit$draws(
    "duration_pred",
    format = "matrix"
  )
  intensity_draws <- fit$draws(
    "intensity_pred",
    format = "matrix"
  )
  metrics$duration_prediction_mean <- colMeans(duration_draws)
  metrics$duration_prediction_sd <- apply(
    duration_draws,
    2L,
    stats::sd
  )
  metrics$intensity_per_minute <- colMeans(intensity_draws)
  diagnostics <- summarize_mcmc_diagnostics(fit)
  diagnostics$fold_id <- fold$fold_id[[1L]]
  diagnostics$training_maps <- nrow(train)
  diagnostics$validation_maps <- nrow(validation)
  diagnostics$effective_training_maps <- sum(weights)
  saveRDS(metrics, metric_path, version = 3L)
  utils::write.csv(
    diagnostics,
    diagnostic_path,
    row.names = FALSE
  )
  fit$save_object(file.path(fold_dir, "fit.rds"))
  fold_metrics[[fold_index]] <- metrics
  fold_diagnostics[[fold_index]] <- diagnostics
}
metrics <- do.call(rbind, fold_metrics)
diagnostics <- do.call(rbind, fold_diagnostics)
summary <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "distribution", "feature_block")
)
summary$folds_completed <- length(unique(metrics$fold_id))
line_evaluation <- evaluate_line_probabilities(
  metrics,
  c(24.5, 27.5, 30.5)
)
utils::write.csv(
  summary,
  file.path(bayes_dir, "bayesian_fold_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  diagnostics,
  file.path(bayes_dir, "bayesian_diagnostics.csv"),
  row.names = FALSE
)
utils::write.csv(
  line_evaluation$summary,
  file.path(bayes_dir, "bayesian_line_summary.csv"),
  row.names = FALSE
)
saveRDS(
  metrics,
  file.path(bayes_dir, "bayesian_map_metrics.rds"),
  version = 3L
)
freeze <- list(
  frozen_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
  development_end = round_config$development_end,
  comparison_2026_used_for_selection = FALSE,
  stan_sha256 = digest::digest(
    file = file.path(
      project_root,
      "stan",
      "hierarchical_intensity_duration.stan"
    ),
    algo = "sha256"
  ),
  intensity_features = intensity_features,
  duration_features = duration_features,
  mcmc = round_config$mcmc,
  folds = as.character(folds$fold_id),
  cmdstan_version = as.character(cmdstanr::cmdstan_version())
)
yaml::write_yaml(
  freeze,
  file.path(bayes_dir, "bayesian_freeze.yml")
)
print(summary, row.names = FALSE)
print(diagnostics, row.names = FALSE)
print(line_evaluation$summary, row.names = FALSE)
