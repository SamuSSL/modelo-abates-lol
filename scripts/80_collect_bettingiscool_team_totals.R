script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
if (!nzchar(Sys.getenv("BETTINGISCOOL_API_KEY", unset = ""))) {
  stop(
    "Defina BETTINGISCOOL_API_KEY no processo antes da coleta.",
    call. = FALSE
  )
}
arguments <- commandArgs(trailingOnly = TRUE)
mode <- if (length(arguments) > 0L) tolower(arguments[[1L]]) else "coverage"
league_filter <- if (length(arguments) > 1L) {
  suppressWarnings(as.integer(arguments[-1L]))
} else {
  integer()
}
league_filter <- league_filter[is.finite(league_filter)]
if (!mode %in% c("coverage", "history")) {
  stop("Modo deve ser coverage ou history.", call. = FALSE)
}
config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "bettingiscool.yml"
))
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

quota_reserve <- as.numeric(
  config$collection$team_totals_quota_reserve_tokens
)
if (!is.finite(quota_reserve)) {
  quota_reserve <- as.numeric(config$collection$quota_reserve_tokens)
}

request_and_store <- function(endpoint, query) {
  response <- bettingiscool_request(
    endpoint,
    query = query,
    max_retries = config$collection$maximum_retries
  )
  raw <- write_bettingiscool_raw_response(response, raw_root)
  response$raw_sha256 <- raw$sha256
  if (isTRUE(response$truncated)) {
    stop("Resposta truncada. Reduza a consulta.", call. = FALSE)
  }
  if (
    is.finite(response$quota_remaining) &&
      response$quota_remaining < quota_reserve
  ) {
    stop(
      "Coleta interrompida antes da reserva segura de quota.",
      call. = FALSE
    )
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
  result <- DBI::dbGetQuery(
    connection,
    "SELECT status FROM api_ingestion_state WHERE state_id = ?",
    params = list(state_id(endpoint, query))
  )
  nrow(result) == 1L && identical(result$status[[1L]], "complete")
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
  .bettingiscool_append_unique(
    connection,
    "api_ingestion_state",
    row,
    "state_id"
  )
}

fixtures <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT * EXCLUDE (fixture_rank) FROM (",
    "SELECT *, ROW_NUMBER() OVER (PARTITION BY event_id",
    "ORDER BY retrieved_at DESC) AS fixture_rank",
    "FROM market_fixtures WHERE resulting_unit = 'Kills')",
    "WHERE fixture_rank = 1 ORDER BY starts, event_id"
  )
)
if (nrow(fixtures) == 0L) {
  stop("Nenhuma fixture de kills foi encontrada no banco.", call. = FALSE)
}
if (length(league_filter) > 0L) {
  fixtures <- fixtures[fixtures$league_id %in% league_filter, , drop = FALSE]
}

if (mode == "coverage") {
  endpoint_specs <- list(
    list(
      endpoint = "/api/opening",
      table = "market_team_totals_opening",
      snapshot_type = "opening",
      extra = list()
    ),
    list(
      endpoint = "/api/closing",
      table = "market_team_totals_closing",
      snapshot_type = "closing",
      extra = list()
    )
  )
} else {
  endpoint_specs <- list(
    list(
      endpoint = "/api/odds",
      table = "market_team_totals_snapshots",
      snapshot_type = "history",
      extra = list(full_history = 1L, main_lines_only = 1L)
    )
  )
}

requests_completed <- 0L
rows_inserted <- 0L
last_quota <- NA_real_
for (index in seq_len(nrow(fixtures))) {
  fixture <- fixtures[index, , drop = FALSE]
  for (market in c("home_totals", "away_totals")) {
    for (spec in endpoint_specs) {
      query <- c(
        list(
          event_id = as.integer(fixture$event_id[[1L]]),
          market = market
        ),
        spec$extra
      )
      if (state_complete(spec$endpoint, query)) {
        next
      }
      response <- request_and_store(spec$endpoint, query)
      odds <- .bettingiscool_as_data_frame(response$data)
      if (nrow(odds) > 0L) {
        valid <- suppressWarnings(as.integer(odds$period)) >= 1L &
          tolower(as.character(odds$market)) == market
        odds <- odds[valid, , drop = FALSE]
      }
      if (nrow(odds) > 0L) {
        rows <- normalize_bettingiscool_team_totals_odds(
          odds,
          response$retrieved_at,
          spec$snapshot_type,
          fixture
        )
        rows$raw_sha256 <- response$raw_sha256
        rows_inserted <- rows_inserted + append_bettingiscool_rows(
          connection,
          spec$table,
          rows,
          "team_total_snapshot_id"
        )
      }
      record_state(spec$endpoint, query, response)
      requests_completed <- requests_completed + 1L
      last_quota <- response$quota_remaining
    }
  }
  if (index %% 50L == 0L) {
    message(
      "Eventos processados: ",
      index,
      "/",
      nrow(fixtures),
      ". Quota restante: ",
      last_quota
    )
  }
}

summary_row <- data.frame(
  mode = mode,
  events_available = nrow(fixtures),
  requests_completed = requests_completed,
  rows_inserted = rows_inserted,
  quota_remaining = last_quota,
  completed_at = as.POSIXct(Sys.time(), tz = "UTC"),
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
  file.path(artifact_dir, paste0("collection_", mode, "_summary.csv")),
  row.names = FALSE
)
print(summary_row, row.names = FALSE)
