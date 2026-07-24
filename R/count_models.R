.team_signal_source_columns <- function() {
  c(
    "blue_hist_combined_kills_per_minute",
    "red_hist_combined_kills_per_minute",
    "blue_hist_kills_per_minute",
    "red_hist_kills_per_minute",
    "blue_hist_deaths_per_minute",
    "red_hist_deaths_per_minute",
    "blue_hist_damage_per_minute",
    "red_hist_damage_per_minute",
    "blue_hist_damage_taken_per_minute",
    "red_hist_damage_taken_per_minute"
  )
}

#' Derive symmetric pre-series team signals
#'
#' @param maps Map feature table with frozen Blue and Red histories.
#' @return Input table with five symmetric team signals appended.
#' @export
derive_team_signal_features <- function(maps) {
  required <- .team_signal_source_columns()
  missing <- setdiff(required, names(maps))
  if (length(missing) > 0L) {
    stop(
      "Missing team signal columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  result <- maps
  result$pace <- (
    result$blue_hist_combined_kills_per_minute +
      result$red_hist_combined_kills_per_minute
  ) / 2
  result$attack <- result$blue_hist_kills_per_minute +
    result$red_hist_kills_per_minute
  result$defensive_exposure <-
    result$blue_hist_deaths_per_minute +
      result$red_hist_deaths_per_minute
  result$attack_defense_balance <-
    result$attack - result$defensive_exposure
  result$damage_output <- (
    result$blue_hist_damage_per_minute +
      result$red_hist_damage_per_minute
  ) / 2
  result$damage_exposure <- (
    result$blue_hist_damage_taken_per_minute +
      result$red_hist_damage_taken_per_minute
  ) / 2
  result
}

.feature_names_for_block <- function(feature_block) {
  switch(
    feature_block,
    league = character(),
    pace = "pace",
    attack_defense = c(
      "pace",
      "attack_defense_balance"
    ),
    pressure = c(
      "pace",
      "attack_defense_balance",
      "damage_output",
      "damage_exposure"
    ),
    pace_player = c(
      "pace",
      "player_conflict",
      "player_mortality"
    ),
    pace_draft = c(
      "pace",
      "draft_frontline",
      "draft_burst",
      "draft_frontline_imbalance"
    ),
    pace_player_draft = c(
      "pace",
      "player_conflict",
      "player_mortality",
      "draft_frontline",
      "draft_burst",
      "draft_frontline_imbalance"
    ),
    stop("Unsupported feature block: ", feature_block, call. = FALSE)
  )
}

#' Read the pre-registered simple-model candidates
#'
#' @param config Evaluation configuration read from YAML.
#' @return Candidate data frame with a list-column of feature names.
#' @export
build_simple_model_candidates <- function(config) {
  definitions <- config$simple_team_models$candidates
  if (is.null(definitions) || length(definitions) == 0L) {
    stop("Evaluation config has no simple model candidates.", call. = FALSE)
  }
  rows <- lapply(definitions, function(definition) {
    data.frame(
      candidate_id = as.character(definition$id),
      distribution = as.character(definition$distribution),
      feature_block = as.character(definition$feature_block),
      stringsAsFactors = FALSE
    )
  })
  result <- do.call(rbind, rows)
  result$feature_names <- I(lapply(
    result$feature_block,
    .feature_names_for_block
  ))
  rownames(result) <- NULL
  result
}

#' Build a finite count probability mass function
#'
#' @param mean Expected count.
#' @param distribution `poisson` or `negative_binomial`.
#' @param theta Negative Binomial size parameter.
#' @param tail_tolerance Maximum probability allowed beyond the support.
#' @return List with normalized PMF, support, and truncated tail mass.
#' @export
make_count_pmf <- function(
  mean,
  distribution,
  theta = NA_real_,
  tail_tolerance = 1e-10
) {
  if (
    length(mean) != 1L ||
      !is.finite(mean) ||
      mean <= 0 ||
      length(tail_tolerance) != 1L ||
      !is.finite(tail_tolerance) ||
      tail_tolerance <= 0 ||
      tail_tolerance >= 1
  ) {
    stop("Mean and tail tolerance must be valid.", call. = FALSE)
  }
  probability <- 1 - tail_tolerance
  if (distribution == "poisson") {
    support_max <- stats::qpois(probability, lambda = mean)
    support <- seq.int(0L, as.integer(support_max))
    mass <- stats::dpois(support, lambda = mean)
    tail_mass <- stats::ppois(
      support_max,
      lambda = mean,
      lower.tail = FALSE
    )
  } else if (distribution == "negative_binomial") {
    if (length(theta) != 1L || !is.finite(theta) || theta <= 0) {
      stop("Negative Binomial theta must be positive.", call. = FALSE)
    }
    support_max <- stats::qnbinom(
      probability,
      size = theta,
      mu = mean
    )
    support <- seq.int(0L, as.integer(support_max))
    mass <- stats::dnbinom(support, size = theta, mu = mean)
    tail_mass <- stats::pnbinom(
      support_max,
      size = theta,
      mu = mean,
      lower.tail = FALSE
    )
  } else {
    stop("Unsupported count distribution.", call. = FALSE)
  }
  if (
    !is.finite(support_max) ||
      any(!is.finite(mass)) ||
      sum(mass) <= 0
  ) {
    stop("Count distribution produced an invalid PMF.", call. = FALSE)
  }
  list(
    pmf = mass / sum(mass),
    support_max = as.integer(support_max),
    tail_mass = as.numeric(tail_mass)
  )
}

.standardize_training_features <- function(data, feature_names) {
  result <- data
  scaling <- vector("list", length(feature_names))
  names(scaling) <- feature_names
  for (feature in feature_names) {
    center <- mean(result[[feature]])
    scale <- stats::sd(result[[feature]])
    if (!is.finite(scale) || scale <= 0) {
      scale <- 1
    }
    result[[feature]] <- (result[[feature]] - center) / scale
    scaling[[feature]] <- list(center = center, scale = scale)
  }
  list(data = result, scaling = scaling)
}

.apply_feature_scaling <- function(data, scaling) {
  result <- data
  for (feature in names(scaling)) {
    result[[feature]] <- (
      result[[feature]] - scaling[[feature]]$center
    ) / scaling[[feature]]$scale
  }
  result
}

#' Fit a simple count regression
#'
#' @param train Training maps.
#' @param distribution `poisson` or `negative_binomial`.
#' @param feature_names Numeric features in addition to league.
#' @param weights Non-negative training weights.
#' @return Fitted count-regression bundle.
#' @export
fit_count_regression <- function(
  train,
  distribution,
  feature_names = character(),
  weights = NULL
) {
  required <- c(
    "league_canonical",
    "total_kills_game",
    feature_names
  )
  missing <- setdiff(required, names(train))
  if (length(missing) > 0L || nrow(train) == 0L) {
    stop("Training data are empty or missing required columns.", call. = FALSE)
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
    stop("Training weights must be finite and non-negative.", call. = FALSE)
  }
  complete <- stats::complete.cases(train[required]) &
    is.finite(train$total_kills_game) &
    train$total_kills_game >= 0
  data <- train[complete, required, drop = FALSE]
  fit_weights <- weights[complete]
  if (nrow(data) == 0L) {
    stop("No complete training rows.", call. = FALSE)
  }
  standardized <- .standardize_training_features(data, feature_names)
  data <- standardized$data
  league_levels <- sort(unique(as.character(data$league_canonical)))
  data$league_canonical <- factor(
    as.character(data$league_canonical),
    levels = league_levels
  )
  formula_terms <- c(
    if (length(league_levels) > 1L) "league_canonical",
    feature_names
  )
  formula <- stats::reformulate(
    formula_terms,
    response = "total_kills_game"
  )
  model <- if (distribution == "poisson") {
    stats::glm(
      formula,
      family = stats::poisson(link = "log"),
      data = data,
      weights = fit_weights,
      control = stats::glm.control(maxit = 100)
    )
  } else if (distribution == "negative_binomial") {
    suppressWarnings(MASS::glm.nb(
      formula,
      data = data,
      weights = fit_weights,
      link = log,
      control = stats::glm.control(maxit = 100)
    ))
  } else {
    stop("Unsupported count distribution.", call. = FALSE)
  }
  if (!isTRUE(model$converged) || any(!is.finite(stats::coef(model)))) {
    stop("Count regression did not converge.", call. = FALSE)
  }
  structure(
    list(
      model = model,
      distribution = distribution,
      feature_names = feature_names,
      scaling = standardized$scaling,
      league_levels = league_levels,
      theta = if (distribution == "negative_binomial") {
        as.numeric(model$theta)
      } else {
        NA_real_
      },
      training_rows = nrow(data),
      effective_training_games = sum(fit_weights)
    ),
    class = "lolkills_count_regression"
  )
}

#' Predict PMFs from a fitted count regression
#'
#' @param fit Fitted object from `fit_count_regression()`.
#' @param new_data Future map features.
#' @param tail_tolerance Maximum probability beyond PMF support.
#' @return One prediction list per row.
#' @export
predict_count_regression <- function(
  fit,
  new_data,
  tail_tolerance = 1e-10
) {
  required <- c("league_canonical", fit$feature_names)
  missing <- setdiff(required, names(new_data))
  if (length(missing) > 0L) {
    stop("Prediction data are missing required columns.", call. = FALSE)
  }
  if (any(!as.character(new_data$league_canonical) %in% fit$league_levels)) {
    stop("Prediction data contain an unseen league.", call. = FALSE)
  }
  if (any(!stats::complete.cases(new_data[required]))) {
    stop("Prediction data contain incomplete features.", call. = FALSE)
  }
  data <- .apply_feature_scaling(new_data, fit$scaling)
  data$league_canonical <- factor(
    as.character(data$league_canonical),
    levels = fit$league_levels
  )
  means <- as.numeric(stats::predict(
    fit$model,
    newdata = data,
    type = "response"
  ))
  lapply(means, function(prediction_mean) {
    distribution <- make_count_pmf(
      mean = prediction_mean,
      distribution = fit$distribution,
      theta = fit$theta,
      tail_tolerance = tail_tolerance
    )
    c(
      list(mean = prediction_mean),
      distribution
    )
  })
}

.score_count_map <- function(
  row,
  prediction,
  candidate_id,
  distribution,
  feature_block,
  fold,
  training_games,
  effective_training_games
) {
  pmf <- prediction$pmf
  observed <- as.integer(row$total_kills_game[[1L]])
  support <- seq.int(0L, length(pmf) - 1L)
  probability_observed <- if (observed <= max(support)) {
    pmf[[observed + 1L]]
  } else {
    0
  }
  result <- data.frame(
    gameid = as.character(row$gameid[[1L]]),
    league_canonical = as.character(row$league_canonical[[1L]]),
    game_datetime = as.POSIXct(row$game_datetime[[1L]], tz = "UTC"),
    fold_id = as.character(fold$fold_id[[1L]]),
    candidate_id = candidate_id,
    distribution = distribution,
    feature_block = feature_block,
    prediction_cutoff = as.POSIXct(
      fold$validation_start[[1L]],
      tz = "UTC"
    ),
    training_games = as.integer(training_games),
    effective_training_games = effective_training_games,
    observed = observed,
    prediction_mean = prediction$mean,
    prediction_median = .pmf_quantile(pmf, 0.5),
    lower_50 = .pmf_quantile(pmf, 0.25),
    upper_50 = .pmf_quantile(pmf, 0.75),
    lower_80 = .pmf_quantile(pmf, 0.10),
    upper_80 = .pmf_quantile(pmf, 0.90),
    lower_90 = .pmf_quantile(pmf, 0.05),
    upper_90 = .pmf_quantile(pmf, 0.95),
    probability_observed = probability_observed,
    tail_mass = prediction$tail_mass,
    crps = discrete_crps(pmf, observed),
    log_score = -log(max(probability_observed, 1e-12)),
    stringsAsFactors = FALSE
  )
  raw_game_columns <- c(
    "blue_raw_team_games",
    "red_raw_team_games"
  )
  if (all(raw_game_columns %in% names(row))) {
    result$blue_raw_team_games <- as.integer(
      row$blue_raw_team_games[[1L]]
    )
    result$red_raw_team_games <- as.integer(
      row$red_raw_team_games[[1L]]
    )
    result$minimum_raw_team_games <- min(
      result$blue_raw_team_games,
      result$red_raw_team_games
    )
  }
  player_sample_columns <- c(
    "minimum_raw_player_games",
    "minimum_effective_player_games",
    "minimum_raw_champion_games",
    "minimum_effective_champion_games"
  )
  for (column in player_sample_columns) {
    if (column %in% names(row)) {
      result[[column]] <- as.numeric(row[[column]][[1L]])
    }
  }
  result
}

.summarize_simple_metrics <- function(data, group_names) {
  interaction_key <- interaction(
    data[group_names],
    drop = TRUE,
    lex.order = TRUE
  )
  groups <- split(data, interaction_key)
  rows <- lapply(groups, function(group) {
    identity <- group[1L, group_names, drop = FALSE]
    metrics <- data.frame(
      maps = nrow(group),
      mean_crps = mean(group$crps),
      mean_log_score = mean(group$log_score),
      mean_error = mean(group$prediction_mean - group$observed),
      coverage_50 = mean(
        group$observed >= group$lower_50 &
          group$observed <= group$upper_50
      ),
      coverage_80 = mean(
        group$observed >= group$lower_80 &
          group$observed <= group$upper_80
      ),
      coverage_90 = mean(
        group$observed >= group$lower_90 &
          group$observed <= group$upper_90
      ),
      stringsAsFactors = FALSE
    )
    cbind(identity, metrics)
  })
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

#' Evaluate pre-registered simple team models
#'
#' @param maps Map table with derived symmetric signals.
#' @param folds Rolling validation folds.
#' @param candidates Candidate table from `build_simple_model_candidates()`.
#' @param holdout_start Start of sealed holdout.
#' @param training_start Earliest training cutoff.
#' @param half_life_days Exponential observation half-life.
#' @param prior_games Empirical league shrinkage strength.
#' @param tail_tolerance Maximum count-PMF tail mass.
#' @return Map predictions, summaries, and fitted standardized coefficients.
#' @export
evaluate_simple_team_models <- function(
  maps,
  folds,
  candidates,
  holdout_start,
  training_start = "2022-01-01 00:00:00",
  half_life_days = 60,
  prior_games = 100,
  tail_tolerance = 1e-10
) {
  required <- c(
    "gameid",
    "game_datetime",
    "series_cutoff",
    "league_canonical",
    "total_kills_game"
  )
  missing <- setdiff(required, names(maps))
  if (length(missing) > 0L) {
    stop("Map data are missing required columns.", call. = FALSE)
  }
  holdout_start <- as.POSIXct(holdout_start, tz = "UTC")
  training_start <- as.POSIXct(training_start, tz = "UTC")
  all_features <- unique(unlist(
    candidates$feature_names,
    use.names = FALSE
  ))
  validation_complete <- if (length(all_features) > 0L) {
    stats::complete.cases(maps[all_features])
  } else {
    rep(TRUE, nrow(maps))
  }
  batches <- list()
  coefficients <- list()
  batch_index <- 0L
  coefficient_index <- 0L

  for (fold_index in seq_len(nrow(folds))) {
    fold <- folds[fold_index, , drop = FALSE]
    validation_start <- as.POSIXct(
      fold$validation_start[[1L]],
      tz = "UTC"
    )
    validation_end <- as.POSIXct(
      fold$validation_end[[1L]],
      tz = "UTC"
    )
    if (
      is.na(validation_start) ||
        is.na(validation_end) ||
        validation_start >= validation_end ||
        validation_end > holdout_start
    ) {
      stop("Invalid fold boundary or holdout overlap.", call. = FALSE)
    }
    train_rows <- maps$series_cutoff >= training_start &
      maps$series_cutoff < validation_start
    validation_rows <- maps$game_datetime >= validation_start &
      maps$game_datetime < validation_end &
      maps$game_datetime < holdout_start &
      validation_complete
    train <- maps[train_rows, , drop = FALSE]
    validation <- maps[validation_rows, , drop = FALSE]
    if (nrow(train) == 0L || nrow(validation) == 0L) {
      next
    }
    age_days <- as.numeric(difftime(
      validation_start,
      train$series_cutoff,
      units = "days"
    ))
    weights <- 0.5^(age_days / half_life_days)

    for (candidate_index in seq_len(nrow(candidates))) {
      candidate <- candidates[candidate_index, , drop = FALSE]
      candidate_id <- as.character(candidate$candidate_id[[1L]])
      distribution <- as.character(candidate$distribution[[1L]])
      feature_block <- as.character(candidate$feature_block[[1L]])
      feature_names <- candidate$feature_names[[1L]]

      if (distribution == "empirical") {
        leagues <- unique(as.character(validation$league_canonical))
        pmfs <- lapply(leagues, function(league) {
          predict_league_empirical_pmf(
            train,
            league,
            prior_games = prior_games,
            weights = weights
          )
        })
        names(pmfs) <- leagues
        predictions <- lapply(
          as.character(validation$league_canonical),
          function(league) {
            pmf <- pmfs[[league]]
            list(
              mean = sum((seq_along(pmf) - 1L) * pmf),
              pmf = pmf,
              support_max = length(pmf) - 1L,
              tail_mass = 0
            )
          }
        )
        fitted_training_rows <- nrow(train)
        effective_training_games <- sum(weights)
      } else {
        fit <- tryCatch(
          fit_count_regression(
            train,
            distribution = distribution,
            feature_names = feature_names,
            weights = weights
          ),
          error = function(condition) {
            stop(
              "Candidate ",
              candidate_id,
              " failed in fold ",
              as.character(fold$fold_id[[1L]]),
              ": ",
              conditionMessage(condition),
              call. = FALSE
            )
          }
        )
        predictions <- predict_count_regression(
          fit,
          validation,
          tail_tolerance = tail_tolerance
        )
        fitted_training_rows <- fit$training_rows
        effective_training_games <- fit$effective_training_games
        coefficient_index <- coefficient_index + 1L
        coefficient_table <- data.frame(
          fold_id = as.character(fold$fold_id[[1L]]),
          candidate_id = candidate_id,
          term = names(stats::coef(fit$model)),
          estimate = as.numeric(stats::coef(fit$model)),
          theta = fit$theta,
          stringsAsFactors = FALSE
        )
        coefficients[[coefficient_index]] <- coefficient_table
      }

      rows <- lapply(seq_len(nrow(validation)), function(row_index) {
        scored <- .score_count_map(
          validation[row_index, , drop = FALSE],
          predictions[[row_index]],
          candidate_id,
          distribution,
          feature_block,
          fold,
          fitted_training_rows,
          effective_training_games
        )
        scored$pmf <- I(list(predictions[[row_index]]$pmf))
        scored
      })
      batch_index <- batch_index + 1L
      batches[[batch_index]] <- do.call(rbind, rows)
    }
  }
  if (length(batches) == 0L) {
    stop("No simple model produced validation predictions.", call. = FALSE)
  }
  map_metrics <- do.call(rbind, batches)
  rownames(map_metrics) <- NULL
  summary <- .summarize_simple_metrics(
    map_metrics,
    c("candidate_id", "distribution", "feature_block")
  )
  summary$folds_completed <- vapply(
    summary$candidate_id,
    function(candidate_id) length(unique(
      map_metrics$fold_id[map_metrics$candidate_id == candidate_id]
    )),
    integer(1L)
  )
  summary <- summary[
    order(summary$mean_crps, summary$mean_log_score),
    ,
    drop = FALSE
  ]
  list(
    map_metrics = map_metrics,
    summary = summary,
    by_fold = .summarize_simple_metrics(
      map_metrics,
      c("candidate_id", "fold_id")
    ),
    by_league = .summarize_simple_metrics(
      map_metrics,
      c("candidate_id", "league_canonical")
    ),
    coefficients = if (length(coefficients) > 0L) {
      do.call(rbind, coefficients)
    } else {
      data.frame()
    }
  )
}
