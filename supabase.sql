-- Will Mac Community: complete database setup (generated from supabase/migrations - do not edit by hand).
-- Paste into Supabase > SQL Editor > Run. Safe to run again on an existing project.

-- ======================= 20261113000001_base_schema.sql =======================
-- Run this in Supabase: SQL Editor > New query > paste everything > Run.
-- Safe to run again. Upgrades older versions (types, review status, per-person staff logins, activity log).

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

alter table public.applications add column if not exists type text not null default 'mod';
alter table public.applications drop constraint if exists applications_type_check;
alter table public.applications add constraint applications_type_check check (type ~ '^[a-z0-9_-]{1,30}$');

alter table public.applications add column if not exists status text not null default 'pending';
alter table public.applications drop constraint if exists applications_status_check;
alter table public.applications add constraint applications_status_check
  check (status in ('pending','in_review','interview','more_info','on_hold','approved','denied'));

-- Progress bar info shown to the applicant.
alter table public.applications add column if not exists reviewer    text;
alter table public.applications add column if not exists status_note text;
alter table public.applications add column if not exists status_at   timestamptz;

-- Every status change is kept here (shown as "Progress history").
create table if not exists public.application_history (
  id             bigint generated always as identity primary key,
  application_id uuid not null references public.applications(id) on delete cascade,
  at             timestamptz not null default now(),
  status         text not null,
  reviewer       text,
  note           text,
  actor          text
);
create index if not exists application_history_app on public.application_history (application_id, at);
alter table public.application_history enable row level security;
revoke all on public.application_history from anon, authenticated;

alter table public.applications add column if not exists discord_id text;
alter table public.applications add column if not exists avatar text;
drop index if exists public.applications_one_pending;
create unique index if not exists applications_one_pending on public.applications (discord_id, type)
  where status in ('pending','in_review','interview','more_info','on_hold') and discord_id is not null;

alter table public.applications enable row level security;

drop policy if exists "staff can view" on public.applications;
drop policy if exists "anyone can view" on public.applications;
drop function if exists public.is_staff();
drop function if exists public.get_statuses(text);

-- ---------------------------------------------------------------
-- STAFF ACCESS
-- Roles: viewer (read only) / reviewer (approve + deny) / admin (everything).
-- Admins create a separate login code per person from the dashboard (Staff button).
-- Codes are stored hashed, so they can't be read back. Use "New code" if one is lost.
-- ---------------------------------------------------------------
create table if not exists public.staff_users (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 40),
  role       text not null default 'viewer' check (role in ('viewer','reviewer','admin')),
  code_hash  text not null unique,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  last_used  timestamptz
);
create table if not exists public.staff_log (
  id     bigserial primary key,
  at     timestamptz not null default now(),
  actor  text not null,
  action text not null,
  detail text
);
alter table public.staff_users enable row level security;
alter table public.staff_log enable row level security;
revoke all on public.staff_users from anon, authenticated;
revoke all on public.staff_log from anon, authenticated;

-- ---------------------------------------------------------------
-- DISCORD ROLE LOGIN FOR STAFF (no bot needed)
-- Staff log in with Discord. The database asks Discord directly which roles that person has in your
-- server, then gives them dashboard access based on the table below. Highest role wins.
--   admin    = everything (open/close, delete, manage logins)
--   reviewer = read + approve/deny
--   viewer   = read only
-- To change who gets what, edit the rows below and run this file again.
-- ---------------------------------------------------------------
do $$ begin
  create extension if not exists http with schema extensions;
exception when others then
  raise notice 'Could not enable the http extension. Turn it on in Supabase > Database > Extensions (search "http"), then run this file again.';
end $$;

create table if not exists public.discord_role_map (
  role_id text primary key check (role_id ~ '^[0-9]{5,25}$'),
  label   text not null,
  access  text not null check (access in ('none','viewer','reviewer','admin'))
);
alter table public.discord_role_map drop constraint if exists discord_role_map_access_check;
alter table public.discord_role_map add constraint discord_role_map_access_check check (access in ('none','viewer','reviewer','admin'));
alter table public.discord_role_map enable row level security;
revoke all on public.discord_role_map from anon, authenticated;

insert into public.discord_role_map (role_id, label, access) values
  ('1402003322633719953', 'Owner',     'admin'),
  ('1402003409028255804', 'Admin',     'admin'),
  ('1544535384355110953', 'Lead Mod',  'reviewer'),
  ('1496649340478029844', 'Mod',       'viewer')
on conflict (role_id) do update set label = excluded.label, access = excluded.access;

-- Per-person access by Discord ID (on top of roles). The highest of role / person wins.
-- Voqcl (the owner) is also hard-coded as admin inside staff_login_discord, so can't be removed.
create table if not exists public.staff_overrides (
  discord_id text primary key check (discord_id ~ '^[0-9]{5,25}$'),
  name       text not null check (char_length(name) between 1 and 40),
  access     text not null check (access in ('viewer','reviewer','admin')),
  created_at timestamptz not null default now()
);
alter table public.staff_overrides enable row level security;
revoke all on public.staff_overrides from anon, authenticated;
insert into public.staff_overrides (discord_id, name, access) values ('1271246652421701633', 'Voqcl', 'admin')
on conflict (discord_id) do update set access = 'admin';

create table if not exists public.staff_sessions (
  key_hash   text primary key,
  discord_id text not null,
  name       text not null,
  role       text not null check (role in ('viewer','reviewer','admin')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
alter table public.staff_sessions enable row level security;
revoke all on public.staff_sessions from anon, authenticated;

-- OWNER KEY: your original login. It always has admin access, so you can never lock yourself out.
-- Change 'macstaff-7x4kq' below (it appears only once) once you have made your own admin code.
create or replace function public.is_master(k text)
returns boolean language sql stable security definer set search_path = public
as $$ select lower(trim(coalesce(k, ''))) = 'macstaff-7x4kq' $$;

create or replace function public.code_hash(k text)
returns text language sql immutable set search_path = public
as $$ select encode(sha256(convert_to(lower(trim(coalesce(k, ''))), 'utf8')), 'hex') $$;

create or replace function public.staff_role(staff_key text)
returns text language sql stable security definer set search_path = public
as $$
  select case when public.is_master(staff_key) then 'admin'
    else coalesce(
      (select role from public.staff_sessions where key_hash = public.code_hash(staff_key) and expires_at > now()),
      (select role from public.staff_users where active and code_hash = public.code_hash(staff_key))) end
$$;

create or replace function public.staff_name(staff_key text)
returns text language sql stable security definer set search_path = public
as $$
  select case when public.is_master(staff_key) then 'Owner'
    else coalesce(
      (select name from public.staff_sessions where key_hash = public.code_hash(staff_key) and expires_at > now()),
      (select name from public.staff_users where code_hash = public.code_hash(staff_key))) end
$$;

create or replace function public.is_staff(staff_key text)
returns boolean language sql stable security definer set search_path = public
as $$ select public.staff_role(staff_key) is not null $$;

create or replace function public.staff_login(staff_key text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare r text;
begin
  r := public.staff_role(staff_key);
  if r is null then return null; end if;
  if not public.is_master(staff_key) then
    update public.staff_users set last_used = now() where active and code_hash = public.code_hash(staff_key);
  end if;
  return jsonb_build_object('role', r, 'name', public.staff_name(staff_key));
end $$;

create or replace function public.log_action(staff_key text, p_action text, p_detail text)
returns void language sql security definer set search_path = public
as $$
  insert into public.staff_log (actor, action, detail)
  values (coalesce(public.staff_name(staff_key), '?'), p_action, left(coalesce(p_detail, ''), 500))
$$;

-- On/off switch per application type (admin only).
create table if not exists public.app_settings (
  type_id text primary key check (type_id ~ '^[a-z0-9_-]{1,30}$'),
  is_open boolean not null default true
);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;

create or replace function public.type_is_open(t text)
returns boolean language sql stable security definer set search_path = public
as $$ select coalesce((select is_open from public.app_settings where type_id = t), true) $$;

create or replace function public.get_closed_types()
returns text[] language sql stable security definer set search_path = public
as $$ select coalesce(array_agg(type_id order by type_id), '{}') from public.app_settings where not is_open $$;

create or replace function public.set_type_open(staff_key text, p_type text, p_open boolean)
returns boolean language plpgsql security definer set search_path = public
as $$
begin
  if public.staff_role(staff_key) is distinct from 'admin' then return false; end if;
  insert into public.app_settings (type_id, is_open) values (p_type, p_open)
  on conflict (type_id) do update set is_open = excluded.is_open;
  perform public.log_action(staff_key, case when p_open then 'opened' else 'closed' end, p_type || ' applications');
  return true;
end $$;

-- Any role can read.
-- Also returns each applicant's CURRENT Discord profile picture, looked up live from their Discord login
-- (so people who applied before profile pictures existed show up too, and new pictures stay up to date).
drop function if exists public.list_applications(text);
create or replace function public.list_applications(staff_key text)
returns table (id uuid, created_at timestamptz, discord_name text, answers jsonb, type text, status text,
               reviewer text, status_note text, status_at timestamptz, discord_id text, avatar text)
language sql stable security definer set search_path = public, auth
as $$
  select a.id, a.created_at, a.discord_name, a.answers, a.type, a.status, a.reviewer, a.status_note, a.status_at, a.discord_id,
         coalesce(left(coalesce(u.m->>'avatar_url', u.m->>'picture'), 300), a.avatar)
  from public.applications a
  left join lateral (
    select x.raw_user_meta_data as m from auth.identities i join auth.users x on x.id = i.user_id
    where i.provider = 'discord' and i.provider_id = a.discord_id limit 1
  ) u on true
  where public.staff_role(staff_key) is not null
  order by a.created_at desc
  limit 2000
$$;

-- Reviewer or admin (approve / deny buttons). Returns count, -1 = bad login/input, -2 = role not allowed.
create or replace function public.set_application_status(staff_key text, p_ids text[], p_status text)
returns integer language plpgsql security definer set search_path = public
as $$
declare n int; r text; names text;
begin
  r := public.staff_role(staff_key);
  if r is null then return -1; end if;
  if r not in ('reviewer','admin') then return -2; end if;
  if p_status not in ('pending','approved','denied') then return -1; end if;
  select string_agg(discord_name, ', ') into names from public.applications where id::text = any(p_ids);
  insert into public.application_history (application_id, status, reviewer, note, actor)
    select id, p_status, reviewer, null, public.staff_name(staff_key) from public.applications where id::text = any(p_ids);
  update public.applications set status = p_status, status_at = now() where id::text = any(p_ids);
  get diagnostics n = row_count;
  if n > 0 then perform public.log_action(staff_key, p_status, n || ' application(s): ' || coalesce(names, '')); end if;
  return n;
end $$;

-- Reviewer or admin: set the progress bar status, who is handling it, and a message for the applicant.
-- With several ids at once (bulk), reviewer and message are left as they are.
create or replace function public.set_application_progress(staff_key text, p_ids text[], p_status text, p_reviewer text, p_note text)
returns integer language plpgsql security definer set search_path = public
as $$
declare n int; r text; names text; rv text; nt text; single boolean;
begin
  r := public.staff_role(staff_key);
  if r is null then return -1; end if;
  if r not in ('reviewer','admin') then return -2; end if;
  if p_status not in ('pending','in_review','interview','more_info','on_hold','approved','denied') then return -1; end if;
  -- Appeals: the staff member who issued the punishment can't decide it (name is answer #3 of the appeal).
  if p_status in ('approved','denied') and length(coalesce(public.staff_name(staff_key), '')) >= 3 and exists (
    select 1 from public.applications
    where id::text = any(p_ids) and type = 'appeal'
      and lower(coalesce(answers->>2, '')) like '%' || lower(public.staff_name(staff_key)) || '%'
  ) then return -3; end if;
  single := coalesce(array_length(p_ids, 1), 0) = 1;
  rv := nullif(left(trim(coalesce(p_reviewer, '')), 40), '');
  nt := nullif(left(trim(coalesce(p_note, '')), 300), '');
  select string_agg(discord_name, ', ') into names from public.applications where id::text = any(p_ids);
  if single then
    insert into public.application_history (application_id, status, reviewer, note, actor)
      select id, p_status, rv, nt, public.staff_name(staff_key) from public.applications where id::text = any(p_ids);
    update public.applications set status = p_status, reviewer = rv, status_note = nt, status_at = now()
      where id::text = any(p_ids);
  else
    insert into public.application_history (application_id, status, reviewer, note, actor)
      select id, p_status, reviewer, null, public.staff_name(staff_key) from public.applications where id::text = any(p_ids);
    update public.applications set status = p_status, status_at = now() where id::text = any(p_ids);
  end if;
  get diagnostics n = row_count;
  if n > 0 then perform public.log_action(staff_key, 'progress: ' || p_status, n || ' application(s): ' || coalesce(names, '')); end if;
  return n;
end $$;

-- Any staff role can read the history of one application.
create or replace function public.list_application_history(staff_key text, p_id text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if public.staff_role(staff_key) is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.at desc) from
    (select at, status, reviewer, note, actor from public.application_history where application_id::text = p_id) x), '[]'::jsonb);
end $$;

-- Admin only.
create or replace function public.delete_applications(staff_key text, p_ids text[])
returns integer language plpgsql security definer set search_path = public
as $$
declare n int; r text; names text;
begin
  r := public.staff_role(staff_key);
  if r is null then return -1; end if;
  if r <> 'admin' then return -2; end if;
  select string_agg(discord_name, ', ') into names from public.applications where id::text = any(p_ids);
  delete from public.applications where id::text = any(p_ids);
  get diagnostics n = row_count;
  if n > 0 then perform public.log_action(staff_key, 'deleted', n || ' application(s): ' || coalesce(names, '')); end if;
  return n;
end $$;

-- Admin only: manage logins.
create or replace function public.list_staff(staff_key text)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if public.staff_role(staff_key) is distinct from 'admin' then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id::text, 'name', name, 'role', role,
    'active', active, 'created_at', created_at, 'last_used', last_used) order by created_at) from public.staff_users), '[]'::jsonb);
end $$;

create or replace function public.create_staff(staff_key text, p_name text, p_role text)
returns text language plpgsql security definer set search_path = public
as $$
declare nm text := trim(coalesce(p_name, '')); code text;
begin
  if public.staff_role(staff_key) is distinct from 'admin' then return null; end if;
  if char_length(nm) < 1 or char_length(nm) > 40 then return null; end if;
  if p_role not in ('viewer','reviewer','admin') then return null; end if;
  code := 'wm-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 20);
  insert into public.staff_users (name, role, code_hash) values (nm, p_role, public.code_hash(code));
  perform public.log_action(staff_key, 'created login', nm || ' (' || p_role || ')');
  return code;
end $$;

create or replace function public.update_staff(staff_key text, p_id text, p_role text, p_active boolean)
returns boolean language plpgsql security definer set search_path = public
as $$
declare nm text;
begin
  if public.staff_role(staff_key) is distinct from 'admin' then return false; end if;
  if p_role is not null and p_role not in ('viewer','reviewer','admin') then return false; end if;
  update public.staff_users set role = coalesce(p_role, role), active = coalesce(p_active, active)
  where id::text = p_id returning name into nm;
  if not found then return false; end if;
  perform public.log_action(staff_key, 'changed login',
    nm || ':' || coalesce(' role ' || p_role, '') ||
    case when p_active is null then '' when p_active then ' restored' else ' revoked' end);
  return true;
end $$;

create or replace function public.reset_staff_code(staff_key text, p_id text)
returns text language plpgsql security definer set search_path = public
as $$
declare nm text; code text;
begin
  if public.staff_role(staff_key) is distinct from 'admin' then return null; end if;
  code := 'wm-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 20);
  update public.staff_users set code_hash = public.code_hash(code) where id::text = p_id returning name into nm;
  if not found then return null; end if;
  perform public.log_action(staff_key, 'reset code', nm);
  return code;
end $$;

create or replace function public.delete_staff(staff_key text, p_id text)
returns boolean language plpgsql security definer set search_path = public
as $$
declare nm text;
begin
  if public.staff_role(staff_key) is distinct from 'admin' then return false; end if;
  delete from public.staff_users where id::text = p_id returning name into nm;
  if not found then return false; end if;
  perform public.log_action(staff_key, 'removed login', nm);
  return true;
end $$;

create or replace function public.list_log(staff_key text)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if public.staff_role(staff_key) is distinct from 'admin' then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(to_jsonb(x)) from
    (select at, actor, action, detail from public.staff_log order by id desc limit 200) x), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------
-- DISCORD LOGIN
-- Applicants log in with Discord (Supabase Auth). Their real Discord ID comes from auth.identities,
-- which they cannot edit, and is stamped onto every application by a trigger. Nobody can fake it.
-- ---------------------------------------------------------------
create or replace function public.my_discord_id()
returns text language sql stable security definer set search_path = public, auth
as $$ select i.provider_id from auth.identities i where i.user_id = auth.uid() and i.provider = 'discord' limit 1 $$;

-- Discord profile picture shown in the staff dashboard. Read from the person's own Discord login (they cannot edit it here).
alter table public.applications add column if not exists avatar text;

create or replace function public.stamp_discord_id()
returns trigger language plpgsql security definer set search_path = public, auth
as $$
begin
  new.discord_id := public.my_discord_id();
  select left(coalesce(u.raw_user_meta_data->>'avatar_url', u.raw_user_meta_data->>'picture'), 300) into new.avatar
    from auth.users u where u.id = auth.uid();
  return new;
end $$;

-- Fill in profile pictures for applications that were sent before this existed (only people who have logged in with Discord).
update public.applications a set avatar = left(coalesce(u.raw_user_meta_data->>'avatar_url', u.raw_user_meta_data->>'picture'), 300)
  from auth.identities i join auth.users u on u.id = i.user_id
  where a.avatar is null and a.discord_id is not null and i.provider = 'discord' and i.provider_id = a.discord_id;

drop trigger if exists applications_stamp_discord on public.applications;
create trigger applications_stamp_discord before insert on public.applications
  for each row execute function public.stamp_discord_id();

-- Only the logged-in person's own applications (status, progress info, history and answers).
drop function if exists public.my_applications();
create or replace function public.my_applications()
returns table (id uuid, created_at timestamptz, type text, status text, answers jsonb,
               reviewer text, status_note text, status_at timestamptz, history jsonb)
language sql stable security definer set search_path = public
as $$
  select a.id, a.created_at, a.type, a.status, a.answers, a.reviewer, a.status_note, a.status_at,
         coalesce((select jsonb_agg(jsonb_build_object('at', h.at, 'status', h.status, 'reviewer', h.reviewer, 'note', h.note) order by h.at)
                   from public.application_history h where h.application_id = a.id), '[]'::jsonb)
  from public.applications a
  where public.my_discord_id() is not null and a.discord_id = public.my_discord_id()
  order by a.created_at desc
$$;

-- APPEALS: after a denial, the same Discord account has to wait 7 days before sending another one.
create or replace function public.appeal_cooldown_guard()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.type = 'appeal' and new.discord_id is not null and exists (
    select 1 from public.applications
    where type = 'appeal' and discord_id = new.discord_id and status = 'denied'
      and coalesce(status_at, created_at) > now() - interval '7 days'
  ) then raise exception 'appeal_cooldown'; end if;
  return new;
