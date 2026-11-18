-- 0012 (Updated Discord-style version): private staff servers (workspaces), channels, members, permissions and revocable invite links.
-- Additive and idempotent. Tables are closed to the public (RLS on, no policies); every action goes through a checked function that
-- verifies the caller's live Discord staff session. Server channels reuse the existing chat engine, so messages, replies, reactions,
-- files, pins and search all work inside servers too - and only members can ever read them (chat_chan_ok).

create table if not exists public.staff_servers (
  id          bigint generated always as identity primary key,
  name        text not null check (char_length(name) between 2 and 40),
  icon        text not null default '🏝️' check (char_length(icon) between 1 and 300),
  color       text not null default '#ff4fb8' check (color ~ '^#[0-9a-fA-F]{6}$'),
  description text not null default '' check (char_length(description) <= 200),
  owner_id    text not null,
  created_at  timestamptz not null default now()
);
create table if not exists public.server_members (
  server_id  bigint not null references public.staff_servers(id) on delete cascade,
  discord_id text not null check (discord_id ~ '^[0-9]{5,25}$'),
  role       text not null default 'member' check (role in ('owner','admin','member')),
  perms      text[] not null default '{send}',
  joined_at  timestamptz not null default now(),
  via_invite text,
  primary key (server_id, discord_id)
);
create index if not exists server_members_user on public.server_members (discord_id);
create table if not exists public.server_invites (
  code       text primary key check (code ~ '^[a-z0-9]{10,24}$'),
  server_id  bigint not null references public.staff_servers(id) on delete cascade,
  created_by text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  max_uses   integer check (max_uses is null or max_uses between 1 and 1000),
  uses       integer not null default 0,
  revoked_at timestamptz,
  revoked_by text
);
create index if not exists server_invites_server on public.server_invites (server_id);
create table if not exists public.server_audit (
  id         bigint generated always as identity primary key,
  server_id  bigint not null references public.staff_servers(id) on delete cascade,
  at         timestamptz not null default now(),
  actor_id   text,
  actor_name text not null default 'System',
  action     text not null,
  detail     text
);
create index if not exists server_audit_server on public.server_audit (server_id, at desc);
create table if not exists public.server_channel_members (
  channel_id bigint not null references public.chat_channels(id) on delete cascade,
  discord_id text not null,
  primary key (channel_id, discord_id)
);
alter table public.staff_servers enable row level security;
alter table public.server_members enable row level security;
alter table public.server_invites enable row level security;
alter table public.server_audit enable row level security;
alter table public.server_channel_members enable row level security;
revoke all on public.staff_servers, public.server_members, public.server_invites, public.server_audit, public.server_channel_members from anon, authenticated;

alter table public.chat_channels add column if not exists server_id bigint references public.staff_servers(id) on delete cascade;
alter table public.chat_channels add column if not exists private boolean not null default false;
alter table public.chat_channels drop constraint if exists chat_channels_slug_key;
create unique index if not exists chat_channels_slug_global on public.chat_channels (slug) where server_id is null;
create unique index if not exists chat_channels_slug_server on public.chat_channels (server_id, slug) where server_id is not null;
create index if not exists chat_channels_server on public.chat_channels (server_id);

-- ---------------- permission helpers ----------------
-- Server permissions: send, invite, manage_channels, manage_members, manage_messages, manage_server. Owner and server admins hold all of them.
create or replace function public.srv_role(did text, sid bigint)
returns text language sql stable security definer set search_path = public
as $$ select m.role from public.server_members m where m.server_id = sid and m.discord_id = did $$;

create or replace function public.srv_can(did text, sid bigint, perm text)
returns boolean language sql stable security definer set search_path = public
as $$ select coalesce((select m.role in ('owner','admin') or perm = any(m.perms) from public.server_members m where m.server_id = sid and m.discord_id = did), false) $$;

create or replace function public.srv_log(sid bigint, k text, act text, det text default null)
returns void language sql security definer set search_path = public
as $$ insert into public.server_audit (server_id, actor_id, actor_name, action, detail) values (sid, public.chat_actor(k), coalesce(public.rpt_name(k), 'Staff'), act, det) $$;

revoke all on function public.srv_role(text, bigint), public.srv_can(text, bigint, text), public.srv_log(bigint, text, text, text) from public, anon, authenticated;

