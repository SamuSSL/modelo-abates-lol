\name{bettingiscool-team-totals}
\alias{validate_bettingiscool_team_totals_contract}
\alias{normalize_bettingiscool_team_totals_odds}
\alias{select_bettingiscool_team_total_snapshots}
\alias{derive_team_total_probabilities}
\alias{select_bettingiscool_team_total_endpoint_rows}
\title{Validate and prepare BettingIsCool team-total markets}
\description{
Helpers for validating the team-total market contract, normalizing raw odds,
selecting time-specific or endpoint snapshots, and deriving no-vig
probabilities.
}
\usage{
validate_bettingiscool_team_totals_contract(odds, fixture = NULL)

normalize_bettingiscool_team_totals_odds(
  odds,
  retrieved_at,
  snapshot_type = "history",
  fixture = NULL
)

select_bettingiscool_team_total_snapshots(
  snapshots,
  minimum_minutes = 15,
  maximum_minutes = 30
)

derive_team_total_probabilities(data)

select_bettingiscool_team_total_endpoint_rows(
  snapshots,
  snapshot_type = c("closing", "opening")
)
}
\arguments{
  \item{odds}{Raw or normalized odds rows.}
  \item{fixture}{Optional fixture metadata used to validate the contract.}
  \item{retrieved_at}{UTC retrieval timestamp.}
  \item{snapshot_type}{Snapshot or endpoint type.}
  \item{snapshots}{Normalized team-total snapshots.}
  \item{minimum_minutes}{Minimum number of minutes before cutoff.}
  \item{maximum_minutes}{Maximum number of minutes before cutoff.}
  \item{data}{Team-total rows containing true Over and Under odds.}
}
\value{
Validation returns invisibly or raises an error. Normalization and selection
helpers return data frames. Probability derivation appends no-vig Over and
Under probabilities.
}
