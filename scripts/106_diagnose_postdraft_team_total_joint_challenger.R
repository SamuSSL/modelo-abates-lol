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
market <- readRDS(file.path(output_dir, "research-dataset.rds"))
scores <- readRDS(file.path(output_dir, "map-scores.rds"))

score_team_pmf <- function(
  gameid,
  sample,
  side,
  candidate_id,
  observed,
  mean,
  theta
) {
  prediction <- make_count_pmf(
    pmax(0.1, mean),
    "negative_binomial",
    theta,
    tail_tolerance = 1e-10
  )
  probability <- if (observed <= prediction$support_max) {
    prediction$pmf[[observed + 1L]]
  } else {
    stats::dnbinom(observed, size = theta, mu = mean)
  }
  data.frame(
    gameid = gameid,
    sample = sample,
    side = side,
    candidate_id = candidate_id,
    observed = observed,
    predicted_mean = mean,
    crps = discrete_crps(prediction$pmf, observed),
    count_log_score = -log(pmax(probability, 1e-300)),
    absolute_error = abs(observed - mean),
    signed_error = observed - mean,
    stringsAsFactors = FALSE
  )
}

team_scores <- list()
score_index <- 0L
for (index in seq_len(nrow(market))) {
  row <- market[index, , drop = FALSE]
  specifications <- list(
    list(side = "home", observed = row$home_kills,
         market_mean = row$market_home_mean, prior_mean = row$prior_home_mean),
    list(side = "away", observed = row$away_kills,
         market_mean = row$market_away_mean, prior_mean = row$prior_away_mean)
  )
  for (specification in specifications) {
    for (candidate_id in c("team_market_nb", "historical_team_prior_nb")) {
      score_index <- score_index + 1L
      prediction_mean <- if (candidate_id == "team_market_nb") {
        specification$market_mean
      } else {
        specification$prior_mean
      }
      team_scores[[score_index]] <- score_team_pmf(
        row$gameid,
        row$sample,
        specification$side,
        candidate_id,
        as.integer(specification$observed),
        prediction_mean,
        row$theta_team
      )
    }
  }
}
team_scores <- do.call(rbind, team_scores)

summarize_team <- function(data, fields) {
  groups <- split(
    seq_len(nrow(data)),
    interaction(data[fields], drop = TRUE, lex.order = TRUE)
  )
  result <- do.call(rbind, lapply(groups, function(indices) {
    rows <- data[indices, , drop = FALSE]
    cbind(
      rows[1L, fields, drop = FALSE],
      data.frame(
        observations = nrow(rows),
        crps = mean(rows$crps),
        count_log_score = mean(rows$count_log_score),
        mae = mean(rows$absolute_error),
        bias = mean(rows$signed_error),
        mean_prediction = mean(rows$predicted_mean),
        mean_observed = mean(rows$observed),
        stringsAsFactors = FALSE
      )
    )
  }))
  rownames(result) <- NULL
  result
}

team_summary <- summarize_team(team_scores, c("sample", "candidate_id"))
team_summary_by_side <- summarize_team(
  team_scores,
  c("sample", "candidate_id", "side")
)

baseline <- scores[
  scores$candidate_id == "pinnacle_total_nb",
  c("gameid", "crps", "count_log_score", "absolute_error")
]
challenger <- scores[
  scores$candidate_id == "joint_market_kl",
  c("gameid", "crps", "count_log_score", "absolute_error")
]
paired <- merge(
  baseline,
  challenger,
  by = "gameid",
  suffixes = c("_baseline", "_challenger")
)
paired <- merge(
  paired,
  market[c(
    "gameid", "sample", "league_canonical", "home_lag_seconds",
    "away_lag_seconds", "market_total_mean", "market_home_mean",
    "market_away_mean"
  )],
  by = "gameid"
)
paired$crps_difference <- paired$crps_challenger - paired$crps_baseline
paired$log_score_difference <-
  paired$count_log_score_challenger - paired$count_log_score_baseline
