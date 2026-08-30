script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

output_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "market-error-variable-discovery"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

atlas <- readRDS(file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "structural-pinnacle-error-atlas",
  "map-error-atlas.rds"
))
team_history <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "team_map_metrics.rds"
))

atlas$game_datetime <- as.POSIXct(atlas$game_datetime, tz = "UTC")
atlas$t15_quote_time <- as.POSIXct(atlas$t15_quote_time, tz = "UTC")
atlas$live_open_time <- as.POSIXct(atlas$live_open_time, tz = "UTC")
team_history$game_datetime <- as.POSIXct(
  team_history$game_datetime,
  tz = "UTC"
)
team_history$available_at <- team_history$game_datetime +
  as.numeric(team_history$game_length_minutes) * 60 + 5 * 60
team_history <- team_history[
  team_history$competition_role == "target" &
    !is.na(team_history$team_id) &
    nzchar(as.character(team_history$team_id)),
  ,
  drop = FALSE
]
team_history <- team_history[order(team_history$available_at), , drop = FALSE]
history_by_team <- split(team_history, as.character(team_history$team_id))

weighted_mean_safe <- function(value, weight) {
  valid <- is.finite(value) & is.finite(weight) & weight > 0
  if (!any(valid)) {
    return(NA_real_)
  }
  stats::weighted.mean(value[valid], weight[valid])
}

weighted_sd_safe <- function(value, weight) {
  valid <- is.finite(value) & is.finite(weight) & weight > 0
  if (sum(valid) < 2L) {
    return(NA_real_)
  }
  value <- value[valid]
  weight <- weight[valid]
  center <- stats::weighted.mean(value, weight)
  sqrt(sum(weight * (value - center)^2) / sum(weight))
}

team_snapshot <- function(team_id, cutoff, maximum_maps = 30L) {
  history <- history_by_team[[as.character(team_id)]]
  empty <- c(
    history_games = 0, early_combined15 = NA, early_gold_abs = NA,
    first_blood_rate = NA, dragon_rate = NA, baron_rate = NA,
    herald_rate = NA, tower_rate = NA, win_duration = NA,
    loss_duration = NA, win_kpm = NA, loss_kpm = NA,
    win_dpm = NA, loss_dpm = NA, win_total = NA, loss_total = NA,
    total_sd = NA, combined_kpm_sd = NA, trend_combined_kpm = NA,
    trend_duration = NA, trend_early15 = NA, win_games = 0,
    loss_games = 0
  )
  if (is.null(history) || is.na(cutoff)) {
    return(empty)
  }
  history <- history[history$available_at <= cutoff, , drop = FALSE]
  if (nrow(history) == 0L) {
    return(empty)
  }
  history <- history[order(history$available_at, decreasing = TRUE), , drop = FALSE]
  history <- utils::head(history, maximum_maps)
  age_days <- pmax(
    0,
    as.numeric(difftime(cutoff, history$available_at, units = "days"))
  )
  weight <- 0.5^(age_days / 180)
  minutes <- pmax(as.numeric(history$game_length_minutes), 1)
  early_combined <- as.numeric(history$kills_at_15) +
    as.numeric(history$deaths_at_15)
  win <- as.numeric(history$result) == 1
  loss <- as.numeric(history$result) == 0
  recent_count <- min(5L, nrow(history))
  comparison_count <- min(15L, nrow(history))
  recent <- seq_len(recent_count)
  comparison <- seq_len(comparison_count)
  recent_mean <- function(value) mean(value[recent], na.rm = TRUE)
  comparison_mean <- function(value) mean(value[comparison], na.rm = TRUE)
  safe_trend <- function(value) {
    result <- recent_mean(value) - comparison_mean(value)
    if (is.nan(result)) NA_real_ else result
  }
  c(
    history_games = nrow(history),
    early_combined15 = weighted_mean_safe(early_combined, weight),
    early_gold_abs = weighted_mean_safe(abs(history$gold_diff_at_15), weight),
    first_blood_rate = weighted_mean_safe(history$first_blood, weight),
    dragon_rate = weighted_mean_safe(history$dragons / minutes, weight),
    baron_rate = weighted_mean_safe(history$barons / minutes, weight),
    herald_rate = weighted_mean_safe(history$heralds / minutes, weight),
    tower_rate = weighted_mean_safe(history$towers / minutes, weight),
    win_duration = weighted_mean_safe(history$game_length_minutes[win], weight[win]),
    loss_duration = weighted_mean_safe(history$game_length_minutes[loss], weight[loss]),
    win_kpm = weighted_mean_safe(history$kills_per_minute[win], weight[win]),
    loss_kpm = weighted_mean_safe(history$kills_per_minute[loss], weight[loss]),
    win_dpm = weighted_mean_safe(history$deaths_per_minute[win], weight[win]),
    loss_dpm = weighted_mean_safe(history$deaths_per_minute[loss], weight[loss]),
    win_total = weighted_mean_safe(history$total_kills_game[win], weight[win]),
    loss_total = weighted_mean_safe(history$total_kills_game[loss], weight[loss]),
    total_sd = weighted_sd_safe(history$total_kills_game, weight),
    combined_kpm_sd = weighted_sd_safe(history$combined_kills_per_minute, weight),
    trend_combined_kpm = safe_trend(history$combined_kills_per_minute),
    trend_duration = safe_trend(history$game_length_minutes),
    trend_early15 = safe_trend(early_combined),
    win_games = sum(win),
    loss_games = sum(loss)
  )
}

