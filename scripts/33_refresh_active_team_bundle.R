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

bundle <- targets::tar_read(portable_model_bundle)
team_metrics <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "team_map_metrics.rds"
))
history <- team_metrics[
  team_metrics$competition_role == "target",
  ,
  drop = FALSE
]
history <- history[
  order(history$game_datetime, history$gameid),
  ,
  drop = FALSE
]
history_key <- vapply(seq_len(nrow(history)), function(index) {
  .rolling_team_key(
    history$team_id[[index]],
    history$team_name[[index]]
  )
}, character(1L))
latest <- !duplicated(history_key, fromLast = TRUE)
history <- history[latest, , drop = FALSE]
history_key <- history_key[latest]
latest_by_key <- setNames(
  format(
    history$game_datetime,
    tz = "UTC",
    usetz = TRUE
  ),
  history_key
)
latest_name_by_key <- setNames(
  as.character(history$team_name),
  history_key
)

bundle$teams <- lapply(bundle$teams, function(team) {
  last_game <- latest_by_key[team$key]
  latest_name <- latest_name_by_key[team$key]
  team$last_game_datetime <- if (
    is.null(last_game) ||
      is.na(last_game)
  ) {
    NULL
  } else {
    unname(last_game)
  }
  team$latest_team_name <- if (
    is.na(latest_name)
  ) {
    team$team_name
  } else {
    unname(latest_name)
  }
  team
})
output_path <- write_portable_model_bundle(
  bundle,
  file.path(project_root, "app_data", "model_bundle.json")
)
active <- vapply(bundle$teams, function(team) {
  value <- team$last_game_datetime
  !is.null(value) &&
    !is.na(value) &&
    startsWith(as.character(value), "2026-") &&
    identical(team$team_name, team$latest_team_name)
}, logical(1L))
cat(
  output_path,
  "\nEquipes com jogos em 2026:",
  sum(active),
  "\n"
)
