script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
evaluation <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation$premap_multiplicative_round
aliases <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "bettingiscool-team-aliases.yml"
))
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
required_tables <- c(
  "kills_regular_event_links",
  "market_fixtures",
  "market_odds_snapshots",
  "game_market_links"
)
missing_tables <- setdiff(
  required_tables,
  DBI::dbListTables(connection)
)
if (length(missing_tables) > 0L) {
  stop(
    "Backfill de moneyline ainda nao foi executado.",
    call. = FALSE
  )
}
moneyline_available <- DBI::dbExistsTable(
  connection,
  "market_moneyline_snapshots"
)
moneylines <- if (moneyline_available) {
  DBI::dbReadTable(connection, "market_moneyline_snapshots")
} else {
  data.frame()
}
moneyline_available <- nrow(moneylines) > 0L
selected_moneylines <- if (moneyline_available) {
  select_bettingiscool_moneyline_snapshots(
    moneylines,
    round_config$moneyline_snapshot_minimum_minutes,
    round_config$moneyline_snapshot_maximum_minutes
  )
} else {
  data.frame()
}
regular_event_links <- DBI::dbReadTable(
  connection,
  "kills_regular_event_links"
)
fixtures <- DBI::dbReadTable(connection, "market_fixtures")
regular_fixtures <- fixtures[
  tolower(as.character(fixtures$resulting_unit)) == "regular",
  ,
  drop = FALSE
]
game_links <- DBI::dbReadTable(connection, "game_market_links")
maps <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "premap_ratio_map_features_t15.rds"
))
moneyline_maps <- if (moneyline_available) {
  attach_moneyline_to_maps(
    maps,
    game_links,
    regular_event_links,
    regular_fixtures,
    selected_moneylines,
    aliases
  )
} else {
  data.frame()
}

kill_snapshots <- DBI::dbReadTable(
  connection,
  "market_odds_snapshots"
)
selected_kills <- select_bettingiscool_map_snapshots(
  kill_snapshots,
  minutes_before_close = 15
)
selected_kills <- selected_kills[
  selected_kills$snapshot_minutes_before_close <= 30 &
    abs(selected_kills$line %% 1 - 0.5) < 1e-12,
  ,
  drop = FALSE
]
kill_links <- game_links[
  game_links$link_status == "verified",
  c("gameid", "event_id", "period"),
  drop = FALSE
]
kill_market <- merge(
  kill_links,
  selected_kills,
  by = c("event_id", "period")
)
over_raw <- 1 / kill_market$true_odds_over
under_raw <- 1 / kill_market$true_odds_under
kill_market$market_probability_over <- over_raw / (over_raw + under_raw)
market_columns <- c(
  "gameid",
  "line",
  "odds_over",
  "odds_under",
  "true_odds_over",
  "true_odds_under",
  "market_probability_over",
  "odds_timestamp",
  "market_close_time",
  "snapshot_minutes_before_close"
)
market_maps <- merge(
  maps,
  kill_market[market_columns],
  by = "gameid"
)
if (moneyline_available) {
  moneyline_columns <- intersect(
    c(
      "p_blue",
      "p_red",
      "favorite_probability",
      "home_log_odds",
      "favorite_log_odds_difference",
      "favorite_band",
      "blue_log_odds",
      "home_is_blue"
    ),
    names(moneyline_maps)
  )
  moneyline_columns <- c("gameid", moneyline_columns)
  market_maps <- merge(
    market_maps,
    moneyline_maps[moneyline_columns],
    by = "gameid"
  )
}
market_maps_before_timing_filter <- market_maps
market_maps <- market_maps[
  !duplicated(market_maps$gameid) &
    market_maps$odds_timestamp <= market_maps$market_close_time &
    market_maps$odds_timestamp <= market_maps$prediction_cutoff &
    market_maps$prediction_cutoff <= market_maps$market_close_time,
  ,
  drop = FALSE
]
timing_audit <- data.frame(
  selected_kill_event_periods = nrow(selected_kills),
  linked_kill_event_periods = nrow(kill_market),
  maps_before_timing_filter = nrow(market_maps_before_timing_filter),
  odds_at_or_before_prediction = sum(
    market_maps_before_timing_filter$odds_timestamp <=
      market_maps_before_timing_filter$prediction_cutoff,
    na.rm = TRUE
  ),
  prediction_at_or_before_market_close = sum(
    market_maps_before_timing_filter$prediction_cutoff <=
      market_maps_before_timing_filter$market_close_time,
    na.rm = TRUE
  ),
  maps_after_timing_filter = nrow(market_maps),
  median_odds_minutes_before_prediction = stats::median(
    as.numeric(difftime(
      market_maps_before_timing_filter$prediction_cutoff,
      market_maps_before_timing_filter$odds_timestamp,
      units = "mins"
    )),
    na.rm = TRUE
  ),
  median_prediction_minutes_before_market_close = stats::median(
    as.numeric(difftime(
      market_maps_before_timing_filter$market_close_time,
      market_maps_before_timing_filter$prediction_cutoff,
      units = "mins"
    )),
    na.rm = TRUE
  ),
  stringsAsFactors = FALSE
)
print(timing_audit, row.names = FALSE)
coverage <- if (moneyline_available) {
  summarize_favoritism_coverage(
    market_maps,
    round_config$favoritism_minimum_aggregate_maps,
    round_config$favoritism_minimum_league_maps
  )
} else {
  data.frame(
    message = "Moneyline indisponivel: backfill autenticado pendente.",
    stringsAsFactors = FALSE
  )
}

