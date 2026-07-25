.tracking_ema <- function(values, span) {
  alpha <- 2 / (as.numeric(span) + 1)
  result <- rep(NA_real_, length(values))
  for (index in seq_along(values)) {
    value <- as.numeric(values[[index]])
    if (!is.finite(value)) {
      result[[index]] <- if (index > 1L) result[[index - 1L]] else NA_real_
    } else if (index == 1L || !is.finite(result[[index - 1L]])) {
      result[[index]] <- value
    } else {
      result[[index]] <- alpha * value +
        (1 - alpha) * result[[index - 1L]]
    }
  }
  result
}

.tracking_rolling_slope <- function(period, values, window) {
  result <- rep(NA_real_, length(values))
  dates <- as.numeric(as.Date(period)) / 7
  for (index in seq_along(values)) {
    start <- max(1L, index - as.integer(window) + 1L)
    selected <- seq.int(start, index)
    valid <- is.finite(dates[selected]) & is.finite(values[selected])
    if (sum(valid) < 3L) {
      next
    }
    x <- dates[selected][valid]
    y <- values[selected][valid]
    denominator <- sum((x - mean(x))^2)
    result[[index]] <- if (denominator > 0) {
      sum((x - mean(x)) * (y - mean(y))) / denominator
    } else {
      0
    }
  }
  result
}

.tracking_rolling_volatility <- function(values, window) {
  changes <- rep(NA_real_, length(values))
  if (length(values) > 1L) {
    valid <- is.finite(values[-1L]) &
      is.finite(values[-length(values)]) &
      values[-1L] > 0 &
      values[-length(values)] > 0
    changes[-1L][valid] <- 100 * log(
      values[-1L][valid] / values[-length(values)][valid]
    )
  }
  result <- rep(NA_real_, length(values))
  for (index in seq_along(values)) {
    start <- max(1L, index - as.integer(window) + 1L)
    selected <- changes[seq.int(start, index)]
    selected <- selected[is.finite(selected)]
    result[[index]] <- if (length(selected) <= 1L) {
      if (length(selected) == 1L) 0 else NA_real_
    } else {
      stats::sd(selected)
    }
  }
  result
}

.tracking_regime <- function(index, momentum, trend) {
  result <- rep("insufficient", length(index))
  valid <- is.finite(index) & is.finite(momentum) & is.finite(trend)
  balanced <- valid & abs(momentum) < 0.5 & abs(trend) < 0.25
  result[balanced] <- "balanced"
  result[valid & !balanced & index >= 100 & trend >= 0] <-
    "hot_accelerating"
  result[valid & !balanced & index >= 100 & trend < 0] <-
    "hot_cooling"
  result[valid & !balanced & index < 100 & trend < 0] <-
    "cold_deteriorating"
  result[valid & !balanced & index < 100 & trend >= 0] <-
    "cold_recovering"
  result
}

