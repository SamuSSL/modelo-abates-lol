#!/usr/bin/env Rscript

output_dir <- "artifacts/modeling-research/predraft-market-dynamic-duration"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
connection <- DBI::dbConnect(
  duckdb::duckdb(),
  "data/processed/lolkills.duckdb",
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)
print(DBI::dbGetQuery(
  connection,
  "select link_status, count(*) as maps from game_market_links group by 1"
))
print(DBI::dbGetQuery(
  connection,
  "select link_status, count(*) as maps from game_moneyline_links group by 1"
))
print(DBI::dbGetQuery(
  connection,
  paste(
    "select min(history_rows) as minimum_history_rows,",
    "max(history_rows) as maximum_history_rows, median(history_rows) as median_history_rows",
    "from (select event_id, period, count(*) as history_rows",
    "from market_moneyline_snapshots group by event_id, period)"
  )
))

total_sql <- "
with candidates as (
  select
    l.gameid,
    l.league_canonical,
    l.competition,
    l.event_id,
    l.period,
    l.market_close_time,
    s.snapshot_id,
    s.line,
    s.odds_over,
    s.odds_under,
    s.odds_timestamp,
    s.score_home,
    s.score_away,
    g.total_kills_game as observed_total,
    g.series_id,
    g.game_datetime,
    date_diff('minute', s.odds_timestamp, l.market_close_time) as lead_minutes,
    row_number() over (
      partition by l.gameid
      order by s.odds_timestamp desc, s.snapshot_id desc
    ) as snapshot_rank
  from game_market_links l
  inner join market_odds_snapshots s
    on s.event_id = l.event_id and s.period = l.period
  inner join canonical_games g on g.gameid = l.gameid
  where l.link_status = 'verified'
    and s.odds_timestamp < l.market_close_time
    and date_diff('second', s.odds_timestamp, l.market_close_time) > 30 * 60
    and date_diff('second', s.odds_timestamp, l.market_close_time) < 45 * 60
    and s.odds_over > 1 and s.odds_under > 1
    and abs(s.line - (floor(s.line) + 0.5)) < 0.000001
    and g.target_valid
)
select * exclude(snapshot_rank)
from candidates
where snapshot_rank = 1
order by market_close_time, gameid
"
total_selection <- DBI::dbGetQuery(connection, total_sql)

moneyline_sql <- "
with history as (
  select
    *,
    max(odds_timestamp) over (
      partition by event_id, period
    ) as inferred_market_close_time
  from market_moneyline_snapshots
), candidates as (
  select
    l.gameid,
    s.odds_timestamp,
    s.odds_home,
    s.odds_away,
    s.true_odds_home,
    s.true_odds_away,
    s.inferred_market_close_time as market_close_time,
    date_diff('second', s.odds_timestamp, s.inferred_market_close_time) / 60.0 as lead_minutes,
    row_number() over (
      partition by l.gameid
      order by s.odds_timestamp desc, s.moneyline_snapshot_id desc
    ) as snapshot_rank
  from game_moneyline_links l
  inner join history s
    on s.event_id = l.event_id and s.period = l.period
  where l.link_status = 'verified'
    and s.odds_timestamp < s.inferred_market_close_time
    and date_diff('second', s.odds_timestamp, s.inferred_market_close_time) > 30 * 60
    and date_diff('second', s.odds_timestamp, s.inferred_market_close_time) < 45 * 60
    and s.odds_home > 1 and s.odds_away > 1
)
select * exclude(snapshot_rank)
from candidates
where snapshot_rank = 1
"
moneyline_selection <- DBI::dbGetQuery(connection, moneyline_sql)

team_total_sql <- "
with candidates as (
  select
    l.gameid,
    l.league_canonical,
    l.market_close_time,
    s.team_side,
    s.team_name,
    s.line,
    s.odds_over,
    s.odds_under,
    s.odds_timestamp,
    date_diff('minute', s.odds_timestamp, l.market_close_time) as lead_minutes,
    row_number() over (
      partition by l.gameid, s.team_side
      order by s.odds_timestamp desc, s.team_total_snapshot_id desc
    ) as snapshot_rank
  from game_market_links l
  inner join market_team_totals_snapshots s
    on s.event_id = l.event_id and s.period = l.period
  where l.link_status = 'verified'
    and s.odds_timestamp < l.market_close_time
    and date_diff('second', s.odds_timestamp, l.market_close_time) > 30 * 60
    and date_diff('second', s.odds_timestamp, l.market_close_time) < 45 * 60
    and s.odds_over > 1 and s.odds_under > 1
    and abs(s.line - (floor(s.line) + 0.5)) < 0.000001
)
select * exclude(snapshot_rank)
from candidates
where snapshot_rank = 1
"
team_total_selection <- DBI::dbGetQuery(connection, team_total_sql)