end $$;
drop trigger if exists zz_appeal_cooldown on public.applications;
create trigger zz_appeal_cooldown before insert on public.applications
  for each row execute function public.appeal_cooldown_guard();

-- Only people logged in with Discord can apply, and only while that type is open (insert only).
drop policy if exists "anyone can apply" on public.applications;
drop policy if exists "discord users can apply" on public.applications;
create policy "discord users can apply" on public.applications
  for insert to authenticated with check (public.type_is_open(type) and public.my_discord_id() is not null);

grant usage on schema public to anon, authenticated;
revoke all on public.applications from anon, authenticated;
grant insert on public.applications to authenticated;

-- Discord staff login. The website sends the person's Discord token; we ask Discord for their roles in
-- the server and hand back a short-lived session key (8 hours) that the dashboard uses like a staff code.
create or replace function public.staff_login_discord(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  guild constant text := '1402002569965867008';
  owner_id constant text := '1271246652421701633';
  resp extensions.http_response;
  j jsonb; rank int := 0; r_rank int := null; m record;
  uid text; nm text; k text; r text;
begin
  if p_token is null or char_length(p_token) < 10 or char_length(p_token) > 300 then
    return jsonb_build_object('error', 'bad_token');
  end if;
  begin
    resp := extensions.http((
      'GET',
      'https://discord.com/api/v10/users/@me/guilds/' || guild || '/member',
      array[extensions.http_header('Authorization', 'Bearer ' || p_token),
            extensions.http_header('User-Agent', 'DiscordBot (willmac-mod-apps, 1.0)')],
      null, null)::extensions.http_request);
  exception when others then
    return jsonb_build_object('error', 'discord_unreachable');
  end;
  if resp.status in (401, 403) then return jsonb_build_object('error', 'bad_token'); end if;
  if resp.status = 404 then return jsonb_build_object('error', 'not_in_server'); end if;
  if resp.status <> 200 then return jsonb_build_object('error', 'discord_error', 'status', resp.status); end if;
  j := resp.content::jsonb;

  uid := j->'user'->>'id';
  if uid is null then return jsonb_build_object('error', 'discord_error'); end if;

  for m in select d.access from public.discord_role_map d
           where d.access <> 'none'
             and d.role_id in (select jsonb_array_elements_text(coalesce(j->'roles', '[]'::jsonb)))
  loop
    r_rank := case m.access when 'admin' then 3 when 'reviewer' then 2 else 1 end;
    if r_rank > rank then rank := r_rank; end if;
  end loop;
  select case o.access when 'admin' then 3 when 'reviewer' then 2 else 1 end into r_rank
    from public.staff_overrides o where o.discord_id = uid;
  if r_rank is not null and r_rank > rank then rank := r_rank; end if;
  if uid = owner_id then rank := 3; end if;
  if rank = 0 then return jsonb_build_object('error', 'no_role'); end if;
  r := case rank when 3 then 'admin' when 2 then 'reviewer' else 'viewer' end;
  nm  := left(coalesce(nullif(j->>'nick', ''), nullif(j->'user'->>'global_name', ''), j->'user'->>'username', 'Staff'), 40);

  delete from public.staff_sessions where expires_at < now() or discord_id = uid;
  k := 'ds-' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.staff_sessions (key_hash, discord_id, name, role, expires_at)
  values (public.code_hash(k), uid, nm, r, now() + interval '8 hours');
  perform public.log_action(k, 'discord login', nm || ' (' || r || ')');
  return jsonb_build_object('key', k, 'role', r, 'name', nm);
end $$;

create or replace function public.staff_logout(staff_key text)
returns void language sql security definer set search_path = public
as $$ delete from public.staff_sessions where key_hash = public.code_hash(staff_key) $$;

-- Admin only: see and change what each Discord role / person can do. Others are signed out so it applies at once.
create or replace function public.list_access(staff_key text)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if public.staff_role(staff_key) is distinct from 'admin' then return null; end if;
  return jsonb_build_object(
    'roles',  coalesce((select jsonb_agg(jsonb_build_object('role_id', role_id, 'label', label, 'access', access) order by label) from public.discord_role_map), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('discord_id', discord_id, 'name', name, 'access', access) order by name) from public.staff_overrides), '[]'::jsonb));
end $$;

create or replace function public.set_role_access(staff_key text, p_role_id text, p_access text)
returns boolean language plpgsql security definer set search_path = public
as $$
declare lb text;
begin
  if public.staff_role(staff_key) is distinct from 'admin' then return false; end if;
  if p_access not in ('none','viewer','reviewer','admin') then return false; end if;
  update public.discord_role_map set access = p_access where role_id = p_role_id returning label into lb;
  if not found then return false; end if;
  delete from public.staff_sessions where key_hash <> public.code_hash(staff_key);
  perform public.log_action(staff_key, 'role access', lb || ' -> ' || p_access);
  return true;
end $$;

-- p_access null removes the person. The owner can't be changed or removed.
create or replace function public.set_person_access(staff_key text, p_discord_id text, p_name text, p_access text)
returns boolean language plpgsql security definer set search_path = public
as $$
declare did text := trim(coalesce(p_discord_id, '')); nm text := trim(coalesce(p_name, ''));
begin
  if public.staff_role(staff_key) is distinct from 'admin' then return false; end if;
  if did !~ '^[0-9]{5,25}$' or did = '1271246652421701633' then return false; end if;
  if p_access is null then
    delete from public.staff_overrides where discord_id = did;
    perform public.log_action(staff_key, 'person access', 'removed ' || did);
  else
    if p_access not in ('viewer','reviewer','admin') or char_length(nm) not between 1 and 40 then return false; end if;
    insert into public.staff_overrides (discord_id, name, access) values (did, nm, p_access)
    on conflict (discord_id) do update set name = excluded.name, access = excluded.access;
    perform public.log_action(staff_key, 'person access', nm || ' (' || did || ') -> ' || p_access);
  end if;
  delete from public.staff_sessions where key_hash <> public.code_hash(staff_key);
  return true;
end $$;

-- Internal helpers: not callable from the website.
revoke all on function public.is_master(text) from public, anon, authenticated;
revoke all on function public.code_hash(text) from public, anon, authenticated;
revoke all on function public.staff_name(text) from public, anon, authenticated;
revoke all on function public.log_action(text, text, text) from public, anon, authenticated;

grant execute on function public.is_staff(text) to anon, authenticated;
grant execute on function public.staff_role(text) to anon, authenticated;
grant execute on function public.staff_login(text) to anon, authenticated;
grant execute on function public.staff_login_discord(text) to anon, authenticated;
grant execute on function public.staff_logout(text) to anon, authenticated;
grant execute on function public.list_access(text) to anon, authenticated;
grant execute on function public.set_role_access(text, text, text) to anon, authenticated;
grant execute on function public.set_person_access(text, text, text, text) to anon, authenticated;
grant execute on function public.type_is_open(text) to anon, authenticated;
grant execute on function public.get_closed_types() to anon, authenticated;
grant execute on function public.set_type_open(text, text, boolean) to anon, authenticated;
grant execute on function public.list_applications(text) to anon, authenticated;
grant execute on function public.set_application_status(text, text[], text) to anon, authenticated;
grant execute on function public.set_application_progress(text, text[], text, text, text) to anon, authenticated;
grant execute on function public.list_application_history(text, text) to anon, authenticated;
grant execute on function public.delete_applications(text, text[]) to anon, authenticated;
grant execute on function public.list_staff(text) to anon, authenticated;
grant execute on function public.create_staff(text, text, text) to anon, authenticated;
grant execute on function public.update_staff(text, text, text, boolean) to anon, authenticated;
grant execute on function public.reset_staff_code(text, text) to anon, authenticated;
grant execute on function public.delete_staff(text, text) to anon, authenticated;
grant execute on function public.list_log(text) to anon, authenticated;

revoke all on function public.my_discord_id() from public, anon;
revoke all on function public.my_applications() from public, anon;
grant execute on function public.my_discord_id() to authenticated;
grant execute on function public.my_applications() to authenticated;

notify pgrst, 'reload schema';


-- ---------------------------------------------------------------
-- RESULT FEEDBACK
-- Members rate a decided result (approved / denied) from "My applications". Their name is always shown.
-- A one-way code is kept so nobody can send twice for the same result.
-- Staff (any role) read it in the pinned Feedback folder; admins can delete it.
-- ---------------------------------------------------------------
create table if not exists public.feedback (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  app_type   text not null,
  outcome    text not null check (outcome in ('approved','denied')),
  message    text not null,
  anonymous  boolean not null default false,
  name       text,
  limit_key  text not null unique
);
-- If you ran an older version of this file (thumbs up/down), this upgrades the table to written reviews.
alter table public.feedback drop column if exists rating;
alter table public.feedback drop constraint if exists feedback_message_check;
alter table public.feedback alter column message set not null;
update public.feedback set message = 'No written review' where message is null;
alter table public.feedback add constraint feedback_message_check check (char_length(message) between 1 and 1000);
alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;

drop function if exists public.submit_feedback(uuid, text, text, boolean);
create or replace function public.submit_feedback(p_app_id uuid, p_message text, p_anonymous boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare did text; a public.applications; k text; n int; m text;
begin
  did := public.my_discord_id();
  if did is null then return 'login'; end if;
  m := left(trim(coalesce(p_message, '')), 1000);
  if char_length(m) < 20 then return 'short'; end if;
  select * into a from public.applications where id = p_app_id and discord_id = did;
  if not found then return 'notfound'; end if;
  if a.status not in ('approved','denied') then return 'notdecided'; end if;
  k := encode(sha256(convert_to(did || ':' || p_app_id::text, 'utf8')), 'hex');
  insert into public.feedback (app_type, outcome, message, anonymous, name, limit_key)
  values (a.type, a.status, m, false, left(a.discord_name, 100), k)
  on conflict (limit_key) do nothing;
  get diagnostics n = row_count;
  return case when n = 0 then 'duplicate' else 'ok' end;
end $$;

create or replace function public.my_feedback_given()
returns text[] language sql stable security definer set search_path = public
as $$
  select coalesce(array_agg(a.id::text), '{}') from public.applications a
  where public.my_discord_id() is not null and a.discord_id = public.my_discord_id()
    and exists (select 1 from public.feedback f
                where f.limit_key = encode(sha256(convert_to(a.discord_id || ':' || a.id::text, 'utf8')), 'hex'))
$$;

drop function if exists public.list_feedback(text);
create or replace function public.list_feedback(staff_key text)
returns table (id bigint, created_at timestamptz, app_type text, outcome text, message text, anonymous boolean, name text)
language sql stable security definer set search_path = public
as $$
  select f.id, f.created_at, f.app_type, f.outcome, f.message, f.anonymous, f.name
  from public.feedback f where public.staff_role(staff_key) is not null
  order by f.created_at desc limit 500
$$;

create or replace function public.delete_feedback(staff_key text, p_id bigint)
returns boolean language plpgsql security definer set search_path = public
as $$
begin
  if public.staff_role(staff_key) is distinct from 'admin' then return false; end if;
  delete from public.feedback where id = p_id;
  perform public.log_action(staff_key, 'deleted', 'feedback #' || p_id);
  return true;
end $$;


-- ---------------------------------------------------------------
-- GENERAL FEEDBACK (new): the "Feedback" box on the home page.
-- Any logged-in member can send a message to staff (no application needed). Their name is always shown.
-- Limit: one message per 5 minutes (admins have no limit) per person. Shows in the pinned Feedback folder on the dashboard.
-- ---------------------------------------------------------------
alter table public.feedback add column if not exists rl_key text;
alter table public.feedback drop constraint if exists feedback_outcome_check;
alter table public.feedback add constraint feedback_outcome_check check (outcome in ('approved','denied','general'));

create index if not exists feedback_rl_key_created_idx on public.feedback (rl_key, created_at desc);

-- Admins have no feedback limit. An admin = the owner, anyone given admin in staff_overrides, or anyone with a live admin staff session
-- (that session is created automatically when an admin logs in with Discord on the site, and lasts 8 hours).
create or replace function public.feedback_is_admin(did text)
returns boolean language sql stable security definer set search_path = public
as $$
  select did is not null and (
    did = '1271246652421701633'
    or exists (select 1 from public.staff_overrides o where o.discord_id = did and o.access = 'admin')
    or exists (select 1 from public.staff_sessions s where s.discord_id = did and s.role = 'admin' and s.expires_at > now())
  )
$$;
revoke all on function public.feedback_is_admin(text) from public, anon, authenticated;

-- FIX: the old version used greatest(1, <null>) which returns 1 in Postgres, so a member with NO earlier feedback
-- was told "wait:1" every time. Now the last message time is read first, and only a real recent message blocks sending.
create or replace function public.submit_general_feedback(p_message text, p_anonymous boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare did text; m text; r text; nm text; last_at timestamptz; w int; adm boolean;
begin
  did := public.my_discord_id();
  if did is null then return 'login'; end if;
  m := left(trim(coalesce(p_message, '')), 1000);
  if char_length(m) < 5 then return 'short'; end if;
  r := encode(sha256(convert_to('gen:' || did, 'utf8')), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(r, 0));   -- two taps / two tabs at once can't both get through
  adm := public.feedback_is_admin(did);
  select max(created_at) into last_at from public.feedback where rl_key = r;
  if not adm and last_at is not null and last_at > now() - interval '5 minutes' then
    w := greatest(1, ceil(extract(epoch from (last_at + interval '5 minutes' - now())))::int);
    return 'wait:' || w;
  end if;
  -- Feedback from the home page always shows the member's name (no anonymous option).
  select left(a.discord_name, 100) into nm from public.applications a where a.discord_id = did order by a.created_at desc limit 1;
  nm := coalesce(nm, 'Member');
  insert into public.feedback (app_type, outcome, message, anonymous, name, limit_key, rl_key)
  values ('general', 'general', m, false, nm,
          encode(sha256(convert_to(did || ':' || clock_timestamp()::text || random()::text, 'utf8')), 'hex'), r);
  return 'ok';
end $$;
grant execute on function public.submit_general_feedback(text, boolean) to anon, authenticated;

-- Seconds left before this member can send more feedback (0 = they can send now). Drives the timer next to Send.
create or replace function public.my_feedback_wait()
returns int language plpgsql stable security definer set search_path = public
as $$
declare did text; r text; last_at timestamptz;
begin
  did := public.my_discord_id();
  if did is null then return 0; end if;
  if public.feedback_is_admin(did) then return 0; end if;
  r := encode(sha256(convert_to('gen:' || did, 'utf8')), 'hex');
  select max(created_at) into last_at from public.feedback where rl_key = r;
  if last_at is null or last_at <= now() - interval '5 minutes' then return 0; end if;
  return greatest(1, ceil(extract(epoch from (last_at + interval '5 minutes' - now())))::int);
end $$;
grant execute on function public.my_feedback_wait() to anon, authenticated;
notify pgrst, 'reload schema';

-- ======================= 20261113000002_discord_helpers_moderation.sql =======================
-- =====================================================================================================
-- 0002  Discord helpers, user management, moderation log, permission matrix
-- Safe to run again. Never deletes data. Requires 0001 (the original schema) to have been run.
-- =====================================================================================================

-- ---------- 1. Discord helpers (internal) ----------
-- All Discord logins as people, with their CURRENT Discord name + picture.
create or replace function public.discord_users()
returns table (discord_id text, username text, display_name text, avatar text, created_at timestamptz, last_sign_in timestamptz)
language sql stable security definer set search_path = public, auth
as $$
  select i.provider_id,
         coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), nullif(u.raw_user_meta_data->>'name', ''), nullif(i.identity_data->>'full_name', '')),
         coalesce(nullif(u.raw_user_meta_data->'custom_claims'->>'global_name', ''), nullif(u.raw_user_meta_data->>'full_name', ''), nullif(u.raw_user_meta_data->>'name', '')),
         left(coalesce(u.raw_user_meta_data->>'avatar_url', u.raw_user_meta_data->>'picture', i.identity_data->>'avatar_url'), 300),
         u.created_at, u.last_sign_in_at
  from auth.identities i join auth.users u on u.id = i.user_id
  where i.provider = 'discord'
$$;
create or replace function public.discord_user(p_id text)
returns table (discord_id text, username text, display_name text, avatar text, created_at timestamptz, last_sign_in timestamptz)
language sql stable security definer set search_path = public, auth
as $$
  select i.provider_id,
         coalesce(nullif(u.raw_user_meta_data->>'full_name', ''), nullif(u.raw_user_meta_data->>'name', ''), nullif(i.identity_data->>'full_name', '')),
         coalesce(nullif(u.raw_user_meta_data->'custom_claims'->>'global_name', ''), nullif(u.raw_user_meta_data->>'full_name', ''), nullif(u.raw_user_meta_data->>'name', '')),
         left(coalesce(u.raw_user_meta_data->>'avatar_url', u.raw_user_meta_data->>'picture', i.identity_data->>'avatar_url'), 300),
         u.created_at, u.last_sign_in_at
  from auth.identities i join auth.users u on u.id = i.user_id
  where i.provider = 'discord' and i.provider_id = p_id limit 1
$$;
create or replace function public.my_discord_name()
returns text language sql stable security definer set search_path = public
as $$ select left(d.display_name, 100) from public.discord_user(public.my_discord_id()) d $$;
create or replace function public.my_discord_avatar()
returns text language sql stable security definer set search_path = public
as $$ select d.avatar from public.discord_user(public.my_discord_id()) d $$;

create or replace function public.acc_rank(a text)
returns int language sql immutable
as $$ select case a when 'admin' then 3 when 'reviewer' then 2 when 'viewer' then 1 else 0 end $$;

-- Optional: a Discord BOT token lets "Add Staff" look up people who never logged in to the website.
-- Never put it in the website. Store it here once, in the SQL editor (run this line yourself, with your own token):
--   insert into public.app_secrets (k, v) values ('discord_bot_token', 'PASTE_BOT_TOKEN_HERE') on conflict (k) do update set v = excluded.v;
create table if not exists public.app_secrets (k text primary key, v text not null);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

-- ---------- 2. User management + moderation log ----------
create table if not exists public.user_moderation (
  discord_id text primary key check (discord_id ~ '^[0-9]{5,25}$'),
  status     text not null check (status in ('banned','timeout')),
  until_at   timestamptz,
  reason     text,
  by_name    text,
  by_id      text,
  created_at timestamptz not null default now()
);
alter table public.user_moderation enable row level security;
revoke all on public.user_moderation from anon, authenticated;

create table if not exists public.moderation_log (
  id          bigserial primary key,
  at          timestamptz not null default now(),
  actor       text not null,
  actor_id    text,
  action      text not null check (action in ('ban','unban','timeout','untimeout','warn','note')),
  target_id   text not null,
  target_name text,
  reason      text,
  detail      text
);
create index if not exists moderation_log_target on public.moderation_log (target_id, at desc);
create index if not exists moderation_log_at on public.moderation_log (at desc);
alter table public.moderation_log enable row level security;
revoke all on public.moderation_log from anon, authenticated;

-- 'active' | 'timeout' | 'banned'. An expired timeout counts as active again by itself.
create or replace function public.user_state(did text)
returns text language sql stable security definer set search_path = public
as $$
  select coalesce((select case when m.status = 'banned' then 'banned' when m.status = 'timeout' and m.until_at > now() then 'timeout' else 'active' end
                   from public.user_moderation m where m.discord_id = did), 'active')
