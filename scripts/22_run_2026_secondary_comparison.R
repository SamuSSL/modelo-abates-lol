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
selection <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "structural-model-selection.yml"
))
round_config <- evaluation_config$structural_bayesian_round
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "structural_map_features.rds"
))
for (column in c(
  "blue_team_id",
  "blue_team_name",
  "red_team_id",
  "red_team_name"
)) {
  if (!column %in% names(maps)) {
    maps[[column]] <- maps[[paste0(column, ".x")]]
  }
}
maps$game_length_minutes <- maps$game_length_seconds / 60
development_end <- as.POSIXct(
  round_config$development_end,
  tz = "UTC"
)
prospective_cutoff <- as.POSIXct(
  selection$prospective_confirmation$result_cutoff,
  tz = "UTC"
)
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
v1_features <- c(
  "pace",
  "draft_frontline",
  "draft_burst",
  "draft_frontline_imbalance"
)
team_opponent_features <- c(
  "draft_frontline",
  "draft_burst",
  "draft_frontline_imbalance",
  "team_opponent_intensity",
  "matchup_intensity_imbalance",
  "duration_history",
  "duration_history_imbalance"
)
archetype_features <- c(
  team_opponent_features,
  "draft_engage",
  "draft_poke_siege",
  "draft_dive",
  "draft_protect",
  "draft_skirmish",
  "draft_scaling"
)
interaction_features <- c(
  archetype_features,
  "player_champion_conflict_delta"
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
  "blue_team_id",
  "blue_team_name",
  "red_team_id",
  "red_team_name",
  "blue_kills",
  "red_kills",
  "total_kills_game",
  "game_length_minutes",
  raw_features
))
train <- maps[
  maps$series_cutoff < development_end,
  required,
  drop = FALSE
]
validation <- maps[
  maps$game_datetime >= development_end &
    maps$game_datetime <= prospective_cutoff,
  required,
  drop = FALSE
]
train <- train[stats::complete.cases(train), , drop = FALSE]
validation <- validation[
  stats::complete.cases(validation),
  ,
  drop = FALSE
]
assert_development_period(train, development_end)
age_days <- as.numeric(difftime(
  development_end,
  train$series_cutoff,
  units = "days"
))
weights <- 0.5^(
  age_days / round_config$observation_half_life_days
)
fold <- data.frame(
  fold_id = "2026_secondary",
  validation_start = development_end,
  stringsAsFactors = FALSE
)
score_predictions <- function(
  predictions,
  candidate_id,
  distribution,
  feature_block
) {
  rows <- lapply(seq_len(nrow(validation)), function(index) {
    scored <- .score_count_map(
      validation[index, , drop = FALSE],
      predictions[[index]],
      candidate_id,
      distribution,
      feature_block,
      fold,
      nrow(train),
      sum(weights)
    )
    scored$pmf <- I(list(predictions[[index]]$pmf))
    scored
  })
  do.call(rbind, rows)
}
candidate_features <- list(
  nb_v1_rebuilt = v1_features,
  nb_team_opponent = team_opponent_features,
  nb_functional_archetypes = archetype_features,
  nb_player_champion = interaction_features
)
batches <- list()
batch_index <- 0L
for (candidate_id in names(candidate_features)) {
  fit <- fit_count_regression(
    train,
    "negative_binomial",
    candidate_features[[candidate_id]],
    weights
  )
  predictions <- predict_count_regression(fit, validation)
  batch_index <- batch_index + 1L
  batches[[batch_index]] <- score_predictions(
    predictions,
    candidate_id,
    "negative_binomial",
    candidate_id
  )
}

pca <- fit_pca_transform(
  train,
  raw_features,
  retained_variance = 0.9
)
pca_train <- cbind(
  train[c("league_canonical", "total_kills_game")],
  apply_pca_transform(pca, train)
)
pca_validation <- cbind(
  validation["league_canonical"],
  apply_pca_transform(pca, validation)
)
pca_features <- grep("^PC", names(pca_train), value = TRUE)
pca_model <- fit_count_regression(
  pca_train,
  "negative_binomial",
  pca_features,
  weights
)
batch_index <- batch_index + 1L
batches[[batch_index]] <- score_predictions(
  predict_count_regression(pca_model, pca_validation),
  "nb_pca90",
  "negative_binomial",
  "nb_pca90"
)

