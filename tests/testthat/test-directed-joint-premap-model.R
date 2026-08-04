make_joint_premap_maps <- function(n = 180L) {
  set.seed(20260730)
  p_blue <- seq(0.2, 0.8, length.out = n)
  imbalance <- abs(stats::qlogis(p_blue))
  duration <- exp(log(31) - 0.05 * imbalance + rnorm(n, 0, 0.08))
  blue_rate <- 0.40 * exp(0.16 * stats::qlogis(p_blue))
  red_rate <- 0.40 * exp(-0.16 * stats::qlogis(p_blue))
  blue_kills <- stats::rpois(n, blue_rate * duration)
  red_kills <- stats::rpois(n, red_rate * duration)
  data <- data.frame(
    gameid = paste0("joint-", seq_len(n)),
    game_datetime = as.POSIXct("2024-01-01", tz = "UTC") +
      seq_len(n) * 86400,
    league_canonical = rep(c("LCK", "LPL"), length.out = n),
    map_number = rep(1:3, length.out = n),
    pace = 0.8 + 0.1 * sin(seq_len(n) / 9),
    game_length_minutes = duration,
    blue_team_kills = blue_kills,
    red_team_kills = red_kills,
    total_kills_game = blue_kills + red_kills,
    p_blue = p_blue,
    p_red = 1 - p_blue,
    favorite_imbalance = imbalance,
    favorite_imbalance_squared = imbalance^2,
    duration_last15 = 31 + sin(seq_len(n) / 11),
    blue_last15_duration_ratio = 1 + 0.04 * sin(seq_len(n) / 7),
    red_last15_duration_ratio = 1 + 0.04 * cos(seq_len(n) / 7),
    blue_last15_total_kills_sd_ratio = 1 + 0.05 * sin(
      seq_len(n) / 13
    ),
    red_last15_total_kills_sd_ratio = 1 + 0.05 * cos(
      seq_len(n) / 13
    ),
    blue_last15_league_kpm = 0.4,
    red_last15_league_kpm = 0.4,
    blue_last15_kpm_ratio = blue_rate / 0.4,
    red_last15_kpm_ratio = red_rate / 0.4,
    blue_last15_dpm_ratio = red_rate / 0.4,
    red_last15_dpm_ratio = blue_rate / 0.4,
    stringsAsFactors = FALSE
  )
  data
}

test_that("joint fundamental integrates duration and team intensities", {
  data <- make_joint_premap_maps()
  fit <- fit_directed_joint_fundamental(
    data,
    windows = "last15",
    dispersion_mode = "global"
  )
  predictions <- predict_directed_joint_fundamental(
    fit,
    data[171:175, , drop = FALSE],
    draws = 100L
  )

  expect_equal(length(predictions), 5L)
  expect_equal(sum(predictions[[1L]]$pmf), 1, tolerance = 1e-10)
  expect_equal(
    predictions[[1L]]$mean,
    predictions[[1L]]$blue_mean + predictions[[1L]]$red_mean,
    tolerance = 1e-10
  )
  expect_true(predictions[[1L]]$duration_mean > 0)
  allocation <- beta_binomial_kill_allocation(
    30,
    predictions[[1L]]$blue_share,
    predictions[[1L]]$allocation_concentration
  )
  expect_equal(sum(allocation), 1, tolerance = 1e-12)
})

test_that("continuous moneyline correction changes allocation coherently", {
  data <- make_joint_premap_maps()
  fundamental <- fit_directed_joint_fundamental(
    data,
    windows = "last15",
    dispersion_mode = "global"
  )
  informed <- fit_moneyline_joint_correction(
    fundamental,
    data,
    shape = "linear",
    dispersion_mode = "favoritism"
  )
  balanced <- data[150L, , drop = FALSE]
  balanced$p_blue <- 0.5
  balanced$p_red <- 0.5
  balanced$favorite_imbalance <- 0
  balanced$favorite_imbalance_squared <- 0
  favorite <- balanced
  favorite$p_blue <- 0.9
  favorite$p_red <- 0.1
  favorite$favorite_imbalance <- abs(stats::qlogis(0.9))
  favorite$favorite_imbalance_squared <-
    favorite$favorite_imbalance^2
  predictions <- predict_moneyline_joint_model(
    informed,
    rbind(balanced, favorite),
    draws = 100L
  )

  expect_true(predictions[[2L]]$blue_share > predictions[[1L]]$blue_share)
  expect_true(all(vapply(
    predictions,
    function(item) is.finite(item$theta) && item$theta > 0,
    logical(1L)
  )))
  expect_equal(sum(predictions[[2L]]$pmf), 1, tolerance = 1e-10)
  single_prediction <- predict_moneyline_joint_model(
    informed,
    favorite,
    draws = 100L
  )
  expect_length(single_prediction, 1L)
  expect_equal(
    sum(single_prediction[[1L]]$pmf),
    1,
    tolerance = 1e-10
  )
})

test_that("conditional dispersion remains positive under volatility", {
  data <- make_joint_premap_maps()
  fundamental <- fit_directed_joint_fundamental(
    data,
    windows = "last15",
    dispersion_mode = "favoritism_team_volatility"
  )
  predictions <- predict_directed_joint_fundamental(
    fundamental,
    data[1:4, , drop = FALSE],
    draws = 100L
  )

  expect_true(all(vapply(
    predictions,
    function(item) item$theta > 0 && is.finite(item$theta),
    logical(1L)
  )))
})
