test_that("raw responses are immutable and contain no API key", {
  directory <- tempfile("bettingiscool-raw-")
  response <- list(
    endpoint = "/api/odds",
    query = list(event_id = 123),
    retrieved_at = "2026-07-28T00:00:00Z",
    status_code = 200L,
    quota_remaining = 10,
    quota_cost = 1,
    row_count = 1,
    truncated = FALSE,
    raw_text = '[{"event_id":123}]'
  )
  first <- write_bettingiscool_raw_response(response, directory)
  second <- write_bettingiscool_raw_response(response, directory)

  expect_equal(first$sha256, second$sha256)
  expect_equal(length(list.files(directory, recursive = TRUE)), 2L)
  expect_false(any(grepl("api_key", readLines(first$metadata_path))))
})

test_that("DuckDB market ingestion is idempotent", {
  connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
  initialize_bettingiscool_store(connection)
  fixtures <- data.frame(
    event_id = 123, sport_id = 12, league_id = 192553,
    league_name = "LCK", starts = "2026-01-01T12:00:00Z",
    runner_home = "A (Kills)", runner_away = "B (Kills)",
    live_status = 2, resulting_unit = "Kills", parent_id = NA,
    version = "1"
  )
  rows <- normalize_bettingiscool_fixtures(
    fixtures,
    "2026-07-28T00:00:00Z",
    paste(rep("a", 64), collapse = "")
  )
  expect_equal(append_bettingiscool_rows(
    connection, "market_fixtures", rows, "fixture_id"
  ), 1L)
  expect_equal(append_bettingiscool_rows(
    connection, "market_fixtures", rows, "fixture_id"
  ), 0L)
})

test_that("snapshot selection uses each period final timestamp", {
  snapshots <- data.frame(
    event_id = c("1", "1", "1", "1"),
    period = c(1L, 1L, 2L, 2L),
    odds_timestamp = c(
      "2026-01-01T10:00:00Z", "2026-01-01T10:08:00Z",
      "2026-01-01T10:50:00Z", "2026-01-01T11:00:00Z"
    ),
    market_status = c(1L, 1L, 1L, 1L),
    line = c(25.5, 26.5, 27.5, 28.5)
  )
  selected <- select_bettingiscool_map_snapshots(snapshots, 5)

  expect_equal(selected$line, c(25.5, 27.5))
  expect_true(all(selected$odds_timestamp < selected$market_close_time))
})

test_that("snapshot selection audits but does not trust provider cutoff", {
  snapshots <- data.frame(
    event_id = c("1", "1", "1"),
    period = c(2L, 2L, 2L),
    odds_timestamp = as.POSIXct(
      c(
        "2025-07-01 12:30:00",
        "2025-07-01 12:43:00",
        "2025-07-01 12:55:00"
      ),
      tz = "UTC"
    ),
    market_cutoff = as.POSIXct(
      rep("2025-07-01 13:00:00", 3L),
      tz = "UTC"
    ),
    market_status = c(1L, 1L, 2L),
    stringsAsFactors = FALSE
  )

  selected <- select_bettingiscool_map_snapshots(snapshots, 15)

  expect_equal(nrow(selected), 1L)
  expect_equal(
    selected$odds_timestamp,
    as.POSIXct("2025-07-01 12:30:00", tz = "UTC")
  )
  expect_equal(
    selected$market_close_time,
    as.POSIXct("2025-07-01 12:55:00", tz = "UTC")
  )
  expect_equal(
    selected$provider_market_cutoff,
    snapshots$market_cutoff[[1L]]
  )
  expect_equal(selected$provider_cutoff_minus_close_minutes, 5)
  expect_equal(selected$market_close_source, "final_main_history_timestamp")
  expect_equal(selected$snapshot_minutes_before_close, 25)
})

