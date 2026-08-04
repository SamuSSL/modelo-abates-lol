.market_count_probability <- function(
  mean,
  line,
  distribution,
  theta = NA_real_
) {
  threshold <- floor(as.numeric(line))
  if (distribution == "poisson") {
    return(stats::ppois(
      threshold,
      lambda = mean,
      lower.tail = FALSE
    ))
  }
  stats::pnbinom(
    threshold,
    size = theta,
    mu = mean,
    lower.tail = FALSE
  )
}

#' Invert a market total into an implied count expectation
#'
#' Finds the distribution mean whose probability above the offered line equals
#' the supplied no-vig Over probability.
#'
#' @param line Offered count line.
#' @param probability_over No-vig Over probability.
#' @param distribution `poisson` or `negative_binomial`.
#' @param theta Negative-Binomial size parameter.
#' @param tolerance Root-finding tolerance.
#' @return Implied distribution mean.
#' @export
invert_market_count_mean <- function(
  line,
  probability_over,
  distribution = c("poisson", "negative_binomial"),
  theta = NA_real_,
  tolerance = 1e-10
) {
  distribution <- match.arg(distribution)
  line <- as.numeric(line)
  probability_over <- as.numeric(probability_over)
  if (
    length(line) != 1L ||
      length(probability_over) != 1L ||
      !is.finite(line) ||
      line < 0 ||
      !is.finite(probability_over) ||
      probability_over <= 0 ||
      probability_over >= 1
  ) {
    stop("Market line and probability are invalid.", call. = FALSE)
  }
  if (
    distribution == "negative_binomial" &&
      (
        length(theta) != 1L ||
          !is.finite(theta) ||
          theta <= 0
      )
  ) {
    stop(
      "Negative-Binomial inversion requires positive theta.",
      call. = FALSE
    )
  }
  objective <- function(mean) {
    .market_count_probability(
      mean,
      line,
      distribution,
      theta
    ) - probability_over
  }
  lower <- 1e-10
  upper <- max(1, line + 1)
  while (objective(upper) < 0 && upper < 1e6) {
    upper <- upper * 2
  }
  if (objective(upper) < 0) {
    stop("Could not bracket the market-implied mean.", call. = FALSE)
  }
  stats::uniroot(
    objective,
    interval = c(lower, upper),
    tol = tolerance
  )$root
}

