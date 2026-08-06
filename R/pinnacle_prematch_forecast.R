.validate_forecast_quote <- function(line, odds_over, odds_under) {
  values <- as.numeric(c(line, odds_over, odds_under))
  if (
    any(!is.finite(values)) ||
      line < 0.5 ||
      abs(line %% 1 - 0.5) > 1e-12 ||
      odds_over <= 1 ||
      odds_under <= 1
  ) {
    stop("Forecast quote contains an invalid line or odds.", call. = FALSE)
  }
  invisible(TRUE)
}

#' Convert a two-sided total market to a no-vig implied mean
#'
#' @param line Total-kills line ending in `.5`.
#' @param odds_over Decimal Over price.
#' @param odds_under Decimal Under price.
#' @param theta Negative-Binomial size.
#' @return A named list with normalized probabilities, overround, and mean.
#' @export
derive_total_market_implied_mean <- function(
  line,
  odds_over,
  odds_under,
  theta
) {
  .validate_forecast_quote(line, odds_over, odds_under)
  theta <- as.numeric(theta)
  if (length(theta) != 1L || !is.finite(theta) || theta <= 0) {
    stop("Forecast inversion requires a positive theta.", call. = FALSE)
  }
  raw_over <- 1 / as.numeric(odds_over)
  raw_under <- 1 / as.numeric(odds_under)
  total <- raw_over + raw_under
  probability_over <- raw_over / total
  list(
    probability_over = probability_over,
    probability_under = raw_under / total,
    overround = total - 1,
    implied_mean = invert_market_count_mean(
      line,
      probability_over,
      distribution = "negative_binomial",
      theta = theta
    )
  )
}

