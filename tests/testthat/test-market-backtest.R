test_that("market backtest evaluates a PMF at a half-kill line", {
  predictions <- data.frame(
    gameid = "g1", candidate_id = "v1"
  )
  predictions$pmf <- I(list(c(0.1, 0.2, 0.3, 0.4)))
  links <- data.frame(
    gameid = "g1", event_id = "e1", period = 1L,
    link_status = "verified"
  )
  snapshots <- data.frame(
    event_id = "e1", period = 1L, line = 1.5,
    odds_over = 2, odds_under = 2,
    true_odds_over = 2, true_odds_under = 2,
    closing_true_odds_over = 2, closing_true_odds_under = 2,
    odds_timestamp = as.POSIXct("2026-01-01", tz = "UTC")
  )
  games <- data.frame(
    gameid = "g1", series_id = "s1",
    game_datetime = as.POSIXct("2026-01-01 01:00:00", tz = "UTC"),
    league_canonical = "LCK", total_kills_game = 3L
  )
  result <- evaluate_kills_market_backtest(
    predictions, links, snapshots, games
  )

  expect_equal(result$model_probability_over, 0.7)
  expect_equal(result$outcome_over, 1L)
  expect_equal(result$profit_units, 1)
})