$$;

-- The logged-in member asks "am I restricted?" (the website shows the ban page when this returns something).
create or replace function public.my_restriction()
returns jsonb language sql stable security definer set search_path = public
as $$
  select (select jsonb_build_object('status', public.user_state(m.discord_id), 'reason', m.reason, 'until', m.until_at, 'since', m.created_at)
          from public.user_moderation m
          where m.discord_id = public.my_discord_id() and public.user_state(m.discord_id) <> 'active')
$$;

-- Refuse new applications from restricted members. Refreshing or logging in again cannot get around this: it is checked here.
create or replace function public.restricted_guard()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.discord_id is not null and public.user_state(new.discord_id) <> 'active' then raise exception 'user_restricted'; end if;
  return new;
end $$;
drop trigger if exists zz_restricted_guard on public.applications;
create trigger zz_restricted_guard before insert on public.applications
  for each row execute function public.restricted_guard();

drop policy if exists "discord users can apply" on public.applications;
create policy "discord users can apply" on public.applications
  for insert to authenticated with check (public.type_is_open(type) and public.my_discord_id() is not null and public.user_state(public.my_discord_id()) = 'active');

-- Staff identity helpers
create table if not exists public.staff_profiles (
  discord_id   text primary key,
  username     text not null default '',
  display_name text not null default '',
  avatar       text,
  access       text,
  last_seen    timestamptz,
  away         boolean not null default false,
  updated_at   timestamptz not null default now()
);
alter table public.staff_profiles enable row level security;
revoke all on public.staff_profiles from anon, authenticated;

