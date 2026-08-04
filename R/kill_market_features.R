.safe_ratio <- function(numerator, denominator) {
  result <- as.numeric(numerator) / as.numeric(denominator)
  result[!is.finite(result)] <- NA_real_
  result
}

#' Derive team-map outcomes used to learn kill-market behavior
#'
#' @param team_metrics Team-map metrics.
#' @return Team-map metrics with rate, conversion and game-state outcomes.
#' @export
derive_kill_market_outcomes <- function(team_metrics) {
  required <- c(
    "gameid",
    "game_length_minutes",
    "result",
    "team_kills",
    "team_deaths",
    "total_kills_game",
    "assists",
    "dragons",
    "barons",
    "heralds",
    "towers",
    "damage_to_champions",
    "kills_at_10",
    "deaths_at_10",
    "combined_kills_at_15",
    "gold_diff_at_15"
  )
  missing <- setdiff(required, names(team_metrics))
  if (length(missing) > 0L) {
    stop(
      "Missing kill-market outcome columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  result <- team_metrics
  duration <- as.numeric(result$game_length_minutes)
  total_kills <- as.numeric(result$total_kills_game)
  damage_by_game <- stats::ave(
    as.numeric(result$damage_to_champions),
    as.character(result$gameid),
    FUN = function(values) sum(values[is.finite(values)])
  )
  result$assists_per_minute <- .safe_ratio(result$assists, duration)
  result$early_pace_10 <- .safe_ratio(
    as.numeric(result$kills_at_10) + as.numeric(result$deaths_at_10),
    10
  )
  result$early_pace_15 <- .safe_ratio(result$combined_kills_at_15, 15)
  result$post_15_pace <- .safe_ratio(
    total_kills - as.numeric(result$combined_kills_at_15),
    duration - 15
  )
  result$post_15_pace[duration <= 15] <- NA_real_
  result$damage_kill_conversion <- .safe_ratio(
    total_kills,
    damage_by_game / 1000
  )
  result$objectives_per_minute <- .safe_ratio(
    as.numeric(result$dragons) +
      as.numeric(result$barons) +
      as.numeric(result$heralds) +
      as.numeric(result$towers),
    duration
  )
  result$major_objectives_per_minute <- .safe_ratio(
    as.numeric(result$dragons) + as.numeric(result$barons),
    duration
  )
  result$dragons_per_minute <- .safe_ratio(result$dragons, duration)
  result$barons_per_minute <- .safe_ratio(result$barons, duration)
  result$towers_per_minute <- .safe_ratio(result$towers, duration)
  result$absolute_gold_lead_15 <- abs(as.numeric(result$gold_diff_at_15))
  ahead <- as.numeric(result$gold_diff_at_15) > 0
  behind <- as.numeric(result$gold_diff_at_15) < 0
  won <- as.numeric(result$result) == 1
  result$duration_when_ahead <- ifelse(ahead, duration, NA_real_)
  result$duration_when_behind <- ifelse(behind, duration, NA_real_)
  result$duration_when_winning <- ifelse(won, duration, NA_real_)
  result$duration_when_losing <- ifelse(!won, duration, NA_real_)
  result$close_minutes_when_ahead <- ifelse(ahead & won, duration, NA_real_)
  result$stall_minutes_when_behind <- ifelse(behind, duration, NA_real_)
  result$lead_conversion <- ifelse(ahead, as.numeric(won), NA_real_)
  result
}

#' List outcomes used in multiscale kill-market histories
#'
#' @return Character vector of metric names.
#' @export
kill_market_metric_names <- function() {
  c(
    "kills_per_minute",
    "deaths_per_minute",
    "combined_kills_per_minute",
    "game_length_minutes",
    "assists_per_minute",
    "early_pace_10",
    "early_pace_15",
    "post_15_pace",
    "damage_per_minute",
    "damage_taken_per_minute",
    "damage_kill_conversion",
    "objectives_per_minute",
    "major_objectives_per_minute",
    "dragons_per_minute",
    "barons_per_minute",
    "towers_per_minute",
    "absolute_gold_lead_15",
    "duration_when_ahead",
    "duration_when_behind",
    "duration_when_winning",
    "duration_when_losing",
    "close_minutes_when_ahead",
    "stall_minutes_when_behind",
    "lead_conversion"
  )
}

.rename_history_window <- function(data, window) {
  prefixes <- c(
    "hist_",
    "effective_",
    "league_prior_",
    "global_prior_",
    "league_peer_prior_",
    "global_peer_prior_"
  )
  for (prefix in prefixes) {
    matched <- startsWith(names(data), prefix)
    names(data)[matched] <- sub(
      paste0("^", prefix),
      paste0(prefix, window, "_"),
      names(data)[matched]
    )
  }
  data
}

.build_kill_market_window <- function(
  outcomes,
  metric_names,
  half_life_days,
  prior_games
) {
  rows <- outcomes[
    outcomes$competition_role %in% c("target", "auxiliary") &
      !is.na(outcomes$game_datetime) &
      !is.na(outcomes$series_cutoff),
    ,
    drop = FALSE
  ]
  rows$.original_index <- seq_len(nrow(rows))
  team_keys <- mapply(
    .rolling_team_key,
    rows$team_id,
    rows$team_name,
    USE.NAMES = FALSE
  )
  team_levels <- unique(team_keys)
  league_keys <- as.character(rows$league_canonical)
  league_levels <- unique(league_keys)
  team_index <- match(team_keys, team_levels)
  league_index <- match(league_keys, league_levels)
  metric_values <- as.matrix(data.frame(
    lapply(rows[metric_names], as.numeric),
    check.names = FALSE
  ))
  metric_count <- length(metric_names)
  team_sum <- matrix(0, length(team_levels), metric_count)
  team_weight <- matrix(0, length(team_levels), metric_count)
  team_last <- rep(NA_real_, length(team_levels))
  league_sum <- matrix(0, length(league_levels), metric_count)
  league_weight <- matrix(0, length(league_levels), metric_count)
  league_last <- rep(NA_real_, length(league_levels))
  global_sum <- numeric(metric_count)
  global_weight <- numeric(metric_count)
  global_last <- NA_real_
  raw_games <- integer(length(team_levels))
  raw_last <- rep(NA_real_, length(team_levels))
  outcome_order <- order(rows$game_datetime, rows$gameid, rows$side)
  target_index <- which(rows$competition_role == "target")
  query_order <- target_index[
    order(
      rows$series_cutoff[target_index],
      rows$gameid[target_index],
      rows$side[target_index]
    )
  ]
  features <- rows[query_order, c(
    "gameid",
    "game_datetime",
    "series_cutoff",
    "league_canonical",
    "side",
    "team_id",
    "team_name"
  ), drop = FALSE]
  features$.original_index <- rows$.original_index[query_order]
  features$raw_team_games <- integer(nrow(features))
  features$latest_history_datetime <- as.POSIXct(
    rep(NA_real_, nrow(features)),
    origin = "1970-01-01",
    tz = "UTC"
  )
  historical <- matrix(
    NA_real_,
    nrow(features),
    metric_count,
    dimnames = list(NULL, paste0("hist_", metric_names))
  )
  effective <- matrix(
    NA_real_,
    nrow(features),
    metric_count,
    dimnames = list(
      NULL,
      paste0("effective_", metric_names, "_games")
    )
  )
  league_priors <- matrix(
    NA_real_,
    nrow(features),
    metric_count,
    dimnames = list(NULL, paste0("league_prior_", metric_names))
  )
  global_priors <- matrix(
    NA_real_,
    nrow(features),
    metric_count,
    dimnames = list(NULL, paste0("global_prior_", metric_names))
  )
  decay_to <- function(sum, weight, last, timestamp) {
    if (!is.finite(last)) {
      return(list(sum = sum, weight = weight))
    }
    factor <- 0.5^((timestamp - last) / 86400 / half_life_days)
    list(sum = sum * factor, weight = weight * factor)
  }
  outcome_pointer <- 1L
  for (query_position in seq_along(query_order)) {
    row_index <- query_order[[query_position]]
    cutoff <- as.numeric(rows$series_cutoff[[row_index]])
    while (
      outcome_pointer <= length(outcome_order) &&
        as.numeric(rows$game_datetime[[outcome_order[[outcome_pointer]]]]) <
          cutoff
    ) {
      outcome_index <- outcome_order[[outcome_pointer]]
      timestamp <- as.numeric(rows$game_datetime[[outcome_index]])
      team <- team_index[[outcome_index]]
      league <- league_index[[outcome_index]]
      values <- metric_values[outcome_index, ]
      finite <- is.finite(values)
      decayed_team <- decay_to(
        team_sum[team, ],
        team_weight[team, ],
        team_last[[team]],
        timestamp
      )
      team_sum[team, ] <- decayed_team$sum
      team_weight[team, ] <- decayed_team$weight
      team_sum[team, finite] <- team_sum[team, finite] + values[finite]
      team_weight[team, finite] <- team_weight[team, finite] + 1
      team_last[[team]] <- timestamp
      if (rows$competition_role[[outcome_index]] == "target") {
        decayed_league <- decay_to(
          league_sum[league, ],
          league_weight[league, ],
          league_last[[league]],
          timestamp
        )
        league_sum[league, ] <- decayed_league$sum
        league_weight[league, ] <- decayed_league$weight
        league_sum[league, finite] <-
          league_sum[league, finite] + values[finite]
        league_weight[league, finite] <-
          league_weight[league, finite] + 1
        league_last[[league]] <- timestamp
        decayed_global <- decay_to(
          global_sum,
          global_weight,
          global_last,
          timestamp
        )
        global_sum <- decayed_global$sum
        global_weight <- decayed_global$weight
        global_sum[finite] <- global_sum[finite] + values[finite]
        global_weight[finite] <- global_weight[finite] + 1
        global_last <- timestamp
      }
      raw_games[[team]] <- raw_games[[team]] + 1L
      raw_last[[team]] <- timestamp
      outcome_pointer <- outcome_pointer + 1L
    }
    team <- team_index[[row_index]]
    league <- league_index[[row_index]]
    team_state <- decay_to(
      team_sum[team, ],
      team_weight[team, ],
      team_last[[team]],
      cutoff
    )
    league_state <- decay_to(
      league_sum[league, ],
      league_weight[league, ],
      league_last[[league]],
      cutoff
    )
    global_state <- decay_to(
      global_sum,
      global_weight,
      global_last,
      cutoff
    )
    league_mean <- .safe_ratio(
      league_state$sum,
      league_state$weight
    )
    global_mean <- .safe_ratio(
      global_state$sum,
      global_state$weight
    )
    prior_mean <- league_mean
    prior_mean[!is.finite(prior_mean)] <-
      global_mean[!is.finite(prior_mean)]
    estimate <- .safe_ratio(
      team_state$sum + prior_games * prior_mean,
      team_state$weight + prior_games
    )
    no_prior <- !is.finite(estimate) & team_state$weight > 0
    estimate[no_prior] <- team_state$sum[no_prior] /
      team_state$weight[no_prior]
    historical[query_position, ] <- estimate
    effective[query_position, ] <- team_state$weight
    league_priors[query_position, ] <- prior_mean
    global_priors[query_position, ] <- global_mean
    features$raw_team_games[[query_position]] <- raw_games[[team]]
    if (is.finite(raw_last[[team]])) {
      features$latest_history_datetime[[query_position]] <-
        as.POSIXct(raw_last[[team]], origin = "1970-01-01", tz = "UTC")
    }
  }
  features <- cbind(
    features,
    as.data.frame(historical, check.names = FALSE),
    as.data.frame(effective, check.names = FALSE),
    as.data.frame(league_priors, check.names = FALSE),
    as.data.frame(global_priors, check.names = FALSE)
  )
  features <- features[
    order(features$.original_index),
    ,
    drop = FALSE
  ]
  features$.original_index <- NULL
  rownames(features) <- NULL
  features
}

#' Build short, medium and long frozen histories for kill markets
#'
#' @param team_metrics Team-map metrics.
#' @param half_lives Named half-lives in days.
#' @param prior_games League-prior effective games.
#' @return Frozen multiscale team features.
#' @export
build_kill_market_multiscale_features <- function(
  team_metrics,
  half_lives = c(short = 30, medium = 60, long = 120),
  prior_games = 10
) {
  if (
    is.null(names(half_lives)) ||
      !all(c("short", "medium", "long") %in% names(half_lives)) ||
      any(!is.finite(half_lives)) ||
      any(half_lives <= 0)
  ) {
    stop(
      "Kill-market half-lives require positive short, medium and long values.",
      call. = FALSE
    )
  }
  outcomes <- derive_kill_market_outcomes(team_metrics)
  metrics <- kill_market_metric_names()
  windows <- lapply(names(half_lives), function(window) {
    history <- .build_kill_market_window(
      outcomes,
      metrics,
      half_life_days = half_lives[[window]],
      prior_games = prior_games
    )
    .rename_history_window(history, window)
  })
  names(windows) <- names(half_lives)
  identity <- c(
    "gameid",
    "game_datetime",
    "series_cutoff",
    "league_canonical",
    "side",
    "team_id",
    "team_name"
  )
  result <- windows[[1L]]
  names(result)[names(result) == "raw_team_games"] <-
    paste0("raw_team_games_", names(windows)[[1L]])
  for (window in names(windows)[-1L]) {
    addition <- windows[[window]]
    names(addition)[names(addition) == "raw_team_games"] <-
      paste0("raw_team_games_", window)
    addition$latest_history_datetime <- NULL
    addition <- addition[c(
      identity,
      setdiff(names(addition), identity)
    )]
    result <- merge(
      result,
      addition,
      by = identity,
      all = TRUE,
      sort = FALSE
    )
  }
  result <- result[
    order(result$game_datetime, result$gameid, result$side),
    ,
    drop = FALSE
  ]
  rownames(result) <- NULL
  result
}

.map_pair_mean <- function(data, base, window) {
  blue <- data[[paste0("blue_hist_", window, "_", base)]]
  red <- data[[paste0("red_hist_", window, "_", base)]]
  (as.numeric(blue) + as.numeric(red)) / 2
}

.map_pair_difference <- function(data, base, window) {
  blue <- data[[paste0("blue_hist_", window, "_", base)]]
  red <- data[[paste0("red_hist_", window, "_", base)]]
  abs(as.numeric(blue) - as.numeric(red))
}

#' Assemble matchup features for total-kills distributions
#'
#' @param maps Map table with Blue and Red multiscale histories.
#' @return Map table with intensity, duration, trend and ratio features.
#' @export
assemble_kill_market_map_features <- function(maps) {
  required_bases <- c(
    "kills_per_minute",
    "deaths_per_minute",
    "game_length_minutes",
    "early_pace_15",
    "post_15_pace",
    "damage_per_minute",
    "damage_taken_per_minute",
    "objectives_per_minute",
    "assists_per_minute",
    "close_minutes_when_ahead",
    "stall_minutes_when_behind",
    "lead_conversion",
    "absolute_gold_lead_15"
  )
  windows <- c("short", "medium", "long")
  required <- unlist(lapply(windows, function(window) {
    unlist(lapply(required_bases, function(base) {
      paste0(c("blue_", "red_"), "hist_", window, "_", base)
    }))
  }))
  missing <- setdiff(required, names(maps))
  if (length(missing) > 0L) {
    stop(
      "Missing kill-market map columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  result <- maps
  for (window in windows) {
    blue_attack <- as.numeric(
      result[[paste0("blue_hist_", window, "_kills_per_minute")]]
    )
    red_attack <- as.numeric(
      result[[paste0("red_hist_", window, "_kills_per_minute")]]
    )
    blue_defense <- as.numeric(
      result[[paste0("blue_hist_", window, "_deaths_per_minute")]]
    )
    red_defense <- as.numeric(
      result[[paste0("red_hist_", window, "_deaths_per_minute")]]
    )
    blue_expected <- (blue_attack + red_defense) / 2
    red_expected <- (red_attack + blue_defense) / 2
    result[[paste0("kill_intensity_", window)]] <-
      blue_expected + red_expected
    result[[paste0("kill_intensity_imbalance_", window)]] <-
      abs(blue_expected - red_expected)
    result[[paste0("duration_level_", window)]] <-
      .map_pair_mean(result, "game_length_minutes", window)
    result[[paste0("duration_imbalance_", window)]] <-
      .map_pair_difference(result, "game_length_minutes", window)
    result[[paste0("early_pace_", window)]] <-
      .map_pair_mean(result, "early_pace_15", window)
    result[[paste0("post_15_pace_", window)]] <-
      .map_pair_mean(result, "post_15_pace", window)
    result[[paste0("damage_pressure_", window)]] <- (
      .map_pair_mean(result, "damage_per_minute", window) +
        .map_pair_mean(result, "damage_taken_per_minute", window)
    ) / 2
    result[[paste0("objective_activity_", window)]] <-
      .map_pair_mean(result, "objectives_per_minute", window)
    result[[paste0("assist_activity_", window)]] <-
      .map_pair_mean(result, "assists_per_minute", window)
    result[[paste0("close_speed_", window)]] <-
      .map_pair_mean(result, "close_minutes_when_ahead", window)
    result[[paste0("stall_capacity_", window)]] <-
      .map_pair_mean(result, "stall_minutes_when_behind", window)
    result[[paste0("lead_conversion_", window)]] <-
      .map_pair_mean(result, "lead_conversion", window)
    result[[paste0("early_lead_size_", window)]] <-
      .map_pair_mean(result, "absolute_gold_lead_15", window)
  }
  result$kill_intensity_trend <-
    result$kill_intensity_short - result$kill_intensity_long
  result$kill_intensity_ratio <- .safe_ratio(
    result$kill_intensity_short,
    result$kill_intensity_long
  )
  result$duration_trend <-
    result$duration_level_short - result$duration_level_long
  result$duration_ratio <- .safe_ratio(
    result$duration_level_short,
    result$duration_level_long
  )
  result$early_pace_trend <-
    result$early_pace_short - result$early_pace_long
  result$post_15_pace_trend <-
    result$post_15_pace_short - result$post_15_pace_long
  result$damage_pressure_trend <-
    result$damage_pressure_short - result$damage_pressure_long
  result$objective_activity_trend <-
    result$objective_activity_short - result$objective_activity_long
  result$close_stall_balance_medium <-
    result$stall_capacity_medium - result$close_speed_medium
  result
}
