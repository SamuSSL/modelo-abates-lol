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
  "market-error-variable-expanded-validation"
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

population <- DBI::dbGetQuery(connection, "
  with verified_links as (
    select *
    from game_market_links
    where link_status = 'verified'
    qualify row_number() over (
      partition by gameid
      order by reviewed_at desc, link_id desc
    ) = 1
  )
  select l.gameid, l.event_id, l.period, l.league_canonical,
         l.market_close_time, g.game_datetime, g.series_id,
         g.total_kills_game as observed_total, g.target_valid
  from verified_links l
  join canonical_games g on g.gameid = l.gameid
")
population$market_close_time <- as.POSIXct(
  population$market_close_time,
  tz = "UTC"
)
population$game_datetime <- as.POSIXct(population$game_datetime, tz = "UTC")

market <- DBI::dbGetQuery(connection, "
  with verified_links as (
    select *
    from game_market_links
    where link_status = 'verified'
    qualify row_number() over (
      partition by gameid
      order by reviewed_at desc, link_id desc
    ) = 1
  ), candidates as (
    select l.gameid, l.event_id, l.period, l.league_canonical,
           l.market_close_time, g.game_datetime, g.series_id,
           g.total_kills_game as observed_total,
           s.snapshot_id, s.line, s.odds_over, s.odds_under,
           s.odds_timestamp,
           date_diff('second', s.odds_timestamp, l.market_close_time)
             as lead_seconds,
           row_number() over (
             partition by l.gameid
             order by s.odds_timestamp desc,
                      try_cast(s.line_id as bigint) desc,
                      s.snapshot_id desc
           ) as snapshot_rank
    from verified_links l
    join market_odds_snapshots s
      on s.event_id = l.event_id and s.period = l.period
    join canonical_games g on g.gameid = l.gameid
    where g.target_valid
      and s.market = 'totals'
      and s.alt_line_id is null
      and s.odds_timestamp <= l.market_close_time - interval 15 minute
      and s.odds_over > 1 and s.odds_under > 1
      and abs(s.line - (floor(s.line) + 0.5)) < 0.000001
  )
  select * exclude(snapshot_rank)
  from candidates
  where snapshot_rank = 1
  order by game_datetime, gameid
")
market$market_close_time <- as.POSIXct(market$market_close_time, tz = "UTC")
market$game_datetime <- as.POSIXct(market$game_datetime, tz = "UTC")
market$odds_timestamp <- as.POSIXct(market$odds_timestamp, tz = "UTC")

population_ids <- unique(as.character(population$gameid[population$target_valid]))
market_ids <- unique(as.character(market$gameid))
coverage <- data.frame(
  stage = c(
    "verified_links_all",
    "verified_target_valid",
    "valid_main_line_snapshot_t15",
    "missing_valid_snapshot_t15"
  ),
  maps = c(
    length(unique(population$gameid)),
    length(population_ids),
    length(market_ids),
    length(setdiff(population_ids, market_ids))
  ),
  stringsAsFactors = FALSE
)

dispersion_cutoff <- min(market$game_datetime)
dispersion_training <- DBI::dbGetQuery(
  connection,
  sprintf(
    paste(
      "select total_kills_game, league_canonical",
      "from canonical_games",
      "where target_valid and game_datetime < timestamp '%s'"
    ),
    format(dispersion_cutoff, "%Y-%m-%d %H:%M:%S", tz = "UTC")
  )
)
dispersion_fit <- suppressWarnings(MASS::glm.nb(
  total_kills_game ~ league_canonical,
  data = dispersion_training,
  control = stats::glm.control(maxit = 100L)
))
market_theta <- as.numeric(dispersion_fit$theta)

no_vig_over <- function(over_odds, under_odds) {
  raw_over <- 1 / as.numeric(over_odds)
  raw_under <- 1 / as.numeric(under_odds)
  raw_over / (raw_over + raw_under)
}
market$market_probability_over <- no_vig_over(
  market$odds_over,
  market$odds_under
)
market$market_mean <- mapply(
  function(line, probability) {
    invert_market_count_mean(
      line,
      probability,
      distribution = "negative_binomial",
      theta = market_theta
    )
  },
  market$line,
  market$market_probability_over
)

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
all_maps <- all_maps[!duplicated(all_maps$gameid), , drop = FALSE]
target_maps <- all_maps[all_maps$gameid %in% market$gameid, , drop = FALSE]

previous_saturday <- function(datetime) {
  date <- as.Date(datetime, tz = "UTC")
  weekday <- as.POSIXlt(date, tz = "UTC")$wday
  offset <- (weekday - 6L) %% 7L
  as.POSIXct(date - offset, tz = "UTC")
}
target_maps$weekly_cutoff <- previous_saturday(target_maps$game_datetime)

evaluation <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation$directed_moneyline_joint_round
development_start <- as.POSIXct(round_config$development_start, tz = "UTC")
half_life <- as.numeric(round_config$observation_half_life_days)
alpha <- as.numeric(round_config$regularization_alpha)
inner_fraction <- as.numeric(
  round_config$inner_temporal_validation_fraction
)
prediction_seed <- as.integer(round_config$prediction_seed)

structural_path <- file.path(output_dir, "structural-weekly-predictions.rds")
progress_path <- file.path(output_dir, "structural-weekly-progress.rds")
universe_fingerprint <- digest::digest(
  list(
    target_ids = sort(as.character(target_maps$gameid)),
    latest_map = max(all_maps$game_datetime),
    round_config = round_config
  ),
  algo = "sha256"
)
prediction_rows <- list()
completed_cutoffs <- as.POSIXct(character(), tz = "UTC")
if (file.exists(progress_path)) {
  progress <- readRDS(progress_path)
  if (identical(progress$universe_fingerprint, universe_fingerprint)) {
    prediction_rows <- progress$rows
    completed_cutoffs <- as.POSIXct(progress$completed_cutoffs, tz = "UTC")
  }
}

weekly_cutoffs <- sort(unique(target_maps$weekly_cutoff))
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
    "Estrutural %s: treino=%d, previsoes=%d",
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
      weekly_cutoff = cutoff,
      structural_mean = as.numeric(predictions[[index]]$mean),
      structural_theta = as.numeric(predictions[[index]]$theta),
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
saveRDS(structural, structural_path, version = 3L)

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

team_snapshot <- function(team_id, cutoff, maximum_maps = 30L) {
  history <- history_by_team[[as.character(team_id)]]
  empty <- c(
    history_games = 0,
    win_kpm = NA,
    loss_kpm = NA,
    loss_dpm = NA,
    win_total = NA,
    loss_total = NA,
    win_games = 0,
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
  win <- as.numeric(history$result) == 1
  loss <- as.numeric(history$result) == 0
  c(
    history_games = nrow(history),
    win_kpm = weighted_mean_safe(history$kills_per_minute[win], weight[win]),
    loss_kpm = weighted_mean_safe(history$kills_per_minute[loss], weight[loss]),
    loss_dpm = weighted_mean_safe(history$deaths_per_minute[loss], weight[loss]),
    win_total = weighted_mean_safe(history$total_kills_game[win], weight[win]),
    loss_total = weighted_mean_safe(history$total_kills_game[loss], weight[loss]),
    win_games = sum(win),
    loss_games = sum(loss)
  )
}

pair_features <- function(blue, red) {
  mean_pair <- function(name) mean(c(blue[[name]], red[[name]]), na.rm = TRUE)
  min_pair <- function(name) {
    value <- c(blue[[name]], red[[name]])
    if (all(!is.finite(value))) NA_real_ else min(value, na.rm = TRUE)
  }
  clean <- function(value) ifelse(is.finite(value), value, NA_real_)
  c(
    win_aggression_mean = clean(mean_pair("win_kpm")),
    loss_trade_mean = clean(mean_pair("loss_kpm")),
    loss_collapse_mean = clean(mean_pair("loss_dpm")),
    win_total_mean = clean(mean_pair("win_total")),
    loss_total_mean = clean(mean_pair("loss_total")),
    cross_fight_ceiling = clean(max(c(
      blue[["win_kpm"]] + red[["loss_dpm"]],
      red[["win_kpm"]] + blue[["loss_dpm"]]
    ), na.rm = TRUE)),
    minimum_history = clean(min_pair("history_games")),
    minimum_win_history = clean(min_pair("win_games")),
    minimum_loss_history = clean(min_pair("loss_games"))
  )
}

team_ids <- all_maps[, c("gameid", "blue_team_id", "red_team_id")]
team_ids <- team_ids[!duplicated(team_ids$gameid), , drop = FALSE]
data <- merge(market, team_ids, by = "gameid", all.x = TRUE, sort = FALSE)
data <- merge(data, structural, by = "gameid", all.x = TRUE, sort = FALSE)
data <- data[match(market$gameid, data$gameid), , drop = FALSE]

feature_rows <- vector("list", nrow(data))
for (index in seq_len(nrow(data))) {
  blue <- team_snapshot(data$blue_team_id[[index]], data$odds_timestamp[[index]])
  red <- team_snapshot(data$red_team_id[[index]], data$odds_timestamp[[index]])
  feature_rows[[index]] <- data.frame(
    gameid = as.character(data$gameid[[index]]),
    as.list(pair_features(blue, red)),
    stringsAsFactors = FALSE
  )
}
features <- do.call(rbind, feature_rows)
data <- merge(data, features, by = "gameid", all.x = TRUE, sort = FALSE)
data <- data[match(market$gameid, data$gameid), , drop = FALSE]
data$structural_signed <- data$structural_mean - data$market_mean
data$structural_absolute <- abs(data$structural_signed)

required <- c(
  "observed_total", "line", "market_mean", "structural_mean",
  "blue_team_id", "red_team_id"
)
complete <- stats::complete.cases(data[, required, drop = FALSE])
data <- data[complete, , drop = FALSE]
coverage <- rbind(
  coverage,
  data.frame(
    stage = c("structural_and_team_identity", "excluded_after_join"),
    maps = c(nrow(data), length(market_ids) - nrow(data)),
    stringsAsFactors = FALSE
  )
)

frozen_columns <- c(
  "structural_signed",
  "structural_absolute",
  "win_aggression_mean",
  "loss_trade_mean",
  "loss_collapse_mean",
  "win_total_mean",
  "loss_total_mean",
  "cross_fight_ceiling"
)
frozen_lambda <- 10

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

data$month <- as.Date(format(data$game_datetime, "%Y-%m-01"))
months <- sort(unique(data$month))
prediction_rows <- list()
for (month in months) {
  month <- as.Date(month, origin = "1970-01-01")
  train <- data[data$game_datetime < as.POSIXct(month, tz = "UTC"), , drop = FALSE]
  validation <- data[data$month == month, , drop = FALSE]
  if (
    nrow(train) < 300L ||
      as.numeric(difftime(month, min(train$game_datetime), units = "days")) < 90
  ) {
    next
  }
  train$residual_target <- train$observed_total - train$market_mean
  matrices <- impute_matrix(train, validation, frozen_columns)
  fit <- glmnet::glmnet(
    matrices$train,
    train$residual_target,
    family = "gaussian",
    alpha = 0,
    lambda = frozen_lambda,
    standardize = TRUE,
    intercept = TRUE
  )
  correction <- as.numeric(stats::predict(
    fit,
    newx = matrices$validation,
    s = frozen_lambda
  ))
  prediction_rows[[as.character(month)]] <- data.frame(
    gameid = as.character(validation$gameid),
    series_id = as.character(validation$series_id),
    league_canonical = as.character(validation$league_canonical),
    game_datetime = as.POSIXct(validation$game_datetime, tz = "UTC"),
    training_maps = nrow(train),
    line = validation$line,
    observed_total = validation$observed_total,
    market_mean = validation$market_mean,
    candidate_mean = pmax(validation$market_mean + correction, 0.1),
    correction = correction,
    stringsAsFactors = FALSE
  )
}
predictions <- do.call(rbind, prediction_rows)
rownames(predictions) <- NULL

score_distribution <- function(observed, line, mean, theta) {
  support <- 0:150
  probability_over <- stats::pnbinom(
    floor(line),
    size = theta,
    mu = mean,
    lower.tail = FALSE
  )
  observed_over <- as.numeric(observed > line)
  crps <- vapply(seq_along(observed), function(index) {
    cumulative <- stats::pnbinom(
      support,
      size = theta,
      mu = mean[[index]]
    )
    sum((cumulative - as.numeric(support >= observed[[index]]))^2)
  }, numeric(1L))
  data.frame(
    crps = crps,
    count_log_score = -stats::dnbinom(
      observed,
      size = theta,
      mu = mean,
      log = TRUE
    ),
    absolute_error = abs(observed - mean),
    brier = (probability_over - observed_over)^2,
    probability_over = probability_over,
    stringsAsFactors = FALSE
  )
}

market_scores <- score_distribution(
  predictions$observed_total,
  predictions$line,
  predictions$market_mean,
  market_theta
)
candidate_scores <- score_distribution(
  predictions$observed_total,
  predictions$line,
  predictions$candidate_mean,
  market_theta
)
for (metric in names(market_scores)) {
  predictions[[paste0("market_", metric)]] <- market_scores[[metric]]
  predictions[[paste0("candidate_", metric)]] <- candidate_scores[[metric]]
}
for (metric in c("crps", "count_log_score", "absolute_error", "brier")) {
  predictions[[paste0("delta_", metric)]] <-
    predictions[[paste0("candidate_", metric)]] -
    predictions[[paste0("market_", metric)]]
}

atlas <- readRDS(file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "structural-pinnacle-error-atlas",
  "map-error-atlas.rds"
))
predictions$sample_scope <- ifelse(
  predictions$gameid %in% atlas$gameid,
  "discovery_atlas_overlap",
  "outside_discovery_atlas"
)
predictions$calendar_scope <- ifelse(
  predictions$game_datetime < as.POSIXct("2026-03-01", tz = "UTC"),
  "before_discovery_window",
  "discovery_window_or_later"
)
predictions$month <- format(predictions$game_datetime, "%Y-%m")

summarize_group <- function(rows, group_type, group_value) {
  data.frame(
    group_type = group_type,
    group_value = group_value,
    maps = nrow(rows),
    series = length(unique(rows$series_id)),
    market_crps = mean(rows$market_crps),
    candidate_crps = mean(rows$candidate_crps),
    delta_crps = mean(rows$delta_crps),
    relative_crps_change = mean(rows$delta_crps) / mean(rows$market_crps),
    market_count_log_score = mean(rows$market_count_log_score),
    candidate_count_log_score = mean(rows$candidate_count_log_score),
    delta_count_log_score = mean(rows$delta_count_log_score),
    market_absolute_error = mean(rows$market_absolute_error),
    candidate_absolute_error = mean(rows$candidate_absolute_error),
    delta_absolute_error = mean(rows$delta_absolute_error),
    market_brier = mean(rows$market_brier),
    candidate_brier = mean(rows$candidate_brier),
    delta_brier = mean(rows$delta_brier),
    mean_correction = mean(rows$correction),
    mean_absolute_correction = mean(abs(rows$correction)),
    stringsAsFactors = FALSE
  )
}

summary_rows <- list(
  overall = summarize_group(predictions, "overall", "all_oof_maps")
)
for (scope in unique(predictions$sample_scope)) {
  rows <- predictions[predictions$sample_scope == scope, , drop = FALSE]
  summary_rows[[paste0("scope_", scope)]] <- summarize_group(
    rows,
    "sample_scope",
    scope
  )
}
for (scope in unique(predictions$calendar_scope)) {
  rows <- predictions[predictions$calendar_scope == scope, , drop = FALSE]
  summary_rows[[paste0("calendar_", scope)]] <- summarize_group(
    rows,
    "calendar_scope",
    scope
  )
}
for (league in sort(unique(predictions$league_canonical))) {
  rows <- predictions[
    predictions$league_canonical == league,
    ,
    drop = FALSE
  ]
  summary_rows[[paste0("league_", league)]] <- summarize_group(
    rows,
    "league",
    league
  )
}
for (month in sort(unique(predictions$month))) {
  rows <- predictions[predictions$month == month, , drop = FALSE]
  summary_rows[[paste0("month_", month)]] <- summarize_group(
    rows,
    "month",
    month
  )
}
summary <- do.call(rbind, summary_rows)
rownames(summary) <- NULL

paired_bootstrap <- function(rows, draws = 5000L, seed = 20260805L) {
  blocks <- split(seq_len(nrow(rows)), paste(rows$month, rows$series_id, sep = "|"))
  metrics <- c("crps", "count_log_score", "absolute_error", "brier")
  set.seed(seed)
  result <- lapply(metrics, function(metric) {
    values <- rows[[paste0("delta_", metric)]]
    sampled <- replicate(draws, {
      selected <- sample(names(blocks), length(blocks), replace = TRUE)
      indices <- unlist(blocks[selected], use.names = FALSE)
      mean(values[indices])
    })
    data.frame(
      metric = metric,
      maps = nrow(rows),
      blocks = length(blocks),
      mean_difference = mean(values),
      lower_95 = unname(stats::quantile(sampled, 0.025)),
      upper_95 = unname(stats::quantile(sampled, 0.975)),
      probability_candidate_better = mean(sampled < 0),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, result)
}

bootstrap_rows <- list(
  overall = transform(
    paired_bootstrap(predictions),
    sample_scope = "all_oof_maps"
  )
)
for (scope in unique(predictions$sample_scope)) {
  rows <- predictions[predictions$sample_scope == scope, , drop = FALSE]
  bootstrap_rows[[scope]] <- transform(
    paired_bootstrap(rows, seed = 20260805L + nchar(scope)),
    sample_scope = scope
  )
}
bootstrap <- do.call(rbind, bootstrap_rows)
rownames(bootstrap) <- NULL

monthly <- summary[summary$group_type == "month", , drop = FALSE]
outside <- summary[
  summary$group_type == "sample_scope" &
    summary$group_value == "outside_discovery_atlas",
  ,
  drop = FALSE
]
outside_bootstrap <- bootstrap[
  bootstrap$sample_scope == "outside_discovery_atlas",
  ,
  drop = FALSE
]
outside_crps <- outside_bootstrap[outside_bootstrap$metric == "crps", ]
outside_log <- outside_bootstrap[
  outside_bootstrap$metric == "count_log_score",
  ,
  drop = FALSE
]
success <- nrow(outside) == 1L &&
  outside$delta_crps < 0 &&
  outside$delta_count_log_score < 0 &&
  outside_crps$probability_candidate_better >= 0.9 &&
  outside_log$probability_candidate_better >= 0.9 &&
  mean(monthly$delta_crps < 0) >= 0.6

decision <- data.frame(
  item = c(
    "experiment_id",
    "frozen_family",
    "frozen_lambda",
    "validation_design",
    "prospective_test",
    "success_rule",
    "result",
    "production_decision"
  ),
  value = c(
    "VAR-CONF-01",
    "structural_plus_win_loss_behavior",
    as.character(frozen_lambda),
    "expanding monthly point-in-time refit; family and lambda frozen",
    "false",
    paste(
      "outside-atlas CRPS and log score improve; bootstrap probability",
      ">= 0.90 for both; >= 60% of months improve CRPS"
    ),
    if (success) "PASS" else "FAIL_OR_INCONCLUSIVE",
    if (success) "challenger_supported_not_automatic_promotion" else "hold"
  ),
  stringsAsFactors = FALSE
)

utils::write.csv(coverage, file.path(output_dir, "coverage-audit.csv"), row.names = FALSE)
utils::write.csv(data, file.path(output_dir, "point-in-time-dataset.csv"), row.names = FALSE)
utils::write.csv(predictions, file.path(output_dir, "oof-predictions.csv"), row.names = FALSE)
utils::write.csv(summary, file.path(output_dir, "metric-summary.csv"), row.names = FALSE)
utils::write.csv(bootstrap, file.path(output_dir, "paired-bootstrap.csv"), row.names = FALSE)
utils::write.csv(decision, file.path(output_dir, "decision.csv"), row.names = FALSE)
saveRDS(
  list(
    coverage = coverage,
    data = data,
    predictions = predictions,
    summary = summary,
    bootstrap = bootstrap,
    decision = decision,
    market_theta = market_theta,
    frozen_columns = frozen_columns,
    frozen_lambda = frozen_lambda
  ),
  file.path(output_dir, "expanded-validation-results.rds"),
  version = 3L
)

report <- c(
  "# Confirmacao ampliada da familia win/loss",
  "",
  "## Escopo",
  "",
  paste(
    "A familia structural_plus_win_loss_behavior e lambda 10 foram",
    "congeladas antes deste teste. Os coeficientes foram reestimados",
    "mensalmente apenas com mapas anteriores ao mes avaliado."
  ),
  "",
  "## Universo e integridade",
  "",
  paste(
    "O universo bruto e formado por",
    coverage$maps[coverage$stage == "verified_target_valid"],
    "mapas verificados e validos. O teste utilizou",
    nrow(predictions),
    "previsoes fora da amostra mensal."
  ),
  "",
  "## Resultado",
  "",
  paste(
    "Fora do atlas original, delta CRPS =",
    sprintf("%.6f", outside$delta_crps),
    "e delta log score =",
    sprintf("%.6f", outside$delta_count_log_score),
    "."
  ),
  paste(
    "Probabilidade bootstrap de melhora: CRPS =",
    sprintf("%.2f%%", 100 * outside_crps$probability_candidate_better),
    "e log score =",
    sprintf("%.2f%%", 100 * outside_log$probability_candidate_better),
    "."
  ),
  paste(
    "Meses com melhora de CRPS:",
    sprintf("%.1f%%", 100 * mean(monthly$delta_crps < 0)),
    "."
  ),
  "",
  "## Decisao",
  "",
  paste(
    "Resultado do criterio predefinido:",
    decision$value[decision$item == "result"],
    "."
  ),
  paste(
    "Este e um teste historico reutilizado, nao prospectivo. Mesmo com",
    "construcao point-in-time, a escolha da familia foi informada por 2026."
  ),
  "",
  "## Limitacao economica",
  "",
  paste(
    "O teste compara distribuicoes contra a Pinnacle. Sem odds soft",
    "sincronizadas, nao estabelece ROI contra casas soft."
  )
)
writeLines(report, file.path(output_dir, "09-final-report.md"), useBytes = TRUE)

print(coverage, row.names = FALSE)
print(summary[summary$group_type %in% c("overall", "sample_scope"), ], row.names = FALSE)
print(bootstrap, row.names = FALSE)
print(decision, row.names = FALSE)
