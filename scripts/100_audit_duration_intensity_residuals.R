script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

metrics_path <- file.path(
  project_root,
  "artifacts",
  "premap_joint_model",
  "map_metrics.rds"
)
maps_path <- file.path(
  project_root,
  "data",
  "interim",
  "premap_ratio_map_features_t15.rds"
)
if (!file.exists(metrics_path) || !file.exists(maps_path)) {
  stop("Os artefatos do modelo conjunto nao estao disponiveis.", call. = FALSE)
}

metrics <- readRDS(metrics_path)
maps <- readRDS(maps_path)
candidate_id <- "joint_ml_quadratic_global"
metrics <- metrics[
  metrics$candidate_id == candidate_id,
  ,
  drop = FALSE
]
maps <- maps[c(
  "gameid",
  "game_length_minutes"
)]
data <- merge(metrics, maps, by = "gameid", all.x = TRUE)
data$predicted_duration <- data$game_length_minutes + data$duration_error
valid <- is.finite(data$game_length_minutes) &
  data$game_length_minutes > 0 &
  is.finite(data$predicted_duration) &
  data$predicted_duration > 0 &
  is.finite(data$observed) &
  data$observed >= 0 &
  is.finite(data$prediction_mean) &
  data$prediction_mean > 0
data <- data[valid, , drop = FALSE]
data$duration_residual_log <- log(data$game_length_minutes) -
  log(data$predicted_duration)
data$observed_rate <- pmax(data$observed, 0.5) /
  data$game_length_minutes
data$predicted_rate <- data$prediction_mean /
  data$predicted_duration
data$intensity_residual_log <- log(data$observed_rate) -
  log(data$predicted_rate)
data$month <- format(data$game_datetime, "%Y-%m", tz = "UTC")
data$bootstrap_block <- paste(data$month, data$series_id, sep = "|")

safe_correlation <- function(frame, method) {
  if (nrow(frame) < 30L) {
    return(NA_real_)
  }
  stats::cor(
    frame$duration_residual_log,
    frame$intensity_residual_log,
    method = method,
    use = "complete.obs"
  )
}

summarize_group <- function(frame, scope, group) {
  data.frame(
    scope = scope,
    group = group,
    maps = nrow(frame),
    pearson = safe_correlation(frame, "pearson"),
    spearman = safe_correlation(frame, "spearman"),
    stringsAsFactors = FALSE
  )
}

summary_rows <- list(summarize_group(data, "overall", "all"))
for (fold in unique(data$fold_id)) {
  summary_rows[[length(summary_rows) + 1L]] <- summarize_group(
    data[data$fold_id == fold, , drop = FALSE],
    "fold",
    fold
  )
}
for (league in unique(data$league_canonical)) {
  summary_rows[[length(summary_rows) + 1L]] <- summarize_group(
    data[data$league_canonical == league, , drop = FALSE],
    "league",
    league
  )
}
summary <- do.call(rbind, summary_rows)

set.seed(20260803L)
blocks <- split(seq_len(nrow(data)), data$bootstrap_block)
bootstrap_replicates <- 2000L
bootstrap <- data.frame(
  replicate = seq_len(bootstrap_replicates),
  pearson = NA_real_,
  spearman = NA_real_
)
for (index in seq_len(bootstrap_replicates)) {
  sampled_blocks <- sample(
    names(blocks),
    length(blocks),
    replace = TRUE
  )
  sampled <- data[unlist(blocks[sampled_blocks], use.names = FALSE), , drop = FALSE]
  bootstrap$pearson[[index]] <- safe_correlation(sampled, "pearson")
  bootstrap$spearman[[index]] <- safe_correlation(sampled, "spearman")
}
interval <- data.frame(
  method = c("pearson", "spearman"),
  estimate = c(summary$pearson[[1L]], summary$spearman[[1L]]),
  lower_95 = c(
    stats::quantile(bootstrap$pearson, 0.025, na.rm = TRUE),
    stats::quantile(bootstrap$spearman, 0.025, na.rm = TRUE)
  ),
  upper_95 = c(
    stats::quantile(bootstrap$pearson, 0.975, na.rm = TRUE),
    stats::quantile(bootstrap$spearman, 0.975, na.rm = TRUE)
  ),
  stringsAsFactors = FALSE
)

artifact_dir <- file.path(
  project_root,
  "artifacts",
  "duration-intensity-residual-audit"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  summary,
  file.path(artifact_dir, "correlation_by_scope.csv"),
  row.names = FALSE
)
utils::write.csv(
  interval,
  file.path(artifact_dir, "clustered_bootstrap_interval.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(artifact_dir, "clustered_bootstrap_replicates.csv"),
  row.names = FALSE
)
print(summary, row.names = FALSE)
print(interval, row.names = FALSE)
