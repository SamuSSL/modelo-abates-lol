script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

output_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "kill-phenomenon-duration-intensity"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

maps <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "premap_ratio_map_features_t15.rds"
))
maps$game_datetime <- as.POSIXct(maps$game_datetime, tz = "UTC")
maps <- maps[
  maps$competition_role == "target" &
    is.finite(maps$total_kills_game) &
    maps$total_kills_game > 0 &
    is.finite(maps$game_length_minutes) &
    maps$game_length_minutes > 0,
  ,
  drop = FALSE
]
maps <- maps[!duplicated(maps$gameid), , drop = FALSE]
maps$observed_duration <- as.numeric(maps$game_length_minutes)
maps$observed_total <- as.numeric(maps$total_kills_game)
maps$observed_intensity <- maps$observed_total / maps$observed_duration
maps$log_total <- log(maps$observed_total)
maps$log_duration <- log(maps$observed_duration)
maps$log_intensity <- log(maps$observed_intensity)
maps$calendar_year <- format(maps$game_datetime, "%Y")

variance_decomposition <- function(frame, scope, group) {
  variance_total <- stats::var(frame$log_total)
  variance_duration <- stats::var(frame$log_duration)
  variance_intensity <- stats::var(frame$log_intensity)
  covariance <- stats::cov(frame$log_duration, frame$log_intensity)
  data.frame(
    scope = scope,
    group = group,
    maps = nrow(frame),
    mean_total = mean(frame$observed_total),
    mean_duration = mean(frame$observed_duration),
    mean_intensity = mean(frame$observed_intensity),
    duration_intensity_correlation = stats::cor(
      frame$log_duration,
      frame$log_intensity
    ),
    log_total_variance = variance_total,
    duration_variance_component = variance_duration,
    intensity_variance_component = variance_intensity,
    covariance_component = 2 * covariance,
    duration_shapley_share = (variance_duration + covariance) / variance_total,
    intensity_shapley_share = (variance_intensity + covariance) / variance_total,
    stringsAsFactors = FALSE
  )
}

variance_rows <- list(
  overall = variance_decomposition(maps, "overall", "all")
)
for (league in sort(unique(maps$league_canonical))) {
  rows <- maps[maps$league_canonical == league, , drop = FALSE]
  if (nrow(rows) >= 30L) {
    variance_rows[[paste0("league_", league)]] <- variance_decomposition(
      rows,
      "league",
      league
    )
  }
}
for (year in sort(unique(maps$calendar_year))) {
  rows <- maps[maps$calendar_year == year, , drop = FALSE]
  if (nrow(rows) >= 30L) {
    variance_rows[[paste0("year_", year)]] <- variance_decomposition(
      rows,
      "year",
      year
    )
  }
}
variance_summary <- do.call(rbind, variance_rows)
rownames(variance_summary) <- NULL

team_history <- readRDS(file.path(
  project_root,
  "data",
  "interim",
  "team_map_metrics.rds"
))
team_history <- team_history[
  team_history$competition_role == "target" &
    team_history$gameid %in% maps$gameid,
  ,
  drop = FALSE
]
winner <- team_history[team_history$result == 1, , drop = FALSE]
loser <- team_history[team_history$result == 0, , drop = FALSE]
winner <- winner[!duplicated(winner$gameid), , drop = FALSE]
loser <- loser[!duplicated(loser$gameid), , drop = FALSE]
outcome <- merge(
  winner[, c(
    "gameid", "team_kills", "kills_at_15", "deaths_at_15",
    "gold_diff_at_15", "dragons", "barons", "heralds", "towers"
  )],
  loser[, c("gameid", "team_kills", "kills_at_15", "gold_diff_at_15")],
  by = "gameid",
  suffixes = c("_winner", "_loser")
)
outcome$early_total <- outcome$kills_at_15_winner + outcome$kills_at_15_loser
outcome$winner_ahead_at_15 <- outcome$gold_diff_at_15_winner > 500
outcome$winner_behind_at_15 <- outcome$gold_diff_at_15_winner < -500
outcome$gold_gap_15 <- abs(outcome$gold_diff_at_15_winner)
outcome$winner_kill_share <- outcome$team_kills_winner /
  pmax(outcome$team_kills_winner + outcome$team_kills_loser, 1)