#' Compute causal indicators for one time series
#'
#' @param period Ordered dates.
#' @param value Positive observed values.
#' @param short_span Short exponential moving-average span.
#' @param long_span Long exponential moving-average span.
#' @param trend_window Rolling trend window in observations.
#' @param volatility_window Rolling log-change volatility window.
#' @return Data frame of normalized level, momentum, trend and regime.
#' @export
compute_time_series_indicators <- function(
  period,
  value,
  short_span = 4,
  long_span = 12,
  trend_window = 8,
  volatility_window = 8
) {
  if (
    length(period) != length(value) ||
      length(value) == 0L ||
      short_span < 2 ||
      long_span <= short_span ||
      trend_window < 3 ||
      volatility_window < 2
  ) {
    stop("Time-series indicator parameters are invalid.", call. = FALSE)
  }
  ordering <- order(as.Date(period))
  if (!identical(ordering, seq_along(ordering))) {
    stop("Time-series periods must be ordered.", call. = FALSE)
  }
  values <- as.numeric(value)
  short_level <- .tracking_ema(values, short_span)
  long_level <- .tracking_ema(values, long_span)
  normalized <- rep(NA_real_, length(values))
  valid <- is.finite(short_level) &
    is.finite(long_level) &
    long_level > 0
  normalized[valid] <- 100 * short_level[valid] / long_level[valid]
  momentum <- normalized - 100
  raw_trend <- .tracking_rolling_slope(
    period,
    short_level,
    trend_window
  )
  trend <- rep(NA_real_, length(raw_trend))
  trend_valid <- is.finite(raw_trend) &
    is.finite(long_level) &
    long_level > 0
  trend[trend_valid] <- 100 *
    raw_trend[trend_valid] /
    long_level[trend_valid]
  volatility <- .tracking_rolling_volatility(values, volatility_window)
  data.frame(
    short_level = short_level,
    long_level = long_level,
    normalized_index = normalized,
    momentum_percent = momentum,
    trend_per_week = trend,
    volatility_percent = volatility,
    regime = .tracking_regime(normalized, momentum, trend),
    observations = seq_along(values),
    stringsAsFactors = FALSE
  )
}

.tracking_week <- function(values) {
  as.Date(cut(
    as.Date(values),
    breaks = "week",
    start.on.monday = TRUE
  ))
}

.tracking_weekly_metrics <- function(
  data,
  entity_type,
  date_column,
  entity_column,
  metric_names
) {
  rows <- lapply(metric_names, function(metric) {
    frame <- data.frame(
      period = .tracking_week(data[[date_column]]),
      entity_type = entity_type,
      league_canonical = as.character(data$league_canonical),
      entity_name = as.character(data[[entity_column]]),
      metric = metric,
      value = as.numeric(data[[metric]]),
      stringsAsFactors = FALSE
    )
    frame <- frame[
      !is.na(frame$period) &
        !is.na(frame$entity_name) &
        nzchar(frame$entity_name) &
        is.finite(frame$value),
      ,
      drop = FALSE
    ]
    stats::aggregate(
      value ~ period + entity_type + league_canonical +
        entity_name + metric,
      data = frame,
      FUN = mean
    )
  })
  do.call(rbind, rows)
}

