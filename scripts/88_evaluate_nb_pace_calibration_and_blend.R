script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

artifact_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "nb-pace-calibration-blend"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

clip_probability <- function(probability) {
  pmin(1 - 1e-6, pmax(1e-6, as.numeric(probability)))
}

market_probability_over <- function(data) {
  true_over <- 1 / as.numeric(data$true_odds_over)
  true_under <- 1 / as.numeric(data$true_odds_under)
  offered_over <- 1 / as.numeric(data$odds_over)
  offered_under <- 1 / as.numeric(data$odds_under)
  valid_true <- is.finite(true_over) &
    is.finite(true_under) &
    true_over > 0 &
    true_under > 0
  result <- offered_over / (offered_over + offered_under)
  result[valid_true] <- true_over[valid_true] /
    (true_over[valid_true] + true_under[valid_true])
  clip_probability(result)
}

maximum_drawdown <- function(profit, datetime) {
  if (length(profit) == 0L) {
    return(0)
  }
  ordered <- profit[order(datetime)]
  cumulative <- cumsum(ordered)
  running_peak <- cummax(c(0, cumulative))[-1L]
  abs(min(cumulative - running_peak, 0))
}

score_betting_rule <- function(data, probability_over) {
  probability_over <- clip_probability(probability_over)
  ev_over <- probability_over * data$odds_over - 1
  ev_under <- (1 - probability_over) * data$odds_under - 1
  selected_side <- ifelse(ev_over >= ev_under, "over", "under")
  selected_ev <- pmax(ev_over, ev_under)
  bet <- selected_ev > 0
  selected_probability <- ifelse(
    selected_side == "over",
    probability_over,
    1 - probability_over
  )
  selected_odds <- ifelse(
    selected_side == "over",
    data$odds_over,
    data$odds_under
  )
  selected_win <- ifelse(
    selected_side == "over",
    data$observed_over,
    !data$observed_over
  )
  selected_profit <- ifelse(selected_win, selected_odds - 1, -1)
  bets <- data.frame(
    gameid = data$gameid,
    series_id = data$series_id,
    game_datetime = data$game_datetime,
    league_canonical = data$league_canonical,
    fold_id = data$fold_id,
    selected_side = selected_side,
    selected_probability = selected_probability,
    selected_odds = selected_odds,
    selected_ev = selected_ev,
    selected_win = selected_win,
    selected_profit = selected_profit,
    bet = bet,
    stringsAsFactors = FALSE
  )
  acted <- bets[bets$bet, , drop = FALSE]
  summary <- data.frame(
    eligible_maps = nrow(data),
    bets = nrow(acted),
    bet_rate = nrow(acted) / nrow(data),
    over_bets = sum(acted$selected_side == "over"),
    under_bets = sum(acted$selected_side == "under"),
    wins = sum(acted$selected_win),
    hit_rate = if (nrow(acted) > 0L) {
      mean(acted$selected_win)
    } else {
      NA_real_
    },
    average_odds = if (nrow(acted) > 0L) {
      mean(acted$selected_odds)
    } else {
      NA_real_
    },
    average_predicted_ev = if (nrow(acted) > 0L) {
      mean(acted$selected_ev)
    } else {
      NA_real_
    },
    selected_probability_gap = if (nrow(acted) > 0L) {
      mean(acted$selected_win - acted$selected_probability)
    } else {
      NA_real_
    },
    profit_units = sum(acted$selected_profit),
    yield = if (nrow(acted) > 0L) {
      mean(acted$selected_profit)
    } else {
      NA_real_
    },
    maximum_drawdown_units = maximum_drawdown(
      acted$selected_profit,
      acted$game_datetime
    ),
    stringsAsFactors = FALSE
  )
  list(summary = summary, bets = bets)
}

pmf_line_probability <- function(pmf, line) {
  pmf_probability_over(pmf, line)
}

database_path <- file.path(
  project_root,
  "data",
  "processed",
  "lolkills.duckdb"
)
connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = database_path,
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

