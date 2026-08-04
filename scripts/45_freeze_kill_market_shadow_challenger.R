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
result_cutoff <- max(maps$game_datetime, na.rm = TRUE)
training_cutoff <- result_cutoff + 1
v1_features <- c(
  "pace",
  "draft_frontline",
  "draft_burst",
  "draft_frontline_imbalance"
)
challenger_features <- c(
  "kill_intensity_short",
  "kill_intensity_medium",
  "kill_intensity_long",
  "kill_intensity_trend",
  "kill_intensity_imbalance_medium",
  "early_pace_medium",
  "early_pace_trend",
  "post_15_pace_medium",
  "post_15_pace_trend",
  "damage_pressure_long",
  "damage_pressure_trend",
  "objective_activity_medium",
  "objective_activity_trend",
  "assist_activity_medium",
  "matchup_attack_defense_pressure_league",
  "matchup_attack_defense_pressure_global",
  "matchup_momentum_attack",
  "matchup_momentum_mortality",
  "matchup_momentum_bloodiness",
  "matchup_aggression_ahead",
  "matchup_aggression_behind",
  "matchup_snowball_index",
  "matchup_snowball_imbalance",
  "draft_frontline",
  "draft_frontline_imbalance",
  "draft_burst",
  "draft_difficulty",
  "draft_engage",
  "draft_poke_siege",
  "draft_dive",
  "draft_protect",
  "draft_skirmish",
  "draft_scaling",
  "draft_scaling_imbalance"
)
train <- maps[
  maps$series_cutoff >= as.POSIXct("2022-01-01", tz = "UTC") &
    maps$series_cutoff < training_cutoff,
  ,
  drop = FALSE
]
age_days <- as.numeric(difftime(
  training_cutoff,
  train$series_cutoff,
  units = "days"
))
weights <- 0.5^(
  age_days / round_config$observation_half_life_days
)
v1_fit <- fit_count_regression(
  train,
  "negative_binomial",
  v1_features,
  weights
)
challenger_fit <- fit_regularized_count_model(
  train,
  challenger_features,
  alpha = 0,
  weights = weights,
  inner_fraction =
    round_config$inner_temporal_validation_fraction
)
bundle <- list(
  status = "prospective_shadow_not_promoted",
  result_cutoff = result_cutoff,
  training_cutoff = training_cutoff,
  training_maps = nrow(train),
  ensemble = list(
    candidate_id = "ensemble_v1_ridge_50",
    component_ids = c(
      "nb_v1_rebuilt",
      "ridge_multiscale_team_draft"
    ),
    weights = c(0.5, 0.5)
  ),
  v1 = v1_fit,
  challenger = challenger_fit,
  v1_features = v1_features,
  challenger_features = challenger_features,
  observation_half_life_days =
    round_config$observation_half_life_days,
  team_history_half_life_days = unlist(
    round_config$team_history_half_life_days
  )
)
model_directory <- file.path(project_root, "models")
dir.create(model_directory, recursive = TRUE, showWarnings = FALSE)
model_path <- file.path(
  model_directory,
  "kill_market_distribution_shadow_challenger.rds"
)
saveRDS(bundle, model_path, version = 3L)
model_hash <- digest::digest(
  file = model_path,
  algo = "sha256"
)
development_summary <- read.csv(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "kill_market_ensemble_development_summary.csv"
))
secondary_summary <- read.csv(file.path(
  project_root,
  config$paths$artifacts,
  "evaluation",
  "kill_market_ensemble_2026_summary.csv"
))
selected_development <- development_summary[
  development_summary$candidate_id == "ensemble_v1_ridge_50",
  ,
  drop = FALSE
]
selected_secondary <- secondary_summary[
  secondary_summary$candidate_id == "ensemble_v1_ridge_50",
  ,
  drop = FALSE
]
metadata <- list(
  model_version = paste0(
    "kill-market-shadow-",
    substr(model_hash, 1L, 12L)
  ),
  status = "prospective_shadow_not_promoted",
  result_cutoff = format(
    result_cutoff,
    tz = "UTC",
    usetz = TRUE
  ),
  clean_maps_must_be_after_cutoff = TRUE,
  training_maps = nrow(train),
  ensemble_weights = list(
    nb_v1_rebuilt = 0.5,
    ridge_multiscale_team_draft = 0.5
  ),
  development = list(
    maps = selected_development$maps[[1L]],
    crps = selected_development$mean_crps[[1L]],
    log_score = selected_development$mean_log_score[[1L]],
    coverage_90 = selected_development$coverage_90[[1L]]
  ),
  comparison_2026 = list(
    maps = selected_secondary$maps[[1L]],
    crps = selected_secondary$mean_crps[[1L]],
    log_score = selected_secondary$mean_log_score[[1L]],
    coverage_90 = selected_secondary$coverage_90[[1L]],
    can_select = FALSE
  ),
  model_sha256 = model_hash
)
yaml::write_yaml(
  metadata,
  file.path(
    project_root,
    "config",
    "frozen-kill-market-shadow-challenger.yml"
  )
)
cat(
  "Modelo-sombra congelado:",
  metadata$model_version,
  "\nMapas de treino:",
  nrow(train),
  "\nCutoff dos resultados:",
  metadata$result_cutoff,
  "\n"
)
