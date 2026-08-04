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
round_config <- evaluation_config$kill_market_distribution_round
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "kill_market_map_features.rds"
))
development_end <- as.POSIXct(
  round_config$development_end,
  tz = "UTC"
)

smooth_features <- c(
  "pace",
  "matchup_attack_defense_pressure_league",
  "kill_intensity_imbalance_medium",
  "post_15_pace_long",
  "matchup_aggression_ahead",
  "matchup_aggression_behind",
  "matchup_snowball_imbalance",
  "draft_frontline",
  "draft_burst",
  "draft_difficulty",
  "draft_engage",
  "draft_poke_siege",
  "draft_scaling"
)
interaction_pairs <- list(
  c("pace", "kill_intensity_imbalance_medium"),
  c(
    "matchup_attack_defense_pressure_league",
    "matchup_snowball_imbalance"
  ),
  c("draft_engage", "draft_scaling")
)
dispersion_features <- c(
  "pace",
  "kill_intensity_imbalance_medium",
  "matchup_snowball_imbalance",
  "draft_difficulty",
  "draft_burst",
  "draft_scaling"
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
    scored <- .score_count_map(
      validation[index, , drop = FALSE],
      predictions[[index]],
      candidate_id,
      "hierarchical_nonlinear_negative_binomial",
      feature_block,
      fold,
      nrow(train),
      sum(weights)
    )
    scored$conditional_theta <- predictions[[index]]$theta
    scored$variance_multiplier <-
      predictions[[index]]$variance_multiplier
    scored$dispersion_blend <- predictions[[index]]$dispersion_blend
    scored$pmf <- I(list(predictions[[index]]$pmf))
    scored
  })
  do.call(rbind, rows)
}

fit_period_models <- function(
  train,
  validation,
  fold,
  weights
) {
  hierarchical <- fit_hierarchical_distribution_model(
    train,
    smooth_features = smooth_features,
    interaction_pairs = interaction_pairs,
    dispersion_features = dispersion_features,
    weights = weights,
    inner_fraction = 0.30,
    include_team_effects = TRUE
  )
  no_team <- fit_hierarchical_distribution_model(
    train,
    smooth_features = smooth_features,
    interaction_pairs = interaction_pairs,
    dispersion_features = dispersion_features,
    weights = weights,
    inner_fraction = 0.30,
    include_team_effects = FALSE
  )
  prediction_sets <- list(
    gam_hierarchical_distributional =
      predict_hierarchical_distribution_model(
        hierarchical,
        validation,
        dispersion_mode = "tuned"
      ),
    gam_hierarchical_global_theta =
      predict_hierarchical_distribution_model(
        hierarchical,
        validation,
        dispersion_mode = "global"
      ),
    gam_distributional_no_team =
      predict_hierarchical_distribution_model(
        no_team,
        validation,
        dispersion_mode = "tuned"
      )
  )
  metrics <- do.call(rbind, lapply(
    names(prediction_sets),
    function(candidate_id) {
      score_predictions(
        validation,
        prediction_sets[[candidate_id]],
        candidate_id,
        if (candidate_id == "gam_distributional_no_team") {
          "nonlinear_distribution_no_team"
        } else if (candidate_id == "gam_hierarchical_global_theta") {
          "nonlinear_hierarchy_global_dispersion"
        } else {
          "nonlinear_hierarchy_distributional"
        },
        fold,
        train,
        weights
      )
    }
  ))
  smooth_table <- summary(hierarchical$mean_model)$s.table
  smooth_diagnostics <- data.frame(
    term = rownames(smooth_table),
    edf = smooth_table[, "edf"],
    reference_df = smooth_table[, "Ref.df"],
    statistic = smooth_table[, ncol(smooth_table) - 1L],
    p_value = smooth_table[, ncol(smooth_table)],
    stringsAsFactors = FALSE
  )
  list(
    metrics = metrics,
    diagnostics = data.frame(
      candidate_id = c(
        "gam_hierarchical_distributional",
        "gam_distributional_no_team"
      ),
      global_theta = c(
        hierarchical$global_theta,
        no_team$global_theta
      ),
      dispersion_blend = c(
        hierarchical$dispersion_blend,
        no_team$dispersion_blend
      ),
      theta_scale = c(
        hierarchical$theta_scale,
        no_team$theta_scale
      ),
      inner_crps = c(
        hierarchical$inner_crps,
        no_team$inner_crps
      ),
      inner_log_score = c(
        hierarchical$inner_log_score,
        no_team$inner_log_score
      ),
      stringsAsFactors = FALSE
    ),
    smooths = smooth_diagnostics
  )
}

bind_rows_fill <- function(batches) {
  all_columns <- unique(unlist(lapply(batches, names)))
  prepared <- lapply(batches, function(data) {
    for (column in setdiff(all_columns, names(data))) {
      data[[column]] <- NA
    }
    data[all_columns]
  })
  do.call(rbind, prepared)
}
summarize_metrics <- function(metrics) {
  summary <- .summarize_simple_metrics(
    metrics,
    c("candidate_id", "distribution", "feature_block")
  )
  point <- do.call(rbind, lapply(
    split(metrics, metrics$candidate_id),
    function(data) {
      error <- data$prediction_mean - data$observed
      data.frame(
        candidate_id = data$candidate_id[[1L]],
        mae = mean(abs(error)),
        rmse = sqrt(mean(error^2)),
        correlation = stats::cor(
          data$prediction_mean,
          data$observed
        ),
        mean_theta = mean(data$conditional_theta, na.rm = TRUE),
        sd_theta = stats::sd(data$conditional_theta, na.rm = TRUE),
        stringsAsFactors = FALSE
      )
    }
  ))
  merge(summary, point, by = "candidate_id")
}
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

