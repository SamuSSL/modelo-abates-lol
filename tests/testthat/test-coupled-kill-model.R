make_coupled_model_fixture <- function(n = 180L) {
  set.seed(20260726)
  date <- as.POSIXct("2023-01-01", tz = "UTC") +
    seq_len(n) * 86400
  pace <- stats::runif(n, 0.65, 1.15)
  duration_signal <- stats::rnorm(n)
  duration <- exp(log(32) + 0.09 * duration_signal +
                    stats::rnorm(n, 0, 0.08))
  log_rate <- log(pace) - 0.35 * (log(duration) - log(32))
  total <- stats::rnbinom(
    n,
    mu = exp(log_rate) * duration,
    size = 20
  )
  data.frame(
    league_canonical = rep(c("LCK", "LEC"), length.out = n),
    game_datetime = date,
    game_length_minutes = duration,
    total_kills_game = total,
    pace = pace,
    duration_signal = duration_signal,
    stringsAsFactors = FALSE
  )
}

test_that("regularized duration model estimates honest uncertainty", {
  train <- make_coupled_model_fixture()
  fit <- fit_regularized_duration_model(
    train,
    feature_names = c("pace", "duration_signal"),
    alpha = 0
  )
  prediction <- predict_regularized_duration_model(
    fit,
    train[171:180, ],
    draws = 400,
    seed = 9
  )

  expect_equal(length(prediction), 10L)
  expect_true(all(vapply(
    prediction,
    function(row) row$sd > 0 && all(row$draws > 0),
    logical(1L)
  )))
  expect_true(is.finite(fit$residual_sd_log))
  expect_gt(fit$residual_sd_log, 0)
})

test_that("coupled model conditions intensity on simulated duration", {
  train <- make_coupled_model_fixture()
  fit <- fit_coupled_kill_model(
    train,
    duration_features = c("pace", "duration_signal"),
    intensity_features = "pace",
    alpha_duration = 0,
    alpha_intensity = 0
  )
  prediction <- predict_coupled_kill_model(
    fit,
    train[171:175, ],
    draws = 300,
    seed = 11
  )

  expect_lt(fit$duration_coupling, 0)
  expect_equal(length(prediction), 5L)
  expect_true(all(vapply(
    prediction,
    function(row) {
      abs(sum(row$pmf) - 1) < 1e-9 &&
        row$mean > 0 &&
        row$duration_mean > 0 &&
        row$intensity_per_minute > 0
    },
    logical(1L)
  )))
})
