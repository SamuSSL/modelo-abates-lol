script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
if (!nzchar(Sys.getenv("BETTINGISCOOL_API_KEY", unset = ""))) {
  stop(
    "Defina BETTINGISCOOL_API_KEY no processo antes da auditoria.",
    call. = FALSE
  )
}
config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "bettingiscool.yml"
))
raw_root <- file.path(project_root, "data", "raw", "bettingiscool")
artifact_dir <- file.path(
  project_root,
  "artifacts",
  "bettingiscool_team_totals"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = file.path(project_root, "data", "processed", "lolkills.duckdb")
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
initialize_bettingiscool_store(connection)

sample_events <- DBI::dbGetQuery(
  connection,
  paste(
    "WITH candidates AS (",
    "SELECT f.league_name, f.league_id, f.event_id, f.runner_home,",
    "f.runner_away, f.resulting_unit, f.starts,",
    "ROW_NUMBER() OVER (PARTITION BY f.league_id ORDER BY f.starts DESC)",
    "AS sample_rank",
    "FROM market_fixtures f",
    "WHERE f.resulting_unit = 'Kills'",
    "AND EXISTS (SELECT 1 FROM market_settlements s",
    "WHERE s.event_id = f.event_id",
    "AND COALESCE(s.result_status, 0) NOT IN (3, 4, 5)))",
    "SELECT * EXCLUDE (sample_rank) FROM candidates",
    "WHERE sample_rank = 1 ORDER BY league_name"
  )
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
    stop("Resposta truncada durante a auditoria.", call. = FALSE)
  }
  response
}

audit_rows <- list()
for (index in seq_len(nrow(sample_events))) {
  fixture <- sample_events[index, , drop = FALSE]
  for (market in c("home_totals", "away_totals")) {
    response <- request_and_store(
      "/api/closing",
      list(
        event_id = as.integer(fixture$event_id[[1L]]),
        market = market
      )
    )
    odds <- .bettingiscool_as_data_frame(response$data)
    odds <- odds[
      suppressWarnings(as.integer(odds$period)) >= 1L &
        tolower(as.character(odds$market)) == market,
      ,
      drop = FALSE
    ]
    contract_passed <- FALSE
    periods <- ""
    if (nrow(odds) > 0L) {
      validate_bettingiscool_team_totals_contract(odds, fixture)
      contract_passed <- TRUE
      periods <- paste(
        sort(unique(suppressWarnings(as.integer(odds$period)))),
        collapse = ","
      )
    }
    audit_rows[[length(audit_rows) + 1L]] <- data.frame(
      league_name = as.character(fixture$league_name[[1L]]),
      league_id = as.integer(fixture$league_id[[1L]]),
      event_id = as.character(fixture$event_id[[1L]]),
      runner_home = as.character(fixture$runner_home[[1L]]),
      runner_away = as.character(fixture$runner_away[[1L]]),
      market = market,
      rows = nrow(odds),
      periods = periods,
      contract_passed = contract_passed,
      quota_remaining = response$quota_remaining,
      stringsAsFactors = FALSE
    )
  }
}
team_total_audit <- do.call(rbind, audit_rows)

specials_status <- tryCatch(
  {
    response <- request_and_store(
      "/api/specials/fixtures",
      list(event_id = as.integer(sample_events$event_id[[1L]]))
    )
    data.frame(
      endpoint = "/api/specials/fixtures",
      accessible = TRUE,
      http_status = 200L,
      rows = nrow(.bettingiscool_as_data_frame(response$data)),
      conclusion = "Specials acessiveis para o evento auditado.",
      stringsAsFactors = FALSE
    )
  },
  error = function(error) {
    message <- conditionMessage(error)
    status <- if (grepl("HTTP 403", message, fixed = TRUE)) 403L else NA_integer_
    data.frame(
      endpoint = "/api/specials/fixtures",
      accessible = FALSE,
      http_status = status,
      rows = NA_integer_,
      conclusion = paste(
        "Specials indisponiveis na conta atual:",
        message
      ),
      stringsAsFactors = FALSE
    )
  }
)

fixture_units <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT resulting_unit, COUNT(*) AS fixtures",
    "FROM market_fixtures GROUP BY resulting_unit ORDER BY fixtures DESC"
  )
)
duration_pattern <- "duration|minute|minutes|time|tempo"
duration_units <- fixture_units[
  grepl(
    duration_pattern,
    tolower(as.character(fixture_units$resulting_unit))
  ),
  ,
  drop = FALSE
]

utils::write.csv(
  team_total_audit,
  file.path(artifact_dir, "authenticated_team_totals_audit.csv"),
  row.names = FALSE
)
utils::write.csv(
  specials_status,
  file.path(artifact_dir, "authenticated_specials_access.csv"),
  row.names = FALSE
)
utils::write.csv(
  fixture_units,
  file.path(artifact_dir, "fixture_resulting_units.csv"),
  row.names = FALSE
)

summary_row <- data.frame(
  leagues_audited = length(unique(team_total_audit$league_id)),
  events_audited = length(unique(team_total_audit$event_id)),
  team_total_markets_with_rows = sum(team_total_audit$rows > 0L),
  team_total_contract_passes = sum(team_total_audit$contract_passed),
  specials_accessible = specials_status$accessible[[1L]],
  duration_fixture_units = nrow(duration_units),
  minimum_quota_remaining = min(
    team_total_audit$quota_remaining,
    na.rm = TRUE
  ),
  audited_at = as.POSIXct(Sys.time(), tz = "UTC"),
  stringsAsFactors = FALSE
)
utils::write.csv(
  summary_row,
  file.path(artifact_dir, "authenticated_audit_summary.csv"),
  row.names = FALSE
)
print(summary_row, row.names = FALSE)
print(team_total_audit, row.names = FALSE)
print(specials_status, row.names = FALSE)