#' Estimate historical team-kill dispersion before a fixed cutoff
#'
#' A Poisson fixed-effects mean model controls for league, scoring team, and
#' opponent. The Negative-Binomial size is then estimated from residual
#' variation using only maps before the declared market-history cutoff.
#'
#' @param games Canonical map records.
#' @param cutoff Latest excluded map timestamp.
#' @param minimum_maps Minimum eligible maps.
#' @return Dispersion estimate and auditable training metadata.
#' @export
estimate_historical_team_kill_dispersion <- function(
  games,
  cutoff = as.POSIXct("2025-05-01 00:00:00", tz = "UTC"),
  minimum_maps = 500L
) {
  required <- c(
    "gameid",
    "game_datetime",
    "league_canonical",
    "blue_team_name",
    "red_team_name",
    "blue_kills",
    "red_kills",
    "target_valid"
  )
  missing <- setdiff(required, names(games))
  if (length(missing) > 0L) {
    stop(
      "Canonical games are missing dispersion fields: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  cutoff <- as.POSIXct(cutoff, tz = "UTC")
  eligible <- games[
    games$target_valid &
      !is.na(games$game_datetime) &
      as.POSIXct(games$game_datetime, tz = "UTC") < cutoff,
    ,
    drop = FALSE
  ]
  if (nrow(eligible) < as.integer(minimum_maps)) {
    stop("Insufficient pre-cutoff maps for dispersion.", call. = FALSE)
  }
  blue <- data.frame(
    gameid = as.character(eligible$gameid),
    game_datetime = as.POSIXct(eligible$game_datetime, tz = "UTC"),
    league = as.character(eligible$league_canonical),
    team = as.character(eligible$blue_team_name),
    opponent = as.character(eligible$red_team_name),
    kills = as.numeric(eligible$blue_kills),
    stringsAsFactors = FALSE
  )
  red <- data.frame(
    gameid = as.character(eligible$gameid),
    game_datetime = as.POSIXct(eligible$game_datetime, tz = "UTC"),
    league = as.character(eligible$league_canonical),
    team = as.character(eligible$red_team_name),
    opponent = as.character(eligible$blue_team_name),
    kills = as.numeric(eligible$red_kills),
    stringsAsFactors = FALSE
  )
  directed <- rbind(blue, red)
  directed <- directed[
    is.finite(directed$kills) & directed$kills >= 0,
    ,
    drop = FALSE
  ]
  mean_model <- stats::glm(
    kills ~ league + team + opponent,
    family = stats::poisson(),
    data = directed
  )
  fitted <- pmax(as.numeric(stats::fitted(mean_model)), 1e-8)
  negative_binomial_model <- tryCatch(
    suppressWarnings(MASS::glm.nb(
      kills ~ league + team + opponent,
      data = directed,
      control = stats::glm.control(maxit = 100L)
    )),
    error = function(error) NULL
  )
  theta <- if (!is.null(negative_binomial_model)) {
    as.numeric(negative_binomial_model$theta)
  } else {
    .estimate_nb_theta(
      directed$kills,
      fitted,
      rep(1, nrow(directed))
    )
  }
  league_groups <- split(
    seq_len(nrow(directed)),
    directed$league
  )
  by_league <- lapply(league_groups, function(index) {
    rows <- directed[index, , drop = FALSE]
    if (nrow(rows) < 200L) {
      return(data.frame(
        league_canonical = rows$league[[1L]],
        team_maps = nrow(rows),
        theta = theta,
        fallback_global = TRUE,
        stringsAsFactors = FALSE
      ))
    }
    league_model <- stats::glm(
      kills ~ team + opponent,
      family = stats::poisson(),
      data = rows
    )
    league_fitted <- pmax(
      as.numeric(stats::fitted(league_model)),
      1e-8
    )
    league_negative_binomial <- tryCatch(
      suppressWarnings(MASS::glm.nb(
        kills ~ team + opponent,
        data = rows,
        control = stats::glm.control(maxit = 100L)
      )),
      error = function(error) NULL
    )
    league_theta <- if (!is.null(league_negative_binomial)) {
      as.numeric(league_negative_binomial$theta)
    } else {
      .estimate_nb_theta(
        rows$kills,
        league_fitted,
        rep(1, nrow(rows))
      )
    }
    data.frame(
      league_canonical = rows$league[[1L]],
      team_maps = nrow(rows),
      theta = league_theta,
      fallback_global = FALSE,
      stringsAsFactors = FALSE
    )
  })
  by_league <- do.call(rbind, by_league)
  rownames(by_league) <- NULL
  list(
    global_theta = theta,
    by_league = by_league,
    training_maps = nrow(eligible),
    training_team_maps = nrow(directed),
    training_start = min(directed$game_datetime),
    training_end = max(directed$game_datetime),
    cutoff = cutoff,
    estimation_method = if (!is.null(negative_binomial_model)) {
      "negative_binomial_maximum_likelihood"
    } else {
      "moment_fallback"
    },
    mean_model_deviance = stats::deviance(mean_model),
    mean_model_df_residual = stats::df.residual(mean_model)
  )
}

#' Derive market-implied team-kill expectations
#'
#' @param data Normalized team-total observations.
#' @param distribution `poisson` or `negative_binomial`.
#' @param theta Scalar or row-specific Negative-Binomial size.
#' @return Input rows with no-vig probability and implied mean.
#' @export
derive_market_implied_team_kills <- function(
  data,
  distribution = c("poisson", "negative_binomial"),
  theta = NA_real_
) {
  distribution <- match.arg(distribution)
  required <- c("line", "true_odds_over", "true_odds_under")
  if (!all(required %in% names(data))) {
    stop("Team-total rows are missing market inputs.", call. = FALSE)
  }
  result <- derive_team_total_probabilities(data)
  if (length(theta) == 1L) {
    theta <- rep(theta, nrow(result))
  }
  if (length(theta) != nrow(result)) {
    stop("theta must be scalar or match team-total rows.", call. = FALSE)
  }
  result$implied_distribution <- distribution
  result$implied_theta <- if (distribution == "poisson") {
    rep(Inf, nrow(result))
  } else {
    as.numeric(theta)
  }
  result$implied_mean <- vapply(
    seq_len(nrow(result)),
    function(index) {
      invert_market_count_mean(
        result$line[[index]],
        result$p_over[[index]],
        distribution,
        theta[[index]]
      )
    },
    numeric(1L)
  )
  result
}

#' Score market-implied marginal team-kill distributions
#'
#' @param data Rows containing observed `team_kills`.
#' @param distribution `poisson` or `negative_binomial`.
#' @param theta Scalar or row-specific Negative-Binomial size.
#' @param mean_distribution Distribution inverted to obtain the mean. Defaults
#'   to the scored distribution. Setting this to `poisson` while scoring a
#'   Negative Binomial preserves the Poisson-implied market center while adding
#'   historical overdispersion.
#' @param tail_tolerance Maximum PMF tail probability.
#' @return Observation-level scores and intervals.
#' @export
score_market_implied_team_kills <- function(
  data,
  distribution = c("poisson", "negative_binomial"),
  theta = NA_real_,
  mean_distribution = distribution,
  tail_tolerance = 1e-10
) {
  distribution <- match.arg(distribution)
  mean_distribution <- match.arg(
    mean_distribution,
    c("poisson", "negative_binomial")
  )
  if (!"team_kills" %in% names(data)) {
    stop("Observed team_kills are required for scoring.", call. = FALSE)
  }
  result <- derive_market_implied_team_kills(
    data,
    mean_distribution,
    theta
  )
  result$mean_inversion_distribution <- result$implied_distribution
  result$implied_distribution <- distribution
  if (length(theta) == 1L) {
    theta <- rep(theta, nrow(result))
  }
  result$implied_theta <- if (distribution == "poisson") {
    rep(Inf, nrow(result))
  } else {
    as.numeric(theta)
  }
  observed <- suppressWarnings(as.integer(result$team_kills))
  if (anyNA(observed) || any(observed < 0L)) {
    stop("Observed team kills must be non-negative integers.", call. = FALSE)
  }
  scores <- lapply(seq_len(nrow(result)), function(index) {
    theta_value <- result$implied_theta[[index]]
    prediction <- make_count_pmf(
      result$implied_mean[[index]],
      distribution,
      theta_value,
      tail_tolerance
    )
    observed_index <- observed[[index]] + 1L
    probability_observed <- if (
      observed_index <= length(prediction$pmf)
    ) {
      prediction$pmf[[observed_index]]
    } else {
      if (distribution == "poisson") {
        stats::dpois(
          observed[[index]],
          result$implied_mean[[index]]
        )
      } else {
        stats::dnbinom(
          observed[[index]],
          size = theta_value,
          mu = result$implied_mean[[index]]
        )
      }
    }
    cumulative <- cumsum(prediction$pmf)
    quantile_from_pmf <- function(probability) {
      which(cumulative >= probability)[[1L]] - 1L
    }
    data.frame(
      probability_observed = probability_observed,
      log_score = -log(pmax(probability_observed, 1e-300)),
      crps = discrete_crps(prediction$pmf, observed[[index]]),
      lower_50 = quantile_from_pmf(0.25),
      upper_50 = quantile_from_pmf(0.75),
      lower_80 = quantile_from_pmf(0.10),
      upper_80 = quantile_from_pmf(0.90),
      lower_90 = quantile_from_pmf(0.05),
      upper_90 = quantile_from_pmf(0.95),
      tail_mass = prediction$tail_mass,
      stringsAsFactors = FALSE
    )
  })
  scores <- do.call(rbind, scores)
  result$team_kills <- observed
  result$absolute_error <- abs(observed - result$implied_mean)
  result$squared_error <- (observed - result$implied_mean)^2
  result$signed_error <- observed - result$implied_mean
  result$probability_observed <- scores$probability_observed
  result$log_score <- scores$log_score
  result$crps <- scores$crps
  result$lower_50 <- scores$lower_50
  result$upper_50 <- scores$upper_50
  result$lower_80 <- scores$lower_80
  result$upper_80 <- scores$upper_80
  result$lower_90 <- scores$lower_90
  result$upper_90 <- scores$upper_90
  result$tail_mass <- scores$tail_mass
  result
}
