test_that("champion taxonomy validates coverage and numeric scores", {
  taxonomy <- data.frame(
    champion = c("A", "B"),
    tank = c(TRUE, FALSE),
    fighter = c(FALSE, TRUE),
    assassin = FALSE,
    mage = FALSE,
    marksman = FALSE,
    support = FALSE,
    attack = c(0.2, 0.8),
    defense = c(0.9, 0.5),
    magic = c(0.1, 0.2),
    difficulty = c(0.3, 0.6),
    stringsAsFactors = FALSE
  )

  expect_true(validate_champion_taxonomy(taxonomy, c("A", "B")))
  expect_error(
    validate_champion_taxonomy(taxonomy, c("A", "C")),
    "Missing taxonomy champions"
  )
})

test_that("composition scores are deterministic and symmetric", {
  taxonomy <- data.frame(
    champion = c("Tank", "Mage", "Carry"),
    tank = c(TRUE, FALSE, FALSE),
    fighter = c(FALSE, FALSE, FALSE),
    assassin = c(FALSE, TRUE, FALSE),
    mage = c(FALSE, TRUE, FALSE),
    marksman = c(FALSE, FALSE, TRUE),
    support = c(FALSE, FALSE, FALSE),
    attack = c(0.2, 0.8, 1),
    defense = c(1, 0.2, 0.2),
    magic = c(0.1, 1, 0.1),
    difficulty = c(0.2, 0.8, 0.6),
    stringsAsFactors = FALSE
  )

  first <- score_composition_archetypes(
    c("Tank", "Mage", "Carry"),
    taxonomy
  )
  second <- score_composition_archetypes(
    c("Carry", "Tank", "Mage"),
    taxonomy
  )

  expect_equal(first, second)
  expect_equal(first$champion_count, 3L)
  expect_true(first$frontline_score > 0)
  expect_true(first$damage_score > 0)
})

test_that("composition scoring rejects duplicate champions", {
  taxonomy <- data.frame(
    champion = "A",
    tank = TRUE,
    fighter = FALSE,
    assassin = FALSE,
    mage = FALSE,
    marksman = FALSE,
    support = FALSE,
    attack = 0.5,
    defense = 0.5,
    magic = 0.5,
    difficulty = 0.5,
    stringsAsFactors = FALSE
  )

  expect_error(
    score_composition_archetypes(c("A", "A"), taxonomy),
    "Duplicate champions"
  )
})
