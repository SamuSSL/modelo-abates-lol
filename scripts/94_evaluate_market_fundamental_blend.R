#!/usr/bin/env Rscript

pkgload::load_all(".", quiet = TRUE)
output_dir <- "artifacts/modeling-research/predraft-market-dynamic-duration"
total <- read.csv(
  file.path(output_dir, "total_snapshot_selection.csv"),
  stringsAsFactors = FALSE
)
directed <- readRDS(file.path(
  "artifacts", "modeling-research", "directed-market-regime-calibration",
  "weekly_base_predictions.rds"
))
directed <- directed[!duplicated(directed$gameid), c(
  "gameid", "base_mean", "base_theta", "weekly_cutoff"
)]
data <- merge(total, directed, by = "gameid", all = FALSE)
data$game_datetime <- as.POSIXct(data$game_datetime, tz = "UTC")
data$weekly_cutoff <- as.POSIXct(data$weekly_cutoff, tz = "UTC")
data <- data[order(data$game_datetime, data$gameid), ]
raw_over <- 1 / data$odds_over
raw_under <- 1 / data$odds_under
data$market_probability_over <- raw_over / (raw_over + raw_under)
data$market_mean <- mapply(function(line, probability_over, theta) {
  invert_market_count_mean(
    line,
    probability_over,
    distribution = "negative_binomial",
    theta = theta
  )
}, data$line, data$market_probability_over, data$base_theta)
data$fundamental_delta <- log(data$base_mean) - log(data$market_mean)
data$observed_over <- as.numeric(data$observed_total > data$line)

weights <- seq(0, 1, by = 0.1)
candidate_rows <- list()
candidate_index <- 1L
for (weight in weights) {
  mean_value <- exp(log(data$market_mean) + weight * data$fundamental_delta)
  probability_over <- stats::pnbinom(
    floor(data$line),
    size = data$base_theta,
    mu = mean_value,
    lower.tail = FALSE
  )
  candidate_rows[[candidate_index]] <- data.frame(
    gameid = data$gameid,
    series_id = data$series_id,
    game_datetime = data$game_datetime,
    weekly_cutoff = data$weekly_cutoff,
    period_group = data$period_group,
    league_canonical = data$league_canonical,
    candidate_id = sprintf("market_fundamental_w%.1f", weight),
    correction_weight = weight,
    observed_total = data$observed_total,
    line = data$line,
    probability_over = probability_over,
    observed_over = data$observed_over,
    brier = (probability_over - data$observed_over)^2,
    log_loss = -(
      data$observed_over * log(pmax(probability_over, 1e-15)) +
      (1 - data$observed_over) * log(pmax(1 - probability_over, 1e-15))
    ),
    predicted_mean = mean_value,
    stringsAsFactors = FALSE
  )
  candidate_index <- candidate_index + 1L
}
predictions <- do.call(rbind, candidate_rows)
predictions$month <- format(predictions$game_datetime, "%Y-%m")
write.csv(
  predictions,
  file.path(output_dir, "market_fundamental_blend_predictions.csv"),
  row.names = FALSE
)

development <- predictions[
  predictions$period_group == "development_2023_2025",
]
diagnostic <- predictions[predictions$period_group == "2026_diagnostic", ]
summarize <- function(rows) {
  metrics <- aggregate(
    cbind(brier, log_loss, probability_over, observed_over) ~
      candidate_id + correction_weight,
    rows,
    mean
  )
  counts <- aggregate(gameid ~ candidate_id + correction_weight, rows, length)
  names(counts)[names(counts) == "gameid"] <- "maps"
  result <- merge(metrics, counts)
  result$calibration_error <- abs(result$probability_over - result$observed_over)
  result[order(result$log_loss, result$brier), ]
}
development_summary <- summarize(development)
development_summary$period <- "development_2025"
diagnostic_summary <- summarize(diagnostic)
diagnostic_summary$period <- "diagnostic_2026"
summary <- rbind(development_summary, diagnostic_summary)
write.csv(
  summary,
  file.path(output_dir, "market_fundamental_blend_summary.csv"),
  row.names = FALSE
)

baseline <- development[development$correction_weight == 0, ]
blocks <- unique(paste(baseline$month, baseline$series_id, sep = "|"))
block_indices <- split(
  seq_len(nrow(baseline)),
  paste(baseline$month, baseline$series_id, sep = "|")
)
set.seed(20260806)
bootstrap_rows <- list()
bootstrap_index <- 1L
for (weight in weights[weights > 0]) {
  candidate <- development[development$correction_weight == weight, ]
  comparison <- merge(
    baseline[c("gameid", "month", "series_id", "brier", "log_loss")],
    candidate[c("gameid", "brier", "log_loss")],
    by = "gameid",
    suffixes = c("_market", "_candidate")
  )
  comparison_blocks <- split(
    seq_len(nrow(comparison)),
    paste(comparison$month, comparison$series_id, sep = "|")
  )
  draws <- replicate(2000L, {
    sampled <- sample(names(comparison_blocks), length(comparison_blocks), replace = TRUE)
    index <- unlist(comparison_blocks[sampled], use.names = FALSE)
    c(
      brier = mean(comparison$brier_candidate[index] - comparison$brier_market[index]),
      log_loss = mean(comparison$log_loss_candidate[index] - comparison$log_loss_market[index])
    )
  })
  bootstrap_rows[[bootstrap_index]] <- data.frame(
    correction_weight = weight,
    metric = rownames(draws),
    maps = nrow(comparison),
    mean_difference = rowMeans(draws),
    lower_95 = apply(draws, 1, stats::quantile, 0.025),
    upper_95 = apply(draws, 1, stats::quantile, 0.975),
    probability_improvement = rowMeans(draws < 0),
    stringsAsFactors = FALSE
  )
  bootstrap_index <- bootstrap_index + 1L
}
bootstrap <- do.call(rbind, bootstrap_rows)
write.csv(
  bootstrap,
  file.path(output_dir, "market_fundamental_blend_bootstrap.csv"),
  row.names = FALSE
)

print(summary)
print(bootstrap)
