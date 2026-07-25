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
evaluation <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation$structural_bayesian_round
interim_dir <- file.path(project_root, config$paths$interim)
player_metrics <- readRDS(file.path(
  interim_dir,
  "player_map_metrics.rds"
))
metric_names <- evaluation$player_draft_research$metric_names
interaction_metric_names <- "conflict_involvement_per_minute"
interaction_features <- build_player_rolling_features(
  player_metrics,
  metric_names = interaction_metric_names,
  half_life_days = round_config$observation_half_life_days,
  prior_games = round_config$player_prior_games,
  interaction_prior_games =
    round_config$player_champion_interaction_prior_games
)
base_player_path <- file.path(
  interim_dir,
  "player_rolling_features.rds"
)
if (!file.exists(base_player_path)) {
  stop(
    "Missing validated base player rolling features.",
    call. = FALSE
  )
}
player_features <- readRDS(base_player_path)
join_columns <- c(
  "gameid",
  "side",
  "position",
  "player_id",
  "champion"
)
interaction_key <- interaction(
  interaction_features[join_columns],
  drop = TRUE,
  lex.order = TRUE
)
base_key <- interaction(
  player_features[join_columns],
  drop = TRUE,
  lex.order = TRUE
)
matched <- match(base_key, interaction_key)
if (anyNA(matched)) {
  stop(
    "Interaction histories do not align with base player histories.",
    call. = FALSE
  )
}
interaction_columns <- c(
  "raw_player_champion_games",
  "latest_player_champion_history_datetime",
  "hist_player_champion_conflict_involvement_per_minute",
  "effective_player_champion_conflict_involvement_per_minute_games"
)
for (column in interaction_columns) {
  player_features[[column]] <-
    interaction_features[[column]][matched]
}
taxonomy <- read_champion_taxonomy(file.path(
  project_root,
  "config",
  "taxonomy",
  "champions-2026.yml"
))
draft_features <- assemble_player_draft_features(
  player_features,
  taxonomy
)
map_features <- derive_team_signal_features(readRDS(file.path(
  interim_dir,
  paste0(
    "map_features_prior",
    round_config$team_prior_games,
    ".rds"
  )
)))
structural <- merge(
  map_features,
  draft_features,
  by = "gameid",
  all.x = TRUE,
  sort = FALSE
)
for (column in c(
  "blue_team_id",
  "blue_team_name",
  "red_team_id",
  "red_team_name"
)) {
  if (!column %in% names(structural)) {
    structural[[column]] <- structural[[paste0(column, ".x")]]
  }
}
if (anyDuplicated(structural$gameid)) {
  stop("Structural feature table has duplicate maps.", call. = FALSE)
}
leakage <- !is.na(
  player_features$latest_player_champion_history_datetime
) &
  player_features$latest_player_champion_history_datetime >=
    player_features$series_cutoff
if (any(leakage)) {
  stop("Player-champion features contain future information.", call. = FALSE)
}
saveRDS(
  player_features,
  file.path(interim_dir, "player_rolling_features_structural.rds"),
  version = 3L
)
saveRDS(
  structural,
  file.path(interim_dir, "structural_map_features.rds"),
  version = 3L
)
summary <- data.frame(
  maps = nrow(structural),
  maps_before_2026 = sum(
    structural$game_datetime <
      as.POSIXct(round_config$development_end, tz = "UTC")
  ),
  maps_2026_secondary = sum(
    structural$game_datetime >=
      as.POSIXct(round_config$secondary_comparison_start, tz = "UTC")
  ),
  taxonomy_champions = nrow(taxonomy),
  player_champion_prior_games =
    round_config$player_champion_interaction_prior_games,
  leakage_rows = sum(leakage),
  stringsAsFactors = FALSE
)
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "research"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  summary,
  file.path(artifact_dir, "structural_feature_summary.csv"),
  row.names = FALSE
)
print(summary, row.names = FALSE)
