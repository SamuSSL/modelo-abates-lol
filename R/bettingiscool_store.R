.bettingiscool_utc <- function(value) {
  as.POSIXct(value, tz = "UTC", tryFormats = c(
    "%Y-%m-%dT%H:%M:%OSZ",
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M:%S"
  ))
}

.bettingiscool_hash_rows <- function(data, columns) {
  vapply(seq_len(nrow(data)), function(index) {
    digest::digest(
      paste(vapply(columns, function(column) {
        as.character(data[[column]][[index]])
      }, character(1L)), collapse = "|"),
      algo = "sha256",
      serialize = FALSE
    )
  }, character(1L))
}

#' Preserve an immutable BettingIsCool API response
#'
#' @param response Result returned by `bettingiscool_request()`.
#' @param raw_dir Root directory for private raw market data.
#' @return Paths and SHA-256 for the stored response.
#' @export
write_bettingiscool_raw_response <- function(response, raw_dir) {
  required <- c("endpoint", "query", "retrieved_at", "raw_text")
  missing <- setdiff(required, names(response))
  if (length(missing) > 0L) {
    stop("Resposta sem metadados brutos: ", paste(missing, collapse = ", "))
  }
  sha256 <- digest::digest(
    enc2utf8(response$raw_text),
    algo = "sha256",
    serialize = FALSE
  )
  endpoint <- gsub("[^a-z0-9]+", "_", tolower(response$endpoint))
  endpoint <- gsub("^_|_$", "", endpoint)
  directory <- file.path(raw_dir, endpoint)
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  body_path <- file.path(directory, paste0(sha256, ".json"))
  request_sha256 <- digest::digest(
    paste(
      response$endpoint,
      jsonlite::toJSON(response$query, auto_unbox = TRUE),
      sep = "|"
    ),
    algo = "sha256",
    serialize = FALSE
  )
  metadata_path <- file.path(
    directory,
    paste0(request_sha256, ".meta.json")
  )
  if (!file.exists(body_path)) {
    connection <- file(body_path, open = "wb")
    on.exit(close(connection), add = TRUE)
    writeBin(charToRaw(enc2utf8(response$raw_text)), connection)
  }
  metadata <- list(
    endpoint = response$endpoint,
    query = response$query,
    retrieved_at = response$retrieved_at,
    status_code = response$status_code,
    quota_remaining = response$quota_remaining,
    quota_cost = response$quota_cost,
    row_count = response$row_count,
    truncated = response$truncated,
    sha256 = sha256,
    request_sha256 = request_sha256
  )
  if (!file.exists(metadata_path)) {
    jsonlite::write_json(
      metadata,
      metadata_path,
      auto_unbox = TRUE,
      pretty = TRUE,
      null = "null"
    )
  }
  list(
    body_path = normalizePath(body_path, winslash = "/", mustWork = TRUE),
    metadata_path = normalizePath(
      metadata_path,
      winslash = "/",
      mustWork = TRUE
    ),
    sha256 = sha256
  )
}

