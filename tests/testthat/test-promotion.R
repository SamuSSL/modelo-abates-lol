test_that("promotion gate requires every registered guardrail", {
  metrics <- data.frame(
    gameid = rep(c("A", "B"), 2L),
    candidate_id = rep(c("candidate", "reference"), each = 2L),
    league_canonical = "LCK",
    crps = c(1, 1, 1.1, 1.1),
    observed = 10L,
    prediction_mean = 10,
    lower_90 = 5L,
    upper_90 = 15L,
    tail_mass = 1e-10,
    stringsAsFactors = FALSE
  )
  metrics$pmf <- I(rep(list(c(0.5, 0.5)), 4L))
  criteria <- list(
    maximum_mean_crps_difference = 0,
    minimum_coverage_90 = 0.8,
    maximum_coverage_90 = 1,
    maximum_absolute_mean_error = 1,
    maximum_league_crps_degradation = 0.1,
    require_all_finite_pmfs = TRUE,
    maximum_tail_mass = 1e-8
  )

  result <- assess_model_promotion(
    metrics,
    "candidate",
    "reference",
    criteria
  )

  expect_true(result$passed)
  expect_equal(result$mean_crps_difference, -0.1)
})

test_that("promotion gate rejects hidden league degradation", {
  metrics <- data.frame(
    gameid = rep(c("A", "B"), 2L),
    candidate_id = rep(c("candidate", "reference"), each = 2L),
    league_canonical = rep(c("LCK", "LPL"), 2L),
    crps = c(0.5, 2, 1, 1),
    observed = 10L,
    prediction_mean = 10,
    lower_90 = 5L,
    upper_90 = 15L,
    tail_mass = 1e-10,
    stringsAsFactors = FALSE
  )
  metrics$pmf <- I(rep(list(c(0.5, 0.5)), 4L))
  criteria <- list(
    maximum_mean_crps_difference = 0.3,
    minimum_coverage_90 = 0.8,
    maximum_coverage_90 = 1,
    maximum_absolute_mean_error = 1,
    maximum_league_crps_degradation = 0.1,
    require_all_finite_pmfs = TRUE,
    maximum_tail_mass = 1e-8
  )

  result <- assess_model_promotion(
    metrics,
    "candidate",
    "reference",
    criteria
  )

  expect_false(result$passed)
  expect_false(result$checks$league_degradation)
})