-- Channel access: community channels keep their rank rules; server channels need membership (and a private channel needs an explicit seat).
create or replace function public.chat_chan_ok(me text, rl text, c public.chat_channels)
returns boolean language sql stable security definer set search_path = public
as $$
  select case when c.server_id is null
    then public.acc_rank(rl) >= public.acc_rank(c.min_access) and (not c.no_helpers or not public.chat_helper(me, rl))
    else exists (select 1 from public.server_members m where m.server_id = c.server_id and m.discord_id = me)
         and (not c.private or public.srv_can(me, c.server_id, 'manage_channels')
              or exists (select 1 from public.server_channel_members x where x.channel_id = c.id and x.discord_id = me))
  end
$$;

-- ---------------- servers ----------------
create or replace function public.server_create(staff_key text, p_name text, p_icon text default '🏝️', p_color text default '#ff4fb8', p_desc text default '')
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); n text := left(trim(coalesce(p_name, '')), 40); ic text := left(trim(coalesce(p_icon, '')), 300); sid bigint; cid bigint;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'server_create') then return jsonb_build_object('error', 'forbidden'); end if;
  if char_length(n) < 2 then return jsonb_build_object('error', 'name'); end if;
  if ic = '' then ic := '🏝️'; end if;
  if ic ~* '^(https?:)' and ic !~* '^https://[^ ]+$' then return jsonb_build_object('error', 'icon'); end if;
  if ic ~* '^[a-z]+:' and ic !~* '^https://' then return jsonb_build_object('error', 'icon'); end if;
  if (select count(*) from public.staff_servers) >= 10 then return jsonb_build_object('error', 'server_limit'); end if;   -- site-wide maximum: 10 private servers
  insert into public.staff_servers (name, icon, color, description, owner_id)
    values (n, ic, case when coalesce(p_color, '') ~ '^#[0-9a-fA-F]{6}$' then p_color else '#ff4fb8' end, left(trim(coalesce(p_desc, '')), 200), me) returning id into sid;
  insert into public.server_members (server_id, discord_id, role, perms) values (sid, me, 'owner', '{send,invite,manage_channels,manage_members,manage_messages,manage_server}');
  insert into public.chat_channels (slug, category, topic, server_id, sort_order) values ('general', 'TEXT CHANNELS', 'Say hello', sid, 1) returning id into cid;
  insert into public.chat_channels (slug, category, topic, server_id, sort_order) values ('announcements', 'TEXT CHANNELS', 'Updates for everyone in this server', sid, 2);
  insert into public.chat_messages (channel_id, author_id, kind, body) values (cid, null, 'system', 'Welcome to ' || n || '. Use Add channel in the sidebar to build your channels and Invite staff in the server menu to bring your team in.');
  perform public.srv_log(sid, staff_key, 'server created', n);
  return jsonb_build_object('ok', true, 'id', sid, 'channel', cid);
end $$;

create or replace function public.server_update(staff_key text, p_id bigint, p_name text default null, p_icon text default null, p_color text default null, p_desc text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); ic text := left(trim(coalesce(p_icon, '')), 300);
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not (public.srv_can(me, p_id, 'manage_server') or public.staff_can(staff_key, 'servers_admin')) then return jsonb_build_object('error', 'forbidden'); end if;
  if p_name is not null and char_length(trim(p_name)) < 2 then return jsonb_build_object('error', 'name'); end if;
  if ic <> '' and ic ~* '^[a-z]+:' and ic !~* '^https://[^ ]+$' then return jsonb_build_object('error', 'icon'); end if;
  update public.staff_servers set name = coalesce(nullif(left(trim(p_name), 40), ''), name), icon = coalesce(nullif(ic, ''), icon),
         color = case when coalesce(p_color, '') ~ '^#[0-9a-fA-F]{6}$' then p_color else color end, description = coalesce(left(trim(p_desc), 200), description) where id = p_id;
  if not found then return jsonb_build_object('error', 'notfound'); end if;
  perform public.srv_log(p_id, staff_key, 'server updated', null);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.server_delete(staff_key text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); n text;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not (public.srv_role(me, p_id) = 'owner' or public.staff_can(staff_key, 'servers_admin')) then return jsonb_build_object('error', 'forbidden'); end if;
  select name into n from public.staff_servers where id = p_id; if n is null then return jsonb_build_object('error', 'notfound'); end if;
  delete from public.staff_servers where id = p_id;
  perform public.log_action(staff_key, 'server deleted', n || ' (#' || p_id || ')');
  return jsonb_build_object('ok', true);
