test_that("line evaluation computes over probabilities and scores", {
  metrics <- data.frame(
    gameid = c("A", "B"),
    league_canonical = "LCK",
    candidate_id = "model",
    fold_id = "fold",
    observed = c(0L, 2L),
    stringsAsFactors = FALSE
  )
  metrics$pmf <- I(list(c(0.5, 0.5), c(0.2, 0.3, 0.5)))

  result <- evaluate_line_probabilities(metrics, c(0.5, 1.5))

  expect_equal(nrow(result$rows), 4L)
  expect_true(all(result$rows$probability_push == 0))
  first <- result$rows[
    result$rows$gameid == "A" & result$rows$line == 0.5,
  ]
  expect_equal(first$probability_over, 0.5)
  expect_equal(first$over_result, 0L)
  expect_true(all(is.finite(result$rows$brier)))
})
