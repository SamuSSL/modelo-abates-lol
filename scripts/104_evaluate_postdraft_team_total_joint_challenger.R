script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

output_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "postdraft-team-total-joint-challenger"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

database_path <- file.path(
  project_root,
  "data",
  "processed",
  "lolkills.duckdb"
)
connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = database_path,
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

market <- DBI::dbGetQuery(connection, "
  with post as (
    select q.*
    from market_postdraft_quotes q
    where q.gameid is not null
    qualify row_number() over (
      partition by q.gameid
      order by q.quote_time desc, q.snapshot_id desc
    ) = 1
  ),
  live_total as (
    select q.gameid, s.line as total_line,
           s.odds_over as total_odds_over,
           s.odds_under as total_odds_under,
           s.true_odds_over as total_true_odds_over,
           s.true_odds_under as total_true_odds_under,
           s.odds_timestamp as total_quote_time
    from post q
    join market_live_odds_snapshots s
      on s.event_id = q.live_event_id and s.period = q.period
    where s.market = 'totals' and s.alt_line_id is null
    qualify row_number() over (
      partition by q.gameid
      order by s.odds_timestamp, try_cast(s.line_id as bigint), s.snapshot_id
    ) = 1
  ),
  team_latest as (
    select q.gameid, t.market, t.team_side, t.team_name,
           t.line, t.odds_over, t.odds_under,
           t.true_odds_over, t.true_odds_under, t.odds_timestamp,
           epoch(t.odds_timestamp - q.live_open_time) as lag_seconds
    from post q
    join market_team_totals_snapshots t
      on t.event_id = q.prematch_event_id and t.period = q.period
    where t.odds_timestamp <= q.live_open_time + interval 60 second
    qualify row_number() over (
      partition by q.gameid, t.market
      order by t.odds_timestamp desc, t.team_total_snapshot_id desc
    ) = 1
  ),
  team_wide as (
    select gameid,
      max(case when market = 'home_totals' then team_name end) as home_market_name,
      max(case when market = 'home_totals' then line end) as home_line,
      max(case when market = 'home_totals' then true_odds_over end) as home_true_odds_over,
      max(case when market = 'home_totals' then true_odds_under end) as home_true_odds_under,
      max(case when market = 'home_totals' then odds_timestamp end) as home_quote_time,
      max(case when market = 'home_totals' then lag_seconds end) as home_lag_seconds,
      max(case when market = 'away_totals' then team_name end) as away_market_name,
      max(case when market = 'away_totals' then line end) as away_line,
      max(case when market = 'away_totals' then true_odds_over end) as away_true_odds_over,
      max(case when market = 'away_totals' then true_odds_under end) as away_true_odds_under,
      max(case when market = 'away_totals' then odds_timestamp end) as away_quote_time,
      max(case when market = 'away_totals' then lag_seconds end) as away_lag_seconds
    from team_latest
    group by gameid
    having count(distinct market) = 2
  )
  select q.gameid, g.series_id, g.game_datetime, g.league_canonical,
         g.blue_team_name, g.red_team_name, g.blue_kills, g.red_kills,
         g.total_kills_game, q.live_open_time,
         l.team_home_market, l.team_away_market,
         t.total_line, t.total_true_odds_over, t.total_true_odds_under,
         t.total_quote_time, w.* exclude(gameid)
  from post q
  join live_total t on t.gameid = q.gameid
  join team_wide w on w.gameid = q.gameid
  join canonical_games g on g.gameid = q.gameid and g.target_valid
  join game_market_links l
    on l.event_id = q.prematch_event_id and l.period = q.period
  order by g.game_datetime, q.gameid
")

canonical <- DBI::dbGetQuery(connection, "
  select gameid, series_id, game_datetime, league_canonical,
         blue_team_name, red_team_name, blue_kills, red_kills,
         total_kills_game
  from canonical_games
  where target_valid
  order by game_datetime, gameid
")

as_utc <- function(value) as.POSIXct(value, tz = "UTC")
market$game_datetime <- as_utc(market$game_datetime)
market$live_open_time <- as_utc(market$live_open_time)
market$total_quote_time <- as_utc(market$total_quote_time)
market$home_quote_time <- as_utc(market$home_quote_time)
market$away_quote_time <- as_utc(market$away_quote_time)
canonical$game_datetime <- as_utc(canonical$game_datetime)

team_key <- function(value) {
  value <- gsub("\\s*\\(Kills\\)\\s*$", "", as.character(value), ignore.case = TRUE)
  value <- iconv(value, from = "", to = "ASCII//TRANSLIT")
  value <- tolower(value)
  gsub("[^a-z0-9]", "", value)
}

market$home_key <- team_key(market$team_home_market)
market$away_key <- team_key(market$team_away_market)
market$blue_key <- team_key(market$blue_team_name)
market$red_key <- team_key(market$red_team_name)
normalized_edit_distance <- function(first, second) {
  denominator <- pmax(nchar(first), nchar(second), 1L)
  distance <- vapply(seq_along(first), function(index) {
    as.numeric(utils::adist(first[[index]], second[[index]], partial = FALSE))
  }, numeric(1L))
  distance / denominator
}
market$orientation_direct_distance <-
  normalized_edit_distance(market$home_key, market$blue_key) +
  normalized_edit_distance(market$away_key, market$red_key)
market$orientation_swapped_distance <-
  normalized_edit_distance(market$home_key, market$red_key) +
  normalized_edit_distance(market$away_key, market$blue_key)
market$home_is_blue <- market$orientation_direct_distance <
  market$orientation_swapped_distance
market$home_is_red <- market$orientation_swapped_distance <
  market$orientation_direct_distance
market$orientation_margin <- abs(
  market$orientation_direct_distance - market$orientation_swapped_distance
)
market$orientation_valid <- (market$home_is_blue | market$home_is_red) &
  market$orientation_margin >= 0.10
market <- market[market$orientation_valid, , drop = FALSE]
market$home_team_name <- ifelse(
  market$home_is_blue,
  market$blue_team_name,
  market$red_team_name
)
market$away_team_name <- ifelse(
  market$home_is_blue,
  market$red_team_name,
  market$blue_team_name
)
market$home_kills <- ifelse(
  market$home_is_blue,
  market$blue_kills,
  market$red_kills
)
market$away_kills <- ifelse(
  market$home_is_blue,
  market$red_kills,
  market$blue_kills
)

no_vig_over <- function(over_odds, under_odds) {
  over_raw <- 1 / as.numeric(over_odds)
  under_raw <- 1 / as.numeric(under_odds)
  over_raw / (over_raw + under_raw)
}
market$p_total_over <- no_vig_over(
  market$total_true_odds_over,
  market$total_true_odds_under
)
market$p_home_over <- no_vig_over(
  market$home_true_odds_over,
  market$home_true_odds_under
)
market$p_away_over <- no_vig_over(
  market$away_true_odds_over,
  market$away_true_odds_under
)
market$sample <- ifelse(
  market$game_datetime < as_utc("2026-05-01 00:00:00"),
  "adjustment_mar_apr",
  ifelse(
    market$game_datetime < as_utc("2026-06-01 00:00:00"),
    "selection_may",
    "diagnostic_jun_jul"
  )
)

directed_history <- rbind(
  data.frame(
    gameid = canonical$gameid,
    game_datetime = canonical$game_datetime,
    league_canonical = canonical$league_canonical,
    side = "Blue",
    team = canonical$blue_team_name,
    opponent = canonical$red_team_name,
    kills = canonical$blue_kills,
    conceded = canonical$red_kills,
    stringsAsFactors = FALSE
  ),
  data.frame(
    gameid = canonical$gameid,
    game_datetime = canonical$game_datetime,
    league_canonical = canonical$league_canonical,
    side = "Red",
    team = canonical$red_team_name,
    opponent = canonical$blue_team_name,
    kills = canonical$red_kills,
    conceded = canonical$blue_kills,
    stringsAsFactors = FALSE
  )
)

weighted_mean_safe <- function(value, weight, fallback) {
  valid <- is.finite(value) & is.finite(weight) & weight > 0
  if (!any(valid)) return(fallback)
  sum(value[valid] * weight[valid]) / sum(weight[valid])
}

midpoint_nb_pit <- function(observed, mean, theta) {
  lower <- stats::pnbinom(observed - 1L, size = theta, mu = mean)
  mass <- stats::dnbinom(observed, size = theta, mu = mean)
  pmin(1 - 1e-8, pmax(1e-8, lower + 0.5 * mass))
}

fit_month_league_parameters <- function(cutoff, league) {
  history <- directed_history[
    directed_history$game_datetime < cutoff &
      directed_history$game_datetime >= cutoff - 365 * 86400 &
      directed_history$league_canonical == league,
    ,
    drop = FALSE
  ]
  fallback <- directed_history[
    directed_history$game_datetime < cutoff &
      directed_history$game_datetime >= cutoff - 365 * 86400,
    ,
    drop = FALSE
  ]
  if (nrow(history) < 400L) history <- fallback
  history$weight <- 0.5^(
    as.numeric(difftime(cutoff, history$game_datetime, units = "days")) / 60
  )
  history$team_factor <- factor(history$team)
  history$opponent_factor <- factor(history$opponent)
  history$side_factor <- factor(history$side)
  fit <- suppressWarnings(tryCatch(
    MASS::glm.nb(
      kills ~ side_factor + team_factor + opponent_factor,
      data = history,
      weights = weight,
      control = stats::glm.control(maxit = 100L)
    ),
    error = function(error) NULL
  ))
  if (is.null(fit)) {
    fit <- suppressWarnings(MASS::glm.nb(
      kills ~ side_factor,
      data = history,
      weights = weight,
      control = stats::glm.control(maxit = 100L)
    ))
  }
  fitted_mean <- pmax(0.1, as.numeric(stats::fitted(fit)))
  theta <- as.numeric(fit$theta)
  z <- stats::qnorm(midpoint_nb_pit(history$kills, fitted_mean, theta))
  residual_frame <- data.frame(
    gameid = history$gameid,
    side = history$side,
    z = z,
    weight = history$weight,
    stringsAsFactors = FALSE
  )
  blue <- residual_frame[
    residual_frame$side == "Blue",
    c("gameid", "z", "weight")
  ]
  red <- residual_frame[
    residual_frame$side == "Red",
    c("gameid", "z", "weight")
  ]
  paired <- merge(blue, red, by = "gameid", suffixes = c("_blue", "_red"))
  rho_raw <- stats::cor(paired$z_blue, paired$z_red)
  if (!is.finite(rho_raw)) rho_raw <- 0
  rho <- pmax(-0.85, pmin(0.85, 0.75 * rho_raw))
  total_frame <- canonical[
    canonical$game_datetime < cutoff &
      canonical$game_datetime >= cutoff - 365 * 86400 &
      canonical$league_canonical == league,
    ,
    drop = FALSE
  ]
  if (nrow(total_frame) < 200L) {
    total_frame <- canonical[
      canonical$game_datetime < cutoff &
        canonical$game_datetime >= cutoff - 365 * 86400,
      ,
      drop = FALSE
    ]
  }
  total_frame$weight <- 0.5^(
    as.numeric(difftime(cutoff, total_frame$game_datetime, units = "days")) / 60
  )
  total_fit <- suppressWarnings(MASS::glm.nb(
    total_kills_game ~ 1,
    data = total_frame,
    weights = weight,
    control = stats::glm.control(maxit = 100L)
  ))
  data.frame(
    parameter_cutoff = cutoff,
    league_canonical = league,
    theta_team = theta,
    theta_total = as.numeric(total_fit$theta),
    rho_raw = rho_raw,
    rho = rho,
    training_team_maps = nrow(history),
    training_maps_total = nrow(total_frame),
    stringsAsFactors = FALSE
  )
}

market$parameter_cutoff <- as_utc(format(
  market$game_datetime,
  "%Y-%m-01 00:00:00",
  tz = "UTC"
))
parameter_keys <- unique(market[c("parameter_cutoff", "league_canonical")])
parameters <- do.call(rbind, lapply(seq_len(nrow(parameter_keys)), function(index) {
  message(sprintf(
    "Parametros %s %s",
    format(parameter_keys$parameter_cutoff[[index]], "%Y-%m-%d", tz = "UTC"),
    parameter_keys$league_canonical[[index]]
  ))
  fit_month_league_parameters(
    parameter_keys$parameter_cutoff[[index]],
    parameter_keys$league_canonical[[index]]
  )
}))
market <- merge(
  market,
  parameters,
  by = c("parameter_cutoff", "league_canonical"),
  all.x = TRUE,
  sort = FALSE
)
market <- market[order(market$game_datetime, market$gameid), , drop = FALSE]

rolling_team_prior <- function(datetime, league, team, opponent) {
  history <- directed_history[
    directed_history$game_datetime < datetime &
      directed_history$game_datetime >= datetime - 365 * 86400 &
      directed_history$league_canonical == league,
    ,
    drop = FALSE
  ]
  if (nrow(history) < 200L) {
    history <- directed_history[
      directed_history$game_datetime < datetime &
        directed_history$game_datetime >= datetime - 365 * 86400,
      ,
      drop = FALSE
    ]
  }
  weight <- 0.5^(
    as.numeric(difftime(datetime, history$game_datetime, units = "days")) / 60
  )
  league_mean <- weighted_mean_safe(history$kills, weight, 12)
  team_rows <- history$team == team
  opponent_rows <- history$team == opponent
  team_weight <- sum(weight[team_rows])
  opponent_weight <- sum(weight[opponent_rows])
  attack_raw <- weighted_mean_safe(
    history$kills[team_rows],
    weight[team_rows],
    league_mean
  )
  opponent_conceded_raw <- weighted_mean_safe(
    history$conceded[opponent_rows],
    weight[opponent_rows],
    league_mean
  )
  attack <- (team_weight * attack_raw + 10 * league_mean) /
    (team_weight + 10)
  opponent_conceded <- (
    opponent_weight * opponent_conceded_raw + 10 * league_mean
  ) / (opponent_weight + 10)
  list(
    mean = sqrt(pmax(0.1, attack) * pmax(0.1, opponent_conceded)),
    attack = attack,
    opponent_conceded = opponent_conceded,
    team_effective_weight = team_weight,
    opponent_effective_weight = opponent_weight,
    league_mean = league_mean
  )
}

prior_rows <- lapply(seq_len(nrow(market)), function(index) {
  row <- market[index, , drop = FALSE]
  home <- rolling_team_prior(
    row$game_datetime,
    row$league_canonical,
    row$home_team_name,
    row$away_team_name
  )
  away <- rolling_team_prior(
    row$game_datetime,
    row$league_canonical,
    row$away_team_name,
    row$home_team_name
  )
  data.frame(
    gameid = row$gameid,
    prior_home_mean = home$mean,
    prior_away_mean = away$mean,
    home_attack = home$attack,
    away_attack = away$attack,
    home_opponent_conceded = home$opponent_conceded,
    away_opponent_conceded = away$opponent_conceded,
    home_effective_weight = home$team_effective_weight,
    away_effective_weight = away$team_effective_weight,
    league_mean = home$league_mean,
    stringsAsFactors = FALSE
  )
})
market <- merge(market, do.call(rbind, prior_rows), by = "gameid", sort = FALSE)
market <- market[order(market$game_datetime, market$gameid), , drop = FALSE]

market$market_total_mean <- mapply(
  invert_market_count_mean,
  market$total_line,
  market$p_total_over,
  MoreArgs = list(distribution = "negative_binomial"),
  theta = market$theta_total
)
market$market_home_mean <- mapply(
  invert_market_count_mean,
  market$home_line,
  market$p_home_over,
  MoreArgs = list(distribution = "negative_binomial"),
  theta = market$theta_team
)
market$market_away_mean <- mapply(
  invert_market_count_mean,
  market$away_line,
  market$p_away_over,
  MoreArgs = list(distribution = "negative_binomial"),
  theta = market$theta_team
)

truncate_pmf <- function(mean, theta, support_max = 80L) {
  support <- 0:support_max
  pmf <- stats::dnbinom(support, size = theta, mu = mean)
  pmf[[length(pmf)]] <- pmf[[length(pmf)]] +
    stats::pnbinom(support_max, size = theta, mu = mean, lower.tail = FALSE)
  pmf / sum(pmf)
}

copula_joint_pmf <- function(
  mean_home,
  mean_away,
  theta_home,
  theta_away,
  rho,
  seed,
  draws = 30000L,
  support_max = 80L,
  smoothing = 0.02
) {
  set.seed(seed)
  first <- stats::rnorm(draws)
  second <- rho * first + sqrt(1 - rho^2) * stats::rnorm(draws)
  home <- stats::qnbinom(
    pmin(1 - 1e-10, pmax(1e-10, stats::pnorm(first))),
    size = theta_home,
    mu = mean_home
  )
  away <- stats::qnbinom(
    pmin(1 - 1e-10, pmax(1e-10, stats::pnorm(second))),
    size = theta_away,
    mu = mean_away
  )
  home <- pmin(support_max, as.integer(home))
  away <- pmin(support_max, as.integer(away))
  joint <- matrix(
    tabulate(
      home + (support_max + 1L) * away + 1L,
      nbins = (support_max + 1L)^2
    ),
    nrow = support_max + 1L,
    ncol = support_max + 1L
  )
  joint <- joint / sum(joint)
  independent <- outer(
    truncate_pmf(mean_home, theta_home, support_max),
    truncate_pmf(mean_away, theta_away, support_max)
  )
  joint <- (1 - smoothing) * joint + smoothing * independent
  joint / sum(joint)
}

joint_to_total <- function(joint) {
  support_max <- nrow(joint) - 1L
  total <- numeric(2L * support_max + 1L)
  for (home in 0:support_max) {
    for (away in 0:support_max) {
      total[[home + away + 1L]] <-
        total[[home + away + 1L]] + joint[[home + 1L, away + 1L]]
    }
  }
  total / sum(total)
}

project_market_kl <- function(
  prior_joint,
  home_line,
  away_line,
  total_line,
  target
) {
  support_max <- nrow(prior_joint) - 1L
  home <- rep(0:support_max, times = support_max + 1L)
  away <- rep(0:support_max, each = support_max + 1L)
  indicators <- cbind(
    home > home_line,
    away > away_line,
    home + away > total_line
  ) * 1
  prior <- as.numeric(prior_joint)
  objective <- function(lambda) {
    log_weight <- as.numeric(indicators %*% lambda)
    center <- max(log_weight)
    log(sum(prior * exp(log_weight - center))) + center - sum(lambda * target)
  }
  gradient <- function(lambda) {
    log_weight <- as.numeric(indicators %*% lambda)
    center <- max(log_weight)
    weight <- prior * exp(log_weight - center)
    probability <- weight / sum(weight)
    as.numeric(crossprod(indicators, probability)) - target
  }
  fit <- stats::optim(
    rep(0, 3L),
    objective,
    gradient,
    method = "L-BFGS-B",
    lower = rep(-20, 3L),
    upper = rep(20, 3L),
    control = list(maxit = 500L, factr = 1e5)
  )
  log_weight <- as.numeric(indicators %*% fit$par)
  center <- max(log_weight)
  posterior <- prior * exp(log_weight - center)
  posterior <- posterior / sum(posterior)
  achieved <- as.numeric(crossprod(indicators, posterior))
  list(
    joint = matrix(posterior, nrow = nrow(prior_joint), ncol = ncol(prior_joint)),
    lambda = fit$par,
    target = target,
    achieved = achieved,
    max_constraint_error = max(abs(achieved - target)),
    convergence = fit$convergence
  )
}

pad_pmf <- function(pmf, length_out = 161L) {
  result <- c(as.numeric(pmf), rep(0, max(0, length_out - length(pmf))))
  result <- result[seq_len(length_out)]
  result / sum(result)
}

score_pmf <- function(row, pmf, candidate_id) {
  pmf <- pad_pmf(pmf)
  support <- 0:(length(pmf) - 1L)
  observed <- as.integer(row$total_kills_game)
  probability_over <- sum(pmf[support > row$total_line])
  observed_over <- as.numeric(observed > row$total_line)
  observed_probability <- if (observed <= max(support)) {
    pmf[[observed + 1L]]
  } else {
    1e-300
  }
  data.frame(
    gameid = row$gameid,
    series_id = row$series_id,
    game_datetime = row$game_datetime,
    league_canonical = row$league_canonical,
    sample = row$sample,
    candidate_id = candidate_id,
    predicted_mean = sum(support * pmf),
    observed_total = observed,
    probability_over = probability_over,
    observed_over = observed_over,
    brier = (probability_over - observed_over)^2,
    line_log_loss = -(
      observed_over * log(pmax(probability_over, 1e-15)) +
        (1 - observed_over) * log(pmax(1 - probability_over, 1e-15))
    ),
    count_log_score = -log(pmax(observed_probability, 1e-300)),
    crps = discrete_crps(pmf, observed),
    absolute_error = abs(observed - sum(support * pmf)),
    signed_error = observed - sum(support * pmf),
    stringsAsFactors = FALSE
  )
}

structural_path <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "pinnacle-market-anchored-model",
  "structural-weekly-predictions.rds"
)
structural <- readRDS(structural_path)
structural <- structural[!duplicated(structural$gameid), , drop = FALSE]

score_rows <- list()
diagnostic_rows <- list()
score_index <- 0L
for (index in seq_len(nrow(market))) {
  row <- market[index, , drop = FALSE]
  if (index %% 25L == 0L || index == 1L) {
    message(sprintf("Distribuicoes %d de %d", index, nrow(market)))
  }
  total_pmf <- truncate_pmf(
    row$market_total_mean,
    row$theta_total,
    support_max = 160L
  )
  home_market_pmf <- truncate_pmf(
    row$market_home_mean,
    row$theta_team,
    support_max = 80L
  )
  away_market_pmf <- truncate_pmf(
    row$market_away_mean,
    row$theta_team,
    support_max = 80L
  )
  independent_pmf <- convolve_count_pmfs(home_market_pmf, away_market_pmf)
  market_rho_joint <- copula_joint_pmf(
    row$market_home_mean,
    row$market_away_mean,
    row$theta_team,
    row$theta_team,
    row$rho,
    seed = 20260805L + index
  )
  market_rho_pmf <- joint_to_total(market_rho_joint)
  historical_prior <- copula_joint_pmf(
    row$prior_home_mean,
    row$prior_away_mean,
    row$theta_team,
    row$theta_team,
    row$rho,
    seed = 20261805L + index
  )
  projection <- project_market_kl(
    historical_prior,
    row$home_line,
    row$away_line,
    row$total_line,
    c(row$p_home_over, row$p_away_over, row$p_total_over)
  )
  joint_kl_pmf <- joint_to_total(projection$joint)
  candidates <- list(
    pinnacle_total_nb = total_pmf,
    team_totals_independent = independent_pmf,
    team_totals_historical_rho = market_rho_pmf,
    joint_market_kl = joint_kl_pmf
  )
  structural_row <- structural[structural$gameid == row$gameid, , drop = FALSE]
  if (nrow(structural_row) == 1L) {
    candidates$structural_current <- truncate_pmf(
      structural_row$structural_mean,
      structural_row$structural_theta,
      support_max = 160L
    )
  }
  for (candidate_id in names(candidates)) {
    score_index <- score_index + 1L
    score_rows[[score_index]] <- score_pmf(
      row,
      candidates[[candidate_id]],
      candidate_id
    )
  }
  diagnostic_rows[[index]] <- data.frame(
    gameid = row$gameid,
    parameter_cutoff = row$parameter_cutoff,
    theta_team = row$theta_team,
    theta_total = row$theta_total,
    rho_raw = row$rho_raw,
    rho = row$rho,
    prior_home_mean = row$prior_home_mean,
    prior_away_mean = row$prior_away_mean,
    market_home_mean = row$market_home_mean,
    market_away_mean = row$market_away_mean,
    market_total_mean = row$market_total_mean,
    team_mean_sum = row$market_home_mean + row$market_away_mean,
    kl_lambda_home = projection$lambda[[1L]],
    kl_lambda_away = projection$lambda[[2L]],
    kl_lambda_total = projection$lambda[[3L]],
    kl_max_constraint_error = projection$max_constraint_error,
    kl_convergence = projection$convergence,
    stringsAsFactors = FALSE
  )
}

scores <- do.call(rbind, score_rows)
diagnostics <- do.call(rbind, diagnostic_rows)

summarize_scores <- function(data, group_fields) {
  groups <- split(
    seq_len(nrow(data)),
    interaction(data[group_fields], drop = TRUE, lex.order = TRUE)
  )
  result <- do.call(rbind, lapply(groups, function(indices) {
    rows <- data[indices, , drop = FALSE]
    identifiers <- rows[1L, group_fields, drop = FALSE]
    cbind(
      identifiers,
      data.frame(
        maps = nrow(rows),
        crps = mean(rows$crps),
        count_log_score = mean(rows$count_log_score),
        brier = mean(rows$brier),
        line_log_loss = mean(rows$line_log_loss),
        mae = mean(rows$absolute_error),
        bias = mean(rows$signed_error),
        mean_prediction = mean(rows$predicted_mean),
        mean_observed = mean(rows$observed_total),
        probability_over = mean(rows$probability_over),
        observed_over = mean(rows$observed_over),
        stringsAsFactors = FALSE
      )
    )
  }))
  rownames(result) <- NULL
  result
}

summary_by_sample <- summarize_scores(scores, c("sample", "candidate_id"))
summary_overall <- summarize_scores(scores, c("candidate_id"))
summary_by_league <- summarize_scores(
  scores,
  c("sample", "candidate_id", "league_canonical")
)

paired_bootstrap <- function(data, candidate_id, baseline_id, sample_name) {
  metrics <- c("crps", "count_log_score", "brier", "line_log_loss", "absolute_error")
  sample_rows <- data[data$sample == sample_name, , drop = FALSE]
  candidate <- sample_rows[sample_rows$candidate_id == candidate_id, , drop = FALSE]
  baseline <- sample_rows[sample_rows$candidate_id == baseline_id, , drop = FALSE]
  paired <- merge(
    baseline[c("gameid", "series_id", metrics)],
    candidate[c("gameid", metrics)],
    by = "gameid",
    suffixes = c("_baseline", "_candidate")
  )
  paired$block <- ifelse(
    is.na(paired$series_id) | !nzchar(paired$series_id),
    paired$gameid,
    paired$series_id
  )
  blocks <- split(seq_len(nrow(paired)), paired$block)
  set.seed(20260805L + nchar(candidate_id) + nchar(sample_name))
  do.call(rbind, lapply(metrics, function(metric) {
    difference <- paired[[paste0(metric, "_candidate")]] -
      paired[[paste0(metric, "_baseline")]]
    draws <- replicate(2000L, {
      sampled_blocks <- sample(names(blocks), length(blocks), replace = TRUE)
      indices <- unlist(blocks[sampled_blocks], use.names = FALSE)
      mean(difference[indices])
    })
    data.frame(
      sample = sample_name,
      candidate_id = candidate_id,
      baseline_id = baseline_id,
      metric = metric,
      maps = nrow(paired),
      blocks = length(blocks),
      mean_difference_candidate_minus_baseline = mean(difference),
      lower_95 = unname(stats::quantile(draws, 0.025)),
      upper_95 = unname(stats::quantile(draws, 0.975)),
      probability_candidate_better = mean(draws < 0),
      stringsAsFactors = FALSE
    )
  }))
}

comparison_candidates <- c(
  "team_totals_independent",
  "team_totals_historical_rho",
  "joint_market_kl",
  "structural_current"
)
bootstrap <- do.call(rbind, lapply(unique(scores$sample), function(sample_name) {
  do.call(rbind, lapply(comparison_candidates, function(candidate_id) {
    paired_bootstrap(scores, candidate_id, "pinnacle_total_nb", sample_name)
  }))
}))

coverage <- data.frame(
  eligible_maps = nrow(market),
  adjustment_mar_apr = sum(market$sample == "adjustment_mar_apr"),
  selection_may = sum(market$sample == "selection_may"),
  diagnostic_jun_jul = sum(market$sample == "diagnostic_jun_jul"),
  earliest_game = min(market$game_datetime),
  latest_game = max(market$game_datetime),
  median_worst_team_quote_lag_seconds = stats::median(pmax(
    market$home_lag_seconds,
    market$away_lag_seconds
  )),
  maximum_kl_constraint_error = max(diagnostics$kl_max_constraint_error),
  median_kl_constraint_error = stats::median(diagnostics$kl_max_constraint_error),
  stringsAsFactors = FALSE
)

saveRDS(scores, file.path(output_dir, "map-scores.rds"), version = 3L)
saveRDS(market, file.path(output_dir, "research-dataset.rds"), version = 3L)
utils::write.csv(market, file.path(output_dir, "research-dataset.csv"), row.names = FALSE)
utils::write.csv(parameters, file.path(output_dir, "historical-parameters.csv"), row.names = FALSE)
utils::write.csv(diagnostics, file.path(output_dir, "optimization-diagnostics.csv"), row.names = FALSE)
utils::write.csv(summary_overall, file.path(output_dir, "summary-overall.csv"), row.names = FALSE)
utils::write.csv(summary_by_sample, file.path(output_dir, "summary-by-sample.csv"), row.names = FALSE)
utils::write.csv(summary_by_league, file.path(output_dir, "summary-by-league.csv"), row.names = FALSE)
utils::write.csv(bootstrap, file.path(output_dir, "paired-series-bootstrap.csv"), row.names = FALSE)
utils::write.csv(coverage, file.path(output_dir, "coverage-and-integrity.csv"), row.names = FALSE)

print(coverage, row.names = FALSE)
print(summary_overall, row.names = FALSE)
print(summary_by_sample, row.names = FALSE)
print(bootstrap[
  bootstrap$sample == "diagnostic_jun_jul" & bootstrap$metric == "crps",
  ,
  drop = FALSE
], row.names = FALSE)
