#' Assess a model against frozen promotion guardrails
#'
#' @param map_metrics Paired holdout prediction metrics.
#' @param candidate_id Candidate model ID.
#' @param reference_id Reference model ID.
#' @param criteria Promotion criteria read from configuration.
#' @return Promotion result and individual checks.
#' @export
assess_model_promotion <- function(
  map_metrics,
  candidate_id,
  reference_id,
  criteria
) {
  required <- c(
    "gameid",
    "candidate_id",
    "league_canonical",
    "crps",
    "observed",
    "prediction_mean",
    "lower_90",
    "upper_90",
    "tail_mass",
    "pmf"
  )
  if (!all(required %in% names(map_metrics))) {
    stop("Promotion metrics are missing required columns.", call. = FALSE)
  }
  candidate <- map_metrics[
    map_metrics$candidate_id == candidate_id,
    ,
    drop = FALSE
  ]
  reference <- map_metrics[
    map_metrics$candidate_id == reference_id,
    ,
    drop = FALSE
  ]
  paired_ids <- intersect(candidate$gameid, reference$gameid)
  candidate <- candidate[candidate$gameid %in% paired_ids, , drop = FALSE]
  reference <- reference[
    match(candidate$gameid, reference$gameid),
    ,
    drop = FALSE
  ]
  if (nrow(candidate) == 0L) {
    stop("Promotion requires paired predictions.", call. = FALSE)
  }
  mean_difference <- mean(candidate$crps - reference$crps)
  coverage_90 <- mean(
    candidate$observed >= candidate$lower_90 &
      candidate$observed <= candidate$upper_90
  )
  mean_error <- mean(
    candidate$prediction_mean - candidate$observed
  )
  league_groups <- split(seq_len(nrow(candidate)), candidate$league_canonical)
  by_league <- do.call(rbind, lapply(names(league_groups), function(league) {
    indices <- league_groups[[league]]
    data.frame(
      league_canonical = league,
      maps = length(indices),
      mean_crps_difference = mean(
        candidate$crps[indices] - reference$crps[indices]
      ),
      stringsAsFactors = FALSE
    )
  }))
  finite_pmfs <- vapply(candidate$pmf, function(pmf) {
    all(is.finite(pmf)) && all(pmf >= 0) &&
      abs(sum(pmf) - 1) < 1e-8
  }, logical(1L))
  checks <- list(
    crps = mean_difference <=
      criteria$maximum_mean_crps_difference,
    coverage_90 = coverage_90 >= criteria$minimum_coverage_90 &&
      coverage_90 <= criteria$maximum_coverage_90,
    mean_error = abs(mean_error) <=
      criteria$maximum_absolute_mean_error,
    league_degradation = max(by_league$mean_crps_difference) <=
      criteria$maximum_league_crps_degradation,
    finite_pmfs = !isTRUE(criteria$require_all_finite_pmfs) ||
      all(finite_pmfs),
    tail_mass = max(candidate$tail_mass) <=
      criteria$maximum_tail_mass
  )
  list(
    passed = all(unlist(checks)),
    candidate_id = candidate_id,
    reference_id = reference_id,
    maps = nrow(candidate),
    mean_crps_difference = mean_difference,
    coverage_90 = coverage_90,
    mean_error = mean_error,
    maximum_league_crps_degradation = max(
      by_league$mean_crps_difference
    ),
    checks = checks,
    by_league = by_league
  )
}
