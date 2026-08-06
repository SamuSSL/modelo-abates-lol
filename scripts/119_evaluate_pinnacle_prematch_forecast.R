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
  "pinnacle-prematch-forecast-soft-open"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
database_path <- file.path(project_root, "data", "processed", "lolkills.duckdb")
connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = database_path,
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

post <- DBI::dbGetQuery(connection, "
  select q.gameid, q.prematch_event_id, q.period, q.live_open_time,
         q.quote_time as last_prematch_time, q.line as last_line,
         q.odds_over as last_odds_over, q.odds_under as last_odds_under,
         g.series_id, g.game_datetime, g.league_canonical,
         g.total_kills_game as observed_total
  from market_postdraft_quotes q
  join canonical_games g on g.gameid = q.gameid
  where q.gameid is not null and g.target_valid
  qualify row_number() over (
    partition by q.gameid order by q.quote_time desc, q.snapshot_id desc
  ) = 1
")
history <- DBI::dbGetQuery(connection, "
  select q.gameid, s.line, s.line_id, s.odds_over, s.odds_under,
         s.odds_timestamp, s.snapshot_id
  from market_postdraft_quotes q
  join market_odds_snapshots s
    on s.event_id = q.prematch_event_id and s.period = q.period
  where q.gameid is not null
    and s.market = 'totals'
    and s.alt_line_id is null
    and s.odds_timestamp < q.quote_time
")
for (field in c("live_open_time", "last_prematch_time", "game_datetime")) {
  post[[field]] <- as.POSIXct(post[[field]], tz = "UTC")
}
history$odds_timestamp <- as.POSIXct(history$odds_timestamp, tz = "UTC")

dispersion_training <- DBI::dbGetQuery(connection, "
  select total_kills_game, league_canonical
  from canonical_games
  where target_valid and game_datetime < timestamp '2026-03-01 00:00:00'
")
dispersion_fit <- suppressWarnings(MASS::glm.nb(
  total_kills_game ~ league_canonical,
  data = dispersion_training,
  control = stats::glm.control(maxit = 100L)
))
global_theta <- as.numeric(dispersion_fit$theta)

weekly_path <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "directed-market-regime-calibration",
  "weekly_base_predictions.csv"
)
weekly <- utils::read.csv(weekly_path, stringsAsFactors = FALSE)
weekly <- weekly[!duplicated(weekly$gameid), c(
  "gameid", "base_mean", "base_theta", "map_number", "training_maps",
  "moneyline_training_maps", "blue_team_id", "red_team_id",
  "blue_latest_history_available_at", "red_latest_history_available_at"
)]
weekly$blue_latest_history_available_at <- as.POSIXct(
  weekly$blue_latest_history_available_at,
  tz = "UTC"
)
weekly$red_latest_history_available_at <- as.POSIXct(
  weekly$red_latest_history_available_at,
  tz = "UTC"
)
post <- merge(post, weekly, by = "gameid", all.x = TRUE)
post$base_theta[!is.finite(post$base_theta)] <- global_theta
post$base_mean[!is.finite(post$base_mean)] <- NA_real_
post$map_number[!is.finite(post$map_number)] <- as.numeric(post$period[
  !is.finite(post$map_number)
])

market_probability <- function(over, under) {
  raw_over <- 1 / as.numeric(over)
  raw_under <- 1 / as.numeric(under)
  raw_over / (raw_over + raw_under)
}

select_snapshot <- function(rows, live_open_time, timing_id) {
  lead_seconds <- as.numeric(difftime(
    live_open_time,
    rows$odds_timestamp,
    units = "secs"
  ))
  if (timing_id == "opening") {
    index <- which.min(rows$odds_timestamp)
  } else {
    minimum <- if (timing_id == "pre_t30") 30 * 60 else 15 * 60
    eligible <- which(lead_seconds >= minimum)
    if (length(eligible) == 0L) {
      return(NULL)
    }
    index <- eligible[[which.max(rows$odds_timestamp[eligible])]]
  }
  rows[index, , drop = FALSE]
}

feature_rows <- list()
row_index <- 1L
for (gameid in intersect(post$gameid, history$gameid)) {
  map <- post[post$gameid == gameid, , drop = FALSE][1L, ]
  rows <- history[history$gameid == gameid, , drop = FALSE]
  rows <- rows[order(rows$odds_timestamp, rows$line_id, rows$snapshot_id), ]
  if (nrow(rows) == 0L) {
    next
  }
  probabilities <- market_probability(rows$odds_over, rows$odds_under)
  rows$mu <- vapply(seq_len(nrow(rows)), function(index) {
    invert_market_count_mean(
      rows$line[[index]],
      probabilities[[index]],
      "negative_binomial",
      map$base_theta
    )
  }, numeric(1L))
  opening_mu <- rows$mu[[1L]]
  opening_line <- rows$line[[1L]]
  for (timing_id in c("opening", "pre_t30", "pre_t15")) {
    snapshot <- select_snapshot(rows, map$live_open_time, timing_id)
    if (is.null(snapshot)) {
      next
    }
    prior <- rows[rows$odds_timestamp <= snapshot$odds_timestamp, , drop = FALSE]
    previous_mu <- if (nrow(prior) >= 2L) prior$mu[[nrow(prior) - 1L]] else prior$mu[[1L]]
    feature_rows[[row_index]] <- data.frame(
      gameid = gameid,
      series_id = map$series_id,
      game_datetime = map$game_datetime,
      league_canonical = map$league_canonical,
      map_number = map$map_number,
      observed_total = map$observed_total,
      snapshot_time = snapshot$odds_timestamp,
      last_prematch_time = map$last_prematch_time,
      live_open_time = map$live_open_time,
      snapshot_line = snapshot$line,
      snapshot_odds_over = snapshot$odds_over,
      snapshot_odds_under = snapshot$odds_under,
      last_line = map$last_line,
      last_odds_over = map$last_odds_over,
      last_odds_under = map$last_odds_under,
      timing_id = timing_id,
      theta = map$base_theta,
      structural_mean = map$base_mean,
      structural_training_maps = map$training_maps,
      moneyline_training_maps = map$moneyline_training_maps,
      blue_team_id = map$blue_team_id,
      red_team_id = map$red_team_id,
      blue_history_age_days = as.numeric(difftime(
        snapshot$odds_timestamp,
        map$blue_latest_history_available_at,
        units = "days"
      )),
      red_history_age_days = as.numeric(difftime(
        snapshot$odds_timestamp,
        map$red_latest_history_available_at,
        units = "days"
      )),
      quote_count = nrow(prior),
      line_from_open = snapshot$line - opening_line,
      mu_from_open = snapshot$mu - opening_mu,
      recent_mu_change = snapshot$mu - previous_mu,
      stringsAsFactors = FALSE
    )
    row_index <- row_index + 1L
  }
}
raw_rows <- do.call(rbind, feature_rows)
valid_quote <- function(line, over, under) {
  is.finite(line) & is.finite(over) & is.finite(under) &
    line >= 0.5 & abs(line %% 1 - 0.5) <= 1e-12 &
    over > 1 & under > 1
}
raw_rows <- raw_rows[
  valid_quote(
    raw_rows$snapshot_line,
    raw_rows$snapshot_odds_over,
    raw_rows$snapshot_odds_under
  ) & valid_quote(
    raw_rows$last_line,
    raw_rows$last_odds_over,
    raw_rows$last_odds_under
  ) & is.finite(raw_rows$theta) & raw_rows$theta > 0,
  ,
  drop = FALSE
]
rows <- build_prematch_forecast_rows(raw_rows)
rows$structural_disagreement <- rows$structural_mean - rows$snapshot_mu
rows$structural_disagreement[!is.finite(rows$structural_disagreement)] <- 0
rows$structural_training_maps[!is.finite(rows$structural_training_maps)] <- 0
rows$moneyline_training_maps[!is.finite(rows$moneyline_training_maps)] <- 0
rows$blue_history_age_days[!is.finite(rows$blue_history_age_days)] <- 999
rows$red_history_age_days[!is.finite(rows$red_history_age_days)] <- 999
rows$sample <- ifelse(
  rows$snapshot_time < as.POSIXct("2026-05-01 00:00:00", tz = "UTC"),
  "adjustment_mar_apr",
  ifelse(
    rows$snapshot_time < as.POSIXct("2026-06-01 00:00:00", tz = "UTC"),
    "selection_may",
    "confirmation_jun_jul"
  )
)
adjustment_leagues <- unique(rows$league_canonical[
  rows$sample == "adjustment_mar_apr"
])
rows$league_model <- factor(
  ifelse(
    rows$league_canonical %in% adjustment_leagues,
    rows$league_canonical,
    "OTHER"
  ),
  levels = unique(c(adjustment_leagues, "OTHER"))
)
adjustment_teams <- stats::na.omit(unique(c(
  rows$blue_team_id[rows$sample == "adjustment_mar_apr"],
  rows$red_team_id[rows$sample == "adjustment_mar_apr"]
)))
rows$blue_team_model <- factor(
  ifelse(
    !is.na(rows$blue_team_id) & rows$blue_team_id %in% adjustment_teams,
    rows$blue_team_id,
    "OTHER"
  ),
  levels = unique(c(adjustment_teams, "OTHER"))
)
rows$red_team_model <- factor(
  ifelse(
    !is.na(rows$red_team_id) & rows$red_team_id %in% adjustment_teams,
    rows$red_team_id,
    "OTHER"
  ),
  levels = unique(c(adjustment_teams, "OTHER"))
)
if (any(rows$snapshot_time >= rows$last_prematch_time) ||
    any(rows$last_prematch_time >= rows$live_open_time)) {
  stop("Temporal ordering failed after row construction.", call. = FALSE)
}

formula <- delta_mu ~ snapshot_mu + lead_minutes + snapshot_overround +
  quote_count + line_from_open + mu_from_open + recent_mu_change +
  structural_disagreement + structural_training_maps +
  moneyline_training_maps + blue_history_age_days + red_history_age_days +
  map_number + league_model + blue_team_model + red_team_model + timing_id
lambdas <- c(0.1, 1, 10, 100)
adjustment <- rows[rows$sample == "adjustment_mar_apr", , drop = FALSE]
selection <- rows[rows$sample == "selection_may", , drop = FALSE]
confirmation <- rows[rows$sample == "confirmation_jun_jul", , drop = FALSE]

lambda_results <- lapply(lambdas, function(lambda) {
  fit <- fit_prematch_delta_ridge(adjustment, formula, lambda)
  prediction <- predict_prematch_delta_ridge(fit, selection)
  data.frame(
    lambda = lambda,
    maps = nrow(selection),
    mae = mean(abs(selection$last_mu - prediction$predicted_last_mu)),
    baseline_mae = mean(abs(selection$delta_mu)),
    stringsAsFactors = FALSE
  )
})
lambda_summary <- do.call(rbind, lambda_results)
selected_lambda <- lambda_summary$lambda[[which.min(lambda_summary$mae)]]
selection_fit <- fit_prematch_delta_ridge(adjustment, formula, selected_lambda)
selection_prediction <- predict_prematch_delta_ridge(selection_fit, selection)
selection_residual <- selection$last_mu - selection_prediction$predicted_last_mu
intervals <- split(selection_residual, selection$timing_id)

final_fit <- fit_prematch_delta_ridge(
  rows[rows$sample != "confirmation_jun_jul", , drop = FALSE],
  formula,
  selected_lambda
)
final_fit$residual_intervals <- do.call(rbind, lapply(names(intervals), function(timing) {
  values <- intervals[[timing]]
  data.frame(
    timing_id = timing,
    lower = unname(stats::quantile(values, 0.05)),
    upper = unname(stats::quantile(values, 0.95)),
    stringsAsFactors = FALSE
  )
}))
prediction <- predict_prematch_delta_ridge(final_fit, confirmation)
scored <- cbind(confirmation, prediction)
scored$baseline_last_mu <- scored$snapshot_mu
group_mean <- stats::aggregate(
  delta_mu ~ league_canonical + timing_id,
  rows[rows$sample != "confirmation_jun_jul", , drop = FALSE],
  mean
)
names(group_mean)[names(group_mean) == "delta_mu"] <- "group_delta_mu"
scored <- merge(scored, group_mean, by = c("league_canonical", "timing_id"), all.x = TRUE)
scored$group_delta_mu[!is.finite(scored$group_delta_mu)] <- 0
scored$model_absolute_error <- abs(scored$last_mu - scored$predicted_last_mu)
scored$baseline_absolute_error <- abs(scored$delta_mu)
scored$group_absolute_error <- abs(scored$delta_mu - scored$group_delta_mu)
scored$interval_covered <- scored$last_mu >= scored$predicted_last_mu_low &
  scored$last_mu <= scored$predicted_last_mu_high
changed <- abs(scored$delta_mu) > 0.05
model_direction <- mean(sign(scored$predicted_delta_mu[changed]) == sign(scored$delta_mu[changed]))
group_direction <- mean(sign(scored$group_delta_mu[changed]) == sign(scored$delta_mu[changed]))

probability_at_line <- function(mean, line, theta) {
  stats::pnbinom(floor(line), size = theta, mu = mean, lower.tail = FALSE)
}
scored$model_probability_over <- mapply(
  probability_at_line,
  scored$predicted_last_mu,
  scored$last_line,
  scored$theta
)
scored$baseline_probability_over <- mapply(
  probability_at_line,
  scored$snapshot_mu,
  scored$last_line,
  scored$theta
)
scored$observed_over <- as.numeric(scored$observed_total > scored$last_line)
score_probability <- function(probability, observed) {
  data.frame(
    brier = mean((probability - observed)^2),
    log_loss = mean(-(
      observed * log(pmax(probability, 1e-15)) +
        (1 - observed) * log(pmax(1 - probability, 1e-15))
    ))
  )
}
model_scores <- score_probability(scored$model_probability_over, scored$observed_over)
baseline_scores <- score_probability(scored$baseline_probability_over, scored$observed_over)

blocks <- split(
  seq_len(nrow(scored)),
  ifelse(is.na(scored$series_id), scored$gameid, scored$series_id)
)
set.seed(20260805)
bootstrap_delta <- replicate(5000L, {
  sampled <- sample(names(blocks), length(blocks), replace = TRUE)
  indices <- unlist(blocks[sampled], use.names = FALSE)
  mean(scored$model_absolute_error[indices] - scored$baseline_absolute_error[indices])
})
mae <- mean(scored$model_absolute_error)
baseline_mae <- mean(scored$baseline_absolute_error)
relative_improvement <- (baseline_mae - mae) / baseline_mae
interval_coverage <- mean(scored$interval_covered)
league_summary <- stats::aggregate(
  cbind(model_absolute_error, baseline_absolute_error) ~ league_canonical,
  scored,
  mean
)
league_summary$relative_improvement <- with(
  league_summary,
  (baseline_absolute_error - model_absolute_error) / baseline_absolute_error
)
league_counts <- stats::aggregate(gameid ~ league_canonical, scored, length)
names(league_counts)[2L] <- "rows"
league_summary <- merge(league_summary, league_counts, by = "league_canonical")

gates <- data.frame(
  gate = c(
    "mae_improvement_5pct", "bootstrap_upper_below_zero",
    "direction_gain_5pp", "brier_not_worse", "log_loss_not_worse",
    "interval_coverage_86_94", "league_stability"
  ),
  passed = c(
    relative_improvement >= 0.05,
    stats::quantile(bootstrap_delta, 0.975) < 0,
    model_direction - group_direction >= 0.05,
    model_scores$brier <= baseline_scores$brier,
    model_scores$log_loss <= baseline_scores$log_loss,
    interval_coverage >= 0.86 && interval_coverage <= 0.94,
    !any(league_summary$rows >= 20 & league_summary$relative_improvement < -0.10)
  ),
  stringsAsFactors = FALSE
)
approved <- all(gates$passed)
overall <- data.frame(
  candidate_id = "ridge_delta_mu",
  selected_lambda = selected_lambda,
  confirmation_rows = nrow(scored),
  confirmation_maps = length(unique(scored$gameid)),
  model_mae = mae,
  no_movement_mae = baseline_mae,
  relative_mae_improvement = relative_improvement,
  bootstrap_delta_lower_95 = unname(stats::quantile(bootstrap_delta, 0.025)),
  bootstrap_delta_upper_95 = unname(stats::quantile(bootstrap_delta, 0.975)),
  model_direction_accuracy = model_direction,
  group_direction_accuracy = group_direction,
  direction_gain = model_direction - group_direction,
  model_brier = model_scores$brier,
  baseline_brier = baseline_scores$brier,
  model_log_loss = model_scores$log_loss,
  baseline_log_loss = baseline_scores$log_loss,
  interval_coverage_90 = interval_coverage,
  approved_for_micro_stake = approved,
  stringsAsFactors = FALSE
)

utils::write.csv(rows, file.path(output_dir, "forecast-dataset.csv"), row.names = FALSE)
temporal_manifest <- data.frame(
  split = c(
    adjustment_mar_apr = "train",
    selection_may = "validation",
    confirmation_jun_jul = "test"
  )[rows$sample],
  prediction_time = format(rows$snapshot_time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  feature_available_time = format(rows$snapshot_time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  target_time = format(rows$last_prematch_time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  stringsAsFactors = FALSE
)
utils::write.csv(
  temporal_manifest,
  file.path(output_dir, "temporal-split-manifest.csv"),
  row.names = FALSE
)
utils::write.csv(lambda_summary, file.path(output_dir, "ridge-selection.csv"), row.names = FALSE)
utils::write.csv(scored, file.path(output_dir, "confirmation-predictions.csv"), row.names = FALSE)
utils::write.csv(overall, file.path(output_dir, "confirmation-summary.csv"), row.names = FALSE)
utils::write.csv(gates, file.path(output_dir, "promotion-gates.csv"), row.names = FALSE)
utils::write.csv(league_summary, file.path(output_dir, "confirmation-by-league.csv"), row.names = FALSE)
utils::write.csv(data.frame(delta_mae = bootstrap_delta), file.path(output_dir, "confirmation-bootstrap.csv"), row.names = FALSE)
saveRDS(final_fit, file.path(output_dir, "ridge-model.rds"))

portable_coefficients <- as.list(as.numeric(final_fit$coefficients))
names(portable_coefficients) <- names(final_fit$coefficients)
portable <- list(
  model_id = "pinnacle-last-prematch-ridge-v1",
  status = if (approved) "approved_for_micro_stake" else "shadow_only",
  target = "pinnacle_last_prematch_implied_mean",
  selected_lambda = selected_lambda,
  coefficients = portable_coefficients,
  factor_levels = final_fit$xlevels,
  residual_intervals = final_fit$residual_intervals,
  minimum_conservative_ev = 0.05,
  stake_units = 1,
  generated_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
  data_cutoff = format(max(rows$game_datetime), tz = "UTC", usetz = TRUE),
  gates = setNames(as.list(gates$passed), gates$gate)
)
jsonlite::write_json(
  portable,
  file.path(output_dir, "forecast-bundle.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  digits = 15
)

parity_index <- 1L
parity_row <- scored[parity_index, , drop = FALSE]
parity_fixture <- list(
  features = list(
    snapshot_mu = parity_row$snapshot_mu,
    lead_minutes = parity_row$lead_minutes,
    snapshot_overround = parity_row$snapshot_overround,
    quote_count = parity_row$quote_count,
    line_from_open = parity_row$line_from_open,
    mu_from_open = parity_row$mu_from_open,
    recent_mu_change = parity_row$recent_mu_change,
    structural_disagreement = parity_row$structural_disagreement,
    structural_training_maps = parity_row$structural_training_maps,
    moneyline_training_maps = parity_row$moneyline_training_maps,
    blue_history_age_days = parity_row$blue_history_age_days,
    red_history_age_days = parity_row$red_history_age_days,
    map_number = parity_row$map_number,
    league_model = as.character(parity_row$league_model),
    blue_team_model = as.character(parity_row$blue_team_model),
    red_team_model = as.character(parity_row$red_team_model),
    timing_id = as.character(parity_row$timing_id),
    theta = parity_row$theta
  ),
  soft_quote = list(
    line = parity_row$last_line,
    odds_over = 1.95,
    odds_under = 1.95
  ),
  expected = list(
    predicted_last_mu = parity_row$predicted_last_mu,
    predicted_last_mu_low = parity_row$predicted_last_mu_low,
    predicted_last_mu_high = parity_row$predicted_last_mu_high
  )
)
jsonlite::write_json(
  parity_fixture,
  file.path(output_dir, "parity-fixture.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  digits = 15
)

registry <- data.frame(
  experiment_id = c("PF-000", "PF-001", "PF-002"),
  status = c("complete", "complete", if (approved) "eligible" else "not_run"),
  hypothesis = c(
    "Point-in-time market reconstruction is valid",
    "Regularized delta forecast beats no movement",
    "XGBoost adds stable value beyond an approved ridge"
  ),
  decision = c(
    "pass",
    if (approved) "pass" else "fail_or_inconclusive",
    if (approved) "run_challenger" else "ridge_gate_required"
  ),
  stringsAsFactors = FALSE
)
utils::write.csv(registry, file.path(output_dir, "experiment-registry.csv"), row.names = FALSE)
cat(jsonlite::toJSON(overall, auto_unbox = TRUE, pretty = TRUE), "\n")
