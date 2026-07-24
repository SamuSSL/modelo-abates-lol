.player_numeric_column <- function(rows, column) {
  suppressWarnings(as.numeric(rows[[column]]))
}

.player_character_column <- function(rows, column) {
  values <- as.character(rows[[column]])
  values[is.na(values) | !nzchar(values)] <- NA_character_
  values
}

#' Build player-map research metrics
#'
#' @param rows Oracle's Elixir rows.
#' @return One row per player and map for included competitions.
#' @export
build_player_map_metrics <- function(rows) {
  missing <- setdiff(player_metric_oe_columns(), names(rows))
  if (length(missing) > 0L) {
    stop(
      "Missing player metric columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  roles <- classify_competition_role(as.character(rows$league))
  players <- rows[
    roles != "excluded" &
      tolower(as.character(rows$position)) != "team",
    ,
    drop = FALSE
  ]
  if (nrow(players) == 0L) {
    return(data.frame())
  }
  duration_minutes <- .player_numeric_column(
    players,
    "gamelength"
  ) / 60
  if (any(!is.finite(duration_minutes) | duration_minutes <= 0)) {
    stop("Player rows require positive game duration.", call. = FALSE)
  }
  kills <- .player_numeric_column(players, "kills")
  deaths <- .player_numeric_column(players, "deaths")
  assists <- .player_numeric_column(players, "assists")
  team_kills <- .player_numeric_column(players, "teamkills")
  raw_league <- .player_character_column(players, "league")
  canonical_league <- canonicalize_league(raw_league)
  canonical_league[is.na(canonical_league)] <-
    raw_league[is.na(canonical_league)]

  result <- data.frame(
    gameid = .player_character_column(players, "gameid"),
    game_datetime = as.POSIXct(
      .player_character_column(players, "date"),
      tz = "UTC"
    ),
    source_season = as.integer(
      .player_numeric_column(players, "year")
    ),
    league_raw = raw_league,
    league_canonical = canonical_league,
    competition_role = classify_competition_role(raw_league),
    side = .player_character_column(players, "side"),
    position = tolower(
      .player_character_column(players, "position")
    ),
    player_id = .player_character_column(players, "playerid"),
    player_name = .player_character_column(players, "playername"),
    team_id = .player_character_column(players, "teamid"),
    team_name = .player_character_column(players, "teamname"),
    champion = .player_character_column(players, "champion"),
    game_length_minutes = duration_minutes,
    kills = kills,
    deaths = deaths,
    assists = assists,
    team_kills = team_kills,
    kills_per_minute = kills / duration_minutes,
    deaths_per_minute = deaths / duration_minutes,
    assists_per_minute = assists / duration_minutes,
    kills_assists_per_minute =
      (kills + assists) / duration_minutes,
    conflict_involvement_per_minute =
      (kills + assists + deaths) / duration_minutes,
    kill_participation = ifelse(
      is.finite(team_kills) & team_kills > 0,
      (kills + assists) / team_kills,
      NA_real_
    ),
    damage_per_minute = .player_numeric_column(players, "dpm"),
    damage_share = .player_numeric_column(
      players,
      "damageshare"
    ),
    earned_gold_share = .player_numeric_column(
      players,
      "earnedgoldshare"
    ),
    vision_score_per_minute = .player_numeric_column(
      players,
      "visionscore"
    ) / duration_minutes,
    stringsAsFactors = FALSE
  )
  result
}
