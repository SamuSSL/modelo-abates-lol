#' Build validated total-kills targets
#'
#' @param rows Oracle's Elixir player and team rows.
#' @return One row per game with team kills and total kills.
#' @export
build_game_targets <- function(rows) {
  required <- c(
    "gameid",
    "participantid",
    "side",
    "position",
    "kills",
    "deaths",
    "teamkills",
    "teamdeaths"
  )
  missing <- setdiff(required, names(rows))
  if (length(missing) > 0L) {
    stop(
      "Missing target columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (nrow(rows) == 0L || anyNA(rows$gameid) || any(rows$gameid == "")) {
    stop("Target rows require a non-empty gameid.", call. = FALSE)
  }

  game_ids <- unique(as.character(rows$gameid))
  targets <- lapply(game_ids, function(game_id) {
    game_rows <- rows[as.character(rows$gameid) == game_id, , drop = FALSE]
    team_rows <- game_rows[
      tolower(as.character(game_rows$position)) == "team",
      ,
      drop = FALSE
    ]

    if (nrow(team_rows) != 2L) {
      stop(
        "Game ",
        game_id,
        " must contain exactly two team rows.",
        call. = FALSE
      )
    }
    if (!setequal(as.character(team_rows$side), c("Blue", "Red"))) {
      stop(
        "Game ",
        game_id,
        " must contain one Blue and one Red team row.",
        call. = FALSE
      )
    }

    player_rows <- game_rows[
      tolower(as.character(game_rows$position)) != "team",
      ,
      drop = FALSE
    ]
    if (nrow(player_rows) != 10L) {
      stop(
        "Game ",
        game_id,
        " must contain exactly ten player rows.",
        call. = FALSE
      )
    }

    team_kills <- suppressWarnings(as.integer(team_rows$teamkills))
    player_kills <- suppressWarnings(as.integer(player_rows$kills))
    player_deaths <- suppressWarnings(as.integer(player_rows$deaths))
    if (
      anyNA(team_kills) ||
      anyNA(player_kills) ||
      anyNA(player_deaths) ||
      any(c(team_kills, player_kills, player_deaths) < 0L)
    ) {
      stop(
        "Game ",
        game_id,
        " contains invalid kills or deaths.",
        call. = FALSE
      )
    }

    sides <- c("Blue", "Red")
    for (side in sides) {
      declared <- team_kills[as.character(team_rows$side) == side]
      observed <- sum(
        player_kills[as.character(player_rows$side) == side]
      )
      if (length(declared) != 1L || observed != declared) {
        stop(
          "Player kills do not match team kills for ",
          side,
          " in game ",
          game_id,
          ".",
          call. = FALSE
        )
      }
    }

    total_kills <- sum(team_kills)
    if (sum(player_deaths) != total_kills) {
      stop(
        "Player deaths do not match total team kills in game ",
        game_id,
        ".",
        call. = FALSE
      )
    }

    data.frame(
      gameid = game_id,
      blue_kills = team_kills[as.character(team_rows$side) == "Blue"],
      red_kills = team_kills[as.character(team_rows$side) == "Red"],
      total_kills_game = total_kills,
      stringsAsFactors = FALSE
    )
  })

  result <- do.call(rbind, targets)
  rownames(result) <- NULL
  result
}

