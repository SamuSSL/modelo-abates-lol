script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop("Execute este script a partir da raiz do projeto.", call. = FALSE)
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()

raw_dir <- file.path(project_root, "data", "raw", "oracles_elixir")
raw_files <- list.files(
  raw_dir,
  pattern = "^[0-9]{4}_.*\\.csv$",
  full.names = TRUE
)
output_dir <- file.path(
  project_root,
  "artifacts",
  "modeling-research",
  "lol-kills-next-step-2026"
)
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

candidate_catalog <- data.frame(
  field = c(
    "gamelength",
    "teamkills",
    "teamdeaths",
    "team kpm",
    "ckpm",
    "firstblood",
    "killsat10",
    "deathsat10",
    "killsat15",
    "deathsat15",
    "golddiffat10",
    "xpdiffat10",
    "csdiffat10",
    "golddiffat15",
    "xpdiffat15",
    "csdiffat15",
    "firstdragon",
    "dragons",
    "elementaldrakes",
    "elders",
    "firstherald",
    "heralds",
    "void_grubs",
    "firstbaron",
    "barons",
    "atakhans",
    "firsttower",
    "firsttothreetowers",
    "towers",
    "turretplates",
    "inhibitors",
    "damagetochampions",
    "dpm",
    "damagetakenperminute",
    "damagemitigatedperminute",
    "damagetotowers",
    "gpr",
    "gspd",
    "earned gpm",
    "goldspent",
    "minionkills",
    "monsterkills",
    "monsterkillsownjungle",
    "monsterkillsenemyjungle",
    "wpm",
    "wcpm",
    "controlwardsbought",
    "vspm"
  ),
  mechanism = c(
    "duration",
    "target_component",
    "target_component",
    "kill_rate",
    "pace",
    "early_aggression",
    "early_aggression",
    "early_aggression",
    "early_aggression",
    "early_aggression",
    "early_strength",
    "early_strength",
    "early_strength",
    "early_strength",
    "early_strength",
    "early_strength",
    "objective_control",
    "objective_control",
    "objective_control",
    "objective_control",
    "objective_control",
    "objective_control",
    "objective_control",
    "objective_control",
    "objective_control",
    "objective_control",
    "structure_control",
    "structure_control",
    "structure_control",
    "structure_control",
    "structure_control",
    "combat_efficiency",
    "combat_efficiency",
    "combat_efficiency",
    "combat_efficiency",
    "structure_pressure",
    "relative_strength",
    "relative_strength",
    "economy",
    "economy",
    "lane_control",
    "jungle_control",
    "jungle_control",
    "jungle_invasion",
    "vision",
    "vision",
    "vision",
    "vision"
  ),
  intended_transformation = c(
    "rolling distribution",
    "rolling attack ratio",
    "rolling concession ratio",
    "rolling rate ratio",
    "rolling pace distribution",
    "rolling probability",
    "rolling rate",
    "rolling concession rate",
    "rolling rate",
    "rolling concession rate",
    "rolling mean and volatility",
    "rolling mean and volatility",
    "rolling mean and volatility",
    "rolling mean and volatility",
    "rolling mean and volatility",
    "rolling mean and volatility",
    "rolling probability",
    "rolling control share",
    "rolling control share",
    "diagnostic only",
    "rolling probability",
    "rolling control share",
    "era-specific control share",
    "rolling probability",
    "rolling control share",
    "era-specific control share",
    "rolling probability",
    "rolling probability",
    "rolling rate",
    "rolling rate",
    "rolling rate",
    "rolling per minute",
    "rolling per minute",
    "rolling per minute",
    "rolling per minute",
    "rolling per minute",
    "rolling relative rating",
    "rolling relative rating",
    "rolling per minute",
    "rolling per minute",
    "rolling share",
    "rolling share",
    "rolling share",
    "rolling share",
    "rolling per minute",
    "rolling per minute",
    "rolling per minute",
    "rolling per minute"
  ),
  stringsAsFactors = FALSE
)
candidate_catalog$model_status <- "candidate"
candidate_catalog$exclusion_reason <- NA_character_
candidate_catalog$model_status[
  candidate_catalog$field %in% c("firstblood", "gspd")
] <- "excluded"
candidate_catalog$exclusion_reason[
  candidate_catalog$field %in% c("firstblood", "gspd")
] <- paste(
  "Excluded from the active model by product decision on",
  "2026-07-30; retained only for source auditing."
)
candidate_catalog$mechanism[
  candidate_catalog$field == "teamdeaths"
] <- "source_diagnostic"
candidate_catalog$intended_transformation[
  candidate_catalog$field == "teamdeaths"
] <- paste(
  "diagnostic only; concession uses opponent teamkills"
)

identity_columns <- c(
  "gameid",
  "datacompleteness",
  "league",
  "year",
  "split",
  "date",
  "patch",
  "side",
  "position",
  "teamname",
  "teamid"
)
pair_columns <- c(
  "opp_dragons",
  "opp_elementaldrakes",
  "opp_elders",
  "opp_heralds",
  "opp_void_grubs",
  "opp_barons",
  "opp_atakhans",
  "opp_towers",
  "opp_turretplates",
  "opp_inhibitors"
)
selected_columns <- unique(c(
  identity_columns,
  candidate_catalog$field,
  pair_columns
))

