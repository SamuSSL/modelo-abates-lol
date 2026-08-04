#' Pair kills fixtures with their Regular fixture
#'
#' @param fixtures Normalized BettingIsCool fixtures.
#' @param aliases Optional versioned team aliases.
#' @param tolerance_minutes Maximum difference between fixture starts.
#' @return Auditable unique event links.
#' @export
match_bettingiscool_regular_events <- function(
  fixtures,
  aliases = list(),
  tolerance_minutes = 5
) {
  required <- c(
    "event_id",
    "league_id",
    "starts",
    "runner_home",
    "runner_away",
    "resulting_unit"
  )
  missing <- setdiff(required, names(fixtures))
  if (length(missing) > 0L) {
    stop("Fixtures are missing Regular-link columns.", call. = FALSE)
  }
  if (!is.finite(tolerance_minutes) || tolerance_minutes < 0) {
    stop("Regular fixture tolerance is invalid.", call. = FALSE)
  }
  aliases <- .bettingiscool_alias_map(aliases)
  data <- fixtures
  data$event_id <- as.character(data$event_id)
  data$starts <- .bettingiscool_utc(data$starts)
  data$home_key <- .bettingiscool_apply_alias(data$runner_home, aliases)
  data$away_key <- .bettingiscool_apply_alias(data$runner_away, aliases)
  data$pair_key <- vapply(seq_len(nrow(data)), function(index) {
    paste(
      sort(c(data$home_key[[index]], data$away_key[[index]])),
      collapse = "|"
    )
  }, character(1L))
  kills <- data[
    tolower(as.character(data$resulting_unit)) == "kills",
    ,
    drop = FALSE
  ]
  regular <- data[
    tolower(as.character(data$resulting_unit)) == "regular",
    ,
    drop = FALSE
  ]
  rows <- lapply(seq_len(nrow(kills)), function(index) {
    event <- kills[index, , drop = FALSE]
    candidates <- regular[
      regular$league_id == event$league_id &
        regular$pair_key == event$pair_key &
        abs(as.numeric(difftime(
          regular$starts,
          event$starts,
          units = "mins"
        ))) <= tolerance_minutes,
      ,
      drop = FALSE
    ]
    if (nrow(candidates) > 0L) {
      distance <- abs(as.numeric(difftime(
        candidates$starts,
        event$starts,
        units = "secs"
      )))
      candidates <- candidates[distance == min(distance), , drop = FALSE]
    }
    status <- if (nrow(candidates) == 1L) {
      "verified"
    } else if (nrow(candidates) == 0L) {
      "unmatched"
    } else {
      "ambiguous"
    }
    regular_event_id <- if (status == "verified") {
      candidates$event_id[[1L]]
    } else {
      NA_character_
    }
    data.frame(
      kills_event_id = event$event_id,
      regular_event_id = regular_event_id,
      league_id = as.integer(event$league_id),
      kills_starts = event$starts,
      regular_starts = if (status == "verified") {
        candidates$starts[[1L]]
      } else {
        as.POSIXct(NA, tz = "UTC")
      },
      runner_home = if (status == "verified") {
        as.character(candidates$runner_home[[1L]])
      } else {
        NA_character_
      },
      runner_away = if (status == "verified") {
        as.character(candidates$runner_away[[1L]])
      } else {
        NA_character_
      },
      link_status = status,
      match_method = if (status == "verified") {
        "exact_league_unordered_teams_nearest_start"
      } else {
        NA_character_
      },
      exclusion_reason = if (status == "unmatched") {
        "no_regular_fixture_within_tolerance"
      } else if (status == "ambiguous") {
        "multiple_regular_fixtures_at_same_distance"
      } else {
        NA_character_
      },
      linked_at = as.POSIXct(Sys.time(), tz = "UTC"),
      stringsAsFactors = FALSE
    )
  })
  if (length(rows) == 0L) {
    return(data.frame())
  }
  result <- do.call(rbind, rows)
  result$event_link_id <- .bettingiscool_hash_rows(
    result,
    c("kills_event_id", "regular_event_id")
  )
  result[c("event_link_id", setdiff(names(result), "event_link_id"))]
}

