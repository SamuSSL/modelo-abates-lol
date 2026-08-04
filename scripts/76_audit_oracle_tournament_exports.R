script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

champion_path <- file.path(
  "C:/Users/Samuel/Downloads",
  "LCK 2026 Rounds 1-2 - Champion Stats - OraclesElixir.csv"
)
team_path <- file.path(
  "C:/Users/Samuel/Downloads",
  "LCK 2026 Rounds 1-2 - Team Stats - OraclesElixir.csv"
)
raw_path <- file.path(
  project_root,
  "data",
  "raw",
  "oracles_elixir",
  "2026_LoL_esports_match_data_from_OraclesElixir.csv"
)
output_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "lol-kills-next-step-2026"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

required_paths <- c(champion_path, team_path, raw_path)
missing_paths <- required_paths[!file.exists(required_paths)]
if (length(missing_paths) > 0L) {
  stop(
    "Arquivos ausentes: ",
    paste(missing_paths, collapse = ", "),
    call. = FALSE
  )
}

parse_percent <- function(value) {
  suppressWarnings(as.numeric(sub("%", "", value, fixed = TRUE)))
}

safe_ratio <- function(numerator, denominator) {
  ifelse(
    is.finite(denominator) & denominator > 0,
    numerator / denominator,
    NA_real_
  )
}

round_percent <- function(value) {
  round(100 * value)
}

team_export <- data.table::fread(
  team_path,
  na.strings = c("", "NA", "-"),
  showProgress = FALSE
)
champion_export <- data.table::fread(
  champion_path,
  na.strings = c("", "NA", "-"),
  showProgress = FALSE
)
raw <- data.table::fread(
  raw_path,
  showProgress = FALSE
)
raw$date <- as.POSIXct(raw$date, tz = "UTC")
period_start <- as.POSIXct("2026-04-01 00:00:00", tz = "UTC")
period_end <- as.POSIXct("2026-06-01 00:00:00", tz = "UTC")
period <- raw[
  league == "LCK" &
    split == "Rounds 1-2" &
    date >= period_start &
    date < period_end
]
team_rows <- period[tolower(position) == "team"]
player_rows <- period[tolower(position) != "team"]

opponent_columns <- c(
  "gameid",
  "teamid",
  "teamname",
  "minionkills",
  "monsterkills"
)
opponents <- team_rows[, ..opponent_columns]
data.table::setnames(
  opponents,
  c(
    "teamid",
    "teamname",
    "minionkills",
    "monsterkills"
  ),
  c(
    "opponent_teamid",
    "opponent_teamname",
    "opponent_minionkills",
    "opponent_monsterkills"
  )
)
team_rows <- merge(
  team_rows,
  opponents,
  by = "gameid",
  allow.cartesian = TRUE
)
team_rows <- team_rows[teamid != opponent_teamid]
team_rows[, duration_minutes := gamelength / 60]
team_rows[, lane_share := safe_ratio(
  minionkills,
  minionkills + opponent_minionkills
)]
team_rows[, jungle_share := safe_ratio(
  monsterkills,
  monsterkills + opponent_monsterkills
)]
team_rows[, control_wards_per_minute := safe_ratio(
  controlwardsbought,
  duration_minutes
)]