pair_features <- function(blue, red) {
  mean_pair <- function(name) mean(c(blue[[name]], red[[name]]), na.rm = TRUE)
  max_pair <- function(name) {
    value <- c(blue[[name]], red[[name]])
    if (all(!is.finite(value))) NA_real_ else max(value, na.rm = TRUE)
  }
  min_pair <- function(name) {
    value <- c(blue[[name]], red[[name]])
    if (all(!is.finite(value))) NA_real_ else min(value, na.rm = TRUE)
  }
  diff_pair <- function(name) abs(blue[[name]] - red[[name]])
  clean <- function(value) ifelse(is.finite(value), value, NA_real_)
  objective_blue <- blue[["dragon_rate"]] + 2 * blue[["baron_rate"]] +
    blue[["herald_rate"]] + blue[["tower_rate"]]
  objective_red <- red[["dragon_rate"]] + 2 * red[["baron_rate"]] +
    red[["herald_rate"]] + red[["tower_rate"]]
  c(
    early_fight_mean = clean(mean_pair("early_combined15")),
    early_fight_max = clean(max_pair("early_combined15")),
    early_gold_volatility = clean(mean_pair("early_gold_abs")),
    first_blood_style_gap = clean(diff_pair("first_blood_rate")),
    objective_activity_mean = clean(mean(c(objective_blue, objective_red), na.rm = TRUE)),
    objective_activity_max = clean(max(c(objective_blue, objective_red), na.rm = TRUE)),
    objective_style_gap = clean(abs(objective_blue - objective_red)),
    tower_pressure_mean = clean(mean_pair("tower_rate")),
    win_aggression_mean = clean(mean_pair("win_kpm")),
    loss_trade_mean = clean(mean_pair("loss_kpm")),
    loss_collapse_mean = clean(mean_pair("loss_dpm")),
    win_total_mean = clean(mean_pair("win_total")),
    loss_total_mean = clean(mean_pair("loss_total")),
    cross_fight_ceiling = clean(max(c(
      blue[["win_kpm"]] + red[["loss_dpm"]],
      red[["win_kpm"]] + blue[["loss_dpm"]]
    ), na.rm = TRUE)),
    fast_close_duration = clean(min_pair("win_duration")),
    resistance_duration = clean(max_pair("loss_duration")),
    close_resistance_gap = clean(
      max_pair("loss_duration") - min_pair("win_duration")
    ),
    trend_kpm_mean = clean(mean_pair("trend_combined_kpm")),
    trend_kpm_disagreement = clean(diff_pair("trend_combined_kpm")),
    trend_duration_mean = clean(mean_pair("trend_duration")),
    trend_early_mean = clean(mean_pair("trend_early15")),
    total_volatility_mean = clean(mean_pair("total_sd")),
    total_volatility_max = clean(max_pair("total_sd")),
    pace_volatility_mean = clean(mean_pair("combined_kpm_sd")),
    minimum_history = clean(min_pair("history_games")),
    minimum_win_history = clean(min_pair("win_games")),
    minimum_loss_history = clean(min_pair("loss_games"))
  )
}

