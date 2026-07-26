.safe_rating <- function(numerator, denominator, scale = 100) {
  numerator <- as.numeric(numerator)
  denominator <- as.numeric(denominator)
  result <- rep(NA_real_, length(numerator))
  valid <- is.finite(numerator) & is.finite(denominator) & denominator > 0
  result[valid] <- scale * numerator[valid] / denominator[valid]
  result
}

.relative_profile <- function(rating, margin = 10) {
  result <- rep("insufficient", length(rating))
  result[is.finite(rating) & rating < 100 - margin] <- "peaceful"
  result[
    is.finite(rating) &
      rating >= 100 - margin &
      rating <= 100 + margin
  ] <- "neutral"
  result[is.finite(rating) & rating > 100 + margin] <- "aggressive"
  result
}

#' Return the dynamic team model feature set
#'
#' @return Character vector used by regularized challenger models.
#' @export
dynamic_team_model_features <- function() {
  c(
    "pace",
    "team_opponent_intensity",
    "matchup_intensity_imbalance",
    "duration_history",
    "duration_history_imbalance",
    "draft_frontline",
    "draft_burst",
    "draft_frontline_imbalance",
    "draft_engage",
    "draft_poke_siege",
    "draft_dive",
    "draft_protect",
    "draft_skirmish",
    "draft_scaling",
    "matchup_attack_league",
    "matchup_attack_global",
    "matchup_defense_league",
    "matchup_defense_global",
    "matchup_attack_defense_pressure_league",
    "matchup_attack_defense_pressure_global",
    "matchup_momentum_attack",
    "matchup_momentum_mortality",
    "matchup_momentum_bloodiness",
    "matchup_aggression_ahead",
    "matchup_aggression_behind",
    "matchup_snowball_index",
    "matchup_snowball_imbalance"
  )
}

