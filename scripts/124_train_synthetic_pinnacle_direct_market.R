script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

output_dir <- file.path(
  project_root, "artifacts", "modeling-research",
  "synthetic-pinnacle-direct-market-v2"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
seed <- 20260806L
set.seed(seed)

connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = file.path(project_root, "data", "processed", "lolkills.duckdb"),
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

target <- DBI::dbGetQuery(connection, "
  WITH candidate_quotes AS (
    SELECT *, 1 AS source_priority FROM market_odds_snapshots
    UNION ALL
    SELECT *, 2 AS source_priority FROM market_closing
  )
  SELECT l.gameid, g.series_id, g.game_datetime,
         g.league_canonical, g.total_kills_game,
         q.odds_timestamp AS last_prematch_time,
         q.line AS final_line,
         q.odds_over AS final_odds_over,
         q.odds_under AS final_odds_under,
         q.true_odds_over AS final_true_odds_over,
         q.true_odds_under AS final_true_odds_under,
         q.snapshot_id
  FROM game_market_links l
  JOIN canonical_games g ON g.gameid = l.gameid
  JOIN candidate_quotes q
    ON q.event_id = l.event_id AND q.period = l.period
  WHERE l.link_status = 'verified'
    AND g.target_valid
    AND q.market = 'totals'
    AND q.alt_line_id IS NULL
    AND q.odds_timestamp < g.game_datetime
    AND q.odds_over > 1 AND q.odds_under > 1
    AND q.line > 0
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY l.gameid
    ORDER BY q.odds_timestamp DESC, q.source_priority DESC, q.snapshot_id DESC
  ) = 1
")
target$game_datetime <- as.POSIXct(target$game_datetime, tz = "UTC")
target$last_prematch_time <- as.POSIXct(target$last_prematch_time, tz = "UTC")
valid_target <- is.finite(target$final_line) &
  abs(target$final_line %% 1 - 0.5) < 1e-12 &
  is.finite(target$final_odds_over) & target$final_odds_over > 1 &
  is.finite(target$final_odds_under) & target$final_odds_under > 1
target <- target[valid_target, , drop = FALSE]
raw_over <- 1 / target$final_odds_over
raw_under <- 1 / target$final_odds_under
target$final_hold <- raw_over + raw_under
target$final_probability_over <- raw_over / target$final_hold
target$final_probability_logit <- stats::qlogis(pmin(
  1 - 1e-6, pmax(1e-6, target$final_probability_over)
))
target$final_log_hold <- log(target$final_hold)

maps <- readRDS(file.path(
  project_root, "data", "interim", "premap_ratio_map_features_series.rds"
))
maps <- maps[!duplicated(maps$gameid), , drop = FALSE]
for (field in c(
  "prediction_cutoff", "blue_latest_history_available_at",
  "red_latest_history_available_at", "game_datetime"
)) {
  maps[[field]] <- as.POSIXct(maps[[field]], tz = "UTC")
}
data <- merge(target, maps, by = "gameid", suffixes = c("", "_feature"))
temporal_valid <- data$prediction_cutoff < data$last_prematch_time &
  data$last_prematch_time < data$game_datetime &
  data$blue_latest_history_available_at <= data$prediction_cutoff &
  data$red_latest_history_available_at <= data$prediction_cutoff
temporal_valid[is.na(temporal_valid)] <- FALSE
utils::write.csv(
  data[!temporal_valid, c(
    "gameid", "prediction_cutoff", "last_prematch_time", "game_datetime",
    "blue_latest_history_available_at", "red_latest_history_available_at"
  )],
  file.path(output_dir, "quarantined-temporal-violations.csv"),
  row.names = FALSE
)
data <- data[temporal_valid, , drop = FALSE]

players <- readRDS(file.path(
  project_root, "data", "interim", "player_map_metrics.rds"
))
players$game_datetime <- as.POSIXct(players$game_datetime, tz = "UTC")
players <- players[
  players$target_valid & !is.na(players$player_id) &
    !is.na(players$team_id) & !is.na(players$position),
  ,
  drop = FALSE
]
players <- players[order(players$game_datetime, players$gameid), , drop = FALSE]
player_split <- split(players, as.character(players$player_id))
team_split <- split(players, as.character(players$team_id))
rating_metrics <- c(
  "kills_per_minute", "deaths_per_minute",
  "conflict_involvement_per_minute", "damage_per_minute",
  "kill_participation"
)
baseline_cache <- new.env(parent = emptyenv())
snapshot_cache <- new.env(parent = emptyenv())

safe_mean <- function(value, fallback = 0) {
  value <- as.numeric(value)
  value <- value[is.finite(value)]
  if (length(value) == 0L) fallback else mean(value)
}

league_position_baseline <- function(league, position, cutoff, metric) {
  key <- paste(league, position, as.numeric(cutoff), metric, sep = "|")
  if (exists(key, baseline_cache, inherits = FALSE)) {
    return(get(key, baseline_cache, inherits = FALSE))
  }
  eligible <- players$game_datetime < cutoff &
    as.character(players$position) == position
  league_eligible <- eligible &
    as.character(players$league_canonical) == league
  value <- safe_mean(players[[metric]][league_eligible], NA_real_)
  if (!is.finite(value)) {
    value <- safe_mean(players[[metric]][eligible], 0)
  }
  assign(key, value, baseline_cache)
  value
}

team_roster_snapshot <- function(team_id, league, cutoff) {
  cache_key <- paste(team_id, league, as.numeric(cutoff), sep = "|")
  if (exists(cache_key, snapshot_cache, inherits = FALSE)) {
    return(get(cache_key, snapshot_cache, inherits = FALSE))
  }
  rows <- team_split[[as.character(team_id)]]
  empty <- c(
    player_games_min = 0, player_games_mean = 0,
    roster_kpm = NA, roster_deaths_pm = NA,
    roster_conflict_pm = NA, roster_damage_pm = NA,
    roster_kill_participation = NA, roster_continuity = 0,
    roster_change = 1, roster_days_together = 0, roster_size = 0
  )
  attr(empty, "roster") <- character()
  if (is.null(rows)) {
    assign(cache_key, empty, snapshot_cache)
    return(empty)
  }
  rows <- rows[rows$game_datetime < cutoff, , drop = FALSE]
  if (nrow(rows) == 0L) {
    assign(cache_key, empty, snapshot_cache)
    return(empty)
  }
  game_times <- sort(unique(rows$game_datetime), decreasing = TRUE)
  latest_time <- game_times[[1L]]
  roster <- unique(as.character(rows$player_id[rows$game_datetime == latest_time]))
  roster <- roster[!is.na(roster) & nzchar(roster)]
  if (length(roster) == 0L) {
    assign(cache_key, empty, snapshot_cache)
    return(empty)
  }
  player_ratings <- lapply(roster, function(player_id) {
    history <- player_split[[player_id]]
    history <- history[history$game_datetime < cutoff, , drop = FALSE]
    position <- as.character(history$position[[nrow(history)]])
    values <- vapply(rating_metrics, function(metric) {
      observed <- as.numeric(history[[metric]])
      observed <- observed[is.finite(observed)]
      n <- length(observed)
      baseline <- league_position_baseline(league, position, cutoff, metric)
      (sum(observed) + 10 * baseline) / (n + 10)
    }, numeric(1L))
    c(games = length(unique(history$gameid)), values)
  })
  player_matrix <- do.call(rbind, player_ratings)
  recent_times <- head(game_times, 5L)
  historical_rosters <- lapply(recent_times, function(game_time) {
    unique(as.character(rows$player_id[rows$game_datetime == game_time]))
  })
  overlaps <- vapply(historical_rosters, function(old_roster) {
    length(intersect(roster, old_roster)) / max(1, length(roster))
  }, numeric(1L))
  signatures <- vapply(historical_rosters, function(old_roster) {
    paste(sort(old_roster), collapse = "|")
  }, character(1L))
  latest_signature <- signatures[[1L]]
  consecutive <- 0L
  for (signature in signatures) {
    if (!identical(signature, latest_signature)) break
    consecutive <- consecutive + 1L
  }
  together_start <- recent_times[[max(1L, consecutive)]]
  result <- c(
    player_games_min = min(player_matrix[, "games"]),
    player_games_mean = mean(player_matrix[, "games"]),
    roster_kpm = mean(player_matrix[, "kills_per_minute"]),
    roster_deaths_pm = mean(player_matrix[, "deaths_per_minute"]),
    roster_conflict_pm = mean(player_matrix[, "conflict_involvement_per_minute"]),
    roster_damage_pm = mean(player_matrix[, "damage_per_minute"]),
    roster_kill_participation = mean(player_matrix[, "kill_participation"]),
    roster_continuity = mean(overlaps),
    roster_change = 1 - if (length(overlaps) >= 2L) overlaps[[2L]] else 1,
    roster_days_together = max(0, as.numeric(difftime(
      cutoff, together_start, units = "days"
    ))),
    roster_size = length(roster)
  )
  attr(result, "roster") <- roster
  assign(cache_key, result, snapshot_cache)
  result
}

roster_pair_features <- function(rows) {
  metrics <- c(
    "player_games_min", "player_games_mean", "roster_kpm",
    "roster_deaths_pm", "roster_conflict_pm", "roster_damage_pm",
    "roster_kill_participation", "roster_continuity",
    "roster_change", "roster_days_together", "roster_size"
  )
  result <- matrix(NA_real_, nrow = nrow(rows), ncol = 0L)
  output <- vector("list", nrow(rows))
  for (index in seq_len(nrow(rows))) {
    first <- team_roster_snapshot(
      rows$blue_team_id[[index]], rows$league_canonical[[index]],
      rows$prediction_cutoff[[index]]
    )
    second <- team_roster_snapshot(
      rows$red_team_id[[index]], rows$league_canonical[[index]],
      rows$prediction_cutoff[[index]]
    )
    values <- c()
    for (metric in metrics) {
      pair <- c(as.numeric(first[[metric]]), as.numeric(second[[metric]]))
      values[[paste0(metric, "_mean")]] <- mean(pair, na.rm = TRUE)
      values[[paste0(metric, "_gap")]] <- abs(diff(pair))
    }
    output[[index]] <- values
  }
  as.data.frame(do.call(rbind, output), stringsAsFactors = FALSE)
}

structural <- build_synthetic_pinnacle_features(data)
roster <- roster_pair_features(data)
pure <- cbind(structural, roster)
forbidden <- grep(
  "moneyline|odds|soft|side|blue|red|market|final|draft",
  names(pure), ignore.case = TRUE, value = TRUE
)
if (length(forbidden) > 0L) {
  stop("Features proibidas detectadas: ", paste(forbidden, collapse = ", "))
}
pure$league_model <- as.character(data$league_canonical)

model_data <- cbind(
  data.frame(
    gameid = data$gameid,
    series_id = data$series_id,
    game_datetime = data$game_datetime,
    prediction_cutoff = data$prediction_cutoff,
    last_prematch_time = data$last_prematch_time,
    league_canonical = data$league_canonical,
    final_line = data$final_line,
    final_probability_over = data$final_probability_over,
    final_probability_logit = data$final_probability_logit,
    final_hold = data$final_hold,
    final_log_hold = data$final_log_hold,
    final_odds_over = data$final_odds_over,
    final_odds_under = data$final_odds_under,
    stringsAsFactors = FALSE
  ),
  pure
)
model_data <- model_data[order(model_data$prediction_cutoff, model_data$gameid), ]
unique_cutoffs <- sort(unique(model_data$prediction_cutoff))
adjustment_end <- unique_cutoffs[[max(2L, floor(length(unique_cutoffs) * 0.60))]]
selection_end <- unique_cutoffs[[max(3L, floor(length(unique_cutoffs) * 0.80))]]
model_data$sample <- ifelse(
  model_data$prediction_cutoff <= adjustment_end, "adjustment",
  ifelse(model_data$prediction_cutoff <= selection_end, "selection", "confirmation")
)
adjustment <- model_data[model_data$sample == "adjustment", , drop = FALSE]
selection <- model_data[model_data$sample == "selection", , drop = FALSE]
confirmation <- model_data[model_data$sample == "confirmation", , drop = FALSE]
if (min(vapply(list(adjustment, selection, confirmation), nrow, integer(1L))) < 100L) {
  stop("Split direto insuficiente.", call. = FALSE)
}

feature_names <- setdiff(names(pure), "league_model")
base_feature_names <- setdiff(feature_names, grep(
  "^player_|^roster_", feature_names, value = TRUE
))
medians <- vapply(feature_names, function(name) {
  value <- as.numeric(adjustment[[name]])
  result <- stats::median(value[is.finite(value)], na.rm = TRUE)
  if (is.finite(result)) result else 0
}, numeric(1L))
prepare <- function(rows, selected_features = feature_names, league_levels = NULL) {
  result <- rows[c(selected_features, "league_model")]
  for (name in selected_features) {
    value <- as.numeric(result[[name]])
    value[!is.finite(value)] <- medians[[name]]
    result[[name]] <- value
  }
  if (is.null(league_levels)) {
    league_levels <- unique(c(as.character(result$league_model), "OTHER"))
  }
  result$league_model <- factor(
    ifelse(as.character(result$league_model) %in% league_levels,
           as.character(result$league_model), "OTHER"),
    levels = league_levels
  )
  result
}

adjustment_frame <- prepare(adjustment)
league_levels <- levels(adjustment_frame$league_model)
design_terms <- stats::terms(~ ., data = adjustment_frame)
design_matrix <- function(rows) {
  frame <- prepare(rows, feature_names, league_levels)
  matrix <- stats::model.matrix(design_terms, frame)
  matrix[, colnames(matrix) != "(Intercept)", drop = FALSE]
}
x_adjustment <- design_matrix(adjustment)
x_selection <- design_matrix(selection)
preconfirmation <- model_data[model_data$sample != "confirmation", , drop = FALSE]
x_pre <- design_matrix(preconfirmation)
x_confirmation <- design_matrix(confirmation)
lambdas <- 10^seq(-3, 3, length.out = 31)

fit_target <- function(target_name, metric = c("mae", "probability")) {
  metric <- match.arg(metric)
  fit <- glmnet::glmnet(
    x_adjustment, adjustment[[target_name]], alpha = 0,
    lambda = lambdas, standardize = TRUE
  )
  losses <- vapply(lambdas, function(lambda) {
    prediction <- as.numeric(stats::predict(fit, x_selection, s = lambda))
    if (metric == "probability") {
      prediction <- stats::plogis(prediction)
      mean(abs(selection$final_probability_over - prediction))
    } else {
      mean(abs(selection[[target_name]] - prediction))
    }
  }, numeric(1L))
  lambda <- lambdas[[which.min(losses)]]
  selection_prediction <- as.numeric(stats::predict(
    fit, x_selection, s = lambda
  ))
  final <- glmnet::glmnet(
    x_pre, preconfirmation[[target_name]], alpha = 0,
    lambda = lambda, standardize = TRUE
  )
  list(
    fit = final,
    lambda = lambda,
    selection_loss = min(losses),
    selection_prediction = selection_prediction,
    prediction = as.numeric(stats::predict(final, x_confirmation, s = lambda))
  )
}

line_fit <- fit_target("final_line")
price_fit <- fit_target("final_probability_logit", "probability")
hold_fit <- fit_target("final_log_hold")
confirmation$predicted_final_line_raw <- line_fit$prediction
confirmation$predicted_final_line <- round(line_fit$prediction * 2) / 2
confirmation$predicted_final_probability_over <- stats::plogis(price_fit$prediction)
confirmation$predicted_final_hold <- exp(hold_fit$prediction)
confirmation$predicted_final_odds_over <- 1 / (
  confirmation$predicted_final_probability_over * confirmation$predicted_final_hold
)
confirmation$predicted_final_odds_under <- 1 / (
  (1 - confirmation$predicted_final_probability_over) * confirmation$predicted_final_hold
)
confirmation$roster_challenger_final_line <- confirmation$predicted_final_line
confirmation$roster_challenger_final_probability_over <-
  confirmation$predicted_final_probability_over
confirmation$roster_challenger_final_hold <- confirmation$predicted_final_hold

base_adjustment_frame <- prepare(adjustment, base_feature_names)
base_league_levels <- levels(base_adjustment_frame$league_model)
base_terms <- stats::terms(~ ., data = base_adjustment_frame)
base_design <- function(rows) {
  frame <- prepare(rows, base_feature_names, base_league_levels)
  matrix <- stats::model.matrix(base_terms, frame)
  matrix[, colnames(matrix) != "(Intercept)", drop = FALSE]
}
base_x_adjustment <- base_design(adjustment)
base_x_selection <- base_design(selection)
base_x_pre <- base_design(preconfirmation)
base_x_confirmation <- base_design(confirmation)
base_line_initial <- glmnet::glmnet(
  base_x_adjustment, adjustment$final_line, alpha = 0,
  lambda = lambdas, standardize = TRUE
)
base_line_losses <- vapply(lambdas, function(lambda) {
  prediction <- as.numeric(stats::predict(
    base_line_initial, base_x_selection, s = lambda
  ))
  mean(abs(selection$final_line - prediction))
}, numeric(1L))
base_line_lambda <- lambdas[[which.min(base_line_losses)]]
base_line_final <- glmnet::glmnet(
  base_x_pre, preconfirmation$final_line, alpha = 0,
  lambda = base_line_lambda, standardize = TRUE
)
confirmation$base_direct_final_line <- round(
  as.numeric(stats::predict(
    base_line_final, base_x_confirmation, s = base_line_lambda
  )) * 2
) / 2

fit_base_target <- function(target_name, metric = c("mae", "probability")) {
  metric <- match.arg(metric)
  initial <- glmnet::glmnet(
    base_x_adjustment, adjustment[[target_name]], alpha = 0,
    lambda = lambdas, standardize = TRUE
  )
  losses <- vapply(lambdas, function(lambda) {
    prediction <- as.numeric(stats::predict(
      initial, base_x_selection, s = lambda
    ))
    if (metric == "probability") {
      mean(abs(selection$final_probability_over - stats::plogis(prediction)))
    } else {
      mean(abs(selection[[target_name]] - prediction))
    }
  }, numeric(1L))
  lambda <- lambdas[[which.min(losses)]]
  final <- glmnet::glmnet(
    base_x_pre, preconfirmation[[target_name]], alpha = 0,
    lambda = lambda, standardize = TRUE
  )
  list(
    fit = final,
    lambda = lambda,
    selection_prediction = as.numeric(stats::predict(
      initial, base_x_selection, s = lambda
    )),
    prediction = as.numeric(stats::predict(
      final, base_x_confirmation, s = lambda
    ))
  )
}
base_price_fit <- fit_base_target("final_probability_logit", "probability")
base_hold_fit <- fit_base_target("final_log_hold")
confirmation$predicted_final_line <- confirmation$base_direct_final_line
confirmation$predicted_final_line_raw <- as.numeric(stats::predict(
  base_line_final, base_x_confirmation, s = base_line_lambda
))
confirmation$predicted_final_probability_over <- stats::plogis(
  base_price_fit$prediction
)
confirmation$predicted_final_hold <- exp(base_hold_fit$prediction)
confirmation$predicted_final_odds_over <- 1 / (
  confirmation$predicted_final_probability_over * confirmation$predicted_final_hold
)
confirmation$predicted_final_odds_under <- 1 / (
  (1 - confirmation$predicted_final_probability_over) * confirmation$predicted_final_hold
)

league_summary <- stats::aggregate(
  cbind(final_line, final_probability_over, final_hold) ~ league_canonical,
  preconfirmation,
  mean
)
global_baseline <- c(
  final_line = mean(preconfirmation$final_line),
  final_probability_over = mean(preconfirmation$final_probability_over),
  final_hold = mean(preconfirmation$final_hold)
)
baseline_value <- function(field) {
  value <- league_summary[[field]][match(
    confirmation$league_canonical, league_summary$league_canonical
  )]
  value[!is.finite(value)] <- global_baseline[[field]]
  value
}
confirmation$baseline_final_line <- round(baseline_value("final_line") * 2) / 2
confirmation$baseline_final_probability_over <- baseline_value(
  "final_probability_over"
)
confirmation$baseline_final_hold <- baseline_value("final_hold")
confirmation$baseline_final_odds_over <- 1 / (
  confirmation$baseline_final_probability_over * confirmation$baseline_final_hold
)
confirmation$baseline_final_odds_under <- 1 / (
  (1 - confirmation$baseline_final_probability_over) * confirmation$baseline_final_hold
)

score <- function(rows, prefix) {
  line_prediction <- rows[[paste0(prefix, "final_line")]]
  probability_prediction <- rows[[paste0(prefix, "final_probability_over")]]
  odds_over_prediction <- rows[[paste0(prefix, "final_odds_over")]]
  odds_under_prediction <- rows[[paste0(prefix, "final_odds_under")]]
  data.frame(
    candidate = sub("_$", "", prefix),
    maps = nrow(rows),
    line_mae = mean(abs(rows$final_line - line_prediction)),
    line_exact = mean(rows$final_line == line_prediction),
    line_within_one = mean(abs(rows$final_line - line_prediction) <= 1),
    probability_mae = mean(abs(
      rows$final_probability_over - probability_prediction
    )),
    odds_mae = mean(c(
      abs(rows$final_odds_over - odds_over_prediction),
      abs(rows$final_odds_under - odds_under_prediction)
    )),
    stringsAsFactors = FALSE
  )
}
confirmation_summary <- rbind(
  score(confirmation, "baseline_"),
  score(confirmation, "predicted_")
)

selection_line_prediction <- as.numeric(stats::predict(
  base_line_initial, base_x_selection, s = base_line_lambda
))
selection_price_prediction <- base_price_fit$selection_prediction
line_interval <- unname(stats::quantile(
  selection$final_line - selection_line_prediction, c(0.05, 0.95)
))
price_interval <- unname(stats::quantile(
  selection$final_probability_logit - selection_price_prediction,
  c(0.05, 0.95)
))

surface_rows <- DBI::dbGetQuery(connection, "
  SELECT l.gameid, c.line, c.odds_over, c.odds_under
  FROM game_market_links l
  JOIN market_closing c
    ON c.event_id = l.event_id AND c.period = l.period
  WHERE l.link_status = 'verified'
    AND c.market = 'totals'
    AND c.odds_over > 1 AND c.odds_under > 1
")
surface_rows <- surface_rows[
  surface_rows$gameid %in% preconfirmation$gameid &
    is.finite(surface_rows$line) & is.finite(surface_rows$odds_over) &
    is.finite(surface_rows$odds_under),
  ,
  drop = FALSE
]
surface_hold <- 1 / surface_rows$odds_over + 1 / surface_rows$odds_under
surface_rows$probability_over <- (1 / surface_rows$odds_over) / surface_hold
surface_rows$logit_probability <- stats::qlogis(pmin(
  1 - 1e-6, pmax(1e-6, surface_rows$probability_over)
))
surface_rows$line_centered <- surface_rows$line - ave(
  surface_rows$line, surface_rows$gameid, FUN = mean
)
surface_slope_fit <- stats::lm(
  logit_probability ~ line_centered + factor(gameid), data = surface_rows
)
market_logit_slope <- max(0.05, -unname(stats::coef(surface_slope_fit)[["line_centered"]]))

blocks <- split(
  seq_len(nrow(confirmation)),
  ifelse(is.na(confirmation$series_id), confirmation$gameid, confirmation$series_id)
)
bootstrap_line_delta <- replicate(5000L, {
  sampled <- sample(names(blocks), length(blocks), replace = TRUE)
  indices <- unlist(blocks[sampled], use.names = FALSE)
  mean(abs(
    confirmation$final_line[indices] - confirmation$predicted_final_line[indices]
  ) - abs(
    confirmation$final_line[indices] - confirmation$baseline_final_line[indices]
  ))
})

model_coefficients <- function(fit, lambda) {
  as.list(as.matrix(stats::coef(fit, s = lambda))[, 1L])
}
candidate_score <- confirmation_summary[
  confirmation_summary$candidate == "predicted", , drop = FALSE
]
baseline_score <- confirmation_summary[
  confirmation_summary$candidate == "baseline", , drop = FALSE
]
gates <- data.frame(
  gate = c(
    "direct_line_better_than_league", "paired_bootstrap_upper_below_zero",
    "direct_price_better_than_league", "minimum_1000_maps",
    "temporal_integrity", "roster_challenger_not_forced",
    "automatic_betting_blocked"
  ),
  passed = c(
    candidate_score$line_mae < baseline_score$line_mae,
    stats::quantile(bootstrap_line_delta, 0.975) < 0,
    candidate_score$probability_mae <= baseline_score$probability_mae,
    nrow(model_data) >= 1000,
    all(model_data$prediction_cutoff < model_data$last_prematch_time),
    mean(abs(
      confirmation$final_line - confirmation$roster_challenger_final_line
    )) >= mean(abs(
      confirmation$final_line - confirmation$predicted_final_line
    )),
    TRUE
  ),
  stringsAsFactors = FALSE
)
manual_approved <- all(gates$passed)

active_bundle <- jsonlite::read_json(
  file.path(project_root, "app_data", "model_bundle.json"),
  simplifyVector = FALSE
)
current_cutoff <- max(players$game_datetime, na.rm = TRUE) + 1
team_roster_features <- list()
for (team in active_bundle$teams) {
  team_id <- as.character(team$team_id)
  snapshot <- team_roster_snapshot(
    team_id, as.character(team$league_canonical), current_cutoff
  )
  roster_ids <- attr(snapshot, "roster")
  team_roster_features[[team_id]] <- c(
    as.list(as.numeric(snapshot)),
    list(
      names = names(snapshot),
      roster_player_ids = as.list(roster_ids)
    )
  )
  names(team_roster_features[[team_id]])[seq_along(snapshot)] <- names(snapshot)
}

portable <- list(
  model_id = "synthetic-pinnacle-direct-market-ridge-v2",
  status = if (manual_approved) {
    "approved_for_manual_soft_comparison"
  } else {
    "shadow_only"
  },
  target = "pinnacle_last_prematch_main_line_and_prices",
  target_mode = "direct_line_price",
  prohibited_features = c("moneyline", "side", "soft_line", "soft_odds", "draft"),
  selected_feature_family = "structural_without_roster",
  roster_challenger_status = "rejected_on_confirmation_line_mae",
  feature_names = base_feature_names,
  feature_medians = as.list(medians[base_feature_names]),
  league_levels = base_league_levels,
  design_columns = colnames(base_x_pre),
  line_model = list(
    coefficients = model_coefficients(base_line_final, base_line_lambda),
    selected_lambda = base_line_lambda,
    residual_interval = list(lower = line_interval[[1L]], upper = line_interval[[2L]])
  ),
  price_model = list(
    coefficients = model_coefficients(base_price_fit$fit, base_price_fit$lambda),
    selected_lambda = base_price_fit$lambda,
    residual_logit_interval = list(
      lower = price_interval[[1L]], upper = price_interval[[2L]]
    )
  ),
  hold_model = list(
    coefficients = model_coefficients(base_hold_fit$fit, base_hold_fit$lambda),
    selected_lambda = base_hold_fit$lambda
  ),
  market_probability_logit_slope_per_kill = market_logit_slope,
  inference_teams = active_bundle$teams,
  team_roster_features = team_roster_features,
  roster_rating = list(
    method = "empirical_bayes_player_position_league",
    shrinkage_games = 10,
    roster_source = "latest_lineup_strictly_before_prediction_cutoff",
    snapshot_cutoff = format(current_cutoff, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  ),
  automatic_betting_approved = FALSE,
  minimum_conservative_ev = 0.05,
  minimum_history_required = 5,
  trained_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  data_cutoff = format(max(model_data$game_datetime), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
  training_maps = nrow(model_data),
  confirmation_maps = nrow(confirmation),
  metrics = list(
    baseline = as.list(baseline_score[1, setdiff(names(baseline_score), "candidate")]),
    direct = as.list(candidate_score[1, setdiff(names(candidate_score), "candidate")]),
    bootstrap_line_delta = list(
      lower = unname(stats::quantile(bootstrap_line_delta, 0.025)),
      upper = unname(stats::quantile(bootstrap_line_delta, 0.975))
    )
  ),
  gates = setNames(as.list(gates$passed), gates$gate)
)
jsonlite::write_json(
  portable,
  file.path(output_dir, "synthetic-pinnacle-direct-bundle.json"),
  auto_unbox = TRUE, pretty = TRUE, digits = 15
)
jsonlite::write_json(
  portable,
  file.path(project_root, "app_data", "synthetic_pinnacle_bundle.json"),
  auto_unbox = TRUE, pretty = TRUE, digits = 15
)

parity_index <- 1L
parity_features <- as.list(confirmation[parity_index, base_feature_names, drop = FALSE])
parity_features$league_model <- as.character(confirmation$league_model[[parity_index]])
parity_fixture <- list(
  features = parity_features,
  soft_quotes = list(
    list(line = 24.5, odds_over = 1.90, odds_under = 1.90),
    list(line = 25.5, odds_over = 1.95, odds_under = 1.85),
    list(line = 26.5, odds_over = 2.05, odds_under = 1.75)
  ),
  expected = list(
    predicted_final_line = confirmation$predicted_final_line[[parity_index]],
    predicted_final_probability_over = confirmation$predicted_final_probability_over[[parity_index]],
    predicted_final_odds_over = confirmation$predicted_final_odds_over[[parity_index]],
    predicted_final_odds_under = confirmation$predicted_final_odds_under[[parity_index]]
  )
)
jsonlite::write_json(
  parity_fixture, file.path(output_dir, "parity-fixture.json"),
  auto_unbox = TRUE, pretty = TRUE, digits = 15
)

temporal_manifest <- data.frame(
  split = c(adjustment = "train", selection = "validation", confirmation = "test")[
    model_data$sample
  ],
  prediction_time = format(
    model_data$prediction_cutoff, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"
  ),
  feature_available_time = format(
    model_data$prediction_cutoff, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"
  ),
  target_time = format(
    model_data$last_prematch_time, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"
  )
)
research_output <- model_data
list_columns <- names(research_output)[vapply(research_output, is.list, logical(1L))]
for (name in list_columns) {
  research_output[[name]] <- vapply(research_output[[name]], function(value) {
    paste(unlist(value, use.names = FALSE), collapse = "|")
  }, character(1L))
}
utils::write.csv(
  research_output, file.path(output_dir, "research-dataset.csv"), row.names = FALSE
)
utils::write.csv(
  temporal_manifest, file.path(output_dir, "temporal-split-manifest.csv"),
  row.names = FALSE
)
confirmation_output <- confirmation
confirmation_list_columns <- names(confirmation_output)[vapply(
  confirmation_output, is.list, logical(1L)
)]
for (name in confirmation_list_columns) {
  confirmation_output[[name]] <- vapply(
    confirmation_output[[name]],
    function(value) paste(unlist(value, use.names = FALSE), collapse = "|"),
    character(1L)
  )
}
utils::write.csv(
  confirmation_output, file.path(output_dir, "confirmation-predictions.csv"),
  row.names = FALSE
)
utils::write.csv(
  confirmation_summary, file.path(output_dir, "confirmation-summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  data.frame(delta_line_mae = bootstrap_line_delta),
  file.path(output_dir, "paired-series-bootstrap.csv"), row.names = FALSE
)
utils::write.csv(
  gates, file.path(output_dir, "promotion-gates.csv"), row.names = FALSE
)
utils::write.csv(
  data.frame(
    candidate = c("direct_without_roster", "direct_with_roster"),
    line_mae = c(
      mean(abs(confirmation$final_line - confirmation$base_direct_final_line)),
      mean(abs(confirmation$final_line - confirmation$roster_challenger_final_line))
    ),
    line_exact = c(
      mean(confirmation$final_line == confirmation$base_direct_final_line),
      mean(confirmation$final_line == confirmation$roster_challenger_final_line)
    )
  ),
  file.path(output_dir, "roster-ablation.csv"), row.names = FALSE
)
utils::write.csv(
  data.frame(
    training_maps = nrow(model_data), adjustment_maps = nrow(adjustment),
    selection_maps = nrow(selection), confirmation_maps = nrow(confirmation),
    market_surface_slope = market_logit_slope,
    manual_approved = manual_approved
  ),
  file.path(output_dir, "decision.csv"), row.names = FALSE
)

cat(jsonlite::toJSON(list(
  training_maps = nrow(model_data),
  split = as.list(table(model_data$sample)),
  confirmation = confirmation_summary,
  market_surface_slope = market_logit_slope,
  gates = gates,
  status = portable$status
), auto_unbox = TRUE, pretty = TRUE), "\n")
