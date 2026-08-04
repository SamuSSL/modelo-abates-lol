#!/usr/bin/env Rscript

output_dir <- "artifacts/modeling-research/predraft-market-dynamic-duration"
predictions <- read.csv(
  file.path(output_dir, "blend_dispersion_grid_predictions.csv"),
  stringsAsFactors = FALSE
)
predictions$game_datetime <- as.POSIXct(predictions$game_datetime, tz = "UTC")
candidate <- predictions[
  predictions$weight == 0.7 & predictions$theta_multiplier == 0.75,
]
control <- predictions[
  predictions$weight == 1 & predictions$theta_multiplier == 1,
]
comparison <- merge(
  control,
  candidate,
  by = c(
    "gameid", "series_id", "game_datetime", "period_group",
    "league_canonical", "observed_over"
  ),
  suffixes = c("_control", "_candidate")
)
comparison$month <- format(comparison$game_datetime, "%Y-%m")
comparison$block <- paste(comparison$month, comparison$series_id, sep = "|")

summarize <- function(rows) {
  data.frame(
    period_group = rows$period_group[[1L]],
    maps = nrow(rows),
    control_brier = mean(rows$brier_control),
    candidate_brier = mean(rows$brier_candidate),
    control_log_loss = mean(rows$line_log_loss_control),
    candidate_log_loss = mean(rows$line_log_loss_candidate),
    control_count_log_score = mean(rows$count_log_score_control),
    candidate_count_log_score = mean(rows$count_log_score_candidate),
    control_crps = mean(rows$crps_control),
    candidate_crps = mean(rows$crps_candidate),
    control_coverage_90 = mean(rows$covered_90_control),
    candidate_coverage_90 = mean(rows$covered_90_candidate),
    stringsAsFactors = FALSE
  )
}
summary <- do.call(rbind, lapply(split(comparison, comparison$period_group), summarize))
write.csv(
  summary,
  file.path(output_dir, "current_regime_candidate_summary.csv"),
  row.names = FALSE
)

bootstrap_rows <- list()
set.seed(20260807)
for (period_name in unique(comparison$period_group)) {
  rows <- comparison[comparison$period_group == period_name, ]
  blocks <- split(seq_len(nrow(rows)), rows$block)
  draws <- replicate(2000L, {
    sampled <- sample(names(blocks), length(blocks), replace = TRUE)
    index <- unlist(blocks[sampled], use.names = FALSE)
    c(
      brier = mean(rows$brier_candidate[index] - rows$brier_control[index]),
      log_loss = mean(rows$line_log_loss_candidate[index] - rows$line_log_loss_control[index]),
      count_log_score = mean(rows$count_log_score_candidate[index] - rows$count_log_score_control[index]),
      crps = mean(rows$crps_candidate[index] - rows$crps_control[index])
    )
  })
  bootstrap_rows[[period_name]] <- data.frame(
    period_group = period_name,
    metric = rownames(draws),
    maps = nrow(rows),
    mean_difference = rowMeans(draws),
    lower_95 = apply(draws, 1, stats::quantile, 0.025),
    upper_95 = apply(draws, 1, stats::quantile, 0.975),
    probability_improvement = rowMeans(draws < 0),
    stringsAsFactors = FALSE
  )
}
bootstrap <- do.call(rbind, bootstrap_rows)
write.csv(
  bootstrap,
  file.path(output_dir, "current_regime_candidate_bootstrap.csv"),
  row.names = FALSE
)

league <- aggregate(
  cbind(
    brier_control, brier_candidate,
    line_log_loss_control, line_log_loss_candidate
  ) ~ period_group + league_canonical,
  comparison,
  mean
)
counts <- aggregate(
  gameid ~ period_group + league_canonical,
  comparison,
  length
)
names(counts)[names(counts) == "gameid"] <- "maps"
league <- merge(league, counts)
write.csv(
  league,
  file.path(output_dir, "current_regime_candidate_by_league.csv"),
  row.names = FALSE
)
print(summary)
print(bootstrap)
print(league)
