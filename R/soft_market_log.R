.soft_quote_columns <- function() {
  c(
    "quote_id",
    "quoted_at",
    "bookmaker",
    "gameid",
    "league_canonical",
    "map_number",
    "side",
    "line",
    "decimal_odds",
    "pinnacle_line",
    "pinnacle_decimal_odds",
    "pinnacle_probability_over",
    "p_blue",
    "p_red",
    "favorite_band",
    "model_family",
    "model_version",
    "model_probability",
    "fair_decimal_odds",
    "expected_value",
    "decision",
    "stake",
    "result",
    "profit",
    "settled_at",
    "notes"
  )
}

#' Create the private soft-book quote log
#'
#' @param connection Open DBI connection.
#' @return `TRUE` invisibly.
#' @export
initialize_soft_market_store <- function(connection) {
  DBI::dbExecute(connection, "CREATE TABLE IF NOT EXISTS soft_market_quotes (
    quote_id VARCHAR PRIMARY KEY, quoted_at TIMESTAMP, bookmaker VARCHAR,
    gameid VARCHAR, league_canonical VARCHAR, map_number INTEGER,
    side VARCHAR, line DOUBLE, decimal_odds DOUBLE,
    pinnacle_line DOUBLE, pinnacle_decimal_odds DOUBLE,
    pinnacle_probability_over DOUBLE, p_blue DOUBLE, p_red DOUBLE,
    favorite_band VARCHAR, model_family VARCHAR, model_version VARCHAR,
    model_probability DOUBLE, fair_decimal_odds DOUBLE,
    expected_value DOUBLE, decision VARCHAR, stake DOUBLE,
    result VARCHAR, profit DOUBLE, settled_at TIMESTAMP, notes VARCHAR
  )")
  invisible(TRUE)
}

#' Validate and derive a manual soft-book quote
#'
#' @param quote One-row quote data.
#' @param minimum_ev Minimum expected value required to simulate a bet.
#' @return Normalized quote with fixed one-unit stake.
#' @export
prepare_soft_market_quote <- function(quote, minimum_ev = 0.05) {
  quote <- as.data.frame(quote, stringsAsFactors = FALSE)
  required <- c(
    "quoted_at",
    "bookmaker",
    "gameid",
    "league_canonical",
    "map_number",
    "side",
    "line",
    "decimal_odds",
    "pinnacle_line",
    "pinnacle_decimal_odds",
    "pinnacle_probability_over",
    "p_blue",
    "p_red",
    "favorite_band",
    "model_family",
    "model_version",
    "model_probability"
  )
  missing <- setdiff(required, names(quote))
  if (length(missing) > 0L || nrow(quote) != 1L) {
    stop(
      "Soft quote must be one row with all required fields.",
      call. = FALSE
    )
  }
  quote$quoted_at <- as.POSIXct(quote$quoted_at, tz = "UTC")
  quote$side <- tolower(as.character(quote$side))
  quote$line <- as.numeric(quote$line)
  quote$decimal_odds <- as.numeric(quote$decimal_odds)
  quote$pinnacle_line <- as.numeric(quote$pinnacle_line)
  quote$pinnacle_decimal_odds <- as.numeric(quote$pinnacle_decimal_odds)
  quote$pinnacle_probability_over <- as.numeric(
    quote$pinnacle_probability_over
  )
  quote$p_blue <- as.numeric(quote$p_blue)
  quote$p_red <- as.numeric(quote$p_red)
  quote$model_probability <- as.numeric(quote$model_probability)
  if (
    is.na(quote$quoted_at) ||
      !quote$side %in% c("over", "under") ||
      !is.finite(quote$line) ||
      abs(quote$line %% 1 - 0.5) > 1e-12 ||
      !is.finite(quote$decimal_odds) ||
      quote$decimal_odds <= 1 ||
      !is.finite(quote$pinnacle_decimal_odds) ||
      quote$pinnacle_decimal_odds <= 1 ||
      any(!is.finite(c(
        quote$pinnacle_probability_over,
        quote$p_blue,
        quote$p_red,
        quote$model_probability
      ))) ||
      any(c(
        quote$pinnacle_probability_over,
        quote$p_blue,
        quote$p_red,
        quote$model_probability
      ) <= 0) ||
      any(c(
        quote$pinnacle_probability_over,
        quote$p_blue,
        quote$p_red,
        quote$model_probability
      ) >= 1) ||
      abs(quote$p_blue + quote$p_red - 1) > 1e-6
  ) {
    stop("Soft quote contains invalid odds or probabilities.", call. = FALSE)
  }
  quote$fair_decimal_odds <- 1 / quote$model_probability
  quote$expected_value <- quote$model_probability *
    quote$decimal_odds - 1
  quote$decision <- if (quote$expected_value >= minimum_ev) {
    "bet"
  } else {
    "pass"
  }
  quote$stake <- if (quote$decision == "bet") 1 else 0
  if (!"result" %in% names(quote)) {
    quote$result <- NA_character_
  }
  if (!"profit" %in% names(quote)) {
    quote$profit <- NA_real_
  }
  if (!"settled_at" %in% names(quote)) {
    quote$settled_at <- as.POSIXct(NA, tz = "UTC")
  } else {
    quote$settled_at <- as.POSIXct(quote$settled_at, tz = "UTC")
  }
  if (!"notes" %in% names(quote)) {
    quote$notes <- NA_character_
  }
  quote$quote_id <- digest::digest(
    paste(
      format(quote$quoted_at, tz = "UTC", usetz = TRUE),
      quote$bookmaker,
      quote$gameid,
      quote$map_number,
      quote$side,
      quote$line,
      quote$decimal_odds,
      sep = "|"
    ),
    algo = "sha256",
    serialize = FALSE
  )
  quote <- quote[.soft_quote_columns()]
  quote
}

