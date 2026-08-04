#!/usr/bin/env Rscript

pkgload::load_all(".", quiet = TRUE)
output_dir <- "artifacts/modeling-research/predraft-market-dynamic-duration"
total <- read.csv(file.path(output_dir, "total_snapshot_selection.csv"))
team <- read.csv(file.path(output_dir, "team_total_snapshot_selection.csv"))
total$game_datetime <- as.POSIXct(total$game_datetime, tz = "UTC")
team$odds_timestamp <- as.POSIXct(team$odds_timestamp, tz = "UTC")

team$raw_over <- 1 / team$odds_over
team$raw_under <- 1 / team$odds_under
team$probability_over <- team$raw_over / (team$raw_over + team$raw_under)
team$implied_mean <- mapply(
  invert_market_count_mean,
  team$line,
  team$probability_over,
  MoreArgs = list(distribution = "poisson")
)
home <- team[team$team_side == "home", c("gameid", "implied_mean")]
away <- team[team$team_side == "away", c("gameid", "implied_mean")]
names(home)[[2L]] <- "home_team_mean"
names(away)[[2L]] <- "away_team_mean"
data <- merge(merge(total, home, by = "gameid"), away, by = "gameid")
data <- data[!duplicated(data$gameid), ]
data <- data[order(data$game_datetime, data$gameid), ]

weekday <- as.POSIXlt(data$game_datetime, tz = "UTC")$wday
data$weekly_cutoff <- as.POSIXct(
  as.Date(data$game_datetime) - ((weekday - 6) %% 7),
  tz = "UTC"
)
directed <- readRDS(file.path(
  "artifacts", "modeling-research", "directed-market-regime-calibration",
  "weekly_base_predictions.rds"
))
theta_by_week <- aggregate(
  directed$base_theta,
  list(weekly_cutoff = as.POSIXct(directed$weekly_cutoff, tz = "UTC")),
  stats::median
)
names(theta_by_week)[[2L]] <- "theta"
theta_by_week <- theta_by_week[order(theta_by_week$weekly_cutoff), ]
data$theta <- vapply(data$weekly_cutoff, function(cutoff) {
  eligible <- theta_by_week$weekly_cutoff <= cutoff
  if (!any(eligible)) return(theta_by_week$theta[[1L]])
  tail(theta_by_week$theta[eligible], 1L)
}, numeric(1))

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
}, data$line, data$market_probability_over, data$theta)
data$team_sum_mean <- data$home_team_mean + data$away_team_mean
data$team_gap_log <- log(data$team_sum_mean / data$market_mean)
data$share_imbalance <- abs(log(data$home_team_mean / data$away_team_mean))
data$observed_over <- as.numeric(data$observed_total > data$line)

ridge_fit <- function(train, feature_names, lambda) {
  factor_levels <- list()
  if ("league_canonical" %in% feature_names) {
    train$league_canonical <- factor(train$league_canonical)
    factor_levels$league_canonical <- levels(train$league_canonical)
  }
  x <- stats::model.matrix(
    stats::reformulate(feature_names),
    data = train
  )
  center <- colMeans(x[, -1, drop = FALSE])
  scale <- apply(x[, -1, drop = FALSE], 2, stats::sd)
  scale[!is.finite(scale) | scale == 0] <- 1
  x[, -1] <- sweep(sweep(x[, -1, drop = FALSE], 2, center), 2, scale, "/")
  y <- log(train$observed_total + 0.5) - log(train$market_mean)
  penalty <- diag(ncol(x)) * lambda
  penalty[[1L, 1L]] <- 0
  coefficient <- solve(crossprod(x) + penalty, crossprod(x, y))
  list(
    coefficient = coefficient,
    feature_names = feature_names,
    columns = colnames(x),
    center = center,
    scale = scale,
    factor_levels = factor_levels
  )
}

ridge_predict <- function(fit, new_data) {
  if ("league_canonical" %in% names(fit$factor_levels)) {
    new_data$league_canonical <- factor(
      new_data$league_canonical,
      levels = fit$factor_levels$league_canonical
    )
  }
  x <- stats::model.matrix(
    stats::reformulate(fit$feature_names),
    data = new_data
  )
  missing <- setdiff(fit$columns, colnames(x))
  if (length(missing)) {
    x <- cbind(x, matrix(0, nrow(x), length(missing), dimnames = list(NULL, missing)))
  }
  x <- x[, fit$columns, drop = FALSE]
  x[, -1] <- sweep(
    sweep(x[, -1, drop = FALSE], 2, fit$center),
    2,
    fit$scale,
    "/"
  )
  exp(log(new_data$market_mean) + as.numeric(x %*% fit$coefficient))
}

