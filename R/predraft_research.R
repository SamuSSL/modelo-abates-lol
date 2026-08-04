#' Select the last strictly point-in-time market snapshot
#'
#' @param snapshots Market rows with event identity and timestamps.
#' @param event_columns Columns defining one map market.
#' @param start_column Scheduled map timestamp column.
#' @param timestamp_column Quote timestamp column.
#' @param minimum_minutes Strict lower lead-time boundary.
#' @param maximum_minutes Strict upper lead-time boundary.
#' @return One last eligible snapshot per event.
#' @export
select_predraft_market_snapshot <- function(
  snapshots,
  event_columns = "gameid",
  start_column = "market_close_time",
  timestamp_column = "odds_timestamp",
  minimum_minutes = 30,
  maximum_minutes = 45
) {
  required <- unique(c(event_columns, start_column, timestamp_column))
  missing <- setdiff(required, names(snapshots))
  if (length(missing) > 0L) {
    stop("Snapshot fields are missing: ", paste(missing, collapse = ", "), call. = FALSE)
  }
  start <- as.POSIXct(snapshots[[start_column]], tz = "UTC")
  timestamp <- as.POSIXct(snapshots[[timestamp_column]], tz = "UTC")
  lead_seconds <- as.numeric(difftime(start, timestamp, units = "secs"))
  eligible <- is.finite(lead_seconds) &
    lead_seconds > minimum_minutes * 60 &
    lead_seconds < maximum_minutes * 60
  rows <- snapshots[eligible, , drop = FALSE]
  if (nrow(rows) == 0L) {
    rows$lead_minutes <- numeric()
    return(rows)
  }
  rows$lead_minutes <- lead_seconds[eligible] / 60
  identity <- do.call(paste, c(rows[event_columns], sep = "|"))
  order_index <- order(identity, as.POSIXct(rows[[timestamp_column]], tz = "UTC"), decreasing = FALSE)
  rows <- rows[order_index, , drop = FALSE]
  identity <- identity[order_index]
  rows[!duplicated(identity, fromLast = TRUE), , drop = FALSE]
}

#' Fit a regularized residual over a market-implied count prior
#'
#' @param train Training maps with observed total, market mean, fundamental mean and league.
#' @param league_pooling Include regularized league deviations.
#' @param lambda Ridge penalty selected inside the training fold.
#' @return Ridge Poisson model with market log-mean offset.
#' @export
fit_market_residual_pooling <- function(
  train,
  league_pooling = FALSE,
  lambda = 1
) {
  required <- c("observed_total", "market_mean", "fundamental_mean", "league_canonical")
  missing <- setdiff(required, names(train))
  if (length(missing) > 0L) {
    stop("Market residual fields are missing: ", paste(missing, collapse = ", "), call. = FALSE)
  }
  complete <- stats::complete.cases(train[required]) &
    train$observed_total >= 0 & train$market_mean > 0 & train$fundamental_mean > 0
  data <- train[complete, , drop = FALSE]
  if (nrow(data) < 30L) {
    stop("At least 30 complete maps are required.", call. = FALSE)
  }
  data$fundamental_delta <- log(data$fundamental_mean) - log(data$market_mean)
  formula <- if (isTRUE(league_pooling)) {
    ~ fundamental_delta + league_canonical - 1
  } else {
    ~ fundamental_delta
  }
  design <- stats::model.matrix(formula, data = data)
  fit <- glmnet::glmnet(
    x = design,
    y = data$observed_total,
    family = "poisson",
    alpha = 0,
    lambda = as.numeric(lambda),
    offset = log(data$market_mean),
    standardize = TRUE
  )
  structure(
    list(
      fit = fit,
      formula = formula,
      league_pooling = isTRUE(league_pooling),
      lambda = as.numeric(lambda),
      design_columns = colnames(design)
    ),
    class = "lolkills_market_residual"
  )
}

#' Predict a regularized count posterior from the market prior
#'
#' @param fit Market residual fit.
#' @param new_data Future maps.
#' @return Expected total kills.
#' @export
predict_market_residual_pooling <- function(fit, new_data) {
  data <- new_data
  data$fundamental_delta <- log(data$fundamental_mean) - log(data$market_mean)
  design <- stats::model.matrix(fit$formula, data = data)
  missing <- setdiff(fit$design_columns, colnames(design))
  if (length(missing) > 0L) {
    design <- cbind(
      design,
      matrix(0, nrow(design), length(missing), dimnames = list(NULL, missing))
    )
  }
  design <- design[, fit$design_columns, drop = FALSE]
  as.numeric(stats::predict(
    fit$fit,
    newx = design,
    type = "response",
    s = fit$lambda,
    offset = log(data$market_mean)
  ))
}

