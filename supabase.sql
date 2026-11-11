-- Run this in Supabase: SQL Editor > New query > paste everything > Run.
-- Safe to run again (it also upgrades an older version of this setup).

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

alter table public.applications enable row level security;

-- ---------------------------------------------------------------
-- STAFF USERNAME: change 'macstaff' below to change the login name.
-- The dashboard sends what staff type; the database checks it here,
-- so the word never appears in your public website files.
-- ---------------------------------------------------------------
create or replace function public.is_staff()
returns boolean
language sql
stable
set search_path = public
as $$
  select lower(trim(coalesce(
    nullif(current_setting('request.headers', true), '')::json ->> 'x-staff-key', ''
  ))) = 'macstaff'
$$;

grant execute on function public.is_staff() to anon, authenticated;

-- Anyone can submit an application (insert only: nobody can edit or delete).
drop policy if exists "anyone can apply" on public.applications;
create policy "anyone can apply" on public.applications
  for insert to anon, authenticated with check (true);

-- Only someone who typed the staff username can read applications.
drop policy if exists "anyone can view" on public.applications;
drop policy if exists "staff can view" on public.applications;
create policy "staff can view" on public.applications
  for select to anon, authenticated using (public.is_staff());

grant insert, select on public.applications to anon, authenticated;
