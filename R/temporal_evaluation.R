.eligible_modeling_games <- function(games) {
  required <- c(
    "competition_role",
    "target_valid",
    "series_eligible",
    "series_cutoff",
    "game_datetime",
    "league_canonical",
    "total_kills_game"
  )
  missing <- setdiff(required, names(games))
  if (length(missing) > 0L) {
    stop(
      "Missing modeling columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  eligible <- games$competition_role == "target" &
    games$target_valid &
    games$series_eligible &
    !is.na(games$series_cutoff) &
    !is.na(games$game_datetime) &
    !is.na(games$total_kills_game)
  games[eligible, , drop = FALSE]
}

.subtract_months <- function(datetime, months) {
  date <- as.Date(datetime, tz = "UTC")
  shifted <- seq(
    date,
    by = paste0("-", as.integer(months), " months"),
    length.out = 2L
  )[[2L]]
  as.POSIXct(shifted, tz = "UTC")
}

#' Select leakage-safe temporal training data
#'
#' @param games Canonical game records.
#' @param validation_start Start of the future validation block.
#' @param window_type One of `fixed_months`, `current_season`,
#'   `current_and_previous_season`, `all_since_2022`, or `exponential`.
#' @param window_value Months for a fixed window or half-life days for
#'   exponential weighting.
#' @return A list containing selected data, weights, and temporal boundaries.
#' @export
select_temporal_training <- function(
  games,
  validation_start,
  window_type,
  window_value = NA_real_
) {
  games <- .eligible_modeling_games(games)
  validation_start <- as.POSIXct(validation_start, tz = "UTC")
  if (length(validation_start) != 1L || is.na(validation_start)) {
    stop("validation_start must be one valid datetime.", call. = FALSE)
  }

  supported <- c(
    "fixed_months",
    "current_season",
    "current_and_previous_season",
    "all_since_2022",
    "exponential"
  )
  if (!window_type %in% supported) {
    stop("Unsupported temporal window type.", call. = FALSE)
  }

  validation_year <- as.integer(format(validation_start, "%Y", tz = "UTC"))
  training_start <- switch(
    window_type,
    fixed_months = {
      if (
        length(window_value) != 1L ||
        is.na(window_value) ||
        window_value <= 0
      ) {
        stop("fixed_months requires a positive month count.", call. = FALSE)
      }
      .subtract_months(validation_start, window_value)
    },
    current_season = as.POSIXct(
      sprintf("%d-01-01 00:00:00", validation_year),
      tz = "UTC"
    ),
    current_and_previous_season = as.POSIXct(
      sprintf("%d-01-01 00:00:00", validation_year - 1L),
      tz = "UTC"
    ),
    all_since_2022 = as.POSIXct("2022-01-01 00:00:00", tz = "UTC"),
    exponential = as.POSIXct("2022-01-01 00:00:00", tz = "UTC")
  )

  selected <- games[
    games$series_cutoff >= training_start &
      games$series_cutoff < validation_start,
    ,
    drop = FALSE
  ]
  weights <- rep(1, nrow(selected))
  if (window_type == "exponential" && nrow(selected) > 0L) {
    if (
      length(window_value) != 1L ||
      is.na(window_value) ||
      window_value <= 0
    ) {
      stop("exponential requires a positive half-life.", call. = FALSE)
    }
    age_days <- as.numeric(
      difftime(
        validation_start,
        selected$series_cutoff,
        units = "days"
      )
    )
    weights <- 0.5^(age_days / window_value)
  }

  list(
    data = selected,
    weights = weights,
    training_start = training_start,
    validation_start = validation_start
  )
}

#' Build validation rows from pre-registered rolling folds
#'
#' @param games Canonical game records.
#' @param folds Data frame with fold ID, start, and end.
#' @param holdout_start Start of the sealed holdout.
#' @return Eligible validation maps with their fold IDs.
#' @export
build_validation_rows <- function(games, folds, holdout_start) {
  games <- .eligible_modeling_games(games)
  required <- c("fold_id", "validation_start", "validation_end")
  missing <- setdiff(required, names(folds))
  if (length(missing) > 0L) {
    stop(
      "Missing fold columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  holdout_start <- as.POSIXct(holdout_start, tz = "UTC")
  batches <- lapply(seq_len(nrow(folds)), function(index) {
    start <- as.POSIXct(folds$validation_start[[index]], tz = "UTC")
    end <- as.POSIXct(folds$validation_end[[index]], tz = "UTC")
    if (is.na(start) || is.na(end) || start >= end || end > holdout_start) {
      stop("Invalid fold boundary or holdout overlap.", call. = FALSE)
    }
    rows <- games[
      games$game_datetime >= start &
        games$game_datetime < end &
        games$game_datetime < holdout_start,
      ,
      drop = FALSE
    ]
    rows$fold_id <- as.character(folds$fold_id[[index]])
    rows
  })
  result <- do.call(rbind, batches)
  rownames(result) <- NULL
  result
}

.validate_pmf <- function(pmf) {
  if (
    !is.numeric(pmf) ||
    length(pmf) == 0L ||
    any(!is.finite(pmf))
  ) {
    stop("PMF must contain finite numeric probabilities.", call. = FALSE)
  }
  if (any(pmf < 0)) {
    stop("PMF probabilities must be non-negative.", call. = FALSE)
  }
  if (abs(sum(pmf) - 1) > 1e-10) {
    stop("PMF probabilities must sum to one.", call. = FALSE)
  }
  invisible(TRUE)
}

#' Calculate discrete CRPS for a probability mass function
#'
#' @param pmf Probabilities for integer outcomes starting at zero.
#' @param observed Observed non-negative integer outcome.
#' @return Scalar CRPS.
#' @export
discrete_crps <- function(pmf, observed) {
  .validate_pmf(pmf)
  if (
    length(observed) != 1L ||
    is.na(observed) ||
    observed < 0 ||
    observed != as.integer(observed)
  ) {
    stop("observed must be one non-negative integer.", call. = FALSE)
  }
  observed <- as.integer(observed)
  support_max <- max(length(pmf) - 1L, observed)
  padded <- c(pmf, rep(0, support_max + 1L - length(pmf)))
  cumulative <- cumsum(padded)
  indicator <- as.numeric(seq.int(0L, support_max) >= observed)
  sum((cumulative - indicator)^2)
}

.weighted_empirical_pmf <- function(values, weights = NULL, support_max = NULL) {
  values <- suppressWarnings(as.integer(values))
  if (length(values) == 0L || anyNA(values) || any(values < 0L)) {
    stop("Empirical values must be non-negative integers.", call. = FALSE)
  }
  if (is.null(weights)) {
    weights <- rep(1, length(values))
  }
  if (
    length(weights) != length(values) ||
    any(!is.finite(weights)) ||
    any(weights < 0) ||
    sum(weights) <= 0
  ) {
    stop("Empirical weights must be finite and non-negative.", call. = FALSE)
  }
  if (is.null(support_max)) {
    support_max <- max(values)
  }
  support_max <- max(as.integer(support_max), max(values))
  mass <- vapply(
    seq.int(0L, support_max),
    function(outcome) sum(weights[values == outcome]),
    numeric(1L)
  )
  mass / sum(mass)
}

#' Predict a league empirical PMF with global shrinkage
#'
#' @param train Training game records.
#' @param league Canonical league to predict.
#' @param prior_games Global-prior strength in effective games.
#' @param weights Optional temporal weights.
#' @return PMF for outcomes from zero through the training maximum.
#' @export
predict_league_empirical_pmf <- function(
  train,
  league,
  prior_games = 100,
  weights = NULL
) {
  required <- c("league_canonical", "total_kills_game")
  missing <- setdiff(required, names(train))
  if (length(missing) > 0L || nrow(train) == 0L) {
    stop("Training data are empty or missing required columns.", call. = FALSE)
  }
  if (is.null(weights)) {
    weights <- rep(1, nrow(train))
  }
  if (length(weights) != nrow(train)) {
    stop("weights must match training rows.", call. = FALSE)
  }
  support_max <- max(as.integer(train$total_kills_game))
  global <- .weighted_empirical_pmf(
    train$total_kills_game,
    weights,
    support_max
  )
  league_rows <- as.character(train$league_canonical) == league
  effective_games <- sum(weights[league_rows])
  if (!any(league_rows) || effective_games <= 0) {
    return(global)
  }
  league_pmf <- .weighted_empirical_pmf(
    train$total_kills_game[league_rows],
    weights[league_rows],
    support_max
  )
  league_weight <- effective_games / (effective_games + prior_games)
  result <- league_weight * league_pmf + (1 - league_weight) * global
  result / sum(result)
}

#' Build the pre-registered historical-window candidate grid
#'
#' @param config Evaluation configuration read from YAML.
#' @return Data frame describing every candidate.
#' @export
build_window_candidate_grid <- function(config) {
  candidates <- config$window_candidates
  if (is.null(candidates)) {
    stop("Evaluation config has no window_candidates.", call. = FALSE)
  }
  fixed <- as.numeric(unlist(candidates$fixed_months))
  calendar <- as.character(unlist(candidates$calendar))
  half_lives <- as.numeric(
    unlist(candidates$exponential_half_life_days)
  )
  data.frame(
    candidate_id = c(
      paste0("fixed_", fixed, "m"),
      calendar,
      paste0("exponential_hl", half_lives, "d")
    ),
    window_type = c(
      rep("fixed_months", length(fixed)),
      calendar,
      rep("exponential", length(half_lives))
    ),
    window_value = c(
      fixed,
      rep(NA_real_, length(calendar)),
      half_lives
    ),
    stringsAsFactors = FALSE
  )
}

.pmf_quantile <- function(pmf, probability) {
  which(cumsum(pmf) >= probability)[[1L]] - 1L
}

.score_empirical_map <- function(
  row,
  pmf,
  candidate,
  fold,
  training
) {
  observed <- as.integer(row$total_kills_game[[1L]])
  support <- seq.int(0L, length(pmf) - 1L)
  probability_observed <- if (observed <= max(support)) {
    pmf[[observed + 1L]]
  } else {
    0
  }
  prediction_mean <- sum(support * pmf)
  league <- as.character(row$league_canonical[[1L]])
  league_rows <- as.character(training$data$league_canonical) == league
  data.frame(
    gameid = as.character(row$gameid[[1L]]),
    league_canonical = as.character(row$league_canonical[[1L]]),
    game_datetime = as.POSIXct(row$game_datetime[[1L]], tz = "UTC"),
    fold_id = as.character(fold$fold_id[[1L]]),
    candidate_id = as.character(candidate$candidate_id[[1L]]),
    window_type = as.character(candidate$window_type[[1L]]),
    window_value = as.numeric(candidate$window_value[[1L]]),
    prediction_cutoff = as.POSIXct(
      fold$validation_start[[1L]],
      tz = "UTC"
    ),
    training_start = as.POSIXct(training$training_start, tz = "UTC"),
    training_games = nrow(training$data),
    effective_training_games = sum(training$weights),
    effective_league_games = sum(training$weights[league_rows]),
    observed = observed,
    prediction_mean = prediction_mean,
    prediction_median = .pmf_quantile(pmf, 0.5),
    lower_50 = .pmf_quantile(pmf, 0.25),
    upper_50 = .pmf_quantile(pmf, 0.75),
    lower_80 = .pmf_quantile(pmf, 0.10),
    upper_80 = .pmf_quantile(pmf, 0.90),
    lower_90 = .pmf_quantile(pmf, 0.05),
    upper_90 = .pmf_quantile(pmf, 0.95),
    probability_observed = probability_observed,
    crps = discrete_crps(pmf, observed),
    log_score = -log(max(probability_observed, 1e-12)),
    patch = if ("patch" %in% names(row)) {
      as.character(row$patch[[1L]])
    } else {
      NA_character_
    },
    playoffs = if ("playoffs" %in% names(row)) {
      as.integer(row$playoffs[[1L]])
    } else {
      NA_integer_
    },
    stringsAsFactors = FALSE
  )
}

.summarize_window_metrics <- function(map_metrics, expected_folds) {
  groups <- split(map_metrics, map_metrics$candidate_id)
  rows <- lapply(groups, function(data) {
    data.frame(
      candidate_id = data$candidate_id[[1L]],
      window_type = data$window_type[[1L]],
      window_value = data$window_value[[1L]],
      maps = nrow(data),
      folds_completed = length(unique(data$fold_id)),
      leagues_covered = length(unique(data$league_canonical)),
      mean_crps = mean(data$crps),
      mean_log_score = mean(data$log_score),
      mean_error = mean(data$prediction_mean - data$observed),
      coverage_50 = mean(
        data$observed >= data$lower_50 &
          data$observed <= data$upper_50
      ),
      coverage_80 = mean(
        data$observed >= data$lower_80 &
          data$observed <= data$upper_80
      ),
      coverage_90 = mean(
        data$observed >= data$lower_90 &
          data$observed <= data$upper_90
      ),
      stringsAsFactors = FALSE
    )
  })
  summary <- do.call(rbind, rows)
  rownames(summary) <- NULL
  summary$eligible_all_folds <- summary$folds_completed == expected_folds
  summary[order(summary$mean_crps, summary$mean_log_score), , drop = FALSE]
}

#' Evaluate historical windows with a leakage-safe empirical baseline
#'
#' @param games Canonical game records.
#' @param folds Pre-registered rolling validation folds.
#' @param candidates Candidate grid from `build_window_candidate_grid()`.
#' @param holdout_start Start of the sealed holdout.
#' @param prior_games League shrinkage prior strength.
#' @return Map-level predictions and aggregate candidate metrics.
#' @export
evaluate_window_candidates <- function(
  games,
  folds,
  candidates,
  holdout_start,
  prior_games = 100
) {
  validation <- build_validation_rows(games, folds, holdout_start)
  batches <- list()
  batch_index <- 0L

  for (candidate_index in seq_len(nrow(candidates))) {
    candidate <- candidates[candidate_index, , drop = FALSE]
    for (fold_index in seq_len(nrow(folds))) {
      fold <- folds[fold_index, , drop = FALSE]
      training <- select_temporal_training(
        games,
        validation_start = fold$validation_start[[1L]],
        window_type = candidate$window_type[[1L]],
        window_value = candidate$window_value[[1L]]
      )
      fold_validation <- validation[
        validation$fold_id == fold$fold_id[[1L]],
        ,
        drop = FALSE
      ]
      if (nrow(training$data) == 0L || nrow(fold_validation) == 0L) {
        next
      }

      pmfs <- lapply(
        unique(as.character(fold_validation$league_canonical)),
        function(league) {
          predict_league_empirical_pmf(
            training$data,
            league,
            prior_games = prior_games,
            weights = training$weights
          )
        }
      )
      names(pmfs) <- unique(as.character(fold_validation$league_canonical))

      rows <- lapply(seq_len(nrow(fold_validation)), function(row_index) {
        row <- fold_validation[row_index, , drop = FALSE]
        league <- as.character(row$league_canonical[[1L]])
        scored <- .score_empirical_map(
          row,
          pmfs[[league]],
          candidate,
          fold,
          training
        )
        scored$pmf <- I(list(pmfs[[league]]))
        scored
      })
      batch_index <- batch_index + 1L
      batches[[batch_index]] <- do.call(rbind, rows)
    }
  }

  if (length(batches) == 0L) {
    stop("No window candidate produced validation predictions.", call. = FALSE)
  }
  map_metrics <- do.call(rbind, batches)
  rownames(map_metrics) <- NULL
  list(
    map_metrics = map_metrics,
    summary = .summarize_window_metrics(
      map_metrics,
      expected_folds = nrow(folds)
    )
  )
}

#' Paired temporal-block bootstrap for CRPS differences
#'
#' @param map_metrics Map-level candidate metrics.
#' @param candidate_id Candidate being compared.
#' @param reference_id Reference candidate.
#' @param replicates Number of bootstrap replicates.
#' @param seed Reproducibility seed.
#' @param confidence Confidence level for the percentile interval.
#' @return One-row data frame. Negative differences favor the candidate.
#' @export
paired_block_bootstrap_crps <- function(
  map_metrics,
  candidate_id,
  reference_id,
  replicates = 2000L,
  seed = 20260723L,
  confidence = 0.95
) {
  required <- c("gameid", "candidate_id", "game_datetime", "crps")
  missing <- setdiff(required, names(map_metrics))
  if (length(missing) > 0L) {
    stop(
      "Missing bootstrap columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  candidate <- map_metrics[
    map_metrics$candidate_id == candidate_id,
    required,
    drop = FALSE
  ]
  reference <- map_metrics[
    map_metrics$candidate_id == reference_id,
    required,
    drop = FALSE
  ]
  if (
    nrow(candidate) == 0L ||
    nrow(reference) == 0L ||
    anyDuplicated(candidate$gameid) ||
    anyDuplicated(reference$gameid)
  ) {
    stop("Candidates must have one prediction per paired map.", call. = FALSE)
  }
  paired <- merge(
    candidate,
    reference,
    by = "gameid",
    suffixes = c("_candidate", "_reference"),
    sort = FALSE
  )
  if (nrow(paired) == 0L) {
    stop("Candidates have no paired maps.", call. = FALSE)
  }
  paired$difference <- paired$crps_candidate - paired$crps_reference
  paired$time_block <- format(
    as.POSIXct(paired$game_datetime_candidate, tz = "UTC"),
    "%Y-%U",
    tz = "UTC"
  )
  block_differences <- split(paired$difference, paired$time_block)
  block_names <- names(block_differences)
  set.seed(as.integer(seed))
  bootstrap <- replicate(as.integer(replicates), {
    sampled <- sample(
      block_names,
      size = length(block_names),
      replace = TRUE
    )
    mean(unlist(block_differences[sampled], use.names = FALSE))
  })
  alpha <- (1 - confidence) / 2
  interval <- stats::quantile(
    bootstrap,
    probs = c(alpha, 1 - alpha),
    names = FALSE,
    type = 7
  )
  data.frame(
    candidate_id = candidate_id,
    reference_id = reference_id,
    paired_maps = nrow(paired),
    time_blocks = length(block_names),
    replicates = as.integer(replicates),
    mean_difference = mean(paired$difference),
    relative_difference = mean(paired$difference) /
      mean(paired$crps_reference),
    ci_lower = interval[[1L]],
    ci_upper = interval[[2L]],
    probability_candidate_better = mean(bootstrap < 0),
    seed = as.integer(seed),
    stringsAsFactors = FALSE
  )
}
