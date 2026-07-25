create table if not exists lol_kills.bet_decisions (
  event_id text primary key
    references lol_kills.prediction_events (event_id),
  prediction_id text not null,
  created_at timestamptz not null,
  decision text not null
    check (decision in ('over', 'under', 'no_bet')),
  stake double precision,
  offered_odds double precision,
  check (
    (decision in ('over', 'under') and stake = 1 and offered_odds > 1)
    or
    (decision = 'no_bet' and stake is null and offered_odds is null)
  )
);

alter table lol_kills.bet_decisions enable row level security;

drop policy if exists lol_kills_writer_insert
  on lol_kills.bet_decisions;
drop policy if exists lol_kills_writer_select
  on lol_kills.bet_decisions;

create policy lol_kills_writer_insert
  on lol_kills.bet_decisions
  for insert
  to lol_kills_writer
  with check (true);

create policy lol_kills_writer_select
  on lol_kills.bet_decisions
  for select
  to lol_kills_writer
  using (true);

revoke all on lol_kills.bet_decisions from public;

grant select, insert on lol_kills.bet_decisions
  to lol_kills_writer;

create index if not exists bet_decisions_prediction_id_idx
  on lol_kills.bet_decisions (prediction_id);
create index if not exists bet_decisions_created_at_idx
  on lol_kills.bet_decisions (created_at);
