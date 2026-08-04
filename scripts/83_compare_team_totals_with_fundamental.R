script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
scored_path <- file.path(
  project_root,
  "artifacts",
  "bettingiscool_team_totals",
  "team_totals_scored_rows.rds"
)
fundamental_path <- file.path(
  project_root,
  "artifacts",
  "premap_model",
  "development_map_metrics.rds"
)
if (!file.exists(scored_path) || !file.exists(fundamental_path)) {
  stop("Artefatos necessarios nao foram encontrados.", call. = FALSE)
}
scored <- readRDS(scored_path)
if (!"t15_to_t30" %in% names(scored)) {
  stop("Nao ha snapshots T-15 a T-30 para comparar.", call. = FALSE)
}
team_rows <- scored$t15_to_t30
team_rows <- team_rows[
  team_rows$market %in% c("home_totals", "away_totals"),
  ,
  drop = FALSE
]
group_key <- paste(
  team_rows$gameid,
  team_rows$event_id,
  team_rows$period,
  sep = "|"
)
groups <- split(seq_len(nrow(team_rows)), group_key)
map_rows <- lapply(groups, function(index) {
  rows <- team_rows[index, , drop = FALSE]
  if (
    nrow(rows) != 2L ||
      length(unique(rows$market)) != 2L
  ) {
    return(NULL)
  }
  data.frame(
    gameid = as.character(rows$gameid[[1L]]),
    event_id = as.character(rows$event_id[[1L]]),
    period = as.integer(rows$period[[1L]]),
    league_canonical = as.character(rows$league_canonical[[1L]]),
    team_total_sum_line = sum(rows$line),
    observed_total = sum(rows$team_kills),
    home_line = rows$line[rows$market == "home_totals"][[1L]],
    away_line = rows$line[rows$market == "away_totals"][[1L]],
    home_kills = rows$team_kills[rows$market == "home_totals"][[1L]],
    away_kills = rows$team_kills[rows$market == "away_totals"][[1L]],
    stringsAsFactors = FALSE
  )
})
map_rows <- map_rows[!vapply(map_rows, is.null, logical(1L))]
team_maps <- do.call(rbind, map_rows)
rownames(team_maps) <- NULL

fundamental <- readRDS(fundamental_path)
required <- c("gameid", "candidate_id", "prediction_mean", "observed")
if (!all(required %in% names(fundamental))) {
  stop("Metricas fundamentais sem colunas esperadas.", call. = FALSE)
}
fundamental <- fundamental[
  fundamental$candidate_id == "nb_pace",
  required,
  drop = FALSE
]
fundamental <- fundamental[!duplicated(fundamental$gameid), , drop = FALSE]
names(fundamental)[names(fundamental) == "prediction_mean"] <-
  "fundamental_mean"
names(fundamental)[names(fundamental) == "observed"] <-
  "fundamental_observed"
overlap <- merge(team_maps, fundamental, by = "gameid")
overlap <- overlap[
  overlap$observed_total == overlap$fundamental_observed,
  ,
  drop = FALSE
]
if (nrow(overlap) == 0L) {
  stop("Nao houve sobreposicao com as previsoes fundamentais.", call. = FALSE)
}

weights <- seq(0, 1, by = 0.25)
metrics <- lapply(weights, function(weight) {
  prediction <- (
    (1 - weight) * overlap$fundamental_mean +
      weight * overlap$team_total_sum_line
  )
  data.frame(
    candidate = if (weight == 0) {
      "league_pace"
    } else if (weight == 1) {
      "team_total_sum_line"
    } else {
      paste0("fixed_blend_", format(weight, trim = TRUE))
    },
    market_weight = weight,
    maps = nrow(overlap),
    mae = mean(abs(overlap$observed_total - prediction)),
    rmse = sqrt(mean((overlap$observed_total - prediction)^2)),
    bias = mean(overlap$observed_total - prediction),
    correlation = stats::cor(overlap$observed_total, prediction),
    stringsAsFactors = FALSE
  )
})
metrics <- do.call(rbind, metrics)
allocation <- data.frame(
  maps = nrow(overlap),
  home_line_mae = mean(abs(overlap$home_kills - overlap$home_line)),
  away_line_mae = mean(abs(overlap$away_kills - overlap$away_line)),
  observed_team_kill_correlation = stats::cor(
    overlap$home_kills,
    overlap$away_kills
  ),
  stringsAsFactors = FALSE
)

artifact_dir <- file.path(
  project_root,
  "artifacts",
  "bettingiscool_team_totals"
)
utils::write.csv(
  metrics,
  file.path(artifact_dir, "team_totals_vs_fundamental.csv"),
  row.names = FALSE
)
utils::write.csv(
  allocation,
  file.path(artifact_dir, "team_totals_allocation_diagnostics.csv"),
  row.names = FALSE
)
saveRDS(
  overlap,
  file.path(artifact_dir, "team_totals_fundamental_overlap.rds")
)
print(metrics, row.names = FALSE)
print(allocation, row.names = FALSE)
