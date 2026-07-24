test_that("canonical games map leagues and compute target once", {
  rows <- make_canonical_game_rows(league = "LVP SL")

  result <- build_canonical_games(rows)

  expect_equal(nrow(result$games), 1L)
  expect_equal(result$games$league_canonical, "LES")
  expect_equal(result$games$competition_role, "target")
  expect_equal(result$games$total_kills_game, 18L)
  expect_true(result$games$target_valid)
  expect_equal(nrow(result$quality_events), 0L)
})

test_that("partial rows remain eligible when required fields are complete", {
  rows <- make_canonical_game_rows()
  rows$datacompleteness <- "partial"

  result <- build_canonical_games(rows)

  expect_true(result$games$target_valid)
  expect_equal(result$games$datacompleteness, "partial")
})

test_that("invalid target is retained with an explicit quality event", {
  rows <- make_canonical_game_rows()
  rows$kills[rows$position == "top" & rows$side == "Blue"] <- 9L

  result <- build_canonical_games(rows)

  expect_false(result$games$target_valid)
  expect_match(result$games$quality_reasons, "player_kills_mismatch")
  expect_equal(result$quality_events$code, "player_kills_mismatch")
})

test_that("deaths mismatch is a warning because executions are possible", {
  rows <- make_canonical_game_rows()
  rows$deaths[rows$position == "top" & rows$side == "Blue"] <- 6L

  result <- build_canonical_games(rows)

  expect_true(result$games$target_valid)
  expect_true(any(result$quality_events$code == "player_deaths_mismatch"))
  expect_true(any(
    result$quality_events$code == "player_deaths_mismatch" &
      result$quality_events$severity == "warning"
  ))
})

test_that("excluded leagues do not enter canonical game tables", {
  target_rows <- make_canonical_game_rows("TARGET", league = "LCK")
  excluded_rows <- make_canonical_game_rows("EXCLUDED", league = "LCKC")

  result <- build_canonical_games(rbind(target_rows, excluded_rows))

  expect_equal(result$games$gameid, "TARGET")
})

test_that("series metadata freezes all maps at the first map", {
  games <- data.frame(
    gameid = c("G1", "G2", "G3"),
    league_canonical = c("LCK", "LCK", "LCK"),
    game_datetime = c(
      "2026-01-01 12:00:00",
      "2026-01-01 13:00:00",
      "2026-01-02 12:00:00"
    ),
    map_number = c(1L, 2L, 1L),
    blue_team_id = c("A", "B", "A"),
    red_team_id = c("B", "A", "B"),
    blue_team_name = c("A", "B", "A"),
    red_team_name = c("B", "A", "B"),
    stringsAsFactors = FALSE
  )

  result <- derive_series_metadata(games)

  expect_equal(result$series_id[1], result$series_id[2])
  expect_false(result$series_id[1] == result$series_id[3])
  expect_equal(
    result$series_cutoff[1:2],
    rep(as.POSIXct("2026-01-01 12:00:00", tz = "UTC"), 2L)
  )
  expect_true(all(result$series_key_quality == "derived_id"))
})

test_that("a map-number restart starts a new series on the same day", {
  games <- data.frame(
    gameid = c("G1", "G2"),
    league_canonical = c("LCK", "LCK"),
    game_datetime = c(
      "2026-01-01 12:00:00",
      "2026-01-01 18:00:00"
    ),
    map_number = c(1L, 1L),
    blue_team_id = c("A", "A"),
    red_team_id = c("B", "B"),
    blue_team_name = c("A", "A"),
    red_team_name = c("B", "B"),
    stringsAsFactors = FALSE
  )

  result <- derive_series_metadata(games)

  expect_false(result$series_id[1] == result$series_id[2])
  expect_true(all(result$series_key_quality == "derived_id"))
  expect_true(all(result$series_eligible))
})

test_that("same map at the same timestamp remains ambiguous", {
  games <- data.frame(
    gameid = c("G1", "G2"),
    league_canonical = c("LCK", "LCK"),
    game_datetime = c(
      "2026-01-01 12:00:00",
      "2026-01-01 12:00:00"
    ),
    map_number = c(1L, 1L),
    blue_team_id = c("A", "A"),
    red_team_id = c("B", "B"),
    blue_team_name = c("A", "A"),
    red_team_name = c("B", "B"),
    stringsAsFactors = FALSE
  )

  result <- derive_series_metadata(games)

  expect_true(all(result$series_key_quality == "ambiguous"))
  expect_false(any(result$series_eligible))
})
