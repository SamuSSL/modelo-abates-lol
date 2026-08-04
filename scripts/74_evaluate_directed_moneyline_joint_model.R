script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
evaluation_config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation_config$directed_moneyline_joint_round
all_maps <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "premap_ratio_map_features_t15.rds"
))
moneyline_maps <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "premap_direct_moneyline_map_features.rds"
))
all_maps <- all_maps[order(all_maps$game_datetime), , drop = FALSE]
moneyline_maps <- moneyline_maps[
  order(moneyline_maps$game_datetime),
  ,
  drop = FALSE
]

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
kill_snapshots <- DBI::dbReadTable(
  connection,
  "market_odds_snapshots"
)
kill_links <- DBI::dbReadTable(connection, "game_market_links")
selected_kills <- select_bettingiscool_map_snapshots(
  kill_snapshots,
  minutes_before_close = as.numeric(
    round_config$prediction_lead_minutes
  )
)
selected_kills <- selected_kills[
  selected_kills$snapshot_minutes_before_close <=
    as.numeric(round_config$maximum_snapshot_age_minutes) &
    abs(selected_kills$line %% 1 - 0.5) < 1e-12,
  ,
  drop = FALSE
]
verified_kill_links <- kill_links[
  kill_links$link_status == "verified",
  c("gameid", "event_id", "period"),
  drop = FALSE
]
kill_market <- merge(
  verified_kill_links,
  selected_kills,
  by = c("event_id", "period")
)
kill_market <- kill_market[
  !duplicated(kill_market$gameid),
  ,
  drop = FALSE
]
line_columns <- c(
  "gameid",
  "line",
  "odds_over",
  "odds_under",
  "true_odds_over",
  "true_odds_under",
  "odds_timestamp"
)
moneyline_maps <- merge(
  moneyline_maps,
  kill_market[line_columns],
  by = "gameid",
  all.x = TRUE,
  sort = FALSE
)
moneyline_maps <- moneyline_maps[
  order(moneyline_maps$game_datetime),
  ,
  drop = FALSE
]

parse_time <- function(value) {
  as.POSIXct(as.character(value), tz = "UTC")
}
development_fold <- data.frame(
  fold_id = "2025_q3_development",
  validation_start = parse_time("2025-07-01 00:00:00"),
  validation_end = parse_time("2025-10-01 00:00:00"),
  can_select = TRUE,
  stringsAsFactors = FALSE
)
secondary_fold <- data.frame(
  fold_id = "2026_secondary",
  validation_start = parse_time("2026-01-01 00:00:00"),
  validation_end = parse_time("2026-08-01 00:00:00"),
  can_select = FALSE,
  stringsAsFactors = FALSE
)
development_start <- parse_time(round_config$development_start)
half_life <- as.numeric(round_config$observation_half_life_days)
prediction_draws <- as.integer(round_config$monte_carlo_draws)
prediction_seed <- as.integer(round_config$prediction_seed)
inner_fraction <- as.numeric(
  round_config$inner_temporal_validation_fraction
)
alpha <- as.numeric(round_config$regularization_alpha)

fold_data <- function(fold) {
  fundamental_train <- all_maps[
    all_maps$game_datetime >= development_start &
      all_maps$prediction_cutoff < fold$validation_start[[1L]],
    ,
    drop = FALSE
  ]
  market_train <- moneyline_maps[
    moneyline_maps$prediction_cutoff < fold$validation_start[[1L]],
    ,
    drop = FALSE
  ]
  validation <- moneyline_maps[
    moneyline_maps$game_datetime >= fold$validation_start[[1L]] &
      moneyline_maps$game_datetime < fold$validation_end[[1L]],
    ,
    drop = FALSE
  ]
  list(
    fundamental_train = fundamental_train,
    market_train = market_train,
    validation = validation,
    fundamental_weights = 0.5^(
      as.numeric(difftime(
        fold$validation_start[[1L]],
        fundamental_train$prediction_cutoff,
        units = "days"
      )) / half_life
    ),
    market_weights = 0.5^(
      as.numeric(difftime(
        fold$validation_start[[1L]],
        market_train$prediction_cutoff,
        units = "days"
      )) / half_life
    )
  )
}

