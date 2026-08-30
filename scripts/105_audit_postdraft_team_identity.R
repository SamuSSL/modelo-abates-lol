script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

connection <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir = file.path(project_root, "data", "processed", "lolkills.duckdb"),
  read_only = TRUE
)
on.exit(DBI::dbDisconnect(connection, shutdown = TRUE), add = TRUE)

identity <- DBI::dbGetQuery(connection, "
  with post as (
    select * from market_postdraft_quotes
    where gameid is not null
    qualify row_number() over (
      partition by gameid order by quote_time desc, snapshot_id desc
    ) = 1
  ),
  complete_team_totals as (
    select p.gameid
    from post p
    join market_team_totals_snapshots t
      on t.event_id = p.prematch_event_id and t.period = p.period
    where t.odds_timestamp <= p.live_open_time + interval 60 second
    group by p.gameid
    having count(distinct t.market) = 2
  )
  select p.gameid, l.team_home_market, l.team_away_market,
         g.blue_team_name, g.red_team_name
  from post p
  join complete_team_totals c on c.gameid = p.gameid
  join game_market_links l
    on l.event_id = p.prematch_event_id and l.period = p.period
  join canonical_games g on g.gameid = p.gameid
")

team_key <- function(value) {
  value <- gsub("\\s*\\(Kills\\)\\s*$", "", as.character(value), ignore.case = TRUE)
  value <- iconv(value, from = "", to = "ASCII//TRANSLIT")
  value <- tolower(value)
  gsub("[^a-z0-9]", "", value)
}

identity$home_key <- team_key(identity$team_home_market)
identity$away_key <- team_key(identity$team_away_market)
identity$blue_key <- team_key(identity$blue_team_name)
identity$red_key <- team_key(identity$red_team_name)
identity$exact_orientation <- (
  identity$home_key == identity$blue_key &
    identity$away_key == identity$red_key
) | (
  identity$home_key == identity$red_key &
  identity$away_key == identity$blue_key
)
normalized_edit_distance <- function(first, second) {
  denominator <- pmax(nchar(first), nchar(second), 1L)
  distance <- vapply(seq_along(first), function(index) {
    as.numeric(utils::adist(first[[index]], second[[index]], partial = FALSE))
  }, numeric(1L))
  distance / denominator
}
identity$direct_distance <-
  normalized_edit_distance(identity$home_key, identity$blue_key) +
  normalized_edit_distance(identity$away_key, identity$red_key)
identity$swapped_distance <-
  normalized_edit_distance(identity$home_key, identity$red_key) +
  normalized_edit_distance(identity$away_key, identity$blue_key)
identity$orientation_margin <- abs(
  identity$direct_distance - identity$swapped_distance
)
identity$fuzzy_orientation_valid <-
  identity$direct_distance != identity$swapped_distance &
  identity$orientation_margin >= 0.10

output <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "postdraft-team-total-joint-challenger",
  "team-identity-audit.csv"
)
utils::write.csv(identity, output, row.names = FALSE)
cat(sprintf(
  "all=%d exact=%d fuzzy_valid=%d invalid=%d\n",
  nrow(identity),
  sum(identity$exact_orientation),
  sum(identity$fuzzy_orientation_valid),
  sum(!identity$fuzzy_orientation_valid)
))
print(
  utils::head(identity[!identity$fuzzy_orientation_valid, ], 40L),
  row.names = FALSE
)