create table if not exists public.staff_members (
  discord_id   text primary key check (discord_id ~ '^[0-9]{5,25}$'),
  username     text not null default '',
  display_name text not null default '',
  avatar       text,
  rank_name    text not null check (rank_name in ('Owner','Co-Owner','Administrator','Senior Moderator','Lead Moderator','Moderator','Helper','Staff')),
  sort_order   int  not null default 0,
  added_by     text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table public.staff_members enable row level security;
revoke all on public.staff_members from anon, authenticated;

-- People removed from the staff team. They lose dashboard access even if they still have a Discord role.
create table if not exists public.staff_blocked (
  discord_id text primary key,
  reason     text,
  created_at timestamptz not null default now()
);
alter table public.staff_blocked enable row level security;
revoke all on public.staff_blocked from anon, authenticated;

create or replace function public.sync_staff_profile(p_id text, p_user text, p_display text, p_avatar text, p_access text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  insert into public.staff_profiles (discord_id, username, display_name, avatar, access, last_seen)
  values (p_id, left(coalesce(p_user, ''), 80), left(coalesce(p_display, p_user, ''), 80), left(p_avatar, 300), p_access, now())
  on conflict (discord_id) do update set username = excluded.username, display_name = excluded.display_name,
    avatar = coalesce(excluded.avatar, public.staff_profiles.avatar), access = excluded.access, updated_at = now();
  update public.staff_members set username = left(coalesce(p_user, username), 80), display_name = left(coalesce(p_display, p_user, display_name), 80),
    avatar = coalesce(left(p_avatar, 300), avatar), updated_at = now() where discord_id = p_id;
end $$;

-- The Discord ID behind a staff session (null for backup codes). The owner key counts as the owner.
create or replace function public.staff_actor_id(k text)
returns text language sql stable security definer set search_path = public
as $$
  select case when public.is_master(k) then '1271246652421701633'
              else (select s.discord_id from public.staff_sessions s where s.key_hash = public.code_hash(k) and s.expires_at > now()) end
$$;


-- ---------- Permission matrix (enforced in the database) ----------
-- Ranks:  Owner > Administrator > Senior (Lead) Moderator > Moderator > Helper.
-- Dashboard access tiers already used by this site:  admin = Owner/Administrator,  reviewer = Senior/Lead Moderator,  viewer = Moderator/Helper.
-- A Helper is a 'viewer' whose staff-team rank is Helper/Staff. Nothing here raises anyone's access: Moderators who are 'viewer'
-- stay read-only for decisions until an admin gives them Reviewer in Staff access. Capabilities:
--   everyone on staff : chat, apps_view
--   Moderator and up  : userinfo, logs, notes_view, warn, note, app_notes
--   Senior Mod and up : claim, decide (approve/deny), timeout, pin, slowmode, feedback_manage, mention_staff
--   Administrator     : ban, assign, announce, lock, clear, apps_toggle, promote, activity, channels, users, staff_manage, mention_everyone, screenshot
--   Owner             : owner (ban/remove/edit other administrators, set administrator-level ranks)
create or replace function public.staff_is_helper(did text)
returns boolean language sql stable security definer set search_path = public
as $$ select coalesce((select m.rank_name in ('Helper','Staff') from public.staff_members m where m.discord_id = did), false) $$;

create or replace function public.staff_caps(k text)
returns text[] language plpgsql stable security definer set search_path = public
as $$
declare rl text := public.staff_role(k); me text := public.staff_actor_id(k); caps text[] := '{}'; helper boolean;
begin
  if rl is null then return '{}'; end if;
  helper := rl = 'viewer' and public.staff_is_helper(me);
  caps := array['chat','apps_view'];
  if not helper then caps := caps || array['userinfo','logs','notes_view','warn','note','app_notes']; end if;
  if rl in ('reviewer','admin') then caps := caps || array['claim','decide','timeout','pin','slowmode','feedback_manage','mention_staff']; end if;
  if rl = 'admin' then caps := caps || array['ban','assign','announce','lock','clear','apps_toggle','promote','activity','channels','users','staff_manage','mention_everyone','screenshot']; end if;
  if public.is_master(k) or me = '1271246652421701633' then caps := caps || array['owner']; end if;
  return caps;
end $$;

create or replace function public.staff_can(k text, cap text)
returns boolean language sql stable security definer set search_path = public
as $$ select cap = any(public.staff_caps(k)) $$;

create or replace function public.staff_access_of(did text)
returns text language sql stable security definer set search_path = public
as $$ select coalesce((select o.access from public.staff_overrides o where o.discord_id = did), (select p.access from public.staff_profiles p where p.discord_id = did)) $$;

-- Can this staff member do <cap> to this person? Returns null when allowed, otherwise a reason code.
-- Nobody can act on the owner or themselves. Only the owner can act on someone with the same or higher access.
create or replace function public.mod_guard(k text, did text, cap text)
returns text language plpgsql stable security definer set search_path = public
as $$
declare owner_id constant text := '1271246652421701633'; actor text := public.staff_actor_id(k); is_owner boolean; tgt text;
begin
  if not public.staff_can(k, cap) then return 'forbidden'; end if;
  if did is null or did !~ '^[0-9]{5,25}$' then return 'invalid'; end if;
  is_owner := public.is_master(k) or actor = owner_id;
  if did = owner_id then return 'protected'; end if;
  if actor is not null and did = actor then return 'self'; end if;
  tgt := public.staff_access_of(did);
  if not is_owner and (
        (tgt is not null and public.acc_rank(tgt) >= public.acc_rank(public.staff_role(k)))
     or exists (select 1 from public.staff_members m where m.discord_id = did and m.rank_name in ('Owner','Co-Owner','Administrator'))
  ) then return 'protected'; end if;
  return null;
end $$;

-- Ban / unban (Administrator+), timeout / remove timeout (Senior Moderator+), warn / note (Moderator+, not Helpers). Returns 'ok' or a reason code.
create or replace function public.mod_action(staff_key text, p_discord_id text, p_action text, p_reason text, p_minutes integer default null)
returns text language plpgsql security definer set search_path = public
as $$
declare g text; did text := trim(coalesce(p_discord_id, '')); rs text := left(trim(coalesce(p_reason, '')), 300);
        tn text; cur text; until_ts timestamptz; actor text; aid text;
begin
  if p_action not in ('ban','unban','timeout','untimeout','warn','note') then return 'invalid'; end if;
  g := public.mod_guard(staff_key, did, case p_action when 'ban' then 'ban' when 'unban' then 'ban' when 'timeout' then 'timeout' when 'untimeout' then 'timeout' when 'warn' then 'warn' else 'note' end);
  if g is not null then return g; end if;
  if p_action in ('ban','timeout','warn') and char_length(rs) < 3 then return 'reason_required'; end if;
  cur := public.user_state(did);
  actor := coalesce(public.staff_name(staff_key), '?'); aid := public.staff_actor_id(staff_key);
  select coalesce(d.display_name, d.username) into tn from public.discord_user(did) d;
  tn := coalesce(tn, (select p.display_name from public.staff_profiles p where p.discord_id = did), did);

  if p_action = 'ban' then
    if cur = 'banned' then return 'already_banned'; end if;
    insert into public.user_moderation (discord_id, status, until_at, reason, by_name, by_id) values (did, 'banned', null, nullif(rs, ''), actor, aid)
    on conflict (discord_id) do update set status = 'banned', until_at = null, reason = excluded.reason, by_name = excluded.by_name, by_id = excluded.by_id, created_at = now();
    delete from public.staff_sessions where discord_id = did;
  elsif p_action = 'timeout' then
    if p_minutes is null or p_minutes < 1 or p_minutes > 43200 then return 'invalid'; end if;
    if cur = 'banned' then return 'already_banned'; end if;
    until_ts := now() + make_interval(mins => p_minutes);
    insert into public.user_moderation (discord_id, status, until_at, reason, by_name, by_id) values (did, 'timeout', until_ts, nullif(rs, ''), actor, aid)
    on conflict (discord_id) do update set status = 'timeout', until_at = excluded.until_at, reason = excluded.reason, by_name = excluded.by_name, by_id = excluded.by_id, created_at = now();
    delete from public.staff_sessions where discord_id = did;
  elsif p_action = 'unban' then
    if cur <> 'banned' then return 'not_banned'; end if;
    delete from public.user_moderation where discord_id = did;
  elsif p_action = 'untimeout' then
    if cur <> 'timeout' then return 'not_timed_out'; end if;
    delete from public.user_moderation where discord_id = did;
  end if;

  insert into public.moderation_log (actor, actor_id, action, target_id, target_name, reason, detail)
  values (actor, aid, p_action, did, tn, nullif(rs, ''),
          case when p_action = 'timeout' then p_minutes || ' minutes, until ' || to_char(until_ts at time zone 'utc', 'YYYY-MM-DD HH24:MI') || ' UTC' end);
  perform public.log_action(staff_key, 'user ' || p_action, tn);
  return 'ok';
end $$;

-- Every member who logged in with Discord. Administrators only.
create or replace function public.list_site_users(staff_key text, p_q text default '', p_status text default 'all', p_limit integer default 500)
returns table (discord_id text, username text, display_name text, avatar text, created_at timestamptz, last_sign_in timestamptz,
               status text, until_at timestamptz, reason text, by_name text, app_count bigint, is_staff boolean)
language sql stable security definer set search_path = public
as $$
  select d.discord_id, d.username, d.display_name, d.avatar, d.created_at, d.last_sign_in,
         public.user_state(d.discord_id), m.until_at, m.reason, m.by_name,
         (select count(*) from public.applications a where a.discord_id = d.discord_id),
         (exists (select 1 from public.staff_members sm where sm.discord_id = d.discord_id) or exists (select 1 from public.staff_overrides so where so.discord_id = d.discord_id)
          or exists (select 1 from public.staff_profiles sp where sp.discord_id = d.discord_id))
  from public.discord_users() d left join public.user_moderation m on m.discord_id = d.discord_id
  where public.staff_can(staff_key, 'users')
    and (coalesce(trim(p_q), '') = '' or d.discord_id = trim(p_q) or d.username ilike '%' || trim(p_q) || '%' or d.display_name ilike '%' || trim(p_q) || '%')
    and (p_status = 'all' or public.user_state(d.discord_id) = p_status)
  order by d.created_at desc
  limit least(greatest(coalesce(p_limit, 500), 1), 2000)
$$;

-- One person: profile + moderation history + their applications. Moderators and up (not Helpers).
create or replace function public.mod_user_detail(staff_key text, p_discord_id text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare did text := trim(coalesce(p_discord_id, '')); d record; m record; owner_id constant text := '1271246652421701633';
begin
  if not public.staff_can(staff_key, 'userinfo') then return null; end if;
  select * into d from public.discord_user(did);
  select * into m from public.user_moderation where discord_id = did;
  return jsonb_build_object(
    'discord_id', did, 'username', d.username, 'display_name', d.display_name, 'avatar', d.avatar, 'registered', d.created_at, 'last_sign_in', d.last_sign_in,
    'status', public.user_state(did), 'until', m.until_at, 'reason', m.reason, 'by', m.by_name, 'since', m.created_at,
    'protected', public.mod_guard(staff_key, did, 'warn') is not null, 'is_owner', did = owner_id,
    'history', coalesce((select jsonb_agg(to_jsonb(x) order by x.at desc) from
        (select at, actor, action, reason, detail from public.moderation_log where target_id = did order by id desc limit 100) x), '[]'::jsonb),
    'applications', coalesce((select jsonb_agg(to_jsonb(y) order by y.created_at desc) from
        (select id, type, status, created_at from public.applications where discord_id = did order by created_at desc limit 30) y), '[]'::jsonb));
end $$;

-- Searchable moderation history. Moderators and up (Helpers cannot see it).
create or replace function public.list_moderation_log(staff_key text, p_q text default '', p_action text default 'all', p_limit integer default 300)
returns table (id bigint, at timestamptz, actor text, action text, target_id text, target_name text, reason text, detail text)
language sql stable security definer set search_path = public
as $$
  select l.id, l.at, l.actor, l.action, l.target_id, l.target_name, l.reason, l.detail
  from public.moderation_log l
  where public.staff_can(staff_key, 'logs')
    and (p_action = 'all' or l.action = p_action)
    and (coalesce(trim(p_q), '') = '' or l.target_id = trim(p_q) or l.target_name ilike '%' || trim(p_q) || '%' or l.actor ilike '%' || trim(p_q) || '%' or l.reason ilike '%' || trim(p_q) || '%')
  order by l.id desc
  limit least(greatest(coalesce(p_limit, 300), 1), 1000)
$$;


-- Discord staff login: now also blocks removed/banned people, syncs their profile and can require 2FA for admins.
create or replace function public.staff_login_discord(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  guild constant text := '1402002569965867008';
  owner_id constant text := '1271246652421701633';
  resp extensions.http_response;
  j jsonb; rank int := 0; r_rank int := null; m record;
  uid text; nm text; k text; r text;
begin
  if p_token is null or char_length(p_token) < 10 or char_length(p_token) > 300 then
    return jsonb_build_object('error', 'bad_token');
  end if;
  begin
    resp := extensions.http((
      'GET',
      'https://discord.com/api/v10/users/@me/guilds/' || guild || '/member',
      array[extensions.http_header('Authorization', 'Bearer ' || p_token),
            extensions.http_header('User-Agent', 'DiscordBot (willmac-mod-apps, 1.0)')],
      null, null)::extensions.http_request);
  exception when others then
    return jsonb_build_object('error', 'discord_unreachable');
  end;
  if resp.status in (401, 403) then return jsonb_build_object('error', 'bad_token'); end if;
  if resp.status = 404 then return jsonb_build_object('error', 'not_in_server'); end if;
  if resp.status <> 200 then return jsonb_build_object('error', 'discord_error', 'status', resp.status); end if;
  j := resp.content::jsonb;

  uid := j->'user'->>'id';
  if uid is null then return jsonb_build_object('error', 'discord_error'); end if;

  for m in select d.access from public.discord_role_map d
           where d.access <> 'none'
             and d.role_id in (select jsonb_array_elements_text(coalesce(j->'roles', '[]'::jsonb)))
  loop
    r_rank := case m.access when 'admin' then 3 when 'reviewer' then 2 else 1 end;
    if r_rank > rank then rank := r_rank; end if;
  end loop;
  select case o.access when 'admin' then 3 when 'reviewer' then 2 else 1 end into r_rank
    from public.staff_overrides o where o.discord_id = uid;
  if r_rank is not null and r_rank > rank then rank := r_rank; end if;
  if uid = owner_id then rank := 3; end if;
  -- Removed from the staff team (blocked) or banned from the site: no dashboard access, even with a Discord role.
  if uid <> owner_id and exists (select 1 from public.staff_blocked b where b.discord_id = uid) then
    return jsonb_build_object('error', 'no_role');
  end if;
  if uid <> owner_id and public.user_state(uid) = 'banned' then return jsonb_build_object('error', 'banned'); end if;
  if rank = 0 then return jsonb_build_object('error', 'no_role'); end if;
  -- Optional: require Discord 2FA for administrators. Off by default. Turn on with:
  --   insert into public.app_secrets (k, v) values ('require_admin_2fa', 'on') on conflict (k) do update set v = excluded.v;
  -- (The owner is never locked out. If Discord can't be asked, administrators are let in rather than locked out.)
  if rank = 3 and uid <> owner_id and coalesce((select s2.v from public.app_secrets s2 where s2.k = 'require_admin_2fa'), '') = 'on' then
    begin
      resp := extensions.http(('GET', 'https://discord.com/api/v10/users/@me',
        array[extensions.http_header('Authorization', 'Bearer ' || p_token), extensions.http_header('User-Agent', 'DiscordBot (willmac-mod-apps, 1.0)')], null, null)::extensions.http_request);
      if resp.status = 200 and (resp.content::jsonb ? 'mfa_enabled') and coalesce((resp.content::jsonb->>'mfa_enabled')::boolean, false) = false then
        return jsonb_build_object('error', 'need_2fa');
      end if;
    exception when others then null;
    end;
  end if;
  r := case rank when 3 then 'admin' when 2 then 'reviewer' else 'viewer' end;
  nm  := left(coalesce(nullif(j->>'nick', ''), nullif(j->'user'->>'global_name', ''), j->'user'->>'username', 'Staff'), 40);

  delete from public.staff_sessions where expires_at < now() or discord_id = uid;
  k := 'ds-' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.staff_sessions (key_hash, discord_id, name, role, expires_at)
  values (public.code_hash(k), uid, nm, r, now() + interval '8 hours');
  -- Keep this person's Discord profile (name + avatar) in sync for Staff Chat and the staff list.
  perform public.sync_staff_profile(uid, j->'user'->>'username', coalesce(nullif(j->'user'->>'global_name', ''), nullif(j->>'nick', ''), j->'user'->>'username'),
    case when coalesce(j->'user'->>'avatar', '') <> '' then 'https://cdn.discordapp.com/avatars/' || uid || '/' || (j->'user'->>'avatar') || '.png?size=128' end, r);
  perform public.log_action(k, 'discord login', nm || ' (' || r || ')');
  return jsonb_build_object('key', k, 'role', r, 'name', nm);
end $$;

-- ---------- permissions ----------
revoke all on function public.discord_users() from public, anon, authenticated;
revoke all on function public.discord_user(text) from public, anon, authenticated;
revoke all on function public.my_discord_name() from public, anon, authenticated;
revoke all on function public.my_discord_avatar() from public, anon, authenticated;
revoke all on function public.sync_staff_profile(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.staff_actor_id(text) from public, anon, authenticated;
revoke all on function public.staff_is_helper(text) from public, anon, authenticated;
revoke all on function public.staff_access_of(text) from public, anon, authenticated;
revoke all on function public.mod_guard(text, text, text) from public, anon, authenticated;
revoke all on function public.restricted_guard() from public, anon, authenticated;
revoke all on function public.staff_can(text, text) from public, anon, authenticated;
revoke all on function public.my_restriction() from public, anon;
grant execute on function public.my_restriction() to authenticated;
revoke all on function public.user_state(text) from public, anon;
grant execute on function public.user_state(text) to authenticated;
-- the website asks which commands/screens to show; every action is still checked again when it runs
grant execute on function public.staff_caps(text) to anon, authenticated;
grant execute on function public.mod_action(text, text, text, text, integer) to anon, authenticated;
grant execute on function public.list_site_users(text, text, text, integer) to anon, authenticated;
grant execute on function public.mod_user_detail(text, text) to anon, authenticated;
grant execute on function public.list_moderation_log(text, text, text, integer) to anon, authenticated;
grant execute on function public.staff_login_discord(text) to anon, authenticated;

notify pgrst, 'reload schema';

-- ======================= 20261113000003_staff_roster.sql =======================
-- =====================================================================================================
-- 0003  Staff roster ("Our Staff Team" on the home page), Add Staff, Discord profile lookup
-- Safe to run again. Never deletes data.
-- =====================================================================================================

-- ---------- 4. Staff roster ("Our Staff Team") ----------
-- Look a person up by Discord ID or name. Uses people who logged in to the site, then staff, then (if a bot token is stored) Discord itself.
create or replace function public.resolve_discord(p_id text)
returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare d record; tok text; resp extensions.http_response; j jsonb; av text;
begin
  select * into d from public.discord_user(p_id);
  if found then return jsonb_build_object('discord_id', p_id, 'username', coalesce(d.username, ''), 'display_name', coalesce(d.display_name, d.username, ''), 'avatar', d.avatar, 'source', 'site'); end if;
  select * into d from public.staff_profiles where discord_id = p_id;
  if found then return jsonb_build_object('discord_id', p_id, 'username', d.username, 'display_name', d.display_name, 'avatar', d.avatar, 'source', 'staff'); end if;
  select v into tok from public.app_secrets where k = 'discord_bot_token';
  if coalesce(tok, '') = '' then return jsonb_build_object('error', 'not_found_no_bot'); end if;
  begin
    resp := extensions.http(('GET', 'https://discord.com/api/v10/users/' || p_id,
      array[extensions.http_header('Authorization', 'Bot ' || tok), extensions.http_header('User-Agent', 'DiscordBot (willmac-mod-apps, 1.0)')], null, null)::extensions.http_request);
  exception when others then return jsonb_build_object('error', 'discord_unreachable'); end;
  if resp.status = 404 then return jsonb_build_object('error', 'not_found'); end if;
  if resp.status <> 200 then return jsonb_build_object('error', 'discord_error'); end if;
  j := resp.content::jsonb; av := j->>'avatar';
  return jsonb_build_object('discord_id', p_id, 'username', coalesce(j->>'username', ''), 'display_name', coalesce(nullif(j->>'global_name', ''), j->>'username', ''),
    'avatar', case when coalesce(av, '') <> '' then 'https://cdn.discordapp.com/avatars/' || p_id || '/' || av || '.png?size=128'
                   else 'https://cdn.discordapp.com/embed/avatars/' || (((p_id::numeric / 4194304)::bigint) % 6)::text || '.png' end, 'source', 'discord');
end $$;

create or replace function public.lookup_discord_user(staff_key text, p_query text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare q text := trim(coalesce(p_query, '')); did text; n int;
begin
  if not public.staff_can(staff_key, 'staff_manage') then return jsonb_build_object('error', 'forbidden'); end if;
  q := regexp_replace(q, '^<@!?([0-9]+)>$', '\1');
  q := regexp_replace(q, '^@', '');
  if char_length(q) < 2 then return jsonb_build_object('error', 'invalid'); end if;
  if q ~ '^[0-9]{5,25}$' then return public.resolve_discord(q); end if;
  select count(*) into n from (select d.discord_id from public.discord_users() d where lower(d.username) = lower(q) or lower(d.display_name) = lower(q)) z;
  if n = 0 then
    select count(*) into n from (select 1 from public.staff_profiles p where lower(p.username) = lower(q) or lower(p.display_name) = lower(q)) z;
    if n = 0 then return jsonb_build_object('error', 'not_found_name'); end if;
    select p.discord_id into did from public.staff_profiles p where lower(p.username) = lower(q) or lower(p.display_name) = lower(q) limit 1;
  else
    select d.discord_id into did from public.discord_users() d where lower(d.username) = lower(q) or lower(d.display_name) = lower(q) order by d.last_sign_in desc nulls last limit 1;
  end if;
  return public.resolve_discord(did) || jsonb_build_object('matches', n);
end $$;

create or replace function public.staff_rank_access(r text)
returns text language sql immutable
as $$ select case r when 'Owner' then 'admin' when 'Co-Owner' then 'admin' when 'Administrator' then 'admin' when 'Senior Moderator' then 'reviewer' when 'Lead Moderator' then 'reviewer' else 'viewer' end $$;

create or replace function public.staff_member_add(staff_key text, p_discord_id text, p_rank text, p_access text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare did text := trim(coalesce(p_discord_id, '')); pr jsonb; acc text; owner_id constant text := '1271246652421701633'; is_owner boolean; nm text;
begin
  if not public.staff_can(staff_key, 'staff_manage') then return jsonb_build_object('error', 'forbidden'); end if;
  if did !~ '^[0-9]{5,25}$' or p_rank not in ('Owner','Co-Owner','Administrator','Senior Moderator','Lead Moderator','Moderator','Helper','Staff') then return jsonb_build_object('error', 'invalid'); end if;
  acc := coalesce(p_access, public.staff_rank_access(p_rank));
  if acc not in ('none','viewer','reviewer','admin') then return jsonb_build_object('error', 'invalid'); end if;
  is_owner := public.is_master(staff_key) or public.staff_actor_id(staff_key) = owner_id;
  if not is_owner and did = public.staff_actor_id(staff_key) then return jsonb_build_object('error', 'self'); end if;   -- nobody promotes themselves
  if not is_owner and (acc = 'admin' or p_rank in ('Owner','Co-Owner','Administrator')) then return jsonb_build_object('error', 'owner_only'); end if;
  pr := public.resolve_discord(did);
  if pr ? 'error' then return pr; end if;
  nm := left(coalesce(nullif(pr->>'display_name', ''), pr->>'username', did), 80);
  insert into public.staff_members (discord_id, username, display_name, avatar, rank_name, added_by)
  values (did, left(coalesce(pr->>'username', ''), 80), nm, left(pr->>'avatar', 300), p_rank, public.staff_name(staff_key))
  on conflict (discord_id) do update set username = excluded.username, display_name = excluded.display_name, avatar = excluded.avatar, rank_name = excluded.rank_name, updated_at = now();
  delete from public.staff_blocked where discord_id = did;
  if did <> owner_id then
    if acc = 'none' then delete from public.staff_overrides where discord_id = did;
    else insert into public.staff_overrides (discord_id, name, access) values (did, left(nm, 40), acc)
         on conflict (discord_id) do update set name = excluded.name, access = excluded.access; end if;
  end if;
  delete from public.staff_sessions where discord_id = did and did is distinct from public.staff_actor_id(staff_key);   -- new access applies at their next login (never log yourself out)
  perform public.log_action(staff_key, 'staff added', nm || ' as ' || p_rank);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.staff_member_update(staff_key text, p_discord_id text, p_rank text, p_access text default null, p_refresh boolean default false)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare did text := trim(coalesce(p_discord_id, '')); m public.staff_members; pr jsonb; acc text; owner_id constant text := '1271246652421701633'; is_owner boolean;
begin
  if not public.staff_can(staff_key, 'staff_manage') then return jsonb_build_object('error', 'forbidden'); end if;
  select * into m from public.staff_members where discord_id = did;
  if not found then return jsonb_build_object('error', 'notfound'); end if;
  if p_rank not in ('Owner','Co-Owner','Administrator','Senior Moderator','Lead Moderator','Moderator','Helper','Staff') then return jsonb_build_object('error', 'invalid'); end if;
  if p_access is not null and p_access not in ('none','viewer','reviewer','admin') then return jsonb_build_object('error', 'invalid'); end if;
  is_owner := public.is_master(staff_key) or public.staff_actor_id(staff_key) = owner_id;
  if not is_owner and did = public.staff_actor_id(staff_key) then return jsonb_build_object('error', 'self'); end if;   -- nobody promotes themselves
  if not is_owner and (p_access = 'admin' or p_rank in ('Owner','Co-Owner','Administrator') or m.rank_name in ('Owner','Co-Owner','Administrator')) then return jsonb_build_object('error', 'owner_only'); end if;
  if coalesce(p_refresh, false) then
    pr := public.resolve_discord(did);
    if not (pr ? 'error') then
      update public.staff_members set username = left(coalesce(pr->>'username', username), 80), display_name = left(coalesce(nullif(pr->>'display_name', ''), display_name), 80),
        avatar = coalesce(left(pr->>'avatar', 300), avatar) where discord_id = did;
    end if;
  end if;
  update public.staff_members set rank_name = p_rank, updated_at = now() where discord_id = did;
  acc := p_access;
  if acc is not null and did <> owner_id then
    if acc = 'none' then delete from public.staff_overrides where discord_id = did;
    else insert into public.staff_overrides (discord_id, name, access) values (did, left((select display_name from public.staff_members where discord_id = did), 40), acc)
         on conflict (discord_id) do update set access = excluded.access; end if;
    delete from public.staff_sessions where discord_id = did and did is distinct from public.staff_actor_id(staff_key);
  end if;
  perform public.log_action(staff_key, 'staff edited', m.display_name || ' -> ' || p_rank);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.staff_member_remove(staff_key text, p_discord_id text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare did text := trim(coalesce(p_discord_id, '')); m public.staff_members; g text;
begin
  g := public.mod_guard(staff_key, did, 'staff_manage');
  if g is not null then return jsonb_build_object('error', g); end if;
  select * into m from public.staff_members where discord_id = did;
  delete from public.staff_members where discord_id = did;
  delete from public.staff_overrides where discord_id = did;
  insert into public.staff_blocked (discord_id, reason) values (did, 'removed from staff by ' || coalesce(public.staff_name(staff_key), '?')) on conflict (discord_id) do nothing;
  delete from public.staff_sessions where discord_id = did;   -- access is revoked immediately
  delete from public.staff_profiles where discord_id = did;
  perform public.log_action(staff_key, 'staff removed', coalesce(m.display_name, did));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.list_staff_members(staff_key text)
returns jsonb language sql stable security definer set search_path = public
as $$
  select case when not public.staff_can(staff_key, 'staff_manage') then null else coalesce((
    select jsonb_agg(jsonb_build_object('discord_id', m.discord_id, 'username', m.username, 'display_name', coalesce(d.display_name, m.display_name),
      'avatar', coalesce(d.avatar, m.avatar), 'rank', m.rank_name, 'added_by', m.added_by, 'created_at', m.created_at,
      'access', coalesce((select o.access from public.staff_overrides o where o.discord_id = m.discord_id), 'none'),
      'last_seen', (select p.last_seen from public.staff_profiles p where p.discord_id = m.discord_id),
      'protected', public.mod_guard(staff_key, m.discord_id, 'staff_manage') is not null)
      order by array_position(array['Owner','Co-Owner','Administrator','Senior Moderator','Lead Moderator','Moderator','Helper','Staff'], m.rank_name), lower(m.display_name))
    from public.staff_members m left join lateral public.discord_user(m.discord_id) d on true), '[]'::jsonb) end
$$;

-- Public: the "Our Staff Team" section on the home page. Only name, picture and position are exposed.
create or replace function public.public_staff()
returns jsonb language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', coalesce(nullif(d.display_name, ''), nullif(m.display_name, ''), m.username), 'avatar', coalesce(d.avatar, m.avatar), 'role', m.rank_name)
    order by array_position(array['Owner','Co-Owner','Administrator','Senior Moderator','Lead Moderator','Moderator','Helper','Staff'], m.rank_name), m.sort_order, lower(coalesce(m.display_name, m.username))), '[]'::jsonb)
  from public.staff_members m left join lateral public.discord_user(m.discord_id) d on true
$$;


-- ---------- permissions ----------
revoke all on function public.resolve_discord(text) from public, anon, authenticated;
revoke all on function public.staff_rank_access(text) from public, anon, authenticated;
grant execute on function public.lookup_discord_user(text, text) to anon, authenticated;
grant execute on function public.staff_member_add(text, text, text, text) to anon, authenticated;
grant execute on function public.staff_member_update(text, text, text, text, boolean) to anon, authenticated;
grant execute on function public.staff_member_remove(text, text) to anon, authenticated;
grant execute on function public.list_staff_members(text) to anon, authenticated;
grant execute on function public.public_staff() to anon, authenticated;

notify pgrst, 'reload schema';

-- ======================= 20261113000004_feedback_tracking.sql =======================
-- =====================================================================================================
-- 0004  Feedback: real Discord name + picture on every message, and a status staff can track
--        (new -> reviewing -> resolved / declined), who handled it, and private staff notes.
-- Safe to run again. Never deletes data. Old feedback keeps its text; it just has no picture until the member sends something new.
-- =====================================================================================================

-- Who sent it (so the dashboard and Staff Chat can show their Discord picture and name) + a status staff can track.
alter table public.feedback add column if not exists discord_id text;
alter table public.feedback add column if not exists avatar     text;
alter table public.feedback add column if not exists status     text not null default 'new';
alter table public.feedback add column if not exists handled_by text;
alter table public.feedback add column if not exists handled_at timestamptz;
alter table public.feedback drop constraint if exists feedback_status_check;
alter table public.feedback add constraint feedback_status_check check (status in ('new','reviewing','resolved','declined'));
create table if not exists public.feedback_notes (
  id          bigint generated always as identity primary key,
  feedback_id bigint not null references public.feedback(id) on delete cascade,
  at          timestamptz not null default now(),
  author      text not null,
  note        text not null check (char_length(note) between 1 and 500)
);
alter table public.feedback_notes enable row level security;
revoke all on public.feedback_notes from anon, authenticated;


-- Members (not staff) submit feedback through these. Banned / timed-out members are refused.
create or replace function public.submit_feedback(p_app_id uuid, p_message text, p_anonymous boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare did text; a public.applications; k text; n int; m text;
begin
  did := public.my_discord_id();
  if did is null then return 'login'; end if;
  if public.user_state(did) <> 'active' then return 'banned'; end if;
  m := left(trim(coalesce(p_message, '')), 1000);
  if char_length(m) < 20 then return 'short'; end if;
  select * into a from public.applications where id = p_app_id and discord_id = did;
  if not found then return 'notfound'; end if;
  if a.status not in ('approved','denied') then return 'notdecided'; end if;
  k := encode(sha256(convert_to(did || ':' || p_app_id::text, 'utf8')), 'hex');
  insert into public.feedback (app_type, outcome, message, anonymous, name, limit_key, discord_id, avatar)
  values (a.type, a.status, m, false, left(coalesce(public.my_discord_name(), a.discord_name), 100), k, did, public.my_discord_avatar())
  on conflict (limit_key) do nothing;
  get diagnostics n = row_count;
  return case when n = 0 then 'duplicate' else 'ok' end;
end $$;

create or replace function public.submit_general_feedback(p_message text, p_anonymous boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare did text; m text; r text; nm text; last_at timestamptz; w int; adm boolean;
begin
  did := public.my_discord_id();
  if did is null then return 'login'; end if;
  if public.user_state(did) <> 'active' then return 'banned'; end if;
  m := left(trim(coalesce(p_message, '')), 1000);
  if char_length(m) < 5 then return 'short'; end if;
  r := encode(sha256(convert_to('gen:' || did, 'utf8')), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(r, 0));   -- two taps / two tabs at once can't both get through
  adm := public.feedback_is_admin(did);
  select max(created_at) into last_at from public.feedback where rl_key = r;
  if not adm and last_at is not null and last_at > now() - interval '5 minutes' then
    w := greatest(1, ceil(extract(epoch from (last_at + interval '5 minutes' - now())))::int);
    return 'wait:' || w;
  end if;
  -- Feedback from the home page always shows the member's name (no anonymous option).
  -- Use the member's real Discord display name + picture (not "Member").
  nm := left(coalesce(public.my_discord_name(), (select a.discord_name from public.applications a where a.discord_id = did order by a.created_at desc limit 1), 'Member'), 100);
  insert into public.feedback (app_type, outcome, message, anonymous, name, limit_key, rl_key, discord_id, avatar)
  values ('general', 'general', m, false, nm,
          encode(sha256(convert_to(did || ':' || clock_timestamp()::text || random()::text, 'utf8')), 'hex'), r, did, public.my_discord_avatar());
  return 'ok';
end $$;

drop function if exists public.list_feedback(text);
create or replace function public.list_feedback(staff_key text)
returns table (id bigint, created_at timestamptz, app_type text, outcome text, message text, anonymous boolean, name text,
               discord_id text, avatar text, status text, handled_by text, handled_at timestamptz, note_count bigint)
language sql stable security definer set search_path = public, auth
as $$
  select f.id, f.created_at, f.app_type, f.outcome, f.message, f.anonymous,
         case when f.anonymous then f.name when coalesce(nullif(trim(f.name), ''), 'Member') = 'Member'
              then coalesce(nullif(u.m->>'full_name', ''), nullif(u.m->>'name', ''), nullif(f.name, ''), 'Member') else f.name end,
         f.discord_id,
         coalesce(left(coalesce(u.m->>'avatar_url', u.m->>'picture'), 300), f.avatar),
         f.status, f.handled_by, f.handled_at,
         (select count(*) from public.feedback_notes n where n.feedback_id = f.id)
  from public.feedback f
  left join lateral (
    select x.raw_user_meta_data as m from auth.identities i join auth.users x on x.id = i.user_id
    where i.provider = 'discord' and i.provider_id = f.discord_id limit 1
  ) u on true
  where public.staff_role(staff_key) is not null
  order by f.created_at desc limit 500
$$;


create or replace function public.chat_feedback_status(staff_key text, p_id bigint, p_status text)
returns text language plpgsql security definer set search_path = public
as $$
begin
  if not public.staff_can(staff_key, 'feedback_manage') then return 'forbidden'; end if;
  if p_status not in ('new','reviewing','resolved','declined') then return 'invalid'; end if;
  update public.feedback set status = p_status, handled_by = case when p_status = 'new' then null else coalesce(public.staff_name(staff_key), '?') end,
         handled_at = case when p_status = 'new' then null else now() end where id = p_id;
  if not found then return 'notfound'; end if;
  perform public.log_action(staff_key, 'feedback ' || p_status, 'feedback #' || p_id);
  return 'ok';
end $$;

create or replace function public.chat_feedback_note(staff_key text, p_id bigint, p_note text)
returns text language plpgsql security definer set search_path = public
as $$
declare nt text := left(trim(coalesce(p_note, '')), 500);
begin
  if not public.staff_can(staff_key, 'feedback_manage') then return 'forbidden'; end if;
  if char_length(nt) < 1 then return 'empty'; end if;
  if not exists (select 1 from public.feedback where id = p_id) then return 'notfound'; end if;
  insert into public.feedback_notes (feedback_id, author, note) values (p_id, coalesce(public.staff_name(staff_key), '?'), nt);
  return 'ok';
end $$;

create or replace function public.chat_feedback_notes(staff_key text, p_id bigint)
returns jsonb language sql stable security definer set search_path = public
as $$
  select case when public.staff_role(staff_key) is null then null else coalesce((select jsonb_agg(jsonb_build_object('at', n.at, 'author', n.author, 'note', n.note) order by n.id)
    from public.feedback_notes n where n.feedback_id = p_id), '[]'::jsonb) end
$$;

grant execute on function public.list_feedback(text) to anon, authenticated;
grant execute on function public.chat_feedback_status(text, bigint, text) to anon, authenticated;
grant execute on function public.chat_feedback_note(text, bigint, text) to anon, authenticated;
grant execute on function public.chat_feedback_notes(text, bigint) to anon, authenticated;
notify pgrst, 'reload schema';

-- ======================= 20261113000005_staff_chat.sql =======================
-- =====================================================================================================
-- 0005  Staff Chat: categorised channels with stored info panels, DMs, replies, threads, reactions, pins,
--        mentions, slow mode, locked channels, mutes, away status, read receipts, file attachments, polls, search.
-- Privacy: every table is closed to the website (RLS on, no grants). The website can only call the functions below,
-- and each function checks the staff session itself. Attachments live in the database behind those functions
-- (there is no public URL for anything). Safe to run again. Never deletes data.
-- =====================================================================================================

alter table public.applications add column if not exists assigned_id text;
alter table public.applications add column if not exists claimed_at timestamptz;
alter table public.staff_profiles add column if not exists notify text not null default 'all';
alter table public.staff_profiles add column if not exists manual_away boolean not null default false;
alter table public.staff_profiles drop constraint if exists staff_profiles_notify_check;
alter table public.staff_profiles add constraint staff_profiles_notify_check check (notify in ('all','mentions','none'));

create table if not exists public.chat_channels (
  id         bigserial primary key,
  slug       text not null unique check (slug ~ '^[a-z0-9-]{1,30}$'),
  category   text not null default 'GENERAL STAFF' check (char_length(category) between 1 and 40),
  topic      text not null default '' check (char_length(topic) <= 200),
  min_access text not null default 'viewer' check (min_access in ('viewer','reviewer','admin')),
  post_min   text not null default 'viewer' check (post_min in ('viewer','reviewer','admin')),
  no_helpers boolean not null default false,
  sys        text unique check (sys in ('applications','feedback','approved','denied','modlog','announcements')),
  locked     boolean not null default false,
  slow_mode  int not null default 0 check (slow_mode between 0 and 3600),
  info       jsonb not null default '{}'::jsonb,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.chat_channels enable row level security;
revoke all on public.chat_channels from anon, authenticated;

-- Default channels + their information panels (kept in the database, editable by administrators in the chat).
insert into public.chat_channels (slug, category, topic, min_access, post_min, no_helpers, sys, sort_order, info) values
 ('staff-chat','GENERAL STAFF','General staff discussions and everyday communication.','viewer','viewer',false,null,10,
  '{"purpose":"Day-to-day conversation for the whole staff team.","belongs":["Everyday questions and quick coordination","Welcoming new staff","Friendly team chat"],"staff_use":["Ask for a second opinion","Say when you are away or back","Share quick tips"],"instructions":["Be professional and kind","Keep serious moderation cases in #moderation","Never share private member information outside staff channels"]}'),
 ('staff-announcements','GENERAL STAFF','Important announcements from administrators.','viewer','admin',false,'announcements',20,
  '{"purpose":"Official announcements from the administrators.","belongs":["Rule or policy changes","Schedule and event notices","Anything every staff member must read"],"staff_use":["Read every announcement","React with a check mark so admins know it was seen"],"instructions":["Only administrators can post here","Ask questions in #staff-chat, not here"]}'),
 ('staff-updates','GENERAL STAFF','Website updates, changes, and new features.','viewer','admin',false,null,30,
  '{"purpose":"What changed on the Will Mac website and dashboard.","belongs":["New features and fixes","Maintenance notices","Changes to how staff tools work"],"staff_use":["Stay current with new tools","Report problems in #staff-chat"],"instructions":["Only administrators post updates","Use /help to see the staff commands"]}'),
 ('applications','APPLICATION MANAGEMENT','New applications appear here for staff review.','viewer','viewer',false,'applications',40,
  '{"purpose":"Every new application and appeal arrives here automatically as a card.","belongs":["Application cards (posted by the website)","Short notes about a card"],"staff_use":["Claim an application before reviewing it","Approve or deny from the card (Senior Moderators and up)","Add a private review note"],"instructions":["Claim first so two people do not review the same application","Never decide an appeal about a punishment you issued","Longer discussion goes in #application-reviews"]}'),
 ('application-reviews','APPLICATION MANAGEMENT','Staff discussions about applicants.','viewer','viewer',true,null,50,
  '{"purpose":"Talk about applicants and decide together.","belongs":["Opinions on an application","Questions about an applicant","Anything that helps a fair decision"],"staff_use":["Link the application with its short ID","Share what you checked"],"instructions":["Keep it fair and respectful","Applicant details stay in staff channels","Moderators and above only"]}'),
 ('approved-applications','APPLICATION MANAGEMENT','Applications that have been approved.','viewer','admin',false,'approved',60,
  '{"purpose":"An automatic record of approved applications.","belongs":["Approval cards posted by the website"],"staff_use":["See who was approved, by whom and when"],"instructions":["Read only. Cards are posted automatically"]}'),
 ('denied-applications','APPLICATION MANAGEMENT','Applications that have been denied.','viewer','admin',false,'denied',70,
  '{"purpose":"An automatic record of denied applications.","belongs":["Denial cards posted by the website"],"staff_use":["See who was denied, by whom, and the reason given"],"instructions":["Read only. Cards are posted automatically"]}'),
 ('moderation','MODERATION','General moderation discussions.','viewer','viewer',true,null,80,
  '{"purpose":"Discuss moderation situations and ask for help.","belongs":["Cases you are unsure about","Evidence and context","Coordinating who handles what"],"staff_use":["Ask before a big action","Hand over cases clearly"],"instructions":["Do not share member private information outside staff channels","Use the moderation commands so every action is logged","Moderators and above only"]}'),
 ('mod-logs','MODERATION','Automatic records of moderation actions.','viewer','admin',true,'modlog',90,
  '{"purpose":"Every ban, timeout, warning and note is recorded here automatically.","belongs":["Moderation log cards posted by the website"],"staff_use":["Check what was done before acting again","Search with /history"],"instructions":["Read only. Cards are posted automatically","Moderators and above only"]}'),
 ('user-reports','MODERATION','Reports involving members.','viewer','viewer',false,null,100,
  '{"purpose":"Collect reports about members for staff to look at.","belongs":["A short description of the report","Message links and screenshots","The member''s Discord ID"],"staff_use":["Say when you take a report","Update the thread when it is handled"],"instructions":["Add evidence, not opinions","Never confront the reported member in chat"]}'),
 ('staff-notes','MODERATION','Internal staff notes and relevant information.','viewer','viewer',true,null,110,
  '{"purpose":"Internal notes that help staff stay consistent.","belongs":["Context about repeat issues","Reminders for the team","Anything staff should know later"],"staff_use":["Keep notes short and factual","Use /note to attach a note to a member"],"instructions":["Private to staff. Moderators and above only"]}'),
 ('feedback','COMMUNITY FEEDBACK','Feedback submitted through the website.','viewer','viewer',false,'feedback',120,
  '{"purpose":"Messages and result reviews from members arrive here automatically.","belongs":["Feedback cards posted by the website"],"staff_use":["Mark feedback Reviewing, Resolved or Declined (Senior Moderators and up)","Add an internal note"],"instructions":["Be honest and fair when replying","Never shame the person who wrote it"]}'),
 ('suggestions','COMMUNITY FEEDBACK','Suggestions for improving the community or website.','viewer','viewer',false,null,130,
  '{"purpose":"Ideas for making the community and the website better.","belongs":["One idea per message","Why it would help"],"staff_use":["React to show support","Discuss in a thread"],"instructions":["Keep it constructive","Admins will move good ideas forward"]}')
on conflict (slug) do nothing;

create table if not exists public.chat_messages (
  id         bigserial primary key,
  channel_id bigint references public.chat_channels(id) on delete cascade,
  dm_key     text,
  author_id  text,
  body       text not null default '' check (char_length(body) <= 2000),
  reply_to   bigint references public.chat_messages(id) on delete set null,
  thread_id  bigint references public.chat_messages(id) on delete cascade,
  kind       text not null default 'user' check (kind in ('user','announcement','application','decision','feedback','modlog','poll','system')),
  ref_id     text,
  poll       jsonb,
  mentions   text[] not null default '{}',
  mention_all boolean not null default false,
  pinned     boolean not null default false,
  pinned_by  text,
  edited_at  timestamptz,
  deleted    boolean not null default false,
  created_at timestamptz not null default now(),
  check ((channel_id is not null) <> (dm_key is not null))
);
create index if not exists chat_messages_channel on public.chat_messages (channel_id, id);
create index if not exists chat_messages_dm on public.chat_messages (dm_key, id);
create index if not exists chat_messages_thread on public.chat_messages (thread_id) where thread_id is not null;
create unique index if not exists chat_messages_ref on public.chat_messages (kind, ref_id) where ref_id is not null;
alter table public.chat_messages enable row level security;
revoke all on public.chat_messages from anon, authenticated;

create table if not exists public.chat_attachments (
  id         bigserial primary key,
  message_id bigint not null references public.chat_messages(id) on delete cascade,
  name       text not null default 'file',
  mime       text not null check (mime in ('image/png','image/jpeg','image/webp','image/gif','application/pdf','text/plain','text/csv','application/zip','application/vnd.openxmlformats-officedocument.wordprocessingml.document')),
  size       int  not null default 0,
  data       text not null check (char_length(data) <= 2000000),
  created_at timestamptz not null default now()
);
create index if not exists chat_attachments_msg on public.chat_attachments (message_id);
alter table public.chat_attachments enable row level security;
revoke all on public.chat_attachments from anon, authenticated;

create table if not exists public.chat_reactions (
  message_id bigint not null references public.chat_messages(id) on delete cascade,
  discord_id text not null,
  emoji      text not null check (char_length(emoji) between 1 and 16),
  primary key (message_id, discord_id, emoji)
);
alter table public.chat_reactions enable row level security;
revoke all on public.chat_reactions from anon, authenticated;

create table if not exists public.chat_reads (
  discord_id text not null,
  scope      text not null,
  last_id    bigint not null default 0,
  primary key (discord_id, scope)
);
alter table public.chat_reads enable row level security;
revoke all on public.chat_reads from anon, authenticated;

create table if not exists public.chat_mutes (
  discord_id text not null,
  scope      text not null,
  primary key (discord_id, scope)
);
alter table public.chat_mutes enable row level security;
revoke all on public.chat_mutes from anon, authenticated;

create table if not exists public.chat_typing (
  discord_id text not null,
  scope      text not null,
  until_at   timestamptz not null,
  primary key (discord_id, scope)
);
alter table public.chat_typing enable row level security;
revoke all on public.chat_typing from anon, authenticated;

create table if not exists public.chat_poll_votes (
  message_id bigint not null references public.chat_messages(id) on delete cascade,
  discord_id text not null,
  opt        int  not null check (opt between 0 and 5),
  primary key (message_id, discord_id)
);
alter table public.chat_poll_votes enable row level security;
revoke all on public.chat_poll_votes from anon, authenticated;

-- ---------- identity, roster, access ----------
-- Chat identity = the real Discord account behind a live Discord staff session. Backup codes can't use chat.
create or replace function public.chat_actor(k text)
returns text language sql stable security definer set search_path = public
as $$ select s.discord_id from public.staff_sessions s where s.key_hash = public.code_hash(k) and s.expires_at > now() $$;

create or replace function public.chat_helper(me text, rl text)
returns boolean language sql stable security definer set search_path = public
as $$ select rl = 'viewer' and public.staff_is_helper(me) $$;

create or replace function public.chat_chan_ok(me text, rl text, c public.chat_channels)
returns boolean language sql stable security definer set search_path = public
as $$ select public.acc_rank(rl) >= public.acc_rank(c.min_access) and (not c.no_helpers or not public.chat_helper(me, rl)) $$;

-- Everyone on the staff team right now, with presence (online / away / offline).
create or replace function public.chat_roster()
returns table (discord_id text, username text, display_name text, avatar text, rank_label text, access text, status text, joined_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select z.id, z.username, z.display_name, z.avatar, z.rank_label, z.access,
         case when z.seen > now() - interval '45 seconds' then (case when z.away or z.manual_away then 'away' else 'online' end)
              when z.seen > now() - interval '5 minutes' then 'away' else 'offline' end,
         z.joined
  from (
    select coalesce(p.discord_id, m.discord_id) as id,
           coalesce(d.username, p.username, m.username, '') as username,
           coalesce(nullif(d.display_name, ''), nullif(p.display_name, ''), nullif(m.display_name, ''), p.username, m.username, 'Staff') as display_name,
           coalesce(d.avatar, p.avatar, m.avatar) as avatar,
           coalesce(m.rank_name, case p.access when 'admin' then 'Administrator' when 'reviewer' then 'Lead Moderator' else 'Moderator' end) as rank_label,
           coalesce(p.access, (select o.access from public.staff_overrides o where o.discord_id = coalesce(p.discord_id, m.discord_id)), public.staff_rank_access(m.rank_name)) as access,
           p.last_seen as seen, coalesce(p.away, false) as away, coalesce(p.manual_away, false) as manual_away,
           coalesce(m.created_at, p.updated_at) as joined
    from public.staff_profiles p
    full join public.staff_members m on m.discord_id = p.discord_id
    left join lateral public.discord_user(coalesce(p.discord_id, m.discord_id)) d on true
    where (m.discord_id is not null or exists (select 1 from public.staff_sessions s where s.discord_id = p.discord_id and s.expires_at > now()))
      and not exists (select 1 from public.staff_blocked b where b.discord_id = coalesce(p.discord_id, m.discord_id))
      and public.user_state(coalesce(p.discord_id, m.discord_id)) <> 'banned'
  ) z
$$;

-- Which conversation is this ("c:<channel id>" or "d:<discord id>") and may I use it?
create or replace function public.chat_resolve(me text, rl text, p_scope text, need_post boolean, out channel_id bigint, out dm_key text, out ok boolean)
language plpgsql stable security definer set search_path = public
as $$
declare c public.chat_channels; other text;
begin
  ok := false;
  if p_scope like 'c:%' and substr(p_scope, 3) ~ '^[0-9]{1,18}$' then
    select * into c from public.chat_channels where id = substr(p_scope, 3)::bigint;
    if found and public.chat_chan_ok(me, rl, c) and (not need_post or public.acc_rank(rl) >= public.acc_rank(c.post_min)) then
      channel_id := c.id; ok := true;
    end if;
  elsif p_scope like 'd:%' then
    other := substr(p_scope, 3);
    if other ~ '^[0-9]{5,25}$' and other <> me and exists (select 1 from public.chat_roster() r where r.discord_id = other) then
      dm_key := least(me, other) || ':' || greatest(me, other); ok := true;
    end if;
  end if;
end $$;

create or replace function public.chat_can_see(me text, rl text, m public.chat_messages)
returns boolean language sql stable security definer set search_path = public
as $$
  select case when m.channel_id is not null then exists (select 1 from public.chat_channels c where c.id = m.channel_id and public.chat_chan_ok(me, rl, c))
              else (split_part(m.dm_key, ':', 1) = me or split_part(m.dm_key, ':', 2) = me) end
$$;

-- Messages as JSON (newest N, older than before_id, one thread, or specific ids). Files are fetched separately so polling stays light.
create or replace function public.chat_msgs_json(me text, p_channel bigint, p_dm text, p_limit integer, p_before bigint, p_thread bigint default null, p_ids bigint[] default null)
returns jsonb language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb) from (
    select m.id, m.author_id, case when m.deleted then '' else m.body end as body, m.reply_to, m.thread_id, m.kind, m.ref_id, m.mentions, m.mention_all, m.pinned, m.edited_at, m.deleted, m.created_at,
      (select jsonb_agg(jsonb_build_object('id', a.id, 'mime', a.mime, 'name', a.name, 'size', a.size) order by a.id) from public.chat_attachments a where a.message_id = m.id) as attachments,
      (select jsonb_agg(jsonb_build_object('emoji', q.emoji, 'users', q.us) order by q.emoji) from
         (select r.emoji, jsonb_agg(r.discord_id) as us from public.chat_reactions r where r.message_id = m.id group by r.emoji) q) as reactions,
      (select jsonb_build_object('id', rm.id, 'author_id', rm.author_id, 'body', left(rm.body, 120), 'deleted', rm.deleted) from public.chat_messages rm where rm.id = m.reply_to) as reply,
      (select count(*) from public.chat_messages t where t.thread_id = m.id and not t.deleted) as thread_count,
      case when m.kind = 'poll' then jsonb_build_object('options', m.poll->'options',
         'counts', coalesce((select jsonb_object_agg(v.opt::text, v.c) from (select pv.opt, count(*) as c from public.chat_poll_votes pv where pv.message_id = m.id group by pv.opt) v), '{}'::jsonb),
         'mine', (select pv.opt from public.chat_poll_votes pv where pv.message_id = m.id and pv.discord_id = me)) end as poll_data,
      case m.kind
        when 'application' then (select jsonb_build_object('id', a.id, 'type', a.type, 'name', a.discord_name, 'discord_id', a.discord_id,
              'username', d.username, 'display_name', d.display_name, 'avatar', coalesce(d.avatar, a.avatar), 'created_at', a.created_at,
              'status', a.status, 'reviewer', a.reviewer, 'assigned_id', a.assigned_id, 'note', a.status_note, 'status_at', a.status_at)
            from public.applications a left join lateral public.discord_user(a.discord_id) d on true where a.id::text = m.ref_id)
        when 'decision' then (select jsonb_build_object('id', a.id, 'type', a.type, 'name', a.discord_name, 'discord_id', a.discord_id,
              'username', d.username, 'display_name', d.display_name, 'avatar', coalesce(d.avatar, a.avatar), 'created_at', a.created_at,
              'status', a.status, 'reviewer', a.reviewer, 'note', a.status_note, 'status_at', a.status_at)
            from public.applications a left join lateral public.discord_user(a.discord_id) d on true where a.id::text = split_part(m.ref_id, ':', 1))
        when 'feedback' then (select jsonb_build_object('id', f.id, 'name', f.name, 'discord_id', f.discord_id, 'username', d.username, 'avatar', coalesce(d.avatar, f.avatar),
              'outcome', f.outcome, 'app_type', f.app_type, 'message', f.message, 'created_at', f.created_at, 'status', f.status, 'handled_by', f.handled_by, 'handled_at', f.handled_at,
              'note_count', (select count(*) from public.feedback_notes n where n.feedback_id = f.id))
            from public.feedback f left join lateral public.discord_user(f.discord_id) d on true where f.id::text = m.ref_id)
        when 'modlog' then (select jsonb_build_object('id', l.id, 'at', l.at, 'actor', l.actor, 'action', l.action, 'target_id', l.target_id, 'target_name', l.target_name,
              'avatar', (select d.avatar from public.discord_user(l.target_id) d), 'reason', l.reason, 'detail', l.detail)
            from public.moderation_log l where l.id::text = m.ref_id)
      end as card
    from public.chat_messages m
    where case when p_ids is not null then m.id = any(p_ids)
               when p_thread is not null then m.thread_id = p_thread
               else ((p_channel is not null and m.channel_id = p_channel) or (p_dm is not null and m.dm_key = p_dm)) and m.thread_id is null end
      and (p_before is null or m.id < p_before)
    order by m.id desc limit least(greatest(coalesce(p_limit, 60), 1), 200)
  ) x
$$;

-- One call does everything the chat screen needs: channels + unread, DMs + unread, who is online, the open conversation, pins, typing, read receipts.
create or replace function public.chat_poll(staff_key text, p_scope text default '', p_away boolean default false, p_read boolean default true, p_limit integer default 60)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record; mx bigint;
        msgs jsonb := '[]'; pins jsonb := '[]'; typ jsonb := '[]'; chans jsonb; dms jsonb; ros jsonb; mine jsonb; canpost boolean := false; oread bigint; ch public.chat_channels;
begin
  if me is null or rl is null then return jsonb_build_object('error', 'login'); end if;
  insert into public.staff_profiles (discord_id, username, display_name, access, last_seen)
    select s.discord_id, s.name, s.name, s.role, now() from public.staff_sessions s where s.key_hash = public.code_hash(staff_key)
  on conflict (discord_id) do nothing;
  update public.staff_profiles set last_seen = now(), away = coalesce(p_away, false), access = rl
    where discord_id = me and (last_seen is null or last_seen < now() - interval '15 seconds' or away is distinct from coalesce(p_away, false));

  if coalesce(p_scope, '') <> '' then
    select * into sc from public.chat_resolve(me, rl, p_scope, false);
    if sc.ok then
      select max(m.id) into mx from public.chat_messages m where m.thread_id is null and ((sc.channel_id is not null and m.channel_id = sc.channel_id) or (sc.dm_key is not null and m.dm_key = sc.dm_key));
      if p_read and mx is not null then
        insert into public.chat_reads (discord_id, scope, last_id) values (me, p_scope, mx)
        on conflict (discord_id, scope) do update set last_id = greatest(public.chat_reads.last_id, excluded.last_id);
      end if;
      msgs := public.chat_msgs_json(me, sc.channel_id, sc.dm_key, p_limit, null);
      select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'author_id', m.author_id, 'body', left(m.body, 140), 'created_at', m.created_at) order by m.id desc), '[]'::jsonb) into pins
        from public.chat_messages m where m.pinned and not m.deleted and ((sc.channel_id is not null and m.channel_id = sc.channel_id) or (sc.dm_key is not null and m.dm_key = sc.dm_key));
      select coalesce(jsonb_agg(t.discord_id), '[]'::jsonb) into typ from public.chat_typing t where t.scope = (case when sc.dm_key is not null then 'd:' || sc.dm_key else p_scope end) and t.until_at > now() and t.discord_id <> me;
      if sc.channel_id is not null then
        select * into ch from public.chat_channels where id = sc.channel_id;
        canpost := public.acc_rank(rl) >= public.acc_rank(ch.post_min) and (not ch.locked or public.staff_can(staff_key, 'lock'));
      else
        canpost := true;
        select r.last_id into oread from public.chat_reads r where r.discord_id = substr(p_scope, 3) and r.scope = 'd:' || me;
      end if;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'slug', c.slug, 'category', c.category, 'topic', c.topic, 'sys', c.sys, 'min_access', c.min_access, 'post_min', c.post_min,
      'no_helpers', c.no_helpers, 'locked', c.locked, 'slow_mode', c.slow_mode, 'info', c.info,
      'can_post', public.acc_rank(rl) >= public.acc_rank(c.post_min) and (not c.locked or public.staff_can(staff_key, 'lock')),
      'muted', exists (select 1 from public.chat_mutes mu where mu.discord_id = me and mu.scope = 'c:' || c.id),
      'unread', (select count(*) from public.chat_messages m where m.channel_id = c.id and m.thread_id is null and not m.deleted and m.author_id is distinct from me and m.id > coalesce(rd.last_id, 0)),
      'mentions', (select count(*) from public.chat_messages m where m.channel_id = c.id and m.thread_id is null and not m.deleted and (me = any(m.mentions) or m.mention_all) and m.author_id is distinct from me and m.id > coalesce(rd.last_id, 0)))
    order by c.sort_order, c.id), '[]'::jsonb) into chans
    from public.chat_channels c left join public.chat_reads rd on rd.discord_id = me and rd.scope = 'c:' || c.id
    where public.chat_chan_ok(me, rl, c);

  select coalesce(jsonb_agg(jsonb_build_object('id', g.other, 'unread', g.n, 'last', g.last_at,
      'muted', exists (select 1 from public.chat_mutes mu where mu.discord_id = me and mu.scope = 'd:' || g.other))), '[]'::jsonb) into dms from (
    select m.other, max(m.created_at) as last_at,
           count(*) filter (where not m.deleted and m.author_id is distinct from me and m.id > coalesce((select rd.last_id from public.chat_reads rd where rd.discord_id = me and rd.scope = 'd:' || m.other), 0)) as n
    from (select m2.id, m2.created_at, m2.author_id, m2.deleted,
                 case when split_part(m2.dm_key, ':', 1) = me then split_part(m2.dm_key, ':', 2) else split_part(m2.dm_key, ':', 1) end as other
          from public.chat_messages m2 where m2.thread_id is null and (m2.dm_key like me || ':%' or m2.dm_key like '%:' || me)) m
    group by m.other) g;

  select coalesce(jsonb_agg(jsonb_build_object('id', r.discord_id, 'username', r.username, 'name', r.display_name, 'avatar', r.avatar, 'rank', r.rank_label, 'access', r.access, 'status', r.status)
    order by lower(r.display_name)), '[]'::jsonb) into ros from public.chat_roster() r;
  select jsonb_build_object('id', me, 'role', rl, 'name', coalesce(r.display_name, 'Staff'), 'avatar', r.avatar, 'rank', r.rank_label,
         'caps', to_jsonb(public.staff_caps(staff_key)), 'notify', (select p.notify from public.staff_profiles p where p.discord_id = me),
         'manual_away', (select p.manual_away from public.staff_profiles p where p.discord_id = me))
    into mine from public.chat_roster() r where r.discord_id = me;

  return jsonb_build_object('me', coalesce(mine, jsonb_build_object('id', me, 'role', rl, 'caps', to_jsonb(public.staff_caps(staff_key)))), 'channels', chans, 'dms', dms, 'roster', ros, 'messages', msgs, 'pins', pins,
                            'typing', typ, 'can_post', canpost, 'other_read', oread, 'at', now());
end $$;

create or replace function public.chat_older(staff_key text, p_scope text, p_before bigint, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record;
begin
  if me is null or rl is null then return null; end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, false);
  if not coalesce(sc.ok, false) then return null; end if;
  return public.chat_msgs_json(me, sc.channel_id, sc.dm_key, p_limit, p_before);
end $$;

-- The replies in one message's thread (plus the message itself).
create or replace function public.chat_thread(staff_key text, p_root bigint)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages;
begin
  if me is null or rl is null then return null; end if;
  select * into m from public.chat_messages where id = p_root;
  if not found or m.thread_id is not null or not public.chat_can_see(me, rl, m) then return null; end if;
  return jsonb_build_object('root', (public.chat_msgs_json(me, null, null, 1, null, null, array[p_root]))->0, 'replies', public.chat_msgs_json(me, null, null, 200, null, p_root));
end $$;

-- Send a message. Files are checked here (type, size, encoding), never trusted from the website.
create or replace function public.chat_send(staff_key text, p_scope text, p_body text, p_reply_to bigint default null, p_files jsonb default '[]'::jsonb, p_mentions text[] default '{}', p_thread bigint default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record; b text := left(trim(coalesce(p_body, '')), 2000);
        mid bigint; f jsonb; n int := 0; mm text[]; rep public.chat_messages; ch public.chat_channels; last_at timestamptz; everyone boolean := false; staffall boolean := false;
        allowed text[] := array['image/png','image/jpeg','image/webp','image/gif','application/pdf','text/plain','text/csv','application/zip','application/vnd.openxmlformats-officedocument.wordprocessingml.document'];
        mime text; nm text; th public.chat_messages;
begin
  if me is null or rl is null then return jsonb_build_object('error', 'login'); end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, true);
  if not coalesce(sc.ok, false) then return jsonb_build_object('error', 'forbidden'); end if;
  if sc.channel_id is not null then
    select * into ch from public.chat_channels where id = sc.channel_id;
    if ch.locked and not public.staff_can(staff_key, 'lock') then return jsonb_build_object('error', 'locked'); end if;
    if ch.slow_mode > 0 and not public.staff_can(staff_key, 'slowmode') then
      select max(created_at) into last_at from public.chat_messages where channel_id = sc.channel_id and author_id = me and kind in ('user','poll');
      if last_at is not null and last_at > now() - make_interval(secs => ch.slow_mode) then
        return jsonb_build_object('error', 'slowmode', 'wait', ceil(extract(epoch from (last_at + make_interval(secs => ch.slow_mode) - now())))::int);
      end if;
    end if;
  end if;
  if p_files is null or jsonb_typeof(p_files) <> 'array' then p_files := '[]'::jsonb; end if;
  if jsonb_array_length(p_files) > 4 then return jsonb_build_object('error', 'too_many_files'); end if;
  if b = '' and jsonb_array_length(p_files) = 0 then return jsonb_build_object('error', 'empty'); end if;
  if (select count(*) from public.chat_messages where author_id = me and created_at > now() - interval '10 seconds') >= 15 then return jsonb_build_object('error', 'rate'); end if;
  for f in select jsonb_array_elements(p_files) loop
    mime := substring(f->>'data' from '^data:([a-z0-9/+.-]+);base64,');
    if jsonb_typeof(f) <> 'object' or mime is null or not (mime = any(allowed)) or char_length(coalesce(f->>'data', '')) > 2000000
       or (f->>'data') !~ '^data:[a-z0-9/+.-]+;base64,[A-Za-z0-9+/]+={0,2}$' then return jsonb_build_object('error', 'bad_file'); end if;
  end loop;
  if p_reply_to is not null then
    select * into rep from public.chat_messages where id = p_reply_to;
    if not found or not public.chat_can_see(me, rl, rep) or rep.channel_id is distinct from sc.channel_id or rep.dm_key is distinct from sc.dm_key then p_reply_to := null; end if;
  end if;
  if p_thread is not null then
    select * into th from public.chat_messages where id = p_thread;
    if not found or th.thread_id is not null or th.deleted or th.channel_id is distinct from sc.channel_id or th.dm_key is distinct from sc.dm_key then return jsonb_build_object('error', 'bad_thread'); end if;
  end if;
  -- @everyone needs Administrator, @staff needs Senior Moderator. Anyone else's token is ignored. Individual mentions are always allowed.
  everyone := 'everyone' = any(coalesce(p_mentions, '{}')) and public.staff_can(staff_key, 'mention_everyone');
  staffall := 'staff' = any(coalesce(p_mentions, '{}')) and public.staff_can(staff_key, 'mention_staff');
  select coalesce(array_agg(distinct r.discord_id), '{}') into mm from public.chat_roster() r where everyone or staffall or r.discord_id = any(coalesce(p_mentions, '{}'));
  insert into public.chat_messages (channel_id, dm_key, author_id, body, reply_to, thread_id, mentions, mention_all, kind)
  values (sc.channel_id, sc.dm_key, me, b, p_reply_to, p_thread, mm, everyone, case when sc.channel_id is not null and (select sys from public.chat_channels where id = sc.channel_id) = 'announcements' then 'announcement' else 'user' end)
  returning id into mid;
  for f in select jsonb_array_elements(p_files) loop
    nm := left(regexp_replace(coalesce(nullif(trim(f->>'name'), ''), 'file'), '[^A-Za-z0-9._ -]', '_', 'g'), 100);
    insert into public.chat_attachments (message_id, name, mime, size, data)
    values (mid, nm, substring(f->>'data' from '^data:([a-z0-9/+.-]+);base64,'), (char_length(f->>'data') * 3 / 4)::int, f->>'data');
  end loop;
  delete from public.chat_typing where discord_id = me;
  return jsonb_build_object('ok', true, 'id', mid);
end $$;

create or replace function public.chat_edit(staff_key text, p_id bigint, p_body text)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); b text := left(trim(coalesce(p_body, '')), 2000); m public.chat_messages;
begin
  if me is null or public.staff_role(staff_key) is null then return 'login'; end if;
  select * into m from public.chat_messages where id = p_id;
  if not found or m.deleted or m.kind not in ('user','announcement') then return 'notfound'; end if;
  if m.author_id is distinct from me then return 'forbidden'; end if;
  if b = '' then return 'empty'; end if;
  update public.chat_messages set body = b, edited_at = now() where id = p_id;
  return 'ok';
end $$;

create or replace function public.chat_delete(staff_key text, p_id bigint)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages;
begin
  if me is null or rl is null then return 'login'; end if;
  select * into m from public.chat_messages where id = p_id;
  if not found or m.deleted then return 'notfound'; end if;
  if not public.chat_can_see(me, rl, m) then return 'forbidden'; end if;
  if m.author_id is distinct from me and rl <> 'admin' then return 'forbidden'; end if;
  update public.chat_messages set deleted = true, body = '', pinned = false where id = p_id;
  delete from public.chat_attachments where message_id = p_id;
  delete from public.chat_reactions where message_id = p_id;
  if m.author_id is distinct from me then perform public.log_action(staff_key, 'chat message removed', 'message #' || p_id); end if;
  return 'ok';
end $$;

create or replace function public.chat_react(staff_key text, p_id bigint, p_emoji text)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages; e text := trim(coalesce(p_emoji, ''));
begin
  if me is null or rl is null then return 'login'; end if;
  if char_length(e) < 1 or char_length(e) > 16 then return 'invalid'; end if;
  select * into m from public.chat_messages where id = p_id;
  if not found or m.deleted or not public.chat_can_see(me, rl, m) then return 'notfound'; end if;
  if exists (select 1 from public.chat_reactions where message_id = p_id and discord_id = me and emoji = e) then
    delete from public.chat_reactions where message_id = p_id and discord_id = me and emoji = e;
  else insert into public.chat_reactions (message_id, discord_id, emoji) values (p_id, me, e); end if;
  return 'ok';
end $$;

create or replace function public.chat_pin(staff_key text, p_id bigint, p_pin boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages;
begin
  if me is null or rl is null then return 'login'; end if;
  if not public.staff_can(staff_key, 'pin') then return 'forbidden'; end if;
  select * into m from public.chat_messages where id = p_id;
  if not found or m.deleted or not public.chat_can_see(me, rl, m) then return 'notfound'; end if;
  -- announcements can only be pinned / unpinned by administrators
  if m.kind = 'announcement' and not public.staff_can(staff_key, 'announce') then return 'forbidden'; end if;
  update public.chat_messages set pinned = coalesce(p_pin, true), pinned_by = case when coalesce(p_pin, true) then me end where id = p_id;
  return 'ok';
end $$;

create or replace function public.chat_typing(staff_key text, p_scope text)
returns void language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record;
begin
  if me is null or rl is null then return; end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, true);
  if not coalesce(sc.ok, false) then return; end if;
  insert into public.chat_typing (discord_id, scope, until_at) values (me, case when sc.dm_key is not null then 'd:' || sc.dm_key else p_scope end, now() + interval '6 seconds')
  on conflict (discord_id, scope) do update set until_at = excluded.until_at;
  delete from public.chat_typing where until_at < now() - interval '1 minute';
end $$;

-- Search messages you are allowed to see. Filters: keywords, author, one channel/DM, date range.
create or replace function public.chat_search(staff_key text, p_q text default '', p_author text default null, p_scope text default null, p_from timestamptz default null, p_to timestamptz default null, p_limit integer default 40)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); q text := trim(coalesce(p_q, '')); sc record; ch bigint; dk text;
begin
  if me is null or rl is null then return '[]'::jsonb; end if;
  if char_length(q) < 2 and p_author is null and p_scope is null and p_from is null and p_to is null then return '[]'::jsonb; end if;
  if p_scope is not null and p_scope <> '' then
    select * into sc from public.chat_resolve(me, rl, p_scope, false);
    if not coalesce(sc.ok, false) then return '[]'::jsonb; end if;
    ch := sc.channel_id; dk := sc.dm_key;
  end if;
  q := replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_');
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.id desc) from (
    select m.id, m.author_id, left(m.body, 200) as body, m.created_at,
           case when m.channel_id is not null then 'c:' || m.channel_id
                else 'd:' || (case when split_part(m.dm_key, ':', 1) = me then split_part(m.dm_key, ':', 2) else split_part(m.dm_key, ':', 1) end) end as scope,
           (select c.slug from public.chat_channels c where c.id = m.channel_id) as channel
    from public.chat_messages m
    where not m.deleted and m.kind in ('user','announcement') and m.body <> ''
      and (q = '' or m.body ilike '%' || q || '%')
      and (p_author is null or p_author = '' or m.author_id = p_author)
      and (p_from is null or m.created_at >= p_from) and (p_to is null or m.created_at < p_to)
      and (ch is null and dk is null or m.channel_id = ch or m.dm_key = dk)
      and ((m.channel_id is not null and exists (select 1 from public.chat_channels c where c.id = m.channel_id and public.chat_chan_ok(me, rl, c)))
           or (m.dm_key is not null and (split_part(m.dm_key, ':', 1) = me or split_part(m.dm_key, ':', 2) = me)))
    order by m.id desc limit least(greatest(coalesce(p_limit, 40), 1), 100)) x), '[]'::jsonb);
