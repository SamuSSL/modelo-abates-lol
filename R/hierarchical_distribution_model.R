.hierarchical_team_keys <- function(data, side) {
  identifier <- as.character(data[[paste0(side, "_team_id")]])
  name <- as.character(data[[paste0(side, "_team_name")]])
  has_identifier <- !is.na(identifier) & nzchar(identifier)
  ifelse(
    has_identifier,
    paste0("id:", identifier),
    paste0("name:", tolower(trimws(name)))
  )
}

.prepare_hierarchical_frame <- function(
  data,
  numeric_features,
  preprocessing = NULL
) {
  required <- c(
    "league_canonical",
    "blue_team_id",
    "blue_team_name",
    "red_team_id",
    "red_team_name",
    numeric_features
  )
  missing <- setdiff(required, names(data))
  if (length(missing) > 0L) {
    stop(
      "Missing hierarchical model columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  result <- data
  blue_keys <- .hierarchical_team_keys(result, "blue")
  red_keys <- .hierarchical_team_keys(result, "red")
  if (is.null(preprocessing)) {
    imputation <- vapply(numeric_features, function(feature) {
      values <- suppressWarnings(as.numeric(result[[feature]]))
      value <- stats::median(values[is.finite(values)], na.rm = TRUE)
      if (is.finite(value)) value else 0
    }, numeric(1L))
    centers <- vapply(numeric_features, function(feature) {
      values <- suppressWarnings(as.numeric(result[[feature]]))
      values[!is.finite(values)] <- imputation[[feature]]
      mean(values)
    }, numeric(1L))
    scales <- vapply(numeric_features, function(feature) {
      values <- suppressWarnings(as.numeric(result[[feature]]))
      values[!is.finite(values)] <- imputation[[feature]]
      value <- stats::sd(values)
      if (is.finite(value) && value > 0) value else 1
    }, numeric(1L))
    preprocessing <- list(
      imputation = imputation,
      centers = centers,
      scales = scales,
      league_levels = sort(unique(as.character(
        result$league_canonical
      ))),
      team_levels = sort(unique(c(blue_keys, red_keys)))
    )
  }
  for (feature in numeric_features) {
    values <- suppressWarnings(as.numeric(result[[feature]]))
    values[!is.finite(values)] <-
      preprocessing$imputation[[feature]]
    result[[feature]] <- (
      values - preprocessing$centers[[feature]]
    ) / preprocessing$scales[[feature]]
  }
  league <- as.character(result$league_canonical)
  if (any(!league %in% preprocessing$league_levels)) {
    stop("Hierarchical model received an unseen league.", call. = FALSE)
  }
  unknown_blue <- !blue_keys %in% preprocessing$team_levels
  unknown_red <- !red_keys %in% preprocessing$team_levels
  blue_keys[unknown_blue] <- preprocessing$team_levels[[1L]]
  red_keys[unknown_red] <- preprocessing$team_levels[[1L]]
  result$league_canonical <- factor(
    league,
    levels = preprocessing$league_levels
  )
  result$blue_team_factor <- factor(
    blue_keys,
    levels = preprocessing$team_levels
  )
  result$red_team_factor <- factor(
    red_keys,
    levels = preprocessing$team_levels
  )
  list(
    data = result,
    preprocessing = preprocessing,
    unknown_blue = unknown_blue,
    unknown_red = unknown_red
  )
}

.hierarchical_mean_formula <- function(
  smooth_features,
  interaction_pairs,
  include_team_effects
) {
  smooth_terms <- paste0(
    "s(",
    smooth_features,
    ", k = 5, bs = 'cr')"
  )
  interaction_terms <- vapply(interaction_pairs, function(pair) {
    if (length(pair) != 2L) {
      stop(
        "Each hierarchical interaction requires two features.",
        call. = FALSE
      )
    }
    paste0(
      "ti(",
      pair[[1L]],
      ", ",
      pair[[2L]],
      ", k = c(4, 4), bs = c('cr', 'cr'))"
    )
  }, character(1L))
  hierarchy_terms <- if (isTRUE(include_team_effects)) {
    c(
      "s(blue_team_factor, bs = 're')",
      "s(red_team_factor, bs = 're')"
    )
  } else {
    character()
  }
  stats::as.formula(paste(
    "total_kills_game ~ league_canonical +",
    paste(
      c(smooth_terms, interaction_terms, hierarchy_terms),
      collapse = " + "
    )
  ))
}

.fit_hierarchical_mean_component <- function(
  data,
  smooth_features,
  interaction_pairs,
  weights,
  include_team_effects
) {
  numeric_features <- unique(c(
    smooth_features,
    unlist(interaction_pairs, use.names = FALSE)
  ))
  prepared <- .prepare_hierarchical_frame(
    data,
    numeric_features
  )
  observation_weights <- as.numeric(weights)
  model_formula <- .hierarchical_mean_formula(
    smooth_features,
    interaction_pairs,
    include_team_effects
  )
  environment(model_formula) <- environment()
  model <- mgcv::bam(
    model_formula,
    data = prepared$data,
    family = mgcv::nb(link = "log"),
    weights = observation_weights,
    method = "fREML",
    discrete = TRUE,
    select = TRUE,
    drop.unused.levels = FALSE,
    nthreads = 1L
  )
  smooth_labels <- vapply(
    model$smooth,
    function(smooth) smooth$label,
    character(1L)
  )
  names(model$smooth) <- smooth_labels
  list(
    model = model,
    preprocessing = prepared$preprocessing,
    numeric_features = numeric_features,
    include_team_effects = include_team_effects
  )
}

.predict_hierarchical_mean_link <- function(component, newdata) {
  prepared <- .prepare_hierarchical_frame(
    newdata,
    component$numeric_features,
    component$preprocessing
  )
  terms <- stats::predict(
    component$model,
    newdata = prepared$data,
    type = "terms"
  )
  if (is.null(dim(terms))) {
    terms <- matrix(terms, nrow = nrow(prepared$data))
  }
  if (isTRUE(component$include_team_effects)) {
    blue_column <- grep(
      "^s\\(blue_team_factor\\)",
      colnames(terms)
    )
    red_column <- grep(
      "^s\\(red_team_factor\\)",
      colnames(terms)
    )
    if (length(blue_column) == 1L) {
      terms[prepared$unknown_blue, blue_column] <- 0
    }
    if (length(red_column) == 1L) {
      terms[prepared$unknown_red, red_column] <- 0
    }
  }
  constant <- attr(terms, "constant")
  if (is.null(constant) || !is.finite(constant)) {
    constant <- stats::coef(component$model)[["(Intercept)"]]
  }
  as.numeric(constant + rowSums(terms))
}

.hierarchical_global_theta <- function(mean_component) {
  theta <- mean_component$model$family$getTheta(TRUE)
  pmin(1e6, pmax(0.1, as.numeric(theta)))
}

.prepare_dispersion_frame <- function(
  data,
  predicted_mean,
  dispersion_features,
  preprocessing = NULL,
  target = NULL
) {
  required <- c("league_canonical", dispersion_features)
  missing <- setdiff(required, names(data))
  if (length(missing) > 0L) {
    stop(
      "Missing dispersion columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  result <- data
  if (is.null(preprocessing)) {
    imputation <- vapply(dispersion_features, function(feature) {
      values <- suppressWarnings(as.numeric(result[[feature]]))
      value <- stats::median(values[is.finite(values)], na.rm = TRUE)
      if (is.finite(value)) value else 0
    }, numeric(1L))
    centers <- vapply(dispersion_features, function(feature) {
      values <- suppressWarnings(as.numeric(result[[feature]]))
      values[!is.finite(values)] <- imputation[[feature]]
      mean(values)
    }, numeric(1L))
    scales <- vapply(dispersion_features, function(feature) {
      values <- suppressWarnings(as.numeric(result[[feature]]))
      values[!is.finite(values)] <- imputation[[feature]]
      value <- stats::sd(values)
      if (is.finite(value) && value > 0) value else 1
    }, numeric(1L))
    preprocessing <- list(
      imputation = imputation,
      centers = centers,
      scales = scales,
      league_levels = sort(unique(as.character(
        result$league_canonical
      )))
    )
  }
  for (feature in dispersion_features) {
    values <- suppressWarnings(as.numeric(result[[feature]]))
    values[!is.finite(values)] <-
      preprocessing$imputation[[feature]]
    result[[feature]] <- (
      values - preprocessing$centers[[feature]]
    ) / preprocessing$scales[[feature]]
  }
  league <- as.character(result$league_canonical)
  if (any(!league %in% preprocessing$league_levels)) {
    stop("Dispersion model received an unseen league.", call. = FALSE)
  }
  result$league_canonical <- factor(
    league,
    levels = preprocessing$league_levels
  )
  result$log_prediction_mean <- log(pmax(predicted_mean, 0.1))
  if (!is.null(target)) {
    result$variance_multiplier <- target
  }
  list(data = result, preprocessing = preprocessing)
}

.dispersion_formula <- function(dispersion_features) {
  smooth_terms <- c(
    "s(log_prediction_mean, k = 5, bs = 'cr')",
    paste0(
      "s(",
      dispersion_features,
      ", k = 4, bs = 'cr')"
    )
  )
  stats::as.formula(paste(
    "variance_multiplier ~ league_canonical +",
    paste(smooth_terms, collapse = " + ")
  ))
}

.fit_dispersion_component <- function(
  data,
  predicted_mean,
  observed,
  dispersion_features,
  weights
) {
  raw_target <- (
    as.numeric(observed) - as.numeric(predicted_mean)
  )^2 / pmax(as.numeric(predicted_mean), 0.1)
  finite_target <- raw_target[is.finite(raw_target)]
  limits <- stats::quantile(
    finite_target,
    c(0.02, 0.98),
    names = FALSE,
    type = 8
  )
  target <- pmin(
    limits[[2L]],
    pmax(limits[[1L]], raw_target)
  )
  target <- pmax(target, 0.02)
  prepared <- .prepare_dispersion_frame(
    data,
    predicted_mean,
    dispersion_features,
    target = target
  )
  observation_weights <- as.numeric(weights)
  model_formula <- .dispersion_formula(dispersion_features)
  environment(model_formula) <- environment()
  model <- mgcv::gam(
    model_formula,
    data = prepared$data,
    family = stats::Gamma(link = "log"),
    weights = observation_weights,
    method = "REML",
    select = TRUE,
    drop.unused.levels = FALSE
  )
  list(
    model = model,
    preprocessing = prepared$preprocessing,
    dispersion_features = dispersion_features,
    target_limits = limits
  )
}

.predict_variance_multiplier <- function(component, newdata, mean) {
  prepared <- .prepare_dispersion_frame(
    newdata,
    mean,
    component$dispersion_features,
    component$preprocessing
  )
  prediction <- as.numeric(stats::predict(
    component$model,
    newdata = prepared$data,
    type = "response"
  ))
  pmin(50, pmax(1.01, prediction))
}

.theta_from_multiplier <- function(mean, multiplier) {
  theta <- as.numeric(mean) / pmax(as.numeric(multiplier) - 1, 0.01)
  pmin(1e6, pmax(0.1, theta))
}

.blend_theta <- function(
  local_theta,
  global_theta,
  blend,
  scale
) {
  inverse_theta <- blend / as.numeric(local_theta) +
    (1 - blend) / as.numeric(global_theta)
  theta <- scale / inverse_theta
  pmin(1e6, pmax(0.1, theta))
}

.score_theta_configuration <- function(
  observed,
  mean,
  local_theta,
  global_theta,
  blend,
  scale
) {
  theta <- .blend_theta(
    local_theta,
    global_theta,
    blend,
    scale
  )
  scores <- lapply(seq_along(mean), function(index) {
    distribution <- make_count_pmf(
      mean[[index]],
      "negative_binomial",
      theta = theta[[index]]
    )
    probability <- if (
      observed[[index]] < length(distribution$pmf)
    ) {
      distribution$pmf[[observed[[index]] + 1L]]
    } else {
      0
    }
    c(
      crps = discrete_crps(
        distribution$pmf,
        observed[[index]]
      ),
      log_score = -log(max(probability, 1e-12))
    )
  })
  matrix <- do.call(rbind, scores)
  c(
    crps = mean(matrix[, "crps"]),
    log_score = mean(matrix[, "log_score"])
  )
}

#' Fit a nonlinear hierarchical distribution model
#'
#' @param train Training maps.
#' @param smooth_features Numeric features receiving nonlinear smooths.
#' @param interaction_pairs List of two-feature nonlinear interactions.
#' @param dispersion_features Features used to predict conditional dispersion.
#' @param weights Optional non-negative temporal weights.
#' @param inner_fraction Latest fraction reserved for dispersion learning.
#' @param include_team_effects Whether to fit shrunken Blue and Red team effects.
#' @param dispersion_blend_grid Candidate weights for local dispersion.
#' @param theta_scale_grid Candidate multiplicative theta calibration.
#' @return Fitted nonlinear hierarchical distribution model.
#' @export
fit_hierarchical_distribution_model <- function(
  train,
  smooth_features,
  interaction_pairs = list(),
  dispersion_features,
  weights = NULL,
  inner_fraction = 0.30,
  include_team_effects = TRUE,
  dispersion_blend_grid = c(0, 0.25, 0.5, 0.75, 1),
  theta_scale_grid = c(0.75, 1, 1.5, 2)
) {
  if (!requireNamespace("mgcv", quietly = TRUE)) {
    stop("Package mgcv is required.", call. = FALSE)
  }
  all_features <- unique(c(
    smooth_features,
    unlist(interaction_pairs, use.names = FALSE),
    dispersion_features
  ))
  required <- c(
    "game_datetime",
    "total_kills_game",
    "league_canonical",
    "blue_team_id",
    "blue_team_name",
    "red_team_id",
    "red_team_name",
    all_features
  )
  missing <- setdiff(required, names(train))
  if (length(missing) > 0L) {
    stop(
      "Missing hierarchical training columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  complete <- stats::complete.cases(train[c(
    "game_datetime",
    "total_kills_game",
    "league_canonical"
  )])
  data <- train[complete, , drop = FALSE]
  if (nrow(data) < 240L) {
    stop(
      "Hierarchical distribution model requires at least 240 maps.",
      call. = FALSE
    )
  }
  if (
    !is.finite(inner_fraction) ||
      inner_fraction < 0.20 ||
      inner_fraction > 0.45
  ) {
    stop("Hierarchical inner fraction is invalid.", call. = FALSE)
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
    stop("Hierarchical model weights are invalid.", call. = FALSE)
  }
  order_index <- order(data$game_datetime)
  data <- data[order_index, , drop = FALSE]
  weights <- weights[order_index]
  residual_size <- max(100L, floor(nrow(data) * inner_fraction))
  pilot_end <- nrow(data) - residual_size
  dispersion_size <- floor(residual_size / 2)
  if (pilot_end < 120L || dispersion_size < 50L) {
    stop("Hierarchical temporal partitions are too small.", call. = FALSE)
  }
  pilot_rows <- seq_len(pilot_end)
  residual_rows <- seq.int(pilot_end + 1L, nrow(data))
  dispersion_rows <- residual_rows[seq_len(dispersion_size)]
  calibration_rows <- residual_rows[
    seq.int(dispersion_size + 1L, length(residual_rows))
  ]
  pilot <- .fit_hierarchical_mean_component(
    data[pilot_rows, , drop = FALSE],
    smooth_features,
    interaction_pairs,
    weights[pilot_rows],
    include_team_effects
  )
  residual_mean <- exp(.predict_hierarchical_mean_link(
    pilot,
    data[residual_rows, , drop = FALSE]
  ))
  dispersion_fit_index <- seq_len(dispersion_size)
  calibration_index <- seq.int(
    dispersion_size + 1L,
    length(residual_rows)
  )
  preliminary_dispersion <- .fit_dispersion_component(
    data[dispersion_rows, , drop = FALSE],
    residual_mean[dispersion_fit_index],
    data$total_kills_game[dispersion_rows],
    dispersion_features,
    weights[dispersion_rows]
  )
  calibration_mean <- residual_mean[calibration_index]
  calibration_multiplier <- .predict_variance_multiplier(
    preliminary_dispersion,
    data[calibration_rows, , drop = FALSE],
    calibration_mean
  )
  calibration_local_theta <- .theta_from_multiplier(
    calibration_mean,
    calibration_multiplier
  )
  pilot_global_theta <- .hierarchical_global_theta(pilot)
  configurations <- expand.grid(
    blend = dispersion_blend_grid,
    scale = theta_scale_grid,
    KEEP.OUT.ATTRS = FALSE,
    stringsAsFactors = FALSE
  )
  configuration_scores <- t(vapply(
    seq_len(nrow(configurations)),
    function(index) {
      .score_theta_configuration(
        as.integer(data$total_kills_game[calibration_rows]),
        calibration_mean,
        calibration_local_theta,
        pilot_global_theta,
        configurations$blend[[index]],
        configurations$scale[[index]]
      )
    },
    numeric(2L)
  ))
  configurations$crps <- configuration_scores[, "crps"]
  configurations$log_score <- configuration_scores[, "log_score"]
  selected <- configurations[
    order(configurations$crps, configurations$log_score),
    ,
    drop = FALSE
  ][1L, , drop = FALSE]
  final_mean <- .fit_hierarchical_mean_component(
    data,
    smooth_features,
    interaction_pairs,
    weights,
    include_team_effects
  )
  final_dispersion <- .fit_dispersion_component(
    data[residual_rows, , drop = FALSE],
    residual_mean,
    data$total_kills_game[residual_rows],
    dispersion_features,
    weights[residual_rows]
  )
  structure(
    list(
      mean_model = final_mean$model,
      mean_component = final_mean,
      dispersion_model = final_dispersion$model,
      dispersion_component = final_dispersion,
      global_theta = .hierarchical_global_theta(final_mean),
      dispersion_blend = selected$blend[[1L]],
      theta_scale = selected$scale[[1L]],
      smooth_features = smooth_features,
      interaction_pairs = interaction_pairs,
      dispersion_features = dispersion_features,
      include_team_effects = include_team_effects,
      tuning_results = configurations,
      inner_crps = selected$crps[[1L]],
      inner_log_score = selected$log_score[[1L]],
      training_games = nrow(data)
    ),
    class = "lolkills_hierarchical_distribution_model"
  )
}

#' Predict row-specific count distributions from a hierarchical model
#'
#' @param fit Fitted hierarchical distribution model.
#' @param newdata New map rows.
#' @param dispersion_mode `tuned`, `global`, or `local`.
#' @param tail_tolerance Maximum probability beyond finite PMF support.
#' @return List of row-specific total-kills distributions.
#' @export
predict_hierarchical_distribution_model <- function(
  fit,
  newdata,
  dispersion_mode = c("tuned", "global", "local"),
  tail_tolerance = 1e-10
) {
  dispersion_mode <- match.arg(dispersion_mode)
  mean <- exp(.predict_hierarchical_mean_link(
    fit$mean_component,
    newdata
  ))
  multiplier <- .predict_variance_multiplier(
    fit$dispersion_component,
    newdata,
    mean
  )
  local_theta <- .theta_from_multiplier(mean, multiplier)
  blend <- switch(
    dispersion_mode,
    tuned = fit$dispersion_blend,
    global = 0,
    local = 1
  )
  theta <- .blend_theta(
    local_theta,
    fit$global_theta,
    blend,
    fit$theta_scale
  )
  lapply(seq_along(mean), function(index) {
    distribution <- make_count_pmf(
      mean[[index]],
      distribution = "negative_binomial",
      theta = theta[[index]],
      tail_tolerance = tail_tolerance
    )
    list(
      mean = mean[[index]],
      theta = theta[[index]],
      variance_multiplier = multiplier[[index]],
      dispersion_blend = blend,
      pmf = distribution$pmf,
      support_max = distribution$support_max,
      tail_mass = distribution$tail_mass
    )
  })
}
