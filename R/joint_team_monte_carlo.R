.first_existing_column <- function(data, candidates) {
  found <- candidates[candidates %in% names(data)]
  if (length(found) == 0L) {
    return(NULL)
  }
  found[[1L]]
}

.map_identity_column <- function(data, side, field) {
  prefix <- tolower(side)
  .first_existing_column(
    data,
    c(
      paste0(prefix, "_team_", field),
      paste0(prefix, "_team_", field, ".x"),
      paste0(prefix, "_team_", field, ".y")
    )
  )
}

.directed_numeric_pairs <- function() {
  list(
    own_attack_rate = c(
      "blue_hist_kills_per_minute",
      "red_hist_kills_per_minute"
    ),
    own_exposure_rate = c(
      "blue_hist_deaths_per_minute",
      "red_hist_deaths_per_minute"
    ),
    own_combined_kill_rate = c(
      "blue_hist_combined_kills_per_minute",
      "red_hist_combined_kills_per_minute"
    ),
    own_duration_history = c(
      "blue_hist_game_length_minutes",
      "red_hist_game_length_minutes"
    ),
    own_rating_attack_league = c(
      "blue_rating_attack_league",
      "red_rating_attack_league"
    ),
    own_rating_attack_global = c(
      "blue_rating_attack_global",
      "red_rating_attack_global"
    ),
    own_rating_defense_league = c(
      "blue_rating_defense_league",
      "red_rating_defense_league"
    ),
    own_rating_defense_global = c(
      "blue_rating_defense_global",
      "red_rating_defense_global"
    ),
    own_momentum_attack = c(
      "blue_momentum_attack",
      "red_momentum_attack"
    ),
    own_momentum_mortality = c(
      "blue_momentum_mortality",
      "red_momentum_mortality"
    ),
    own_momentum_bloodiness = c(
      "blue_momentum_bloodiness",
      "red_momentum_bloodiness"
    ),
    own_aggression_ahead = c(
      "blue_aggression_ahead_league",
      "red_aggression_ahead_league"
    ),
    own_aggression_behind = c(
      "blue_aggression_behind_league",
      "red_aggression_behind_league"
    ),
    own_snowball_index = c(
      "blue_snowball_index_league",
      "red_snowball_index_league"
    )
  )
}

#' Build one directed observation for each team in a map
#'
#' @param maps One row per map with Blue and Red outcomes and frozen features.
#' @return Two rows per map, one from each team's point of view.
#' @export
build_directed_team_maps <- function(maps) {
  required <- c(
    "gameid",
    "league_canonical",
    "game_datetime",
    "blue_kills",
    "red_kills",
    "total_kills_game",
    "game_length_minutes"
  )
  identity <- c(
    .map_identity_column(maps, "blue", "id"),
    .map_identity_column(maps, "red", "id"),
    .map_identity_column(maps, "blue", "name"),
    .map_identity_column(maps, "red", "name")
  )
  missing <- setdiff(required, names(maps))
  if (length(missing) > 0L || any(vapply(identity, is.null, logical(1L)))) {
    stop("Map data are missing directed-team columns.", call. = FALSE)
  }
  if (
    nrow(maps) == 0L ||
      anyDuplicated(as.character(maps$gameid)) ||
      any(maps$blue_kills + maps$red_kills != maps$total_kills_game)
  ) {
    stop("Map rows must be unique and have coherent kill totals.", call. = FALSE)
  }
  blue_id <- .map_identity_column(maps, "blue", "id")
  red_id <- .map_identity_column(maps, "red", "id")
  blue_name <- .map_identity_column(maps, "blue", "name")
  red_name <- .map_identity_column(maps, "red", "name")
  generic_names <- names(maps)[
    !grepl("^(blue|red)_", names(maps)) &
      !grepl("player", names(maps), ignore.case = TRUE)
  ]
  generic <- maps[generic_names]
  make_side <- function(side) {
    is_blue <- identical(side, "Blue")
    own_index <- if (is_blue) 1L else 2L
    opponent_index <- if (is_blue) 2L else 1L
    result <- generic
    result$map_row <- seq_len(nrow(maps))
    result$side <- side
    result$team_id <- as.character(maps[[
      if (is_blue) blue_id else red_id
    ]])
    result$opponent_id <- as.character(maps[[
      if (is_blue) red_id else blue_id
    ]])
    result$team_name <- as.character(maps[[
      if (is_blue) blue_name else red_name
    ]])
    result$opponent_name <- as.character(maps[[
      if (is_blue) red_name else blue_name
    ]])
    result$team_kills <- as.integer(
      if (is_blue) maps$blue_kills else maps$red_kills
    )
    result$opponent_kills <- as.integer(
      if (is_blue) maps$red_kills else maps$blue_kills
    )
    pairs <- .directed_numeric_pairs()
    for (output in names(pairs)) {
      sources <- pairs[[output]]
      if (all(sources %in% names(maps))) {
        result[[output]] <- as.numeric(maps[[sources[[own_index]]]])
        opponent_output <- sub("^own_", "opponent_", output)
        result[[opponent_output]] <- as.numeric(
          maps[[sources[[opponent_index]]]]
        )
      }
    }
    side_draft <- grep(
      paste0("^", tolower(side), "_draft_"),
      names(maps),
      value = TRUE
    )
    opponent_side <- if (is_blue) "red" else "blue"
    for (source in side_draft) {
      base <- sub(
        paste0("^", tolower(side), "_draft_"),
        "",
        source
      )
      opponent_source <- paste0(opponent_side, "_draft_", base)
      result[[paste0("draft_", base, "_own")]] <-
        as.numeric(maps[[source]])
      if (opponent_source %in% names(maps)) {
        result[[paste0("draft_", base, "_opponent")]] <-
          as.numeric(maps[[opponent_source]])
      }
    }
    result
  }
  result <- rbind(make_side("Blue"), make_side("Red"))
  result <- result[order(result$map_row, result$side), , drop = FALSE]
  rownames(result) <- NULL
  if (
    any(table(result$gameid) != 2L) ||
      any(result$team_kills + result$opponent_kills !=
        result$total_kills_game)
  ) {
    stop("Directed-team construction failed its identity checks.", call. = FALSE)
  }
  result
}