paired$mae_difference <-
  paired$absolute_error_challenger - paired$absolute_error_baseline
paired$worst_team_quote_lag_seconds <- pmax(
  paired$home_lag_seconds,
  paired$away_lag_seconds
)
paired$freshness_band <- ifelse(
  paired$worst_team_quote_lag_seconds <= 0,
  "both_at_or_before_live",
  "one_or_both_within_60s_after_live"
)
paired$market_mean_disagreement <- abs(
  paired$market_home_mean + paired$market_away_mean - paired$market_total_mean
)
development_disagreement_cut <- stats::median(
  paired$market_mean_disagreement[paired$sample == "adjustment_mar_apr"]
)
paired$market_consistency_band <- ifelse(
  paired$market_mean_disagreement <= development_disagreement_cut,
  "lower_disagreement",
  "higher_disagreement"
)
paired$sample_freshness <- paste(
  paired$sample,
  paired$freshness_band,
  sep = "__"
)

summarize_robustness <- function(data, variable) {
  groups <- split(data, as.character(data[[variable]]))
  do.call(rbind, lapply(names(groups), function(group_name) {
    rows <- groups[[group_name]]
    data.frame(
      variable = variable,
      value = group_name,
      maps = nrow(rows),
      mean_crps_difference = mean(rows$crps_difference),
      mean_log_score_difference = mean(rows$log_score_difference),
      mean_mae_difference = mean(rows$mae_difference),
      stringsAsFactors = FALSE
    )
  }))
}

robustness <- do.call(rbind, lapply(
  c(
    "sample", "league_canonical", "freshness_band",
    "market_consistency_band", "sample_freshness"
  ),
  function(variable) summarize_robustness(paired, variable)
))

canonical <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "canonical_games.rds"
))
canonical <- canonical[c("gameid", "game_datetime", "game_length_seconds")]
canonical <- canonical[!duplicated(canonical$gameid), , drop = FALSE]
temporal_audit <- merge(
  market[c(
    "gameid", "sample", "live_open_time", "total_quote_time",
    "home_quote_time", "away_quote_time"
  )],
  canonical,
  by = "gameid"
)
temporal_audit$split <- c(
  adjustment_mar_apr = "train",
  selection_may = "validation",
  diagnostic_jun_jul = "test"
)[temporal_audit$sample]
temporal_audit$feature_available_time <- do.call(
  pmax,
  c(
    temporal_audit[c("total_quote_time", "home_quote_time", "away_quote_time")],
    list(na.rm = TRUE)
  )
)
temporal_audit$prediction_time <- temporal_audit$feature_available_time
temporal_audit$target_time <- as.POSIXct(
  temporal_audit$game_datetime,
  tz = "UTC"
) + as.numeric(temporal_audit$game_length_seconds)
format_iso <- function(value) format(
  as.POSIXct(value, tz = "UTC"),
  "%Y-%m-%dT%H:%M:%SZ",
  tz = "UTC"
)
temporal_audit$prediction_time <- format_iso(temporal_audit$prediction_time)
temporal_audit$feature_available_time <- format_iso(
  temporal_audit$feature_available_time
)
temporal_audit$target_time <- format_iso(temporal_audit$target_time)
temporal_audit <- temporal_audit[c(
  "gameid", "split", "prediction_time", "feature_available_time",
  "target_time"
)]

utils::write.csv(
  team_scores,
  file.path(output_dir, "team-marginal-scores.csv"),
  row.names = FALSE
)
utils::write.csv(
  team_summary,
  file.path(output_dir, "team-marginal-summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  team_summary_by_side,
  file.path(output_dir, "team-marginal-summary-by-side.csv"),
  row.names = FALSE
)
utils::write.csv(
  robustness,
  file.path(output_dir, "robustness-summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  temporal_audit,
  file.path(output_dir, "temporal-audit.csv"),
  row.names = FALSE
)

print(team_summary, row.names = FALSE)
print(robustness, row.names = FALSE)
