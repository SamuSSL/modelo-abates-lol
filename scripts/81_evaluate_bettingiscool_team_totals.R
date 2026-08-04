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

auc_binary <- function(outcome, probability) {
  positive <- outcome == 1L
  n_positive <- sum(positive)
  n_negative <- sum(!positive)
  if (n_positive == 0L || n_negative == 0L) {
    return(NA_real_)
  }
  ranks <- rank(probability, ties.method = "average")
  (
    sum(ranks[positive]) -
      n_positive * (n_positive + 1) / 2
  ) / (n_positive * n_negative)
}

score_rows <- function(data, snapshot_name) {
  if (nrow(data) == 0L) {
    return(data.frame())
  }
  data <- derive_team_total_probabilities(data)
  data$team_kills <- ifelse(
    data$team_side == "home",
    data$score_home,
    data$score_away
  )
  valid <- is.finite(data$team_kills) &
    is.finite(data$line) &
    abs(data$line %% 1 - 0.5) < 1e-8 &
    is.finite(data$p_over) &
    data$p_over > 0 &
    data$p_over < 1 &
    !data$result_status %in% c(3L, 4L, 5L)
  data <- data[valid, , drop = FALSE]
  if (nrow(data) == 0L) {
    return(data.frame())
  }
  data$outcome_over <- as.integer(data$team_kills > data$line)
  data$brier <- (data$p_over - data$outcome_over)^2
  data$log_loss <- -(
    data$outcome_over * log(data$p_over) +
      (1 - data$outcome_over) * log(1 - data$p_over)
  )
  groups <- split(
    seq_len(nrow(data)),
    interaction(data$league_canonical, data$market, drop = TRUE)
  )
  by_group <- lapply(groups, function(index) {
    rows <- data[index, , drop = FALSE]
    data.frame(
      snapshot = snapshot_name,
      league = as.character(rows$league_canonical[[1L]]),
      market = as.character(rows$market[[1L]]),
      observations = nrow(rows),
      over_rate = mean(rows$outcome_over),
      mean_market_probability = mean(rows$p_over),
      calibration_bias = mean(rows$p_over) - mean(rows$outcome_over),
      brier = mean(rows$brier),
      log_loss = mean(rows$log_loss),
      auc = auc_binary(rows$outcome_over, rows$p_over),
      line_mae = mean(abs(rows$team_kills - rows$line)),
      line_rmse = sqrt(mean((rows$team_kills - rows$line)^2)),
      line_score_bias = mean(rows$team_kills - rows$line),
      favorite_accuracy = mean(
        as.integer(rows$p_over >= 0.5) == rows$outcome_over
      ),
      stringsAsFactors = FALSE
    )
  })
  aggregate <- data.frame(
    snapshot = snapshot_name,
    league = "ALL",
    market = "ALL",
    observations = nrow(data),
    over_rate = mean(data$outcome_over),
    mean_market_probability = mean(data$p_over),
    calibration_bias = mean(data$p_over) - mean(data$outcome_over),
    brier = mean(data$brier),
    log_loss = mean(data$log_loss),
    auc = auc_binary(data$outcome_over, data$p_over),
    line_mae = mean(abs(data$team_kills - data$line)),
    line_rmse = sqrt(mean((data$team_kills - data$line)^2)),
    line_score_bias = mean(data$team_kills - data$line),
    favorite_accuracy = mean(
      as.integer(data$p_over >= 0.5) == data$outcome_over
    ),
    stringsAsFactors = FALSE
  )
  list(
    metrics = rbind(aggregate, do.call(rbind, by_group)),
    scored_rows = data
  )
}

links <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT gameid, event_id, period, league_canonical, competition",
    "FROM game_market_links WHERE link_status = 'verified'"
  )
)
settlements <- DBI::dbGetQuery(
  connection,
  paste(
    "SELECT event_id, period, result_status, score_home, score_away",
    "FROM market_settlements"
  )
)
closing <- DBI::dbGetQuery(
  connection,
  "SELECT * FROM market_team_totals_closing"
)
closing <- select_bettingiscool_team_total_endpoint_rows(
  closing,
  "closing"
)
history <- DBI::dbGetQuery(
  connection,
  "SELECT * FROM market_team_totals_snapshots"
)

join_outcomes <- function(odds) {
  if (nrow(odds) == 0L) {
    return(odds)
  }
  result <- merge(odds, links, by = c("event_id", "period"))
  merge(result, settlements, by = c("event_id", "period"))
}

closing_result <- score_rows(join_outcomes(closing), "closing")
t15 <- select_bettingiscool_team_total_snapshots(history)
t15_result <- score_rows(join_outcomes(t15), "t15_to_t30")
results <- Filter(
  function(value) is.list(value) && nrow(value$metrics) > 0L,
  list(closing_result, t15_result)
)
if (length(results) == 0L) {
  stop("Nao ha team totals vinculados e liquidados para avaliar.", call. = FALSE)
}

metrics <- do.call(rbind, lapply(results, `[[`, "metrics"))
scored <- lapply(results, `[[`, "scored_rows")
names(scored) <- vapply(
  results,
  function(result) as.character(result$metrics$snapshot[[1L]]),
  character(1L)
)
artifact_dir <- file.path(
  project_root,
  "artifacts",
  "bettingiscool_team_totals"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  metrics,
  file.path(artifact_dir, "team_totals_efficiency_metrics.csv"),
  row.names = FALSE
)
saveRDS(
  scored,
  file.path(artifact_dir, "team_totals_scored_rows.rds")
)
print(metrics, row.names = FALSE)
