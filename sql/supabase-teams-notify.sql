-- =====================================================================
-- Crowd Test Tracker → Microsoft Teams chat-wait notifications (Supabase, project <PROJECT_REF>)
-- Paste this whole file into Supabase → SQL Editor → Run. Safe to re-run.
--
-- Reported: "אנשים ממש רוצים לקבל עדכון מהכלי כשמחכה להם הודעה, כי אחרת הם ממש צריכים לעקוב
-- בכלי" — people need to know a new message from the crowd side (Applause/Tester/Other) arrived
-- WITHOUT having the tracker open. A Postgres trigger that diffs the whole JSON payload on every
-- sync write would be complex and fragile (and risks a notification storm on any bulk
-- import/merge of OLD chat history). Instead: the tracker itself calls this relay at the exact
-- moment someone sends a chat message as the crowd side (same moment a human is already looking
-- at the tool to type it in) — same shape as the Jira relay in supabase-jira-relay.sql (anon key
-- calls an RPC, a row is inserted, pg_net POSTs it, the secret webhook URL never leaves the DB).
--
-- Routing: one default row (match_tester = '*') catches everyone. To later route a SPECIFIC
-- tester's notifications to a different person/channel, create another Teams Workflow pointed at
-- that person's own chat and insert one row here — no code change needed:
--   insert into public.teams_notify_config (match_tester, webhook_url)
--   values ('Eugene', 'https://.../workflows/...')
--   on conflict (match_tester) do update set webhook_url = excluded.webhook_url;
--
-- How to get a webhook_url: in Teams, open the chat/channel you want notifications in → "..." →
-- Workflows → "Post to a channel when a webhook request is received" (or "...when a webhook
-- request is received" for a chat) → finish the wizard → copy the HTTP POST URL it gives you.
-- When the wizard asks you to describe the incoming JSON, paste this sample so it knows the
-- fields (Edit → "Generate from sample" on the trigger):
--   {"title":"New Applause message","cycle":"Payments cycle","transaction":"AgataMM · P24",
--    "tester":"Eugene","from":"Applause PM","role":"Applause","message":"please check this one",
--    "when":"2026-11-24T10:00:00.000Z","link":"https://estyca-tr.github.io/crowd-tracker/crowd-test-tracker.html"}
-- =====================================================================

create extension if not exists pg_net with schema extensions;   -- creates schema "net" (no-op if already enabled by the Jira relay)

-- ---------- Config (webhook URL per tester, '*' = default/fallback) — server-side only ----------
create table if not exists public.teams_notify_config (
  match_tester   text primary key,   -- '*' = default/fallback; otherwise an exact tester name (cycle.testers / tx.tester)
  webhook_url    text not null check (webhook_url ~ '^https://'),
  max_per_minute int  not null default 10,
  max_per_day    int  not null default 300,
  updated_at     timestamptz not null default now()
);
alter table public.teams_notify_config enable row level security;   -- no policies = no anon access
revoke all on table public.teams_notify_config from anon, authenticated;

-- ---------- Requests log ----------
create table if not exists public.teams_notify_requests (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  match_tester    text not null,
  payload         jsonb not null,
  status          text not null default 'queued' check (status in ('queued', 'sent', 'skipped', 'error')),
  net_request_id  bigint,
  error           text
);
create index if not exists teams_notify_requests_created_idx on public.teams_notify_requests (created_at desc);
alter table public.teams_notify_requests enable row level security;  -- no policies: access only via the RPC below
revoke all on table public.teams_notify_requests from anon, authenticated;

-- ---------- Config lookup: exact tester match, else the '*' default ----------
create or replace function public.teams_notify_config_for(p_tester text)
returns public.teams_notify_config
language sql
stable
security definer
set search_path = public
as $$
  select c.*
    from public.teams_notify_config c
   where c.match_tester = coalesce(nullif(trim(p_tester), ''), '*')
      or c.match_tester = '*'
   order by (c.match_tester = '*')   -- exact tester match first
   limit 1;
$$;

-- ---------- BEFORE INSERT: abuse guard (same shape as the Jira relay's) ----------
create or replace function public.teams_notify_requests_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg   public.teams_notify_config;
  n_min int;
  n_day int;
begin
  cfg := public.teams_notify_config_for(new.match_tester);
  if cfg.match_tester is null then
    new.status := 'skipped';   -- not configured yet — never block/error the chat send itself
    return new;
  end if;
  if octet_length(new.payload::text) > 20000 then
    raise exception 'Payload too large (max 20 KB)';
  end if;
  perform pg_advisory_xact_lock(hashtext('teams_notify_rate_' || cfg.match_tester));
  select count(*) filter (where r.created_at > now() - interval '1 minute'), count(*)
    into n_min, n_day
    from public.teams_notify_requests r
   where r.match_tester = cfg.match_tester
     and r.created_at > now() - interval '1 day';
  if n_min >= cfg.max_per_minute then
    raise exception 'Rate limit: max % Teams notifications per minute', cfg.max_per_minute;
  end if;
  if n_day >= cfg.max_per_day then
    raise exception 'Daily limit reached: max % Teams notifications per day', cfg.max_per_day;
  end if;
  return new;
end;
$$;

-- ---------- AFTER INSERT: POST to the Teams webhook ----------
create or replace function public.teams_notify_requests_send()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cfg public.teams_notify_config;
  rid bigint;
begin
  if new.status = 'skipped' then return null; end if;
  cfg := public.teams_notify_config_for(new.match_tester);
  if cfg.match_tester is null then return null; end if;
  rid := net.http_post(
    url                  := cfg.webhook_url,
    body                 := new.payload,
    headers              := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 10000
  );
  update public.teams_notify_requests r
     set status = 'sent', net_request_id = rid
   where r.id = new.id;
  return null;
end;
$$;

drop trigger if exists teams_notify_requests_guard_trg on public.teams_notify_requests;
create trigger teams_notify_requests_guard_trg
  before insert on public.teams_notify_requests
  for each row execute function public.teams_notify_requests_guard();

drop trigger if exists teams_notify_requests_send_trg on public.teams_notify_requests;
create trigger teams_notify_requests_send_trg
  after insert on public.teams_notify_requests
  for each row execute function public.teams_notify_requests_send();

-- ---------- RPC: called by the tracker right when a crowd-side chat message is sent ----------
create or replace function public.request_teams_notify(p_tester text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rid uuid;
begin
  if jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Payload must be a JSON object';
  end if;
  insert into public.teams_notify_requests (match_tester, payload)
  values (coalesce(nullif(trim(p_tester), ''), '*'), p_payload)
  returning id into rid;
  return jsonb_build_object('id', rid, 'status', 'queued');
end;
$$;
grant execute on function public.request_teams_notify(text, jsonb) to anon, authenticated;

-- ---------- STEP: set the default webhook (replace the URL, then run just this once) ----------
-- insert into public.teams_notify_config (match_tester, webhook_url)
-- values ('*', 'https://<your-teams-workflow-url>')
-- on conflict (match_tester) do update set webhook_url = excluded.webhook_url, updated_at = now();
