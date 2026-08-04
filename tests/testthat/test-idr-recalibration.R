test_that("IDR cold start preserves the first fold and produces valid PMFs", {
  skip_if_not_installed("isodistrreg")
  metrics <- data.frame(
    gameid = paste0("g", 1:240),
    fold_id = rep(c("f1", "f2"), each = 120),
    game_datetime = as.POSIXct("2025-01-01", tz = "UTC") + 1:240,
    observed = rep(20:39, 12),
    prediction_mean = rep(21:40, 12),
    candidate_id = "v1",
    distribution = "nb",
    feature_block = "v1",
    prediction_median = 25L,
    lower_50 = 20L, upper_50 = 30L,
    lower_80 = 15L, upper_80 = 35L,
    lower_90 = 12L, upper_90 = 40L,
    probability_observed = 0.05,
    crps = 1, log_score = 3
  )
  metrics$pmf <- I(rep(list(rep(1 / 81, 81)), 240))
  result <- recalibrate_oof_idr(metrics)

  expect_equal(nrow(result), 240)
  expect_true(all(vapply(result$pmf, function(pmf) {
    abs(sum(pmf) - 1) < 1e-10 && all(pmf >= 0)
  }, logical(1L))))
})
