.rolling_player_key <- function(player_id, player_name, position) {
  identity <- if (!is.na(player_id) && nzchar(as.character(player_id))) {
    paste0("id:", as.character(player_id))
  } else {
    paste0("name:", tolower(trimws(as.character(player_name))))
  }
  paste(identity, tolower(as.character(position)), sep = "|")
}

#' Build leakage-safe rolling player features
#'
#' @param player_metrics Player-map metrics with series cutoffs.
#' @param metric_names Historical metrics to estimate.
#' @param half_life_days Exponential-decay half-life.
#' @param prior_games League-position prior strength.
#' @param interaction_prior_games Strong player-champion interaction prior.
#' @return Target-player rows with frozen pre-series features.
#' @export
build_player_rolling_features <- function(
  player_metrics,
  metric_names,
  half_life_days = 60,
  prior_games = 10,
  interaction_prior_games = 30
) {
  required <- c(
    "gameid",
    "game_datetime",
    "series_cutoff",
    "league_canonical",
    "competition_role",
    "side",
    "position",
    "player_id",
    "player_name",
    "champion"
  )
  missing <- setdiff(c(required, metric_names), names(player_metrics))
  if (length(missing) > 0L) {
    stop(
      "Missing rolling player columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  rows <- player_metrics[
    player_metrics$competition_role %in% c("target", "auxiliary") &
      !is.na(player_metrics$game_datetime) &
      !is.na(player_metrics$series_cutoff),
    ,
    drop = FALSE
  ]
  rows$.original_index <- seq_len(nrow(rows))
  outcome_order <- order(
    rows$game_datetime,
    rows$gameid,
    rows$side,
    rows$position
  )
  target_index <- which(rows$competition_role == "target")
  query_order <- target_index[order(
    rows$series_cutoff[target_index],
    rows$gameid[target_index],
    rows$side[target_index],
    rows$position[target_index]
  )]
  states <- lapply(metric_names, function(metric) {
    list(
      player = new.env(hash = TRUE, parent = emptyenv()),
      interaction = new.env(hash = TRUE, parent = emptyenv()),
      prior = new.env(hash = TRUE, parent = emptyenv()),
      global = new.env(hash = TRUE, parent = emptyenv())
    )
  })
  names(states) <- metric_names
  raw_state <- new.env(hash = TRUE, parent = emptyenv())
  champion_state <- new.env(hash = TRUE, parent = emptyenv())
  raw_champion_state <- new.env(hash = TRUE, parent = emptyenv())
  raw_interaction_state <- new.env(hash = TRUE, parent = emptyenv())
  features <- rows[query_order, c(
    "gameid",
    "game_datetime",
    "series_cutoff",
    "league_canonical",
    "side",
    "position",
    "player_id",
    "player_name",
    "champion"
  ), drop = FALSE]
  features$.original_index <- rows$.original_index[query_order]
  features$raw_player_games <- integer(nrow(features))
  features$raw_champion_games <- integer(nrow(features))
  features$effective_champion_games <- numeric(nrow(features))
  features$raw_player_champion_games <- integer(nrow(features))
  features$latest_history_datetime <- as.POSIXct(
    rep(NA_real_, nrow(features)),
    origin = "1970-01-01",
    tz = "UTC"
  )
  features$latest_player_champion_history_datetime <- as.POSIXct(
    rep(NA_real_, nrow(features)),
    origin = "1970-01-01",
    tz = "UTC"
  )
  for (metric in metric_names) {
    features[[paste0("hist_", metric)]] <- NA_real_
    features[[paste0("effective_", metric, "_games")]] <- NA_real_
    features[[paste0(
      "hist_player_champion_",
      metric
    )]] <- NA_real_
    features[[paste0(
      "effective_player_champion_",
      metric,
      "_games"
    )]] <- NA_real_
  }
  pointer <- 1L
  for (query_position in seq_along(query_order)) {
    row_index <- query_order[[query_position]]
    cutoff <- as.numeric(rows$series_cutoff[[row_index]])
    while (
      pointer <= length(outcome_order) &&
        as.numeric(rows$game_datetime[[outcome_order[[pointer]]]]) < cutoff
    ) {
      outcome_index <- outcome_order[[pointer]]
      outcome_time <- as.numeric(rows$game_datetime[[outcome_index]])
      player_key <- .rolling_player_key(
        rows$player_id[[outcome_index]],
        rows$player_name[[outcome_index]],
        rows$position[[outcome_index]]
      )
      prior_key <- paste(
        rows$league_canonical[[outcome_index]],
        rows$position[[outcome_index]],
        sep = "|"
      )
      interaction_key <- paste(
        player_key,
        as.character(rows$champion[[outcome_index]]),
        sep = "|champion:"
      )
      for (metric in metric_names) {
        value <- suppressWarnings(
          as.numeric(rows[[metric]][[outcome_index]])
        )
        .update_state(
          states[[metric]]$player,
          player_key,
          outcome_time,
          value,
          half_life_days
        )
        .update_state(
          states[[metric]]$interaction,
          interaction_key,
          outcome_time,
          value,
          half_life_days
        )
        if (rows$competition_role[[outcome_index]] == "target") {
          .update_state(
            states[[metric]]$prior,
            prior_key,
            outcome_time,
            value,
            half_life_days
          )
          .update_state(
            states[[metric]]$global,
            as.character(rows$position[[outcome_index]]),
            outcome_time,
            value,
            half_life_days
          )
        }
      }
      .update_raw_team_state(raw_state, player_key, outcome_time)
      .update_raw_team_state(
        raw_interaction_state,
        interaction_key,
        outcome_time
      )
      champion_key <- as.character(rows$champion[[outcome_index]])
      .update_state(
        champion_state,
        champion_key,
        outcome_time,
        1,
        half_life_days
      )
      .update_raw_team_state(
        raw_champion_state,
        champion_key,
        outcome_time
      )
      pointer <- pointer + 1L
    }
    player_key <- .rolling_player_key(
      rows$player_id[[row_index]],
      rows$player_name[[row_index]],
      rows$position[[row_index]]
    )
    prior_key <- paste(
      rows$league_canonical[[row_index]],
      rows$position[[row_index]],
      sep = "|"
    )
    raw <- .raw_team_state(raw_state, player_key)
    features$raw_player_games[[query_position]] <- raw$games
    features$latest_history_datetime[[query_position]] <- raw$last
    champion_key <- as.character(rows$champion[[row_index]])
    interaction_key <- paste(
      player_key,
      champion_key,
      sep = "|champion:"
    )
    raw_champion <- .raw_team_state(
      raw_champion_state,
      champion_key
    )
    champion_history <- .query_state(
      champion_state,
      champion_key,
      cutoff,
      half_life_days
    )
    features$raw_champion_games[[query_position]] <-
      raw_champion$games
    features$effective_champion_games[[query_position]] <-
      champion_history[["weight"]]
    raw_interaction <- .raw_team_state(
      raw_interaction_state,
      interaction_key
    )
    features$raw_player_champion_games[[query_position]] <-
      raw_interaction$games
    features$latest_player_champion_history_datetime[[query_position]] <-
      raw_interaction$last
    for (metric in metric_names) {
      player_state <- .query_state(
        states[[metric]]$player,
        player_key,
        cutoff,
        half_life_days
      )
      prior_state <- .query_state(
        states[[metric]]$prior,
        prior_key,
        cutoff,
        half_life_days
      )
      global_state <- .query_state(
        states[[metric]]$global,
        as.character(rows$position[[row_index]]),
        cutoff,
        half_life_days
      )
      interaction_state <- .query_state(
        states[[metric]]$interaction,
        interaction_key,
        cutoff,
        half_life_days
      )
      prior_mean <- if (prior_state[["weight"]] > 0) {
        prior_state[["sum"]] / prior_state[["weight"]]
      } else if (global_state[["weight"]] > 0) {
        global_state[["sum"]] / global_state[["weight"]]
      } else {
        NA_real_
      }
      estimate <- if (is.finite(prior_mean)) {
        (
          player_state[["sum"]] + prior_games * prior_mean
        ) / (player_state[["weight"]] + prior_games)
      } else if (player_state[["weight"]] > 0) {
        player_state[["sum"]] / player_state[["weight"]]
      } else {
        NA_real_
      }
      features[[paste0("hist_", metric)]][[query_position]] <- estimate
      features[[
        paste0("effective_", metric, "_games")
      ]][[query_position]] <- player_state[["weight"]]
      interaction_estimate <- if (is.finite(estimate)) {
        (
          interaction_state[["sum"]] +
            interaction_prior_games * estimate
        ) / (
          interaction_state[["weight"]] +
            interaction_prior_games
        )
      } else if (interaction_state[["weight"]] > 0) {
        interaction_state[["sum"]] / interaction_state[["weight"]]
      } else {
        NA_real_
      }
      features[[paste0(
        "hist_player_champion_",
        metric
      )]][[query_position]] <- interaction_estimate
      features[[paste0(
        "effective_player_champion_",
        metric,
        "_games"
      )]][[query_position]] <- interaction_state[["weight"]]
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

#' Build leakage-safe rolling champion coverage
#'
#' @param draft_rows Champion-pick rows with series cutoffs.
#' @param half_life_days Exponential-decay half-life.
#' @return Target draft rows with frozen champion sample coverage.
#' @export
build_champion_rolling_features <- function(
  draft_rows,
  half_life_days = 60
) {
  required <- c(
    "gameid",
    "game_datetime",
    "series_cutoff",
    "competition_role",
    "side",
    "position",
    "champion"
  )
  missing <- setdiff(required, names(draft_rows))
  if (length(missing) > 0L) {
    stop(
      "Missing rolling champion columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  rows <- draft_rows[
    draft_rows$competition_role %in% c("target", "auxiliary") &
      !is.na(draft_rows$game_datetime) &
      !is.na(draft_rows$series_cutoff) &
      !is.na(draft_rows$champion) &
      nzchar(as.character(draft_rows$champion)),
    ,
    drop = FALSE
  ]
  rows$.original_index <- seq_len(nrow(rows))
  outcome_order <- order(
    rows$game_datetime,
    rows$gameid,
    rows$side,
    rows$position
  )
  target_index <- which(rows$competition_role == "target")
  query_order <- target_index[order(
    rows$series_cutoff[target_index],
    rows$gameid[target_index],
    rows$side[target_index],
    rows$position[target_index]
  )]
  champion_state <- new.env(hash = TRUE, parent = emptyenv())
  raw_champion_state <- new.env(hash = TRUE, parent = emptyenv())
  features <- rows[query_order, c(
    "gameid",
    "game_datetime",
    "series_cutoff",
    "side",
    "position",
    "champion"
  ), drop = FALSE]
  features$.original_index <- rows$.original_index[query_order]
  features$raw_champion_games <- integer(nrow(features))
  features$effective_champion_games <- numeric(nrow(features))
  pointer <- 1L
  for (query_position in seq_along(query_order)) {
    row_index <- query_order[[query_position]]
    cutoff <- as.numeric(rows$series_cutoff[[row_index]])
    while (
      pointer <= length(outcome_order) &&
        as.numeric(rows$game_datetime[[outcome_order[[pointer]]]]) < cutoff
    ) {
      outcome_index <- outcome_order[[pointer]]
      outcome_time <- as.numeric(rows$game_datetime[[outcome_index]])
      champion_key <- as.character(rows$champion[[outcome_index]])
      .update_state(
        champion_state,
        champion_key,
        outcome_time,
        1,
        half_life_days
      )
      .update_raw_team_state(
        raw_champion_state,
        champion_key,
        outcome_time
      )
      pointer <- pointer + 1L
    }
    champion_key <- as.character(rows$champion[[row_index]])
    raw <- .raw_team_state(raw_champion_state, champion_key)
    history <- .query_state(
      champion_state,
      champion_key,
      cutoff,
      half_life_days
    )
    features$raw_champion_games[[query_position]] <- raw$games
    features$effective_champion_games[[query_position]] <-
      history[["weight"]]
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

#' Assemble player and draft signals for each map
#'
#' @param player_features Frozen player histories with final champions.
#' @param taxonomy Static champion taxonomy.
#' @return One row per map with symmetric player and draft signals.
#' @export
assemble_player_draft_features <- function(player_features, taxonomy) {
  required <- c(
    "gameid",
    "side",
    "position",
    "player_id",
    "player_name",
    "champion",
    "raw_player_games",
    "raw_champion_games",
    "effective_champion_games",
    "effective_conflict_involvement_per_minute_games",
    "hist_conflict_involvement_per_minute",
    "hist_kills_assists_per_minute",
    "hist_deaths_per_minute",
    "hist_damage_per_minute"
  )
  missing <- setdiff(required, names(player_features))
  if (length(missing) > 0L) {
    stop(
      "Missing player draft columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  validate_champion_taxonomy(
    taxonomy,
    unique(as.character(player_features$champion))
  )
  groups <- split(player_features, player_features$gameid)
  rows <- lapply(groups, function(map) {
    if (
      nrow(map) != 10L ||
        !setequal(map$side, c("Blue", "Red")) ||
        any(table(map$side) != 5L)
    ) {
      stop("Each draft requires five players per side.", call. = FALSE)
    }
    side_scores <- lapply(c("Blue", "Red"), function(side) {
      side_rows <- map[map$side == side, , drop = FALSE]
      score_composition_archetypes(side_rows$champion, taxonomy)
    })
    names(side_scores) <- c("blue", "red")
    average_score <- function(column) {
      mean(c(
        side_scores$blue[[column]],
        side_scores$red[[column]]
      ))
    }
    imbalance <- function(column) {
      abs(
        side_scores$blue[[column]] -
          side_scores$red[[column]]
      )
    }
    result_row <- data.frame(
      gameid = as.character(map$gameid[[1L]]),
      player_conflict = mean(
        map$hist_conflict_involvement_per_minute
      ),
      player_aggression = mean(
        map$hist_kills_assists_per_minute
      ),
      player_mortality = mean(map$hist_deaths_per_minute),
      player_damage = mean(map$hist_damage_per_minute),
      minimum_raw_player_games = min(map$raw_player_games),
      minimum_effective_player_games = min(
        map$effective_conflict_involvement_per_minute_games
      ),
      minimum_raw_champion_games = min(map$raw_champion_games),
      minimum_effective_champion_games = min(
        map$effective_champion_games
      ),
      draft_frontline = average_score("frontline_score"),
      draft_damage = average_score("damage_score"),
      draft_magic = average_score("magic_score"),
      draft_burst = average_score("burst_score"),
      draft_utility = average_score("utility_score"),
      draft_difficulty = average_score("execution_difficulty"),
      draft_frontline_imbalance = imbalance("frontline_score"),
      draft_damage_imbalance = imbalance("damage_score"),
      stringsAsFactors = FALSE
    )
    interaction_column <- paste0(
      "hist_player_champion_",
      "conflict_involvement_per_minute"
    )
    if (interaction_column %in% names(map)) {
      result_row$player_champion_conflict <- mean(
        map[[interaction_column]]
      )
      result_row$player_champion_conflict_delta <- mean(
        map[[interaction_column]] -
          map$hist_conflict_involvement_per_minute
      )
      if ("raw_player_champion_games" %in% names(map)) {
        result_row$minimum_raw_player_champion_games <- min(
          map$raw_player_champion_games
        )
      }
      effective_column <- paste0(
        "effective_player_champion_",
        "conflict_involvement_per_minute_games"
      )
      if (effective_column %in% names(map)) {
        result_row$minimum_effective_player_champion_games <- min(
          map[[effective_column]]
        )
      }
    }
    functional_scores <- intersect(
      c(
        "engage_score", "pick_score", "poke_siege_score",
        "dive_score", "protect_score", "front_to_back_score",
        "split_map_score", "skirmish_score", "scaling_score"
      ),
      names(side_scores$blue)
    )
    for (score in functional_scores) {
      name <- sub("_score$", "", score)
      result_row[[paste0("draft_", name)]] <-
        average_score(score)
      result_row[[paste0("draft_", name, "_imbalance")]] <-
        imbalance(score)
    }
    if ("primary_archetype" %in% names(side_scores$blue)) {
      result_row$blue_primary_archetype <-
        side_scores$blue$primary_archetype
      result_row$red_primary_archetype <-
        side_scores$red$primary_archetype
      result_row$blue_secondary_archetype <-
        side_scores$blue$secondary_archetype
      result_row$red_secondary_archetype <-
        side_scores$red$secondary_archetype
      result_row$draft_archetype_confidence <- average_score(
        "archetype_confidence"
      )
      result_row$draft_functional_coverage <- average_score(
        "functional_coverage"
      )
    }
    result_row
  })
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

#' Assemble draft-only signals for each map
#'
#' Player identities and player histories are intentionally ignored. Player
#' rows are used only as the source format for champion picks and positions.
#'
#' @param draft_rows Frozen map rows with final champions.
#' @param taxonomy Static champion taxonomy.
#' @return One row per map with champion coverage and composition signals.
#' @export
assemble_draft_features <- function(draft_rows, taxonomy) {
  required <- c(
    "gameid",
    "side",
    "position",
    "champion",
    "raw_champion_games",
    "effective_champion_games"
  )
  missing <- setdiff(required, names(draft_rows))
  if (length(missing) > 0L) {
    stop(
      "Missing draft columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  validate_champion_taxonomy(
    taxonomy,
    unique(as.character(draft_rows$champion))
  )
  groups <- split(draft_rows, draft_rows$gameid)
  rows <- lapply(groups, function(map) {
    if (
      nrow(map) != 10L ||
        !setequal(map$side, c("Blue", "Red")) ||
        any(table(map$side) != 5L)
    ) {
      stop("Each draft requires five champions per side.", call. = FALSE)
    }
    side_scores <- lapply(c("Blue", "Red"), function(side) {
      side_rows <- map[map$side == side, , drop = FALSE]
      score_composition_archetypes(side_rows$champion, taxonomy)
    })
    names(side_scores) <- c("blue", "red")
    average_score <- function(column) {
      mean(c(
        side_scores$blue[[column]],
        side_scores$red[[column]]
      ))
    }
    imbalance <- function(column) {
      abs(
        side_scores$blue[[column]] -
          side_scores$red[[column]]
      )
    }
    result_row <- data.frame(
      gameid = as.character(map$gameid[[1L]]),
      minimum_raw_champion_games = min(map$raw_champion_games),
      minimum_effective_champion_games = min(
        map$effective_champion_games
      ),
      draft_frontline = average_score("frontline_score"),
      draft_damage = average_score("damage_score"),
      draft_magic = average_score("magic_score"),
      draft_burst = average_score("burst_score"),
      draft_utility = average_score("utility_score"),
      draft_difficulty = average_score("execution_difficulty"),
      draft_frontline_imbalance = imbalance("frontline_score"),
      draft_damage_imbalance = imbalance("damage_score"),
      stringsAsFactors = FALSE
    )
    functional_scores <- intersect(
      c(
        "engage_score", "pick_score", "poke_siege_score",
        "dive_score", "protect_score", "front_to_back_score",
        "split_map_score", "skirmish_score", "scaling_score"
      ),
      names(side_scores$blue)
    )
    for (score in functional_scores) {
      name <- sub("_score$", "", score)
      result_row[[paste0("draft_", name)]] <-
        average_score(score)
      result_row[[paste0("draft_", name, "_imbalance")]] <-
        imbalance(score)
    }
    if ("primary_archetype" %in% names(side_scores$blue)) {
      result_row$blue_primary_archetype <-
        side_scores$blue$primary_archetype
      result_row$red_primary_archetype <-
        side_scores$red$primary_archetype
      result_row$blue_secondary_archetype <-
        side_scores$blue$secondary_archetype
      result_row$red_secondary_archetype <-
        side_scores$red$secondary_archetype
      result_row$draft_archetype_confidence <- average_score(
        "archetype_confidence"
      )
      result_row$draft_functional_coverage <- average_score(
        "functional_coverage"
      )
    }
    result_row
  })
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}
