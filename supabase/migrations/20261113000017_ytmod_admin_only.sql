-- YouTube Mod applications (type "ytmod"): only Administrators (and the Owner) can see or review them.
-- Everyone else gets "not allowed" from every function that could read or change one.
create or replace function public.app_locked(staff_key text, p_app text) returns boolean language sql stable security definer set search_path = public
as $$ select coalesce(public.staff_role(staff_key), '') <> 'admin' and exists (select 1 from public.applications a where a.id = public.resolve_app(p_app) and a.type = 'ytmod') $$;
create or replace function public.apps_locked(staff_key text, p_ids text[]) returns boolean language sql stable security definer set search_path = public
as $$ select coalesce(public.staff_role(staff_key), '') <> 'admin' and exists (select 1 from public.applications a where a.id::text = any(p_ids) and a.type = 'ytmod') $$;
revoke all on function public.app_locked(text, text) from public, anon, authenticated;
revoke all on function public.apps_locked(text, text[]) from public, anon, authenticated;

alter table public.chat_channels drop constraint if exists chat_channels_sys_check;
alter table public.chat_channels add constraint chat_channels_sys_check check (sys in ('applications','feedback','approved','denied','modlog','announcements','ytmod'));

-- Admin-only channel where new YouTube Mod applications arrive as cards.
insert into public.chat_channels (slug, category, topic, min_access, post_min, no_helpers, sys, sort_order, info)
select 'youtube-mod-apps', 'APPLICATION MANAGEMENT', 'YouTube Mod applications. Administrators only.', 'admin', 'admin', true, 'ytmod', 45,
  '{"purpose":"New YouTube Mod applications arrive here as cards. Only Administrators can see this channel.","belongs":["YouTube Mod application cards"],"staff_use":["Claim an application before reviewing it","Approve or deny from the card"],"instructions":["Administrators only"]}'::jsonb
where not exists (select 1 from public.chat_channels where sys = 'ytmod');

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
  where public.staff_role(staff_key) is not null and (a.type <> 'ytmod' or public.staff_role(staff_key) = 'admin')
  order by a.created_at desc
  limit 2000
$$;

create or replace function public.list_application_history(staff_key text, p_id text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if public.app_locked(staff_key, p_id) then return '[]'::jsonb; end if;
  if public.staff_role(staff_key) is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.at desc) from
    (select at, status, reviewer, note, actor from public.application_history where application_id::text = p_id) x), '[]'::jsonb);
end $$;

create or replace function public.app_applicant_info(staff_key text, p_app text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare aid uuid := public.resolve_app(p_app); a public.applications; d record; prior jsonb; dups jsonb;
begin
  if public.app_locked(staff_key, p_app) then return null; end if;
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

create or replace function public.chat_application_answers(staff_key text, p_app_id text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if public.app_locked(staff_key, p_app_id) then return null; end if;
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'apps_view') then return null; end if;
  return (select a.answers from public.applications a where a.id::text = p_app_id);
end $$;

create or replace function public.chat_decide_application(staff_key text, p_app_id text, p_status text, p_reason text default '')
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); a public.applications; n int; rs text := left(trim(coalesce(p_reason, '')), 300); nm text; cid bigint; aid uuid := public.resolve_app(p_app_id);
begin
  if public.app_locked(staff_key, p_app_id) then return 'forbidden'; end if;
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

create or replace function public.app_claim(staff_key text, p_app text)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); a public.applications; aid uuid := public.resolve_app(p_app);
begin
  if public.app_locked(staff_key, p_app) then return 'forbidden'; end if;
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

create or replace function public.app_assign(staff_key text, p_app text, p_to text)
returns text language plpgsql security definer set search_path = public
as $$
declare a public.applications; aid uuid := public.resolve_app(p_app); to_id text := nullif(trim(coalesce(p_to, '')), '');
begin
  if public.app_locked(staff_key, p_app) then return 'forbidden'; end if;
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

create or replace function public.app_release(staff_key text, p_app text)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); a public.applications; aid uuid := public.resolve_app(p_app);
begin
  if public.app_locked(staff_key, p_app) then return 'forbidden'; end if;
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

create or replace function public.set_application_progress(staff_key text, p_ids text[], p_status text, p_reviewer text, p_note text)
returns integer language plpgsql security definer set search_path = public
as $$
declare n int; r text; names text; rv text; nt text; single boolean;
begin
  if public.apps_locked(staff_key, p_ids) then return -2; end if;
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

create or replace function public.set_application_status(staff_key text, p_ids text[], p_status text)
returns integer language plpgsql security definer set search_path = public
as $$
declare n int; r text; names text;
begin
  if public.apps_locked(staff_key, p_ids) then return -2; end if;
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

create or replace function public.delete_applications(staff_key text, p_ids text[])
returns integer language plpgsql security definer set search_path = public
as $$
declare n int; r text; names text;
begin
  if public.apps_locked(staff_key, p_ids) then return -2; end if;
  r := public.staff_role(staff_key);
  if r is null then return -1; end if;
  if r <> 'admin' then return -2; end if;
  select string_agg(discord_name, ', ') into names from public.applications where id::text = any(p_ids);
  delete from public.applications where id::text = any(p_ids);
  get diagnostics n = row_count;
  if n > 0 then perform public.log_action(staff_key, 'deleted', n || ' application(s): ' || coalesce(names, '')); end if;
  return n;
end $$;

create or replace function public.app_list(staff_key text, p_status text default 'open', p_limit integer default 15)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'apps_view') then return null; end if;
  return coalesce((select jsonb_agg(to_jsonb(x)) from (
    select left(a.id::text, 8) as short, a.type, a.status, a.discord_name as name, a.created_at as at,
           (select r.display_name from public.chat_roster() r where r.discord_id = a.assigned_id) as assigned
    from public.applications a
    where (a.type <> 'ytmod' or coalesce(public.staff_role(staff_key), '') = 'admin') and case p_status when 'open' then a.status not in ('approved','denied') when 'pending' then a.status = 'pending' when 'all' then true else a.status = p_status end
    order by a.created_at desc limit least(greatest(coalesce(p_limit, 15), 1), 50)) x), '[]'::jsonb);
end $$;

create or replace function public.chat_post_card()
returns trigger language plpgsql security definer set search_path = public
as $$
declare cid bigint;
begin
  if tg_table_name = 'applications' then
    select id into cid from public.chat_channels where sys = case when new.type = 'ytmod' then 'ytmod' else 'applications' end;
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

create or replace function public.chat_post_decision()
returns trigger language plpgsql security definer set search_path = public
as $$
declare cid bigint;
begin
  if new.status in ('approved','denied') and new.status is distinct from old.status and new.type <> 'ytmod' then
    select id into cid from public.chat_channels where sys = new.status;
    if cid is not null then
      insert into public.chat_messages (channel_id, kind, ref_id) values (cid, 'decision', new.id::text || ':' || new.status) on conflict do nothing;
    end if;
  end if;
  return new;
exception when others then return new;
end $$;


-- keep the function permissions the website needs
do $g$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('list_applications','list_application_history','app_applicant_info','chat_application_answers','chat_decide_application','app_claim','app_assign','app_release','set_application_progress','set_application_status','delete_applications','app_list')
  loop execute format('grant execute on function %s to anon, authenticated', f.sig); end loop;
end $g$;
notify pgrst, 'reload schema';
