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
  "pinnacle-prematch-forecast-soft-open"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = file.path(project_root, "data", "processed", "lolkills.duckdb"),
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

quotes <- DBI::dbGetQuery(connection, "
  select q.gameid, s.line,
         s.odds_over, s.odds_under,
         s.odds_timestamp as final_pinnacle_time
  from market_postdraft_quotes q
  join market_odds_snapshots s
    on s.event_id = q.prematch_event_id and s.period = q.period
  where q.gameid is not null
    and s.market = 'totals'
    and s.alt_line_id is null
    and s.odds_timestamp <= q.quote_time
    and s.odds_over > 1 and s.odds_under > 1
  qualify row_number() over (
    partition by q.gameid, s.line
    order by s.odds_timestamp desc, s.snapshot_id desc
  ) = 1
")
quotes$final_pinnacle_time <- format(
  as.POSIXct(quotes$final_pinnacle_time, tz = "UTC"),
  "%Y-%m-%dT%H:%M:%SZ",
  tz = "UTC"
)
utils::write.csv(
  quotes,
  file.path(output_dir, "pinnacle-final-quotes-by-line.csv"),
  row.names = FALSE
)
cat(nrow(quotes), "cotações Pinnacle finais exportadas.\n")
