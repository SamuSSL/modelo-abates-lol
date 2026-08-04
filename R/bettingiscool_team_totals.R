#' Validate the BettingIsCool team-total contract
#'
#' Standard team totals use `home_totals` or `away_totals`, with
#' `odds1/todds1 = Over` and `odds2/todds2 = Under`.
#'
#' @param odds Odds rows from a standard-market endpoint.
#' @param fixture Optional one-row Kills fixture used to bind team orientation.
#' @return `TRUE` invisibly when the contract is valid.
#' @export
validate_bettingiscool_team_totals_contract <- function(
  odds,
  fixture = NULL
) {
  odds <- .bettingiscool_as_data_frame(odds)
  required <- c(
    "event_id",
    "period",
    "market",
    "line",
    "odds1",
    "odds2",
    "todds1",
    "todds2"
  )
  missing <- setdiff(required, names(odds))
  if (length(missing) > 0L) {
    stop(
      "Team-total response is missing required fields: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (nrow(odds) == 0L) {
    stop("Empty team-total odds do not confirm the contract.", call. = FALSE)
  }
  markets <- tolower(as.character(odds$market))
  if (any(!markets %in% c("home_totals", "away_totals"))) {
    stop(
      "Team-total contract accepts only home_totals or away_totals.",
      call. = FALSE
    )
  }
  periods <- suppressWarnings(as.integer(odds$period))
  if (anyNA(periods) || any(periods < 1L)) {
    stop("Team-total period must identify a positive map.", call. = FALSE)
  }
  lines <- suppressWarnings(as.numeric(odds$line))
  if (any(!is.finite(lines)) || any(lines < 0)) {
    stop("Team-total lines must be finite and non-negative.", call. = FALSE)
  }
  decimal_columns <- c("odds1", "odds2", "todds1", "todds2")
  valid_decimal <- vapply(decimal_columns, function(column) {
    values <- suppressWarnings(as.numeric(odds[[column]]))
    all(is.finite(values) & values > 1)
  }, logical(1L))
  if (!all(valid_decimal)) {
    stop("Team-total odds and true odds must exceed 1.", call. = FALSE)
  }
  if (!is.null(fixture)) {
    fixture <- .bettingiscool_as_data_frame(fixture)
    fixture_required <- c(
      "event_id",
      "runner_home",
      "runner_away",
      "resulting_unit"
    )
    valid_fixture <- nrow(fixture) == 1L &&
      all(fixture_required %in% names(fixture)) &&
      tolower(as.character(fixture$resulting_unit[[1L]])) == "kills" &&
      all(
        as.character(odds$event_id) ==
          as.character(fixture$event_id[[1L]])
      )
    if (!valid_fixture) {
      stop(
        "Team-total orientation requires its matching Kills fixture.",
        call. = FALSE
      )
    }
  }
  invisible(TRUE)
}

#' Normalize BettingIsCool map team totals
#'
#' @param odds Raw team-total rows.
#' @param retrieved_at Retrieval timestamp.
#' @param snapshot_type `history`, `opening`, or `closing`.
#' @param fixture Optional one-row Kills fixture used for team names.
#' @return Normalized team-total snapshots.
#' @export
normalize_bettingiscool_team_totals_odds <- function(
  odds,
  retrieved_at,
  snapshot_type = "history",
  fixture = NULL
) {
  odds <- .bettingiscool_as_data_frame(odds)
  validate_bettingiscool_team_totals_contract(odds, fixture)
  odds <- .bettingiscool_add_missing(
    odds,
    c(
      "line_id",
      "alt_line_id",
      "timestamp",
      "cutoff",
      "status",
      "max_win"
    )
  )
  markets <- tolower(as.character(odds$market))
  team_side <- ifelse(markets == "home_totals", "home", "away")
  team_name <- rep(NA_character_, nrow(odds))
  if (!is.null(fixture)) {
    fixture <- .bettingiscool_as_data_frame(fixture)
    home_name <- sub(
      "\\s*\\(Kills\\)\\s*$",
      "",
      as.character(fixture$runner_home[[1L]]),
      ignore.case = TRUE
    )
    away_name <- sub(
      "\\s*\\(Kills\\)\\s*$",
      "",
      as.character(fixture$runner_away[[1L]]),
      ignore.case = TRUE
    )
    team_name <- ifelse(team_side == "home", home_name, away_name)
  }
  result <- data.frame(
    provider = rep("bettingiscool", nrow(odds)),
    event_id = as.character(odds$event_id),
    period = suppressWarnings(as.integer(odds$period)),
    market = markets,
    team_side = team_side,
    team_name = team_name,
    line = suppressWarnings(as.numeric(odds$line)),
    line_id = as.character(odds$line_id),
    alt_line_id = as.character(odds$alt_line_id),
    odds_over = suppressWarnings(as.numeric(odds$odds1)),
    odds_under = suppressWarnings(as.numeric(odds$odds2)),
    true_odds_over = suppressWarnings(as.numeric(odds$todds1)),
    true_odds_under = suppressWarnings(as.numeric(odds$todds2)),
    odds_timestamp = .bettingiscool_utc(odds$timestamp),
    market_cutoff = .bettingiscool_utc(odds$cutoff),
    market_status = suppressWarnings(as.integer(odds$status)),
    max_win = suppressWarnings(as.numeric(odds$max_win)),
    snapshot_type = rep(as.character(snapshot_type), nrow(odds)),
    retrieved_at = rep(.bettingiscool_utc(retrieved_at), nrow(odds)),
    stringsAsFactors = FALSE
  )
  result$team_total_snapshot_id <- .bettingiscool_hash_rows(
    result,
    c(
      "provider",
      "event_id",
      "period",
      "market",
      "line",
      "line_id",
      "alt_line_id",
      "odds_timestamp",
      "snapshot_type"
    )
  )
  result[c(
    "team_total_snapshot_id",
    setdiff(names(result), "team_total_snapshot_id")
  )]
}

#' Select the last open team total 15 to 30 minutes before map close
#'
#' @param snapshots Historical team-total snapshots.
#' @param minimum_minutes Minimum lead before period-specific close.
#' @param maximum_minutes Maximum accepted lead before close.
#' @return One leakage-safe snapshot per event, period, and team market.
#' @export
select_bettingiscool_team_total_snapshots <- function(
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
    stop("Team-total snapshot interval is invalid.", call. = FALSE)
  }
  required <- c(
    "event_id",
    "period",
    "market",
    "odds_timestamp",
    "market_status"
  )
  if (!all(required %in% names(snapshots))) {
    stop("Team-total snapshots are missing selection fields.", call. = FALSE)
  }
  data <- snapshots
  data$odds_timestamp <- .bettingiscool_utc(data$odds_timestamp)
  if ("market_cutoff" %in% names(data)) {
    data$market_cutoff <- .bettingiscool_utc(data$market_cutoff)
  }
  groups <- split(
    seq_len(nrow(data)),
    paste(data$event_id, data$period, data$market, sep = "|")
  )
  selected <- lapply(groups, function(index) {
    rows <- data[index, , drop = FALSE]
    valid_time <- !is.na(rows$odds_timestamp)
    rows <- rows[valid_time, , drop = FALSE]
    if (nrow(rows) == 0L) {
      return(NULL)
    }
    close_time <- max(rows$odds_timestamp)
    lead <- as.numeric(difftime(
      close_time,
      rows$odds_timestamp,
      units = "mins"
    ))
    eligible <- is.finite(lead) &
      lead >= minimum_minutes &
      lead <= maximum_minutes &
      (is.na(rows$market_status) | rows$market_status == 1L)
    eligible_rows <- rows[eligible, , drop = FALSE]
    eligible_lead <- lead[eligible]
    if (nrow(eligible_rows) == 0L) {
      return(NULL)
    }
    selected_index <- which.max(eligible_rows$odds_timestamp)
    row <- eligible_rows[selected_index, , drop = FALSE]
    explicit_cutoff <- if ("market_cutoff" %in% names(rows)) {
      rows$market_cutoff[!is.na(rows$market_cutoff)]
    } else {
      as.POSIXct(character(), tz = "UTC")
    }
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
    row$snapshot_minutes_before_close <- eligible_lead[[selected_index]]
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

#' Derive no-vig team-total probabilities
#'
#' @param data Normalized team-total rows.
#' @return Input rows with normalized Over and Under probabilities.
#' @export
derive_team_total_probabilities <- function(data) {
  required <- c("true_odds_over", "true_odds_under")
  if (!all(required %in% names(data))) {
    stop("Team-total data are missing true odds.", call. = FALSE)
  }
  over_raw <- 1 / suppressWarnings(as.numeric(data$true_odds_over))
  under_raw <- 1 / suppressWarnings(as.numeric(data$true_odds_under))
  normalizer <- over_raw + under_raw
  if (any(!is.finite(normalizer)) || any(normalizer <= 0)) {
    stop("Team-total true odds are invalid.", call. = FALSE)
  }
  result <- data
  result$p_over <- over_raw / normalizer
  result$p_under <- under_raw / normalizer
  result
}

#' Select one opening or closing team-total line
#'
#' The opening and closing endpoints can return one row for every line that
#' was main during the market lifetime. Selection is therefore timestamp based.
#'
#' @param snapshots Normalized opening or closing rows.
#' @param snapshot_type `opening` selects the earliest row; `closing` the latest.
#' @return One row per event, period, and team market.
#' @export
select_bettingiscool_team_total_endpoint_rows <- function(
  snapshots,
  snapshot_type = c("closing", "opening")
) {
  snapshot_type <- match.arg(snapshot_type)
  required <- c("event_id", "period", "market", "odds_timestamp")
  if (!all(required %in% names(snapshots))) {
    stop("Team-total endpoint rows are missing selection fields.", call. = FALSE)
  }
  data <- snapshots
  data$odds_timestamp <- .bettingiscool_utc(data$odds_timestamp)
  groups <- split(
    seq_len(nrow(data)),
    paste(data$event_id, data$period, data$market, sep = "|")
  )
  selected <- lapply(groups, function(index) {
    rows <- data[index, , drop = FALSE]
    valid <- !is.na(rows$odds_timestamp)
    rows <- rows[valid, , drop = FALSE]
    if (nrow(rows) == 0L) {
      return(NULL)
    }
    target <- if (snapshot_type == "closing") {
      max(rows$odds_timestamp)
    } else {
      min(rows$odds_timestamp)
    }
    candidates <- rows[
      rows$odds_timestamp == target,
      ,
      drop = FALSE
    ]
    if (nrow(candidates) > 1L) {
      over <- 1 / suppressWarnings(as.numeric(candidates$true_odds_over))
      under <- 1 / suppressWarnings(as.numeric(candidates$true_odds_under))
      balance <- abs(over / (over + under) - 0.5)
      candidates <- candidates[which.min(balance), , drop = FALSE]
    }
    candidates[1L, , drop = FALSE]
  })
  selected <- selected[!vapply(selected, is.null, logical(1L))]
  if (length(selected) == 0L) {
    return(data[FALSE, , drop = FALSE])
  }
  result <- do.call(rbind, selected)
  rownames(result) <- NULL
  result
}