feature_rows <- vector("list", nrow(atlas))
for (index in seq_len(nrow(atlas))) {
  cutoff <- atlas$t15_quote_time[[index]]
  blue <- team_snapshot(atlas$blue_team_id[[index]], cutoff)
  red <- team_snapshot(atlas$red_team_id[[index]], cutoff)
  feature_rows[[index]] <- data.frame(
    gameid = as.character(atlas$gameid[[index]]),
    as.list(pair_features(blue, red)),
    stringsAsFactors = FALSE
  )
}
features <- do.call(rbind, feature_rows)
data <- merge(atlas, features, by = "gameid", all.x = TRUE, sort = FALSE)
data <- data[match(atlas$gameid, data$gameid), , drop = FALSE]

data$structural_signed <- data$structural_mean - data$market_mean
data$structural_absolute <- abs(data$structural_signed)
data$minimum_history_log <- log1p(data$minimum_history)
data$minimum_win_history_log <- log1p(data$minimum_win_history)
data$minimum_loss_history_log <- log1p(data$minimum_loss_history)

families <- list(
  early_fight = c(
    "early_fight_mean", "early_fight_max", "early_gold_volatility",
    "first_blood_style_gap"
  ),
  objectives = c(
    "objective_activity_mean", "objective_activity_max",
    "objective_style_gap", "tower_pressure_mean"
  ),
  win_loss_behavior = c(
    "win_aggression_mean", "loss_trade_mean", "loss_collapse_mean",
    "win_total_mean", "loss_total_mean", "cross_fight_ceiling"
  ),
  close_resistance = c(
    "fast_close_duration", "resistance_duration", "close_resistance_gap"
  ),
  trend_volatility = c(
    "trend_kpm_mean", "trend_kpm_disagreement", "trend_duration_mean",
    "trend_early_mean", "total_volatility_mean", "total_volatility_max",
    "pace_volatility_mean", "minimum_history_log",
    "minimum_win_history_log", "minimum_loss_history_log"
  )
)
structural_columns <- c("structural_signed", "structural_absolute")
all_new_columns <- unique(unlist(families, use.names = FALSE))
candidates <- list(structural_signal = structural_columns)
for (family_name in names(families)) {
  candidates[[family_name]] <- families[[family_name]]
  candidates[[paste0("structural_plus_", family_name)]] <- unique(c(
    structural_columns,
    families[[family_name]]
  ))
}
candidates$winner_behavior <- c(
  "win_aggression_mean", "win_total_mean", "cross_fight_ceiling"
)
candidates$structural_plus_winner_behavior <- unique(c(
  structural_columns,
  candidates$winner_behavior
))
candidates$loser_behavior <- c(
  "loss_trade_mean", "loss_collapse_mean", "loss_total_mean"
)
candidates$structural_plus_loser_behavior <- unique(c(
  structural_columns,
  candidates$loser_behavior
))
candidates$all_new_variables <- all_new_columns
candidates$structural_plus_all_new <- unique(c(
  structural_columns,
  all_new_columns
))

timings <- list(
  pre_t15 = list(
    mean = "t15_market_mean",
    line = "t15_line",
    probability = "t15_probability_over"
  ),
  live_open = list(
    mean = "market_mean",
    line = "live_line",
    probability = "market_probability_over"
  )
)
lambdas <- c(0.01, 0.1, 1, 10, 100)

impute_matrix <- function(train, validation, columns) {
  train_matrix <- as.matrix(train[, columns, drop = FALSE])
  validation_matrix <- as.matrix(validation[, columns, drop = FALSE])
  storage.mode(train_matrix) <- "double"
  storage.mode(validation_matrix) <- "double"
  medians <- vapply(seq_along(columns), function(index) {
    value <- stats::median(train_matrix[, index], na.rm = TRUE)
    if (!is.finite(value)) 0 else value
  }, numeric(1L))
  for (index in seq_along(columns)) {
    train_matrix[!is.finite(train_matrix[, index]), index] <- medians[[index]]
    validation_matrix[!is.finite(validation_matrix[, index]), index] <- medians[[index]]
  }
  list(train = train_matrix, validation = validation_matrix)
}