end $$;

-- A file attached to a message you are allowed to see.
create or replace function public.chat_file(staff_key text, p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); a public.chat_attachments; m public.chat_messages;
begin
  if me is null or rl is null then return null; end if;
  select * into a from public.chat_attachments where id = p_id;
  if not found then return null; end if;
  select * into m from public.chat_messages where id = a.message_id;
  if not public.chat_can_see(me, rl, m) then return null; end if;
  return jsonb_build_object('mime', a.mime, 'data', a.data, 'name', a.name);
end $$;

-- ---------- channel management ----------
create or replace function public.chat_channel_save(staff_key text, p_id bigint, p_name text, p_topic text, p_min text, p_post text,
                                                    p_category text default null, p_info jsonb default null, p_no_helpers boolean default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_slug text := regexp_replace(regexp_replace(lower(trim(coalesce(p_name, ''))), '^#', ''), '[^a-z0-9]+', '-', 'g'); cid bigint; cat text := left(upper(trim(coalesce(p_category, ''))), 40);
begin
  if not public.staff_can(staff_key, 'channels') then return jsonb_build_object('error', 'forbidden'); end if;
  v_slug := trim(both '-' from v_slug);
  if v_slug !~ '^[a-z0-9-]{1,30}$' then return jsonb_build_object('error', 'invalid_name'); end if;
  if p_min not in ('viewer','reviewer','admin') or p_post not in ('viewer','reviewer','admin') then return jsonb_build_object('error', 'invalid'); end if;
  if p_info is not null and (jsonb_typeof(p_info) <> 'object' or length(p_info::text) > 4000) then return jsonb_build_object('error', 'invalid'); end if;
  if p_id is null then
    insert into public.chat_channels (slug, category, topic, min_access, post_min, no_helpers, info, sort_order)
    values (v_slug, coalesce(nullif(cat, ''), 'GENERAL STAFF'), left(coalesce(p_topic, ''), 200), p_min, p_post, coalesce(p_no_helpers, false), coalesce(p_info, '{}'::jsonb),
            coalesce((select max(sort_order) from public.chat_channels), 0) + 10) returning id into cid;
    perform public.log_action(staff_key, 'chat channel created', '#' || v_slug);
  else
    update public.chat_channels set slug = v_slug, topic = left(coalesce(p_topic, ''), 200), min_access = p_min, post_min = p_post,
      category = coalesce(nullif(cat, ''), category), info = coalesce(p_info, info), no_helpers = coalesce(p_no_helpers, no_helpers) where id = p_id returning id into cid;
    if cid is null then return jsonb_build_object('error', 'notfound'); end if;
    perform public.log_action(staff_key, 'chat channel edited', '#' || v_slug);
  end if;
  return jsonb_build_object('ok', true, 'id', cid);
exception when unique_violation then return jsonb_build_object('error', 'name_taken');
end $$;

create or replace function public.chat_channel_delete(staff_key text, p_id bigint)
returns text language plpgsql security definer set search_path = public
as $$
declare c public.chat_channels;
begin
  if not public.staff_can(staff_key, 'channels') then return 'forbidden'; end if;
  select * into c from public.chat_channels where id = p_id;
  if not found then return 'notfound'; end if;
  if c.sys is not null then return 'system'; end if;
  delete from public.chat_channels where id = p_id;
  delete from public.chat_reads where scope = 'c:' || p_id;
  perform public.log_action(staff_key, 'chat channel deleted', '#' || c.slug);
  return 'ok';
end $$;

-- Lock / unlock (Administrators) and slow mode (Senior Moderators and up).
create or replace function public.chat_channel_set(staff_key text, p_id bigint, p_locked boolean default null, p_slow integer default null)
returns text language plpgsql security definer set search_path = public
as $$
declare c public.chat_channels;
begin
  select * into c from public.chat_channels where id = p_id;
  if not found then return 'notfound'; end if;
  if p_locked is not null then
    if not public.staff_can(staff_key, 'lock') then return 'forbidden'; end if;
    update public.chat_channels set locked = p_locked where id = p_id;
    perform public.log_action(staff_key, case when p_locked then 'chat channel locked' else 'chat channel unlocked' end, '#' || c.slug);
  end if;
  if p_slow is not null then
    if not public.staff_can(staff_key, 'slowmode') then return 'forbidden'; end if;
    if p_slow < 0 or p_slow > 3600 then return 'invalid'; end if;
    update public.chat_channels set slow_mode = p_slow where id = p_id;
    perform public.log_action(staff_key, 'chat slow mode', '#' || c.slug || ' = ' || p_slow || 's');
  end if;
  return 'ok';
end $$;

-- ---------- personal settings ----------
create or replace function public.chat_mute(staff_key text, p_scope text, p_muted boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record;
begin
  if me is null or rl is null then return 'login'; end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, false);
  if not coalesce(sc.ok, false) then return 'forbidden'; end if;
  if coalesce(p_muted, true) then insert into public.chat_mutes (discord_id, scope) values (me, p_scope) on conflict do nothing;
  else delete from public.chat_mutes where discord_id = me and scope = p_scope; end if;
  return 'ok';
end $$;

create or replace function public.chat_set_prefs(staff_key text, p_notify text default null, p_away boolean default null)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key);
begin
  if me is null or public.staff_role(staff_key) is null then return 'login'; end if;
  if p_notify is not null and p_notify not in ('all','mentions','none') then return 'invalid'; end if;
  update public.staff_profiles set notify = coalesce(p_notify, notify), manual_away = coalesce(p_away, manual_away), last_seen = now() where discord_id = me;
  return 'ok';
