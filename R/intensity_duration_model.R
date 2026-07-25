#' Reject development data that touch the reserved comparison period
#'
#' @param data Data frame with `game_datetime`.
#' @param comparison_start First datetime excluded from development.
#' @return `TRUE` invisibly.
#' @export
assert_development_period <- function(
  data,
  comparison_start = "2026-01-01 00:00:00"
) {
  if (!"game_datetime" %in% names(data)) {
    stop("Development data require game_datetime.", call. = FALSE)
  }
  comparison_start <- as.POSIXct(comparison_start, tz = "UTC")
  if (any(data$game_datetime >= comparison_start, na.rm = TRUE)) {
    stop("Development data must not contain 2026 observations.", call. = FALSE)
  }
  invisible(TRUE)
}

.prepare_duration_data <- function(data, feature_names, scaling = NULL) {
  required <- c("league_canonical", feature_names)
  missing <- setdiff(required, names(data))
  if (length(missing) > 0L) {
    stop("Duration data are missing required columns.", call. = FALSE)
  }
  result <- data
  if (is.null(scaling)) {
    standardized <- .standardize_training_features(result, feature_names)
    return(standardized)
  }
  list(data = .apply_feature_scaling(result, scaling), scaling = scaling)
}

#' Fit a probabilistic duration regression
#'
#' @param train Training maps.
#' @param distribution `gamma` or `lognormal`.
#' @param feature_names Numeric pre-series features.
#' @param weights Optional non-negative observation weights.
#' @return Duration model bundle.
#' @export
fit_duration_regression <- function(
  train,
  distribution = c("gamma", "lognormal"),
  feature_names = character(),
  weights = NULL
) {
  distribution <- match.arg(distribution)
  required <- c(
    "league_canonical",
    "game_length_minutes",
    feature_names
  )
  complete <- stats::complete.cases(train[required]) &
    is.finite(train$game_length_minutes) &
    train$game_length_minutes > 0
  data <- train[complete, required, drop = FALSE]
  if (nrow(data) == 0L) {
    stop("No complete duration training rows.", call. = FALSE)
  }
  if (is.null(weights)) {
    weights <- rep(1, nrow(train))
  }
  weights <- weights[complete]
  standardized <- .prepare_duration_data(data, feature_names)
  data <- standardized$data
  league_levels <- sort(unique(as.character(data$league_canonical)))
  data$league_canonical <- factor(
    as.character(data$league_canonical),
    levels = league_levels
  )
  terms <- c(
    if (length(league_levels) > 1L) "league_canonical",
    feature_names
  )
  response <- if (distribution == "lognormal") {
    "log(game_length_minutes)"
  } else {
    "game_length_minutes"
  }
  formula <- stats::reformulate(terms, response = response)
  model <- if (distribution == "gamma") {
    stats::glm(
      formula,
      family = stats::Gamma(link = "log"),
      data = data,
      weights = weights
    )
  } else {
    stats::lm(formula, data = data, weights = weights)
  }
  if (any(!is.finite(stats::coef(model)))) {
    stop("Duration regression did not converge.", call. = FALSE)
  }
  structure(
    list(
      model = model,
      distribution = distribution,
      feature_names = feature_names,
      scaling = standardized$scaling,
      league_levels = league_levels,
      dispersion = if (distribution == "gamma") {
        summary(model)$dispersion
      } else {
        summary(model)$sigma
      }
    ),
    class = "lolkills_duration_regression"
  )
}

#' Draw future map durations
#'
#' @param fit Duration model bundle.
#' @param new_data Future pre-series features.
#' @param draws Monte Carlo draws per map.
#' @param seed Reproducibility seed.
#' @return One duration prediction per row.
#' @export
predict_duration_regression <- function(
  fit,
  new_data,
  draws = 2000L,
  seed = 20260724L
) {
  prepared <- .prepare_duration_data(
    new_data,
    fit$feature_names,
    fit$scaling
  )$data
  if (any(!as.character(prepared$league_canonical) %in%
          fit$league_levels)) {
    stop("Duration data contain an unseen league.", call. = FALSE)
  }
  prepared$league_canonical <- factor(
    as.character(prepared$league_canonical),
    levels = fit$league_levels
  )
  linear <- as.numeric(stats::predict(fit$model, newdata = prepared))
  set.seed(as.integer(seed))
  lapply(seq_along(linear), function(index) {
    samples <- if (fit$distribution == "gamma") {
      expected <- exp(linear[[index]])
      shape <- 1 / fit$dispersion
      stats::rgamma(
        as.integer(draws),
        shape = shape,
        scale = expected / shape
      )
    } else {
      stats::rlnorm(
        as.integer(draws),
        meanlog = linear[[index]],
        sdlog = fit$dispersion
      )
    }
    list(
      mean = mean(samples),
      median = stats::median(samples),
      sd = stats::sd(samples),
      draws = samples
    )
  })
}

