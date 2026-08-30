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
  "structural-pinnacle-error-atlas"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

market_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "pinnacle-market-anchored-model"
)
atlas <- readRDS(file.path(market_dir, "research-dataset.rds"))
maps <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "premap_ratio_map_features_t15.rds"
))
moneyline <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "premap_direct_moneyline_map_features.rds"
))
players <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "player_map_metrics.rds"
))
experiment <- utils::read.csv(
  file.path(market_dir, "experiment-summary.csv"),
  stringsAsFactors = FALSE
)
market_theta <- as.numeric(experiment$market_theta[[1L]])

if (anyDuplicated(atlas$gameid)) {
  stop("O dataset de mercado possui gameid duplicado.", call. = FALSE)
}
if (any(atlas$weekly_cutoff >= atlas$game_datetime)) {
  stop("Existe cutoff estrutural posterior ao mapa.", call. = FALSE)
}

feature_fields <- c(
  "gameid", "blue_team_id", "blue_team_name", "red_team_id",
  "red_team_name", "blue_last15_team_games", "red_last15_team_games",
  "blue_last15_attack_ratio", "red_last15_attack_ratio",
  "blue_last15_concession_ratio", "red_last15_concession_ratio",
  "blue_last15_kpm_ratio", "red_last15_kpm_ratio",
  "blue_last15_duration_ratio", "red_last15_duration_ratio",
  "blue_last15_total_kills_sd_ratio", "red_last15_total_kills_sd_ratio"
)
missing_feature_fields <- setdiff(feature_fields, names(maps))
if (length(missing_feature_fields) > 0L) {
  stop(
    paste("Features ausentes:", paste(missing_feature_fields, collapse = ", ")),
    call. = FALSE
  )
}
map_features <- maps[match(atlas$gameid, maps$gameid), feature_fields]
if (any(is.na(map_features$gameid))) {
  stop("Nem todos os mapas do atlas possuem features históricas.", call. = FALSE)
}
atlas <- cbind(atlas, map_features[setdiff(names(map_features), "gameid")])

moneyline_fields <- c(
  "gameid", "favorite_probability", "favorite_band",
  "favorite_imbalance", "odds_timestamp", "prediction_cutoff"
)
moneyline_unique <- moneyline[!duplicated(moneyline$gameid), moneyline_fields]
moneyline_match <- match(atlas$gameid, moneyline_unique$gameid)
atlas$favorite_probability <- moneyline_unique$favorite_probability[
  moneyline_match
]
atlas$favorite_band <- as.character(
  moneyline_unique$favorite_band[moneyline_match]
)
atlas$favorite_imbalance <- moneyline_unique$favorite_imbalance[
  moneyline_match
]
atlas$moneyline_quote_time <- moneyline_unique$odds_timestamp[moneyline_match]
atlas$moneyline_cutoff <- moneyline_unique$prediction_cutoff[moneyline_match]
atlas$favorite_band[is.na(atlas$favorite_band)] <- "moneyline_unavailable"

valid_players <- players[
  players$target_valid &
    !is.na(players$player_id) & nzchar(players$player_id) &
    !is.na(players$team_id) & nzchar(players$team_id),
  ,
  drop = FALSE
]
roster_groups <- split(
  seq_len(nrow(valid_players)),
  paste(valid_players$gameid, valid_players$team_id, sep = "||")
)
roster_rows <- lapply(roster_groups, function(index) {
  rows <- valid_players[index, , drop = FALSE]
  roster <- sort(unique(as.character(rows$player_id)))
  data.frame(
    gameid = as.character(rows$gameid[[1L]]),
    team_id = as.character(rows$team_id[[1L]]),
    game_datetime = as.POSIXct(rows$game_datetime[[1L]], tz = "UTC"),
    roster_size = length(roster),
    roster_signature = paste(roster, collapse = "|"),
    stringsAsFactors = FALSE
  )
})
rosters <- do.call(rbind, roster_rows)
rosters <- rosters[order(rosters$team_id, rosters$game_datetime), ]
rosters$previous_roster_overlap <- NA_integer_
team_roster_indices <- split(seq_len(nrow(rosters)), rosters$team_id)
for (indices in team_roster_indices) {
  if (length(indices) < 2L) {
    next
  }
  for (position in 2:length(indices)) {
    current <- indices[[position]]
    previous <- indices[[position - 1L]]
    current_players <- strsplit(
      rosters$roster_signature[[current]], "\\|", fixed = FALSE
    )[[1L]]
    previous_players <- strsplit(
      rosters$roster_signature[[previous]], "\\|", fixed = FALSE
    )[[1L]]
    if (
      rosters$roster_size[[current]] == 5L &&
        rosters$roster_size[[previous]] == 5L
    ) {
      rosters$previous_roster_overlap[[current]] <- length(intersect(
        current_players,
        previous_players
      ))
    }
  }
}

