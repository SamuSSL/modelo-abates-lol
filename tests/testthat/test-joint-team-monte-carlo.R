make_joint_team_fixture <- function(n = 160L) {
  set.seed(20260728)
  game_datetime <- as.POSIXct("2023-01-01", tz = "UTC") +
    seq_len(n) * 86400
  duration <- exp(log(32) + stats::rnorm(n, 0, 0.08))
  total <- stats::rnbinom(n, mu = 27, size = 18)
  blue_share <- stats::rbeta(n, 8, 8)
  blue_kills <- stats::rbinom(n, total, blue_share)
  red_kills <- total - blue_kills
  data.frame(
    gameid = paste0("G", seq_len(n)),
    league_canonical = rep(c("LCK", "LEC"), length.out = n),
    game_datetime = game_datetime,
    series_cutoff = game_datetime,
    blue_team_id = rep(c("A", "B", "C", "D"), length.out = n),
    red_team_id = rep(c("C", "D", "A", "B"), length.out = n),
    blue_team_name = rep(c("A", "B", "C", "D"), length.out = n),
    red_team_name = rep(c("C", "D", "A", "B"), length.out = n),
    blue_kills = blue_kills,
    red_kills = red_kills,
    total_kills_game = total,
    game_length_minutes = duration,
    blue_hist_kills_per_minute = rep(c(0.42, 0.48), length.out = n),
    red_hist_kills_per_minute = rep(c(0.44, 0.40), length.out = n),
    blue_hist_deaths_per_minute = rep(c(0.40, 0.45), length.out = n),
    red_hist_deaths_per_minute = rep(c(0.46, 0.41), length.out = n),
    blue_hist_combined_kills_per_minute = 0.85,
    red_hist_combined_kills_per_minute = 0.84,
    blue_hist_game_length_minutes = 32,
    red_hist_game_length_minutes = 32,
    blue_draft_engage = rep(c(0.3, 0.7), length.out = n),
    red_draft_engage = rep(c(0.6, 0.4), length.out = n),
    draft_engage = 0.5,
    player_conflict = 999,
    stringsAsFactors = FALSE
  )
}

test_that("directed team maps preserve identities, sums and side features", {
  maps <- make_joint_team_fixture(4)
  directed <- build_directed_team_maps(maps)

  expect_equal(nrow(directed), 8L)
  expect_true(all(table(directed$gameid) == 2L))
  expect_equal(
    directed$team_kills + directed$opponent_kills,
    directed$total_kills_game
  )
  blue <- directed[directed$gameid == "G1" & directed$side == "Blue", ]
  red <- directed[directed$gameid == "G1" & directed$side == "Red", ]
  expect_equal(blue$team_id, maps$blue_team_id[[1L]])
  expect_equal(blue$opponent_id, maps$red_team_id[[1L]])
  expect_equal(blue$own_attack_rate, maps$blue_hist_kills_per_minute[[1L]])
  expect_equal(
    blue$opponent_exposure_rate,
    maps$red_hist_deaths_per_minute[[1L]]
  )
  expect_equal(blue$draft_engage_own, maps$blue_draft_engage[[1L]])
  expect_equal(red$draft_engage_own, maps$red_draft_engage[[1L]])
  expect_false(any(grepl("player", names(directed), ignore.case = TRUE)))
})

test_that("exact convolution returns the distribution of the sum", {
  result <- convolve_count_pmfs(c(0.5, 0.5), c(0.25, 0.75))

  expect_equal(result, c(0.125, 0.5, 0.375))
  expect_equal(sum(result), 1)
})

test_that("historical bank rejects future-informed residuals", {
  history <- data.frame(
    gameid = c("G1", "G2"),
    league_canonical = "LCK",
    game_datetime = as.POSIXct(
      c("2025-01-02", "2025-01-03"),
      tz = "UTC"
    ),
    prediction_cutoff = as.POSIXct(
      c("2025-01-01", "2025-01-04"),
      tz = "UTC"
    ),
    observed_duration = c(30, 31),
    observed_blue = c(10L, 11L),
    observed_red = c(8L, 9L),
    predicted_duration = c(31, 31),
    predicted_blue_mean = c(11, 11),
    predicted_red_mean = c(9, 9),
    blue_theta = 5,
    red_theta = 5,
    stringsAsFactors = FALSE
  )

  expect_error(
    fit_historical_monte_carlo_bank(history),
    "earlier than the game"
  )
})

test_that("historical simulation keeps observed event vectors paired", {
  history <- data.frame(
    gameid = paste0("H", 1:6),
    league_canonical = "LCK",
    game_datetime = as.POSIXct("2025-01-10", tz = "UTC") + 1:6 * 86400,
    prediction_cutoff = as.POSIXct("2025-01-09", tz = "UTC") + 1:6 * 86400,
    observed_duration = 25:30,
    observed_blue = 1:6,
    observed_red = 11:16,
    predicted_duration = rep(27.5, 6),
    predicted_blue_mean = rep(3.5, 6),
    predicted_red_mean = rep(13.5, 6),
    blue_theta = 8,
    red_theta = 8,
    stringsAsFactors = FALSE
  )
  bank <- fit_historical_monte_carlo_bank(history)
  current <- data.frame(
    league_canonical = "LCK",
    prediction_cutoff = as.POSIXct("2025-02-01", tz = "UTC"),
    predicted_duration = 28,
    predicted_blue_mean = 4,
    predicted_red_mean = 14,
    blue_theta = 8,
    red_theta = 8
  )
  simulated <- simulate_historical_kills(
    bank,
    current = current,
    method = "pure",
    draws = 500,
    seed = 42
  )

  expect_true(all(
    paste(simulated$blue, simulated$red) %in%
      paste(history$observed_blue, history$observed_red)
  ))
  repeated <- simulate_historical_kills(
    bank,
    current = current,
    method = "pure",
    draws = 500,
    seed = 42
  )
  expect_identical(simulated, repeated)
})

test_that("PMF blending is normalized on a common support", {
  result <- blend_predictive_pmfs(
    c(0.5, 0.5),
    c(0.1, 0.2, 0.7),
    historical_weight = 0.4
  )

  expect_equal(length(result), 3L)
  expect_equal(sum(result), 1)
  expect_equal(result, c(0.34, 0.38, 0.28))
})

test_that("joint Monte Carlo produces deterministic coherent totals", {
  train <- make_joint_team_fixture()
  fit <- fit_joint_team_monte_carlo_model(
    train,
    team_feature_names = c(
      "own_attack_rate",
      "opponent_exposure_rate",
      "draft_engage_own"
    ),
    duration_feature_names = "draft_engage"
  )
  first <- predict_joint_team_monte_carlo_model(
    fit,
    train[151:152, ],
    method = "coherent_total",
    draws = 1000,
    seed = 12
  )
  second <- predict_joint_team_monte_carlo_model(
    fit,
    train[151:152, ],
    method = "coherent_total",
    draws = 1000,
    seed = 12
  )

  expect_identical(first, second)
  expect_equal(length(first), 2L)
  expect_true(all(vapply(first, function(item) {
    abs(sum(item$pmf) - 1) < 1e-10 &&
      all(item$blue_draws + item$red_draws == item$total_draws)
  }, logical(1L))))
})
