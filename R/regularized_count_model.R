.regularized_design_matrix <- function(
  data,
  feature_names,
  league_levels,
  expected_columns = NULL
) {
  league <- factor(
    as.character(data$league_canonical),
    levels = league_levels
  )
  if (anyNA(league)) {
    stop("Regularized model received an unseen league.", call. = FALSE)
  }
  frame <- data.frame(data[feature_names], check.names = FALSE)
  if (length(league_levels) > 1L) {
    frame$league_canonical <- league
    frame <- frame[c("league_canonical", feature_names)]
  }
  matrix <- stats::model.matrix(
    ~ .,
    data = frame
  )
  matrix <- matrix[, colnames(matrix) != "(Intercept)", drop = FALSE]
  if (!is.null(expected_columns)) {
    missing <- setdiff(expected_columns, colnames(matrix))
    if (length(missing) > 0L) {
      additions <- base::matrix(
        0,
        nrow = nrow(matrix),
        ncol = length(missing),
        dimnames = list(NULL, missing)
      )
      matrix <- cbind(matrix, additions)
    }
    matrix <- matrix[, expected_columns, drop = FALSE]
  }
  matrix
}

.estimate_nb_theta <- function(observed, fitted, weights) {
  residual_excess <- pmax(
    (as.numeric(observed) - as.numeric(fitted))^2 -
      as.numeric(fitted),
    0
  )
  denominator <- sum(weights * residual_excess)
  if (!is.finite(denominator) || denominator <= 0) {
    return(1e6)
  }
  theta <- sum(weights * as.numeric(fitted)^2) / denominator
  pmin(1e6, pmax(0.1, theta))
}

