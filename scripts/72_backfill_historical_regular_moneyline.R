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

provider_config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "bettingiscool.yml"
))
evaluation_config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation_config$directed_moneyline_joint_round
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

state_id <- function(endpoint, query) {
  digest::digest(
    paste(
      endpoint,
      jsonlite::toJSON(query, auto_unbox = TRUE),
      sep = "|"
    ),
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

record_state <- function(
  endpoint,
  query,
  response,
  window_start = as.POSIXct(NA, tz = "UTC"),
  window_end = as.POSIXct(NA, tz = "UTC")
) {
  row <- data.frame(
    state_id = state_id(endpoint, query),
    endpoint = endpoint,
    query_json = jsonlite::toJSON(query, auto_unbox = TRUE),
    window_start = window_start,
    window_end = window_end,
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

request_and_store <- function(endpoint, query) {
  response <- bettingiscool_request(
    endpoint,
    query = query,
    max_retries = provider_config$collection$maximum_retries
  )
  raw <- write_bettingiscool_raw_response(response, raw_root)
  response$raw_sha256 <- raw$sha256
  if (isTRUE(response$truncated)) {
    stop(
      "Resposta truncada na coleta historica de moneyline.",
      call. = FALSE
    )
  }
  if (
    is.finite(response$quota_remaining) &&
      response$quota_remaining <
        provider_config$collection$quota_reserve_tokens
  ) {
    stop(
      "Coleta interrompida antes da reserva diaria de quota.",
      call. = FALSE
    )
  }
  response
}

audit_start <- as.POSIXct(
  as.character(round_config$historical_moneyline_audit_start),
  tz = "UTC"
)
audit_end <- as.POSIXct(
  as.character(round_config$historical_moneyline_audit_end),
  tz = "UTC"
)
window_days <- as.integer(provider_config$collection$fixture_window_days)
window_starts <- seq(
  audit_start,
  audit_end - 1,
  by = paste(window_days, "days")
)
manifest <- provider_config$canonical_competitions
audit_rows <- list()
audit_index <- 0L

for (competition in manifest) {
  league_id <- as.integer(competition$bettingiscool_league_id)
  for (window_start in window_starts) {
    window_start <- as.POSIXct(
      window_start,
      origin = "1970-01-01",
      tz = "UTC"
    )
    window_end <- min(
      window_start + window_days * 86400,
      audit_end
    )
    query <- list(
      sport_id = as.integer(provider_config$provider$sport_id),
      league_id = league_id,
      starts_from = format(
        window_start,
        "%Y-%m-%d %H:%M:%S",
        tz = "UTC"
      ),
      starts_to = format(
        window_end - 1,
        "%Y-%m-%d %H:%M:%S",
        tz = "UTC"
      ),
      live = 0,
      limit = as.integer(provider_config$collection$fixture_limit)
    )
    if (state_complete("/api/fixtures", query)) {
      fixture_rows <- DBI::dbGetQuery(
        connection,
        paste(
          "SELECT * FROM market_fixtures",
          "WHERE league_id = ? AND starts >= ? AND starts < ?"
        ),
        params = list(league_id, window_start, window_end)
      )
      raw_sha256 <- NA_character_
      quota_remaining <- NA_real_
    } else {
      response <- request_and_store("/api/fixtures", query)
      fixture_rows <- .bettingiscool_as_data_frame(response$data)
      raw_sha256 <- response$raw_sha256
      quota_remaining <- response$quota_remaining
      if (nrow(fixture_rows) > 0L) {
        normalized <- normalize_bettingiscool_fixtures(
          fixture_rows,
          response$retrieved_at,
          response$raw_sha256
        )
        append_bettingiscool_rows(
          connection,
          "market_fixtures",
          normalized,
          "fixture_id"
        )
        fixture_rows <- normalized
      }
      record_state(
        "/api/fixtures",
        query,
        response,
        window_start,
        window_end
      )
    }
    regular_count <- if (nrow(fixture_rows) == 0L) {
      0L
    } else {
      sum(
        tolower(as.character(fixture_rows$resulting_unit)) == "regular",
        na.rm = TRUE
      )
    }
    audit_index <- audit_index + 1L
    audit_rows[[audit_index]] <- data.frame(
      canonical_league = as.character(competition$canonical_league),
      competition = as.character(competition$competition),
      league_id = league_id,
      window_start = window_start,
      window_end = window_end,
      fixture_rows = nrow(fixture_rows),
      regular_events = regular_count,
      raw_sha256 = raw_sha256,
      quota_remaining = quota_remaining,
      stringsAsFactors = FALSE
    )
  }
}

fixture_audit <- do.call(rbind, audit_rows)
all_fixtures <- DBI::dbReadTable(connection, "market_fixtures")
all_fixtures <- .deduplicate_bettingiscool_fixtures(all_fixtures)
historical_regular <- all_fixtures[
  tolower(as.character(all_fixtures$resulting_unit)) == "regular" &
    all_fixtures$starts >= audit_start &
    all_fixtures$starts < audit_end &
    all_fixtures$league_id %in% vapply(
      manifest,
      function(entry) as.integer(entry$bettingiscool_league_id),
      integer(1L)
    ),
  ,
  drop = FALSE
]

collection_rows <- list()
collection_index <- 0L
for (event_id in as.character(historical_regular$event_id)) {
  query <- list(
    event_id = as.integer(event_id),
    market = "moneyline",
    full_history = 1,
    main_lines_only = 1
  )
  if (state_complete("/api/odds", query)) {
    next
  }
  response <- request_and_store("/api/odds", query)
  odds <- .bettingiscool_as_data_frame(response$data)
  if (nrow(odds) > 0L) {
    odds <- odds[
      suppressWarnings(as.integer(odds$period)) >= 1L &
        tolower(as.character(odds$market)) == "moneyline",
      ,
      drop = FALSE
    ]
  }
  inserted <- 0L
  if (nrow(odds) > 0L) {
    fixture <- historical_regular[
      historical_regular$event_id == event_id,
      ,
      drop = FALSE
    ]
    rows <- normalize_bettingiscool_moneyline_odds(
      odds,
      response$retrieved_at,
      snapshot_type = "history",
      fixture = fixture[1L, , drop = FALSE]
    )
    rows$raw_sha256 <- response$raw_sha256
    inserted <- append_bettingiscool_rows(
      connection,
      "market_moneyline_snapshots",
      rows,
      "moneyline_snapshot_id"
    )
  }
  record_state("/api/odds", query, response)
  collection_index <- collection_index + 1L
  collection_rows[[collection_index]] <- data.frame(
    event_id = event_id,
    rows_received = nrow(odds),
    rows_inserted = inserted,
    raw_sha256 = response$raw_sha256,
    quota_remaining = response$quota_remaining,
    stringsAsFactors = FALSE
  )
}

collection_status <- if (length(collection_rows) > 0L) {
  do.call(rbind, collection_rows)
} else {
  data.frame(
    event_id = character(),
    rows_received = integer(),
    rows_inserted = integer(),
    raw_sha256 = character(),
    quota_remaining = numeric(),
    stringsAsFactors = FALSE
  )
}
artifact_dir <- file.path(project_root, "artifacts", "premap_model")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  fixture_audit,
  file.path(
    artifact_dir,
    "historical_regular_moneyline_fixture_audit.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  collection_status,
  file.path(
    artifact_dir,
    "historical_regular_moneyline_collection_status.csv"
  ),
  row.names = FALSE
)
summary <- stats::aggregate(
  fixture_audit[c("fixture_rows", "regular_events")],
  fixture_audit[c("canonical_league", "competition")],
  sum
)
utils::write.csv(
  summary,
  file.path(
    artifact_dir,
    "historical_regular_moneyline_coverage_summary.csv"
  ),
  row.names = FALSE
)
print(summary, row.names = FALSE)
cat(
  "Eventos Regular historicos:",
  nrow(historical_regular),
  "\nNovas consultas de odds:",
  nrow(collection_status),
  "\n"
)