all_rows <- lapply(raw_files, function(path) {
  available_columns <- names(data.table::fread(
    path,
    nrows = 0L,
    showProgress = FALSE
  ))
  missing_columns <- setdiff(selected_columns, available_columns)
  data <- data.table::fread(
    path,
    select = intersect(selected_columns, available_columns),
    showProgress = FALSE
  )
  for (column in missing_columns) {
    data[, (column) := NA_real_]
  }
  data[, source_file := basename(path)]
  data
})
rows <- data.table::rbindlist(all_rows, fill = TRUE)
rows <- rows[tolower(position) == "team"]
rows[, league_canonical := canonicalize_league(as.character(league))]
rows[, competition_role := classify_competition_role(as.character(league))]
rows <- rows[competition_role %in% c("target", "supporting")]
games_before_explicit_exclusions <- data.table::uniqueN(rows$gameid)
exclusion_config <- yaml::read_yaml(file.path(
  project_root,
  "config",
  "game-exclusions.yml"
))
excluded_game_ids <- vapply(
  exclusion_config$exclusions,
  function(exclusion) as.character(exclusion$gameid),
  character(1L)
)
rows <- rows[!gameid %in% excluded_game_ids]

field_missingness <- data.table::rbindlist(lapply(
  candidate_catalog$field,
  function(field) {
    rows[, .(
      team_rows = .N,
      games = data.table::uniqueN(gameid),
      missing = sum(is.na(get(field))),
      missing_rate = mean(is.na(get(field))),
      nonzero_rate = mean(
        suppressWarnings(as.numeric(get(field))) != 0,
        na.rm = TRUE
      )
    ), by = .(year, league_canonical)][
      ,
      field := field
    ][]
  }
), fill = TRUE)
field_missingness <- merge(
  field_missingness,
  candidate_catalog,
  by = "field",
  all.x = TRUE
)
data.table::setcolorder(
  field_missingness,
  c(
    "year",
    "league_canonical",
    "field",
    "mechanism",
    "intended_transformation",
    "team_rows",
    "games",
    "missing",
    "missing_rate",
    "nonzero_rate"
  )
)
data.table::setorder(
  field_missingness,
  year,
  league_canonical,
  mechanism,
  field
)

schema_rows <- data.table::rbindlist(lapply(raw_files, function(path) {
  columns <- names(data.table::fread(
    path,
    nrows = 0L,
    showProgress = FALSE
  ))
  data.table::data.table(
    source_file = basename(path),
    source_year = as.integer(substr(basename(path), 1L, 4L)),
    columns = length(columns),
    schema_sha256 = digest::digest(columns, algo = "sha256"),
    candidate_fields_present = sum(candidate_catalog$field %in% columns),
    candidate_fields_missing = paste(
      setdiff(candidate_catalog$field, columns),
      collapse = "|"
    )
  )
}))

duplicate_keys <- rows[
  ,
  .N,
  by = .(gameid, side)
][N > 1L]
game_pairs <- rows[
  ,
  .(
    sides = data.table::uniqueN(side),
    team_kills_sum = sum(teamkills, na.rm = TRUE),
    team_deaths_sum = sum(teamdeaths, na.rm = TRUE),
    total_gold_diff_15 = sum(golddiffat15, na.rm = TRUE),
    duration_min = min(gamelength, na.rm = TRUE),
    duration_max = max(gamelength, na.rm = TRUE)
  ),
  by = gameid
]
integrity <- data.frame(
  check = c(
    "games_before_explicit_exclusions",
    "games_after_explicit_exclusions",
    "team_rows",
    "games",
    "duplicate_game_side_keys",
    "games_without_two_sides",
    "games_kills_deaths_identity_failure",
    "games_gold_diff_15_zero_sum_failure",
    "games_duration_disagreement",
    "rows_nonpositive_duration",
    "rows_negative_teamkills",
    "rows_negative_teamdeaths",
    "datacompleteness_levels",
    "schema_versions",
    "schema_hashes"
  ),
  value = c(
    games_before_explicit_exclusions,
    data.table::uniqueN(rows$gameid),
    nrow(rows),
    data.table::uniqueN(rows$gameid),
    nrow(duplicate_keys),
    sum(game_pairs$sides != 2L),
    sum(game_pairs$team_kills_sum != game_pairs$team_deaths_sum),
    sum(abs(game_pairs$total_gold_diff_15) > 1e-8),
    sum(game_pairs$duration_min != game_pairs$duration_max),
    sum(rows$gamelength <= 0, na.rm = TRUE),
    sum(rows$teamkills < 0, na.rm = TRUE),
    sum(rows$teamdeaths < 0, na.rm = TRUE),
    paste(sort(unique(rows$datacompleteness)), collapse = "|"),
    nrow(schema_rows),
    data.table::uniqueN(schema_rows$schema_sha256)
  ),
  stringsAsFactors = FALSE
)

data.table::fwrite(
  candidate_catalog,
  file.path(output_dir, "oracle_candidate_field_catalog.csv")
)
data.table::fwrite(
  field_missingness,
  file.path(output_dir, "oracle_candidate_field_missingness.csv")
)
data.table::fwrite(
  schema_rows,
  file.path(output_dir, "oracle_candidate_schema.csv")
)
data.table::fwrite(
  integrity,
  file.path(output_dir, "oracle_candidate_integrity.csv")
)

print(integrity, row.names = FALSE)
print(schema_rows, row.names = FALSE)
