.clip_probability <- function(probability, epsilon = 1e-6) {
  pmin(1 - epsilon, pmax(epsilon, as.numeric(probability)))
}
.validate_binary_calibration_data <- function(probability, outcome) {
  probability <- .clip_probability(probability)
  outcome <- as.integer(outcome)
  if (
    length(probability) != length(outcome) ||
      length(probability) < 2L ||
      any(!is.finite(probability)) ||
      any(!outcome %in% c(0L, 1L))
  ) {
    stop("Dados invalidos para calibracao binaria.", call. = FALSE)
  }
  list(probability = probability, outcome = outcome)
}

#' Fit a binary probability calibrator
#'
#' @param probability Original probabilities.
#' @param outcome Binary outcomes.
#' @param method Either `platt` or `beta`.
#' @return A fitted probability calibrator.
fit_binary_probability_calibrator <- function(
  probability,
  outcome,
  method = c("platt", "beta")
) {
  method <- match.arg(method)
  data <- .validate_binary_calibration_data(probability, outcome)
  frame <- data.frame(
    outcome = data$outcome,
    logit_probability = stats::qlogis(data$probability),
    log_probability = log(data$probability),
    log_one_minus_probability = log1p(-data$probability)
  )
  formula <- if (method == "platt") {
    outcome ~ logit_probability
  } else {
    outcome ~ log_probability + log_one_minus_probability
  }
  fit <- suppressWarnings(stats::glm(
    formula,
    data = frame,
    family = stats::binomial()
  ))
  structure(
    list(method = method, fit = fit),
    class = "lolkills_binary_probability_calibrator"
  )
}

#' Predict with a binary probability calibrator
#'
#' @param fit Fitted calibrator.
#' @param probability Original probabilities.
#' @return Calibrated probabilities.
predict_binary_probability_calibrator <- function(fit, probability) {
  if (!inherits(fit, "lolkills_binary_probability_calibrator")) {
    stop("Objeto de calibracao binaria invalido.", call. = FALSE)
  }
  probability <- .clip_probability(probability)
  frame <- data.frame(
    logit_probability = stats::qlogis(probability),
    log_probability = log(probability),
    log_one_minus_probability = log1p(-probability)
  )
  .clip_probability(stats::predict(
    fit$fit,
    newdata = frame,
    type = "response"
  ))
}

.market_blend_loss <- function(
  parameters,
  model_probability,
  market_probability,
  outcome,
  include_intercept
) {
  intercept <- if (include_intercept) parameters[[1L]] else 0
  weight <- parameters[[length(parameters)]]
  delta <- stats::qlogis(model_probability) -
    stats::qlogis(market_probability)
  blended <- stats::plogis(
    stats::qlogis(market_probability) + intercept + weight * delta
  )
  blended <- .clip_probability(blended)
  -mean(
    outcome * log(blended) +
      (1 - outcome) * log1p(-blended)
  )
}

#' Fit a market-anchored probability blend
#'
#' @param model_probability Model probabilities.
#' @param market_probability No-vig market probabilities.
#' @param outcome Binary outcomes.
#' @param include_intercept Whether to estimate a market-level intercept.
#' @return A fitted market blend.
fit_market_probability_blend <- function(
  model_probability,
  market_probability,
  outcome,
  include_intercept = FALSE
) {
  model_data <- .validate_binary_calibration_data(
    model_probability,
    outcome
  )
  market_probability <- .clip_probability(market_probability)
  if (
    length(market_probability) != length(model_data$probability) ||
      any(!is.finite(market_probability))
  ) {
    stop("Probabilidades de mercado invalidas.", call. = FALSE)
  }
  initial <- if (include_intercept) c(0, 0.25) else 0.25
  lower <- if (include_intercept) c(-1, 0) else 0
  upper <- if (include_intercept) c(1, 1) else 1
  optimization <- stats::optim(
    initial,
    .market_blend_loss,
    model_probability = model_data$probability,
    market_probability = market_probability,
    outcome = model_data$outcome,
    include_intercept = include_intercept,
    method = "L-BFGS-B",
    lower = lower,
    upper = upper
  )
  parameters <- optimization$par
  structure(
    list(
      include_intercept = include_intercept,
      intercept = if (include_intercept) parameters[[1L]] else 0,
      weight = parameters[[length(parameters)]],
      training_log_loss = optimization$value,
      convergence = optimization$convergence
    ),
    class = "lolkills_market_probability_blend"
  )
}

