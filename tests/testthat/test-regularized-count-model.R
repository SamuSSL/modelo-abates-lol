make_regularized_fixture <- function(rows = 240L) {
  set.seed(20260724)
  x1 <- stats::rnorm(rows)
  x2 <- x1 + stats::rnorm(rows, sd = 0.05)
  league <- rep(c("LCK", "LPL"), length.out = rows)
  mean <- exp(3.1 + 0.15 * x1 - 0.1 * (league == "LPL"))
  data.frame(
    game_datetime = as.POSIXct(
      "2023-01-01",
      tz = "UTC"
    ) + seq_len(rows) * 86400,
    league_canonical = league,
    total_kills_game = stats::rnbinom(rows, mu = mean, size = 12),
    signal = x1,
    duplicate_signal = x2,
    stringsAsFactors = FALSE
  )
}

test_that("Ridge, Elastic Net and Lasso return valid count distributions", {
  skip_if_not_installed("glmnet")
  train <- make_regularized_fixture()
  validation <- tail(train, 10)

  for (alpha in c(0, 0.5, 1)) {
    fit <- fit_regularized_count_model(
      train,
      feature_names = c("signal", "duplicate_signal"),
      alpha = alpha
    )
    predictions <- predict_regularized_count_model(fit, validation)

    expect_true(fit$lambda > 0)
    expect_true(fit$theta > 0)
    expect_length(predictions, nrow(validation))
    expect_true(all(vapply(
      predictions,
      function(prediction) prediction$mean > 0 &&
        abs(sum(prediction$pmf) - 1) < 1e-10,
      logical(1L)
    )))
  }
})

test_that("regularized preprocessing rejects unseen leagues", {
  skip_if_not_installed("glmnet")
  train <- make_regularized_fixture()
  fit <- fit_regularized_count_model(
    train,
    feature_names = "signal",
    alpha = 0
  )
  validation <- tail(train, 1)
  validation$league_canonical <- "NEW"

  expect_error(
    predict_regularized_count_model(fit, validation),
    "unseen league"
  )
})

test_that("regularized model learns training-only missing-value imputation", {
  skip_if_not_installed("glmnet")
  train <- make_regularized_fixture()
  train$signal[c(3, 12, 40)] <- NA_real_
  fit <- fit_regularized_count_model(
    train,
    feature_names = c("signal", "duplicate_signal"),
    alpha = 0.5
  )
  validation <- tail(train, 2)
  validation$signal <- NA_real_
  predictions <- predict_regularized_count_model(fit, validation)

  expect_true(is.finite(fit$imputation[["signal"]]))
  expect_true(all(vapply(
    predictions,
    function(prediction) is.finite(prediction$mean),
    logical(1L)
  )))
})