snapshots <- DBI::dbReadTable(connection, "market_odds_snapshots")
links <- DBI::dbReadTable(connection, "game_market_links")
selected_snapshots <- select_bettingiscool_map_snapshots(
  snapshots,
  minutes_before_close = 15
)
selected_snapshots <- selected_snapshots[
  selected_snapshots$snapshot_minutes_before_close <= 30 &
    abs(selected_snapshots$line %% 1 - 0.5) < 1e-12,
  ,
  drop = FALSE
]
verified_links <- links[
  links$link_status == "verified",
  c("gameid", "event_id", "period"),
  drop = FALSE
]
market <- merge(
  verified_links,
  selected_snapshots,
  by = c("event_id", "period")
)
market <- market[!duplicated(market$gameid), , drop = FALSE]
market$market_line <- market$line
market <- market[c(
  "gameid",
  "market_line",
  "odds_over",
  "odds_under",
  "true_odds_over",
  "true_odds_under",
  "odds_timestamp",
  "snapshot_minutes_before_close"
)]

development_metrics <- readRDS(file.path(
  project_root,
  "artifacts",
  "premap_model",
  "development_map_metrics.rds"
))
development_nb_pace <- development_metrics[
  development_metrics$candidate_id == "nb_pace",
  ,
  drop = FALSE
]

development_market <- merge(
  development_nb_pace,
  market,
  by = "gameid"
)
development_market <- development_market[
  is.finite(development_market$odds_over) &
    development_market$odds_over > 1 &
    is.finite(development_market$odds_under) &
    development_market$odds_under > 1,
  ,
  drop = FALSE
]
development_market$raw_probability_over <- vapply(
  seq_len(nrow(development_market)),
  function(index) {
    pmf_line_probability(
      development_market$pmf[[index]],
      development_market$market_line[[index]]
    )
  },
  numeric(1L)
)
development_market$observed_over <-
  development_market$observed > development_market$market_line
development_market$market_probability_over <-
  market_probability_over(development_market)

evaluation <- readRDS(file.path(
  project_root,
  "artifacts",
  "bettingiscool",
  "nb_pace_ev_thresholds",
  "eligible_map_metrics.rds"
))
evaluation$raw_probability_over <- evaluation$probability_over
evaluation$market_probability_over <- market_probability_over(evaluation)

if (
  any(duplicated(evaluation[c("gameid", "fold_id")])) ||
    any(abs(evaluation$line - evaluation$market_line) > 1e-12)
) {
  stop("A amostra de avaliacao possui duplicatas ou linhas divergentes.")
}

fold_starts <- c(
  "2025_q3_development" = as.POSIXct(
    "2025-07-01 00:00:00",
    tz = "UTC"
  ),
  "2026_secondary" = as.POSIXct(
    "2026-01-01 00:00:00",
    tz = "UTC"
  )
)

prediction_rows <- list()
fit_rows <- list()
count_rows <- list()
prediction_index <- 0L
fit_index <- 0L
count_index <- 0L

