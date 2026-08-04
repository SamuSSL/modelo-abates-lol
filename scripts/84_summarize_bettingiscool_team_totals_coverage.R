script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = file.path(project_root, "data", "processed", "lolkills.duckdb"),
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

fixtures <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT DISTINCT event_id FROM market_fixtures",
    "WHERE resulting_unit = 'Kills'"
  )
)
opening <- DBI::dbGetQuery(
  connection,
  "SELECT * FROM market_team_totals_opening"
)
closing <- DBI::dbGetQuery(
  connection,
  "SELECT * FROM market_team_totals_closing"
)
history <- DBI::dbGetQuery(
  connection,
  "SELECT * FROM market_team_totals_snapshots"
)
links <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT event_id, period, league_canonical",
    "FROM game_market_links WHERE link_status = 'verified'"
  )
)

opening_selected <- select_bettingiscool_team_total_endpoint_rows(
  opening,
  "opening"
)
closing_selected <- select_bettingiscool_team_total_endpoint_rows(
  closing,
  "closing"
)
t15_selected <- select_bettingiscool_team_total_snapshots(history)

read_metadata <- function(directory) {
  files <- list.files(
    directory,
    pattern = "\\.meta\\.json$",
    full.names = TRUE
  )
  rows <- lapply(files, function(path) {
    metadata <- tryCatch(
      jsonlite::read_json(path, simplifyVector = TRUE),
      error = function(error) NULL
    )
    if (is.null(metadata) || !"market" %in% names(metadata$query)) {
      return(NULL)
    }
    market <- tolower(as.character(metadata$query$market))
    if (!market %in% c("home_totals", "away_totals")) {
      return(NULL)
    }
    data.frame(
      endpoint = as.character(metadata$endpoint),
      event_id = as.character(metadata$query$event_id),
      market = market,
      full_history = if ("full_history" %in% names(metadata$query)) {
        as.integer(metadata$query$full_history)
      } else {
        NA_integer_
      },
      main_lines_only = if ("main_lines_only" %in% names(metadata$query)) {
        as.integer(metadata$query$main_lines_only)
      } else {
        NA_integer_
      },
      rows = as.integer(metadata$row_count),
      stringsAsFactors = FALSE
    )
  })
  rows <- rows[!vapply(rows, is.null, logical(1L))]
  if (length(rows) == 0L) {
    return(data.frame())
  }
  result <- do.call(rbind, rows)
  result[!duplicated(result[c(
    "endpoint",
    "event_id",
    "market",
    "full_history",
    "main_lines_only"
  )]), , drop = FALSE]
}

raw_root <- file.path(project_root, "data", "raw", "bettingiscool")
metadata <- do.call(rbind, lapply(
  c("api_opening", "api_closing", "api_odds"),
  function(directory) read_metadata(file.path(raw_root, directory))
))
coverage_requests <- metadata[
  metadata$endpoint %in% c("/api/opening", "/api/closing"),
  ,
  drop = FALSE
]
history_requests <- metadata[
  metadata$endpoint == "/api/odds" &
    metadata$full_history == 1L &
    metadata$main_lines_only == 1L,
  ,
  drop = FALSE
]

summary_table <- data.frame(
  item = c(
    "kills_events",
    "expected_opening_closing_requests",
    "completed_opening_closing_requests",
    "expected_history_requests",
    "completed_history_requests",
    "opening_rows",
    "closing_rows",
    "history_rows",
    "selected_closing_team_observations",
    "selected_t15_team_observations"
  ),
  value = c(
    nrow(fixtures),
    nrow(fixtures) * 4L,
    nrow(coverage_requests),
    nrow(fixtures) * 2L,
    nrow(history_requests),
    nrow(opening),
    nrow(closing),
    nrow(history),
    nrow(closing_selected),
    nrow(t15_selected)
  ),
  stringsAsFactors = FALSE
)

summarize_linked <- function(selected, snapshot) {
  linked <- merge(selected, links, by = c("event_id", "period"))
  groups <- split(
    seq_len(nrow(linked)),
    linked$league_canonical
  )
  rows <- lapply(groups, function(index) {
    data <- linked[index, , drop = FALSE]
    data.frame(
      snapshot = snapshot,
      league = as.character(data$league_canonical[[1L]]),
      team_observations = nrow(data),
      maps = length(unique(paste(data$event_id, data$period, sep = "|"))),
      events = length(unique(data$event_id)),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}
by_league <- rbind(
  summarize_linked(closing_selected, "closing"),
  summarize_linked(t15_selected, "t15_to_t30")
)
rownames(by_league) <- NULL

artifact_dir <- file.path(
  project_root,
  "artifacts",
  "bettingiscool_team_totals"
)
utils::write.csv(
  summary_table,
  file.path(artifact_dir, "team_totals_coverage_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(artifact_dir, "team_totals_coverage_by_league.csv"),
  row.names = FALSE
)
print(summary_table, row.names = FALSE)
print(by_league, row.names = FALSE)