#' Predict with a market-anchored probability blend
#'
#' @param fit Fitted market blend.
#' @param model_probability Model probabilities.
#' @param market_probability No-vig market probabilities.
#' @return Blended probabilities.
predict_market_probability_blend <- function(
  fit,
  model_probability,
  market_probability
) {
  if (!inherits(fit, "lolkills_market_probability_blend")) {
    stop("Objeto de blend de mercado invalido.", call. = FALSE)
  }
  model_probability <- .clip_probability(model_probability)
  market_probability <- .clip_probability(market_probability)
  delta <- stats::qlogis(model_probability) -
    stats::qlogis(market_probability)
  .clip_probability(stats::plogis(
    stats::qlogis(market_probability) +
      fit$intercept +
      fit$weight * delta
  ))
}

#' Fit an IDR count-distribution calibrator
#'
#' @param prediction_mean Original predicted count means.
#' @param observed Observed counts.
#' @return A fitted IDR model.
fit_idr_count_calibrator <- function(prediction_mean, observed) {
  if (!requireNamespace("isodistrreg", quietly = TRUE)) {
    stop("Package isodistrreg is required.", call. = FALSE)
  }
  prediction_mean <- as.numeric(prediction_mean)
  observed <- as.integer(observed)
  if (
    length(prediction_mean) != length(observed) ||
      length(prediction_mean) < 200L ||
      any(!is.finite(prediction_mean)) ||
      any(!is.finite(observed))
  ) {
    stop("Dados invalidos para calibracao IDR.", call. = FALSE)
  }
  isodistrreg::idr(
    y = observed,
    X = data.frame(prediction_mean = prediction_mean),
    progress = FALSE
  )
}

#' Predict count PMFs from an IDR calibrator
#'
#' @param fit Fitted IDR model.
#' @param prediction_mean Original predicted count means.
#' @param maximum Maximum supported count.
#' @return A list of calibrated PMFs.
predict_idr_count_pmfs <- function(fit, prediction_mean, maximum = 100L) {
  prediction_mean <- as.numeric(prediction_mean)
  prediction <- stats::predict(
    fit,
    data = data.frame(prediction_mean = prediction_mean)
  )
  cdfs <- isodistrreg::cdf(prediction, 0:as.integer(maximum))
  lapply(seq_len(nrow(cdfs)), function(index) {
    pmf <- diff(c(0, as.numeric(cdfs[index, ])))
    pmf[pmf < 0 & pmf > -1e-10] <- 0
    pmf <- pmax(pmf, 0)
    total <- sum(pmf)
    if (!is.finite(total) || total <= 0) {
      stop("IDR produziu uma PMF invalida.", call. = FALSE)
    }
    pmf / total
  })
}

#' Calculate the Over probability from a count PMF
#'
#' @param pmf Count PMF whose first entry represents zero.
#' @param line Half-point total line.
#' @return Probability of finishing above the line.
pmf_probability_over <- function(pmf, line) {
  threshold <- floor(as.numeric(line))
  support <- seq_along(pmf) - 1L
  sum(as.numeric(pmf)[support > threshold])
}

#' Summarize binary probability quality
#'
#' @param probability Predicted probabilities.
#' @param outcome Binary outcomes.
#' @param bins Number of fixed-width calibration bins.
#' @return One-row metric data frame.
summarize_binary_probability_quality <- function(
  probability,
  outcome,
  bins = 10L
) {
  data <- .validate_binary_calibration_data(probability, outcome)
  probability <- data$probability
  outcome <- data$outcome
  log_loss <- -mean(
    outcome * log(probability) +
      (1 - outcome) * log1p(-probability)
  )
  bin <- cut(
    probability,
    breaks = seq(0, 1, length.out = bins + 1L),
    include.lowest = TRUE,
    labels = FALSE
  )
  bin_groups <- split(seq_along(probability), bin)
  expected_calibration_error <- sum(vapply(
    bin_groups,
    function(index) {
      length(index) / length(probability) *
        abs(mean(outcome[index]) - mean(probability[index]))
    },
    numeric(1L)
  ))
  slope_fit <- suppressWarnings(stats::glm(
    outcome ~ stats::qlogis(probability),
    family = stats::binomial()
  ))
  intercept_fit <- suppressWarnings(stats::glm(
    outcome ~ 1 + offset(stats::qlogis(probability)),
    family = stats::binomial()
  ))
  data.frame(
    maps = length(outcome),
    brier = mean((probability - outcome)^2),
    log_loss = log_loss,
    calibration_gap = mean(outcome - probability),
    expected_calibration_error = expected_calibration_error,
    calibration_intercept = unname(stats::coef(intercept_fit)[[1L]]),
    calibration_slope = unname(stats::coef(slope_fit)[[2L]]),
    average_probability = mean(probability),
    observed_frequency = mean(outcome),
    stringsAsFactors = FALSE
  )
}
