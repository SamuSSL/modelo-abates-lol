test_that("equal-weight ensemble averages paired PMFs", {
  metrics <- data.frame(
    gameid = rep("A", 2L),
    candidate_id = c("first", "second"),
    observed = 1L,
    tail_mass = 0,
    stringsAsFactors = FALSE
  )
  metrics$pmf <- I(list(c(0.8, 0.2), c(0.2, 0.8)))

  result <- build_pmf_ensemble(
    metrics,
    c("first", "second"),
    weights = c(0.5, 0.5),
    ensemble_id = "ensemble"
  )

  expect_equal(result$candidate_id, "ensemble")
  expect_equal(result$pmf[[1L]], c(0.5, 0.5))
  expect_equal(result$crps, discrete_crps(c(0.5, 0.5), 1L))
})
