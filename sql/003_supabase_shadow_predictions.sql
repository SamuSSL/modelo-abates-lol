create table if not exists lol_kills.shadow_predictions (
  shadow_id text primary key,
  event_id text not null references lol_kills.prediction_events (event_id),
  prediction_id text not null,
  created_at timestamptz not null,
  model_id text not null,
  mode text not null,
  shadow_json jsonb not null
);

create table if not exists lol_kills.paper_bet_decisions (
  paper_id text primary key,
  shadow_id text not null references lol_kills.shadow_predictions (shadow_id),
  event_id text not null references lol_kills.prediction_events (event_id),
  prediction_id text not null,
  created_at timestamptz not null,
  model_id text not null,
  minimum_ev double precision not null,
  decision text not null check (decision in ('bet', 'pass', 'blocked')),
  side text,
  probability double precision,
  odds double precision,
  expected_value double precision not null,
  stake double precision not null
);

create index if not exists shadow_predictions_event_idx
  on lol_kills.shadow_predictions (event_id, model_id);
create index if not exists paper_bet_decisions_event_idx
  on lol_kills.paper_bet_decisions (event_id, model_id, minimum_ev);

alter table lol_kills.shadow_predictions enable row level security;
alter table lol_kills.paper_bet_decisions enable row level security;

drop policy if exists lol_kills_writer_insert on lol_kills.shadow_predictions;
drop policy if exists lol_kills_writer_select on lol_kills.shadow_predictions;
drop policy if exists lol_kills_writer_insert on lol_kills.paper_bet_decisions;
drop policy if exists lol_kills_writer_select on lol_kills.paper_bet_decisions;

create policy lol_kills_writer_insert on lol_kills.shadow_predictions
  for insert to lol_kills_writer with check (true);
create policy lol_kills_writer_select on lol_kills.shadow_predictions
  for select to lol_kills_writer using (true);
create policy lol_kills_writer_insert on lol_kills.paper_bet_decisions
  for insert to lol_kills_writer with check (true);
create policy lol_kills_writer_select on lol_kills.paper_bet_decisions
  for select to lol_kills_writer using (true);

revoke all on lol_kills.shadow_predictions from public;
revoke all on lol_kills.paper_bet_decisions from public;
grant select, insert on lol_kills.shadow_predictions to lol_kills_writer;
grant select, insert on lol_kills.paper_bet_decisions to lol_kills_writer;
