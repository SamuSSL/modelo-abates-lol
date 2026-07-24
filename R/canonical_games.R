.first_value <- function(x) {
  if (length(x) == 0L) {
    return(NA)
  }
  x[[1L]]
}

.integer_value <- function(x) {
  suppressWarnings(as.integer(.first_value(x)))
}

.nonempty_value <- function(x) {
  value <- as.character(.first_value(x))
  if (length(value) == 0L || is.na(value) || !nzchar(value)) {
    NA_character_
  } else {
    value
  }
}

.summarize_canonical_game <- function(game_rows) {
  game_id <- as.character(game_rows$gameid[[1L]])
  raw_league <- as.character(game_rows$league[[1L]])
  competition_role <- classify_competition_role(raw_league)
  canonical <- canonicalize_league(raw_league)
  if (is.na(canonical)) {
    canonical <- raw_league
  }

  team_rows <- game_rows[
    tolower(as.character(game_rows$position)) == "team",
    ,
    drop = FALSE
  ]
  player_rows <- game_rows[
    tolower(as.character(game_rows$position)) != "team",
    ,
    drop = FALSE
  ]

  critical <- character()
  warnings <- character()
  if (nrow(team_rows) != 2L) {
    critical <- c(critical, "team_row_count")
  }
  if (
    nrow(team_rows) == 2L &&
    !setequal(as.character(team_rows$side), c("Blue", "Red"))
  ) {
    critical <- c(critical, "side_structure")
  }
  if (nrow(player_rows) != 10L) {
    critical <- c(critical, "player_row_count")
  }

  blue_team <- team_rows[as.character(team_rows$side) == "Blue", , drop = FALSE]
  red_team <- team_rows[as.character(team_rows$side) == "Red", , drop = FALSE]
  blue_kills <- .integer_value(blue_team$teamkills)
  red_kills <- .integer_value(red_team$teamkills)

  if (
    is.na(blue_kills) ||
    is.na(red_kills) ||
    blue_kills < 0L ||
    red_kills < 0L
  ) {
    critical <- c(critical, "missing_or_invalid_teamkills")
  }

  player_kills <- suppressWarnings(as.integer(player_rows$kills))
  if (length(player_kills) != nrow(player_rows) || anyNA(player_kills)) {
    critical <- c(critical, "missing_player_kills")
  } else if (
    !is.na(blue_kills) &&
    !is.na(red_kills) &&
    (
      sum(player_kills[as.character(player_rows$side) == "Blue"]) !=
        blue_kills ||
      sum(player_kills[as.character(player_rows$side) == "Red"]) !=
        red_kills
    )
  ) {
    critical <- c(critical, "player_kills_mismatch")
  }

  player_deaths <- suppressWarnings(as.integer(player_rows$deaths))
  total_kills <- if (
    is.na(blue_kills) || is.na(red_kills)
  ) {
    NA_integer_
  } else {
    blue_kills + red_kills
  }
  if (length(player_deaths) != nrow(player_rows) || anyNA(player_deaths)) {
    warnings <- c(warnings, "player_deaths_missing")
  } else if (!is.na(total_kills) && sum(player_deaths) != total_kills) {
    warnings <- c(warnings, "player_deaths_mismatch")
  }

  reasons <- unique(c(critical, warnings))
  data.frame(
    gameid = game_id,
    league_raw = raw_league,
    league_canonical = canonical,
    competition_role = competition_role,
    datacompleteness = as.character(
      .first_value(game_rows$datacompleteness)
    ),
    game_datetime = as.character(.first_value(game_rows$date)),
    map_number = .integer_value(game_rows$game),
    split = as.character(.first_value(game_rows$split)),
    playoffs = .integer_value(game_rows$playoffs),
    patch = as.character(.first_value(game_rows$patch)),
    game_length_seconds = .integer_value(game_rows$gamelength),
    blue_team_id = .nonempty_value(blue_team$teamid),
    red_team_id = .nonempty_value(red_team$teamid),
    blue_team_name = .nonempty_value(blue_team$teamname),
    red_team_name = .nonempty_value(red_team$teamname),
    blue_kills = blue_kills,
    red_kills = red_kills,
    total_kills_game = total_kills,
    target_valid = length(critical) == 0L,
    quality_reasons = paste(reasons, collapse = ";"),
    stringsAsFactors = FALSE
  )
}

#' Build canonical game records and quality events
#'
#' @param rows Oracle's Elixir rows from one or more files.
#' @return A list with `games` and `quality_events`.
#' @export
build_canonical_games <- function(rows) {
  validate_oe_schema(names(rows))
  if (nrow(rows) == 0L) {
    return(list(games = data.frame(), quality_events = data.frame()))
  }

  roles <- classify_competition_role(as.character(rows$league))
  included <- roles != "excluded"
  rows <- rows[included, , drop = FALSE]
  if (nrow(rows) == 0L) {
    return(list(games = data.frame(), quality_events = data.frame()))
  }

  game_ids <- unique(as.character(rows$gameid))
  row_groups <- split(
    seq_len(nrow(rows)),
    factor(as.character(rows$gameid), levels = game_ids)
  )
  summaries <- lapply(row_groups, function(index) {
    .summarize_canonical_game(rows[index, , drop = FALSE])
  })
  games <- do.call(rbind, summaries)
  rownames(games) <- NULL

  events <- lapply(seq_len(nrow(games)), function(index) {
    reasons <- games$quality_reasons[[index]]
    if (is.na(reasons) || !nzchar(reasons)) {
      return(NULL)
    }
    codes <- strsplit(reasons, ";", fixed = TRUE)[[1L]]
    data.frame(
      gameid = rep(games$gameid[[index]], length(codes)),
      code = codes,
      severity = ifelse(
        codes %in% c("player_deaths_missing", "player_deaths_mismatch"),
        "warning",
        "error"
      ),
      stringsAsFactors = FALSE
    )
  })
  events <- Filter(Negate(is.null), events)
  quality_events <- if (length(events) == 0L) {
    data.frame(
      gameid = character(),
      code = character(),
      severity = character(),
      stringsAsFactors = FALSE
    )
  } else {
    result <- do.call(rbind, events)
    rownames(result) <- NULL
    result
  }

  list(games = games, quality_events = quality_events)
}

