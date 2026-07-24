.portable_entity_key <- function(identifier, name, position = NULL) {
  identity <- if (!is.null(identifier) &&
      length(identifier) == 1L &&
      !is.na(identifier) &&
      nzchar(as.character(identifier))) {
    paste0("id:", identifier)
  } else {
    paste0("name:", tolower(trimws(as.character(name))))
  }
  if (is.null(position)) {
    identity
  } else {
    paste(identity, tolower(as.character(position)), sep = "|")
  }
}

.portable_composition_scores <- function(champions, taxonomy) {
  if (length(champions) != 5L || anyDuplicated(champions)) {
    stop(
      "Cada equipe precisa de cinco campe\u00f5es \u00fanicos.",
      call. = FALSE
    )
  }
  missing <- setdiff(champions, names(taxonomy))
  if (length(missing) > 0L) {
    stop(
      "Campe\u00e3o sem taxonomia: ",
      missing[[1L]],
      ". N\u00e3o apostar.",
      call. = FALSE
    )
  }
  rows <- taxonomy[champions]
  average <- function(field) {
    mean(vapply(rows, function(row) as.numeric(row[[field]]), numeric(1L)))
  }
  logical_average <- function(first, second) {
    mean(vapply(rows, function(row) {
      as.numeric(isTRUE(row[[first]]) || isTRUE(row[[second]]))
    }, numeric(1L)))
  }
  list(
    frontline_score = mean(vapply(rows, function(row) {
      0.6 * as.numeric(row$defense) +
        0.4 * as.numeric(isTRUE(row$tank) || isTRUE(row$fighter))
    }, numeric(1L))),
    damage_score = average("attack"),
    magic_score = average("magic"),
    burst_score = logical_average("assassin", "mage"),
    utility_score = logical_average("support", "tank"),
    execution_difficulty = average("difficulty")
  )
}

.portable_lookup <- function(rows, key) {
  keys <- vapply(rows, `[[`, character(1L), "key")
  index <- match(key, keys)
  if (is.na(index)) NULL else rows[[index]]
}

.portable_derive_features <- function(request, bundle) {
  teams <- list()
  players <- list()
  champions <- character()
  warnings <- character()
  positions <- c("top", "jng", "mid", "bot", "sup")
  if (identical(
    as.character(request$blue$team_name),
    as.character(request$red$team_name)
  )) {
    stop(
      "As equipes azul e vermelha devem ser diferentes.",
      call. = FALSE
    )
  }
  for (side in c("blue", "red")) {
    side_request <- request[[side]]
    team_key <- .portable_entity_key(
      side_request$team_id,
      side_request$team_name
    )
    team <- .portable_lookup(bundle$teams, team_key)
    if (is.null(team) ||
        as.numeric(team$effective_team_games) <
          as.numeric(bundle$sample_limits$team_effective_games)) {
      stop(
        "Pouca amostra para ",
        side_request$team_name,
        ". N\u00e3o apostar.",
        call. = FALSE
      )
    }
    teams[[side]] <- team
    side_positions <- vapply(
      side_request$players,
      `[[`,
      character(1L),
      "position"
    )
    if (!identical(side_positions, positions)) {
      stop(
        "As posi\u00e7\u00f5es devem ser top, jng, mid, bot e sup.",
        call. = FALSE
      )
    }
    for (player_request in side_request$players) {
      player_key <- .portable_entity_key(
        player_request$player_id,
        player_request$player_name,
        player_request$position
      )
      player <- .portable_lookup(bundle$players, player_key)
      if (is.null(player) ||
          as.numeric(player$effective_player_games) <
            as.numeric(bundle$sample_limits$player_effective_games)) {
        stop(
          "Pouca amostra para ",
          player_request$player_name,
          ". N\u00e3o apostar.",
          call. = FALSE
        )
      }
      players[[length(players) + 1L]] <- player
      champions <- c(champions, player_request$champion)
    }
  }
  if (anyDuplicated(champions)) {
    stop(
      "O draft n\u00e3o pode repetir campe\u00f5es.",
      call. = FALSE
    )
  }
  for (champion in champions) {
    sample <- bundle$champion_samples[[champion]]
    if (is.null(sample) ||
        as.numeric(sample) <
          as.numeric(bundle$sample_limits$champion_effective_games)) {
      stop(
        "Pouca amostra para ",
        champion,
        ". N\u00e3o apostar.",
        call. = FALSE
      )
    }
  }
  blue_scores <- .portable_composition_scores(
    champions[seq_len(5L)],
    bundle$taxonomy
  )
  red_scores <- .portable_composition_scores(
    champions[6:10],
    bundle$taxonomy
  )
  player_field_mean <- function(field) {
    mean(vapply(players, function(player) {
      as.numeric(player[[field]])
    }, numeric(1L)))
  }
  list(
    features = list(
      pace = mean(vapply(teams, function(team) {
        as.numeric(team$hist_pace)
      }, numeric(1L))),
      player_conflict = player_field_mean(
        "hist_conflict_involvement_per_minute"
      ),
      player_mortality = player_field_mean(
        "hist_deaths_per_minute"
      ),
      draft_frontline = mean(c(
        blue_scores$frontline_score,
        red_scores$frontline_score
      )),
      draft_burst = mean(c(
        blue_scores$burst_score,
        red_scores$burst_score
      )),
      draft_frontline_imbalance = abs(
        blue_scores$frontline_score -
          red_scores$frontline_score
      )
    ),
    warnings = warnings
  )
}

