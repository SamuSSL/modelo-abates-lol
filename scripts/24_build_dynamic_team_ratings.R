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
dynamic_config <- evaluation_config$dynamic_team_round
team_metrics <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "team_map_metrics.rds"
))
games <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "canonical_games.rds"
))
structural_maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "structural_map_features.rds"
))

ratings <- build_team_dynamic_ratings(
  team_metrics,
  rating_half_life_days = dynamic_config$rating_half_life_days,
  short_half_life_days =
    dynamic_config$short_momentum_half_life_days,
  long_half_life_days =
    dynamic_config$long_momentum_half_life_days,
  prior_games = dynamic_config$prior_games,
  early_kill_lead = dynamic_config$early_kill_lead_at_15,
  profile_margin =
    dynamic_config$profile_neutral_margin_percent
)
rating_maps <- assemble_map_feature_table(ratings, games)
dynamic_columns <- grep(
  paste0(
    "^(blue|red)_(rating_|momentum_|aggression_|",
    "snowball_|behavior_|effective_snowball)"
  ),
  names(rating_maps),
  value = TRUE
)
enriched <- merge(
  structural_maps,
  rating_maps[c("gameid", dynamic_columns)],
  by = "gameid",
  all.x = TRUE,
  sort = FALSE
)
original_order <- match(
  structural_maps$gameid,
  enriched$gameid
)
enriched <- enriched[original_order, , drop = FALSE]
rownames(enriched) <- NULL
pair_mean <- function(prefix) {
  rowMeans(cbind(
    enriched[[paste0("blue_", prefix)]],
    enriched[[paste0("red_", prefix)]]
  ))
}
pair_difference <- function(prefix) {
  abs(
    enriched[[paste0("blue_", prefix)]] -
      enriched[[paste0("red_", prefix)]]
  )
}
enriched$matchup_attack_league <- pair_mean("rating_attack_league")
enriched$matchup_attack_global <- pair_mean("rating_attack_global")
enriched$matchup_defense_league <- pair_mean("rating_defense_league")
enriched$matchup_defense_global <- pair_mean("rating_defense_global")
enriched$matchup_attack_defense_pressure_league <-
  enriched$matchup_attack_league -
    enriched$matchup_defense_league
enriched$matchup_attack_defense_pressure_global <-
  enriched$matchup_attack_global -
    enriched$matchup_defense_global
enriched$matchup_momentum_attack <- pair_mean("momentum_attack")
enriched$matchup_momentum_mortality <- pair_mean("momentum_mortality")
enriched$matchup_momentum_bloodiness <- pair_mean(
  "momentum_bloodiness"
)
enriched$matchup_aggression_ahead <- pair_mean(
  "aggression_ahead_league"
)
enriched$matchup_aggression_behind <- pair_mean(
  "aggression_behind_league"
)
enriched$matchup_snowball_index <- pair_mean(
  "snowball_index_league"
)
enriched$matchup_snowball_imbalance <- pair_difference(
  "snowball_index_league"
)

saveRDS(
  ratings,
  file.path(
    project_root,
    config$paths$interim,
    "team_dynamic_ratings.rds"
  ),
  version = 3L
)
saveRDS(
  enriched,
  file.path(
    project_root,
    config$paths$interim,
    "dynamic_structural_map_features.rds"
  ),
  version = 3L
)
cat(
  "Team rows:", nrow(ratings),
  "\nMap rows:", nrow(enriched),
  "\nLeakage rows:",
  sum(
    !is.na(ratings$latest_history_datetime) &
      ratings$latest_history_datetime >= ratings$series_cutoff
  ),
  "\n"
)
