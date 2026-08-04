.team_numeric <- function(row, column) {
  suppressWarnings(as.numeric(row[[column]][[1L]]))
}

.team_character <- function(row, column) {
  value <- as.character(row[[column]][[1L]])
  if (is.na(value) || !nzchar(value)) {
    NA_character_
  } else {
    value
  }
}

.summarize_team_metric_game <- function(game_rows) {
  team_rows <- game_rows[
    tolower(as.character(game_rows$position)) == "team",
    ,
    drop = FALSE
  ]
  if (
    nrow(team_rows) != 2L ||
    !setequal(as.character(team_rows$side), c("Blue", "Red"))
  ) {
    stop(
      "Each game must contain exactly two team rows with Blue and Red sides.",
      call. = FALSE
    )
  }
  duration_minutes <- .team_numeric(team_rows, "gamelength") / 60
  if (!is.finite(duration_minutes) || duration_minutes <= 0) {
    stop("Game duration must be positive.", call. = FALSE)
  }

  rows <- lapply(seq_len(2L), function(index) {
    team <- team_rows[index, , drop = FALSE]
    opponent <- team_rows[-index, , drop = FALSE]
    team_kills <- .team_numeric(team, "teamkills")
    team_deaths <- .team_numeric(team, "teamdeaths")
    opponent_kills <- .team_numeric(opponent, "teamkills")
    assists <- .team_numeric(team, "assists")
    damage_to_champions <- .team_numeric(team, "damagetochampions")
    kills_at_15 <- .team_numeric(team, "killsat15")
    deaths_at_15 <- .team_numeric(team, "deathsat15")
    league_raw <- .team_character(team, "league")
    league_canonical <- canonicalize_league(league_raw)
    if (is.na(league_canonical)) {
      league_canonical <- league_raw
    }
    data.frame(
      gameid = .team_character(team, "gameid"),
      game_datetime = as.POSIXct(
        .team_character(team, "date"),
        tz = "UTC"
      ),
      source_season = as.integer(.team_numeric(team, "year")),
      league_raw = league_raw,
      league_canonical = league_canonical,
      competition_role = classify_competition_role(league_raw),
      split = .team_character(team, "split"),
      playoffs = as.integer(.team_numeric(team, "playoffs")),
      patch = .team_character(team, "patch"),
      map_number = as.integer(.team_numeric(team, "game")),
      side = .team_character(team, "side"),
      team_id = .team_character(team, "teamid"),
      team_name = .team_character(team, "teamname"),
      opponent_id = .team_character(opponent, "teamid"),
      opponent_name = .team_character(opponent, "teamname"),
      result = as.integer(.team_numeric(team, "result")),
      game_length_minutes = duration_minutes,
      team_kills = team_kills,
      reported_team_deaths = team_deaths,
      opponent_kills = opponent_kills,
      neutral_deaths = team_deaths - opponent_kills,
      team_deaths = opponent_kills,
      total_kills_game = team_kills + opponent_kills,
      kills_per_minute = team_kills / duration_minutes,
      deaths_per_minute = opponent_kills / duration_minutes,
      combined_kills_per_minute =
        (team_kills + opponent_kills) / duration_minutes,
      assists = assists,
      assists_per_kill = if (team_kills > 0) {
        assists / team_kills
      } else {
        NA_real_
      },
      first_blood = .team_numeric(team, "firstblood"),
      dragons = .team_numeric(team, "dragons"),
      barons = .team_numeric(team, "barons"),
      heralds = .team_numeric(team, "heralds"),
      towers = .team_numeric(team, "towers"),
      damage_to_champions = damage_to_champions,
      kills_per_1000_damage = if (damage_to_champions > 0) {
        team_kills / (damage_to_champions / 1000)
      } else {
        NA_real_
      },
      damage_per_minute = .team_numeric(team, "dpm"),
      damage_taken_per_minute = .team_numeric(
        team,
        "damagetakenperminute"
      ),
      kills_at_10 = .team_numeric(team, "killsat10"),
      deaths_at_10 = .team_numeric(team, "deathsat10"),
      kills_at_15 = kills_at_15,
      deaths_at_15 = deaths_at_15,
      combined_kills_at_15 = kills_at_15 + deaths_at_15,
      gold_diff_at_15 = .team_numeric(team, "golddiffat15"),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

#' Build team-map metrics for stability research
#'
#' @param rows Oracle's Elixir rows.
#' @return Two team-level rows per included game.
#' @export
build_team_map_metrics <- function(rows) {
  missing <- setdiff(team_metric_oe_columns(), names(rows))
  if (length(missing) > 0L) {
    stop(
      "Missing team metric columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  roles <- classify_competition_role(as.character(rows$league))
  rows <- rows[roles != "excluded", , drop = FALSE]
  if (nrow(rows) == 0L) {
    return(data.frame())
  }
  game_ids <- unique(as.character(rows$gameid))
  groups <- split(
    seq_len(nrow(rows)),
    factor(as.character(rows$gameid), levels = game_ids)
  )
  result <- do.call(
    rbind,
    lapply(groups, function(index) {
      .summarize_team_metric_game(rows[index, , drop = FALSE])
    })
  )
  rownames(result) <- NULL
  result
}