pmf_quantile <- function(pmf, probability) {
  which(cumsum(pmf) >= probability)[[1L]] - 1L
}

score_prediction_set <- function(
  validation,
  predictions,
  candidate_id,
  fold_id
) {
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    prediction <- predictions[[index]]
    observed <- as.integer(validation$total_kills_game[[index]])
    support <- seq.int(0L, length(prediction$pmf) - 1L)
    observed_probability <- if (observed %in% support) {
      prediction$pmf[[observed + 1L]]
    } else {
      0
    }
    lower_90 <- pmf_quantile(prediction$pmf, 0.05)
    upper_90 <- pmf_quantile(prediction$pmf, 0.95)
    has_duration <- !is.null(prediction$duration_draws)
    duration_draws <- if (has_duration) {
      prediction$duration_draws
    } else {
      numeric()
    }
    has_allocation <- !is.null(prediction$blue_share) &&
      !is.null(prediction$allocation_concentration)
    allocation_log_score <- if (has_allocation) {
      -.premap_beta_binomial_log_probability(
        validation$blue_team_kills[[index]],
        observed,
        prediction$blue_share,
        prediction$allocation_concentration
      )
    } else {
      NA_real_
    }
    line <- suppressWarnings(as.numeric(validation$line[[index]]))
    has_line <- is.finite(line) && abs(line %% 1 - 0.5) < 1e-12
    probability_over <- if (has_line) {
      sum(prediction$pmf[support > line])
    } else {
      NA_real_
    }
    observed_over <- if (has_line) observed > line else NA
    odds_over <- suppressWarnings(
      as.numeric(validation$odds_over[[index]])
    )
    odds_under <- suppressWarnings(
      as.numeric(validation$odds_under[[index]])
    )
    over_ev <- if (
      has_line &&
        is.finite(odds_over) &&
        odds_over > 1
    ) {
      probability_over * odds_over - 1
    } else {
      NA_real_
    }
    under_ev <- if (
      has_line &&
        is.finite(odds_under) &&
        odds_under > 1
    ) {
      (1 - probability_over) * odds_under - 1
    } else {
      NA_real_
    }
    decision <- if (
      !is.finite(over_ev) ||
        !is.finite(under_ev) ||
        max(over_ev, under_ev) <
          as.numeric(
            evaluation_config$premap_multiplicative_round$
              soft_market_minimum_ev
          )
    ) {
      "pass"
    } else if (over_ev >= under_ev) {
      "over"
    } else {
      "under"
    }
    profit <- if (decision == "pass") {
      0
    } else if (decision == "over") {
      if (observed_over) odds_over - 1 else -1
    } else {
      if (!observed_over) odds_under - 1 else -1
    }
    data.frame(
      gameid = validation$gameid[[index]],
      series_id = validation$series_id[[index]],
      game_datetime = validation$game_datetime[[index]],
      league_canonical = validation$league_canonical[[index]],
      map_number = validation$map_number[[index]],
      favorite_band = as.character(
        validation$favorite_band[[index]]
      ),
      favorite_probability = validation$favorite_probability[[index]],
      fold_id = fold_id,
      candidate_id = candidate_id,
      observed = observed,
      prediction_mean = prediction$mean,
      error = prediction$mean - observed,
      crps = discrete_crps(prediction$pmf, observed),
      log_score = -log(max(observed_probability, 1e-12)),
      coverage_90 = observed >= lower_90 && observed <= upper_90,
      interval_width_90 = upper_90 - lower_90,
      duration_crps = if (has_duration) {
        .sample_crps(
          duration_draws,
          validation$game_length_minutes[[index]]
        )
      } else {
        NA_real_
      },
      duration_absolute_error = if (has_duration) {
        abs(
          mean(duration_draws) -
            validation$game_length_minutes[[index]]
        )
      } else {
        NA_real_
      },
      duration_error = if (has_duration) {
        mean(duration_draws) -
          validation$game_length_minutes[[index]]
      } else {
        NA_real_
      },
      duration_coverage_90 = if (has_duration) {
        validation$game_length_minutes[[index]] >=
          stats::quantile(duration_draws, 0.05, names = FALSE) &&
          validation$game_length_minutes[[index]] <=
            stats::quantile(duration_draws, 0.95, names = FALSE)
      } else {
        NA
      },
      allocation_log_score = allocation_log_score,
      blue_share_error = if (has_allocation && observed > 0) {
        prediction$blue_share -
          validation$blue_team_kills[[index]] / observed
      } else {
        NA_real_
      },
      theta = if (is.null(prediction$theta)) {
        NA_real_
      } else {
        prediction$theta
      },
      line = line,
      probability_over = probability_over,
      observed_over = observed_over,
      brier = if (has_line) {
        (probability_over - observed_over)^2
      } else {
        NA_real_
      },
      line_log_loss = if (has_line) {
        -log(max(
          if (observed_over) {
            probability_over
          } else {
            1 - probability_over
          },
          1e-12
        ))
      } else {
        NA_real_
      },
      decision = decision,
      stake = as.integer(decision != "pass"),
      profit = profit,
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, rows)
}

