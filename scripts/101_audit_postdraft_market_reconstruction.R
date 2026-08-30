script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "bettingiscool.yml"
))

database_path <- file.path(
  project_root,
  "data",
  "processed",
  "lolkills.duckdb"
)
output_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "postdraft-market-reconstruction"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = database_path,
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

live_start <- as.POSIXct(config$coverage$live_history_start, tz = "UTC")

audit_query <- "
with verified_links as (
  select * from game_market_links where link_status = 'verified'
  qualify row_number() over (
    partition by gameid order by reviewed_at desc, link_id desc
  ) = 1
), prematch_fixtures as (
  select * from market_fixtures
  qualify row_number() over (
    partition by event_id order by retrieved_at desc, version desc
  ) = 1
), live_fixtures as (
  select * from market_live_fixtures
  qualify row_number() over (
    partition by event_id order by retrieved_at desc, version desc
  ) = 1
), eligible as (
  select l.gameid, l.event_id as prematch_event_id, l.period,
         l.league_canonical, l.competition, f.parent_id as root_event_id,
         f.runner_home, f.runner_away, f.starts
  from verified_links l
  join prematch_fixtures f on f.event_id = l.event_id
  where f.resulting_unit = 'Kills'
    and f.parent_id is not null
    and f.starts >= ?
), live_pairs as (
  select e.*, live.event_id as live_event_id,
         count(live.event_id) over (
           partition by e.gameid
         ) as live_pair_count
  from eligible e
  left join live_fixtures live
    on live.parent_id = e.root_event_id
   and lower(trim(live.runner_home)) = lower(trim(e.runner_home))
   and lower(trim(live.runner_away)) = lower(trim(e.runner_away))
   and live.resulting_unit = 'Kills'
   and live.live_status = 1
), boundaries as (
  select p.*, min(s.odds_timestamp) as live_open_time,
         count(s.snapshot_id) as live_snapshot_rows
  from live_pairs p
  left join market_live_odds_snapshots s
    on s.event_id = p.live_event_id
   and s.period = p.period
   and s.market = 'totals'
   and s.alt_line_id is null
  group by all
), prematch_availability as (
  select b.*, count(s.snapshot_id) as prematch_rows_before_live
  from boundaries b
  left join market_odds_snapshots s
    on s.event_id = b.prematch_event_id
   and s.period = b.period
   and s.market = 'totals'
   and s.alt_line_id is null
   and s.odds_timestamp < b.live_open_time
  group by all
)
select a.*,
       case
         when a.live_event_id is null then 'missing_live_fixture'
         when a.live_pair_count <> 1 then 'ambiguous_live_fixture'
         when a.live_open_time is null then 'missing_live_period_odds'
         when a.prematch_rows_before_live = 0 then 'missing_prematch_before_live'
         when q.gameid is null then 'view_pairing_failure'
         else 'reconstructed'
       end as reconstruction_status,
       q.quote_time, q.freshness_seconds, q.line, q.odds_over,
       q.odds_under, q.true_probability_over, q.true_probability_under,
       q.max_win
from prematch_availability a
left join market_postdraft_quotes q on q.gameid = a.gameid
"

audit <- DBI::dbGetQuery(
  connection,
  audit_query,
  params = list(live_start)
)

coverage_by_league <- DBI::dbGetQuery(
  connection,
  paste0(
    "with audit as (", audit_query, ") ",
    "select league_canonical, count(*) as eligible_maps, ",
    "sum(case when reconstruction_status = 'reconstructed' then 1 else 0 end) ",
    "as reconstructed_maps, ",
    "reconstructed_maps / eligible_maps::double as coverage_rate ",
    "from audit group by league_canonical order by league_canonical"
  ),
  params = list(live_start)
)

failure_summary <- as.data.frame(table(
  audit$reconstruction_status,
  useNA = "ifany"
))
names(failure_summary) <- c("reconstruction_status", "maps")
failure_summary <- failure_summary[
  failure_summary$maps > 0,
  ,
  drop = FALSE
]

quotes <- audit[
  audit$reconstruction_status == "reconstructed",
  ,
  drop = FALSE
]
freshness_by_league <- do.call(rbind, lapply(
  split(quotes, quotes$league_canonical),
  function(rows) {
    data.frame(
      league_canonical = rows$league_canonical[[1L]],
      maps = nrow(rows),
      median_freshness_seconds = median(rows$freshness_seconds),
      p90_freshness_seconds = unname(stats::quantile(
        rows$freshness_seconds,
        0.90
      )),
      maximum_freshness_seconds = max(rows$freshness_seconds),
      share_within_60_seconds = mean(rows$freshness_seconds <= 60),
      share_within_300_seconds = mean(rows$freshness_seconds <= 300)
    )
  }
))
rownames(freshness_by_league) <- NULL

overall_summary <- data.frame(
  eligible_maps = nrow(audit),
  reconstructed_maps = nrow(quotes),
  coverage_rate = nrow(quotes) / nrow(audit),
  median_freshness_seconds = median(quotes$freshness_seconds),
  p90_freshness_seconds = unname(stats::quantile(
    quotes$freshness_seconds,
    0.90
  )),
  p95_freshness_seconds = unname(stats::quantile(
    quotes$freshness_seconds,
    0.95
  )),
  maximum_freshness_seconds = max(quotes$freshness_seconds),
  share_within_60_seconds = mean(quotes$freshness_seconds <= 60),
  share_within_300_seconds = mean(quotes$freshness_seconds <= 300)
)

utils::write.csv(
  overall_summary,
  file.path(output_dir, "coverage-summary.csv"),
  row.names = FALSE,
  na = ""
)
utils::write.csv(
  coverage_by_league,
  file.path(output_dir, "coverage-by-league.csv"),
  row.names = FALSE,
  na = ""
)
utils::write.csv(
  failure_summary,
  file.path(output_dir, "failure-summary.csv"),
  row.names = FALSE,
  na = ""
)
utils::write.csv(
  freshness_by_league,
  file.path(output_dir, "freshness-by-league.csv"),
  row.names = FALSE,
  na = ""
)

print(overall_summary)
print(coverage_by_league)
print(failure_summary)
print(freshness_by_league)
