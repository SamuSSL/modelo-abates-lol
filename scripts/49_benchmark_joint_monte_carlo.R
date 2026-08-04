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
bundle <- readRDS(file.path(
  project_root,
  config$paths$models,
  "joint_team_monte_carlo_frozen_2025.rds"
))
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "kill_market_map_features.rds"
))
maps <- maps[maps$game_datetime >= bundle$cutoff, , drop = FALSE]
groups <- split(seq_len(nrow(maps)), maps$league_canonical)
indices <- unique(unlist(lapply(groups, function(index) {
  size <- max(1L, round(300 * length(index) / nrow(maps)))
  index[unique(round(seq(1, length(index), length.out = size)))]
})))
sample_maps <- maps[head(indices, 300L), , drop = FALSE]
result <- benchmark_monte_carlo_draws(
  bundle$model,
  sample_maps,
  method = "coherent_total",
  draw_grid = as.integer(unlist(round_config$monte_carlo_draw_grid))[
    as.integer(unlist(round_config$monte_carlo_draw_grid)) < 100000L
  ],
  reference_draws = 100000L,
  lines = as.numeric(unlist(round_config$line_grid)),
  seed = 20260728L
)
result$passes_probability_tolerance <-
  result$max_over_under_difference < 0.0025
result$passes_crps_tolerance <-
  result$mean_absolute_crps_difference < 0.005
result$passes_latency <-
  result$elapsed_seconds / nrow(sample_maps) < 30
utils::write.csv(
  result,
  file.path(
    project_root,
    config$paths$artifacts,
    "evaluation",
    "joint_team_monte_carlo_convergence.csv"
  ),
  row.names = FALSE
)
print(result, row.names = FALSE)