for (fold_id in names(fold_starts)) {
  validation <- evaluation[
    evaluation$fold_id == fold_id,
    ,
    drop = FALSE
  ]
  validation_start <- fold_starts[[fold_id]]
  count_train <- development_nb_pace[
    development_nb_pace$game_datetime < validation_start,
    ,
    drop = FALSE
  ]
  market_train <- development_market[
    development_market$game_datetime < validation_start,
    ,
    drop = FALSE
  ]
  if (nrow(count_train) < 200L || nrow(market_train) < 100L) {
    stop("Historico anterior insuficiente para ", fold_id, ".")
  }

  idr_fit <- fit_idr_count_calibrator(
    count_train$prediction_mean,
    count_train$observed
  )
  idr_pmfs <- predict_idr_count_pmfs(
    idr_fit,
    validation$prediction_mean,
    maximum = max(c(
      count_train$observed,
      validation$observed,
      100L
    ))
  )
  idr_probability <- vapply(
    seq_len(nrow(validation)),
    function(index) {
      pmf_line_probability(
        idr_pmfs[[index]],
        validation$line[[index]]
      )
    },
    numeric(1L)
  )

  platt_fit <- fit_binary_probability_calibrator(
    market_train$raw_probability_over,
    market_train$observed_over,
    method = "platt"
  )
  beta_fit <- fit_binary_probability_calibrator(
    market_train$raw_probability_over,
    market_train$observed_over,
    method = "beta"
  )
  blend_fit <- fit_market_probability_blend(
    market_train$raw_probability_over,
    market_train$market_probability_over,
    market_train$observed_over,
    include_intercept = FALSE
  )
  blend_intercept_fit <- fit_market_probability_blend(
    market_train$raw_probability_over,
    market_train$market_probability_over,
    market_train$observed_over,
    include_intercept = TRUE
  )

  prediction_sets <- list(
    raw_nb_pace = validation$raw_probability_over,
    idr_distribution = idr_probability,
    platt = predict_binary_probability_calibrator(
      platt_fit,
      validation$raw_probability_over
    ),
    beta = predict_binary_probability_calibrator(
      beta_fit,
      validation$raw_probability_over
    ),
    pinnacle_no_vig = validation$market_probability_over,
    market_blend = predict_market_probability_blend(
      blend_fit,
      validation$raw_probability_over,
      validation$market_probability_over
    ),
    market_blend_intercept = predict_market_probability_blend(
      blend_intercept_fit,
      validation$raw_probability_over,
      validation$market_probability_over
    )
  )

  for (candidate_id in names(prediction_sets)) {
    prediction_index <- prediction_index + 1L
    prediction_rows[[prediction_index]] <- data.frame(
      gameid = validation$gameid,
      series_id = validation$series_id,
      game_datetime = validation$game_datetime,
      league_canonical = validation$league_canonical,
      map_number = validation$map_number,
      favorite_band = validation$favorite_band,
      fold_id = fold_id,
      candidate_id = candidate_id,
      observed = validation$observed,
      line = validation$line,
      observed_over = validation$observed_over,
      probability_over = clip_probability(
        prediction_sets[[candidate_id]]
      ),
      odds_over = validation$odds_over,
      odds_under = validation$odds_under,
      stringsAsFactors = FALSE
    )
  }

  fit_index <- fit_index + 1L
  fit_rows[[fit_index]] <- data.frame(
    fold_id = fold_id,
    calibration_batch = "fold_fixed",
    count_training_maps = nrow(count_train),
    market_training_maps = nrow(market_train),
    platt_intercept = unname(stats::coef(platt_fit$fit)[[1L]]),
    platt_slope = unname(stats::coef(platt_fit$fit)[[2L]]),
    beta_intercept = unname(stats::coef(beta_fit$fit)[[1L]]),
    beta_log_probability = unname(stats::coef(beta_fit$fit)[[2L]]),
    beta_log_one_minus = unname(stats::coef(beta_fit$fit)[[3L]]),
    market_blend_weight = blend_fit$weight,
    market_blend_intercept = blend_intercept_fit$intercept,
    market_blend_intercept_weight = blend_intercept_fit$weight,
    stringsAsFactors = FALSE
  )

  idr_crps <- vapply(seq_len(nrow(validation)), function(index) {
    discrete_crps(idr_pmfs[[index]], validation$observed[[index]])
  }, numeric(1L))
  idr_log_score <- vapply(seq_len(nrow(validation)), function(index) {
    pmf <- idr_pmfs[[index]]
    observed <- as.integer(validation$observed[[index]])
    probability <- if (observed < length(pmf)) {
      pmf[[observed + 1L]]
    } else {
      0
    }
    -log(max(probability, 1e-12))
  }, numeric(1L))
  count_index <- count_index + 1L
  count_rows[[count_index]] <- data.frame(
    fold_id = fold_id,
    candidate_id = c("raw_nb_pace", "idr_distribution"),
    maps = nrow(validation),
    crps = c(mean(validation$crps), mean(idr_crps)),
    log_score = c(
      mean(validation$log_score),
      mean(idr_log_score)
    ),
    mean_error = c(
      mean(validation$error),
      mean(vapply(idr_pmfs, function(pmf) {
        sum((seq_along(pmf) - 1L) * pmf)
      }, numeric(1L)) - validation$observed)
    ),
    stringsAsFactors = FALSE
  )
}

