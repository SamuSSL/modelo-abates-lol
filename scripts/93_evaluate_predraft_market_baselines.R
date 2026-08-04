#!/usr/bin/env Rscript

pkgload::load_all(".", quiet = TRUE)
output_dir <- "artifacts/modeling-research/predraft-market-dynamic-duration"
selection_path <- file.path(output_dir, "total_snapshot_selection.csv")
if (!file.exists(selection_path)) {
  stop("Execute scripts/92_audit_predraft_market_coverage.R first.")
}
selection <- read.csv(selection_path, stringsAsFactors = FALSE)
selection$market_close_time <- as.POSIXct(selection$market_close_time, tz = "UTC")
selection$game_datetime <- as.POSIXct(selection$game_datetime, tz = "UTC")
selection$observed_over <- as.numeric(selection$observed_total > selection$line)
raw_over <- 1 / selection$odds_over
raw_under <- 1 / selection$odds_under
selection$market_probability_over <- raw_over / (raw_over + raw_under)

bundle <- jsonlite::read_json("app_data/model_bundle.json", simplifyVector = TRUE)
theta <- as.numeric(bundle$model$theta)
selection$market_nb_mean <- mapply(
  invert_market_count_mean,
  selection$line,
  selection$market_probability_over,
  MoreArgs = list(distribution = "negative_binomial", theta = theta)
)
selection$market_poisson_mean <- mapply(
  invert_market_count_mean,
  selection$line,
  selection$market_probability_over,
  MoreArgs = list(distribution = "poisson")
)

connection <- DBI::dbConnect(
  duckdb::duckdb(),
  "data/processed/lolkills.duckdb",
  read_only = TRUE
)
games <- DBI::dbGetQuery(
  connection,
  paste(
    "select game_datetime, league_canonical, total_kills_game",
    "from canonical_games where target_valid"
  )
)
DBI::dbDisconnect(connection, shutdown = TRUE)
games$game_datetime <- as.POSIXct(games$game_datetime, tz = "UTC")
selection$weekly_cutoff <- as.POSIXct(
  as.Date(selection$game_datetime) - ((as.POSIXlt(selection$game_datetime)$wday - 6) %% 7),
  tz = "UTC"
)
selection$league_pace_mean <- vapply(seq_len(nrow(selection)), function(index) {
  rows <- games$game_datetime < selection$weekly_cutoff[[index]] &
    games$league_canonical == selection$league_canonical[[index]]
  mean(tail(games$total_kills_game[rows], 300), na.rm = TRUE)
}, numeric(1))

weekly_path <- "artifacts/modeling-research/directed-market-regime-calibration/weekly_base_predictions.rds"
weekly <- readRDS(weekly_path)
weekly <- weekly[!duplicated(weekly$gameid), c("gameid", "base_mean", "base_theta")]
selection <- merge(selection, weekly, by = "gameid", all.x = TRUE, sort = FALSE)

pmf_nb <- function(mean, size, maximum = 150L) {
  mass <- stats::dnbinom(0:maximum, mu = mean, size = size)
  mass[[length(mass)]] <- mass[[length(mass)]] + max(0, 1 - sum(mass))
  mass / sum(mass)
}
line_probability <- function(pmf, line) 1 - sum(pmf[seq_len(floor(line) + 1L)])
score_pmf <- function(pmf, observed) {
  index <- min(as.integer(observed), length(pmf) - 1L) + 1L
  c(
    log_score = -log(max(pmf[[index]], 1e-15)),
    crps = sum((cumsum(pmf) - as.numeric(0:(length(pmf) - 1L) >= observed))^2),
    covered_90 = as.numeric(
      observed >= which(cumsum(pmf) >= 0.05)[[1]] - 1L &&
      observed <= which(cumsum(pmf) >= 0.95)[[1]] - 1L
    )
  )
}

candidate_definitions <- list(
  pinnacle_no_vig = list(mean = selection$market_nb_mean, size = rep(theta, nrow(selection))),
  market_implied_count = list(mean = selection$market_nb_mean, size = rep(theta, nrow(selection))),
  market_poisson_center_nb = list(mean = selection$market_poisson_mean, size = rep(theta, nrow(selection))),
  league_pace = list(mean = selection$league_pace_mean, size = rep(theta, nrow(selection))),
  weekly_directed_raw = list(mean = selection$base_mean, size = selection$base_theta)
)

