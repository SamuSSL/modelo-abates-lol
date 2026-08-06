.synthetic_safe_pair <- function(first, second, operation = c("mean", "gap")) {
  operation <- match.arg(operation)
  first <- as.numeric(first)
  second <- as.numeric(second)
  if (operation == "mean") {
    rowMeans(cbind(first, second), na.rm = TRUE)
  } else {
    abs(first - second)
  }
}

#' Build side-invariant pre-opening features for a synthetic Pinnacle
#'
#' @param data Map rows containing leakage-safe Blue and Red team ratings.
#' @param windows Rating windows to use.
#' @return Numeric features that are invariant to swapping the two teams.
#' @export
build_synthetic_pinnacle_features <- function(
  data,
  windows = c("season", "last15")
) {
  result <- data.frame(
    map_number = pmin(as.numeric(data$map_number), 5),
    stringsAsFactors = FALSE
  )
  if ("pace" %in% names(data)) {
    result$pace <- as.numeric(data$pace)
  }
  for (window in windows) {
    source <- function(side, metric) {
      field <- paste(side, window, metric, sep = "_")
      if (!field %in% names(data)) {
        stop("Synthetic Pinnacle feature missing: ", field, call. = FALSE)
      }
      as.numeric(data[[field]])
    }
    blue_attack <- source("blue", "attack_ratio")
    red_attack <- source("red", "attack_ratio")
    blue_concession <- source("blue", "concession_ratio")
    red_concession <- source("red", "concession_ratio")
    blue_kpm <- source("blue", "kpm_ratio")
    red_kpm <- source("red", "kpm_ratio")
    blue_dpm <- source("blue", "dpm_ratio")
    red_dpm <- source("red", "dpm_ratio")
    prefix <- paste0(window, "_")
    result[[paste0(prefix, "team_games_min")]] <- pmin(
      source("blue", "team_games"),
      source("red", "team_games")
    )
    result[[paste0(prefix, "attack_mean")]] <- .synthetic_safe_pair(
      blue_attack, red_attack
    )
    result[[paste0(prefix, "concession_mean")]] <- .synthetic_safe_pair(
      blue_concession, red_concession
    )
    result[[paste0(prefix, "matchup_count")]] <- 0.5 * (
      blue_attack * red_concession + red_attack * blue_concession
    )
    result[[paste0(prefix, "matchup_rate")]] <- 0.5 * (
      blue_kpm * red_dpm + red_kpm * blue_dpm
    )
    result[[paste0(prefix, "kpm_mean")]] <- .synthetic_safe_pair(
      blue_kpm, red_kpm
    )
    result[[paste0(prefix, "dpm_mean")]] <- .synthetic_safe_pair(
      blue_dpm, red_dpm
    )
    result[[paste0(prefix, "duration_mean")]] <- .synthetic_safe_pair(
      source("blue", "duration_ratio"),
      source("red", "duration_ratio")
    )
    result[[paste0(prefix, "volatility_mean")]] <- .synthetic_safe_pair(
      source("blue", "total_kills_sd_ratio"),
      source("red", "total_kills_sd_ratio")
    )
    result[[paste0(prefix, "attack_gap")]] <- .synthetic_safe_pair(
      blue_attack, red_attack, "gap"
    )
    result[[paste0(prefix, "concession_gap")]] <- .synthetic_safe_pair(
      blue_concession, red_concession, "gap"
    )
    result[[paste0(prefix, "rate_gap")]] <- .synthetic_safe_pair(
      blue_kpm + blue_dpm,
      red_kpm + red_dpm,
      "gap"
    )
    league_kills <- .synthetic_safe_pair(
      source("blue", "league_kills_per_map"),
      source("red", "league_kills_per_map")
    )
    league_deaths <- .synthetic_safe_pair(
      source("blue", "league_deaths_per_map"),
      source("red", "league_deaths_per_map")
    )
    result[[paste0(prefix, "league_total")]] <- league_kills + league_deaths
    result[[paste0(prefix, "league_duration")]] <- .synthetic_safe_pair(
      source("blue", "league_duration"),
      source("red", "league_duration")
    )
    result[[paste0(prefix, "structural_proxy")]] <-
      result[[paste0(prefix, "league_total")]] *
      result[[paste0(prefix, "matchup_count")]]
  }
  result$minimum_history <- pmin(
    result$season_team_games_min,
    result$last15_team_games_min
  )
  result
}