#' Append a soft-book quote idempotently
#'
#' @param connection Open DBI connection.
#' @param quote Prepared quote or raw one-row quote.
#' @param minimum_ev Minimum expected value for a simulated bet.
#' @return Number of inserted rows.
#' @export
append_soft_market_quote <- function(
  connection,
  quote,
  minimum_ev = 0.05
) {
  initialize_soft_market_store(connection)
  if (!"quote_id" %in% names(quote)) {
    quote <- prepare_soft_market_quote(quote, minimum_ev)
  }
  .bettingiscool_append_unique(
    connection,
    "soft_market_quotes",
    quote,
    "quote_id"
  )
}

#' Assess whether the soft-book evidence gate has passed
#'
#' @param quotes Settled manual quote records.
#' @param confidence Confidence level for the yield interval.
#' @return Evidence counts, yield interval, and gate decision.
#' @export
assess_soft_market_edge <- function(quotes, confidence = 0.95) {
  required <- c(
    "quote_id",
    "league_canonical",
    "decision",
    "stake",
    "profit"
  )
  if (!all(required %in% names(quotes))) {
    stop("Soft quote log is missing edge-assessment fields.", call. = FALSE)
  }
  bets <- quotes[
    quotes$decision == "bet" &
      is.finite(quotes$stake) &
      quotes$stake > 0 &
      is.finite(quotes$profit),
    ,
    drop = FALSE
  ]
  yield <- if (nrow(bets) > 0L) {
    sum(bets$profit) / sum(bets$stake)
  } else {
    NA_real_
  }
  interval <- c(NA_real_, NA_real_)
  if (nrow(bets) >= 2L) {
    per_bet <- bets$profit / bets$stake
    standard_error <- stats::sd(per_bet) / sqrt(nrow(bets))
    critical <- stats::qnorm(1 - (1 - confidence) / 2)
    interval <- yield + c(-1, 1) * critical * standard_error
  }
  quote_count <- length(unique(as.character(quotes$quote_id)))
  bet_count <- nrow(bets)
  league_count <- length(unique(as.character(bets$league_canonical)))
  passed <- quote_count >= 500L &&
    bet_count >= 300L &&
    league_count >= 3L &&
    is.finite(interval[[1L]]) &&
    interval[[1L]] > 0
  data.frame(
    quotes = quote_count,
    settled_bets = bet_count,
    leagues = league_count,
    yield = yield,
    yield_lower_95 = interval[[1L]],
    yield_upper_95 = interval[[2L]],
    gate_passed = passed,
    decision = if (passed) {
      "Vantagem confirmatoria aprovada."
    } else {
      "Evidencia insuficiente. N\u00e3o afirmar vantagem."
    },
    stringsAsFactors = FALSE
  )
}