.prepare_directed_features <- function(
  data,
  feature_names,
  imputation = NULL
) {
  missing <- setdiff(feature_names, names(data))
  if (length(missing) > 0L) {
    stop(
      "Missing directed numeric features: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  result <- data
  if (is.null(imputation)) {
    imputation <- vapply(feature_names, function(feature) {
      values <- suppressWarnings(as.numeric(result[[feature]]))
      center <- stats::median(values[is.finite(values)], na.rm = TRUE)
      if (is.finite(center)) center else 0
    }, numeric(1L))
  }
  for (feature in feature_names) {
    values <- suppressWarnings(as.numeric(result[[feature]]))
    values[!is.finite(values)] <- imputation[[feature]]
    result[[feature]] <- values
  }
  list(data = result, imputation = imputation)
}

.directed_design_matrix <- function(
  data,
  feature_names,
  league_levels,
  team_levels,
  include_team_effects,
  expected_columns = NULL
) {
  normalize_entity <- function(values) {
    values <- as.character(values)
    values[!values %in% team_levels] <- "__OTHER__"
    factor(values, levels = team_levels)
  }
  frame <- data.frame(
    league = factor(
      as.character(data$league_canonical),
      levels = league_levels
    ),
    side = factor(as.character(data$side), levels = c("Blue", "Red")),
    data[feature_names],
    check.names = FALSE
  )
  if (isTRUE(include_team_effects)) {
    frame$team <- normalize_entity(data$team_id)
    frame$opponent <- normalize_entity(data$opponent_id)
  }
  if (anyNA(frame$league) || anyNA(frame$side)) {
    stop("Directed model received an unseen league or side.", call. = FALSE)
  }
  terms <- c(
    "league",
    "side",
    if (isTRUE(include_team_effects)) c("team", "opponent"),
    feature_names
  )
  formula <- stats::reformulate(terms, intercept = FALSE)
  matrix <- stats::model.matrix(formula, data = frame)
  if (!is.null(expected_columns)) {
    missing <- setdiff(expected_columns, colnames(matrix))
    if (length(missing) > 0L) {
      matrix <- cbind(
        matrix,
        base::matrix(
          0,
          nrow = nrow(matrix),
          ncol = length(missing),
          dimnames = list(NULL, missing)
        )
      )
    }
    matrix <- matrix[, expected_columns, drop = FALSE]
  }
  matrix
}

.midpoint_nb_pit <- function(observed, mean, theta) {
  lower <- stats::pnbinom(
    observed - 1L,
    size = theta,
    mu = mean
  )
  upper <- stats::pnbinom(
    observed,
    size = theta,
    mu = mean
  )
  pmin(1 - 1e-8, pmax(1e-8, (lower + upper) / 2))
}

.fit_directed_team_rate_model <- function(
  directed,
  feature_names,
  weights,
  alpha,
  inner_fraction,
  include_team_effects
) {
  if (!requireNamespace("glmnet", quietly = TRUE)) {
    stop("Package glmnet is required.", call. = FALSE)
  }
  required <- c(
    "gameid",
    "game_datetime",
    "league_canonical",
    "side",
    "team_id",
    "opponent_id",
    "team_kills",
    "game_length_minutes"
  )
  missing <- setdiff(required, names(directed))
  if (length(missing) > 0L) {
    stop("Directed training data are incomplete.", call. = FALSE)
  }
  complete <- stats::complete.cases(directed[required]) &
    directed$team_kills >= 0 &
    directed$game_length_minutes > 0
  data <- directed[complete, , drop = FALSE]
  weights <- as.numeric(weights)[complete]
  if (
    nrow(data) < 200L ||
      length(weights) != nrow(data) ||
      any(!is.finite(weights)) ||
      any(weights < 0) ||
      sum(weights) <= 0
  ) {
    stop("Directed model requires at least 100 complete maps.", call. = FALSE)
  }
  order_index <- order(data$game_datetime, data$gameid, data$side)
  data <- data[order_index, , drop = FALSE]
  weights <- weights[order_index]
  prepared <- .prepare_directed_features(data, feature_names)
  data <- prepared$data
  league_levels <- sort(unique(as.character(data$league_canonical)))
  team_levels <- c(
    sort(unique(c(
      as.character(data$team_id),
      as.character(data$opponent_id)
    ))),
    "__OTHER__"
  )
  x <- .directed_design_matrix(
    data,
    feature_names,
    league_levels,
    team_levels,
    include_team_effects
  )
  game_order <- unique(as.character(data$gameid))
  inner_games <- max(20L, floor(length(game_order) * inner_fraction))
  if (length(game_order) - inner_games < 50L) {
    stop("Directed inner temporal split is too small.", call. = FALSE)
  }
  validation_games <- utils::tail(game_order, inner_games)
  inner_validation <- as.character(data$gameid) %in% validation_games
  inner_train <- !inner_validation
  observed <- as.numeric(data$team_kills)
  offset <- log(as.numeric(data$game_length_minutes))
  path <- glmnet::glmnet(
    x[inner_train, , drop = FALSE],
    observed[inner_train],
    family = "poisson",
    alpha = alpha,
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
  losses <- vapply(seq_len(ncol(inner_mean)), function(index) {
    stats::weighted.mean(
      inner_mean[, index] -
        observed[inner_validation] *
          log(pmax(inner_mean[, index], 1e-12)),
      weights[inner_validation]
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
  theta <- .estimate_nb_theta(observed, fitted, weights)
  theta_by_side <- vapply(c("Blue", "Red"), function(side) {
    selected <- data$side == side
    .estimate_nb_theta(
      observed[selected],
      fitted[selected],
      weights[selected]
    )
  }, numeric(1L))
  names(theta_by_side) <- c("Blue", "Red")
  structure(
    list(
      model = model,
      lambda = selected_lambda,
      alpha = alpha,
      theta = theta,
      theta_by_side = theta_by_side,
      feature_names = feature_names,
      imputation = prepared$imputation,
      league_levels = league_levels,
      team_levels = team_levels,
      include_team_effects = include_team_effects,
      x_columns = colnames(x),
      training_rows = nrow(data),
      training_maps = length(game_order),
      inner_loss = min(losses),
      training_data = data,
      fitted_means = fitted,
      training_weights = weights
    ),
    class = "lolkills_directed_team_rate_model"
  )
}

.predict_directed_team_rates <- function(fit, newdata) {
  prepared <- .prepare_directed_features(
    newdata,
    fit$feature_names,
    fit$imputation
  )$data
  x <- .directed_design_matrix(
    prepared,
    fit$feature_names,
    fit$league_levels,
    fit$team_levels,
    fit$include_team_effects,
    expected_columns = fit$x_columns
  )
  rates <- as.numeric(stats::predict(
    fit$model,
    newx = x,
    s = fit$lambda,
    type = "response",
    newoffset = rep(0, nrow(x))
  ))
  data.frame(
    gameid = as.character(prepared$gameid),
    map_row = as.integer(prepared$map_row),
    side = as.character(prepared$side),
    rate = rates,
    theta = unname(fit$theta_by_side[as.character(prepared$side)]),
    stringsAsFactors = FALSE
  )
}

.estimate_beta_concentration <- function(data, fitted_means, weights) {
  blue <- data$side == "Blue"
  red <- data$side == "Red"
  blue_rows <- data[blue, c("gameid", "team_kills"), drop = FALSE]
  red_rows <- data[red, c("gameid", "team_kills"), drop = FALSE]
  blue_rows$blue_mean <- fitted_means[blue]
  red_rows$red_mean <- fitted_means[red]
  paired <- merge(blue_rows, red_rows, by = "gameid")
  total <- paired$team_kills.x + paired$team_kills.y
  valid <- total > 0
  if (sum(valid) < 50L) {
    return(50)
  }
  share <- paired$team_kills.x[valid] / total[valid]
  probability <- paired$blue_mean[valid] /
    (paired$blue_mean[valid] + paired$red_mean[valid])
  empirical <- mean((share - probability)^2)
  binomial <- mean(probability * (1 - probability) / total[valid])
  beta_variance <- pmax(empirical - binomial, 1e-6)
  concentration <- mean(probability * (1 - probability)) /
    beta_variance - 1
  pmin(500, pmax(2, concentration))
}

.estimate_copula_correlation <- function(data, fitted_means, theta_by_side) {
  residual <- stats::qnorm(.midpoint_nb_pit(
    data$team_kills,
    fitted_means,
    unname(theta_by_side[as.character(data$side)])
  ))
  frame <- data.frame(
    gameid = as.character(data$gameid),
    side = as.character(data$side),
    residual = residual,
    stringsAsFactors = FALSE
  )
  blue <- frame[frame$side == "Blue", c("gameid", "residual")]
  red <- frame[frame$side == "Red", c("gameid", "residual")]
  paired <- merge(blue, red, by = "gameid")
  correlation <- stats::cor(paired$residual.x, paired$residual.y)
  if (is.finite(correlation)) correlation else 0
}

#' Fit the joint team-intensity and duration challenger
#'
#' @param train One row per historical map.
#' @param team_feature_names Directed numeric predictors.
#' @param duration_feature_names Map-level duration predictors.
#' @param weights Optional map-level temporal weights.
#' @param alpha Ridge or elastic-net mixing value.
#' @param inner_fraction Latest training fraction used for tuning.
#' @param include_team_effects Include shrunken team and opponent identities.
#' @param copula_shrinkage Fraction shrinking empirical correlation to zero.
#' @return Joint probabilistic model bundle.
#' @export
fit_joint_team_monte_carlo_model <- function(
  train,
  team_feature_names,
  duration_feature_names,
  weights = NULL,
  alpha = 0,
  inner_fraction = 0.2,
  include_team_effects = TRUE,
  copula_shrinkage = 0.25
) {
  if (
    !is.finite(copula_shrinkage) ||
      copula_shrinkage < 0 ||
      copula_shrinkage > 1
  ) {
    stop("Copula shrinkage must be between zero and one.", call. = FALSE)
  }
  if (is.null(weights)) {
    weights <- rep(1, nrow(train))
  }
  if (length(weights) != nrow(train)) {
    stop("Joint-model weights must be map-level.", call. = FALSE)
  }
  directed <- build_directed_team_maps(train)
  directed_weights <- as.numeric(weights)[directed$map_row]
  team <- .fit_directed_team_rate_model(
    directed,
    team_feature_names,
    directed_weights,
    alpha,
    inner_fraction,
    include_team_effects
  )
  duration <- fit_regularized_duration_model(
    train,
    duration_feature_names,
    alpha = alpha,
    weights = weights,
    inner_fraction = inner_fraction
  )
  fitted_map_mean <- tapply(
    team$fitted_means,
    team$training_data$gameid,
    sum
  )
  ordered_gameids <- names(fitted_map_mean)
  match_index <- match(ordered_gameids, as.character(train$gameid))
  total_theta <- .estimate_nb_theta(
    train$total_kills_game[match_index],
    as.numeric(fitted_map_mean),
    weights[match_index]
  )
  raw_correlation <- .estimate_copula_correlation(
    team$training_data,
    team$fitted_means,
    team$theta_by_side
  )
  copula_correlation <- pmin(
    0.95,
    pmax(-0.95, raw_correlation * (1 - copula_shrinkage))
  )
  structure(
    list(
      team = team,
      duration = duration,
      total_theta = total_theta,
      beta_concentration = .estimate_beta_concentration(
        team$training_data,
        team$fitted_means,
        team$training_weights
      ),
      raw_copula_correlation = raw_correlation,
      copula_correlation = copula_correlation,
      copula_shrinkage = copula_shrinkage,
      team_feature_names = team_feature_names,
      duration_feature_names = duration_feature_names,
      training_maps = nrow(train)
    ),
    class = "lolkills_joint_team_monte_carlo_model"
  )
}

#' Convolve two finite count PMFs
#'
#' @param first First PMF starting at count zero.
#' @param second Second PMF starting at count zero.
#' @return Normalized PMF of the sum.
#' @export
convolve_count_pmfs <- function(first, second) {
  .validate_pmf(first)
  .validate_pmf(second)
  result <- stats::convolve(first, rev(second), type = "open")
  result <- pmax(0, as.numeric(result))
  result / sum(result)
}

.samples_to_pmf <- function(samples, support_max = NULL, floor = 1e-12) {
  samples <- as.integer(samples)
  if (length(samples) == 0L || anyNA(samples) || any(samples < 0L)) {
    stop("Monte Carlo samples must be non-negative integers.", call. = FALSE)
  }
  if (is.null(support_max)) {
    support_max <- max(samples)
  }
  support_max <- max(as.integer(support_max), max(samples))
  mass <- tabulate(samples + 1L, nbins = support_max + 1L)
  mass <- as.numeric(mass) + floor
  mass / sum(mass)
}

#' Blend parametric and historical predictive distributions
#'
#' @param parametric_pmf Parametric PMF.
#' @param historical_pmf Historical PMF.
#' @param historical_weight Weight assigned to historical scenarios.
#' @return Normalized blended PMF on the union support.
#' @export
blend_predictive_pmfs <- function(
  parametric_pmf,
  historical_pmf,
  historical_weight
) {
  .validate_pmf(parametric_pmf)
  .validate_pmf(historical_pmf)
  if (
    length(historical_weight) != 1L ||
      !is.finite(historical_weight) ||
      historical_weight < 0 ||
      historical_weight > 1
  ) {
    stop("Historical weight must be between zero and one.", call. = FALSE)
  }
  size <- max(length(parametric_pmf), length(historical_pmf))
  pad <- function(pmf) c(pmf, rep(0, size - length(pmf)))
  result <- (1 - historical_weight) * pad(parametric_pmf) +
    historical_weight * pad(historical_pmf)
  result / sum(result)
}

.sample_joint_parametric <- function(
  method,
  duration_draws,
  blue_rate,
  red_rate,
  blue_theta,
  red_theta,
  total_theta,
  beta_concentration,
  copula_correlation
) {
  blue_mean <- pmax(duration_draws * blue_rate, 1e-8)
  red_mean <- pmax(duration_draws * red_rate, 1e-8)
  if (method == "shared_duration") {
    blue <- stats::rnbinom(
      length(duration_draws),
      size = blue_theta,
      mu = blue_mean
    )
    red <- stats::rnbinom(
      length(duration_draws),
      size = red_theta,
      mu = red_mean
    )
    total <- blue + red
  } else if (method == "coherent_total") {
    total <- stats::rnbinom(
      length(duration_draws),
      size = total_theta,
      mu = blue_mean + red_mean
    )
    base_share <- blue_rate / (blue_rate + red_rate)
    share <- stats::rbeta(
      length(duration_draws),
      base_share * beta_concentration,
      (1 - base_share) * beta_concentration
    )
    blue <- stats::rbinom(length(total), total, share)
    red <- total - blue
  } else if (method == "gaussian_copula") {
    first <- stats::rnorm(length(duration_draws))
    second <- copula_correlation * first +
      sqrt(1 - copula_correlation^2) *
        stats::rnorm(length(duration_draws))
    blue <- stats::qnbinom(
      pmin(1 - 1e-12, pmax(1e-12, stats::pnorm(first))),
      size = blue_theta,
      mu = blue_mean
    )
    red <- stats::qnbinom(
      pmin(1 - 1e-12, pmax(1e-12, stats::pnorm(second))),
      size = red_theta,
      mu = red_mean
    )
    total <- blue + red
  } else {
    stop("Unsupported joint parametric method.", call. = FALSE)
  }
  list(
    duration = duration_draws,
    blue = as.integer(blue),
    red = as.integer(red),
    total = as.integer(total)
  )
}

#' Predict total-kills distributions from the joint challenger
#'
#' @param fit Fitted joint model.
#' @param newdata One row per future map.
#' @param method Joint simulation method.
#' @param draws Monte Carlo draws per map.
#' @param seed Deterministic seed.
#' @param tail_tolerance Tail tolerance for exact count PMFs.
#' @return One prediction list per map.
#' @export
predict_joint_team_monte_carlo_model <- function(
  fit,
  newdata,
  method = c(
    "independent_exact",
    "shared_duration",
    "coherent_total",
    "gaussian_copula"
  ),
  draws = 10000L,
  seed = 20260728L,
  tail_tolerance = 1e-10
) {
  method <- match.arg(method)
  if (!requireNamespace("glmnet", quietly = TRUE)) {
    stop("Package glmnet is required.", call. = FALSE)
  }
  if (!is.finite(draws) || draws < 100L) {
    stop("Joint Monte Carlo requires at least 100 draws.", call. = FALSE)
  }
  directed <- build_directed_team_maps(newdata)
  rate_predictions <- .predict_directed_team_rates(fit$team, directed)
  durations <- predict_regularized_duration_model(
    fit$duration,
    newdata,
    draws = draws,
    seed = seed
  )
  set.seed(as.integer(seed) + 1L)
  lapply(seq_len(nrow(newdata)), function(index) {
    rates <- rate_predictions[
      rate_predictions$map_row == index,
      ,
      drop = FALSE
    ]
    blue <- rates[rates$side == "Blue", , drop = FALSE]
    red <- rates[rates$side == "Red", , drop = FALSE]
    if (nrow(blue) != 1L || nrow(red) != 1L) {
      stop("Joint prediction requires one row per side.", call. = FALSE)
    }
    duration_draws <- durations[[index]]$draws
    if (method == "independent_exact") {
      blue_mean <- durations[[index]]$mean * blue$rate
      red_mean <- durations[[index]]$mean * red$rate
      blue_pmf <- make_count_pmf(
        blue_mean,
        "negative_binomial",
        blue$theta,
        tail_tolerance
      )$pmf
      red_pmf <- make_count_pmf(
        red_mean,
        "negative_binomial",
        red$theta,
        tail_tolerance
      )$pmf
      pmf <- convolve_count_pmfs(blue_pmf, red_pmf)
      samples <- list(
        duration = numeric(),
        blue = integer(),
        red = integer(),
        total = integer()
      )
    } else {
      samples <- .sample_joint_parametric(
        method,
        duration_draws,
        blue$rate,
        red$rate,
        blue$theta,
        red$theta,
        fit$total_theta,
        fit$beta_concentration,
        fit$copula_correlation
      )
      pmf <- .samples_to_pmf(samples$total)
      blue_mean <- mean(samples$blue)
      red_mean <- mean(samples$red)
    }
    support <- seq.int(0L, length(pmf) - 1L)
    list(
      mean = sum(support * pmf),
      blue_mean = as.numeric(blue_mean),
      red_mean = as.numeric(red_mean),
      duration_mean = durations[[index]]$mean,
      duration_sd = durations[[index]]$sd,
      pmf = pmf,
      support_max = length(pmf) - 1L,
      tail_mass = 0,
      method = method,
      copula_correlation = fit$copula_correlation,
      blue_draws = samples$blue,
      red_draws = samples$red,
      total_draws = samples$total
    )
  })
}

#' Build a point-in-time historical Monte Carlo event bank
#'
#' @param history Out-of-fold historical predictions and observed event vectors.
#' @param neighbor_features Numeric fields used for conditional neighbors.
#' @return Validated historical event bank.
#' @export
fit_historical_monte_carlo_bank <- function(
  history,
  neighbor_features = c(
    "predicted_duration",
    "predicted_blue_mean",
    "predicted_red_mean",
    "predicted_total",
    "predicted_share",
    "predicted_margin"
  )
) {
  required <- c(
    "gameid",
    "league_canonical",
    "game_datetime",
    "prediction_cutoff",
    "observed_duration",
    "observed_blue",
    "observed_red",
    "predicted_duration",
    "predicted_blue_mean",
    "predicted_red_mean",
    "blue_theta",
    "red_theta"
  )
  missing <- setdiff(required, names(history))
  if (length(missing) > 0L || nrow(history) == 0L) {
    stop("Historical bank rows are incomplete.", call. = FALSE)
  }
  data <- history
  data$game_datetime <- as.POSIXct(data$game_datetime, tz = "UTC")
  data$prediction_cutoff <- as.POSIXct(data$prediction_cutoff, tz = "UTC")
  if (
    anyNA(data$game_datetime) ||
      anyNA(data$prediction_cutoff) ||
      any(data$prediction_cutoff >= data$game_datetime)
  ) {
    stop(
      "Historical prediction cutoffs must be earlier than the game.",
      call. = FALSE
    )
  }
  if (anyDuplicated(as.character(data$gameid))) {
    stop("Historical event bank requires unique maps.", call. = FALSE)
  }
  data$predicted_total <- data$predicted_blue_mean +
    data$predicted_red_mean
  data$predicted_share <- data$predicted_blue_mean /
    pmax(data$predicted_total, 1e-8)
  data$predicted_margin <- data$predicted_blue_mean -
    data$predicted_red_mean
  data$duration_ratio <- data$observed_duration /
    pmax(data$predicted_duration, 1e-8)
  data$blue_pit <- .midpoint_nb_pit(
    data$observed_blue,
    data$predicted_blue_mean,
    data$blue_theta
  )
  data$red_pit <- .midpoint_nb_pit(
    data$observed_red,
    data$predicted_red_mean,
    data$red_theta
  )
  missing_features <- setdiff(neighbor_features, names(data))
  if (length(missing_features) > 0L) {
    stop("Historical neighbor features are missing.", call. = FALSE)
  }
  centers <- vapply(
    data[neighbor_features],
    function(values) mean(as.numeric(values), na.rm = TRUE),
    numeric(1L)
  )
  scales <- vapply(
    data[neighbor_features],
    function(values) {
      value <- stats::sd(as.numeric(values), na.rm = TRUE)
      if (is.finite(value) && value > 0) value else 1
    },
    numeric(1L)
  )
  structure(
    list(
      events = data,
      neighbor_features = neighbor_features,
      centers = centers,
      scales = scales
    ),
    class = "lolkills_historical_monte_carlo_bank"
  )
}

.historical_current_features <- function(current, feature_names) {
  data <- current
  data$predicted_total <- data$predicted_blue_mean +
    data$predicted_red_mean
  data$predicted_share <- data$predicted_blue_mean /
    pmax(data$predicted_total, 1e-8)
  data$predicted_margin <- data$predicted_blue_mean -
    data$predicted_red_mean
  missing <- setdiff(feature_names, names(data))
  if (length(missing) > 0L) {
    stop("Current historical-simulation features are missing.", call. = FALSE)
  }
  data
}

#' Simulate kills by resampling paired historical events
#'
#' @param bank Historical event bank.
#' @param current One current conditional prediction row.
#' @param method `pure`, `nearest`, or `shock`.
#' @param draws Number of historical draws.
#' @param seed Deterministic seed.
#' @param neighbors Maximum nearest historical events.
#' @param half_life_days Recency half-life.
#' @return Paired duration, Blue, Red, and total draws.
#' @export
simulate_historical_kills <- function(
  bank,
  current,
  method = c("pure", "nearest", "shock"),
  draws = 10000L,
  seed = 20260728L,
  neighbors = 250L,
  half_life_days = 60
) {
  method <- match.arg(method)
  if (
    nrow(current) != 1L ||
      !is.finite(draws) ||
      draws < 100L ||
      !is.finite(neighbors) ||
      neighbors < 1L ||
      !is.finite(half_life_days) ||
      half_life_days <= 0
  ) {
    stop("Historical simulation parameters are invalid.", call. = FALSE)
  }
  current <- .historical_current_features(
    current,
    bank$neighbor_features
  )
  cutoff <- as.POSIXct(current$prediction_cutoff[[1L]], tz = "UTC")
  eligible <- bank$events$game_datetime < cutoff
  events <- bank$events[eligible, , drop = FALSE]
  if (nrow(events) == 0L) {
    stop("No historical events exist before the prediction cutoff.", call. = FALSE)
  }
  same_league <- events$league_canonical ==
    as.character(current$league_canonical[[1L]])
  if (sum(same_league) >= 5L) {
    events <- events[same_league, , drop = FALSE]
  }
  age_days <- as.numeric(difftime(
    cutoff,
    events$game_datetime,
    units = "days"
  ))
  weights <- 0.5^(pmax(age_days, 0) / half_life_days)
  if (method %in% c("nearest", "shock")) {
    event_matrix <- sweep(
      as.matrix(events[bank$neighbor_features]),
      2L,
      bank$centers,
      "-"
    )
    event_matrix <- sweep(event_matrix, 2L, bank$scales, "/")
    current_vector <- (
      as.numeric(current[1L, bank$neighbor_features]) -
        bank$centers
    ) / bank$scales
    distance <- sqrt(rowSums(
      (event_matrix -
        matrix(
          current_vector,
          nrow = nrow(event_matrix),
          ncol = length(current_vector),
          byrow = TRUE
        ))^2
    ))
    selected <- order(distance)[
      seq_len(min(as.integer(neighbors), nrow(events)))
    ]
    events <- events[selected, , drop = FALSE]
    distance <- distance[selected]
    weights <- weights[selected] * exp(-distance)
  }
  weights <- weights / sum(weights)
  set.seed(as.integer(seed))
  sampled <- sample(
    seq_len(nrow(events)),
    size = as.integer(draws),
    replace = TRUE,
    prob = weights
  )
  selected <- events[sampled, , drop = FALSE]
  if (method %in% c("pure", "nearest")) {
    duration <- selected$observed_duration
    blue <- selected$observed_blue
    red <- selected$observed_red
  } else {
    duration <- as.numeric(current$predicted_duration[[1L]]) *
      selected$duration_ratio
    blue_rate <- as.numeric(current$predicted_blue_mean[[1L]]) /
      as.numeric(current$predicted_duration[[1L]])
    red_rate <- as.numeric(current$predicted_red_mean[[1L]]) /
      as.numeric(current$predicted_duration[[1L]])
    blue <- stats::qnbinom(
      selected$blue_pit,
      size = as.numeric(current$blue_theta[[1L]]),
      mu = pmax(duration * blue_rate, 1e-8)
    )
    red <- stats::qnbinom(
      selected$red_pit,
      size = as.numeric(current$red_theta[[1L]]),
      mu = pmax(duration * red_rate, 1e-8)
    )
  }
  data.frame(
    duration = as.numeric(duration),
    blue = as.integer(blue),
    red = as.integer(red),
    total = as.integer(blue + red),
    source_gameid = as.character(selected$gameid),
    stringsAsFactors = FALSE
  )
}

#' Convert honest historical predictions into an event-bank table
#'
#' @param fit Joint model fitted strictly before `prediction_cutoff`.
#' @param maps Later maps whose outcomes are already known.
#' @param prediction_cutoff Training cutoff of `fit`.
#' @return Historical prediction rows accepted by
#'   `fit_historical_monte_carlo_bank()`.
#' @export
build_historical_prediction_rows <- function(
  fit,
  maps,
  prediction_cutoff
) {
  cutoff <- as.POSIXct(prediction_cutoff, tz = "UTC")
  if (
    length(cutoff) != 1L ||
      is.na(cutoff) ||
      any(as.POSIXct(maps$game_datetime, tz = "UTC") <= cutoff)
  ) {
    stop(
      "Historical scoring maps must occur after the model cutoff.",
      call. = FALSE
    )
  }
  predictions <- predict_joint_team_monte_carlo_model(
    fit,
    maps,
    method = "independent_exact",
    draws = 100L,
    seed = 20260728L
  )
  data.frame(
    gameid = as.character(maps$gameid),
    league_canonical = as.character(maps$league_canonical),
    game_datetime = as.POSIXct(maps$game_datetime, tz = "UTC"),
    prediction_cutoff = rep(cutoff, nrow(maps)),
    observed_duration = as.numeric(maps$game_length_minutes),
    observed_blue = as.integer(maps$blue_kills),
    observed_red = as.integer(maps$red_kills),
    predicted_duration = vapply(
      predictions,
      function(item) item$duration_mean,
      numeric(1L)
    ),
    predicted_blue_mean = vapply(
      predictions,
      function(item) item$blue_mean,
      numeric(1L)
    ),
    predicted_red_mean = vapply(
      predictions,
      function(item) item$red_mean,
      numeric(1L)
    ),
    blue_theta = rep(fit$team$theta_by_side[["Blue"]], nrow(maps)),
    red_theta = rep(fit$team$theta_by_side[["Red"]], nrow(maps)),
    stringsAsFactors = FALSE
  )
}

#' Predict total kills with a historical event bank
#'
#' @param fit Current joint parametric model.
#' @param bank Point-in-time historical event bank.
#' @param newdata Future map rows.
#' @param method Historical resampling method.
#' @param draws Draws per map.
#' @param seed Base deterministic seed.
#' @param neighbors Maximum nearest events.
#' @param half_life_days Historical recency half-life.
#' @return One historical prediction distribution per map.
#' @export
predict_historical_monte_carlo_model <- function(
  fit,
  bank,
  newdata,
  method = c("pure", "nearest", "shock"),
  draws = 10000L,
  seed = 20260728L,
  neighbors = 250L,
  half_life_days = 60
) {
  method <- match.arg(method)
  conditional <- predict_joint_team_monte_carlo_model(
    fit,
    newdata,
    method = "independent_exact",
    draws = 100L,
    seed = seed
  )
  lapply(seq_len(nrow(newdata)), function(index) {
    current <- data.frame(
      league_canonical = as.character(
        newdata$league_canonical[[index]]
      ),
      prediction_cutoff = as.POSIXct(
        newdata$series_cutoff[[index]],
        tz = "UTC"
      ),
      predicted_duration = conditional[[index]]$duration_mean,
      predicted_blue_mean = conditional[[index]]$blue_mean,
      predicted_red_mean = conditional[[index]]$red_mean,
      blue_theta = fit$team$theta_by_side[["Blue"]],
      red_theta = fit$team$theta_by_side[["Red"]],
      stringsAsFactors = FALSE
    )
    samples <- simulate_historical_kills(
      bank,
      current,
      method = method,
      draws = draws,
      seed = as.integer(seed) + index,
      neighbors = neighbors,
      half_life_days = half_life_days
    )
    pmf <- .samples_to_pmf(samples$total)
    support <- seq.int(0L, length(pmf) - 1L)
    list(
      mean = sum(support * pmf),
      blue_mean = mean(samples$blue),
      red_mean = mean(samples$red),
      duration_mean = mean(samples$duration),
      duration_sd = stats::sd(samples$duration),
      pmf = pmf,
      support_max = length(pmf) - 1L,
      tail_mass = 0,
      method = paste0("historical_", method),
      blue_draws = samples$blue,
      red_draws = samples$red,
      total_draws = samples$total
    )
  })
}

.probability_over_from_pmf <- function(pmf, line) {
  maximum_under <- floor(line)
  if (maximum_under >= length(pmf) - 1L) {
    return(0)
  }
  1 - sum(pmf[seq_len(maximum_under + 1L)])
}

#' Benchmark Monte Carlo numerical convergence
#'
#' @param fit Fitted joint model.
#' @param maps Stratified maps with observed totals.
#' @param method Parametric simulation method.
#' @param draw_grid Candidate numbers of draws.
#' @param reference_draws High-draw reference.
#' @param lines Half-kill lines.
#' @param seed Deterministic seed.
#' @return Numerical convergence table.
#' @export
benchmark_monte_carlo_draws <- function(
  fit,
  maps,
  method = "coherent_total",
  draw_grid = c(1000L, 5000L, 10000L, 40000L),
  reference_draws = 100000L,
  lines = seq(18.5, 44.5, by = 2),
  seed = 20260728L
) {
  if (
    nrow(maps) == 0L ||
      !"total_kills_game" %in% names(maps) ||
      any(abs(lines %% 1 - 0.5) > 1e-12)
  ) {
    stop("Monte Carlo benchmark data or lines are invalid.", call. = FALSE)
  }
  started <- proc.time()[["elapsed"]]
  reference <- predict_joint_team_monte_carlo_model(
    fit,
    maps,
    method = method,
    draws = reference_draws,
    seed = seed
  )
  reference_seconds <- proc.time()[["elapsed"]] - started
  reference_crps <- vapply(seq_len(nrow(maps)), function(index) {
    discrete_crps(
      reference[[index]]$pmf,
      as.integer(maps$total_kills_game[[index]])
    )
  }, numeric(1L))
  do.call(rbind, lapply(draw_grid, function(draws) {
    started <- proc.time()[["elapsed"]]
    candidate <- predict_joint_team_monte_carlo_model(
      fit,
      maps,
      method = method,
      draws = draws,
      seed = seed
    )
    elapsed <- proc.time()[["elapsed"]] - started
    candidate_crps <- vapply(seq_len(nrow(maps)), function(index) {
      discrete_crps(
        candidate[[index]]$pmf,
        as.integer(maps$total_kills_game[[index]])
      )
    }, numeric(1L))
    probability_difference <- unlist(lapply(
      seq_len(nrow(maps)),
      function(index) {
        vapply(lines, function(line) {
          abs(
            .probability_over_from_pmf(candidate[[index]]$pmf, line) -
              .probability_over_from_pmf(reference[[index]]$pmf, line)
          )
        }, numeric(1L))
      }
    ))
    data.frame(
      draws = as.integer(draws),
      maps = nrow(maps),
      max_over_under_difference =
        max(probability_difference),
      mean_absolute_crps_difference =
        mean(abs(candidate_crps - reference_crps)),
      elapsed_seconds = elapsed,
      reference_draws = as.integer(reference_draws),
      reference_elapsed_seconds = reference_seconds,
      stringsAsFactors = FALSE
    )
  }))
}