fit_predict <- function(train, validation, columns, target, lambda) {
  matrices <- impute_matrix(train, validation, columns)
  fit <- glmnet::glmnet(
    matrices$train,
    train[[target]],
    family = "gaussian",
    alpha = 0,
    lambda = lambda,
    standardize = TRUE,
    intercept = TRUE
  )
  as.numeric(stats::predict(
    fit,
    newx = matrices$validation,
    s = lambda
  ))
}

estimate_theta <- function(observed, mean) {
  objective <- function(log_theta) {
    -sum(stats::dnbinom(
      observed,
      size = exp(log_theta),
      mu = pmax(mean, 0.1),
      log = TRUE
    ))
  }
  exp(stats::optimize(objective, interval = log(c(0.5, 200)))$minimum)
}

score_predictions <- function(frame, mean, timing_id, candidate_id, stage, theta) {
  specification <- timings[[timing_id]]
  line <- as.numeric(frame[[specification$line]])
  mean <- pmax(as.numeric(mean), 0.1)
  observed <- as.numeric(frame$observed_total)
  probability_over <- stats::pnbinom(
    floor(line),
    size = theta,
    mu = mean,
    lower.tail = FALSE
  )
  observed_over <- as.numeric(observed > line)
  support <- 0:150
  crps <- vapply(seq_len(nrow(frame)), function(index) {
    cumulative <- stats::pnbinom(
      support,
      size = theta,
      mu = mean[[index]]
    )
    sum((cumulative - as.numeric(support >= observed[[index]]))^2)
  }, numeric(1L))
  data.frame(
    gameid = as.character(frame$gameid),
    series_id = as.character(frame$series_id),
    league_canonical = as.character(frame$league_canonical),
    game_datetime = as.POSIXct(frame$game_datetime, tz = "UTC"),
    timing_id = timing_id,
    candidate_id = candidate_id,
    stage = stage,
    predicted_mean = mean,
    observed_total = observed,
    line = line,
    probability_over = probability_over,
    observed_over = observed_over,
    crps = crps,
    count_log_score = -stats::dnbinom(
      observed,
      size = theta,
      mu = mean,
      log = TRUE
    ),
    absolute_error = abs(observed - mean),
    brier = (probability_over - observed_over)^2,
    stringsAsFactors = FALSE
  )
}

summarize_scores <- function(scores) {
  metrics <- stats::aggregate(
    cbind(crps, count_log_score, absolute_error, brier) ~
      timing_id + candidate_id + stage,
    scores,
    mean
  )
  counts <- stats::aggregate(
    gameid ~ timing_id + candidate_id + stage,
    scores,
    length
  )
  names(counts)[names(counts) == "gameid"] <- "maps"
  merge(metrics, counts, by = c("timing_id", "candidate_id", "stage"))
}

adjustment <- data[data$sample == "adjustment_mar_apr", , drop = FALSE]
selection <- data[data$sample == "selection_may", , drop = FALSE]
confirmation <- data[data$sample == "confirmation_jun_jul", , drop = FALSE]
development <- rbind(adjustment, selection)

