test_that("processed store writes DuckDB and Parquet with matching rows", {
  output_dir <- tempfile("processed-")
  dir.create(output_dir)
  database_path <- file.path(output_dir, "lolkills.duckdb")
  games <- data.frame(
    gameid = c("G1", "G2"),
    total_kills_game = c(18L, 25L),
    stringsAsFactors = FALSE
  )
  events <- data.frame(
    gameid = "G2",
    code = "player_deaths_mismatch",
    severity = "warning",
    stringsAsFactors = FALSE
  )
  excluded <- data.frame(
    gameid = "G3",
    reason_code = "aborted_or_incomplete_capture",
    stringsAsFactors = FALSE
  )

  result <- write_processed_store(
    games,
    events,
    output_dir,
    database_path,
    excluded_games = excluded
  )

  expect_true(file.exists(result$database))
  expect_true(file.exists(result$canonical_games_parquet))
  expect_true(file.exists(result$quality_events_parquet))
  expect_true(file.exists(result$excluded_games_parquet))

  connection <- DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = result$database,
    read_only = TRUE
  )
  on.exit(
    DBI::dbDisconnect(connection, shutdown = TRUE),
    add = TRUE
  )
  expect_equal(
    DBI::dbGetQuery(
      connection,
      "SELECT COUNT(*) AS n FROM canonical_games"
    )$n,
    2
  )
  expect_equal(
    DBI::dbGetQuery(
      connection,
      "SELECT COUNT(*) AS n FROM game_quality_events"
    )$n,
    1
  )
  expect_equal(
    DBI::dbGetQuery(
      connection,
      "SELECT COUNT(*) AS n FROM excluded_games"
    )$n,
    1
  )
})
