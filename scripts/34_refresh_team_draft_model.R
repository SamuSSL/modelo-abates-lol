script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
load_lolkills_project()

targets::tar_make(
  names = c(
    portable_model_bundle_file,
    portable_parity_fixture_file,
    final_holdout_files
  ),
  reporter = "balanced"
)

config <- yaml::read_yaml(file.path("config", "default.yml"))
evaluation <- yaml::read_yaml(file.path("config", "evaluation.yml"))
interim_dir <- config$paths$interim
dir.create(interim_dir, recursive = TRUE, showWarnings = FALSE)

saveRDS(
  targets::tar_read(canonical_games),
  file.path(interim_dir, "canonical_games.rds"),
  version = 3L
)
saveRDS(
  targets::tar_read(team_map_metrics),
  file.path(interim_dir, "team_map_metrics.rds"),
  version = 3L
)
saveRDS(
  targets::tar_read(player_map_metrics),
  file.path(interim_dir, "player_map_metrics.rds"),
  version = 3L
)
saveRDS(
  targets::tar_read(rolling_champion_features),
  file.path(interim_dir, "champion_rolling_features.rds"),
  version = 3L
)
saveRDS(
  targets::tar_read(map_feature_table),
  file.path(
    interim_dir,
    paste0(
      "map_features_prior",
      evaluation$team_feature_research$default_prior_games,
      ".rds"
    )
  ),
  version = 3L
)