end $$;

-- One server: members with live presence, channels, invites (only for people allowed to manage them) and the recent audit trail.
create or replace function public.server_get(staff_key text, p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); s public.staff_servers; mine public.server_members; sa boolean := false;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  select * into s from public.staff_servers where id = p_id; if not found then return jsonb_build_object('error', 'notfound'); end if;
  select * into mine from public.server_members where server_id = p_id and discord_id = me;
  sa := public.staff_can(staff_key, 'servers_admin');
  if mine.discord_id is null and not sa then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object('id', s.id, 'name', s.name, 'icon', s.icon, 'color', s.color, 'description', s.description, 'owner_id', s.owner_id, 'created_at', s.created_at,
    'member', mine.discord_id is not null, 'role', mine.role, 'perms', case when mine.role in ('owner','admin') then to_jsonb(array['send','invite','manage_channels','manage_members','manage_messages','manage_server']) else to_jsonb(coalesce(mine.perms, '{}')) end,
    'site_admin', sa,
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.discord_id, 'role', m.role, 'perms', m.perms, 'joined', m.joined_at,
         'name', coalesce(r.display_name, d.display_name, d.username, 'Staff member'), 'avatar', coalesce(r.avatar, d.avatar), 'rank', r.rank_label, 'status', coalesce(r.status, 'offline'))
         order by case m.role when 'owner' then 0 when 'admin' then 1 else 2 end, lower(coalesce(r.display_name, d.display_name, ''))) from public.server_members m
         left join lateral (select x.* from public.chat_roster() x where x.discord_id = m.discord_id) r on true
         left join lateral public.discord_user(m.discord_id) d on true where m.server_id = p_id), '[]'::jsonb),
    'channels', case when mine.discord_id is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'slug', c.slug, 'topic', c.topic, 'private', c.private, 'locked', c.locked,
         'members', case when public.srv_can(me, p_id, 'manage_channels') then coalesce((select jsonb_agg(x.discord_id) from public.server_channel_members x where x.channel_id = c.id), '[]'::jsonb) else null end) order by c.sort_order, c.id)
         from public.chat_channels c where c.server_id = p_id and public.chat_chan_ok(me, public.staff_role(staff_key), c)), '[]'::jsonb) end,
    'invites', case when public.srv_can(me, p_id, 'invite') or public.srv_can(me, p_id, 'manage_server') then coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'created_at', i.created_at, 'expires_at', i.expires_at, 'max_uses', i.max_uses, 'uses', i.uses,
         'revoked', i.revoked_at is not null, 'expired', i.expires_at is not null and i.expires_at < now(), 'by', coalesce((select r2.display_name from public.chat_roster() r2 where r2.discord_id = i.created_by), 'Staff'))
         order by i.created_at desc) from (select * from public.server_invites where server_id = p_id order by created_at desc limit 30) i), '[]'::jsonb) else null end,
    'audit', case when mine.role in ('owner','admin') or sa then coalesce((select jsonb_agg(jsonb_build_object('at', a.at, 'actor', a.actor_name, 'action', a.action, 'detail', a.detail) order by a.id desc)
         from (select * from public.server_audit where server_id = p_id order by id desc limit 40) a), '[]'::jsonb) else null end);
end $$;

