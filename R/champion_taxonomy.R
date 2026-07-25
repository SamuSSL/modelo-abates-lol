.champion_taxonomy_columns <- function() {
  c(
    "champion",
    "tank",
    "fighter",
    "assassin",
    "mage",
    "marksman",
    "support",
    "attack",
    "defense",
    "magic",
    "difficulty"
  )
}

.functional_champion_columns <- function() {
  c(
    "engage", "disengage", "dive", "pick", "poke", "siege",
    "frontline", "protect", "scaling", "early_pressure",
    "skirmish", "split_push", "wave_clear", "mobility",
    "crowd_control", "global_pressure", "damage_physical",
    "damage_magic", "execution_difficulty", "snowball_dependency"
  )
}

.bounded_score <- function(value) {
  pmin(1, pmax(0, as.numeric(value)))
}

.text_signal <- function(text, patterns, scale = 2) {
  hits <- vapply(
    patterns,
    function(pattern) grepl(pattern, text, ignore.case = TRUE),
    logical(1L)
  )
  .bounded_score(sum(hits) / scale)
}

#' Derive transparent functional scores from a champion kit
#'
#' @param detail One detailed Data Dragon champion record.
#' @return Named list of bounded functional scores.
#' @export
derive_functional_champion_scores <- function(detail) {
  tags <- tolower(as.character(unlist(detail$tags)))
  descriptions <- c(
    as.character(detail$passive$description),
    vapply(
      detail$spells,
      function(spell) as.character(spell$description),
      character(1L)
    )
  )
  text <- paste(descriptions, collapse = " ")
  has_tag <- function(tag) as.numeric(tag %in% tags)
  signal <- function(patterns, scale = 2) {
    .text_signal(text, patterns, scale)
  }
  attack_range <- suppressWarnings(as.numeric(detail$stats$attackrange))
  if (!is.finite(attack_range)) {
    attack_range <- 125
  }
  difficulty <- suppressWarnings(as.numeric(detail$info$difficulty)) / 10
  attack <- suppressWarnings(as.numeric(detail$info$attack)) / 10
  defense <- suppressWarnings(as.numeric(detail$info$defense)) / 10
  magic <- suppressWarnings(as.numeric(detail$info$magic)) / 10
  values <- list(
    engage = .bounded_score(
      0.55 * signal(c("dash", "charge", "knock", "stun", "pull")) +
        0.25 * has_tag("tank") +
        0.20 * signal(c("all enemies", "nearby enemies"))
    ),
    disengage = .bounded_score(
      0.65 * signal(c("knock.*back", "push.*away", "slow", "flee")) +
        0.35 * has_tag("support")
    ),
    dive = .bounded_score(
      0.65 * signal(c("dash", "blink", "leap", "charge")) +
        0.35 * max(has_tag("assassin"), has_tag("fighter"))
    ),
    pick = .bounded_score(
      0.7 * signal(c("stun", "root", "charm", "suppress", "pull")) +
        0.3 * has_tag("assassin")
    ),
    poke = .bounded_score(
      0.65 * signal(c("long range", "missile", "projectile")) +
        0.35 * as.numeric(attack_range >= 525)
    ),
    siege = .bounded_score(
      0.55 * as.numeric(attack_range >= 525) +
        0.25 * has_tag("marksman") +
        0.20 * signal(c("turret", "structure", "range"))
    ),
    frontline = .bounded_score(
      0.55 * defense + 0.30 * has_tag("tank") +
        0.15 * has_tag("fighter")
    ),
    protect = .bounded_score(
      0.65 * signal(c("shield", "heal", "ally", "protect")) +
        0.35 * has_tag("support")
    ),
    scaling = .bounded_score(
      0.45 * signal(c("permanently", "maximum", "infinite", "stack")) +
        0.30 * has_tag("marksman") + 0.25 * attack
    ),
    early_pressure = .bounded_score(
      0.45 * max(has_tag("assassin"), has_tag("fighter")) +
        0.35 * attack + 0.20 * signal(c("bonus damage", "execute"))
    ),
    skirmish = .bounded_score(
      0.4 * has_tag("fighter") + 0.3 * has_tag("assassin") +
        0.3 * signal(c("heal", "dash", "shield"))
    ),
    split_push = .bounded_score(
      0.45 * has_tag("fighter") + 0.30 * attack +
        0.25 * signal(c("turret", "attack speed", "duel"))
    ),
    wave_clear = .bounded_score(
      0.55 * signal(c("area", "all enemies", "nearby enemies")) +
        0.30 * has_tag("mage") + 0.15 * has_tag("marksman")
    ),
    mobility = signal(c("dash", "blink", "leap", "charge"), scale = 2),
    crowd_control = signal(
      c("stun", "root", "slow", "knock", "charm", "fear", "suppress"),
      scale = 3
    ),
    global_pressure = signal(
      c("anywhere", "global", "across the map", "teleport"),
      scale = 1
    ),
    damage_physical = .bounded_score(
      0.65 * attack + 0.35 * max(
        has_tag("fighter"),
        has_tag("marksman"),
        has_tag("assassin")
      )
    ),
    damage_magic = .bounded_score(
      0.65 * magic + 0.35 * has_tag("mage")
    ),
    execution_difficulty = .bounded_score(difficulty),
    snowball_dependency = .bounded_score(
      0.5 * has_tag("assassin") + 0.3 * attack +
        0.2 * signal(c("execute", "reset", "takedown"))
    )
  )
  values
}