selection_rows <- list()
selection_scores <- list()
selected_specs <- list()
for (timing_id in names(timings)) {
  specification <- timings[[timing_id]]
  target <- paste0(timing_id, "_residual_target")
  adjustment[[target]] <- adjustment$observed_total -
    adjustment[[specification$mean]]
  selection[[target]] <- selection$observed_total -
    selection[[specification$mean]]
  theta <- estimate_theta(
    adjustment$observed_total,
    adjustment[[specification$mean]]
  )
  market_scores <- score_predictions(
    selection,
    selection[[specification$mean]],
    timing_id,
    "market_baseline",
    "selection",
    theta
  )
  selection_scores[[paste(timing_id, "market", sep = "__")]] <- market_scores
  for (candidate_id in names(candidates)) {
    lambda_scores <- list()
    for (lambda in lambdas) {
      correction <- fit_predict(
        adjustment,
        selection,
        candidates[[candidate_id]],
        target,
        lambda
      )
      scores <- score_predictions(
        selection,
        selection[[specification$mean]] + correction,
        timing_id,
        candidate_id,
        "selection",
        theta
      )
      summary <- summarize_scores(scores)
      lambda_scores[[as.character(lambda)]] <- data.frame(
        timing_id = timing_id,
        candidate_id = candidate_id,
        lambda = lambda,
        crps = summary$crps,
        count_log_score = summary$count_log_score,
        absolute_error = summary$absolute_error,
        brier = summary$brier,
        stringsAsFactors = FALSE
      )
    }
    lambda_scores <- do.call(rbind, lambda_scores)
    best <- lambda_scores[order(
      lambda_scores$crps,
      lambda_scores$count_log_score,
      lambda_scores$brier
    ), , drop = FALSE][1L, , drop = FALSE]
    selection_rows[[paste(timing_id, candidate_id, sep = "__")]] <- lambda_scores
    selected_specs[[paste(timing_id, candidate_id, sep = "__")]] <- best
    correction <- fit_predict(
      adjustment,
      selection,
      candidates[[candidate_id]],
      target,
      best$lambda[[1L]]
    )
    selection_scores[[paste(timing_id, candidate_id, sep = "__")]] <-
      score_predictions(
        selection,
        selection[[specification$mean]] + correction,
        timing_id,
        candidate_id,
        "selection",
        theta
      )
  }
}
selection_grid <- do.call(rbind, selection_rows)
selection_scores <- do.call(rbind, selection_scores)
selection_summary <- summarize_scores(selection_scores)
selected_specs <- do.call(rbind, selected_specs)

primary_candidates <- list()
for (timing_id in names(timings)) {
  available <- selection_summary[
    selection_summary$timing_id == timing_id &
      selection_summary$candidate_id != "market_baseline",
    ,
    drop = FALSE
  ]
  primary_candidates[[timing_id]] <- available$candidate_id[[
    order(available$crps, available$count_log_score, available$brier)[[1L]]
  ]]
}

confirmation_scores <- list()
for (timing_id in names(timings)) {
  specification <- timings[[timing_id]]
  target <- paste0(timing_id, "_residual_target")
  development[[target]] <- development$observed_total -
    development[[specification$mean]]
  theta <- estimate_theta(
    development$observed_total,
    development[[specification$mean]]
  )
  confirmation_scores[[paste(timing_id, "market", sep = "__")]] <-
    score_predictions(
      confirmation,
      confirmation[[specification$mean]],
      timing_id,
      "market_baseline",
      "confirmation",
      theta
    )
  for (candidate_id in names(candidates)) {
    specification_row <- selected_specs[
      selected_specs$timing_id == timing_id &
        selected_specs$candidate_id == candidate_id,
      ,
      drop = FALSE
    ]
    correction <- fit_predict(
      development,
      confirmation,
      candidates[[candidate_id]],
      target,
      specification_row$lambda[[1L]]
    )
    confirmation_scores[[paste(timing_id, candidate_id, sep = "__")]] <-
      score_predictions(
        confirmation,
        confirmation[[specification$mean]] + correction,
        timing_id,
        candidate_id,
        "confirmation",
        theta
      )
  }
}
confirmation_scores <- do.call(rbind, confirmation_scores)
confirmation_summary <- summarize_scores(confirmation_scores)

