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
  "market-structural-v2"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

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
maps_path <- file.path(
  project_root,
  "data",
  "interim",
  "premap_ratio_map_features_t15.rds"
)
if (!all(file.exists(c(atlas_path, market_experiment_path, maps_path)))) {
  stop("Execute primeiro os scripts 103 e 107.", call. = FALSE)
}

data <- readRDS(atlas_path)
maps <- readRDS(maps_path)
market_theta <- as.numeric(utils::read.csv(
  market_experiment_path,
  stringsAsFactors = FALSE
)$market_theta[[1L]])

map_extra <- maps[match(data$gameid, maps$gameid), c(
  "gameid", "game_length_minutes"
)]
if (anyNA(map_extra$gameid)) {
  stop("Duracao observada ausente no atlas.", call. = FALSE)
}
data$game_length_minutes <- map_extra$game_length_minutes

required <- c(
  "observed_total", "market_mean", "structural_mean",
  "structural_duration_mean", "structural_intensity_mean",
  "live_line", "live_odds_over", "live_odds_under",
  "absolute_structural_disagreement", "structural_disagreement"
)
missing <- setdiff(required, names(data))
if (length(missing) > 0L) {
  stop(
    paste("Campos ausentes no atlas:", paste(missing, collapse = ", ")),
    call. = FALSE
  )
}

data$league_factor <- factor(
  data$league_canonical,
  levels = sort(unique(as.character(data$league_canonical)))
)
data$matchup_factor <- factor(
  data$matchup_type,
  levels = sort(unique(as.character(data$matchup_type)))
)
data$roster_factor <- factor(
  data$roster_stability_band,
  levels = sort(unique(as.character(data$roster_stability_band)))
)
data$map_factor <- factor(
  data$map_group,
  levels = sort(unique(as.character(data$map_group)))
)
data$volatility_z <- as.numeric(scale(data$historical_volatility))
data$heat_z <- as.numeric(scale(data$attack_concession_heat))
data$history_z <- as.numeric(scale(log1p(data$minimum_history_games)))
for (column in c("volatility_z", "heat_z", "history_z")) {
  data[[column]][!is.finite(data[[column]])] <- 0
}
data$observed_duration <- as.numeric(data$game_length_minutes)
data$observed_intensity <- data$observed_total / data$observed_duration
data$duration_log_residual <- log(
  data$observed_duration / data$structural_duration_mean
)
data$intensity_log_residual <- log(
  pmax(data$observed_intensity, 1e-6) /
    pmax(data$structural_intensity_mean, 1e-6)
)

adjustment <- data[data$sample == "adjustment_mar_apr", , drop = FALSE]
selection <- data[data$sample == "selection_may", , drop = FALSE]
confirmation <- data[
  data$sample == "confirmation_jun_jul",
  ,
  drop = FALSE
]
development <- rbind(adjustment, selection)

score_means <- function(frame, means, candidate_id, stage, complexity) {
  means <- pmax(0.1, as.numeric(means))
  theta <- rep(market_theta, nrow(frame))
  support <- 0:150
  probability_over <- stats::pnbinom(
    floor(frame$live_line),
    size = theta,
    mu = means,
    lower.tail = FALSE
  )
  observed_over <- as.numeric(frame$observed_total > frame$live_line)
  crps <- vapply(seq_len(nrow(frame)), function(index) {
    cumulative <- stats::pnbinom(
      support,
      size = theta[[index]],
      mu = means[[index]]
    )
    sum((cumulative - as.numeric(
      support >= frame$observed_total[[index]]
    ))^2)
  }, numeric(1L))
  data.frame(
    gameid = as.character(frame$gameid),
    series_id = as.character(frame$series_id),
    game_datetime = as.POSIXct(frame$game_datetime, tz = "UTC"),
    league_canonical = as.character(frame$league_canonical),
    stage = stage,
    candidate_id = candidate_id,
    complexity = complexity,
    predicted_mean = means,
    probability_over = probability_over,
    observed_over = observed_over,
    crps = crps,
    count_log_score = -stats::dnbinom(
      frame$observed_total,
      size = theta,
      mu = means,
      log = TRUE
    ),
    absolute_error = abs(frame$observed_total - means),
    brier = (probability_over - observed_over)^2,
    odds_over = as.numeric(frame$live_odds_over),
    odds_under = as.numeric(frame$live_odds_under),
    line = as.numeric(frame$live_line),
    roster_stability_band = as.character(frame$roster_stability_band),
    stringsAsFactors = FALSE
  )
}

