make_multiplicative_training_maps <- function(n = 80L) {
  set.seed(17)
  data <- data.frame(
    gameid = paste0("g", seq_len(n)),
    game_datetime = as.POSIXct("2025-01-01", tz = "UTC") +
      seq_len(n) * 3600,
    league_canonical = rep(c("LCK", "LEC"), length.out = n),
    pace = seq(0.8, 1.2, length.out = n),
    stringsAsFactors = FALSE
  )
  for (window in c("season", "split", "last15", "last10", "last5")) {
    data[[paste0("blue_mu_count_", window)]] <-
      14 * data$pace * runif(n, 0.95, 1.05)
    data[[paste0("red_mu_count_", window)]] <-
      12 * data$pace * runif(n, 0.95, 1.05)
    data[[paste0("blue_mu_rate_", window)]] <-
      13.5 * data$pace * runif(n, 0.95, 1.05)
    data[[paste0("red_mu_rate_", window)]] <-
      12.5 * data$pace * runif(n, 0.95, 1.05)
  }
  data$blue_team_kills <- stats::rpois(n, 14 * data$pace)
  data$red_team_kills <- stats::rpois(n, 12 * data$pace)
  data$total_kills_game <- data$blue_team_kills + data$red_team_kills
  data
}

test_that("optimized window model produces coherent normalized predictions", {
  data <- make_multiplicative_training_maps()
  fit <- fit_premap_multiplicative_model(
    data,
    expectation = "count",
    combination = "optimized"
  )
  predictions <- predict_premap_multiplicative_model(
    fit,
    data[1:3, , drop = FALSE]
  )

  expect_equal(sum(fit$window_weights), 1, tolerance = 1e-10)
  expect_true(all(fit$window_weights >= 0))
  expect_equal(length(predictions), 3L)
  expect_equal(sum(predictions[[1L]]$pmf), 1, tolerance = 1e-10)
  expect_equal(
    predictions[[1L]]$mean,
    predictions[[1L]]$blue_mean + predictions[[1L]]$red_mean
  )
})

test_that("Beta-Binomial allocation is coherent with the map total", {
  mass <- beta_binomial_kill_allocation(
    total_kills = 30L,
    blue_probability = 0.6,
    concentration = 20
  )

  expect_equal(length(mass), 31L)
  expect_equal(sum(mass), 1, tolerance = 1e-12)
  expect_equal(
    sum(seq.int(0L, 30L) * mass),
    18,
    tolerance = 1e-8
  )
})

test_that("market tilt matches the no-vig probability at full weight", {
  pmf <- make_count_pmf(27, "negative_binomial", theta = 12)$pmf
  hybrid <- tilt_pmf_to_kill_market(
    pmf,
    line = 26.5,
    market_probability_over = 0.62,
    weight = 1
  )
  support <- seq.int(0L, length(hybrid) - 1L)

  expect_equal(sum(hybrid), 1, tolerance = 1e-12)
  expect_equal(sum(hybrid[support > 26.5]), 0.62, tolerance = 1e-8)
})

test_that("moneyline correction remains coherent around the fundamental", {
  data <- make_multiplicative_training_maps()
  data$p_blue <- seq(0.35, 0.80, length.out = nrow(data))
  data$p_red <- 1 - data$p_blue
  fundamental <- fit_premap_multiplicative_model(
    data,
    expectation = "count",
    combination = "equal"
  )
  informed <- fit_moneyline_informed_model(
    data,
    fundamental,
    interactions = FALSE
  )
  prediction <- predict_moneyline_informed_model(
    informed,
    data[1:2, , drop = FALSE]
  )

  expect_equal(length(prediction), 2L)
  expect_equal(
    prediction[[1L]]$mean,
    prediction[[1L]]$blue_mean + prediction[[1L]]$red_mean
  )
  expect_equal(sum(prediction[[1L]]$pmf), 1, tolerance = 1e-10)

  unseen_league <- data[1L, , drop = FALSE]
  unseen_league$league_canonical <- "UNSEEN_LEAGUE"
  transported <- predict_moneyline_informed_model(
    informed,
    unseen_league
  )
  expect_equal(length(transported), 1L)
  expect_equal(sum(transported[[1L]]$pmf), 1, tolerance = 1e-10)
})
