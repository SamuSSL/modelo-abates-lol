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

games_path <- file.path(
  project_root,
  project_config$paths$interim,
  "canonical_games.rds"
)
if (!file.exists(games_path)) {
  stop(
    "Execute primeiro o script 03_build_canonical_games.R.",
    call. = FALSE
  )
}

parse_datetime <- function(value) {
  as.POSIXct(as.character(value), tz = evaluation_config$timezone)
}

folds <- do.call(
  rbind,
  lapply(evaluation_config$development_folds, function(fold) {
    data.frame(
      fold_id = as.character(fold$id),
      validation_start = parse_datetime(fold$validation_start),
      validation_end = parse_datetime(fold$validation_end),
      stringsAsFactors = FALSE
    )
  })
)
rownames(folds) <- NULL
holdout_start <- parse_datetime(evaluation_config$holdout$start)
candidates <- build_window_candidate_grid(evaluation_config)
games <- readRDS(games_path)

evaluation <- evaluate_window_candidates(
  games,
  folds,
  candidates,
  holdout_start,
  prior_games = evaluation_config$baseline$league_shrinkage_prior_games
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
development$month <- format(
  development$game_datetime,
  "%Y-%m",
  tz = "UTC"
)

summarize_group <- function(data, groups) {
  result <- aggregate(
    list(
      games = rep(1L, nrow(data)),
      mean_kills = data$total_kills_game,
      mean_duration_minutes = data$game_length_seconds / 60
    ),
    by = data[groups],
    FUN = mean
  )
  counts <- aggregate(
    rep(1L, nrow(data)),
    by = data[groups],
    FUN = sum
  )
  result$games <- counts$x
  result
}

league_summary <- summarize_group(
  development,
  c("league_canonical")
)
league_distribution <- aggregate(
  development$total_kills_game,
  by = list(league_canonical = development$league_canonical),
  FUN = function(values) {
    c(
      sd = stats::sd(values),
      median = stats::median(values),
      q10 = stats::quantile(values, 0.10, names = FALSE),
      q90 = stats::quantile(values, 0.90, names = FALSE),
      variance_to_mean = stats::var(values) / mean(values)
    )
  }
)
league_distribution <- data.frame(
  league_canonical = league_distribution$league_canonical,
  league_distribution$x,
  row.names = NULL,
  check.names = FALSE
)
league_summary <- merge(
  league_summary,
  league_distribution,
  by = "league_canonical",
  sort = TRUE
)
season_summary <- summarize_group(development, c("season"))
monthly_summary <- summarize_group(
  development,
  c("month", "league_canonical")
)
fold_coverage <- aggregate(
  rep(1L, nrow(evaluation$map_metrics)),
  by = list(
    candidate_id = evaluation$map_metrics$candidate_id,
    fold_id = evaluation$map_metrics$fold_id,
    league_canonical = evaluation$map_metrics$league_canonical
  ),
  FUN = sum
)
names(fold_coverage)[[4L]] <- "maps"

association_ratio <- function(values, group) {
  valid <- !is.na(values) & !is.na(group)
  values <- values[valid]
  group <- group[valid]
  total <- sum((values - mean(values))^2)
  if (length(values) == 0L || total == 0) {
    return(NA_real_)
  }
  group_means <- tapply(values, group, mean)
  group_counts <- table(group)
  between <- sum(group_counts * (group_means - mean(values))^2)
  sqrt(between / total)
}

associations <- data.frame(
  variable = c(
    "game_length_seconds",
    "league_canonical",
    "season",
    "patch",
    "playoffs"
  ),
  treatment = c(
    "challenger_only",
    "modeling",
    "temporal_adapter",
    "diagnostic_only",
    "diagnostic_only"
  ),
  measure = c(
    "spearman",
    "correlation_ratio",
    "correlation_ratio",
    "correlation_ratio",
    "correlation_ratio"
  ),
  association = c(
    stats::cor(
      development$total_kills_game,
      development$game_length_seconds,
      method = "spearman",
      use = "complete.obs"
    ),
    association_ratio(
      development$total_kills_game,
      development$league_canonical
    ),
    association_ratio(
      development$total_kills_game,
      development$season
    ),
    association_ratio(
      development$total_kills_game,
      development$patch
    ),
    association_ratio(
      development$total_kills_game,
      development$playoffs
    )
  ),
  stringsAsFactors = FALSE
)

eligible_summary <- evaluation$summary[
  evaluation$summary$eligible_all_folds &
    evaluation$summary$leagues_covered == length(canonical_target_leagues()),
  ,
  drop = FALSE
]
if (nrow(eligible_summary) == 0L) {
  stop("Nenhuma janela completou todos os folds e ligas.", call. = FALSE)
}
selected_window <- eligible_summary[1L, , drop = FALSE]
reference_id <- if (
  selected_window$candidate_id[[1L]] == "fixed_12m"
) {
  eligible_summary$candidate_id[[2L]]
} else {
  "fixed_12m"
}
bootstrap_comparison <- paired_block_bootstrap_crps(
  evaluation$map_metrics,
  candidate_id = selected_window$candidate_id[[1L]],
  reference_id = reference_id,
  replicates = 2000L,
  seed = project_config$project$seed
)

candidate_pair <- evaluation$map_metrics[
  evaluation$map_metrics$candidate_id %in%
    c(selected_window$candidate_id[[1L]], reference_id),
  ,
  drop = FALSE
]
fold_pair <- aggregate(
  crps ~ candidate_id + fold_id,
  candidate_pair,
  mean
)
league_pair <- aggregate(
  crps ~ candidate_id + league_canonical,
  candidate_pair,
  mean
)
fold_stability <- reshape(
  fold_pair,
  idvar = "fold_id",
  timevar = "candidate_id",
  direction = "wide"
)
league_stability <- reshape(
  league_pair,
  idvar = "league_canonical",
  timevar = "candidate_id",
  direction = "wide"
)
candidate_column <- paste0(
  "crps.",
  selected_window$candidate_id[[1L]]
)
reference_column <- paste0("crps.", reference_id)
fold_stability$crps_difference <- fold_stability[[candidate_column]] -
  fold_stability[[reference_column]]
league_stability$crps_difference <- league_stability[[candidate_column]] -
  league_stability[[reference_column]]
selection_status <- if (
  bootstrap_comparison$ci_upper[[1L]] < 0 &&
    all(fold_stability$crps_difference < 0)
) {
  "supported_in_development"
} else {
  "provisional_gain_not_conclusive"
}
selected_window$selection_status <- selection_status

artifact_dir <- file.path(
  project_root,
  project_config$paths$artifacts,
  "evaluation"
)
chart_dir <- file.path(
  project_root,
  project_config$paths$artifacts,
  "eda"
)
report_dir <- file.path(
  project_root,
  project_config$paths$reports
)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(chart_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(report_dir, recursive = TRUE, showWarnings = FALSE)

saveRDS(
  evaluation$map_metrics,
  file.path(artifact_dir, "window_map_metrics.rds"),
  version = 3L
)
utils::write.csv(
  evaluation$summary,
  file.path(artifact_dir, "window_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  selected_window,
  file.path(artifact_dir, "selected_window.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap_comparison,
  file.path(artifact_dir, "window_bootstrap_comparison.csv"),
  row.names = FALSE
)
utils::write.csv(
  fold_stability,
  file.path(artifact_dir, "window_stability_by_fold.csv"),
  row.names = FALSE
)
utils::write.csv(
  league_stability,
  file.path(artifact_dir, "window_stability_by_league.csv"),
  row.names = FALSE
)
utils::write.csv(
  fold_coverage,
  file.path(artifact_dir, "fold_coverage.csv"),
  row.names = FALSE
)
utils::write.csv(
  league_summary,
  file.path(artifact_dir, "eda_league_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  season_summary,
  file.path(artifact_dir, "eda_season_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  monthly_summary,
  file.path(artifact_dir, "eda_monthly_summary.csv"),
  row.names = FALSE
)
utils::write.csv(
  associations,
  file.path(artifact_dir, "feature_associations.csv"),
  row.names = FALSE
)

grDevices::png(
  file.path(chart_dir, "kills-distribution.png"),
  width = 1200,
  height = 700,
  res = 120
)
graphics::hist(
  development$total_kills_game,
  breaks = seq(-0.5, max(development$total_kills_game) + 1.5, by = 2),
  main = "Distribuição de total de kills no desenvolvimento",
  xlab = "Total de kills por mapa",
  ylab = "Mapas",
  col = "#3366A6",
  border = "white"
)
grDevices::dev.off()

grDevices::png(
  file.path(chart_dir, "kills-by-league.png"),
  width = 1200,
  height = 700,
  res = 120
)
graphics::boxplot(
  total_kills_game ~ league_canonical,
  data = development,
  main = "Total de kills por liga",
  xlab = "Liga",
  ylab = "Total de kills",
  col = "#8BB8E8",
  outline = FALSE
)
grDevices::dev.off()

month_levels <- sort(unique(monthly_summary$month))
league_levels <- sort(unique(monthly_summary$league_canonical))
league_colors <- grDevices::hcl.colors(
  length(league_levels),
  palette = "Dark 3"
)
grDevices::png(
  file.path(chart_dir, "monthly-drift.png"),
  width = 1400,
  height = 700,
  res = 120
)
graphics::par(mar = c(7, 4, 4, 2) + 0.1)
graphics::plot(
  seq_along(month_levels),
  rep(NA_real_, length(month_levels)),
  type = "n",
  ylim = range(monthly_summary$mean_kills),
  xaxt = "n",
  main = "Média mensal de kills por liga antes do holdout",
  xlab = "Mês",
  ylab = "Média de kills"
)
for (index in seq_along(league_levels)) {
  league <- league_levels[[index]]
  rows <- monthly_summary[
    monthly_summary$league_canonical == league,
    ,
    drop = FALSE
  ]
  graphics::lines(
    match(rows$month, month_levels),
    rows$mean_kills,
    type = "b",
    pch = 16,
    cex = 0.6,
    col = league_colors[[index]]
  )
}
axis_positions <- unique(round(seq(
  1,
  length(month_levels),
  length.out = min(12L, length(month_levels))
)))
graphics::axis(
  1,
  at = axis_positions,
  labels = month_levels[axis_positions],
  las = 2,
  cex.axis = 0.8
)
graphics::legend(
  "topleft",
  legend = league_levels,
  col = league_colors,
  lty = 1,
  pch = 16,
  cex = 0.8,
  ncol = 2,
  bty = "n"
)
grDevices::dev.off()

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

report_css <- paste(
  "body{font-family:Segoe UI,Arial,sans-serif;max-width:1200px;",
  "margin:40px auto;padding:0 24px;color:#1f2933;line-height:1.5}",
  "h1,h2{color:#17324d}table{border-collapse:collapse;width:100%;",
  "margin:16px 0 28px}th,td{border:1px solid #d9e2ec;padding:7px;",
  "text-align:right}th{background:#eaf2f8}th:first-child,td:first-child{",
  "text-align:left}.warning{background:#fff4d6;padding:12px 16px;",
  "border-left:4px solid #c58b00}img{max-width:100%;height:auto}",
  sep = ""
)

eda_html <- c(
  "<!doctype html><html lang=\"pt-BR\"><head><meta charset=\"utf-8\">",
  "<title>EDA do modelo de kills</title>",
  paste0("<style>", report_css, "</style></head><body>"),
  "<h1>EDA do modelo probabilístico de kills</h1>",
  paste0(
    "<p>Dados de desenvolvimento: ",
    nrow(development),
    " mapas das sete ligas. Holdout selado a partir de ",
    format(holdout_start, "%Y-%m-%d", tz = "UTC"),
    ".</p>"
  ),
  "<div class=\"warning\">Nenhum target de 2026 foi usado na seleção da janela.</div>",
  "<h2>Distribuição</h2>",
  "<img src=\"../artifacts/eda/kills-distribution.png\" alt=\"Distribuição de kills\">",
  "<img src=\"../artifacts/eda/kills-by-league.png\" alt=\"Kills por liga\">",
  "<h2>Resumo por liga</h2>",
  format_table(league_summary),
  "<h2>Drift temporal</h2>",
  "<img src=\"../artifacts/eda/monthly-drift.png\" alt=\"Drift mensal\">",
  "<h2>Comparação das janelas</h2>",
  format_table(evaluation$summary),
  "<h2>Janela selecionada no desenvolvimento</h2>",
  format_table(selected_window),
  "<h2>Incerteza pareada contra a referência</h2>",
  format_table(bootstrap_comparison),
  "<h2>Estabilidade por fold</h2>",
  format_table(fold_stability),
  "<h2>Estabilidade por liga</h2>",
  format_table(league_stability),
  "<p>A recomendação permanece sujeita à aprovação dos guardrails de calibração. O holdout continua fechado.</p>",
  "</body></html>"
)
writeLines(
  eda_html,
  file.path(report_dir, "eda.html"),
  useBytes = TRUE
)

association_html <- c(
  "<!doctype html><html lang=\"pt-BR\"><head><meta charset=\"utf-8\">",
  "<title>Associações de features</title>",
  paste0("<style>", report_css, "</style></head><body>"),
  "<h1>Associações de features</h1>",
  "<p>As associações são descritivas e usam somente o período anterior ao holdout. Patch e playoffs permanecem proibidos como features.</p>",
  format_table(associations),
  "</body></html>"
)
writeLines(
  association_html,
  file.path(report_dir, "feature-association.html"),
  useBytes = TRUE
)

print(evaluation$summary, row.names = FALSE)
cat("\nJanela selecionada no desenvolvimento:\n")
print(selected_window, row.names = FALSE)
cat("\nBootstrap temporal pareado:\n")
print(bootstrap_comparison, row.names = FALSE)
