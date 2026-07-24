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
artifact_dir <- file.path(project_root, config$paths$artifacts)
dir.create(artifact_dir, recursive = TRUE, showWarnings = FALSE)

manifest <- read_data_manifest(manifest_path)
validate_data_manifest(manifest, raw_dir)

audit_rows <- lapply(manifest$file_name, function(file_name) {
  audit_oe_file(
    file.path(raw_dir, file_name),
    expected_rows_per_game = config$data$expected_rows_per_game
  )
})
audit <- do.call(rbind, audit_rows)
audit_path <- file.path(artifact_dir, "oracle_elixir_file_audit.csv")
utils::write.csv(audit, audit_path, row.names = FALSE, na = "")

message("Auditoria estrutural gravada em: ", audit_path)
print(audit, row.names = FALSE)

