.rolling_team_key <- function(team_id, team_name) {
  if (!is.na(team_id) && nzchar(as.character(team_id))) {
    paste0("id:", as.character(team_id))
  } else {
    paste0("name:", tolower(trimws(as.character(team_name))))
  }
}

.decay_state <- function(environment, key, timestamp, half_life_days) {
  if (!exists(key, envir = environment, inherits = FALSE)) {
    return(c(sum = 0, weight = 0, last = timestamp))
  }
  state <- get(key, envir = environment, inherits = FALSE)
  age_days <- (timestamp - state[["last"]]) / 86400
  if (age_days < 0) {
    stop("Rolling state received non-chronological data.", call. = FALSE)
  }
  factor <- 0.5^(age_days / half_life_days)
  c(
    sum = state[["sum"]] * factor,
    weight = state[["weight"]] * factor,
    last = timestamp
  )
}

.update_state <- function(
  environment,
  key,
  timestamp,
  value,
  half_life_days
) {
  if (!is.finite(value)) {
    return(invisible(NULL))
  }
  state <- .decay_state(
    environment,
    key,
    timestamp,
    half_life_days
  )
  state[["sum"]] <- state[["sum"]] + value
  state[["weight"]] <- state[["weight"]] + 1
  assign(key, state, envir = environment)
  invisible(NULL)
}

.query_state <- function(
  environment,
  key,
  timestamp,
  half_life_days
) {
  .decay_state(environment, key, timestamp, half_life_days)
}

.raw_team_state <- function(environment, key) {
  if (!exists(key, envir = environment, inherits = FALSE)) {
    return(list(games = 0L, last = as.POSIXct(NA, tz = "UTC")))
  }
  get(key, envir = environment, inherits = FALSE)
}

.update_raw_team_state <- function(environment, key, timestamp) {
  state <- .raw_team_state(environment, key)
  state$games <- state$games + 1L
  state$last <- as.POSIXct(timestamp, origin = "1970-01-01", tz = "UTC")
  assign(key, state, envir = environment)
  invisible(NULL)
}

#' Build leakage-safe rolling team features
#'
#' @param team_metrics Team-map metrics with series cutoffs.
#' @param metric_names Historical metrics to estimate.
#' @param half_life_days Exponential-decay half-life.
#' @param prior_games League-prior strength in effective games.
#' @return Target-team rows with frozen pre-series features.
#' @export
build_team_rolling_features <- function(
  team_metrics,
  metric_names,
  half_life_days = 60,
  prior_games = 20
) {
  required <- c(
    "gameid",
    "game_datetime",
    "series_cutoff",
    "league_canonical",
    "competition_role",
    "side",
    "team_id",
    "team_name"
  )
  missing <- setdiff(c(required, metric_names), names(team_metrics))
  if (length(missing) > 0L) {
    stop(
      "Missing rolling-feature columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (half_life_days <= 0 || prior_games < 0) {
    stop("Decay and prior parameters must be valid.", call. = FALSE)
  }
  rows <- team_metrics[
    team_metrics$competition_role %in% c("target", "auxiliary") &
      !is.na(team_metrics$game_datetime) &
      !is.na(team_metrics$series_cutoff),
    ,
    drop = FALSE
  ]
  rows$.original_index <- seq_len(nrow(rows))
  outcome_order <- order(rows$game_datetime, rows$gameid, rows$side)
  target_index <- which(rows$competition_role == "target")
  query_order <- target_index[
    order(
      rows$series_cutoff[target_index],
      rows$gameid[target_index],
      rows$side[target_index]
    )
  ]

  metric_states <- lapply(metric_names, function(metric) {
    list(
      team = new.env(hash = TRUE, parent = emptyenv()),
      league = new.env(hash = TRUE, parent = emptyenv()),
      global = new.env(hash = TRUE, parent = emptyenv())
    )
  })
  names(metric_states) <- metric_names
  raw_state <- new.env(hash = TRUE, parent = emptyenv())

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
  for (metric in metric_names) {
    features[[paste0("hist_", metric)]] <- NA_real_
    features[[paste0("effective_", metric, "_games")]] <- NA_real_
    features[[paste0("league_prior_", metric)]] <- NA_real_
  }

  outcome_pointer <- 1L
  for (query_position in seq_along(query_order)) {
    row_index <- query_order[[query_position]]
    cutoff <- as.numeric(rows$series_cutoff[[row_index]])

    while (
      outcome_pointer <= length(outcome_order) &&
        as.numeric(
          rows$game_datetime[[outcome_order[[outcome_pointer]]]]
        ) < cutoff
    ) {
      outcome_index <- outcome_order[[outcome_pointer]]
      outcome_time <- as.numeric(rows$game_datetime[[outcome_index]])
      outcome_team_key <- .rolling_team_key(
        rows$team_id[[outcome_index]],
        rows$team_name[[outcome_index]]
      )
      outcome_league <- as.character(
        rows$league_canonical[[outcome_index]]
      )
      role <- as.character(rows$competition_role[[outcome_index]])

      for (metric in metric_names) {
        value <- suppressWarnings(
          as.numeric(rows[[metric]][[outcome_index]])
        )
        states <- metric_states[[metric]]
        .update_state(
          states$team,
          outcome_team_key,
          outcome_time,
          value,
          half_life_days
        )
        if (role == "target") {
          .update_state(
            states$league,
            outcome_league,
            outcome_time,
            value,
            half_life_days
          )
          .update_state(
            states$global,
            "global",
            outcome_time,
            value,
            half_life_days
          )
        }
      }
      .update_raw_team_state(
        raw_state,
        outcome_team_key,
        outcome_time
      )
      outcome_pointer <- outcome_pointer + 1L
    }

    team_key <- .rolling_team_key(
      rows$team_id[[row_index]],
      rows$team_name[[row_index]]
    )
    league <- as.character(rows$league_canonical[[row_index]])
    raw <- .raw_team_state(raw_state, team_key)
    features$raw_team_games[[query_position]] <- raw$games
    features$latest_history_datetime[[query_position]] <- raw$last

    for (metric in metric_names) {
      states <- metric_states[[metric]]
      team_state <- .query_state(
        states$team,
        team_key,
        cutoff,
        half_life_days
      )
      league_state <- .query_state(
        states$league,
        league,
        cutoff,
        half_life_days
      )
      global_state <- .query_state(
        states$global,
        "global",
        cutoff,
        half_life_days
      )
      prior_mean <- if (league_state[["weight"]] > 0) {
        league_state[["sum"]] / league_state[["weight"]]
      } else if (global_state[["weight"]] > 0) {
        global_state[["sum"]] / global_state[["weight"]]
      } else {
        NA_real_
      }
      estimate <- if (is.finite(prior_mean)) {
        (
          team_state[["sum"]] +
            prior_games * prior_mean
        ) / (
          team_state[["weight"]] + prior_games
        )
      } else if (team_state[["weight"]] > 0) {
        team_state[["sum"]] / team_state[["weight"]]
      } else {
        NA_real_
      }
      features[[paste0("hist_", metric)]][[query_position]] <-
        estimate
      features[[
        paste0("effective_", metric, "_games")
      ]][[query_position]] <- team_state[["weight"]]
      features[[
        paste0("league_prior_", metric)
      ]][[query_position]] <- prior_mean
    }
  }

  features <- features[
    order(features$.original_index),
    ,
    drop = FALSE
  ]
  features$.original_index <- NULL
  rownames(features) <- NULL
  features
}