phenomenon <- merge(
  maps[, c(
    "gameid", "series_id", "game_datetime", "league_canonical",
    "observed_total", "observed_duration", "observed_intensity"
  )],
  outcome,
  by = "gameid",
  all.x = TRUE,
  sort = FALSE
)
phenomenon$post_15_kills <- pmax(
  phenomenon$observed_total - phenomenon$early_total,
  0
)
phenomenon$post_15_minutes <- pmax(phenomenon$observed_duration - 15, 1)
phenomenon$post_15_intensity <- phenomenon$post_15_kills /
  phenomenon$post_15_minutes

early_cuts <- stats::quantile(
  phenomenon$early_total,
  c(0.25, 0.75),
  na.rm = TRUE,
  names = FALSE,
  type = 8
)
gold_cuts <- stats::quantile(
  phenomenon$gold_gap_15,
  c(0.5, 0.75),
  na.rm = TRUE,
  names = FALSE,
  type = 8
)
phenomenon$early_fight_band <- cut(
  phenomenon$early_total,
  breaks = c(-Inf, early_cuts, Inf),
  labels = c("low", "medium", "high"),
  include.lowest = TRUE
)
phenomenon$gold_gap_band <- cut(
  phenomenon$gold_gap_15,
  breaks = c(-Inf, gold_cuts, Inf),
  labels = c("close", "clear", "stomp"),
  include.lowest = TRUE
)
phenomenon$winner_state_15 <- ifelse(
  phenomenon$winner_ahead_at_15,
  "winner_ahead",
  ifelse(
    phenomenon$winner_behind_at_15,
    "winner_behind_comeback",
    "near_even"
  )
)

summarize_mechanism <- function(frame, scope, group) {
  data.frame(
    scope = scope,
    group = group,
    maps = nrow(frame),
    mean_total = mean(frame$observed_total, na.rm = TRUE),
    mean_duration = mean(frame$observed_duration, na.rm = TRUE),
    mean_intensity = mean(frame$observed_intensity, na.rm = TRUE),
    mean_early_total = mean(frame$early_total, na.rm = TRUE),
    mean_post_15_intensity = mean(frame$post_15_intensity, na.rm = TRUE),
    mean_winner_kills = mean(frame$team_kills_winner, na.rm = TRUE),
    mean_loser_kills = mean(frame$team_kills_loser, na.rm = TRUE),
    mean_winner_kill_share = mean(frame$winner_kill_share, na.rm = TRUE),
    comeback_rate = mean(frame$winner_behind_at_15, na.rm = TRUE),
    stringsAsFactors = FALSE
  )
}

mechanism_rows <- list(
  overall = summarize_mechanism(phenomenon, "overall", "all")
)
for (field in c("early_fight_band", "gold_gap_band", "winner_state_15")) {
  for (level in unique(as.character(phenomenon[[field]]))) {
    if (is.na(level)) {
      next
    }
    rows <- phenomenon[
      !is.na(phenomenon[[field]]) &
        as.character(phenomenon[[field]]) == level,
      ,
      drop = FALSE
    ]
    mechanism_rows[[paste(field, level, sep = "__")]] <- summarize_mechanism(
      rows,
      field,
      level
    )
  }
}
mechanism_summary <- do.call(rbind, mechanism_rows)
rownames(mechanism_summary) <- NULL

atlas <- readRDS(file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "structural-pinnacle-error-atlas",
  "map-error-atlas.rds"
))
atlas$game_datetime <- as.POSIXct(atlas$game_datetime, tz = "UTC")
map_actual <- maps[match(atlas$gameid, maps$gameid), c(
  "gameid", "observed_duration", "observed_total", "observed_intensity"
)]
if (anyNA(map_actual$gameid)) {
  stop("Duracao observada ausente em parte do atlas.", call. = FALSE)
}
model_error <- cbind(
  atlas,
  map_actual[, c("observed_duration", "observed_intensity")]
)
model_error$predicted_duration <- as.numeric(
  model_error$structural_duration_mean
)
model_error$predicted_intensity <- as.numeric(
  model_error$structural_intensity_mean
)
model_error$component_product_mean <- model_error$predicted_duration *
  model_error$predicted_intensity
