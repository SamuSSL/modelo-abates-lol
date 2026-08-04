\name{bettingiscool_infrastructure}
\alias{bettingiscool_request}
\alias{validate_bettingiscool_kills_contract}
\alias{normalize_bettingiscool_kills_odds}
\alias{write_bettingiscool_raw_response}
\alias{initialize_bettingiscool_store}
\alias{normalize_bettingiscool_fixtures}
\alias{normalize_bettingiscool_settlements}
\alias{prepare_bettingiscool_odds_rows}
\alias{append_bettingiscool_rows}
\alias{select_bettingiscool_map_snapshots}
\alias{match_bettingiscool_games}
\alias{evaluate_kills_market_backtest}
\alias{summarize_kills_market_backtest}
\alias{bootstrap_kills_market_backtest}
\title{BettingIsCool market data infrastructure}
\description{
Authenticated, resumable and idempotent ingestion, matching, snapshot
selection and market backtesting for map-level League of Legends kills totals.
}
\usage{
bettingiscool_request(endpoint, query = list(),
  api_key = Sys.getenv("BETTINGISCOOL_API_KEY", unset = ""),
  base_url = .bettingiscool_default_base_url, max_retries = 5L,
  transport = .bettingiscool_default_transport, sleeper = Sys.sleep)

validate_bettingiscool_kills_contract(odds)

normalize_bettingiscool_kills_odds(odds, retrieved_at,
  snapshot_type = "history")

write_bettingiscool_raw_response(response, raw_dir)

initialize_bettingiscool_store(connection)

normalize_bettingiscool_fixtures(fixtures, retrieved_at, raw_sha256)

normalize_bettingiscool_settlements(settlements, retrieved_at, raw_sha256)

prepare_bettingiscool_odds_rows(odds, raw_sha256)

append_bettingiscool_rows(connection, table, data, id_column)

select_bettingiscool_map_snapshots(snapshots, minutes_before_close = 5)

match_bettingiscool_games(fixtures, periods, games, competition_manifest,
  aliases = list(), settlements = NULL,
  cancelled_statuses = c(3L, 4L, 5L), date_tolerance_days = 1L)

evaluate_kills_market_backtest(predictions, links, snapshots,
  canonical_games)

summarize_kills_market_backtest(backtest)

bootstrap_kills_market_backtest(backtest, replicates = 2000L,
  seed = 20260728L)
}
\arguments{
\item{endpoint}{API endpoint.}
\item{query}{Named query parameters.}
\item{api_key}{Authentication key supplied through the environment.}
\item{base_url}{Provider API base URL.}
\item{max_retries}{Maximum retry count.}
\item{transport}{Injectable HTTP transport.}
\item{sleeper}{Injectable wait function.}
\item{odds}{Raw or normalized odds rows.}
\item{retrieved_at}{UTC retrieval timestamp.}
\item{snapshot_type}{History, opening, or closing label.}
\item{response}{Authenticated API response with raw text and metadata.}
\item{raw_dir}{Private raw-response directory.}
\item{connection}{Open DBI connection.}
\item{fixtures}{Normalized or raw fixture rows.}
\item{raw_sha256}{SHA-256 of the raw response body.}
\item{settlements}{Settlement rows.}
\item{table}{Target DuckDB table.}
\item{data}{Normalized rows to append.}
\item{id_column}{Deterministic primary-key column.}
\item{snapshots}{Historical odds snapshots.}
\item{minutes_before_close}{Snapshot distance from map market close.}
\item{periods}{Event and map-period pairs.}
\item{games}{Canonical Oracle map rows.}
\item{competition_manifest}{Versioned league manifest.}
\item{aliases}{Versioned team aliases.}
\item{cancelled_statuses}{Provider cancellation status codes.}
\item{date_tolerance_days}{Maximum series-date tolerance.}
\item{predictions}{OOF probabilistic predictions.}
\item{links}{Audited game-market links.}
\item{canonical_games}{Canonical observed map outcomes.}
\item{backtest}{Map-level market backtest rows.}
\item{replicates}{Number of bootstrap replicates.}
\item{seed}{Reproducible random seed.}
}
\value{
The API functions return normalized data and provenance. Store functions
return insertion counts. Matching and backtest functions return auditable data
frames.
}
