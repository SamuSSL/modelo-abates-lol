make_rolling_team_fixture <- function() {
  data.frame(
    gameid = c("G1", "G1", "G2", "G2", "G3", "G3"),
    game_datetime = as.POSIXct(
      c(
        "2024-01-01 12:00:00",
        "2024-01-01 12:00:00",
        "2024-01-01 13:00:00",
        "2024-01-01 13:00:00",
        "2024-02-01 12:00:00",
        "2024-02-01 12:00:00"
      ),
      tz = "UTC"
    ),
    series_cutoff = as.POSIXct(
      c(
        "2024-01-01 12:00:00",
        "2024-01-01 12:00:00",
        "2024-01-01 12:00:00",
        "2024-01-01 12:00:00",
        "2024-02-01 12:00:00",
        "2024-02-01 12:00:00"
      ),
      tz = "UTC"
    ),
    league_canonical = "LCK",
    competition_role = "target",
    side = rep(c("Blue", "Red"), 3L),
    team_id = rep(c("A", "B"), 3L),
    team_name = rep(c("A", "B"), 3L),
    kills_per_minute = c(1.0, 0.2, 0.8, 0.3, 0.7, 0.4),
    stringsAsFactors = FALSE
  )
}

test_that("all maps in a series share frozen pre-series features", {
  result <- build_team_rolling_features(
    make_rolling_team_fixture(),
    metric_names = "kills_per_minute",
    half_life_days = 60,
    prior_games = 2
  )

  first_series <- result[result$gameid %in% c("G1", "G2"), ]
  expect_true(all(is.na(first_series$hist_kills_per_minute)))
  expect_equal(first_series$raw_team_games, rep(0L, 4L))

  future_a <- result[result$gameid == "G3" & result$team_id == "A", ]
  expect_equal(future_a$raw_team_games, 2L)
  expect_true(future_a$hist_kills_per_minute < 0.9)
  expect_true(future_a$hist_kills_per_minute > 0.5)
})

test_that("rolling features never use outcomes at or after cutoff", {
  rows <- make_rolling_team_fixture()
  result <- build_team_rolling_features(
    rows,
    metric_names = "kills_per_minute",
    half_life_days = 60,
    prior_games = 2
  )

  g3 <- result[result$gameid == "G3", ]
  expect_true(all(g3$latest_history_datetime < g3$series_cutoff))
  expect_equal(g3$raw_team_games, rep(2L, 2L))
})
