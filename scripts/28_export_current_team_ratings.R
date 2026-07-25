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
ratings <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "team_dynamic_ratings.rds"
))
team_key <- vapply(seq_len(nrow(ratings)), function(index) {
  .rolling_team_key(
    ratings$team_id[[index]],
    ratings$team_name[[index]]
  )
}, character(1L))
ordering <- order(
  ratings$series_cutoff,
  ratings$game_datetime,
  ratings$gameid
)
ratings <- ratings[ordering, , drop = FALSE]
team_key <- team_key[ordering]
latest <- !duplicated(team_key, fromLast = TRUE)
snapshot <- ratings[latest, , drop = FALSE]
cutoff <- max(ratings$series_cutoff, na.rm = TRUE)
active <- !is.na(snapshot$latest_history_datetime) &
  snapshot$latest_history_datetime >= cutoff - 180 * 86400
snapshot <- snapshot[active, , drop = FALSE]
columns <- c(
  "league_canonical",
  "team_id",
  "team_name",
  "series_cutoff",
  "latest_history_datetime",
  "raw_team_games",
  "effective_combined_kills_per_minute_games",
  "rating_attack_league",
  "rating_defense_league",
  "rating_attack_global",
  "rating_defense_global",
  "momentum_attack",
  "momentum_mortality",
  "momentum_bloodiness",
  "aggression_ahead_league",
  "behavior_ahead_profile",
  "aggression_behind_league",
  "behavior_behind_profile",
  "effective_snowball_opportunities",
  "snowball_conversion_league",
  "snowball_close_speed_league",
  "snowball_index_league"
)
snapshot <- snapshot[columns]
names(snapshot)[names(snapshot) == "series_cutoff"] <-
  "rating_entering_latest_series"
snapshot <- snapshot[
  order(snapshot$league_canonical, snapshot$team_name),
  ,
  drop = FALSE
]
output_path <- file.path(
  project_root,
  "reports",
  "team-dynamic-ratings-latest.csv"
)
utils::write.csv(
  snapshot,
  output_path,
  row.names = FALSE,
  na = ""
)
cat(
  normalizePath(output_path, winslash = "/", mustWork = TRUE),
  "\nActive teams:", nrow(snapshot),
  "\n"
)
