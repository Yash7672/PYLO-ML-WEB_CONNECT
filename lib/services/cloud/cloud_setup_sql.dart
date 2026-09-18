/// SQL the user runs in their OWN Supabase project's SQL Editor to prepare it
/// for PYLO cloud sync. Shown on the Cloud Setup help screen as three separate,
/// labelled, copyable blocks (Step 5 / Step 6 / Step 7), each idempotent so a
/// re-run never breaks.
///
/// The column shapes are generated from the app's ACTUAL data usage — see
/// `today_data_serializer.dart` (payload) and `CloudSyncService` (`daily_data`
/// upsert/select/delete) — no invented columns. `profiles` is the standard
/// Supabase profile shape (PYLO currently writes only signups; the table exists
/// so RLS + the auto-create trigger + future web features have a home).
library;

/// Step 5 — the per-user profile table.
const String createProfilesTableSql = r'''
-- (5) Create profiles table
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  full_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
''';

/// Step 6 — one row per (user, local calendar date). `UNIQUE(user_id,
/// data_date)` is the conflict target the app uses for its upserts.
const String createDailyDataTableSql = r'''
-- (6) Create daily_data table
create table if not exists public.daily_data (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  data_date date not null,
  tasks jsonb not null default '[]'::jsonb,
  lists jsonb not null default '[]'::jsonb,
  sublists jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  unique (user_id, data_date)
);
''';

/// Step 7 — row-level security + ownership policies, the signup profile
/// trigger and the realtime publication. Runs AFTER steps 5 and 6.
const String enableRlsAndPoliciesSql = r'''
-- (7) Enable RLS + policies
alter table public.profiles enable row level security;
alter table public.daily_data enable row level security;

-- Profiles: each user manages only their own row.
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id)
  with check (auth.uid() = id);

-- daily_data: every row is scoped to its owner.
drop policy if exists "daily_data_select_own" on public.daily_data;
create policy "daily_data_select_own" on public.daily_data
  for select using (auth.uid() = user_id);

drop policy if exists "daily_data_insert_own" on public.daily_data;
create policy "daily_data_insert_own" on public.daily_data
  for insert with check (auth.uid() = user_id);

drop policy if exists "daily_data_update_own" on public.daily_data;
create policy "daily_data_update_own" on public.daily_data
  for update using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "daily_data_delete_own" on public.daily_data;
create policy "daily_data_delete_own" on public.daily_data
  for delete using (auth.uid() = user_id);

-- Auto-create a profile row on signup.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $pylo$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$pylo$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Let the realtime listener receive UPDATEs on the user's own daily_data rows.
do $pylo$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'daily_data'
  ) then
    alter publication supabase_realtime add table public.daily_data;
  end if;
end;
$pylo$;
''';