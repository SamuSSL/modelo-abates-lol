script_path <- file.path("scripts", "_load_project.R")
if (!file.exists(script_path)) {
  stop(
    "Execute este script a partir da raiz do projeto.",
    call. = FALSE
  )
}
source(script_path, local = TRUE)
project_root <- load_lolkills_project()
config <- yaml::read_yaml(
  file.path(project_root, "config", "default.yml")
)

raw_dir <- file.path(
  project_root,
  config$paths$raw_oracles_elixir
)
manifest_path <- file.path(
  project_root,
  config$paths$raw_manifest
)

manifest <- build_data_manifest(raw_dir)
expected_seasons <- as.integer(config$data$expected_seasons)
if (!identical(manifest$season, expected_seasons)) {
  stop(
    "Temporadas encontradas: ",
    paste(manifest$season, collapse = ", "),
    ". Esperadas: ",
    paste(expected_seasons, collapse = ", "),
    ".",
    call. = FALSE
  )
}

validate_data_manifest(manifest, raw_dir)
write_data_manifest(manifest, manifest_path)

message("Manifesto registrado em: ", manifest_path)
print(
  manifest[, c("season", "file_name", "size_bytes", "sha256")],
  row.names = FALSE
)