summarize_metrics <- function(metrics) {
  groups <- split(
    seq_len(nrow(metrics)),
    interaction(
      metrics$fold_id,
      metrics$candidate_id,
      drop = TRUE,
      lex.order = TRUE
    )
  )
  rows <- lapply(groups, function(index) {
    data <- metrics[index, , drop = FALSE]
    blocks <- stats::aggregate(
      data$crps,
      list(series_id = data$series_id),
      mean
    )
    bets <- data[data$stake == 1L, , drop = FALSE]
    data.frame(
      fold_id = data$fold_id[[1L]],
      candidate_id = data$candidate_id[[1L]],
      maps = nrow(data),
      series = length(unique(data$series_id)),
      mean_crps = mean(data$crps),
      crps_standard_error = stats::sd(blocks$x) /
        sqrt(nrow(blocks)),
      mean_log_score = mean(data$log_score),
      mean_error = mean(data$error),
      coverage_90 = mean(data$coverage_90),
      interval_width_90 = mean(data$interval_width_90),
      duration_crps = mean(data$duration_crps, na.rm = TRUE),
      duration_mae = mean(
        data$duration_absolute_error,
        na.rm = TRUE
      ),
      duration_bias = mean(data$duration_error, na.rm = TRUE),
      duration_coverage_90 = mean(
        data$duration_coverage_90,
        na.rm = TRUE
      ),
      allocation_log_score = mean(
        data$allocation_log_score,
        na.rm = TRUE
      ),
      blue_share_bias = mean(
        data$blue_share_error,
        na.rm = TRUE
      ),
      mean_brier = mean(data$brier, na.rm = TRUE),
      mean_line_log_loss = mean(data$line_log_loss, na.rm = TRUE),
      calibration_error = mean(
        data$probability_over - data$observed_over,
        na.rm = TRUE
      ),
      bets = nrow(bets),
      profit = sum(bets$profit),
      yield = if (nrow(bets) > 0L) mean(bets$profit) else NA_real_,
      stringsAsFactors = FALSE
    )
  })
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

select_one_standard_error <- function(summary, complexity) {
  best_index <- which.min(summary$mean_crps)
  threshold <- summary$mean_crps[[best_index]] +
    summary$crps_standard_error[[best_index]]
  eligible <- summary[
    summary$mean_crps <= threshold,
    ,
    drop = FALSE
  ]
  eligible$complexity <- complexity[eligible$candidate_id]
  eligible <- eligible[
    order(
      eligible$complexity,
      eligible$mean_crps,
      eligible$mean_log_score
    ),
    ,
    drop = FALSE
  ]
  eligible[1L, , drop = FALSE]
}

fit_pace_baseline <- function(training, weights, validation) {
  fit <- fit_count_regression(
    training,
    distribution = "negative_binomial",
    feature_names = "pace",
    weights = weights
  )
  predict_count_regression(fit, validation)
}

development <- fold_data(development_fold)
if (
  nrow(development$market_train) < 80L ||
    nrow(development$validation) < 30L
) {
  stop(
    "A cobertura de moneyline nao sustenta o fold de desenvolvimento.",
    call. = FALSE
  )
}

development_batches <- list()
batch_index <- 0L
pace_predictions <- fit_pace_baseline(
  development$fundamental_train,
  development$fundamental_weights,
  development$validation
)
batch_index <- batch_index + 1L
development_batches[[batch_index]] <- score_prediction_set(
  development$validation,
  pace_predictions,
  "nb_pace",
  development_fold$fold_id
)

fundamental_specs <- list(
  joint_last15_global = list(
    windows = "last15",
    dispersion = "global",
    complexity = 3
  ),
  joint_season_last15_global = list(
    windows = c("season", "last15"),
    dispersion = "global",
    complexity = 4
  ),
  joint_all_windows_global = list(
    windows = as.character(unlist(round_config$rating_windows)),
    dispersion = "global",
    complexity = 7
  ),
  joint_last15_team_volatility = list(
    windows = "last15",
    dispersion = "favoritism_team_volatility",
    complexity = 4
  )
)
fundamental_fits <- list()
for (candidate_id in names(fundamental_specs)) {
  spec <- fundamental_specs[[candidate_id]]
  fit <- fit_directed_joint_fundamental(
    development$fundamental_train,
    windows = spec$windows,
    alpha = alpha,
    weights = development$fundamental_weights,
    inner_fraction = inner_fraction,
    dispersion_mode = spec$dispersion,
    seed = prediction_seed
  )
  predictions <- predict_directed_joint_fundamental(
    fit,
    development$validation,
    draws = prediction_draws,
    seed = prediction_seed
  )
  fundamental_fits[[candidate_id]] <- fit
  batch_index <- batch_index + 1L
  development_batches[[batch_index]] <- score_prediction_set(
    development$validation,
    predictions,
    candidate_id,
    development_fold$fold_id
  )
}
development_fundamental_metrics <- do.call(
  rbind,
  development_batches
)
development_fundamental_summary <- summarize_metrics(
  development_fundamental_metrics
)
fundamental_complexity <- c(
  nb_pace = 2,
  vapply(
    fundamental_specs,
    function(spec) spec$complexity,
    numeric(1L)
  )
)
selected_fundamental_row <- select_one_standard_error(
  development_fundamental_summary,
  fundamental_complexity
)
selected_fundamental_id <- selected_fundamental_row$candidate_id[[1L]]
challenger_rows <- development_fundamental_summary[
  development_fundamental_summary$candidate_id != "nb_pace",
  ,
  drop = FALSE
]
best_joint_fundamental_id <- challenger_rows$candidate_id[[
  which.min(challenger_rows$mean_crps)
]]
correction_base_id <- if (
  selected_fundamental_id == "nb_pace"
) {
  best_joint_fundamental_id
} else {
  selected_fundamental_id
}
correction_base_fit <- fundamental_fits[[correction_base_id]]

correction_specs <- list(
  joint_ml_linear_global = list(
    shape = "linear",
    interactions = FALSE,
    dispersion = "global",
    complexity = 5
  ),
  joint_ml_linear_favoritism_dispersion = list(
    shape = "linear",
    interactions = FALSE,
    dispersion = "favoritism",
    complexity = 6
  ),
  joint_ml_linear_favoritism_volatility = list(
    shape = "linear",
    interactions = FALSE,
    dispersion = "favoritism_team_volatility",
    complexity = 7
  ),
  joint_ml_quadratic_global = list(
    shape = "quadratic",
    interactions = FALSE,
    dispersion = "global",
    complexity = 7
  ),
  joint_ml_quadratic_favoritism_dispersion = list(
    shape = "quadratic",
    interactions = FALSE,
    dispersion = "favoritism",
    complexity = 8
  ),
  joint_ml_quadratic_interactions_global = list(
    shape = "quadratic",
    interactions = TRUE,
    dispersion = "global",
    complexity = 10
  )
)
correction_fits <- list()
for (candidate_id in names(correction_specs)) {
  spec <- correction_specs[[candidate_id]]
  fit <- fit_moneyline_joint_correction(
    correction_base_fit,
    development$market_train,
    shape = spec$shape,
    interactions = spec$interactions,
    dispersion_mode = spec$dispersion,
    weights = development$market_weights,
    seed = prediction_seed
  )
  predictions <- predict_moneyline_joint_model(
    fit,
    development$validation,
    draws = prediction_draws,
    seed = prediction_seed
  )
  correction_fits[[candidate_id]] <- fit
  batch_index <- batch_index + 1L
  development_batches[[batch_index]] <- score_prediction_set(
    development$validation,
    predictions,
    candidate_id,
    development_fold$fold_id
  )
}
development_metrics <- do.call(rbind, development_batches)
development_summary <- summarize_metrics(development_metrics)
all_complexity <- c(
  fundamental_complexity,
  vapply(
    correction_specs,
    function(spec) spec$complexity,
    numeric(1L)
  )
)
selected_overall_row <- select_one_standard_error(
  development_summary,
  all_complexity
)
selected_overall_id <- selected_overall_row$candidate_id[[1L]]
correction_rows <- development_summary[
  development_summary$candidate_id %in% names(correction_specs),
  ,
  drop = FALSE
]
selected_moneyline_id <- correction_rows$candidate_id[[
  which.min(correction_rows$mean_crps)
]]

secondary <- fold_data(secondary_fold)
selected_fundamental_spec <- fundamental_specs[[correction_base_id]]
secondary_fundamental <- fit_directed_joint_fundamental(
  secondary$fundamental_train,
  windows = selected_fundamental_spec$windows,
  alpha = alpha,
  weights = secondary$fundamental_weights,
  inner_fraction = inner_fraction,
  dispersion_mode = selected_fundamental_spec$dispersion,
  seed = prediction_seed
)
selected_moneyline_spec <- correction_specs[[selected_moneyline_id]]
secondary_moneyline <- fit_moneyline_joint_correction(
  secondary_fundamental,
  secondary$market_train,
  shape = selected_moneyline_spec$shape,
  interactions = selected_moneyline_spec$interactions,
  dispersion_mode = selected_moneyline_spec$dispersion,
  weights = secondary$market_weights,
  seed = prediction_seed
)
secondary_batches <- list(
  score_prediction_set(
    secondary$validation,
    fit_pace_baseline(
      secondary$fundamental_train,
      secondary$fundamental_weights,
      secondary$validation
    ),
    "nb_pace",
    secondary_fold$fold_id
  ),
  score_prediction_set(
    secondary$validation,
    predict_directed_joint_fundamental(
      secondary_fundamental,
      secondary$validation,
      draws = prediction_draws,
      seed = prediction_seed
    ),
    correction_base_id,
    secondary_fold$fold_id
  ),
  score_prediction_set(
    secondary$validation,
    predict_moneyline_joint_model(
      secondary_moneyline,
      secondary$validation,
      draws = prediction_draws,
      seed = prediction_seed
    ),
    selected_moneyline_id,
    secondary_fold$fold_id
  )
)
secondary_metrics <- do.call(rbind, secondary_batches)
all_metrics <- rbind(development_metrics, secondary_metrics)
all_summary <- summarize_metrics(all_metrics)

group_summary <- function(columns) {
  complete <- stats::complete.cases(all_metrics[columns])
  data <- all_metrics[complete, , drop = FALSE]
  stats::aggregate(
    data[c(
      "crps",
      "log_score",
      "error",
      "coverage_90",
      "duration_crps",
      "allocation_log_score",
      "brier",
      "line_log_loss"
    )],
    data[columns],
    function(value) mean(value, na.rm = TRUE)
  )
}

development_selected <- development_metrics[
  development_metrics$candidate_id == selected_moneyline_id,
  ,
  drop = FALSE
]
development_pace <- development_metrics[
  development_metrics$candidate_id == "nb_pace",
  ,
  drop = FALSE
]
paired <- merge(
  development_selected,
  development_pace,
  by = "gameid",
  suffixes = c("_challenger", "_pace")
)
set.seed(as.integer(round_config$bootstrap_seed))
blocks <- split(
  seq_len(nrow(paired)),
  paired$series_id_challenger
)
replicates <- as.integer(round_config$bootstrap_replicates)
bootstrap_delta <- replicate(replicates, {
  sampled <- sample(seq_along(blocks), length(blocks), replace = TRUE)
  rows <- unlist(blocks[sampled], use.names = FALSE)
  mean(
    paired$crps_challenger[rows] -
      paired$crps_pace[rows]
  )
})
bootstrap_summary <- data.frame(
  challenger_id = selected_moneyline_id,
  reference_id = "nb_pace",
  replicates = replicates,
  mean_crps_delta = mean(
    paired$crps_challenger - paired$crps_pace
  ),
  crps_delta_low = stats::quantile(
    bootstrap_delta,
    0.025,
    names = FALSE
  ),
  crps_delta_high = stats::quantile(
    bootstrap_delta,
    0.975,
    names = FALSE
  ),
  stringsAsFactors = FALSE
)

development_by_league <- group_summary(
  c("fold_id", "candidate_id", "league_canonical")
)
development_by_band <- group_summary(
  c("fold_id", "candidate_id", "favorite_band")
)
development_by_map <- group_summary(
  c("fold_id", "candidate_id", "map_number")
)

selected_summary <- development_summary[
  development_summary$candidate_id == selected_moneyline_id,
  ,
  drop = FALSE
]
pace_summary <- development_summary[
  development_summary$candidate_id == "nb_pace",
  ,
  drop = FALSE
]
league_challenger <- development_by_league[
  development_by_league$fold_id == development_fold$fold_id &
    development_by_league$candidate_id == selected_moneyline_id,
  c("league_canonical", "crps"),
  drop = FALSE
]
league_pace <- development_by_league[
  development_by_league$fold_id == development_fold$fold_id &
    development_by_league$candidate_id == "nb_pace",
  c("league_canonical", "crps"),
  drop = FALSE
]
league_gate <- merge(
  league_challenger,
  league_pace,
  by = "league_canonical",
  suffixes = c("_challenger", "_pace")
)
band_challenger <- development_by_band[
  development_by_band$fold_id == development_fold$fold_id &
    development_by_band$candidate_id == selected_moneyline_id,
  c("favorite_band", "crps"),
  drop = FALSE
]
band_pace <- development_by_band[
  development_by_band$fold_id == development_fold$fold_id &
    development_by_band$candidate_id == "nb_pace",
  c("favorite_band", "crps"),
  drop = FALSE
]
band_gate <- merge(
  band_challenger,
  band_pace,
  by = "favorite_band",
  suffixes = c("_challenger", "_pace")
)
promotion_checks <- data.frame(
  check = c(
    "development_crps_improves",
    "development_log_score_not_worse",
    "no_league_worse_than_one_percent",
    "at_least_two_favoritism_bands_improve",
    "coverage_90_inside_guardrail",
    "prospective_confirmation_complete"
  ),
  passed = c(
    selected_summary$mean_crps < pace_summary$mean_crps,
    selected_summary$mean_log_score <= pace_summary$mean_log_score,
    all(
      league_gate$crps_challenger <=
        league_gate$crps_pace * (
          1 + as.numeric(
            round_config$promotion$
              maximum_league_crps_degradation_fraction
          )
        )
    ),
    sum(
      band_gate$crps_challenger < band_gate$crps_pace
    ) >= as.integer(
      round_config$promotion$minimum_favoritism_bands_improved
    ),
    selected_summary$coverage_90 >= as.numeric(
      round_config$promotion$coverage_90_minimum
    ) &&
      selected_summary$coverage_90 <= as.numeric(
        round_config$promotion$coverage_90_maximum
      ),
    FALSE
  ),
  stringsAsFactors = FALSE
)
promotion_decision <- data.frame(
  selected_by_one_standard_error = selected_overall_id,
  best_joint_fundamental = best_joint_fundamental_id,
  selected_moneyline_challenger = selected_moneyline_id,
  all_historical_checks_passed = all(
    promotion_checks$passed[
      promotion_checks$check !=
        "prospective_confirmation_complete"
    ]
  ),
  prospective_confirmation_complete = FALSE,
  promote_to_streamlit = all(promotion_checks$passed),
  decision = if (all(promotion_checks$passed)) {
    "promote"
  } else {
    "retain_nb_pace_and_run_joint_model_in_shadow"
  },
  stringsAsFactors = FALSE
)

artifact_dir <- file.path(project_root, "artifacts", "premap_joint_model")
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(
  all_metrics,
  file.path(artifact_dir, "map_metrics.rds"),
  version = 3L
)
saveRDS(
  list(
    development_fundamental_fits = fundamental_fits,
    development_correction_fits = correction_fits,
    secondary_fundamental = secondary_fundamental,
    secondary_moneyline = secondary_moneyline,
    selected_fundamental_id = correction_base_id,
    selected_moneyline_id = selected_moneyline_id
  ),
  file.path(artifact_dir, "model_fits.rds"),
  version = 3L
)
utils::write.csv(
  all_summary,
  file.path(artifact_dir, "model_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  development_by_league,
  file.path(artifact_dir, "by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  development_by_band,
  file.path(artifact_dir, "by_favoritism.csv"),
  row.names = FALSE
)
utils::write.csv(
  development_by_map,
  file.path(artifact_dir, "by_map_number.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap_summary,
  file.path(artifact_dir, "bootstrap_vs_pace.csv"),
  row.names = FALSE
)
utils::write.csv(
  promotion_checks,
  file.path(artifact_dir, "promotion_checks.csv"),
  row.names = FALSE
)
utils::write.csv(
  promotion_decision,
  file.path(artifact_dir, "promotion_decision.csv"),
  row.names = FALSE
)
fold_coverage <- rbind(
  data.frame(
    fold_id = development_fold$fold_id,
    fundamental_train_maps = nrow(development$fundamental_train),
    moneyline_train_maps = nrow(development$market_train),
    validation_maps = nrow(development$validation),
    can_select = TRUE
  ),
  data.frame(
    fold_id = secondary_fold$fold_id,
    fundamental_train_maps = nrow(secondary$fundamental_train),
    moneyline_train_maps = nrow(secondary$market_train),
    validation_maps = nrow(secondary$validation),
    can_select = FALSE
  )
)
utils::write.csv(
  fold_coverage,
  file.path(artifact_dir, "fold_coverage.csv"),
  row.names = FALSE
)
print(all_summary, row.names = FALSE)
print(bootstrap_summary, row.names = FALSE)
print(promotion_checks, row.names = FALSE)
print(promotion_decision, row.names = FALSE)
