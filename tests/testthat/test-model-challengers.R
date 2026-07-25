test_that("quantile cuts are frozen from training data", {
  train <- data.frame(x = 1:100)
  validation <- data.frame(x = c(-1000, 1000))
  fit <- fit_quantile_bins(train, "x", bins = 5)
  breaks_before <- fit$breaks$x

  transformed <- apply_quantile_bins(fit, validation)

  expect_equal(fit$breaks$x, breaks_before)
  expect_equal(as.integer(transformed$q_x), c(1L, 5L))
})

test_that("PCA centers only on training data", {
  train <- data.frame(
    a = 1:20,
    b = 20:1,
    c = rep(c(0, 1), 10)
  )
  validation <- data.frame(
    a = 1000,
    b = -1000,
    c = 1
  )
  fit <- fit_pca_transform(
    train,
    c("a", "b", "c"),
    retained_variance = 0.9
  )
  center_before <- fit$model$center

  result <- apply_pca_transform(fit, validation)

  expect_equal(fit$model$center, center_before)
  expect_equal(nrow(result), 1L)
  expect_true(all(is.finite(unlist(result[1, ]))))
  expect_gte(fit$retained_variance, 0.9)
})
