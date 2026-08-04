.prepare_regularized_numeric_features <- function(
  data,
  feature_names,
  imputation = NULL
) {
  result <- data
  if (is.null(imputation)) {
    imputation <- vapply(feature_names, function(feature) {
      values <- suppressWarnings(as.numeric(result[[feature]]))
      value <- stats::median(values[is.finite(values)], na.rm = TRUE)
      if (is.finite(value)) value else 0
    }, numeric(1L))
  }
  for (feature in feature_names) {
    values <- suppressWarnings(as.numeric(result[[feature]]))
    values[!is.finite(values)] <- imputation[[feature]]
    result[[feature]] <- values
  }
  list(data = result, imputation = imputation)
}

.validate_regularized_training <- function(
  train,
  response_names,
  feature_names,
  weights
) {
  required <- c(
    "league_canonical",
    "game_datetime",
    response_names,
    feature_names
  )
  missing <- setdiff(required, names(train))
  if (length(missing) > 0L) {
    stop(
      "Missing coupled-model columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  complete <- stats::complete.cases(
    train[c("league_canonical", "game_datetime", response_names)]
  )
  data <- train[complete, , drop = FALSE]
  if (nrow(data) < 100L) {
    stop("Coupled model requires at least 100 complete maps.", call. = FALSE)
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
    stop("Coupled-model weights are invalid.", call. = FALSE)
  }
  order_index <- order(data$game_datetime)
  list(
    data = data[order_index, , drop = FALSE],
    weights = weights[order_index]
  )
}

#' Fit a regularized probabilistic duration model
#'
#' @param train Training maps.
#' @param feature_names Numeric pre-series duration features.
#' @param alpha Elastic-net mixing value.
#' @param weights Optional non-negative observation weights.
#' @param inner_fraction Latest fraction used to select regularization.
#' @return Fitted lognormal duration model.
#' @export
fit_regularized_duration_model <- function(
  train,
  feature_names,
  alpha = 0,
  weights = NULL,
  inner_fraction = 0.2
) {
  if (!requireNamespace("glmnet", quietly = TRUE)) {
    stop("Package glmnet is required.", call. = FALSE)
  }
  if (
    !is.finite(alpha) ||
      alpha < 0 ||
      alpha > 1 ||
      !is.finite(inner_fraction) ||
      inner_fraction <= 0 ||
      inner_fraction >= 0.5
  ) {
    stop("Duration-model parameters are invalid.", call. = FALSE)
  }
  validated <- .validate_regularized_training(
    train,
    "game_length_minutes",
    feature_names,
    weights
  )
  data <- validated$data
  weights <- validated$weights
  valid_duration <- is.finite(data$game_length_minutes) &
    data$game_length_minutes > 0
  data <- data[valid_duration, , drop = FALSE]
  weights <- weights[valid_duration]
  prepared <- .prepare_regularized_numeric_features(data, feature_names)
  data <- prepared$data
  league_levels <- sort(unique(as.character(data$league_canonical)))
  x <- .regularized_design_matrix(
    data,
    feature_names,
    league_levels
  )
  observed <- log(as.numeric(data$game_length_minutes))
  inner_size <- max(50L, floor(nrow(data) * inner_fraction))
  split_index <- nrow(data) - inner_size
  if (split_index < 50L) {
    stop("Duration inner training split is too small.", call. = FALSE)
  }
  inner_train <- seq_len(split_index)
  inner_validation <- seq.int(split_index + 1L, nrow(data))
  path <- glmnet::glmnet(
    x[inner_train, , drop = FALSE],
    observed[inner_train],
    family = "gaussian",
    alpha = alpha,
    weights = weights[inner_train],
    standardize = TRUE
  )
  inner_log_mean <- as.matrix(stats::predict(
    path,
    newx = x[inner_validation, , drop = FALSE],
    type = "response"
  ))
  inner_observed <- observed[inner_validation]
  inner_weights <- weights[inner_validation]
  losses <- vapply(seq_len(ncol(inner_log_mean)), function(index) {
    stats::weighted.mean(
      (inner_log_mean[, index] - inner_observed)^2,
      inner_weights
    )
  }, numeric(1L))
  selected_index <- which.min(losses)
  selected_lambda <- path$lambda[[selected_index]]
  residuals <- inner_observed - inner_log_mean[, selected_index]
  residual_sd_log <- sqrt(stats::weighted.mean(
    residuals^2,
    inner_weights
  ))
  residual_sd_log <- pmax(residual_sd_log, 0.02)
  model <- glmnet::glmnet(
    x,
    observed,
    family = "gaussian",
    alpha = alpha,
    lambda = selected_lambda,
    weights = weights,
    standardize = TRUE
  )
  structure(
    list(
      model = model,
      alpha = alpha,
      lambda = selected_lambda,
      residual_sd_log = residual_sd_log,
      feature_names = feature_names,
      imputation = prepared$imputation,
      league_levels = league_levels,
      x_columns = colnames(x),
      inner_loss = min(losses),
      training_games = nrow(data)
    ),
    class = "lolkills_regularized_duration_model"
  )
}

#' Predict duration distributions from a regularized model
#'
#' @param fit Fitted duration model.
#' @param newdata New map rows.
#' @param draws Monte Carlo draws per row.
#' @param seed Reproducibility seed.
#' @return List of duration prediction distributions.
#' @export
predict_regularized_duration_model <- function(
  fit,
  newdata,
  draws = 2000L,
  seed = 20260726L
) {
  required <- c("league_canonical", fit$feature_names)
  missing <- setdiff(required, names(newdata))
  if (length(missing) > 0L) {
    stop(
      "Missing duration prediction columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (!is.finite(draws) || draws < 50L) {
    stop("Duration prediction requires at least 50 draws.", call. = FALSE)
  }
  prepared <- .prepare_regularized_numeric_features(
    newdata,
    fit$feature_names,
    fit$imputation
  )$data
  x <- .regularized_design_matrix(
    prepared,
    fit$feature_names,
    fit$league_levels,
    expected_columns = fit$x_columns
  )
  log_means <- as.numeric(stats::predict(
    fit$model,
    newx = x,
    s = fit$lambda,
    type = "response"
  ))
  set.seed(as.integer(seed))
  lapply(seq_along(log_means), function(index) {
    samples <- stats::rlnorm(
      as.integer(draws),
      meanlog = log_means[[index]],
      sdlog = fit$residual_sd_log
    )
    list(
      mean = mean(samples),
      median = stats::median(samples),
      sd = stats::sd(samples),
      draws = samples
    )
  })
}

#' Fit a duration-coupled total-kills model
#'
#' @param train Training maps.
#' @param duration_features Pre-series duration features.
#' @param intensity_features Pre-series kill-intensity features.
#' @param alpha_duration Elastic-net mixing value for duration.
#' @param alpha_intensity Elastic-net mixing value for intensity.
#' @param weights Optional non-negative observation weights.
#' @param inner_fraction Latest fraction used to select regularization.
#' @param couple_duration Whether kill rate may depend on duration.
#' @return Fitted coupled probabilistic model.
#' @export
fit_coupled_kill_model <- function(
  train,
  duration_features,
  intensity_features,
  alpha_duration = 0,
  alpha_intensity = 0,
  weights = NULL,
  inner_fraction = 0.2,
  couple_duration = TRUE
) {
  if (
    !is.finite(alpha_intensity) ||
      alpha_intensity < 0 ||
      alpha_intensity > 1
  ) {
    stop("Intensity alpha is invalid.", call. = FALSE)
  }
  duration <- fit_regularized_duration_model(
    train,
    feature_names = duration_features,
    alpha = alpha_duration,
    weights = weights,
    inner_fraction = inner_fraction
  )
  validated <- .validate_regularized_training(
    train,
    c("game_length_minutes", "total_kills_game"),
    intensity_features,
    weights
  )
  data <- validated$data
  weights <- validated$weights
  valid <- is.finite(data$game_length_minutes) &
    data$game_length_minutes > 0 &
    is.finite(data$total_kills_game) &
    data$total_kills_game >= 0
  data <- data[valid, , drop = FALSE]
  weights <- weights[valid]
  prepared <- .prepare_regularized_numeric_features(
    data,
    intensity_features
  )
  data <- prepared$data
  model_features <- intensity_features
  if (isTRUE(couple_duration)) {
    data$log_duration <- log(as.numeric(data$game_length_minutes))
    model_features <- c(model_features, "log_duration")
  }
  league_levels <- sort(unique(as.character(data$league_canonical)))
  x <- .regularized_design_matrix(
    data,
    model_features,
    league_levels
  )
  observed <- as.numeric(data$total_kills_game)
  offset <- log(as.numeric(data$game_length_minutes))
  inner_size <- max(50L, floor(nrow(data) * inner_fraction))
  split_index <- nrow(data) - inner_size
  if (split_index < 50L) {
    stop("Intensity inner training split is too small.", call. = FALSE)
  }
  inner_train <- seq_len(split_index)
  inner_validation <- seq.int(split_index + 1L, nrow(data))
  path <- glmnet::glmnet(
    x[inner_train, , drop = FALSE],
    observed[inner_train],
    family = "poisson",
    alpha = alpha_intensity,
    weights = weights[inner_train],
    offset = offset[inner_train],
    standardize = TRUE
  )
  inner_mean <- as.matrix(stats::predict(
    path,
    newx = x[inner_validation, , drop = FALSE],
    type = "response",
    newoffset = offset[inner_validation]
  ))
  inner_observed <- observed[inner_validation]
  inner_weights <- weights[inner_validation]
  losses <- vapply(seq_len(ncol(inner_mean)), function(index) {
    stats::weighted.mean(
      inner_mean[, index] -
        inner_observed * log(pmax(inner_mean[, index], 1e-12)),
      inner_weights
    )
  }, numeric(1L))
  selected_lambda <- path$lambda[[which.min(losses)]]
  model <- glmnet::glmnet(
    x,
    observed,
    family = "poisson",
    alpha = alpha_intensity,
    lambda = selected_lambda,
    weights = weights,
    offset = offset,
    standardize = TRUE
  )
  fitted <- as.numeric(stats::predict(
    model,
    newx = x,
    s = selected_lambda,
    type = "response",
    newoffset = offset
  ))
  coefficients <- as.matrix(stats::coef(model, s = selected_lambda))
  duration_coupling <- if (
    isTRUE(couple_duration) &&
      "log_duration" %in% rownames(coefficients)
  ) {
    as.numeric(coefficients["log_duration", 1L])
  } else {
    0
  }
  structure(
    list(
      duration = duration,
      intensity_model = model,
      alpha_intensity = alpha_intensity,
      lambda = selected_lambda,
      theta = .estimate_nb_theta(observed, fitted, weights),
      intensity_features = intensity_features,
      model_features = model_features,
      intensity_imputation = prepared$imputation,
      league_levels = league_levels,
      x_columns = colnames(x),
      duration_coupling = duration_coupling,
      couple_duration = isTRUE(couple_duration),
      inner_loss = min(losses),
      training_games = nrow(data)
    ),
    class = "lolkills_coupled_kill_model"
  )
}

#' Predict a total-kills PMF while integrating duration uncertainty
#'
#' @param fit Fitted coupled model.
#' @param newdata New map rows.
#' @param draws Monte Carlo draws per row.
#' @param seed Reproducibility seed.
#' @param tail_tolerance Maximum probability beyond finite PMF support.
#' @return List of total-kills prediction distributions.
#' @export
predict_coupled_kill_model <- function(
  fit,
  newdata,
  draws = 2000L,
  seed = 20260726L,
  tail_tolerance = 1e-10
) {
  required <- c("league_canonical", fit$intensity_features)
  missing <- setdiff(required, names(newdata))
  if (length(missing) > 0L) {
    stop(
      "Missing coupled prediction columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  durations <- predict_regularized_duration_model(
    fit$duration,
    newdata,
    draws = draws,
    seed = seed
  )
  prepared <- .prepare_regularized_numeric_features(
    newdata,
    fit$intensity_features,
    fit$intensity_imputation
  )$data
  duration_matrix <- do.call(rbind, lapply(
    durations,
    function(item) item$draws
  ))
  row_index <- rep(seq_len(nrow(prepared)), each = ncol(duration_matrix))
  duration_vector <- as.vector(t(duration_matrix))
  repeated <- prepared[row_index, , drop = FALSE]
  if (isTRUE(fit$couple_duration)) {
    repeated$log_duration <- log(duration_vector)
  }
  x <- .regularized_design_matrix(
    repeated,
    fit$model_features,
    fit$league_levels,
    expected_columns = fit$x_columns
  )
  all_means <- as.numeric(stats::predict(
    fit$intensity_model,
    newx = x,
    s = fit$lambda,
    type = "response",
    newoffset = log(duration_vector)
  ))
  mean_groups <- split(all_means, row_index)
  lapply(seq_len(nrow(prepared)), function(index) {
    duration_draws <- durations[[index]]$draws
    means <- as.numeric(mean_groups[[as.character(index)]])
    support_max <- max(stats::qnbinom(
      1 - tail_tolerance,
      size = fit$theta,
      mu = means
    ))
    support <- seq.int(0L, as.integer(support_max))
    mass <- rowMeans(vapply(
      means,
      function(mu) {
        stats::dnbinom(support, size = fit$theta, mu = mu)
      },
      numeric(length(support))
    ))
    tail_mass <- mean(stats::pnbinom(
      support_max,
      size = fit$theta,
      mu = means,
      lower.tail = FALSE
    ))
    normalized <- mass / sum(mass)
    list(
      mean = mean(means),
      pmf = normalized,
      support_max = as.integer(support_max),
      tail_mass = tail_mass,
      duration_mean = durations[[index]]$mean,
      duration_sd = durations[[index]]$sd,
      duration_lower_90 = as.numeric(stats::quantile(
        duration_draws,
        0.05,
        names = FALSE
      )),
      duration_upper_90 = as.numeric(stats::quantile(
        duration_draws,
        0.95,
        names = FALSE
      )),
      intensity_per_minute = mean(means / duration_draws),
      duration_coupling = fit$duration_coupling
    )
  })
}
