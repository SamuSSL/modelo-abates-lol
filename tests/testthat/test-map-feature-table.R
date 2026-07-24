test_that("map feature table combines frozen Blue and Red histories", {
  team_features <- data.frame(
    gameid = c("G1", "G1"),
    game_datetime = as.POSIXct(
      rep("2025-01-01 12:00:00", 2L),
      tz = "UTC"
    ),
    series_cutoff = as.POSIXct(
      rep("2025-01-01 12:00:00", 2L),
      tz = "UTC"
    ),
    league_canonical = "LCK",
    side = c("Blue", "Red"),
    team_id = c("A", "B"),
    team_name = c("A", "B"),
    raw_team_games = c(20L, 30L),
    latest_history_datetime = as.POSIXct(
      rep("2024-12-20 12:00:00", 2L),
      tz = "UTC"
    ),
    hist_kills_per_minute = c(0.4, 0.3),
    effective_kills_per_minute_games = c(10, 15),
    league_prior_kills_per_minute = c(0.35, 0.35),
    stringsAsFactors = FALSE
  )
  games <- data.frame(
    gameid = "G1",
    game_datetime = as.POSIXct(
      "2025-01-01 12:00:00",
      tz = "UTC"
    ),
    series_cutoff = as.POSIXct(
      "2025-01-01 12:00:00",
      tz = "UTC"
    ),
    league_canonical = "LCK",
    total_kills_game = 25L,
    target_valid = TRUE,
    series_eligible = TRUE,
    competition_role = "target",
    stringsAsFactors = FALSE
  )

  result <- assemble_map_feature_table(team_features, games)

  expect_equal(nrow(result), 1L)
  expect_equal(result$blue_team_id, "A")
  expect_equal(result$red_team_id, "B")
  expect_equal(result$blue_hist_kills_per_minute, 0.4)
  expect_equal(result$red_hist_kills_per_minute, 0.3)
  expect_equal(result$total_kills_game, 25L)
})

test_that("map feature table rejects missing sides", {
  team_features <- data.frame(
    gameid = "G1",
    side = "Blue",
    team_id = "A",
    team_name = "A",
    raw_team_games = 1L,
    stringsAsFactors = FALSE
  )
  games <- data.frame(
    gameid = "G1",
    target_valid = TRUE,
    series_eligible = TRUE,
    competition_role = "target",
    stringsAsFactors = FALSE
  )

  expect_error(
    assemble_map_feature_table(team_features, games),
    "Blue and Red"
  )
})