roster_key <- paste(rosters$gameid, rosters$team_id, sep = "||")
blue_roster_match <- match(
  paste(atlas$gameid, atlas$blue_team_id, sep = "||"),
  roster_key
)
red_roster_match <- match(
  paste(atlas$gameid, atlas$red_team_id, sep = "||"),
  roster_key
)
atlas$blue_roster_overlap <- rosters$previous_roster_overlap[
  blue_roster_match
]
atlas$red_roster_overlap <- rosters$previous_roster_overlap[
  red_roster_match
]
atlas$blue_roster_size <- rosters$roster_size[blue_roster_match]
atlas$red_roster_size <- rosters$roster_size[red_roster_match]
atlas$minimum_roster_overlap <- pmin(
  atlas$blue_roster_overlap,
  atlas$red_roster_overlap,
  na.rm = FALSE
)
atlas$roster_stability_band <- ifelse(
  is.na(atlas$minimum_roster_overlap),
  "unknown",
  ifelse(
    atlas$minimum_roster_overlap >= 5L,
    "both_unchanged",
    ifelse(atlas$minimum_roster_overlap == 4L, "one_change", "multiple_changes")
  )
)

blue_aggressive <- atlas$blue_last15_kpm_ratio >= 1
red_aggressive <- atlas$red_last15_kpm_ratio >= 1
atlas$matchup_type <- ifelse(
  is.na(blue_aggressive) | is.na(red_aggressive),
  "unknown",
  ifelse(
    blue_aggressive & red_aggressive,
    "both_aggressive",
    ifelse(!blue_aggressive & !red_aggressive, "both_controlled", "mixed")
  )
)
atlas$attack_concession_heat <- 0.5 * (
  atlas$blue_last15_attack_ratio * atlas$red_last15_concession_ratio +
    atlas$red_last15_attack_ratio * atlas$blue_last15_concession_ratio
)
atlas$historical_volatility <- 0.5 * (
  atlas$blue_last15_total_kills_sd_ratio +
    atlas$red_last15_total_kills_sd_ratio
)
atlas$minimum_history_games <- pmin(
  atlas$blue_last15_team_games,
  atlas$red_last15_team_games,
  na.rm = FALSE
)
atlas$sample_stability_band <- ifelse(
  is.na(atlas$minimum_history_games),
  "unknown",
  ifelse(
    atlas$minimum_history_games < 5,
    "under_5",
    ifelse(atlas$minimum_history_games < 10, "5_to_9", "10_plus")
  )
)

adjustment <- atlas$sample == "adjustment_mar_apr"
quantile_from_adjustment <- function(values, probabilities) {
  stats::quantile(
    values[adjustment & is.finite(values)],
    probabilities,
    na.rm = TRUE,
    names = FALSE,
    type = 8
  )
}
heat_cuts <- quantile_from_adjustment(atlas$attack_concession_heat, c(1 / 3, 2 / 3))
volatility_cut <- quantile_from_adjustment(atlas$historical_volatility, 0.75)
divergence_cuts <- quantile_from_adjustment(
  atlas$absolute_structural_disagreement,
  c(0.5, 0.75, 0.9)
)
segmentation_thresholds <- data.frame(
  threshold = c(
    "attack_concession_tertile_1", "attack_concession_tertile_2",
    "historical_volatility_q75", "absolute_divergence_q50",
    "absolute_divergence_q75", "absolute_divergence_q90"
  ),
  value = c(heat_cuts, volatility_cut, divergence_cuts),
  fitted_on = "adjustment_mar_apr",
  stringsAsFactors = FALSE
)
atlas$attack_concession_band <- cut(
  atlas$attack_concession_heat,
  breaks = c(-Inf, heat_cuts, Inf),
  labels = c("low", "medium", "high"),
  right = FALSE
)
atlas$volatility_band <- ifelse(
  is.na(atlas$historical_volatility),
  "unknown",
  ifelse(atlas$historical_volatility >= volatility_cut, "high", "normal")
)
atlas$divergence_magnitude_band <- cut(
  atlas$absolute_structural_disagreement,
  breaks = c(-Inf, divergence_cuts, Inf),
  labels = c("low", "medium", "high", "extreme"),
  right = FALSE
)
atlas$divergence_direction <- ifelse(
  atlas$structural_disagreement >= 0,
  "structural_above_market",
  "structural_below_market"
)