model_error$product_gap <- model_error$structural_mean -
  model_error$component_product_mean
model_error$duration_log_residual <- log(
  model_error$observed_duration / model_error$predicted_duration
)
model_error$intensity_log_residual <- log(
  model_error$observed_intensity / model_error$predicted_intensity
)
model_error$total_log_residual <- log(
  model_error$observed_total / model_error$component_product_mean
)
model_error$duration_contribution <- (
  model_error$observed_duration - model_error$predicted_duration
) * (
  model_error$predicted_intensity + model_error$observed_intensity
) / 2
model_error$intensity_contribution <- (
  model_error$observed_intensity - model_error$predicted_intensity
) * (
  model_error$predicted_duration + model_error$observed_duration
) / 2
model_error$decomposition_gap <- (
  model_error$duration_contribution + model_error$intensity_contribution
) - (
  model_error$observed_total - model_error$component_product_mean
)
model_error$dominant_error_driver <- ifelse(
  abs(model_error$duration_contribution) >=
    abs(model_error$intensity_contribution),
  "duration",
  "intensity"
)
model_error$duration_oracle_mean <- model_error$observed_duration *
  model_error$predicted_intensity
model_error$intensity_oracle_mean <- model_error$predicted_duration *
  model_error$observed_intensity
model_error$both_oracle_mean <- model_error$observed_total

error_metrics <- function(observed, predicted, model_id) {
  data.frame(
    model_id = model_id,
    maps = length(observed),
    mean_error = mean(observed - predicted),
    mean_absolute_error = mean(abs(observed - predicted)),
    root_mean_squared_error = sqrt(mean((observed - predicted)^2)),
    stringsAsFactors = FALSE
  )
}
oracle_summary <- rbind(
  error_metrics(
    model_error$observed_total,
    model_error$component_product_mean,
    "structural_components"
  ),
  error_metrics(
    model_error$observed_total,
    model_error$duration_oracle_mean,
    "oracle_duration"
  ),
  error_metrics(
    model_error$observed_total,
    model_error$intensity_oracle_mean,
    "oracle_intensity"
  ),
  error_metrics(
    model_error$observed_total,
    model_error$both_oracle_mean,
    "oracle_both"
  )
)

summarize_error <- function(frame, scope, group) {
  data.frame(
    scope = scope,
    group = group,
    maps = nrow(frame),
    mean_total_error = mean(
      frame$observed_total - frame$component_product_mean
    ),
    mean_duration_log_residual = mean(frame$duration_log_residual),
    mean_intensity_log_residual = mean(frame$intensity_log_residual),
    mean_absolute_duration_contribution = mean(
      abs(frame$duration_contribution)
    ),
    mean_absolute_intensity_contribution = mean(
      abs(frame$intensity_contribution)
    ),
    intensity_dominant_rate = mean(
      frame$dominant_error_driver == "intensity"
    ),
    structural_crps = mean(frame$structural_crps),
    market_crps = mean(frame$market_crps),
    delta_crps_structural_minus_market = mean(frame$delta_crps),
    structural_direction_accuracy = mean(
      frame$structural_direction_correct
    ),
    stringsAsFactors = FALSE
  )
}

error_rows <- list(
  overall = summarize_error(model_error, "overall", "all")
)
for (field in c(
  "sample", "league_canonical", "favorite_band", "matchup_type",
  "roster_stability_band", "divergence_magnitude_band",
  "dominant_error_driver"
)) {
  for (level in unique(as.character(model_error[[field]]))) {
    if (is.na(level)) {
      next
    }
    rows <- model_error[
      !is.na(model_error[[field]]) &
        as.character(model_error[[field]]) == level,
      ,
      drop = FALSE
    ]
    error_rows[[paste(field, level, sep = "__")]] <- summarize_error(
      rows,
      field,
      level
    )
  }
}
error_summary <- do.call(rbind, error_rows)
rownames(error_summary) <- NULL

