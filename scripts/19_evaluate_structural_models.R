script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "default.yml"
))
evaluation_config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
round_config <- evaluation_config$structural_bayesian_round
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "structural_map_features.rds"
))
maps$game_length_minutes <- maps$game_length_seconds / 60
development_end <- as.POSIXct(
  round_config$development_end,
  tz = "UTC"
)
assert_development_period(
  maps[maps$game_datetime < development_end, , drop = FALSE],
  development_end
)
parse_datetime <- function(value) {
  as.POSIXct(as.character(value), tz = "UTC")
}
folds <- do.call(rbind, lapply(
  evaluation_config$recency_sensitivity$folds,
  function(fold) {
    data.frame(
      fold_id = fold$id,
      validation_start = parse_datetime(fold$validation_start),
      validation_end = parse_datetime(fold$validation_end),
      stringsAsFactors = FALSE
    )
  }
))

v1_features <- c(
  "pace",
  "draft_frontline",
  "draft_burst",
  "draft_frontline_imbalance"
)
team_opponent_features <- c(
  "team_opponent_intensity",
  "matchup_intensity_imbalance",
  "duration_history",
  "duration_history_imbalance"
)
v1_draft_features <- setdiff(v1_features, "pace")
archetype_features <- c(
  "draft_engage",
  "draft_poke_siege",
  "draft_dive",
  "draft_protect",
  "draft_skirmish",
  "draft_scaling"
)
interaction_features <- c(
  "player_champion_conflict_delta"
)
candidate_features <- list(
  nb_v1_rebuilt = v1_features,
  nb_team_opponent = c(
    v1_draft_features,
    team_opponent_features
  ),
  nb_functional_archetypes = c(
    v1_draft_features,
    team_opponent_features,
    archetype_features
  ),
  nb_player_champion = c(
    v1_draft_features,
    team_opponent_features,
    archetype_features,
    interaction_features
  )
)
candidates <- data.frame(
  candidate_id = names(candidate_features),
  distribution = "negative_binomial",
  feature_block = names(candidate_features),
  stringsAsFactors = FALSE
)
candidates$feature_names <- I(unname(candidate_features))
direct <- evaluate_simple_team_models(
  maps = maps,
  folds = folds,
  candidates = candidates,
  holdout_start = development_end,
  training_start = "2022-01-01 00:00:00",
  half_life_days = round_config$observation_half_life_days,
  prior_games =
    evaluation_config$baseline$league_shrinkage_prior_games,
  tail_tolerance =
    evaluation_config$simple_team_models$pmf_tail_tolerance
)

duration_features <- c(
  "duration_history",
  "duration_history_imbalance",
  "draft_scaling",
  "draft_poke_siege",
  "draft_protect"
)
intensity_features <- c(
  "team_opponent_intensity",
  "matchup_intensity_imbalance",
  "draft_engage",
  "draft_dive",
  "draft_skirmish",
  "player_champion_conflict_delta"
)
required <- unique(c(
  "gameid",
  "game_datetime",
  "series_cutoff",
  "league_canonical",
  "total_kills_game",
  "game_length_minutes",
  duration_features,
  intensity_features
))
decomposition_batches <- list()
batch_index <- 0L
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  training_rows <- maps$series_cutoff <
    fold$validation_start[[1L]]
  validation_rows <- maps$game_datetime >=
    fold$validation_start[[1L]] &
    maps$game_datetime < fold$validation_end[[1L]] &
    maps$game_datetime < development_end
  train <- maps[training_rows, required, drop = FALSE]
  validation <- maps[validation_rows, required, drop = FALSE]
  train <- train[stats::complete.cases(train), , drop = FALSE]
  validation <- validation[
    stats::complete.cases(validation),
    ,
    drop = FALSE
  ]
  if (nrow(train) == 0L || nrow(validation) == 0L) {
    next
  }
  age_days <- as.numeric(difftime(
    fold$validation_start[[1L]],
    train$series_cutoff,
    units = "days"
  ))
  weights <- 0.5^(
    age_days / round_config$observation_half_life_days
  )
  for (
    duration_distribution in
      round_config$duration_distributions
  ) {
    candidate_id <- paste0(
      "decomposed_",
      duration_distribution
    )
    fit <- fit_intensity_duration_model(
      train,
      duration_distribution = duration_distribution,
      duration_features = duration_features,
      intensity_features = intensity_features,
      weights = weights
    )
    predictions <- predict_intensity_duration_model(
      fit,
      validation,
      draws = 250L,
      seed = round_config$mcmc$seed + fold_index
    )
    rows <- lapply(seq_len(nrow(validation)), function(index) {
      scored <- .score_count_map(
        validation[index, , drop = FALSE],
        predictions[[index]],
        candidate_id = candidate_id,
        distribution = "negative_binomial_mixture",
        feature_block = "intensity_duration",
        fold = fold,
        training_games = nrow(train),
        effective_training_games = sum(weights)
      )
      scored$duration_prediction_mean <-
        predictions[[index]]$duration_mean
      scored$duration_prediction_sd <-
        predictions[[index]]$duration_sd
      scored$intensity_per_minute <-
        predictions[[index]]$intensity_per_minute
      scored$pmf <- I(list(predictions[[index]]$pmf))
      scored
    })
    batch_index <- batch_index + 1L
    decomposition_batches[[batch_index]] <- do.call(rbind, rows)
  }
}
decomposition_metrics <- do.call(rbind, decomposition_batches)
shared_columns <- union(
  names(direct$map_metrics),
  names(decomposition_metrics)
)
for (column in setdiff(
  shared_columns,
  names(direct$map_metrics)
)) {
  direct$map_metrics[[column]] <- NA
}
for (column in setdiff(
  shared_columns,
  names(decomposition_metrics)
)) {
  decomposition_metrics[[column]] <- NA
}
all_metrics <- rbind(
  direct$map_metrics[shared_columns],
  decomposition_metrics[shared_columns]
)
summary <- .summarize_simple_metrics(
  all_metrics,
  c("candidate_id", "distribution", "feature_block")
)
summary$folds_completed <- vapply(
  summary$candidate_id,
  function(candidate) length(unique(
    all_metrics$fold_id[
      all_metrics$candidate_id == candidate
    ]
  )),
  integer(1L)
)
summary <- summary[
  order(summary$mean_crps, summary$mean_log_score),
  ,
  drop = FALSE
]
duration_metrics <- data.frame(
  candidate_id = decomposition_metrics$candidate_id,
  fold_id = decomposition_metrics$fold_id,
  observed_duration = maps$game_length_minutes[
    match(decomposition_metrics$gameid, maps$gameid)
  ],
  predicted_duration =
    decomposition_metrics$duration_prediction_mean,
  prediction_sd =
    decomposition_metrics$duration_prediction_sd,
  stringsAsFactors = FALSE
)
duration_summary <- aggregate(
  cbind(
    absolute_error =
      abs(observed_duration - predicted_duration),
    error = predicted_duration - observed_duration,
    prediction_sd = prediction_sd
  ) ~ candidate_id,
  duration_metrics,
  mean
)
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(
  all_metrics,
  file.path(artifact_dir, "structural_model_map_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "structural_model_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  duration_summary,
  file.path(artifact_dir, "structural_duration_summary.csv"),
  row.names = FALSE
)
print(summary, row.names = FALSE)
cat("\nDuração:\n")
print(duration_summary, row.names = FALSE)
