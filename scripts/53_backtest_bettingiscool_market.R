script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
database_path <- file.path(
  project_root, "data", "processed", "lolkills.duckdb"
)
connection <- DBI::dbConnect(duckdb::duckdb(), dbdir = database_path)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
history <- DBI::dbReadTable(connection, "market_odds_snapshots")
closing <- DBI::dbReadTable(connection, "market_closing")
links <- DBI::dbReadTable(connection, "game_market_links")
if (nrow(history) == 0L || nrow(links) == 0L) {
  stop("Colete e faça o matching das odds antes do backtest.", call. = FALSE)
}
snapshots <- select_bettingiscool_map_snapshots(history, 5)
closing <- closing[order(
  closing$event_id,
  closing$period,
  closing$line,
  closing$odds_timestamp,
  decreasing = TRUE
), , drop = FALSE]
closing <- closing[!duplicated(paste(
  closing$event_id,
  closing$period,
  closing$line,
  sep = "|"
)), , drop = FALSE]
closing <- closing[c(
  "event_id", "period", "line", "true_odds_over", "true_odds_under"
)]
names(closing)[4:5] <- c(
  "closing_true_odds_over",
  "closing_true_odds_under"
)
snapshots <- merge(
  snapshots,
  closing,
  by = c("event_id", "period", "line"),
  all.x = TRUE
)
bind_rows_fill <- function(batches) {
  columns <- unique(unlist(lapply(batches, names)))
  prepared <- lapply(batches, function(data) {
    for (column in setdiff(columns, names(data))) {
      data[[column]] <- NA
    }
    data[columns]
  })
  do.call(rbind, prepared)
}
artifact_dir <- file.path(project_root, "artifacts", "evaluation")
development <- readRDS(file.path(
  artifact_dir, "all_development_model_metrics.rds"
))
development <- development[
  development$candidate_id == "nb_v1_rebuilt",
  ,
  drop = FALSE
]
ridge <- readRDS(file.path(
  artifact_dir, "kill_market_development_map_metrics.rds"
))
ridge <- ridge[
  ridge$candidate_id == "ridge_multiscale_team_draft",
  ,
  drop = FALSE
]
shadow <- build_pmf_ensemble(
  bind_rows_fill(list(development, ridge)),
  c("nb_v1_rebuilt", "ridge_multiscale_team_draft"),
  c(0.5, 0.5),
  "ensemble_shadow_50"
)
predictions <- bind_rows_fill(list(development, ridge, shadow))
secondary <- readRDS(file.path(
  artifact_dir, "kill_market_2026_map_metrics.rds"
))
secondary <- secondary[
  secondary$candidate_id %in% c(
    "nb_v1_rebuilt", "ridge_multiscale_team_draft"
  ),
  ,
  drop = FALSE
]
secondary_shadow <- build_pmf_ensemble(
  secondary,
  c("nb_v1_rebuilt", "ridge_multiscale_team_draft"),
  c(0.5, 0.5),
  "ensemble_shadow_50"
)
predictions <- bind_rows_fill(list(
  predictions, secondary, secondary_shadow
))
games <- readRDS(file.path(
  project_root, "data", "interim", "canonical_games.rds"
))
backtest <- evaluate_kills_market_backtest(
  predictions, links, snapshots, games
)
summary <- summarize_kills_market_backtest(backtest)
bootstrap <- bootstrap_kills_market_backtest(
  backtest,
  replicates = 2000L,
  seed = 20260728L
)
output_dir <- file.path(project_root, "artifacts", "bettingiscool")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(backtest, file.path(output_dir, "market_backtest_map_metrics.rds"))
utils::write.csv(
  summary,
  file.path(output_dir, "market_backtest_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(output_dir, "market_backtest_bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  as.data.frame(with(
    backtest,
    table(candidate_id, league_canonical, outcome_over)
  )),
  file.path(output_dir, "market_backtest_coverage.csv"),
  row.names = FALSE
)
print(summary)