#' Read a static champion taxonomy
#'
#' @param path YAML taxonomy path.
#' @return Data frame with one row per champion.
#' @export
read_champion_taxonomy <- function(path) {
  document <- yaml::read_yaml(path)
  if (is.null(document$champions) || length(document$champions) == 0L) {
    stop("Champion taxonomy is empty.", call. = FALSE)
  }
  rows <- lapply(document$champions, function(champion) {
    as.data.frame(champion, stringsAsFactors = FALSE)
  })
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  validate_champion_taxonomy(result)
  result
}

#' Validate the static champion taxonomy
#'
#' @param taxonomy Data frame with one row per champion.
#' @param required_champions Champions that must be covered.
#' @return `TRUE` invisibly when valid.
#' @export
validate_champion_taxonomy <- function(
  taxonomy,
  required_champions = character()
) {
  missing_columns <- setdiff(
    .champion_taxonomy_columns(),
    names(taxonomy)
  )
  if (length(missing_columns) > 0L) {
    stop(
      "Missing taxonomy columns: ",
      paste(missing_columns, collapse = ", "),
      call. = FALSE
    )
  }
  if (anyNA(taxonomy$champion) ||
      any(!nzchar(as.character(taxonomy$champion))) ||
      anyDuplicated(as.character(taxonomy$champion))) {
    stop("Taxonomy champion names must be unique.", call. = FALSE)
  }
  score_columns <- c("attack", "defense", "magic", "difficulty")
  functional_present <- intersect(
    .functional_champion_columns(),
    names(taxonomy)
  )
  if (
    length(functional_present) > 0L &&
      length(functional_present) != length(.functional_champion_columns())
  ) {
    stop("Functional taxonomy columns must be complete.", call. = FALSE)
  }
  score_columns <- c(score_columns, functional_present)
  valid_scores <- vapply(
    taxonomy[score_columns],
    function(values) {
      values <- as.numeric(values)
      all(is.finite(values) & values >= 0 & values <= 1)
    },
    logical(1L)
  )
  if (!all(valid_scores)) {
    stop("Taxonomy scores must be between zero and one.", call. = FALSE)
  }
  missing_champions <- setdiff(
    required_champions,
    as.character(taxonomy$champion)
  )
  if (length(missing_champions) > 0L) {
    stop(
      "Missing taxonomy champions: ",
      paste(missing_champions, collapse = ", "),
      call. = FALSE
    )
  }
  invisible(TRUE)
}