evaluation_history_market <- data.frame(
  gameid = evaluation$gameid,
  series_id = evaluation$series_id,
  game_datetime = evaluation$game_datetime,
  fold_id = evaluation$fold_id,
  observed = evaluation$observed,
  prediction_mean = evaluation$prediction_mean,
  raw_probability_over = evaluation$raw_probability_over,
  observed_over = evaluation$observed_over,
  market_probability_over = evaluation$market_probability_over,
  stringsAsFactors = FALSE
)
development_history_market <- data.frame(
  gameid = development_market$gameid,
  series_id = NA_character_,
  game_datetime = development_market$game_datetime,
  fold_id = development_market$fold_id,
  observed = development_market$observed,
  prediction_mean = development_market$prediction_mean,
  raw_probability_over = development_market$raw_probability_over,
  observed_over = development_market$observed_over,
  market_probability_over = development_market$market_probability_over,
  stringsAsFactors = FALSE
)
rolling_market_history <- rbind(
  development_history_market,
  evaluation_history_market
)
rolling_market_history <- rolling_market_history[
  order(rolling_market_history$game_datetime),
  ,
  drop = FALSE
]
rolling_market_history <- rolling_market_history[
  !duplicated(rolling_market_history$gameid, fromLast = TRUE),
  ,
  drop = FALSE
]

evaluation_history_count <- data.frame(
  gameid = evaluation$gameid,
  game_datetime = evaluation$game_datetime,
  prediction_mean = evaluation$prediction_mean,
  observed = evaluation$observed,
  stringsAsFactors = FALSE
)
development_history_count <- development_nb_pace[c(
  "gameid",
  "game_datetime",
  "prediction_mean",
  "observed"
)]
rolling_count_history <- rbind(
  development_history_count,
  evaluation_history_count
)
rolling_count_history <- rolling_count_history[
  order(rolling_count_history$game_datetime),
  ,
  drop = FALSE
]
rolling_count_history <- rolling_count_history[
  !duplicated(rolling_count_history$gameid, fromLast = TRUE),
  ,
  drop = FALSE
]

for (fold_id in names(fold_starts)) {
  fold_validation <- evaluation[
    evaluation$fold_id == fold_id,
    ,
    drop = FALSE
  ]
  calibration_month <- as.POSIXct(
    paste0(format(
      fold_validation$game_datetime,
      "%Y-%m",
      tz = "UTC"
    ), "-01 00:00:00"),
    tz = "UTC"
  )
  for (month_value in sort(unique(calibration_month))) {
    month_start <- as.POSIXct(
      month_value,
      origin = "1970-01-01",
      tz = "UTC"
    )
    validation <- fold_validation[
      calibration_month == month_start,
      ,
      drop = FALSE
    ]
    count_train <- rolling_count_history[
      rolling_count_history$game_datetime < month_start,
      ,
      drop = FALSE
    ]
    market_train <- rolling_market_history[
      rolling_market_history$game_datetime < month_start,
      ,
      drop = FALSE
    ]
    if (nrow(count_train) < 200L || nrow(market_train) < 100L) {
      stop(
        "Historico mensal insuficiente para ",
        format(month_start, "%Y-%m"),
        "."
      )
    }

    idr_fit <- fit_idr_count_calibrator(
      count_train$prediction_mean,
      count_train$observed
    )
    idr_pmfs <- predict_idr_count_pmfs(
      idr_fit,
      validation$prediction_mean,
      maximum = max(c(
        count_train$observed,
        validation$observed,
        100L
      ))
    )
    idr_probability <- vapply(
      seq_len(nrow(validation)),
      function(index) {
        pmf_line_probability(
          idr_pmfs[[index]],
          validation$line[[index]]
        )
      },
      numeric(1L)
    )
    platt_fit <- fit_binary_probability_calibrator(
      market_train$raw_probability_over,
      market_train$observed_over,
      method = "platt"
    )
    beta_fit <- fit_binary_probability_calibrator(
      market_train$raw_probability_over,
      market_train$observed_over,
      method = "beta"
    )
    blend_fit <- fit_market_probability_blend(
      market_train$raw_probability_over,
      market_train$market_probability_over,
      market_train$observed_over,
      include_intercept = FALSE
    )
    blend_intercept_fit <- fit_market_probability_blend(
      market_train$raw_probability_over,
      market_train$market_probability_over,
      market_train$observed_over,
      include_intercept = TRUE
    )
    rolling_prediction_sets <- list(
      rolling_idr = idr_probability,
      rolling_platt = predict_binary_probability_calibrator(
        platt_fit,
        validation$raw_probability_over
      ),
      rolling_beta = predict_binary_probability_calibrator(
        beta_fit,
        validation$raw_probability_over
      ),
      rolling_market_blend = predict_market_probability_blend(
        blend_fit,
        validation$raw_probability_over,
        validation$market_probability_over
      ),
      rolling_market_blend_intercept =
        predict_market_probability_blend(
          blend_intercept_fit,
          validation$raw_probability_over,
          validation$market_probability_over
        )
    )
    for (candidate_id in names(rolling_prediction_sets)) {
      prediction_index <- prediction_index + 1L
      prediction_rows[[prediction_index]] <- data.frame(
        gameid = validation$gameid,
        series_id = validation$series_id,
        game_datetime = validation$game_datetime,
        league_canonical = validation$league_canonical,
        map_number = validation$map_number,
        favorite_band = validation$favorite_band,
        fold_id = fold_id,
        candidate_id = candidate_id,
        observed = validation$observed,
        line = validation$line,
        observed_over = validation$observed_over,
        probability_over = clip_probability(
          rolling_prediction_sets[[candidate_id]]
        ),
        odds_over = validation$odds_over,
        odds_under = validation$odds_under,
        stringsAsFactors = FALSE
      )
    }

    fit_index <- fit_index + 1L
    fit_rows[[fit_index]] <- data.frame(
      fold_id = fold_id,
      calibration_batch = format(month_start, "%Y-%m"),
      count_training_maps = nrow(count_train),
      market_training_maps = nrow(market_train),
      platt_intercept = unname(stats::coef(platt_fit$fit)[[1L]]),
      platt_slope = unname(stats::coef(platt_fit$fit)[[2L]]),
      beta_intercept = unname(stats::coef(beta_fit$fit)[[1L]]),
      beta_log_probability = unname(stats::coef(beta_fit$fit)[[2L]]),
      beta_log_one_minus = unname(stats::coef(beta_fit$fit)[[3L]]),
      market_blend_weight = blend_fit$weight,
      market_blend_intercept = blend_intercept_fit$intercept,
      market_blend_intercept_weight = blend_intercept_fit$weight,
      stringsAsFactors = FALSE
    )
  }
}

