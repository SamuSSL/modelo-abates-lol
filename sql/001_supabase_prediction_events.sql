create schema if not exists lol_kills;

create table if not exists lol_kills.prediction_events (
  event_id text primary key,
  prediction_id text not null,
  created_at timestamptz not null,
  status text not null,
  league text not null,
  planned_at timestamptz not null,
  blue_team text not null,
  red_team text not null,
  map_number integer not null,
  line double precision not null,
  bet_side text,
  stake double precision,
  request_json text not null,
  result_json text not null
);

alter table lol_kills.prediction_events enable row level security;

drop policy if exists lol_kills_writer_insert
  on lol_kills.prediction_events;
drop policy if exists lol_kills_writer_select
  on lol_kills.prediction_events;

create policy lol_kills_writer_insert
  on lol_kills.prediction_events
  for insert
  to lol_kills_writer
  with check (true);

create policy lol_kills_writer_select
  on lol_kills.prediction_events
  for select
  to lol_kills_writer
  using (true);

revoke all on schema lol_kills from public;
revoke all on lol_kills.prediction_events from public;

grant connect on database postgres to lol_kills_writer;
grant usage on schema lol_kills to lol_kills_writer;
grant select, insert on lol_kills.prediction_events
  to lol_kills_writer;

create index if not exists prediction_events_created_at_idx
  on lol_kills.prediction_events (created_at);
create index if not exists prediction_events_prediction_id_idx
  on lol_kills.prediction_events (prediction_id);