summarize_scores <- function(scores) {
  metrics <- stats::aggregate(
    cbind(crps, count_log_score, absolute_error, brier) ~
      stage + candidate_id + complexity,
    scores,
    mean
  )
  counts <- stats::aggregate(
    gameid ~ stage + candidate_id + complexity,
    scores,
    length
  )
  names(counts)[names(counts) == "gameid"] <- "maps"
  merge(metrics, counts, by = c("stage", "candidate_id", "complexity"))
}

factor_formula_signal <- stats::as.formula(paste(
  "~ structural_disagreement + absolute_structural_disagreement +",
  "I(structural_disagreement * absolute_structural_disagreement)"
))
factor_formula_league <- stats::as.formula(paste(
  "~ structural_disagreement + absolute_structural_disagreement +",
  "league_factor + league_factor:structural_disagreement"
))
factor_formula_context <- stats::as.formula(paste(
  "~ structural_disagreement + absolute_structural_disagreement +",
  "league_factor + league_factor:structural_disagreement +",
  "matchup_factor + roster_factor + map_factor +",
  "volatility_z + heat_z + history_z"
))
factor_formula_duration <- stats::as.formula(paste(
  "~ league_factor + matchup_factor + roster_factor + map_factor +",
  "volatility_z + heat_z + history_z"
))

ridge_predict <- function(train, validation, target, formula, lambda) {
  predictor_names <- all.vars(formula)
  combined <- rbind(
    train[, predictor_names, drop = FALSE],
    validation[, predictor_names, drop = FALSE]
  )
  matrix <- stats::model.matrix(formula, data = combined)
  matrix <- matrix[, colnames(matrix) != "(Intercept)", drop = FALSE]
  train_matrix <- matrix[seq_len(nrow(train)), , drop = FALSE]
  validation_matrix <- matrix[
    nrow(train) + seq_len(nrow(validation)),
    ,
    drop = FALSE
  ]
  fit <- glmnet::glmnet(
    train_matrix,
    train[[target]],
    family = "gaussian",
    alpha = 0,
    lambda = lambda,
    standardize = TRUE,
    intercept = TRUE
  )
  as.numeric(stats::predict(
    fit,
    newx = validation_matrix,
    s = lambda
  ))
}

predict_residual_candidate <- function(
  train,
  validation,
  formula,
  lambda
) {
  train$market_residual_target <- train$observed_total - train$market_mean
  correction <- ridge_predict(
    train,
    validation,
    "market_residual_target",
    formula,
    lambda
  )
  pmax(0.1, validation$market_mean + correction)
}

predict_duration_intensity <- function(train, validation, lambda) {
  duration_adjustment <- ridge_predict(
    train,
    validation,
    "duration_log_residual",
    factor_formula_duration,
    lambda
  )
  intensity_adjustment <- ridge_predict(
    train,
    validation,
    "intensity_log_residual",
    factor_formula_duration,
    lambda
  )
  corrected_duration <- validation$structural_duration_mean *
    exp(duration_adjustment)
  corrected_intensity <- validation$structural_intensity_mean *
    exp(intensity_adjustment)
  pmax(0.1, corrected_duration * corrected_intensity)
}

adaptive_mean <- function(frame, structural_mean, tau, roster = FALSE) {
  disagreement <- structural_mean - frame$market_mean
  weight <- exp(-abs(disagreement) / tau)
  if (roster) {
    roster_weight <- ifelse(
      frame$roster_stability_band == "both_unchanged",
      1,
      ifelse(frame$roster_stability_band == "one_change", 0.35, 0.15)
    )
    weight <- weight * roster_weight
  }
  pmax(0.1, frame$market_mean + weight * disagreement)
}

team_total_means <- function(frame) {
  path <- file.path(
    project_root,
    "artifacts",
    "modeling-research",
    "postdraft-team-total-joint-challenger",
    "map-scores.rds"
  )
  result <- frame$market_mean
  if (!file.exists(path)) {
    return(result)
  }
  scores <- readRDS(path)
  scores <- scores[
    scores$candidate_id == "joint_market_kl",
    c("gameid", "predicted_mean"),
    drop = FALSE
  ]
  index <- match(frame$gameid, scores$gameid)
  available <- !is.na(index) & is.finite(scores$predicted_mean[index])
  result[available] <- scores$predicted_mean[index[available]]
  result
}

