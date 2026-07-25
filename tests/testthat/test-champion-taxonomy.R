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

test_that("functional taxonomy returns complete archetypes and confidence", {
  functional <- c(
    "engage", "disengage", "dive", "pick", "poke", "siege",
    "frontline", "protect", "scaling", "early_pressure",
    "skirmish", "split_push", "wave_clear", "mobility",
    "crowd_control", "global_pressure", "damage_physical",
    "damage_magic", "execution_difficulty", "snowball_dependency"
  )
  taxonomy <- data.frame(
    champion = paste0("C", 1:5),
    tank = c(TRUE, FALSE, FALSE, FALSE, FALSE),
    fighter = FALSE,
    assassin = FALSE,
    mage = c(FALSE, TRUE, TRUE, FALSE, FALSE),
    marksman = c(FALSE, FALSE, FALSE, TRUE, FALSE),
    support = c(FALSE, FALSE, FALSE, FALSE, TRUE),
    attack = rep(0.5, 5),
    defense = rep(0.5, 5),
    magic = rep(0.5, 5),
    difficulty = rep(0.5, 5),
    stringsAsFactors = FALSE
  )
  for (column in functional) {
    taxonomy[[column]] <- 0.2
  }
  taxonomy$engage <- c(1, 0.8, 0.8, 0.2, 0.7)
  taxonomy$crowd_control <- c(1, 0.7, 0.8, 0.1, 0.9)
  taxonomy$frontline <- c(1, 0.1, 0.1, 0.1, 0.5)

  result <- score_composition_archetypes(
    taxonomy$champion,
    taxonomy
  )

  expect_true(all(c(
    "engage_score",
    "pick_score",
    "poke_siege_score",
    "dive_score",
    "protect_score",
    "front_to_back_score",
    "split_map_score",
    "skirmish_score",
    "scaling_score",
    "primary_archetype",
    "secondary_archetype",
    "archetype_confidence",
    "functional_coverage"
  ) %in% names(result)))
  expect_equal(result$primary_archetype, "engage")
  expect_true(result$archetype_confidence >= 0)
  expect_true(result$archetype_confidence <= 1)
})

test_that("functional scores derived from kit text are bounded", {
  detail <- list(
    tags = c("Tank", "Support"),
    info = list(attack = 2, defense = 9, magic = 5, difficulty = 4),
    stats = list(attackrange = 125, movespeed = 335),
    passive = list(description = "Gains a shield."),
    spells = list(
      list(description = "Dashes and knocks up enemies."),
      list(description = "Stuns the target."),
      list(description = "Shields an ally."),
      list(description = "Slows all nearby enemies.")
    )
  )

  scores <- derive_functional_champion_scores(detail)

  expect_true(all(is.finite(unlist(scores))))
  expect_true(all(unlist(scores) >= 0 & unlist(scores) <= 1))
  expect_gt(scores$engage, scores$poke)
  expect_gt(scores$protect, 0)
})
