.premap_expectation_columns <- function(expectation, windows) {
  list(
    blue = paste0("blue_mu_", expectation, "_", windows),
    red = paste0("red_mu_", expectation, "_", windows)
  )
}

.premap_softmax <- function(parameters) {
  shifted <- parameters - max(parameters)
  values <- exp(shifted)
  values / sum(values)
}

.premap_combine_means <- function(data, expectation, windows, weights) {
  columns <- .premap_expectation_columns(expectation, windows)
  blue <- as.matrix(data[columns$blue])
  red <- as.matrix(data[columns$red])
  if (
    any(!is.finite(blue)) ||
      any(!is.finite(red)) ||
      any(blue <= 0) ||
      any(red <= 0)
  ) {
    stop("Multiplicative expectations must be finite and positive.", call. = FALSE)
  }
  list(
    blue = exp(as.numeric(log(blue) %*% weights)),
    red = exp(as.numeric(log(red) %*% weights))
  )
}

.premap_optimize_window_weights <- function(
  train,
  expectation,
  windows,
  observation_weights
) {
  objective <- function(parameters) {
    weights <- .premap_softmax(parameters)
    means <- .premap_combine_means(
      train,
      expectation,
      windows,
      weights
    )
    total <- means$blue + means$red
    sum(observation_weights * (
      total - train$total_kills_game * log(pmax(total, 1e-12))
    ))
  }
  initial <- rep(0, length(windows))
  optimization <- stats::optim(
    initial,
    objective,
    method = "BFGS",
    control = list(maxit = 500, reltol = 1e-10)
  )
  if (optimization$convergence != 0L) {
    stop("Window-weight optimization did not converge.", call. = FALSE)
  }
  .premap_softmax(optimization$par)
}

.premap_prepare_offset_data <- function(
  data,
  feature_names,
  league_levels,
  scaling = NULL
) {
  result <- data
  if (length(feature_names) > 0L) {
    if (is.null(scaling)) {
      prepared <- .standardize_training_features(result, feature_names)
    } else {
      prepared <- list(
        data = .apply_feature_scaling(result, scaling),
        scaling = scaling
      )
    }
    result <- prepared$data
    scaling <- prepared$scaling
  } else {
    scaling <- list()
  }
  result$league_canonical <- factor(
    as.character(result$league_canonical),
    levels = league_levels
  )
  if (anyNA(result$league_canonical)) {
    stop("Multiplicative model received an unseen league.", call. = FALSE)
  }
  list(data = result, scaling = scaling)
}

