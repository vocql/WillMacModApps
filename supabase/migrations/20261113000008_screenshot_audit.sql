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