lambda_sensitivity_rows <- list()
for (timing_id in names(timings)) {
  candidate_id <- primary_candidates[[timing_id]]
  specification <- timings[[timing_id]]
  target <- paste0(timing_id, "_residual_target")
  theta <- estimate_theta(
    development$observed_total,
    development[[specification$mean]]
  )
  for (lambda in lambdas) {
    correction <- fit_predict(
      development,
      confirmation,
      candidates[[candidate_id]],
      target,
      lambda
    )
    scores <- score_predictions(
      confirmation,
      confirmation[[specification$mean]] + correction,
      timing_id,
      candidate_id,
      "confirmation",
      theta
    )
    summary <- summarize_scores(scores)
    lambda_sensitivity_rows[[paste(timing_id, lambda, sep = "__")]] <- data.frame(
      timing_id = timing_id,
      candidate_id = candidate_id,
      lambda = lambda,
      crps = summary$crps,
      count_log_score = summary$count_log_score,
      absolute_error = summary$absolute_error,
      brier = summary$brier,
      stringsAsFactors = FALSE
    )
  }
}
lambda_sensitivity <- do.call(rbind, lambda_sensitivity_rows)

paired_bootstrap <- function(candidate, baseline, draws = 2000L, seed = 20260805L) {
  merged <- merge(
    candidate[, c("gameid", "series_id", "crps", "count_log_score", "brier")],
    baseline[, c("gameid", "crps", "count_log_score", "brier")],
    by = "gameid",
    suffixes = c("_candidate", "_baseline")
  )
  series <- unique(merged$series_id)
  set.seed(seed)
  metrics <- c("crps", "count_log_score", "brier")
  result <- list()
  for (metric in metrics) {
    difference <- merged[[paste0(metric, "_candidate")]] -
      merged[[paste0(metric, "_baseline")]]
    series_difference <- split(difference, merged$series_id)
    sampled <- replicate(draws, {
      sampled_series <- sample(series, length(series), replace = TRUE)
      mean(unlist(series_difference[sampled_series], use.names = FALSE))
    })
    result[[metric]] <- data.frame(
      metric = metric,
      maps = nrow(merged),
      mean_difference = mean(difference),
      lower_95 = stats::quantile(sampled, 0.025),
      upper_95 = stats::quantile(sampled, 0.975),
      probability_candidate_better = mean(sampled < 0),
      stringsAsFactors = FALSE
    )
  }
  do.call(rbind, result)
}

bootstrap_rows <- list()
for (timing_id in names(timings)) {
  candidate_id <- primary_candidates[[timing_id]]
  candidate <- confirmation_scores[
    confirmation_scores$timing_id == timing_id &
      confirmation_scores$candidate_id == candidate_id,
    ,
    drop = FALSE
  ]
  baseline <- confirmation_scores[
    confirmation_scores$timing_id == timing_id &
      confirmation_scores$candidate_id == "market_baseline",
    ,
    drop = FALSE
  ]
  bootstrap <- paired_bootstrap(candidate, baseline)
  bootstrap$timing_id <- timing_id
  bootstrap$candidate_id <- candidate_id
  bootstrap_rows[[timing_id]] <- bootstrap
}
bootstrap_summary <- do.call(rbind, bootstrap_rows)

primary_by_league <- list()
for (timing_id in names(timings)) {
  ids <- c("market_baseline", primary_candidates[[timing_id]])
  scores <- confirmation_scores[
    confirmation_scores$timing_id == timing_id &
      confirmation_scores$candidate_id %in% ids,
    ,
    drop = FALSE
  ]
  summary <- stats::aggregate(
    cbind(crps, count_log_score, absolute_error, brier) ~
      timing_id + candidate_id + league_canonical,
    scores,
    mean
  )
  counts <- stats::aggregate(
    gameid ~ timing_id + candidate_id + league_canonical,
    scores,
    length
  )
  names(counts)[names(counts) == "gameid"] <- "maps"
  primary_by_league[[timing_id]] <- merge(
    summary,
    counts,
    by = c("timing_id", "candidate_id", "league_canonical")
  )
}
primary_by_league <- do.call(rbind, primary_by_league)

correlation_rows <- list()
for (timing_id in names(timings)) {
  residual <- data$observed_total - data[[timings[[timing_id]]$mean]]
  for (stage in unique(data$sample)) {
    selected <- data$sample == stage
    for (feature in all_new_columns) {
      valid <- selected & is.finite(data[[feature]]) & is.finite(residual)
      correlation_rows[[length(correlation_rows) + 1L]] <- data.frame(
        timing_id = timing_id,
        stage = stage,
        feature = feature,
        maps = sum(valid),
        correlation = if (sum(valid) >= 10L) {
          stats::cor(data[[feature]][valid], residual[valid])
        } else {
          NA_real_
        },
        stringsAsFactors = FALSE
      )
    }
  }
}
correlations <- do.call(rbind, correlation_rows)

