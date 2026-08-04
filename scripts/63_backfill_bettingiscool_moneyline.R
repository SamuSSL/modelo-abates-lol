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
config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "bettingiscool.yml"
))
aliases <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "bettingiscool-team-aliases.yml"
))
raw_root <- file.path(project_root, "data", "raw", "bettingiscool")
fixture_dir <- file.path(raw_root, "api_fixtures")
fixture_files <- list.files(
  fixture_dir,
  pattern = "^[a-f0-9]{64}\\.json$",
  full.names = TRUE
)
if (length(fixture_files) == 0L) {
  stop("Nenhuma fixture bruta foi encontrada.", call. = FALSE)
}
fixture_batches <- lapply(fixture_files, function(path) {
  jsonlite::fromJSON(path, simplifyDataFrame = TRUE)
})
fixtures_raw <- do.call(rbind, fixture_batches)
fixtures_raw <- fixtures_raw[
  !duplicated(as.character(fixtures_raw$event_id)),
  ,
  drop = FALSE
]
fixtures <- normalize_bettingiscool_fixtures(
  fixtures_raw,
  format(Sys.time(), tz = "UTC", usetz = TRUE),
  raw_sha256 = "fixture_raw_manifest"
)
event_links <- match_bettingiscool_regular_events(
  fixtures,
  aliases = aliases,
  tolerance_minutes = 5
)

processed_dir <- file.path(project_root, "data", "processed")
database_path <- file.path(processed_dir, "lolkills.duckdb")
connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = database_path)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
initialize_bettingiscool_store(connection)
append_bettingiscool_rows(
  connection,
  "market_fixtures",
  fixtures,
  "fixture_id"
)
append_bettingiscool_rows(
  connection,
  "kills_regular_event_links",
  event_links,
  "event_link_id"
)

request_and_store <- function(endpoint, query) {
  response <- bettingiscool_request(
    endpoint,
    query = query,
    max_retries = config$collection$maximum_retries
  )
  raw <- write_bettingiscool_raw_response(response, raw_root)
  response$raw_sha256 <- raw$sha256
  if (isTRUE(response$truncated)) {
    stop("Resposta truncada. Reduza a consulta antes de continuar.", call. = FALSE)
  }
  if (
    is.finite(response$quota_remaining) &&
      response$quota_remaining < config$collection$quota_reserve_tokens
  ) {
    stop("Coleta interrompida antes da reserva diaria de quota.", call. = FALSE)
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

verified <- event_links[
  event_links$link_status == "verified",
  ,
  drop = FALSE
]
regular_fixtures <- fixtures[
  fixtures$event_id %in% verified$regular_event_id,
  ,
  drop = FALSE
]
contract_passed <- FALSE
contract_event <- NA_character_
for (event_id in head(verified$regular_event_id, 10L)) {
  query <- list(
    event_id = as.integer(event_id),
    market = "moneyline",
    full_history = 1,
    main_lines_only = 1
  )
  response <- request_and_store("/api/odds", query)
  odds <- .bettingiscool_as_data_frame(response$data)
  odds <- odds[
    suppressWarnings(as.integer(odds$period)) >= 1L &
      tolower(as.character(odds$market)) == "moneyline",
    ,
    drop = FALSE
  ]
  if (nrow(odds) == 0L) {
    next
  }
  fixture <- regular_fixtures[
    regular_fixtures$event_id == event_id,
    ,
    drop = FALSE
  ]
  validate_bettingiscool_moneyline_contract(odds, fixture)
  contract_passed <- TRUE
  contract_event <- event_id
  break
}
if (!contract_passed) {
  stop(
    "O teste de contrato da moneyline nao encontrou um evento auditavel.",
    call. = FALSE
  )
}

endpoint_specs <- list(
  list(
    endpoint = "/api/odds",
    table = "market_moneyline_snapshots",
    snapshot_type = "history",
    extra = list(full_history = 1, main_lines_only = 1)
  ),
  list(
    endpoint = "/api/opening",
    table = "market_moneyline_opening",
    snapshot_type = "opening",
    extra = list(main_lines_only = 1)
  ),
  list(
    endpoint = "/api/closing",
    table = "market_moneyline_closing",
    snapshot_type = "closing",
    extra = list(main_lines_only = 1)
  )
)

for (event_id in verified$regular_event_id) {
  fixture <- regular_fixtures[
    regular_fixtures$event_id == event_id,
    ,
    drop = FALSE
  ]
  for (spec in endpoint_specs) {
    query <- c(
      list(event_id = as.integer(event_id), market = "moneyline"),
      spec$extra
    )
    if (state_complete(spec$endpoint, query)) {
      next
    }
    response <- request_and_store(spec$endpoint, query)
    odds <- .bettingiscool_as_data_frame(response$data)
    if (nrow(odds) > 0L) {
      odds <- odds[
        suppressWarnings(as.integer(odds$period)) >= 1L &
          tolower(as.character(odds$market)) == "moneyline",
        ,
        drop = FALSE
      ]
    }
    if (nrow(odds) > 0L) {
      rows <- normalize_bettingiscool_moneyline_odds(
        odds,
        response$retrieved_at,
        spec$snapshot_type,
        fixture
      )
      rows$raw_sha256 <- response$raw_sha256
      append_bettingiscool_rows(
        connection,
        spec$table,
        rows,
        "moneyline_snapshot_id"
      )
    }
    record_state(spec$endpoint, query, response)
  }
}

artifact_dir <- file.path(project_root, "artifacts", "premap_model")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
contract_report <- data.frame(
  contract_passed = contract_passed,
  audited_event_id = contract_event,
  verified_event_links = nrow(verified),
  checked_at = as.POSIXct(Sys.time(), tz = "UTC"),
  stringsAsFactors = FALSE
)
utils::write.csv(
  contract_report,
  file.path(artifact_dir, "moneyline_contract_report.csv"),
  row.names = FALSE
)
print(contract_report, row.names = FALSE)