#' Build point-in-time rows for a final-prematch forecast
#'
#' @param snapshots Market snapshots with quote and target timestamps.
#' @param theta_column Column containing row-specific Negative-Binomial size.
#' @return Validated rows with current and final implied means.
#' @export
build_prematch_forecast_rows <- function(
  snapshots,
  theta_column = "theta"
) {
  required <- c(
    "gameid", "series_id", "snapshot_time", "last_prematch_time",
    "live_open_time", "snapshot_line", "snapshot_odds_over",
    "snapshot_odds_under", "last_line", "last_odds_over",
    "last_odds_under", "timing_id", theta_column
  )
  missing <- setdiff(required, names(snapshots))
  if (length(missing) > 0L) {
    stop(
      "Prematch forecast rows are missing fields: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  result <- as.data.frame(snapshots, stringsAsFactors = FALSE)
  for (field in c("snapshot_time", "last_prematch_time", "live_open_time")) {
    result[[field]] <- as.POSIXct(result[[field]], tz = "UTC")
  }
  valid_order <- !is.na(result$snapshot_time) &
    !is.na(result$last_prematch_time) &
    !is.na(result$live_open_time) &
    result$snapshot_time < result$last_prematch_time &
    result$last_prematch_time < result$live_open_time
  if (any(!valid_order)) {
    stop(
      "Prematch forecast rows violate snapshot < last prematch < live open.",
      call. = FALSE
    )
  }
  theta <- as.numeric(result[[theta_column]])
  current <- lapply(seq_len(nrow(result)), function(index) {
    derive_total_market_implied_mean(
      result$snapshot_line[[index]],
      result$snapshot_odds_over[[index]],
      result$snapshot_odds_under[[index]],
      theta[[index]]
    )
  })
  target <- lapply(seq_len(nrow(result)), function(index) {
    derive_total_market_implied_mean(
      result$last_line[[index]],
      result$last_odds_over[[index]],
      result$last_odds_under[[index]],
      theta[[index]]
    )
  })
  result$snapshot_probability_over <- vapply(
    current,
    `[[`,
    numeric(1L),
    "probability_over"
  )
  result$snapshot_overround <- vapply(
    current,
    `[[`,
    numeric(1L),
    "overround"
  )
  result$snapshot_mu <- vapply(current, `[[`, numeric(1L), "implied_mean")
  result$last_probability_over <- vapply(
    target,
    `[[`,
    numeric(1L),
    "probability_over"
  )
  result$last_mu <- vapply(target, `[[`, numeric(1L), "implied_mean")
  result$delta_mu <- result$last_mu - result$snapshot_mu
  result$lead_minutes <- as.numeric(difftime(
    result$live_open_time,
    result$snapshot_time,
    units = "mins"
  ))
  result
}

.ridge_design <- function(data, formula, terms = NULL, xlevels = NULL) {
  if (is.null(terms)) {
    frame <- stats::model.frame(formula, data, na.action = stats::na.pass)
    terms <- stats::terms(frame)
    xlevels <- stats::.getXlevels(terms, frame)
  } else {
    frame <- stats::model.frame(
      stats::delete.response(terms),
      data,
      xlev = xlevels,
      na.action = stats::na.pass
    )
  }
  design <- stats::model.matrix(
    stats::delete.response(terms),
    frame,
    contrasts.arg = NULL
  )
  list(design = design, terms = terms, xlevels = xlevels)
}

#' Fit a compact ridge model for future Pinnacle movement
#'
#' @param data Training rows containing `delta_mu`.
#' @param formula Formula whose response is `delta_mu`.
#' @param lambda Non-negative ridge penalty. The intercept is not penalized.
#' @return Portable ridge fit.
#' @export
fit_prematch_delta_ridge <- function(data, formula, lambda = 10) {
  if (!"delta_mu" %in% names(data)) {
    stop("delta_mu is required for the ridge forecast.", call. = FALSE)
  }
  lambda <- as.numeric(lambda)
  if (!is.finite(lambda) || lambda < 0) {
    stop("lambda must be non-negative.", call. = FALSE)
  }
  keep <- is.finite(as.numeric(data$delta_mu))
  training <- data[keep, , drop = FALSE]
  design <- .ridge_design(training, formula)
  x <- design$design
  y <- as.numeric(training$delta_mu)
  complete <- stats::complete.cases(x) & is.finite(y)
  x <- x[complete, , drop = FALSE]
  y <- y[complete]
  if (nrow(x) < ncol(x) + 10L) {
    stop("Insufficient complete rows for the ridge forecast.", call. = FALSE)
  }
  penalty <- diag(ncol(x)) * lambda
  intercept <- which(colnames(x) == "(Intercept)")
  if (length(intercept) == 1L) {
    penalty[intercept, intercept] <- 0
  }
  coefficients <- solve(crossprod(x) + penalty, crossprod(x, y))
  names(coefficients) <- colnames(x)
  fitted <- as.numeric(x %*% coefficients)
  residuals <- y - fitted
  residual_intervals <- stats::aggregate(
    residuals,
    list(timing_id = training$timing_id[complete]),
    function(values) stats::quantile(values, c(0.05, 0.95), names = FALSE)
  )
  residual_quantiles <- residual_intervals$x
  if (is.matrix(residual_quantiles)) {
    residual_intervals$lower <- residual_quantiles[, 1L]
    residual_intervals$upper <- residual_quantiles[, 2L]
  } else {
    residual_intervals$lower <- vapply(
      residual_quantiles,
      `[[`,
      numeric(1L),
      1L
    )
    residual_intervals$upper <- vapply(
      residual_quantiles,
      `[[`,
      numeric(1L),
      2L
    )
  }
  residual_intervals$x <- NULL
  structure(list(
    formula = formula,
    terms = design$terms,
    xlevels = design$xlevels,
    coefficients = coefficients,
    lambda = lambda,
    training_rows = nrow(x),
    residual_intervals = residual_intervals
  ), class = "prematch_delta_ridge")
}

#' Predict final-prematch implied means
#'
#' @param model Ridge fit from `fit_prematch_delta_ridge()`.
#' @param new_data Point-in-time feature rows.
#' @return Rows with delta, final mean, and conservative interval forecasts.
#' @export
predict_prematch_delta_ridge <- function(model, new_data) {
  design <- .ridge_design(
    new_data,
    model$formula,
    model$terms,
    model$xlevels
  )$design
  missing_columns <- setdiff(names(model$coefficients), colnames(design))
  for (column in missing_columns) {
    design <- cbind(design, rep(0, nrow(design)))
    colnames(design)[ncol(design)] <- column
  }
  design <- design[, names(model$coefficients), drop = FALSE]
  delta <- as.numeric(design %*% model$coefficients)
  intervals <- merge(
    data.frame(
      row_id = seq_len(nrow(new_data)),
      timing_id = as.character(new_data$timing_id),
      stringsAsFactors = FALSE
    ),
    model$residual_intervals,
    by = "timing_id",
    all.x = TRUE,
    sort = FALSE
  )
  intervals <- intervals[order(intervals$row_id), , drop = FALSE]
  fallback <- stats::quantile(
    unlist(model$residual_intervals[c("lower", "upper")]),
    c(0.05, 0.95),
    na.rm = TRUE,
    names = FALSE
  )
  intervals$lower[!is.finite(intervals$lower)] <- fallback[[1L]]
  intervals$upper[!is.finite(intervals$upper)] <- fallback[[2L]]
  data.frame(
    predicted_delta_mu = delta,
    predicted_last_mu = as.numeric(new_data$snapshot_mu) + delta,
    predicted_last_mu_low = as.numeric(new_data$snapshot_mu) + delta +
      intervals$lower,
    predicted_last_mu_high = as.numeric(new_data$snapshot_mu) + delta +
      intervals$upper,
    stringsAsFactors = FALSE
  )
}

#' Translate a final-mean interval into conservative soft-book value
#'
#' @param mean_low Lower final-prematch mean forecast.
#' @param mean_high Upper final-prematch mean forecast.
#' @param theta Negative-Binomial size.
#' @param line Soft-book line.
#' @param odds_over Decimal Over price.
#' @param odds_under Decimal Under price.
#' @param minimum_ev Minimum conservative EV.
#' @return Conservative probabilities, EVs, and action.
#' @export
evaluate_conservative_soft_value <- function(
  mean_low,
  mean_high,
  theta,
  line,
  odds_over,
  odds_under,
  minimum_ev = 0.05
) {
  .validate_forecast_quote(line, odds_over, odds_under)
  values <- as.numeric(c(mean_low, mean_high, theta, minimum_ev))
  if (
    any(!is.finite(values)) || mean_low <= 0 || mean_high < mean_low ||
      theta <= 0 || minimum_ev < 0
  ) {
    stop("Conservative forecast inputs are invalid.", call. = FALSE)
  }
  over_probability <- stats::pnbinom(
    floor(line),
    size = theta,
    mu = mean_low,
    lower.tail = FALSE
  )
  under_probability <- stats::pnbinom(
    floor(line),
    size = theta,
    mu = mean_high,
    lower.tail = TRUE
  )
  ev_over <- over_probability * odds_over - 1
  ev_under <- under_probability * odds_under - 1
  side <- if (ev_over >= ev_under) "over" else "under"
  best_ev <- max(ev_over, ev_under)
  data.frame(
    conservative_probability_over = over_probability,
    conservative_probability_under = under_probability,
    conservative_ev_over = ev_over,
    conservative_ev_under = ev_under,
    recommended_side = if (best_ev >= minimum_ev) side else NA_character_,
    action = if (best_ev >= minimum_ev) "paper_bet" else "abstain",
    stake = if (best_ev >= minimum_ev) 1 else 0,
    stringsAsFactors = FALSE
  )
}
