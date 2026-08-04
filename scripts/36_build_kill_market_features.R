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
interim_dir <- file.path(project_root, config$paths$interim)
team_metrics <- readRDS(file.path(
  interim_dir,
  "team_map_metrics.rds"
))
games <- readRDS(file.path(
  interim_dir,
  "canonical_games.rds"
))
dynamic_maps <- readRDS(file.path(
  interim_dir,
  "dynamic_structural_map_features.rds"
))

half_lives <- c(short = 30, medium = 60, long = 120)
team_features <- build_kill_market_multiscale_features(
  team_metrics,
  half_lives = half_lives,
  prior_games = 10
)
base_maps <- assemble_map_feature_table(team_features, games)
kill_market_maps <- assemble_kill_market_map_features(base_maps)

derived_patterns <- paste0(
  "^(kill_intensity_|duration_level_|duration_imbalance_|",
  "duration_trend$|duration_ratio$|early_pace_|post_15_pace_|",
  "damage_pressure_|objective_activity_|assist_activity_|",
  "close_speed_|stall_capacity_|lead_conversion_|early_lead_size_|",
  "close_stall_balance_medium$)"
)
derived_columns <- grep(
  derived_patterns,
  names(kill_market_maps),
  value = TRUE
)
new_features <- kill_market_maps[
  ,
  c("gameid", derived_columns),
  drop = FALSE
]
result <- merge(
  dynamic_maps,
  new_features,
  by = "gameid",
  all.x = TRUE,
  sort = FALSE
)
result$game_length_minutes <- result$game_length_seconds / 60
result <- result[
  order(result$game_datetime, result$gameid),
  ,
  drop = FALSE
]
rownames(result) <- NULL

saveRDS(
  team_features,
  file.path(interim_dir, "team_kill_market_multiscale_features.rds"),
  version = 3L
)
saveRDS(
  result,
  file.path(interim_dir, "kill_market_map_features.rds"),
  version = 3L
)
cat(
  "Features de mercado de kills construidas:",
  nrow(result),
  "mapas e",
  ncol(result),
  "colunas.\n"
)