-- ---------------- channels ----------------
create or replace function public.server_channel_save(staff_key text, p_server bigint, p_id bigint default null, p_name text default '', p_topic text default '', p_private boolean default false, p_members text[] default '{}')
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); v_slug text := regexp_replace(lower(trim(coalesce(p_name, ''))), '[^a-z0-9]+', '-', 'g'); cid bigint; mem text;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.srv_can(me, p_server, 'manage_channels') then return jsonb_build_object('error', 'forbidden'); end if;
  v_slug := trim(both '-' from v_slug); v_slug := left(v_slug, 30);
  if v_slug = '' then return jsonb_build_object('error', 'name'); end if;
  if p_id is null then
    if (select count(*) from public.chat_channels where server_id = p_server) >= 30 then return jsonb_build_object('error', 'limit'); end if;
    if exists (select 1 from public.chat_channels where server_id = p_server and chat_channels.slug = v_slug) then return jsonb_build_object('error', 'exists'); end if;
    insert into public.chat_channels (slug, category, topic, server_id, private, sort_order)
      values (v_slug, case when coalesce(p_private, false) then 'PRIVATE CHANNELS' else 'TEXT CHANNELS' end, left(coalesce(p_topic, ''), 200), p_server, coalesce(p_private, false), 10 + (select count(*) from public.chat_channels where server_id = p_server)) returning id into cid;
    perform public.srv_log(p_server, staff_key, 'channel created', '#' || v_slug || case when coalesce(p_private, false) then ' (private)' else '' end);
  else
    cid := p_id;
    if not exists (select 1 from public.chat_channels where id = cid and server_id = p_server) then return jsonb_build_object('error', 'notfound'); end if;
    if exists (select 1 from public.chat_channels where server_id = p_server and chat_channels.slug = v_slug and id <> cid) then return jsonb_build_object('error', 'exists'); end if;
    update public.chat_channels set slug = v_slug, topic = left(coalesce(p_topic, ''), 200), private = coalesce(p_private, false),
           category = case when coalesce(p_private, false) then 'PRIVATE CHANNELS' else 'TEXT CHANNELS' end where id = cid;
    perform public.srv_log(p_server, staff_key, 'channel updated', '#' || v_slug);
  end if;
  delete from public.server_channel_members where channel_id = cid;
  if coalesce(p_private, false) then
    foreach mem in array coalesce(p_members, '{}') loop
      if exists (select 1 from public.server_members where server_id = p_server and discord_id = mem) then
        insert into public.server_channel_members (channel_id, discord_id) values (cid, mem) on conflict do nothing;
      end if;
    end loop;
    insert into public.server_channel_members (channel_id, discord_id) values (cid, me) on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true, 'id', cid);
end $$;

create or replace function public.server_channel_delete(staff_key text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); c public.chat_channels;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  select * into c from public.chat_channels where id = p_id and server_id is not null; if not found then return jsonb_build_object('error', 'notfound'); end if;
  if not public.srv_can(me, c.server_id, 'manage_channels') then return jsonb_build_object('error', 'forbidden'); end if;
  if (select count(*) from public.chat_channels where server_id = c.server_id) <= 1 then return jsonb_build_object('error', 'last'); end if;
  delete from public.chat_channels where id = p_id;
  perform public.srv_log(c.server_id, staff_key, 'channel deleted', '#' || c.slug);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------- members ----------------
create or replace function public.server_member_set(staff_key text, p_server bigint, p_user text, p_role text default 'member', p_perms text[] default '{send}')
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); t public.server_members; r text := lower(coalesce(p_role, 'member')); pr text[]; nm text;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.srv_can(me, p_server, 'manage_members') then return jsonb_build_object('error', 'forbidden'); end if;
  select * into t from public.server_members where server_id = p_server and discord_id = p_user; if not found then return jsonb_build_object('error', 'notfound'); end if;
  if t.role = 'owner' then return jsonb_build_object('error', 'owner'); end if;
  if r not in ('admin','member') then return jsonb_build_object('error', 'role'); end if;
  if (r = 'admin' or t.role = 'admin') and public.srv_role(me, p_server) <> 'owner' then return jsonb_build_object('error', 'owner_only'); end if;
  select coalesce(array_agg(distinct x), '{}') into pr from unnest(coalesce(p_perms, '{}')) x where x in ('send','invite','manage_channels','manage_members','manage_messages','manage_server');
  update public.server_members set role = r, perms = case when r = 'admin' then '{send,invite,manage_channels,manage_members,manage_messages,manage_server}' else pr end where server_id = p_server and discord_id = p_user;
  select coalesce(display_name, p_user) into nm from public.chat_roster() where discord_id = p_user;
  perform public.srv_log(p_server, staff_key, 'permissions changed', coalesce(nm, p_user) || ': ' || r || ' [' || array_to_string(pr, ',') || ']');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.server_member_remove(staff_key text, p_server bigint, p_user text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); t public.server_members; nm text;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  select * into t from public.server_members where server_id = p_server and discord_id = p_user; if not found then return jsonb_build_object('error', 'notfound'); end if;
  if t.role = 'owner' then return jsonb_build_object('error', 'owner'); end if;
  if p_user <> me then
    if not (public.srv_can(me, p_server, 'manage_members') or public.staff_can(staff_key, 'servers_admin')) then return jsonb_build_object('error', 'forbidden'); end if;
    if t.role = 'admin' and not (public.srv_role(me, p_server) = 'owner' or public.staff_can(staff_key, 'servers_admin')) then return jsonb_build_object('error', 'owner_only'); end if;
  end if;
  delete from public.server_channel_members where discord_id = p_user and channel_id in (select id from public.chat_channels where server_id = p_server);
  delete from public.server_members where server_id = p_server and discord_id = p_user;
  select coalesce(display_name, p_user) into nm from public.chat_roster() where discord_id = p_user;
  perform public.srv_log(p_server, staff_key, case when p_user = me then 'left the server' else 'member removed' end, coalesce(nm, p_user));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.server_transfer(staff_key text, p_server bigint, p_user text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key);
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if public.srv_role(me, p_server) is distinct from 'owner' then return jsonb_build_object('error', 'forbidden'); end if;
  if p_user = me or not exists (select 1 from public.server_members where server_id = p_server and discord_id = p_user) then return jsonb_build_object('error', 'notfound'); end if;
  update public.server_members set role = 'admin' where server_id = p_server and discord_id = me;
  update public.server_members set role = 'owner', perms = '{send,invite,manage_channels,manage_members,manage_messages,manage_server}' where server_id = p_server and discord_id = p_user;
  update public.staff_servers set owner_id = p_user where id = p_server;
  perform public.srv_log(p_server, staff_key, 'ownership transferred', p_user);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------- invites ----------------
