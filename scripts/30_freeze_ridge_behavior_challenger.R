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
dynamic_config <- evaluation_config$dynamic_team_round
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "dynamic_structural_map_features.rds"
))
result_cutoff <- max(maps$game_datetime, na.rm = TRUE)
training_cutoff <- result_cutoff + 1
momentum_features <- c(
  "matchup_momentum_attack",
  "matchup_momentum_mortality",
  "matchup_momentum_bloodiness"
)
feature_names <- setdiff(
  dynamic_team_model_features(),
  momentum_features
)
train <- maps[
  maps$series_cutoff >= as.POSIXct("2022-01-01", tz = "UTC") &
    maps$series_cutoff < training_cutoff,
  ,
  drop = FALSE
]
age_days <- as.numeric(difftime(
  training_cutoff,
  train$series_cutoff,
  units = "days"
))
weights <- 0.5^(
  age_days / round_config$observation_half_life_days
)
fit <- fit_regularized_count_model(
  train,
  feature_names = feature_names,
  alpha = 0,
  weights = weights,
  inner_fraction =
    dynamic_config$inner_temporal_validation_fraction
)
model_directory <- file.path(project_root, "models")
dir.create(model_directory, recursive = TRUE, showWarnings = FALSE)
model_path <- file.path(
  model_directory,
  "ridge_plus_behavior_challenger.rds"
)
saveRDS(fit, model_path, version = 3L)
model_hash <- digest::digest(
  file = model_path,
  algo = "sha256"
)
metadata <- list(
  model_version = paste0(
    "ridge-behavior-",
    substr(model_hash, 1L, 12L)
  ),
  status = "prospective_challenger_not_promoted",
  result_cutoff = format(
    result_cutoff,
    tz = "UTC",
    usetz = TRUE
  ),
  clean_maps_must_be_after_cutoff = TRUE,
  training_maps = nrow(train),
  observation_half_life_days =
    round_config$observation_half_life_days,
  alpha = fit$alpha,
  lambda = fit$lambda,
  theta = fit$theta,
  feature_names = as.list(feature_names),
  excluded_feature_blocks = list("momentum"),
  model_sha256 = model_hash
)
yaml::write_yaml(
  metadata,
  file.path(
    project_root,
    "config",
    "frozen-ridge-behavior-challenger.yml"
  )
)
cat(
  "Frozen model:", metadata$model_version,
  "\nTraining maps:", nrow(train),
  "\nResult cutoff:", metadata$result_cutoff,
  "\n"
)
