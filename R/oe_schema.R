#' Required Oracle's Elixir columns
#'
#' @return Character vector of canonical source column names.
#' @export
required_oe_columns <- function() {
  c(
    "gameid",
    "datacompleteness",
    "league",
    "year",
    "split",
    "playoffs",
    "date",
    "game",
    "patch",
    "participantid",
    "side",
    "position",
    "playername",
    "playerid",
    "teamname",
    "teamid",
    "champion",
    "gamelength",
    "kills",
    "deaths",
    "teamkills",
    "teamdeaths"
  )
}

#' Oracle's Elixir columns used for team-level research metrics
#'
#' @return Character vector of source column names.
#' @export
team_metric_oe_columns <- function() {
  unique(c(
    required_oe_columns(),
    "result",
    "assists",
    "firstblood",
    "dragons",
    "barons",
    "heralds",
    "towers",
    "damagetochampions",
    "dpm",
    "damagetakenperminute",
    "killsat10",
    "deathsat10",
    "killsat15",
    "deathsat15",
    "golddiffat15"
  ))
}

#' Oracle's Elixir columns used for player-level research metrics
#'
#' @return Character vector of source column names.
#' @export
player_metric_oe_columns <- function() {
  unique(c(
    required_oe_columns(),
    "assists",
    "dpm",
    "damageshare",
    "earnedgoldshare",
    "visionscore"
  ))
}

#' Validate Oracle's Elixir source columns
#'
#' @param columns Character vector of column names.
#' @return `TRUE` invisibly when valid.
#' @export
validate_oe_schema <- function(columns) {
  if (!is.character(columns)) {
    stop("Schema columns must be a character vector.", call. = FALSE)
  }

  missing <- setdiff(required_oe_columns(), columns)
  if (length(missing) > 0L) {
    stop(
      "Missing required Oracle's Elixir columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }

  invisible(TRUE)
}
