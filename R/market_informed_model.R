.moneyline_directed_data <- function(data, base_predictions, interactions) {
  rows <- vector("list", nrow(data) * 2L)
  index <- 0L
  for (map_index in seq_len(nrow(data))) {
    prediction <- base_predictions[[map_index]]
    for (side in c("blue", "red")) {
      index <- index + 1L
      probability <- data[[paste0("p_", side)]][[map_index]]
      row <- data.frame(
        gameid = as.character(data$gameid[[map_index]]),
        league_canonical = as.character(
          data$league_canonical[[map_index]]
        ),
        observed = as.numeric(
          data[[paste0(side, "_team_kills")]][[map_index]]
        ),
        fundamental_mean = as.numeric(
          prediction[[paste0(side, "_mean")]]
        ),
        logit_win_probability = stats::qlogis(pmin(
          1 - 1e-8,
          pmax(1e-8, probability)
        )),
        stringsAsFactors = FALSE
      )
      if (isTRUE(interactions)) {
        opponent <- if (side == "blue") "red" else "blue"
        row$attack_signal <- .moneyline_weighted_ratio_signal(
          data,
          map_index,
          side,
          "attack_ratio",
          prediction
        )
        row$concession_signal <- .moneyline_weighted_ratio_signal(
          data,
          map_index,
          opponent,
          "concession_ratio",
          prediction
        )
        row$duration_signal <- .moneyline_weighted_ratio_signal(
          data,
          map_index,
          side,
          "duration_ratio",
          prediction
        )
        row$win_attack_interaction <-
          row$logit_win_probability * row$attack_signal
        row$win_concession_interaction <-
          row$logit_win_probability * row$concession_signal
        row$win_duration_interaction <-
          row$logit_win_probability * row$duration_signal
      }
      rows[[index]] <- row
    }
  }
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

.predict_fundamental_team_model <- function(fit, data) {
  if (inherits(fit, "lolkills_premap_multiplicative_model")) {
    predictions <- predict_premap_multiplicative_model(fit, data)
    windows <- fit$windows
    weights <- fit$window_weights
  } else if (
    inherits(fit, "lolkills_regularized_multiplicative_exponents")
  ) {
    predictions <- predict_regularized_multiplicative_exponents(fit, data)
    windows <- fit$windows
    weights <- rep(1 / length(windows), length(windows))
  } else {
    stop(
      "Moneyline correction requires a directed fundamental model.",
      call. = FALSE
    )
  }
  for (index in seq_along(predictions)) {
    predictions[[index]]$model_windows <- windows
    predictions[[index]]$model_window_weights <- weights
  }
  predictions
}

.moneyline_weighted_ratio_signal <- function(
  data,
  row_index,
  side,
  ratio,
  prediction
) {
  windows <- prediction$model_windows
  weights <- prediction$model_window_weights
  if (is.null(windows) || is.null(weights)) {
    return(0)
  }
  values <- vapply(windows, function(window) {
    log(as.numeric(data[[
      paste0(side, "_", window, "_", ratio)
    ]][[row_index]]))
  }, numeric(1L))
  sum(values * weights)
}

#' Fit a moneyline correction around a fundamental model
#'
#' @param train Training maps with no-vig Blue and Red probabilities.
#' @param fundamental_fit Fitted multiplicative fundamental model.
#' @param interactions Whether to add restricted rating interactions.
#' @param spline Whether to test a three-degree natural spline.
#' @param weights Optional temporal map weights.
#' @return Fifteen-minute moneyline-informed model.
#' @export
fit_moneyline_informed_model <- function(
  train,
  fundamental_fit,
  interactions = FALSE,
  spline = FALSE,
  weights = NULL
) {
  required <- c(
    "gameid",
    "league_canonical",
    "blue_team_kills",
    "red_team_kills",
    "total_kills_game",
    "p_blue",
    "p_red"
  )
  missing <- setdiff(required, names(train))
  if (length(missing) > 0L) {
    stop(
      "Moneyline training data are missing: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (is.null(weights)) {
    weights <- rep(1, nrow(train))
  }
  if (
    length(weights) != nrow(train) ||
      any(!is.finite(weights)) ||
      any(weights < 0) ||
      sum(weights) <= 0
  ) {
    stop("Moneyline model weights are invalid.", call. = FALSE)
  }
  base_predictions <- .predict_fundamental_team_model(
    fundamental_fit,
    train
  )
  directed <- .moneyline_directed_data(
    train,
    base_predictions,
    interactions
  )
  directed$log_fundamental_mean <- log(directed$fundamental_mean)
  directed$league_canonical <- factor(directed$league_canonical)
  terms <- c(
    if (isTRUE(spline)) {
      "splines::ns(logit_win_probability, df = 3)"
    } else {
      "logit_win_probability"
    },
    if (isTRUE(interactions)) {
      c(
        "attack_signal",
        "concession_signal",
        "duration_signal",
        "win_attack_interaction",
        "win_concession_interaction",
        "win_duration_interaction"
      )
    },
    "offset(log_fundamental_mean)"
  )
  formula <- stats::reformulate(terms, response = "observed")
  model <- stats::glm(
    formula,
    family = stats::poisson(link = "log"),
    data = directed,
    weights = rep(as.numeric(weights), each = 2L),
    control = stats::glm.control(maxit = 100)
  )
  if (!isTRUE(model$converged) || any(!is.finite(stats::coef(model)))) {
    stop("Moneyline correction did not converge.", call. = FALSE)
  }
  directed_fitted <- as.numeric(stats::predict(
    model,
    newdata = directed,
    type = "response"
  ))
  fitted_total <- directed_fitted[c(TRUE, FALSE)] +
    directed_fitted[c(FALSE, TRUE)]
  structure(
    list(
      fundamental_fit = fundamental_fit,
      model = model,
      interactions = isTRUE(interactions),
      spline = isTRUE(spline),
      league_levels = levels(directed$league_canonical),
      theta = .estimate_nb_theta(
        train$total_kills_game,
        fitted_total,
        weights
      ),
      training_maps = nrow(train)
    ),
    class = "lolkills_moneyline_informed_model"
  )
}

#' Predict with a moneyline-informed model
#'
#' @param fit Fitted moneyline model.
#' @param new_data Future maps with current no-vig moneylines.
#' @param tail_tolerance Maximum total-PMF tail probability.
#' @return Coherent team and total kill predictions.
#' @export
predict_moneyline_informed_model <- function(
  fit,
  new_data,
  tail_tolerance = 1e-10
) {
  base_predictions <- .predict_fundamental_team_model(
    fit$fundamental_fit,
    new_data
  )
  directed <- .moneyline_directed_data(
    new_data,
    base_predictions,
    fit$interactions
  )
  directed$log_fundamental_mean <- log(directed$fundamental_mean)
  directed$league_canonical <- as.character(
    directed$league_canonical
  )
  directed_mean <- as.numeric(stats::predict(
    fit$model,
    newdata = directed,
    type = "response"
  ))
  lapply(seq_len(nrow(new_data)), function(index) {
    blue <- directed_mean[[2L * index - 1L]]
    red <- directed_mean[[2L * index]]
    total <- blue + red
    distribution <- make_count_pmf(
      total,
      "negative_binomial",
      fit$theta,
      tail_tolerance
    )
    list(
      mean = total,
      blue_mean = blue,
      red_mean = red,
      blue_share = blue / total,
      theta = fit$theta,
      pmf = distribution$pmf,
      support_max = distribution$support_max,
      tail_mass = distribution$tail_mass
    )
  })
}

.pmf_probability_over <- function(pmf, line) {
  if (!is.finite(line) || abs(line %% 1 - 0.5) > 1e-12) {
    stop("Market-informed totals require a half-kill line.", call. = FALSE)
  }
  support <- seq.int(0L, length(pmf) - 1L)
  sum(pmf[support > line])
}

.pmf_tilt_parameter <- function(pmf, line, target_probability_over) {
  if (
    !is.finite(target_probability_over) ||
      target_probability_over <= 0 ||
      target_probability_over >= 1
  ) {
    stop("Target market probability must be inside (0, 1).", call. = FALSE)
  }
  support <- seq.int(0L, length(pmf) - 1L)
  probability_at <- function(lambda) {
    log_mass <- log(pmax(pmf, 1e-300)) + lambda * support
    mass <- exp(log_mass - max(log_mass))
    mass <- mass / sum(mass)
    sum(mass[support > line]) - target_probability_over
  }
  lower <- -1
  upper <- 1
  while (probability_at(lower) > 0 && lower > -100) {
    lower <- lower * 2
  }
  while (probability_at(upper) < 0 && upper < 100) {
    upper <- upper * 2
  }
  stats::uniroot(probability_at, c(lower, upper), tol = 1e-10)$root
}

#' Exponentially tilt a full PMF toward the Pinnacle total market
#'
#' @param pmf Fundamental predictive PMF.
#' @param line Pinnacle half-kill line.
#' @param market_probability_over No-vig probability of Over.
#' @param weight Information weight from zero to one.
#' @return A normalized hybrid PMF.
#' @export
tilt_pmf_to_kill_market <- function(
  pmf,
  line,
  market_probability_over,
  weight = 1
) {
  if (
    !is.finite(weight) ||
      weight < 0 ||
      weight > 1
  ) {
    stop("Market tilt weight must be between zero and one.", call. = FALSE)
  }
  lambda <- .pmf_tilt_parameter(
    pmf,
    line,
    market_probability_over
  )
  support <- seq.int(0L, length(pmf) - 1L)
  log_mass <- log(pmax(pmf, 1e-300)) + weight * lambda * support
  mass <- exp(log_mass - max(log_mass))
  mass / sum(mass)
}

#' Fit the kill-market information weight inside training data
#'
#' @param predictions Fundamental or moneyline-informed predictions.
#' @param market_data Rows with line, no-vig Over probability, and outcome.
#' @return Scalar blend weight minimizing full-PMF Log Score.
#' @export
fit_kill_market_tilt_weight <- function(predictions, market_data) {
  required <- c("line", "market_probability_over", "total_kills_game")
  if (!all(required %in% names(market_data))) {
    stop("Kill-market training rows are incomplete.", call. = FALSE)
  }
  if (length(predictions) != nrow(market_data)) {
    stop("Kill-market predictions and rows are misaligned.", call. = FALSE)
  }
  objective <- function(weight) {
    losses <- vapply(seq_len(nrow(market_data)), function(index) {
      pmf <- tilt_pmf_to_kill_market(
        predictions[[index]]$pmf,
        market_data$line[[index]],
        market_data$market_probability_over[[index]],
        weight
      )
      observed <- as.integer(market_data$total_kills_game[[index]])
      -log(if (observed + 1L <= length(pmf)) {
        max(pmf[[observed + 1L]], 1e-12)
      } else {
        1e-12
      })
    }, numeric(1L))
    mean(losses)
  }
  fit <- stats::optimize(objective, interval = c(0, 1))
  structure(
    list(weight = fit$minimum, log_score = fit$objective),
    class = "lolkills_kill_market_tilt"
  )
}

#' Apply the fitted total-market block to predictive PMFs
#'
#' @param predictions Fundamental or moneyline-informed predictions.
#' @param market_data Rows with the real line and no-vig Over probability.
#' @param tilt Fitted market-tilt weight.
#' @return Hybrid predictions preserving all original metadata.
#' @export
predict_kill_market_hybrid <- function(
  predictions,
  market_data,
  tilt
) {
  if (length(predictions) != nrow(market_data)) {
    stop("Hybrid predictions and market rows are misaligned.", call. = FALSE)
  }
  lapply(seq_len(nrow(market_data)), function(index) {
    prediction <- predictions[[index]]
    prediction$pmf <- tilt_pmf_to_kill_market(
      prediction$pmf,
      market_data$line[[index]],
      market_data$market_probability_over[[index]],
      tilt$weight
    )
    support <- seq.int(0L, length(prediction$pmf) - 1L)
    prediction$mean <- sum(support * prediction$pmf)
    prediction$market_tilt_weight <- tilt$weight
    prediction$market_probability_over <- .pmf_probability_over(
      prediction$pmf,
      market_data$line[[index]]
    )
    prediction
  })
}
