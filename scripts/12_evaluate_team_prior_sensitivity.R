script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
project_config <- yaml::read_yaml(
  file.path(project_root, "config", "default.yml")
)
evaluation_config <- yaml::read_yaml(
  file.path(project_root, "config", "evaluation.yml")
)
prior_config <- evaluation_config$team_prior_sensitivity
prior_grid <- as.numeric(unlist(prior_config$prior_grid_games))
team_metrics <- readRDS(file.path(
  project_root,
  project_config$paths$interim,
  "team_map_metrics.rds"
))
games <- readRDS(file.path(
  project_root,
  project_config$paths$interim,
  "canonical_games.rds"
))
metric_names <- c(
  "combined_kills_per_minute",
  "damage_per_minute",
  "damage_taken_per_minute",
  "kills_per_minute",
  "deaths_per_minute"
)

map_tables <- lapply(prior_grid, function(prior_games) {
  team_features <- build_team_rolling_features(
    team_metrics,
    metric_names = metric_names,
    half_life_days = prior_config$team_feature_half_life_days,
    prior_games = prior_games
  )
  team_path <- file.path(
    project_root,
    project_config$paths$interim,
    paste0("team_rolling_features_prior", prior_games, ".rds")
  )
  saveRDS(team_features, team_path, version = 3L)
  map_features <- assemble_map_feature_table(team_features, games)
  map_path <- file.path(
    project_root,
    project_config$paths$interim,
    paste0("map_features_prior", prior_games, ".rds")
  )
  saveRDS(map_features, map_path, version = 3L)
  derive_team_signal_features(map_features)
})
names(map_tables) <- paste0("prior", prior_grid)

parse_datetime <- function(value) {
  as.POSIXct(as.character(value), tz = evaluation_config$timezone)
}
folds <- do.call(
  rbind,
  lapply(evaluation_config$recency_sensitivity$folds, function(fold) {
    data.frame(
      fold_id = as.character(fold$id),
      validation_start = parse_datetime(fold$validation_start),
      validation_end = parse_datetime(fold$validation_end),
      stringsAsFactors = FALSE
    )
  })
)
rownames(folds) <- NULL
evaluation <- evaluate_team_prior_sensitivity(
  map_tables = map_tables,
  prior_grid_games = prior_grid,
  folds = folds,
  holdout_start = parse_datetime(evaluation_config$holdout$start),
  training_start = parse_datetime(
    evaluation_config$simple_team_models$training_start
  ),
  half_life_days = prior_config$observation_half_life_days,
  tail_tolerance = prior_config$pmf_tail_tolerance
)

candidate_ids <- paste0("nb_pace_prior", prior_grid)
pair_indices <- utils::combn(candidate_ids, 2L)
bootstrap_pairwise <- do.call(
  rbind,
  lapply(seq_len(ncol(pair_indices)), function(index) {
    paired_block_bootstrap_crps(
      evaluation$map_metrics,
      candidate_id = pair_indices[1L, index],
      reference_id = pair_indices[2L, index],
      replicates = prior_config$bootstrap_replicates,
      seed = prior_config$bootstrap_seed
    )
  })
)
numeric_best <- evaluation$summary[1L, , drop = FALSE]
best_id <- numeric_best$candidate_id[[1L]]
comparisons_to_best <- lapply(candidate_ids, function(candidate_id) {
  prior_games <- as.numeric(sub("nb_pace_prior", "", candidate_id))
  if (candidate_id == best_id) {
    return(data.frame(
      candidate_id = candidate_id,
      reference_id = best_id,
      prior_games = prior_games,
      mean_difference = 0,
      ci_lower = 0,
      ci_upper = 0,
      statistically_tied = TRUE,
      stringsAsFactors = FALSE
    ))
  }
  result <- paired_block_bootstrap_crps(
    evaluation$map_metrics,
    candidate_id = candidate_id,
    reference_id = best_id,
    replicates = prior_config$bootstrap_replicates,
    seed = prior_config$bootstrap_seed
  )
  data.frame(
    candidate_id = candidate_id,
    reference_id = best_id,
    prior_games = prior_games,
    mean_difference = result$mean_difference,
    ci_lower = result$ci_lower,
    ci_upper = result$ci_upper,
    statistically_tied =
      result$ci_lower <= 0 && result$ci_upper >= 0,
    stringsAsFactors = FALSE
  )
})
comparisons_to_best <- do.call(rbind, comparisons_to_best)
selected_prior <- max(
  comparisons_to_best$prior_games[
    comparisons_to_best$statistically_tied
  ]
)
selected <- evaluation$summary[
  evaluation$summary$prior_games == selected_prior,
  ,
  drop = FALSE
]
selected$numeric_best_prior <- numeric_best$prior_games[[1L]]
selected$selection_rule <- prior_config$tie_rule
selected$selection_status <- "selected_in_development"

