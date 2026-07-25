test_that("Bayesian fold data keep team and opponent effects distinct", {
  dates <- as.POSIXct(
    c(
      "2025-01-01 12:00:00",
      "2025-01-02 12:00:00",
      "2025-02-01 12:00:00"
    ),
    tz = "UTC"
  )
  maps <- data.frame(
    gameid = c("T1", "T2", "V1"),
    game_datetime = dates,
    series_cutoff = dates,
    league_canonical = "LCK",
    blue_team_id = c("A", "A", "B"),
    blue_team_name = c("A", "A", "B"),
    red_team_id = c("B", "C", "C"),
    red_team_name = c("B", "C", "C"),
    blue_kills = c(10L, 12L, 8L),
    red_kills = c(8L, 6L, 9L),
    total_kills_game = c(18L, 18L, 17L),
    game_length_minutes = c(30, 32, 31),
    intensity = c(0.8, 0.9, 0.85),
    duration_signal = c(31, 32, 31.5),
    stringsAsFactors = FALSE
  )
  prepared <- prepare_bayesian_fold_data(
    maps[1:2, ],
    maps[3, , drop = FALSE],
    intensity_features = "intensity",
    duration_features = "duration_signal",
    development_end = "2026-01-01"
  )

  expect_equal(prepared$data$N, 2L)
  expect_equal(prepared$data$M, 1L)
  expect_false(identical(
    prepared$data$blue_team,
    prepared$data$red_team
  ))
  expect_equal(
    unname(colMeans(prepared$data$X_intensity)),
    0
  )
  expect_equal(prepared$metadata$validation$gameid, "V1")
})

test_that("Bayesian fold rejects validation leakage and 2026", {
  row <- data.frame(
    gameid = "G",
    game_datetime = as.POSIXct("2026-01-01", tz = "UTC"),
    series_cutoff = as.POSIXct("2026-01-01", tz = "UTC"),
    league_canonical = "LCK",
    blue_team_id = "A",
    blue_team_name = "A",
    red_team_id = "B",
    red_team_name = "B",
    blue_kills = 10L,
    red_kills = 8L,
    total_kills_game = 18L,
    game_length_minutes = 30,
    intensity = 0.8,
    duration_signal = 30,
    stringsAsFactors = FALSE
  )
  expect_error(
    prepare_bayesian_fold_data(
      row,
      row,
      "intensity",
      "duration_signal"
    ),
    "2026"
  )
})

test_that("posterior predictive draws form valid PMFs", {
  validation <- data.frame(
    gameid = "V1",
    league_canonical = "LCK",
    game_datetime = as.POSIXct("2025-02-01", tz = "UTC"),
    total_kills_game = 20L,
    stringsAsFactors = FALSE
  )
  fold <- data.frame(
    fold_id = "fold",
    validation_start = as.POSIXct("2025-02-01", tz = "UTC")
  )
  result <- score_bayesian_predictions(
    matrix(c(18, 19, 20, 20, 21, 22), ncol = 1),
    validation,
    fold
  )

  expect_equal(sum(result$pmf[[1L]]), 1, tolerance = 1e-12)
  expect_true(is.finite(result$crps))
  expect_true(is.finite(result$log_score))
})

test_that("secondary validation can use 2026 without changing training", {
  make_row <- function(id, date) {
    data.frame(
      gameid = id,
      game_datetime = as.POSIXct(date, tz = "UTC"),
      series_cutoff = as.POSIXct(date, tz = "UTC"),
      league_canonical = "LCK",
      blue_team_id = "A",
      blue_team_name = "A",
      red_team_id = "B",
      red_team_name = "B",
      blue_kills = 10L,
      red_kills = 8L,
      total_kills_game = 18L,
      game_length_minutes = 30,
      intensity = 0.8,
      duration_signal = 30,
      stringsAsFactors = FALSE
    )
  }
  prepared <- prepare_bayesian_fold_data(
    make_row("T", "2025-12-01"),
    make_row("V", "2026-01-10"),
    "intensity",
    "duration_signal",
    allow_secondary_validation = TRUE
  )

  expect_equal(prepared$data$N, 1L)
  expect_equal(prepared$data$M, 1L)
  expect_equal(prepared$metadata$validation$gameid, "V")
})
