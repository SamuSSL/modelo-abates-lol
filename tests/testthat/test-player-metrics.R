test_that("player map metrics derive stable conflict indicators", {
  rows <- make_canonical_game_rows()
  rows$assists <- c(rep(2L, 10L), 20L, 18L)
  rows$dpm <- c(rep(500, 10L), 2500, 2400)
  rows$damageshare <- c(rep(0.2, 10L), NA, NA)
  rows$earnedgoldshare <- c(rep(0.2, 10L), NA, NA)
  rows$visionscore <- c(rep(30, 10L), NA, NA)

  result <- build_player_map_metrics(rows)

  expect_equal(nrow(result), 10L)
  expect_false(any(result$position == "team"))
  expect_equal(result$game_length_minutes, rep(30, 10L))
  expect_equal(
    result$kills_assists_per_minute[[1L]],
    (2 + 2) / 30
  )
  expect_equal(
    result$deaths_per_minute[[1L]],
    1 / 30
  )
  expect_equal(
    result$conflict_involvement_per_minute[[1L]],
    (2 + 2 + 1) / 30
  )
  expect_equal(result$kill_participation[[1L]], 0.4)
  expect_equal(result$vision_score_per_minute[[1L]], 1)
})

test_that("player map metrics preserve missing IDs for later audit", {
  rows <- make_canonical_game_rows()
  rows$assists <- 0L
  rows$dpm <- 0
  rows$damageshare <- 0
  rows$earnedgoldshare <- 0
  rows$visionscore <- 0
  rows$playerid[[1L]] <- ""

  result <- build_player_map_metrics(rows)

  expect_true(is.na(result$player_id[[1L]]))
  expect_equal(result$player_name[[1L]], "Player 1")
})

test_that("player metric schema declares required source fields", {
  required <- player_metric_oe_columns()

  expect_true(all(c(
    "assists",
    "dpm",
    "damageshare",
    "earnedgoldshare",
    "visionscore"
  ) %in% required))
})