#' Fit an explicit intensity times duration model
#'
#' @param train Training maps with observed duration and total kills.
#' @param duration_distribution Duration distribution.
#' @param duration_features Pre-series duration features.
#' @param intensity_features Pre-series intensity features.
#' @param weights Optional training weights.
#' @return Combined model bundle.
#' @export
fit_intensity_duration_model <- function(
  train,
  duration_distribution = c("gamma", "lognormal"),
  duration_features = character(),
  intensity_features = character(),
  weights = NULL
) {
  duration_distribution <- match.arg(duration_distribution)
  duration <- fit_duration_regression(
    train,
    duration_distribution,
    duration_features,
    weights
  )
  intensity_train <- train
  intensity_train$log_exposure <- log(
    intensity_train$game_length_minutes
  )
  standardized <- .standardize_training_features(
    intensity_train,
    intensity_features
  )
  data <- standardized$data
  league_levels <- sort(unique(as.character(data$league_canonical)))
  data$league_canonical <- factor(
    as.character(data$league_canonical),
    levels = league_levels
  )
  terms <- c(
    if (length(league_levels) > 1L) "league_canonical",
    intensity_features,
    "offset(log_exposure)"
  )
  formula <- stats::reformulate(terms, response = "total_kills_game")
  if (is.null(weights)) {
    weights <- rep(1, nrow(data))
  }
  model <- suppressWarnings(MASS::glm.nb(
    formula,
    data = data,
    weights = weights,
    link = log,
    control = stats::glm.control(maxit = 100)
  ))
  if (!isTRUE(model$converged)) {
    stop("Intensity regression did not converge.", call. = FALSE)
  }
  structure(
    list(
      duration = duration,
      intensity_model = model,
      intensity_features = intensity_features,
      intensity_scaling = standardized$scaling,
      league_levels = league_levels,
      theta = as.numeric(model$theta)
    ),
    class = "lolkills_intensity_duration_model"
  )
}

#' Predict a count PMF by integrating duration uncertainty
#'
#' @param fit Combined model bundle.
#' @param new_data Future pre-series features.
#' @param draws Duration integration draws.
#' @param seed Reproducibility seed.
#' @param tail_tolerance Maximum residual probability.
#' @return One probabilistic prediction per row.
#' @export
predict_intensity_duration_model <- function(
  fit,
  new_data,
  draws = 2000L,
  seed = 20260724L,
  tail_tolerance = 1e-10
) {
  durations <- predict_duration_regression(
    fit$duration,
    new_data,
    draws,
    seed
  )
  intensity_data <- .apply_feature_scaling(
    new_data,
    fit$intensity_scaling
  )
  if (any(!as.character(intensity_data$league_canonical) %in%
          fit$league_levels)) {
    stop("Intensity data contain an unseen league.", call. = FALSE)
  }
  intensity_data$league_canonical <- factor(
    as.character(intensity_data$league_canonical),
    levels = fit$league_levels
  )
  intensity_data$log_exposure <- 0
  rates <- as.numeric(stats::predict(
    fit$intensity_model,
    newdata = intensity_data,
    type = "response"
  ))
  lapply(seq_len(nrow(new_data)), function(index) {
    means <- rates[[index]] * durations[[index]]$draws
    support_max <- max(stats::qnbinom(
      1 - tail_tolerance,
      size = fit$theta,
      mu = means
    ))
    support <- seq.int(0L, as.integer(support_max))
    mass <- rowMeans(vapply(
      means,
      function(mu) stats::dnbinom(support, size = fit$theta, mu = mu),
      numeric(length(support))
    ))
    tail_mass <- mean(stats::pnbinom(
      support_max,
      size = fit$theta,
      mu = means,
      lower.tail = FALSE
    ))
    list(
      mean = sum(support * mass) / sum(mass),
      pmf = mass / sum(mass),
      support_max = as.integer(support_max),
      tail_mass = tail_mass,
      duration_mean = durations[[index]]$mean,
      duration_sd = durations[[index]]$sd,
      intensity_per_minute = rates[[index]]
    )
  })
}