test_that("post-draft view selects the last prematch quote before live opens", {
  connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
  on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
  initialize_bettingiscool_store(connection)

  raw_sha256 <- paste(rep("b", 64), collapse = "")
  prematch_fixture <- normalize_bettingiscool_fixtures(
    data.frame(
      event_id = 1001, sport_id = 12, league_id = 196921,
      league_name = "LEC", starts = "2026-04-11T12:09:00Z",
      runner_home = "A (Kills)", runner_away = "B (Kills)",
      live_status = 2L, resulting_unit = "Kills", parent_id = 9001,
      version = "1"
    ),
    "2026-08-04T00:00:00Z",
    raw_sha256
  )
  live_fixture <- normalize_bettingiscool_fixtures(
    data.frame(
      event_id = 2001, sport_id = 12, league_id = 196921,
      league_name = "LEC", starts = "2026-04-11T12:09:00Z",
      runner_home = "A (Kills)", runner_away = "B (Kills)",
      live_status = 1L, resulting_unit = "Kills", parent_id = 9001,
      version = "2"
    ),
    "2026-08-04T00:00:00Z",
    raw_sha256
  )
  append_bettingiscool_rows(
    connection, "market_fixtures", prematch_fixture, "fixture_id"
  )
  append_bettingiscool_rows(
    connection, "market_live_fixtures", live_fixture, "fixture_id"
  )

  prematch_raw <- data.frame(
    event_id = rep(1001, 3), period = rep(1L, 3),
    market = rep("totals", 3), line = c(25.5, 27.5, 29.5),
    odds1 = c(1.90, 1.91, 1.92), odds2 = c(1.90, 1.89, 1.88),
    todds1 = c(2.00, 2.01, 2.02), todds2 = c(2.00, 1.99, 1.98),
    line_id = c(1, 2, 3), alt_line_id = NA,
    timestamp = c(
      "2026-04-11T12:00:00Z",
      "2026-04-11T12:09:00Z",
      "2026-04-11T12:09:20Z"
    ),
    cutoff = rep("2026-04-11T12:10:00Z", 3)
  )
  live_raw <- data.frame(
    event_id = rep(2001, 2), period = rep(1L, 2),
    market = rep("totals", 2), line = c(30.5, 31.5),
    odds1 = c(1.90, 1.91), odds2 = c(1.90, 1.89),
    todds1 = c(2.00, 2.01), todds2 = c(2.00, 1.99),
    line_id = c(10, 11), alt_line_id = NA,
    timestamp = c(
      "2026-04-11T12:09:10Z",
      "2026-04-11T12:09:30Z"
    ),
    cutoff = rep("2026-04-11T13:00:00Z", 2),
    status = rep(1L, 2)
  )
  prematch_rows <- normalize_bettingiscool_kills_odds(
    prematch_raw,
    "2026-08-04T00:00:00Z",
    snapshot_type = "history"
  )
  live_rows <- normalize_bettingiscool_kills_odds(
    live_raw,
    "2026-08-04T00:00:00Z",
    snapshot_type = "live_history"
  )
  prematch_rows <- prepare_bettingiscool_odds_rows(
    prematch_rows,
    raw_sha256
  )
  live_rows <- prepare_bettingiscool_odds_rows(live_rows, raw_sha256)
  append_bettingiscool_rows(
    connection,
    "market_odds_snapshots",
    prematch_rows,
    "snapshot_id"
  )
  append_bettingiscool_rows(
    connection,
    "market_live_odds_snapshots",
    live_rows,
    "snapshot_id"
  )

  link <- data.frame(
    link_id = "test-link", gameid = "game-1", event_id = "1001",
    period = 1L, link_status = "verified", match_method = "test",
    league_canonical = "LEC", competition = "LEC",
    team_home_market = "A", team_away_market = "B",
    market_close_time = as.POSIXct("2026-04-11 12:09:20", tz = "UTC"),
    exclusion_reason = NA_character_,
    reviewed_at = as.POSIXct("2026-08-04 00:00:00", tz = "UTC")
  )
  DBI::dbAppendTable(connection, "game_market_links", link)

  quote <- DBI::dbGetQuery(connection, "SELECT * FROM market_postdraft_quotes")

  expect_equal(nrow(quote), 1L)
  expect_equal(quote$line, 27.5)
  expect_equal(quote$freshness_seconds, 10)
  expect_equal(quote$live_open_time, as.POSIXct(
    "2026-04-11 12:09:10", tz = "UTC"
  ))
  expect_equal(quote$quote_time, as.POSIXct(
    "2026-04-11 12:09:00", tz = "UTC"
  ))
  expect_equal(quote$gameid, "game-1")
})
