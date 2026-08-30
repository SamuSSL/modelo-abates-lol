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
  "pinnacle-market-anchored-model"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

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

post <- DBI::dbGetQuery(connection, "
  select q.*, g.game_datetime, g.series_id, g.total_kills_game,
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

live_open <- DBI::dbGetQuery(connection, "
  select q.gameid, s.line, s.odds_over, s.odds_under,
         s.true_odds_over, s.true_odds_under, s.odds_timestamp,
         s.market_status, s.snapshot_id
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
live_open$odds_timestamp <- as.POSIXct(
  live_open$odds_timestamp,
  tz = "UTC"
)

history <- DBI::dbGetQuery(connection, "
  select q.gameid, q.live_open_time, s.line, s.line_id,
         s.odds_over, s.odds_under, s.true_odds_over,
         s.true_odds_under, s.odds_timestamp, s.snapshot_id
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
history_t15 <- history[history$lead_seconds >= 15 * 60, , drop = FALSE]
history_t15 <- history_t15[order(
  history_t15$gameid,
  history_t15$odds_timestamp,
  suppressWarnings(as.numeric(history_t15$line_id)),
  history_t15$snapshot_id
), , drop = FALSE]
history_t15 <- history_t15[
  !duplicated(history_t15$gameid, fromLast = TRUE),
  ,
  drop = FALSE
]

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
market_theta <- as.numeric(dispersion_fit$theta)

all_maps <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "premap_ratio_map_features_t15.rds"
))
all_maps$game_datetime <- as.POSIXct(all_maps$game_datetime, tz = "UTC")
all_maps$prediction_cutoff <- as.POSIXct(
  all_maps$prediction_cutoff,
  tz = "UTC"
)
target_ids <- intersect(post$gameid, live_open$gameid)
target_maps <- all_maps[all_maps$gameid %in% target_ids, , drop = FALSE]
if (nrow(target_maps) != length(target_ids)) {
  stop(
    sprintf(
      "Cobertura estrutural incompleta: %d de %d mapas.",
      nrow(target_maps),
      length(target_ids)
    ),
    call. = FALSE
  )
}

previous_saturday <- function(datetime) {
  date <- as.Date(datetime, tz = "UTC")
  weekday <- as.POSIXlt(date, tz = "UTC")$wday
  offset <- (weekday - 6L) %% 7L
  as.POSIXct(date - offset, tz = "UTC")
}

target_maps$weekly_cutoff <- previous_saturday(target_maps$game_datetime)
structural_path <- file.path(output_dir, "structural-weekly-predictions.rds")
progress_path <- file.path(output_dir, "structural-weekly-progress.rds")
evaluation <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation$directed_moneyline_joint_round

prediction_rows <- list()
completed_cutoffs <- as.POSIXct(character(), tz = "UTC")
universe_fingerprint <- digest::digest(
  list(
    target_leagues = canonical_target_leagues(),
    gameids = sort(as.character(all_maps$gameid)),
    last_game = max(all_maps$game_datetime)
  ),
  algo = "sha256"
)
if (file.exists(progress_path)) {
  progress <- readRDS(progress_path)
  if (
    !is.null(progress$universe_fingerprint) &&
      identical(progress$universe_fingerprint, universe_fingerprint)
  ) {
    prediction_rows <- progress$rows
    completed_cutoffs <- as.POSIXct(progress$completed_cutoffs, tz = "UTC")
  } else {
    message("Universo alterado; previsoes semanais serao recalculadas.")
  }
}

weekly_cutoffs <- sort(unique(target_maps$weekly_cutoff))
development_start <- as.POSIXct(
  round_config$development_start,
  tz = "UTC"
)
half_life <- as.numeric(round_config$observation_half_life_days)
alpha <- as.numeric(round_config$regularization_alpha)
inner_fraction <- as.numeric(
  round_config$inner_temporal_validation_fraction
)
prediction_seed <- as.integer(round_config$prediction_seed)

for (cutoff_value in weekly_cutoffs) {
  cutoff <- as.POSIXct(cutoff_value, origin = "1970-01-01", tz = "UTC")
  if (cutoff %in% completed_cutoffs) {
    next
  }
  validation <- target_maps[
    target_maps$weekly_cutoff == cutoff,
    ,
    drop = FALSE
  ]
  train <- all_maps[
    all_maps$game_datetime >= development_start &
      all_maps$prediction_cutoff < cutoff,
    ,
    drop = FALSE
  ]
  weights <- 0.5^(
    as.numeric(difftime(
      cutoff,
      train$prediction_cutoff,
      units = "days"
    )) / half_life
  )
  message(sprintf(
    "Semana %s: treino=%d, previsoes=%d",
    format(cutoff, "%Y-%m-%d", tz = "UTC"),
    nrow(train),
    nrow(validation)
  ))
  fit <- fit_directed_joint_fundamental(
    train,
    windows = c("season", "last15"),
    alpha = alpha,
    weights = weights,
    inner_fraction = inner_fraction,
    dispersion_mode = "global",
    seed = prediction_seed
  )
  predictions <- predict_directed_joint_fundamental(
    fit,
    validation,
    draws = 1000L,
    seed = prediction_seed
  )
  batch <- lapply(seq_len(nrow(validation)), function(index) {
    data.frame(
      gameid = as.character(validation$gameid[[index]]),
      series_id = as.character(validation$series_id[[index]]),
      game_datetime = as.POSIXct(
        validation$game_datetime[[index]],
        tz = "UTC"
      ),
      weekly_cutoff = cutoff,
      league_canonical = as.character(
        validation$league_canonical[[index]]
      ),
      map_number = as.integer(validation$map_number[[index]]),
      structural_mean = as.numeric(predictions[[index]]$mean),
      structural_theta = as.numeric(predictions[[index]]$theta),
      structural_duration_mean = as.numeric(
        predictions[[index]]$duration_mean
      ),
      structural_intensity_mean = as.numeric(
        predictions[[index]]$blue_rate + predictions[[index]]$red_rate
      ),
      training_maps = as.integer(fit$training_maps),
      stringsAsFactors = FALSE
    )
  })
  prediction_rows[[length(prediction_rows) + 1L]] <- do.call(rbind, batch)
  completed_cutoffs <- c(completed_cutoffs, cutoff)
  saveRDS(
    list(
      rows = prediction_rows,
      completed_cutoffs = completed_cutoffs,
      universe_fingerprint = universe_fingerprint
    ),
    progress_path,
    version = 3L
  )
}

structural <- do.call(rbind, prediction_rows)
structural <- structural[!duplicated(structural$gameid), , drop = FALSE]
structural <- structural[structural$gameid %in% target_ids, , drop = FALSE]
if (nrow(structural) != length(target_ids)) {
  stop(
    sprintf(
      "Previsoes estruturais incompletas: %d de %d mapas.",
      nrow(structural),
      length(target_ids)
    ),
    call. = FALSE
  )
}
if (any(structural$weekly_cutoff >= structural$game_datetime)) {
  stop("Cutoff estrutural invalido.", call. = FALSE)
}
saveRDS(structural, structural_path, version = 3L)
utils::write.csv(
  structural,
  file.path(output_dir, "structural-weekly-predictions.csv"),
  row.names = FALSE
)

no_vig_over <- function(over_odds, under_odds) {
  over_raw <- 1 / as.numeric(over_odds)
  under_raw <- 1 / as.numeric(under_odds)
  over_raw / (over_raw + under_raw)
}

live_fields <- live_open[c(
  "gameid", "line", "odds_over", "odds_under", "odds_timestamp"
)]
names(live_fields) <- c(
  "gameid", "live_line", "live_odds_over", "live_odds_under",
  "live_quote_time"
)
t15_fields <- history_t15[c(
  "gameid", "line", "odds_over", "odds_under", "odds_timestamp"
)]
names(t15_fields) <- c(
  "gameid", "t15_line", "t15_odds_over", "t15_odds_under",
  "t15_quote_time"
)
base <- post[c(
  "gameid", "series_id", "game_datetime", "league_canonical",
  "period", "live_open_time", "total_kills_game"
)]
base <- merge(base, live_fields, by = "gameid", all = FALSE)
base <- merge(base, t15_fields, by = "gameid", all = FALSE)
base <- merge(
  base,
  structural[c(
    "gameid", "weekly_cutoff", "map_number", "structural_mean",
    "structural_theta", "structural_duration_mean",
    "structural_intensity_mean", "training_maps"
  )],
  by = "gameid",
  all = FALSE
)
base$market_probability_over <- no_vig_over(
  base$live_odds_over,
  base$live_odds_under
)
base$t15_probability_over <- no_vig_over(
  base$t15_odds_over,
  base$t15_odds_under
)
base$market_overround <- 1 / base$live_odds_over +
  1 / base$live_odds_under - 1
base$market_mean <- mapply(
  function(line, probability) {
    invert_market_count_mean(
      line,
      probability,
      distribution = "negative_binomial",
      theta = market_theta
    )
  },
  base$live_line,
  base$market_probability_over
)
base$t15_market_mean <- mapply(
  function(line, probability) {
    invert_market_count_mean(
      line,
      probability,
      distribution = "negative_binomial",
      theta = market_theta
    )
  },
  base$t15_line,
  base$t15_probability_over
)
base$mean_delta <- base$market_mean - base$t15_market_mean
base$absolute_mean_delta <- abs(base$mean_delta)
base$line_delta <- base$live_line - base$t15_line
base$log_ratio_structural_market <- log(
  base$structural_mean / base$market_mean
)
base$structural_disagreement <- base$structural_mean - base$market_mean
base$absolute_structural_disagreement <- abs(
  base$structural_disagreement
)
base$movement_toward_structural <- ifelse(
  base$mean_delta == 0,
  "no_move",
  ifelse(
    sign(base$mean_delta) ==
      sign(base$structural_mean - base$t15_market_mean),
    "toward_structural",
    "away_from_structural"
  )
)
base$live_delay_seconds <- as.numeric(difftime(
  base$live_quote_time,
  base$live_open_time,
  units = "secs"
))
base$map_group <- ifelse(base$map_number >= 4L, "4_plus", base$map_number)
base$map_number_capped <- pmin(4L, as.integer(base$map_number))
base$sample <- ifelse(
  base$game_datetime < as.POSIXct("2026-05-01", tz = "UTC"),
  "adjustment_mar_apr",
  ifelse(
    base$game_datetime < as.POSIXct("2026-06-01", tz = "UTC"),
    "selection_may",
    "confirmation_jun_jul"
  )
)
base$league_canonical <- factor(base$league_canonical)
base$map_group <- factor(base$map_group)
base$observed_total <- as.integer(base$total_kills_game)

required_complete <- c(
  "observed_total", "live_line", "market_mean", "t15_market_mean",
  "structural_mean", "structural_theta", "mean_delta",
  "absolute_mean_delta", "log_ratio_structural_market",
  "live_delay_seconds"
)
base <- base[stats::complete.cases(base[required_complete]), , drop = FALSE]
saveRDS(base, file.path(output_dir, "research-dataset.rds"), version = 3L)
utils::write.csv(
  base,
  file.path(output_dir, "research-dataset.csv"),
  row.names = FALSE
)

score_means <- function(data, means, theta, candidate_id) {
  means <- pmax(0.1, as.numeric(means))
  theta <- rep(as.numeric(theta), length.out = nrow(data))
  probability_over <- stats::pnbinom(
    floor(data$live_line),
    size = theta,
    mu = means,
    lower.tail = FALSE
  )
  observed_over <- as.numeric(data$observed_total > data$live_line)
  observed_probability <- stats::dnbinom(
    data$observed_total,
    size = theta,
    mu = means
  )
  support <- 0:150
  crps <- vapply(seq_len(nrow(data)), function(index) {
    cumulative <- stats::pnbinom(
      support,
      size = theta[[index]],
      mu = means[[index]]
    )
    sum((cumulative - as.numeric(
      support >= data$observed_total[[index]]
    ))^2)
  }, numeric(1L))
  data.frame(
    gameid = as.character(data$gameid),
    series_id = as.character(data$series_id),
    sample = as.character(data$sample),
    candidate_id = candidate_id,
    predicted_mean = means,
    theta = theta,
    probability_over = probability_over,
    observed_over = observed_over,
    brier = (probability_over - observed_over)^2,
    line_log_loss = -(
      observed_over * log(pmax(probability_over, 1e-15)) +
        (1 - observed_over) * log(pmax(1 - probability_over, 1e-15))
    ),
    count_log_score = -log(pmax(observed_probability, 1e-300)),
    crps = crps,
    absolute_error = abs(data$observed_total - means),
    signed_error = data$observed_total - means,
    stringsAsFactors = FALSE
  )
}

summarize_scores <- function(scores) {
  metrics <- stats::aggregate(
    cbind(
      brier, line_log_loss, count_log_score, crps, absolute_error,
      signed_error, probability_over, observed_over
    ) ~ candidate_id,
    scores,
    mean
  )
  counts <- stats::aggregate(gameid ~ candidate_id, scores, length)
  names(counts)[names(counts) == "gameid"] <- "maps"
  result <- merge(metrics, counts, by = "candidate_id")
  result$calibration_gap <- result$probability_over - result$observed_over
  result
}

candidate_complexity <- c(
  pinnacle_live = 0L,
  structural = 1L,
  blend_w0.1 = 1L,
  blend_w0.2 = 1L,
  blend_w0.3 = 1L,
  blend_w0.4 = 1L,
  blend_w0.5 = 1L,
  blend_w0.6 = 1L,
  blend_w0.7 = 1L,
  blend_w0.8 = 1L,
  blend_w0.9 = 1L,
  residual_simple = 2L,
  residual_movement = 3L,
  residual_context = 4L
)

residual_formulas <- list(
  residual_simple = stats::as.formula(
    "observed_total ~ log_ratio_structural_market + offset(log(market_mean))"
  ),
  residual_movement = stats::as.formula(paste(
    "observed_total ~ log_ratio_structural_market + mean_delta +",
    "absolute_mean_delta + offset(log(market_mean))"
  )),
  residual_context = stats::as.formula(paste(
    "observed_total ~ log_ratio_structural_market + mean_delta +",
    "absolute_mean_delta + league_canonical + map_number_capped +",
    "offset(log(market_mean))"
  ))
)

fit_residual <- function(candidate_id, train) {
  league_counts <- sort(table(as.character(train$league_canonical)), decreasing = TRUE)
  fallback_league <- names(league_counts)[[1L]]
  train$league_canonical <- stats::relevel(
    factor(as.character(train$league_canonical)),
    ref = fallback_league
  )
  fit <- suppressWarnings(MASS::glm.nb(
    residual_formulas[[candidate_id]],
    data = train,
    control = stats::glm.control(maxit = 100L)
  ))
  attr(fit, "fallback_league") <- fallback_league
  fit
}

predict_candidate <- function(candidate_id, train, new_data) {
  if (candidate_id == "pinnacle_live") {
    return(list(mean = new_data$market_mean, theta = market_theta, fit = NULL))
  }
  if (candidate_id == "structural") {
    return(list(
      mean = new_data$structural_mean,
      theta = new_data$structural_theta,
      fit = NULL
    ))
  }
  if (grepl("^blend_w", candidate_id)) {
    weight <- as.numeric(sub("blend_w", "", candidate_id))
    blended_mean <- exp(
      (1 - weight) * log(new_data$market_mean) +
        weight * log(new_data$structural_mean)
    )
    return(list(mean = blended_mean, theta = market_theta, fit = NULL))
  }
  fit <- fit_residual(candidate_id, train)
  if ("league_canonical" %in% names(new_data)) {
    fallback_league <- attr(fit, "fallback_league")
    league_values <- as.character(new_data$league_canonical)
    known_levels <- fit$xlevels$league_canonical
    league_values[!league_values %in% known_levels] <- fallback_league
    new_data$league_canonical <- factor(
      league_values,
      levels = known_levels
    )
  }
  list(
    mean = as.numeric(stats::predict(fit, newdata = new_data, type = "response")),
    theta = as.numeric(fit$theta),
    fit = fit
  )
}

adjustment <- base[base$sample == "adjustment_mar_apr", , drop = FALSE]
selection <- base[base$sample == "selection_may", , drop = FALSE]
confirmation <- base[
  base$sample == "confirmation_jun_jul",
  ,
  drop = FALSE
]

candidate_ids <- names(candidate_complexity)
selection_scores <- list()
selection_fits <- list()
for (candidate_id in candidate_ids) {
  prediction <- predict_candidate(candidate_id, adjustment, selection)
  selection_scores[[candidate_id]] <- score_means(
    selection,
    prediction$mean,
    prediction$theta,
    candidate_id
  )
  selection_fits[[candidate_id]] <- prediction$fit
}
selection_scores <- do.call(rbind, selection_scores)
selection_summary <- summarize_scores(selection_scores)
selection_summary$complexity <- as.integer(
  candidate_complexity[selection_summary$candidate_id]
)
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
eligible$within_crps_tolerance <- eligible$crps <= best_crps * 1.0025
winner_pool <- eligible[eligible$within_crps_tolerance, , drop = FALSE]
winner_pool <- winner_pool[order(
  winner_pool$complexity,
  winner_pool$crps,
  winner_pool$count_log_score
), , drop = FALSE]
selected_candidate <- winner_pool$candidate_id[[1L]]

nonmarket <- eligible[eligible$candidate_id != "pinnacle_live", , drop = FALSE]
nonmarket_best_crps <- min(nonmarket$crps)
nonmarket$within_crps_tolerance <- nonmarket$crps <=
  nonmarket_best_crps * 1.0025
nonmarket_pool <- nonmarket[
  nonmarket$within_crps_tolerance,
  ,
  drop = FALSE
]
nonmarket_pool <- nonmarket_pool[order(
  nonmarket_pool$complexity,
  nonmarket_pool$crps,
  nonmarket_pool$count_log_score
), , drop = FALSE]
selected_nonmarket <- nonmarket_pool$candidate_id[[1L]]

development <- rbind(adjustment, selection)
confirmation_ids <- unique(c(
  "pinnacle_live",
  "structural",
  selected_candidate,
  selected_nonmarket
))
confirmation_scores <- list()
confirmation_fits <- list()
for (candidate_id in confirmation_ids) {
  prediction <- predict_candidate(candidate_id, development, confirmation)
  confirmation_scores[[candidate_id]] <- score_means(
    confirmation,
    prediction$mean,
    prediction$theta,
    candidate_id
  )
  confirmation_fits[[candidate_id]] <- prediction$fit
}
confirmation_scores <- do.call(rbind, confirmation_scores)
confirmation_summary <- summarize_scores(confirmation_scores)
confirmation_summary$selected_overall <-
  confirmation_summary$candidate_id == selected_candidate
confirmation_summary$selected_nonmarket <-
  confirmation_summary$candidate_id == selected_nonmarket

paired_bootstrap <- function(scores, candidate_id, baseline_id) {
  metrics <- c(
    "brier", "line_log_loss", "count_log_score", "crps",
    "absolute_error"
  )
  candidate <- scores[scores$candidate_id == candidate_id, ]
  baseline <- scores[scores$candidate_id == baseline_id, ]
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
  set.seed(20260807 + nchar(candidate_id) + nchar(baseline_id))
  do.call(rbind, lapply(metrics, function(metric) {
    difference <- comparison[[paste0(metric, "_candidate")]] -
      comparison[[paste0(metric, "_baseline")]]
    draws <- replicate(2000L, {
      sampled_blocks <- sample(names(blocks), length(blocks), replace = TRUE)
      indices <- unlist(blocks[sampled_blocks], use.names = FALSE)
      mean(difference[indices])
    })
    data.frame(
      candidate_id = candidate_id,
      baseline_id = baseline_id,
      metric = metric,
      maps = nrow(comparison),
      mean_difference_candidate_minus_baseline = mean(difference),
      relative_improvement = -mean(difference) /
        mean(comparison[[paste0(metric, "_baseline")]]),
      lower_95 = unname(stats::quantile(draws, 0.025)),
      upper_95 = unname(stats::quantile(draws, 0.975)),
      probability_candidate_better = mean(draws < 0),
      stringsAsFactors = FALSE
    )
  }))
}

bootstrap_comparisons <- unique(rbind(
  data.frame(candidate = selected_candidate, baseline = "pinnacle_live"),
  data.frame(candidate = selected_nonmarket, baseline = "pinnacle_live"),
  data.frame(candidate = selected_nonmarket, baseline = "structural"),
  data.frame(candidate = "pinnacle_live", baseline = "structural")
))
bootstrap_results <- do.call(rbind, lapply(
  seq_len(nrow(bootstrap_comparisons)),
  function(index) {
    paired_bootstrap(
      confirmation_scores,
      bootstrap_comparisons$candidate[[index]],
      bootstrap_comparisons$baseline[[index]]
    )
  }
))

development$absolute_disagreement_band <- ifelse(
  development$absolute_structural_disagreement >= stats::quantile(
    development$absolute_structural_disagreement,
    0.75
  ),
  "high_disagreement",
  "normal_disagreement"
)
disagreement_cut <- stats::quantile(
  development$absolute_structural_disagreement,
  0.75
)
movement_cut <- stats::quantile(
  development$absolute_mean_delta,
  0.75
)
confirmation$absolute_disagreement_band <- ifelse(
  confirmation$absolute_structural_disagreement >= disagreement_cut,
  "high_disagreement",
  "normal_disagreement"
)
confirmation$movement_band <- ifelse(
  confirmation$absolute_mean_delta >= movement_cut,
  "large_movement",
  "normal_movement"
)
confirmation$freshness_band <- ifelse(
  confirmation$live_delay_seconds <= 60,
  "within_60_seconds",
  "over_60_seconds"
)

candidate_filter_scores <- confirmation_scores[
  confirmation_scores$candidate_id == selected_nonmarket,
  ,
  drop = FALSE
]
market_filter_scores <- confirmation_scores[
  confirmation_scores$candidate_id == "pinnacle_live",
  ,
  drop = FALSE
]
filter_data <- merge(
  confirmation[c(
    "gameid", "league_canonical", "movement_toward_structural",
    "absolute_disagreement_band", "movement_band", "freshness_band",
    "observed_total", "market_mean"
  )],
  merge(
    market_filter_scores,
    candidate_filter_scores,
    by = "gameid",
    suffixes = c("_market", "_challenger")
  ),
  by = "gameid"
)

summarize_filter <- function(data, variable) {
  groups <- split(data, as.character(data[[variable]]))
  do.call(rbind, lapply(names(groups), function(group_name) {
    rows <- groups[[group_name]]
    data.frame(
      filter_variable = variable,
      filter_value = group_name,
      maps = nrow(rows),
      market_signed_error = mean(rows$observed_total - rows$market_mean),
      challenger_crps_improvement = (
        mean(rows$crps_market) - mean(rows$crps_challenger)
      ) / mean(rows$crps_market),
      challenger_log_score_improvement = (
        mean(rows$count_log_score_market) -
          mean(rows$count_log_score_challenger)
      ) / mean(rows$count_log_score_market),
      challenger_brier_improvement = (
        mean(rows$brier_market) - mean(rows$brier_challenger)
      ) / mean(rows$brier_market),
      recommendation_eligible = nrow(rows) >= 50L,
      stringsAsFactors = FALSE
    )
  }))
}

filter_summary <- do.call(rbind, lapply(
  c(
    "movement_toward_structural", "absolute_disagreement_band",
    "movement_band", "freshness_band", "league_canonical"
  ),
  function(variable) summarize_filter(filter_data, variable)
))

coefficient_rows <- list()
for (candidate_id in names(confirmation_fits)) {
  fit <- confirmation_fits[[candidate_id]]
  if (is.null(fit)) {
    next
  }
  coefficient_rows[[candidate_id]] <- data.frame(
    candidate_id = candidate_id,
    term = names(stats::coef(fit)),
    estimate = as.numeric(stats::coef(fit)),
    theta = as.numeric(fit$theta),
    stringsAsFactors = FALSE
  )
}
coefficients <- if (length(coefficient_rows) > 0L) {
  do.call(rbind, coefficient_rows)
} else {
  data.frame(
    candidate_id = character(),
    term = character(),
    estimate = numeric(),
    theta = numeric()
  )
}

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
  bootstrap_results,
  file.path(output_dir, "confirmation-bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  filter_summary,
  file.path(output_dir, "confirmation-filter-summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  coefficients,
  file.path(output_dir, "selected-model-coefficients.csv"),
  row.names = FALSE
)
utils::write.csv(
  data.frame(
    market_theta = market_theta,
    adjustment_maps = nrow(adjustment),
    selection_maps = nrow(selection),
    confirmation_maps = nrow(confirmation),
    selected_candidate = selected_candidate,
    selected_nonmarket = selected_nonmarket,
    disagreement_cut = disagreement_cut,
    movement_cut = movement_cut,
    stringsAsFactors = FALSE
  ),
  file.path(output_dir, "experiment-summary.csv"),
  row.names = FALSE
)

print(data.frame(
  market_theta = market_theta,
  adjustment_maps = nrow(adjustment),
  selection_maps = nrow(selection),
  confirmation_maps = nrow(confirmation),
  selected_candidate = selected_candidate,
  selected_nonmarket = selected_nonmarket
))
print(selection_summary[order(selection_summary$crps), ], row.names = FALSE)
print(confirmation_summary[order(confirmation_summary$crps), ], row.names = FALSE)
print(bootstrap_results, row.names = FALSE)
print(filter_summary, row.names = FALSE)