#' Build normalized weekly tracking series
#'
#' @param games Canonical map rows.
#' @param team_metrics Team-map outcome metrics.
#' @param dynamic_ratings Frozen pre-series team ratings.
#' @param min_date Earliest included calendar date.
#' @return Long weekly league and team time series with causal indicators.
#' @export
build_tracking_time_series <- function(
  games,
  team_metrics,
  dynamic_ratings,
  min_date = as.Date("2022-01-01")
) {
  game_required <- c(
    "gameid",
    "game_datetime",
    "league_canonical",
    "competition_role",
    "total_kills_game",
    "game_length_seconds"
  )
  team_required <- c(
    "game_datetime",
    "league_canonical",
    "competition_role",
    "team_name",
    "kills_per_minute",
    "deaths_per_minute",
    "combined_kills_per_minute",
    "game_length_minutes"
  )
  rating_metrics <- c(
    "rating_attack_league",
    "rating_defense_league",
    "rating_attack_global",
    "rating_defense_global",
    "aggression_ahead_league",
    "aggression_behind_league",
    "snowball_index_league"
  )
  rating_required <- c(
    "series_cutoff",
    "league_canonical",
    "team_id",
    "team_name",
    rating_metrics
  )
  missing <- c(
    setdiff(game_required, names(games)),
    setdiff(team_required, names(team_metrics)),
    setdiff(rating_required, names(dynamic_ratings))
  )
  if (length(missing) > 0L) {
    stop(
      "Missing tracking columns: ",
      paste(unique(missing), collapse = ", "),
      call. = FALSE
    )
  }
  games <- games[
    games$competition_role == "target" &
      as.Date(games$game_datetime) >= as.Date(min_date),
    ,
    drop = FALSE
  ]
  if ("target_valid" %in% names(games)) {
    games <- games[games$target_valid, , drop = FALSE]
  }
  games$game_length_minutes <- games$game_length_seconds / 60
  games$total_kills_per_minute <- games$total_kills_game /
    games$game_length_minutes
  games$league_entity <- games$league_canonical
  league_weekly <- .tracking_weekly_metrics(
    games,
    entity_type = "league",
    date_column = "game_datetime",
    entity_column = "league_entity",
    metric_names = c(
      "total_kills_game",
      "total_kills_per_minute",
      "game_length_minutes"
    )
  )
  league_weekly$metric[league_weekly$metric == "total_kills_game"] <-
    "total_kills"

  team_metrics <- team_metrics[
    team_metrics$competition_role == "target" &
      as.Date(team_metrics$game_datetime) >= as.Date(min_date),
    ,
    drop = FALSE
  ]
  team_weekly <- .tracking_weekly_metrics(
    team_metrics,
    entity_type = "team",
    date_column = "game_datetime",
    entity_column = "team_name",
    metric_names = c(
      "kills_per_minute",
      "deaths_per_minute",
      "combined_kills_per_minute",
      "game_length_minutes"
    )
  )

  dynamic_ratings <- dynamic_ratings[
    as.Date(dynamic_ratings$series_cutoff) >= as.Date(min_date),
    ,
    drop = FALSE
  ]
  rating_identity <- paste(
    dynamic_ratings$league_canonical,
    ifelse(
      is.na(dynamic_ratings$team_id),
      dynamic_ratings$team_name,
      dynamic_ratings$team_id
    ),
    dynamic_ratings$series_cutoff,
    sep = "|"
  )
  dynamic_ratings <- dynamic_ratings[
    !duplicated(rating_identity),
    ,
    drop = FALSE
  ]
  rating_weekly <- .tracking_weekly_metrics(
    dynamic_ratings,
    entity_type = "team",
    date_column = "series_cutoff",
    entity_column = "team_name",
    metric_names = rating_metrics
  )
  weekly <- rbind(league_weekly, team_weekly, rating_weekly)
  weekly <- weekly[
    order(
      weekly$entity_type,
      weekly$league_canonical,
      weekly$entity_name,
      weekly$metric,
      weekly$period
    ),
    ,
    drop = FALSE
  ]
  group_key <- interaction(
    weekly[c(
      "entity_type",
      "league_canonical",
      "entity_name",
      "metric"
    )],
    drop = TRUE,
    lex.order = TRUE
  )
  groups <- split(weekly, group_key)
  result <- do.call(rbind, lapply(groups, function(group) {
    indicators <- compute_time_series_indicators(
      group$period,
      group$value
    )
    cbind(group, indicators)
  }))
  rownames(result) <- NULL
  result
}

.tracking_asof_lookup <- function(
  tracking,
  leagues,
  entities,
  cutoffs,
  entity_type,
  metric
) {
  selected <- tracking[
    tracking$entity_type == entity_type &
      tracking$metric == metric,
    ,
    drop = FALSE
  ]
  keys <- paste(
    selected$league_canonical,
    selected$entity_name,
    sep = "|"
  )
  groups <- split(selected, keys)
  indicator_columns <- c(
    "normalized_index",
    "momentum_percent",
    "trend_per_week",
    "volatility_percent"
  )
  result <- base::matrix(
    NA_real_,
    nrow = length(cutoffs),
    ncol = length(indicator_columns),
    dimnames = list(NULL, indicator_columns)
  )
  requested_keys <- paste(leagues, entities, sep = "|")
  cutoff_weeks <- .tracking_week(cutoffs)
  for (index in seq_along(cutoff_weeks)) {
    group <- groups[[requested_keys[[index]]]]
    if (is.null(group)) {
      next
    }
    eligible <- which(
      as.Date(group$period) < cutoff_weeks[[index]]
    )
    if (length(eligible) == 0L) {
      next
    }
    row <- group[eligible[[length(eligible)]], , drop = FALSE]
    result[index, ] <- as.numeric(row[indicator_columns])
  }
  as.data.frame(result)
}