specifications <- list(
  market_total_only = list(features = character(), lambda = Inf),
  team_gap_ridge_1 = list(features = "team_gap_log", lambda = 1),
  team_gap_ridge_10 = list(features = "team_gap_log", lambda = 10),
  team_gap_share_ridge_10 = list(
    features = c("team_gap_log", "share_imbalance"), lambda = 10
  ),
  team_gap_league_pooling = list(
    features = c("team_gap_log", "share_imbalance", "league_canonical"),
    lambda = 10
  )
)

prediction_rows <- list()
prediction_index <- 1L
cutoffs <- sort(unique(data$weekly_cutoff))
for (candidate_id in names(specifications)) {
  specification <- specifications[[candidate_id]]
  for (cutoff in cutoffs) {
    train <- data[data$weekly_cutoff < cutoff, ]
    test <- data[data$weekly_cutoff == cutoff, ]
    final_mean <- test$market_mean
    fitted <- FALSE
    if (candidate_id != "market_total_only" && nrow(train) >= 80L) {
      fit <- ridge_fit(train, specification$features, specification$lambda)
      final_mean <- ridge_predict(fit, test)
      fitted <- TRUE
    }
    probability_over <- stats::pnbinom(
      floor(test$line),
      size = test$theta,
      mu = final_mean,
      lower.tail = FALSE
    )
    prediction_rows[[prediction_index]] <- data.frame(
      gameid = test$gameid,
      series_id = test$series_id,
      game_datetime = test$game_datetime,
      weekly_cutoff = test$weekly_cutoff,
      period_group = test$period_group,
      league_canonical = test$league_canonical,
      candidate_id = candidate_id,
      fitted = fitted,
      observed_over = test$observed_over,
      probability_over = probability_over,
      brier = (probability_over - test$observed_over)^2,
      log_loss = -(
        test$observed_over * log(pmax(probability_over, 1e-15)) +
        (1 - test$observed_over) * log(pmax(1 - probability_over, 1e-15))
      ),
      stringsAsFactors = FALSE
    )
    prediction_index <- prediction_index + 1L
  }
}
predictions <- do.call(rbind, prediction_rows)
predictions$month <- format(predictions$game_datetime, "%Y-%m")
write.csv(
  predictions,
  file.path(output_dir, "team_total_residual_predictions.csv"),
  row.names = FALSE
)

summary <- aggregate(
  cbind(brier, log_loss, probability_over, observed_over) ~
    period_group + candidate_id,
  predictions,
  mean
)
counts <- aggregate(
  cbind(maps = as.numeric(predictions$fitted), total_maps = rep(1, nrow(predictions))) ~
    period_group + candidate_id,
  predictions,
  sum
)
summary <- merge(summary, counts)
summary$calibration_error <- abs(summary$probability_over - summary$observed_over)
summary <- summary[order(summary$period_group, summary$log_loss), ]
write.csv(
  summary,
  file.path(output_dir, "team_total_residual_summary.csv"),
  row.names = FALSE
)

bootstrap_rows <- list()
bootstrap_index <- 1L
set.seed(20260808)
for (period_name in unique(predictions$period_group)) {
  baseline <- predictions[
    predictions$period_group == period_name &
      predictions$candidate_id == "market_total_only",
  ]
  for (candidate_id in setdiff(names(specifications), "market_total_only")) {
    candidate <- predictions[
      predictions$period_group == period_name &
        predictions$candidate_id == candidate_id,
    ]
    comparison <- merge(
      baseline[c("gameid", "month", "series_id", "brier", "log_loss")],
      candidate[c("gameid", "brier", "log_loss", "fitted")],
      by = "gameid",
      suffixes = c("_market", "_candidate")
    )
    comparison <- comparison[comparison$fitted, ]
    blocks <- split(
      seq_len(nrow(comparison)),
      paste(comparison$month, comparison$series_id, sep = "|")
    )
    if (nrow(comparison) == 0L) next
    draws <- replicate(2000L, {
      sampled <- sample(names(blocks), length(blocks), replace = TRUE)
      index <- unlist(blocks[sampled], use.names = FALSE)
      c(
        brier = mean(comparison$brier_candidate[index] - comparison$brier_market[index]),
        log_loss = mean(comparison$log_loss_candidate[index] - comparison$log_loss_market[index])
      )
    })
    bootstrap_rows[[bootstrap_index]] <- data.frame(
      period_group = period_name,
      candidate_id = candidate_id,
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
}
bootstrap <- do.call(rbind, bootstrap_rows)
write.csv(
  bootstrap,
  file.path(output_dir, "team_total_residual_bootstrap.csv"),
  row.names = FALSE
)
print(summary)
print(bootstrap)