#' Create the market-data schema in DuckDB
#'
#' @param connection Open DBI connection.
#' @return `TRUE` invisibly.
#' @export
initialize_bettingiscool_store <- function(connection) {
  statements <- c(
    "CREATE TABLE IF NOT EXISTS market_fixtures (
      fixture_id VARCHAR PRIMARY KEY, provider VARCHAR, event_id VARCHAR,
      sport_id INTEGER, league_id INTEGER, league_name VARCHAR,
      starts TIMESTAMP, runner_home VARCHAR, runner_away VARCHAR,
      live_status INTEGER, resulting_unit VARCHAR, parent_id VARCHAR,
      version VARCHAR, retrieved_at TIMESTAMP, raw_sha256 VARCHAR
    )",
    "CREATE TABLE IF NOT EXISTS market_live_fixtures (
      fixture_id VARCHAR PRIMARY KEY, provider VARCHAR, event_id VARCHAR,
      sport_id INTEGER, league_id INTEGER, league_name VARCHAR,
      starts TIMESTAMP, runner_home VARCHAR, runner_away VARCHAR,
      live_status INTEGER, resulting_unit VARCHAR, parent_id VARCHAR,
      version VARCHAR, retrieved_at TIMESTAMP, raw_sha256 VARCHAR
    )",
    "CREATE TABLE IF NOT EXISTS market_odds_snapshots (
      snapshot_id VARCHAR PRIMARY KEY, provider VARCHAR, event_id VARCHAR,
      period INTEGER, market VARCHAR, line DOUBLE, line_id VARCHAR,
      alt_line_id VARCHAR, odds_over DOUBLE, odds_under DOUBLE,
      true_odds_over DOUBLE, true_odds_under DOUBLE,
      odds_timestamp TIMESTAMP, market_cutoff TIMESTAMP,
      market_status INTEGER, max_win DOUBLE, result_status INTEGER,
      score_home DOUBLE, score_away DOUBLE, snapshot_type VARCHAR,
      retrieved_at TIMESTAMP, raw_sha256 VARCHAR
    )",
    "CREATE TABLE IF NOT EXISTS market_live_odds_snapshots (
      snapshot_id VARCHAR PRIMARY KEY, provider VARCHAR, event_id VARCHAR,
      period INTEGER, market VARCHAR, line DOUBLE, line_id VARCHAR,
      alt_line_id VARCHAR, odds_over DOUBLE, odds_under DOUBLE,
      true_odds_over DOUBLE, true_odds_under DOUBLE,
      odds_timestamp TIMESTAMP, market_cutoff TIMESTAMP,
      market_status INTEGER, max_win DOUBLE, result_status INTEGER,
      score_home DOUBLE, score_away DOUBLE, snapshot_type VARCHAR,
      retrieved_at TIMESTAMP, raw_sha256 VARCHAR
    )",
    "CREATE TABLE IF NOT EXISTS market_opening AS
      SELECT * FROM market_odds_snapshots WHERE FALSE",
    "CREATE TABLE IF NOT EXISTS market_closing AS
      SELECT * FROM market_odds_snapshots WHERE FALSE",
    "CREATE TABLE IF NOT EXISTS market_settlements (
      settlement_id VARCHAR PRIMARY KEY, provider VARCHAR, event_id VARCHAR,
      period INTEGER, result_status INTEGER, score_home DOUBLE,
      score_away DOUBLE, settled_at TIMESTAMP, retrieved_at TIMESTAMP,
      raw_sha256 VARCHAR
    )",
    "CREATE TABLE IF NOT EXISTS game_market_links (
      link_id VARCHAR PRIMARY KEY, gameid VARCHAR, event_id VARCHAR,
      period INTEGER, link_status VARCHAR, match_method VARCHAR,
      league_canonical VARCHAR, competition VARCHAR,
      team_home_market VARCHAR, team_away_market VARCHAR,
      market_close_time TIMESTAMP, exclusion_reason VARCHAR,
      reviewed_at TIMESTAMP
    )",
    "CREATE TABLE IF NOT EXISTS api_ingestion_state (
      state_id VARCHAR PRIMARY KEY, endpoint VARCHAR, query_json VARCHAR,
      window_start TIMESTAMP, window_end TIMESTAMP, status VARCHAR,
      raw_sha256 VARCHAR, rows_received BIGINT, quota_remaining DOUBLE,
      completed_at TIMESTAMP, error_message VARCHAR
    )",
    "CREATE TABLE IF NOT EXISTS kills_regular_event_links (
      event_link_id VARCHAR PRIMARY KEY, kills_event_id VARCHAR,
      regular_event_id VARCHAR, league_id INTEGER,
      kills_starts TIMESTAMP, regular_starts TIMESTAMP,
      runner_home VARCHAR, runner_away VARCHAR,
      link_status VARCHAR, match_method VARCHAR,
      exclusion_reason VARCHAR, linked_at TIMESTAMP
    )",
    "CREATE TABLE IF NOT EXISTS market_moneyline_snapshots (
      moneyline_snapshot_id VARCHAR PRIMARY KEY, provider VARCHAR,
      event_id VARCHAR, period INTEGER, market VARCHAR,
      odds_home DOUBLE, odds_away DOUBLE,
      true_odds_home DOUBLE, true_odds_away DOUBLE,
      odds_timestamp TIMESTAMP, market_cutoff TIMESTAMP,
      market_status INTEGER, max_win DOUBLE, snapshot_type VARCHAR,
      retrieved_at TIMESTAMP, raw_sha256 VARCHAR
    )",
    "CREATE TABLE IF NOT EXISTS market_moneyline_opening AS
      SELECT * FROM market_moneyline_snapshots WHERE FALSE",
    "CREATE TABLE IF NOT EXISTS market_moneyline_closing AS
      SELECT * FROM market_moneyline_snapshots WHERE FALSE",
    "CREATE TABLE IF NOT EXISTS market_team_totals_snapshots (
      team_total_snapshot_id VARCHAR PRIMARY KEY, provider VARCHAR,
      event_id VARCHAR, period INTEGER, market VARCHAR,
      team_side VARCHAR, team_name VARCHAR, line DOUBLE,
      line_id VARCHAR, alt_line_id VARCHAR,
      odds_over DOUBLE, odds_under DOUBLE,
      true_odds_over DOUBLE, true_odds_under DOUBLE,
      odds_timestamp TIMESTAMP, market_cutoff TIMESTAMP,
      market_status INTEGER, max_win DOUBLE, snapshot_type VARCHAR,
      retrieved_at TIMESTAMP, raw_sha256 VARCHAR
    )",
    "CREATE TABLE IF NOT EXISTS market_team_totals_opening AS
      SELECT * FROM market_team_totals_snapshots WHERE FALSE",
    "CREATE TABLE IF NOT EXISTS market_team_totals_closing AS
      SELECT * FROM market_team_totals_snapshots WHERE FALSE",
    "CREATE TABLE IF NOT EXISTS game_moneyline_links (
      link_id VARCHAR PRIMARY KEY, gameid VARCHAR, event_id VARCHAR,
      period INTEGER, link_status VARCHAR, match_method VARCHAR,
      league_canonical VARCHAR, competition VARCHAR,
      team_home_market VARCHAR, team_away_market VARCHAR,
      market_close_time TIMESTAMP, exclusion_reason VARCHAR,
      reviewed_at TIMESTAMP
    )"

  )
  for (statement in statements) {
    DBI::dbExecute(connection, statement)
  }
  DBI::dbExecute(connection, paste(
    "CREATE OR REPLACE VIEW market_backtest_view AS",
    "SELECT l.*, s.line, s.odds_over, s.odds_under,",
    "s.true_odds_over, s.true_odds_under, s.odds_timestamp,",
    "s.market_status, t.result_status, t.score_home, t.score_away",
    "FROM game_market_links l",
    "LEFT JOIN market_odds_snapshots s",
    "ON l.event_id = s.event_id AND l.period = s.period",
    "LEFT JOIN market_settlements t",
    "ON l.event_id = t.event_id AND l.period = t.period"
  ))
  DBI::dbExecute(connection, paste(
    "CREATE OR REPLACE VIEW team_totals_backtest_view AS",
    "SELECT l.gameid, l.event_id, l.period, l.link_status,",
    "l.league_canonical, l.competition, l.team_home_market,",
    "l.team_away_market, s.market, s.team_side, s.team_name,",
    "s.line, s.odds_over, s.odds_under, s.true_odds_over,",
    "s.true_odds_under, s.odds_timestamp, s.market_cutoff,",
    "s.market_status, t.result_status, t.score_home, t.score_away,",
    "CASE WHEN s.team_side = 'home' THEN t.score_home",
    "ELSE t.score_away END AS team_kills",
    "FROM game_market_links l",
    "LEFT JOIN market_team_totals_snapshots s",
    "ON l.event_id = s.event_id AND l.period = s.period",
    "LEFT JOIN market_settlements t",
    "ON l.event_id = t.event_id AND l.period = t.period"
  ))
  DBI::dbExecute(connection, paste(
    "CREATE OR REPLACE VIEW market_postdraft_quotes AS",
    "WITH prematch_fixtures AS (",
    "SELECT * FROM market_fixtures",
    "QUALIFY ROW_NUMBER() OVER (",
    "PARTITION BY event_id ORDER BY retrieved_at DESC, version DESC) = 1",
    "), live_fixtures AS (",
    "SELECT * FROM market_live_fixtures",
    "QUALIFY ROW_NUMBER() OVER (",
    "PARTITION BY event_id ORDER BY retrieved_at DESC, version DESC) = 1",
    "), live_boundaries AS (",
    "SELECT f.parent_id AS root_event_id, f.event_id AS live_event_id,",
    "f.runner_home, f.runner_away, s.period,",
    "MIN(s.odds_timestamp) AS live_open_time,",
    "COUNT(*) AS live_snapshot_rows",
    "FROM live_fixtures f",
    "JOIN market_live_odds_snapshots s ON f.event_id = s.event_id",
    "WHERE f.resulting_unit = 'Kills' AND f.live_status = 1",
    "AND s.market = 'totals' AND s.alt_line_id IS NULL",
    "GROUP BY f.parent_id, f.event_id, f.runner_home, f.runner_away, s.period",
    "), event_pairs AS (",
    "SELECT p.event_id AS prematch_event_id, b.*,",
    "COUNT(*) OVER (PARTITION BY b.root_event_id, b.live_event_id, b.period)",
    "AS pair_count",
    "FROM live_boundaries b",
    "JOIN prematch_fixtures p ON p.parent_id = b.root_event_id",
    "AND LOWER(TRIM(p.runner_home)) = LOWER(TRIM(b.runner_home))",
    "AND LOWER(TRIM(p.runner_away)) = LOWER(TRIM(b.runner_away))",
    "WHERE p.resulting_unit = 'Kills' AND COALESCE(p.live_status, 0) <> 1",
    "), candidates AS (",
    "SELECT p.*, s.snapshot_id, s.line, s.line_id, s.odds_over,",
    "s.odds_under, s.true_odds_over, s.true_odds_under,",
    "s.odds_timestamp AS quote_time, s.market_cutoff, s.market_status,",
    "s.max_win, DATE_DIFF('second', s.odds_timestamp, p.live_open_time)",
    "AS freshness_seconds,",
    "ROW_NUMBER() OVER (",
    "PARTITION BY p.prematch_event_id, p.live_event_id, p.period",
    "ORDER BY s.odds_timestamp DESC, TRY_CAST(s.line_id AS BIGINT) DESC,",
    "s.snapshot_id DESC) AS recency_rank",
    "FROM event_pairs p",
    "JOIN market_odds_snapshots s",
    "ON s.event_id = p.prematch_event_id AND s.period = p.period",
    "WHERE p.pair_count = 1 AND s.market = 'totals'",
    "AND s.alt_line_id IS NULL AND s.odds_timestamp < p.live_open_time",
    "), selected AS (",
    "SELECT * FROM candidates WHERE recency_rank = 1",
    "), verified_links AS (",
    "SELECT * FROM game_market_links WHERE link_status = 'verified'",
    "QUALIFY ROW_NUMBER() OVER (",
    "PARTITION BY gameid ORDER BY reviewed_at DESC, link_id DESC) = 1",
    ")",
    "SELECT x.root_event_id, x.prematch_event_id, x.live_event_id,",
    "x.period, l.gameid, l.league_canonical, l.competition,",
    "x.runner_home, x.runner_away, x.live_open_time, x.quote_time,",
    "x.freshness_seconds, x.live_snapshot_rows, x.line, x.line_id,",
    "x.odds_over, x.odds_under, x.true_odds_over, x.true_odds_under,",
    "1.0 / x.true_odds_over AS true_probability_over,",
    "1.0 / x.true_odds_under AS true_probability_under,",
    "x.market_cutoff, x.market_status, x.max_win, x.snapshot_id",
    "FROM selected x",
    "LEFT JOIN verified_links l",
    "ON l.event_id = x.prematch_event_id AND l.period = x.period",
    ""
  ))
  invisible(TRUE)
}

