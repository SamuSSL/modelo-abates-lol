.joint_feature_value <- function(data, name, default = 0) {
  if (!name %in% names(data)) {
    return(rep(default, nrow(data)))
  }
  value <- suppressWarnings(as.numeric(data[[name]]))
  value[!is.finite(value)] <- default
  value
}

.joint_prepare_map_features <- function(data, windows) {
  result <- data
  duration_columns <- paste0("duration_", windows)
  missing_duration <- setdiff(duration_columns, names(result))
  if (length(missing_duration) > 0L) {
    stop(
      "Joint model is missing duration windows: ",
      paste(missing_duration, collapse = ", "),
      call. = FALSE
    )
  }
  duration_matrix <- as.matrix(result[duration_columns])
  if (any(!is.finite(duration_matrix)) || any(duration_matrix <= 0)) {
    stop("Joint duration features must be positive.", call. = FALSE)
  }
  result$duration_level <- exp(rowMeans(log(duration_matrix)))
  imbalance_matrix <- vapply(windows, function(window) {
    blue <- .joint_feature_value(
      result,
      paste0("blue_", window, "_duration_ratio"),
      1
    )
    red <- .joint_feature_value(
      result,
      paste0("red_", window, "_duration_ratio"),
      1
    )
    abs(log(pmax(blue, 1e-8)) - log(pmax(red, 1e-8)))
  }, numeric(nrow(result)))
  if (is.null(dim(imbalance_matrix))) {
    imbalance_matrix <- matrix(
      imbalance_matrix,
      nrow = nrow(result),
      ncol = length(windows)
    )
  }
  result$duration_imbalance <- rowMeans(imbalance_matrix)
  volatility_matrix <- vapply(windows, function(window) {
    blue <- .joint_feature_value(
      result,
      paste0("blue_", window, "_total_kills_sd_ratio"),
      1
    )
    red <- .joint_feature_value(
      result,
      paste0("red_", window, "_total_kills_sd_ratio"),
      1
    )
    sqrt(pmax(blue, 1e-8) * pmax(red, 1e-8))
  }, numeric(nrow(result)))
  if (is.null(dim(volatility_matrix))) {
    volatility_matrix <- matrix(
      volatility_matrix,
      nrow = nrow(result),
      ncol = length(windows)
    )
  }
  result$team_volatility <- rowMeans(volatility_matrix)
  map_number <- suppressWarnings(as.integer(result$map_number))
  result$map_2 <- as.numeric(map_number == 2L)
  result$map_3 <- as.numeric(map_number == 3L)
  result$map_4_plus <- as.numeric(map_number >= 4L)
  result$favorite_imbalance <- .joint_feature_value(
    result,
    "favorite_imbalance",
    0
  )
  result$favorite_imbalance_squared <-
    result$favorite_imbalance^2
  result
}

