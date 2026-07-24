.bind_prior_evaluations <- function(evaluations, component) {
  rows <- lapply(evaluations, `[[`, component)
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

#' Evaluate team-history shrinkage priors
#'
#' @param map_tables Named map tables such as `prior10` and `prior20`.
#' @param prior_grid_games Numeric prior strengths matching `map_tables`.
#' @param folds Rolling validation folds.
#' @param holdout_start Start of sealed holdout.
#' @param training_start Earliest training cutoff.
#' @param half_life_days Exponential observation half-life.
#' @param tail_tolerance Maximum count-PMF tail mass.
#' @return Combined evaluations for every prior strength.
#' @export
evaluate_team_prior_sensitivity <- function(
  map_tables,
  prior_grid_games,
  folds,
  holdout_start,
  training_start = "2022-01-01 00:00:00",
  half_life_days = 60,
  tail_tolerance = 1e-10
) {
  prior_grid_games <- as.numeric(prior_grid_games)
  expected_names <- paste0("prior", prior_grid_games)
  if (
    !is.list(map_tables) ||
      length(map_tables) != length(prior_grid_games) ||
      !all(expected_names %in% names(map_tables))
  ) {
    stop(
      "map_tables must contain: ",
      paste(expected_names, collapse = ", "),
      call. = FALSE
    )
  }
  evaluations <- lapply(seq_along(prior_grid_games), function(index) {
    prior_games <- prior_grid_games[[index]]
    candidate_id <- paste0("nb_pace_prior", prior_games)
    candidates <- data.frame(
      candidate_id = candidate_id,
      distribution = "negative_binomial",
      feature_block = "pace",
      stringsAsFactors = FALSE
    )
    candidates$feature_names <- I(list("pace"))
    evaluation <- evaluate_simple_team_models(
      maps = map_tables[[expected_names[[index]]]],
      folds = folds,
      candidates = candidates,
      holdout_start = holdout_start,
      training_start = training_start,
      half_life_days = half_life_days,
      tail_tolerance = tail_tolerance
    )
    for (component in c(
      "map_metrics",
      "summary",
      "by_fold",
      "by_league",
      "coefficients"
    )) {
      evaluation[[component]]$prior_games <- prior_games
    }
    evaluation
  })
  names(evaluations) <- expected_names

  prediction_keys <- lapply(evaluations, function(evaluation) {
    sort(paste(
      evaluation$map_metrics$fold_id,
      evaluation$map_metrics$gameid,
      sep = "::"
    ))
  })
  reference_keys <- prediction_keys[[1L]]
  same_maps <- vapply(
    prediction_keys,
    identical,
    logical(1L),
    y = reference_keys
  )
  if (!all(same_maps)) {
    stop("Prior candidates did not predict the same maps.", call. = FALSE)
  }

  summary <- .bind_prior_evaluations(evaluations, "summary")
  summary <- summary[
    order(summary$mean_crps, summary$mean_log_score),
    ,
    drop = FALSE
  ]
  list(
    map_metrics = .bind_prior_evaluations(
      evaluations,
      "map_metrics"
    ),
    summary = summary,
    by_fold = .bind_prior_evaluations(evaluations, "by_fold"),
    by_league = .bind_prior_evaluations(
      evaluations,
      "by_league"
    ),
    coefficients = .bind_prior_evaluations(
      evaluations,
      "coefficients"
    )
  )
}