.bettingiscool_append_unique <- function(connection, table, data, id_column) {
  if (nrow(data) == 0L) {
    return(0L)
  }
  target_columns <- DBI::dbListFields(connection, table)
  missing <- setdiff(target_columns, names(data))
  if (length(missing) > 0L) {
    stop(
      "Dados sem colunas da tabela ",
      table,
      ": ",
      paste(missing, collapse = ", "),
      call. = FALSE
    )
  }
  data <- data[target_columns]
  data <- data[!duplicated(data[[id_column]]), , drop = FALSE]
  temporary <- paste0("incoming_", gsub("[^a-z0-9]", "_", table))
  DBI::dbWriteTable(connection, temporary, data, temporary = TRUE, overwrite = TRUE)
  quoted_id <- DBI::dbQuoteIdentifier(connection, id_column)
  sql <- paste0(
    "INSERT INTO ", DBI::dbQuoteIdentifier(connection, table),
    " SELECT incoming.* FROM ", DBI::dbQuoteIdentifier(connection, temporary),
    " incoming WHERE NOT EXISTS (SELECT 1 FROM ",
    DBI::dbQuoteIdentifier(connection, table), " existing WHERE existing.",
    quoted_id, " = incoming.", quoted_id, ")"
  )
  as.integer(DBI::dbExecute(connection, sql))
}