lambda_grid <- c(0.01, 0.1, 1, 10, 100)
tau_grid <- c(0.5, 1, 1.5, 2.5, 4)
selection_scores <- list(
  market = score_means(
    selection,
    selection$market_mean,
    "pinnacle_live",
    "selection",
    0L
  ),
  structural = score_means(
    selection,
    selection$structural_mean,
    "structural_current",
    "selection",
    1L
  ),
  team_totals = score_means(
    selection,
    team_total_means(selection),
    "team_totals_fallback_market",
    "selection",
    2L
  )
)

for (tau in tau_grid) {
  id <- paste0("shrink_raw_tau_", tau)
  selection_scores[[id]] <- score_means(
    selection,
    adaptive_mean(selection, selection$structural_mean, tau),
    id,
    "selection",
    1L
  )
  roster_id <- paste0("shrink_roster_tau_", tau)
  selection_scores[[roster_id]] <- score_means(
    selection,
    adaptive_mean(
      selection,
      selection$structural_mean,
      tau,
      roster = TRUE
    ),
    roster_id,
    "selection",
    2L
  )
}

residual_formulas <- list(
  residual_signal = factor_formula_signal,
  residual_league = factor_formula_league,
  residual_context = factor_formula_context
)
for (family in names(residual_formulas)) {
  for (lambda in lambda_grid) {
    id <- paste0(family, "_lambda_", lambda)
    means <- predict_residual_candidate(
      adjustment,
      selection,
      residual_formulas[[family]],
      lambda
    )
    selection_scores[[id]] <- score_means(
      selection,
      means,
      id,
      "selection",
      match(family, names(residual_formulas)) + 1L
    )
  }
}

for (lambda in lambda_grid) {
  corrected <- predict_duration_intensity(adjustment, selection, lambda)
  id <- paste0("duration_intensity_lambda_", lambda)
  selection_scores[[id]] <- score_means(
    selection,
    corrected,
    id,
    "selection",
    4L
  )
  for (tau in tau_grid) {
    hybrid_id <- paste0("duration_intensity_lambda_", lambda, "_tau_", tau)
    selection_scores[[hybrid_id]] <- score_means(
      selection,
      adaptive_mean(selection, corrected, tau),
      hybrid_id,
      "selection",
      5L
    )
  }
}
selection_scores <- do.call(rbind, selection_scores)
selection_summary <- summarize_scores(selection_scores)
market_selection <- selection_summary[
  selection_summary$candidate_id == "pinnacle_live",
  ,
  drop = FALSE
]
eligible <- selection_summary[
  selection_summary$count_log_score <=
    market_selection$count_log_score * 1.005,
  ,
  drop = FALSE
]
best_crps <- min(eligible$crps)
eligible <- eligible[eligible$crps <= best_crps * 1.0025, , drop = FALSE]
eligible <- eligible[order(
  eligible$complexity,
  eligible$crps,
  eligible$count_log_score
), , drop = FALSE]
selected_id <- eligible$candidate_id[[1L]]

predict_registered <- function(candidate_id, train, validation) {
  if (candidate_id == "pinnacle_live") {
    return(validation$market_mean)
  }
  if (candidate_id == "structural_current") {
    return(validation$structural_mean)
  }
  if (candidate_id == "team_totals_fallback_market") {
    return(team_total_means(validation))
  }
  if (grepl("^shrink_raw_tau_", candidate_id)) {
    tau <- as.numeric(sub("^shrink_raw_tau_", "", candidate_id))
    return(adaptive_mean(validation, validation$structural_mean, tau))
  }
  if (grepl("^shrink_roster_tau_", candidate_id)) {
    tau <- as.numeric(sub("^shrink_roster_tau_", "", candidate_id))
    return(adaptive_mean(
      validation,
      validation$structural_mean,
      tau,
      roster = TRUE
    ))
  }
  if (grepl("^residual_", candidate_id)) {
    family <- sub("_lambda_.*$", "", candidate_id)
    lambda <- as.numeric(sub("^.*_lambda_", "", candidate_id))
    return(predict_residual_candidate(
      train,
      validation,
      residual_formulas[[family]],
      lambda
    ))
  }
  if (grepl("^duration_intensity_lambda_", candidate_id)) {
    lambda <- as.numeric(sub(
      "^duration_intensity_lambda_([^_]+).*$",
      "\\1",
      candidate_id
    ))
    corrected <- predict_duration_intensity(train, validation, lambda)
    if (grepl("_tau_", candidate_id)) {
      tau <- as.numeric(sub("^.*_tau_", "", candidate_id))
      corrected <- adaptive_mean(validation, corrected, tau)
    }
    return(corrected)
  }
  stop("Candidato desconhecido: ", candidate_id, call. = FALSE)
}