create or replace function public.server_invite_create(staff_key text, p_server bigint, p_hours integer default 168, p_max_uses integer default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); code text;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not (public.srv_can(me, p_server, 'invite') or public.srv_can(me, p_server, 'manage_server')) then return jsonb_build_object('error', 'forbidden'); end if;
  if (select count(*) from public.server_invites where server_id = p_server and revoked_at is null and (expires_at is null or expires_at > now())) >= 20 then return jsonb_build_object('error', 'limit'); end if;
  if p_hours is not null and (p_hours < 0 or p_hours > 24 * 90) then return jsonb_build_object('error', 'hours'); end if;
  code := substr(replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), 1, 14);
  insert into public.server_invites (code, server_id, created_by, expires_at, max_uses)
    values (code, p_server, me, case when coalesce(p_hours, 0) = 0 then null else now() + make_interval(hours => p_hours) end, nullif(p_max_uses, 0));
  perform public.srv_log(p_server, staff_key, 'invite created', code || case when coalesce(p_hours, 0) = 0 then ' (never expires)' else ' (' || p_hours || 'h)' end);
  return jsonb_build_object('ok', true, 'code', code);
end $$;

create or replace function public.server_invite_revoke(staff_key text, p_code text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); i public.server_invites;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  select * into i from public.server_invites where code = lower(trim(coalesce(p_code, ''))); if not found then return jsonb_build_object('error', 'notfound'); end if;
  if not (i.created_by = me or public.srv_can(me, i.server_id, 'manage_server')) then return jsonb_build_object('error', 'forbidden'); end if;
  update public.server_invites set revoked_at = coalesce(revoked_at, now()), revoked_by = coalesce(revoked_by, me) where code = i.code;
  perform public.srv_log(i.server_id, staff_key, 'invite revoked', i.code);
  return jsonb_build_object('ok', true);
end $$;

-- Preview of an invite. Only people with a live staff session get an answer, so outsiders learn nothing.
create or replace function public.server_invite_info(staff_key text, p_code text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); i public.server_invites; s public.staff_servers;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  select * into i from public.server_invites where code = lower(trim(coalesce(p_code, ''))); if not found then return jsonb_build_object('error', 'invalid'); end if;
  if i.revoked_at is not null then return jsonb_build_object('error', 'revoked'); end if;
  if i.expires_at is not null and i.expires_at < now() then return jsonb_build_object('error', 'expired'); end if;
  if i.max_uses is not null and i.uses >= i.max_uses then return jsonb_build_object('error', 'full'); end if;
  select * into s from public.staff_servers where id = i.server_id;
  return jsonb_build_object('ok', true, 'server', jsonb_build_object('id', s.id, 'name', s.name, 'icon', s.icon, 'color', s.color, 'description', s.description,
         'members', (select count(*) from public.server_members where server_id = s.id)), 'already', public.srv_role(me, s.id) is not null, 'expires_at', i.expires_at);
