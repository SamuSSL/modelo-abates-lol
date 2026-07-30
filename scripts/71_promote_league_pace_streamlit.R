script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

evaluation_config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "evaluation.yml"
))
model_selection <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "model-selection.yml"
))
maps <- targets::tar_read(operational_map_table)
deployment_cutoff <- targets::tar_read(deployment_cutoff)
team_snapshot <- targets::tar_read(deployment_team_snapshot_enriched)
taxonomy <- targets::tar_read(champion_taxonomy)
champion_snapshot <- targets::tar_read(deployment_champion_snapshot)

training <- maps[
  maps$game_datetime < deployment_cutoff,
  ,
  drop = FALSE
]
age_days <- as.numeric(difftime(
  deployment_cutoff,
  training$series_cutoff,
  units = "days"
))
fit <- fit_count_regression(
  training,
  distribution = "negative_binomial",
  feature_names = "pace",
  weights = 0.5^(
    age_days /
      evaluation_config$simple_team_models$
        observation_half_life_days
  )
)
model_hash <- substr(
  digest::digest(
    list(
      stats::coef(fit$model),
      fit$theta,
      deployment_cutoff,
      "nb_pace"
    ),
    algo = "sha256"
  ),
  1L,
  12L
)
bundle <- build_portable_model_bundle(
  fit,
  team_snapshot,
  taxonomy,
  champion_snapshot,
  metadata = list(
    model_version = paste0("pace-", model_hash),
    selected_candidate_id = "nb_pace",
    data_cutoff = format(
      deployment_cutoff,
      tz = "UTC",
      usetz = TRUE
    )
  ),
  sample_limits = model_selection$sample_limits
)
bundle$taxonomy <- list()
bundle$champion_samples <- list()
bundle_path <- write_portable_model_bundle(
  bundle,
  file.path(project_root, "app_data", "model_bundle.json")
)

complete <- stats::complete.cases(maps[c("league_canonical", "pace")])
fixture_row <- maps[complete, , drop = FALSE]
fixture_row <- fixture_row[
  which.max(fixture_row$game_datetime),
  ,
  drop = FALSE
]
prediction <- predict_count_regression(
  fit,
  fixture_row,
  tail_tolerance =
    evaluation_config$simple_team_models$pmf_tail_tolerance
)[[1L]]
fixture <- list(
  league = as.character(fixture_row$league_canonical),
  features = list(pace = as.numeric(fixture_row$pace)),
  expected_mean = prediction$mean,
  expected_pmf = prediction$pmf,
  tolerance = 1e-10
)
fixture_path <- file.path(
  project_root,
  "app_data",
  "parity_fixture.json"
)
jsonlite::write_json(
  fixture,
  fixture_path,
  auto_unbox = TRUE,
  pretty = TRUE,
  digits = NA
)

cat(
  "Modelo liga + pace promovido.\n",
  "Bundle:", bundle_path, "\n",
  "Versão:", bundle$metadata$model_version, "\n",
  "Mapas de treino:", fit$training_rows, "\n"
)