team_reconstructed <- team_rows[, .(
  GP_raw = .N,
  W_raw = sum(result, na.rm = TRUE),
  L_raw = sum(1 - result, na.rm = TRUE),
  AGT_raw = mean(duration_minutes, na.rm = TRUE),
  K_raw = sum(teamkills, na.rm = TRUE),
  D_raw = sum(teamdeaths, na.rm = TRUE),
  KD_raw = safe_ratio(
    sum(teamkills, na.rm = TRUE),
    sum(teamdeaths, na.rm = TRUE)
  ),
  CKPM_raw = mean(ckpm, na.rm = TRUE),
  GPR_raw = mean(gpr, na.rm = TRUE),
  GSPD_raw = 100 * mean(gspd, na.rm = TRUE),
  GD15_raw = mean(golddiffat15, na.rm = TRUE),
  `FB%_raw` = round_percent(mean(firstblood, na.rm = TRUE)),
  `FT%_raw` = round_percent(mean(firsttower, na.rm = TRUE)),
  `F3T%_raw` = round_percent(mean(firsttothreetowers, na.rm = TRUE)),
  PPG_raw = mean(turretplates, na.rm = TRUE),
  `HLD%_raw` = round_percent(safe_ratio(
    sum(heralds, na.rm = TRUE),
    sum(heralds, na.rm = TRUE) + sum(opp_heralds, na.rm = TRUE)
  )),
  `GRB%_raw` = round_percent(safe_ratio(
    sum(void_grubs, na.rm = TRUE),
    sum(void_grubs, na.rm = TRUE) + sum(opp_void_grubs, na.rm = TRUE)
  )),
  `FD%_raw` = round_percent(mean(firstdragon, na.rm = TRUE)),
  `DRG%_raw` = round_percent(safe_ratio(
    sum(elementaldrakes, na.rm = TRUE),
    sum(elementaldrakes, na.rm = TRUE) +
      sum(opp_elementaldrakes, na.rm = TRUE)
  )),
  `ELD%_raw` = round_percent(safe_ratio(
    sum(elders, na.rm = TRUE),
    sum(elders, na.rm = TRUE) + sum(opp_elders, na.rm = TRUE)
  )),
  `FBN%_raw` = round_percent(mean(firstbaron, na.rm = TRUE)),
  `BN%_raw` = round_percent(safe_ratio(
    sum(barons, na.rm = TRUE),
    sum(barons, na.rm = TRUE) + sum(opp_barons, na.rm = TRUE)
  )),
  `LNE%_raw` = 100 * mean(lane_share, na.rm = TRUE),
  `JNG%_raw` = 100 * mean(jungle_share, na.rm = TRUE),
  WPM_raw = mean(wpm, na.rm = TRUE),
  CWPM_raw = mean(control_wards_per_minute, na.rm = TRUE),
  WCPM_raw = mean(wcpm, na.rm = TRUE)
), by = .(Team = teamname)]

team_numeric <- data.table::copy(team_export)
percent_columns <- names(team_numeric)[grepl("%$", names(team_numeric))]
for (column in percent_columns) {
  data.table::set(
    team_numeric,
    j = column,
    value = parse_percent(team_numeric[[column]])
  )
}
team_numeric[, GSPD := parse_percent(GSPD)]
team_reconciliation <- merge(
  team_numeric,
  team_reconstructed,
  by = "Team",
  all = TRUE
)
comparison_map <- c(
  GP = "GP_raw",
  W = "W_raw",
  L = "L_raw",
  AGT = "AGT_raw",
  K = "K_raw",
  D = "D_raw",
  KD = "KD_raw",
  CKPM = "CKPM_raw",
  GPR = "GPR_raw",
  GSPD = "GSPD_raw",
  GD15 = "GD15_raw",
  `FB%` = "FB%_raw",
  `FT%` = "FT%_raw",
  `F3T%` = "F3T%_raw",
  PPG = "PPG_raw",
  `HLD%` = "HLD%_raw",
  `GRB%` = "GRB%_raw",
  `FD%` = "FD%_raw",
  `DRG%` = "DRG%_raw",
  `ELD%` = "ELD%_raw",
  `FBN%` = "FBN%_raw",
  `BN%` = "BN%_raw",
  `LNE%` = "LNE%_raw",
  `JNG%` = "JNG%_raw",
  WPM = "WPM_raw",
  CWPM = "CWPM_raw",
  WCPM = "WCPM_raw"
)
for (export_column in names(comparison_map)) {
  raw_column <- comparison_map[[export_column]]
  difference_column <- paste0(export_column, "_difference")
  data.table::set(
    team_reconciliation,
    j = difference_column,
    value = as.numeric(team_reconciliation[[export_column]]) -
      as.numeric(team_reconciliation[[raw_column]])
  )
}

position_map <- c(
  top = "Top",
  jng = "Jungle",
  mid = "Middle",
  bot = "ADC",
  sup = "Support"
)
player_rows[, Pos := unname(position_map[tolower(position)])]
champion_reconstructed <- player_rows[, .(
  GP_raw = .N,
  K_raw = sum(kills, na.rm = TRUE),
  D_raw = sum(deaths, na.rm = TRUE),
  A_raw = sum(assists, na.rm = TRUE),
  `W%_raw` = round_percent(mean(result, na.rm = TRUE)),
  KDA_raw = safe_ratio(
    sum(kills, na.rm = TRUE) + sum(assists, na.rm = TRUE),
    sum(deaths, na.rm = TRUE)
  ),
  KP_raw = 100 * mean(safe_ratio(kills + assists, teamkills), na.rm = TRUE),
  `DTH%_raw` = 100 * mean(safe_ratio(deaths, teamdeaths), na.rm = TRUE),
  `FB%_raw` = round_percent(mean(
    firstbloodkill + firstbloodassist > 0,
    na.rm = TRUE
  )),
  GD10_raw = mean(golddiffat10, na.rm = TRUE),
  XPD10_raw = mean(xpdiffat10, na.rm = TRUE),
  CSD10_raw = mean(csdiffat10, na.rm = TRUE),
  CSPM_raw = mean(cspm, na.rm = TRUE),
  DPM_raw = mean(dpm, na.rm = TRUE),
  `DMG%_raw` = 100 * mean(damageshare, na.rm = TRUE),
  `GOLD%_raw` = 100 * mean(earnedgoldshare, na.rm = TRUE),
  WPM_raw = mean(wpm, na.rm = TRUE),
  WCPM_raw = mean(wcpm, na.rm = TRUE)
), by = .(Champion = champion, Pos)]