#' Validate the BettingIsCool map-moneyline contract
#'
#' The standard-market convention is `odds1/todds1 = fixture home` and
#' `odds2/todds2 = fixture away`.
#'
#' @param odds Odds rows from a standard moneyline endpoint.
#' @param fixture Optional one-row Regular fixture used to bind orientation.
#' @return `TRUE` invisibly when the contract is valid.
#' @export
validate_bettingiscool_moneyline_contract <- function(
  odds,
  fixture = NULL
) {
  odds <- .bettingiscool_as_data_frame(odds)
  required <- c(
    "event_id",
    "period",
    "market",
    "odds1",
    "odds2",
    "todds1",
    "todds2"
  )
  missing <- setdiff(required, names(odds))
  if (length(missing) > 0L) {
    stop(
      "Moneyline response is missing required fields: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (nrow(odds) == 0L) {
    stop("Empty moneyline odds do not confirm the contract.", call. = FALSE)
  }
  if (any(tolower(as.character(odds$market)) != "moneyline")) {
    stop("Moneyline contract accepts only market=moneyline.", call. = FALSE)
  }
  periods <- suppressWarnings(as.integer(odds$period))
  if (anyNA(periods) || any(periods < 1L)) {
    stop("Moneyline period must identify a positive map.", call. = FALSE)
  }
  decimal_columns <- c("odds1", "odds2", "todds1", "todds2")
  valid_decimal <- vapply(decimal_columns, function(column) {
    values <- suppressWarnings(as.numeric(odds[[column]]))
    all(is.finite(values) & values > 1)
  }, logical(1L))
  if (!all(valid_decimal)) {
    stop("Moneyline odds and true odds must exceed 1.", call. = FALSE)
  }
  if (!is.null(fixture)) {
    fixture <- .bettingiscool_as_data_frame(fixture)
    fixture_required <- c(
      "event_id",
      "runner_home",
      "runner_away",
      "resulting_unit"
    )
    if (
      nrow(fixture) != 1L ||
        !all(fixture_required %in% names(fixture)) ||
        tolower(as.character(fixture$resulting_unit[[1L]])) != "regular" ||
        any(as.character(odds$event_id) !=
          as.character(fixture$event_id[[1L]]))
    ) {
      stop("Moneyline orientation requires its matching Regular fixture.", call. = FALSE)
    }
  }
  invisible(TRUE)
}

#' Normalize BettingIsCool map moneylines
#'
#' @param odds Raw moneyline rows.
#' @param retrieved_at Retrieval timestamp.
#' @param snapshot_type `history`, `opening`, or `closing`.
#' @param fixture Optional one-row Regular fixture for contract validation.
#' @return Normalized home and away moneyline snapshots.
#' @export
normalize_bettingiscool_moneyline_odds <- function(
  odds,
  retrieved_at,
  snapshot_type = "history",
  fixture = NULL
) {
  odds <- .bettingiscool_as_data_frame(odds)
  validate_bettingiscool_moneyline_contract(odds, fixture)
  odds <- .bettingiscool_add_missing(
    odds,
    c("timestamp", "cutoff", "status", "max_win")
  )
  result <- data.frame(
    provider = rep("bettingiscool", nrow(odds)),
    event_id = as.character(odds$event_id),
    period = suppressWarnings(as.integer(odds$period)),
    market = tolower(as.character(odds$market)),
    odds_home = suppressWarnings(as.numeric(odds$odds1)),
    odds_away = suppressWarnings(as.numeric(odds$odds2)),
    true_odds_home = suppressWarnings(as.numeric(odds$todds1)),
    true_odds_away = suppressWarnings(as.numeric(odds$todds2)),
    odds_timestamp = .bettingiscool_utc(odds$timestamp),
    market_cutoff = .bettingiscool_utc(odds$cutoff),
    market_status = suppressWarnings(as.integer(odds$status)),
    max_win = suppressWarnings(as.numeric(odds$max_win)),
    snapshot_type = rep(as.character(snapshot_type), nrow(odds)),
    retrieved_at = rep(.bettingiscool_utc(retrieved_at), nrow(odds)),
    stringsAsFactors = FALSE
  )
  result$moneyline_snapshot_id <- .bettingiscool_hash_rows(
    result,
    c(
      "provider",
      "event_id",
      "period",
      "odds_timestamp",
      "snapshot_type"
    )
  )
  result[c(
    "moneyline_snapshot_id",
    setdiff(names(result), "moneyline_snapshot_id")
  )]
}

#' Select the last open moneyline 15 to 30 minutes before map close
#'
#' @param snapshots Historical map moneylines.
#' @param minimum_minutes Minimum lead before period-specific close.
#' @param maximum_minutes Maximum accepted lead before close.
#' @return One leakage-safe snapshot per event and period.
#' @export
select_bettingiscool_moneyline_snapshots <- function(
  snapshots,
  minimum_minutes = 15,
  maximum_minutes = 30
) {
  if (
    !is.finite(minimum_minutes) ||
      !is.finite(maximum_minutes) ||
      minimum_minutes < 0 ||
      maximum_minutes < minimum_minutes
  ) {
    stop("Moneyline snapshot interval is invalid.", call. = FALSE)
  }
  required <- c(
    "event_id",
    "period",
    "odds_timestamp",
    "market_status"
  )
  if (!all(required %in% names(snapshots))) {
    stop("Moneyline snapshots are missing selection fields.", call. = FALSE)
  }
  data <- snapshots
  data$odds_timestamp <- .bettingiscool_utc(data$odds_timestamp)
  if ("market_cutoff" %in% names(data)) {
    data$market_cutoff <- .bettingiscool_utc(data$market_cutoff)
  }
  groups <- split(
    seq_len(nrow(data)),
    paste(data$event_id, data$period, sep = "|")
  )
  selected <- lapply(groups, function(index) {
    rows <- data[index, , drop = FALSE]
    explicit_cutoff <- if ("market_cutoff" %in% names(rows)) {
      rows$market_cutoff[!is.na(rows$market_cutoff)]
    } else {
      as.POSIXct(character(), tz = "UTC")
    }
    final_history_timestamp <- max(
      rows$odds_timestamp,
      na.rm = TRUE
    )
    close_time <- final_history_timestamp
    lead <- as.numeric(difftime(
      close_time,
      rows$odds_timestamp,
      units = "mins"
    ))
    eligible <- is.finite(lead) &
      lead >= minimum_minutes &
      lead <= maximum_minutes &
      (is.na(rows$market_status) | rows$market_status == 1L)
    rows <- rows[eligible, , drop = FALSE]
    lead <- lead[eligible]
    if (nrow(rows) == 0L) {
      return(NULL)
    }
    row <- rows[which.max(rows$odds_timestamp), , drop = FALSE]
    row$market_close_time <- close_time
    row$provider_market_cutoff <- if (length(explicit_cutoff) > 0L) {
      max(explicit_cutoff)
    } else {
      as.POSIXct(NA, tz = "UTC")
    }
    row$provider_cutoff_minus_close_minutes <- as.numeric(difftime(
      row$provider_market_cutoff,
      close_time,
      units = "mins"
    ))
    row$market_close_source <- "final_main_history_timestamp"
    row$snapshot_minutes_before_close <- lead[[
      which.max(rows$odds_timestamp)
    ]]
    row
  })
  selected <- selected[!vapply(selected, is.null, logical(1L))]
  if (length(selected) == 0L) {
    return(data[FALSE, , drop = FALSE])
  }
  result <- do.call(rbind, selected)
  rownames(result) <- NULL
  result
}

#' Add no-vig probabilities and favoritism features
#'
#' @param data Rows with true home and away decimal odds.
#' @return Input rows with normalized probabilities and favorite bands.
#' @export
derive_moneyline_favoritism <- function(data) {
  required <- c("true_odds_home", "true_odds_away")
  if (!all(required %in% names(data))) {
    stop("Moneyline data are missing true odds.", call. = FALSE)
  }
  home_raw <- 1 / as.numeric(data$true_odds_home)
  away_raw <- 1 / as.numeric(data$true_odds_away)
  normalizer <- home_raw + away_raw
  if (
    any(!is.finite(normalizer)) ||
      any(normalizer <= 0)
  ) {
    stop("Moneyline true odds are invalid.", call. = FALSE)
  }
  result <- data
  result$p_home <- home_raw / normalizer
  result$p_away <- away_raw / normalizer
  result$favorite_probability <- pmax(result$p_home, result$p_away)
  result$home_log_odds <- stats::qlogis(pmin(
    1 - 1e-8,
    pmax(1e-8, result$p_home)
  ))
  result$favorite_log_odds_difference <- abs(result$home_log_odds)
  result$favorite_band <- cut(
    result$favorite_probability,
    breaks = c(0.5, 0.55, 0.65, 0.75, 0.85, 1),
    include.lowest = TRUE,
    right = FALSE,
    labels = c(
      "balanced",
      "slight_favorite",
      "moderate_favorite",
      "strong_favorite",
      "super_favorite"
    )
  )
  result
}

#' Attach selected moneylines to canonical maps
#'
#' @param maps Map rows containing Blue and Red team names.
#' @param game_market_links Verified kills-event map links.
#' @param regular_event_links Kills-to-Regular fixture links.
#' @param regular_fixtures Regular fixtures with home and away runners.
#' @param selected_moneylines Selected period snapshots.
#' @param aliases Optional versioned team aliases.
#' @return Maps with Blue/Red win probabilities and favoritism.
#' @export
attach_moneyline_to_maps <- function(
  maps,
  game_market_links,
  regular_event_links,
  regular_fixtures,
  selected_moneylines,
  aliases = list()
) {
  map_required <- c("gameid", "blue_team_name", "red_team_name")
  if (!all(map_required %in% names(maps))) {
    stop("Maps are missing Blue and Red team names.", call. = FALSE)
  }
  links <- game_market_links[
    game_market_links$link_status == "verified",
    c("gameid", "event_id", "period"),
    drop = FALSE
  ]
  names(links)[names(links) == "event_id"] <- "kills_event_id"
  event_links <- regular_event_links[
    regular_event_links$link_status == "verified",
    c("kills_event_id", "regular_event_id"),
    drop = FALSE
  ]
  joined <- merge(links, event_links, by = "kills_event_id")
  fixtures <- regular_fixtures[c(
    "event_id",
    "runner_home",
    "runner_away"
  )]
  names(fixtures)[names(fixtures) == "event_id"] <- "regular_event_id"
  joined <- merge(joined, fixtures, by = "regular_event_id")
  moneylines <- derive_moneyline_favoritism(selected_moneylines)
  names(moneylines)[names(moneylines) == "event_id"] <- "regular_event_id"
  joined <- merge(
    joined,
    moneylines,
    by = c("regular_event_id", "period")
  )
  aliases <- .bettingiscool_alias_map(aliases)
  joined <- merge(joined, maps, by = "gameid")
  home_key <- .bettingiscool_apply_alias(joined$runner_home, aliases)
  blue_key <- .bettingiscool_apply_alias(joined$blue_team_name, aliases)
  red_key <- .bettingiscool_apply_alias(joined$red_team_name, aliases)
  valid_orientation <- home_key == blue_key | home_key == red_key
  joined <- joined[valid_orientation, , drop = FALSE]
  home_is_blue <- home_key[valid_orientation] == blue_key[valid_orientation]
  joined$p_blue <- ifelse(
    home_is_blue,
    joined$p_home,
    joined$p_away
  )
  joined$p_red <- 1 - joined$p_blue
  joined$blue_log_odds <- stats::qlogis(pmin(
    1 - 1e-8,
    pmax(1e-8, joined$p_blue)
  ))
  joined$home_is_blue <- home_is_blue
  joined
}

#' Apply sample guardrails to favoritism bands
#'
#' @param data Map rows with league and favorite band.
#' @param minimum_total Minimum maps in the aggregate band.
#' @param minimum_league Minimum maps in the league-band cell.
#' @return Coverage table with an explicit betting eligibility message.
#' @export
summarize_favoritism_coverage <- function(
  data,
  minimum_total = 100L,
  minimum_league = 30L
) {
  required <- c("league_canonical", "favorite_band")
  if (!all(required %in% names(data))) {
    stop("Favoritism data are missing coverage columns.", call. = FALSE)
  }
  aggregate_counts <- table(as.character(data$favorite_band))
  groups <- split(
    seq_len(nrow(data)),
    interaction(
      data$league_canonical,
      data$favorite_band,
      drop = TRUE,
      lex.order = TRUE
    )
  )
  rows <- lapply(groups, function(index) {
    group <- data[index, , drop = FALSE]
    band <- as.character(group$favorite_band[[1L]])
    total_maps <- as.integer(aggregate_counts[[band]])
    league_maps <- nrow(group)
    eligible <- total_maps >= minimum_total &&
      league_maps >= minimum_league
    data.frame(
      league_canonical = as.character(group$league_canonical[[1L]]),
      favorite_band = band,
      aggregate_maps = total_maps,
      league_maps = league_maps,
      eligible = eligible,
      message = if (eligible) {
        "Amostra suficiente para avaliacao."
      } else {
        "Pouca amostra para esta faixa. N\u00e3o apostar"
      },
      stringsAsFactors = FALSE
    )
  })
  if (length(rows) == 0L) {
    return(data.frame())
  }
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}
