test_that("audited exclusions remove only exact game IDs", {
  games <- data.frame(
    gameid = c("KEEP", "DROP"),
    total_kills_game = c(20L, 0L),
    stringsAsFactors = FALSE
  )
  quality_events <- data.frame(
    gameid = character(),
    code = character(),
    severity = character(),
    stringsAsFactors = FALSE
  )
  exclusions <- data.frame(
    gameid = "DROP",
    reason_code = "aborted_or_incomplete_capture",
    rationale = "Audited mismatch",
    reviewed_at = "2026-07-23",
    stringsAsFactors = FALSE
  )

  result <- apply_game_exclusions(
    games,
    quality_events,
    exclusions
  )

  expect_equal(result$games$gameid, "KEEP")
  expect_equal(result$excluded_games$gameid, "DROP")
  expect_equal(
    result$quality_events$code,
    "aborted_or_incomplete_capture"
  )
  expect_equal(result$quality_events$severity, "excluded")
})

test_that("exclusion config cannot silently reference an absent game", {
  games <- data.frame(
    gameid = "KEEP",
    total_kills_game = 20L,
    stringsAsFactors = FALSE
  )
  exclusions <- data.frame(
    gameid = "MISSING",
    reason_code = "aborted_or_incomplete_capture",
    rationale = "Audited mismatch",
    reviewed_at = "2026-07-23",
    stringsAsFactors = FALSE
  )

  expect_error(
    apply_game_exclusions(games, data.frame(), exclusions),
    "not found"
  )
})
