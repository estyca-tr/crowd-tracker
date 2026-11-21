-- Team Portal — QA / Automation shared registry
-- Paste into Supabase → SQL Editor → Run (safe to re-run where noted).
-- Requires Supabase Auth (email magic link). Restrict access via RLS to @etoro.com / @etorocorp.com.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function public.portal_allowed_email()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (auth.jwt() ->> 'email') ~* '@(etoro\.com|etorocorp\.com)$',
    false
  );
$$;

create or replace function public.portal_set_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();
  new.last_changed_by := coalesce(auth.jwt() ->> 'email', new.last_changed_by);
  if tg_op = 'INSERT' and (new.owner is null or new.owner = '') then
    new.owner := coalesce(auth.jwt() ->> 'email', new.owner);
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------
create table if not exists public.portal_devices (
  id uuid primary key default gen_random_uuid(),
  device_name text not null default '',
  model text not null default '',
  os_name text not null default '',
  os_version text not null default '',
  device_type text not null default 'phone'
    check (device_type in ('phone', 'tablet')),
  asset_tag text not null default '',
  current_holder text not null default '',
  held_since date,
  location_team text not null default '',
  status text not null default 'available'
    check (status in ('available', 'in_use', 'broken', 'lost')),
  notes text not null default '',
  owner text not null default '',
  updated_at timestamptz not null default now(),
  last_changed_by text not null default ''
);

create index if not exists portal_devices_status_idx on public.portal_devices (status);
create index if not exists portal_devices_holder_idx on public.portal_devices (current_holder);
create index if not exists portal_devices_asset_tag_idx on public.portal_devices (asset_tag);

drop trigger if exists portal_devices_audit on public.portal_devices;
create trigger portal_devices_audit
  before insert or update on public.portal_devices
  for each row execute function public.portal_set_audit();

create table if not exists public.portal_device_history (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.portal_devices (id) on delete cascade,
  action text not null check (action in ('take', 'return', 'note', 'status')),
  holder text not null default '',
  notes text not null default '',
  created_at timestamptz not null default now(),
  created_by text not null default ''
);

