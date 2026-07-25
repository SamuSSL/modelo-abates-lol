.bayesian_team_key <- function(id, name) {
  ifelse(
    !is.na(id) & nzchar(as.character(id)),
    paste0("id:", as.character(id)),
    paste0("name:", tolower(trimws(as.character(name))))
  )
}

.scale_matrix_from_training <- function(train, validation, columns) {
  center <- vapply(
    train[columns],
    mean,
    numeric(1L)
  )
  scale <- vapply(
    train[columns],
    stats::sd,
    numeric(1L)
  )
  scale[!is.finite(scale) | scale <= 0] <- 1
  train_matrix <- sweep(
    sweep(as.matrix(train[columns]), 2L, center, "-"),
    2L,
    scale,
    "/"
  )
  validation_matrix <- sweep(
    sweep(as.matrix(validation[columns]), 2L, center, "-"),
    2L,
    scale,
    "/"
  )
  list(
    train = train_matrix,
    validation = validation_matrix,
    center = center,
    scale = scale
  )
}

#' Build leakage-safe Stan data for a temporal fold
#'
#' @param train Training maps ending before validation.
#' @param validation Future validation maps.
#' @param intensity_features Numeric intensity features.
#' @param duration_features Numeric duration features.
#' @param weights Optional recency weights.
#' @param development_end First forbidden datetime.
#' @param allow_secondary_validation Allow a frozen post-development comparison.
#' @return Stan data and preprocessing metadata.
#' @export
prepare_bayesian_fold_data <- function(
  train,
  validation,
  intensity_features,
  duration_features,
  weights = NULL,
  development_end = "2026-01-01 00:00:00",
  allow_secondary_validation = FALSE
) {
  required <- unique(c(
    "gameid",
    "game_datetime",
    "series_cutoff",
    "league_canonical",
    "blue_team_id",
    "blue_team_name",
    "red_team_id",
    "red_team_name",
    "blue_kills",
    "red_kills",
    "game_length_minutes",
    intensity_features,
    duration_features
  ))
  missing <- setdiff(required, union(names(train), names(validation)))
  if (length(missing) > 0L) {
    stop("Bayesian fold data are missing columns.", call. = FALSE)
  }
  assert_development_period(train, development_end)
  if (!isTRUE(allow_secondary_validation)) {
    assert_development_period(validation, development_end)
  }
  if (
    any(train$series_cutoff >= min(validation$game_datetime)) ||
      any(train$game_datetime >= min(validation$game_datetime))
  ) {
    stop("Bayesian fold training touches validation.", call. = FALSE)
  }
  train <- train[stats::complete.cases(train[required]), , drop = FALSE]
  validation <- validation[
    stats::complete.cases(validation[required]),
    ,
    drop = FALSE
  ]
  if (nrow(train) == 0L || nrow(validation) == 0L) {
    stop("Bayesian fold has no complete rows.", call. = FALSE)
  }
  if (is.null(weights)) {
    weights <- rep(1, nrow(train))
  }
  if (length(weights) != nrow(train)) {
    stop("Bayesian weights do not match training rows.", call. = FALSE)
  }
  leagues <- sort(unique(c(
    as.character(train$league_canonical),
    as.character(validation$league_canonical)
  )))
  blue_keys <- c(
    .bayesian_team_key(train$blue_team_id, train$blue_team_name),
    .bayesian_team_key(
      validation$blue_team_id,
      validation$blue_team_name
    )
  )
  red_keys <- c(
    .bayesian_team_key(train$red_team_id, train$red_team_name),
    .bayesian_team_key(
      validation$red_team_id,
      validation$red_team_name
    )
  )
  teams <- sort(unique(c(blue_keys, red_keys)))
  intensity <- .scale_matrix_from_training(
    train,
    validation,
    intensity_features
  )
  duration <- .scale_matrix_from_training(
    train,
    validation,
    duration_features
  )
  train_blue <- .bayesian_team_key(
    train$blue_team_id,
    train$blue_team_name
  )
  train_red <- .bayesian_team_key(
    train$red_team_id,
    train$red_team_name
  )
  validation_blue <- .bayesian_team_key(
    validation$blue_team_id,
    validation$blue_team_name
  )
  validation_red <- .bayesian_team_key(
    validation$red_team_id,
    validation$red_team_name
  )
  list(
    data = list(
      N = nrow(train),
      M = nrow(validation),
      L = length(leagues),
      T = length(teams),
      K_intensity = length(intensity_features),
      K_duration = length(duration_features),
      blue_kills = as.integer(train$blue_kills),
      red_kills = as.integer(train$red_kills),
      duration = as.numeric(train$game_length_minutes),
      league = match(train$league_canonical, leagues),
      blue_team = match(train_blue, teams),
      red_team = match(train_red, teams),
      X_intensity = intensity$train,
      X_duration = duration$train,
      observation_weight = as.numeric(weights),
      league_pred = match(
        validation$league_canonical,
        leagues
      ),
      blue_team_pred = match(validation_blue, teams),
      red_team_pred = match(validation_red, teams),
      X_intensity_pred = intensity$validation,
      X_duration_pred = duration$validation
    ),
    metadata = list(
      validation = validation,
      leagues = leagues,
      teams = teams,
      intensity_features = intensity_features,
      duration_features = duration_features,
      intensity_center = intensity$center,
      intensity_scale = intensity$scale,
      duration_center = duration$center,
      duration_scale = duration$scale
    )
  )
}

