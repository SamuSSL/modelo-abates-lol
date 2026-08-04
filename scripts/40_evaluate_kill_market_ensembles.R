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
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)

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
summarize_ensembles <- function(metrics) {
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
        stringsAsFactors = FALSE
      )
    }
  ))
  merge(summary, point, by = "candidate_id")
}
build_exploratory_ensembles <- function(metrics) {
  definitions <- list(
    ensemble_v1_ridge_50 = list(
      candidates = c(
        "nb_v1_rebuilt",
        "ridge_multiscale_team_draft"
      ),
      weights = c(0.5, 0.5)
    ),
    ensemble_v1_coupled_50 = list(
      candidates = c(
        "nb_v1_rebuilt",
        "coupled_kill_market"
      ),
      weights = c(0.5, 0.5)
    ),
    ensemble_v1_ridge_coupled = list(
      candidates = c(
        "nb_v1_rebuilt",
        "ridge_multiscale_team_draft",
        "coupled_kill_market"
      ),
      weights = c(0.5, 0.25, 0.25)
    )
  )
  ensembles <- lapply(names(definitions), function(ensemble_id) {
    definition <- definitions[[ensemble_id]]
    build_pmf_ensemble(
      metrics,
      candidate_ids = definition$candidates,
      weights = definition$weights,
      ensemble_id = ensemble_id
    )
  })
  bind_rows_fill(c(list(metrics), ensembles))
}

development_reference <- readRDS(file.path(
  artifact_dir,
  "all_development_model_metrics.rds"
))
development_reference <- development_reference[
  development_reference$candidate_id == "nb_v1_rebuilt",
  ,
  drop = FALSE
]
development_new <- readRDS(file.path(
  artifact_dir,
  "kill_market_development_map_metrics.rds"
))
development_base <- bind_rows_fill(list(
  development_reference,
  development_new[
    development_new$candidate_id %in% c(
      "ridge_multiscale_team_draft",
      "coupled_kill_market"
    ),
    ,
    drop = FALSE
  ]
))
development <- build_exploratory_ensembles(development_base)
development_summary <- summarize_ensembles(development)
development_lines <- evaluate_line_probabilities(
  development,
  as.numeric(unlist(round_config$line_grid))
)$summary
development_bootstrap <- do.call(rbind, lapply(
  grep(
    "^ensemble_",
    unique(development$candidate_id),
    value = TRUE
  ),
  function(candidate) {
    paired_block_bootstrap_crps(
      development,
      candidate,
      "nb_v1_rebuilt",
      replicates = 2000L,
      seed = 20260726L
    )
  }
))

secondary_base <- readRDS(file.path(
  artifact_dir,
  "kill_market_2026_map_metrics.rds"
))
secondary_base <- secondary_base[
  secondary_base$candidate_id %in% c(
    "nb_v1_rebuilt",
    "ridge_multiscale_team_draft",
    "coupled_kill_market"
  ),
  ,
  drop = FALSE
]
secondary <- build_exploratory_ensembles(secondary_base)
secondary_summary <- summarize_ensembles(secondary)
secondary_lines <- evaluate_line_probabilities(
  secondary,
  as.numeric(unlist(round_config$line_grid))
)$summary
secondary_bootstrap <- do.call(rbind, lapply(
  grep(
    "^ensemble_",
    unique(secondary$candidate_id),
    value = TRUE
  ),
  function(candidate) {
    paired_block_bootstrap_crps(
      secondary,
      candidate,
      "nb_v1_rebuilt",
      replicates = 2000L,
      seed = 20260726L
    )
  }
))

utils::write.csv(
  development_summary,
  file.path(artifact_dir, "kill_market_ensemble_development_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  development_lines,
  file.path(artifact_dir, "kill_market_ensemble_development_lines.csv"),
  row.names = FALSE
)
utils::write.csv(
  development_bootstrap,
  file.path(artifact_dir, "kill_market_ensemble_development_bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  secondary_summary,
  file.path(artifact_dir, "kill_market_ensemble_2026_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  secondary_lines,
  file.path(artifact_dir, "kill_market_ensemble_2026_lines.csv"),
  row.names = FALSE
)
utils::write.csv(
  secondary_bootstrap,
  file.path(artifact_dir, "kill_market_ensemble_2026_bootstrap.csv"),
  row.names = FALSE
)
cat("Desenvolvimento:\n")
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
