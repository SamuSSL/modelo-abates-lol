test_that("target sums team kills exactly once", {
  rows <- make_valid_game_rows()

  target <- build_game_targets(rows)

  expect_equal(target$blue_kills, 10L)
  expect_equal(target$red_kills, 8L)
  expect_equal(target$total_kills_game, 18L)
  expect_false(target$total_kills_game == sum(rows$kills) + sum(rows$deaths))
})

test_that("target rejects disagreement between team and player kills", {
  rows <- make_valid_game_rows()
  rows$kills[rows$side == "Blue" & rows$position == "top"] <- 9L

  expect_error(
    build_game_targets(rows),
    "Player kills do not match team kills"
  )
})

test_that("target rejects missing or duplicated team rows", {
  rows <- make_valid_game_rows()
  missing_team <- rows[rows$participantid != "200", ]
  duplicated_team <- rbind(rows, rows[rows$participantid == "100", ])

  expect_error(build_game_targets(missing_team), "exactly two team rows")
  expect_error(build_game_targets(duplicated_team), "exactly two team rows")
})

test_that("target can process more than one valid game", {
  rows <- rbind(
    make_valid_game_rows("GAME_1"),
    make_valid_game_rows("GAME_2")
  )

  targets <- build_game_targets(rows)

  expect_equal(targets$gameid, c("GAME_1", "GAME_2"))
  expect_equal(targets$total_kills_game, c(18L, 18L))
})