residual_correlations <- data.frame(
  pair = c(
    "duration_vs_intensity_log_residual",
    "duration_contribution_vs_market_residual",
    "intensity_contribution_vs_market_residual",
    "duration_contribution_vs_structural_disagreement",
    "intensity_contribution_vs_structural_disagreement"
  ),
  pearson = c(
    stats::cor(
      model_error$duration_log_residual,
      model_error$intensity_log_residual
    ),
    stats::cor(
      model_error$duration_contribution,
      model_error$market_residual
    ),
    stats::cor(
      model_error$intensity_contribution,
      model_error$market_residual
    ),
    stats::cor(
      model_error$duration_contribution,
      model_error$structural_disagreement
    ),
    stats::cor(
      model_error$intensity_contribution,
      model_error$structural_disagreement
    )
  ),
  spearman = c(
    stats::cor(
      model_error$duration_log_residual,
      model_error$intensity_log_residual,
      method = "spearman"
    ),
    stats::cor(
      model_error$duration_contribution,
      model_error$market_residual,
      method = "spearman"
    ),
    stats::cor(
      model_error$intensity_contribution,
      model_error$market_residual,
      method = "spearman"
    ),
    stats::cor(
      model_error$duration_contribution,
      model_error$structural_disagreement,
      method = "spearman"
    ),
    stats::cor(
      model_error$intensity_contribution,
      model_error$structural_disagreement,
      method = "spearman"
    )
  ),
  stringsAsFactors = FALSE
)

bootstrap_decomposition <- function(frame, draws = 3000L, seed = 20260805L) {
  blocks <- split(seq_len(nrow(frame)), frame$series_id)
  set.seed(seed)
  values <- replicate(draws, {
    sampled <- sample(names(blocks), length(blocks), replace = TRUE)
    rows <- frame[unlist(blocks[sampled], use.names = FALSE), , drop = FALSE]
    c(
      mean_absolute_duration_contribution = mean(
        abs(rows$duration_contribution)
      ),
      mean_absolute_intensity_contribution = mean(
        abs(rows$intensity_contribution)
      ),
      intensity_dominant_rate = mean(
        rows$dominant_error_driver == "intensity"
      ),
      duration_intensity_residual_correlation = stats::cor(
        rows$duration_log_residual,
        rows$intensity_log_residual
      )
    )
  })
  data.frame(
    metric = rownames(values),
    estimate = rowMeans(values),
    lower_95 = apply(values, 1, stats::quantile, 0.025),
    upper_95 = apply(values, 1, stats::quantile, 0.975),
    stringsAsFactors = FALSE
  )
}
bootstrap <- bootstrap_decomposition(model_error)

integrity <- data.frame(
  metric = c(
    "phenomenon_maps",
    "phenomenon_series",
    "atlas_maps",
    "duplicate_phenomenon_gameids",
    "duplicate_atlas_gameids",
    "maximum_shapley_decomposition_gap",
    "mean_absolute_product_gap"
  ),
  value = c(
    nrow(maps),
    length(unique(maps$series_id)),
    nrow(model_error),
    anyDuplicated(maps$gameid),
    anyDuplicated(model_error$gameid),
    max(abs(model_error$decomposition_gap)),
    mean(abs(model_error$product_gap))
  ),
  stringsAsFactors = FALSE
)

