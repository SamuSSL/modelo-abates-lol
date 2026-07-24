test_that("team snapshot includes the latest completed map", {
  metrics <- data.frame(
    gameid = c("G1", "G1"),
    game_datetime = as.POSIXct(
      rep("2026-01-01 12:00:00", 2L),
      tz = "UTC"
    ),
    series_cutoff = as.POSIXct(
      rep("2026-01-01 12:00:00", 2L),
      tz = "UTC"
    ),
    league_canonical = "LCK",
    competition_role = "target",
    side = c("Blue", "Red"),
    team_id = c("blue", "red"),
    team_name = c("Blue", "Red"),
    combined_kills_per_minute = c(0.8, 0.8),
    stringsAsFactors = FALSE
  )
  snapshot <- build_team_feature_snapshot(
    metrics,
    metric_names = "combined_kills_per_minute",
    snapshot_cutoff = as.POSIXct(
      "2026-01-10 00:00:00",
      tz = "UTC"
    ),
    half_life_days = 60,
    prior_games = 0
  )

  expect_equal(nrow(snapshot), 2L)
  expect_true(all(snapshot$raw_team_games > 0L))
  expect_true(all(
    snapshot$latest_history_datetime < snapshot$series_cutoff
  ))
})

test_that("player snapshot contains one row per known player and role", {
  metrics <- data.frame(
    gameid = c("G1", "G2"),
    game_datetime = as.POSIXct(
      c("2025-01-01", "2025-01-02"),
      tz = "UTC"
    ),
    series_cutoff = as.POSIXct(
      c("2025-01-01", "2025-01-02"),
      tz = "UTC"
    ),
    league_canonical = "LCK",
    competition_role = "target",
    side = "Blue",
    position = "top",
    player_id = "p1",
    player_name = "Player",
    champion = "A",
    conflict_involvement_per_minute = c(1, 2),
    stringsAsFactors = FALSE
  )
  snapshot <- build_player_feature_snapshot(
    metrics,
    metric_names = "conflict_involvement_per_minute",
    snapshot_cutoff = as.POSIXct("2025-02-01", tz = "UTC"),
    half_life_days = 60,
    prior_games = 0
  )

  expect_equal(nrow(snapshot), 1L)
  expect_equal(snapshot$raw_player_games, 2L)
})
