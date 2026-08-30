script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

database_path <- file.path(
  project_root,
  "data",
  "processed",
  "lolkills.duckdb"
)
output_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "postdraft-market-efficiency"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = database_path,
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

post <- DBI::dbGetQuery(connection, "
  select q.*, g.game_datetime, g.series_id, g.total_kills_game as observed_total,
         g.target_valid
  from market_postdraft_quotes q
  join canonical_games g on g.gameid = q.gameid
  where q.gameid is not null and g.target_valid
  qualify row_number() over (
    partition by q.gameid order by q.quote_time desc, q.snapshot_id desc
  ) = 1
")
post$game_datetime <- as.POSIXct(post$game_datetime, tz = "UTC")
post$live_open_time <- as.POSIXct(post$live_open_time, tz = "UTC")
post$quote_time <- as.POSIXct(post$quote_time, tz = "UTC")
post$period_group <- ifelse(
  post$game_datetime < as.POSIXct("2026-06-01 00:00:00", tz = "UTC"),
  "development_mar_may",
  "confirmation_jun_jul"
)

live_open <- DBI::dbGetQuery(connection, "
  select q.gameid, s.line, s.odds_over, s.odds_under,
         s.true_odds_over, s.true_odds_under,
         s.odds_timestamp, s.market_status, s.snapshot_id
  from market_postdraft_quotes q
  join market_live_odds_snapshots s
    on s.event_id = q.live_event_id and s.period = q.period
  where q.gameid is not null
    and s.market = 'totals'
    and s.alt_line_id is null
  qualify row_number() over (
    partition by q.gameid
    order by s.odds_timestamp, try_cast(s.line_id as bigint), s.snapshot_id
  ) = 1
")
live_open$odds_timestamp <- as.POSIXct(live_open$odds_timestamp, tz = "UTC")

history <- DBI::dbGetQuery(connection, "
  select q.gameid, q.live_open_time, s.line, s.line_id, s.odds_over,
         s.odds_under, s.true_odds_over, s.true_odds_under,
         s.odds_timestamp, s.snapshot_id
  from market_postdraft_quotes q
  join market_odds_snapshots s
    on s.event_id = q.prematch_event_id and s.period = q.period
  where q.gameid is not null
    and s.market = 'totals'
    and s.alt_line_id is null
    and s.odds_timestamp < q.live_open_time
")
history$live_open_time <- as.POSIXct(history$live_open_time, tz = "UTC")
history$odds_timestamp <- as.POSIXct(history$odds_timestamp, tz = "UTC")
history$lead_seconds <- as.numeric(difftime(
  history$live_open_time,
  history$odds_timestamp,
  units = "secs"
))

select_snapshot <- function(rows, minimum_lead_seconds, opening = FALSE) {
  eligible <- rows$lead_seconds >= minimum_lead_seconds
  data <- rows[eligible, , drop = FALSE]
  if (nrow(data) == 0L) {
    return(data)
  }
  numeric_line_id <- suppressWarnings(as.numeric(data$line_id))
  numeric_line_id[!is.finite(numeric_line_id)] <- -Inf
  order_index <- order(
    data$gameid,
    data$odds_timestamp,
    numeric_line_id,
    data$snapshot_id
  )
  data <- data[order_index, , drop = FALSE]
  if (isTRUE(opening)) {
    data[!duplicated(data$gameid), , drop = FALSE]
  } else {
    data[!duplicated(data$gameid, fromLast = TRUE), , drop = FALSE]
  }
}

opening <- select_snapshot(history, 0, opening = TRUE)
pre_t30 <- select_snapshot(history, 30 * 60)
pre_t15 <- select_snapshot(history, 15 * 60)

quote_columns <- c(
  "gameid", "line", "odds_over", "odds_under", "true_odds_over",
  "true_odds_under"
)
make_quote_variant <- function(rows, timing, timestamp_column) {
  result <- rows[quote_columns]
  result$quote_time_variant <- as.POSIXct(rows[[timestamp_column]], tz = "UTC")
  result$timing <- timing
  result
}
post_variant <- data.frame(
  gameid = post$gameid,
  line = post$line,
  odds_over = post$odds_over,
  odds_under = post$odds_under,
  true_odds_over = post$true_odds_over,
  true_odds_under = post$true_odds_under,
  quote_time_variant = post$quote_time,
  timing = "postdraft_prematch",
  stringsAsFactors = FALSE
)
live_open_variant <- make_quote_variant(
  live_open,
  "live_open",
  "odds_timestamp"
)
quotes <- rbind(
  make_quote_variant(opening, "opening", "odds_timestamp"),
  make_quote_variant(pre_t30, "pre_t30", "odds_timestamp"),
  make_quote_variant(pre_t15, "pre_t15", "odds_timestamp"),
  post_variant,
  live_open_variant
)
target_lines <- live_open[c("gameid", "line")]
names(target_lines)[names(target_lines) == "line"] <- "target_line"
map_fields <- post[c(
  "gameid", "game_datetime", "series_id", "league_canonical",
  "observed_total", "period_group", "freshness_seconds"
)]
map_fields <- merge(map_fields, target_lines, by = "gameid", all = FALSE)
quotes <- merge(quotes, map_fields, by = "gameid", all = FALSE)
quotes$raw_probability_over <- 1 / quotes$odds_over
quotes$raw_probability_under <- 1 / quotes$odds_under
quotes$probability_over <- quotes$raw_probability_over / (
  quotes$raw_probability_over + quotes$raw_probability_under
)

dispersion_training <- DBI::dbGetQuery(connection, "
  select total_kills_game, league_canonical
  from canonical_games
  where target_valid
    and game_datetime < timestamp '2026-03-01 00:00:00'
")
dispersion_fit <- suppressWarnings(MASS::glm.nb(
  total_kills_game ~ league_canonical,
  data = dispersion_training,
  control = stats::glm.control(maxit = 100L)
))
base_theta <- as.numeric(dispersion_fit$theta)

score_quotes <- function(data, distribution, theta, configuration_id) {
  implied_mean <- mapply(
    function(line, probability_over) {
      invert_market_count_mean(
        line,
        probability_over,
        distribution = distribution,
        theta = theta
      )
    },
    data$line,
    data$probability_over
  )
  probability_target_line <- if (distribution == "poisson") {
    stats::ppois(
      floor(data$target_line),
      lambda = implied_mean,
      lower.tail = FALSE
    )
  } else {
    stats::pnbinom(
      floor(data$target_line),
      size = theta,
      mu = implied_mean,
      lower.tail = FALSE
    )
  }
  observed_over_target <- as.numeric(data$observed_total > data$target_line)
  probability_observed <- if (distribution == "poisson") {
    stats::dpois(data$observed_total, lambda = implied_mean)
  } else {
    stats::dnbinom(data$observed_total, size = theta, mu = implied_mean)
  }
  support <- 0:150
  crps <- vapply(seq_len(nrow(data)), function(index) {
    cumulative <- if (distribution == "poisson") {
      stats::ppois(support, lambda = implied_mean[[index]])
    } else {
      stats::pnbinom(support, size = theta, mu = implied_mean[[index]])
    }
    sum((cumulative - as.numeric(support >= data$observed_total[[index]]))^2)
  }, numeric(1L))
  data$configuration_id <- configuration_id
  data$distribution <- distribution
  data$theta <- if (distribution == "poisson") Inf else theta
  data$implied_mean <- implied_mean
  data$probability_over_target_line <- probability_target_line
  data$observed_over_target_line <- observed_over_target
  data$brier <- (probability_target_line - observed_over_target)^2
  data$line_log_loss <- -(
    observed_over_target * log(pmax(probability_target_line, 1e-15)) +
      (1 - observed_over_target) * log(pmax(1 - probability_target_line, 1e-15))
  )
  data$count_log_score <- -log(pmax(probability_observed, 1e-300))
  data$crps <- crps
  data$absolute_error <- abs(data$observed_total - implied_mean)
  data$signed_error <- data$observed_total - implied_mean
  data
}

configurations <- data.frame(
  configuration_id = c("poisson", "nb_0.75", "nb_1.00", "nb_1.25"),
  distribution = c("poisson", rep("negative_binomial", 3)),
  theta = c(NA_real_, base_theta * c(0.75, 1, 1.25)),
  stringsAsFactors = FALSE
)
scored <- do.call(rbind, lapply(seq_len(nrow(configurations)), function(index) {
  configuration <- configurations[index, ]
  score_quotes(
    quotes,
    configuration$distribution,
    configuration$theta,
    configuration$configuration_id
  )
}))

summarize_scores <- function(rows, grouping) {
  formula <- stats::as.formula(paste(
    "cbind(brier, line_log_loss, count_log_score, crps, absolute_error,",
    "signed_error, probability_over_target_line, observed_over_target_line) ~",
    paste(grouping, collapse = " + ")
  ))
  metrics <- aggregate(formula, rows, mean)
  counts <- aggregate(
    stats::as.formula(paste("gameid ~", paste(grouping, collapse = " + "))),
    rows,
    length
  )
  names(counts)[names(counts) == "gameid"] <- "maps"
  result <- merge(metrics, counts, by = grouping)
  result$calibration_error <- abs(
    result$probability_over_target_line - result$observed_over_target_line
  )
  result
}

timing_summary <- summarize_scores(
  scored,
  c("configuration_id", "period_group", "timing")
)
primary <- scored[scored$configuration_id == "nb_1.00", , drop = FALSE]
league_summary <- summarize_scores(
  primary,
  c("period_group", "league_canonical", "timing")
)

paired_bootstrap <- function(rows, pre_timing, post_timing, subset_id) {
  metrics <- c(
    "brier", "line_log_loss", "count_log_score", "crps", "absolute_error"
  )
  pre <- rows[rows$timing == pre_timing, c(
    "gameid", "series_id", "line", "target_line", metrics
  )]
  post_rows <- rows[rows$timing == post_timing, c("gameid", metrics)]
  comparison <- merge(
    pre,
    post_rows,
    by = "gameid",
    suffixes = c("_pre", "_post")
  )
  if (subset_id == "same_line") {
    comparison <- comparison[comparison$line == comparison$target_line, , drop = FALSE]
  }
  if (nrow(comparison) == 0L) {
    return(data.frame())
  }
  comparison$block <- ifelse(
    is.na(comparison$series_id) | !nzchar(comparison$series_id),
    comparison$gameid,
    comparison$series_id
  )
  blocks <- split(seq_len(nrow(comparison)), comparison$block)
  set.seed(20260805 + nrow(comparison))
  results <- lapply(metrics, function(metric) {
    differences <- comparison[[paste0(metric, "_post")]] -
      comparison[[paste0(metric, "_pre")]]
    draws <- replicate(2000L, {
      sampled_blocks <- sample(names(blocks), length(blocks), replace = TRUE)
      indices <- unlist(blocks[sampled_blocks], use.names = FALSE)
      mean(differences[indices])
    })
    data.frame(
      pre_timing = pre_timing,
      post_timing = post_timing,
      subset_id = subset_id,
      metric = metric,
      maps = nrow(comparison),
      mean_pre = mean(comparison[[paste0(metric, "_pre")]]),
      mean_post = mean(comparison[[paste0(metric, "_post")]]),
      mean_difference_post_minus_pre = mean(differences),
      relative_improvement = -mean(differences) /
        mean(comparison[[paste0(metric, "_pre")]]),
      lower_95 = unname(stats::quantile(draws, 0.025)),
      upper_95 = unname(stats::quantile(draws, 0.975)),
      probability_post_better = mean(draws < 0),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, results)
}

bootstrap_rows <- list()
bootstrap_index <- 1L
for (period in unique(primary$period_group)) {
  period_rows <- primary[primary$period_group == period, , drop = FALSE]
  for (pre_timing in c("opening", "pre_t30", "pre_t15", "postdraft_prematch")) {
    for (subset_id in c("all", "same_line")) {
      result <- paired_bootstrap(
        period_rows,
        pre_timing,
        "live_open",
        subset_id
      )
      if (nrow(result) > 0L) {
        result$period_group <- period
        bootstrap_rows[[bootstrap_index]] <- result
        bootstrap_index <- bootstrap_index + 1L
      }
    }
  }
}
paired_bootstrap_results <- do.call(rbind, bootstrap_rows)

freshness_filters <- list(
  all = function(rows) rep(TRUE, nrow(rows)),
  within_300_seconds = function(rows) rows$freshness_seconds <= 300,
  within_60_seconds = function(rows) rows$freshness_seconds <= 60
)
freshness_bootstrap_rows <- list()
freshness_bootstrap_index <- 1L
for (period in unique(primary$period_group)) {
  period_rows <- primary[primary$period_group == period, , drop = FALSE]
  for (filter_id in names(freshness_filters)) {
    keep <- freshness_filters[[filter_id]](period_rows)
    filtered <- period_rows[!is.na(keep) & keep, , drop = FALSE]
    result <- paired_bootstrap(
      filtered,
      "pre_t15",
      "live_open",
      "all"
    )
    result$period_group <- period
    result$freshness_filter <- filter_id
    freshness_bootstrap_rows[[freshness_bootstrap_index]] <- result
    freshness_bootstrap_index <- freshness_bootstrap_index + 1L
  }
}
freshness_bootstrap <- do.call(rbind, freshness_bootstrap_rows)

robustness_rows <- list()
robustness_index <- 1L
for (configuration_id in unique(scored$configuration_id)) {
  configuration_rows <- scored[
    scored$configuration_id == configuration_id,
    ,
    drop = FALSE
  ]
  for (period in unique(configuration_rows$period_group)) {
    period_rows <- configuration_rows[
      configuration_rows$period_group == period,
      ,
      drop = FALSE
    ]
    for (filter_id in names(freshness_filters)) {
      keep <- freshness_filters[[filter_id]](period_rows)
      filtered <- period_rows[!is.na(keep) & keep, , drop = FALSE]
      pre_rows <- filtered[
        filtered$timing == "pre_t15",
        c("gameid", "brier", "line_log_loss", "count_log_score", "crps", "absolute_error")
      ]
      live_rows <- filtered[
        filtered$timing == "live_open",
        c("gameid", "brier", "line_log_loss", "count_log_score", "crps", "absolute_error")
      ]
      comparison <- merge(
        pre_rows,
        live_rows,
        by = "gameid",
        suffixes = c("_pre", "_live")
      )
      for (metric in c(
        "brier", "line_log_loss", "count_log_score", "crps", "absolute_error"
      )) {
        pre_value <- comparison[[paste0(metric, "_pre")]]
        live_value <- comparison[[paste0(metric, "_live")]]
        robustness_rows[[robustness_index]] <- data.frame(
          configuration_id = configuration_id,
          period_group = period,
          freshness_filter = filter_id,
          metric = metric,
          maps = nrow(comparison),
          mean_pre = mean(pre_value),
          mean_live = mean(live_value),
          relative_improvement = (mean(pre_value) - mean(live_value)) /
            mean(pre_value),
          stringsAsFactors = FALSE
        )
        robustness_index <- robustness_index + 1L
      }
    }
  }
}
robustness_summary <- do.call(rbind, robustness_rows)

league_comparison <- merge(
  primary[primary$timing == "pre_t15", c(
    "gameid", "period_group", "league_canonical", "brier",
    "line_log_loss", "count_log_score", "crps", "absolute_error"
  )],
  primary[primary$timing == "live_open", c(
    "gameid", "brier", "line_log_loss", "count_log_score", "crps",
    "absolute_error"
  )],
  by = "gameid",
  suffixes = c("_pre", "_live")
)
league_difference_rows <- list()
league_difference_index <- 1L
for (period in unique(league_comparison$period_group)) {
  for (league in unique(league_comparison$league_canonical)) {
    rows <- league_comparison[
      league_comparison$period_group == period &
        league_comparison$league_canonical == league,
      ,
      drop = FALSE
    ]
    if (nrow(rows) == 0L) {
      next
    }
    for (metric in c(
      "brier", "line_log_loss", "count_log_score", "crps", "absolute_error"
    )) {
      pre_value <- rows[[paste0(metric, "_pre")]]
      live_value <- rows[[paste0(metric, "_live")]]
      league_difference_rows[[league_difference_index]] <- data.frame(
        period_group = period,
        league_canonical = league,
        metric = metric,
        maps = nrow(rows),
        mean_pre = mean(pre_value),
        mean_live = mean(live_value),
        relative_improvement = (mean(pre_value) - mean(live_value)) /
          mean(pre_value),
        stringsAsFactors = FALSE
      )
      league_difference_index <- league_difference_index + 1L
    }
  }
}
league_differences <- do.call(rbind, league_difference_rows)

primary_wide <- merge(
  primary[primary$timing == "pre_t15", c(
    "gameid", "period_group", "league_canonical", "observed_total",
    "line", "implied_mean", "probability_over_target_line", "brier",
    "line_log_loss", "freshness_seconds"
  )],
  primary[primary$timing == "live_open", c(
    "gameid", "line", "implied_mean", "probability_over_target_line",
    "brier", "line_log_loss"
  )],
  by = "gameid",
  suffixes = c("_pre", "_post")
)
primary_wide$line_delta <- primary_wide$line_post - primary_wide$line_pre
primary_wide$mean_delta <- primary_wide$implied_mean_post -
  primary_wide$implied_mean_pre
primary_wide$pre_residual <- primary_wide$observed_total -
  primary_wide$implied_mean_pre
nonzero_movement <- primary_wide$mean_delta != 0
movement_summary <- do.call(rbind, lapply(
  split(primary_wide, primary_wide$period_group),
  function(rows) {
    moved <- rows$mean_delta != 0
    data.frame(
      period_group = rows$period_group[[1L]],
      maps = nrow(rows),
      share_line_changed = mean(rows$line_delta != 0),
      mean_absolute_line_change = mean(abs(rows$line_delta)),
      mean_absolute_implied_mean_change = mean(abs(rows$mean_delta)),
      correlation_movement_with_pre_residual = stats::cor(
        rows$mean_delta,
        rows$pre_residual
      ),
      directional_accuracy_when_moved = mean(
        sign(rows$mean_delta[moved]) == sign(rows$pre_residual[moved])
      ),
      share_post_mean_closer_to_outcome = mean(
        abs(rows$observed_total - rows$implied_mean_post) <
          abs(rows$observed_total - rows$implied_mean_pre)
      ),
      stringsAsFactors = FALSE
    )
  }
))

weekly_path <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "directed-market-regime-calibration",
  "weekly_base_predictions.rds"
)
weekly <- readRDS(weekly_path)
weekly <- weekly[!duplicated(weekly$gameid), c(
  "gameid", "base_mean", "base_theta", "weekly_cutoff"
)]
model_data <- merge(
  merge(
    post[c(
      "gameid", "series_id", "game_datetime", "league_canonical",
      "observed_total", "period_group", "freshness_seconds"
    )],
    live_open[c("gameid", "line", "odds_over", "odds_under")],
    by = "gameid",
    all = FALSE
  ),
  weekly,
  by = "gameid",
  all = FALSE
)
model_data$market_probability_over <- (1 / model_data$odds_over) / (
  (1 / model_data$odds_over) + (1 / model_data$odds_under)
)
model_data$market_mean <- mapply(
  function(line, probability_over, theta) {
    invert_market_count_mean(
      line,
      probability_over,
      distribution = "negative_binomial",
      theta = theta
    )
  },
  model_data$line,
  model_data$market_probability_over,
  model_data$base_theta
)

score_model_mean <- function(data, mean_value, candidate_id, weight) {
  probability_over <- stats::pnbinom(
    floor(data$line),
    size = data$base_theta,
    mu = mean_value,
    lower.tail = FALSE
  )
  observed_over <- as.numeric(data$observed_total > data$line)
  probability_observed <- stats::dnbinom(
    data$observed_total,
    size = data$base_theta,
    mu = mean_value
  )
  support <- 0:150
  crps <- vapply(seq_len(nrow(data)), function(index) {
    cumulative <- stats::pnbinom(
      support,
      size = data$base_theta[[index]],
      mu = mean_value[[index]]
    )
    sum((cumulative - as.numeric(support >= data$observed_total[[index]]))^2)
  }, numeric(1L))
  data.frame(
    gameid = data$gameid,
    series_id = data$series_id,
    game_datetime = data$game_datetime,
    league_canonical = data$league_canonical,
    period_group = data$period_group,
    candidate_id = candidate_id,
    directed_weight = weight,
    predicted_mean = mean_value,
    probability_over_target_line = probability_over,
    observed_over_target_line = observed_over,
    brier = (probability_over - observed_over)^2,
    line_log_loss = -(
      observed_over * log(pmax(probability_over, 1e-15)) +
        (1 - observed_over) * log(pmax(1 - probability_over, 1e-15))
    ),
    count_log_score = -log(pmax(probability_observed, 1e-300)),
    crps = crps,
    absolute_error = abs(data$observed_total - mean_value),
    signed_error = data$observed_total - mean_value,
    stringsAsFactors = FALSE
  )
}

weights <- seq(0, 1, by = 0.1)
model_predictions <- do.call(rbind, lapply(weights, function(weight) {
  mean_value <- exp(
    (1 - weight) * log(model_data$market_mean) +
      weight * log(model_data$base_mean)
  )
  score_model_mean(
    model_data,
    mean_value,
    sprintf("post_market_directed_w%.1f", weight),
    weight
  )
}))
model_summary <- summarize_scores(
  model_predictions,
  c("period_group", "candidate_id", "directed_weight")
)
development_model <- model_summary[
  model_summary$period_group == "development_mar_may",
  ,
  drop = FALSE
]
selected_weight <- development_model$directed_weight[[which.min(
  development_model$line_log_loss
)]]

bootstrap_model_comparison <- function(rows, candidate_weight, baseline_weight) {
  metrics <- c(
    "brier", "line_log_loss", "count_log_score", "crps", "absolute_error"
  )
  candidate <- rows[rows$directed_weight == candidate_weight, ]
  baseline <- rows[rows$directed_weight == baseline_weight, ]
  comparison <- merge(
    baseline[c("gameid", "series_id", metrics)],
    candidate[c("gameid", metrics)],
    by = "gameid",
    suffixes = c("_baseline", "_candidate")
  )
  comparison$block <- ifelse(
    is.na(comparison$series_id) | !nzchar(comparison$series_id),
    comparison$gameid,
    comparison$series_id
  )
  blocks <- split(seq_len(nrow(comparison)), comparison$block)
  set.seed(20260806 + round(candidate_weight * 10) + round(baseline_weight * 100))
  do.call(rbind, lapply(metrics, function(metric) {
    differences <- comparison[[paste0(metric, "_candidate")]] -
      comparison[[paste0(metric, "_baseline")]]
    draws <- replicate(2000L, {
      sampled_blocks <- sample(names(blocks), length(blocks), replace = TRUE)
      indices <- unlist(blocks[sampled_blocks], use.names = FALSE)
      mean(differences[indices])
    })
    data.frame(
      candidate_weight = candidate_weight,
      baseline_weight = baseline_weight,
      metric = metric,
      maps = nrow(comparison),
      mean_difference_candidate_minus_baseline = mean(differences),
      lower_95 = unname(stats::quantile(draws, 0.025)),
      upper_95 = unname(stats::quantile(draws, 0.975)),
      probability_candidate_better = mean(draws < 0),
      stringsAsFactors = FALSE
    )
  }))
}

confirmation_predictions <- model_predictions[
  model_predictions$period_group == "confirmation_jun_jul",
  ,
  drop = FALSE
]
model_bootstrap <- rbind(
  transform(
    bootstrap_model_comparison(
      confirmation_predictions,
      selected_weight,
      0
    ),
    comparison = "selected_blend_vs_post_market"
  ),
  transform(
    bootstrap_model_comparison(
      confirmation_predictions,
      selected_weight,
      1
    ),
    comparison = "selected_blend_vs_directed"
  ),
  transform(
    bootstrap_model_comparison(
      confirmation_predictions,
      1,
      0
    ),
    comparison = "directed_vs_post_market"
  )
)

utils::write.csv(
  timing_summary,
  file.path(output_dir, "market-timing-metrics.csv"),
  row.names = FALSE
)
utils::write.csv(
  paired_bootstrap_results,
  file.path(output_dir, "paired-bootstrap-pre-vs-post.csv"),
  row.names = FALSE
)
utils::write.csv(
  league_summary,
  file.path(output_dir, "market-timing-by-league.csv"),
  row.names = FALSE
)
utils::write.csv(
  movement_summary,
  file.path(output_dir, "market-movement-summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  freshness_bootstrap,
  file.path(output_dir, "freshness-sensitivity-bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  robustness_summary,
  file.path(output_dir, "dispersion-and-freshness-robustness.csv"),
  row.names = FALSE
)
utils::write.csv(
  league_differences,
  file.path(output_dir, "pre-vs-live-by-league.csv"),
  row.names = FALSE
)
utils::write.csv(
  model_summary,
  file.path(output_dir, "post-market-model-blend-summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  model_bootstrap,
  file.path(output_dir, "post-market-model-blend-bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  data.frame(
    dispersion_training_maps = nrow(dispersion_training),
    base_theta = base_theta,
    postdraft_maps = nrow(post),
    live_open_maps = nrow(live_open),
    opening_maps = length(unique(opening$gameid)),
    pre_t30_maps = length(unique(pre_t30$gameid)),
    pre_t15_maps = length(unique(pre_t15$gameid)),
    model_intersection_maps = nrow(model_data),
    selected_directed_weight = selected_weight
  ),
  file.path(output_dir, "experiment-summary.csv"),
  row.names = FALSE
)

print(data.frame(
  dispersion_training_maps = nrow(dispersion_training),
  base_theta = base_theta,
  postdraft_maps = nrow(post),
  live_open_maps = nrow(live_open),
  pre_t15_maps = length(unique(pre_t15$gameid)),
  model_intersection_maps = nrow(model_data),
  selected_directed_weight = selected_weight
))
print(timing_summary[
  timing_summary$configuration_id == "nb_1.00" &
  timing_summary$timing %in% c(
    "pre_t15", "postdraft_prematch", "live_open"
  ),
])
print(paired_bootstrap_results[
    paired_bootstrap_results$pre_timing %in% c(
      "pre_t15", "postdraft_prematch"
    ) &
    paired_bootstrap_results$subset_id == "all",
])
print(movement_summary)
print(model_summary[
  model_summary$directed_weight %in% unique(c(0, 1, selected_weight)),
])
print(model_bootstrap)