metrics <- evaluation$map_metrics
metrics$sample_bin <- cut(
  metrics$minimum_raw_team_games,
  breaks = c(-Inf, 4, 9, 19, 49, Inf),
  labels = c("0-4", "5-9", "10-19", "20-49", "50+"),
  right = TRUE
)
sample_groups <- split(
  metrics,
  interaction(
    metrics$candidate_id,
    metrics$sample_bin,
    drop = TRUE
  )
)
by_sample <- do.call(rbind, lapply(sample_groups, function(group) {
  data.frame(
    candidate_id = group$candidate_id[[1L]],
    prior_games = group$prior_games[[1L]],
    sample_bin = as.character(group$sample_bin[[1L]]),
    maps = nrow(group),
    mean_crps = mean(group$crps),
    mean_log_score = mean(group$log_score),
    mean_error = mean(group$prediction_mean - group$observed),
    coverage_90 = mean(
      group$observed >= group$lower_90 &
        group$observed <= group$upper_90
    ),
    stringsAsFactors = FALSE
  )
}))
rownames(by_sample) <- NULL
sample_coverage <- unique(metrics[c(
  "gameid",
  "fold_id",
  "minimum_raw_team_games",
  "sample_bin"
)])
sample_coverage <- aggregate(
  gameid ~ sample_bin,
  sample_coverage,
  length
)
names(sample_coverage)[[2L]] <- "maps"
sample_coverage$share <- sample_coverage$maps /
  sum(sample_coverage$maps)

artifact_dir <- file.path(
  project_root,
  project_config$paths$artifacts,
  "evaluation"
)
report_dir <- file.path(
  project_root,
  project_config$paths$reports
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(
  metrics,
  file.path(artifact_dir, "team_prior_sensitivity_map_metrics.rds"),
  version = 3L
)
outputs <- list(
  team_prior_sensitivity_summary = evaluation$summary,
  team_prior_sensitivity_selected = selected,
  team_prior_sensitivity_by_fold = evaluation$by_fold,
  team_prior_sensitivity_by_league = evaluation$by_league,
  team_prior_sensitivity_by_sample = by_sample,
  team_prior_sensitivity_sample_coverage = sample_coverage,
  team_prior_sensitivity_coefficients = evaluation$coefficients,
  team_prior_sensitivity_bootstrap_pairwise = bootstrap_pairwise,
  team_prior_sensitivity_comparisons_to_best = comparisons_to_best
)
for (name in names(outputs)) {
  utils::write.csv(
    outputs[[name]],
    file.path(artifact_dir, paste0(name, ".csv")),
    row.names = FALSE
  )
}

html_escape <- function(value) {
  value <- gsub("&", "&amp;", as.character(value), fixed = TRUE)
  value <- gsub("<", "&lt;", value, fixed = TRUE)
  gsub(">", "&gt;", value, fixed = TRUE)
}
format_table <- function(data, digits = 4L) {
  formatted <- data
  numeric_columns <- vapply(formatted, is.numeric, logical(1L))
  formatted[numeric_columns] <- lapply(
    formatted[numeric_columns],
    function(values) format(round(values, digits), trim = TRUE)
  )
  header <- paste0(
    "<tr>",
    paste0("<th>", html_escape(names(formatted)), "</th>", collapse = ""),
    "</tr>"
  )
  rows <- apply(formatted, 1L, function(row) {
    paste0(
      "<tr>",
      paste0("<td>", html_escape(row), "</td>", collapse = ""),
      "</tr>"
    )
  })
  paste0(
    "<table><thead>",
    header,
    "</thead><tbody>",
    paste(rows, collapse = "\n"),
    "</tbody></table>"
  )
}
css <- paste(
  "body{font-family:Segoe UI,Arial,sans-serif;max-width:1200px;",
  "margin:40px auto;padding:0 24px;color:#1f2933;line-height:1.5}",
  "h1,h2{color:#17324d}table{border-collapse:collapse;width:100%;",
  "margin:16px 0 28px}th,td{border:1px solid #d9e2ec;padding:7px;",
  "text-align:right}th{background:#eaf2f8}th:first-child,td:first-child{",
  "text-align:left}",
  sep = ""
)
html <- c(
  "<!doctype html><html lang=\"pt-BR\"><head><meta charset=\"utf-8\">",
  "<title>Sensibilidade do shrinkage</title>",
  paste0("<style>", css, "</style></head><body>"),
  "<h1>Sensibilidade do shrinkage de equipe</h1>",
  "<p>Nove folds entre 2023 e 2025. Holdout de 2026 fechado.</p>",
  "<h2>Resumo</h2>",
  format_table(evaluation$summary),
  "<h2>Escolha</h2>",
  format_table(selected),
  "<h2>Comparações contra melhor CRPS</h2>",
  format_table(comparisons_to_best),
  "<h2>Resultados por experiência mínima</h2>",
  format_table(by_sample),
  "<h2>Cobertura de experiência</h2>",
  format_table(sample_coverage),
  "</body></html>"
)
writeLines(
  html,
  file.path(report_dir, "team-prior-sensitivity.html"),
  useBytes = TRUE
)

print(evaluation$summary, row.names = FALSE)
cat("\nEscolha pela regra pré-registrada:\n")
print(selected, row.names = FALSE)
cat("\nComparações contra melhor CRPS:\n")
print(comparisons_to_best, row.names = FALSE)
