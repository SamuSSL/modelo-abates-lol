.sql_path <- function(path) {
  normalized <- normalizePath(
    path,
    winslash = "/",
    mustWork = FALSE
  )
  gsub("'", "''", normalized, fixed = TRUE)
}

#' Write canonical data to DuckDB and Parquet
#'
#' @param games Canonical game records.
#' @param quality_events Game-level quality events.
#' @param output_dir Directory for Parquet files.
#' @param database_path Path to the DuckDB database.
#' @param excluded_games Optional audited excluded-game records.
#' @return Named paths to the generated storage files.
#' @export
write_processed_store <- function(
  games,
  quality_events,
  output_dir,
  database_path,
  excluded_games = NULL
) {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(
    dirname(database_path),
    recursive = TRUE,
    showWarnings = FALSE
  )

  canonical_path <- file.path(output_dir, "canonical_games.parquet")
  quality_path <- file.path(output_dir, "game_quality_events.parquet")
  excluded_path <- file.path(output_dir, "excluded_games.parquet")
  existing_parquet <- c(canonical_path, quality_path)
  if (!is.null(excluded_games)) {
    existing_parquet <- c(existing_parquet, excluded_path)
  }
  existing_parquet <- existing_parquet[file.exists(existing_parquet)]
  if (length(existing_parquet) > 0L) {
    unlink(existing_parquet)
  }

  connection <- DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = database_path
  )
  on.exit(
    DBI::dbDisconnect(connection, shutdown = TRUE),
    add = TRUE
  )

  DBI::dbWriteTable(
    connection,
    "canonical_games",
    games,
    overwrite = TRUE
  )
  DBI::dbWriteTable(
    connection,
    "game_quality_events",
    quality_events,
    overwrite = TRUE
  )
  if (!is.null(excluded_games)) {
    DBI::dbWriteTable(
      connection,
      "excluded_games",
      excluded_games,
      overwrite = TRUE
    )
  }
  DBI::dbExecute(
    connection,
    paste0(
      "COPY canonical_games TO '",
      .sql_path(canonical_path),
      "' (FORMAT PARQUET)"
    )
  )
  DBI::dbExecute(
    connection,
    paste0(
      "COPY game_quality_events TO '",
      .sql_path(quality_path),
      "' (FORMAT PARQUET)"
    )
  )
  if (!is.null(excluded_games)) {
    DBI::dbExecute(
      connection,
      paste0(
        "COPY excluded_games TO '",
        .sql_path(excluded_path),
        "' (FORMAT PARQUET)"
      )
    )
  }

  paths <- list(
    database = normalizePath(
      database_path,
      winslash = "/",
      mustWork = TRUE
    ),
    canonical_games_parquet = normalizePath(
      canonical_path,
      winslash = "/",
      mustWork = TRUE
    ),
    quality_events_parquet = normalizePath(
      quality_path,
      winslash = "/",
      mustWork = TRUE
    )
  )
  if (!is.null(excluded_games)) {
    paths$excluded_games_parquet <- normalizePath(
      excluded_path,
      winslash = "/",
      mustWork = TRUE
    )
  }
  paths
}
