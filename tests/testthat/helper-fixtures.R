make_valid_game_rows <- function(gameid = "GAME_1") {
  positions <- c("top", "jng", "mid", "bot", "sup")
  blue_kills <- c(2L, 3L, 1L, 4L, 0L)
  red_kills <- c(1L, 2L, 2L, 1L, 2L)

  players <- data.frame(
    gameid = rep(gameid, 10L),
    participantid = as.character(seq_len(10L)),
    side = rep(c("Blue", "Red"), each = 5L),
    position = rep(positions, 2L),
    kills = c(blue_kills, red_kills),
    deaths = c(red_kills, blue_kills),
    teamkills = c(rep(sum(blue_kills), 5L), rep(sum(red_kills), 5L)),
    teamdeaths = c(rep(sum(red_kills), 5L), rep(sum(blue_kills), 5L)),
    stringsAsFactors = FALSE
  )

  teams <- data.frame(
    gameid = rep(gameid, 2L),
    participantid = c("100", "200"),
    side = c("Blue", "Red"),
    position = c("team", "team"),
    kills = c(sum(blue_kills), sum(red_kills)),
    deaths = c(sum(red_kills), sum(blue_kills)),
    teamkills = c(sum(blue_kills), sum(red_kills)),
    teamdeaths = c(sum(red_kills), sum(blue_kills)),
    stringsAsFactors = FALSE
  )

  rbind(players, teams)
}

make_canonical_game_rows <- function(
  gameid = "GAME_1",
  league = "LCK",
  date = "2026-01-01 12:00:00",
  map_number = 1L,
  blue_team = "Blue Team",
  red_team = "Red Team",
  blue_team_id = "blue-id",
  red_team_id = "red-id"
) {
  rows <- make_valid_game_rows(gameid)
  rows$datacompleteness <- "complete"
  rows$league <- league
  rows$year <- 2026L
  rows$split <- "Spring"
  rows$playoffs <- 0L
  rows$date <- date
  rows$game <- map_number
  rows$patch <- "26.1"
  rows$playername <- ifelse(
    rows$position == "team",
    NA,
    paste0("Player ", rows$participantid)
  )
  rows$playerid <- ifelse(
    rows$position == "team",
    NA,
    paste0("player-", rows$participantid)
  )
  rows$teamname <- ifelse(rows$side == "Blue", blue_team, red_team)
  rows$teamid <- ifelse(rows$side == "Blue", blue_team_id, red_team_id)
  rows$champion <- ifelse(
    rows$position == "team",
    NA,
    paste0("Champion ", rows$participantid)
  )
  rows$gamelength <- 1800L
  rows[, required_oe_columns()]
}
