script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "bettingiscool.yml"
))
if (!nzchar(Sys.getenv("BETTINGISCOOL_API_KEY", unset = ""))) {
  stop(
    "Defina BETTINGISCOOL_API_KEY no processo antes da coleta.",
    call. = FALSE
  )
}

processed_dir <- file.path(project_root, "data", "processed")
raw_dir <- file.path(project_root, "data", "raw", "bettingiscool")
database_path <- file.path(processed_dir, "lolkills.duckdb")
dir.create(processed_dir, recursive = TRUE, showWarnings = FALSE)
connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = database_path)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
initialize_bettingiscool_store(connection)

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

request_and_store <- function(endpoint, query) {
  response <- bettingiscool_request(
    endpoint,
    query = query,
    max_retries = config$collection$maximum_retries
  )
  raw <- write_bettingiscool_raw_response(response, raw_dir)
  response$raw_sha256 <- raw$sha256
  reserve <- as.numeric(config$collection$live_quota_reserve_tokens)
  if (
    isTRUE(response$truncated) ||
      (
        is.finite(response$quota_remaining) &&
          response$quota_remaining < reserve
      )
  ) {
    stop(
      "Coleta live interrompida pelo guardrail de quota/truncamento.",
      call. = FALSE
    )
  }
  response
}

record_state <- function(endpoint, query, response) {
  row <- data.frame(
    state_id = state_id(endpoint, query),
    endpoint = endpoint,
    query_json = jsonlite::toJSON(query, auto_unbox = TRUE),
    window_start = as.POSIXct(NA, tz = "UTC"),
    window_end = as.POSIXct(NA, tz = "UTC"),
    status = "complete",
    raw_sha256 = response$raw_sha256,
    rows_received = as.integer(response$row_count),
    quota_remaining = response$quota_remaining,
    completed_at = as.POSIXct(Sys.time(), tz = "UTC"),
    error_message = NA_character_,
    stringsAsFactors = FALSE
  )
  append_bettingiscool_rows(
    connection,
    "api_ingestion_state",
    row,
    "state_id"
  )
}

parent_events <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT DISTINCT f.parent_id",
    "FROM game_market_links l",
    "JOIN market_fixtures f ON f.event_id = l.event_id",
    "WHERE l.link_status = 'verified'",
    "AND f.resulting_unit = 'Kills'",
    "AND f.parent_id IS NOT NULL",
    "AND f.starts >= ?",
    "ORDER BY f.parent_id"
  ),
  params = list(as.POSIXct(
    config$coverage$live_history_start,
    tz = "UTC"
  ))
)$parent_id

for (index in seq_along(parent_events)) {
  parent_id <- parent_events[[index]]
  query <- list(
    parent_id = as.integer(parent_id),
    live = 1L,
    limit = 100L
  )
  if (!state_complete("/api/fixtures", query)) {
    response <- request_and_store("/api/fixtures", query)
    fixtures <- normalize_bettingiscool_fixtures(
      response$data,
      response$retrieved_at,
      response$raw_sha256
    )
    fixtures <- fixtures[
      !is.na(fixtures$resulting_unit) &
        fixtures$resulting_unit == "Kills" &
        fixtures$live_status == 1L,
      ,
      drop = FALSE
    ]
    append_bettingiscool_rows(
      connection,
      "market_live_fixtures",
      fixtures,
      "fixture_id"
    )
    record_state("/api/fixtures", query, response)
  }
  if (index %% 25L == 0L || index == length(parent_events)) {
    message("Live fixtures: ", index, "/", length(parent_events))
  }
}

live_events <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT DISTINCT live.event_id",
    "FROM market_live_fixtures live",
    "JOIN market_fixtures prematch",
    "ON prematch.parent_id = live.parent_id",
    "JOIN game_market_links links",
    "ON links.event_id = prematch.event_id",
    "WHERE live.resulting_unit = 'Kills'",
    "AND live.live_status = 1",
    "AND links.link_status = 'verified'",
    "ORDER BY live.event_id"
  )
)$event_id

for (index in seq_along(live_events)) {
  event_id <- live_events[[index]]
  query <- list(
    event_id = as.integer(event_id),
    market = "totals",
    full_history = 1L,
    main_lines_only = 1L
  )
  if (!state_complete("/api/odds", query)) {
    response <- request_and_store("/api/odds", query)
    raw_rows <- .bettingiscool_as_data_frame(response$data)
    if (nrow(raw_rows) > 0L) {
      required <- c(
        "event_id", "period", "market", "line",
        "odds1", "odds2", "todds1", "todds2"
      )
      if (all(required %in% names(raw_rows))) {
        valid <- suppressWarnings(as.integer(raw_rows$period)) >= 1L &
          tolower(as.character(raw_rows$market)) == "totals"
        for (column in c("line", "odds1", "odds2", "todds1", "todds2")) {
          valid <- valid & is.finite(suppressWarnings(
            as.numeric(raw_rows[[column]])
          ))
        }
        raw_rows <- raw_rows[valid, , drop = FALSE]
      }
    }
    if (nrow(raw_rows) > 0L) {
      rows <- normalize_bettingiscool_kills_odds(
        raw_rows,
        response$retrieved_at,
        snapshot_type = "live_history"
      )
      rows <- prepare_bettingiscool_odds_rows(rows, response$raw_sha256)
      append_bettingiscool_rows(
        connection,
        "market_live_odds_snapshots",
        rows,
        "snapshot_id"
      )
    }
    record_state("/api/odds", query, response)
  }
  if (index %% 25L == 0L || index == length(live_events)) {
    message("Live odds: ", index, "/", length(live_events))
  }
}

summary <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT 'live_fixtures' AS table_name, COUNT(*) AS rows",
    "FROM market_live_fixtures",
    "UNION ALL",
    "SELECT 'live_odds', COUNT(*) FROM market_live_odds_snapshots",
    "UNION ALL",
    "SELECT 'postdraft_quotes', COUNT(*) FROM market_postdraft_quotes",
    "UNION ALL",
    "SELECT 'verified_postdraft_quotes', COUNT(*)",
    "FROM market_postdraft_quotes WHERE gameid IS NOT NULL"
  )
)
print(summary)