confirmation_ids <- unique(c(
  "pinnacle_live",
  "structural_current",
  "team_totals_fallback_market",
  selected_id,
  selection_summary$candidate_id[order(selection_summary$crps)][1:5]
))
confirmation_scores <- lapply(confirmation_ids, function(candidate_id) {
  complexity <- selection_summary$complexity[
    match(candidate_id, selection_summary$candidate_id)
  ]
  score_means(
    confirmation,
    predict_registered(candidate_id, development, confirmation),
    candidate_id,
    "confirmation",
    complexity
  )
})
confirmation_scores <- do.call(rbind, confirmation_scores)
confirmation_summary <- summarize_scores(confirmation_scores)

paired_bootstrap <- function(scores, candidate_id, baseline_id) {
  metrics <- c("crps", "count_log_score", "absolute_error", "brier")
  candidate <- scores[scores$candidate_id == candidate_id, ]
  baseline <- scores[scores$candidate_id == baseline_id, ]
  paired <- merge(
    baseline[c("gameid", "series_id", metrics)],
    candidate[c("gameid", metrics)],
    by = "gameid",
    suffixes = c("_baseline", "_candidate")
  )
  blocks <- split(seq_len(nrow(paired)), paired$series_id)
  set.seed(20260805L + nchar(candidate_id))
  do.call(rbind, lapply(metrics, function(metric) {
    difference <- paired[[paste0(metric, "_candidate")]] -
      paired[[paste0(metric, "_baseline")]]
    draws <- replicate(2000L, {
      sampled <- sample(names(blocks), length(blocks), replace = TRUE)
      indices <- unlist(blocks[sampled], use.names = FALSE)
      mean(difference[indices])
    })
    data.frame(
      candidate_id = candidate_id,
      baseline_id = baseline_id,
      metric = metric,
      maps = nrow(paired),
      mean_difference = mean(difference),
      lower_95 = unname(stats::quantile(draws, 0.025)),
      upper_95 = unname(stats::quantile(draws, 0.975)),
      probability_candidate_better = mean(draws < 0),
      stringsAsFactors = FALSE
    )
  }))
}
bootstrap <- rbind(
  paired_bootstrap(confirmation_scores, selected_id, "pinnacle_live"),
  paired_bootstrap(confirmation_scores, selected_id, "structural_current")
)

by_league <- stats::aggregate(
  cbind(crps, count_log_score, absolute_error, brier) ~
    candidate_id + league_canonical,
  confirmation_scores,
  mean
)
league_counts <- stats::aggregate(
  gameid ~ candidate_id + league_canonical,
  confirmation_scores,
  length
)
names(league_counts)[names(league_counts) == "gameid"] <- "maps"
by_league <- merge(
  by_league,
  league_counts,
  by = c("candidate_id", "league_canonical")
)

backtest_one <- function(scores, threshold) {
  over_ev <- scores$probability_over * scores$odds_over - 1
  under_ev <- (1 - scores$probability_over) * scores$odds_under - 1
  best_ev <- pmax(over_ev, under_ev)
  side <- ifelse(over_ev >= under_ev, "over", "under")
  bet <- is.finite(best_ev) & best_ev >= threshold
  profit <- rep(0, nrow(scores))
  profit[bet & side == "over"] <- ifelse(
    scores$observed_over[bet & side == "over"] == 1,
    scores$odds_over[bet & side == "over"] - 1,
    -1
  )
  profit[bet & side == "under"] <- ifelse(
    scores$observed_over[bet & side == "under"] == 0,
    scores$odds_under[bet & side == "under"] - 1,
    -1
  )
  ordered <- order(scores$game_datetime)
  cumulative <- cumsum(profit[ordered])
  peak <- cummax(c(0, cumulative))[-1L]
  data.frame(
    candidate_id = unique(scores$candidate_id),
    ev_threshold = threshold,
    maps = nrow(scores),
    bets = sum(bet),
    over_bets = sum(bet & side == "over"),
    under_bets = sum(bet & side == "under"),
    profit_units = sum(profit),
    yield = if (sum(bet) > 0L) sum(profit) / sum(bet) else NA_real_,
    maximum_drawdown = if (length(cumulative) > 0L) {
      max(peak - cumulative)
    } else {
      0
    },
    stringsAsFactors = FALSE
  )
}