experiment_registry <- data.frame(
  experiment_id = paste0("VAR-", sprintf("%02d", seq_along(candidates))),
  candidate_id = names(candidates),
  feature_count = vapply(candidates, length, integer(1L)),
  adjustment = "2026-03-01 through 2026-04-30",
  selection = "2026-05-01 through 2026-05-31",
  confirmation = "2026-06-01 through 2026-07-31",
  primary_metric = "CRPS",
  status = "historical exploratory",
  stringsAsFactors = FALSE
)

coefficient_rows <- list()
for (timing_id in names(timings)) {
  candidate_id <- primary_candidates[[timing_id]]
  columns <- candidates[[candidate_id]]
  target <- paste0(timing_id, "_residual_target")
  specification_row <- selected_specs[
    selected_specs$timing_id == timing_id &
      selected_specs$candidate_id == candidate_id,
    ,
    drop = FALSE
  ]
  matrices <- impute_matrix(development, confirmation, columns)
  fit <- glmnet::glmnet(
    matrices$train,
    development[[target]],
    family = "gaussian",
    alpha = 0,
    lambda = specification_row$lambda[[1L]],
    standardize = TRUE,
    intercept = TRUE
  )
  coefficient <- as.matrix(stats::coef(
    fit,
    s = specification_row$lambda[[1L]]
  ))[, 1L]
  coefficient_rows[[timing_id]] <- data.frame(
    timing_id = timing_id,
    candidate_id = candidate_id,
    lambda = specification_row$lambda[[1L]],
    feature = names(coefficient),
    coefficient = as.numeric(coefficient),
    stringsAsFactors = FALSE
  )
}
selected_coefficients <- do.call(rbind, coefficient_rows)

utils::write.csv(features, file.path(output_dir, "point-in-time-features.csv"), row.names = FALSE)
utils::write.csv(selection_grid, file.path(output_dir, "selection-lambda-grid.csv"), row.names = FALSE)
utils::write.csv(selection_summary, file.path(output_dir, "selection-summary.csv"), row.names = FALSE)
utils::write.csv(confirmation_summary, file.path(output_dir, "confirmation-summary.csv"), row.names = FALSE)
utils::write.csv(lambda_sensitivity, file.path(output_dir, "confirmation-lambda-sensitivity.csv"), row.names = FALSE)
utils::write.csv(bootstrap_summary, file.path(output_dir, "confirmation-bootstrap.csv"), row.names = FALSE)
utils::write.csv(primary_by_league, file.path(output_dir, "primary-by-league.csv"), row.names = FALSE)
utils::write.csv(correlations, file.path(output_dir, "feature-residual-correlations.csv"), row.names = FALSE)
utils::write.csv(experiment_registry, file.path(output_dir, "experiment-registry.csv"), row.names = FALSE)
utils::write.csv(selected_coefficients, file.path(output_dir, "selected-coefficients.csv"), row.names = FALSE)
saveRDS(
  list(
    data = data,
    families = families,
    candidates = candidates,
    primary_candidates = primary_candidates,
    selection_scores = selection_scores,
    confirmation_scores = confirmation_scores
  ),
  file.path(output_dir, "evaluation-results.rds")
)
jsonlite::write_json(
  list(
    adjustment_maps = nrow(adjustment),
    selection_maps = nrow(selection),
    confirmation_maps = nrow(confirmation),
    primary_candidates = primary_candidates,
    prospective_test = FALSE,
    evidence_status = "historical_reused_exploratory"
  ),
  file.path(output_dir, "selection.json"),
  auto_unbox = TRUE,
  pretty = TRUE
)

print(selection_summary[order(
  selection_summary$timing_id,
  selection_summary$crps
), ], row.names = FALSE)
print(confirmation_summary[order(
  confirmation_summary$timing_id,
  confirmation_summary$crps
), ], row.names = FALSE)
print(bootstrap_summary, row.names = FALSE)