prediction_rows <- list()
row_id <- 1L
for (model_id in names(candidate_definitions)) {
  candidate <- candidate_definitions[[model_id]]
  for (index in seq_len(nrow(selection))) {
    if (!is.finite(candidate$mean[[index]]) || !is.finite(candidate$size[[index]])) next
    pmf <- pmf_nb(candidate$mean[[index]], candidate$size[[index]])
    probability_over <- if (model_id %in% c("pinnacle_no_vig", "market_implied_count")) {
      selection$market_probability_over[[index]]
    } else {
      line_probability(pmf, selection$line[[index]])
    }
    distribution_scores <- score_pmf(pmf, selection$observed_total[[index]])
    prediction_rows[[row_id]] <- data.frame(
      gameid = selection$gameid[[index]],
      series_id = selection$series_id[[index]],
      game_datetime = selection$game_datetime[[index]],
      period_group = selection$period_group[[index]],
      league_canonical = selection$league_canonical[[index]],
      model_id = model_id,
      line = selection$line[[index]],
      odds_over = selection$odds_over[[index]],
      odds_under = selection$odds_under[[index]],
      observed_total = selection$observed_total[[index]],
      observed_over = selection$observed_over[[index]],
      predicted_mean = candidate$mean[[index]],
      probability_over = probability_over,
      brier = (probability_over - selection$observed_over[[index]])^2,
      log_loss = -(
        selection$observed_over[[index]] * log(max(probability_over, 1e-15)) +
        (1 - selection$observed_over[[index]]) * log(max(1 - probability_over, 1e-15))
      ),
      log_score = distribution_scores[["log_score"]],
      crps = distribution_scores[["crps"]],
      covered_90 = distribution_scores[["covered_90"]],
      stringsAsFactors = FALSE
    )
    row_id <- row_id + 1L
  }
}
predictions <- do.call(rbind, prediction_rows)
predictions$month <- format(predictions$game_datetime, "%Y-%m")
write.csv(predictions, file.path(output_dir, "market_baseline_predictions.csv"), row.names = FALSE)

metric_summary <- aggregate(
  cbind(brier, log_loss, log_score, crps, covered_90) ~ period_group + model_id,
  predictions,
  mean
)
counts <- aggregate(gameid ~ period_group + model_id, predictions, length)
names(counts)[names(counts) == "gameid"] <- "maps"
metric_summary <- merge(metric_summary, counts, by = c("period_group", "model_id"))
calibration <- aggregate(
  cbind(probability_over, observed_over) ~ period_group + model_id,
  predictions,
  mean
)
calibration$calibration_error <- abs(calibration$probability_over - calibration$observed_over)
metric_summary <- merge(metric_summary, calibration, by = c("period_group", "model_id"))
write.csv(metric_summary, file.path(output_dir, "predictive_metric_summary.csv"), row.names = FALSE)

league_summary <- aggregate(
  cbind(brier, log_loss) ~ period_group + league_canonical + model_id,
  predictions,
  mean
)
league_counts <- aggregate(
  gameid ~ period_group + league_canonical + model_id,
  predictions,
  length
)
names(league_counts)[names(league_counts) == "gameid"] <- "maps"
league_summary <- merge(league_summary, league_counts)
write.csv(league_summary, file.path(output_dir, "predictive_metrics_by_league.csv"), row.names = FALSE)

economic_rows <- list()
economic_id <- 1L
for (threshold in c(0, 0.03, 0.05, 0.08, 0.10)) {
  for (model_id in unique(predictions$model_id)) {
    rows <- predictions[predictions$model_id == model_id, ]
    ev_over <- rows$probability_over * rows$odds_over - 1
    ev_under <- (1 - rows$probability_over) * rows$odds_under - 1
    chosen_over <- ev_over >= ev_under
    chosen_ev <- ifelse(chosen_over, ev_over, ev_under)
    bet <- chosen_ev > threshold
    profit <- ifelse(
      !bet,
      0,
      ifelse(
        chosen_over == (rows$observed_over == 1),
        ifelse(chosen_over, rows$odds_over - 1, rows$odds_under - 1),
        -1
      )
    )
    bankroll <- cumsum(profit[order(rows$game_datetime)])
    drawdown <- if (length(bankroll)) max(cummax(c(0, bankroll))[-1] - bankroll) else 0
    economic_rows[[economic_id]] <- data.frame(
      model_id = model_id,
      minimum_ev = threshold,
      bets = sum(bet),
      profit = sum(profit),
      yield = if (sum(bet)) sum(profit) / sum(bet) else NA_real_,
      maximum_drawdown = drawdown,
      over_bets = sum(bet & chosen_over),
      under_bets = sum(bet & !chosen_over),
      stringsAsFactors = FALSE
    )
    economic_id <- economic_id + 1L
  }
}
economic <- do.call(rbind, economic_rows)
write.csv(economic, file.path(output_dir, "economic_benchmark_ev_grid.csv"), row.names = FALSE)

