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
interim_dir <- file.path(project_root, "data", "interim")
team_metrics <- readRDS(file.path(interim_dir, "team_map_metrics.rds"))
pace_path <- file.path(interim_dir, "dynamic_structural_map_features.rds")
pace_maps <- if (file.exists(pace_path)) {
  source_maps <- readRDS(pace_path)
  if (all(c("gameid", "pace") %in% names(source_maps))) {
    source_maps[!duplicated(source_maps$gameid), c("gameid", "pace")]
  } else {
    NULL
  }
} else {
  NULL
}
current_game_ids <- unique(as.character(team_metrics$gameid[
  team_metrics$competition_role == "target"
]))
pace_coverage_complete <- !is.null(pace_maps) &&
  all(current_game_ids %in% as.character(pace_maps$gameid))
if (!pace_coverage_complete) {
  prior_games <- evaluation$team_feature_research$default_prior_games
  map_feature_path <- file.path(
    interim_dir,
    paste0("map_features_prior", prior_games, ".rds")
  )
  if (!file.exists(map_feature_path)) {
    stop(
      "Execute primeiro os scripts 09 e 10 para atualizar o pace.",
      call. = FALSE
    )
  }
  source_maps <- derive_team_signal_features(readRDS(map_feature_path))
  pace_maps <- source_maps[
    !duplicated(source_maps$gameid),
    c("gameid", "pace")
  ]
  missing_pace_games <- setdiff(
    current_game_ids,
    as.character(pace_maps$gameid)
  )
  if (length(missing_pace_games) > 0L) {
    stop(
      "Pace atualizado ausente para mapas canônicos.",
      call. = FALSE
    )
  }
}

build_mode <- function(mode, lead_minutes, output_name) {
  team_features <- build_premap_ratio_features(
    team_metrics,
    cutoff_mode = mode,
    prediction_lead_minutes = lead_minutes,
    result_lag_minutes = round_config$result_lag_minutes,
    prior_games = round_config$rating_prior_games
  )
  if (any(
    team_features$latest_history_available_at >
      team_features$prediction_cutoff,
    na.rm = TRUE
  )) {
    stop("Vazamento temporal detectado nos ratings pre-map.", call. = FALSE)
  }
  maps <- assemble_premap_ratio_map_features(
    team_features,
    pace_maps
  )
  maps <- derive_multiplicative_expectations(
    maps,
    round_config$windows
  )
  output_path <- file.path(interim_dir, output_name)
  saveRDS(maps, output_path, version = 3L)
  data.frame(
    artifact = output_name,
    cutoff_mode = mode,
    maps = nrow(maps),
    first_map = min(maps$game_datetime, na.rm = TRUE),
    last_map = max(maps$game_datetime, na.rm = TRUE),
    sha256 = compute_file_sha256(output_path),
    stringsAsFactors = FALSE
  )
}

manifest <- rbind(
  build_mode(
    round_config$fundamental_cutoff_mode,
    round_config$market_prediction_lead_minutes,
    "premap_ratio_map_features_series.rds"
  ),
  build_mode(
    round_config$market_cutoff_mode,
    round_config$market_prediction_lead_minutes,
    "premap_ratio_map_features_t15.rds"
  )
)
artifact_dir <- file.path(project_root, "artifacts", "premap_model")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  manifest,
  file.path(artifact_dir, "feature_manifest.csv"),
  row.names = FALSE
)
print(manifest, row.names = FALSE)
