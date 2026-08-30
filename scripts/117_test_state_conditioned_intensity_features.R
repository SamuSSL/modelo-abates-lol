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
  "state-conditioned-intensity-challenger"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

expanded_path <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "market-error-variable-expanded-validation",
  "expanded-validation-results.rds"
)
atlas_path <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "structural-pinnacle-error-atlas",
  "map-error-atlas.rds"
)
market_experiment_path <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "pinnacle-market-anchored-model",
  "experiment-summary.csv"
)
if (!all(file.exists(c(expanded_path, atlas_path, market_experiment_path)))) {
  stop("Artefatos de mercado ausentes.", call. = FALSE)
}

expanded <- readRDS(expanded_path)
pre <- expanded$data
pre$game_datetime <- as.POSIXct(pre$game_datetime, tz = "UTC")
pre$odds_timestamp <- as.POSIXct(pre$odds_timestamp, tz = "UTC")
pre$timing_id <- "pre_t15"
pre$market_line <- as.numeric(pre$line)
pre$market_theta <- as.numeric(expanded$market_theta)

atlas <- readRDS(atlas_path)
atlas$game_datetime <- as.POSIXct(atlas$game_datetime, tz = "UTC")
atlas$live_open_time <- as.POSIXct(atlas$live_open_time, tz = "UTC")
atlas$timing_id <- "live_open"
atlas$market_line <- as.numeric(atlas$live_line)
atlas$market_theta <- as.numeric(utils::read.csv(
  market_experiment_path,
  stringsAsFactors = FALSE
)$market_theta[[1L]])

team_history <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "team_map_metrics.rds"
))
team_history$game_datetime <- as.POSIXct(
  team_history$game_datetime,
  tz = "UTC"
)
team_history$available_at <- team_history$game_datetime +
  as.numeric(team_history$game_length_minutes) * 60 + 5 * 60
team_history$post_15_minutes <- pmax(
  as.numeric(team_history$game_length_minutes) - 15,
  1
)
team_history$early_total <- as.numeric(team_history$combined_kills_at_15)
team_history$early_pace <- team_history$early_total / 15
team_history$own_post_15_kpm <- pmax(
  as.numeric(team_history$team_kills) - as.numeric(team_history$kills_at_15),
  0
) / team_history$post_15_minutes
team_history$opponent_post_15_kpm <- pmax(
  as.numeric(team_history$team_deaths) - as.numeric(team_history$deaths_at_15),
  0
) / team_history$post_15_minutes
team_history$combined_post_15_kpm <- pmax(
  as.numeric(team_history$total_kills_game) - team_history$early_total,
  0
) / team_history$post_15_minutes
team_history$state_15 <- ifelse(
  team_history$gold_diff_at_15 > 500,
  "ahead",
  ifelse(team_history$gold_diff_at_15 < -500, "behind", "even")
)
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

weighted_covariance_safe <- function(x, y, weight) {
  valid <- is.finite(x) & is.finite(y) & is.finite(weight) & weight > 0
  if (sum(valid) < 5L) {
    return(NA_real_)
  }
  x <- x[valid]
  y <- y[valid]
  weight <- weight[valid]
  center_x <- stats::weighted.mean(x, weight)
  center_y <- stats::weighted.mean(y, weight)
  sum(weight * (x - center_x) * (y - center_y)) / sum(weight)
}

weighted_correlation_safe <- function(x, y, weight) {
  covariance <- weighted_covariance_safe(x, y, weight)
  variance_x <- weighted_covariance_safe(x, x, weight)
  variance_y <- weighted_covariance_safe(y, y, weight)
  if (
    !is.finite(covariance) || !is.finite(variance_x) ||
      !is.finite(variance_y) || variance_x <= 0 || variance_y <= 0
  ) {
    return(NA_real_)
  }
  covariance / sqrt(variance_x * variance_y)
}

