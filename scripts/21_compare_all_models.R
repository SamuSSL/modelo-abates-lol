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
if (!requireNamespace("xgboost", quietly = TRUE)) {
  stop("xgboost is required for the ML challenger.", call. = FALSE)
}
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
folds <- do.call(rbind, lapply(
  evaluation_config$recency_sensitivity$folds,
  function(fold) {
    data.frame(
      fold_id = fold$id,
      validation_start = as.POSIXct(
        fold$validation_start,
        tz = "UTC"
      ),
      validation_end = as.POSIXct(
        fold$validation_end,
        tz = "UTC"
      ),
      stringsAsFactors = FALSE
    )
  }
))
raw_features <- c(
  "pace",
  "team_opponent_intensity",
  "matchup_intensity_imbalance",
  "duration_history",
  "duration_history_imbalance",
  "draft_frontline",
  "draft_burst",
  "draft_frontline_imbalance",
  "draft_engage",
  "draft_poke_siege",
  "draft_dive",
  "draft_protect",
  "draft_skirmish",
  "draft_scaling",
  "player_champion_conflict_delta"
)
qcut_features <- c(
  "team_opponent_intensity",
  "matchup_intensity_imbalance",
  "duration_history",
  "draft_engage",
  "draft_poke_siege",
  "draft_dive",
  "draft_protect",
  "draft_skirmish",
  "draft_scaling",
  "player_champion_conflict_delta"
)
required <- unique(c(
  "gameid",
  "game_datetime",
  "series_cutoff",
  "league_canonical",
  "total_kills_game",
  raw_features
))
challenger_batches <- list()
batch_index <- 0L
for (fold_index in seq_len(nrow(folds))) {
  fold <- folds[fold_index, , drop = FALSE]
  train_rows <- maps$series_cutoff <
    fold$validation_start[[1L]]
  validation_rows <- maps$game_datetime >=
    fold$validation_start[[1L]] &
    maps$game_datetime < fold$validation_end[[1L]] &
    maps$game_datetime < development_end
  train <- maps[train_rows, required, drop = FALSE]
  validation <- maps[validation_rows, required, drop = FALSE]
  train <- train[stats::complete.cases(train), , drop = FALSE]
  validation <- validation[
    stats::complete.cases(validation),
    ,
    drop = FALSE
  ]
  age_days <- as.numeric(difftime(
    fold$validation_start[[1L]],
    train$series_cutoff,
    units = "days"
  ))
  weights <- 0.5^(
    age_days / round_config$observation_half_life_days
  )

  qfit <- fit_quantile_bins(
    train,
    qcut_features,
    bins = 5L
  )
  qtrain <- cbind(
    data.frame(
      total_kills_game = train$total_kills_game,
      league_canonical = factor(train$league_canonical),
      stringsAsFactors = FALSE
    ),
    apply_quantile_bins(qfit, train)
  )
  qvalidation <- cbind(
    data.frame(
      league_canonical = factor(
        validation$league_canonical,
        levels = levels(qtrain$league_canonical)
      ),
      stringsAsFactors = FALSE
    ),
    apply_quantile_bins(qfit, validation)
  )
  qmodel <- suppressWarnings(MASS::glm.nb(
    total_kills_game ~ .,
    data = qtrain,
    weights = weights,
    control = stats::glm.control(maxit = 100)
  ))
  qmeans <- as.numeric(stats::predict(
    qmodel,
    qvalidation,
    type = "response"
  ))

  pca <- fit_pca_transform(
    train,
    raw_features,
    retained_variance = 0.9
  )
  pca_train <- cbind(
    data.frame(
      league_canonical = train$league_canonical,
      total_kills_game = train$total_kills_game,
      stringsAsFactors = FALSE
    ),
    apply_pca_transform(pca, train)
  )
  pca_validation <- cbind(
    data.frame(
      league_canonical = validation$league_canonical,
      stringsAsFactors = FALSE
    ),
    apply_pca_transform(pca, validation)
  )
  pca_features <- grep("^PC", names(pca_train), value = TRUE)
  pca_model <- fit_count_regression(
    pca_train,
    distribution = "negative_binomial",
    feature_names = pca_features,
    weights = weights
  )
  pca_predictions <- predict_count_regression(
    pca_model,
    pca_validation
  )

  league_levels <- sort(unique(train$league_canonical))
  train$league_canonical <- factor(
    train$league_canonical,
    levels = league_levels
  )
  validation$league_canonical <- factor(
    validation$league_canonical,
    levels = league_levels
  )
  x_formula <- stats::reformulate(
    c("league_canonical", raw_features)
  )
  x_train <- stats::model.matrix(x_formula, train)
  x_validation <- stats::model.matrix(x_formula, validation)
  dtrain <- xgboost::xgb.DMatrix(
    data = x_train,
    label = train$total_kills_game,
    weight = weights
  )
  boost_config <- round_config$boosting
  boost <- xgboost::xgb.train(
    params = list(
      objective = boost_config$objective,
      eta = boost_config$eta,
      max_depth = boost_config$max_depth,
      min_child_weight = boost_config$min_child_weight,
      subsample = boost_config$subsample,
      colsample_bytree = boost_config$colsample_bytree,
      lambda = boost_config$lambda,
      alpha = boost_config$alpha,
      nthread = boost_config$nthread,
      seed = round_config$mcmc$seed + fold_index
    ),
    data = dtrain,
    nrounds = boost_config$nrounds,
    verbose = 0
  )
  boost_train_mean <- as.numeric(stats::predict(
    boost,
    x_train
  ))
  boost_means <- as.numeric(stats::predict(
    boost,
    x_validation
  ))
  boost_theta <- suppressWarnings(MASS::theta.ml(
    train$total_kills_game,
    boost_train_mean,
    weights = weights,
    limit = 100
  ))

  predictions <- list(
    nb_qcut5 = lapply(qmeans, function(mean) {
      distribution <- make_count_pmf(
        mean,
        "negative_binomial",
        theta = qmodel$theta
      )
      c(list(mean = mean), distribution)
    }),
    nb_pca90 = pca_predictions,
    xgboost_poisson_mean_nb_pmf = lapply(
      boost_means,
      function(mean) {
        distribution <- make_count_pmf(
          mean,
          "negative_binomial",
          theta = boost_theta
        )
        c(list(mean = mean), distribution)
      }
    )
  )
  for (candidate_id in names(predictions)) {
    rows <- lapply(seq_len(nrow(validation)), function(index) {
      scored <- .score_count_map(
        validation[index, , drop = FALSE],
        predictions[[candidate_id]][[index]],
        candidate_id = candidate_id,
        distribution = if (
          candidate_id == "xgboost_poisson_mean_nb_pmf"
        ) {
          "xgboost_negative_binomial"
        } else {
          "negative_binomial"
        },
        feature_block = candidate_id,
        fold = fold,
        training_games = nrow(train),
        effective_training_games = sum(weights)
      )
      scored$pmf <- I(list(
        predictions[[candidate_id]][[index]]$pmf
      ))
      scored
    })
    batch_index <- batch_index + 1L
    challenger_batches[[batch_index]] <- do.call(rbind, rows)
  }
}
challenger_metrics <- do.call(rbind, challenger_batches)
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
structural_metrics <- readRDS(file.path(
  artifact_dir,
  "structural_model_map_metrics.rds"
))
bayesian_metrics <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "bayesian",
  "bayesian_map_metrics.rds"
))
shared_columns <- Reduce(
  union,
  list(
    names(structural_metrics),
    names(bayesian_metrics),
    names(challenger_metrics)
  )
)
align_columns <- function(data) {
  for (column in setdiff(shared_columns, names(data))) {
    data[[column]] <- NA
  }
  data[shared_columns]
}
all_metrics <- rbind(
  align_columns(structural_metrics),
  align_columns(bayesian_metrics),
  align_columns(challenger_metrics)
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
reference_id <- "nb_v1_rebuilt"
bootstrap <- do.call(rbind, lapply(
  setdiff(unique(all_metrics$candidate_id), reference_id),
  function(candidate) {
    paired_block_bootstrap_crps(
      all_metrics,
      candidate_id = candidate,
      reference_id = reference_id,
      replicates =
        evaluation_config$simple_team_models$bootstrap_replicates,
      seed =
        evaluation_config$simple_team_models$bootstrap_seed
    )
  }
))
line_evaluation <- evaluate_line_probabilities(
  all_metrics,
  c(24.5, 27.5, 30.5)
)
by_fold <- .summarize_simple_metrics(
  all_metrics,
  c("candidate_id", "fold_id")
)
by_league <- .summarize_simple_metrics(
  all_metrics,
  c("candidate_id", "league_canonical")
)
saveRDS(
  challenger_metrics,
  file.path(artifact_dir, "challenger_model_map_metrics.rds"),
  version = 3L
)
saveRDS(
  all_metrics,
  file.path(artifact_dir, "all_development_model_metrics.rds"),
  version = 3L
)
outputs <- list(
  all_model_summary = summary,
  all_model_bootstrap_vs_v1 = bootstrap,
  all_model_line_summary = line_evaluation$summary,
  all_model_by_fold = by_fold,
  all_model_by_league = by_league
)
for (name in names(outputs)) {
  utils::write.csv(
    outputs[[name]],
    file.path(artifact_dir, paste0(name, ".csv")),
    row.names = FALSE
  )
}
print(summary, row.names = FALSE)
cat("\nBootstrap contra V1:\n")
print(bootstrap, row.names = FALSE)
cat("\nLinhas:\n")
print(line_evaluation$summary, row.names = FALSE)