#' Normalize BettingIsCool fixtures
#'
#' @param fixtures Fixture rows returned by the API.
#' @param retrieved_at Retrieval timestamp.
#' @param raw_sha256 Raw response hash.
#' @return Normalized fixture records.
#' @export
normalize_bettingiscool_fixtures <- function(
  fixtures,
  retrieved_at,
  raw_sha256
) {
  fixtures <- .bettingiscool_as_data_frame(fixtures)
  fixtures <- .bettingiscool_add_missing(fixtures, c(
    "event_id", "sport_id", "league_id", "league_name", "starts", "runner_home",
    "runner_away", "live_status", "resulting_unit", "parent_id", "version"
  ))
  result <- data.frame(
    provider = rep("bettingiscool", nrow(fixtures)),
    event_id = as.character(fixtures$event_id),
    sport_id = suppressWarnings(as.integer(fixtures$sport_id)),
    league_id = suppressWarnings(as.integer(fixtures$league_id)),
    league_name = as.character(fixtures$league_name),
    starts = .bettingiscool_utc(fixtures$starts),
    runner_home = as.character(fixtures$runner_home),
    runner_away = as.character(fixtures$runner_away),
    live_status = suppressWarnings(as.integer(fixtures$live_status)),
    resulting_unit = as.character(fixtures$resulting_unit),
    parent_id = as.character(fixtures$parent_id),
    version = as.character(fixtures$version),
    retrieved_at = rep(.bettingiscool_utc(retrieved_at), nrow(fixtures)),
    raw_sha256 = rep(raw_sha256, nrow(fixtures)),
    stringsAsFactors = FALSE
  )
  result$fixture_id <- .bettingiscool_hash_rows(
    result,
    c("provider", "event_id", "version")
  )
  result[c("fixture_id", setdiff(names(result), "fixture_id"))]
}

