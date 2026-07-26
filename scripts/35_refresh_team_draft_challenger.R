scripts <- c(
  "25_evaluate_regularized_dynamic_models.R",
  "27_evaluate_regularized_2026_secondary.R",
  "29_evaluate_dynamic_rating_ablations.R",
  "30_freeze_ridge_behavior_challenger.R",
  "31_build_time_series_tracking.R",
  "32_evaluate_time_series_challenger.R",
  "33_refresh_active_team_bundle.R"
)

for (script in scripts) {
  message("Executando ", script)
  source(file.path("scripts", script), local = new.env(parent = globalenv()))
}