champion_numeric <- data.table::copy(champion_export)
champion_percent_columns <- names(champion_numeric)[
  grepl("%$", names(champion_numeric)) |
    names(champion_numeric) %in% c("KP")
]
for (column in champion_percent_columns) {
  data.table::set(
    champion_numeric,
    j = column,
    value = parse_percent(champion_numeric[[column]])
  )
}
numeric_columns <- setdiff(
  names(champion_numeric),
  c("Champion", "Pos")
)
for (column in numeric_columns) {
  data.table::set(
    champion_numeric,
    j = column,
    value = suppressWarnings(as.numeric(champion_numeric[[column]]))
  )
}
champion_reconciliation <- merge(
  champion_numeric,
  champion_reconstructed,
  by = c("Champion", "Pos"),
  all = TRUE
)

audit_summary <- data.frame(
  check = c(
    "page_period_start",
    "page_period_end_exclusive",
    "raw_games_in_period",
    "raw_team_rows_in_period",
    "raw_player_rows_in_period",
    "team_export_rows",
    "team_export_gp_sum",
    "team_export_wins_sum",
    "team_export_losses_sum",
    "champion_export_rows",
    "champion_export_gp_sum",
    "raw_unique_patches",
    "team_export_duplicate_keys",
    "champion_export_duplicate_keys",
    "team_export_missing_cells",
    "champion_export_missing_cells",
    "team_export_sha256",
    "champion_export_sha256"
  ),
  value = c(
    format(period_start, tz = "UTC"),
    format(period_end, tz = "UTC"),
    data.table::uniqueN(period$gameid),
    nrow(team_rows),
    nrow(player_rows),
    nrow(team_export),
    sum(team_export$GP),
    sum(team_export$W),
    sum(team_export$L),
    nrow(champion_export),
    sum(champion_export$GP),
    paste(sort(unique(period$patch)), collapse = "|"),
    sum(duplicated(team_export$Team)),
    sum(duplicated(champion_export[, .(Champion, Pos)])),
    sum(is.na(team_export)),
    sum(is.na(champion_export)),
    digest::digest(team_path, algo = "sha256", file = TRUE),
    digest::digest(champion_path, algo = "sha256", file = TRUE)
  ),
  stringsAsFactors = FALSE
)

missingness <- rbind(
  data.frame(
    dataset = "team_export",
    column = names(team_export),
    rows = nrow(team_export),
    missing = vapply(team_export, function(x) sum(is.na(x)), numeric(1L)),
    stringsAsFactors = FALSE
  ),
  data.frame(
    dataset = "champion_export",
    column = names(champion_export),
    rows = nrow(champion_export),
    missing = vapply(
      champion_export,
      function(x) sum(is.na(x)),
      numeric(1L)
    ),
    stringsAsFactors = FALSE
  )
)
missingness$missing_rate <- missingness$missing / missingness$rows

data.table::fwrite(
  audit_summary,
  file.path(output_dir, "oracle_export_audit_summary.csv")
)
data.table::fwrite(
  team_reconciliation,
  file.path(output_dir, "team_export_reconciliation.csv")
)
data.table::fwrite(
  champion_reconciliation,
  file.path(output_dir, "champion_export_reconciliation.csv")
)
data.table::fwrite(
  missingness,
  file.path(output_dir, "oracle_export_missingness.csv")
)

print(audit_summary, row.names = FALSE)
print(
  team_reconciliation[
    ,
    c(
      "Team",
      "GP",
      "GP_raw",
      "CKPM",
      "CKPM_raw",
      "GPR",
      "GPR_raw",
      "GSPD",
      "GSPD_raw"
    ),
    with = FALSE
  ],
  row.names = FALSE
)