#' Convert posterior predictive counts to map-level scores
#'
#' @param posterior_counts Matrix of draws by validation map.
#' @param validation Validation map table.
#' @param fold Fold definition.
#' @param candidate_id Model identifier.
#' @param pseudocount Small smoothing mass per count.
#' @return Map-level probabilistic metrics.
#' @export
score_bayesian_predictions <- function(
  posterior_counts,
  validation,
  fold,
  candidate_id = "bayesian_hierarchical",
  pseudocount = 0.1
) {
  posterior_counts <- as.matrix(posterior_counts)
  if (ncol(posterior_counts) != nrow(validation)) {
    stop("Posterior predictions do not match validation.", call. = FALSE)
  }
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    counts <- as.integer(posterior_counts[, index])
    support_max <- max(counts, validation$total_kills_game[[index]])
    frequency <- tabulate(counts + 1L, nbins = support_max + 1L)
    pmf <- (frequency + pseudocount) /
      (sum(frequency) + pseudocount * length(frequency))
    prediction <- list(
      mean = sum((seq_along(pmf) - 1L) * pmf),
      pmf = pmf,
      tail_mass = 0
    )
    scored <- .score_count_map(
      validation[index, , drop = FALSE],
      prediction,
      candidate_id = candidate_id,
      distribution = "bayesian_negative_binomial",
      feature_block = "hierarchical_intensity_duration",
      fold = fold,
      training_games = NA_integer_,
      effective_training_games = NA_real_
    )
    scored$pmf <- I(list(pmf))
    scored
  })
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

#' Summarize mandatory MCMC diagnostics
#'
#' @param fit CmdStanMCMC object.
#' @return One-row diagnostic summary.
#' @export
summarize_mcmc_diagnostics <- function(fit) {
  summary <- fit$summary()
  diagnostics <- fit$diagnostic_summary()
  parameters <- summary[
    !grepl("^(y_pred|duration_pred|intensity_pred)\\[",
           summary$variable),
    ,
    drop = FALSE
  ]
  data.frame(
    max_rhat = max(parameters$rhat, na.rm = TRUE),
    min_ess_bulk = min(parameters$ess_bulk, na.rm = TRUE),
    min_ess_tail = min(parameters$ess_tail, na.rm = TRUE),
    divergences = sum(diagnostics$num_divergent),
    max_treedepth_hits = sum(diagnostics$num_max_treedepth),
    minimum_ebfmi = min(diagnostics$ebfmi),
    stringsAsFactors = FALSE
  )
}