#' Build deterministic Saturday-frozen latent team states
#'
#' @param team_maps Directed team-map observations.
#' @param evolution Weight assigned to the latest completed weekly signal.
#' @param prior_games Shrinkage strength toward the contemporaneous league mean.
#' @return Leakage-safe pre-map state rows and final states.
#' @export
build_weekly_latent_team_states <- function(
  team_maps,
  evolution = 0.35,
  prior_games = 12
) {
  required <- c(
    "gameid", "game_datetime", "team_id", "league_canonical",
    "kills_per_minute", "deaths_per_minute", "combined_kills_per_minute",
    "game_length_minutes", "result", "gold_diff_at_15"
  )
  missing <- setdiff(required, names(team_maps))
  if (length(missing) > 0L) {
    stop("Latent state fields are missing: ", paste(missing, collapse = ", "), call. = FALSE)
  }
  if (!is.finite(evolution) || evolution <= 0 || evolution > 1 || prior_games < 0) {
    stop("Latent state parameters are invalid.", call. = FALSE)
  }
  data <- team_maps
  data$game_datetime <- as.POSIXct(data$game_datetime, tz = "UTC")
  weekday <- as.POSIXlt(data$game_datetime, tz = "UTC")$wday
  days_since_saturday <- (weekday - 6) %% 7
  data$weekly_cutoff <- as.POSIXct(as.Date(data$game_datetime) - days_since_saturday, tz = "UTC")
  data <- data[order(data$weekly_cutoff, data$game_datetime, data$gameid, data$team_id), ]
  metrics <- c("attack", "concession", "conflict", "closing_speed", "resistance_behind")
  state <- list()
  premap <- vector("list", nrow(data))
  cutoffs <- sort(unique(data$weekly_cutoff))
  output_index <- 1L
  for (cutoff in cutoffs) {
    week_rows <- data[data$weekly_cutoff == cutoff, , drop = FALSE]
    prior_rows <- data[data$game_datetime < cutoff, , drop = FALSE]
    league_priors <- if (nrow(prior_rows) > 0L) {
      aggregate(
        cbind(kills_per_minute, deaths_per_minute, combined_kills_per_minute) ~ league_canonical,
        prior_rows,
        mean,
        na.rm = TRUE
      )
    } else {
      data.frame()
    }
    for (row_index in seq_len(nrow(week_rows))) {
      row <- week_rows[row_index, ]
      current <- state[[as.character(row$team_id)]]
      values <- if (is.null(current)) rep(NA_real_, length(metrics)) else current$values
      premap[[output_index]] <- data.frame(
        gameid = row$gameid,
        team_id = row$team_id,
        weekly_cutoff = as.POSIXct(cutoff, origin = "1970-01-01", tz = "UTC"),
        state_attack = values[[1]],
        state_concession = values[[2]],
        state_conflict = values[[3]],
        state_closing_speed = values[[4]],
        state_resistance_behind = values[[5]],
        stringsAsFactors = FALSE
      )
      output_index <- output_index + 1L
    }
    team_groups <- split(seq_len(nrow(week_rows)), week_rows$team_id)
    for (team_id in names(team_groups)) {
      rows <- week_rows[team_groups[[team_id]], , drop = FALSE]
      signal <- c(
        mean(rows$kills_per_minute, na.rm = TRUE),
        mean(rows$deaths_per_minute, na.rm = TRUE),
        mean(rows$combined_kills_per_minute, na.rm = TRUE),
        -mean(rows$game_length_minutes[rows$result == 1], na.rm = TRUE),
        mean(rows$result[rows$gold_diff_at_15 < 0], na.rm = TRUE)
      )
      signal[!is.finite(signal)] <- NA_real_
      old <- state[[team_id]]
      old_values <- if (is.null(old)) signal else old$values
      updated <- ifelse(
        is.finite(signal) & is.finite(old_values),
        (1 - evolution) * old_values + evolution * signal,
        ifelse(is.finite(signal), signal, old_values)
      )
      state[[team_id]] <- list(values = updated, cutoff = cutoff, maps = nrow(rows))
    }
  }
  list(premap = do.call(rbind, premap), final_states = state, metric_names = metrics)
}

#' Apply a partial roster reset to a latent state
#'
#' @param previous_state Numeric state vector.
#' @param league_prior Numeric league prior vector.
#' @param retention Retained share of the previous organization state.
#' @return Reset state.
#' @export
apply_roster_state_retention <- function(previous_state, league_prior, retention) {
  if (!is.finite(retention) || !retention %in% c(0.25, 0.5, 0.75)) {
    stop("Roster retention must be 0.25, 0.50 or 0.75.", call. = FALSE)
  }
  retention * as.numeric(previous_state) + (1 - retention) * as.numeric(league_prior)
}

#' Fit a lognormal duration mixture conditional on the winner
#'
#' @param train Pre-map features with `winner_a` and duration.
#' @param feature_names Allowed pre-draft feature names.
#' @return Two conditional lognormal regressions.
#' @export
fit_winner_mixture_duration <- function(train, feature_names = character()) {
  required <- c("game_length_minutes", "winner_a", feature_names)
  if (length(setdiff(required, names(train))) > 0L) {
    stop("Winner-mixture duration fields are missing.", call. = FALSE)
  }
  formula <- stats::reformulate(feature_names, response = "log(game_length_minutes)")
  fits <- lapply(c(1, 0), function(winner) {
    rows <- train[train$winner_a == winner & stats::complete.cases(train[required]), , drop = FALSE]
    if (nrow(rows) < 30L) stop("Each winner component requires at least 30 maps.", call. = FALSE)
    stats::lm(formula, data = rows)
  })
  structure(list(team_a = fits[[1]], team_b = fits[[2]], feature_names = feature_names), class = "lolkills_winner_duration")
}

#' Predict parameters of a winner-conditional duration mixture
#'
#' @param fit Winner-mixture duration fit.
#' @param new_data Future pre-draft features.
#' @param probability_team_a Probability that team A wins.
#' @return Mixture weights and lognormal parameters.
#' @export
predict_winner_mixture_duration <- function(fit, new_data, probability_team_a) {
  probability_team_a <- as.numeric(probability_team_a)
  if (any(probability_team_a <= 0 | probability_team_a >= 1)) {
    stop("Winner probabilities must be strictly between zero and one.", call. = FALSE)
  }
  data.frame(
    probability_team_a = probability_team_a,
    meanlog_team_a = as.numeric(stats::predict(fit$team_a, newdata = new_data)),
    sdlog_team_a = summary(fit$team_a)$sigma,
    meanlog_team_b = as.numeric(stats::predict(fit$team_b, newdata = new_data)),
    sdlog_team_b = summary(fit$team_b)$sigma
  )
}
