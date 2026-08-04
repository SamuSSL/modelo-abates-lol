script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
arguments <- commandArgs(trailingOnly = TRUE)
mode <- if (length(arguments) > 0L) tolower(arguments[[1L]]) else "coverage"
if (!mode %in% c("coverage", "history")) {
  stop("Modo deve ser coverage ou history.", call. = FALSE)
}
raw_root <- file.path(project_root, "data", "raw", "bettingiscool")
database_path <- file.path(
  project_root,
  "data",
  "processed",
  "lolkills.duckdb"
)
connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = database_path)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
initialize_bettingiscool_store(connection)

fixtures <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT * EXCLUDE (fixture_rank) FROM (",
    "SELECT *, ROW_NUMBER() OVER (PARTITION BY event_id",
    "ORDER BY retrieved_at DESC) AS fixture_rank",
    "FROM market_fixtures WHERE resulting_unit = 'Kills')",
    "WHERE fixture_rank = 1"
  )
)
fixture_index <- split(
  seq_len(nrow(fixtures)),
  as.character(fixtures$event_id)
)

state_id <- function(endpoint, query) {
  digest::digest(
    paste(endpoint, jsonlite::toJSON(query, auto_unbox = TRUE), sep = "|"),
    algo = "sha256",
    serialize = FALSE
  )
}

state_complete <- function(endpoint, query) {
  result <- DBI::dbGetQuery(
    connection,
    "SELECT status FROM api_ingestion_state WHERE state_id = ?",
    params = list(state_id(endpoint, query))
  )
  nrow(result) == 1L && identical(result$status[[1L]], "complete")
}

record_state <- function(metadata) {
  query <- metadata$query
  row <- data.frame(
    state_id = state_id(metadata$endpoint, query),
    endpoint = metadata$endpoint,
    query_json = jsonlite::toJSON(query, auto_unbox = TRUE),
    window_start = as.POSIXct(NA, tz = "UTC"),
    window_end = as.POSIXct(NA, tz = "UTC"),
    status = "complete",
    raw_sha256 = as.character(metadata$sha256),
    rows_received = as.integer(metadata$row_count),
    quota_remaining = as.numeric(metadata$quota_remaining),
    completed_at = .bettingiscool_utc(metadata$retrieved_at),
    error_message = NA_character_,
    stringsAsFactors = FALSE
  )
  .bettingiscool_append_unique(
    connection,
    "api_ingestion_state",
    row,
    "state_id"
  )
}

directories <- if (mode == "coverage") {
  c("api_opening", "api_closing")
} else {
  "api_odds"
}
metadata_files <- unlist(lapply(directories, function(directory) {
  list.files(
    file.path(raw_root, directory),
    pattern = "\\.meta\\.json$",
    full.names = TRUE
  )
}), use.names = FALSE)

requests_imported <- 0L
rows_inserted <- 0L
for (metadata_path in metadata_files) {
  metadata <- jsonlite::read_json(metadata_path, simplifyVector = TRUE)
  query <- metadata$query
  market <- if ("market" %in% names(query)) {
    tolower(as.character(query$market))
  } else {
    ""
  }
  if (!market %in% c("home_totals", "away_totals")) {
    next
  }
  is_history <- identical(metadata$endpoint, "/api/odds") &&
    identical(as.integer(query$full_history), 1L) &&
    identical(as.integer(query$main_lines_only), 1L)
  is_coverage <- metadata$endpoint %in% c("/api/opening", "/api/closing")
  if (
    (mode == "history" && !is_history) ||
      (mode == "coverage" && !is_coverage)
  ) {
    next
  }
  if (state_complete(metadata$endpoint, query)) {
    next
  }
  event_id <- as.character(query$event_id)
  fixture_rows <- fixture_index[[event_id]]
  if (is.null(fixture_rows) || length(fixture_rows) != 1L) {
    next
  }
  body_path <- file.path(
    dirname(metadata_path),
    paste0(metadata$sha256, ".json")
  )
  if (!file.exists(body_path)) {
    next
  }
  odds <- jsonlite::fromJSON(body_path, simplifyDataFrame = TRUE)
  odds <- .bettingiscool_as_data_frame(odds)
  if (nrow(odds) > 0L) {
    valid <- suppressWarnings(as.integer(odds$period)) >= 1L &
      tolower(as.character(odds$market)) == market
    odds <- odds[valid, , drop = FALSE]
  }
  if (nrow(odds) > 0L) {
    snapshot_type <- if (metadata$endpoint == "/api/opening") {
      "opening"
    } else if (metadata$endpoint == "/api/closing") {
      "closing"
    } else {
      "history"
    }
    table <- if (snapshot_type == "opening") {
      "market_team_totals_opening"
    } else if (snapshot_type == "closing") {
      "market_team_totals_closing"
    } else {
      "market_team_totals_snapshots"
    }
    rows <- normalize_bettingiscool_team_totals_odds(
      odds,
      metadata$retrieved_at,
      snapshot_type,
      fixtures[fixture_rows, , drop = FALSE]
    )
    rows$raw_sha256 <- as.character(metadata$sha256)
    rows_inserted <- rows_inserted + append_bettingiscool_rows(
      connection,
      table,
      rows,
      "team_total_snapshot_id"
    )
  }
  record_state(metadata)
  requests_imported <- requests_imported + 1L
}

summary_row <- data.frame(
  mode = mode,
  metadata_files_scanned = length(metadata_files),
  requests_imported = requests_imported,
  rows_inserted = rows_inserted,
  imported_at = as.POSIXct(Sys.time(), tz = "UTC"),
  stringsAsFactors = FALSE
)
artifact_dir <- file.path(
  project_root,
  "artifacts",
  "bettingiscool_team_totals"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  summary_row,
  file.path(artifact_dir, paste0("raw_import_", mode, "_summary.csv")),
  row.names = FALSE
)
print(summary_row, row.names = FALSE)
