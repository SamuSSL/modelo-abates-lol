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
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "kill_market_map_features.rds"
))
maps$season <- format(maps$game_datetime, "%Y", tz = "UTC")
maps$total_kills_per_minute <- maps$total_kills_game /
  maps$game_length_minutes

kill_market_features <- c(
  "pace",
  "attack",
  "defensive_exposure",
  "team_opponent_intensity",
  "matchup_intensity_imbalance",
  "matchup_attack_defense_pressure_league",
  "matchup_attack_defense_pressure_global",
  "matchup_momentum_attack",
  "matchup_momentum_mortality",
  "matchup_momentum_bloodiness",
  "matchup_aggression_ahead",
  "matchup_aggression_behind",
  "matchup_snowball_index",
  "matchup_snowball_imbalance",
  grep(
    paste0(
      "^(kill_intensity_|duration_level_|duration_imbalance_|",
      "duration_trend$|duration_ratio$|early_pace_|post_15_pace_|",
      "damage_pressure_|objective_activity_|assist_activity_|",
      "close_speed_|stall_capacity_|lead_conversion_|early_lead_size_|",
      "close_stall_balance_medium$|draft_)"
    ),
    names(maps),
    value = TRUE
  )
)
kill_market_features <- unique(intersect(
  kill_market_features,
  names(maps)
))

safe_correlation <- function(x, y, method) {
  complete <- is.finite(x) & is.finite(y)
  if (sum(complete) < 30L) {
    return(NA_real_)
  }
  suppressWarnings(stats::cor(x[complete], y[complete], method = method))
}
adjusted_correlation <- function(feature, outcome) {
  complete <- is.finite(feature) &
    is.finite(outcome) &
    !is.na(maps$league_canonical) &
    !is.na(maps$season)
  if (sum(complete) < 30L) {
    return(NA_real_)
  }
  controls <- data.frame(
    league_season = interaction(
      maps$league_canonical[complete],
      maps$season[complete],
      drop = TRUE
    )
  )
  feature_residual <- stats::residuals(stats::lm(
    feature[complete] ~ league_season,
    data = controls
  ))
  outcome_residual <- stats::residuals(stats::lm(
    outcome[complete] ~ league_season,
    data = controls
  ))
  safe_correlation(feature_residual, outcome_residual, "pearson")
}
outcomes <- list(
  total_kills = maps$total_kills_game,
  duration = maps$game_length_minutes,
  kills_per_minute = maps$total_kills_per_minute
)
overall <- do.call(rbind, lapply(kill_market_features, function(feature) {
  values <- as.numeric(maps[[feature]])
  do.call(rbind, lapply(names(outcomes), function(outcome_name) {
    outcome <- outcomes[[outcome_name]]
    data.frame(
      feature = feature,
      outcome = outcome_name,
      maps = sum(is.finite(values) & is.finite(outcome)),
      missing_fraction = mean(!is.finite(values)),
      pearson = safe_correlation(values, outcome, "pearson"),
      spearman = safe_correlation(values, outcome, "spearman"),
      adjusted_league_season = adjusted_correlation(values, outcome),
      stringsAsFactors = FALSE
    )
  }))
}))
overall <- overall[
  order(
    overall$outcome,
    -abs(overall$adjusted_league_season)
  ),
  ,
  drop = FALSE
]

league_rows <- list()
league_index <- 0L
for (league in sort(unique(as.character(maps$league_canonical)))) {
  selected <- as.character(maps$league_canonical) == league
  for (feature in kill_market_features) {
    values <- as.numeric(maps[[feature]][selected])
    outcome <- as.numeric(maps$total_kills_game[selected])
    league_index <- league_index + 1L
    league_rows[[league_index]] <- data.frame(
      league_canonical = league,
      feature = feature,
      maps = sum(is.finite(values) & is.finite(outcome)),
      pearson_total_kills = safe_correlation(
        values,
        outcome,
        "pearson"
      ),
      spearman_total_kills = safe_correlation(
        values,
        outcome,
        "spearman"
      ),
      stringsAsFactors = FALSE
    )
  }
}
by_league <- do.call(rbind, league_rows)

artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  overall,
  file.path(artifact_dir, "kill_market_feature_correlations.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(artifact_dir, "kill_market_feature_correlations_by_league.csv"),
  row.names = FALSE
)
cat("Maiores correlacoes pre-jogo ajustadas com kills totais:\n")
print(
  head(
    overall[
      overall$outcome == "total_kills",
      c(
        "feature",
        "maps",
        "pearson",
        "spearman",
        "adjusted_league_season"
      )
    ],
    20L
  ),
  row.names = FALSE
)