development_batches <- list()
diagnostic_batches <- list()
smooth_batches <- list()
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  train <- maps[
    maps$series_cutoff >= as.POSIXct("2022-01-01", tz = "UTC") &
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
  age_days <- as.numeric(difftime(
    fold$validation_start[[1L]],
    train$series_cutoff,
    units = "days"
  ))
  weights <- 0.5^(
    age_days / round_config$observation_half_life_days
  )
  result <- fit_period_models(
    train,
    validation,
    fold,
    weights
  )
  development_batches[[fold_index]] <- result$metrics
  result$diagnostics$fold_id <- fold$fold_id[[1L]]
  diagnostic_batches[[fold_index]] <- result$diagnostics
  result$smooths$fold_id <- fold$fold_id[[1L]]
  smooth_batches[[fold_index]] <- result$smooths
  cat(
    "Fold hierarquico concluido:",
    fold$fold_id[[1L]],
    "com",
    nrow(validation),
    "mapas.\n"
  )
}
development_new <- do.call(rbind, development_batches)
diagnostics <- do.call(rbind, diagnostic_batches)
smooths <- do.call(rbind, smooth_batches)

development_reference <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "all_development_model_metrics.rds"
))
development_reference <- development_reference[
  development_reference$candidate_id == "nb_v1_rebuilt",
  ,
  drop = FALSE
]
development_all <- bind_rows_fill(list(
  development_reference,
  development_new
))
development_summary <- summarize_metrics(development_all)
development_by_fold <- .summarize_simple_metrics(
  development_all,
  c("candidate_id", "fold_id")
)
development_by_league <- .summarize_simple_metrics(
  development_all,
  c("candidate_id", "league_canonical")
)
development_lines <- evaluate_line_probabilities(
  development_all,
  as.numeric(unlist(round_config$line_grid))
)$summary
development_bootstrap <- do.call(rbind, lapply(
  unique(development_new$candidate_id),
  function(candidate_id) {
    paired_block_bootstrap_crps(
      development_all,
      candidate_id,
      "nb_v1_rebuilt",
      replicates = 2000L,
      seed = 20260727L
    )
  }
))

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
age_days <- as.numeric(difftime(
  development_end,
  train$series_cutoff,
  units = "days"
))
weights <- 0.5^(
  age_days / round_config$observation_half_life_days
)
secondary_fold <- data.frame(
  fold_id = "2026_secondary",
  validation_start = development_end,
  stringsAsFactors = FALSE
)
secondary_result <- fit_period_models(
  train,
  validation,
  secondary_fold,
  weights
)
secondary_new <- secondary_result$metrics
secondary_reference <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "kill_market_2026_map_metrics.rds"
))
secondary_reference <- secondary_reference[
  secondary_reference$candidate_id == "nb_v1_rebuilt",
  ,
  drop = FALSE
]
secondary_all <- bind_rows_fill(list(
  secondary_reference,
  secondary_new
))
secondary_summary <- summarize_metrics(secondary_all)
secondary_by_league <- .summarize_simple_metrics(
  secondary_all,
  c("candidate_id", "league_canonical")
)
secondary_lines <- evaluate_line_probabilities(
  secondary_all,
  as.numeric(unlist(round_config$line_grid))
)$summary
secondary_bootstrap <- do.call(rbind, lapply(
  unique(secondary_new$candidate_id),
  function(candidate_id) {
    paired_block_bootstrap_crps(
      secondary_all,
      candidate_id,
      "nb_v1_rebuilt",
      replicates = 2000L,
      seed = 20260727L
    )
  }
))

artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
saveRDS(
  development_new,
  file.path(
    artifact_dir,
    "hierarchical_distribution_development_metrics.rds"
  ),
  version = 3L
)
saveRDS(
  secondary_new,
  file.path(
    artifact_dir,
    "hierarchical_distribution_2026_metrics.rds"
  ),
  version = 3L
)
utils::write.csv(
  development_summary,
  file.path(
    artifact_dir,
    "hierarchical_distribution_development_summary.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  development_by_fold,
  file.path(
    artifact_dir,
    "hierarchical_distribution_development_by_fold.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  development_by_league,
  file.path(
    artifact_dir,
    "hierarchical_distribution_development_by_league.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  development_lines,
  file.path(
    artifact_dir,
    "hierarchical_distribution_development_lines.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  development_bootstrap,
  file.path(
    artifact_dir,
    "hierarchical_distribution_development_bootstrap.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  secondary_summary,
  file.path(
    artifact_dir,
    "hierarchical_distribution_2026_summary.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  secondary_by_league,
  file.path(
    artifact_dir,
    "hierarchical_distribution_2026_by_league.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  secondary_lines,
  file.path(
    artifact_dir,
    "hierarchical_distribution_2026_lines.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  secondary_bootstrap,
  file.path(
    artifact_dir,
    "hierarchical_distribution_2026_bootstrap.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  diagnostics,
  file.path(
    artifact_dir,
    "hierarchical_distribution_diagnostics.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  smooths,
  file.path(
    artifact_dir,
    "hierarchical_distribution_smooths.csv"
  ),
  row.names = FALSE
)
cat("\nDesenvolvimento:\n")
print(
  development_summary[
    order(development_summary$mean_crps),
    ,
    drop = FALSE
  ],
  row.names = FALSE
)
cat("\n2026 secundario:\n")
print(
  secondary_summary[
    order(secondary_summary$mean_crps),
    ,
    drop = FALSE
  ],
  row.names = FALSE
)
