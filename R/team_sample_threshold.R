#' Derive recent and raw team-history coverage
#'
#' @param maps Map feature table.
#' @param metric_name Rolling metric used by the operational model.
#' @return One coverage row per map using the weaker of both teams.
#' @export
derive_team_sample_coverage <- function(
  maps,
  metric_name = "combined_kills_per_minute"
) {
  effective_columns <- paste0(
    c("blue_", "red_"),
    "effective_",
    metric_name,
    "_games"
  )
  raw_columns <- c(
    "blue_raw_team_games",
    "red_raw_team_games"
  )
  required <- c("gameid", effective_columns, raw_columns)
  missing <- setdiff(required, names(maps))
  if (length(missing) > 0L) {
    stop(
      "Missing team coverage columns: ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  if (anyDuplicated(maps$gameid)) {
    stop("Team coverage requires one row per map.", call. = FALSE)
  }
  result <- data.frame(
    gameid = as.character(maps$gameid),
    blue_effective_team_games = as.numeric(
      maps[[effective_columns[[1L]]]]
    ),
    red_effective_team_games = as.numeric(
      maps[[effective_columns[[2L]]]]
    ),
    blue_raw_team_games = as.integer(maps$blue_raw_team_games),
    red_raw_team_games = as.integer(maps$red_raw_team_games),
    stringsAsFactors = FALSE
  )
  result$minimum_effective_team_games <- pmin(
    result$blue_effective_team_games,
    result$red_effective_team_games
  )
  result$minimum_raw_team_games <- pmin(
    result$blue_raw_team_games,
    result$red_raw_team_games
  )
  result
}

.score_sample_group <- function(
  map_metrics,
  game_ids,
  signal_candidate_id,
  reference_candidate_id,
  bootstrap_replicates,
  bootstrap_seed
) {
  subset <- map_metrics[
    map_metrics$gameid %in% game_ids &
      map_metrics$candidate_id %in% c(
        signal_candidate_id,
        reference_candidate_id
      ),
    ,
    drop = FALSE
  ]
  signal <- subset[
    subset$candidate_id == signal_candidate_id,
    ,
    drop = FALSE
  ]
  reference <- subset[
    subset$candidate_id == reference_candidate_id,
    ,
    drop = FALSE
  ]
  paired_ids <- intersect(signal$gameid, reference$gameid)
  signal <- signal[signal$gameid %in% paired_ids, , drop = FALSE]
  if (length(paired_ids) < 2L) {
    return(data.frame(
      maps = length(paired_ids),
      mean_difference = NA_real_,
      ci_lower = NA_real_,
      ci_upper = NA_real_,
      probability_signal_better = NA_real_,
      signal_mean_crps = if (nrow(signal) > 0L) {
        mean(signal$crps)
      } else {
        NA_real_
      },
      signal_mean_log_score = if (nrow(signal) > 0L) {
        mean(signal$log_score)
      } else {
        NA_real_
      },
      signal_coverage_90 = if (nrow(signal) > 0L) {
        mean(
          signal$observed >= signal$lower_90 &
            signal$observed <= signal$upper_90
        )
      } else {
        NA_real_
      },
      stringsAsFactors = FALSE
    ))
  }
  bootstrap <- paired_block_bootstrap_crps(
    subset,
    candidate_id = signal_candidate_id,
    reference_id = reference_candidate_id,
    replicates = bootstrap_replicates,
    seed = bootstrap_seed
  )
  data.frame(
    maps = length(paired_ids),
    mean_difference = bootstrap$mean_difference,
    ci_lower = bootstrap$ci_lower,
    ci_upper = bootstrap$ci_upper,
    probability_signal_better =
      bootstrap$probability_candidate_better,
    signal_mean_crps = mean(signal$crps),
    signal_mean_log_score = mean(signal$log_score),
    signal_coverage_90 = mean(
      signal$observed >= signal$lower_90 &
        signal$observed <= signal$upper_90
    ),
    stringsAsFactors = FALSE
  )
}

.sample_threshold_by_league <- function(
  paired,
  thresholds,
  sample_column
) {
  rows <- list()
  index <- 0L
  for (threshold in thresholds) {
    for (group_name in c("eligible", "blocked")) {
      group_rows <- if (group_name == "eligible") {
        paired[[sample_column]] >= threshold
      } else {
        paired[[sample_column]] < threshold
      }
      group <- paired[group_rows, , drop = FALSE]
      league_groups <- split(
        group,
        as.character(group$league_canonical)
      )
      for (league in names(league_groups)) {
        data <- league_groups[[league]]
        index <- index + 1L
        rows[[index]] <- data.frame(
          threshold = threshold,
          group = group_name,
          league_canonical = league,
          maps = nrow(data),
          mean_crps_difference = mean(
            data$crps_signal - data$crps_reference
          ),
          mean_log_score_difference = mean(
            data$log_score_signal -
              data$log_score_reference
          ),
          stringsAsFactors = FALSE
        )
      }
    }
  }
  if (length(rows) == 0L) {
    return(data.frame())
  }
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

#' Evaluate operational team-history thresholds
#'
#' @param map_metrics Out-of-fold metrics containing signal and reference.
#' @param coverage Output from `derive_team_sample_coverage()`.
#' @param thresholds Candidate minimum sample sizes.
#' @param signal_candidate_id Candidate using team history.
#' @param reference_candidate_id Candidate using league only.
#' @param sample_column Coverage column used for gating.
#' @param bootstrap_replicates Temporal bootstrap replicates.
#' @param bootstrap_seed Reproducibility seed.
#' @return Threshold comparisons, selected threshold, and league diagnostics.
#' @export
evaluate_team_sample_thresholds <- function(
  map_metrics,
  coverage,
  thresholds,
  signal_candidate_id,
  reference_candidate_id,
  sample_column = "minimum_effective_team_games",
  bootstrap_replicates = 2000L,
  bootstrap_seed = 20260723L
) {
  metric_required <- c(
    "gameid",
    "candidate_id",
    "league_canonical",
    "game_datetime",
    "crps",
    "log_score",
    "observed",
    "lower_90",
    "upper_90"
  )
  missing_metrics <- setdiff(metric_required, names(map_metrics))
  missing_coverage <- setdiff(
    c("gameid", sample_column),
    names(coverage)
  )
  if (length(missing_metrics) > 0L || length(missing_coverage) > 0L) {
    stop("Sample evaluation inputs are missing columns.", call. = FALSE)
  }
  if (
    anyDuplicated(coverage$gameid) ||
      any(!is.finite(coverage[[sample_column]]))
  ) {
    stop("Sample coverage must be finite and unique by map.", call. = FALSE)
  }
  candidates <- map_metrics[
    map_metrics$candidate_id %in% c(
      signal_candidate_id,
      reference_candidate_id
    ),
    metric_required,
    drop = FALSE
  ]
  if (
    !all(c(
      signal_candidate_id,
      reference_candidate_id
    ) %in% candidates$candidate_id)
  ) {
    stop("Signal or reference candidate is missing.", call. = FALSE)
  }
  signal <- candidates[
    candidates$candidate_id == signal_candidate_id,
    ,
    drop = FALSE
  ]
  reference <- candidates[
    candidates$candidate_id == reference_candidate_id,
    ,
    drop = FALSE
  ]
  if (anyDuplicated(signal$gameid) || anyDuplicated(reference$gameid)) {
    stop("Candidates require one prediction per map.", call. = FALSE)
  }
  paired <- merge(
    signal,
    reference,
    by = "gameid",
    suffixes = c("_signal", "_reference"),
    sort = FALSE
  )
  paired <- merge(
    paired,
    coverage[c("gameid", sample_column)],
    by = "gameid",
    sort = FALSE
  )
  if (nrow(paired) == 0L) {
    stop("No paired maps have sample coverage.", call. = FALSE)
  }
  paired$league_canonical <- paired$league_canonical_signal

  thresholds <- sort(unique(as.numeric(thresholds)))
  threshold_rows <- lapply(thresholds, function(threshold) {
    eligible_ids <- paired$gameid[
      paired[[sample_column]] >= threshold
    ]
    blocked_ids <- paired$gameid[
      paired[[sample_column]] < threshold
    ]
    eligible <- .score_sample_group(
      candidates,
      eligible_ids,
      signal_candidate_id,
      reference_candidate_id,
      bootstrap_replicates,
      bootstrap_seed
    )
    blocked <- .score_sample_group(
      candidates,
      blocked_ids,
      signal_candidate_id,
      reference_candidate_id,
      bootstrap_replicates,
      bootstrap_seed
    )
    data.frame(
      threshold = threshold,
      retained_share = eligible$maps / nrow(paired),
      eligible_maps = eligible$maps,
      eligible_mean_difference = eligible$mean_difference,
      eligible_ci_lower = eligible$ci_lower,
      eligible_ci_upper = eligible$ci_upper,
      eligible_probability_signal_better =
        eligible$probability_signal_better,
      eligible_signal_mean_crps = eligible$signal_mean_crps,
      eligible_signal_mean_log_score =
        eligible$signal_mean_log_score,
      eligible_signal_coverage_90 = eligible$signal_coverage_90,
      blocked_maps = blocked$maps,
      blocked_mean_difference = blocked$mean_difference,
      blocked_ci_lower = blocked$ci_lower,
      blocked_ci_upper = blocked$ci_upper,
      blocked_probability_signal_better =
        blocked$probability_signal_better,
      blocked_signal_mean_crps = blocked$signal_mean_crps,
      blocked_signal_mean_log_score =
        blocked$signal_mean_log_score,
      blocked_signal_coverage_90 = blocked$signal_coverage_90,
      stringsAsFactors = FALSE
    )
  })
  threshold_results <- do.call(rbind, threshold_rows)
  rownames(threshold_results) <- NULL
  threshold_results$eligible_reliable_gain <-
    is.finite(threshold_results$eligible_ci_upper) &
      threshold_results$eligible_ci_upper < 0
  threshold_results$blocked_reliable_gain <-
    is.finite(threshold_results$blocked_ci_upper) &
      threshold_results$blocked_ci_upper < 0
  threshold_results$qualifies <-
    threshold_results$eligible_reliable_gain &
      !threshold_results$blocked_reliable_gain &
      threshold_results$blocked_maps >= 2L
  qualifying <- threshold_results[
    threshold_results$qualifies,
    ,
    drop = FALSE
  ]
  selected <- if (nrow(qualifying) > 0L) {
    qualifying[which.min(qualifying$threshold), , drop = FALSE]
  } else {
    data.frame()
  }
  list(
    thresholds = threshold_results,
    selected = selected,
    by_league = .sample_threshold_by_league(
      paired,
      thresholds,
      sample_column
    )
  )
}
