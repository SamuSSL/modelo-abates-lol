test_that("Poisson inversion reproduces the spreadsheet example", {
  probability_over <- (1 / 1.847) / ((1 / 1.847) + (1 / 1.923))
  implied <- invert_market_count_mean(
    55.5,
    probability_over,
    "poisson"
  )

  expect_equal(implied, 55.85605175409203, tolerance = 1e-3)
  expect_equal(
    stats::ppois(55, implied, lower.tail = FALSE),
    probability_over,
    tolerance = 1e-8
  )
})

test_that("Negative-Binomial inversion reproduces the target probability", {
  implied <- invert_market_count_mean(
    14.5,
    0.54,
    "negative_binomial",
    theta = 8
  )

  expect_equal(
    stats::pnbinom(14, size = 8, mu = implied, lower.tail = FALSE),
    0.54,
    tolerance = 1e-8
  )
})

test_that("large Negative-Binomial theta approaches Poisson inversion", {
  poisson <- invert_market_count_mean(12.5, 0.48, "poisson")
  negative_binomial <- invert_market_count_mean(
    12.5,
    0.48,
    "negative_binomial",
    theta = 1e8
  )

  expect_equal(negative_binomial, poisson, tolerance = 1e-5)
})

test_that("market-implied scoring returns coherent count metrics", {
  rows <- data.frame(
    line = c(10.5, 14.5),
    true_odds_over = c(2, 2.2),
    true_odds_under = c(2, 1.8333333333),
    team_kills = c(12L, 10L)
  )
  scored <- score_market_implied_team_kills(rows, "poisson")

  expect_true(all(scored$implied_mean > 0))
  expect_true(all(scored$probability_observed > 0))
  expect_true(all(scored$crps >= 0))
  expect_true(all(scored$lower_90 <= scored$upper_90))
})

test_that("Negative Binomial can retain the Poisson-implied center", {
  rows <- data.frame(
    line = 14.5,
    true_odds_over = 2,
    true_odds_under = 2,
    team_kills = 16L
  )
  poisson <- score_market_implied_team_kills(rows, "poisson")
  hybrid <- score_market_implied_team_kills(
    rows,
    "negative_binomial",
    theta = 5,
    mean_distribution = "poisson"
  )

  expect_equal(hybrid$implied_mean, poisson$implied_mean)
  expect_equal(hybrid$mean_inversion_distribution, "poisson")
  expect_equal(hybrid$implied_distribution, "negative_binomial")
})

test_that("dispersion estimation respects the historical cutoff", {
  games <- data.frame(
    gameid = as.character(seq_len(300L)),
    game_datetime = as.POSIXct(
      "2024-01-01",
      tz = "UTC"
    ) + seq_len(300L) * 3600,
    league_canonical = rep(c("LCK", "LPL"), each = 150L),
    blue_team_name = rep(c("A", "B"), 150L),
    red_team_name = rep(c("C", "D"), 150L),
    blue_kills = rep(c(8L, 20L, 12L), 100L),
    red_kills = rep(c(15L, 5L, 10L), 100L),
    target_valid = TRUE,
    stringsAsFactors = FALSE
  )
  estimate <- estimate_historical_team_kill_dispersion(
    games,
    cutoff = as.POSIXct("2025-01-01", tz = "UTC"),
    minimum_maps = 250L
  )

  expect_true(is.finite(estimate$global_theta))
  expect_gt(estimate$global_theta, 0)
  expect_lt(estimate$training_end, estimate$cutoff)
})