end $$;

-- ---------- polls ----------
create or replace function public.chat_poll_create(staff_key text, p_scope text, p_question text, p_options text[])
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record; q text := left(trim(coalesce(p_question, '')), 300); opts text[]; mid bigint; o text;
begin
  if me is null or rl is null then return jsonb_build_object('error', 'login'); end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, true);
  if not coalesce(sc.ok, false) then return jsonb_build_object('error', 'forbidden'); end if;
  if char_length(q) < 3 then return jsonb_build_object('error', 'invalid'); end if;
  opts := '{}';
  foreach o in array coalesce(p_options, '{}') loop if char_length(trim(o)) > 0 then opts := opts || left(trim(o), 80); end if; end loop;
  if array_length(opts, 1) is null or array_length(opts, 1) < 2 or array_length(opts, 1) > 6 then return jsonb_build_object('error', 'options'); end if;
  insert into public.chat_messages (channel_id, dm_key, author_id, body, kind, poll) values (sc.channel_id, sc.dm_key, me, q, 'poll', jsonb_build_object('options', to_jsonb(opts))) returning id into mid;
  return jsonb_build_object('ok', true, 'id', mid);
end $$;

create or replace function public.chat_poll_vote(staff_key text, p_id bigint, p_opt integer)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages;
begin
  if me is null or rl is null then return 'login'; end if;
  select * into m from public.chat_messages where id = p_id and kind = 'poll';
  if not found or m.deleted or not public.chat_can_see(me, rl, m) then return 'notfound'; end if;
  if p_opt is null or p_opt < 0 or p_opt >= jsonb_array_length(m.poll->'options') then return 'invalid'; end if;
  if exists (select 1 from public.chat_poll_votes where message_id = p_id and discord_id = me and opt = p_opt) then
    delete from public.chat_poll_votes where message_id = p_id and discord_id = me;   -- clicking your vote again removes it
  else insert into public.chat_poll_votes (message_id, discord_id, opt) values (p_id, me, p_opt) on conflict (message_id, discord_id) do update set opt = excluded.opt; end if;
  return 'ok';