score_distribution <- function(observed, line, mean, theta) {
  support <- 0:150
  probability_over <- stats::pnbinom(
    floor(line),
    size = theta,
    mu = mean,
    lower.tail = FALSE
  )
  observed_over <- as.numeric(observed > line)
  crps <- vapply(seq_along(observed), function(index) {
    cumulative <- stats::pnbinom(
      support,
      size = theta[[index]],
      mu = mean[[index]]
    )
    sum((cumulative - as.numeric(support >= observed[[index]]))^2)
  }, numeric(1L))
  data.frame(
    predicted_mean = mean,
    signed_error = observed - mean,
    absolute_error = abs(observed - mean),
    crps = crps,
    count_log_score = -stats::dnbinom(
      observed,
      size = theta,
      mu = mean,
      log = TRUE
    ),
    brier = (probability_over - observed_over)^2,
    probability_over = probability_over,
    observed_over = observed_over,
    stringsAsFactors = FALSE
  )
}

structural_scores <- score_distribution(
  atlas$observed_total,
  atlas$live_line,
  pmax(0.1, atlas$structural_mean),
  pmax(0.1, atlas$structural_theta)
)
market_scores <- score_distribution(
  atlas$observed_total,
  atlas$live_line,
  pmax(0.1, atlas$market_mean),
  rep(market_theta, nrow(atlas))
)
for (metric in names(structural_scores)) {
  atlas[[paste0("structural_", metric)]] <- structural_scores[[metric]]
  atlas[[paste0("market_", metric)]] <- market_scores[[metric]]
}
for (metric in c("crps", "count_log_score", "absolute_error", "brier")) {
  atlas[[paste0("delta_", metric)]] <-
    atlas[[paste0("structural_", metric)]] -
    atlas[[paste0("market_", metric)]]
}
atlas$market_residual <- atlas$observed_total - atlas$market_mean
atlas$structural_adjustment_helped <- atlas$delta_crps < 0
atlas$structural_direction_correct <- with(
  atlas,
  structural_disagreement * market_residual > 0
)

structural_error_cut <- quantile_from_adjustment(
  atlas$structural_absolute_error,
  0.9
)
market_error_cut <- quantile_from_adjustment(atlas$market_absolute_error, 0.9)
atlas$error_regime <- ifelse(
  atlas$structural_absolute_error >= structural_error_cut &
    atlas$market_absolute_error >= market_error_cut,
  "both_large_error",
  ifelse(
    atlas$structural_absolute_error >= structural_error_cut,
    "structural_only_large_error",
    ifelse(
      atlas$market_absolute_error >= market_error_cut,
      "market_only_large_error",
      "neither_large_error"
    )
  )
)

atlas$league_x_divergence <- paste(
  atlas$league_canonical,
  atlas$divergence_magnitude_band,
  sep = "__"
)
atlas$favorite_x_divergence <- paste(
  atlas$favorite_band,
  atlas$divergence_magnitude_band,
  sep = "__"
)
atlas$roster_x_divergence <- paste(
  atlas$roster_stability_band,
  atlas$divergence_magnitude_band,
  sep = "__"
)
atlas$matchup_x_divergence <- paste(
  atlas$matchup_type,
  atlas$divergence_magnitude_band,
  sep = "__"
)

segment_variables <- c(
  "league_canonical", "favorite_band", "roster_stability_band",
  "matchup_type", "attack_concession_band", "sample_stability_band",
  "volatility_band", "divergence_magnitude_band",
  "divergence_direction", "error_regime", "map_group"
)
segment_variables <- c(
  segment_variables,
  "league_x_divergence", "favorite_x_divergence",
  "roster_x_divergence", "matchup_x_divergence"
)
atlas$overall <- "all_maps"
segment_variables <- c("overall", segment_variables)