predictions <- do.call(rbind, prediction_rows)
fit_parameters <- do.call(rbind, fit_rows)
count_quality <- do.call(rbind, count_rows)
rownames(predictions) <- NULL
rownames(fit_parameters) <- NULL
rownames(count_quality) <- NULL

samples <- c(
  list(combined = predictions),
  split(predictions, predictions$fold_id)
)
line_quality_rows <- list()
economic_rows <- list()
bet_rows <- list()
line_index <- 0L
economic_index <- 0L
bet_index <- 0L

for (sample_name in names(samples)) {
  sample_data <- samples[[sample_name]]
  for (candidate_id in unique(sample_data$candidate_id)) {
    candidate <- sample_data[
      sample_data$candidate_id == candidate_id,
      ,
      drop = FALSE
    ]
    quality <- summarize_binary_probability_quality(
      candidate$probability_over,
      candidate$observed_over
    )
    line_index <- line_index + 1L
    line_quality_rows[[line_index]] <- cbind(
      data.frame(
        sample = sample_name,
        candidate_id = candidate_id,
        stringsAsFactors = FALSE
      ),
      quality
    )
    economic <- score_betting_rule(
      candidate,
      candidate$probability_over
    )
    economic_index <- economic_index + 1L
    economic_rows[[economic_index]] <- cbind(
      data.frame(
        sample = sample_name,
        candidate_id = candidate_id,
        stringsAsFactors = FALSE
      ),
      economic$summary
    )
    bet_index <- bet_index + 1L
    economic$bets$sample <- sample_name
    economic$bets$candidate_id <- candidate_id
    bet_rows[[bet_index]] <- economic$bets
  }
}

line_quality <- do.call(rbind, line_quality_rows)
economic_summary <- do.call(rbind, economic_rows)
bet_decisions <- do.call(rbind, bet_rows)
rownames(line_quality) <- NULL
rownames(economic_summary) <- NULL
rownames(bet_decisions) <- NULL

