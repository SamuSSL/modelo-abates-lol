.deduplicate_bettingiscool_fixtures <- function(fixtures) {
  if (nrow(fixtures) == 0L) {
    return(fixtures)
  }
  fixtures$retrieved_at <- .bettingiscool_utc(fixtures$retrieved_at)
  order_index <- order(
    as.character(fixtures$event_id),
    fixtures$retrieved_at,
    na.last = TRUE
  )
  fixtures <- fixtures[order_index, , drop = FALSE]
  fixtures <- fixtures[
    !duplicated(as.character(fixtures$event_id), fromLast = TRUE),
    ,
    drop = FALSE
  ]
  rownames(fixtures) <- NULL
  fixtures
}

#' Match independent Regular moneyline periods to canonical maps
#'
#' Unlike the original market join, this matcher does not require a
#' corresponding Kills fixture. It therefore permits an independent audit of
#' historical map moneylines.
#'
#' @param fixtures Normalized BettingIsCool fixtures.
#' @param snapshots Normalized moneyline history.
#' @param games Canonical Oracle map records.
#' @param competition_manifest BettingIsCool competition manifest.
#' @param aliases Versioned team aliases.
#' @param date_tolerance_days Maximum difference between series and map date.
#' @return Auditable direct moneyline-to-map links.
#' @export
match_bettingiscool_regular_maps <- function(
  fixtures,
  snapshots,
  games,
  competition_manifest,
  aliases = list(),
  date_tolerance_days = 1L
) {
  required_fixture <- c(
    "event_id",
    "league_id",
    "starts",
    "runner_home",
    "runner_away",
    "resulting_unit"
  )
  required_snapshot <- c("event_id", "period")
  missing <- c(
    setdiff(required_fixture, names(fixtures)),
    setdiff(required_snapshot, names(snapshots))
  )
  if (length(missing) > 0L) {
    stop(
      "Independent moneyline matching is missing columns: ",
      paste(unique(missing), collapse = ", "),
      call. = FALSE
    )
  }
  fixtures <- .deduplicate_bettingiscool_fixtures(fixtures)
  fixtures <- fixtures[
    tolower(as.character(fixtures$resulting_unit)) == "regular",
    ,
    drop = FALSE
  ]
  periods <- unique(data.frame(
    event_id = as.character(snapshots$event_id),
    period = suppressWarnings(as.integer(snapshots$period)),
    stringsAsFactors = FALSE
  ))
  periods <- periods[
    !is.na(periods$period) & periods$period >= 1L,
    ,
    drop = FALSE
  ]
  periods <- periods[
    periods$event_id %in% as.character(fixtures$event_id),
    ,
    drop = FALSE
  ]
  if (nrow(periods) == 0L) {
    return(data.frame())
  }
  match_bettingiscool_games(
    fixtures = fixtures,
    periods = periods,
    games = games,
    competition_manifest = competition_manifest,
    aliases = aliases,
    settlements = NULL,
    date_tolerance_days = date_tolerance_days
  )
}