end $$;

-- Joining re-checks everything on the server: live Discord staff session, not banned or removed from staff, invite still valid.
create or replace function public.server_invite_join(staff_key text, p_code text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); i public.server_invites; nm text; cid bigint;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if public.user_state(me) = 'banned' or exists (select 1 from public.staff_blocked b where b.discord_id = me) then return jsonb_build_object('error', 'not_staff'); end if;
  if not exists (select 1 from public.chat_roster() r where r.discord_id = me) then return jsonb_build_object('error', 'not_staff'); end if;
  select * into i from public.server_invites where code = lower(trim(coalesce(p_code, ''))) for update; if not found then return jsonb_build_object('error', 'invalid'); end if;
  if i.revoked_at is not null then return jsonb_build_object('error', 'revoked'); end if;
  if i.expires_at is not null and i.expires_at < now() then return jsonb_build_object('error', 'expired'); end if;
  if public.srv_role(me, i.server_id) is not null then return jsonb_build_object('ok', true, 'id', i.server_id, 'already', true); end if;
  if i.max_uses is not null and i.uses >= i.max_uses then return jsonb_build_object('error', 'full'); end if;
  insert into public.server_members (server_id, discord_id, role, perms, via_invite) values (i.server_id, me, 'member', '{send}', i.code);
  update public.server_invites set uses = uses + 1 where code = i.code;
  nm := coalesce(public.rpt_name(staff_key), 'A staff member');
  perform public.srv_log(i.server_id, staff_key, 'joined via invite', i.code);
  select id into cid from public.chat_channels where server_id = i.server_id and private = false order by sort_order, id limit 1;
  if cid is not null then insert into public.chat_messages (channel_id, author_id, kind, body) values (cid, null, 'system', nm || ' joined the server.'); end if;
  return jsonb_build_object('ok', true, 'id', i.server_id);
end $$;

create or replace function public.server_list(staff_key text, p_all boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key);
begin
  if me is null or public.staff_role(staff_key) is null then return null; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'icon', s.icon, 'color', s.color, 'role', m.role, 'members', (select count(*) from public.server_members x where x.server_id = s.id), 'owner_id', s.owner_id) order by s.name)
    from public.staff_servers s left join public.server_members m on m.server_id = s.id and m.discord_id = me
    where m.discord_id is not null or (coalesce(p_all, false) and public.staff_can(staff_key, 'servers_admin'))), '[]'::jsonb);
end $$;

revoke all on function public.server_create(text, text, text, text, text), public.server_update(text, bigint, text, text, text, text), public.server_delete(text, bigint), public.server_get(text, bigint),
  public.server_channel_save(text, bigint, bigint, text, text, boolean, text[]), public.server_channel_delete(text, bigint), public.server_member_set(text, bigint, text, text, text[]),
  public.server_member_remove(text, bigint, text), public.server_transfer(text, bigint, text), public.server_invite_create(text, bigint, integer, integer), public.server_invite_revoke(text, text),
  public.server_invite_info(text, text), public.server_invite_join(text, text), public.server_list(text, boolean) from public;
grant execute on function public.server_create(text, text, text, text, text), public.server_update(text, bigint, text, text, text, text), public.server_delete(text, bigint), public.server_get(text, bigint),
  public.server_channel_save(text, bigint, bigint, text, text, boolean, text[]), public.server_channel_delete(text, bigint), public.server_member_set(text, bigint, text, text, text[]),
  public.server_member_remove(text, bigint, text), public.server_transfer(text, bigint, text), public.server_invite_create(text, bigint, integer, integer), public.server_invite_revoke(text, text),
  public.server_invite_info(text, text), public.server_invite_join(text, text), public.server_list(text, boolean) to anon, authenticated;

-- ---------------- chat engine hooks for servers ----------------
CREATE OR REPLACE FUNCTION public.chat_resolve(me text, rl text, p_scope text, need_post boolean, OUT channel_id bigint, OUT dm_key text, OUT ok boolean)
 RETURNS record
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.chat_channels; other text;
begin
  ok := false;
  if p_scope like 'c:%' and substr(p_scope, 3) ~ '^[0-9]{1,18}$' then
    select * into c from public.chat_channels where id = substr(p_scope, 3)::bigint;
    if found and public.chat_chan_ok(me, rl, c) and (not need_post or (case when c.server_id is null then public.acc_rank(rl) >= public.acc_rank(c.post_min) else public.srv_can(me, c.server_id, 'send') and (not c.locked or public.srv_can(me, c.server_id, 'manage_channels')) end)) then
      channel_id := c.id; ok := true;
    end if;
  elsif p_scope like 'd:%' then
    other := substr(p_scope, 3);
    if other ~ '^[0-9]{5,25}$' and other <> me and exists (select 1 from public.chat_roster() r where r.discord_id = other) then
      dm_key := least(me, other) || ':' || greatest(me, other); ok := true;
    end if;
  end if;
