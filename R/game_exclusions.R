.bind_quality_rows <- function(first, second) {
  columns <- union(names(first), names(second))
  add_missing <- function(data) {
    missing <- setdiff(columns, names(data))
    for (column in missing) {
      data[[column]] <- rep(NA, nrow(data))
    }
    data[columns]
  }
  result <- rbind(add_missing(first), add_missing(second))
  rownames(result) <- NULL
  result
}

#' Apply exact audited game exclusions
#'
#' @param games Canonical game records before series derivation.
#' @param quality_events Existing quality-event table.
#' @param exclusions Audited exclusions with exact game IDs and reasons.
#' @return Filtered games, augmented events, and excluded-game audit rows.
#' @export
apply_game_exclusions <- function(games, quality_events, exclusions) {
  required <- c("gameid", "reason_code", "rationale", "reviewed_at")
  missing <- setdiff(required, names(exclusions))
  if (length(missing) > 0L) {
    stop(
      "Missing exclusion columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (nrow(exclusions) == 0L) {
    return(list(
      games = games,
      quality_events = quality_events,
      excluded_games = games[FALSE, , drop = FALSE]
    ))
  }
  if (anyDuplicated(exclusions$gameid)) {
    stop("Exclusion game IDs must be unique.", call. = FALSE)
  }
  absent <- setdiff(as.character(exclusions$gameid), as.character(games$gameid))
  if (length(absent) > 0L) {
    stop(
      "Excluded game IDs not found: ",
      paste(absent, collapse = ", "),
      call. = FALSE
    )
  }

  excluded <- as.character(games$gameid) %in%
    as.character(exclusions$gameid)
  excluded_games <- merge(
    games[excluded, , drop = FALSE],
    exclusions,
    by = "gameid",
    all.x = TRUE,
    sort = FALSE
  )
  events <- data.frame(
    gameid = as.character(exclusions$gameid),
    code = as.character(exclusions$reason_code),
    severity = "excluded",
    rationale = as.character(exclusions$rationale),
    reviewed_at = as.character(exclusions$reviewed_at),
    stringsAsFactors = FALSE
  )
  if ("source_file" %in% names(excluded_games)) {
    events$source_file <- excluded_games$source_file[
      match(events$gameid, excluded_games$gameid)
    ]
  }
  if ("source_season" %in% names(excluded_games)) {
    events$source_season <- excluded_games$source_season[
      match(events$gameid, excluded_games$gameid)
    ]
  }

  list(
    games = games[!excluded, , drop = FALSE],
    quality_events = .bind_quality_rows(quality_events, events),
    excluded_games = excluded_games
  )
}
