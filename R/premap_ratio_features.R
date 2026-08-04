.premap_required_team_columns <- function() {
  c(
    "gameid",
    "game_datetime",
    "source_season",
    "league_canonical",
    "competition_role",
    "split",
    "map_number",
    "side",
    "team_id",
    "team_name",
    "opponent_id",
    "opponent_name",
    "game_length_minutes",
    "team_kills",
    "team_deaths",
    "series_id",
    "series_cutoff"
  )
}

.premap_key <- function(data, columns) {
  values <- lapply(columns, function(column) {
    value <- as.character(data[[column]])
    value[is.na(value) | !nzchar(value)] <- "<NA>"
    value
  })
  do.call(paste, c(values, sep = "\u001f"))
}

.premap_build_history_index <- function(data, key_columns) {
  keys <- .premap_key(data, key_columns)
  groups <- split(seq_len(nrow(data)), keys)
  result <- lapply(groups, function(index) {
    index <- index[order(
      data$result_available_at[index],
      data$game_datetime[index],
      data$gameid[index],
      data$side[index]
    )]
    list(
      available = as.numeric(data$result_available_at[index]),
      kills = cumsum(as.numeric(data$team_kills[index])),
      deaths = cumsum(as.numeric(data$team_deaths[index])),
      minutes = cumsum(as.numeric(data$game_length_minutes[index])),
      total_kills = cumsum(as.numeric(
        data$team_kills[index] + data$team_deaths[index]
      )),
      total_kills_squared = cumsum(as.numeric(
        data$team_kills[index] + data$team_deaths[index]
      )^2),
      games = seq_along(index),
      team_id = as.character(data$team_id[index])
    )
  })
  result
}

.premap_empty_stats <- function() {
  c(
    games = 0,
    kills = 0,
    deaths = 0,
    minutes = 0,
    total_kills = 0,
    total_kills_squared = 0
  )
}

.premap_index_stats <- function(index, key, cutoff) {
  group <- index[[key]]
  if (is.null(group) || length(group$available) == 0L) {
    return(.premap_empty_stats())
  }
  position <- findInterval(as.numeric(cutoff), group$available)
  if (position < 1L) {
    return(.premap_empty_stats())
  }
  c(
    games = group$games[[position]],
    kills = group$kills[[position]],
    deaths = group$deaths[[position]],
    minutes = group$minutes[[position]],
    total_kills = group$total_kills[[position]],
    total_kills_squared = group$total_kills_squared[[position]]
  )
}

.premap_index_latest <- function(index, key, cutoff) {
  group <- index[[key]]
  if (is.null(group) || length(group$available) == 0L) {
    return(NA_real_)
  }
  position <- findInterval(as.numeric(cutoff), group$available)
  if (position < 1L) {
    return(NA_real_)
  }
  group$available[[position]]
}

.premap_recent_stats <- function(index, key, cutoff, observations) {
  group <- index[[key]]
  if (is.null(group) || length(group$available) == 0L) {
    return(.premap_empty_stats())
  }
  position <- findInterval(as.numeric(cutoff), group$available)
  if (position < 1L) {
    return(.premap_empty_stats())
  }
  first <- max(1L, position - as.integer(observations) + 1L)
  previous <- first - 1L
  previous_value <- function(values) {
    if (previous > 0L) values[[previous]] else 0
  }
  c(
    games = position - first + 1L,
    kills = group$kills[[position]] - previous_value(group$kills),
    deaths = group$deaths[[position]] - previous_value(group$deaths),
    minutes = group$minutes[[position]] - previous_value(group$minutes),
    total_kills = group$total_kills[[position]] -
      previous_value(group$total_kills),
    total_kills_squared = group$total_kills_squared[[position]] -
      previous_value(group$total_kills_squared)
  )
}

