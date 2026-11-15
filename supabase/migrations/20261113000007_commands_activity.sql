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