#' Return temporal tracking features used by the challenger model
#'
#' @return Character vector of leakage-safe numeric feature names.
#' @export
tracking_model_features <- function() {
  suffixes <- c(
    "index",
    "momentum",
    "trend",
    "volatility"
  )
  c(
    paste0("tracking_league_kills_", suffixes),
    paste0("tracking_matchup_bloodiness_", suffixes),
    paste0("tracking_matchup_attack_", suffixes),
    paste0("tracking_matchup_defense_", suffixes)
  )
}

#' Attach prior-week temporal tracking features to maps
#'
#' @param maps Map rows with league, series cutoff and both team names.
#' @param tracking Output table from `build_tracking_time_series()`.
#' @return Maps with league and matchup temporal features.
#' @export
attach_tracking_features_to_maps <- function(maps, tracking) {
  blue_column <- if ("blue_team_name.x" %in% names(maps)) {
    "blue_team_name.x"
  } else {
    "blue_team_name"
  }
  red_column <- if ("red_team_name.x" %in% names(maps)) {
    "red_team_name.x"
  } else {
    "red_team_name"
  }
  required_maps <- c(
    "league_canonical",
    "series_cutoff",
    blue_column,
    red_column
  )
  required_tracking <- c(
    "period",
    "entity_type",
    "league_canonical",
    "entity_name",
    "metric",
    "normalized_index",
    "momentum_percent",
    "trend_per_week",
    "volatility_percent"
  )
  missing <- c(
    setdiff(required_maps, names(maps)),
    setdiff(required_tracking, names(tracking))
  )
  if (length(missing) > 0L) {
    stop(
      "Missing tracking feature columns: ",
      paste(unique(missing), collapse = ", "),
      call. = FALSE
    )
  }
  result <- maps
  leagues <- as.character(maps$league_canonical)
  cutoffs <- maps$series_cutoff
  suffixes <- c(
    normalized_index = "index",
    momentum_percent = "momentum",
    trend_per_week = "trend",
    volatility_percent = "volatility"
  )
  league_values <- .tracking_asof_lookup(
    tracking,
    leagues,
    leagues,
    cutoffs,
    entity_type = "league",
    metric = "total_kills"
  )
  for (indicator in names(suffixes)) {
    result[[paste0(
      "tracking_league_kills_",
      suffixes[[indicator]]
    )]] <- league_values[[indicator]]
  }
  team_metrics <- c(
    bloodiness = "combined_kills_per_minute",
    attack = "rating_attack_league",
    defense = "rating_defense_league"
  )
  for (feature_group in names(team_metrics)) {
    blue_values <- .tracking_asof_lookup(
      tracking,
      leagues,
      as.character(maps[[blue_column]]),
      cutoffs,
      entity_type = "team",
      metric = team_metrics[[feature_group]]
    )
    red_values <- .tracking_asof_lookup(
      tracking,
      leagues,
      as.character(maps[[red_column]]),
      cutoffs,
      entity_type = "team",
      metric = team_metrics[[feature_group]]
    )
    for (indicator in names(suffixes)) {
      result[[paste0(
        "tracking_matchup_",
        feature_group,
        "_",
        suffixes[[indicator]]
      )]] <- rowMeans(
        cbind(
          blue_values[[indicator]],
          red_values[[indicator]]
        ),
        na.rm = TRUE
      )
      result[[paste0(
        "tracking_matchup_",
        feature_group,
        "_",
        suffixes[[indicator]]
      )]][!is.finite(result[[paste0(
        "tracking_matchup_",
        feature_group,
        "_",
        suffixes[[indicator]]
      )]])] <- NA_real_
    }
  }
  result
}