#' Attach independently matched moneylines to canonical map features
#'
#' @param maps Canonical pre-map feature rows.
#' @param moneyline_links Direct Regular-event links.
#' @param regular_fixtures Normalized Regular fixtures.
#' @param selected_moneylines Point-in-time moneyline snapshots.
#' @param aliases Versioned team aliases.
#' @return Canonical maps with oriented Blue and Red probabilities.
#' @export
attach_direct_moneyline_to_maps <- function(
  maps,
  moneyline_links,
  regular_fixtures,
  selected_moneylines,
  aliases = list()
) {
  map_required <- c(
    "gameid",
    "blue_team_name",
    "red_team_name",
    "prediction_cutoff"
  )
  if (!all(map_required %in% names(maps))) {
    stop(
      "Canonical maps are missing direct-moneyline columns.",
      call. = FALSE
    )
  }
  link_required <- c(
    "gameid",
    "event_id",
    "period",
    "link_status"
  )
  if (!all(link_required %in% names(moneyline_links))) {
    stop("Direct moneyline links are incomplete.", call. = FALSE)
  }
  fixture_required <- c("event_id", "runner_home", "runner_away")
  if (!all(fixture_required %in% names(regular_fixtures))) {
    stop("Regular fixtures are missing orientation fields.", call. = FALSE)
  }
  links <- moneyline_links[
    moneyline_links$link_status == "verified" &
      !is.na(moneyline_links$gameid),
    c("gameid", "event_id", "period"),
    drop = FALSE
  ]
  if (nrow(links) == 0L) {
    return(maps[FALSE, , drop = FALSE])
  }
  fixtures <- .deduplicate_bettingiscool_fixtures(regular_fixtures)
  fixtures <- fixtures[c("event_id", "runner_home", "runner_away")]
  moneylines <- derive_moneyline_favoritism(selected_moneylines)
  joined <- merge(
    links,
    fixtures,
    by = "event_id"
  )
  joined <- merge(
    joined,
    moneylines,
    by = c("event_id", "period")
  )
  joined <- merge(joined, maps, by = "gameid")
  aliases <- .bettingiscool_alias_map(aliases)
  home_key <- .bettingiscool_apply_alias(joined$runner_home, aliases)
  away_key <- .bettingiscool_apply_alias(joined$runner_away, aliases)
  blue_key <- .bettingiscool_apply_alias(joined$blue_team_name, aliases)
  red_key <- .bettingiscool_apply_alias(joined$red_team_name, aliases)
  orientation_valid <- (
    home_key == blue_key & away_key == red_key
  ) | (
    home_key == red_key & away_key == blue_key
  )
  joined <- joined[orientation_valid, , drop = FALSE]
  home_is_blue <- home_key[orientation_valid] == blue_key[orientation_valid]
  joined$p_blue <- ifelse(home_is_blue, joined$p_home, joined$p_away)
  joined$p_red <- 1 - joined$p_blue
  joined$blue_log_odds <- stats::qlogis(pmin(
    1 - 1e-8,
    pmax(1e-8, joined$p_blue)
  ))
  joined$favorite_probability <- pmax(joined$p_blue, joined$p_red)
  joined$favorite_imbalance <- abs(joined$blue_log_odds)
  joined$favorite_imbalance_squared <- joined$favorite_imbalance^2
  joined$home_is_blue <- home_is_blue
  joined$prediction_cutoff <- .bettingiscool_utc(
    joined$prediction_cutoff
  )
  joined$odds_timestamp <- .bettingiscool_utc(joined$odds_timestamp)
  joined$market_close_time <- .bettingiscool_utc(
    joined$market_close_time
  )
  joined$moneyline_is_point_in_time_valid <-
    joined$odds_timestamp <= joined$prediction_cutoff &
    joined$odds_timestamp <= joined$market_close_time
  event_period_key <- paste(joined$event_id, joined$period, sep = "|")
  joined$event_period_match_count <- ave(
    rep(1L, nrow(joined)),
    event_period_key,
    FUN = length
  )
  joined$game_match_count <- ave(
    rep(1L, nrow(joined)),
    joined$gameid,
    FUN = length
  )
  joined <- joined[
    joined$event_period_match_count == 1L &
      joined$game_match_count == 1L &
      joined$moneyline_is_point_in_time_valid,
    ,
    drop = FALSE
  ]
  rownames(joined) <- NULL
  joined
}

#' Summarize independent moneyline coverage
#'
#' @param fixtures Normalized fixtures.
#' @param snapshots Normalized moneyline snapshots.
#' @param links Direct map links.
#' @return Coverage by calendar year and canonical league.
#' @export
summarize_direct_moneyline_coverage <- function(
  fixtures,
  snapshots,
  links
) {
  fixture_lookup <- .deduplicate_bettingiscool_fixtures(fixtures)
  fixture_lookup$event_id <- as.character(fixture_lookup$event_id)
  fixture_lookup$starts <- .bettingiscool_utc(fixture_lookup$starts)
  snapshot_periods <- unique(data.frame(
    event_id = as.character(snapshots$event_id),
    period = as.integer(snapshots$period),
    stringsAsFactors = FALSE
  ))
  event_coverage <- merge(
    snapshot_periods,
    fixture_lookup[c("event_id", "league_id", "starts")],
    by = "event_id",
    all.x = TRUE
  )
  event_coverage$year <- format(event_coverage$starts, "%Y", tz = "UTC")
  link_counts <- if (nrow(links) > 0L) {
    stats::aggregate(
      rep(1L, nrow(links)),
      links[c("league_canonical", "link_status")],
      sum
    )
  } else {
    data.frame(
      league_canonical = character(),
      link_status = character(),
      x = integer()
    )
  }
  names(link_counts)[names(link_counts) == "x"] <- "maps"
  list(
    event_periods_by_year = stats::aggregate(
      rep(1L, nrow(event_coverage)),
      event_coverage["year"],
      sum
    ),
    links_by_league_status = link_counts
  )
}
