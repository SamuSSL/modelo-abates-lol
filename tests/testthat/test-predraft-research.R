test_that("predraft snapshot selection uses strict bounds and last quote", {
  start <- as.POSIXct("2026-01-01 12:00:00", tz = "UTC")
  snapshots <- data.frame(
    gameid = rep("g1", 5),
    market_close_time = rep(start, 5),
    odds_timestamp = start - c(46, 45, 40, 31, 30) * 60,
    quote = 1:5
  )
  selected <- select_predraft_market_snapshot(snapshots)
  expect_equal(nrow(selected), 1L)
  expect_equal(selected$quote, 4)
  expect_gt(selected$lead_minutes, 30)
  expect_lt(selected$lead_minutes, 45)
})

test_that("roster retention only accepts the frozen grid", {
  expect_equal(
    apply_roster_state_retention(c(2, 4), c(1, 1), 0.5),
    c(1.5, 2.5)
  )
  expect_error(apply_roster_state_retention(c(2), c(1), 0.6))
})

test_that("weekly states never include a map from the same frozen week", {
  maps <- data.frame(
    gameid = paste0("g", 1:4),
    game_datetime = as.POSIXct(c(
      "2025-01-04 12:00:00", "2025-01-05 12:00:00",
      "2025-01-11 12:00:00", "2025-01-12 12:00:00"
    ), tz = "UTC"),
    team_id = "team",
    league_canonical = "LEC",
    kills_per_minute = c(0.4, 0.8, 0.5, 0.5),
    deaths_per_minute = c(0.4, 0.8, 0.5, 0.5),
    combined_kills_per_minute = c(0.8, 1.6, 1, 1),
    game_length_minutes = c(30, 31, 32, 33),
    result = c(1, 0, 1, 0),
    gold_diff_at_15 = c(100, -100, 100, -100)
  )
  states <- build_weekly_latent_team_states(maps, evolution = 1)$premap
  expect_true(all(is.na(states$state_attack[1:2])))
  expect_equal(states$state_attack[3], mean(c(0.4, 0.8)))
  expect_equal(states$state_attack[3], states$state_attack[4])
  expect_true(all(states$weekly_cutoff < maps$game_datetime))
})

test_that("winner duration mixture returns both components", {
  train <- data.frame(
    game_length_minutes = c(
      30 + seq(-2, 2, length.out = 35),
      35 + seq(-2, 2, length.out = 35)
    ),
    winner_a = c(rep(1, 35), rep(0, 35)),
    imbalance = rep(seq(-1, 1, length.out = 35), 2)
  )
  fit <- fit_winner_mixture_duration(train, "imbalance")
  prediction <- predict_winner_mixture_duration(
    fit,
    data.frame(imbalance = 0),
    0.6
  )
  expect_equal(prediction$probability_team_a, 0.6)
  expect_true(all(is.finite(unlist(prediction))))
})
