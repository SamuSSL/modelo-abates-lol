#' Build current champion sample coverage
#'
#' @param draft_rows Historical champion-pick rows.
#' @param snapshot_cutoff Timestamp after the latest allowed result.
#' @param half_life_days Exponential-decay half-life.
#' @return One row per champion with raw and effective picks.
#' @export
build_champion_sample_snapshot <- function(
  draft_rows,
  snapshot_cutoff,
  half_life_days = 60
) {
  cutoff <- as.POSIXct(snapshot_cutoff, tz = "UTC")
  rows <- draft_rows[
    draft_rows$competition_role %in% c("target", "auxiliary") &
      !is.na(draft_rows$champion) &
      nzchar(as.character(draft_rows$champion)) &
      draft_rows$game_datetime < cutoff,
    ,
    drop = FALSE
  ]
  age_days <- as.numeric(difftime(
    cutoff,
    rows$game_datetime,
    units = "days"
  ))
  rows$.weight <- 0.5^(age_days / half_life_days)
  groups <- split(rows, rows$champion)
  result <- do.call(rbind, lapply(groups, function(group) {
    data.frame(
      champion = as.character(group$champion[[1L]]),
      raw_champion_games = nrow(group),
      effective_champion_games = sum(group$.weight),
      stringsAsFactors = FALSE
    )
  }))
  rownames(result) <- NULL
  result
}

#' Build a portable public-inference bundle
#'
#' @param fit Fitted count regression.
#' @param team_snapshot Current team histories.
#' @param taxonomy Static champion taxonomy.
#' @param champion_samples Current champion sample coverage.
#' @param metadata Model metadata.
#' @param sample_limits Operational sample limits.
#' @return Nested list serializable to JSON.
#' @export
build_portable_model_bundle <- function(
  fit,
  team_snapshot,
  taxonomy,
  champion_samples,
  metadata,
  sample_limits
) {
  team_rows <- lapply(seq_len(nrow(team_snapshot)), function(index) {
    row <- team_snapshot[index, , drop = FALSE]
    list(
      key = .rolling_team_key(row$team_id, row$team_name),
      team_id = if (is.na(row$team_id)) NULL else row$team_id,
      team_name = as.character(row$team_name),
      latest_team_name = if (
        "latest_team_name" %in% names(row) &&
          !is.na(row$latest_team_name)
      ) {
        as.character(row$latest_team_name)
      } else {
        as.character(row$team_name)
      },
      league_canonical = as.character(row$league_canonical),
      last_game_datetime = if (
        "latest_history_datetime" %in% names(row) &&
          !is.na(row$latest_history_datetime)
      ) {
        format(
          row$latest_history_datetime,
          tz = "UTC",
          usetz = TRUE
        )
      } else {
        NULL
      },
      effective_team_games = as.numeric(
        row$effective_combined_kills_per_minute_games
      ),
      hist_pace = as.numeric(
        row$hist_combined_kills_per_minute
      )
    )
  })
  taxonomy_rows <- lapply(seq_len(nrow(taxonomy)), function(index) {
    row <- taxonomy[index, , drop = FALSE]
    as.list(row[setdiff(names(row), "champion")])
  })
  names(taxonomy_rows) <- taxonomy$champion
  champion_sample_values <- as.list(
    as.numeric(champion_samples$effective_champion_games)
  )
  names(champion_sample_values) <- champion_samples$champion
  list(
    metadata = metadata,
    model = list(
      distribution = fit$distribution,
      theta = as.numeric(fit$theta),
      league_levels = as.character(fit$league_levels),
      feature_names = as.character(fit$feature_names),
      coefficients = as.list(stats::coef(fit$model)),
      scaling = fit$scaling
    ),
    teams = team_rows,
    taxonomy = taxonomy_rows,
    champion_samples = champion_sample_values,
    sample_limits = sample_limits
  )
}

#' Write a portable public-inference bundle
#'
#' @param bundle Bundle from `build_portable_model_bundle()`.
#' @param path Output JSON path.
#' @return Normalized output path.
#' @export
write_portable_model_bundle <- function(bundle, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(
    bundle,
    path,
    auto_unbox = TRUE,
    pretty = TRUE,
    digits = NA,
    null = "null"
  )
  normalizePath(path, winslash = "/", mustWork = TRUE)
}