utils::write.csv(
  integrity,
  file.path(output_dir, "integrity-audit.csv"),
  row.names = FALSE
)
utils::write.csv(
  variance_summary,
  file.path(output_dir, "observed-variance-decomposition.csv"),
  row.names = FALSE
)
utils::write.csv(
  mechanism_summary,
  file.path(output_dir, "observed-mechanism-segments.csv"),
  row.names = FALSE
)
utils::write.csv(
  oracle_summary,
  file.path(output_dir, "oracle-component-diagnostics.csv"),
  row.names = FALSE
)
utils::write.csv(
  error_summary,
  file.path(output_dir, "model-error-segments.csv"),
  row.names = FALSE
)
utils::write.csv(
  residual_correlations,
  file.path(output_dir, "residual-correlations.csv"),
  row.names = FALSE
)
utils::write.csv(
  bootstrap,
  file.path(output_dir, "decomposition-bootstrap.csv"),
  row.names = FALSE
)
utils::write.csv(
  model_error[, c(
    "gameid", "series_id", "game_datetime", "league_canonical", "sample",
    "observed_total", "observed_duration", "observed_intensity",
    "predicted_duration", "predicted_intensity", "component_product_mean",
    "duration_log_residual", "intensity_log_residual",
    "duration_contribution", "intensity_contribution",
    "dominant_error_driver", "structural_disagreement", "market_residual",
    "delta_crps"
  )],
  file.path(output_dir, "map-error-decomposition.csv"),
  row.names = FALSE
)
saveRDS(
  list(
    maps = maps,
    phenomenon = phenomenon,
    model_error = model_error,
    integrity = integrity,
    variance_summary = variance_summary,
    mechanism_summary = mechanism_summary,
    oracle_summary = oracle_summary,
    error_summary = error_summary,
    residual_correlations = residual_correlations,
    bootstrap = bootstrap
  ),
  file.path(output_dir, "phenomenon-results.rds"),
  version = 3L
)

overall_variance <- variance_summary[
  variance_summary$scope == "overall",
  ,
  drop = FALSE
]
overall_error <- error_summary[
  error_summary$scope == "overall",
  ,
  drop = FALSE
]
base_mae <- oracle_summary$mean_absolute_error[
  oracle_summary$model_id == "structural_components"
]
duration_oracle_mae <- oracle_summary$mean_absolute_error[
  oracle_summary$model_id == "oracle_duration"
]
intensity_oracle_mae <- oracle_summary$mean_absolute_error[
  oracle_summary$model_id == "oracle_intensity"
]