summarize_segment <- function(data, variable, level) {
  rows <- data[as.character(data[[variable]]) == level, , drop = FALSE]
  period_counts <- table(as.character(rows$sample))
  data.frame(
    segment_variable = variable,
    segment_level = level,
    maps = nrow(rows),
    series = length(unique(rows$series_id)),
    adjustment_maps = unname(period_counts["adjustment_mar_apr"] %||% 0L),
    selection_maps = unname(period_counts["selection_may"] %||% 0L),
    confirmation_maps = unname(period_counts["confirmation_jun_jul"] %||% 0L),
    structural_mean_error = mean(rows$structural_signed_error),
    market_mean_error = mean(rows$market_signed_error),
    structural_crps = mean(rows$structural_crps),
    market_crps = mean(rows$market_crps),
    delta_crps = mean(rows$delta_crps),
    delta_count_log_score = mean(rows$delta_count_log_score),
    delta_absolute_error = mean(rows$delta_absolute_error),
    delta_brier = mean(rows$delta_brier),
    mean_absolute_disagreement = mean(rows$absolute_structural_disagreement),
    structural_help_rate = mean(rows$structural_adjustment_helped),
    structural_direction_accuracy = mean(rows$structural_direction_correct),
    stringsAsFactors = FALSE
  )
}

`%||%` <- function(value, fallback) {
  if (length(value) == 0L || is.na(value)) fallback else value
}
segment_summary_rows <- list()
for (variable in segment_variables) {
  levels <- sort(unique(as.character(atlas[[variable]])))
  levels <- levels[!is.na(levels)]
  for (level in levels) {
    key <- paste(variable, level, sep = "||")
    segment_summary_rows[[key]] <- summarize_segment(atlas, variable, level)
  }
}
segment_summary <- do.call(rbind, segment_summary_rows)
rownames(segment_summary) <- NULL

temporal_rows <- list()
for (variable in segment_variables) {
  levels <- sort(unique(as.character(atlas[[variable]])))
  levels <- levels[!is.na(levels)]
  for (level in levels) {
    for (sample_name in sort(unique(as.character(atlas$sample)))) {
      rows <- atlas[
        as.character(atlas[[variable]]) == level & atlas$sample == sample_name,
        ,
        drop = FALSE
      ]
      temporal_rows[[paste(variable, level, sample_name, sep = "||")]] <-
        data.frame(
          segment_variable = variable,
          segment_level = level,
          sample = sample_name,
          maps = nrow(rows),
          delta_crps = if (nrow(rows) > 0L) mean(rows$delta_crps) else NA_real_,
          delta_count_log_score = if (nrow(rows) > 0L) {
            mean(rows$delta_count_log_score)
          } else {
            NA_real_
          },
          delta_absolute_error = if (nrow(rows) > 0L) {
            mean(rows$delta_absolute_error)
          } else {
            NA_real_
          },
          stringsAsFactors = FALSE
        )
    }
  }
}
temporal_summary <- do.call(rbind, temporal_rows)
rownames(temporal_summary) <- NULL

bootstrap_segment <- function(data, variable, level, draws = 2000L) {
  rows <- data[as.character(data[[variable]]) == level, , drop = FALSE]
  blocks <- split(seq_len(nrow(rows)), rows$series_id)
  set.seed(20260805 + nchar(variable) * 17L + nchar(level))
  boot <- replicate(draws, {
    sampled <- sample(names(blocks), length(blocks), replace = TRUE)
    indices <- unlist(blocks[sampled], use.names = FALSE)
    c(
      crps = mean(rows$delta_crps[indices]),
      log_score = mean(rows$delta_count_log_score[indices]),
      absolute_error = mean(rows$delta_absolute_error[indices])
    )
  })
  crps_draws <- boot["crps", ]
  probability_better <- mean(crps_draws < 0)
  data.frame(
    segment_variable = variable,
    segment_level = level,
    maps = nrow(rows),
    series = length(blocks),
    delta_crps = mean(rows$delta_crps),
    lower_95_crps = unname(stats::quantile(crps_draws, 0.025)),
    upper_95_crps = unname(stats::quantile(crps_draws, 0.975)),
    probability_structural_better_crps = probability_better,
    exploratory_two_sided_p = 2 * min(probability_better, 1 - probability_better),
    delta_count_log_score = mean(rows$delta_count_log_score),
    lower_95_log_score = unname(stats::quantile(boot["log_score", ], 0.025)),
    upper_95_log_score = unname(stats::quantile(boot["log_score", ], 0.975)),
    delta_absolute_error = mean(rows$delta_absolute_error),
    stringsAsFactors = FALSE
  )
}

