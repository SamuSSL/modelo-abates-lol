make_forecast_rows <- function() {
  data.frame(
    gameid = paste0("game-", seq_len(60)),
    series_id = paste0("series-", rep(seq_len(30), each = 2)),
    snapshot_time = as.POSIXct("2026-06-01 11:30:00", tz = "UTC") + seq_len(60),
    last_prematch_time = as.POSIXct("2026-06-01 11:59:00", tz = "UTC") + seq_len(60),
    live_open_time = as.POSIXct("2026-06-01 12:00:00", tz = "UTC") + seq_len(60),
    snapshot_line = 24.5,
    snapshot_odds_over = 1.90,
    snapshot_odds_under = 1.90,
    last_line = 25.5,
    last_odds_over = 1.90,
    last_odds_under = 1.90,
    timing_id = rep(c("opening", "pre_t15"), 30),
    theta = 20,
    feature = seq_len(60) / 60,
    stringsAsFactors = FALSE
  )
}

test_that("market inversion and line translation are coherent", {
  market <- derive_total_market_implied_mean(24.5, 1.90, 1.90, 20)
  expect_equal(market$probability_over, 0.5)
  expect_true(market$implied_mean > 0)
  value <- evaluate_conservative_soft_value(
    market$implied_mean - 0.5,
    market$implied_mean + 0.5,
    20,
    24.5,
    2.20,
    1.70
  )
  expect_named(value, c(
    "conservative_probability_over", "conservative_probability_under",
    "conservative_ev_over", "conservative_ev_under", "recommended_side",
    "action", "stake"
  ))
})

test_that("forecast rows reject temporal leakage", {
  rows <- make_forecast_rows()
  built <- build_prematch_forecast_rows(rows)
  expect_true(all(built$snapshot_time < built$last_prematch_time))
  expect_true(all(built$last_prematch_time < built$live_open_time))
  rows$snapshot_time[[1L]] <- rows$last_prematch_time[[1L]]
  expect_error(
    build_prematch_forecast_rows(rows),
    "snapshot < last prematch < live open"
  )
})

test_that("ridge forecast returns ordered intervals", {
  rows <- build_prematch_forecast_rows(make_forecast_rows())
  rows$delta_mu <- 0.25 + 0.5 * rows$feature
  fit <- fit_prematch_delta_ridge(
    rows,
    delta_mu ~ feature + timing_id,
    lambda = 1
  )
  prediction <- predict_prematch_delta_ridge(fit, rows)
  expect_equal(nrow(prediction), nrow(rows))
  expect_true(all(prediction$predicted_last_mu_low <= prediction$predicted_last_mu))
  expect_true(all(prediction$predicted_last_mu <= prediction$predicted_last_mu_high))
})

test_that("invalid soft quote is rejected", {
  expect_error(
    evaluate_conservative_soft_value(24, 26, 20, 24, 1.90, 1.90),
    "invalid line or odds"
  )
})
