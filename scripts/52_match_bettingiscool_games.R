script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(file.path(
  project_root, "config", "bettingiscool.yml"
))
alias_config <- yaml::read_yaml(file.path(
  project_root, "config", "bettingiscool-team-aliases.yml"
))
database_path <- file.path(
  project_root, "data", "processed", "lolkills.duckdb"
)
connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = database_path)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
initialize_bettingiscool_store(connection)

fixtures <- DBI::dbReadTable(connection, "market_fixtures")
periods <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT DISTINCT event_id, period FROM market_odds_snapshots",
    "UNION SELECT DISTINCT event_id, period FROM market_settlements"
  )
)
settlements <- DBI::dbReadTable(connection, "market_settlements")
games <- readRDS(file.path(
  project_root, "data", "interim", "canonical_games.rds"
))
links <- match_bettingiscool_games(
  fixtures,
  periods,
  games,
  config$canonical_competitions,
  aliases = alias_config$aliases,
  settlements = settlements,
  cancelled_statuses = unlist(
    config$market_contract$cancelled_result_status
  )
)

history <- DBI::dbReadTable(connection, "market_odds_snapshots")
if (nrow(history) > 0L) {
  close_times <- stats::aggregate(
    history$odds_timestamp,
    list(event_id = history$event_id, period = history$period),
    max,
    na.rm = TRUE
  )
  names(close_times)[[3L]] <- "market_close_time"
  link_close <- merge(
    links[c("link_id", "event_id", "period")],
    close_times,
    by = c("event_id", "period"),
    all.x = TRUE
  )
  links$market_close_time <- link_close$market_close_time[
    match(links$link_id, link_close$link_id)
  ]
}
DBI::dbExecute(connection, "DELETE FROM game_market_links")
DBI::dbWriteTable(
  connection,
  "game_market_links",
  links,
  append = TRUE
)

artifact_dir <- file.path(project_root, "artifacts", "bettingiscool")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
fixture_seasons <- fixtures[c("event_id", "starts")]
fixture_seasons$season <- format(
  as.POSIXct(fixture_seasons$starts, tz = "UTC"),
  "%Y",
  tz = "UTC"
)
fixture_seasons <- fixture_seasons[
  !duplicated(fixture_seasons$event_id),
  c("event_id", "season"),
  drop = FALSE
]
links_reporting <- merge(
  links,
  fixture_seasons,
  by = "event_id",
  all.x = TRUE
)
links_reporting$exclusion_reason[
  is.na(links_reporting$exclusion_reason)
] <- "included"
coverage <- as.data.frame(with(
  links_reporting,
  table(
    league_canonical,
    competition,
    season,
    period,
    link_status,
    exclusion_reason
  )
))
coverage <- coverage[coverage$Freq > 0L, , drop = FALSE]
utils::write.csv(
  coverage,
  file.path(artifact_dir, "matching_coverage.csv"),
  row.names = FALSE
)
utils::write.csv(
  links[links$link_status != "verified", , drop = FALSE],
  file.path(artifact_dir, "matching_review.csv"),
  row.names = FALSE
)
print(as.data.frame(table(links$link_status)))