.premap_recent_reference <- function(
  index,
  key,
  cutoff,
  team_id,
  observations
) {
  group <- index[[key]]
  if (is.null(group) || length(group$available) == 0L) {
    return(.premap_empty_stats())
  }
  position <- findInterval(as.numeric(cutoff), group$available)
  if (position < 1L) {
    return(.premap_empty_stats())
  }
  candidates <- seq_len(position)
  candidates <- candidates[group$team_id[candidates] != team_id]
  if (length(candidates) == 0L) {
    return(.premap_empty_stats())
  }
  candidates <- utils::tail(candidates, as.integer(observations))
  cumulative_difference <- function(values, indices) {
    previous <- c(0, values[-length(values)])
    sum(values[indices] - previous[indices])
  }
  c(
    games = length(candidates),
    kills = cumulative_difference(group$kills, candidates),
    deaths = cumulative_difference(group$deaths, candidates),
    minutes = cumulative_difference(group$minutes, candidates),
    total_kills = cumulative_difference(
      group$total_kills,
      candidates
    ),
    total_kills_squared = cumulative_difference(
      group$total_kills_squared,
      candidates
    )
  )
}

.premap_subtract_stats <- function(total, excluded) {
  result <- total - excluded
  result[!is.finite(result)] <- 0
  pmax(result, 0)
}

.premap_valid_reference <- function(stats) {
  stats[["games"]] > 0 &&
    stats[["minutes"]] > 0 &&
    stats[["kills"]] >= 0 &&
    stats[["deaths"]] >= 0
}

.premap_reference_rates <- function(stats) {
  if (!.premap_valid_reference(stats)) {
    return(c(
      kills_per_map = NA_real_,
      deaths_per_map = NA_real_,
      kpm = NA_real_,
      dpm = NA_real_,
      duration = NA_real_
    ))
  }
  c(
    kills_per_map = stats[["kills"]] / stats[["games"]],
    deaths_per_map = stats[["deaths"]] / stats[["games"]],
    kpm = stats[["kills"]] / stats[["minutes"]],
    dpm = stats[["deaths"]] / stats[["minutes"]],
    duration = stats[["minutes"]] / stats[["games"]]
  )
}

.premap_shrunk_ratios <- function(team, reference, prior_games) {
  baseline <- .premap_reference_rates(reference)
  if (
    any(!is.finite(baseline)) ||
      baseline[["kills_per_map"]] <= 0 ||
      baseline[["deaths_per_map"]] <= 0 ||
      baseline[["kpm"]] <= 0 ||
      baseline[["dpm"]] <= 0 ||
      baseline[["duration"]] <= 0
  ) {
    return(c(
      attack_ratio = 1,
      concession_ratio = 1,
      kpm_ratio = 1,
      dpm_ratio = 1,
      duration_ratio = 1
    ))
  }
  games <- team[["games"]]
  minutes <- team[["minutes"]]
  prior_minutes <- prior_games * baseline[["duration"]]
  attack <- (
    team[["kills"]] + prior_games * baseline[["kills_per_map"]]
  ) / (games + prior_games)
  concession <- (
    team[["deaths"]] + prior_games * baseline[["deaths_per_map"]]
  ) / (games + prior_games)
  kpm <- (
    team[["kills"]] + prior_minutes * baseline[["kpm"]]
  ) / (minutes + prior_minutes)
  dpm <- (
    team[["deaths"]] + prior_minutes * baseline[["dpm"]]
  ) / (minutes + prior_minutes)
  duration <- (
    minutes + prior_games * baseline[["duration"]]
  ) / (games + prior_games)
  c(
    attack_ratio = attack / baseline[["kills_per_map"]],
    concession_ratio = concession / baseline[["deaths_per_map"]],
    kpm_ratio = kpm / baseline[["kpm"]],
    dpm_ratio = dpm / baseline[["dpm"]],
    duration_ratio = duration / baseline[["duration"]]
  )
}

.premap_total_kills_variance <- function(stats) {
  games <- as.numeric(stats[["games"]])
  if (
    !is.finite(games) ||
      games < 2 ||
      !is.finite(stats[["total_kills"]]) ||
      !is.finite(stats[["total_kills_squared"]])
  ) {
    return(NA_real_)
  }
  total <- as.numeric(stats[["total_kills"]])
  squared <- as.numeric(stats[["total_kills_squared"]])
  max((squared - total^2 / games) / (games - 1), 0)
}

