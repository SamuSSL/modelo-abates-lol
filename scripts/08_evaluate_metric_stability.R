script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(
  file.path(project_root, "config", "default.yml")
)
evaluation_config <- yaml::read_yaml(
  file.path(project_root, "config", "evaluation.yml")
)
team_metrics_path <- file.path(
  project_root,
  config$paths$interim,
  "team_map_metrics.rds"
)
if (!file.exists(team_metrics_path)) {
  stop("Execute primeiro o script 07_build_team_metrics.R.", call. = FALSE)
}
team_metrics <- readRDS(team_metrics_path)
holdout_start <- as.POSIXct(
  as.character(evaluation_config$holdout$start),
  tz = evaluation_config$timezone
)
team_metrics <- team_metrics[
  team_metrics$game_datetime < holdout_start,
  ,
  drop = FALSE
]

metric_names <- c(
  "kills_per_minute",
  "deaths_per_minute",
  "combined_kills_per_minute",
  "game_length_minutes",
  "first_blood",
  "damage_per_minute",
  "damage_taken_per_minute",
  "kills_per_1000_damage",
  "assists_per_kill",
  "kills_at_10",
  "deaths_at_10",
  "kills_at_15",
  "deaths_at_15",
  "combined_kills_at_15",
  "gold_diff_at_15",
  "dragons",
  "barons",
  "heralds",
  "towers"
)
metric_names <- setdiff(
  metric_names,
  c("first_blood")
)
block_sizes <- c(5L, 10L, 20L)
studies <- lapply(block_sizes, function(block_size) {
  result <- evaluate_metric_stability(
    team_metrics,
    metric_names,
    block_size
  )
  result$summary$block_size <- block_size
  result$by_league$block_size <- block_size
  result
})
names(studies) <- paste0("block_", block_sizes)

summary <- do.call(rbind, lapply(studies, `[[`, "summary"))
by_league <- do.call(rbind, lapply(studies, `[[`, "by_league"))
rownames(summary) <- NULL
rownames(by_league) <- NULL
coverage <- data.frame(
  metric = metric_names,
  non_missing = vapply(
    metric_names,
    function(metric) sum(is.finite(team_metrics[[metric]])),
    integer(1L)
  ),
  total = nrow(team_metrics),
  stringsAsFactors = FALSE
)
coverage$coverage <- coverage$non_missing / coverage$total

summary$stability_rank <- ave(
  -summary$stability_spearman,
  summary$block_size,
  FUN = function(values) rank(values, na.last = "keep")
)
summary$future_intensity_rank <- ave(
  -abs(summary$future_intensity_spearman),
  summary$block_size,
  FUN = function(values) rank(values, na.last = "keep")
)
summary$combined_rank <- summary$stability_rank +
  summary$future_intensity_rank
summary <- summary[
  order(summary$block_size, summary$combined_rank),
  ,
  drop = FALSE
]

artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "research"
)
report_dir <- file.path(project_root, config$paths$reports)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)
utils::write.csv(
  summary,
  file.path(artifact_dir, "metric_stability_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  by_league,
  file.path(artifact_dir, "metric_stability_by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  coverage,
  file.path(artifact_dir, "metric_coverage.csv"),
  row.names = FALSE
)
saveRDS(
  studies,
  file.path(artifact_dir, "metric_stability_details.rds"),
  version = 3L
)

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
  "text-align:left}",
  sep = ""
)
html <- c(
  "<!doctype html><html lang=\"pt-BR\"><head><meta charset=\"utf-8\">",
  "<title>Estabilidade das métricas</title>",
  paste0("<style>", css, "</style></head><body>"),
  "<h1>Estabilidade das métricas subjacentes</h1>",
  "<p>Blocos passados são comparados somente com blocos futuros da mesma equipe. Holdout de 2026 excluído.</p>",
  "<h2>Resumo</h2>",
  format_table(summary),
  "<h2>Cobertura</h2>",
  format_table(coverage),
  "</body></html>"
)
writeLines(
  html,
  file.path(report_dir, "metric-stability.html"),
  useBytes = TRUE
)

cat("Top métricas em blocos de 10 jogos:\n")
print(
  head(summary[summary$block_size == 10L, ], 10L),
  row.names = FALSE
)