development_candidates <- line_quality[
  line_quality$sample == "2025_q3_development" &
    line_quality$candidate_id %in% c(
      "raw_nb_pace",
      "idr_distribution",
      "platt",
      "beta",
      "rolling_idr",
      "rolling_platt",
      "rolling_beta"
    ),
  ,
  drop = FALSE
]
best_log_loss <- min(development_candidates$log_loss)
best_row <- development_candidates[
  which.min(development_candidates$log_loss),
  ,
  drop = FALSE
]
paired_predictions <- reshape(
  predictions[
    predictions$fold_id == "2025_q3_development" &
      predictions$candidate_id %in%
        development_candidates$candidate_id,
    c(
      "gameid",
      "candidate_id",
      "observed_over",
      "probability_over"
    )
  ],
  idvar = c("gameid", "observed_over"),
  timevar = "candidate_id",
  direction = "wide"
)
best_loss_column <- paste0(
  "probability_over.",
  best_row$candidate_id[[1L]]
)
best_map_loss <- -(
  paired_predictions$observed_over *
    log(clip_probability(paired_predictions[[best_loss_column]])) +
    (1 - paired_predictions$observed_over) *
      log1p(-clip_probability(paired_predictions[[best_loss_column]]))
)
best_standard_error <- stats::sd(best_map_loss) /
  sqrt(length(best_map_loss))
development_candidates$within_one_standard_error <-
  development_candidates$log_loss <=
    best_log_loss + best_standard_error
complexity_order <- c(
  raw_nb_pace = 1L,
  platt = 2L,
  rolling_platt = 2L,
  beta = 3L,
  rolling_beta = 3L,
  idr_distribution = 4L,
  rolling_idr = 4L
)
eligible_selection <- development_candidates[
  development_candidates$within_one_standard_error,
  ,
  drop = FALSE
]
eligible_selection$complexity <- complexity_order[
  eligible_selection$candidate_id
]
selected_calibrator <- eligible_selection$candidate_id[[
  which.min(eligible_selection$complexity)
]]

structural_metrics <- readRDS(file.path(
  project_root,
  "artifacts",
  "premap_joint_model",
  "map_metrics.rds"
))
structural_candidates <- c(
  "nb_pace",
  "joint_season_last15_global",
  "joint_ml_quadratic_global"
)
structural_metrics <- structural_metrics[
  structural_metrics$candidate_id %in% structural_candidates,
  ,
  drop = FALSE
]
structural_market <- merge(
  structural_metrics,
  market,
  by = "gameid"
)
structural_market <- structural_market[
  is.finite(structural_market$probability_over) &
    is.finite(structural_market$odds_over) &
    is.finite(structural_market$odds_under) &
    abs(structural_market$line -
      structural_market$market_line) < 1e-12,
  ,
  drop = FALSE
]
structural_samples <- c(
  list(combined = structural_market),
  split(structural_market, structural_market$fold_id)
)
structural_rows <- list()
structural_index <- 0L
structural_bet_rows <- list()
structural_bet_index <- 0L
for (sample_name in names(structural_samples)) {
  sample_data <- structural_samples[[sample_name]]
  for (candidate_id in structural_candidates) {
    candidate <- sample_data[
      sample_data$candidate_id == candidate_id,
      ,
      drop = FALSE
    ]
    if (nrow(candidate) == 0L) {
      next
    }
    quality <- summarize_binary_probability_quality(
      candidate$probability_over,
      candidate$observed_over
    )
    economic <- score_betting_rule(
      candidate,
      candidate$probability_over
    )
    structural_bet_index <- structural_bet_index + 1L
    economic$bets$sample <- sample_name
    economic$bets$candidate_id <- candidate_id
    structural_bet_rows[[structural_bet_index]] <- economic$bets
    structural_index <- structural_index + 1L
    structural_rows[[structural_index]] <- cbind(
      data.frame(
        sample = sample_name,
        candidate_id = candidate_id,
        stringsAsFactors = FALSE
      ),
      data.frame(
        crps = mean(candidate$crps),
        log_score = mean(candidate$log_score),
        mean_error = mean(candidate$error),
        stringsAsFactors = FALSE
      ),
      quality[c(
        "maps",
        "brier",
        "log_loss",
        "calibration_gap",
        "expected_calibration_error"
      )],
      economic$summary
    )
  }
}
structural_summary <- do.call(rbind, structural_rows)
structural_bet_decisions <- do.call(rbind, structural_bet_rows)
rownames(structural_summary) <- NULL
rownames(structural_bet_decisions) <- NULL