end $function$;
CREATE OR REPLACE FUNCTION public.chat_poll(staff_key text, p_scope text DEFAULT ''::text, p_away boolean DEFAULT false, p_read boolean DEFAULT true, p_limit integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record; mx bigint;
        msgs jsonb := '[]'; ppl jsonb := '[]'; pins jsonb := '[]'; typ jsonb := '[]'; chans jsonb; dms jsonb; ros jsonb; mine jsonb; canpost boolean := false; oread bigint; ch public.chat_channels;
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
        canpost := case when ch.server_id is null then public.acc_rank(rl) >= public.acc_rank(ch.post_min) and (not ch.locked or public.staff_can(staff_key, 'lock')) else public.srv_can(me, ch.server_id, 'send') and (not ch.locked or public.srv_can(me, ch.server_id, 'manage_channels')) end;
      else
        canpost := true;
        select r.last_id into oread from public.chat_reads r where r.discord_id = substr(p_scope, 3) and r.scope = 'd:' || me;
      end if;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'slug', c.slug, 'category', c.category, 'topic', c.topic, 'sys', c.sys, 'server_id', c.server_id, 'private', c.private, 'min_access', c.min_access, 'post_min', c.post_min,
      'no_helpers', c.no_helpers, 'locked', c.locked, 'slow_mode', c.slow_mode, 'info', c.info,
      'can_post', case when c.server_id is null then public.acc_rank(rl) >= public.acc_rank(c.post_min) and (not c.locked or public.staff_can(staff_key, 'lock')) else public.srv_can(me, c.server_id, 'send') and (not c.locked or public.srv_can(me, c.server_id, 'manage_channels')) end,
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
  -- people who wrote something here but are not in the live roster (staff whose session ended, removed staff): still show their Discord name and avatar
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'username', coalesce(d.username, p.username, ''), 'name', coalesce(nullif(d.display_name, ''), nullif(p.display_name, ''), p.username, 'Staff member'),
      'avatar', coalesce(d.avatar, p.avatar), 'rank', coalesce(m.rank_name, 'Staff'), 'access', coalesce(p.access, 'viewer'), 'status', 'offline')), '[]'::jsonb) into ppl
    from (select distinct a.id from (
            select e->>'author_id' as id from jsonb_array_elements(msgs) e
            union select e->>'author_id' from jsonb_array_elements(pins) e
            union select e->'reply'->>'author_id' from jsonb_array_elements(msgs) e) a
          where a.id is not null and not exists (select 1 from jsonb_array_elements(ros) q where q->>'id' = a.id)) x
    left join public.staff_profiles p on p.discord_id = x.id
    left join public.staff_members m on m.discord_id = x.id
    left join lateral public.discord_user(x.id) d on true;
  select jsonb_build_object('id', me, 'role', rl, 'name', coalesce(r.display_name, 'Staff'), 'avatar', r.avatar, 'rank', r.rank_label,
         'caps', to_jsonb(public.staff_caps(staff_key)), 'notify', (select p.notify from public.staff_profiles p where p.discord_id = me),
         'manual_away', (select p.manual_away from public.staff_profiles p where p.discord_id = me))
    into mine from public.chat_roster() r where r.discord_id = me;

  return jsonb_build_object('me', coalesce(mine, jsonb_build_object('id', me, 'role', rl, 'caps', to_jsonb(public.staff_caps(staff_key)))), 'channels', chans, 'dms', dms, 'roster', ros, 'people', ppl, 'messages', msgs, 'pins', pins,
                            'typing', typ, 'can_post', canpost, 'other_read', oread, 'at', now());
