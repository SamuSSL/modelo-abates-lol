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
train <- maps[
  maps$series_cutoff >= as.POSIXct("2022-01-01", tz = "UTC") &
    maps$series_cutoff < development_end,
  ,
  drop = FALSE
]
validation <- maps[
  maps$game_datetime >= development_end,
  ,
  drop = FALSE
]
if (nrow(train) == 0L || nrow(validation) == 0L) {
  stop("The secondary split has no maps.", call. = FALSE)
}
age_days <- as.numeric(difftime(
  development_end,
  train$series_cutoff,
  units = "days"
))
weights <- 0.5^(
  age_days / round_config$observation_half_life_days
)
alphas <- as.numeric(unlist(dynamic_config$regularized_alphas))
names(alphas) <- names(dynamic_config$regularized_alphas)
feature_names <- dynamic_team_model_features()
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
base_features <- setdiff(
  feature_names,
  c(rating_features, momentum_features, behavior_features)
)
candidate_specs <- lapply(names(alphas), function(candidate_id) {
  list(
    candidate_id = candidate_id,
    alpha = alphas[[candidate_id]],
    feature_names = feature_names
  )
})
names(candidate_specs) <- names(alphas)
candidate_specs$ridge_plus_behavior <- list(
  candidate_id = "ridge_plus_behavior",
  alpha = 0,
  feature_names = c(
    base_features,
    rating_features,
    behavior_features
  )
)
fold <- data.frame(
  fold_id = "2026_secondary",
  validation_start = development_end,
  validation_end = max(validation$game_datetime) + 1,
  stringsAsFactors = FALSE
)
batches <- list()
diagnostics <- list()
coefficients <- list()
for (candidate_id in names(candidate_specs)) {
  candidate <- candidate_specs[[candidate_id]]
  fit <- fit_regularized_count_model(
    train,
    feature_names = candidate$feature_names,
    alpha = candidate$alpha,
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
  batches[[candidate_id]] <- do.call(rbind, rows)
  diagnostics[[candidate_id]] <- data.frame(
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
  coefficients[[candidate_id]] <- data.frame(
    candidate_id = candidate_id,
    term = rownames(coefficient_matrix),
    estimate = as.numeric(coefficient_matrix[, 1L]),
    standardized_estimate = as.numeric(
      coefficient_matrix[, 1L]
    ) * c(1, fit$x_scale),
    stringsAsFactors = FALSE
  )
}
metrics <- do.call(rbind, batches)
diagnostic_table <- do.call(rbind, diagnostics)
coefficient_table <- do.call(rbind, coefficients)
rownames(metrics) <- NULL
rownames(diagnostic_table) <- NULL
summary <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "distribution", "feature_block")
)
summary <- summary[
  order(summary$mean_crps, summary$mean_log_score),
  ,
  drop = FALSE
]
line_summary <- evaluate_line_probabilities(
  metrics,
  lines = c(24.5, 27.5, 30.5)
)$summary
reference <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "secondary_2026_map_metrics.rds"
))
reference <- reference[
  reference$candidate_id == "nb_v1_rebuilt",
  ,
  drop = FALSE
]
bootstrap_columns <- c(
  "gameid",
  "candidate_id",
  "game_datetime",
  "crps"
)
comparison <- rbind(
  reference[bootstrap_columns],
  metrics[bootstrap_columns]
)
bootstrap <- do.call(rbind, lapply(names(candidate_specs), function(candidate) {
  paired_block_bootstrap_crps(
    comparison,
    candidate_id = candidate,
    reference_id = "nb_v1_rebuilt",
    replicates = 2000,
    seed = round_config$mcmc$seed
  )
}))
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
saveRDS(
  metrics,
  file.path(
    artifact_dir,
    "regularized_dynamic_2026_map_metrics.rds"
  ),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(
    artifact_dir,
    "regularized_dynamic_2026_summary.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  line_summary,
  file.path(
    artifact_dir,
    "regularized_dynamic_2026_line_summary.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  diagnostic_table,
  file.path(
    artifact_dir,
    "regularized_dynamic_2026_diagnostics.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  coefficient_table,
  file.path(
    artifact_dir,
    "regularized_dynamic_2026_coefficients.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(
    artifact_dir,
    "regularized_dynamic_2026_bootstrap_vs_v1.csv"
  ),
  row.names = FALSE
)
print(summary, row.names = FALSE)
cat("\nBootstrap secundário contra V1:\n")
print(bootstrap, row.names = FALSE)
