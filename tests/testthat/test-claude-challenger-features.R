test_that("RW1 does not use outcomes from the current or future week", {
  maps <- data.frame(
    gameid = paste0("g", 1:4),
    game_datetime = as.POSIXct(c(
      "2026-01-01", "2026-01-02", "2026-01-08", "2026-01-09"
    ), tz = "UTC"),
    total_kills_game = c(10, 20, 100, 200)
  )
  archetypes <- c(
    "engage", "pick", "poke_siege", "dive", "protect",
    "front_to_back", "split_map", "skirmish", "scaling"
  )
  for (name in archetypes) {
    maps[[paste0("blue_draft_", name)]] <- 0.5
    maps[[paste0("red_draft_", name)]] <- 0.5
  }
  first <- build_claude_challenger_features(maps)
  changed <- maps
  changed$total_kills_game[3:4] <- c(1000, 2000)
  second <- build_claude_challenger_features(changed)

  expect_equal(first$global_weekly_rw1[1:3], second$global_weekly_rw1[1:3])
  expect_equal(first$archetype_distance, rep(0, 4))
})
