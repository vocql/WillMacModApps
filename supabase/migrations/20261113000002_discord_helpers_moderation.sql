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
