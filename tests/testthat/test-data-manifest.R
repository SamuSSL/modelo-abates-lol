test_that("manifest records one immutable entry per seasonal file", {
  raw_dir <- file.path(tempdir(), paste0("oe-", sample.int(1e8, 1L)))
  dir.create(raw_dir, recursive = TRUE)

  years <- 2022:2026
  for (year in years) {
    file_name <- sprintf(
      "%d_LoL_esports_match_data_from_OraclesElixir.csv",
      year
    )
    writeLines(
      c("gameid,league", sprintf("game-%d,LCK", year)),
      file.path(raw_dir, file_name),
      useBytes = TRUE
    )
  }

  manifest <- build_data_manifest(raw_dir)

  expect_equal(manifest$season, years)
  expect_equal(nrow(manifest), 5L)
  expect_true(all(grepl("^[a-f0-9]{64}$", manifest$sha256)))
  expect_true(all(!grepl("^[A-Za-z]:", manifest$file_name)))
  expect_true(validate_data_manifest(manifest, raw_dir))
})

test_that("manifest rejects duplicate seasons and changed hashes", {
  raw_dir <- file.path(tempdir(), paste0("oe-", sample.int(1e8, 1L)))
  dir.create(raw_dir, recursive = TRUE)
  path <- file.path(
    raw_dir,
    "2022_LoL_esports_match_data_from_OraclesElixir.csv"
  )
  writeLines("gameid,league", path, useBytes = TRUE)

  manifest <- build_data_manifest(raw_dir)
  duplicated <- rbind(manifest, manifest)

  expect_error(
    validate_data_manifest(duplicated, raw_dir),
    "Duplicate season"
  )

  writeLines(c("gameid,league", "changed,LCK"), path, useBytes = TRUE)
  expect_error(
    validate_data_manifest(manifest, raw_dir),
    "SHA-256 mismatch"
  )
})

test_that("manifest YAML round-trip preserves immutable fields", {
  raw_dir <- file.path(tempdir(), paste0("oe-", sample.int(1e8, 1L)))
  dir.create(raw_dir, recursive = TRUE)
  path <- file.path(
    raw_dir,
    "2026_LoL_esports_match_data_from_OraclesElixir.csv"
  )
  writeLines(
    c("gameid,league", "game-2026,LCK"),
    path,
    useBytes = TRUE
  )
  manifest <- build_data_manifest(raw_dir)
  manifest_path <- tempfile(fileext = ".yml")

  write_data_manifest(manifest, manifest_path)
  restored <- read_data_manifest(manifest_path)

  expect_equal(restored, manifest)
  expect_true(validate_data_manifest(restored, raw_dir))
})
