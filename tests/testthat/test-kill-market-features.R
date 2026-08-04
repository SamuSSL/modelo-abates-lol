make_kill_market_fixture <- function() {
  timestamps <- as.POSIXct(
    rep(
      c(
        "2025-01-01 12:00:00",
        "2025-01-11 12:00:00",
        "2025-01-21 12:00:00"
      ),
      each = 2
    ),
    tz = "UTC"
  )
  data.frame(
    gameid = rep(c("G1", "G2", "G3"), each = 2),
    game_datetime = timestamps,
    series_cutoff = timestamps,
    league_canonical = "LCK",
    competition_role = "target",
    side = rep(c("Blue", "Red"), 3),
    team_id = rep(c("A", "B"), 3),
    team_name = rep(c("A", "B"), 3),
    result = rep(c(1, 0), 3),
    game_length_minutes = rep(c(30, 35, 28), each = 2),
    team_kills = c(12, 8, 18, 12, 10, 7),
    team_deaths = c(8, 12, 12, 18, 7, 10),
    total_kills_game = rep(c(20, 30, 17), each = 2),
    kills_per_minute = c(
      12 / 30, 8 / 30, 18 / 35, 12 / 35, 10 / 28, 7 / 28
    ),
    deaths_per_minute = c(
      8 / 30, 12 / 30, 12 / 35, 18 / 35, 7 / 28, 10 / 28
    ),
    combined_kills_per_minute = rep(c(20 / 30, 30 / 35, 17 / 28), each = 2),
    assists = c(28, 20, 42, 31, 24, 17),
    dragons = c(3, 2, 4, 3, 2, 2),
    barons = c(1, 0, 2, 1, 1, 0),
    heralds = c(1, 0, 1, 0, 1, 0),
    towers = c(9, 4, 10, 6, 8, 3),
    damage_to_champions = c(
      60000, 50000, 85000, 70000, 53000, 45000
    ),
    damage_per_minute = c(2000, 1667, 2429, 2000, 1893, 1607),
    damage_taken_per_minute = c(
      1667, 2000, 2000, 2429, 1607, 1893
    ),
    kills_at_10 = c(2, 1, 4, 2, 1, 1),
    deaths_at_10 = c(1, 2, 2, 4, 1, 1),
    kills_at_15 = c(4, 2, 7, 4, 3, 2),
    deaths_at_15 = c(2, 4, 4, 7, 2, 3),
    combined_kills_at_15 = rep(c(6, 11, 5), each = 2),
    gold_diff_at_15 = c(1200, -1200, 2600, -2600, 800, -800),
    stringsAsFactors = FALSE
  )
}

test_that("kill-market outcomes expose rates and game-state behavior", {
  result <- derive_kill_market_outcomes(make_kill_market_fixture())

  expect_equal(result$assists_per_minute[[1L]], 28 / 30)
  expect_equal(result$early_pace_15[[1L]], 6 / 15)
  expect_equal(result$post_15_pace[[1L]], 14 / 15)
  expect_equal(result$damage_kill_conversion[[1L]], 20 / 110)
  expect_equal(result$duration_when_ahead[[1L]], 30)
  expect_true(is.na(result$duration_when_behind[[1L]]))
  expect_equal(result$close_minutes_when_ahead[[1L]], 30)
})

test_that("multiscale histories remain frozen before the series", {
  result <- build_kill_market_multiscale_features(
    make_kill_market_fixture(),
    half_lives = c(short = 7, medium = 30, long = 120),
    prior_games = 0
  )
  future_a <- result[result$gameid == "G3" & result$team_id == "A", ]

  expect_true(all(c(
    "hist_short_combined_kills_per_minute",
    "hist_medium_combined_kills_per_minute",
    "hist_long_combined_kills_per_minute"
  ) %in% names(result)))
  expect_true(
    future_a$latest_history_datetime < future_a$series_cutoff
  )
  expect_gt(
    future_a$hist_short_combined_kills_per_minute,
    future_a$hist_long_combined_kills_per_minute
  )
})

test_that("map features include intensity, duration and trend ratios", {
  team_features <- build_kill_market_multiscale_features(
    make_kill_market_fixture(),
    half_lives = c(short = 7, medium = 30, long = 120),
    prior_games = 1
  )
  games <- data.frame(
    gameid = c("G1", "G2", "G3"),
    competition_role = "target",
    target_valid = TRUE,
    series_eligible = TRUE,
    series_cutoff = as.POSIXct(
      c(
        "2025-01-01 12:00:00",
        "2025-01-11 12:00:00",
        "2025-01-21 12:00:00"
      ),
      tz = "UTC"
    ),
    stringsAsFactors = FALSE
  )
  maps <- assemble_map_feature_table(team_features, games)
  result <- assemble_kill_market_map_features(maps)

  expect_true(all(c(
    "kill_intensity_short",
    "kill_intensity_long",
    "kill_intensity_trend",
    "duration_level_medium",
    "early_pace_medium",
    "damage_pressure_medium",
    "objective_activity_medium"
  ) %in% names(result)))
  expect_true(all(is.finite(
    result$kill_intensity_trend[result$gameid == "G3"]
  )))
})