.joint_directed_rows <- function(data, windows) {
  rows <- vector("list", nrow(data) * 2L)
  row_index <- 0L
  for (map_index in seq_len(nrow(data))) {
    for (side in c("blue", "red")) {
      row_index <- row_index + 1L
      opponent <- if (side == "blue") "red" else "blue"
      row <- list(
        gameid = as.character(data$gameid[[map_index]]),
        league_canonical = as.character(
          data$league_canonical[[map_index]]
        ),
        observed = as.numeric(
          data[[paste0(side, "_team_kills")]][[map_index]]
        ),
        observed_duration = as.numeric(
          data$game_length_minutes[[map_index]]
        ),
        pace = as.numeric(data$pace[[map_index]]),
        map_2 = as.numeric(data$map_2[[map_index]]),
        map_3 = as.numeric(data$map_3[[map_index]]),
        map_4_plus = as.numeric(data$map_4_plus[[map_index]])
      )
      baseline <- numeric(length(windows))
      for (window_index in seq_along(windows)) {
        window <- windows[[window_index]]
        baseline[[window_index]] <- log(as.numeric(data[[
          paste0(side, "_", window, "_league_kpm")
        ]][[map_index]]))
        row[[paste0("own_kpm_", window)]] <- log(as.numeric(data[[
          paste0(side, "_", window, "_kpm_ratio")
        ]][[map_index]]))
        row[[paste0("opponent_dpm_", window)]] <- log(as.numeric(data[[
          paste0(opponent, "_", window, "_dpm_ratio")
        ]][[map_index]]))
      }
      row$baseline_log_rate <- mean(baseline)
      rows[[row_index]] <- as.data.frame(
        row,
        stringsAsFactors = FALSE
      )
    }
  }
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

.joint_fit_intensity <- function(
  train,
  windows,
  weights,
  alpha,
  inner_fraction
) {
  if (!requireNamespace("glmnet", quietly = TRUE)) {
    stop("Package glmnet is required.", call. = FALSE)
  }
  directed <- .joint_directed_rows(train, windows)
  feature_names <- setdiff(
    names(directed),
    c(
      "gameid",
      "league_canonical",
      "observed",
      "observed_duration",
      "baseline_log_rate"
    )
  )
  league_levels <- sort(unique(directed$league_canonical))
  x <- .regularized_design_matrix(
    directed,
    feature_names,
    league_levels
  )
  directed_weights <- rep(as.numeric(weights), each = 2L)
  offset <- log(pmax(directed$observed_duration, 1e-8)) +
    directed$baseline_log_rate
  map_count <- nrow(train)
  inner_maps <- max(50L, floor(map_count * inner_fraction))
  split_index <- map_count - inner_maps
  if (split_index < 50L) {
    stop("Joint intensity inner split is too small.", call. = FALSE)
  }
  training_maps <- seq_len(split_index)
  validation_maps <- seq.int(split_index + 1L, map_count)
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
    offset = offset[inner_training],
    standardize = TRUE
  )
  validation_mean <- as.matrix(stats::predict(
    path,
    newx = x[inner_validation, , drop = FALSE],
    type = "response",
    newoffset = offset[inner_validation]
  ))
  validation_loss <- vapply(
    seq_len(ncol(validation_mean)),
    function(index) {
      stats::weighted.mean(
        validation_mean[, index] -
          directed$observed[inner_validation] *
            log(pmax(validation_mean[, index], 1e-12)),
        directed_weights[inner_validation]
      )
    },
    numeric(1L)
  )
  lambda <- path$lambda[[which.min(validation_loss)]]
  model <- glmnet::glmnet(
    x,
    directed$observed,
    family = "poisson",
    alpha = alpha,
    lambda = lambda,
    weights = directed_weights,
    offset = offset,
    standardize = TRUE
  )
  list(
    model = model,
    lambda = lambda,
    feature_names = feature_names,
    league_levels = league_levels,
    x_columns = colnames(x),
    inner_loss = min(validation_loss)
  )
}

.joint_predict_rates <- function(intensity, data, windows) {
  directed <- .joint_directed_rows(data, windows)
  x <- .regularized_design_matrix(
    directed,
    intensity$feature_names,
    intensity$league_levels,
    expected_columns = intensity$x_columns
  )
  rates <- as.numeric(stats::predict(
    intensity$model,
    newx = x,
    s = intensity$lambda,
    type = "response",
    newoffset = directed$baseline_log_rate
  ))
  list(
    blue = rates[seq.int(1L, length(rates), by = 2L)],
    red = rates[seq.int(2L, length(rates), by = 2L)],
    directed = directed
  )
}