#' Fit a multiplicative pre-map total-kills model
#'
#' @param train Training maps with multiplicative expectations.
#' @param expectation `count` or `rate`.
#' @param windows Windows eligible for the geometric combination.
#' @param combination `single`, `equal`, or `optimized`.
#' @param selected_window Window used by the single-window model.
#' @param calibrated Whether to fit regularized corrections around the formula.
#' @param correction_features Numeric corrections, normally `pace`.
#' @param weights Optional temporal observation weights.
#' @return A coherent Blue, Red, and Negative Binomial total model.
#' @export
fit_premap_multiplicative_model <- function(
  train,
  expectation = c("count", "rate"),
  windows = .premap_window_names(),
  combination = c("single", "equal", "optimized"),
  selected_window = NULL,
  calibrated = FALSE,
  correction_features = "pace",
  weights = NULL
) {
  expectation <- match.arg(expectation)
  combination <- match.arg(combination)
  required <- c(
    "league_canonical",
    "total_kills_game",
    .premap_expectation_columns(expectation, windows)$blue,
    .premap_expectation_columns(expectation, windows)$red
  )
  if (isTRUE(calibrated)) {
    required <- c(required, correction_features)
  }
  missing <- setdiff(required, names(train))
  if (length(missing) > 0L) {
    stop(
      "Missing multiplicative training columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  complete <- stats::complete.cases(train[required]) &
    is.finite(train$total_kills_game) &
    train$total_kills_game >= 0
  data <- train[complete, , drop = FALSE]
  if (nrow(data) < 20L) {
    stop("Multiplicative model requires at least 20 complete maps.", call. = FALSE)
  }
  if (is.null(weights)) {
    weights <- rep(1, nrow(train))
  }
  weights <- as.numeric(weights)[complete]
  if (
    length(weights) != nrow(data) ||
      any(!is.finite(weights)) ||
      any(weights < 0) ||
      sum(weights) <= 0
  ) {
    stop("Multiplicative observation weights are invalid.", call. = FALSE)
  }
  if (combination == "single") {
    if (is.null(selected_window)) {
      selected_window <- windows[[1L]]
    }
    if (!selected_window %in% windows) {
      stop("selected_window is not part of windows.", call. = FALSE)
    }
    model_windows <- selected_window
    window_weights <- 1
  } else {
    model_windows <- windows
    window_weights <- if (combination == "equal") {
      rep(1 / length(model_windows), length(model_windows))
    } else {
      .premap_optimize_window_weights(
        data,
        expectation,
        model_windows,
        weights
      )
    }
  }
  names(window_weights) <- model_windows
  component_means <- .premap_combine_means(
    data,
    expectation,
    model_windows,
    window_weights
  )
  data$formula_mean <- component_means$blue + component_means$red
  data$log_formula_mean <- log(data$formula_mean)
  league_levels <- sort(unique(as.character(data$league_canonical)))
  correction <- NULL
  scaling <- list()
  fitted_mean <- data$formula_mean
  if (isTRUE(calibrated)) {
    prepared <- .premap_prepare_offset_data(
      data,
      correction_features,
      league_levels
    )
    model_data <- prepared$data
    scaling <- prepared$scaling
    terms <- c(
      if (length(league_levels) > 1L) "league_canonical",
      correction_features,
      "offset(log_formula_mean)"
    )
    formula <- stats::reformulate(terms, response = "total_kills_game")
    correction <- suppressWarnings(MASS::glm.nb(
      formula,
      data = model_data,
      weights = weights,
      link = log,
      control = stats::glm.control(maxit = 100)
    ))
    if (!isTRUE(correction$converged)) {
      stop("Multiplicative offset calibration did not converge.", call. = FALSE)
    }
    fitted_mean <- as.numeric(stats::predict(
      correction,
      newdata = model_data,
      type = "response"
    ))
  }
  theta <- if (!is.null(correction)) {
    as.numeric(correction$theta)
  } else {
    .estimate_nb_theta(data$total_kills_game, fitted_mean, weights)
  }
  structure(
    list(
      expectation = expectation,
      combination = combination,
      windows = model_windows,
      window_weights = window_weights,
      calibrated = isTRUE(calibrated),
      correction = correction,
      correction_features = if (isTRUE(calibrated)) {
        correction_features
      } else {
        character()
      },
      scaling = scaling,
      league_levels = league_levels,
      theta = theta,
      allocation_concentration = .premap_fit_allocation_concentration(
        data$blue_team_kills,
        data$total_kills_game,
        component_means$blue / data$formula_mean,
        weights
      ),
      training_maps = nrow(data)
    ),
    class = "lolkills_premap_multiplicative_model"
  )
}

.premap_beta_binomial_log_probability <- function(
  kills,
  total,
  probability,
  concentration
) {
  alpha <- pmax(probability * concentration, 1e-8)
  beta <- pmax((1 - probability) * concentration, 1e-8)
  lchoose(total, kills) +
    lbeta(kills + alpha, total - kills + beta) -
    lbeta(alpha, beta)
}

.premap_fit_allocation_concentration <- function(
  blue_kills,
  total_kills,
  probability,
  weights
) {
  if (
    is.null(blue_kills) ||
      length(blue_kills) != length(total_kills) ||
      any(!is.finite(blue_kills))
  ) {
    return(100)
  }
  probability <- pmin(1 - 1e-6, pmax(1e-6, probability))
  objective <- function(log_concentration) {
    -sum(weights * .premap_beta_binomial_log_probability(
      blue_kills,
      total_kills,
      probability,
      exp(log_concentration)
    ))
  }
  fit <- stats::optimize(
    objective,
    interval = log(c(0.2, 10000))
  )
  exp(fit$minimum)
}

#' Compute a conditional Beta-Binomial kill allocation
#'
#' @param total_kills Total kills in the map.
#' @param blue_probability Expected Blue share of kills.
#' @param concentration Beta concentration.
#' @return Probabilities for Blue kills from zero to total kills.
#' @export
beta_binomial_kill_allocation <- function(
  total_kills,
  blue_probability,
  concentration
) {
  if (
    length(total_kills) != 1L ||
      !is.finite(total_kills) ||
      total_kills < 0 ||
      total_kills != floor(total_kills) ||
      length(blue_probability) != 1L ||
      !is.finite(blue_probability) ||
      blue_probability <= 0 ||
      blue_probability >= 1 ||
      length(concentration) != 1L ||
      !is.finite(concentration) ||
      concentration <= 0
  ) {
    stop("Beta-Binomial allocation parameters are invalid.", call. = FALSE)
  }
  support <- seq.int(0L, as.integer(total_kills))
  log_mass <- .premap_beta_binomial_log_probability(
    support,
    as.integer(total_kills),
    blue_probability,
    concentration
  )
  mass <- exp(log_mass - max(log_mass))
  mass / sum(mass)
}

#' Predict coherent pre-map kill distributions
#'
#' @param fit Multiplicative model bundle.
#' @param new_data Future map features.
#' @param tail_tolerance Maximum probability beyond finite support.
#' @return One prediction per map with total PMF and allocation parameters.
#' @export
predict_premap_multiplicative_model <- function(
  fit,
  new_data,
  tail_tolerance = 1e-10
) {
  component_means <- .premap_combine_means(
    new_data,
    fit$expectation,
    fit$windows,
    fit$window_weights
  )
  formula_mean <- component_means$blue + component_means$red
  total_mean <- formula_mean
  if (isTRUE(fit$calibrated)) {
    prepared <- new_data
    prepared$formula_mean <- formula_mean
    prepared$log_formula_mean <- log(formula_mean)
    prepared <- .premap_prepare_offset_data(
      prepared,
      fit$correction_features,
      fit$league_levels,
      fit$scaling
    )$data
    total_mean <- as.numeric(stats::predict(
      fit$correction,
      newdata = prepared,
      type = "response"
    ))
  }
  scale <- total_mean / formula_mean
  blue_mean <- component_means$blue * scale
  red_mean <- component_means$red * scale
  lapply(seq_along(total_mean), function(index) {
    distribution <- make_count_pmf(
      total_mean[[index]],
      distribution = "negative_binomial",
      theta = fit$theta,
      tail_tolerance = tail_tolerance
    )
    list(
      mean = total_mean[[index]],
      blue_mean = blue_mean[[index]],
      red_mean = red_mean[[index]],
      blue_share = blue_mean[[index]] / total_mean[[index]],
      allocation_concentration = fit$allocation_concentration,
      theta = fit$theta,
      pmf = distribution$pmf,
      support_max = distribution$support_max,
      tail_mass = distribution$tail_mass
    )
  })
}

#' Fit regularized multiplicative exponents for directed team kills
#'
#' @param train Training maps with ratio features.
#' @param expectation `count` or `rate`.
#' @param windows Windows included as separate directed predictors.
#' @param alpha Elastic-net mixing value.
#' @param weights Optional map weights.
#' @return Directed regularized model with coherent total predictions.
#' @export
fit_regularized_multiplicative_exponents <- function(
  train,
  expectation = c("count", "rate"),
  windows = .premap_window_names(),
  alpha = 0,
  weights = NULL
) {
  expectation <- match.arg(expectation)
  if (!requireNamespace("glmnet", quietly = TRUE)) {
    stop("Package glmnet is required.", call. = FALSE)
  }
  if (!is.finite(alpha) || alpha < 0 || alpha > 1) {
    stop("Regularized exponent alpha is invalid.", call. = FALSE)
  }
  if (is.null(weights)) {
    weights <- rep(1, nrow(train))
  }
  order_index <- order(train$game_datetime)
  train <- train[order_index, , drop = FALSE]
  weights <- as.numeric(weights)[order_index]
  directed <- .premap_directed_exponent_data(train, expectation, windows)
  directed_weights <- rep(as.numeric(weights), each = 2L)
  complete <- stats::complete.cases(directed)
  directed <- directed[complete, , drop = FALSE]
  directed_weights <- directed_weights[complete]
  if (nrow(directed) < 100L) {
    stop("Regularized exponents require at least 50 complete maps.", call. = FALSE)
  }
  feature_names <- setdiff(
    names(directed),
    c("gameid", "league_canonical", "observed", "offset")
  )
  league_levels <- sort(unique(directed$league_canonical))
  x <- .regularized_design_matrix(
    directed,
    feature_names,
    league_levels
  )
  map_count <- nrow(directed) / 2L
  inner_maps <- max(25L, floor(map_count * 0.2))
  training_maps <- seq_len(map_count - inner_maps)
  validation_maps <- seq.int(map_count - inner_maps + 1L, map_count)
  inner_training <- as.vector(rbind(
    2L * training_maps - 1L,
    2L * training_maps
  ))
  inner_validation <- as.vector(rbind(
    2L * validation_maps - 1L,
    2L * validation_maps
  ))
  path <- glmnet::glmnet(
    x[inner_training, , drop = FALSE],
    directed$observed[inner_training],
    family = "poisson",
    alpha = alpha,
    weights = directed_weights[inner_training],
    offset = directed$offset[inner_training],
    standardize = TRUE
  )
  validation_means <- as.matrix(stats::predict(
    path,
    newx = x[inner_validation, , drop = FALSE],
    type = "response",
    newoffset = directed$offset[inner_validation]
  ))
  validation_loss <- vapply(seq_len(ncol(validation_means)), function(index) {
    stats::weighted.mean(
      validation_means[, index] -
        directed$observed[inner_validation] *
          log(pmax(validation_means[, index], 1e-12)),
      directed_weights[inner_validation]
    )
  }, numeric(1L))
  selected_lambda <- path$lambda[[which.min(validation_loss)]]
  model <- glmnet::glmnet(
    x,
    directed$observed,
    family = "poisson",
    alpha = alpha,
    lambda = selected_lambda,
    weights = directed_weights,
    offset = directed$offset,
    standardize = TRUE
  )
  fitted <- as.numeric(stats::predict(
    model,
    newx = x,
    s = selected_lambda,
    type = "response",
    newoffset = directed$offset
  ))
  map_total <- rowsum(fitted, directed$gameid, reorder = FALSE)[, 1L]
  observed_total <- rowsum(
    directed$observed,
    directed$gameid,
    reorder = FALSE
  )[, 1L]
  map_weights <- rowsum(
    directed_weights,
    directed$gameid,
    reorder = FALSE
  )[, 1L] / 2
  structure(
    list(
      model = model,
      lambda = selected_lambda,
      expectation = expectation,
      windows = windows,
      feature_names = feature_names,
      league_levels = league_levels,
      x_columns = colnames(x),
      theta = .estimate_nb_theta(
        observed_total,
        map_total,
        map_weights
      )
    ),
    class = "lolkills_regularized_multiplicative_exponents"
  )
}

.premap_directed_exponent_data <- function(data, expectation, windows) {
  rows <- vector("list", nrow(data) * 2L)
  index <- 0L
  for (map_index in seq_len(nrow(data))) {
    for (side in c("blue", "red")) {
      index <- index + 1L
      opponent <- if (side == "blue") "red" else "blue"
      row <- list(
        gameid = as.character(data$gameid[[map_index]]),
        league_canonical = as.character(
          data$league_canonical[[map_index]]
        ),
        observed = as.numeric(
          data[[paste0(side, "_team_kills")]][[map_index]]
        )
      )
      offsets <- numeric(length(windows))
      for (window_index in seq_along(windows)) {
        window <- windows[[window_index]]
        if (expectation == "count") {
          league <- data[[
            paste0(side, "_", window, "_league_kills_per_map")
          ]][[map_index]]
          row[[paste0(window, "_attack")]] <- log(data[[
            paste0(side, "_", window, "_attack_ratio")
          ]][[map_index]])
          row[[paste0(window, "_concession")]] <- log(data[[
            paste0(opponent, "_", window, "_concession_ratio")
          ]][[map_index]])
          offsets[[window_index]] <- log(league)
        } else {
          league <- data[[
            paste0(side, "_", window, "_league_kpm")
          ]][[map_index]]
          duration <- data[[paste0("duration_", window)]][[map_index]]
          row[[paste0(window, "_kpm")]] <- log(data[[
            paste0(side, "_", window, "_kpm_ratio")
          ]][[map_index]])
          row[[paste0(window, "_dpm")]] <- log(data[[
            paste0(opponent, "_", window, "_dpm_ratio")
          ]][[map_index]])
          row[[paste0(window, "_duration")]] <- log(duration)
          offsets[[window_index]] <- log(league)
        }
      }
      row$offset <- mean(offsets)
      rows[[index]] <- as.data.frame(row, stringsAsFactors = FALSE)
    }
  }
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

#' Predict from regularized directed multiplicative exponents
#'
#' @param fit Fitted regularized exponent model.
#' @param new_data Future map rows.
#' @param tail_tolerance Maximum count-PMF tail probability.
#' @return Coherent total and team predictions.
#' @export
predict_regularized_multiplicative_exponents <- function(
  fit,
  new_data,
  tail_tolerance = 1e-10
) {
  directed <- .premap_directed_exponent_data(
    new_data,
    fit$expectation,
    fit$windows
  )
  x <- .regularized_design_matrix(
    directed,
    fit$feature_names,
    fit$league_levels,
    fit$x_columns
  )
  means <- as.numeric(stats::predict(
    fit$model,
    newx = x,
    s = fit$lambda,
    type = "response",
    newoffset = directed$offset
  ))
  lapply(seq_len(nrow(new_data)), function(index) {
    blue <- means[[2L * index - 1L]]
    red <- means[[2L * index]]
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
