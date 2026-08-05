do $$
declare
  constraint_name text;
begin
  for constraint_name in
    select conname
    from pg_constraint
    where conrelid = 'lol_kills.bet_decisions'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%stake%'
      and pg_get_constraintdef(oid) ilike '%offered_odds%'
  loop
    execute format(
      'alter table lol_kills.bet_decisions drop constraint %I',
      constraint_name
    );
  end loop;
end
$$;

alter table lol_kills.bet_decisions
  add constraint bet_decisions_stake_odds_check
  check (
    (
      decision in ('over', 'under')
      and stake in (0.5, 1.0)
      and offered_odds > 1
    )
    or
    (decision = 'no_bet' and stake is null and offered_odds is null)
  );