#' Derive series identifiers and pre-series cutoffs
#'
#' @param games Canonical game data frame.
#' @return The input rows plus series metadata.
#' @export
derive_series_metadata <- function(games) {
  required <- c(
    "gameid",
    "league_canonical",
    "game_datetime",
    "map_number",
    "blue_team_id",
    "red_team_id",
    "blue_team_name",
    "red_team_name"
  )
  missing <- setdiff(required, names(games))
  if (length(missing) > 0L) {
    stop(
      "Missing series columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (nrow(games) == 0L) {
    games$series_id <- character()
    games$series_cutoff <- as.POSIXct(character(), tz = "UTC")
    games$series_key_quality <- character()
    games$series_eligible <- logical()
    return(games)
  }

  datetimes <- as.POSIXct(
    as.character(games$game_datetime),
    tz = "UTC"
  )
  ids_available <- !is.na(games$blue_team_id) &
    nzchar(games$blue_team_id) &
    !is.na(games$red_team_id) &
    nzchar(games$red_team_id)
  blue_key <- ifelse(
    ids_available,
    as.character(games$blue_team_id),
    as.character(games$blue_team_name)
  )
  red_key <- ifelse(
    ids_available,
    as.character(games$red_team_id),
    as.character(games$red_team_name)
  )
  team_one <- ifelse(blue_key <= red_key, blue_key, red_key)
  team_two <- ifelse(blue_key <= red_key, red_key, blue_key)
  date_key <- format(datetimes, tz = "UTC", format = "%Y-%m-%d")
  base_key <- paste(
    games$league_canonical,
    date_key,
    team_one,
    team_two,
    sep = "|"
  )

  base_levels <- unique(base_key)
  groups <- split(
    seq_len(nrow(games)),
    factor(base_key, levels = base_levels)
  )
  series_id <- rep(NA_character_, nrow(games))
  series_cutoff <- rep(as.POSIXct(NA, tz = "UTC"), nrow(games))
  quality <- rep(NA_character_, nrow(games))
  eligible <- rep(FALSE, nrow(games))

  for (key in names(groups)) {
    base_index <- groups[[key]]
    ordered <- order(
      datetimes[base_index],
      as.character(games$gameid[base_index]),
      na.last = TRUE
    )
    index <- base_index[ordered]
    map_numbers <- suppressWarnings(as.integer(games$map_number[index]))
    missing_key <- anyNA(datetimes[index]) ||
      anyNA(map_numbers) ||
      anyNA(team_one[index]) ||
      anyNA(team_two[index]) ||
      any(!nzchar(team_one[index])) ||
      any(!nzchar(team_two[index]))
    timestamp_map_key <- paste(
      as.character(datetimes[index]),
      map_numbers,
      sep = "|"
    )
    duplicate_observation <- anyDuplicated(timestamp_map_key) > 0L

    if (missing_key || duplicate_observation) {
      series_id[index] <- paste0(
        "series_",
        substr(
          digest::digest(key, algo = "sha256", serialize = FALSE),
          1L,
          20L
        )
      )
      if (!all(is.na(datetimes[index]))) {
        series_cutoff[index] <- min(datetimes[index], na.rm = TRUE)
      }
      quality[index] <- "ambiguous"
      eligible[index] <- FALSE
      next
    }

    restart <- c(
      TRUE,
      map_numbers[-1L] <= map_numbers[-length(map_numbers)]
    )
    segment <- cumsum(restart)
    segment_groups <- split(index, segment)

    for (segment_name in names(segment_groups)) {
      segment_index <- segment_groups[[segment_name]]
      segment_key <- paste(key, segment_name, sep = "|")
      series_id[segment_index] <- paste0(
        "series_",
        substr(
          digest::digest(
            segment_key,
            algo = "sha256",
            serialize = FALSE
          ),
          1L,
          20L
        )
      )
      series_cutoff[segment_index] <- min(datetimes[segment_index])
      quality[segment_index] <- if (all(ids_available[segment_index])) {
        "derived_id"
      } else {
        "derived_name"
      }
      eligible[segment_index] <- TRUE
    }
  }

  games$game_datetime <- datetimes
  games$series_id <- series_id
  games$series_cutoff <- as.POSIXct(
    series_cutoff,
    origin = "1970-01-01",
    tz = "UTC"
  )
  games$series_key_quality <- quality
  games$series_eligible <- eligible
  games
}