#' Normalize BettingIsCool map settlements
#'
#' @param settlements Result rows returned by `/api/results`.
#' @param retrieved_at Retrieval timestamp.
#' @param raw_sha256 Raw response hash.
#' @return Normalized map settlement records.
#' @export
normalize_bettingiscool_settlements <- function(
  settlements,
  retrieved_at,
  raw_sha256
) {
  settlements <- .bettingiscool_as_data_frame(settlements)
  if (
    !"result_status" %in% names(settlements) &&
      "status" %in% names(settlements)
  ) {
    settlements$result_status <- settlements$status
  }
  settlements <- .bettingiscool_add_missing(settlements, c(
    "event_id", "period", "result_status", "score_home", "score_away", "timestamp"
  ))
  result <- data.frame(
    provider = rep("bettingiscool", nrow(settlements)),
    event_id = as.character(settlements$event_id),
    period = suppressWarnings(as.integer(settlements$period)),
    result_status = suppressWarnings(as.integer(settlements$result_status)),
    score_home = suppressWarnings(as.numeric(settlements$score_home)),
    score_away = suppressWarnings(as.numeric(settlements$score_away)),
    settled_at = .bettingiscool_utc(settlements$timestamp),
    retrieved_at = rep(.bettingiscool_utc(retrieved_at), nrow(settlements)),
    raw_sha256 = rep(raw_sha256, nrow(settlements)),
    stringsAsFactors = FALSE
  )
  result <- result[!is.na(result$period) & result$period >= 1L, , drop = FALSE]
  result$settlement_id <- .bettingiscool_hash_rows(
    result,
    c("provider", "event_id", "period")
  )
  result[c("settlement_id", setdiff(names(result), "settlement_id"))]
}

