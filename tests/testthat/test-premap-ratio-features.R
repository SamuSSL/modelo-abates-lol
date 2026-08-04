make_premap_team_rows <- function() {
  map_rows <- function(
    gameid,
    datetime,
    series_id,
    series_cutoff,
    map_number,
    blue_kills,
    red_kills
  ) {
    data.frame(
      gameid = rep(gameid, 2L),
      game_datetime = rep(as.POSIXct(datetime, tz = "UTC"), 2L),
      source_season = rep(2025L, 2L),
      league_canonical = rep("LCK", 2L),
      competition_role = rep("target", 2L),
      split = rep("Spring", 2L),
      map_number = rep(map_number, 2L),
      side = c("Blue", "Red"),
      team_id = c("A", "B"),
      team_name = c("Team A", "Team B"),
      opponent_id = c("B", "A"),
      opponent_name = c("Team B", "Team A"),
      game_length_minutes = rep(30, 2L),
      team_kills = c(blue_kills, red_kills),
      team_deaths = c(red_kills, blue_kills),
      series_id = rep(series_id, 2L),
      series_cutoff = rep(as.POSIXct(series_cutoff, tz = "UTC"), 2L),
      stringsAsFactors = FALSE
    )
  }
  rbind(
    map_rows(
      "g1", "2025-01-01 10:00:00", "s1",
      "2025-01-01 10:00:00", 1L, 10, 5
    ),
    map_rows(
      "g2", "2025-01-01 11:00:00", "s1",
      "2025-01-01 10:00:00", 2L, 20, 10
    ),
    map_rows(
      "g3", "2025-01-02 10:00:00", "s2",
      "2025-01-02 10:00:00", 1L, 15, 12
    )
  )
}

test_that("series cutoff freezes all maps before map one", {
  data <- make_premap_team_rows()
  features <- build_premap_ratio_features(
    data,
    cutoff_mode = "series",
    prior_games = 1
  )
  map_two <- features[
    features$gameid == "g2" & features$team_id == "A",
    ,
    drop = FALSE
  ]

  expect_equal(map_two$last5_team_games, 0)
  expect_equal(map_two$season_team_games, 0)
  expect_equal(map_two$last5_attack_ratio, 1)
})

test_that("map cutoff admits a completed earlier map but never the current map", {
  data <- make_premap_team_rows()
  features <- build_premap_ratio_features(
    data,
    cutoff_mode = "map",
    prediction_lead_minutes = 15,
    result_lag_minutes = 5,
    prior_games = 1
  )
  map_two <- features[
    features$gameid == "g2" & features$team_id == "A",
    ,
    drop = FALSE
  ]
  map_three <- features[
    features$gameid == "g3" & features$team_id == "A",
    ,
    drop = FALSE
  ]

  expect_equal(map_two$last5_team_games, 1)
  expect_equal(map_three$season_team_games, 2)
  expect_equal(map_three$season_league_games, 2)
  expect_true(all(
    features$latest_history_available_at <= features$prediction_cutoff,
    na.rm = TRUE
  ))
  expect_equal(map_three$season_attack_ratio, 5 / 3, tolerance = 1e-8)
  expect_equal(
    map_three$season_concession_ratio,
    2 / 3,
    tolerance = 1e-8
  )
})

test_that("multiplicative expectations preserve directed coherence", {
  data <- make_premap_team_rows()
  team_features <- build_premap_ratio_features(
    data,
    cutoff_mode = "series",
    prior_games = 1
  )
  maps <- assemble_premap_ratio_map_features(team_features)
  expectations <- derive_multiplicative_expectations(maps)
  row <- expectations[expectations$gameid == "g3", , drop = FALSE]

  expected_blue <- row$blue_season_league_kills_per_map *
    row$blue_season_attack_ratio *
    row$red_season_concession_ratio
  expect_equal(row$blue_mu_count_season, expected_blue)
  expect_equal(
    row$total_mu_count_season,
    row$blue_mu_count_season + row$red_mu_count_season
  )
  expect_equal(
    row$total_mu_rate_season,
    row$blue_mu_rate_season + row$red_mu_rate_season
  )
  expect_true(row$duration_season > 0)
})

test_that("team volatility is shrunk and uses only eligible history", {
  data <- make_premap_team_rows()
  features <- build_premap_ratio_features(
    data,
    cutoff_mode = "map",
    prediction_lead_minutes = 15,
    result_lag_minutes = 5,
    prior_games = 1
  )
  map_one <- features[
    features$gameid == "g1" & features$team_id == "A",
    ,
    drop = FALSE
  ]
  map_three <- features[
    features$gameid == "g3" & features$team_id == "A",
    ,
    drop = FALSE
  ]

  expect_equal(map_one$season_total_kills_sd_ratio, 1)
  expect_true(is.finite(map_three$season_total_kills_sd_ratio))
  expect_gt(map_three$season_total_kills_sd_ratio, 0)
  expect_true(is.finite(map_three$season_league_total_kills_sd))
  expect_equal(map_three$season_team_games, 2)
})
