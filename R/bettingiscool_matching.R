.bettingiscool_team_key <- function(value) {
  value <- gsub("\\s*\\(Kills\\)\\s*$", "", as.character(value), ignore.case = TRUE)
  value <- iconv(value, from = "", to = "ASCII//TRANSLIT")
  value <- tolower(value)
  gsub("[^a-z0-9]", "", value)
}

.bettingiscool_alias_map <- function(aliases) {
  if (is.null(aliases) || length(aliases) == 0L) {
    return(character())
  }
  values <- unlist(aliases, use.names = TRUE)
  stats::setNames(
    .bettingiscool_team_key(values),
    .bettingiscool_team_key(names(values))
  )
}

.bettingiscool_apply_alias <- function(value, aliases) {
  key <- .bettingiscool_team_key(value)
  mapped <- aliases[key]
  replace <- !is.na(mapped)
  key[replace] <- unname(mapped[replace])
  key
}

#' Match BettingIsCool map markets to canonical Oracle maps
#'
#' Only unique exact matches are accepted. Settlement is used to validate an
#' accepted link and never to choose among candidates.
#'
#' @param fixtures Normalized market fixtures.
#' @param periods Distinct event and period pairs with market data.
#' @param games Canonical map records.
#' @param competition_manifest Entries from `config/bettingiscool.yml`.
#' @param aliases Versioned team aliases.
#' @param settlements Optional normalized settlements.
#' @param cancelled_statuses Provider result statuses treated as cancelled.
#' @param date_tolerance_days Maximum series-start date difference.
#' @return Auditable link records.
#' @export
match_bettingiscool_games <- function(
  fixtures,
  periods,
  games,
  competition_manifest,
  aliases = list(),
  settlements = NULL,
  cancelled_statuses = c(3L, 4L, 5L),
  date_tolerance_days = 1L
) {
  manifest <- do.call(rbind, lapply(competition_manifest, function(entry) {
    data.frame(
      league_id = as.integer(entry$bettingiscool_league_id),
      league_canonical = as.character(entry$canonical_league),
      competition = as.character(entry$competition),
      stringsAsFactors = FALSE
    )
  }))
  aliases <- .bettingiscool_alias_map(aliases)
  fixtures$event_id <- as.character(fixtures$event_id)
  fixtures$home_key <- .bettingiscool_apply_alias(
    fixtures$runner_home,
    aliases
  )
  fixtures$away_key <- .bettingiscool_apply_alias(
    fixtures$runner_away,
    aliases
  )
  fixtures$starts <- .bettingiscool_utc(fixtures$starts)
  fixtures <- merge(fixtures, manifest, by = "league_id", all.x = TRUE)

  games$blue_key <- .bettingiscool_apply_alias(games$blue_team_name, aliases)
  games$red_key <- .bettingiscool_apply_alias(games$red_team_name, aliases)
  games$game_datetime <- .bettingiscool_utc(games$game_datetime)
  periods$event_id <- as.character(periods$event_id)
  periods$period <- as.integer(periods$period)
  market_maps <- merge(periods, fixtures, by = "event_id", all.x = TRUE)

  if (is.null(settlements)) {
    settlements <- data.frame()
  }
  if (nrow(settlements) > 0L) {
    settlements$event_id <- as.character(settlements$event_id)
    settlements$period <- as.integer(settlements$period)
  }

  links <- lapply(seq_len(nrow(market_maps)), function(index) {
    market <- market_maps[index, , drop = FALSE]
    candidates <- games[
      games$league_canonical == market$league_canonical &
        games$map_number == market$period &
        abs(as.numeric(difftime(
          games$game_datetime,
          market$starts,
          units = "days"
        ))) <= as.numeric(date_tolerance_days) &
        (
          (
            games$blue_key == market$home_key &
              games$red_key == market$away_key
          ) |
            (
              games$blue_key == market$away_key &
                games$red_key == market$home_key
            )
        ),
      ,
      drop = FALSE
    ]
    status <- if (nrow(candidates) == 0L) {
      "unmatched"
    } else if (nrow(candidates) > 1L) {
      "ambiguous"
    } else {
      "verified"
    }
    gameid <- if (nrow(candidates) == 1L) {
      as.character(candidates$gameid[[1L]])
    } else {
      NA_character_
    }
    reason <- if (status == "unmatched") {
      "no_unique_exact_team_date_league_match"
    } else if (status == "ambiguous") {
      "multiple_exact_candidates"
    } else {
      NA_character_
    }

    settlement <- settlements[
      settlements$event_id == market$event_id &
        settlements$period == market$period,
      ,
      drop = FALSE
    ]
    if (
      nrow(settlement) > 0L &&
        settlement$result_status[[1L]] %in% cancelled_statuses
    ) {
      status <- "cancelled"
      reason <- "provider_cancelled"
    } else if (status == "verified" && nrow(settlement) > 0L) {
      candidate <- candidates[1L, , drop = FALSE]
      home_is_blue <- candidate$blue_key == market$home_key
      expected_home <- if (home_is_blue) {
        candidate$blue_kills
      } else {
        candidate$red_kills
      }
      expected_away <- if (home_is_blue) {
        candidate$red_kills
      } else {
        candidate$blue_kills
      }
      scores_differ <- !is.na(settlement$score_home[[1L]]) &&
        !is.na(settlement$score_away[[1L]]) &&
        (
          settlement$score_home[[1L]] != expected_home ||
            settlement$score_away[[1L]] != expected_away
        )
      if (scores_differ) {
        status <- "conflict"
        reason <- "settlement_score_conflict"
      }
    }
    data.frame(
      gameid = gameid,
      event_id = market$event_id,
      period = market$period,
      link_status = status,
      match_method = if (status %in% c("verified", "conflict")) {
        "exact_league_date_unordered_teams_period"
      } else {
        NA_character_
      },
      league_canonical = market$league_canonical,
      competition = market$competition,
      team_home_market = market$runner_home,
      team_away_market = market$runner_away,
      market_close_time = as.POSIXct(NA, tz = "UTC"),
      exclusion_reason = reason,
      reviewed_at = as.POSIXct(Sys.time(), tz = "UTC"),
      stringsAsFactors = FALSE
    )
  })
  result <- do.call(rbind, links)
  result$link_id <- .bettingiscool_hash_rows(
    result,
    c("event_id", "period")
  )
  result[c("link_id", setdiff(names(result), "link_id"))]
}
