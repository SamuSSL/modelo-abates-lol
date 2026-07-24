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

games <- readRDS(
  file.path(
    project_root,
    project_config$paths$interim,
    "canonical_games.rds"
  )
)
parse_datetime <- function(value) {
  as.POSIXct(as.character(value), tz = evaluation_config$timezone)
}
sensitivity_config <- evaluation_config$recency_sensitivity
folds <- do.call(
  rbind,
  lapply(sensitivity_config$folds, function(fold) {
    data.frame(
      fold_id = as.character(fold$id),
      validation_start = parse_datetime(fold$validation_start),
      validation_end = parse_datetime(fold$validation_end),
      stringsAsFactors = FALSE
    )
  })
)
rownames(folds) <- NULL
half_lives <- as.numeric(
  unlist(sensitivity_config$exponential_half_life_days)
)
candidates <- data.frame(
  candidate_id = paste0("exponential_hl", half_lives, "d"),
  window_type = "exponential",
  window_value = half_lives,
  stringsAsFactors = FALSE
)
holdout_start <- parse_datetime(evaluation_config$holdout$start)

evaluation <- evaluate_window_candidates(
  games,
  folds,
  candidates,
  holdout_start,
  prior_games = evaluation_config$baseline$league_shrinkage_prior_games
)
eligible <- evaluation$summary[
  evaluation$summary$eligible_all_folds &
    evaluation$summary$leagues_covered == 7L,
  ,
  drop = FALSE
]
if (nrow(eligible) == 0L) {
  stop(
    "Nenhuma meia-vida completou os nove folds e sete ligas.",
    call. = FALSE
  )
}
selected <- eligible[1L, , drop = FALSE]
reference_id <- if (
  selected$candidate_id[[1L]] == "exponential_hl90d"
) {
  eligible$candidate_id[[2L]]
} else {
  "exponential_hl90d"
}
bootstrap <- paired_block_bootstrap_crps(
  evaluation$map_metrics,
  candidate_id = selected$candidate_id[[1L]],
  reference_id = reference_id,
  replicates = 5000L,
  seed = project_config$project$seed
)
pairwise_vs_90 <- do.call(
  rbind,
  lapply(candidates$candidate_id, function(candidate_id) {
    paired_block_bootstrap_crps(
      evaluation$map_metrics,
      candidate_id = candidate_id,
      reference_id = "exponential_hl90d",
      replicates = 5000L,
      seed = project_config$project$seed
    )
  })
)
selected$comparison_reference <- reference_id
selected$bootstrap_ci_lower <- bootstrap$ci_lower
selected$bootstrap_ci_upper <- bootstrap$ci_upper
selected$selection_status <- if (bootstrap$ci_upper < 0) {
  "supported_in_expanded_development"
} else {
  "gain_not_conclusive"
}

metrics <- evaluation$map_metrics
metrics$validation_year <- as.integer(substr(metrics$fold_id, 1L, 4L))
by_year <- aggregate(
  cbind(crps, log_score) ~ candidate_id + validation_year,
  metrics,
  mean
)
by_fold <- aggregate(
  cbind(crps, log_score) ~ candidate_id + fold_id,
  metrics,
  mean
)
by_league <- aggregate(
  cbind(crps, log_score) ~ candidate_id + league_canonical,
  metrics,
  mean
)
effective_sample <- aggregate(
  cbind(effective_training_games, effective_league_games) ~
    candidate_id + fold_id + league_canonical,
  metrics,
  mean
)

patch_performance <- aggregate(
  cbind(crps, log_score) ~ candidate_id + patch,
  metrics,
  mean
)
patch_counts <- aggregate(
  rep(1L, nrow(metrics)),
  by = list(
    candidate_id = metrics$candidate_id,
    patch = metrics$patch
  ),
  FUN = sum
)
names(patch_counts)[[3L]] <- "maps"
patch_performance <- merge(
  patch_performance,
  patch_counts,
  by = c("candidate_id", "patch"),
  all.x = TRUE,
  sort = FALSE
)

