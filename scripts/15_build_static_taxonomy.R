script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
version <- "16.14.1"
source_url <- paste0(
  "https://ddragon.leagueoflegends.com/cdn/",
  version,
  "/data/en_US/champion.json"
)
payload <- jsonlite::fromJSON(source_url, simplifyDataFrame = FALSE)
champions <- payload$data
rows <- lapply(champions, function(champion) {
  tags <- as.character(unlist(champion$tags))
  detail_url <- paste0(
    "https://ddragon.leagueoflegends.com/cdn/",
    version,
    "/data/en_US/champion/",
    champion$id,
    ".json"
  )
  detail_payload <- jsonlite::fromJSON(
    detail_url,
    simplifyDataFrame = FALSE
  )
  detail <- detail_payload$data[[champion$id]]
  functional <- derive_functional_champion_scores(detail)
  base <- data.frame(
    champion = as.character(champion$name),
    tank = "Tank" %in% tags,
    fighter = "Fighter" %in% tags,
    assassin = "Assassin" %in% tags,
    mage = "Mage" %in% tags,
    marksman = "Marksman" %in% tags,
    support = "Support" %in% tags,
    attack = as.numeric(champion$info$attack) / 10,
    defense = as.numeric(champion$info$defense) / 10,
    magic = as.numeric(champion$info$magic) / 10,
    difficulty = as.numeric(champion$info$difficulty) / 10,
    stringsAsFactors = FALSE
  )
  for (name in names(functional)) {
    base[[name]] <- functional[[name]]
  }
  base
})
taxonomy <- do.call(rbind, rows)
taxonomy <- taxonomy[order(taxonomy$champion), , drop = FALSE]
rownames(taxonomy) <- NULL
coverage <- utils::read.csv(
  file.path(
    project_root,
    "artifacts",
    "research",
    "champion_catalog_coverage.csv"
  ),
  stringsAsFactors = FALSE,
  check.names = FALSE
)
validate_champion_taxonomy(taxonomy, coverage$champion)
output_dir <- file.path(project_root, "config", "taxonomy")
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
taxonomy_path <- file.path(output_dir, "champions-2026.yml")
manifest_path <- file.path(output_dir, "manifest.yml")
yaml::write_yaml(
  list(
    version = "2026-functional-v2",
    champions = split(taxonomy, seq_len(nrow(taxonomy)))
  ),
  taxonomy_path
)
source_sha256 <- digest::digest(
  readLines(source_url, warn = FALSE),
  algo = "sha256",
  serialize = FALSE
)
yaml::write_yaml(
  list(
    taxonomy_version = "2026-functional-v2",
    data_dragon_version = version,
    source_url = source_url,
    source_sha256 = source_sha256,
    generated_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
    champion_count = nrow(taxonomy),
    historical_coverage_count = nrow(coverage),
    rework_versions = FALSE,
    functional_method = "deterministic_kit_text_v1",
    functional_columns = .functional_champion_columns()
  ),
  manifest_path
)
cat(
  "Taxonomia criada:",
  nrow(taxonomy),
  "campeoes; cobertura historica completa.\n"
)
