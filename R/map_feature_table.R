#' Assemble one modeling row per map from team histories
#'
#' @param team_features Frozen team-level rolling features.
#' @param games Canonical game table.
#' @return Map-level modeling table with Blue and Red feature prefixes.
#' @export
assemble_map_feature_table <- function(team_features, games) {
  required_team <- c("gameid", "side", "team_id", "team_name")
  missing_team <- setdiff(required_team, names(team_features))
  if (length(missing_team) > 0L) {
    stop(
      "Missing team feature columns: ",
      paste(missing_team, collapse = ", "),
      call. = FALSE
    )
  }
  groups <- split(
    as.character(team_features$side),
    as.character(team_features$gameid)
  )
  valid_sides <- vapply(
    groups,
    function(sides) length(sides) == 2L &&
      setequal(sides, c("Blue", "Red")),
    logical(1L)
  )
  if (!all(valid_sides)) {
    stop(
      "Each map feature row requires exactly Blue and Red teams.",
      call. = FALSE
    )
  }
  if (!"gameid" %in% names(games)) {
    stop("Canonical games require gameid.", call. = FALSE)
  }

  feature_columns <- c(
    "team_id",
    "team_name",
    "raw_team_games",
    "latest_history_datetime",
    grep(
      paste0(
        "^(hist_|effective_|league_prior_|global_prior_|",
        "league_peer_prior_|global_peer_prior_|",
        "rating_|momentum_|aggression_|snowball_|behavior_)"
      ),
      names(team_features),
      value = TRUE
    )
  )
  feature_columns <- intersect(feature_columns, names(team_features))
  make_side <- function(side, prefix) {
    data <- team_features[
      as.character(team_features$side) == side,
      c("gameid", feature_columns),
      drop = FALSE
    ]
    names(data)[-1L] <- paste0(prefix, "_", names(data)[-1L])
    data
  }
  blue <- make_side("Blue", "blue")
  red <- make_side("Red", "red")
  features <- merge(blue, red, by = "gameid", sort = FALSE)

  eligible <- rep(TRUE, nrow(games))
  if ("competition_role" %in% names(games)) {
    eligible <- eligible & games$competition_role == "target"
  }
  if ("target_valid" %in% names(games)) {
    eligible <- eligible & games$target_valid
  }
  if ("series_eligible" %in% names(games)) {
    eligible <- eligible & games$series_eligible
  }
  result <- merge(
    games[eligible, , drop = FALSE],
    features,
    by = "gameid",
    all.x = TRUE,
    sort = FALSE
  )
  if (
    anyNA(result$blue_team_id) ||
    anyNA(result$red_team_id)
  ) {
    stop("Canonical target games are missing team features.", call. = FALSE)
  }
  if (
    "blue_latest_history_datetime" %in% names(result) &&
    "series_cutoff" %in% names(result) &&
    any(
      !is.na(result$blue_latest_history_datetime) &
        result$blue_latest_history_datetime >= result$series_cutoff
    )
  ) {
    stop("Blue features contain future information.", call. = FALSE)
  }
  if (
    "red_latest_history_datetime" %in% names(result) &&
    "series_cutoff" %in% names(result) &&
    any(
      !is.na(result$red_latest_history_datetime) &
        result$red_latest_history_datetime >= result$series_cutoff
    )
  ) {
    stop("Red features contain future information.", call. = FALSE)
  }
  result
}