#' Predict from a portable public-inference request
#'
#' @param request Nested inference request.
#' @param bundle Portable model bundle.
#' @return Prediction contract list with status `ok` or `blocked`.
#' @export
predict_portable_request <- function(request, bundle) {
  tryCatch({
    line <- as.numeric(request$line)
    if (!is.finite(line) || abs(line %% 1 - 0.5) > 1e-12) {
      stop("A linha precisa terminar em .5.", call. = FALSE)
    }
    derived <- .portable_derive_features(request, bundle)
    model <- bundle$model
    league <- as.character(request$league)
    if (!league %in% unlist(model$league_levels)) {
      stop("Liga n\u00e3o suportada: ", league, ".", call. = FALSE)
    }
    coefficients <- unlist(model$coefficients)
    linear <- as.numeric(coefficients[["(Intercept)"]])
    league_term <- paste0("league_canonical", league)
    if (league_term %in% names(coefficients)) {
      linear <- linear + as.numeric(coefficients[[league_term]])
    }
    for (feature in unlist(model$feature_names)) {
      scaling <- model$scaling[[feature]]
      standardized <- (
        as.numeric(derived$features[[feature]]) -
          as.numeric(scaling$center)
      ) / as.numeric(scaling$scale)
      linear <- linear +
        as.numeric(coefficients[[feature]]) * standardized
    }
    prediction_mean <- exp(linear)
    support_max <- stats::qnbinom(
      1 - 1e-10,
      size = as.numeric(model$theta),
      mu = prediction_mean
    )
    support <- seq.int(0L, as.integer(support_max))
    pmf <- stats::dnbinom(
      support,
      size = as.numeric(model$theta),
      mu = prediction_mean
    )
    pmf <- pmf / sum(pmf)
    probability_under <- sum(pmf[support <= floor(line)])
    probability_over <- 1 - probability_under
    quantile_pmf <- function(probability) {
      which(cumsum(pmf) >= probability)[[1L]] - 1L
    }
    identity <- paste(
      request$league,
      request$planned_at,
      request$blue$team_name,
      request$red$team_name,
      request$map_number,
      sep = "|"
    )
    result <- list(
      status = "ok",
      prediction_id = substr(
        digest::digest(identity, algo = "sha256", serialize = FALSE),
        1L,
        24L
      ),
      mean = prediction_mean,
      median = quantile_pmf(0.5),
      prediction_interval_90 = c(
        quantile_pmf(0.05),
        quantile_pmf(0.95)
      ),
      pmf = pmf,
      probability_over = probability_over,
      probability_under = probability_under,
      probability_push = 0,
      fair_odds_over = 1 / probability_over,
      fair_odds_under = 1 / probability_under,
      features = derived$features,
      warnings = derived$warnings,
      model_version = bundle$metadata$model_version,
      data_cutoff = bundle$metadata$data_cutoff
    )
    if (!is.null(request$odds_over)) {
      result$ev_over <- probability_over *
        as.numeric(request$odds_over) - 1
    }
    if (!is.null(request$odds_under)) {
      result$ev_under <- probability_under *
        as.numeric(request$odds_under) - 1
    }
    result
  }, error = function(condition) {
    list(
      status = "blocked",
      reason = conditionMessage(condition),
      probability_push = 0,
      model_version = bundle$metadata$model_version,
      data_cutoff = bundle$metadata$data_cutoff
    )
  })
}
