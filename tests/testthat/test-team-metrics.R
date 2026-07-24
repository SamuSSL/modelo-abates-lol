make_team_metric_rows <- function() {
  rows <- make_canonical_game_rows()
  rows$result <- ifelse(rows$side == "Blue", 1L, 0L)
  rows$assists <- ifelse(rows$position == "team", 20L, 4L)
  rows$firstblood <- ifelse(
    rows$position == "team" & rows$side == "Blue",
    1L,
    0L
  )
  rows$dragons <- ifelse(rows$position == "team", 2L, NA)
  rows$barons <- ifelse(rows$position == "team", 1L, NA)
  rows$heralds <- ifelse(rows$position == "team", 1L, NA)
  rows$towers <- ifelse(rows$position == "team", 7L, NA)
  rows$damagetochampions <- ifelse(
    rows$position == "team",
    60000,
    12000
  )
  rows$dpm <- ifelse(rows$position == "team", 2000, 400)
  rows$damagetakenperminute <- ifelse(
    rows$position == "team",
    1800,
    360
  )
  rows$killsat10 <- ifelse(rows$position == "team", 2L, 0L)
  rows$deathsat10 <- ifelse(rows$position == "team", 1L, 0L)
  rows$killsat15 <- ifelse(rows$position == "team", 4L, 0L)
  rows$deathsat15 <- ifelse(rows$position == "team", 3L, 0L)
  rows$golddiffat15 <- ifelse(
    rows$position == "team" & rows$side == "Blue",
    1000,
    ifelse(rows$position == "team", -1000, 0)
  )
  rows
}

test_that("team metrics derive offense, exposure, and opponent", {
  rows <- make_team_metric_rows()

  result <- build_team_map_metrics(rows)

  expect_equal(nrow(result), 2L)
  expect_setequal(result$team_id, c("blue-id", "red-id"))
  expect_equal(result$opponent_id[result$side == "Blue"], "red-id")
  expect_equal(result$opponent_id[result$side == "Red"], "blue-id")
  expect_equal(result$kills_per_minute[result$side == "Blue"], 10 / 30)
  expect_equal(result$deaths_per_minute[result$side == "Blue"], 8 / 30)
  expect_equal(result$combined_kills_per_minute, rep(18 / 30, 2L))
  expect_equal(result$combined_kills_at_15, rep(7L, 2L))
  expect_equal(result$kills_per_1000_damage[result$side == "Blue"], 10 / 60)
  expect_equal(result$assists_per_kill[result$side == "Blue"], 2)
})

test_that("team metric builder rejects malformed team structure", {
  rows <- make_team_metric_rows()
  rows <- rows[!(rows$position == "team" & rows$side == "Red"), ]

  expect_error(
    build_team_map_metrics(rows),
    "exactly two team rows"
  )
})
