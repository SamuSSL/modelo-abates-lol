make_dynamic_rating_fixture <- function() {
  timestamps <- as.POSIXct(
    rep(
      c(
        "2024-01-01 12:00:00",
        "2024-01-11 12:00:00",
        "2024-01-21 12:00:00"
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
    kills_per_minute = c(0.2, 0.2, 0.8, 0.2, 0.5, 0.3),
    deaths_per_minute = c(0.2, 0.2, 0.1, 0.8, 0.3, 0.5),
    combined_kills_per_minute = c(0.4, 0.4, 0.9, 1.0, 0.8, 0.8),
    kills_at_15 = c(4, 2, 8, 1, 4, 3),
    deaths_at_15 = c(2, 4, 1, 8, 3, 4),
    gold_diff_at_15 = c(500, -500, 2500, -2500, 400, -400),
    game_length_minutes = c(31, 31, 24, 24, 30, 30),
    result = c(1, 0, 1, 0, 1, 0),
    stringsAsFactors = FALSE
  )
}

test_that("behavior outcomes distinguish ahead, behind and snowball maps", {
  result <- derive_team_behavior_outcomes(
    make_dynamic_rating_fixture(),
    early_kill_lead = 2
  )

  expect_true(is.finite(result$pace_when_ahead[[1L]]))
  expect_true(is.na(result$pace_when_behind[[1L]]))
  expect_equal(result$snowball_win_conversion[[1L]], 1)
  expect_equal(result$snowball_close_minutes[[1L]], 31)
  expect_true(is.na(result$snowball_win_conversion[[2L]]))
})

test_that("dynamic ratings are frozen and relative to league and global pace", {
  result <- build_team_dynamic_ratings(
    make_dynamic_rating_fixture(),
    rating_half_life_days = 60,
    short_half_life_days = 5,
    long_half_life_days = 120,
    prior_games = 0
  )
  future_a <- result[result$gameid == "G3" & result$team_id == "A", ]

  expect_true(
    future_a$latest_history_datetime < future_a$series_cutoff
  )
  expect_gt(future_a$rating_attack_league, 100)
  expect_gt(future_a$rating_defense_league, 100)
  expect_true(is.finite(future_a$rating_attack_global))
  expect_gt(future_a$momentum_bloodiness, 0)
  expect_true(is.finite(future_a$snowball_index_league))
  expect_true(
    future_a$behavior_ahead_profile %in%
      c("peaceful", "neutral", "aggressive")
  )
})

test_that("rolling team histories expose a separate global prior", {
  fixture <- make_dynamic_rating_fixture()
  result <- build_team_rolling_features(
    fixture,
    metric_names = "kills_per_minute",
    half_life_days = 60,
    prior_games = 2
  )

  expect_true("global_prior_kills_per_minute" %in% names(result))
  expect_true("league_peer_prior_kills_per_minute" %in% names(result))
  expect_true(is.finite(
    result$global_prior_kills_per_minute[result$gameid == "G3"][[1L]]
  ))
  expect_true(is.finite(
    result$league_peer_prior_kills_per_minute[
      result$gameid == "G3"
    ][[1L]]
  ))
})
