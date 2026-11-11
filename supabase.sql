-- Run this in Supabase: SQL Editor > New query > paste everything > Run.
-- Safe to run again. It also upgrades older versions (adds application types, new staff login).

create table if not exists public.applications (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  discord_name text not null check (char_length(discord_name) between 1 and 100),
  answers      jsonb not null check (
                 jsonb_typeof(answers) = 'array'
                 and jsonb_array_length(answers) between 1 and 30
                 and pg_column_size(answers) < 40000
               )
);

-- NEW: which application this is (mod, creator, events, partner...). Old rows count as 'mod'.
alter table public.applications add column if not exists type text not null default 'mod';
alter table public.applications drop constraint if exists applications_type_check;
alter table public.applications add constraint applications_type_check check (type ~ '^[a-z0-9_-]{1,30}$');

alter table public.applications enable row level security;

-- Clean up the old header-based login (replaced below).
drop policy if exists "staff can view" on public.applications;
drop policy if exists "anyone can view" on public.applications;
drop function if exists public.is_staff();

-- ---------------------------------------------------------------
-- STAFF USERNAME: change 'macstaff' below (it appears only once).
-- It is checked here in the database, so it never appears in your website files.
-- ---------------------------------------------------------------
create or replace function public.is_staff(staff_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select lower(trim(coalesce(staff_key, ''))) = 'macstaff-7x4kq'
$$;

-- On/off switch per application type (staff flip it from the dashboard).
create table if not exists public.app_settings (
  type_id text primary key check (type_id ~ '^[a-z0-9_-]{1,30}$'),
  is_open boolean not null default true
);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;

create or replace function public.type_is_open(t text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select is_open from public.app_settings where type_id = t), true)
$$;

create or replace function public.get_closed_types()
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(type_id order by type_id), '{}') from public.app_settings where not is_open
$$;

create or replace function public.set_type_open(staff_key text, p_type text, p_open boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_staff(staff_key) then return false; end if;
  insert into public.app_settings (type_id, is_open) values (p_type, p_open)
  on conflict (type_id) do update set is_open = excluded.is_open;
  return true;
end
$$;

create or replace function public.list_applications(staff_key text)
returns setof public.applications
language sql
stable
security definer
set search_path = public
as $$
  select * from public.applications
  where public.is_staff(staff_key)
  order by created_at desc
  limit 2000
$$;

-- Anyone can submit an application, but only while that type is open (insert only).
drop policy if exists "anyone can apply" on public.applications;
create policy "anyone can apply" on public.applications
  for insert to anon, authenticated with check (public.type_is_open(type));

grant usage on schema public to anon, authenticated;
-- Nobody can read, change or delete the table directly. Staff read through list_applications().
revoke all on public.applications from anon, authenticated;
grant insert on public.applications to anon, authenticated;

grant execute on function public.is_staff(text) to anon, authenticated;
grant execute on function public.type_is_open(text) to anon, authenticated;
grant execute on function public.get_closed_types() to anon, authenticated;
grant execute on function public.set_type_open(text, text, boolean) to anon, authenticated;
grant execute on function public.list_applications(text) to anon, authenticated;

-- Make the API pick up the changes right away.
notify pgrst, 'reload schema';
