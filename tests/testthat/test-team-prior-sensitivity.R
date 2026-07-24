test_that("prior sensitivity compares the same future maps without holdout", {
  training_dates <- seq(
    as.POSIXct("2022-09-01 12:00:00", tz = "UTC"),
    by = "2 days",
    length.out = 60L
  )
  validation_dates <- seq(
    as.POSIXct("2023-01-05 12:00:00", tz = "UTC"),
    by = "7 days",
    length.out = 6L
  )
  holdout_date <- as.POSIXct("2026-01-05 12:00:00", tz = "UTC")
  dates <- c(training_dates, validation_dates, holdout_date)
  observed <- as.integer(
    round(24 + 4 * sin(seq_along(dates) / 3))
  )
  make_maps <- function(prior_games) {
    data.frame(
      gameid = paste0("G", seq_along(dates)),
      game_datetime = dates,
      series_cutoff = dates,
      league_canonical = "LCK",
      total_kills_game = observed,
      pace = 0.8 + observed / (100 + prior_games),
      blue_raw_team_games = seq_along(dates),
      red_raw_team_games = rev(seq_along(dates)),
      stringsAsFactors = FALSE
    )
  }
  map_tables <- list(
    prior10 = make_maps(10),
    prior20 = make_maps(20)
  )
  folds <- data.frame(
    fold_id = "2023_q1",
    validation_start = "2023-01-01 00:00:00",
    validation_end = "2023-04-01 00:00:00",
    stringsAsFactors = FALSE
  )

  result <- evaluate_team_prior_sensitivity(
    map_tables = map_tables,
    prior_grid_games = c(10, 20),
    folds = folds,
    holdout_start = "2026-01-01 00:00:00",
    training_start = "2022-01-01 00:00:00",
    half_life_days = 60
  )

  expect_equal(
    sort(unique(result$map_metrics$candidate_id)),
    c("nb_pace_prior10", "nb_pace_prior20")
  )
  candidate_counts <- table(result$map_metrics$candidate_id)
  expect_equal(
    as.integer(candidate_counts),
    c(6L, 6L)
  )
  expect_equal(
    names(candidate_counts),
    c("nb_pace_prior10", "nb_pace_prior20")
  )
  expect_equal(length(unique(result$map_metrics$gameid)), 6L)
  expect_true(all(result$map_metrics$game_datetime <
    as.POSIXct("2026-01-01", tz = "UTC")))
  expect_equal(sort(result$summary$prior_games), c(10, 20))
  expect_true("minimum_raw_team_games" %in%
    names(result$map_metrics))
})

test_that("prior sensitivity rejects mismatched table names", {
  maps <- data.frame(
    gameid = "G1",
    game_datetime = as.POSIXct("2022-01-01", tz = "UTC"),
    series_cutoff = as.POSIXct("2022-01-01", tz = "UTC"),
    league_canonical = "LCK",
    total_kills_game = 20L,
    pace = 0.8,
    stringsAsFactors = FALSE
  )

  expect_error(
    evaluate_team_prior_sensitivity(
      map_tables = list(wrong_name = maps),
      prior_grid_games = 10,
      folds = data.frame(
        fold_id = "2023_q1",
        validation_start = "2023-01-01",
        validation_end = "2023-04-01"
      ),
      holdout_start = "2026-01-01"
    ),
    "prior10"
  )
})