#' Add raw provenance to normalized market odds
#'
#' @param odds Normalized odds from `normalize_bettingiscool_kills_odds()`.
#' @param raw_sha256 Raw response hash.
#' @return Rows ready for a market odds table.
#' @export
prepare_bettingiscool_odds_rows <- function(odds, raw_sha256) {
  odds$odds_timestamp <- .bettingiscool_utc(odds$odds_timestamp)
  odds$market_cutoff <- .bettingiscool_utc(odds$market_cutoff)
  odds$retrieved_at <- .bettingiscool_utc(odds$retrieved_at)
  odds$raw_sha256 <- raw_sha256
  odds
}

#' Write normalized BettingIsCool data idempotently
#'
#' @param connection Open DBI connection.
#' @param table Target market table.
#' @param data Normalized rows.
#' @param id_column Deterministic identifier.
#' @return Number of inserted rows.
#' @export
append_bettingiscool_rows <- function(connection, table, data, id_column) {
  initialize_bettingiscool_store(connection)
  .bettingiscool_append_unique(connection, table, data, id_column)
}

#' Select leakage-safe snapshots before each map closes
#'
#' @param snapshots Main-line historical snapshots.
#' @param minutes_before_close Minutes before the period-specific final update.
#' @return One selected row per event and period.
#' @export
select_bettingiscool_map_snapshots <- function(
  snapshots,
  minutes_before_close = 5
) {
  snapshots$odds_timestamp <- .bettingiscool_utc(snapshots$odds_timestamp)
  snapshots <- snapshots[
    !is.na(snapshots$odds_timestamp),
    ,
    drop = FALSE
  ]
  groups <- split(
    seq_len(nrow(snapshots)),
    paste(snapshots$event_id, snapshots$period, sep = "|")
  )
  selected <- lapply(groups, function(index) {
    rows <- snapshots[index, , drop = FALSE]
    explicit_cutoff <- if ("market_cutoff" %in% names(rows)) {
      .bettingiscool_utc(rows$market_cutoff)
    } else {
      as.POSIXct(character(), tz = "UTC")
    }
    explicit_cutoff <- explicit_cutoff[!is.na(explicit_cutoff)]
    final_history_timestamp <- max(rows$odds_timestamp)
    close_time <- final_history_timestamp
    threshold <- close_time - as.numeric(minutes_before_close) * 60
    eligible <- rows[
      rows$odds_timestamp <= threshold &
        (
          is.na(rows$market_status) |
            !rows$market_status %in% c(2L, 3L)
        ),
      ,
      drop = FALSE
    ]
    if (nrow(eligible) == 0L) {
      return(NULL)
    }
    row <- eligible[which.max(eligible$odds_timestamp), , drop = FALSE]
    row$market_close_time <- close_time
    row$provider_market_cutoff <- if (length(explicit_cutoff) > 0L) {
      max(explicit_cutoff)
    } else {
      as.POSIXct(NA, tz = "UTC")
    }
    row$provider_cutoff_minus_close_minutes <- as.numeric(difftime(
      row$provider_market_cutoff,
      close_time,
      units = "mins"
    ))
    row$market_close_source <- "final_main_history_timestamp"
    row$snapshot_minutes_before_close <- as.numeric(difftime(
      close_time,
      row$odds_timestamp,
      units = "mins"
    ))
    row
  })
  selected <- selected[!vapply(selected, is.null, logical(1L))]
  if (length(selected) == 0L) {
    return(snapshots[FALSE, , drop = FALSE])
  }
  result <- do.call(rbind, selected)
  rownames(result) <- NULL
  result
}
