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
sample_config <- evaluation_config$team_sample_threshold
prior_games <- evaluation_config$team_feature_research$
  default_prior_games
map_features <- readRDS(file.path(
  project_root,
  project_config$paths$interim,
  paste0("map_features_prior", prior_games, ".rds")
))
map_metrics <- readRDS(file.path(
  project_root,
  project_config$paths$artifacts,
  "evaluation",
  "simple_team_model_map_metrics.rds"
))
holdout_start <- as.POSIXct(
  as.character(evaluation_config$holdout$start),
  tz = evaluation_config$timezone
)
if (any(map_metrics$game_datetime >= holdout_start)) {
  stop("Métricas de amostra tocaram o holdout de 2026.", call. = FALSE)
}
modeling_game_ids <- unique(as.character(map_metrics$gameid))
map_features <- map_features[
  as.character(map_features$gameid) %in% modeling_game_ids,
  ,
  drop = FALSE
]
coverage <- derive_team_sample_coverage(
  map_features,
  metric_name = sample_config$effective_metric
)
effective <- evaluate_team_sample_thresholds(
  map_metrics = map_metrics,
  coverage = coverage,
  thresholds = as.numeric(unlist(
    sample_config$effective_game_thresholds
  )),
  signal_candidate_id = sample_config$signal_candidate_id,
  reference_candidate_id =
    sample_config$reference_candidate_id,
  sample_column = "minimum_effective_team_games",
  bootstrap_replicates = sample_config$bootstrap_replicates,
  bootstrap_seed = sample_config$bootstrap_seed
)
raw <- evaluate_team_sample_thresholds(
  map_metrics = map_metrics,
  coverage = coverage,
  thresholds = as.numeric(unlist(
    sample_config$raw_game_diagnostic_thresholds
  )),
  signal_candidate_id = sample_config$signal_candidate_id,
  reference_candidate_id =
    sample_config$reference_candidate_id,
  sample_column = "minimum_raw_team_games",
  bootstrap_replicates = sample_config$bootstrap_replicates,
  bootstrap_seed = sample_config$bootstrap_seed
)

selected_league <- if (nrow(effective$selected) > 0L) {
  effective$by_league[
    effective$by_league$threshold ==
      effective$selected$threshold[[1L]],
    ,
    drop = FALSE
  ]
} else {
  data.frame()
}
coverage_summary <- data.frame(
  maps = nrow(coverage),
  minimum_effective_median = stats::median(
    coverage$minimum_effective_team_games
  ),
  minimum_effective_q10 = stats::quantile(
    coverage$minimum_effective_team_games,
    0.10,
    names = FALSE
  ),
  minimum_effective_q90 = stats::quantile(
    coverage$minimum_effective_team_games,
    0.90,
    names = FALSE
  ),
  minimum_raw_median = stats::median(
    coverage$minimum_raw_team_games
  ),
  stringsAsFactors = FALSE
)

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
outputs <- list(
  team_sample_threshold_effective = effective$thresholds,
  team_sample_threshold_selected = effective$selected,
  team_sample_threshold_by_league = effective$by_league,
  team_sample_threshold_selected_league = selected_league,
  team_sample_threshold_raw_diagnostic = raw$thresholds,
  team_sample_threshold_coverage_summary = coverage_summary
)
for (name in names(outputs)) {
  utils::write.csv(
    outputs[[name]],
    file.path(artifact_dir, paste0(name, ".csv")),
    row.names = FALSE
  )
}
saveRDS(
  coverage,
  file.path(artifact_dir, "team_sample_coverage.rds"),
  version = 3L
)

html_escape <- function(value) {
  value <- gsub("&", "&amp;", as.character(value), fixed = TRUE)
  value <- gsub("<", "&lt;", value, fixed = TRUE)
  gsub(">", "&gt;", value, fixed = TRUE)
}
format_table <- function(data, digits = 4L) {
  if (nrow(data) == 0L) {
    return("<p>Nenhum limite cumpriu a regra pré-registrada.</p>")
  }
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
  "<title>Amostra mínima de equipe</title>",
  paste0("<style>", css, "</style></head><body>"),
  "<h1>Amostra mínima de equipe</h1>",
  "<p>Comparação pareada entre nb_pace e nb_league. Holdout 2026 fechado.</p>",
  "<h2>Limites por jogos efetivos</h2>",
  format_table(effective$thresholds),
  "<h2>Limite selecionado</h2>",
  format_table(effective$selected),
  "<h2>Ligas no limite selecionado</h2>",
  format_table(selected_league),
  "<h2>Diagnóstico por jogos brutos</h2>",
  format_table(raw$thresholds),
  "</body></html>"
)
writeLines(
  html,
  file.path(report_dir, "team-sample-threshold.html"),
  useBytes = TRUE
)

print(effective$thresholds, row.names = FALSE)
cat("\nLimite selecionado:\n")
if (nrow(effective$selected) > 0L) {
  print(effective$selected, row.names = FALSE)
} else {
  cat("Nenhum limite cumpriu a regra pré-registrada.\n")
}