end $$;

-- ---------- announcements + clearing (Administrators) ----------
create or replace function public.chat_announce(staff_key text, p_text text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); t text := left(trim(coalesce(p_text, '')), 2000); cid bigint; mid bigint;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'announce') then return jsonb_build_object('error', 'forbidden'); end if;
  if char_length(t) < 3 then return jsonb_build_object('error', 'empty'); end if;
  select id into cid from public.chat_channels where sys = 'announcements';
  if cid is null then return jsonb_build_object('error', 'notfound'); end if;
  insert into public.chat_messages (channel_id, author_id, body, kind, mention_all) values (cid, me, t, 'announcement', true) returning id into mid;
  perform public.log_action(staff_key, 'announcement', left(t, 120));
  return jsonb_build_object('ok', true, 'id', mid, 'channel', cid);
end $$;

create or replace function public.chat_clear(staff_key text, p_scope text, p_count integer)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record; n int := 0; ids bigint[];
begin
  if me is null or rl is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'clear') then return jsonb_build_object('error', 'forbidden'); end if;
  if p_count is null or p_count < 1 or p_count > 100 then return jsonb_build_object('error', 'invalid'); end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, false);
  if not coalesce(sc.ok, false) or sc.channel_id is null then return jsonb_build_object('error', 'forbidden'); end if;   -- channels only: private DMs can't be cleared by anyone else
  select array_agg(x.id) into ids from (select m.id from public.chat_messages m where m.channel_id = sc.channel_id and not m.deleted and m.kind in ('user','announcement','poll','system') and not m.pinned order by m.id desc limit p_count) x;
  if ids is null then return jsonb_build_object('ok', true, 'cleared', 0); end if;
  update public.chat_messages set deleted = true, body = '', pinned = false where id = any(ids);
  get diagnostics n = row_count;
  delete from public.chat_attachments where message_id = any(ids);
  delete from public.chat_reactions where message_id = any(ids);
  perform public.log_action(staff_key, 'chat clear', n || ' messages in #' || (select slug from public.chat_channels where id = sc.channel_id));
  return jsonb_build_object('ok', true, 'cleared', n);
end $$;

-- ---------- permissions ----------
revoke all on function public.chat_actor(text) from public, anon, authenticated;
revoke all on function public.chat_helper(text, text) from public, anon, authenticated;
revoke all on function public.chat_chan_ok(text, text, public.chat_channels) from public, anon, authenticated;
revoke all on function public.chat_roster() from public, anon, authenticated;
revoke all on function public.chat_resolve(text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.chat_can_see(text, text, public.chat_messages) from public, anon, authenticated;
revoke all on function public.chat_msgs_json(text, bigint, text, integer, bigint, bigint, bigint[]) from public, anon, authenticated;

grant execute on function public.chat_poll(text, text, boolean, boolean, integer) to anon, authenticated;
grant execute on function public.chat_older(text, text, bigint, integer) to anon, authenticated;
grant execute on function public.chat_thread(text, bigint) to anon, authenticated;
grant execute on function public.chat_send(text, text, text, bigint, jsonb, text[], bigint) to anon, authenticated;
grant execute on function public.chat_edit(text, bigint, text) to anon, authenticated;
grant execute on function public.chat_delete(text, bigint) to anon, authenticated;
grant execute on function public.chat_react(text, bigint, text) to anon, authenticated;
grant execute on function public.chat_pin(text, bigint, boolean) to anon, authenticated;
grant execute on function public.chat_typing(text, text) to anon, authenticated;
grant execute on function public.chat_search(text, text, text, text, timestamptz, timestamptz, integer) to anon, authenticated;
grant execute on function public.chat_file(text, bigint) to anon, authenticated;
grant execute on function public.chat_channel_save(text, bigint, text, text, text, text, text, jsonb, boolean) to anon, authenticated;
grant execute on function public.chat_channel_delete(text, bigint) to anon, authenticated;
grant execute on function public.chat_channel_set(text, bigint, boolean, integer) to anon, authenticated;
grant execute on function public.chat_mute(text, text, boolean) to anon, authenticated;
grant execute on function public.chat_set_prefs(text, text, boolean) to anon, authenticated;
grant execute on function public.chat_poll_create(text, text, text, text[]) to anon, authenticated;
grant execute on function public.chat_poll_vote(text, bigint, integer) to anon, authenticated;
grant execute on function public.chat_announce(text, text) to anon, authenticated;
grant execute on function public.chat_clear(text, text, integer) to anon, authenticated;

notify pgrst, 'reload schema';

-- ======================= 20261113000006_application_workflow.sql =======================
-- =====================================================================================================
-- 0006  Application workflow: cards in chat, claim / release / assign (atomic), review notes, applicant
--        history + duplicate detection, approve/deny from the card, automatic approved/denied/mod-log cards.
-- Existing applications, statuses and the old dashboard keep working: decisions still go through
-- set_application_progress(), so history, progress bar and appeal rules are unchanged. Safe to re-run.
-- =====================================================================================================

create table if not exists public.application_notes (
  id             bigserial primary key,
  application_id uuid not null references public.applications(id) on delete cascade,
  author_id      text,
  author_name    text not null,
  note           text not null check (char_length(note) between 1 and 1000),
  created_at     timestamptz not null default now()
);
create index if not exists application_notes_app on public.application_notes (application_id, created_at);
alter table public.application_notes enable row level security;
revoke all on public.application_notes from anon, authenticated;

-- ---------- automatic cards ----------
create or replace function public.chat_post_card()
returns trigger language plpgsql security definer set search_path = public
as $$
declare cid bigint;
begin
  if tg_table_name = 'applications' then
    select id into cid from public.chat_channels where sys = 'applications';
    if cid is not null then insert into public.chat_messages (channel_id, kind, ref_id) values (cid, 'application', new.id::text) on conflict do nothing; end if;
  elsif tg_table_name = 'feedback' then
    select id into cid from public.chat_channels where sys = 'feedback';
    if cid is not null then insert into public.chat_messages (channel_id, kind, ref_id) values (cid, 'feedback', new.id::text) on conflict do nothing; end if;
  elsif tg_table_name = 'moderation_log' then
    select id into cid from public.chat_channels where sys = 'modlog';
    if cid is not null then insert into public.chat_messages (channel_id, kind, ref_id) values (cid, 'modlog', new.id::text) on conflict do nothing; end if;
  end if;
  return new;
exception when others then return new;   -- a chat problem must never block an application, feedback or moderation action
end $$;
drop trigger if exists zz_chat_card on public.applications;
create trigger zz_chat_card after insert on public.applications for each row execute function public.chat_post_card();
drop trigger if exists zz_chat_card on public.feedback;
create trigger zz_chat_card after insert on public.feedback for each row execute function public.chat_post_card();
drop trigger if exists zz_chat_card on public.moderation_log;
create trigger zz_chat_card after insert on public.moderation_log for each row execute function public.chat_post_card();

-- Approved / denied record. Fires for decisions made anywhere (chat card or the old dashboard).
create or replace function public.chat_post_decision()
returns trigger language plpgsql security definer set search_path = public
as $$
declare cid bigint;
begin
  if new.status in ('approved','denied') and new.status is distinct from old.status then
    select id into cid from public.chat_channels where sys = new.status;
    if cid is not null then
      insert into public.chat_messages (channel_id, kind, ref_id) values (cid, 'decision', new.id::text || ':' || new.status) on conflict do nothing;
    end if;
  end if;
  return new;
exception when others then return new;
end $$;
drop trigger if exists zz_chat_decision on public.applications;
create trigger zz_chat_decision after update of status on public.applications for each row execute function public.chat_post_decision();

-- Cards for everything that already exists (once; deleted cards stay deleted).
insert into public.chat_messages (channel_id, kind, ref_id, created_at)
  select (select id from public.chat_channels where sys = 'applications'), 'application', a.id::text, a.created_at from public.applications a
  where exists (select 1 from public.chat_channels where sys = 'applications') order by a.created_at
on conflict do nothing;
insert into public.chat_messages (channel_id, kind, ref_id, created_at)
  select (select id from public.chat_channels where sys = 'feedback'), 'feedback', f.id::text, f.created_at from public.feedback f
  where exists (select 1 from public.chat_channels where sys = 'feedback') order by f.created_at
on conflict do nothing;
insert into public.chat_messages (channel_id, kind, ref_id, created_at)
  select (select id from public.chat_channels where sys = a.status), 'decision', a.id::text || ':' || a.status, coalesce(a.status_at, a.created_at)
  from public.applications a where a.status in ('approved','denied')
  and exists (select 1 from public.chat_channels c where c.sys = a.status) order by coalesce(a.status_at, a.created_at)
on conflict do nothing;
insert into public.chat_messages (channel_id, kind, ref_id, created_at)
  select (select id from public.chat_channels where sys = 'modlog'), 'modlog', l.id::text, l.at from public.moderation_log l
  where exists (select 1 from public.chat_channels where sys = 'modlog') order by l.at
on conflict do nothing;

-- ---------- helpers ----------
-- "a1b2c3d4" (first 8 characters) or a full id → the application.
create or replace function public.resolve_app(p text)
returns uuid language sql stable security definer set search_path = public
as $$
  select a.id from public.applications a
  where a.id::text = lower(trim(p)) or (char_length(trim(p)) >= 6 and a.id::text like lower(trim(p)) || '%')
  order by a.created_at desc limit 1
$$;

-- The full answers of one application card (loaded when you open it, not on every refresh).
create or replace function public.chat_application_answers(staff_key text, p_app_id text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'apps_view') then return null; end if;
  return (select a.answers from public.applications a where a.id::text = p_app_id);
end $$;

-- ---------- claim / release / assign (atomic: the row is locked, so two people can't both win) ----------
create or replace function public.app_claim(staff_key text, p_app text)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); a public.applications; aid uuid := public.resolve_app(p_app);
begin
  if me is null then return 'login'; end if;
  if not public.staff_can(staff_key, 'claim') then return 'forbidden'; end if;
  if aid is null then return 'notfound'; end if;
  select * into a from public.applications where applications.id = aid for update;
  if a.status in ('approved','denied') then return 'already_decided'; end if;
  if a.assigned_id is not null and a.assigned_id <> me then return 'claimed'; end if;
  if a.assigned_id = me then return 'ok'; end if;
  update public.applications set assigned_id = me, claimed_at = now() where applications.id = aid;
  if a.status = 'pending' then
    insert into public.application_history (application_id, status, reviewer, note, actor) values (aid, 'in_review', public.staff_name(staff_key), 'Claimed', public.staff_name(staff_key));
    update public.applications set status = 'in_review', status_at = now(), reviewer = public.staff_name(staff_key) where applications.id = aid;
  end if;
  perform public.log_action(staff_key, 'claimed application', a.discord_name);
  return 'ok';
end $$;

create or replace function public.app_release(staff_key text, p_app text)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); a public.applications; aid uuid := public.resolve_app(p_app);
begin
  if me is null then return 'login'; end if;
  if not public.staff_can(staff_key, 'claim') then return 'forbidden'; end if;
  if aid is null then return 'notfound'; end if;
  select * into a from public.applications where applications.id = aid for update;
  if a.assigned_id is null then return 'not_claimed'; end if;
  if a.assigned_id <> me and not public.staff_can(staff_key, 'assign') then return 'forbidden'; end if;
  update public.applications set assigned_id = null, claimed_at = null where applications.id = aid;
  perform public.log_action(staff_key, 'released application', a.discord_name);
  return 'ok';
end $$;

create or replace function public.app_assign(staff_key text, p_app text, p_to text)
returns text language plpgsql security definer set search_path = public
as $$
declare a public.applications; aid uuid := public.resolve_app(p_app); to_id text := nullif(trim(coalesce(p_to, '')), '');
begin
  if public.chat_actor(staff_key) is null then return 'login'; end if;
  if not public.staff_can(staff_key, 'assign') then return 'forbidden'; end if;
  if aid is null then return 'notfound'; end if;
  if to_id is not null and not exists (select 1 from public.chat_roster() r where r.discord_id = to_id and r.access in ('reviewer','admin')) then return 'invalid_target'; end if;
  select * into a from public.applications where applications.id = aid for update;
  if a.status in ('approved','denied') then return 'already_decided'; end if;
  update public.applications set assigned_id = to_id, claimed_at = case when to_id is null then null else now() end where applications.id = aid;
  perform public.log_action(staff_key, 'assigned application', a.discord_name || ' -> ' || coalesce(to_id, 'nobody'));
  return 'ok';
end $$;

-- ---------- review notes ----------
create or replace function public.app_note_add(staff_key text, p_app text, p_note text)
returns text language plpgsql security definer set search_path = public
as $$
declare aid uuid := public.resolve_app(p_app); t text := left(trim(coalesce(p_note, '')), 1000);
begin
  if public.chat_actor(staff_key) is null then return 'login'; end if;
  if not public.staff_can(staff_key, 'app_notes') then return 'forbidden'; end if;
  if aid is null then return 'notfound'; end if;
  if char_length(t) < 1 then return 'empty'; end if;
  insert into public.application_notes (application_id, author_id, author_name, note) values (aid, public.chat_actor(staff_key), coalesce(public.staff_name(staff_key), 'Staff'), t);
  perform public.log_action(staff_key, 'application note', left(t, 80));
  return 'ok';
end $$;

