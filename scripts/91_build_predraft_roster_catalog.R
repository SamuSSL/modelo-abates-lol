#!/usr/bin/env Rscript

input_path <- "data/interim/player_map_metrics.rds"
output_path <- "app_data/roster_catalog.json"

if (!file.exists(input_path)) {
  stop("Arquivo de jogadores nao encontrado: ", input_path)
}

players <- readRDS(input_path)
required <- c(
  "gameid", "game_datetime", "league_canonical", "team_id", "team_name",
  "player_id", "player_name", "position"
)
missing <- setdiff(required, names(players))
if (length(missing) > 0) {
  stop("Colunas ausentes: ", paste(missing, collapse = ", "))
}

players <- players[stats::complete.cases(players[, required]), required]
players$game_datetime <- as.POSIXct(players$game_datetime, tz = "UTC")
players <- players[order(players$game_datetime, players$gameid), ]

game_team_key <- paste(players$gameid, players$team_id, sep = "|")
game_groups <- split(seq_len(nrow(players)), game_team_key)
game_rosters <- lapply(game_groups, function(index) {
  rows <- players[index, ]
  identities <- sort(unique(as.character(rows$player_id)))
  if (length(identities) != 5) {
    return(NULL)
  }
  data.frame(
    gameid = as.character(rows$gameid[[1]]),
    game_datetime = max(rows$game_datetime),
    league_canonical = as.character(rows$league_canonical[[1]]),
    team_id = as.character(rows$team_id[[1]]),
    team_name = as.character(rows$team_name[[1]]),
    signature = substr(
      digest::digest(paste(identities, collapse = "|"), algo = "sha256", serialize = FALSE),
      1,
      20
    ),
    roster = I(list(identities)),
    stringsAsFactors = FALSE
  )
})
game_rosters <- do.call(rbind, Filter(Negate(is.null), game_rosters))

signature_groups <- split(seq_len(nrow(game_rosters)), game_rosters$signature)
roster_signatures <- lapply(signature_groups, function(index) {
  rows <- game_rosters[index, ]
  list(
    maps = length(unique(rows$gameid)),
    first_seen = format(min(rows$game_datetime), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    last_seen = format(max(rows$game_datetime), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    player_ids = unname(rows$roster[[which.max(rows$game_datetime)]])
  )
})

team_groups <- split(seq_len(nrow(game_rosters)), game_rosters$team_id)
teams <- lapply(team_groups, function(index) {
  team_games <- game_rosters[index, ]
  latest_index <- index[[which.max(game_rosters$game_datetime[index])]]
  latest_game <- game_rosters[latest_index, ]
  recent_game_ids <- tail(unique(team_games$gameid[order(team_games$game_datetime)]), 10)
  candidates <- players[
    players$team_id == latest_game$team_id & players$gameid %in% recent_game_ids,
  ]
  candidates <- candidates[order(candidates$game_datetime, decreasing = TRUE), ]
  candidates <- candidates[!duplicated(candidates$player_id), ]
  player_rows <- lapply(seq_len(nrow(candidates)), function(row_index) {
    row <- candidates[row_index, ]
    list(
      player_id = as.character(row$player_id),
      player_name = as.character(row$player_name),
      position = as.character(row$position),
      last_seen = format(row$game_datetime, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    )
  })
  list(
    team_id = as.character(latest_game$team_id),
    team_name = as.character(latest_game$team_name),
    league = as.character(latest_game$league_canonical),
    latest_roster = unname(latest_game$roster[[1]]),
    latest_signature = as.character(latest_game$signature),
    latest_game_datetime = format(latest_game$game_datetime, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    players = unname(player_rows)
  )
})

catalog <- list(
  metadata = list(
    generated_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    data_cutoff = format(max(players$game_datetime), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    source = input_path,
    player_map_rows = nrow(players),
    valid_team_maps = nrow(game_rosters)
  ),
  teams = teams,
  roster_signatures = roster_signatures
)

dir.create(dirname(output_path), recursive = TRUE, showWarnings = FALSE)
jsonlite::write_json(catalog, output_path, auto_unbox = TRUE, pretty = TRUE, null = "null")
message("Catalogo salvo em ", output_path)