backtest_ids <- unique(c(
  selected_id,
  "pinnacle_live",
  "structural_current",
  "team_totals_fallback_market"
))
backtest <- do.call(rbind, lapply(backtest_ids, function(candidate_id) {
  scores <- confirmation_scores[
    confirmation_scores$candidate_id == candidate_id,
    ,
    drop = FALSE
  ]
  do.call(rbind, lapply(
    c(0, 0.05, 0.10, 0.15),
    function(threshold) backtest_one(scores, threshold)
  ))
}))

staleness_path <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "directed-market-regime-calibration",
  "research_dataset.rds"
)
backtest_staleness <- data.frame()
if (file.exists(staleness_path)) {
  staleness <- readRDS(staleness_path)
  selected_scores <- confirmation_scores[
    confirmation_scores$candidate_id == selected_id,
    ,
    drop = FALSE
  ]
  accepted <- staleness[
    staleness$staleness_accepted,
    c("gameid"),
    drop = FALSE
  ]
  selected_scores <- selected_scores[
    selected_scores$gameid %in% accepted$gameid,
    ,
    drop = FALSE
  ]
  if (nrow(selected_scores) > 0L) {
    backtest_staleness <- do.call(rbind, lapply(
      c(0, 0.05, 0.10, 0.15),
      function(threshold) backtest_one(selected_scores, threshold)
    ))
    backtest_staleness$gate <- "historical_60_3_5_available_only"
  }
}

registry <- data.frame(
  experiment_id = c(
    "E1", "E2", "E3", "E4", "E5", "E6"
  ),
  family = c(
    "baseline", "adaptive_shrinkage", "roster_shrinkage",
    "league_residual", "context_residual", "duration_intensity"
  ),
  selection_period = "2026-05",
  historical_confirmation_period = "2026-06_to_2026-07-25",
  status = "completed_historical",
  stringsAsFactors = FALSE
)

utils::write.csv(
  selection_summary[order(selection_summary$crps), ],
  file.path(output_dir, "selection-summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  confirmation_summary[order(confirmation_summary$crps), ],
  file.path(output_dir, "confirmation-summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(output_dir, "confirmation-bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(output_dir, "confirmation-by-league.csv"),
  row.names = FALSE
)
utils::write.csv(
  backtest,
  file.path(output_dir, "historical-backtest.csv"),
  row.names = FALSE
)
utils::write.csv(
  backtest_staleness,
  file.path(output_dir, "historical-backtest-staleness-gate.csv"),
  row.names = FALSE
)
utils::write.csv(
  registry,
  file.path(output_dir, "experiment-registry.csv"),
  row.names = FALSE
)
saveRDS(
  list(
    selection_scores = selection_scores,
    confirmation_scores = confirmation_scores,
    selected_id = selected_id,
    market_theta = market_theta
  ),
  file.path(output_dir, "evaluation-results.rds"),
  version = 3L
)
jsonlite::write_json(
  list(
    selected_candidate = selected_id,
    selection_maps = nrow(selection),
    confirmation_maps = nrow(confirmation),
    target_leagues = as.list(canonical_target_leagues()),
    prospective_test = FALSE,
    evidence_status = "historical_reused_exploratory"
  ),
  file.path(output_dir, "selection.json"),
  auto_unbox = TRUE,
  pretty = TRUE
)

print(selection_summary[order(selection_summary$crps), ], row.names = FALSE)
print(confirmation_summary[order(confirmation_summary$crps), ], row.names = FALSE)
print(bootstrap, row.names = FALSE)
print(backtest, row.names = FALSE)
