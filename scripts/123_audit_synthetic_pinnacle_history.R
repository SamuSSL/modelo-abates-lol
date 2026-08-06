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

tables <- DBI::dbListTables(connection)
wanted <- intersect(
  c(
    "market_fixtures", "market_odds_snapshots", "market_opening",
    "market_closing", "market_settlements", "game_market_links",
    "market_postdraft_quotes", "canonical_games"
  ),
  tables
)
counts <- data.frame(
  table = wanted,
  rows = vapply(wanted, function(table) {
    DBI::dbGetQuery(
      connection,
      paste("SELECT COUNT(*) AS n FROM", table)
    )$n[[1L]]
  }, numeric(1L)),
  stringsAsFactors = FALSE
)
print(counts)

coverage <- DBI::dbGetQuery(connection, "
  SELECT MIN(odds_timestamp) AS min_ts,
         MAX(odds_timestamp) AS max_ts,
         COUNT(DISTINCT event_id) AS events,
         COUNT(DISTINCT CAST(event_id AS VARCHAR) || '-' || CAST(period AS VARCHAR)) AS maps
  FROM market_odds_snapshots
  WHERE market = 'totals'
")
print(coverage)

if ("game_market_links" %in% tables) {
  matching <- DBI::dbGetQuery(connection, "
    SELECT link_status, COUNT(*) AS n, COUNT(DISTINCT gameid) AS games
    FROM game_market_links
    GROUP BY link_status
    ORDER BY link_status
  ")
  print(matching)
}

for (path in c(
  file.path(project_root, "data", "interim", "canonical_games.rds"),
  file.path(project_root, "data", "interim", "player_map_metrics.rds"),
  file.path(project_root, "data", "interim", "premap_ratio_map_features_series.rds")
)) {
  if (file.exists(path)) {
    object <- readRDS(path)
    cat("\n", basename(path), ": ", nrow(object), " rows\n", sep = "")
    cat(paste(names(object), collapse = ", "), "\n")
  }
}

for (table in intersect(
  c("game_market_links", "market_odds_snapshots", "market_closing", "market_postdraft_quotes"),
  tables
)) {
  cat("\n", table, " columns:\n", sep = "")
  cat(paste(DBI::dbListFields(connection, table), collapse = ", "), "\n")
}

if (all(c("game_market_links", "market_odds_snapshots", "canonical_games") %in% tables)) {
  direct_targets <- DBI::dbGetQuery(connection, "
    SELECT COUNT(*) AS rows,
           COUNT(DISTINCT l.gameid) AS maps,
           MIN(s.odds_timestamp) AS min_ts,
           MAX(s.odds_timestamp) AS max_ts
    FROM game_market_links l
    JOIN canonical_games g ON g.gameid = l.gameid
    JOIN market_odds_snapshots s
      ON s.event_id = l.event_id AND s.period = l.period
    WHERE l.link_status = 'verified'
      AND s.market = 'totals'
      AND s.odds_timestamp < g.game_datetime
      AND s.odds_over > 1 AND s.odds_under > 1
  ")
  cat("\nDirect point-in-time target coverage:\n")
  print(direct_targets)
}
