script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
artifact_dir <- file.path(
  project_root,
  "artifacts",
  "bettingiscool_team_totals",
  "implied_expectations"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

canonical <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "canonical_games.rds"
))
dispersion <- estimate_historical_team_kill_dispersion(
  canonical,
  cutoff = as.POSIXct("2025-05-01 00:00:00", tz = "UTC")
)
dispersion_summary <- data.frame(
  global_theta = dispersion$global_theta,
  training_maps = dispersion$training_maps,
  training_team_maps = dispersion$training_team_maps,
  training_start = dispersion$training_start,
  training_end = dispersion$training_end,
  market_history_cutoff = dispersion$cutoff,
  estimation_method = dispersion$estimation_method,
  stringsAsFactors = FALSE
)
utils::write.csv(
  dispersion_summary,
  file.path(artifact_dir, "dispersion_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  dispersion$by_league,
  file.path(artifact_dir, "dispersion_by_league.csv"),
  row.names = FALSE
)

scored_path <- file.path(
  project_root,
  "artifacts",
  "bettingiscool_team_totals",
  "team_totals_scored_rows.rds"
)
market_rows <- readRDS(scored_path)
canonical_identity <- canonical[c(
  "gameid",
  "game_datetime",
  "series_id"
)]
canonical_identity <- canonical_identity[
  !duplicated(canonical_identity$gameid),
  ,
  drop = FALSE
]

theta_for_rows <- function(data) {
  match_index <- match(
    as.character(data$league_canonical),
    dispersion$by_league$league_canonical
  )
  theta <- dispersion$by_league$theta[match_index]
  theta[!is.finite(theta)] <- dispersion$global_theta
  theta
}

scored_candidates <- list()
candidate_index <- 0L
for (snapshot_name in names(market_rows)) {
  data <- merge(
    market_rows[[snapshot_name]],
    canonical_identity,
    by = "gameid",
    all.x = TRUE
  )
  specifications <- list(
    list(
      candidate_id = "poisson_inversion",
      distribution = "poisson",
      theta = NA_real_
    ),
    list(
      candidate_id = "negative_binomial_global",
      distribution = "negative_binomial",
      theta = dispersion$global_theta,
      mean_distribution = "negative_binomial"
    ),
    list(
      candidate_id = "negative_binomial_by_league",
      distribution = "negative_binomial",
      theta = theta_for_rows(data),
      mean_distribution = "negative_binomial"
    ),
    list(
      candidate_id = "negative_binomial_poisson_center",
      distribution = "negative_binomial",
      theta = dispersion$global_theta,
      mean_distribution = "poisson"
    )
  )
  specifications[[1L]]$mean_distribution <- "poisson"
  for (specification in specifications) {
    candidate_index <- candidate_index + 1L
    scored <- score_market_implied_team_kills(
      data,
      specification$distribution,
      specification$theta,
      specification$mean_distribution
    )
    scored$candidate_id <- specification$candidate_id
    scored$snapshot <- snapshot_name
    scored$line_probability_difference <- abs(
      .market_count_probability(
        scored$implied_mean,
        scored$line,
        specification$distribution,
        scored$implied_theta
      ) - scored$p_over
    )
    scored_candidates[[candidate_index]] <- scored
  }
}
team_metrics <- as.data.frame(
  data.table::rbindlist(scored_candidates, fill = TRUE)
)
rownames(team_metrics) <- NULL

summarize_team_metrics <- function(data, groups) {
  indices <- split(
    seq_len(nrow(data)),
    interaction(data[groups], drop = TRUE, lex.order = TRUE)
  )
  rows <- lapply(indices, function(index) {
    values <- data[index, , drop = FALSE]
    identifiers <- values[1L, groups, drop = FALSE]
    cbind(
      identifiers,
      data.frame(
        observations = nrow(values),
        mean_implied_kills = mean(values$implied_mean),
        mean_observed_kills = mean(values$team_kills),
        mae = mean(values$absolute_error),
        rmse = sqrt(mean(values$squared_error)),
        bias = mean(values$signed_error),
        correlation = stats::cor(
          values$team_kills,
          values$implied_mean
        ),
        crps = mean(values$crps),
        log_score = mean(values$log_score),
        coverage_50 = mean(
          values$team_kills >= values$lower_50 &
            values$team_kills <= values$upper_50
        ),
        coverage_80 = mean(
          values$team_kills >= values$lower_80 &
            values$team_kills <= values$upper_80
        ),
        coverage_90 = mean(
          values$team_kills >= values$lower_90 &
            values$team_kills <= values$upper_90
        ),
        maximum_line_probability_difference = max(
          values$line_probability_difference
        ),
        stringsAsFactors = FALSE
      )
    )
  })
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}

team_summary <- summarize_team_metrics(
  team_metrics,
  c("snapshot", "candidate_id")
)
team_by_league <- summarize_team_metrics(
  team_metrics,
  c("snapshot", "candidate_id", "league_canonical")
)
utils::write.csv(
  team_summary,
  file.path(artifact_dir, "team_distribution_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  team_by_league,
  file.path(artifact_dir, "team_distribution_by_league.csv"),
  row.names = FALSE
)

map_groups <- split(
  seq_len(nrow(team_metrics)),
  interaction(
    team_metrics$snapshot,
    team_metrics$candidate_id,
    team_metrics$gameid,
    drop = TRUE,
    lex.order = TRUE
  )
)
map_rows <- lapply(map_groups, function(index) {
  rows <- team_metrics[index, , drop = FALSE]
  if (
    nrow(rows) != 2L ||
      length(unique(rows$market)) != 2L
  ) {
    return(NULL)
  }
  data.frame(
    snapshot = rows$snapshot[[1L]],
    candidate_id = rows$candidate_id[[1L]],
    gameid = rows$gameid[[1L]],
    game_datetime = rows$game_datetime[[1L]],
    series_id = rows$series_id[[1L]],
    league_canonical = rows$league_canonical[[1L]],
    implied_total_mean = sum(rows$implied_mean),
    observed_total = sum(rows$team_kills),
    stringsAsFactors = FALSE
  )
})
map_rows <- map_rows[!vapply(map_rows, is.null, logical(1L))]
map_metrics <- do.call(rbind, map_rows)
rownames(map_metrics) <- NULL

summarize_map_metrics <- function(data) {
  groups <- split(
    seq_len(nrow(data)),
    interaction(data$snapshot, data$candidate_id, drop = TRUE)
  )
  rows <- lapply(groups, function(index) {
    values <- data[index, , drop = FALSE]
    error <- values$observed_total - values$implied_total_mean
    data.frame(
      snapshot = values$snapshot[[1L]],
      candidate_id = values$candidate_id[[1L]],
      maps = nrow(values),
      mean_implied_total = mean(values$implied_total_mean),
      mean_observed_total = mean(values$observed_total),
      mae = mean(abs(error)),
      rmse = sqrt(mean(error^2)),
      bias = mean(error),
      correlation = stats::cor(
        values$observed_total,
        values$implied_total_mean
      ),
      stringsAsFactors = FALSE
    )
  })
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result
}
map_summary <- summarize_map_metrics(map_metrics)
utils::write.csv(
  map_summary,
  file.path(artifact_dir, "map_expectation_summary.csv"),
  row.names = FALSE
)

set.seed(20260730L)
comparison_candidates <- c(
  "negative_binomial_global",
  "negative_binomial_by_league",
  "negative_binomial_poisson_center"
)
bootstrap_rows <- lapply(comparison_candidates, function(candidate_id) {
  paired <- merge(
    team_metrics[
      team_metrics$candidate_id == "poisson_inversion",
      c(
        "snapshot",
        "gameid",
        "market",
        "series_id",
        "crps",
        "log_score"
      )
    ],
    team_metrics[
      team_metrics$candidate_id == candidate_id,
      c(
        "snapshot",
        "gameid",
        "market",
        "series_id",
        "crps",
        "log_score"
      )
    ],
    by = c("snapshot", "gameid", "market", "series_id"),
    suffixes = c("_poisson", "_candidate")
  )
  do.call(rbind, lapply(unique(paired$snapshot), function(snapshot_name) {
    data <- paired[paired$snapshot == snapshot_name, , drop = FALSE]
    series <- unique(data$series_id)
    replicates <- replicate(2000L, {
      sampled <- sample(series, length(series), replace = TRUE)
      index <- unlist(lapply(sampled, function(series_id) {
        which(data$series_id == series_id)
      }), use.names = FALSE)
      c(
        crps = mean(
          data$crps_candidate[index] -
            data$crps_poisson[index]
        ),
        log_score = mean(
          data$log_score_candidate[index] -
            data$log_score_poisson[index]
        )
      )
    })
    data.frame(
      snapshot = snapshot_name,
      candidate_id = candidate_id,
      metric = c("crps", "log_score"),
      mean_difference = rowMeans(replicates),
      ci_lower = apply(replicates, 1L, stats::quantile, 0.025),
      ci_upper = apply(replicates, 1L, stats::quantile, 0.975),
      blocks = length(series),
      replicates = ncol(replicates),
      stringsAsFactors = FALSE
    )
  }))
})
bootstrap <- do.call(rbind, bootstrap_rows)
rownames(bootstrap) <- NULL
utils::write.csv(
  bootstrap,
  file.path(artifact_dir, "nb_vs_poisson_series_bootstrap.csv"),
  row.names = FALSE
)

fundamental <- readRDS(file.path(
  project_root,
  "artifacts",
  "premap_model",
  "development_map_metrics.rds"
))
fundamental <- fundamental[
  fundamental$candidate_id == "nb_pace",
  c("gameid", "prediction_mean", "observed"),
  drop = FALSE
]
fundamental <- fundamental[!duplicated(fundamental$gameid), , drop = FALSE]
names(fundamental)[names(fundamental) == "prediction_mean"] <-
  "fundamental_mean"
names(fundamental)[names(fundamental) == "observed"] <-
  "fundamental_observed"
t15_maps <- map_metrics[
  map_metrics$snapshot == "t15_to_t30",
  ,
  drop = FALSE
]
overlap <- merge(t15_maps, fundamental, by = "gameid")
overlap <- overlap[
  overlap$observed_total == overlap$fundamental_observed,
  ,
  drop = FALSE
]

blend_rows <- list()
blend_index <- 0L
for (candidate_id in unique(overlap$candidate_id)) {
  data <- overlap[overlap$candidate_id == candidate_id, , drop = FALSE]
  data <- data[order(data$game_datetime, data$gameid), , drop = FALSE]
  unique_games <- unique(data$gameid)
  split_index <- floor(length(unique_games) * 0.6)
  development_games <- unique_games[seq_len(split_index)]
  development <- data[data$gameid %in% development_games, , drop = FALSE]
  validation <- data[!data$gameid %in% development_games, , drop = FALSE]
  weight_grid <- seq(0, 1, by = 0.05)
  development_mae <- vapply(weight_grid, function(weight) {
    prediction <- (
      (1 - weight) * development$fundamental_mean +
        weight * development$implied_total_mean
    )
    mean(abs(development$observed_total - prediction))
  }, numeric(1L))
  selected_weight <- weight_grid[[which.min(development_mae)]]
  for (sample_name in c("development", "validation")) {
    rows <- if (sample_name == "development") development else validation
    prediction <- (
      (1 - selected_weight) * rows$fundamental_mean +
        selected_weight * rows$implied_total_mean
    )
    error <- rows$observed_total - prediction
    blend_index <- blend_index + 1L
    blend_rows[[blend_index]] <- data.frame(
      market_candidate_id = candidate_id,
      sample = sample_name,
      selected_market_weight = selected_weight,
      maps = nrow(rows),
      mae = mean(abs(error)),
      rmse = sqrt(mean(error^2)),
      bias = mean(error),
      correlation = stats::cor(rows$observed_total, prediction),
      stringsAsFactors = FALSE
    )
  }
}
blend_summary <- do.call(rbind, blend_rows)
rownames(blend_summary) <- NULL
utils::write.csv(
  blend_summary,
  file.path(artifact_dir, "temporal_blend_summary.csv"),
  row.names = FALSE
)

saveRDS(
  team_metrics,
  file.path(artifact_dir, "team_observation_metrics.rds"),
  version = 3L
)
saveRDS(
  map_metrics,
  file.path(artifact_dir, "map_expectation_metrics.rds"),
  version = 3L
)

print(dispersion_summary, row.names = FALSE)
print(team_summary, row.names = FALSE)
print(map_summary, row.names = FALSE)
print(bootstrap, row.names = FALSE)
print(blend_summary, row.names = FALSE)
