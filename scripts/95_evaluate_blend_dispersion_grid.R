#!/usr/bin/env Rscript

pkgload::load_all(".", quiet = TRUE)
output_dir <- "artifacts/modeling-research/predraft-market-dynamic-duration"
total <- read.csv(file.path(output_dir, "total_snapshot_selection.csv"))
directed <- readRDS(file.path(
  "artifacts", "modeling-research", "directed-market-regime-calibration",
  "weekly_base_predictions.rds"
))
directed <- directed[!duplicated(directed$gameid), c(
  "gameid", "base_mean", "base_theta", "weekly_cutoff"
)]
data <- merge(total, directed, by = "gameid", all = FALSE)
data$game_datetime <- as.POSIXct(data$game_datetime, tz = "UTC")
data <- data[order(data$game_datetime, data$gameid), ]
raw_over <- 1 / data$odds_over
raw_under <- 1 / data$odds_under
data$market_probability_over <- raw_over / (raw_over + raw_under)
data$observed_over <- as.numeric(data$observed_total > data$line)

score_configuration <- function(weight, theta_multiplier) {
  effective_theta <- data$base_theta * theta_multiplier
  market_mean <- mapply(function(line, probability_over, theta) {
    invert_market_count_mean(
      line,
      probability_over,
      distribution = "negative_binomial",
      theta = theta
    )
  }, data$line, data$market_probability_over, effective_theta)
  final_mean <- exp(
    log(market_mean) + weight * (log(data$base_mean) - log(market_mean))
  )
  probability_over <- stats::pnbinom(
    floor(data$line),
    size = effective_theta,
    mu = final_mean,
    lower.tail = FALSE
  )
  pmf_scores <- lapply(seq_len(nrow(data)), function(index) {
    support <- 0:150
    pmf <- stats::dnbinom(
      support,
      size = effective_theta[[index]],
      mu = final_mean[[index]]
    )
    pmf[[length(pmf)]] <- pmf[[length(pmf)]] + max(0, 1 - sum(pmf))
    cumulative <- cumsum(pmf)
    observed <- data$observed_total[[index]]
    observed_index <- min(observed, max(support)) + 1L
    lower <- support[which(cumulative >= 0.05)[[1L]]]
    upper <- support[which(cumulative >= 0.95)[[1L]]]
    c(
      count_log_score = -log(max(pmf[[observed_index]], 1e-15)),
      crps = sum((cumulative - as.numeric(support >= observed))^2),
      covered_90 = as.numeric(observed >= lower && observed <= upper)
    )
  })
  pmf_scores <- do.call(rbind, pmf_scores)
  data.frame(
    gameid = data$gameid,
    series_id = data$series_id,
    game_datetime = data$game_datetime,
    period_group = data$period_group,
    league_canonical = data$league_canonical,
    weight = weight,
    theta_multiplier = theta_multiplier,
    observed_over = data$observed_over,
    probability_over = probability_over,
    brier = (probability_over - data$observed_over)^2,
    line_log_loss = -(
      data$observed_over * log(pmax(probability_over, 1e-15)) +
      (1 - data$observed_over) * log(pmax(1 - probability_over, 1e-15))
    ),
    count_log_score = pmf_scores[, "count_log_score"],
    crps = pmf_scores[, "crps"],
    covered_90 = pmf_scores[, "covered_90"],
    stringsAsFactors = FALSE
  )
}

grid <- expand.grid(
  weight = seq(0, 1, by = 0.1),
  theta_multiplier = c(0.75, 1, 1.25, 1.5, 2),
  KEEP.OUT.ATTRS = FALSE
)
predictions <- do.call(rbind, lapply(seq_len(nrow(grid)), function(index) {
  score_configuration(grid$weight[[index]], grid$theta_multiplier[[index]])
}))
write.csv(
  predictions,
  file.path(output_dir, "blend_dispersion_grid_predictions.csv"),
  row.names = FALSE
)

summaries <- lapply(
  split(predictions, predictions$period_group),
  function(rows) {
    summary <- aggregate(
      cbind(
        brier, line_log_loss, count_log_score, crps, covered_90,
        probability_over, observed_over
      ) ~ weight + theta_multiplier,
      rows,
      mean
    )
    counts <- aggregate(gameid ~ weight + theta_multiplier, rows, length)
    names(counts)[names(counts) == "gameid"] <- "maps"
    summary <- merge(summary, counts)
    summary$calibration_error <- abs(summary$probability_over - summary$observed_over)
    summary$period_group <- rows$period_group[[1L]]
    summary
  }
)
summary <- do.call(rbind, summaries)
summary <- summary[order(summary$period_group, summary$line_log_loss, summary$brier), ]
write.csv(
  summary,
  file.path(output_dir, "blend_dispersion_grid_summary.csv"),
  row.names = FALSE
)
print(head(summary[summary$period_group == "development_2023_2025", ], 15))
print(head(summary[summary$period_group == "2026_diagnostic", ], 15))
