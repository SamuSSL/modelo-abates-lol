test_that("Platt and beta calibration return valid probabilities", {
  probability <- seq(0.1, 0.9, length.out = 200)
  outcome <- as.integer(probability > 0.5)

  platt <- fit_binary_probability_calibrator(
    probability,
    outcome,
    "platt"
  )
  beta <- fit_binary_probability_calibrator(
    probability,
    outcome,
    "beta"
  )

  expect_true(all(
    predict_binary_probability_calibrator(platt, probability) > 0 &
      predict_binary_probability_calibrator(platt, probability) < 1
  ))
  expect_true(all(
    predict_binary_probability_calibrator(beta, probability) > 0 &
      predict_binary_probability_calibrator(beta, probability) < 1
  ))
})

test_that("market blend respects its fitted edge weight", {
  model_probability <- rep(c(0.45, 0.55, 0.60, 0.40), 100)
  market_probability <- rep(c(0.48, 0.52, 0.54, 0.46), 100)
  outcome <- rep(c(0L, 1L, 1L, 0L), 100)

  fit <- fit_market_probability_blend(
    model_probability,
    market_probability,
    outcome,
    include_intercept = FALSE
  )
  prediction <- predict_market_probability_blend(
    fit,
    model_probability,
    market_probability
  )

  expect_gte(fit$weight, 0)
  expect_lte(fit$weight, 1)
  expect_true(all(prediction > 0 & prediction < 1))
})

test_that("PMF Over probability uses count support correctly", {
  pmf <- c(0.10, 0.20, 0.30, 0.40)

  expect_equal(pmf_probability_over(pmf, 1.5), 0.70)
  expect_equal(pmf_probability_over(pmf, 2.5), 0.40)
})

test_that("binary quality summary reports perfect calibration gap", {
  probability <- c(0.25, 0.25, 0.75, 0.75)
  outcome <- c(0L, 1L, 0L, 1L)
  metrics <- summarize_binary_probability_quality(
    probability,
    outcome,
    bins = 2L
  )

  expect_equal(metrics$maps, 4L)
  expect_equal(metrics$calibration_gap, 0)
  expect_true(is.finite(metrics$brier))
  expect_true(is.finite(metrics$log_loss))
})
