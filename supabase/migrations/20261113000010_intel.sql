-- Intel: search, risk-scored dossiers and an overview "radar" for moderators (capability: userinfo = Moderator and up).
-- Read-only. Every function re-checks the staff session; tables stay closed to the public.

create or replace function public.intel_risk(did text)
returns int language sql stable security definer set search_path = public
as $$
  select least(100,
      (case when public.user_state(did) = 'banned' then 55 when public.user_state(did) = 'timeout' then 25 else 0 end)
    + 12 * (select count(*) from public.moderation_log l where l.target_id = did and l.action = 'warn' and l.at > now() - interval '90 days')::int
    + 15 * (select count(*) from public.moderation_log l where l.target_id = did and l.action = 'timeout')::int
    + 20 * (select count(*) from public.moderation_log l where l.target_id = did and l.action = 'ban')::int
    + 6  * (select count(*) from public.user_reports r where r.target_id = did and r.status in ('open','investigating'))::int
    + 2  * (select count(*) from public.applications a where a.discord_id = did and a.status = 'denied')::int)
$$;
revoke all on function public.intel_risk(text) from public, anon, authenticated;

create or replace function public.intel_search(staff_key text, p_q text default '')
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare q text := trim(coalesce(p_q, '')); res jsonb;
begin
  if not public.staff_can(staff_key, 'userinfo') then return jsonb_build_object('error', 'forbidden'); end if;
  if char_length(q) < 2 then return jsonb_build_object('results', '[]'::jsonb); end if;
  select coalesce(jsonb_agg(x order by (x->>'risk')::int desc, x->>'name'), '[]'::jsonb) into res from (
    select jsonb_build_object('id', d.discord_id, 'name', coalesce(nullif(d.display_name, ''), d.username, d.discord_id), 'username', d.username,
             'avatar', d.avatar, 'state', public.user_state(d.discord_id), 'risk', public.intel_risk(d.discord_id),
             'apps', (select count(*) from public.applications a where a.discord_id = d.discord_id)) x
    from public.discord_users() d
    where d.discord_id = q or d.username ilike '%' || q || '%' or d.display_name ilike '%' || q || '%'
    limit 25) s;
  return jsonb_build_object('results', res);
end $$;

create or replace function public.intel_profile(staff_key text, p_id text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare d record; m record; out jsonb;
begin
  if not public.staff_can(staff_key, 'userinfo') then return jsonb_build_object('error', 'forbidden'); end if;
  if p_id is null or p_id !~ '^[0-9]{5,25}$' then return jsonb_build_object('error', 'bad_id'); end if;
  select * into d from public.discord_user(p_id);
  select * into m from public.user_moderation where discord_id = p_id;
  select jsonb_build_object(
    'id', p_id, 'name', coalesce(nullif(d.display_name, ''), d.username, 'Unknown member'), 'username', d.username, 'avatar', d.avatar,
    'joined', d.created_at, 'last_login', d.last_sign_in, 'state', public.user_state(p_id), 'until', m.until_at, 'reason', m.reason,
    'risk', public.intel_risk(p_id),
    'is_staff', exists (select 1 from public.staff_members s where s.discord_id = p_id),
    'counts', jsonb_build_object(
       'warns', (select count(*) from public.moderation_log l where l.target_id = p_id and l.action = 'warn'),
       'timeouts', (select count(*) from public.moderation_log l where l.target_id = p_id and l.action = 'timeout'),
       'bans', (select count(*) from public.moderation_log l where l.target_id = p_id and l.action = 'ban'),
       'notes', (select count(*) from public.moderation_log l where l.target_id = p_id and l.action = 'note'),
       'reports', (select count(*) from public.user_reports r where r.target_id = p_id),
       'apps', (select count(*) from public.applications a where a.discord_id = p_id),
       'denied', (select count(*) from public.applications a where a.discord_id = p_id and a.status = 'denied')),
    'timeline', (select coalesce(jsonb_agg(t order by t->>'at' desc), '[]'::jsonb) from (
        select jsonb_build_object('at', l.at, 'kind', 'mod', 'title', initcap(l.action), 'text', coalesce(l.reason, l.detail, ''), 'by', l.actor) t
          from public.moderation_log l where l.target_id = p_id
        union all
        select jsonb_build_object('at', r.created_at, 'kind', 'report', 'title', 'Report: ' || r.category, 'text', left(r.details, 160), 'by', r.reporter_name)
          from public.user_reports r where r.target_id = p_id
        union all
        select jsonb_build_object('at', a.created_at, 'kind', 'app', 'title', 'Application: ' || a.type, 'text', a.status, 'by', null)
          from public.applications a where a.discord_id = p_id
        limit 60) u)
  ) into out;
  return out;
end $$;

create or replace function public.intel_overview(staff_key text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if not public.staff_can(staff_key, 'userinfo') then return jsonb_build_object('error', 'forbidden'); end if;
  return jsonb_build_object(
    'banned', (select count(*) from public.user_moderation where status = 'banned'),
    'timeouts', (select count(*) from public.user_moderation where status = 'timeout' and until_at > now()),
    'open_reports', (select count(*) from public.user_reports where status in ('open','investigating')),
    'actions_7d', (select count(*) from public.moderation_log where at > now() - interval '7 days'),
    'watch', (select coalesce(jsonb_agg(w order by (w->>'risk')::int desc), '[]'::jsonb) from (
        select jsonb_build_object('id', d.discord_id, 'name', coalesce(nullif(d.display_name, ''), d.username, d.discord_id), 'avatar', d.avatar,
               'state', public.user_state(d.discord_id), 'risk', public.intel_risk(d.discord_id)) w
        from public.discord_users() d where public.intel_risk(d.discord_id) >= 20 order by public.intel_risk(d.discord_id) desc limit 8) z),
    'by_day', (select coalesce(jsonb_agg(jsonb_build_object('d', to_char(g, 'Mon DD'), 'n', (select count(*) from public.moderation_log l where l.at::date = g::date))), '[]'::jsonb)
               from generate_series(current_date - 6, current_date, interval '1 day') g));
end $$;

revoke all on function public.intel_search(text, text), public.intel_profile(text, text), public.intel_overview(text) from public;
grant execute on function public.intel_search(text, text), public.intel_profile(text, text), public.intel_overview(text) to anon, authenticated;
