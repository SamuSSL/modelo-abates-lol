library(targets)

tar_option_set(
  packages = c("yaml", "data.table", "digest"),
  seed = 20260723
)

tar_source("R")

list(
  tar_target(
    project_config_file,
    "config/default.yml",
    format = "file"
  ),
  tar_target(
    league_config_file,
    "config/leagues.yml",
    format = "file"
  ),
  tar_target(
    evaluation_config_file,
    "config/evaluation.yml",
    format = "file"
  ),
  tar_target(
    game_exclusions_file,
    "config/game-exclusions.yml",
    format = "file"
  ),
  tar_target(
    model_selection_file,
    "config/model-selection.yml",
    format = "file"
  ),
  tar_target(
    promotion_config_file,
    "config/promotion.yml",
    format = "file"
  ),
  tar_target(
    model_selection,
    yaml::read_yaml(model_selection_file)
  ),
  tar_target(
    promotion_config,
    yaml::read_yaml(promotion_config_file)
  ),
  tar_target(
    champion_taxonomy_file,
    "config/taxonomy/champions-2026.yml",
    format = "file"
  ),
  tar_target(
    champion_taxonomy_manifest_file,
    "config/taxonomy/manifest.yml",
    format = "file"
  ),
  tar_target(
    champion_taxonomy,
    read_champion_taxonomy(champion_taxonomy_file)
  ),
  tar_target(
    project_config,
    yaml::read_yaml(project_config_file)
  ),
  tar_target(
    evaluation_config,
    yaml::read_yaml(evaluation_config_file)
  ),
  tar_target(
    game_exclusions_config,
    yaml::read_yaml(game_exclusions_file)
  ),
  tar_target(
    game_exclusions,
    {
      rows <- lapply(
        game_exclusions_config$exclusions,
        function(exclusion) {
          data.frame(
            gameid = as.character(exclusion$gameid),
            reason_code = as.character(exclusion$reason_code),
            rationale = as.character(exclusion$rationale),
            reviewed_at = as.character(exclusion$reviewed_at),
            stringsAsFactors = FALSE
          )
        }
      )
      do.call(rbind, rows)
    }
  ),
  tar_target(
    raw_manifest_file,
    project_config$paths$raw_manifest,
    format = "file"
  ),
  tar_target(
    raw_manifest,
    read_data_manifest(raw_manifest_file)
  ),
  tar_target(
    raw_files,
    file.path(
      project_config$paths$raw_oracles_elixir,
      raw_manifest$file_name
    ),
    format = "file"
  ),
  tar_target(
    validated_manifest,
    {
      validate_data_manifest(
        raw_manifest,
        project_config$paths$raw_oracles_elixir
      )
      raw_manifest
    }
  ),
  tar_target(
    file_audit,
    {
      rows <- lapply(raw_files, function(path) {
        audit_oe_file(
          path,
          expected_rows_per_game =
            project_config$data$expected_rows_per_game
        )
      })
      do.call(rbind, rows)
    }
  ),
  tar_target(
    file_audit_csv,
    {
      dir.create(
        project_config$paths$artifacts,
        recursive = TRUE,
        showWarnings = FALSE
      )
      path <- file.path(
        project_config$paths$artifacts,
        "oracle_elixir_file_audit.csv"
      )
      utils::write.csv(file_audit, path, row.names = FALSE, na = "")
      path
    },
    format = "file"
  ),
  tar_target(
    canonical_batches,
    {
      validated_manifest
      lapply(seq_along(raw_files), function(index) {
        rows <- data.table::fread(
          raw_files[[index]],
          select = required_oe_columns(),
          showProgress = FALSE,
          encoding = "UTF-8",
          na.strings = c("", "NA")
        )
        result <- build_canonical_games(rows)
        result$games$source_file <- basename(raw_files[[index]])
        result$games$source_season <- raw_manifest$season[[index]]
        result$quality_events$source_file <- basename(raw_files[[index]])
        result$quality_events$source_season <- raw_manifest$season[[index]]
        result
      })
    }
  ),
  tar_target(
    canonical_game_rows,
    {
      games <- do.call(
        rbind,
        lapply(canonical_batches, `[[`, "games")
      )
      rownames(games) <- NULL
      duplicate_ids <- unique(games$gameid[duplicated(games$gameid)])
      if (length(duplicate_ids) > 0L) {
        stop(
          "Game IDs duplicados entre arquivos: ",
          paste(head(duplicate_ids, 20L), collapse = ", "),
          call. = FALSE
        )
      }
      games
    }
  ),
  tar_target(
    game_quality_events_raw,
    {
      events <- do.call(
        rbind,
        lapply(canonical_batches, `[[`, "quality_events")
      )
      rownames(events) <- NULL
      events
    }
  ),
  tar_target(
    canonical_exclusion_result,
    apply_game_exclusions(
      canonical_game_rows,
      game_quality_events_raw,
      game_exclusions
    )
  ),
  tar_target(
    canonical_games,
    derive_series_metadata(canonical_exclusion_result$games)
  ),
  tar_target(
    game_quality_events,
    canonical_exclusion_result$quality_events
  ),
  tar_target(
    excluded_games,
    canonical_exclusion_result$excluded_games
  ),
  tar_target(
    canonical_games_file,
    {
      dir.create(
        project_config$paths$interim,
        recursive = TRUE,
        showWarnings = FALSE
      )
      path <- file.path(
        project_config$paths$interim,
        "canonical_games.rds"
      )
      saveRDS(canonical_games, path, version = 3L)
      path
    },
    format = "file"
  ),
  tar_target(
    game_quality_events_file,
    {
      dir.create(
        project_config$paths$interim,
        recursive = TRUE,
        showWarnings = FALSE
      )
      path <- file.path(
        project_config$paths$interim,
        "game_quality_events.rds"
      )
      saveRDS(game_quality_events, path, version = 3L)
      path
    },
    format = "file"
  ),
  tar_target(
    excluded_games_file,
    {
      dir.create(
        project_config$paths$interim,
        recursive = TRUE,
        showWarnings = FALSE
      )
      path <- file.path(
        project_config$paths$interim,
        "excluded_games.rds"
      )
      saveRDS(excluded_games, path, version = 3L)
      path
    },
    format = "file"
  ),
  tar_target(
    processed_store_files,
    unlist(
      write_processed_store(
        canonical_games,
        game_quality_events,
        project_config$paths$processed,
        file.path(
          project_config$paths$processed,
          "lolkills.duckdb"
        ),
        excluded_games = excluded_games
      ),
      use.names = FALSE
    ),
    format = "file"
  ),
  tar_target(
    development_folds,
    {
      rows <- lapply(
        evaluation_config$development_folds,
        function(fold) {
          data.frame(
            fold_id = as.character(fold$id),
            validation_start = as.POSIXct(
              as.character(fold$validation_start),
              tz = evaluation_config$timezone
            ),
            validation_end = as.POSIXct(
              as.character(fold$validation_end),
              tz = evaluation_config$timezone
            ),
            stringsAsFactors = FALSE
          )
        }
      )
      result <- do.call(rbind, rows)
      rownames(result) <- NULL
      result
    }
  ),
  tar_target(
    window_candidates,
    build_window_candidate_grid(evaluation_config)
  ),
  tar_target(
    window_evaluation,
    evaluate_window_candidates(
      canonical_games,
      development_folds,
      window_candidates,
      as.POSIXct(
        as.character(evaluation_config$holdout$start),
        tz = evaluation_config$timezone
      ),
      prior_games =
        evaluation_config$baseline$league_shrinkage_prior_games
    )
  ),
  tar_target(
    window_evaluation_files,
    {
      path <- file.path(
        project_config$paths$artifacts,
        "evaluation"
      )
      dir.create(path, recursive = TRUE, showWarnings = FALSE)
      metrics_path <- file.path(path, "window_map_metrics.rds")
      summary_path <- file.path(path, "window_summary.csv")
      saveRDS(
        window_evaluation$map_metrics,
        metrics_path,
        version = 3L
      )
      utils::write.csv(
        window_evaluation$summary,
        summary_path,
        row.names = FALSE
      )
      c(metrics_path, summary_path)
    },
    format = "file"
  ),
  tar_target(
    recency_sensitivity_folds,
    {
      rows <- lapply(
        evaluation_config$recency_sensitivity$folds,
        function(fold) {
          data.frame(
            fold_id = as.character(fold$id),
            validation_start = as.POSIXct(
              as.character(fold$validation_start),
              tz = evaluation_config$timezone
            ),
            validation_end = as.POSIXct(
              as.character(fold$validation_end),
              tz = evaluation_config$timezone
            ),
            stringsAsFactors = FALSE
          )
        }
      )
      result <- do.call(rbind, rows)
      rownames(result) <- NULL
      result
    }
  ),
  tar_target(
    recency_sensitivity_candidates,
    {
      half_lives <- as.numeric(
        unlist(
          evaluation_config$recency_sensitivity$
            exponential_half_life_days
        )
      )
      data.frame(
        candidate_id = paste0("exponential_hl", half_lives, "d"),
        window_type = "exponential",
        window_value = half_lives,
        stringsAsFactors = FALSE
      )
    }
  ),
  tar_target(
    recency_sensitivity_evaluation,
    evaluate_window_candidates(
      canonical_games,
      recency_sensitivity_folds,
      recency_sensitivity_candidates,
      as.POSIXct(
        as.character(evaluation_config$holdout$start),
        tz = evaluation_config$timezone
      ),
      prior_games =
        evaluation_config$baseline$league_shrinkage_prior_games
    )
  ),
  tar_target(
    recency_sensitivity_files,
    {
      path <- file.path(
        project_config$paths$artifacts,
        "evaluation"
      )
      dir.create(path, recursive = TRUE, showWarnings = FALSE)
      metrics_path <- file.path(
        path,
        "recency_sensitivity_map_metrics.rds"
      )
      summary_path <- file.path(
        path,
        "recency_sensitivity_summary.csv"
      )
      saveRDS(
        recency_sensitivity_evaluation$map_metrics,
        metrics_path,
        version = 3L
      )
      utils::write.csv(
        recency_sensitivity_evaluation$summary,
        summary_path,
        row.names = FALSE
      )
      c(metrics_path, summary_path)
    },
    format = "file"
  ),
  tar_target(
    team_metric_batches,
    {
      validated_manifest
      lapply(seq_along(raw_files), function(index) {
        rows <- data.table::fread(
          raw_files[[index]],
          select = team_metric_oe_columns(),
          showProgress = FALSE,
          encoding = "UTF-8",
          na.strings = c("", "NA")
        )
        rows <- rows[
          tolower(as.character(rows$position)) == "team",
          ,
          drop = FALSE
        ]
        result <- build_team_map_metrics(rows)
        result$source_file <- basename(raw_files[[index]])
        result
      })
    }
  ),
  tar_target(
    team_map_metrics,
    {
      result <- do.call(rbind, team_metric_batches)
      rownames(result) <- NULL
      result <- result[
        !result$gameid %in% game_exclusions$gameid,
        ,
        drop = FALSE
      ]
      canonical_match <- match(result$gameid, canonical_games$gameid)
      if (anyNA(canonical_match)) {
        stop(
          "Team metrics contain non-canonical games.",
          call. = FALSE
        )
      }
      result$series_id <- canonical_games$series_id[canonical_match]
      result$series_cutoff <-
        canonical_games$series_cutoff[canonical_match]
      result
    }
  ),
  tar_target(
    team_map_metrics_file,
    {
      path <- file.path(
        project_config$paths$interim,
        "team_map_metrics.rds"
      )
      saveRDS(team_map_metrics, path, version = 3L)
      path
    },
    format = "file"
  ),
  tar_target(
    player_metric_batches,
    {
      validated_manifest
      lapply(seq_along(raw_files), function(index) {
        rows <- data.table::fread(
          raw_files[[index]],
          select = player_metric_oe_columns(),
          showProgress = FALSE,
          encoding = "UTF-8",
          na.strings = c("", "NA")
        )
        result <- build_player_map_metrics(rows)
        result$source_file <- basename(raw_files[[index]])
        result
      })
    }
  ),
  tar_target(
    player_map_metrics,
    {
      result <- do.call(rbind, player_metric_batches)
      rownames(result) <- NULL
      result <- result[
        !result$gameid %in% game_exclusions$gameid,
        ,
        drop = FALSE
      ]
      canonical_match <- match(result$gameid, canonical_games$gameid)
      if (anyNA(canonical_match)) {
        stop(
          "Player metrics contain non-canonical games.",
          call. = FALSE
        )
      }
      for (column in c(
        "series_id",
        "series_cutoff",
        "series_eligible",
        "target_valid"
      )) {
        result[[column]] <- canonical_games[[column]][canonical_match]
      }
      result
    }
  ),
  tar_target(
    player_map_metrics_file,
    {
      path <- file.path(
        project_config$paths$interim,
        "player_map_metrics.rds"
      )
      saveRDS(player_map_metrics, path, version = 3L)
      path
    },
    format = "file"
  ),
  tar_target(
    player_draft_audit_files,
    {
      target <- player_map_metrics[
        player_map_metrics$competition_role == "target",
        ,
        drop = FALSE
      ]
      groups <- split(target, target$gameid)
      map_audit <- do.call(rbind, lapply(groups, function(data) {
        data.frame(
          gameid = data$gameid[[1L]],
          season = data$source_season[[1L]],
          player_rows = nrow(data),
          unique_players = length(unique(data$player_id)),
          unique_champions = length(unique(data$champion)),
          canonical_positions = length(unique(data$position)),
          missing_player_id = any(is.na(data$player_id)),
          stringsAsFactors = FALSE
        )
      }))
      invalid <- map_audit$player_rows != 10L |
        map_audit$unique_players != 10L |
        map_audit$unique_champions != 10L |
        map_audit$canonical_positions != 5L
      if (any(invalid)) {
        stop("Invalid player or draft map structure.", call. = FALSE)
      }
      validate_champion_taxonomy(
        champion_taxonomy,
        unique(target$champion)
      )
      path <- file.path(
        project_config$paths$artifacts,
        "research"
      )
      dir.create(path, recursive = TRUE, showWarnings = FALSE)
      audit_path <- file.path(path, "player_draft_map_audit.csv")
      missing_path <- file.path(path, "player_missing_ids.csv")
      utils::write.csv(map_audit, audit_path, row.names = FALSE)
      utils::write.csv(
        target[is.na(target$player_id), c(
          "gameid",
          "game_datetime",
          "league_canonical",
          "side",
          "position",
          "player_name",
          "team_name",
          "champion"
        )],
        missing_path,
        row.names = FALSE
      )
      c(audit_path, missing_path)
    },
    format = "file"
  ),
  tar_target(
    team_stability_metric_names,
    c(
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
  ),
  tar_target(
    team_metric_stability,
    {
      development <- team_map_metrics[
        team_map_metrics$game_datetime <
          as.POSIXct(
            as.character(evaluation_config$holdout$start),
            tz = evaluation_config$timezone
          ),
        ,
        drop = FALSE
      ]
      studies <- lapply(c(5L, 10L, 20L), function(block_size) {
        result <- evaluate_metric_stability(
          development,
          team_stability_metric_names,
          block_size
        )
        result$summary$block_size <- block_size
        result$by_league$block_size <- block_size
        result
      })
      names(studies) <- c("block_5", "block_10", "block_20")
      studies
    }
  ),
  tar_target(
    team_metric_stability_files,
    {
      path <- file.path(
        project_config$paths$artifacts,
        "research"
      )
      dir.create(path, recursive = TRUE, showWarnings = FALSE)
      details_path <- file.path(
        path,
        "metric_stability_details.rds"
      )
      summary_path <- file.path(
        path,
        "metric_stability_summary.csv"
      )
      summary <- do.call(
        rbind,
        lapply(team_metric_stability, `[[`, "summary")
      )
      saveRDS(
        team_metric_stability,
        details_path,
        version = 3L
      )
      utils::write.csv(summary, summary_path, row.names = FALSE)
      c(details_path, summary_path)
    },
    format = "file"
  ),
  tar_target(
    rolling_team_metric_names,
    c(
      "combined_kills_per_minute",
      "damage_per_minute",
      "damage_taken_per_minute",
      "kills_per_minute",
      "deaths_per_minute"
    )
  ),
  tar_target(
    rolling_team_features,
    build_team_rolling_features(
      team_map_metrics,
      metric_names = rolling_team_metric_names,
      half_life_days =
        evaluation_config$approved_recency$half_life_days,
      prior_games =
        evaluation_config$team_feature_research$default_prior_games
    )
  ),
  tar_target(
    rolling_team_features_file,
    {
      path <- file.path(
        project_config$paths$interim,
        paste0(
          "team_rolling_features_prior",
          evaluation_config$team_feature_research$
            default_prior_games,
          ".rds"
        )
      )
      saveRDS(rolling_team_features, path, version = 3L)
      path
    },
    format = "file"
  ),
  tar_target(
    map_feature_table,
    assemble_map_feature_table(
      rolling_team_features,
      canonical_games
    )
  ),
  tar_target(
    map_feature_table_file,
    {
      path <- file.path(
        project_config$paths$interim,
        paste0(
          "map_features_prior",
          evaluation_config$team_feature_research$
            default_prior_games,
          ".rds"
        )
      )
      saveRDS(map_feature_table, path, version = 3L)
      path
    },
    format = "file"
  ),
  tar_target(
    map_signal_table,
    derive_team_signal_features(map_feature_table)
  ),
  tar_target(
    rolling_player_features,
    build_player_rolling_features(
      player_map_metrics,
      metric_names = as.character(unlist(
        evaluation_config$player_draft_research$metric_names
      )),
      half_life_days =
        evaluation_config$player_draft_research$half_life_days,
      prior_games =
        evaluation_config$player_draft_research$player_prior_games
    )
  ),
  tar_target(
    rolling_player_features_file,
    {
      path <- file.path(
        project_config$paths$interim,
        "player_rolling_features.rds"
      )
      saveRDS(rolling_player_features, path, version = 3L)
      path
    },
    format = "file"
  ),
  tar_target(
    player_draft_map_features,
    assemble_player_draft_features(
      rolling_player_features,
      champion_taxonomy
    )
  ),
  tar_target(
    extended_map_signal_table,
    merge(
      map_signal_table,
      player_draft_map_features,
      by = "gameid",
      all.x = TRUE,
      sort = FALSE
    )
  ),
  tar_target(
    simple_model_candidates,
    build_simple_model_candidates(evaluation_config)
  ),
  tar_target(
    simple_model_folds,
    {
      folds <- do.call(
        rbind,
        lapply(
          evaluation_config$recency_sensitivity$folds,
          function(fold) {
            data.frame(
              fold_id = as.character(fold$id),
              validation_start = as.POSIXct(
                as.character(fold$validation_start),
                tz = evaluation_config$timezone
              ),
              validation_end = as.POSIXct(
                as.character(fold$validation_end),
                tz = evaluation_config$timezone
              ),
              stringsAsFactors = FALSE
            )
          }
        )
      )
      rownames(folds) <- NULL
      folds
    }
  ),
  tar_target(
    simple_team_model_evaluation,
    evaluate_simple_team_models(
      maps = map_signal_table,
      folds = simple_model_folds,
      candidates = simple_model_candidates,
      holdout_start = as.POSIXct(
        as.character(evaluation_config$holdout$start),
        tz = evaluation_config$timezone
      ),
      training_start = as.POSIXct(
        as.character(
          evaluation_config$simple_team_models$training_start
        ),
        tz = evaluation_config$timezone
      ),
      half_life_days =
        evaluation_config$simple_team_models$
          observation_half_life_days,
      prior_games =
        evaluation_config$baseline$league_shrinkage_prior_games,
      tail_tolerance =
        evaluation_config$simple_team_models$pmf_tail_tolerance
    )
  ),
  tar_target(
    simple_team_model_evaluation_files,
    {
      path <- file.path(
        project_config$paths$artifacts,
        "evaluation"
      )
      dir.create(path, recursive = TRUE, showWarnings = FALSE)
      metrics_path <- file.path(
        path,
        "simple_team_model_map_metrics.rds"
      )
      summary_path <- file.path(
        path,
        "simple_team_model_summary.csv"
      )
      fold_path <- file.path(
        path,
        "simple_team_model_by_fold.csv"
      )
      league_path <- file.path(
        path,
        "simple_team_model_by_league.csv"
      )
      coefficients_path <- file.path(
        path,
        "simple_team_model_coefficients.csv"
      )
      saveRDS(
        simple_team_model_evaluation$map_metrics,
        metrics_path,
        version = 3L
      )
      utils::write.csv(
        simple_team_model_evaluation$summary,
        summary_path,
        row.names = FALSE
      )
      utils::write.csv(
        simple_team_model_evaluation$by_fold,
        fold_path,
        row.names = FALSE
      )
      utils::write.csv(
        simple_team_model_evaluation$by_league,
        league_path,
        row.names = FALSE
      )
      utils::write.csv(
        simple_team_model_evaluation$coefficients,
        coefficients_path,
        row.names = FALSE
      )
      c(
        metrics_path,
        summary_path,
        fold_path,
        league_path,
        coefficients_path
      )
    },
    format = "file"
  ),
  tar_target(
    player_draft_model_candidates,
    {
      research_config <- evaluation_config
      research_config$simple_team_models$candidates <-
        evaluation_config$player_draft_research$candidates
      build_simple_model_candidates(research_config)
    }
  ),
  tar_target(
    player_draft_model_evaluation,
    evaluate_simple_team_models(
      maps = extended_map_signal_table,
      folds = simple_model_folds,
      candidates = player_draft_model_candidates,
      holdout_start = as.POSIXct(
        as.character(evaluation_config$holdout$start),
        tz = evaluation_config$timezone
      ),
      training_start = as.POSIXct(
        as.character(
          evaluation_config$simple_team_models$training_start
        ),
        tz = evaluation_config$timezone
      ),
      half_life_days =
        evaluation_config$simple_team_models$
          observation_half_life_days,
      prior_games =
        evaluation_config$baseline$league_shrinkage_prior_games,
      tail_tolerance =
        evaluation_config$simple_team_models$pmf_tail_tolerance
    )
  ),
  tar_target(
    player_draft_model_evaluation_files,
    {
      path <- file.path(
        project_config$paths$artifacts,
        "evaluation"
      )
      dir.create(path, recursive = TRUE, showWarnings = FALSE)
      metrics_path <- file.path(
        path,
        "player_draft_model_map_metrics.rds"
      )
      summary_path <- file.path(
        path,
        "player_draft_model_summary.csv"
      )
      fold_path <- file.path(
        path,
        "player_draft_model_by_fold.csv"
      )
      league_path <- file.path(
        path,
        "player_draft_model_by_league.csv"
      )
      coefficients_path <- file.path(
        path,
        "player_draft_model_coefficients.csv"
      )
      saveRDS(
        player_draft_model_evaluation$map_metrics,
        metrics_path,
        version = 3L
      )
      utils::write.csv(
        player_draft_model_evaluation$summary,
        summary_path,
        row.names = FALSE
      )
      utils::write.csv(
        player_draft_model_evaluation$by_fold,
        fold_path,
        row.names = FALSE
      )
      utils::write.csv(
        player_draft_model_evaluation$by_league,
        league_path,
        row.names = FALSE
      )
      utils::write.csv(
        player_draft_model_evaluation$coefficients,
        coefficients_path,
        row.names = FALSE
      )
      c(
        metrics_path,
        summary_path,
        fold_path,
        league_path,
        coefficients_path
      )
    },
    format = "file"
  ),
  tar_target(
    player_draft_bootstrap,
    {
      comparisons <- list(
        c("nb_pace_draft", "nb_pace"),
        c("nb_pace_player", "nb_pace"),
        c("nb_pace_player_draft", "nb_pace_draft")
      )
      do.call(rbind, lapply(comparisons, function(pair) {
        paired_block_bootstrap_crps(
          player_draft_model_evaluation$map_metrics,
          candidate_id = pair[[1L]],
          reference_id = pair[[2L]],
          replicates = 5000,
          seed = 20260724
        )
      }))
    }
  ),
  tar_target(
    player_sample_threshold_evaluation,
    evaluate_team_sample_thresholds(
      map_metrics = player_draft_model_evaluation$map_metrics,
      coverage = player_draft_map_features,
      thresholds = as.numeric(unlist(
        evaluation_config$player_champion_sample_threshold$
          player_effective_thresholds
      )),
      signal_candidate_id =
        evaluation_config$player_champion_sample_threshold$
          signal_candidate_id,
      reference_candidate_id =
        evaluation_config$player_champion_sample_threshold$
          reference_candidate_id,
      sample_column = "minimum_effective_player_games",
      bootstrap_replicates =
        evaluation_config$player_champion_sample_threshold$
          bootstrap_replicates,
      bootstrap_seed =
        evaluation_config$player_champion_sample_threshold$
          bootstrap_seed
    )
  ),
  tar_target(
    champion_sample_threshold_evaluation,
    evaluate_team_sample_thresholds(
      map_metrics = player_draft_model_evaluation$map_metrics,
      coverage = player_draft_map_features,
      thresholds = as.numeric(unlist(
        evaluation_config$player_champion_sample_threshold$
          champion_effective_thresholds
      )),
      signal_candidate_id =
        evaluation_config$player_champion_sample_threshold$
          signal_candidate_id,
      reference_candidate_id =
        evaluation_config$player_champion_sample_threshold$
          reference_candidate_id,
      sample_column = "minimum_effective_champion_games",
      bootstrap_replicates =
        evaluation_config$player_champion_sample_threshold$
          bootstrap_replicates,
      bootstrap_seed =
        evaluation_config$player_champion_sample_threshold$
          bootstrap_seed
    )
  ),
  tar_target(
    player_champion_threshold_files,
    {
      path <- file.path(
        project_config$paths$artifacts,
        "evaluation"
      )
      bootstrap_path <- file.path(
        path,
        "player_draft_bootstrap.csv"
      )
      player_path <- file.path(
        path,
        "player_sample_threshold.csv"
      )
      champion_path <- file.path(
        path,
        "champion_sample_threshold.csv"
      )
      utils::write.csv(
        player_draft_bootstrap,
        bootstrap_path,
        row.names = FALSE
      )
      utils::write.csv(
        player_sample_threshold_evaluation$thresholds,
        player_path,
        row.names = FALSE
      )
      utils::write.csv(
        champion_sample_threshold_evaluation$thresholds,
        champion_path,
        row.names = FALSE
      )
      c(bootstrap_path, player_path, champion_path)
    },
    format = "file"
  ),
  tar_target(
    team_prior_map_tables,
    {
      prior_grid <- as.numeric(unlist(
        evaluation_config$team_prior_sensitivity$prior_grid_games
      ))
      tables <- lapply(prior_grid, function(prior_games) {
        features <- if (
          prior_games ==
            evaluation_config$team_feature_research$
              default_prior_games
        ) {
          rolling_team_features
        } else {
          build_team_rolling_features(
            team_map_metrics,
            metric_names = rolling_team_metric_names,
            half_life_days =
              evaluation_config$team_prior_sensitivity$
                team_feature_half_life_days,
            prior_games = prior_games
          )
        }
        derive_team_signal_features(
          assemble_map_feature_table(features, canonical_games)
        )
      })
      names(tables) <- paste0("prior", prior_grid)
      tables
    }
  ),
  tar_target(
    team_prior_sensitivity_evaluation,
    evaluate_team_prior_sensitivity(
      map_tables = team_prior_map_tables,
      prior_grid_games = as.numeric(unlist(
        evaluation_config$team_prior_sensitivity$
          prior_grid_games
      )),
      folds = simple_model_folds,
      holdout_start = as.POSIXct(
        as.character(evaluation_config$holdout$start),
        tz = evaluation_config$timezone
      ),
      training_start = as.POSIXct(
        as.character(
          evaluation_config$simple_team_models$training_start
        ),
        tz = evaluation_config$timezone
      ),
      half_life_days =
        evaluation_config$team_prior_sensitivity$
          observation_half_life_days,
      tail_tolerance =
        evaluation_config$team_prior_sensitivity$
          pmf_tail_tolerance
    )
  ),
  tar_target(
    team_prior_sensitivity_bootstrap,
    {
      candidate_ids <- unique(
        team_prior_sensitivity_evaluation$
          map_metrics$candidate_id
      )
      pairs <- utils::combn(candidate_ids, 2L)
      result <- lapply(seq_len(ncol(pairs)), function(index) {
        paired_block_bootstrap_crps(
          team_prior_sensitivity_evaluation$map_metrics,
          candidate_id = pairs[1L, index],
          reference_id = pairs[2L, index],
          replicates =
            evaluation_config$team_prior_sensitivity$
              bootstrap_replicates,
          seed =
            evaluation_config$team_prior_sensitivity$
              bootstrap_seed
        )
      })
      do.call(rbind, result)
    }
  ),
  tar_target(
    team_prior_sensitivity_files,
    {
      path <- file.path(
        project_config$paths$artifacts,
        "evaluation"
      )
      dir.create(path, recursive = TRUE, showWarnings = FALSE)
      metrics_path <- file.path(
        path,
        "team_prior_sensitivity_map_metrics.rds"
      )
      summary_path <- file.path(
        path,
        "team_prior_sensitivity_summary.csv"
      )
      fold_path <- file.path(
        path,
        "team_prior_sensitivity_by_fold.csv"
      )
      league_path <- file.path(
        path,
        "team_prior_sensitivity_by_league.csv"
      )
      bootstrap_path <- file.path(
        path,
        "team_prior_sensitivity_bootstrap_pairwise.csv"
      )
      saveRDS(
        team_prior_sensitivity_evaluation$map_metrics,
        metrics_path,
        version = 3L
      )
      utils::write.csv(
        team_prior_sensitivity_evaluation$summary,
        summary_path,
        row.names = FALSE
      )
      utils::write.csv(
        team_prior_sensitivity_evaluation$by_fold,
        fold_path,
        row.names = FALSE
      )
      utils::write.csv(
        team_prior_sensitivity_evaluation$by_league,
        league_path,
        row.names = FALSE
      )
      utils::write.csv(
        team_prior_sensitivity_bootstrap,
        bootstrap_path,
        row.names = FALSE
      )
      c(
        metrics_path,
        summary_path,
        fold_path,
        league_path,
        bootstrap_path
      )
    },
    format = "file"
  ),
  tar_target(
    team_sample_coverage,
    {
      game_ids <- unique(
        simple_team_model_evaluation$map_metrics$gameid
      )
      maps <- map_feature_table[
        map_feature_table$gameid %in% game_ids,
        ,
        drop = FALSE
      ]
      derive_team_sample_coverage(
        maps,
        metric_name =
          evaluation_config$team_sample_threshold$
            effective_metric
      )
    }
  ),
  tar_target(
    team_sample_threshold_evaluation,
    evaluate_team_sample_thresholds(
      map_metrics =
        simple_team_model_evaluation$map_metrics,
      coverage = team_sample_coverage,
      thresholds = as.numeric(unlist(
        evaluation_config$team_sample_threshold$
          effective_game_thresholds
      )),
      signal_candidate_id =
        evaluation_config$team_sample_threshold$
          signal_candidate_id,
      reference_candidate_id =
        evaluation_config$team_sample_threshold$
          reference_candidate_id,
      sample_column = "minimum_effective_team_games",
      bootstrap_replicates =
        evaluation_config$team_sample_threshold$
          bootstrap_replicates,
      bootstrap_seed =
        evaluation_config$team_sample_threshold$
          bootstrap_seed
    )
  ),
  tar_target(
    team_sample_raw_diagnostic,
    evaluate_team_sample_thresholds(
      map_metrics =
        simple_team_model_evaluation$map_metrics,
      coverage = team_sample_coverage,
      thresholds = as.numeric(unlist(
        evaluation_config$team_sample_threshold$
          raw_game_diagnostic_thresholds
      )),
      signal_candidate_id =
        evaluation_config$team_sample_threshold$
          signal_candidate_id,
      reference_candidate_id =
        evaluation_config$team_sample_threshold$
          reference_candidate_id,
      sample_column = "minimum_raw_team_games",
      bootstrap_replicates =
        evaluation_config$team_sample_threshold$
          bootstrap_replicates,
      bootstrap_seed =
        evaluation_config$team_sample_threshold$
          bootstrap_seed
    )
  ),
  tar_target(
    team_sample_threshold_files,
    {
      path <- file.path(
        project_config$paths$artifacts,
        "evaluation"
      )
      dir.create(path, recursive = TRUE, showWarnings = FALSE)
      effective_path <- file.path(
        path,
        "team_sample_threshold_effective.csv"
      )
      selected_path <- file.path(
        path,
        "team_sample_threshold_selected.csv"
      )
      league_path <- file.path(
        path,
        "team_sample_threshold_by_league.csv"
      )
      raw_path <- file.path(
        path,
        "team_sample_threshold_raw_diagnostic.csv"
      )
      coverage_path <- file.path(
        path,
        "team_sample_coverage.rds"
      )
      utils::write.csv(
        team_sample_threshold_evaluation$thresholds,
        effective_path,
        row.names = FALSE
      )
      utils::write.csv(
        team_sample_threshold_evaluation$selected,
        selected_path,
        row.names = FALSE
      )
      utils::write.csv(
        team_sample_threshold_evaluation$by_league,
        league_path,
        row.names = FALSE
      )
      utils::write.csv(
        team_sample_raw_diagnostic$thresholds,
        raw_path,
        row.names = FALSE
      )
      saveRDS(
        team_sample_coverage,
        coverage_path,
        version = 3L
      )
      c(
        effective_path,
        selected_path,
        league_path,
        raw_path,
        coverage_path
      )
    },
    format = "file"
  ),
  tar_target(
    holdout_model_candidates,
    {
      holdout_config <- evaluation_config
      holdout_config$simple_team_models$candidates <- list(
        list(
          id = "nb_league",
          distribution = "negative_binomial",
          feature_block = "league"
        ),
        list(
          id = "nb_pace",
          distribution = "negative_binomial",
          feature_block = "pace"
        ),
        list(
          id = "nb_pace_draft",
          distribution = "negative_binomial",
          feature_block = "pace_draft"
        )
      )
      build_simple_model_candidates(holdout_config)
    }
  ),
  tar_target(
    operational_map_table,
    {
      team_coverage <- derive_team_sample_coverage(
        map_feature_table,
        metric_name =
          evaluation_config$team_sample_threshold$
            effective_metric
      )
      result <- merge(
        extended_map_signal_table,
        team_coverage[c(
          "gameid",
          "minimum_effective_team_games"
        )],
        by = "gameid",
        all.x = TRUE,
        sort = FALSE
      )
      limits <- model_selection$sample_limits
      result$operationally_eligible <-
        result$minimum_effective_team_games >=
          limits$team_effective_games &
        result$minimum_effective_player_games >=
          limits$player_effective_games &
        result$minimum_effective_champion_games >=
          limits$champion_effective_games
      result
    }
  ),
  tar_target(
    holdout_fold,
    data.frame(
      fold_id = "2026_final_holdout",
      validation_start = as.POSIXct(
        promotion_config$holdout$start,
        tz = promotion_config$timezone
      ),
      validation_end = as.POSIXct(
        promotion_config$holdout$end,
        tz = promotion_config$timezone
      ),
      stringsAsFactors = FALSE
    )
  ),
  tar_target(
    final_holdout_evaluation,
    evaluate_simple_team_models(
      maps = operational_map_table[
        operational_map_table$operationally_eligible,
        ,
        drop = FALSE
      ],
      folds = holdout_fold,
      candidates = holdout_model_candidates,
      holdout_start = as.POSIXct(
        promotion_config$holdout$end,
        tz = promotion_config$timezone
      ),
      training_start = as.POSIXct(
        evaluation_config$simple_team_models$training_start,
        tz = evaluation_config$timezone
      ),
      half_life_days =
        evaluation_config$simple_team_models$
          observation_half_life_days,
      prior_games =
        evaluation_config$baseline$league_shrinkage_prior_games,
      tail_tolerance =
        evaluation_config$simple_team_models$pmf_tail_tolerance
    )
  ),
  tar_target(
    primary_promotion_assessment,
    assess_model_promotion(
      final_holdout_evaluation$map_metrics,
      promotion_config$primary_candidate,
      promotion_config$primary_reference,
      promotion_config$criteria
    )
  ),
  tar_target(
    fallback_promotion_assessment,
    assess_model_promotion(
      final_holdout_evaluation$map_metrics,
      promotion_config$fallback_candidate,
      promotion_config$fallback_reference,
      promotion_config$criteria
    )
  ),
  tar_target(
    promoted_candidate_id,
    {
      if (isTRUE(primary_promotion_assessment$passed)) {
        promotion_config$primary_candidate
      } else if (isTRUE(fallback_promotion_assessment$passed)) {
        promotion_config$fallback_candidate
      } else {
        stop(
          "Nenhum modelo passou os critérios do holdout.",
          call. = FALSE
        )
      }
    }
  ),
  tar_target(
    final_holdout_line_evaluation,
    evaluate_line_probabilities(
      final_holdout_evaluation$map_metrics[
        final_holdout_evaluation$map_metrics$candidate_id ==
          promoted_candidate_id,
        ,
        drop = FALSE
      ],
      lines = seq(10.5, 50.5, by = 1)
    )
  ),
  tar_target(
    final_holdout_files,
    {
      path <- file.path(
        project_config$paths$artifacts,
        "evaluation"
      )
      metrics_path <- file.path(
        path,
        "final_holdout_map_metrics.rds"
      )
      summary_path <- file.path(
        path,
        "final_holdout_summary.csv"
      )
      league_path <- file.path(
        path,
        "final_holdout_by_league.csv"
      )
      lines_path <- file.path(
        path,
        "final_holdout_line_summary.csv"
      )
      gate_path <- file.path(
        path,
        "final_holdout_promotion_gate.rds"
      )
      saveRDS(
        final_holdout_evaluation$map_metrics,
        metrics_path,
        version = 3L
      )
      utils::write.csv(
        final_holdout_evaluation$summary,
        summary_path,
        row.names = FALSE
      )
      utils::write.csv(
        final_holdout_evaluation$by_league,
        league_path,
        row.names = FALSE
      )
      utils::write.csv(
        final_holdout_line_evaluation$summary,
        lines_path,
        row.names = FALSE
      )
      saveRDS(
        list(
          primary = primary_promotion_assessment,
          fallback = fallback_promotion_assessment,
          promoted_candidate_id = promoted_candidate_id
        ),
        gate_path,
        version = 3L
      )
      c(
        metrics_path,
        summary_path,
        league_path,
        lines_path,
        gate_path
      )
    },
    format = "file"
  ),
  tar_target(
    deployment_cutoff,
    max(canonical_games$game_datetime) + 1
  ),
  tar_target(
    final_model_feature_names,
    holdout_model_candidates$feature_names[[
      match(
        promoted_candidate_id,
        holdout_model_candidates$candidate_id
      )
    ]]
  ),
  tar_target(
    final_model_fit,
    {
      training <- operational_map_table[
        operational_map_table$game_datetime < deployment_cutoff,
        ,
        drop = FALSE
      ]
      age_days <- as.numeric(difftime(
        deployment_cutoff,
        training$series_cutoff,
        units = "days"
      ))
      fit_count_regression(
        training,
        distribution = "negative_binomial",
        feature_names = final_model_feature_names,
        weights = 0.5^(
          age_days /
            evaluation_config$simple_team_models$
              observation_half_life_days
        )
      )
    }
  ),
  tar_target(
    deployment_team_snapshot,
    build_team_feature_snapshot(
      team_map_metrics,
      metric_names = rolling_team_metric_names,
      snapshot_cutoff = deployment_cutoff,
      half_life_days =
        evaluation_config$approved_recency$half_life_days,
      prior_games =
        evaluation_config$team_feature_research$
          default_prior_games
    )
  ),
  tar_target(
    deployment_team_snapshot_enriched,
    {
      history <- team_map_metrics[
        team_map_metrics$competition_role == "target",
        ,
        drop = FALSE
      ]
      history <- history[
        order(history$game_datetime, history$gameid),
        ,
        drop = FALSE
      ]
      history_key <- vapply(seq_len(nrow(history)), function(index) {
        .rolling_team_key(
          history$team_id[[index]],
          history$team_name[[index]]
        )
      }, character(1L))
      latest <- !duplicated(history_key, fromLast = TRUE)
      history <- history[latest, , drop = FALSE]
      history_key <- history_key[latest]
      snapshot_key <- vapply(
        seq_len(nrow(deployment_team_snapshot)),
        function(index) {
          .rolling_team_key(
            deployment_team_snapshot$team_id[[index]],
            deployment_team_snapshot$team_name[[index]]
          )
        },
        character(1L)
      )
      matched <- match(snapshot_key, history_key)
      result <- deployment_team_snapshot
      result$league_canonical <-
        history$league_canonical[matched]
      result$latest_history_datetime <-
        history$game_datetime[matched]
      result$latest_team_name <-
        history$team_name[matched]
      result
    }
  ),
  tar_target(
    deployment_player_snapshot,
    build_player_feature_snapshot(
      player_map_metrics,
      metric_names = as.character(unlist(
        evaluation_config$player_draft_research$metric_names
      )),
      snapshot_cutoff = deployment_cutoff,
      half_life_days =
        evaluation_config$player_draft_research$half_life_days,
      prior_games =
        evaluation_config$player_draft_research$player_prior_games
    )
  ),
  tar_target(
    deployment_player_snapshot_enriched,
    {
      history <- player_map_metrics[
        order(
          player_map_metrics$game_datetime,
          player_map_metrics$gameid
        ),
        ,
        drop = FALSE
      ]
      history_key <- vapply(seq_len(nrow(history)), function(index) {
        .rolling_player_key(
          history$player_id[[index]],
          history$player_name[[index]],
          history$position[[index]]
        )
      }, character(1L))
      latest <- !duplicated(history_key, fromLast = TRUE)
      history <- history[latest, , drop = FALSE]
      history_key <- history_key[latest]
      snapshot_key <- vapply(
        seq_len(nrow(deployment_player_snapshot)),
        function(index) {
          .rolling_player_key(
            deployment_player_snapshot$player_id[[index]],
            deployment_player_snapshot$player_name[[index]],
            deployment_player_snapshot$position[[index]]
          )
        },
        character(1L)
      )
      matched <- match(snapshot_key, history_key)
      result <- deployment_player_snapshot
      result$team_id <- history$team_id[matched]
      result$team_name <- history$team_name[matched]
      result$league_canonical <-
        history$league_canonical[matched]
      result
    }
  ),
  tar_target(
    deployment_champion_snapshot,
    build_champion_sample_snapshot(
      player_map_metrics,
      snapshot_cutoff = deployment_cutoff,
      half_life_days =
        evaluation_config$player_draft_research$half_life_days
    )
  ),
  tar_target(
    portable_model_bundle,
    {
      model_hash <- substr(
        digest::digest(
          list(
            stats::coef(final_model_fit$model),
            final_model_fit$theta,
            deployment_cutoff
          ),
          algo = "sha256"
        ),
        1L,
        12L
      )
      build_portable_model_bundle(
        final_model_fit,
        deployment_team_snapshot_enriched,
        deployment_player_snapshot_enriched,
        champion_taxonomy,
        deployment_champion_snapshot,
        metadata = list(
          model_version = paste0("v1-", model_hash),
          selected_candidate_id = promoted_candidate_id,
          taxonomy_version = "2026-static-v1",
          data_cutoff = format(
            deployment_cutoff,
            tz = "UTC",
            usetz = TRUE
          )
        ),
        sample_limits = model_selection$sample_limits
      )
    }
  ),
  tar_target(
    portable_model_bundle_file,
    write_portable_model_bundle(
      portable_model_bundle,
      file.path("app_data", "model_bundle.json")
    ),
    format = "file"
  ),
  tar_target(
    portable_parity_fixture_file,
    {
      complete <- stats::complete.cases(
        operational_map_table[final_model_feature_names]
      )
      fixture_row <- operational_map_table[
        complete,
        ,
        drop = FALSE
      ]
      fixture_row <- fixture_row[
        which.max(fixture_row$game_datetime),
        ,
        drop = FALSE
      ]
      prediction <- predict_count_regression(
        final_model_fit,
        fixture_row,
        tail_tolerance =
          evaluation_config$simple_team_models$
            pmf_tail_tolerance
      )[[1L]]
      fixture <- list(
        league = as.character(fixture_row$league_canonical),
        features = as.list(
          fixture_row[final_model_feature_names]
        ),
        expected_mean = prediction$mean,
        expected_pmf = prediction$pmf,
        tolerance = 1e-10
      )
      path <- file.path("app_data", "parity_fixture.json")
      jsonlite::write_json(
        fixture,
        path,
        auto_unbox = TRUE,
        pretty = TRUE,
        digits = NA
      )
      path
    },
    format = "file"
  )
)