parse_time <- function(value) as.POSIXct(as.character(value), tz = "UTC")
folds <- data.frame(
  fold_id = c("2025_q3_market", "2025_q4_market"),
  validation_start = parse_time(c(
    "2025-07-01 00:00:00",
    "2025-10-01 00:00:00"
  )),
  validation_end = parse_time(c(
    "2025-10-01 00:00:00",
    "2026-01-01 00:00:00"
  )),
  stringsAsFactors = FALSE
)
development_start <- parse_time(round_config$development_start)
windows <- unlist(round_config$windows, use.names = FALSE)

score_candidate <- function(
  validation,
  predictions,
  candidate_id,
  fold_id
) {
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    prediction <- predictions[[index]]
    observed <- as.integer(validation$total_kills_game[[index]])
    probability_observed <- if (observed + 1L <= length(prediction$pmf)) {
      prediction$pmf[[observed + 1L]]
    } else {
      0
    }
    probability_over <- .pmf_probability_over(
      prediction$pmf,
      validation$line[[index]]
    )
    observed_over <- observed > validation$line[[index]]
    over_ev <- probability_over * validation$odds_over[[index]] - 1
    under_ev <- (1 - probability_over) *
      validation$odds_under[[index]] - 1
    decision <- if (max(over_ev, under_ev) < 0.05) {
      "pass"
    } else if (over_ev >= under_ev) {
      "over"
    } else {
      "under"
    }
    profit <- if (decision == "pass") {
      0
    } else if (decision == "over") {
      if (observed_over) validation$odds_over[[index]] - 1 else -1
    } else {
      if (!observed_over) validation$odds_under[[index]] - 1 else -1
    }
    data.frame(
      gameid = validation$gameid[[index]],
      series_id = validation$series_id[[index]],
      game_datetime = validation$game_datetime[[index]],
      league_canonical = validation$league_canonical[[index]],
      map_number = validation$map_number[[index]],
      favorite_band = if ("favorite_band" %in% names(validation)) {
        as.character(validation$favorite_band[[index]])
      } else {
        NA_character_
      },
      fold_id = fold_id,
      candidate_id = candidate_id,
      observed = observed,
      prediction_mean = prediction$mean,
      crps = discrete_crps(prediction$pmf, observed),
      log_score = -log(max(probability_observed, 1e-12)),
      line = validation$line[[index]],
      probability_over = probability_over,
      market_probability_over =
        validation$market_probability_over[[index]],
      market_tilt_weight = if (
        is.null(prediction$market_tilt_weight)
      ) {
        NA_real_
      } else {
        as.numeric(prediction$market_tilt_weight)
      },
      observed_over = observed_over,
      brier = (probability_over - observed_over)^2,
      line_log_loss = -log(max(if (observed_over) {
        probability_over
      } else {
        1 - probability_over
      }, 1e-12)),
      decision = decision,
      stake = as.integer(decision != "pass"),
      profit = profit,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

batches <- list()
batch_index <- 0L
fold_coverage_rows <- list()
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  fundamental_train <- maps[
    maps$game_datetime >= development_start &
      maps$prediction_cutoff < fold$validation_start[[1L]],
    ,
    drop = FALSE
  ]
  market_train <- market_maps[
    market_maps$prediction_cutoff < fold$validation_start[[1L]],
    ,
    drop = FALSE
  ]
  validation <- market_maps[
    market_maps$game_datetime >= fold$validation_start[[1L]] &
      market_maps$game_datetime < fold$validation_end[[1L]],
    ,
    drop = FALSE
  ]
  fold_coverage_rows[[fold_index]] <- data.frame(
    fold_id = fold$fold_id[[1L]],
    fundamental_train_maps = nrow(fundamental_train),
    market_train_maps = nrow(market_train),
    validation_maps = nrow(validation),
    stringsAsFactors = FALSE
  )
  if (nrow(market_train) < 100L || nrow(validation) < 30L) {
    next
  }
  fundamental_weights <- 0.5^(as.numeric(difftime(
    fold$validation_start[[1L]],
    fundamental_train$prediction_cutoff,
    units = "days"
  )) / round_config$observation_half_life_days)
  market_weights <- 0.5^(as.numeric(difftime(
    fold$validation_start[[1L]],
    market_train$prediction_cutoff,
    units = "days"
  )) / round_config$observation_half_life_days)
  fundamental <- fit_regularized_multiplicative_exponents(
    fundamental_train,
    expectation = "rate",
    windows = windows,
    alpha = 0,
    weights = fundamental_weights
  )
  fundamental_train_predictions <-
    predict_regularized_multiplicative_exponents(
      fundamental,
      market_train
    )
  fundamental_validation_predictions <-
    predict_regularized_multiplicative_exponents(
      fundamental,
      validation
    )
  pace_fundamental <- fit_count_regression(
    fundamental_train,
    "negative_binomial",
    "pace",
    fundamental_weights
  )
  pace_train_predictions <- predict_count_regression(
    pace_fundamental,
    market_train
  )
  pace_validation_predictions <- predict_count_regression(
    pace_fundamental,
    validation
  )
  fundamental_tilt <- fit_kill_market_tilt_weight(
    fundamental_train_predictions,
    market_train
  )
  pace_tilt <- fit_kill_market_tilt_weight(
    pace_train_predictions,
    market_train
  )
  prediction_sets <- list(
    fundamental_multiplicative =
      fundamental_validation_predictions,
    fundamental_pace =
      pace_validation_predictions,
    fundamental_total_market = predict_kill_market_hybrid(
      fundamental_validation_predictions,
      validation,
      fundamental_tilt
    ),
    fundamental_pace_total_market = predict_kill_market_hybrid(
      pace_validation_predictions,
      validation,
      pace_tilt
    )
  )
  if (moneyline_available) {
    moneyline <- fit_moneyline_informed_model(
      market_train,
      fundamental,
      interactions = FALSE,
      weights = market_weights
    )
    moneyline_train_predictions <- predict_moneyline_informed_model(
      moneyline,
      market_train
    )
    moneyline_validation_predictions <- predict_moneyline_informed_model(
      moneyline,
      validation
    )
    moneyline_spline <- fit_moneyline_informed_model(
      market_train,
      fundamental,
      interactions = FALSE,
      spline = TRUE,
      weights = market_weights
    )
    moneyline_spline_validation_predictions <-
      predict_moneyline_informed_model(
        moneyline_spline,
        validation
      )
    moneyline_interactions <- fit_moneyline_informed_model(
      market_train,
      fundamental,
      interactions = TRUE,
      weights = market_weights
    )
    interaction_validation_predictions <-
      predict_moneyline_informed_model(
        moneyline_interactions,
        validation
      )
    moneyline_tilt <- fit_kill_market_tilt_weight(
      moneyline_train_predictions,
      market_train
    )
    prediction_sets$fundamental_moneyline <-
      moneyline_validation_predictions
    prediction_sets$fundamental_moneyline_spline <-
      moneyline_spline_validation_predictions
    prediction_sets$fundamental_moneyline_interactions <-
      interaction_validation_predictions
    prediction_sets$fundamental_moneyline_total_market <-
      predict_kill_market_hybrid(
        moneyline_validation_predictions,
        validation,
        moneyline_tilt
      )
  }
  for (candidate_id in names(prediction_sets)) {
    batch_index <- batch_index + 1L
    batches[[batch_index]] <- score_candidate(
      validation,
      prediction_sets[[candidate_id]],
      candidate_id,
      fold$fold_id[[1L]]
    )
  }
}
fold_coverage <- do.call(rbind, fold_coverage_rows)
print(fold_coverage, row.names = FALSE)
if (length(batches) == 0L) {
  artifact_dir <- file.path(project_root, "artifacts", "premap_model")
  utils::write.csv(
    timing_audit,
    file.path(artifact_dir, "market_informed_timing_audit.csv"),
    row.names = FALSE
  )
  utils::write.csv(
    fold_coverage,
    file.path(artifact_dir, "market_informed_fold_coverage.csv"),
    row.names = FALSE
  )
  stop(
    "Cobertura historica insuficiente para folds de mercado.",
    call. = FALSE
  )
}
metrics <- do.call(rbind, batches)
metrics <- metrics[order(metrics$candidate_id, metrics$game_datetime), ]
groups <- split(metrics, metrics$candidate_id)
summary <- do.call(rbind, lapply(groups, function(group) {
  bets <- group[group$stake == 1L, , drop = FALSE]
  cumulative <- if (nrow(bets) > 0L) cumsum(bets$profit) else numeric()
  running_peak <- if (length(cumulative) > 0L) {
    cummax(c(0, cumulative))[-1L]
  } else {
    numeric()
  }
  data.frame(
    candidate_id = group$candidate_id[[1L]],
    maps = nrow(group),
    mean_crps = mean(group$crps),
    mean_log_score = mean(group$log_score),
    mean_brier = mean(group$brier),
    mean_line_log_loss = mean(group$line_log_loss),
    calibration_error = mean(
      group$probability_over - group$observed_over
    ),
    bets = nrow(bets),
    profit = sum(bets$profit),
    yield = if (nrow(bets) > 0L) mean(bets$profit) else NA_real_,
    maximum_drawdown = if (length(cumulative) > 0L) {
      max(running_peak - cumulative)
    } else {
      0
    },
    stringsAsFactors = FALSE
  )
}))
benchmark_maps <- metrics[
  !duplicated(paste(metrics$fold_id, metrics$gameid)),
  ,
  drop = FALSE
]
market_brier <- (
  benchmark_maps$market_probability_over -
    benchmark_maps$observed_over
)^2
market_line_log_loss <- -log(pmax(
  ifelse(
    benchmark_maps$observed_over,
    benchmark_maps$market_probability_over,
    1 - benchmark_maps$market_probability_over
  ),
  1e-12
))
benchmark_summary <- data.frame(
  candidate_id = "pinnacle_total_market_no_vig",
  maps = nrow(benchmark_maps),
  mean_crps = NA_real_,
  mean_log_score = NA_real_,
  mean_brier = mean(market_brier),
  mean_line_log_loss = mean(market_line_log_loss),
  calibration_error = mean(
    benchmark_maps$market_probability_over -
      benchmark_maps$observed_over
  ),
  bets = NA_integer_,
  profit = NA_real_,
  yield = NA_real_,
  maximum_drawdown = NA_real_,
  stringsAsFactors = FALSE
)
summary_with_benchmark <- rbind(summary, benchmark_summary)

set.seed(20260729L)
bootstrap_rows <- lapply(groups, function(group) {
  block_id <- paste(
    format(group$game_datetime, "%Y-%m", tz = "UTC"),
    group$series_id,
    sep = "|"
  )
  blocks <- split(seq_len(nrow(group)), block_id)
  draws <- replicate(2000L, {
    sampled_blocks <- sample(
      seq_along(blocks),
      length(blocks),
      replace = TRUE
    )
    rows <- unlist(blocks[sampled_blocks], use.names = FALSE)
    sample_data <- group[rows, , drop = FALSE]
    bets <- sample_data[sample_data$stake == 1L, , drop = FALSE]
    market_sample_brier <- (
      sample_data$market_probability_over -
        sample_data$observed_over
    )^2
    market_sample_log_loss <- -log(pmax(
      ifelse(
        sample_data$observed_over,
        sample_data$market_probability_over,
        1 - sample_data$market_probability_over
      ),
      1e-12
    ))
    c(
      brier_delta = mean(sample_data$brier - market_sample_brier),
      line_log_loss_delta = mean(
        sample_data$line_log_loss - market_sample_log_loss
      ),
      yield = if (nrow(bets) > 0L) mean(bets$profit) else NA_real_
    )
  })
  quantile_value <- function(metric, probability) {
    stats::quantile(
      draws[metric, ],
      probability,
      na.rm = TRUE,
      names = FALSE
    )
  }
  data.frame(
    candidate_id = group$candidate_id[[1L]],
    replicates = 2000L,
    brier_delta_low = quantile_value("brier_delta", 0.025),
    brier_delta_high = quantile_value("brier_delta", 0.975),
    line_log_loss_delta_low = quantile_value(
      "line_log_loss_delta",
      0.025
    ),
    line_log_loss_delta_high = quantile_value(
      "line_log_loss_delta",
      0.975
    ),
    yield_low = quantile_value("yield", 0.025),
    yield_high = quantile_value("yield", 0.975),
    stringsAsFactors = FALSE
  )
})
bootstrap_summary <- do.call(rbind, bootstrap_rows)

tilt_weights <- stats::aggregate(
  metrics$market_tilt_weight,
  metrics[c("candidate_id", "fold_id")],
  function(value) {
    value <- value[is.finite(value)]
    if (length(value) == 0L) NA_real_ else unique(value)[[1L]]
  }
)
names(tilt_weights)[[3L]] <- "market_tilt_weight"
execution_status <- data.frame(
  evaluated_at = as.POSIXct(Sys.time(), tz = "UTC"),
  kill_market_snapshots = nrow(kill_snapshots),
  selected_kill_event_periods = nrow(selected_kills),
  matched_market_maps = nrow(market_maps),
  evaluated_maps = nrow(benchmark_maps),
  moneyline_available = moneyline_available,
  selected_moneyline_event_periods = nrow(selected_moneylines),
  folds_evaluated = length(unique(metrics$fold_id)),
  stringsAsFactors = FALSE
)
artifact_dir <- file.path(project_root, "artifacts", "premap_model")
saveRDS(
  metrics,
  file.path(artifact_dir, "market_informed_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary_with_benchmark[
    order(
      is.na(summary_with_benchmark$mean_crps),
      summary_with_benchmark$mean_crps
    ),
  ],
  file.path(artifact_dir, "market_informed_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap_summary,
  file.path(artifact_dir, "market_informed_bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  tilt_weights,
  file.path(artifact_dir, "market_informed_tilt_weights.csv"),
  row.names = FALSE
)
utils::write.csv(
  execution_status,
  file.path(artifact_dir, "market_informed_execution_status.csv"),
  row.names = FALSE
)
utils::write.csv(
  timing_audit,
  file.path(artifact_dir, "market_informed_timing_audit.csv"),
  row.names = FALSE
)
utils::write.csv(
  fold_coverage,
  file.path(artifact_dir, "market_informed_fold_coverage.csv"),
  row.names = FALSE
)
utils::write.csv(
  coverage,
  file.path(artifact_dir, "favoritism_coverage.csv"),
  row.names = FALSE
)
utils::write.csv(
  stats::aggregate(
    metrics[c("crps", "brier", "line_log_loss")],
    metrics[c("candidate_id", "league_canonical")],
    mean
  ),
  file.path(artifact_dir, "market_informed_by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  if (moneyline_available) {
    stats::aggregate(
      metrics[c("crps", "brier", "line_log_loss")],
      metrics[c("candidate_id", "favorite_band")],
      mean
    )
  } else {
    data.frame(
      message = "Moneyline indisponivel: backfill autenticado pendente.",
      stringsAsFactors = FALSE
    )
  },
  file.path(artifact_dir, "market_informed_by_favoritism.csv"),
  row.names = FALSE
)
print(
  summary_with_benchmark[
    order(
      is.na(summary_with_benchmark$mean_crps),
      summary_with_benchmark$mean_crps
    ),
  ],
  row.names = FALSE
)
print(bootstrap_summary, row.names = FALSE)
print(execution_status, row.names = FALSE)
