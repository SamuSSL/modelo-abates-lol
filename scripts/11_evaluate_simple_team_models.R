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
model_config <- evaluation_config$simple_team_models
prior_games <- model_config$team_feature_prior_games
map_path <- file.path(
  project_root,
  project_config$paths$interim,
  paste0("map_features_prior", prior_games, ".rds")
)
if (!file.exists(map_path)) {
  stop("Execute primeiro o script 10_build_map_feature_table.R.", call. = FALSE)
}
maps <- derive_team_signal_features(readRDS(map_path))
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
candidates <- build_simple_model_candidates(evaluation_config)

evaluation <- evaluate_simple_team_models(
  maps = maps,
  folds = folds,
  candidates = candidates,
  holdout_start = parse_datetime(evaluation_config$holdout$start),
  training_start = parse_datetime(model_config$training_start),
  half_life_days = model_config$observation_half_life_days,
  prior_games = evaluation_config$baseline$league_shrinkage_prior_games,
  tail_tolerance = model_config$pmf_tail_tolerance
)

nested_references <- data.frame(
  candidate_id = c(
    "poisson_league",
    "nb_league",
    "nb_pace",
    "nb_attack_defense",
    "nb_pressure"
  ),
  reference_id = c(
    "empirical_league",
    "poisson_league",
    "nb_league",
    "nb_pace",
    "nb_attack_defense"
  ),
  stringsAsFactors = FALSE
)
bootstrap_nested <- do.call(
  rbind,
  lapply(seq_len(nrow(nested_references)), function(index) {
    paired_block_bootstrap_crps(
      evaluation$map_metrics,
      candidate_id = nested_references$candidate_id[[index]],
      reference_id = nested_references$reference_id[[index]],
      replicates = model_config$bootstrap_replicates,
      seed = model_config$bootstrap_seed
    )
  })
)
bootstrap_vs_baseline <- do.call(
  rbind,
  lapply(
    setdiff(candidates$candidate_id, "empirical_league"),
    function(candidate_id) {
      paired_block_bootstrap_crps(
        evaluation$map_metrics,
        candidate_id = candidate_id,
        reference_id = "empirical_league",
        replicates = model_config$bootstrap_replicates,
        seed = model_config$bootstrap_seed
      )
    }
  )
)
coefficient_summary <- aggregate(
  estimate ~ candidate_id + term,
  evaluation$coefficients,
  function(values) {
    c(
      mean = mean(values),
      minimum = min(values),
      maximum = max(values),
      positive_folds = mean(values > 0)
    )
  }
)
coefficient_summary <- data.frame(
  candidate_id = coefficient_summary$candidate_id,
  term = coefficient_summary$term,
  coefficient_summary$estimate,
  row.names = NULL,
  check.names = FALSE
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
saveRDS(
  evaluation$map_metrics,
  file.path(artifact_dir, "simple_team_model_map_metrics.rds"),
  version = 3L
)
outputs <- list(
  simple_team_model_summary = evaluation$summary,
  simple_team_model_by_fold = evaluation$by_fold,
  simple_team_model_by_league = evaluation$by_league,
  simple_team_model_coefficients = evaluation$coefficients,
  simple_team_model_coefficient_summary = coefficient_summary,
  simple_team_model_bootstrap_nested = bootstrap_nested,
  simple_team_model_bootstrap_vs_baseline = bootstrap_vs_baseline
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
  "<title>Modelos simples de equipe</title>",
  paste0("<style>", css, "</style></head><body>"),
  "<h1>Modelos probabilísticos simples de equipe</h1>",
  "<p>Nove folds entre 2023 e 2025. Holdout de 2026 fechado.</p>",
  "<h2>Resumo</h2>",
  format_table(evaluation$summary),
  "<h2>Ablações aninhadas</h2>",
  format_table(bootstrap_nested),
  "<h2>Comparações contra baseline empírico</h2>",
  format_table(bootstrap_vs_baseline),
  "<h2>Coeficientes padronizados</h2>",
  format_table(coefficient_summary),
  "</body></html>"
)
writeLines(
  html,
  file.path(report_dir, "simple-team-models.html"),
  useBytes = TRUE
)

print(evaluation$summary, row.names = FALSE)
cat("\nAblações aninhadas:\n")
print(bootstrap_nested, row.names = FALSE)