economic_detail <- list()
detail_id <- 1L
for (period_name in unique(predictions$period_group)) {
  for (league_name in c("ALL", sort(unique(predictions$league_canonical)))) {
    group_rows <- predictions[
      predictions$period_group == period_name &
        (league_name == "ALL" | predictions$league_canonical == league_name),
    ]
    for (threshold in c(0, 0.03, 0.05, 0.08, 0.10)) {
      for (model_id in unique(group_rows$model_id)) {
        rows <- group_rows[group_rows$model_id == model_id, ]
        if (nrow(rows) == 0L) next
        ev_over <- rows$probability_over * rows$odds_over - 1
        ev_under <- (1 - rows$probability_over) * rows$odds_under - 1
        chosen_over <- ev_over >= ev_under
        chosen_ev <- ifelse(chosen_over, ev_over, ev_under)
        bet <- chosen_ev > threshold
        profit <- ifelse(
          !bet,
          0,
          ifelse(
            chosen_over == (rows$observed_over == 1),
            ifelse(chosen_over, rows$odds_over - 1, rows$odds_under - 1),
            -1
          )
        )
        ordered_profit <- profit[order(rows$game_datetime)]
        bankroll <- cumsum(ordered_profit)
        drawdown <- if (length(bankroll)) max(cummax(c(0, bankroll))[-1] - bankroll) else 0
        economic_detail[[detail_id]] <- data.frame(
          period_group = period_name,
          league_canonical = league_name,
          model_id = model_id,
          minimum_ev = threshold,
          bets = sum(bet),
          profit = sum(profit),
          yield = if (sum(bet)) sum(profit) / sum(bet) else NA_real_,
          maximum_drawdown = drawdown,
          over_bets = sum(bet & chosen_over),
          under_bets = sum(bet & !chosen_over),
          stringsAsFactors = FALSE
        )
        detail_id <- detail_id + 1L
      }
    }
  }
}
write.csv(
  do.call(rbind, economic_detail),
  file.path(output_dir, "economic_benchmark_by_period_league.csv"),
  row.names = FALSE
)

development <- predictions[predictions$period_group == "development_2023_2025", ]
directed_games <- development$gameid[development$model_id == "weekly_directed_raw"]
same_sample <- development[development$gameid %in% directed_games, ]
same_sample_summary <- aggregate(
  cbind(brier, log_loss, log_score, crps, covered_90) ~ model_id,
  same_sample,
  mean
)
same_sample_counts <- aggregate(gameid ~ model_id, same_sample, length)
names(same_sample_counts)[names(same_sample_counts) == "gameid"] <- "maps"
same_sample_summary <- merge(same_sample_summary, same_sample_counts, by = "model_id")
write.csv(
  same_sample_summary,
  file.path(output_dir, "directed_same_sample_comparison.csv"),
  row.names = FALSE
)

economic_bootstrap <- list()
bootstrap_id <- 1L
set.seed(20260804)
for (model_id in unique(development$model_id)) {
  rows <- development[development$model_id == model_id, ]
  rows$block <- paste(rows$month, rows$series_id, sep = "|")
  blocks_economic <- split(seq_len(nrow(rows)), rows$block)
  for (threshold in c(0, 0.03, 0.05, 0.08, 0.10)) {
    ev_over <- rows$probability_over * rows$odds_over - 1
    ev_under <- (1 - rows$probability_over) * rows$odds_under - 1
    chosen_over <- ev_over >= ev_under
    chosen_ev <- pmax(ev_over, ev_under)
    bet <- chosen_ev > threshold
    profit <- ifelse(
      !bet,
      0,
      ifelse(
        chosen_over == (rows$observed_over == 1),
        ifelse(chosen_over, rows$odds_over - 1, rows$odds_under - 1),
        -1
      )
    )
    if (!any(bet)) {
      interval <- c(NA_real_, NA_real_)
    } else {
      yields <- replicate(2000L, {
        sampled <- sample(names(blocks_economic), length(blocks_economic), replace = TRUE)
        indices <- unlist(blocks_economic[sampled], use.names = FALSE)
        selected_bets <- sum(bet[indices])
        if (selected_bets) sum(profit[indices]) / selected_bets else NA_real_
      })
      interval <- stats::quantile(yields, c(0.025, 0.975), na.rm = TRUE)
    }
    economic_bootstrap[[bootstrap_id]] <- data.frame(
      model_id = model_id,
      minimum_ev = threshold,
      yield_lower_95 = interval[[1]],
      yield_upper_95 = interval[[2]],
      stringsAsFactors = FALSE
    )
    bootstrap_id <- bootstrap_id + 1L
  }
}
write.csv(
  do.call(rbind, economic_bootstrap),
  file.path(output_dir, "economic_benchmark_bootstrap_ci.csv"),
  row.names = FALSE
)

