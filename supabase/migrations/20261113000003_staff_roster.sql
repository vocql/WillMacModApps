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