#' Derive team behavior outcomes from completed maps
#'
#' @param team_metrics Team-map metrics.
#' @param early_kill_lead Minimum kill advantage at 15 minutes.
#' @return Team-map metrics with conditional behavior outcomes.
#' @export
derive_team_behavior_outcomes <- function(
  team_metrics,
  early_kill_lead = 2
) {
  required <- c(
    "kills_per_minute",
    "deaths_per_minute",
    "combined_kills_per_minute",
    "kills_at_15",
    "deaths_at_15",
    "gold_diff_at_15",
    "game_length_minutes",
    "result"
  )
  missing <- setdiff(required, names(team_metrics))
  if (length(missing) > 0L) {
    stop(
      "Missing behavior columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (!is.finite(early_kill_lead) || early_kill_lead < 1) {
    stop("Early kill lead must be at least one.", call. = FALSE)
  }
  result <- team_metrics
  ahead <- is.finite(result$gold_diff_at_15) &
    result$gold_diff_at_15 > 0
  behind <- is.finite(result$gold_diff_at_15) &
    result$gold_diff_at_15 < 0
  early_kill_difference <- as.numeric(result$kills_at_15) -
    as.numeric(result$deaths_at_15)
  snowball_opportunity <- is.finite(early_kill_difference) &
    early_kill_difference >= early_kill_lead
  converted <- snowball_opportunity &
    is.finite(result$result) &
    result$result == 1

  result$pace_when_ahead <- ifelse(
    ahead,
    result$combined_kills_per_minute,
    NA_real_
  )
  result$pace_when_behind <- ifelse(
    behind,
    result$combined_kills_per_minute,
    NA_real_
  )
  result$attack_when_ahead <- ifelse(
    ahead,
    result$kills_per_minute,
    NA_real_
  )
  result$attack_when_behind <- ifelse(
    behind,
    result$kills_per_minute,
    NA_real_
  )
  result$snowball_win_conversion <- ifelse(
    snowball_opportunity,
    as.numeric(result$result == 1),
    NA_real_
  )
  result$snowball_close_minutes <- ifelse(
    converted,
    result$game_length_minutes,
    NA_real_
  )
  result
}

#' Build leakage-safe dynamic team ratings
#'
#' @param team_metrics Team-map metrics with frozen series cutoffs.
#' @param rating_half_life_days Half-life for current attack and defense.
#' @param short_half_life_days Half-life for short-term momentum.
#' @param long_half_life_days Half-life for the momentum baseline.
#' @param prior_games League-prior shrinkage strength.
#' @param early_kill_lead Kill lead at 15 defining a snowball opportunity.
#' @param profile_margin Percentage-point margin around league average.
#' @return Target-team rows with local, global, momentum and behavior ratings.
#' @export
build_team_dynamic_ratings <- function(
  team_metrics,
  rating_half_life_days = 60,
  short_half_life_days = 21,
  long_half_life_days = 120,
  prior_games = 20,
  early_kill_lead = 2,
  profile_margin = 3
) {
  if (
    rating_half_life_days <= 0 ||
      short_half_life_days <= 0 ||
      long_half_life_days <= short_half_life_days ||
      prior_games < 0 ||
      profile_margin < 0
  ) {
    stop("Dynamic rating parameters are invalid.", call. = FALSE)
  }
  outcomes <- derive_team_behavior_outcomes(
    team_metrics,
    early_kill_lead = early_kill_lead
  )
  rating_metrics <- c(
    "kills_per_minute",
    "deaths_per_minute",
    "combined_kills_per_minute",
    "pace_when_ahead",
    "pace_when_behind",
    "attack_when_ahead",
    "attack_when_behind",
    "snowball_win_conversion",
    "snowball_close_minutes"
  )
  current <- build_team_rolling_features(
    outcomes,
    metric_names = rating_metrics,
    half_life_days = rating_half_life_days,
    prior_games = prior_games
  )
  momentum_metrics <- c(
    "kills_per_minute",
    "deaths_per_minute",
    "combined_kills_per_minute"
  )
  short <- build_team_rolling_features(
    outcomes,
    metric_names = momentum_metrics,
    half_life_days = short_half_life_days,
    prior_games = prior_games
  )
  long <- build_team_rolling_features(
    outcomes,
    metric_names = momentum_metrics,
    half_life_days = long_half_life_days,
    prior_games = prior_games
  )
  identity_columns <- c("gameid", "side", "team_id", "team_name")
  if (
    !identical(current[identity_columns], short[identity_columns]) ||
      !identical(current[identity_columns], long[identity_columns])
  ) {
    stop("Dynamic rating histories are not aligned.", call. = FALSE)
  }

  current$rating_attack_league <- .safe_rating(
    current$hist_kills_per_minute,
    ifelse(
      is.finite(current$league_peer_prior_kills_per_minute),
      current$league_peer_prior_kills_per_minute,
      current$league_prior_kills_per_minute
    )
  )
  current$rating_attack_global <- .safe_rating(
    current$hist_kills_per_minute,
    ifelse(
      is.finite(current$global_peer_prior_kills_per_minute),
      current$global_peer_prior_kills_per_minute,
      current$global_prior_kills_per_minute
    )
  )
  current$rating_defense_league <- .safe_rating(
    ifelse(
      is.finite(current$league_peer_prior_deaths_per_minute),
      current$league_peer_prior_deaths_per_minute,
      current$league_prior_deaths_per_minute
    ),
    current$hist_deaths_per_minute
  )
  current$rating_defense_global <- .safe_rating(
    ifelse(
      is.finite(current$global_peer_prior_deaths_per_minute),
      current$global_peer_prior_deaths_per_minute,
      current$global_prior_deaths_per_minute
    ),
    current$hist_deaths_per_minute
  )
  current$momentum_attack <- .safe_rating(
    short$hist_kills_per_minute,
    long$hist_kills_per_minute
  ) - 100
  current$momentum_mortality <- .safe_rating(
    short$hist_deaths_per_minute,
    long$hist_deaths_per_minute
  ) - 100
  current$momentum_bloodiness <- .safe_rating(
    short$hist_combined_kills_per_minute,
    long$hist_combined_kills_per_minute
  ) - 100
  current$aggression_ahead_league <- .safe_rating(
    current$hist_pace_when_ahead,
    ifelse(
      is.finite(current$league_peer_prior_pace_when_ahead),
      current$league_peer_prior_pace_when_ahead,
      current$league_prior_pace_when_ahead
    )
  )
  current$aggression_behind_league <- .safe_rating(
    current$hist_pace_when_behind,
    ifelse(
      is.finite(current$league_peer_prior_pace_when_behind),
      current$league_peer_prior_pace_when_behind,
      current$league_prior_pace_when_behind
    )
  )
  current$aggression_ahead_global <- .safe_rating(
    current$hist_pace_when_ahead,
    ifelse(
      is.finite(current$global_peer_prior_pace_when_ahead),
      current$global_peer_prior_pace_when_ahead,
      current$global_prior_pace_when_ahead
    )
  )
  current$aggression_behind_global <- .safe_rating(
    current$hist_pace_when_behind,
    ifelse(
      is.finite(current$global_peer_prior_pace_when_behind),
      current$global_peer_prior_pace_when_behind,
      current$global_prior_pace_when_behind
    )
  )
  current$behavior_ahead_profile <- .relative_profile(
    current$aggression_ahead_league,
    profile_margin
  )
  current$behavior_behind_profile <- .relative_profile(
    current$aggression_behind_league,
    profile_margin
  )
  current$snowball_conversion_league <- .safe_rating(
    current$hist_snowball_win_conversion,
    ifelse(
      is.finite(
        current$league_peer_prior_snowball_win_conversion
      ),
      current$league_peer_prior_snowball_win_conversion,
      current$league_prior_snowball_win_conversion
    )
  )
  current$snowball_conversion_global <- .safe_rating(
    current$hist_snowball_win_conversion,
    ifelse(
      is.finite(
        current$global_peer_prior_snowball_win_conversion
      ),
      current$global_peer_prior_snowball_win_conversion,
      current$global_prior_snowball_win_conversion
    )
  )
  current$snowball_close_speed_league <- .safe_rating(
    ifelse(
      is.finite(current$league_peer_prior_snowball_close_minutes),
      current$league_peer_prior_snowball_close_minutes,
      current$league_prior_snowball_close_minutes
    ),
    current$hist_snowball_close_minutes
  )
  current$snowball_close_speed_global <- .safe_rating(
    ifelse(
      is.finite(current$global_peer_prior_snowball_close_minutes),
      current$global_peer_prior_snowball_close_minutes,
      current$global_prior_snowball_close_minutes
    ),
    current$hist_snowball_close_minutes
  )
  current$snowball_index_league <- rowMeans(
    cbind(
      current$snowball_conversion_league,
      current$snowball_close_speed_league
    ),
    na.rm = TRUE
  )
  current$snowball_index_global <- rowMeans(
    cbind(
      current$snowball_conversion_global,
      current$snowball_close_speed_global
    ),
    na.rm = TRUE
  )
  current$snowball_index_league[
    !is.finite(current$snowball_index_league)
  ] <- NA_real_
  current$snowball_index_global[
    !is.finite(current$snowball_index_global)
  ] <- NA_real_
  current$effective_snowball_opportunities <-
    current$effective_snowball_win_conversion_games
  current
}