#' Fit a regularized count regression with temporal lambda selection
#'
#' @param train Training maps.
#' @param feature_names Numeric features in addition to league.
#' @param alpha Elastic-net mixing value: zero Ridge, one Lasso.
#' @param weights Non-negative observation weights.
#' @param inner_fraction Fraction reserved as the latest inner validation.
#' @return Fitted regularized probabilistic count model.
#' @export
fit_regularized_count_model <- function(
  train,
  feature_names,
  alpha,
  weights = NULL,
  inner_fraction = 0.2
) {
  if (!requireNamespace("glmnet", quietly = TRUE)) {
    stop("Package glmnet is required.", call. = FALSE)
  }
  required <- c(
    "league_canonical",
    "total_kills_game",
    "game_datetime",
    feature_names
  )
  missing <- setdiff(required, names(train))
  if (length(missing) > 0L) {
    stop(
      "Missing regularized model columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (
    !is.finite(alpha) ||
      alpha < 0 ||
      alpha > 1 ||
      !is.finite(inner_fraction) ||
      inner_fraction <= 0 ||
      inner_fraction >= 0.5
  ) {
    stop("Regularized model parameters are invalid.", call. = FALSE)
  }
  identity_required <- c(
    "league_canonical",
    "total_kills_game",
    "game_datetime"
  )
  complete <- stats::complete.cases(train[identity_required])
  train <- train[complete, , drop = FALSE]
  if (nrow(train) < 100L) {
    stop("Regularized model requires at least 100 complete maps.", call. = FALSE)
  }
  if (is.null(weights)) {
    weights <- rep(1, length(complete))
  }
  weights <- as.numeric(weights)[complete]
  if (
    length(weights) != nrow(train) ||
      any(!is.finite(weights)) ||
      any(weights < 0) ||
      sum(weights) <= 0
  ) {
    stop("Regularized model weights are invalid.", call. = FALSE)
  }
  order_index <- order(train$game_datetime, train$total_kills_game)
  train <- train[order_index, , drop = FALSE]
  weights <- weights[order_index]
  imputation <- vapply(feature_names, function(feature) {
    values <- as.numeric(train[[feature]])
    value <- stats::median(values[is.finite(values)], na.rm = TRUE)
    if (is.finite(value)) value else 0
  }, numeric(1L))
  for (feature in feature_names) {
    values <- as.numeric(train[[feature]])
    values[!is.finite(values)] <- imputation[[feature]]
    train[[feature]] <- values
  }
  league_levels <- sort(unique(as.character(train$league_canonical)))
  x <- .regularized_design_matrix(
    train,
    feature_names,
    league_levels
  )
  observed <- as.numeric(train$total_kills_game)
  inner_size <- max(50L, floor(nrow(train) * inner_fraction))
  split_index <- nrow(train) - inner_size
  if (split_index < 50L) {
    stop("Regularized inner training split is too small.", call. = FALSE)
  }
  inner_train <- seq_len(split_index)
  inner_validation <- seq.int(split_index + 1L, nrow(train))
  path <- glmnet::glmnet(
    x[inner_train, , drop = FALSE],
    observed[inner_train],
    family = "poisson",
    alpha = alpha,
    weights = weights[inner_train],
    standardize = TRUE
  )
  inner_mean <- as.matrix(stats::predict(
    path,
    newx = x[inner_validation, , drop = FALSE],
    type = "response"
  ))
  inner_observed <- observed[inner_validation]
  inner_weights <- weights[inner_validation]
  losses <- vapply(seq_len(ncol(inner_mean)), function(index) {
    mean(
      inner_weights * (
        inner_mean[, index] -
          inner_observed * log(pmax(inner_mean[, index], 1e-12))
      )
    )
  }, numeric(1L))
  selected_lambda <- path$lambda[[which.min(losses)]]
  model <- glmnet::glmnet(
    x,
    observed,
    family = "poisson",
    alpha = alpha,
    lambda = selected_lambda,
    weights = weights,
    standardize = TRUE
  )
  fitted <- as.numeric(stats::predict(
    model,
    newx = x,
    s = selected_lambda,
    type = "response"
  ))
  structure(
    list(
      model = model,
      alpha = alpha,
      lambda = selected_lambda,
      theta = .estimate_nb_theta(observed, fitted, weights),
      feature_names = feature_names,
      imputation = imputation,
      league_levels = league_levels,
      x_columns = colnames(x),
      x_scale = vapply(
        seq_len(ncol(x)),
        function(index) {
          value <- stats::sd(x[, index])
          if (is.finite(value) && value > 0) value else 1
        },
        numeric(1L)
      ),
      inner_loss = min(losses),
      training_games = nrow(train)
    ),
    class = "lolkills_regularized_count_model"
  )
}

#' Predict from a regularized probabilistic count model
#'
#' @param fit Fitted regularized model.
#' @param newdata New map rows.
#' @param tail_tolerance Maximum probability beyond finite PMF support.
#' @return List of count prediction distributions.
#' @export
predict_regularized_count_model <- function(
  fit,
  newdata,
  tail_tolerance = 1e-10
) {
  required <- c("league_canonical", fit$feature_names)
  missing <- setdiff(required, names(newdata))
  if (length(missing) > 0L) {
    stop(
      "Missing regularized prediction columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  prepared <- newdata
  for (feature in fit$feature_names) {
    values <- as.numeric(prepared[[feature]])
    values[!is.finite(values)] <- fit$imputation[[feature]]
    prepared[[feature]] <- values
  }
  x <- .regularized_design_matrix(
    prepared,
    fit$feature_names,
    fit$league_levels,
    expected_columns = fit$x_columns
  )
  means <- as.numeric(stats::predict(
    fit$model,
    newx = x,
    s = fit$lambda,
    type = "response"
  ))
  lapply(means, function(mean) {
    distribution <- make_count_pmf(
      mean,
      distribution = "negative_binomial",
      theta = fit$theta,
      tail_tolerance = tail_tolerance
    )
    list(
      mean = mean,
      theta = fit$theta,
      pmf = distribution$pmf,
      support_max = distribution$support_max,
      tail_mass = distribution$tail_mass
    )
  })
}
