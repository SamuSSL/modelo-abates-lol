script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
aliases <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "bettingiscool-team-aliases.yml"
))
fixture_dir <- file.path(
  project_root,
  "data",
  "raw",
  "bettingiscool",
  "api_fixtures"
)
fixture_files <- list.files(
  fixture_dir,
  pattern = "^[a-f0-9]{64}\\.json$",
  full.names = TRUE
)
if (length(fixture_files) == 0L) {
  stop("Nenhuma fixture bruta foi encontrada.", call. = FALSE)
}
batches <- lapply(fixture_files, function(path) {
  raw <- jsonlite::fromJSON(path, simplifyDataFrame = TRUE)
  normalize_bettingiscool_fixtures(
    raw,
    format(file.info(path)$mtime, tz = "UTC", usetz = TRUE),
    sub("\\.json$", "", basename(path))
  )
})
fixtures <- do.call(rbind, batches)
fixtures <- fixtures[
  !duplicated(as.character(fixtures$event_id)),
  ,
  drop = FALSE
]
event_links <- match_bettingiscool_regular_events(
  fixtures,
  aliases,
  tolerance_minutes = 5
)
database_path <- file.path(
  project_root,
  "data",
  "processed",
  "lolkills.duckdb"
)
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
coverage <- stats::aggregate(
  rep(1L, nrow(event_links)),
  event_links[c("league_id", "link_status")],
  sum
)
names(coverage)[[3L]] <- "events"
coverage <- coverage[
  order(coverage$league_id, coverage$link_status),
  ,
  drop = FALSE
]
game_links <- DBI::dbReadTable(connection, "game_market_links")
matching_coverage <- stats::aggregate(
  rep(1L, nrow(game_links)),
  game_links[c("league_canonical", "link_status")],
  sum
)
names(matching_coverage)[[3L]] <- "maps"
artifact_dir <- file.path(project_root, "artifacts", "premap_model")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  coverage,
  file.path(artifact_dir, "moneyline_event_link_coverage.csv"),
  row.names = FALSE
)
utils::write.csv(
  matching_coverage,
  file.path(artifact_dir, "kills_game_matching_coverage.csv"),
  row.names = FALSE
)
summary <- data.frame(
  fixture_events = nrow(fixtures),
  kills_events = sum(
    tolower(as.character(fixtures$resulting_unit)) == "kills"
  ),
  regular_events = sum(
    tolower(as.character(fixtures$resulting_unit)) == "regular"
  ),
  verified_pairs = sum(event_links$link_status == "verified"),
  ambiguous_pairs = sum(event_links$link_status == "ambiguous"),
  unmatched_pairs = sum(event_links$link_status == "unmatched"),
  stringsAsFactors = FALSE
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "moneyline_manifest_summary.csv"),
  row.names = FALSE
)
print(summary, row.names = FALSE)