create or replace function public.app_notes_list(staff_key text, p_app text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare aid uuid := public.resolve_app(p_app);
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'app_notes') or aid is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'author', n.author_name, 'note', n.note, 'at', n.created_at) order by n.created_at) from public.application_notes n where n.application_id = aid), '[]'::jsonb);
end $$;

-- ---------- applicant history + duplicate detection ----------
create or replace function public.app_applicant_info(staff_key text, p_app text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare aid uuid := public.resolve_app(p_app); a public.applications; d record; prior jsonb; dups jsonb;
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'apps_view') or aid is null then return null; end if;
  select * into a from public.applications where applications.id = aid;
  select * into d from public.discord_user(a.discord_id);
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'type', x.type, 'status', x.status, 'at', x.created_at, 'reviewer', x.reviewer) order by x.created_at desc), '[]'::jsonb) into prior
    from public.applications x where x.id <> a.id and ((a.discord_id is not null and x.discord_id = a.discord_id) or (a.discord_id is null and lower(x.discord_name) = lower(a.discord_name)));
  -- duplicates: another still-open application of the same type from the same person
  select coalesce(jsonb_agg(x.id), '[]'::jsonb) into dups from public.applications x
    where x.id <> a.id and x.type = a.type and x.status not in ('approved','denied') and ((a.discord_id is not null and x.discord_id = a.discord_id) or lower(x.discord_name) = lower(a.discord_name));
  return jsonb_build_object('id', a.id, 'type', a.type, 'status', a.status, 'discord_id', a.discord_id, 'name', a.discord_name, 'username', d.username, 'display_name', d.display_name,
    'avatar', coalesce(d.avatar, a.avatar), 'registered', d.created_at, 'state', case when a.discord_id is null then 'active' else public.user_state(a.discord_id) end,
    'assigned_id', a.assigned_id, 'assigned_name', (select r.display_name from public.chat_roster() r where r.discord_id = a.assigned_id),
    'previous', prior, 'duplicates', dups, 'created_at', a.created_at,
    'history', coalesce((select jsonb_agg(jsonb_build_object('status', h.status, 'actor', h.actor, 'note', h.note, 'at', h.at) order by h.at desc) from public.application_history h where h.application_id = a.id), '[]'::jsonb));
end $$;

-- ---------- approve / deny from the card ----------
create or replace function public.chat_decide_application(staff_key text, p_app_id text, p_status text, p_reason text default '')
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); a public.applications; n int; rs text := left(trim(coalesce(p_reason, '')), 300); nm text; cid bigint; aid uuid := public.resolve_app(p_app_id);
begin
  if me is null then return 'login'; end if;
  if not public.staff_can(staff_key, 'decide') then return 'forbidden'; end if;
  if p_status not in ('approved','denied') then return 'invalid'; end if;
  if aid is null then return 'notfound'; end if;
  select * into a from public.applications where applications.id = aid for update;   -- row lock: two people can't decide at once
  if a.status in ('approved','denied') then return 'already_decided'; end if;
  if a.assigned_id is not null and a.assigned_id <> me and not public.staff_can(staff_key, 'assign') then return 'claimed'; end if;
  if a.type = 'appeal' and char_length(rs) < 15 then return 'reason_required'; end if;
  nm := coalesce(public.staff_name(staff_key), 'Staff');
  n := public.set_application_progress(staff_key, array[a.id::text], p_status, nm, nullif(rs, ''));
  if n = -3 then return 'own_punishment'; end if;
  if n is null or n < 1 then return 'failed'; end if;
  update public.applications set assigned_id = coalesce(assigned_id, me) where applications.id = aid;
  return 'ok';
end $$;

-- ---------- permissions ----------
revoke all on function public.chat_post_card() from public, anon, authenticated;
revoke all on function public.chat_post_decision() from public, anon, authenticated;
revoke all on function public.resolve_app(text) from public, anon, authenticated;
grant execute on function public.chat_application_answers(text, text) to anon, authenticated;
grant execute on function public.app_claim(text, text) to anon, authenticated;
grant execute on function public.app_release(text, text) to anon, authenticated;
grant execute on function public.app_assign(text, text, text) to anon, authenticated;
grant execute on function public.app_note_add(text, text, text) to anon, authenticated;
grant execute on function public.app_notes_list(text, text) to anon, authenticated;
grant execute on function public.app_applicant_info(text, text) to anon, authenticated;
grant execute on function public.chat_decide_application(text, text, text, text) to anon, authenticated;
notify pgrst, 'reload schema';

-- ======================= 20261113000007_commands_activity.sql =======================
-- =====================================================================================================
-- 0007  Backends for the chat slash commands and the staff activity dashboard.
-- Every function checks the staff session and the capability itself. Read-mostly; nothing here deletes data.
-- =====================================================================================================

-- Find a member by Discord ID or by name (Moderators and above).
create or replace function public.find_user(staff_key text, p_q text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare q text := trim(coalesce(p_q, '')); pat text;
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'userinfo') or char_length(q) < 2 then return '[]'::jsonb; end if;
  q := regexp_replace(q, '^<@!?([0-9]+)>$', '\1'); q := regexp_replace(q, '^@', '');
  pat := '%' || replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.discord_id, 'username', x.username, 'display_name', x.display_name, 'avatar', x.avatar, 'state', public.user_state(x.discord_id)))
    from (select u.* from public.discord_users() u where u.discord_id = q or u.username ilike pat or u.display_name ilike pat
          order by (u.discord_id = q) desc, u.username limit 8) x), '[]'::jsonb);
end $$;

-- /applications, /pending
create or replace function public.app_list(staff_key text, p_status text default 'open', p_limit integer default 15)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'apps_view') then return null; end if;
  return coalesce((select jsonb_agg(to_jsonb(x)) from (
    select left(a.id::text, 8) as short, a.type, a.status, a.discord_name as name, a.created_at as at,
           (select r.display_name from public.chat_roster() r where r.discord_id = a.assigned_id) as assigned
    from public.applications a
    where case p_status when 'open' then a.status not in ('approved','denied') when 'pending' then a.status = 'pending' when 'all' then true else a.status = p_status end
    order by a.created_at desc limit least(greatest(coalesce(p_limit, 15), 1), 50)) x), '[]'::jsonb);
end $$;

-- /appstats
create or replace function public.app_stats(staff_key text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'apps_view') then return null; end if;
  return jsonb_build_object(
    'total', (select count(*) from public.applications),
    'today', (select count(*) from public.applications where created_at > now() - interval '24 hours'),
    'week', (select count(*) from public.applications where created_at > now() - interval '7 days'),
    'by_status', coalesce((select jsonb_object_agg(s, c) from (select status as s, count(*) as c from public.applications group by status) q), '{}'::jsonb),
    'by_type', coalesce((select jsonb_object_agg(s, c) from (select type as s, count(*) as c from public.applications group by type) q), '{}'::jsonb),
    'unclaimed_open', (select count(*) from public.applications where status not in ('approved','denied') and assigned_id is null),
    'closed_types', to_jsonb(public.get_closed_types()));
end $$;

-- /openapps /closeapps  (type name or "all" of the types that exist)
create or replace function public.app_toggle(staff_key text, p_type text, p_open boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare t text := lower(trim(coalesce(p_type, ''))); n int := 0; x text;
begin
  if public.chat_actor(staff_key) is null then return 'login'; end if;
  if not public.staff_can(staff_key, 'apps_toggle') then return 'forbidden'; end if;
  if t = 'all' then
    for x in select distinct type from public.applications loop perform public.set_type_open(staff_key, x, p_open); n := n + 1; end loop;
    return 'ok:' || n;
  end if;
  if t !~ '^[a-z0-9_-]{1,30}$' then return 'invalid'; end if;
  perform public.set_type_open(staff_key, t, p_open);
  return 'ok:1';
end $$;

-- Promote / demote one step on the ladder Helper < Moderator < Senior Moderator < Administrator. The roster function enforces who may do what.
create or replace function public.staff_rank_step(staff_key text, p_discord_id text, p_dir integer)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare ladder text[] := array['Helper','Moderator','Senior Moderator','Administrator']; cur text; i int; did text := trim(coalesce(p_discord_id, ''));
begin
  if public.chat_actor(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'promote') then return jsonb_build_object('error', 'forbidden'); end if;
  select rank_name into cur from public.staff_members where discord_id = did;
  if cur is null then return jsonb_build_object('error', 'notfound'); end if;
  i := array_position(ladder, cur);
  if i is null then return jsonb_build_object('error', 'protected'); end if;   -- Owner / Co-Owner / Staff are set by hand in Staff Management
  if p_dir not in (-1, 1) then return jsonb_build_object('error', 'invalid'); end if;
  if i + p_dir < 1 or i + p_dir > array_length(ladder, 1) then return jsonb_build_object('error', 'limit'); end if;
  return public.staff_member_update(staff_key, did, ladder[i + p_dir]) || jsonb_build_object('from', cur, 'to', ladder[i + p_dir]);
end $$;

-- Per-person numbers (used by /staffstats, profile cards and the activity dashboard).
create or replace function public.staff_numbers(did text, p_days integer default 30)
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'decisions', (select count(*) from public.application_history h where h.actor = (select coalesce(nullif(r.display_name, ''), r.username) from public.chat_roster() r where r.discord_id = did limit 1) and h.status in ('approved','denied') and h.at > now() - make_interval(days => p_days)),
    'mod_actions', (select count(*) from public.moderation_log l where l.actor_id = did and l.at > now() - make_interval(days => p_days)),
    'messages', (select count(*) from public.chat_messages m where m.author_id = did and m.kind in ('user','announcement','poll') and not m.deleted and m.created_at > now() - make_interval(days => p_days)),
    'claimed_open', (select count(*) from public.applications a where a.assigned_id = did and a.status not in ('approved','denied')))
$$;

create or replace function public.staff_profile(staff_key text, p_discord_id text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare did text := trim(coalesce(p_discord_id, '')); r record;
begin
  if public.chat_actor(staff_key) is null then return null; end if;
  select * into r from public.chat_roster() x where x.discord_id = did;
  if not found then return null; end if;
  return jsonb_build_object('id', r.discord_id, 'username', r.username, 'name', r.display_name, 'avatar', r.avatar, 'rank', r.rank_label, 'access', r.access, 'status', r.status,
    'joined', r.joined_at, 'last_seen', (select p.last_seen from public.staff_profiles p where p.discord_id = did),
    'stats', case when public.staff_can(staff_key, 'activity') or did = public.chat_actor(staff_key) then public.staff_numbers(did, 30) end);
end $$;

-- /staffstats: yourself, or anyone if you are an administrator.
create or replace function public.staff_stats(staff_key text, p_discord_id text default null)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); did text := coalesce(nullif(trim(p_discord_id), ''), public.chat_actor(staff_key));
begin
  if me is null then return null; end if;
  if did <> me and not public.staff_can(staff_key, 'activity') then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object('id', did, 'days', 30) || public.staff_numbers(did, 30);
end $$;

-- Administrators: who is active, who is not.
create or replace function public.staff_activity(staff_key text, p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare d int := least(greatest(coalesce(p_days, 30), 1), 365);
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'activity') then return null; end if;
  return jsonb_build_object('days', d, 'staff', coalesce((select jsonb_agg(jsonb_build_object('id', r.discord_id, 'name', r.display_name, 'avatar', r.avatar, 'rank', r.rank_label, 'status', r.status,
      'last_seen', (select p.last_seen from public.staff_profiles p where p.discord_id = r.discord_id)) || public.staff_numbers(r.discord_id, d) order by lower(r.display_name))
      from public.chat_roster() r), '[]'::jsonb),
    'totals', jsonb_build_object('applications', (select count(*) from public.applications where created_at > now() - make_interval(days => d)),
      'decided', (select count(*) from public.application_history where status in ('approved','denied') and at > now() - make_interval(days => d)),
      'mod_actions', (select count(*) from public.moderation_log where at > now() - make_interval(days => d)),
      'feedback', (select count(*) from public.feedback where created_at > now() - make_interval(days => d))));
end $$;

-- /serverinfo : numbers about the website.
create or replace function public.server_info(staff_key text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'userinfo') then return null; end if;
  return jsonb_build_object('members', (select count(*) from public.discord_users()),
    'banned', (select count(*) from public.user_moderation m where public.user_state(m.discord_id) = 'banned'),
    'timed_out', (select count(*) from public.user_moderation m where public.user_state(m.discord_id) = 'timeout'),
    'staff', (select count(*) from public.chat_roster()), 'staff_online', (select count(*) from public.chat_roster() r where r.status = 'online'),
    'applications_open', (select count(*) from public.applications where status not in ('approved','denied')),
    'applications_total', (select count(*) from public.applications),
    'feedback_new', (select count(*) from public.feedback where status = 'new'),
    'channels', (select count(*) from public.chat_channels), 'closed_types', to_jsonb(public.get_closed_types()));
end $$;

revoke all on function public.staff_numbers(text, integer) from public, anon, authenticated;
grant execute on function public.find_user(text, text) to anon, authenticated;
grant execute on function public.app_list(text, text, integer) to anon, authenticated;
grant execute on function public.app_stats(text) to anon, authenticated;
grant execute on function public.app_toggle(text, text, boolean) to anon, authenticated;
grant execute on function public.staff_rank_step(text, text, integer) to anon, authenticated;
grant execute on function public.staff_profile(text, text) to anon, authenticated;
grant execute on function public.staff_stats(text, text) to anon, authenticated;
grant execute on function public.staff_activity(text, integer) to anon, authenticated;
grant execute on function public.server_info(text) to anon, authenticated;

-- What can this login do? The dashboard uses it to show only the buttons that will work (the database still checks every action itself).
create or replace function public.staff_me(staff_key text)
returns jsonb language sql stable security definer set search_path = public
as $$
  select case when public.staff_role(staff_key) is null then null
    else jsonb_build_object('role', public.staff_role(staff_key), 'name', public.staff_name(staff_key), 'caps', to_jsonb(public.staff_caps(staff_key)),
                            'discord', public.chat_actor(staff_key) is not null, 'id', public.chat_actor(staff_key)) end
$$;
grant execute on function public.staff_me(text) to anon, authenticated;
notify pgrst, 'reload schema';

-- ======================= 20261113000008_screenshot_audit.sql =======================
-- =====================================================================================================
-- 0008  Built-in screenshot tool (administrators only) + privacy audit.
-- The website's screenshot button first asks the database for permission. The database checks, every time,
-- that the caller has a live Discord administrator session and may open that conversation. It then writes
-- an audit row (who, Discord ID, when, which channel or DM) and only then does the browser take the picture.
-- A website cannot stop someone using Windows, a phone camera or screen recording; this controls and logs the built-in tool.
-- =====================================================================================================

create table if not exists public.screenshot_log (
  id             bigserial primary key,
  at             timestamptz not null default now(),
  actor_id       text not null,
  actor_username text not null default '',
  actor_name     text not null default '',
  kind           text not null check (kind in ('taken','denied','key_detected')),
  scope          text,
  scope_label    text,
  detail         text
);
create index if not exists screenshot_log_at on public.screenshot_log (at desc);
alter table public.screenshot_log enable row level security;
revoke all on public.screenshot_log from anon, authenticated;

create or replace function public.chat_watermark(staff_key text)
returns jsonb language sql stable security definer set search_path = public
as $$
  select case when public.chat_actor(staff_key) is null then null
    else jsonb_build_object('id', public.chat_actor(staff_key),
      'username', coalesce((select r.username from public.chat_roster() r where r.discord_id = public.chat_actor(staff_key)), public.staff_name(staff_key), 'staff')) end
$$;

-- Ask permission to take a screenshot of one conversation. Returns {ok:true,...} only for an administrator who may open it.
create or replace function public.chat_screenshot(staff_key text, p_scope text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record; lbl text; uname text; nm text; lid bigint;
begin
  if me is null or rl is null then return jsonb_build_object('error', 'login'); end if;
  select r.username, r.display_name into uname, nm from public.chat_roster() r where r.discord_id = me;
  if not public.staff_can(staff_key, 'screenshot') then
    insert into public.screenshot_log (actor_id, actor_username, actor_name, kind, scope, detail) values (me, coalesce(uname, ''), coalesce(nm, ''), 'denied', left(coalesce(p_scope, ''), 40), 'Not an administrator');
    perform public.log_action(staff_key, 'screenshot denied', left(coalesce(p_scope, ''), 40));
    return jsonb_build_object('error', 'forbidden');
  end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, false);
  if not coalesce(sc.ok, false) then
    insert into public.screenshot_log (actor_id, actor_username, actor_name, kind, scope, detail) values (me, coalesce(uname, ''), coalesce(nm, ''), 'denied', left(coalesce(p_scope, ''), 40), 'No access to that conversation');
    return jsonb_build_object('error', 'forbidden');
  end if;
  if sc.channel_id is not null then lbl := '#' || (select slug from public.chat_channels where id = sc.channel_id);
  else lbl := 'Private chat with ' || coalesce((select r.display_name from public.chat_roster() r where r.discord_id = substr(p_scope, 3)), substr(p_scope, 3)); end if;
  insert into public.screenshot_log (actor_id, actor_username, actor_name, kind, scope, scope_label) values (me, coalesce(uname, ''), coalesce(nm, ''), 'taken', p_scope, lbl) returning id into lid;
  perform public.log_action(staff_key, 'screenshot', lbl);
  return jsonb_build_object('ok', true, 'id', lid, 'label', lbl, 'at', now(), 'username', coalesce(uname, ''), 'discord_id', me);
end $$;

-- Screenshot-style key presses noticed by the browser (PrintScreen, Win+Shift+S, print). Any staff member's browser may report; one row per 10 seconds each.
create or replace function public.chat_privacy_event(staff_key text, p_kind text, p_scope text default null)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); uname text; nm text;
begin
  if me is null or public.staff_role(staff_key) is null then return 'login'; end if;
  if p_kind not in ('PrintScreen', 'Win+Shift+S', 'Cmd+Shift+3/4/5', 'print') then return 'invalid'; end if;
  if exists (select 1 from public.screenshot_log where actor_id = me and kind = 'key_detected' and at > now() - interval '10 seconds') then return 'ok'; end if;
  select r.username, r.display_name into uname, nm from public.chat_roster() r where r.discord_id = me;
  insert into public.screenshot_log (actor_id, actor_username, actor_name, kind, scope, detail) values (me, coalesce(uname, ''), coalesce(nm, ''), 'key_detected', left(coalesce(p_scope, ''), 40), p_kind);
  return 'ok';
end $$;

-- Administrators read the audit trail.
create or replace function public.list_screenshot_log(staff_key text, p_limit integer default 200)
returns table (id bigint, at timestamptz, actor_id text, actor_username text, actor_name text, kind text, scope_label text, detail text)
language sql stable security definer set search_path = public
as $$
  select l.id, l.at, l.actor_id, l.actor_username, l.actor_name, l.kind, coalesce(l.scope_label, l.scope), l.detail
  from public.screenshot_log l where public.staff_can(staff_key, 'screenshot') order by l.id desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)
$$;

grant execute on function public.chat_watermark(text) to anon, authenticated;
grant execute on function public.chat_screenshot(text, text) to anon, authenticated;
grant execute on function public.chat_privacy_event(text, text, text) to anon, authenticated;
grant execute on function public.list_screenshot_log(text, integer) to anon, authenticated;
notify pgrst, 'reload schema';