.joint_fit_dispersion <- function(
  observed,
  means,
  data,
  weights,
  mode = c("global", "favoritism", "favoritism_team_volatility"),
  ridge_penalty = 5
) {
  mode <- match.arg(mode)
  global_theta <- .estimate_nb_theta(observed, means, weights)
  if (mode == "global") {
    return(list(
      mode = mode,
      global_theta = global_theta,
      coefficients = numeric(),
      center = numeric(),
      scale = numeric(),
      converged = TRUE
    ))
  }
  features <- if (mode == "favoritism") {
    c("favorite_imbalance")
  } else {
    c("favorite_imbalance", "team_volatility")
  }
  matrix <- as.matrix(data[features])
  center <- colMeans(matrix)
  scale <- apply(matrix, 2L, stats::sd)
  scale[!is.finite(scale) | scale <= 1e-8] <- 1
  standardized <- sweep(
    sweep(matrix, 2L, center, "-"),
    2L,
    scale,
    "/"
  )
  objective <- function(coefficients) {
    theta <- exp(pmin(
      12,
      pmax(
        -8,
        log(global_theta) +
          as.numeric(standardized %*% coefficients)
      )
    ))
    likelihood <- stats::dnbinom(
      observed,
      size = theta,
      mu = means,
      log = TRUE
    )
    -sum(weights * likelihood) / sum(weights) +
      ridge_penalty * sum(coefficients^2)
  }
  optimization <- stats::optim(
    rep(0, ncol(standardized)),
    objective,
    method = "BFGS"
  )
  coefficients <- if (
    optimization$convergence == 0L &&
      all(is.finite(optimization$par))
  ) {
    optimization$par
  } else {
    rep(0, ncol(standardized))
  }
  names(coefficients) <- features
  names(center) <- features
  names(scale) <- features
  list(
    mode = mode,
    global_theta = global_theta,
    coefficients = coefficients,
    center = center,
    scale = scale,
    converged = optimization$convergence == 0L
  )
}

.joint_predict_theta <- function(dispersion, data) {
  if (
    dispersion$mode == "global" ||
      length(dispersion$coefficients) == 0L
  ) {
    return(rep(dispersion$global_theta, nrow(data)))
  }
  features <- names(dispersion$coefficients)
  matrix <- as.matrix(data[features])
  standardized <- sweep(
    sweep(matrix, 2L, dispersion$center, "-"),
    2L,
    dispersion$scale,
    "/"
  )
  exp(pmin(
    12,
    pmax(
      -8,
      log(dispersion$global_theta) +
        as.numeric(standardized %*% dispersion$coefficients)
    )
  ))
}

.joint_mixture_pmf <- function(means, theta, tail_tolerance) {
  support_max <- max(stats::qnbinom(
    1 - tail_tolerance,
    size = theta,
    mu = means
  ))
  support <- seq.int(0L, as.integer(support_max))
  mass <- rowMeans(vapply(means, function(mean_value) {
    stats::dnbinom(
      support,
      size = theta,
      mu = mean_value
    )
  }, numeric(length(support))))
  tail_mass <- mean(stats::pnbinom(
    support_max,
    size = theta,
    mu = means,
    lower.tail = FALSE
  ))
  list(
    pmf = mass / sum(mass),
    support_max = as.integer(support_max),
    tail_mass = tail_mass
  )
}

.joint_prediction_from_components <- function(
  duration_predictions,
  rates,
  theta,
  allocation_concentration,
  tail_tolerance
) {
  lapply(seq_along(duration_predictions), function(index) {
    duration_draws <- duration_predictions[[index]]$draws
    total_rate <- rates$blue[[index]] + rates$red[[index]]
    total_means <- duration_draws * total_rate
    distribution <- .joint_mixture_pmf(
      total_means,
      theta[[index]],
      tail_tolerance
    )
    total_mean <- mean(total_means)
    blue_share <- rates$blue[[index]] / total_rate
    list(
      mean = total_mean,
      blue_mean = total_mean * blue_share,
      red_mean = total_mean * (1 - blue_share),
      blue_share = blue_share,
      allocation_concentration = allocation_concentration,
      theta = theta[[index]],
      pmf = distribution$pmf,
      support_max = distribution$support_max,
      tail_mass = distribution$tail_mass,
      duration_mean = mean(duration_draws),
      duration_median = stats::median(duration_draws),
      duration_sd = stats::sd(duration_draws),
      duration_draws = duration_draws,
      blue_rate = rates$blue[[index]],
      red_rate = rates$red[[index]]
    )
  })
}