report <- c(
  "# Relatorio de viabilidade e desenho de modelagem",
  "",
  "## 1. Resumo executivo",
  "",
  paste(
    "A intensidade explica",
    sprintf("%.1f%%", 100 * overall_variance$intensity_shapley_share),
    "da variacao logaritmica observada do total; a duracao explica",
    sprintf("%.1f%%", 100 * overall_variance$duration_shapley_share),
    ". No erro estrutural, a intensidade domina em",
    sprintf("%.1f%%", 100 * overall_error$intensity_dominant_rate),
    "dos mapas. Status: GO WITH CONDITIONS para pesquisar variaveis de",
    "intensidade; HOLD para alterar o modelo ativo."
  ),
  "",
  "## 2. Decisao pretendida",
  "",
  "Priorizar mecanismos que possam melhorar apostas pre e live contra softs.",
  "",
  "## 3. Pergunta de pesquisa",
  "",
  "O total e os erros do modelo sao dominados por duracao ou intensidade?",
  "",
  "## 4. Definicao formal do problema",
  "",
  "Total de kills = duracao do mapa multiplicada pela intensidade de kills.",
  "",
  "## 5. Variavel-alvo",
  "",
  "Total de kills por mapa, duracao em minutos e kills por minuto.",
  "",
  "## 6. Unidade de observacao",
  "",
  "Mapa individual, com dependencia agrupada por serie.",
  "",
  "## 7. Horizonte e cutoff de informacao",
  "",
  "Diagnostico pos-resultado sobre previsoes pre e live-open point-in-time.",
  "",
  "## 8. Processo gerador dos dados",
  "",
  "Duracao define exposicao; intensidade define a taxa de eventos nessa exposicao.",
  "",
  "## 9. Hipoteses causais",
  "",
  "Estado de vantagem, luta inicial, resistencia e fechamento alteram os dois mecanismos.",
  "",
  "## 10. Revisao de literatura",
  "",
  "Nao aplicavel; auditoria empirica dos dados locais.",
  "",
  "## 11. Estado da evidencia",
  "",
  "Historico reutilizado e diagnostico; nao constitui confirmacao prospectiva.",
  "",
  "## 12. Fontes de dados",
  "",
  "Oracle Elixir local, modelo estrutural e atlas estrutural-Pinnacle.",
  "",
  "## 13. Auditoria dos dados",
  "",
  paste(nrow(maps), "mapas do fenomeno e", nrow(model_error), "mapas com decomposicao de erro."),
  "",
  "## 14. Representatividade do historico",
  "",
  "O fenomeno cobre varias temporadas; o erro contra mercado concentra-se em 2026.",
  "",
  "## 15. Variaveis candidatas",
  "",
  "Estado aos 15 minutos, kills iniciais, intensidade pos-15, comeback e gold gap.",
  "",
  "## 16. Riscos de leakage e vieses",
  "",
  "Variaveis de estado do mapa sao apenas diagnosticas e nao podem entrar no pre.",
  "",
  "## 17. Baselines",
  "",
  "Modelo estrutural atual e Pinnacle live-open.",
  "",
  "## 18. Modelos candidatos",
  "",
  "Nenhum modelo novo; decomposicao deterministica e cenarios oracle.",
  "",
  "## 19. Estrategia de validacao",
  "",
  "Estabilidade por periodo, liga e bootstrap por serie.",
  "",
  "## 20. Metricas preditivas",
  "",
  "MAE, RMSE, residuo logaritmico, CRPS e atribuicao Shapley.",
  "",
  "## 21. Metricas decisorias ou economicas",
  "",
  "Nao estimadas; odds soft sincronizadas continuam indisponiveis.",
  "",
  "## 22. Calibracao",
  "",
  "A Pinnacle permanece a referencia probabilistica operacional.",
  "",
  "## 23. Incerteza",
  "",
  "Bootstrap por serie com 3.000 repeticoes.",
  "",
  "## 24. Analise de sensibilidade",
  "",
  "Resultados separados por liga, periodo, favoritismo, matchup e elenco.",
  "",
  "## 25. Custos e restricoes",
  "",
  "Baixo custo computacional; estados intrajogo exigem feed live para uso live.",
  "",
  "## 26. Viabilidade operacional",
  "",
  "Viavel para orientar feature engineering; nao e regra de aposta pronta.",
  "",
  "## 27. Plano experimental",
  "",
  "Testar familias preditivas do mecanismo dominante isoladamente contra Pinnacle.",
  "",
  "## 28. Criterios de sucesso",
  "",
  "Reducao temporalmente estavel de CRPS e log score sobre Pinnacle.",
  "",
  "## 29. Criterios de abandono",
  "",
  "Abandonar proxies que so expliquem o resultado depois do mapa.",
  "",
  "## 30. Riscos tecnicos",
  "",
  "Cobertura parcial dos campos aos 15 minutos.",
  "",
  "## 31. Riscos estatisticos",
  "",
  "Analise exploratoria, multiplos segmentos e confirmacao historica reutilizada.",
  "",
  "## 32. Limitacoes",
  "",
  "A decomposicao explica erro, mas nao prova que o componente seja previsivel.",
  "",
  "## 33. Recomendacao final",
  "",
  paste(
    "GO WITH CONDITIONS para pesquisar intensidade. O oracle de duracao reduz",
    "MAE de", sprintf("%.3f", base_mae), "para",
    sprintf("%.3f", duration_oracle_mae), "; o oracle de intensidade reduz para",
    sprintf("%.3f", intensity_oracle_mae), "."
  ),
  "",
  "## 34. Proximos passos priorizados",
  "",
  "Investigar proxies pre e sinais live da intensidade pos-15 e do estado de vantagem.",
  "",
  "## 35. Referencias",
  "",
  "Veja os artefatos locais desta pesquisa.",
  "",
  "## 36. Apendices",
  "",
  "Veja os CSVs de variancia, mecanismos, erros, oracle e bootstrap."
)
writeLines(report, file.path(output_dir, "09-final-report.md"), useBytes = TRUE)

print(integrity, row.names = FALSE)
print(overall_variance, row.names = FALSE)
print(mechanism_summary, row.names = FALSE)
print(oracle_summary, row.names = FALSE)
print(overall_error, row.names = FALSE)
print(residual_correlations, row.names = FALSE)
print(bootstrap, row.names = FALSE)
