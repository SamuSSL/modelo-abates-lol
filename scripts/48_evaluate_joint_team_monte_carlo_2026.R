script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(file.path(project_root, "config", "default.yml"))
evaluation <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation$joint_team_monte_carlo_round
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "kill_market_map_features.rds"
))
development_end <- as.POSIXct(
  round_config$development_end,
  tz = "UTC"
)
development <- maps[
  maps$series_cutoff >= as.POSIXct(
    round_config$development_start,
    tz = "UTC"
  ) &
    maps$series_cutoff < development_end,
  ,
  drop = FALSE
]
secondary <- maps[maps$game_datetime >= development_end, , drop = FALSE]
age_days <- as.numeric(difftime(
  development_end,
  development$series_cutoff,
  units = "days"
))
weights <- 0.5^(pmax(age_days, 0) /
  round_config$observation_half_life_days)
team_features <- as.character(unlist(round_config$team_features))
duration_features <- as.character(unlist(round_config$duration_features))

fit_model <- function(data, data_weights) {
  fit_joint_team_monte_carlo_model(
    data,
    team_feature_names = team_features,
    duration_feature_names = duration_features,
    weights = data_weights,
    alpha = round_config$regularization_alpha,
    inner_fraction =
      round_config$inner_temporal_validation_fraction,
    include_team_effects =
      round_config$include_team_and_opponent_effects,
    copula_shrinkage = round_config$copula_shrinkage
  )
}

cutoffs <- sort(unique(as.numeric(development$series_cutoff)))
core_cutoff <- as.POSIXct(
  cutoffs[[floor(length(cutoffs) * 0.70)]],
  origin = "1970-01-01",
  tz = "UTC"
)
core <- development[
  development$series_cutoff < core_cutoff,
  ,
  drop = FALSE
]
bank_maps <- development[
  development$game_datetime > core_cutoff,
  ,
  drop = FALSE
]
core_weights <- weights[match(core$gameid, development$gameid)]
core_fit <- fit_model(core, core_weights)
bank_rows <- build_historical_prediction_rows(
  core_fit,
  bank_maps,
  core_cutoff
)
bank <- fit_historical_monte_carlo_bank(bank_rows)
fit <- fit_model(development, weights)
dir.create(
  file.path(project_root, config$paths$models),
  recursive = TRUE,
  showWarnings = FALSE
)
saveRDS(
  list(model = fit, historical_bank = bank, cutoff = development_end),
  file.path(
    project_root,
    config$paths$models,
    "joint_team_monte_carlo_frozen_2025.rds"
  ),
  version = 3L
)

selected <- utils::read.csv(file.path(
  artifact_dir,
  "joint_team_monte_carlo_inner_selection.csv"
))
select_consensus <- function(method) {
  data <- selected[selected$method == method, , drop = FALSE]
  key <- interaction(
    data$neighbors,
    data$half_life_days,
    data$historical_weight,
    drop = TRUE
  )
  groups <- split(data, key)
  summary <- do.call(rbind, lapply(groups, function(group) {
    row <- group[which.min(group$mean_crps), , drop = FALSE]
    row$fold_count <- nrow(group)
    row$average_selected_crps <- mean(group$mean_crps)
    row
  }))
  summary[
    order(-summary$fold_count, summary$average_selected_crps),
    ,
    drop = FALSE
  ][1L, , drop = FALSE]
}

predictions <- list()
for (method in as.character(unlist(
  round_config$parametric_candidates
))) {
  predictions[[method]] <- predict_joint_team_monte_carlo_model(
    fit,
    secondary,
    method = method,
    draws = as.integer(round_config$monte_carlo_draws),
    seed = 20260728L
  )
}
consensus_rows <- list()
for (method in as.character(unlist(
  round_config$historical_candidates
))) {
  consensus <- select_consensus(method)
  consensus_rows[[method]] <- consensus
  historical <- predict_historical_monte_carlo_model(
    fit,
    bank,
    secondary,
    method = method,
    draws = as.integer(round_config$monte_carlo_draws),
    seed = 20260828L,
    neighbors = consensus$neighbors,
    half_life_days = consensus$half_life_days
  )
  predictions[[paste0("historical_", method)]] <- historical
  predictions[[paste0("hybrid_", method)]] <- lapply(
    seq_along(historical),
    function(index) {
      pmf <- blend_predictive_pmfs(
        predictions$coherent_total[[index]]$pmf,
        historical[[index]]$pmf,
        consensus$historical_weight
      )
      support <- seq.int(0L, length(pmf) - 1L)
      result <- historical[[index]]
      result$pmf <- pmf
      result$mean <- sum(support * pmf)
      result
    }
  )
}

fold <- data.frame(
  fold_id = "2026_secondary",
  validation_start = development_end,
  stringsAsFactors = FALSE
)
new_metrics <- do.call(rbind, lapply(names(predictions), function(candidate) {
  rows <- lapply(seq_len(nrow(secondary)), function(index) {
    scored <- .score_count_map(
      secondary[index, , drop = FALSE],
      predictions[[candidate]][[index]],
      candidate,
      if (grepl("^historical", candidate)) {
        "historical_monte_carlo"
      } else {
        "joint_negative_binomial"
      },
      "team_intensity_duration_dependency",
      fold,
      nrow(development),
      sum(weights)
    )
    scored$pmf <- I(list(predictions[[candidate]][[index]]$pmf))
    scored
  })
  do.call(rbind, rows)
}))
reference <- readRDS(file.path(
  artifact_dir,
  "kill_market_2026_map_metrics.rds"
))
reference <- reference[
  reference$candidate_id == "nb_v1_rebuilt",
  ,
  drop = FALSE
]
all_columns <- union(names(reference), names(new_metrics))
fill <- function(data) {
  for (column in setdiff(all_columns, names(data))) data[[column]] <- NA
  data[all_columns]
}
comparison <- rbind(fill(reference), fill(new_metrics))
summary <- .summarize_simple_metrics(
  comparison,
  c("candidate_id", "distribution", "feature_block")
)
by_league <- .summarize_simple_metrics(
  comparison,
  c("candidate_id", "league_canonical")
)
lines <- evaluate_line_probabilities(
  comparison,
  as.numeric(unlist(round_config$line_grid))
)$summary
bootstrap <- do.call(rbind, lapply(
  unique(new_metrics$candidate_id),
  function(candidate) paired_block_bootstrap_crps(
    comparison,
    candidate,
    "nb_v1_rebuilt",
    replicates = 2000L,
    seed = 20260728L
  )
))
saveRDS(
  new_metrics,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_2026_metrics.rds"
  ),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_2026_summary.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_2026_by_league.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  lines,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_2026_lines.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_2026_bootstrap.csv"
  ),
  row.names = FALSE
)
utils::write.csv(
  do.call(rbind, consensus_rows),
  file.path(
    artifact_dir,
    "joint_team_monte_carlo_historical_consensus.csv"
  ),
  row.names = FALSE
)
print(summary[order(summary$mean_crps), ], row.names = FALSE)