.premap_shrunk_volatility <- function(team, reference, prior_games) {
  reference_variance <- .premap_total_kills_variance(reference)
  reference_games <- as.numeric(reference[["games"]])
  if (
    !is.finite(reference_variance) ||
      reference_variance <= 0 ||
      !is.finite(reference_games) ||
      reference_games < 2
  ) {
    return(c(
      total_kills_sd_ratio = 1,
      league_total_kills_sd = NA_real_
    ))
  }
  team_games <- as.numeric(team[["games"]])
  reference_mean <- as.numeric(reference[["total_kills"]]) /
    reference_games
  centered_sum_squares <- as.numeric(
    team[["total_kills_squared"]]
  ) - 2 * reference_mean * as.numeric(
    team[["total_kills"]]
  ) + team_games * reference_mean^2
  centered_sum_squares <- max(centered_sum_squares, 0)
  shrunk_variance <- (
    centered_sum_squares + prior_games * reference_variance
  ) / (team_games + prior_games)
  c(
    total_kills_sd_ratio = sqrt(
      pmax(shrunk_variance, 0) / reference_variance
    ),
    league_total_kills_sd = sqrt(reference_variance)
  )
}

.premap_window_names <- function() {
  c("season", "split", "last15", "last10", "last5")
}

#' Build leakage-safe pre-map team ratios
#'
#' @param team_metrics Team-map observations.
#' @param cutoff_mode `series` freezes every map before the series. `map`
#'   uses a separate lead time for every map.
#' @param prediction_lead_minutes Lead time used when `cutoff_mode = "map"`.
#' @param result_lag_minutes Safety lag after the observed map ends.
#' @param prior_games Shrinkage strength toward the leave-one-team-out league.
#' @param history_roles Competition roles allowed in historical ratings.
#' @param prediction_roles Competition roles emitted as prediction rows.
#' @return One row per team and target map with five point-in-time windows.
#' @export
build_premap_ratio_features <- function(
  team_metrics,
  cutoff_mode = c("series", "map"),
  prediction_lead_minutes = 15,
  result_lag_minutes = 5,
  prior_games = 10,
  history_roles = c("target", "supporting"),
  prediction_roles = "target"
) {
  cutoff_mode <- match.arg(cutoff_mode)
  required <- .premap_required_team_columns()
  missing <- setdiff(required, names(team_metrics))
  if (length(missing) > 0L) {
    stop(
      "Team metrics are missing pre-map columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (
    !is.finite(prediction_lead_minutes) ||
      prediction_lead_minutes < 0 ||
      !is.finite(result_lag_minutes) ||
      result_lag_minutes < 0 ||
      !is.finite(prior_games) ||
      prior_games <= 0
  ) {
    stop("Pre-map timing and shrinkage parameters are invalid.", call. = FALSE)
  }
  data <- team_metrics
  data$game_datetime <- as.POSIXct(data$game_datetime, tz = "UTC")
  data$series_cutoff <- as.POSIXct(data$series_cutoff, tz = "UTC")
  data$result_available_at <- data$game_datetime +
    as.numeric(data$game_length_minutes) * 60 +
    as.numeric(result_lag_minutes) * 60
  valid_history <- as.character(data$competition_role) %in% history_roles &
    stats::complete.cases(data[c(
      "game_datetime",
      "result_available_at",
      "source_season",
      "league_canonical",
      "team_id",
      "game_length_minutes",
      "team_kills",
      "team_deaths"
    )]) &
    is.finite(data$game_length_minutes) &
    data$game_length_minutes > 0 &
    is.finite(data$team_kills) &
    data$team_kills >= 0 &
    is.finite(data$team_deaths) &
    data$team_deaths >= 0
  history <- data[valid_history, , drop = FALSE]
  queries <- data[
    as.character(data$competition_role) %in% prediction_roles,
    ,
    drop = FALSE
  ]
  if (nrow(history) == 0L || nrow(queries) == 0L) {
    stop("No eligible history or prediction rows.", call. = FALSE)
  }
  queries$prediction_cutoff <- if (cutoff_mode == "series") {
    queries$series_cutoff
  } else {
    queries$game_datetime - as.numeric(prediction_lead_minutes) * 60
  }
  if (anyNA(queries$prediction_cutoff)) {
    stop("Prediction rows contain missing cutoffs.", call. = FALSE)
  }

  league_all <- .premap_build_history_index(
    history,
    c("league_canonical")
  )
  team_all <- .premap_build_history_index(
    history,
    c("league_canonical", "team_id")
  )
  league_season <- .premap_build_history_index(
    history,
    c("league_canonical", "source_season")
  )
  team_season <- .premap_build_history_index(
    history,
    c("league_canonical", "source_season", "team_id")
  )
  league_split <- .premap_build_history_index(
    history,
    c("league_canonical", "source_season", "split")
  )
  team_split <- .premap_build_history_index(
    history,
    c("league_canonical", "source_season", "split", "team_id")
  )

  identity_columns <- c(
    "gameid",
    "game_datetime",
    "source_season",
    "league_canonical",
    "competition_role",
    "split",
    "map_number",
    "side",
    "team_id",
    "team_name",
    "opponent_id",
    "opponent_name",
    "series_id",
    "series_cutoff",
    "prediction_cutoff",
    "game_length_minutes",
    "team_kills",
    "team_deaths"
  )
  result <- queries[identity_columns]
  windows <- .premap_window_names()
  ratio_names <- c(
    "attack_ratio",
    "concession_ratio",
    "kpm_ratio",
    "dpm_ratio",
    "duration_ratio",
    "total_kills_sd_ratio"
  )
  baseline_names <- c(
    "league_kills_per_map",
    "league_deaths_per_map",
    "league_kpm",
    "league_dpm",
    "league_duration",
    "league_total_kills_sd"
  )
  metric_names <- unlist(lapply(windows, function(window) {
    paste(
      window,
      c("team_games", "league_games", ratio_names, baseline_names),
      sep = "_"
    )
  }), use.names = FALSE)
  metric_values <- matrix(
    NA_real_,
    nrow = nrow(result),
    ncol = length(metric_names),
    dimnames = list(NULL, metric_names)
  )
  latest_history <- rep(NA_real_, nrow(result))
  for (window in windows) {
    invisible(window)
  }

  for (row_index in seq_len(nrow(queries))) {
    query <- queries[row_index, , drop = FALSE]
    cutoff <- query$prediction_cutoff[[1L]]
    team_id <- as.character(query$team_id[[1L]])
    league_key <- .premap_key(query, "league_canonical")
    team_key <- .premap_key(query, c("league_canonical", "team_id"))
    fallback_total <- .premap_index_stats(league_all, league_key, cutoff)
    fallback_team <- .premap_index_stats(team_all, team_key, cutoff)
    fallback_reference <- .premap_subtract_stats(
      fallback_total,
      fallback_team
    )
    latest_available <- .premap_index_latest(
      league_all,
      league_key,
      cutoff
    )
    if (is.finite(latest_available)) {
      latest_history[[row_index]] <- latest_available
    }

    for (window in windows) {
      if (window == "season") {
        league_window_key <- .premap_key(
          query,
          c("league_canonical", "source_season")
        )
        team_window_key <- .premap_key(
          query,
          c("league_canonical", "source_season", "team_id")
        )
        team_stats <- .premap_index_stats(
          team_season,
          team_window_key,
          cutoff
        )
        reference <- .premap_subtract_stats(
          .premap_index_stats(league_season, league_window_key, cutoff),
          team_stats
        )
      } else if (window == "split") {
        league_window_key <- .premap_key(
          query,
          c("league_canonical", "source_season", "split")
        )
        team_window_key <- .premap_key(
          query,
          c("league_canonical", "source_season", "split", "team_id")
        )
        team_stats <- .premap_index_stats(
          team_split,
          team_window_key,
          cutoff
        )
        reference <- .premap_subtract_stats(
          .premap_index_stats(league_split, league_window_key, cutoff),
          team_stats
        )
      } else {
        recent_games <- as.integer(sub("last", "", window))
        team_stats <- .premap_recent_stats(
          team_all,
          team_key,
          cutoff,
          recent_games
        )
        reference <- .premap_recent_reference(
          league_all,
          league_key,
          cutoff,
          team_id,
          observations = 2L * recent_games
        )
      }
      if (!.premap_valid_reference(reference)) {
        reference <- fallback_reference
      }
      ratios <- .premap_shrunk_ratios(
        team_stats,
        reference,
        prior_games
      )
      volatility <- .premap_shrunk_volatility(
        team_stats,
        reference,
        prior_games
      )
      rates <- .premap_reference_rates(reference)
      metric_values[row_index, paste0(window, "_team_games")] <-
        team_stats[["games"]]
      metric_values[row_index, paste0(window, "_league_games")] <-
        reference[["games"]]
      for (name in names(ratios)) {
        metric_values[row_index, paste(window, name, sep = "_")] <-
          ratios[[name]]
      }
      metric_values[
        row_index,
        paste(window, "total_kills_sd_ratio", sep = "_")
      ] <- volatility[["total_kills_sd_ratio"]]
      rate_map <- c(
        league_kills_per_map = "kills_per_map",
        league_deaths_per_map = "deaths_per_map",
        league_kpm = "kpm",
        league_dpm = "dpm",
        league_duration = "duration"
      )
      for (name in names(rate_map)) {
        metric_values[row_index, paste(window, name, sep = "_")] <-
          rates[[rate_map[[name]]]]
      }
      metric_values[
        row_index,
        paste(window, "league_total_kills_sd", sep = "_")
      ] <- volatility[["league_total_kills_sd"]]
    }
  }
  result$latest_history_available_at <- as.POSIXct(
    latest_history,
    origin = "1970-01-01",
    tz = "UTC"
  )
  result <- cbind(
    result,
    as.data.frame(metric_values, stringsAsFactors = FALSE)
  )
  result$cutoff_mode <- cutoff_mode
  rownames(result) <- NULL
  result
}

#' Assemble Blue and Red ratio rows into a map feature table
#'
#' @param team_features Output from `build_premap_ratio_features()`.
#' @param pace_maps Optional map table containing a precomputed `pace` column.
#' @return One coherent feature row per map.
#' @export
assemble_premap_ratio_map_features <- function(
  team_features,
  pace_maps = NULL
) {
  required <- c(
    "gameid",
    "side",
    "league_canonical",
    "game_datetime",
    "series_cutoff",
    "prediction_cutoff",
    "team_id",
    "team_name",
    "team_kills",
    "team_deaths",
    "game_length_minutes"
  )
  missing <- setdiff(required, names(team_features))
  if (length(missing) > 0L) {
    stop("Team ratio rows are missing map identity columns.", call. = FALSE)
  }
  blue <- team_features[
    as.character(team_features$side) == "Blue",
    ,
    drop = FALSE
  ]
  red <- team_features[
    as.character(team_features$side) == "Red",
    ,
    drop = FALSE
  ]
  if (
    nrow(blue) == 0L ||
      nrow(red) == 0L ||
      anyDuplicated(blue$gameid) ||
      anyDuplicated(red$gameid) ||
      !setequal(blue$gameid, red$gameid)
  ) {
    stop("Every map must have exactly one Blue and one Red ratio row.", call. = FALSE)
  }
  identity <- c(
    "gameid",
    "game_datetime",
    "source_season",
    "league_canonical",
    "competition_role",
    "split",
    "map_number",
    "series_id",
    "series_cutoff",
    "prediction_cutoff",
    "cutoff_mode"
  )
  identity <- intersect(identity, names(team_features))
  side_columns <- setdiff(
    names(team_features),
    c(identity, "side", "opponent_id", "opponent_name")
  )
  prefix_side <- function(data, prefix) {
    result <- data[c("gameid", side_columns)]
    names(result)[-1L] <- paste0(prefix, "_", names(result)[-1L])
    result
  }
  maps <- merge(
    blue[identity],
    prefix_side(blue, "blue"),
    by = "gameid",
    all.x = TRUE,
    sort = FALSE
  )
  maps <- merge(
    maps,
    prefix_side(red, "red"),
    by = "gameid",
    all.x = TRUE,
    sort = FALSE
  )
  maps$total_kills_game <- maps$blue_team_kills + maps$red_team_kills
  maps$game_length_minutes <- maps$blue_game_length_minutes
  if (!is.null(pace_maps)) {
    if (!all(c("gameid", "pace") %in% names(pace_maps))) {
      stop("pace_maps must contain gameid and pace.", call. = FALSE)
    }
    if (anyDuplicated(pace_maps$gameid)) {
      stop("pace_maps must contain one row per gameid.", call. = FALSE)
    }
    maps <- merge(
      maps,
      pace_maps[c("gameid", "pace")],
      by = "gameid",
      all.x = TRUE,
      sort = FALSE
    )
  } else {
    maps$pace <- (
      maps$blue_last10_kpm_ratio +
        maps$blue_last10_dpm_ratio +
        maps$red_last10_kpm_ratio +
        maps$red_last10_dpm_ratio
    ) / 4
  }
  maps <- maps[match(blue$gameid, maps$gameid), , drop = FALSE]
  rownames(maps) <- NULL
  maps
}

#' Derive direct and rate-times-duration multiplicative expectations
#'
#' @param maps Map-level pre-map ratio features.
#' @param windows Rating windows to derive.
#' @return Input maps with coherent Blue, Red, total, and duration expectations.
#' @export
derive_multiplicative_expectations <- function(
  maps,
  windows = .premap_window_names()
) {
  result <- maps
  for (window in windows) {
    required <- c(
      paste0("blue_", window, "_attack_ratio"),
      paste0("blue_", window, "_concession_ratio"),
      paste0("blue_", window, "_kpm_ratio"),
      paste0("blue_", window, "_dpm_ratio"),
      paste0("blue_", window, "_duration_ratio"),
      paste0("red_", window, "_attack_ratio"),
      paste0("red_", window, "_concession_ratio"),
      paste0("red_", window, "_kpm_ratio"),
      paste0("red_", window, "_dpm_ratio"),
      paste0("red_", window, "_duration_ratio"),
      paste0("blue_", window, "_league_kills_per_map"),
      paste0("blue_", window, "_league_kpm"),
      paste0("blue_", window, "_league_duration")
    )
    missing <- setdiff(required, names(result))
    if (length(missing) > 0L) {
      stop(
        "Missing multiplicative columns for ",
        window,
        ": ",
        paste(missing, collapse = ", "),
        call. = FALSE
      )
    }
    blue_league_kills <-
      result[[paste0("blue_", window, "_league_kills_per_map")]]
    red_league_kills <-
      result[[paste0("red_", window, "_league_kills_per_map")]]
    blue_league_kpm <-
      result[[paste0("blue_", window, "_league_kpm")]]
    red_league_kpm <-
      result[[paste0("red_", window, "_league_kpm")]]
    league_duration <- sqrt(
      result[[paste0("blue_", window, "_league_duration")]] *
        result[[paste0("red_", window, "_league_duration")]]
    )
    duration <- league_duration * sqrt(
      result[[paste0("blue_", window, "_duration_ratio")]] *
        result[[paste0("red_", window, "_duration_ratio")]]
    )
    blue_count <- blue_league_kills *
      result[[paste0("blue_", window, "_attack_ratio")]] *
      result[[paste0("red_", window, "_concession_ratio")]]
    red_count <- red_league_kills *
      result[[paste0("red_", window, "_attack_ratio")]] *
      result[[paste0("blue_", window, "_concession_ratio")]]
    blue_rate <- blue_league_kpm *
      result[[paste0("blue_", window, "_kpm_ratio")]] *
      result[[paste0("red_", window, "_dpm_ratio")]]
    red_rate <- red_league_kpm *
      result[[paste0("red_", window, "_kpm_ratio")]] *
      result[[paste0("blue_", window, "_dpm_ratio")]]
    result[[paste0("duration_", window)]] <- duration
    result[[paste0("blue_mu_count_", window)]] <- blue_count
    result[[paste0("red_mu_count_", window)]] <- red_count
    result[[paste0("total_mu_count_", window)]] <- blue_count + red_count
    result[[paste0("blue_rate_", window)]] <- blue_rate
    result[[paste0("red_rate_", window)]] <- red_rate
    result[[paste0("blue_mu_rate_", window)]] <- blue_rate * duration
    result[[paste0("red_mu_rate_", window)]] <- red_rate * duration
    result[[paste0("total_mu_rate_", window)]] <-
      result[[paste0("blue_mu_rate_", window)]] +
      result[[paste0("red_mu_rate_", window)]]
  }
  result
}
