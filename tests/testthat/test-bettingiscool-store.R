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