#' Fit a directed team-intensity and probabilistic duration model
#'
#' @param train Point-in-time map features.
#' @param windows Rating windows included in the directed attack-concession
#'   model.
#' @param alpha Ridge or elastic-net mixing value.
#' @param weights Optional temporal weights.
#' @param inner_fraction Latest training fraction used for lambda selection.
#' @param dispersion_mode Total-kills dispersion specification.
#' @param seed Reproducibility seed for fitted duration summaries.
#' @return Fundamental joint model.
#' @export
fit_directed_joint_fundamental <- function(
  train,
  windows = "last15",
  alpha = 0,
  weights = NULL,
  inner_fraction = 0.2,
  dispersion_mode = c("global", "favoritism_team_volatility"),
  seed = 20260730L
) {
  dispersion_mode <- match.arg(dispersion_mode)
  if (is.null(weights)) {
    weights <- rep(1, nrow(train))
  }
  positive_columns <- c(
    "game_length_minutes",
    "pace",
    paste0("duration_", windows),
    unlist(lapply(windows, function(window) {
      c(
        paste0("blue_", window, "_league_kpm"),
        paste0("red_", window, "_league_kpm"),
        paste0("blue_", window, "_kpm_ratio"),
        paste0("red_", window, "_kpm_ratio"),
        paste0("blue_", window, "_dpm_ratio"),
        paste0("red_", window, "_dpm_ratio"),
        paste0("blue_", window, "_duration_ratio"),
        paste0("red_", window, "_duration_ratio")
      )
    }), use.names = FALSE)
  )
  required_columns <- c(
    "game_datetime",
    "league_canonical",
    "blue_team_kills",
    "red_team_kills",
    "total_kills_game",
    positive_columns
  )
  missing <- setdiff(required_columns, names(train))
  if (length(missing) > 0L) {
    stop(
      "Joint fundamental training is missing: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  complete <- stats::complete.cases(train[required_columns])
  complete <- complete & apply(
    as.matrix(train[positive_columns]),
    1L,
    function(value) all(is.finite(value) & value > 0)
  )
  complete <- complete &
    train$blue_team_kills >= 0 &
    train$red_team_kills >= 0 &
    train$total_kills_game >= 0
  train <- train[complete, , drop = FALSE]
  weights <- as.numeric(weights)[complete]
  if (nrow(train) < 100L) {
    stop(
      "Joint fundamental requires at least 100 complete maps.",
      call. = FALSE
    )
  }
  order_index <- order(train$game_datetime)
  data <- .joint_prepare_map_features(
    train[order_index, , drop = FALSE],
    windows
  )
  weights <- as.numeric(weights)[order_index]
  duration_features <- c(
    "pace",
    "duration_level",
    "duration_imbalance",
    "map_2",
    "map_3",
    "map_4_plus"
  )
  duration <- fit_regularized_duration_model(
    data,
    feature_names = duration_features,
    alpha = alpha,
    weights = weights,
    inner_fraction = inner_fraction
  )
  intensity <- .joint_fit_intensity(
    data,
    windows,
    weights,
    alpha,
    inner_fraction
  )
  duration_predictions <- predict_regularized_duration_model(
    duration,
    data,
    draws = 500L,
    seed = seed
  )
  rates <- .joint_predict_rates(intensity, data, windows)
  duration_means <- vapply(
    duration_predictions,
    function(item) item$mean,
    numeric(1L)
  )
  total_means <- duration_means * (rates$blue + rates$red)
  dispersion_data <- data
  if (dispersion_mode == "favoritism_team_volatility") {
    dispersion_data$favorite_imbalance <- 0
  }
  dispersion <- .joint_fit_dispersion(
    data$total_kills_game,
    total_means,
    dispersion_data,
    weights,
    mode = dispersion_mode
  )
  blue_share <- rates$blue / (rates$blue + rates$red)
  allocation_concentration <- .premap_fit_allocation_concentration(
    data$blue_team_kills,
    data$total_kills_game,
    blue_share,
    weights
  )
  structure(
    list(
      windows = windows,
      alpha = alpha,
      duration = duration,
      duration_features = duration_features,
      intensity = intensity,
      dispersion = dispersion,
      allocation_concentration = allocation_concentration,
      inner_fraction = inner_fraction,
      training_maps = nrow(data),
      seed = as.integer(seed)
    ),
    class = "lolkills_directed_joint_fundamental"
  )
}

#' Predict from the directed fundamental joint model
#'
#' @param fit Fundamental joint model.
#' @param new_data Point-in-time map features.
#' @param draws Duration Monte Carlo draws per map.
#' @param seed Reproducibility seed.
#' @param tail_tolerance Maximum unrepresented count probability.
#' @return Total and team-kill predictive objects.
#' @export
predict_directed_joint_fundamental <- function(
  fit,
  new_data,
  draws = 2000L,
  seed = fit$seed,
  tail_tolerance = 1e-10
) {
  data <- .joint_prepare_map_features(new_data, fit$windows)
  duration_predictions <- predict_regularized_duration_model(
    fit$duration,
    data,
    draws = draws,
    seed = seed
  )
  rates <- .joint_predict_rates(fit$intensity, data, fit$windows)
  theta <- .joint_predict_theta(fit$dispersion, data)
  .joint_prediction_from_components(
    duration_predictions,
    rates,
    theta,
    fit$allocation_concentration,
    tail_tolerance
  )
}

.moneyline_correction_features <- function(
  data,
  shape = c("linear", "quadratic"),
  interactions = FALSE
) {
  shape <- match.arg(shape)
  result <- data.frame(
    win_logit = as.numeric(data$win_logit),
    favorite_imbalance = as.numeric(data$favorite_imbalance),
    stringsAsFactors = FALSE
  )
  if (shape == "quadratic") {
    result$win_logit_times_imbalance <-
      result$win_logit * result$favorite_imbalance
    result$favorite_imbalance_squared <-
      result$favorite_imbalance^2
  }
  if (isTRUE(interactions)) {
    result$win_attack_interaction <-
      result$win_logit * as.numeric(data$attack_signal)
    result$win_concession_interaction <-
      result$win_logit * as.numeric(data$concession_signal)
  }
  result
}

.joint_moneyline_directed_data <- function(data, base_rates, windows) {
  rows <- vector("list", nrow(data) * 2L)
  index <- 0L
  for (map_index in seq_len(nrow(data))) {
    for (side in c("blue", "red")) {
      index <- index + 1L
      opponent <- if (side == "blue") "red" else "blue"
      side_probability <- if (side == "blue") {
        data$p_blue[[map_index]]
      } else {
        data$p_red[[map_index]]
      }
      attack_signal <- mean(vapply(windows, function(window) {
        log(as.numeric(data[[
          paste0(side, "_", window, "_kpm_ratio")
        ]][[map_index]]))
      }, numeric(1L)))
      concession_signal <- mean(vapply(windows, function(window) {
        log(as.numeric(data[[
          paste0(opponent, "_", window, "_dpm_ratio")
        ]][[map_index]]))
      }, numeric(1L)))
      base_rate <- if (side == "blue") {
        base_rates$blue[[map_index]]
      } else {
        base_rates$red[[map_index]]
      }
      rows[[index]] <- data.frame(
        gameid = as.character(data$gameid[[map_index]]),
        side = side,
        observed = as.numeric(data[[
          paste0(side, "_team_kills")
        ]][[map_index]]),
        observed_duration = as.numeric(
          data$game_length_minutes[[map_index]]
        ),
        base_rate = base_rate,
        win_logit = stats::qlogis(pmin(
          1 - 1e-8,
          pmax(1e-8, side_probability)
        )),
        favorite_imbalance = abs(stats::qlogis(pmin(
          1 - 1e-8,
          pmax(1e-8, data$p_blue[[map_index]])
        ))),
        attack_signal = attack_signal,
        concession_signal = concession_signal,
        stringsAsFactors = FALSE
      )
    }
  }
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

.joint_fit_weighted_linear <- function(x, y, weights) {
  design <- cbind("(Intercept)" = 1, as.matrix(x))
  fit <- stats::lm.wfit(design, y, weights)
  coefficients <- fit$coefficients
  coefficients[!is.finite(coefficients)] <- 0
  list(
    coefficients = coefficients,
    columns = colnames(design)
  )
}

.joint_predict_weighted_linear <- function(fit, x) {
  design <- cbind("(Intercept)" = 1, as.matrix(x))
  missing <- setdiff(fit$columns, colnames(design))
  for (column in missing) {
    design <- cbind(design, 0)
    colnames(design)[[ncol(design)]] <- column
  }
  design <- design[, fit$columns, drop = FALSE]
  as.numeric(design %*% fit$coefficients)
}

#' Fit a continuous moneyline correction around the joint fundamental model
#'
#' @param fundamental Fitted directed fundamental model.
#' @param market_train Maps with no-vig Blue and Red moneyline probabilities.
#' @param shape Linear or quadratic continuous favoritism correction.
#' @param interactions Whether favoritism interacts with attack and concession.
#' @param dispersion_mode Global, favoritism, or favoritism plus team
#'   volatility.
#' @param weights Optional temporal weights.
#' @param seed Reproducibility seed.
#' @return Market-informed joint model.
#' @export
fit_moneyline_joint_correction <- function(
  fundamental,
  market_train,
  shape = c("linear", "quadratic"),
  interactions = FALSE,
  dispersion_mode = c(
    "global",
    "favoritism",
    "favoritism_team_volatility"
  ),
  weights = NULL,
  seed = 20260730L
) {
  shape <- match.arg(shape)
  dispersion_mode <- match.arg(dispersion_mode)
  required <- c("p_blue", "p_red", "game_length_minutes")
  missing <- setdiff(required, names(market_train))
  if (length(missing) > 0L) {
    stop(
      "Moneyline correction is missing: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (nrow(market_train) < 80L) {
    stop("Moneyline correction requires at least 80 maps.", call. = FALSE)
  }
  if (is.null(weights)) {
    weights <- rep(1, nrow(market_train))
  }
  data <- .joint_prepare_map_features(
    market_train,
    fundamental$windows
  )
  base_duration <- predict_regularized_duration_model(
    fundamental$duration,
    data,
    draws = 500L,
    seed = seed
  )
  base_rates <- .joint_predict_rates(
    fundamental$intensity,
    data,
    fundamental$windows
  )
  duration_mean <- vapply(
    base_duration,
    function(item) item$mean,
    numeric(1L)
  )
  duration_x <- data.frame(
    favorite_imbalance = data$favorite_imbalance
  )
  if (shape == "quadratic") {
    duration_x$favorite_imbalance_squared <-
      data$favorite_imbalance_squared
  }
  duration_correction <- .joint_fit_weighted_linear(
    duration_x,
    log(data$game_length_minutes / duration_mean),
    weights
  )
  directed <- .joint_moneyline_directed_data(
    data,
    base_rates,
    fundamental$windows
  )
  correction_x <- .moneyline_correction_features(
    directed,
    shape,
    interactions
  )
  correction_data <- cbind(directed, correction_x)
  correction_terms <- names(correction_x)
  correction_data$log_base_mean <- log(pmax(
    correction_data$base_rate *
      correction_data$observed_duration,
    1e-10
  ))
  formula <- stats::reformulate(
    c(correction_terms, "offset(log_base_mean)"),
    response = "observed"
  )
  intensity_correction <- stats::glm(
    formula,
    family = stats::poisson(link = "log"),
    data = correction_data,
    weights = rep(as.numeric(weights), each = 2L),
    control = stats::glm.control(maxit = 100)
  )
  if (
    !isTRUE(intensity_correction$converged) ||
      any(!is.finite(stats::coef(intensity_correction)))
  ) {
    stop("Moneyline joint correction did not converge.", call. = FALSE)
  }
  duration_scale <- exp(.joint_predict_weighted_linear(
    duration_correction,
    duration_x
  ))
  rate_prediction_data <- correction_data
  rate_prediction_data$log_base_mean <- log(pmax(
    correction_data$base_rate,
    1e-10
  ))
  corrected_rates <- as.numeric(stats::predict(
    intensity_correction,
    newdata = rate_prediction_data,
    type = "response"
  ))
  corrected_blue <- corrected_rates[
    seq.int(1L, length(corrected_rates), by = 2L)
  ]
  corrected_red <- corrected_rates[
    seq.int(2L, length(corrected_rates), by = 2L)
  ]
  corrected_duration <- duration_mean * duration_scale
  total_means <- corrected_duration * (
    corrected_blue + corrected_red
  )
  dispersion <- .joint_fit_dispersion(
    data$total_kills_game,
    total_means,
    data,
    weights,
    dispersion_mode
  )
  blue_share <- corrected_blue / (corrected_blue + corrected_red)
  allocation_concentration <- .premap_fit_allocation_concentration(
    data$blue_team_kills,
    data$total_kills_game,
    blue_share,
    weights
  )
  structure(
    list(
      fundamental = fundamental,
      shape = shape,
      interactions = isTRUE(interactions),
      duration_correction = duration_correction,
      intensity_correction = intensity_correction,
      correction_terms = correction_terms,
      dispersion = dispersion,
      allocation_concentration = allocation_concentration,
      training_maps = nrow(data),
      seed = as.integer(seed)
    ),
    class = "lolkills_moneyline_joint_model"
  )
}

#' Predict from the continuous moneyline-informed joint model
#'
#' @param fit Fitted moneyline joint model.
#' @param new_data Maps with current no-vig moneyline probabilities.
#' @param draws Duration draws per map.
#' @param seed Reproducibility seed.
#' @param tail_tolerance Maximum unrepresented count probability.
#' @return Coherent total and conditional team-kill distributions.
#' @export
predict_moneyline_joint_model <- function(
  fit,
  new_data,
  draws = 2000L,
  seed = fit$seed,
  tail_tolerance = 1e-10
) {
  fundamental <- fit$fundamental
  data <- .joint_prepare_map_features(
    new_data,
    fundamental$windows
  )
  duration_predictions <- predict_regularized_duration_model(
    fundamental$duration,
    data,
    draws = draws,
    seed = seed
  )
  base_rates <- .joint_predict_rates(
    fundamental$intensity,
    data,
    fundamental$windows
  )
  duration_x <- data.frame(
    favorite_imbalance = data$favorite_imbalance
  )
  if (fit$shape == "quadratic") {
    duration_x$favorite_imbalance_squared <-
      data$favorite_imbalance_squared
  }
  duration_scale <- exp(.joint_predict_weighted_linear(
    fit$duration_correction,
    duration_x
  ))
  duration_predictions <- lapply(
    seq_along(duration_predictions),
    function(index) {
      result <- duration_predictions[[index]]
      result$draws <- result$draws * duration_scale[[index]]
      result$mean <- mean(result$draws)
      result$median <- stats::median(result$draws)
      result$sd <- stats::sd(result$draws)
      result
    }
  )
  directed <- .joint_moneyline_directed_data(
    data,
    base_rates,
    fundamental$windows
  )
  correction_x <- .moneyline_correction_features(
    directed,
    fit$shape,
    fit$interactions
  )
  correction_data <- cbind(directed, correction_x)
  correction_data$log_base_mean <- log(pmax(
    correction_data$base_rate,
    1e-10
  ))
  corrected_rates <- as.numeric(stats::predict(
    fit$intensity_correction,
    newdata = correction_data,
    type = "response"
  ))
  rates <- list(
    blue = corrected_rates[
      seq.int(1L, length(corrected_rates), by = 2L)
    ],
    red = corrected_rates[
      seq.int(2L, length(corrected_rates), by = 2L)
    ]
  )
  theta <- .joint_predict_theta(fit$dispersion, data)
  .joint_prediction_from_components(
    duration_predictions,
    rates,
    theta,
    fit$allocation_concentration,
    tail_tolerance
  )
}
