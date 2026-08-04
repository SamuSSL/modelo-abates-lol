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

request_and_store <- function(endpoint, query) {
  response <- bettingiscool_request(
    endpoint,
    query = query,
    max_retries = config$collection$maximum_retries
  )
  raw <- write_bettingiscool_raw_response(response, raw_dir)
  response$raw_sha256 <- raw$sha256
  if (
    isTRUE(response$truncated) ||
    (
      is.finite(response$quota_remaining) &&
        response$quota_remaining < config$collection$quota_reserve_tokens
    )
  ) {
    stop("Coleta interrompida pelo guardrail de quota/truncamento.", call. = FALSE)
  }
  response
}

state_id <- function(endpoint, query) {
  digest::digest(
    paste(endpoint, jsonlite::toJSON(query, auto_unbox = TRUE), sep = "|"),
    algo = "sha256",
    serialize = FALSE
  )
}

state_complete <- function(endpoint, query) {
  id <- state_id(endpoint, query)
  result <- DBI::dbGetQuery(
    connection,
    "SELECT status FROM api_ingestion_state WHERE state_id = ?",
    params = list(id)
  )
  nrow(result) == 1L && identical(result$status[[1L]], "complete")
}

record_state <- function(endpoint, query, response, status = "complete") {
  row <- data.frame(
    state_id = state_id(endpoint, query),
    endpoint = endpoint,
    query_json = jsonlite::toJSON(query, auto_unbox = TRUE),
    window_start = as.POSIXct(
      if ("starts_from" %in% names(query)) query$starts_from else NA,
      tz = "UTC"
    ),
    window_end = as.POSIXct(
      if ("starts_to" %in% names(query)) query$starts_to else NA,
      tz = "UTC"
    ),
    status = status,
    raw_sha256 = response$raw_sha256,
    rows_received = as.integer(response$row_count),
    quota_remaining = response$quota_remaining,
    completed_at = as.POSIXct(Sys.time(), tz = "UTC"),
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

start <- as.Date(config$coverage$useful_history_start)
canonical_path <- file.path(project_root, "data", "interim", "canonical_games.rds")
end <- if (file.exists(canonical_path)) {
  max(as.Date(readRDS(canonical_path)$game_datetime), na.rm = TRUE) + 2
} else {
  Sys.Date()
}
window_days <- as.integer(config$collection$fixture_window_days)
window_starts <- seq(start, end, by = window_days)

for (competition in config$canonical_competitions) {
  league_id <- competition$bettingiscool_league_id
  for (window_start in window_starts) {
    window_start <- as.Date(window_start, origin = "1970-01-01")
    window_end <- min(window_start + window_days, end + 1)
    query <- list(
      sport_id = config$provider$sport_id,
      league_id = league_id,
      starts_from = paste0(window_start, "T00:00:00Z"),
      starts_to = paste0(window_end, "T00:00:00Z"),
      live = config$market_contract$live,
      limit = config$collection$fixture_limit
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
          fixtures$resulting_unit == config$market_contract$resulting_unit,
        ,
        drop = FALSE
      ]
      append_bettingiscool_rows(
        connection,
        "market_fixtures",
        fixtures,
        "fixture_id"
      )
      record_state("/api/fixtures", query, response)
    }
  }
}

events <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT DISTINCT event_id FROM market_fixtures",
    "WHERE resulting_unit = 'Kills'"
  )
)$event_id

endpoint_specs <- list(
  list(
    endpoint = "/api/odds",
    table = "market_odds_snapshots",
    snapshot_type = "history",
    extra = list(
      full_history = config$market_contract$full_history,
      main_lines_only = config$market_contract$main_lines_only
    )
  ),
  list(
    endpoint = "/api/opening",
    table = "market_opening",
    snapshot_type = "opening",
    extra = list()
  ),
  list(
    endpoint = "/api/closing",
    table = "market_closing",
    snapshot_type = "closing",
    extra = list()
  )
)

for (event_id in events) {
  for (spec in endpoint_specs) {
    query <- c(
      list(
        event_id = as.integer(event_id),
        market = config$market_contract$market
      ),
      spec$extra
    )
    if (state_complete(spec$endpoint, query)) {
      next
    }
    response <- request_and_store(spec$endpoint, query)
    raw_rows <- .bettingiscool_as_data_frame(response$data)
    if (nrow(raw_rows) > 0L) {
      required_odds <- c(
        "event_id", "period", "market", "line",
        "odds1", "odds2", "todds1", "todds2"
      )
      if (all(required_odds %in% names(raw_rows))) {
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
        spec$snapshot_type
      )
      rows <- prepare_bettingiscool_odds_rows(rows, response$raw_sha256)
      append_bettingiscool_rows(
        connection,
        spec$table,
        rows,
        "snapshot_id"
      )
    }
    record_state(spec$endpoint, query, response)
  }
  query <- list(event_id = as.integer(event_id))
  if (!state_complete("/api/results", query)) {
    response <- request_and_store("/api/results", query)
    results <- normalize_bettingiscool_settlements(
      response$data,
      response$retrieved_at,
      response$raw_sha256
    )
    append_bettingiscool_rows(
      connection,
      "market_settlements",
      results,
      "settlement_id"
    )
    record_state("/api/results", query, response)
  }
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
