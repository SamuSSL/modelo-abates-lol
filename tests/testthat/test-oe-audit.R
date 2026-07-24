make_audit_rows <- function() {
  rows <- rbind(
    make_valid_game_rows("GAME_1"),
    make_valid_game_rows("GAME_2")
  )
  rows$datacompleteness <- "complete"
  rows$league <- "LCK"
  rows$year <- 2026L
  rows$split <- "Spring"
  rows$playoffs <- 0L
  rows$date <- rep(
    c("2026-01-01 12:00:00", "2026-01-01 13:00:00"),
    each = 12L
  )
  rows$game <- rep(c(1L, 2L), each = 12L)
  rows$patch <- "26.1"
  rows$playername <- ifelse(rows$position == "team", NA, "Player")
  rows$playerid <- ifelse(rows$position == "team", NA, "player-id")
  rows$teamname <- ifelse(rows$side == "Blue", "Blue Team", "Red Team")
  rows$teamid <- ifelse(rows$side == "Blue", "blue-id", "red-id")
  rows$champion <- ifelse(rows$position == "team", NA, "Champion")
  rows$gamelength <- 1800L
  rows[, required_oe_columns()]
}

test_that("file audit confirms the expected 12-row game structure", {
  path <- tempfile(fileext = ".csv")
  utils::write.csv(make_audit_rows(), path, row.names = FALSE, na = "")

  audit <- audit_oe_file(path)

  expect_equal(audit$row_count, 24L)
  expect_equal(audit$game_count, 2L)
  expect_equal(audit$games_with_12_rows, 2L)
  expect_equal(audit$games_with_invalid_row_count, 0L)
  expect_equal(audit$team_row_count, 4L)
  expect_true(audit$schema_valid)
})

test_that("file audit reports games with incomplete row structure", {
  rows <- make_audit_rows()
  rows <- rows[-1L, ]
  path <- tempfile(fileext = ".csv")
  utils::write.csv(rows, path, row.names = FALSE, na = "")

  audit <- audit_oe_file(path)

  expect_equal(audit$game_count, 2L)
  expect_equal(audit$games_with_12_rows, 1L)
  expect_equal(audit$games_with_invalid_row_count, 1L)
})

