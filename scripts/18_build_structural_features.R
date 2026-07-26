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
champion_history_path <- file.path(
  interim_dir,
  "champion_rolling_features.rds"
)
if (!file.exists(champion_history_path)) {
  stop(
    "Missing validated champion rolling features.",
    call. = FALSE
  )
}
champion_features <- readRDS(champion_history_path)
taxonomy <- read_champion_taxonomy(file.path(
  project_root,
  "config",
  "taxonomy",
  "champions-2026.yml"
))
draft_features <- assemble_draft_features(
  champion_features,
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
  player_identity_features = FALSE,
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