end $function$;
CREATE OR REPLACE FUNCTION public.chat_delete(staff_key text, p_id bigint)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages;
begin
  if me is null or rl is null then return 'login'; end if;
  select * into m from public.chat_messages where id = p_id;
  if not found or m.deleted then return 'notfound'; end if;
  if not public.chat_can_see(me, rl, m) then return 'forbidden'; end if;
  if m.author_id is distinct from me and not (case when exists (select 1 from public.chat_channels c where c.id = m.channel_id and c.server_id is not null) then public.srv_can(me, (select c.server_id from public.chat_channels c where c.id = m.channel_id), 'manage_messages') else rl = 'admin' end) then return 'forbidden'; end if;
  update public.chat_messages set deleted = true, body = '', pinned = false where id = p_id;
  delete from public.chat_attachments where message_id = p_id;
  delete from public.chat_reactions where message_id = p_id;
  if m.author_id is distinct from me then perform public.log_action(staff_key, 'chat message removed', 'message #' || p_id); end if;
  return 'ok';
end $function$;
CREATE OR REPLACE FUNCTION public.chat_pin(staff_key text, p_id bigint, p_pin boolean)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages;
begin
  if me is null or rl is null then return 'login'; end if;
  select * into m from public.chat_messages where id = p_id;
  if not found or m.deleted or not public.chat_can_see(me, rl, m) then return 'notfound'; end if;
  if not (public.staff_can(staff_key, 'pin') or (m.channel_id is not null and exists (select 1 from public.chat_channels c where c.id = m.channel_id and c.server_id is not null and public.srv_can(me, c.server_id, 'manage_messages')))) then return 'forbidden'; end if;
  -- announcements can only be pinned / unpinned by administrators
  if m.kind = 'announcement' and not public.staff_can(staff_key, 'announce') then return 'forbidden'; end if;
  update public.chat_messages set pinned = coalesce(p_pin, true), pinned_by = case when coalesce(p_pin, true) then me end where id = p_id;
  return 'ok';
end $function$;

-- The poll the redesigned chat uses: the community (p_server null) or one server. Adds the server rail with unread counts and the server's own member list.
create or replace function public.chat_poll2(staff_key text, p_scope text default '', p_server bigint default null, p_away boolean default false, p_read boolean default true, p_limit integer default 60)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare r jsonb; me text := public.chat_actor(staff_key); srv jsonb; allc jsonb; mem jsonb := null;
begin
  r := public.chat_poll(staff_key, p_scope, p_away, p_read, p_limit);
  if r ? 'error' then return r; end if;
  allc := r->'channels';
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'icon', s.icon, 'color', s.color, 'role', m.role,
        'unread', coalesce((select sum((c->>'unread')::int) from jsonb_array_elements(allc) c where (c->>'server_id')::bigint = s.id and not (c->>'muted')::boolean), 0),
        'mentions', coalesce((select sum((c->>'mentions')::int) from jsonb_array_elements(allc) c where (c->>'server_id')::bigint = s.id and not (c->>'muted')::boolean), 0)) order by s.created_at), '[]'::jsonb)
    into srv from public.staff_servers s join public.server_members m on m.server_id = s.id and m.discord_id = me;
  if p_server is not null then
    if public.srv_role(me, p_server) is null then return jsonb_build_object('error', 'forbidden'); end if;
    select coalesce(jsonb_agg(x || jsonb_build_object('srole', m.role)), '[]'::jsonb) into mem
      from jsonb_array_elements(r->'roster') x join public.server_members m on m.server_id = p_server and m.discord_id = x->>'id';
  end if;
  return (r - 'channels' - 'roster')
    || jsonb_build_object('channels', coalesce((select jsonb_agg(c) from jsonb_array_elements(allc) c where (c->>'server_id')::bigint is not distinct from p_server), '[]'::jsonb),
                          'roster', coalesce(mem, r->'roster'), 'everyone', r->'roster', 'servers', srv, 'server', p_server,
                          'community', jsonb_build_object('unread', coalesce((select sum((c->>'unread')::int) from jsonb_array_elements(allc) c where c->>'server_id' is null and not (c->>'muted')::boolean), 0),
                                                          'mentions', coalesce((select sum((c->>'mentions')::int) from jsonb_array_elements(allc) c where c->>'server_id' is null and not (c->>'muted')::boolean), 0)));
end $$;
revoke all on function public.chat_poll2(text, text, bigint, boolean, boolean, integer) from public;
grant execute on function public.chat_poll2(text, text, bigint, boolean, boolean, integer) to anon, authenticated;
