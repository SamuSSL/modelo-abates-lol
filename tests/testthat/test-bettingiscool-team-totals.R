test_that("team-total contract fixes Over and Under semantics", {
  odds <- data.frame(
    event_id = c("kills-1", "kills-1"),
    period = c(2L, 2L),
    market = c("home_totals", "away_totals"),
    line = c(14.5, 9.5),
    odds1 = c(1.9, 2.1),
    odds2 = c(1.85, 1.7),
    todds1 = c(2, 2.25),
    todds2 = c(2, 1.8),
    timestamp = c(
      "2025-05-01T10:40:00Z",
      "2025-05-01T10:40:00Z"
    ),
    cutoff = c(
      "2025-05-01T11:00:00Z",
      "2025-05-01T11:00:00Z"
    ),
    status = c(1L, 1L),
    stringsAsFactors = FALSE
  )
  fixture <- data.frame(
    event_id = "kills-1",
    runner_home = "Team A (Kills)",
    runner_away = "Team B (Kills)",
    resulting_unit = "Kills"
  )
  normalized <- normalize_bettingiscool_team_totals_odds(
    odds,
    "2025-05-02T00:00:00Z",
    fixture = fixture
  )
  probabilities <- derive_team_total_probabilities(normalized)

  expect_equal(normalized$team_side, c("home", "away"))
  expect_equal(normalized$team_name, c("Team A", "Team B"))
  expect_equal(normalized$odds_over, odds$odds1)
  expect_equal(normalized$odds_under, odds$odds2)
  expect_equal(probabilities$p_over + probabilities$p_under, c(1, 1))
})

test_that("team-total snapshot selection keeps markets separate", {
  snapshots <- data.frame(
    event_id = rep("kills-1", 6L),
    period = rep(1L, 6L),
    market = rep(c("home_totals", "away_totals"), each = 3L),
    odds_timestamp = c(
      "2025-05-01T10:20:00Z",
      "2025-05-01T10:40:00Z",
      "2025-05-01T11:00:00Z",
      "2025-05-01T10:25:00Z",
      "2025-05-01T10:45:00Z",
      "2025-05-01T11:05:00Z"
    ),
    market_cutoff = rep("2025-05-01T11:10:00Z", 6L),
    market_status = rep(1L, 6L),
    line = c(10.5, 11.5, 11.5, 14.5, 15.5, 15.5),
    stringsAsFactors = FALSE
  )
  selected <- select_bettingiscool_team_total_snapshots(snapshots)

  expect_equal(nrow(selected), 2L)
  expect_equal(sort(selected$line), c(11.5, 15.5))
  expect_true(all(selected$snapshot_minutes_before_close == 20))
})

test_that("team-total storage is idempotent", {
  connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
  initialize_bettingiscool_store(connection)
  row <- data.frame(
    team_total_snapshot_id = "id-1",
    provider = "bettingiscool",
    event_id = "kills-1",
    period = 1L,
    market = "home_totals",
    team_side = "home",
    team_name = "Team A",
    line = 10.5,
    line_id = NA_character_,
    alt_line_id = NA_character_,
    odds_over = 1.9,
    odds_under = 1.9,
    true_odds_over = 2,
    true_odds_under = 2,
    odds_timestamp = as.POSIXct("2025-05-01 10:00:00", tz = "UTC"),
    market_cutoff = as.POSIXct("2025-05-01 11:00:00", tz = "UTC"),
    market_status = 1L,
    max_win = 100,
    snapshot_type = "history",
    retrieved_at = as.POSIXct("2025-05-02 00:00:00", tz = "UTC"),
    raw_sha256 = paste(rep("a", 64), collapse = ""),
    stringsAsFactors = FALSE
  )

  expect_equal(append_bettingiscool_rows(
    connection,
    "market_team_totals_snapshots",
    row,
    "team_total_snapshot_id"
  ), 1L)
  expect_equal(append_bettingiscool_rows(
    connection,
    "market_team_totals_snapshots",
    row,
    "team_total_snapshot_id"
  ), 0L)
})

test_that("closing selector uses the final line of each team market", {
  snapshots <- data.frame(
    event_id = rep("kills-1", 4L),
    period = rep(1L, 4L),
    market = c(
      "home_totals",
      "home_totals",
      "away_totals",
      "away_totals"
    ),
    odds_timestamp = c(
      "2025-05-01T10:00:00Z",
      "2025-05-01T10:10:00Z",
      "2025-05-01T10:05:00Z",
      "2025-05-01T10:15:00Z"
    ),
    line = c(10.5, 11.5, 14.5, 13.5),
    true_odds_over = rep(2, 4L),
    true_odds_under = rep(2, 4L),
    stringsAsFactors = FALSE
  )

  selected <- select_bettingiscool_team_total_endpoint_rows(
    snapshots,
    "closing"
  )

  expect_equal(nrow(selected), 2L)
  expect_equal(sort(selected$line), c(11.5, 13.5))
})