#' Score a champion composition with the static taxonomy
#'
#' @param champions Character vector of champion names.
#' @param taxonomy Valid champion taxonomy.
#' @return One-row data frame of transparent composition scores.
#' @export
score_composition_archetypes <- function(champions, taxonomy) {
  champions <- as.character(champions)
  if (anyDuplicated(champions)) {
    stop("Duplicate champions are not allowed.", call. = FALSE)
  }
  validate_champion_taxonomy(taxonomy, champions)
  rows <- taxonomy[match(champions, taxonomy$champion), , drop = FALSE]
  role_count <- function(column) {
    sum(as.logical(rows[[column]]))
  }
  scores <- data.frame(
    champion_count = as.integer(length(champions)),
    frontline_score = mean(
      0.6 * as.numeric(rows$defense) +
        0.4 * (as.numeric(rows$tank) | as.numeric(rows$fighter))
    ),
    damage_score = mean(as.numeric(rows$attack)),
    magic_score = mean(as.numeric(rows$magic)),
    burst_score = mean(
      as.numeric(rows$assassin) | as.numeric(rows$mage)
    ),
    utility_score = mean(
      as.numeric(rows$support) | as.numeric(rows$tank)
    ),
    execution_difficulty = mean(as.numeric(rows$difficulty)),
    tank_count = role_count("tank"),
    fighter_count = role_count("fighter"),
    assassin_count = role_count("assassin"),
    mage_count = role_count("mage"),
    marksman_count = role_count("marksman"),
    support_count = role_count("support"),
    stringsAsFactors = FALSE
  )
  functional <- .functional_champion_columns()
  if (all(functional %in% names(rows))) {
    average <- function(column) mean(as.numeric(rows[[column]]))
    archetypes <- c(
      engage = mean(c(
        average("engage"),
        average("crowd_control"),
        average("frontline"),
        average("mobility")
      )),
      pick = mean(c(
        average("pick"),
        average("crowd_control"),
        average("mobility")
      )),
      poke_siege = mean(c(
        average("poke"),
        average("siege"),
        average("wave_clear")
      )),
      dive = mean(c(
        average("dive"),
        average("mobility"),
        average("early_pressure")
      )),
      protect = mean(c(
        average("protect"),
        average("disengage"),
        average("scaling")
      )),
      front_to_back = mean(c(
        average("frontline"),
        average("protect"),
        average("scaling"),
        (
          average("damage_physical") +
            average("damage_magic")
        ) / 2
      )),
      split_map = mean(c(
        average("split_push"),
        average("global_pressure"),
        average("wave_clear")
      )),
      skirmish = mean(c(
        average("skirmish"),
        average("early_pressure"),
        average("mobility")
      )),
      scaling = mean(c(
        average("scaling"),
        average("wave_clear"),
        average("protect")
      ))
    )
    ranking <- order(archetypes, decreasing = TRUE)
    separation <- archetypes[[ranking[[1L]]]] -
      archetypes[[ranking[[2L]]]]
    coverage <- mean(stats::complete.cases(rows[functional]))
    functional_scores <- data.frame(
      engage_score = archetypes[["engage"]],
      pick_score = archetypes[["pick"]],
      poke_siege_score = archetypes[["poke_siege"]],
      dive_score = archetypes[["dive"]],
      protect_score = archetypes[["protect"]],
      front_to_back_score = archetypes[["front_to_back"]],
      split_map_score = archetypes[["split_map"]],
      skirmish_score = archetypes[["skirmish"]],
      scaling_score = archetypes[["scaling"]],
      functional_coverage = coverage,
      damage_balance = 1 - abs(
        average("damage_physical") - average("damage_magic")
      ),
      functional_redundancy = mean(vapply(
        functional,
        function(column) stats::sd(as.numeric(rows[[column]])),
        numeric(1L)
      ) < 0.1),
      primary_archetype = names(archetypes)[ranking[[1L]]],
      secondary_archetype = names(archetypes)[ranking[[2L]]],
      archetype_confidence = .bounded_score(
        separation * coverage * 2
      ),
      stringsAsFactors = FALSE
    )
    scores <- cbind(scores, functional_scores)
  }
  scores
}