structural_subgroup_rows <- list()
structural_subgroup_index <- 0L
combined_structural_bets <- structural_bet_decisions[
  structural_bet_decisions$sample == "combined" &
    structural_bet_decisions$bet,
  ,
  drop = FALSE
]
for (candidate_id in structural_candidates) {
  candidate <- combined_structural_bets[
    combined_structural_bets$candidate_id == candidate_id,
    ,
    drop = FALSE
  ]
  subgroup_ids <- list(
    overall = rep("overall", nrow(candidate)),
    side = paste0("side=", candidate$selected_side),
    league = paste0("league=", candidate$league_canonical),
    league_side = paste0(
      "league=",
      candidate$league_canonical,
      "|side=",
      candidate$selected_side
    )
  )
  for (grouping in names(subgroup_ids)) {
    groups <- split(candidate, subgroup_ids[[grouping]])
    for (subgroup_id in names(groups)) {
      group <- groups[[subgroup_id]]
      structural_subgroup_index <- structural_subgroup_index + 1L
      structural_subgroup_rows[[structural_subgroup_index]] <- data.frame(
        candidate_id = candidate_id,
        grouping = grouping,
        subgroup = subgroup_id,
        bets = nrow(group),
        wins = sum(group$selected_win),
        hit_rate = mean(group$selected_win),
        average_odds = mean(group$selected_odds),
        average_predicted_ev = mean(group$selected_ev),
        selected_probability_gap = mean(
          group$selected_win - group$selected_probability
        ),
        profit_units = sum(group$selected_profit),
        yield = mean(group$selected_profit),
        stringsAsFactors = FALSE
      )
    }
  }
}
structural_subgroups <- do.call(rbind, structural_subgroup_rows)
rownames(structural_subgroups) <- NULL

set.seed(20260731L)
structural_bootstrap_rows <- list()
structural_bootstrap_index <- 0L
for (candidate_id in structural_candidates) {
  for (sample_name in c(
    "combined",
    "2025_q3_development",
    "2026_secondary"
  )) {
    candidate <- structural_bet_decisions[
      structural_bet_decisions$sample == sample_name &
        structural_bet_decisions$candidate_id == candidate_id &
        structural_bet_decisions$bet,
      ,
      drop = FALSE
    ]
    if (nrow(candidate) == 0L) {
      next
    }
    month <- format(candidate$game_datetime, "%Y-%m", tz = "UTC")
    block_id <- paste(month, candidate$series_id, sep = "|")
    blocks <- split(seq_len(nrow(candidate)), block_id)
    estimates <- replicate(2000L, {
      sampled_blocks <- sample(
        seq_along(blocks),
        length(blocks),
        replace = TRUE
      )
      rows <- unlist(blocks[sampled_blocks], use.names = FALSE)
      draw <- candidate[rows, , drop = FALSE]
      c(
        profit_units = sum(draw$selected_profit),
        yield = mean(draw$selected_profit)
      )
    })
    structural_bootstrap_index <- structural_bootstrap_index + 1L
    structural_bootstrap_rows[[structural_bootstrap_index]] <- data.frame(
      sample = sample_name,
      candidate_id = candidate_id,
      bets = nrow(candidate),
      blocks = length(blocks),
      yield_lower_95 = stats::quantile(
        estimates["yield", ],
        0.025,
        names = FALSE
      ),
      yield_upper_95 = stats::quantile(
        estimates["yield", ],
        0.975,
        names = FALSE
      ),
      profit_lower_95 = stats::quantile(
        estimates["profit_units", ],
        0.025,
        names = FALSE
      ),
      profit_upper_95 = stats::quantile(
        estimates["profit_units", ],
        0.975,
        names = FALSE
      ),
      stringsAsFactors = FALSE
    )
  }
}
structural_bootstrap <- do.call(rbind, structural_bootstrap_rows)
rownames(structural_bootstrap) <- NULL

development_summary <- utils::read.csv(file.path(
  project_root,
  "artifacts",
  "premap_model",
  "development_summary.csv"
))
incremental_ids <- c(
  "nb_pace",
  "multiplicative_count_regularized_exponents",
  "multiplicative_rate_regularized_exponents"
)
incremental_model_summary <- development_summary[
  development_summary$candidate_id %in% incremental_ids,
  ,
  drop = FALSE
]
duration_summary <- utils::read.csv(file.path(
  project_root,
  "artifacts",
  "premap_model",
  "duration_summary.csv"
))