team_snapshot <- function(team_id, cutoff, maximum_maps = 40L) {
  history <- history_by_team[[as.character(team_id)]]
  empty <- c(
    history_games = 0,
    ahead_games = 0,
    behind_games = 0,
    even_games = 0,
    ahead_own_post15 = NA,
    ahead_opponent_post15 = NA,
    ahead_combined_post15 = NA,
    ahead_duration = NA,
    ahead_win_rate = NA,
    behind_own_post15 = NA,
    behind_opponent_post15 = NA,
    behind_combined_post15 = NA,
    behind_duration = NA,
    behind_comeback_rate = NA,
    even_combined_post15 = NA,
    even_duration = NA,
    early_pace_mean = NA,
    post15_pace_mean = NA,
    early_late_slope = NA,
    early_late_correlation = NA,
    early_late_gap = NA
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
  ahead <- history$state_15 == "ahead"
  behind <- history$state_15 == "behind"
  even <- history$state_15 == "even"
  early_late_covariance <- weighted_covariance_safe(
    history$early_pace,
    history$combined_post_15_kpm,
    weight
  )
  early_variance <- weighted_covariance_safe(
    history$early_pace,
    history$early_pace,
    weight
  )
  c(
    history_games = nrow(history),
    ahead_games = sum(ahead, na.rm = TRUE),
    behind_games = sum(behind, na.rm = TRUE),
    even_games = sum(even, na.rm = TRUE),
    ahead_own_post15 = weighted_mean_safe(
      history$own_post_15_kpm[ahead], weight[ahead]
    ),
    ahead_opponent_post15 = weighted_mean_safe(
      history$opponent_post_15_kpm[ahead], weight[ahead]
    ),
    ahead_combined_post15 = weighted_mean_safe(
      history$combined_post_15_kpm[ahead], weight[ahead]
    ),
    ahead_duration = weighted_mean_safe(
      history$game_length_minutes[ahead], weight[ahead]
    ),
    ahead_win_rate = weighted_mean_safe(history$result[ahead], weight[ahead]),
    behind_own_post15 = weighted_mean_safe(
      history$own_post_15_kpm[behind], weight[behind]
    ),
    behind_opponent_post15 = weighted_mean_safe(
      history$opponent_post_15_kpm[behind], weight[behind]
    ),
    behind_combined_post15 = weighted_mean_safe(
      history$combined_post_15_kpm[behind], weight[behind]
    ),
    behind_duration = weighted_mean_safe(
      history$game_length_minutes[behind], weight[behind]
    ),
    behind_comeback_rate = weighted_mean_safe(
      history$result[behind], weight[behind]
    ),
    even_combined_post15 = weighted_mean_safe(
      history$combined_post_15_kpm[even], weight[even]
    ),
    even_duration = weighted_mean_safe(
      history$game_length_minutes[even], weight[even]
    ),
    early_pace_mean = weighted_mean_safe(history$early_pace, weight),
    post15_pace_mean = weighted_mean_safe(
      history$combined_post_15_kpm,
      weight
    ),
    early_late_slope = if (
      is.finite(early_late_covariance) &&
        is.finite(early_variance) && early_variance > 0
    ) {
      early_late_covariance / early_variance
    } else {
      NA_real_
    },
    early_late_correlation = weighted_correlation_safe(
      history$early_pace,
      history$combined_post_15_kpm,
      weight
    ),
    early_late_gap = weighted_mean_safe(
      history$combined_post_15_kpm - history$early_pace,
      weight
    )
  )
}

safe_mean <- function(values) {
  if (all(!is.finite(values))) NA_real_ else mean(values, na.rm = TRUE)
}
safe_max <- function(values) {
  if (all(!is.finite(values))) NA_real_ else max(values, na.rm = TRUE)
}
safe_min <- function(values) {
  if (all(!is.finite(values))) NA_real_ else min(values, na.rm = TRUE)
}
safe_gap <- function(a, b) {
  if (!is.finite(a) || !is.finite(b)) NA_real_ else abs(a - b)
}

pair_features <- function(blue, red) {
  blue_ahead_scenario <- blue[["ahead_own_post15"]] +
    red[["behind_own_post15"]]
  red_ahead_scenario <- red[["ahead_own_post15"]] +
    blue[["behind_own_post15"]]
  blue_duration_scenario <- safe_mean(c(
    blue[["ahead_duration"]], red[["behind_duration"]]
  ))
  red_duration_scenario <- safe_mean(c(
    red[["ahead_duration"]], blue[["behind_duration"]]
  ))
  c(
    ahead_combined_mean = safe_mean(c(
      blue[["ahead_combined_post15"]], red[["ahead_combined_post15"]]
    )),
    ahead_duration_mean = safe_mean(c(
      blue[["ahead_duration"]], red[["ahead_duration"]]
    )),
    ahead_win_rate_mean = safe_mean(c(
      blue[["ahead_win_rate"]], red[["ahead_win_rate"]]
    )),
    ahead_attack_gap = safe_gap(
      blue[["ahead_own_post15"]], red[["ahead_own_post15"]]
    ),
    behind_trade_mean = safe_mean(c(
      blue[["behind_own_post15"]], red[["behind_own_post15"]]
    )),
    behind_combined_mean = safe_mean(c(
      blue[["behind_combined_post15"]], red[["behind_combined_post15"]]
    )),
    behind_duration_mean = safe_mean(c(
      blue[["behind_duration"]], red[["behind_duration"]]
    )),
    behind_comeback_mean = safe_mean(c(
      blue[["behind_comeback_rate"]], red[["behind_comeback_rate"]]
    )),
    state_fight_mean = safe_mean(c(
      blue_ahead_scenario, red_ahead_scenario
    )),
    state_fight_ceiling = safe_max(c(
      blue_ahead_scenario, red_ahead_scenario
    )),
    state_fight_floor = safe_min(c(
      blue_ahead_scenario, red_ahead_scenario
    )),
    state_fight_gap = safe_gap(blue_ahead_scenario, red_ahead_scenario),
    state_duration_mean = safe_mean(c(
      blue_duration_scenario, red_duration_scenario
    )),
    state_duration_gap = safe_gap(
      blue_duration_scenario, red_duration_scenario
    ),
    persistence_slope_mean = safe_mean(c(
      blue[["early_late_slope"]], red[["early_late_slope"]]
    )),
    persistence_correlation_mean = safe_mean(c(
      blue[["early_late_correlation"]],
      red[["early_late_correlation"]]
    )),
    early_late_gap_mean = safe_mean(c(
      blue[["early_late_gap"]], red[["early_late_gap"]]
    )),
    historical_early_pace_mean = safe_mean(c(
      blue[["early_pace_mean"]], red[["early_pace_mean"]]
    )),
    historical_post15_pace_mean = safe_mean(c(
      blue[["post15_pace_mean"]], red[["post15_pace_mean"]]
    )),
    state_minimum_history = safe_min(c(
      blue[["history_games"]], red[["history_games"]]
    )),
    minimum_ahead_history = safe_min(c(
      blue[["ahead_games"]], red[["ahead_games"]]
    )),
    minimum_behind_history = safe_min(c(
      blue[["behind_games"]], red[["behind_games"]]
    ))
  )
}

build_features <- function(frame, cutoff_field) {
  rows <- vector("list", nrow(frame))
  for (index in seq_len(nrow(frame))) {
    blue <- team_snapshot(
      frame$blue_team_id[[index]],
      frame[[cutoff_field]][[index]]
    )
    red <- team_snapshot(
      frame$red_team_id[[index]],
      frame[[cutoff_field]][[index]]
    )
    rows[[index]] <- data.frame(
      gameid = as.character(frame$gameid[[index]]),
      as.list(pair_features(blue, red)),
      stringsAsFactors = FALSE
    )
  }
  do.call(rbind, rows)
}

pre_features <- build_features(pre, "odds_timestamp")
pre <- merge(pre, pre_features, by = "gameid", all.x = TRUE, sort = FALSE)
pre <- pre[match(expanded$data$gameid, pre$gameid), , drop = FALSE]

live_features <- build_features(atlas, "live_open_time")
live <- merge(atlas, live_features, by = "gameid", all.x = TRUE, sort = FALSE)
live <- live[match(atlas$gameid, live$gameid), , drop = FALSE]

state_feature_names <- setdiff(names(pre_features), "gameid")
for (frame_name in c("pre", "live")) {
  frame <- get(frame_name)
  for (feature_name in state_feature_names) {
    frame[[feature_name]] <- as.numeric(frame[[feature_name]])
  }
  frame$minimum_history_log <- log1p(frame$state_minimum_history)
  frame$minimum_ahead_history_log <- log1p(frame$minimum_ahead_history)
  frame$minimum_behind_history_log <- log1p(frame$minimum_behind_history)
  assign(frame_name, frame)
}

families <- list(
  ahead_closing = c(
    "ahead_combined_mean", "ahead_duration_mean",
    "ahead_win_rate_mean", "ahead_attack_gap",
    "minimum_ahead_history_log"
  ),
  behind_resistance = c(
    "behind_trade_mean", "behind_combined_mean",
    "behind_duration_mean", "behind_comeback_mean",
    "minimum_behind_history_log"
  ),
  state_interaction = c(
    "state_fight_mean", "state_fight_ceiling", "state_fight_floor",
    "state_fight_gap", "state_duration_mean", "state_duration_gap",
    "minimum_ahead_history_log", "minimum_behind_history_log"
  ),
  early_late_persistence = c(
    "persistence_slope_mean", "persistence_correlation_mean",
    "early_late_gap_mean", "historical_early_pace_mean",
    "historical_post15_pace_mean", "minimum_history_log"
  )
)
families$all_state_conditioned <- unique(unlist(families, use.names = FALSE))
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

fit_predict <- function(train, validation, columns, lambda) {
  train$residual_target <- train$observed_total - train$market_mean
  matrices <- impute_matrix(train, validation, columns)
  fit <- glmnet::glmnet(
    matrices$train,
    train$residual_target,
    family = "gaussian",
    alpha = 0,
    lambda = lambda,
    standardize = TRUE,
    intercept = TRUE
  )
  pmax(
    validation$market_mean + as.numeric(stats::predict(
      fit,
      newx = matrices$validation,
      s = lambda
    )),
    0.1
  )
}

intercept_predict <- function(train, validation) {
  residual <- train$observed_total - train$market_mean
  pmax(validation$market_mean + mean(residual), 0.1)
}

score_means <- function(frame, means, candidate_id, stage, timing_id) {
  theta <- unique(as.numeric(frame$market_theta))
  if (length(theta) != 1L) {
    stop("Theta inconsistente.", call. = FALSE)
  }
  line <- as.numeric(frame$market_line)
  observed <- as.numeric(frame$observed_total)
  means <- pmax(as.numeric(means), 0.1)
  support <- 0:150
  probability_over <- stats::pnbinom(
    floor(line),
    size = theta,
    mu = means,
    lower.tail = FALSE
  )
  observed_over <- as.numeric(observed > line)
  crps <- vapply(seq_len(nrow(frame)), function(index) {
    cumulative <- stats::pnbinom(
      support,
      size = theta,
      mu = means[[index]]
    )
    sum((cumulative - as.numeric(support >= observed[[index]]))^2)
  }, numeric(1L))
  data.frame(
    gameid = as.character(frame$gameid),
    series_id = as.character(frame$series_id),
    game_datetime = as.POSIXct(frame$game_datetime, tz = "UTC"),
    league_canonical = as.character(frame$league_canonical),
    timing_id = timing_id,
    stage = stage,
    candidate_id = candidate_id,
    predicted_mean = means,
    crps = crps,
    count_log_score = -stats::dnbinom(
      observed,
      size = theta,
      mu = means,
      log = TRUE
    ),
    absolute_error = abs(observed - means),
    brier = (probability_over - observed_over)^2,
    stringsAsFactors = FALSE
  )
}

summarize_scores <- function(scores) {
  metrics <- stats::aggregate(
    cbind(crps, count_log_score, absolute_error, brier) ~
      timing_id + stage + candidate_id,
    scores,
    mean
  )
  counts <- stats::aggregate(
    gameid ~ timing_id + stage + candidate_id,
    scores,
    length
  )
  names(counts)[names(counts) == "gameid"] <- "maps"
  merge(metrics, counts, by = c("timing_id", "stage", "candidate_id"))
}

pre_adjustment <- pre[
  pre$game_datetime < as.POSIXct("2025-09-01", tz = "UTC"),
  ,
  drop = FALSE
]
pre_selection <- pre[
  pre$game_datetime >= as.POSIXct("2025-09-01", tz = "UTC") &
    pre$game_datetime < as.POSIXct("2025-10-01", tz = "UTC"),
  ,
  drop = FALSE
]
pre_confirmation <- pre[
  pre$game_datetime >= as.POSIXct("2026-01-01", tz = "UTC"),
  ,
  drop = FALSE
]
pre_development <- rbind(pre_adjustment, pre_selection)

selection_scores <- list(
  market = score_means(
    pre_selection,
    pre_selection$market_mean,
    "market_baseline",
    "selection",
    "pre_t15"
  ),
  intercept = score_means(
    pre_selection,
    intercept_predict(pre_adjustment, pre_selection),
    "intercept_only",
    "selection",
    "pre_t15"
  )
)
selection_grid_rows <- list()
for (family_id in names(families)) {
  for (lambda in lambdas) {
    candidate_id <- paste0(family_id, "_lambda_", lambda)
    scores <- score_means(
      pre_selection,
      fit_predict(
        pre_adjustment,
        pre_selection,
        families[[family_id]],
        lambda
      ),
      candidate_id,
      "selection",
      "pre_t15"
    )
    selection_scores[[candidate_id]] <- scores
    summary <- summarize_scores(scores)
    selection_grid_rows[[candidate_id]] <- data.frame(
      family_id = family_id,
      lambda = lambda,
      crps = summary$crps,
      count_log_score = summary$count_log_score,
      absolute_error = summary$absolute_error,
      brier = summary$brier,
      stringsAsFactors = FALSE
    )
  }
}
selection_scores <- do.call(rbind, selection_scores)
selection_summary <- summarize_scores(selection_scores)
selection_grid <- do.call(rbind, selection_grid_rows)
rownames(selection_grid) <- NULL

best_by_family <- do.call(rbind, lapply(
  split(selection_grid, selection_grid$family_id),
  function(rows) rows[order(
    rows$crps,
    rows$count_log_score,
    rows$brier
  )[1L], , drop = FALSE]
))
best_by_family <- best_by_family[order(
  best_by_family$crps,
  best_by_family$count_log_score,
  best_by_family$brier
), , drop = FALSE]
selected_family <- best_by_family$family_id[[1L]]
selected_lambda <- best_by_family$lambda[[1L]]
selected_id <- paste0(selected_family, "_lambda_", selected_lambda)

confirmation_scores <- list(
  market = score_means(
    pre_confirmation,
    pre_confirmation$market_mean,
    "market_baseline",
    "confirmation",
    "pre_t15"
  ),
  intercept = score_means(
    pre_confirmation,
    intercept_predict(pre_development, pre_confirmation),
    "intercept_only",
    "confirmation",
    "pre_t15"
  )
)
for (index in seq_len(nrow(best_by_family))) {
  family_id <- best_by_family$family_id[[index]]
  lambda <- best_by_family$lambda[[index]]
  candidate_id <- paste0(family_id, "_lambda_", lambda)
  confirmation_scores[[candidate_id]] <- score_means(
    pre_confirmation,
    fit_predict(
      pre_development,
      pre_confirmation,
      families[[family_id]],
      lambda
    ),
    candidate_id,
    "confirmation",
    "pre_t15"
  )
}
confirmation_scores <- do.call(rbind, confirmation_scores)

live_development <- live[
  live$sample %in% c("adjustment_mar_apr", "selection_may"),
  ,
  drop = FALSE
]
live_confirmation <- live[
  live$sample == "confirmation_jun_jul",
  ,
  drop = FALSE
]
live_score_rows <- list(
  market = score_means(
    live_confirmation,
    live_confirmation$market_mean,
    "market_baseline",
    "confirmation",
    "live_open"
  ),
  intercept = score_means(
    live_confirmation,
    intercept_predict(live_development, live_confirmation),
    "intercept_only",
    "confirmation",
    "live_open"
  )
)
for (index in seq_len(nrow(best_by_family))) {
  family_id <- best_by_family$family_id[[index]]
  lambda <- best_by_family$lambda[[index]]
  candidate_id <- paste0(family_id, "_lambda_", lambda)
  live_score_rows[[candidate_id]] <- score_means(
    live_confirmation,
    fit_predict(
      live_development,
      live_confirmation,
      families[[family_id]],
      lambda
    ),
    candidate_id,
    "confirmation",
    "live_open"
  )
}
live_scores <- do.call(rbind, live_score_rows)
all_confirmation_scores <- rbind(confirmation_scores, live_scores)
confirmation_summary <- summarize_scores(all_confirmation_scores)

paired_bootstrap <- function(
  scores,
  timing_id,
  candidate_id,
  baseline_id,
  draws = 5000L,
  seed = 20260805L
) {
  metrics <- c("crps", "count_log_score", "absolute_error", "brier")
  candidate <- scores[
    scores$timing_id == timing_id & scores$candidate_id == candidate_id,
    ,
    drop = FALSE
  ]
  baseline <- scores[
    scores$timing_id == timing_id & scores$candidate_id == baseline_id,
    ,
    drop = FALSE
  ]
  paired <- merge(
    baseline[, c("gameid", "series_id", metrics)],
    candidate[, c("gameid", metrics)],
    by = "gameid",
    suffixes = c("_baseline", "_candidate")
  )
  blocks <- split(seq_len(nrow(paired)), paired$series_id)
  set.seed(seed + nchar(timing_id) + nchar(baseline_id))
  do.call(rbind, lapply(metrics, function(metric) {
    difference <- paired[[paste0(metric, "_candidate")]] -
      paired[[paste0(metric, "_baseline")]]
    sampled <- replicate(draws, {
      selected <- sample(names(blocks), length(blocks), replace = TRUE)
      indices <- unlist(blocks[selected], use.names = FALSE)
      mean(difference[indices])
    })
    data.frame(
      timing_id = timing_id,
      candidate_id = candidate_id,
      baseline_id = baseline_id,
      metric = metric,
      maps = nrow(paired),
      mean_difference = mean(difference),
      lower_95 = unname(stats::quantile(sampled, 0.025)),
      upper_95 = unname(stats::quantile(sampled, 0.975)),
      probability_candidate_better = mean(sampled < 0),
      stringsAsFactors = FALSE
    )
  }))
}

bootstrap <- rbind(
  paired_bootstrap(
    all_confirmation_scores,
    "pre_t15",
    selected_id,
    "market_baseline"
  ),
  paired_bootstrap(
    all_confirmation_scores,
    "pre_t15",
    selected_id,
    "intercept_only"
  ),
  paired_bootstrap(
    all_confirmation_scores,
    "live_open",
    selected_id,
    "market_baseline"
  ),
  paired_bootstrap(
    all_confirmation_scores,
    "live_open",
    selected_id,
    "intercept_only"
  )
)

transport_bootstrap_rows <- list()
for (index in seq_len(nrow(best_by_family))) {
  family_id <- best_by_family$family_id[[index]]
  lambda <- best_by_family$lambda[[index]]
  candidate_id <- paste0(family_id, "_lambda_", lambda)
  for (timing_id in c("pre_t15", "live_open")) {
    for (baseline_id in c("market_baseline", "intercept_only")) {
      transport_bootstrap_rows[[paste(
        candidate_id,
        timing_id,
        baseline_id,
        sep = "__"
      )]] <- paired_bootstrap(
        all_confirmation_scores,
        timing_id,
        candidate_id,
        baseline_id,
        draws = 5000L,
        seed = 20260835L
      )
    }
  }
}
transport_bootstrap <- do.call(rbind, transport_bootstrap_rows)
rownames(transport_bootstrap) <- NULL

family_candidate_ids <- paste0(
  best_by_family$family_id,
  "_lambda_",
  best_by_family$lambda
)
selected_pre_scores <- confirmation_scores[
  confirmation_scores$candidate_id %in% c(
    "market_baseline",
    "intercept_only",
    family_candidate_ids
  ),
  ,
  drop = FALSE
]
by_league <- stats::aggregate(
  cbind(crps, count_log_score, absolute_error, brier) ~
    candidate_id + league_canonical,
  selected_pre_scores,
  mean
)
league_counts <- stats::aggregate(
  gameid ~ candidate_id + league_canonical,
  selected_pre_scores,
  length
)
names(league_counts)[names(league_counts) == "gameid"] <- "maps"
by_league <- merge(
  by_league,
  league_counts,
  by = c("candidate_id", "league_canonical")
)

feature_coverage <- data.frame(
  timing_id = rep(c("pre_t15", "live_open"), each = 4L),
  metric = rep(c(
    "maps", "minimum_history_ge_10", "minimum_ahead_history_ge_3",
    "minimum_behind_history_ge_3"
  ), 2L),
  value = c(
    nrow(pre),
    mean(pre$state_minimum_history >= 10, na.rm = TRUE),
    mean(pre$minimum_ahead_history >= 3, na.rm = TRUE),
    mean(pre$minimum_behind_history >= 3, na.rm = TRUE),
    nrow(live),
    mean(live$state_minimum_history >= 10, na.rm = TRUE),
    mean(live$minimum_ahead_history >= 3, na.rm = TRUE),
    mean(live$minimum_behind_history >= 3, na.rm = TRUE)
  ),
  stringsAsFactors = FALSE
)

pre_market <- confirmation_summary[
  confirmation_summary$timing_id == "pre_t15" &
    confirmation_summary$candidate_id == "market_baseline",
  ,
  drop = FALSE
]
pre_selected <- confirmation_summary[
  confirmation_summary$timing_id == "pre_t15" &
    confirmation_summary$candidate_id == selected_id,
  ,
  drop = FALSE
]
live_market <- confirmation_summary[
  confirmation_summary$timing_id == "live_open" &
    confirmation_summary$candidate_id == "market_baseline",
  ,
  drop = FALSE
]
live_selected <- confirmation_summary[
  confirmation_summary$timing_id == "live_open" &
    confirmation_summary$candidate_id == selected_id,
  ,
  drop = FALSE
]
pre_boot_crps <- bootstrap[
  bootstrap$timing_id == "pre_t15" &
    bootstrap$baseline_id == "market_baseline" &
    bootstrap$metric == "crps",
  ,
  drop = FALSE
]
pre_boot_log <- bootstrap[
  bootstrap$timing_id == "pre_t15" &
    bootstrap$baseline_id == "market_baseline" &
    bootstrap$metric == "count_log_score",
  ,
  drop = FALSE
]
live_boot_crps <- bootstrap[
  bootstrap$timing_id == "live_open" &
    bootstrap$baseline_id == "market_baseline" &
    bootstrap$metric == "crps",
  ,
  drop = FALSE
]
live_boot_log <- bootstrap[
  bootstrap$timing_id == "live_open" &
    bootstrap$baseline_id == "market_baseline" &
    bootstrap$metric == "count_log_score",
  ,
  drop = FALSE
]
success <- pre_selected$crps < pre_market$crps &&
  pre_selected$count_log_score < pre_market$count_log_score &&
  live_selected$crps < live_market$crps &&
  live_selected$count_log_score < live_market$count_log_score &&
  pre_boot_crps$probability_candidate_better >= 0.9 &&
  pre_boot_log$probability_candidate_better >= 0.9 &&
  live_boot_crps$probability_candidate_better >= 0.9 &&
  live_boot_log$probability_candidate_better >= 0.9

decision <- data.frame(
  item = c(
    "experiment_id", "selected_family", "selected_lambda",
    "pre_adjustment_maps", "pre_selection_maps", "pre_confirmation_maps",
    "live_development_maps", "live_confirmation_maps", "success_rule",
    "result", "production_decision", "prospective_test"
  ),
  value = c(
    "STATE-INT-01",
    selected_family,
    as.character(selected_lambda),
    nrow(pre_adjustment),
    nrow(pre_selection),
    nrow(pre_confirmation),
    nrow(live_development),
    nrow(live_confirmation),
    "CRPS and log score improve pre and live with bootstrap probability >= 0.90",
    if (success) "PASS" else "FAIL_OR_INCONCLUSIVE",
    if (success) "challenger_supported_not_promoted" else "hold",
    "false"
  ),
  stringsAsFactors = FALSE
)

utils::write.csv(
  feature_coverage,
  file.path(output_dir, "feature-coverage.csv"),
  row.names = FALSE
)
utils::write.csv(
  selection_grid,
  file.path(output_dir, "selection-grid.csv"),
  row.names = FALSE
)
utils::write.csv(
  selection_summary[order(selection_summary$crps), ],
  file.path(output_dir, "selection-summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  confirmation_summary[order(
    confirmation_summary$timing_id,
    confirmation_summary$crps
  ), ],
  file.path(output_dir, "confirmation-summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(output_dir, "confirmation-bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  transport_bootstrap,
  file.path(output_dir, "family-transport-bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(output_dir, "pre-confirmation-by-league.csv"),
  row.names = FALSE
)
utils::write.csv(
  decision,
  file.path(output_dir, "decision.csv"),
  row.names = FALSE
)
utils::write.csv(
  pre_features,
  file.path(output_dir, "pre-point-in-time-features.csv"),
  row.names = FALSE
)
utils::write.csv(
  live_features,
  file.path(output_dir, "live-point-in-time-features.csv"),
  row.names = FALSE
)
saveRDS(
  list(
    families = families,
    selected_family = selected_family,
    selected_lambda = selected_lambda,
    selection_scores = selection_scores,
    confirmation_scores = all_confirmation_scores,
    confirmation_summary = confirmation_summary,
    bootstrap = bootstrap,
    transport_bootstrap = transport_bootstrap,
    by_league = by_league,
    decision = decision
  ),
  file.path(output_dir, "state-intensity-results.rds"),
  version = 3L
)

report <- c(
  "# Relatorio de viabilidade e desenho de modelagem",
  "",
  "## 1. Resumo executivo",
  "",
  paste(
    "A familia selecionada no pre foi", selected_family,
    "com lambda", selected_lambda, ". No pre de confirmacao, CRPS mudou de",
    sprintf("%.6f", pre_market$crps), "para",
    sprintf("%.6f", pre_selected$crps), ". No live-open mudou de",
    sprintf("%.6f", live_market$crps), "para",
    sprintf("%.6f", live_selected$crps), ". Status:",
    if (success) "GO WITH CONDITIONS." else "HOLD."
  ),
  paste(
    "Entre as familias secundarias, state_interaction com lambda 100 teve",
    "ganho pequeno contra Pinnacle nos dois recortes, mas a incerteza cruzou",
    "zero no pre e no live. Contra intercept_only, o ganho foi confirmado",
    "apenas no pre; nao transportou com confianca para o live-open."
  ),
  "",
  "## 2. Decisao pretendida",
  "",
  "Decidir se respostas condicionadas ao estado acrescentam informacao a Pinnacle.",
  "",
  "## 3. Pergunta de pesquisa",
  "",
  "Ahead closing, behind resistance ou persistencia melhoram pre e live-open?",
  "",
  "## 4. Definicao formal do problema",
  "",
  "Predicao do residuo de kills observado menos media implicita da Pinnacle.",
  "",
  "## 5. Variavel-alvo",
  "",
  "Total de kills por mapa e distribuicao na linha principal.",
  "",
  "## 6. Unidade de observacao",
  "",
  "Mapa individual agrupado por serie.",
  "",
  "## 7. Horizonte e cutoff de informacao",
  "",
  "Pre T-15 e live-open; somente mapas anteriores disponiveis entram nas features.",
  "",
  "## 8. Processo gerador dos dados",
  "",
  "Estado de vantagem altera luta, resistencia, comeback, intensidade e duracao.",
  "",
  "## 9. Hipoteses causais",
  "",
  "Respostas historicas em ahead e behind transportam estilo para o confronto futuro.",
  "",
  "## 10. Revisao de literatura",
  "",
  "Nao aplicavel; experimento empirico local.",
  "",
  "## 11. Estado da evidencia",
  "",
  "Historico reutilizado e exploratorio; sem teste prospectivo.",
  "",
  "## 12. Fontes de dados",
  "",
  "Oracle Elixir local, BettingIsCool e atlas estrutural-Pinnacle.",
  "",
  "## 13. Auditoria dos dados",
  "",
  paste(
    nrow(pre), "mapas pre e", nrow(live),
    "mapas live-open com reconstrucao point-in-time."
  ),
  "",
  "## 14. Representatividade do historico",
  "",
  "Pre cobre 2025-2026; live-open concentra-se em 2026.",
  "",
  "## 15. Variaveis candidatas",
  "",
  paste(names(families), collapse = ", "),
  "",
  "## 16. Riscos de leakage e vieses",
  "",
  "O estado aos 15 e usado apenas em mapas historicos ja encerrados e disponiveis.",
  "",
  "## 17. Baselines",
  "",
  "Pinnacle no-vig e correcao simples de intercepto.",
  "",
  "## 18. Modelos candidatos",
  "",
  "Ridge residual por familia com grade fixa de lambda.",
  "",
  "## 19. Estrategia de validacao",
  "",
  "Ajuste pre maio-agosto 2025, selecao setembro e confirmacao 2026; live confirma junho-julho.",
  "",
  "## 20. Metricas preditivas",
  "",
  "CRPS primario; log score, MAE e Brier secundarios.",
  "",
  "## 21. Metricas decisorias ou economicas",
  "",
  "Nao estimadas sem odds soft sincronizadas.",
  "",
  "## 22. Calibracao",
  "",
  "Comparacao na linha principal por Brier e log score.",
  "",
  "## 23. Incerteza",
  "",
  "Bootstrap pareado por serie com 5.000 repeticoes.",
  "",
  "## 24. Analise de sensibilidade",
  "",
  "Familias isoladas, grade lambda e transporte pre para live.",
  "",
  "## 25. Custos e restricoes",
  "",
  "Baixo custo e cobertura parcial dos campos aos 15 minutos.",
  "",
  "## 26. Viabilidade operacional",
  "",
  "Features podem ser calculadas antes da partida a partir do historico local.",
  "",
  "## 27. Plano experimental",
  "",
  "Testar familias isoladas e confirmar a selecionada nos dois timings.",
  "",
  "## 28. Criterios de sucesso",
  "",
  "Melhora de CRPS e log score pre e live com probabilidade bootstrap de 90%.",
  "",
  "## 29. Criterios de abandono",
  "",
  "Abandonar se nao transportar para confirmacao ou perder para intercepto.",
  "",
  "## 30. Riscos tecnicos",
  "",
  "Times com pouca amostra ahead ou behind exigem imputacao.",
  "",
  "## 31. Riscos estatisticos",
  "",
  "Multiplas familias e historico reutilizado reduzem a confianca.",
  "",
  "## 32. Limitacoes",
  "",
  "Sem preco soft real e sem prospectivo.",
  "",
  "## 33. Recomendacao final",
  "",
  if (success) {
    "GO WITH CONDITIONS para manter como challenger; nao promover automaticamente."
  } else {
    "HOLD; nao integrar estas familias ao modelo ativo."
  },
  "",
  "## 34. Proximos passos priorizados",
  "",
  if (success) {
    "Testar combinacao com estrutural e impacto em filtros contra softs."
  } else {
    "Interromper esta familia e voltar a filtros ou dados de draft mais ricos."
  },
  "",
  "## 35. Referencias",
  "",
  "Veja os artefatos locais desta pesquisa.",
  "",
  "## 36. Apendices",
  "",
  "Veja selection-grid, confirmation-summary, bootstrap e resultados por liga."
)
writeLines(report, file.path(output_dir, "09-final-report.md"), useBytes = TRUE)

print(feature_coverage, row.names = FALSE)
print(best_by_family, row.names = FALSE)
print(selection_summary[order(selection_summary$crps), ], row.names = FALSE)
print(confirmation_summary[order(
  confirmation_summary$timing_id,
  confirmation_summary$crps
), ], row.names = FALSE)
print(bootstrap, row.names = FALSE)
print(decision, row.names = FALSE)