create index if not exists portal_device_history_device_idx on public.portal_device_history (device_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Test users (no passwords / secrets)
-- ---------------------------------------------------------------------------
create table if not exists public.portal_test_users (
  id uuid primary key default gen_random_uuid(),
  label text not null default '',
  username_alias text not null default '',
  environment text not null default 'STG'
    check (environment in ('STG', 'INT', 'PROD')),
  country text not null default '',
  account_type text not null default '',
  flags text[] not null default '{}',
  current_user_label text not null default '',
  purpose text not null default '',
  notes text not null default '',
  owner text not null default '',
  updated_at timestamptz not null default now(),
  last_changed_by text not null default ''
);

create index if not exists portal_test_users_env_idx on public.portal_test_users (environment);

drop trigger if exists portal_test_users_audit on public.portal_test_users;
create trigger portal_test_users_audit
  before insert or update on public.portal_test_users
  for each row execute function public.portal_set_audit();

-- ---------------------------------------------------------------------------
-- Test cards — LAST 4 DIGITS ONLY
-- ---------------------------------------------------------------------------
create table if not exists public.portal_test_cards (
  id uuid primary key default gen_random_uuid(),
  label text not null default '',
  issuer text not null default '',
  brand text not null default '',
  card_type text not null default 'debit'
    check (card_type in ('debit', 'credit', 'virtual')),
  country text not null default '',
  currency text not null default '',
  environment text not null default 'STG'
    check (environment in ('STG', 'INT', 'PROD')),
  last4 text not null
    check (last4 ~ '^\d{4}$'),
  expiry_month smallint check (expiry_month is null or (expiry_month between 1 and 12)),
  expiry_year smallint check (expiry_year is null or (expiry_year between 2020 and 2099)),
  holder text not null default '',
  linked_test_user_id uuid references public.portal_test_users (id) on delete set null,
  details_location text not null default '',
  notes text not null default '',
  owner text not null default '',
  updated_at timestamptz not null default now(),
  last_changed_by text not null default ''
);

create index if not exists portal_test_cards_last4_idx on public.portal_test_cards (last4);

drop trigger if exists portal_test_cards_audit on public.portal_test_cards;
create trigger portal_test_cards_audit
  before insert or update on public.portal_test_cards
  for each row execute function public.portal_set_audit();

-- ---------------------------------------------------------------------------
-- Contacts
-- ---------------------------------------------------------------------------
create table if not exists public.portal_contacts (
  id uuid primary key default gen_random_uuid(),
  name text not null default '',
  company text not null default '',
  role_title text not null default '',
  contact_about text not null default '',
  channel text not null default '',
  notes text not null default '',
  owner text not null default '',
  updated_at timestamptz not null default now(),
  last_changed_by text not null default ''
);

create index if not exists portal_contacts_company_idx on public.portal_contacts (company);

drop trigger if exists portal_contacts_audit on public.portal_contacts;
create trigger portal_contacts_audit
  before insert or update on public.portal_contacts
  for each row execute function public.portal_set_audit();

-- ---------------------------------------------------------------------------
-- Whitelisting
-- ---------------------------------------------------------------------------
create table if not exists public.portal_whitelisting (
  id uuid primary key default gen_random_uuid(),
  item text not null default '',
  environment text not null default 'STG'
    check (environment in ('STG', 'INT', 'PROD')),
  status text not null default 'requested'
    check (status in ('requested', 'pending', 'done')),
  requested_by text not null default '',
  requested_date date,
  notes text not null default '',
  owner text not null default '',
  updated_at timestamptz not null default now(),
  last_changed_by text not null default ''
);

create index if not exists portal_whitelisting_status_idx on public.portal_whitelisting (status);

drop trigger if exists portal_whitelisting_audit on public.portal_whitelisting;
create trigger portal_whitelisting_audit
  before insert or update on public.portal_whitelisting
  for each row execute function public.portal_set_audit();

-- ---------------------------------------------------------------------------
-- How-tos
-- ---------------------------------------------------------------------------
create table if not exists public.portal_howtos (
  id uuid primary key default gen_random_uuid(),
  title text not null default '',
  body_md text not null default '',
  link_url text not null default '',
  owner text not null default '',
  updated_at timestamptz not null default now(),
  last_changed_by text not null default ''
);

drop trigger if exists portal_howtos_audit on public.portal_howtos;
create trigger portal_howtos_audit
  before insert or update on public.portal_howtos
  for each row execute function public.portal_set_audit();

-- ---------------------------------------------------------------------------
-- Assignment board
-- ---------------------------------------------------------------------------
create table if not exists public.portal_assignments (
  id uuid primary key default gen_random_uuid(),
  person text not null default '',
  week_label text not null default '',
  focus_area text not null default '',
  availability text not null default 'available'
    check (availability in ('available', 'partial', 'not_available')),
  notes text not null default '',
  owner text not null default '',
  updated_at timestamptz not null default now(),
  last_changed_by text not null default ''
);

create index if not exists portal_assignments_week_idx on public.portal_assignments (week_label);

drop trigger if exists portal_assignments_audit on public.portal_assignments;
create trigger portal_assignments_audit
  before insert or update on public.portal_assignments
  for each row execute function public.portal_set_audit();

-- ---------------------------------------------------------------------------
-- Row Level Security — authenticated @etoro.com / @etorocorp.com only; anon: nothing
-- ---------------------------------------------------------------------------
alter table public.portal_devices enable row level security;
alter table public.portal_device_history enable row level security;
alter table public.portal_test_users enable row level security;
alter table public.portal_test_cards enable row level security;
alter table public.portal_contacts enable row level security;
alter table public.portal_whitelisting enable row level security;
alter table public.portal_howtos enable row level security;
alter table public.portal_assignments enable row level security;

-- portal_devices
drop policy if exists "portal_devices_auth" on public.portal_devices;
create policy "portal_devices_auth" on public.portal_devices
  for all to authenticated
  using (portal_allowed_email())
  with check (portal_allowed_email());

-- portal_device_history
drop policy if exists "portal_device_history_auth" on public.portal_device_history;
create policy "portal_device_history_auth" on public.portal_device_history
  for all to authenticated
  using (portal_allowed_email())
  with check (portal_allowed_email());

-- portal_test_users
drop policy if exists "portal_test_users_auth" on public.portal_test_users;
create policy "portal_test_users_auth" on public.portal_test_users
  for all to authenticated
  using (portal_allowed_email())
  with check (portal_allowed_email());

-- portal_test_cards
drop policy if exists "portal_test_cards_auth" on public.portal_test_cards;
create policy "portal_test_cards_auth" on public.portal_test_cards
  for all to authenticated
  using (portal_allowed_email())
  with check (portal_allowed_email());

-- portal_contacts
drop policy if exists "portal_contacts_auth" on public.portal_contacts;
create policy "portal_contacts_auth" on public.portal_contacts
  for all to authenticated
  using (portal_allowed_email())
  with check (portal_allowed_email());

-- portal_whitelisting
drop policy if exists "portal_whitelisting_auth" on public.portal_whitelisting;
create policy "portal_whitelisting_auth" on public.portal_whitelisting
  for all to authenticated
  using (portal_allowed_email())
  with check (portal_allowed_email());

-- portal_howtos
drop policy if exists "portal_howtos_auth" on public.portal_howtos;
create policy "portal_howtos_auth" on public.portal_howtos
  for all to authenticated
  using (portal_allowed_email())
  with check (portal_allowed_email());

-- portal_assignments
drop policy if exists "portal_assignments_auth" on public.portal_assignments;
create policy "portal_assignments_auth" on public.portal_assignments
  for all to authenticated
  using (portal_allowed_email())
  with check (portal_allowed_email());

-- Optional: realtime (uncomment if you want live updates across browsers)
-- alter publication supabase_realtime add table portal_devices;
-- alter publication supabase_realtime add table portal_test_users;
-- alter publication supabase_realtime add table portal_test_cards;
-- alter publication supabase_realtime add table portal_contacts;
-- alter publication supabase_realtime add table portal_whitelisting;
-- alter publication supabase_realtime add table portal_howtos;
-- alter publication supabase_realtime add table portal_assignments;