complete_team_games <- aggregate(
  team_side ~ gameid + league_canonical,
  team_total_selection,
  function(value) length(unique(value))
)
complete_team_games <- complete_team_games[complete_team_games$team_side >= 2, ]

total_selection$period_group <- ifelse(
  as.Date(total_selection$market_close_time) >= as.Date("2026-01-01"),
  "2026_diagnostic",
  "development_2023_2025"
)
coverage <- do.call(rbind, lapply(
  split(total_selection, total_selection$period_group),
  function(rows) data.frame(
    layer = "total_t45_t30",
    period = rows$period_group[[1]],
    maps = length(unique(rows$gameid)),
    leagues = length(unique(rows$league_canonical)),
    earliest = min(rows$market_close_time),
    latest = max(rows$market_close_time),
    stringsAsFactors = FALSE
  )
))
coverage <- rbind(
  coverage,
  data.frame(
    layer = "moneyline_t45_t30",
    period = "all",
    maps = length(unique(moneyline_selection$gameid)),
    leagues = length(unique(total_selection$league_canonical[total_selection$gameid %in% moneyline_selection$gameid])),
    earliest = min(moneyline_selection$odds_timestamp),
    latest = max(moneyline_selection$odds_timestamp),
    stringsAsFactors = FALSE
  ),
  data.frame(
    layer = "team_totals_complete_t45_t30",
    period = "all",
    maps = nrow(complete_team_games),
    leagues = length(unique(complete_team_games$league_canonical)),
    earliest = if (nrow(team_total_selection)) min(team_total_selection$market_close_time) else as.POSIXct(NA),
    latest = if (nrow(team_total_selection)) max(team_total_selection$market_close_time) else as.POSIXct(NA),
    stringsAsFactors = FALSE
  )
)

by_league <- aggregate(
  gameid ~ period_group + league_canonical,
  total_selection,
  function(value) length(unique(value))
)
names(by_league)[names(by_league) == "gameid"] <- "maps"

write.csv(total_selection, file.path(output_dir, "total_snapshot_selection.csv"), row.names = FALSE)
write.csv(moneyline_selection, file.path(output_dir, "moneyline_snapshot_selection.csv"), row.names = FALSE)
write.csv(team_total_selection, file.path(output_dir, "team_total_snapshot_selection.csv"), row.names = FALSE)
write.csv(coverage, file.path(output_dir, "coverage_gates.csv"), row.names = FALSE)
write.csv(by_league, file.path(output_dir, "coverage_by_league.csv"), row.names = FALSE)

folds <- data.frame(
  fold_id = sprintf("fold_%02d", 1:9),
  train_end = as.Date(c(
    "2023-09-30", "2023-12-31", "2024-03-31", "2024-06-30", "2024-09-30",
    "2024-12-31", "2025-03-31", "2025-06-30", "2025-09-30"
  )),
  test_start = as.Date(c(
    "2023-10-01", "2024-01-01", "2024-04-01", "2024-07-01", "2024-10-01",
    "2025-01-01", "2025-04-01", "2025-07-01", "2025-10-01"
  )),
  test_end = as.Date(c(
    "2023-12-31", "2024-03-31", "2024-06-30", "2024-09-30", "2024-12-31",
    "2025-03-31", "2025-06-30", "2025-09-30", "2025-12-31"
  )),
  refresh = "saturday_weekly_frozen",
  stringsAsFactors = FALSE
)
write.csv(folds, file.path(output_dir, "temporal_split_manifest.csv"), row.names = FALSE)
audit_rows <- total_selection[
  total_selection$period_group == "development_2023_2025",
  c("gameid", "odds_timestamp", "game_datetime")
]
audit_rows$split <- ifelse(
  as.Date(audit_rows$game_datetime) < as.Date("2025-07-01"),
  "train",
  ifelse(
    as.Date(audit_rows$game_datetime) < as.Date("2025-09-01"),
    "validation",
    "test"
  )
)
audit_rows$prediction_time <- audit_rows$odds_timestamp
audit_rows$feature_available_time <- audit_rows$odds_timestamp
audit_rows$target_time <- audit_rows$game_datetime
write.csv(
  audit_rows[, c(
    "gameid", "split", "prediction_time", "feature_available_time", "target_time"
  )],
  file.path(output_dir, "temporal_point_in_time_audit.csv"),
  row.names = FALSE
)
print(coverage)
print(by_league)
