.market_probability_over <- function(pmf, line) {
  threshold <- floor(as.numeric(line))
  support <- seq_along(pmf) - 1L
  sum(as.numeric(pmf)[support > threshold], na.rm = TRUE)
}

.market_clip_probability <- function(value, epsilon = 1e-12) {
  pmin(pmax(as.numeric(value), epsilon), 1 - epsilon)
}

#' Evaluate probabilistic kill predictions at real market lines
#'
#' @param predictions OOF map predictions containing list-column `pmf`.
#' @param links Verified game-market links.
#' @param snapshots One leakage-safe snapshot per event and period.
#' @param canonical_games Canonical observed map outcomes.
#' @return Map-level model, no-vig market, and economic metrics.
#' @export
evaluate_kills_market_backtest <- function(
  predictions,
  links,
  snapshots,
  canonical_games
) {
  required_prediction <- c("gameid", "candidate_id", "pmf")
  missing <- setdiff(required_prediction, names(predictions))
  if (length(missing) > 0L) {
    stop("Previsoes sem campos: ", paste(missing, collapse = ", "))
  }
  links <- links[links$link_status == "verified", , drop = FALSE]
  snapshots <- snapshots[
    abs(snapshots$line %% 1 - 0.5) < 1e-9,
    ,
    drop = FALSE
  ]
  market <- merge(
    links,
    snapshots,
    by = c("event_id", "period"),
    all = FALSE
  )
  outcomes <- canonical_games[c(
    "gameid", "series_id", "total_kills_game"
  )]
  market <- merge(market, outcomes, by = "gameid", all = FALSE)
  data <- merge(predictions, market, by = "gameid", all = FALSE)
  if (nrow(data) == 0L) {
    return(data.frame())
  }
  if (!"league_canonical" %in% names(data)) {
    data$league_canonical <- data$league_canonical.x
  }
  data$model_probability_over <- mapply(
    .market_probability_over,
    data$pmf,
    data$line
  )
  data$model_probability_over <- .market_clip_probability(
    data$model_probability_over
  )
  data$market_probability_over <- .market_clip_probability(
    1 / data$true_odds_over
  )
  data$multiplicative_probability_over <- .market_clip_probability(
    (1 / data$odds_over) /
      ((1 / data$odds_over) + (1 / data$odds_under))
  )
  data$outcome_over <- as.integer(data$total_kills_game > data$line)
  data$model_brier <- (
    data$model_probability_over - data$outcome_over
  )^2
  data$market_brier <- (
    data$market_probability_over - data$outcome_over
  )^2
  data$model_log_loss <- -(
    data$outcome_over * log(data$model_probability_over) +
      (1 - data$outcome_over) * log(1 - data$model_probability_over)
  )
  data$market_log_loss <- -(
    data$outcome_over * log(data$market_probability_over) +
      (1 - data$outcome_over) * log(1 - data$market_probability_over)
  )
  ev_over <- data$model_probability_over * data$odds_over - 1
  ev_under <- (1 - data$model_probability_over) * data$odds_under - 1
  data$bet_side <- ifelse(
    pmax(ev_over, ev_under) > 0,
    ifelse(ev_over >= ev_under, "over", "under"),
    "no_bet"
  )
  data$profit_units <- ifelse(
    data$bet_side == "over",
    ifelse(data$outcome_over == 1L, data$odds_over - 1, -1),
    ifelse(
      data$bet_side == "under",
      ifelse(data$outcome_over == 0L, data$odds_under - 1, -1),
      0
    )
  )
  data$stake_units <- as.integer(data$bet_side != "no_bet")
  data$clv <- ifelse(
    data$bet_side == "over",
    data$odds_over / data$closing_true_odds_over - 1,
    ifelse(
      data$bet_side == "under",
      data$odds_under / data$closing_true_odds_under - 1,
      NA_real_
    )
  )
  data
}

#' Summarize a market backtest
#'
#' @param backtest Map-level output of `evaluate_kills_market_backtest()`.
#' @return Candidate-level scoring and fixed-stake economics.
#' @export
summarize_kills_market_backtest <- function(backtest) {
  if (nrow(backtest) == 0L) {
    return(data.frame())
  }
  groups <- split(backtest, backtest$candidate_id)
  result <- lapply(groups, function(data) {
    cumulative <- cumsum(data$profit_units[order(data$game_datetime)])
    drawdown <- cumulative - cummax(c(0, cumulative))[-1L]
    stakes <- sum(data$stake_units)
    data.frame(
      candidate_id = data$candidate_id[[1L]],
      maps = nrow(data),
      model_brier = mean(data$model_brier),
      market_brier = mean(data$market_brier),
      model_log_loss = mean(data$model_log_loss),
      market_log_loss = mean(data$market_log_loss),
      bets = stakes,
      profit_units = sum(data$profit_units),
      yield = if (stakes > 0L) sum(data$profit_units) / stakes else NA_real_,
      maximum_drawdown = if (length(drawdown) > 0L) min(drawdown) else 0,
      mean_clv = mean(data$clv, na.rm = TRUE),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, result)
}

#' Bootstrap market metrics by temporal series blocks
#'
#' @param backtest Map-level market backtest.
#' @param replicates Number of bootstrap replicates.
#' @param seed Reproducible seed.
#' @return Candidate-level confidence intervals.
#' @export
bootstrap_kills_market_backtest <- function(
  backtest,
  replicates = 2000L,
  seed = 20260728L
) {
  if (nrow(backtest) == 0L) {
    return(data.frame())
  }
  set.seed(seed)
  results <- lapply(split(backtest, backtest$candidate_id), function(data) {
    month <- format(data$game_datetime, "%Y-%m", tz = "UTC")
    block <- paste(month, data$series_id, sep = "|")
    blocks <- split(seq_len(nrow(data)), block)
    estimates <- replicate(replicates, {
      sampled <- sample(seq_along(blocks), length(blocks), replace = TRUE)
      rows <- unlist(blocks[sampled], use.names = FALSE)
      draw <- data[rows, , drop = FALSE]
      stakes <- sum(draw$stake_units)
      c(
        brier_delta = mean(draw$model_brier - draw$market_brier),
        log_loss_delta = mean(draw$model_log_loss - draw$market_log_loss),
        yield = if (stakes > 0L) sum(draw$profit_units) / stakes else NA,
        mean_clv = mean(draw$clv, na.rm = TRUE)
      )
    })
    quantile_row <- function(name, probability) {
      stats::quantile(
        estimates[name, ],
        probability,
        na.rm = TRUE,
        names = FALSE
      )
    }
    data.frame(
      candidate_id = data$candidate_id[[1L]],
      replicates = replicates,
      brier_delta_low = quantile_row("brier_delta", 0.025),
      brier_delta_high = quantile_row("brier_delta", 0.975),
      log_loss_delta_low = quantile_row("log_loss_delta", 0.025),
      log_loss_delta_high = quantile_row("log_loss_delta", 0.975),
      yield_low = quantile_row("yield", 0.025),
      yield_high = quantile_row("yield", 0.975),
      mean_clv_low = quantile_row("mean_clv", 0.025),
      mean_clv_high = quantile_row("mean_clv", 0.975),
      stringsAsFactors = FALSE
    )
  })
  do.call(rbind, results)
}