bootstrap_rows <- list()
for (index in seq_len(nrow(segment_summary))) {
  row <- segment_summary[index, ]
  if (row$maps < 20L || row$series < 10L) {
    next
  }
  key <- paste(row$segment_variable, row$segment_level, sep = "||")
  bootstrap_rows[[key]] <- bootstrap_segment(
    atlas,
    row$segment_variable,
    row$segment_level
  )
}
bootstrap_summary <- do.call(rbind, bootstrap_rows)
rownames(bootstrap_summary) <- NULL
bootstrap_summary$exploratory_bh_q <- stats::p.adjust(
  bootstrap_summary$exploratory_two_sided_p,
  method = "BH"
)

period_support <- stats::aggregate(
  maps ~ segment_variable + segment_level,
  temporal_summary,
  function(values) sum(values >= 15L)
)
names(period_support)[names(period_support) == "maps"] <- "periods_with_15_maps"
priority <- merge(
  bootstrap_summary,
  period_support,
  by = c("segment_variable", "segment_level"),
  all.x = TRUE
)
priority$research_priority <- with(
  priority,
  maps >= 50L & periods_with_15_maps >= 2L & delta_crps < 0 &
    delta_count_log_score < 0 & probability_structural_better_crps > 0.9
)
priority$pre_event_segment <- !priority$segment_variable %in% c(
  "overall", "error_regime"
)
priority$research_priority <- priority$research_priority &
  priority$pre_event_segment
priority <- priority[order(
  !priority$research_priority,
  priority$delta_crps,
  priority$exploratory_bh_q
), ]

coverage <- data.frame(
  metric = c(
    "atlas_maps", "atlas_series", "moneyline_maps", "roster_overlap_maps",
    "complete_matchup_maps", "post_cutoff_moneylines", "duplicate_gameids",
    "invalid_roster_rows", "atlas_invalid_roster_maps"
  ),
  value = c(
    nrow(atlas),
    length(unique(atlas$series_id)),
    sum(atlas$favorite_band != "moneyline_unavailable"),
    sum(!is.na(atlas$minimum_roster_overlap)),
    sum(atlas$matchup_type != "unknown"),
    sum(
      !is.na(atlas$moneyline_quote_time) &
        atlas$moneyline_quote_time > atlas$moneyline_cutoff
    ),
    anyDuplicated(atlas$gameid),
    sum(rosters$roster_size != 5L),
    sum(atlas$blue_roster_size != 5L | atlas$red_roster_size != 5L)
  ),
  stringsAsFactors = FALSE
)

structural_worst <- atlas[order(-atlas$delta_crps), ]
structural_worst <- utils::head(structural_worst, 50L)
structural_best <- atlas[order(atlas$delta_crps), ]
structural_best <- utils::head(structural_best, 50L)

utils::write.csv(
  atlas,
  file.path(output_dir, "map-error-atlas.csv"),
  row.names = FALSE
)
saveRDS(atlas, file.path(output_dir, "map-error-atlas.rds"), version = 3L)
utils::write.csv(
  coverage,
  file.path(output_dir, "coverage-and-integrity.csv"),
  row.names = FALSE
)
utils::write.csv(
  segmentation_thresholds,
  file.path(output_dir, "segmentation-thresholds.csv"),
  row.names = FALSE
)
utils::write.csv(
  segment_summary,
  file.path(output_dir, "segment-summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  temporal_summary,
  file.path(output_dir, "segment-temporal-stability.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap_summary,
  file.path(output_dir, "segment-bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  priority,
  file.path(output_dir, "research-priority-segments.csv"),
  row.names = FALSE
)
utils::write.csv(
  priority[priority$pre_event_segment, , drop = FALSE],
  file.path(output_dir, "pre-event-segment-evidence.csv"),
  row.names = FALSE
)
utils::write.csv(
  structural_worst,
  file.path(output_dir, "largest-structural-losses.csv"),
  row.names = FALSE
)
utils::write.csv(
  structural_best,
  file.path(output_dir, "largest-structural-wins.csv"),
  row.names = FALSE
)

print(coverage, row.names = FALSE)
print(
  priority[priority$segment_variable != "overall", c(
    "segment_variable", "segment_level", "maps", "delta_crps",
    "delta_count_log_score", "probability_structural_better_crps",
    "exploratory_bh_q", "periods_with_15_maps", "research_priority"
  )],
  row.names = FALSE
)