development <- games[
  games$competition_role == "target" &
    games$target_valid &
    games$series_eligible &
    games$game_datetime < holdout_start,
  ,
  drop = FALSE
]
development$season <- as.integer(
  format(development$game_datetime, "%Y", tz = "UTC")
)
patch_target <- aggregate(
  development$total_kills_game,
  by = list(
    league_canonical = development$league_canonical,
    season = development$season,
    patch = development$patch
  ),
  FUN = function(values) {
    c(
      maps = length(values),
      mean_kills = mean(values),
      sd_kills = stats::sd(values)
    )
  }
)
patch_target <- data.frame(
  league_canonical = patch_target$league_canonical,
  season = patch_target$season,
  patch = patch_target$patch,
  patch_target$x,
  row.names = NULL,
  check.names = FALSE
)
patch_target$patch_numeric <- suppressWarnings(
  as.numeric(patch_target$patch)
)
patch_target <- patch_target[
  patch_target$maps >= 10L &
    !is.na(patch_target$patch_numeric),
  ,
  drop = FALSE
]
patch_groups <- split(
  patch_target,
  interaction(
    patch_target$league_canonical,
    patch_target$season,
    drop = TRUE
  )
)
patch_shifts <- lapply(patch_groups, function(data) {
  data <- data[order(data$patch_numeric), , drop = FALSE]
  if (nrow(data) < 2L) {
    return(NULL)
  }
  data.frame(
    league_canonical = data$league_canonical[-1L],
    season = data$season[-1L],
    previous_patch = data$patch[-nrow(data)],
    patch = data$patch[-1L],
    previous_maps = data$maps[-nrow(data)],
    maps = data$maps[-1L],
    mean_kills_change = data$mean_kills[-1L] -
      data$mean_kills[-nrow(data)],
    absolute_mean_kills_change = abs(
      data$mean_kills[-1L] - data$mean_kills[-nrow(data)]
    ),
    stringsAsFactors = FALSE
  )
})
patch_shifts <- Filter(Negate(is.null), patch_shifts)
patch_shifts <- do.call(rbind, patch_shifts)
rownames(patch_shifts) <- NULL
patch_shift_summary <- data.frame(
  transitions = nrow(patch_shifts),
  median_absolute_change = stats::median(
    patch_shifts$absolute_mean_kills_change
  ),
  mean_absolute_change = mean(
    patch_shifts$absolute_mean_kills_change
  ),
  q90_absolute_change = stats::quantile(
    patch_shifts$absolute_mean_kills_change,
    0.90,
    names = FALSE
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

saveRDS(
  metrics,
  file.path(artifact_dir, "recency_sensitivity_map_metrics.rds"),
  version = 3L
)
outputs <- list(
  recency_sensitivity_summary = evaluation$summary,
  recency_sensitivity_selected = selected,
  recency_sensitivity_bootstrap = bootstrap,
  recency_pairwise_vs_90 = pairwise_vs_90,
  recency_sensitivity_by_year = by_year,
  recency_sensitivity_by_fold = by_fold,
  recency_sensitivity_by_league = by_league,
  recency_effective_sample = effective_sample,
  recency_performance_by_patch = patch_performance,
  patch_target_summary = patch_target,
  patch_transitions = patch_shifts,
  patch_transition_summary = patch_shift_summary
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
  value <- gsub(">", "&gt;", value, fixed = TRUE)
  value
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
  "text-align:left}.warning{background:#fff4d6;padding:12px 16px;",
  "border-left:4px solid #c58b00}",
  sep = ""
)
html <- c(
  "<!doctype html><html lang=\"pt-BR\"><head><meta charset=\"utf-8\">",
  "<title>Sensibilidade de recência</title>",
  paste0("<style>", css, "</style></head><body>"),
  "<h1>Sensibilidade de recência e patches</h1>",
  "<p>Nove folds entre 2023 e 2025. O holdout de 2026 permaneceu fechado.</p>",
  "<h2>Comparação das meias-vidas</h2>",
  format_table(evaluation$summary),
  "<h2>Recomendação ampliada</h2>",
  format_table(selected),
  "<h2>Bootstrap temporal pareado</h2>",
  format_table(bootstrap),
  "<h2>Todas as comparações contra 90 dias</h2>",
  format_table(pairwise_vs_90),
  "<h2>Resultados por ano</h2>",
  format_table(by_year),
  "<h2>Diagnóstico de transições de patch</h2>",
  format_table(patch_shift_summary),
  "<div class=\"warning\">Patch foi usado somente para diagnóstico e não como feature.</div>",
  "</body></html>"
)
writeLines(
  html,
  file.path(report_dir, "recency-sensitivity.html"),
  useBytes = TRUE
)

print(evaluation$summary, row.names = FALSE)
cat("\nRecomendação ampliada:\n")
print(selected, row.names = FALSE)
cat("\nBootstrap pareado:\n")
print(bootstrap, row.names = FALSE)
cat("\nTransições de patch:\n")
print(patch_shift_summary, row.names = FALSE)