development <- predictions[predictions$period_group == "development_2023_2025", ]
paired <- merge(
  development[development$model_id == "pinnacle_no_vig", c("gameid", "month", "series_id", "brier", "log_loss")],
  development[development$model_id == "market_poisson_center_nb", c("gameid", "brier", "log_loss")],
  by = "gameid",
  suffixes = c("_benchmark", "_candidate")
)
paired$block <- paste(paired$month, paired$series_id, sep = "|")
blocks <- split(seq_len(nrow(paired)), paired$block)
set.seed(20260803)
bootstrap <- replicate(2000L, {
  sampled <- sample(names(blocks), length(blocks), replace = TRUE)
  indices <- unlist(blocks[sampled], use.names = FALSE)
  c(
    brier_difference = mean(paired$brier_candidate[indices] - paired$brier_benchmark[indices]),
    log_loss_difference = mean(paired$log_loss_candidate[indices] - paired$log_loss_benchmark[indices])
  )
})
bootstrap_summary <- data.frame(
  metric = rownames(bootstrap),
  mean_difference = rowMeans(bootstrap),
  lower_95 = apply(bootstrap, 1, stats::quantile, 0.025),
  upper_95 = apply(bootstrap, 1, stats::quantile, 0.975),
  probability_improvement = rowMeans(bootstrap < 0),
  stringsAsFactors = FALSE
)
write.csv(bootstrap_summary, file.path(output_dir, "paired_block_bootstrap.csv"), row.names = FALSE)

comparison_bootstrap <- list()
comparison_id <- 1L
set.seed(20260805)
for (candidate_id in c("market_poisson_center_nb", "league_pace", "weekly_directed_raw")) {
  benchmark_rows <- development[
    development$model_id == "pinnacle_no_vig",
    c("gameid", "month", "series_id", "brier", "log_loss")
  ]
  candidate_rows <- development[
    development$model_id == candidate_id,
    c("gameid", "brier", "log_loss")
  ]
  comparison <- merge(
    benchmark_rows,
    candidate_rows,
    by = "gameid",
    suffixes = c("_benchmark", "_candidate")
  )
  comparison$block <- paste(comparison$month, comparison$series_id, sep = "|")
  comparison_blocks <- split(seq_len(nrow(comparison)), comparison$block)
  draws <- replicate(2000L, {
    sampled <- sample(names(comparison_blocks), length(comparison_blocks), replace = TRUE)
    indices <- unlist(comparison_blocks[sampled], use.names = FALSE)
    c(
      brier = mean(comparison$brier_candidate[indices] - comparison$brier_benchmark[indices]),
      log_loss = mean(comparison$log_loss_candidate[indices] - comparison$log_loss_benchmark[indices])
    )
  })
  comparison_bootstrap[[comparison_id]] <- data.frame(
    candidate_id = candidate_id,
    metric = rownames(draws),
    maps = nrow(comparison),
    mean_difference = rowMeans(draws),
    lower_95 = apply(draws, 1, stats::quantile, 0.025),
    upper_95 = apply(draws, 1, stats::quantile, 0.975),
    probability_improvement = rowMeans(draws < 0),
    stringsAsFactors = FALSE
  )
  comparison_id <- comparison_id + 1L
}
write.csv(
  do.call(rbind, comparison_bootstrap),
  file.path(output_dir, "paired_bootstrap_all_candidates.csv"),
  row.names = FALSE
)

print(metric_summary)
print(economic)
print(bootstrap_summary)
