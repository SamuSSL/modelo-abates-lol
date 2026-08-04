script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
raw_root <- file.path(project_root, "data", "raw", "bettingiscool")
database_path <- file.path(
  project_root, "data", "processed", "lolkills.duckdb"
)
connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = database_path)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
initialize_bettingiscool_store(connection)

metadata_paths <- list.files(
  raw_root,
  pattern = "\\.meta\\.json$",
  recursive = TRUE,
  full.names = TRUE
)
batches <- list(
  market_fixtures = list(),
  market_odds_snapshots = list(),
  market_opening = list(),
  market_closing = list(),
  market_settlements = list(),
  api_ingestion_state = list()
)
batch_ids <- stats::setNames(integer(length(batches)), names(batches))
add_batch <- function(table, rows) {
  if (nrow(rows) == 0L) {
    return(invisible(NULL))
  }
  batch_ids[[table]] <<- batch_ids[[table]] + 1L
  batches[[table]][[batch_ids[[table]]]] <<- rows
  invisible(NULL)
}
for (metadata_path in metadata_paths) {
  metadata <- jsonlite::read_json(
    metadata_path,
    simplifyVector = TRUE
  )
  body_path <- file.path(
    dirname(metadata_path),
    paste0(metadata$sha256, ".json")
  )
  if (!file.exists(body_path)) {
    stop("Resposta bruta ausente para ", metadata_path, call. = FALSE)
  }
  data <- jsonlite::fromJSON(body_path, simplifyVector = TRUE)
  data <- .bettingiscool_as_data_frame(data)
  endpoint <- as.character(metadata$endpoint)
  if (endpoint == "/api/fixtures") {
    rows <- normalize_bettingiscool_fixtures(
      data,
      metadata$retrieved_at,
      metadata$sha256
    )
    rows <- rows[
      !is.na(rows$resulting_unit) & rows$resulting_unit == "Kills",
      ,
      drop = FALSE
    ]
    add_batch("market_fixtures", rows)
  } else if (endpoint %in% c(
    "/api/odds", "/api/opening", "/api/closing"
  )) {
    required <- c(
      "event_id", "period", "market", "line",
      "odds1", "odds2", "todds1", "todds2"
    )
    if (nrow(data) > 0L && all(required %in% names(data))) {
      valid <- suppressWarnings(as.integer(data$period)) >= 1L &
        tolower(as.character(data$market)) == "totals"
      for (column in c("line", "odds1", "odds2", "todds1", "todds2")) {
        valid <- valid & is.finite(suppressWarnings(
          as.numeric(data[[column]])
        ))
      }
      data <- data[valid, , drop = FALSE]
    }
    if (nrow(data) > 0L) {
      snapshot_type <- switch(
        endpoint,
        "/api/odds" = "history",
        "/api/opening" = "opening",
        "/api/closing" = "closing"
      )
      table <- switch(
        endpoint,
        "/api/odds" = "market_odds_snapshots",
        "/api/opening" = "market_opening",
        "/api/closing" = "market_closing"
      )
      rows <- normalize_bettingiscool_kills_odds(
        data,
        metadata$retrieved_at,
        snapshot_type
      )
      rows <- prepare_bettingiscool_odds_rows(rows, metadata$sha256)
      add_batch(table, rows)
    }
  } else if (endpoint == "/api/results") {
    rows <- normalize_bettingiscool_settlements(
      data,
      metadata$retrieved_at,
      metadata$sha256
    )
    add_batch("market_settlements", rows)
  }
  query_json <- jsonlite::toJSON(metadata$query, auto_unbox = TRUE)
  state <- data.frame(
    state_id = digest::digest(
      paste(endpoint, query_json, sep = "|"),
      algo = "sha256",
      serialize = FALSE
    ),
    endpoint = endpoint,
    query_json = as.character(query_json),
    window_start = as.POSIXct(NA, tz = "UTC"),
    window_end = as.POSIXct(NA, tz = "UTC"),
    status = "complete",
    raw_sha256 = metadata$sha256,
    rows_received = as.integer(metadata$row_count),
    quota_remaining = as.numeric(metadata$quota_remaining),
    completed_at = .bettingiscool_utc(metadata$retrieved_at),
    error_message = NA_character_,
    stringsAsFactors = FALSE
  )
  add_batch("api_ingestion_state", state)
}

id_columns <- c(
  market_fixtures = "fixture_id",
  market_odds_snapshots = "snapshot_id",
  market_opening = "snapshot_id",
  market_closing = "snapshot_id",
  market_settlements = "settlement_id",
  api_ingestion_state = "state_id"
)
for (table in names(batches)) {
  if (length(batches[[table]]) == 0L) {
    next
  }
  rows <- do.call(rbind, batches[[table]])
  append_bettingiscool_rows(
    connection,
    table,
    rows,
    id_columns[[table]]
  )
}

summary <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT 'fixtures' AS table_name, COUNT(*) AS rows FROM market_fixtures",
    "UNION ALL SELECT 'history', COUNT(*) FROM market_odds_snapshots",
    "UNION ALL SELECT 'opening', COUNT(*) FROM market_opening",
    "UNION ALL SELECT 'closing', COUNT(*) FROM market_closing",
    "UNION ALL SELECT 'settlements', COUNT(*) FROM market_settlements"
  )
)
print(summary)
