script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
artifact_dir <- file.path(project_root, "artifacts", "evaluation")
all_metrics <- readRDS(file.path(
  artifact_dir, "all_development_model_metrics.rds"
))
v1 <- all_metrics[
  all_metrics$candidate_id == "nb_v1_rebuilt",
  ,
  drop = FALSE
]
ridge <- readRDS(file.path(
  artifact_dir, "kill_market_development_map_metrics.rds"
))
ridge <- ridge[
  ridge$candidate_id == "ridge_multiscale_team_draft",
  ,
  drop = FALSE
]
bind_rows_fill <- function(batches) {
  columns <- unique(unlist(lapply(batches, names)))
  prepared <- lapply(batches, function(data) {
    for (column in setdiff(columns, names(data))) {
      data[[column]] <- NA
    }
    data[columns]
  })
  do.call(rbind, prepared)
}
shadow <- build_pmf_ensemble(
  bind_rows_fill(list(v1, ridge)),
  c("nb_v1_rebuilt", "ridge_multiscale_team_draft"),
  c(0.5, 0.5),
  "ensemble_shadow_50"
)
v1_idr <- recalibrate_oof_idr(v1, "nb_v1_rebuilt_idr")
shadow_idr <- recalibrate_oof_idr(shadow, "ensemble_shadow_50_idr")
metrics <- bind_rows_fill(list(v1, shadow, v1_idr, shadow_idr))
summary <- .summarize_simple_metrics(
  metrics, c("candidate_id", "distribution", "feature_block")
)
saveRDS(
  metrics,
  file.path(artifact_dir, "idr_recalibration_development_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "idr_recalibration_summary.csv"),
  row.names = FALSE
)
print(summary[order(summary$mean_crps), ], row.names = FALSE)