qcut_features <- setdiff(
  raw_features,
  c(
    "pace",
    "draft_frontline",
    "draft_burst",
    "draft_frontline_imbalance",
    "duration_history_imbalance"
  )
)
qfit <- fit_quantile_bins(train, qcut_features, bins = 5L)
qtrain <- cbind(
  data.frame(
    total_kills_game = train$total_kills_game,
    league_canonical = factor(train$league_canonical)
  ),
  apply_quantile_bins(qfit, train)
)
qvalidation <- cbind(
  data.frame(
    league_canonical = factor(
      validation$league_canonical,
      levels = levels(qtrain$league_canonical)
    )
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
qpredictions <- lapply(qmeans, function(mean) {
  distribution <- make_count_pmf(
    mean,
    "negative_binomial",
    theta = qmodel$theta
  )
  c(list(mean = mean), distribution)
})
batch_index <- batch_index + 1L
batches[[batch_index]] <- score_predictions(
  qpredictions,
  "nb_qcut5",
  "negative_binomial",
  "nb_qcut5"
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
  x_train,
  label = train$total_kills_game,
  weight = weights
)
boost_config <- round_config$boosting
boost <- xgboost::xgb.train(
  params = c(
    as.list(boost_config[setdiff(
      names(boost_config),
      "nrounds"
    )]),
    list(seed = round_config$mcmc$seed)
  ),
  data = dtrain,
  nrounds = boost_config$nrounds,
  verbose = 0
)
boost_train_mean <- as.numeric(stats::predict(boost, x_train))
boost_mean <- as.numeric(stats::predict(boost, x_validation))
boost_theta <- suppressWarnings(MASS::theta.ml(
  train$total_kills_game,
  boost_train_mean,
  weights = weights,
  limit = 100
))
boost_predictions <- lapply(boost_mean, function(mean) {
  distribution <- make_count_pmf(
    mean,
    "negative_binomial",
    theta = boost_theta
  )
  c(list(mean = mean), distribution)
})
batch_index <- batch_index + 1L
batches[[batch_index]] <- score_predictions(
  boost_predictions,
  "xgboost_poisson_mean_nb_pmf",
  "xgboost_negative_binomial",
  "xgboost_poisson_mean_nb_pmf"
)

for (
  duration_distribution in
    round_config$duration_distributions
) {
  fit <- fit_intensity_duration_model(
    train,
    duration_distribution,
    duration_features,
    intensity_features,
    weights
  )
  predictions <- predict_intensity_duration_model(
    fit,
    validation,
    draws = 500L,
    seed = round_config$mcmc$seed
  )
  candidate_id <- paste0(
    "decomposed_",
    duration_distribution
  )
  batch_index <- batch_index + 1L
  batches[[batch_index]] <- score_predictions(
    predictions,
    candidate_id,
    "negative_binomial_mixture",
    "intensity_duration"
  )
}

cmdstanr::set_cmdstan_path(file.path(
  Sys.getenv("USERPROFILE"),
  ".cmdstan",
  "cmdstan-2.37.0"
))
stan_model <- cmdstanr::cmdstan_model(file.path(
  project_root,
  "stan",
  "hierarchical_intensity_duration.stan"
))
prepared <- prepare_bayesian_fold_data(
  train,
  validation,
  intensity_features,
  duration_features,
  weights,
  development_end,
  allow_secondary_validation = TRUE
)
bayes_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "bayesian",
  "secondary_2026"
)
dir.create(bayes_dir, recursive = TRUE, showWarnings = FALSE)
bayes_fit <- stan_model$sample(
  data = prepared$data,
  seed = round_config$mcmc$seed,
  chains = round_config$mcmc$chains,
  parallel_chains = round_config$mcmc$parallel_chains,
  iter_warmup = round_config$mcmc$iter_warmup,
  iter_sampling = round_config$mcmc$iter_sampling,
  adapt_delta = round_config$mcmc$adapt_delta,
  max_treedepth = round_config$mcmc$max_treedepth,
  output_dir = bayes_dir,
  refresh = 200
)
bayes_metrics <- score_bayesian_predictions(
  bayes_fit$draws("y_pred", format = "matrix"),
  prepared$metadata$validation,
  fold,
  candidate_id = "bayesian_hierarchical"
)
bayes_diagnostics <- summarize_mcmc_diagnostics(bayes_fit)
utils::write.csv(
  bayes_diagnostics,
  file.path(bayes_dir, "diagnostics.csv"),
  row.names = FALSE
)
bayes_fit$save_object(file.path(bayes_dir, "fit.rds"))
batches[[length(batches) + 1L]] <- bayes_metrics

metrics <- do.call(rbind, batches)
summary <- .summarize_simple_metrics(
  metrics,
  c("candidate_id", "distribution", "feature_block")
)
summary <- summary[
  order(summary$mean_crps, summary$mean_log_score),
  ,
  drop = FALSE
]
lines <- evaluate_line_probabilities(
  metrics,
  c(24.5, 27.5, 30.5)
)
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
saveRDS(
  metrics,
  file.path(artifact_dir, "secondary_2026_map_metrics.rds"),
  version = 3L
)
utils::write.csv(
  summary,
  file.path(artifact_dir, "secondary_2026_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  lines$summary,
  file.path(artifact_dir, "secondary_2026_line_summary.csv"),
  row.names = FALSE
)
metadata <- list(
  selection_frozen_before_comparison = TRUE,
  comparison_can_change_selection = FALSE,
  development_end = round_config$development_end,
  prospective_cutoff =
    selection$prospective_confirmation$result_cutoff,
  maps = nrow(validation)
)
yaml::write_yaml(
  metadata,
  file.path(artifact_dir, "secondary_2026_metadata.yml")
)
print(summary, row.names = FALSE)
print(bayes_diagnostics, row.names = FALSE)
print(lines$summary, row.names = FALSE)
