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
maps <- readRDS(file.path(
  project_root,
  config$paths$interim,
  "structural_map_features.rds"
))
raw_features <- c(
  "pace",
  "team_opponent_intensity",
  "matchup_intensity_imbalance",
  "duration_history",
  "duration_history_imbalance",
  "draft_frontline",
  "draft_burst",
  "draft_frontline_imbalance",
  "draft_engage",
  "draft_poke_siege",
  "draft_dive",
  "draft_protect",
  "draft_skirmish",
  "draft_scaling",
  "player_champion_conflict_delta"
)
development <- maps[
  maps$game_datetime < as.POSIXct(
    "2026-01-01",
    tz = "UTC"
  ) &
    stats::complete.cases(maps[raw_features]),
  ,
  drop = FALSE
]
pca <- fit_pca_transform(
  development,
  raw_features,
  retained_variance = 0.9
)
loadings <- data.frame(
  feature = rep(
    rownames(pca$model$rotation),
    pca$components
  ),
  component = rep(
    paste0("PC", seq_len(pca$components)),
    each = nrow(pca$model$rotation)
  ),
  loading = as.numeric(
    pca$model$rotation[
      ,
      seq_len(pca$components),
      drop = FALSE
    ]
  ),
  stringsAsFactors = FALSE
)
loadings$absolute_loading <- abs(loadings$loading)
explained <- pca$model$sdev^2 / sum(pca$model$sdev^2)
components <- data.frame(
  component = paste0("PC", seq_len(pca$components)),
  explained_variance = explained[seq_len(pca$components)],
  cumulative_variance = cumsum(
    explained[seq_len(pca$components)]
  ),
  stringsAsFactors = FALSE
)
fit <- readRDS(file.path(
  project_root,
  config$paths$artifacts,
  "bayesian",
  "secondary_2026",
  "fit.rds"
))
bayes_summary <- fit$summary(variables = c(
  "beta_intensity",
  "beta_duration",
  "sigma_attack",
  "sigma_exposure",
  "sigma_team_duration",
  "sigma_duration",
  "phi"
))
intensity_names <- c(
  "team_opponent_intensity",
  "matchup_intensity_imbalance",
  "draft_engage",
  "draft_dive",
  "draft_skirmish",
  "player_champion_conflict_delta"
)
duration_names <- c(
  "duration_history",
  "duration_history_imbalance",
  "draft_scaling",
  "draft_poke_siege",
  "draft_protect"
)
bayes_summary$feature <- NA_character_
for (index in seq_along(intensity_names)) {
  bayes_summary$feature[
    bayes_summary$variable ==
      paste0("beta_intensity[", index, "]")
  ] <- intensity_names[[index]]
}
for (index in seq_along(duration_names)) {
  bayes_summary$feature[
    bayes_summary$variable ==
      paste0("beta_duration[", index, "]")
  ] <- duration_names[[index]]
}
artifact_dir <- file.path(
  project_root,
  config$paths$artifacts,
  "evaluation"
)
utils::write.csv(
  loadings,
  file.path(artifact_dir, "pca_full_development_loadings.csv"),
  row.names = FALSE
)
utils::write.csv(
  components,
  file.path(artifact_dir, "pca_full_development_components.csv"),
  row.names = FALSE
)
utils::write.csv(
  bayes_summary,
  file.path(artifact_dir, "bayesian_parameter_summary.csv"),
  row.names = FALSE
)
print(components, row.names = FALSE)
for (component in components$component) {
  top <- loadings[
    loadings$component == component,
    ,
    drop = FALSE
  ]
  top <- top[
    order(top$absolute_loading, decreasing = TRUE),
    ,
    drop = FALSE
  ]
  cat("\n", component, ":\n", sep = "")
  print(utils::head(top, 5L), row.names = FALSE)
}
cat("\nParâmetros bayesianos:\n")
print(
  bayes_summary[
    ,
    c(
      "variable",
      "feature",
      "mean",
      "sd",
      "rhat",
      "ess_bulk"
    )
  ],
  row.names = FALSE
)