set.seed(20260730L)
bootstrap_candidates <- c(
  "raw_nb_pace",
  selected_calibrator,
  "pinnacle_no_vig",
  "market_blend",
  "market_blend_intercept"
)
bootstrap_candidates <- unique(bootstrap_candidates)
bootstrap_rows <- list()
bootstrap_index <- 0L
for (candidate_id in bootstrap_candidates) {
  candidate_bets <- bet_decisions[
    bet_decisions$sample == "combined" &
      bet_decisions$candidate_id == candidate_id &
      bet_decisions$bet,
    ,
    drop = FALSE
  ]
  if (nrow(candidate_bets) == 0L) {
    next
  }
  month <- format(
    candidate_bets$game_datetime,
    "%Y-%m",
    tz = "UTC"
  )
  block_id <- paste(month, candidate_bets$series_id, sep = "|")
  blocks <- split(seq_len(nrow(candidate_bets)), block_id)
  estimates <- replicate(2000L, {
    sampled_blocks <- sample(
      seq_along(blocks),
      length(blocks),
      replace = TRUE
    )
    rows <- unlist(blocks[sampled_blocks], use.names = FALSE)
    draw <- candidate_bets[rows, , drop = FALSE]
    c(
      profit_units = sum(draw$selected_profit),
      yield = mean(draw$selected_profit)
    )
  })
  bootstrap_index <- bootstrap_index + 1L
  bootstrap_rows[[bootstrap_index]] <- data.frame(
    candidate_id = candidate_id,
    bets = nrow(candidate_bets),
    blocks = length(blocks),
    yield_lower_95 = stats::quantile(
      estimates["yield", ],
      0.025,
      names = FALSE
    ),
    yield_upper_95 = stats::quantile(
      estimates["yield", ],
      0.975,
      names = FALSE
    ),
    profit_lower_95 = stats::quantile(
      estimates["profit_units", ],
      0.025,
      names = FALSE
    ),
    profit_upper_95 = stats::quantile(
      estimates["profit_units", ],
      0.975,
      names = FALSE
    ),
    stringsAsFactors = FALSE
  )
}
bootstrap_summary <- do.call(rbind, bootstrap_rows)
rownames(bootstrap_summary) <- NULL

selection <- data.frame(
  selection_period = "2025_q3_development",
  best_log_loss_candidate = best_row$candidate_id[[1L]],
  best_log_loss = best_log_loss,
  best_log_loss_standard_error = best_standard_error,
  selected_simplest_within_one_standard_error = selected_calibrator,
  secondary_period_can_select = FALSE,
  stringsAsFactors = FALSE
)

utils::write.csv(
  fit_parameters,
  file.path(artifact_dir, "calibration_fit_parameters.csv"),
  row.names = FALSE
)
utils::write.csv(
  line_quality,
  file.path(artifact_dir, "line_probability_quality.csv"),
  row.names = FALSE
)
utils::write.csv(
  count_quality,
  file.path(artifact_dir, "count_distribution_quality.csv"),
  row.names = FALSE
)
utils::write.csv(
  economic_summary,
  file.path(artifact_dir, "economic_summary_ev_positive.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap_summary,
  file.path(artifact_dir, "economic_block_bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  structural_summary,
  file.path(artifact_dir, "structural_increment_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  structural_subgroups,
  file.path(artifact_dir, "structural_subgroups.csv"),
  row.names = FALSE
)
utils::write.csv(
  structural_bootstrap,
  file.path(artifact_dir, "structural_economic_bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  incremental_model_summary,
  file.path(artifact_dir, "fundamental_block_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  duration_summary,
  file.path(artifact_dir, "duration_model_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  selection,
  file.path(artifact_dir, "calibrator_selection.csv"),
  row.names = FALSE
)
saveRDS(
  predictions,
  file.path(artifact_dir, "map_probability_predictions.rds"),
  version = 3L
)
saveRDS(
  bet_decisions,
  file.path(artifact_dir, "bet_decisions_ev_positive.rds"),
  version = 3L
)
saveRDS(
  structural_bet_decisions,
  file.path(artifact_dir, "structural_bet_decisions.rds"),
  version = 3L
)

print(selection, row.names = FALSE)
print(
  line_quality[
    line_quality$sample %in% c(
      "2025_q3_development",
      "2026_secondary",
      "combined"
    ),
    ,
    drop = FALSE
  ],
  row.names = FALSE
)
print(
  economic_summary[economic_summary$sample == "combined", ],
  row.names = FALSE
)
print(structural_summary, row.names = FALSE)
