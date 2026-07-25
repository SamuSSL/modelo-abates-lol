test_that("duration model predicts a positive distribution without target duration", {
  train <- data.frame(
    league_canonical = rep(c("LCK", "LEC"), each = 30),
    game_length_minutes = c(seq(28, 34, length.out = 30),
                            seq(30, 38, length.out = 30)),
    pace = seq(0.7, 1.1, length.out = 60),
    stringsAsFactors = FALSE
  )
  fit <- fit_duration_regression(
    train,
    distribution = "gamma",
    feature_names = "pace"
  )
  future <- data.frame(
    league_canonical = "LCK",
    pace = 0.9,
    stringsAsFactors = FALSE
  )

  prediction <- predict_duration_regression(
    fit,
    future,
    draws = 500,
    seed = 7
  )

  expect_equal(length(prediction), 1L)
  expect_true(all(prediction[[1L]]$draws > 0))
  expect_true(is.finite(prediction[[1L]]$mean))
  expect_false("game_length_minutes" %in% names(future))
})

test_that("intensity times duration integrates duration uncertainty into a PMF", {
  train <- data.frame(
    league_canonical = rep("LCK", 80),
    game_length_minutes = seq(25, 40, length.out = 80),
    total_kills_game = round(seq(18, 38, length.out = 80)),
    pace = seq(0.7, 1.2, length.out = 80),
    stringsAsFactors = FALSE
  )
  fit <- fit_intensity_duration_model(
    train,
    duration_distribution = "gamma",
    duration_features = "pace",
    intensity_features = "pace"
  )
  prediction <- predict_intensity_duration_model(
    fit,
    data.frame(league_canonical = "LCK", pace = 0.95),
    draws = 1000,
    seed = 11
  )[[1L]]

  expect_equal(sum(prediction$pmf), 1, tolerance = 1e-10)
  expect_true(prediction$duration_sd > 0)
  expect_true(prediction$intensity_per_minute > 0)
  expect_true(prediction$mean > 0)
  expect_lte(prediction$tail_mass, 1e-8)
})

test_that("training partition rejects observations from 2026", {
  data <- data.frame(
    game_datetime = as.POSIXct(
      c("2025-12-31 12:00:00", "2026-01-01 12:00:00"),
      tz = "UTC"
    )
  )
  expect_error(
    assert_development_period(data, "2026-01-01 00:00:00"),
    "2026"
  )
})
