-- 0012 (Updated Discord-style version): Online/Offline presence, new permissions, and reports that need NO login.
-- Additive and idempotent. Tables stay closed (RLS, no policies); everything goes through checked functions.

-- 1) Presence is simply Online or Offline. Online = the dashboard pinged us (heartbeat / chat poll) in the last 60 seconds.
create or replace function public.chat_roster()
returns table (discord_id text, username text, display_name text, avatar text, rank_label text, access text, status text, joined_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select z.id, z.username, z.display_name, z.avatar, z.rank_label, z.access,
         case when z.seen > now() - interval '60 seconds' then 'online' else 'offline' end,
         z.joined
  from (
    select coalesce(p.discord_id, m.discord_id) as id,
           coalesce(d.username, p.username, m.username, '') as username,
           coalesce(nullif(d.display_name, ''), nullif(p.display_name, ''), nullif(m.display_name, ''), p.username, m.username, 'Staff') as display_name,
           coalesce(d.avatar, p.avatar, m.avatar) as avatar,
           coalesce(m.rank_name, case p.access when 'admin' then 'Administrator' when 'reviewer' then 'Lead Moderator' else 'Moderator' end) as rank_label,
           coalesce(p.access, (select o.access from public.staff_overrides o where o.discord_id = coalesce(p.discord_id, m.discord_id)), public.staff_rank_access(m.rank_name)) as access,
           p.last_seen as seen,
           coalesce(m.created_at, p.updated_at) as joined
    from public.staff_profiles p
    full join public.staff_members m on m.discord_id = p.discord_id
    left join lateral public.discord_user(coalesce(p.discord_id, m.discord_id)) d on true
    where (m.discord_id is not null or exists (select 1 from public.staff_sessions s where s.discord_id = p.discord_id and s.expires_at > now()))
      and not exists (select 1 from public.staff_blocked b where b.discord_id = coalesce(p.discord_id, m.discord_id))
      and public.user_state(coalesce(p.discord_id, m.discord_id)) <> 'banned'
  ) z
$$;

-- 2) Permission matrix additions. Helpers / "other staff" get none of these; they can still be invited into a server.
create or replace function public.staff_caps(k text)
returns text[] language plpgsql stable security definer set search_path = public
as $$
declare rl text := public.staff_role(k); me text := public.staff_actor_id(k); caps text[] := '{}'; helper boolean;
begin
  if rl is null then return '{}'; end if;
  helper := rl = 'viewer' and public.staff_is_helper(me);
  caps := array['chat','apps_view'];
  if not helper then caps := caps || array['userinfo','logs','notes_view','warn','note','app_notes','reports_view','reports_update','server_create']; end if;
  if rl in ('reviewer','admin') then caps := caps || array['claim','decide','timeout','pin','slowmode','feedback_manage','mention_staff']; end if;
  if rl = 'admin' then caps := caps || array['ban','assign','announce','lock','clear','apps_toggle','promote','activity','channels','users','staff_manage','mention_everyone','screenshot','reports_manage','servers_admin']; end if;
  if public.is_master(k) or me = '1271246652421701633' then caps := caps || array['owner']; end if;
  return caps;
end $$;

-- 3) Reports: anyone can file one without an account; staff review them on the Reports page.
alter table public.user_reports alter column reporter_id drop not null;
alter table public.user_reports alter column target_id drop not null;
alter table public.user_reports add column if not exists target_label text;
alter table public.user_reports add column if not exists evidence text;
alter table public.user_reports add column if not exists contact text;
alter table public.user_reports add column if not exists where_text text;
alter table public.user_reports add column if not exists source text not null default 'staff';
alter table public.user_reports drop constraint if exists user_reports_status_check;
alter table public.user_reports add constraint user_reports_status_check check (status in ('open','investigating','reviewed','resolved','dismissed'));
alter table public.user_reports drop constraint if exists user_reports_source_check;
alter table public.user_reports add constraint user_reports_source_check check (source in ('staff','public'));
alter table public.user_reports drop constraint if exists user_reports_category_check;
alter table public.user_reports add constraint user_reports_category_check check (category in ('spam','harassment','inappropriate','cheating','ban_evasion','scam','other'));
create index if not exists user_reports_created_idx on public.user_reports (created_at desc);

-- Record of every moderation action on a report (who did what, when). Never editable from the website.
create table if not exists public.report_audit (
  id         bigint generated always as identity primary key,
  report_id  bigint not null references public.user_reports(id) on delete cascade,
  at         timestamptz not null default now(),
  actor_id   text,
  actor_name text not null default 'System',
  action     text not null,
  detail     text
);
create index if not exists report_audit_report on public.report_audit (report_id, at);
alter table public.report_audit enable row level security;
revoke all on public.report_audit from anon, authenticated;

-- Public submission. No login. Honeypot + global rate limit + duplicate guard. Returns only a reference number.
create or replace function public.report_submit(p_target text, p_category text, p_details text,
                                                p_where text default '', p_evidence text default '', p_contact text default '', p_hp text default '')
returns jsonb language plpgsql security definer set search_path = public
as $$
declare t text := left(trim(coalesce(p_target, '')), 100); d text := left(trim(coalesce(p_details, '')), 2000); c text := lower(coalesce(p_category, 'other'));
        tid text; tn text; rid bigint; cid bigint;
begin
  if coalesce(p_hp, '') <> '' then return jsonb_build_object('ok', true, 'ref', 'R-0'); end if;      -- bots fill the hidden field
  if char_length(t) < 2 then return jsonb_build_object('error', 'target'); end if;
  if char_length(d) < 10 then return jsonb_build_object('error', 'short'); end if;
  if c not in ('spam','harassment','inappropriate','cheating','ban_evasion','scam','other') then c := 'other'; end if;
  if (select count(*) from public.user_reports r where r.source = 'public' and r.created_at > now() - interval '10 minutes') >= 40 then return jsonb_build_object('error', 'busy'); end if;
  if exists (select 1 from public.user_reports r where r.source = 'public' and r.details = d and r.created_at > now() - interval '24 hours') then
    return jsonb_build_object('ok', true, 'ref', 'R-dup');                                             -- same text already received
  end if;
  if t ~ '^[0-9]{5,25}$' then tid := t;
  else select u.discord_id into tid from public.discord_users() u where lower(u.username) = lower(t) or lower(u.display_name) = lower(t) limit 1;
  end if;
  if tid is not null then select coalesce(nullif(x.display_name, ''), x.username) into tn from public.discord_user(tid) x; end if;
  insert into public.user_reports (reporter_id, reporter_name, target_id, target_name, target_label, category, details, evidence, contact, where_text, source)
    values (null, 'Anonymous', tid, left(coalesce(tn, t), 100), t, c, d, nullif(left(trim(coalesce(p_evidence, '')), 800), ''), nullif(left(trim(coalesce(p_contact, '')), 100), ''),
            nullif(left(trim(coalesce(p_where, '')), 200), ''), 'public') returning id into rid;
  insert into public.report_audit (report_id, actor_name, action, detail) values (rid, 'Public form', 'submitted', 'No login required');
  select id into cid from public.chat_channels where slug = 'user-reports' and server_id is null;
  if cid is not null then
    insert into public.chat_messages (channel_id, author_id, kind, body) values (cid, null, 'system', 'New anonymous report #' || rid || ' about ' || coalesce(tn, t) || ' (' || replace(c, '_', ' ') || '). Open the Reports page to review it.');
  end if;
  return jsonb_build_object('ok', true, 'ref', 'R-' || rid);
exception when others then return jsonb_build_object('error', 'failed');
end $$;
revoke all on function public.report_submit(text, text, text, text, text, text, text) from public;
grant execute on function public.report_submit(text, text, text, text, text, text, text) to anon, authenticated;

create or replace function public.report_create(staff_key text, p_target_id text, p_category text, p_details text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); t text := trim(coalesce(p_target_id, '')); d text := left(trim(coalesce(p_details, '')), 2000); c text := lower(coalesce(p_category, 'other')); tn text; rid bigint; cid bigint;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'reports_update') then return jsonb_build_object('error', 'forbidden'); end if;
  if t !~ '^[0-9]{5,25}$' then return jsonb_build_object('error', 'badid'); end if;
  if char_length(d) < 10 then return jsonb_build_object('error', 'short'); end if;
  if c not in ('spam','harassment','inappropriate','cheating','ban_evasion','scam','other') then c := 'other'; end if;
  if (select count(*) from public.user_reports where reporter_id = me and created_at > now() - interval '1 hour') >= 20 then return jsonb_build_object('error', 'ratelimit'); end if;
  select coalesce(nullif(x.display_name, ''), x.username) into tn from public.discord_user(t) x;
  insert into public.user_reports (reporter_id, reporter_name, target_id, target_name, target_label, category, details, source)
    values (me, public.rpt_name(staff_key), t, left(coalesce(tn, 'Unknown user'), 100), t, c, d, 'staff') returning id into rid;
  insert into public.report_audit (report_id, actor_id, actor_name, action, detail) values (rid, me, public.rpt_name(staff_key), 'submitted', 'Filed by staff');
  select id into cid from public.chat_channels where slug = 'user-reports' and server_id is null;
  if cid is not null then
    insert into public.chat_messages (channel_id, author_id, body) values (cid, me, 'Report #' || rid || ' filed against ' || coalesce(tn, t) || ' (' || replace(c, '_', ' ') || '): ' || left(d, 300));
  end if;
  perform public.log_action(staff_key, 'report filed', '#' || rid || ' about ' || t);
  return jsonb_build_object('ok', true, 'id', rid);
end $$;

create or replace function public.report_list(staff_key text, p_status text default 'all', p_q text default '')
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare s text := lower(coalesce(p_status, 'all')); q text := lower(trim(coalesce(p_q, '')));
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'reports_view') then return null; end if;
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
    select r.id, r.created_at, r.updated_at, r.source, r.reporter_name, r.target_id, coalesce(r.target_name, r.target_label) as target_name, r.target_label, r.category,
           left(r.details, 200) as preview, r.status, r.assigned_id, r.assigned_name,
           (select count(*) from public.user_report_notes n where n.report_id = r.id) as notes,
           (select d.avatar from public.discord_user(r.target_id) d) as target_avatar,
           case when r.target_id is null then 'unknown' else public.user_state(r.target_id) end as state,
           (select count(*) from public.user_reports o where o.target_id is not null and o.target_id = r.target_id) as against
    from public.user_reports r
    where (s = 'all' or r.status = s)
      and (q = '' or lower(coalesce(r.target_name, '')) like '%' || q || '%' or lower(coalesce(r.target_label, '')) like '%' || q || '%' or r.target_id = q or r.id::text = q)
    order by r.created_at desc limit 300) x), '[]'::jsonb);
end $$;

create or replace function public.report_get(staff_key text, p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare r public.user_reports;
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'reports_view') then return null; end if;
  select * into r from public.user_reports where id = p_id; if not found then return null; end if;
  return to_jsonb(r) - 'reporter_id' || jsonb_build_object('target_avatar', (select d.avatar from public.discord_user(r.target_id) d),
    'state', case when r.target_id is null then 'unknown' else public.user_state(r.target_id) end,
    'against', (select count(*) from public.user_reports o where o.target_id is not null and o.target_id = r.target_id),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'author', n.author_name, 'body', n.body, 'at', n.created_at) order by n.id) from public.user_report_notes n where n.report_id = r.id), '[]'::jsonb),
    'audit', coalesce((select jsonb_agg(jsonb_build_object('actor', a.actor_name, 'action', a.action, 'detail', a.detail, 'at', a.at) order by a.id) from public.report_audit a where a.report_id = r.id), '[]'::jsonb));
end $$;

create or replace function public.report_update(staff_key text, p_id bigint, p_status text default null, p_claim boolean default false)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); r public.user_reports; s text := lower(coalesce(p_status, '')); nm text;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'reports_update') then return jsonb_build_object('error', 'forbidden'); end if;
  select * into r from public.user_reports where id = p_id for update; if not found then return jsonb_build_object('error', 'notfound'); end if;
  if s <> '' and s not in ('open','investigating','reviewed','resolved','dismissed') then return jsonb_build_object('error', 'badstatus'); end if;
  nm := public.rpt_name(staff_key);
  if p_claim then
    if r.assigned_id is not null and r.assigned_id <> me and not public.staff_can(staff_key, 'reports_manage') then return jsonb_build_object('error', 'claimed', 'by', r.assigned_name); end if;
    update public.user_reports set assigned_id = me, assigned_name = nm, status = case when status = 'open' then 'investigating' else status end, updated_at = now() where id = p_id;
    insert into public.report_audit (report_id, actor_id, actor_name, action, detail) values (p_id, me, nm, 'claimed', null);
  end if;
  if s <> '' and s <> r.status then
    update public.user_reports set status = s, updated_at = now(), handled_by = case when s in ('reviewed','resolved','dismissed') then nm else null end,
      handled_at = case when s in ('reviewed','resolved','dismissed') then now() else null end where id = p_id;
    insert into public.report_audit (report_id, actor_id, actor_name, action, detail) values (p_id, me, nm, 'status', r.status || ' → ' || s);
  end if;
  perform public.log_action(staff_key, 'report update', '#' || p_id || ' ' || coalesce(nullif(s, ''), case when p_claim then 'claimed' else '' end));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.report_note(staff_key text, p_id bigint, p_body text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); b text := left(trim(coalesce(p_body, '')), 1000); nm text;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'reports_update') then return jsonb_build_object('error', 'forbidden'); end if;
  if b = '' then return jsonb_build_object('error', 'empty'); end if;
  if not exists (select 1 from public.user_reports where id = p_id) then return jsonb_build_object('error', 'notfound'); end if;
  nm := public.rpt_name(staff_key);
  insert into public.user_report_notes (report_id, author_id, author_name, body) values (p_id, me, nm, b);
  insert into public.report_audit (report_id, actor_id, actor_name, action, detail) values (p_id, me, nm, 'note added', null);
  update public.user_reports set updated_at = now() where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.report_delete(staff_key text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if public.chat_actor(staff_key) is null or not public.staff_can(staff_key, 'reports_manage') then return jsonb_build_object('error', 'forbidden'); end if;
  delete from public.user_reports where id = p_id;
  perform public.log_action(staff_key, 'report deleted', '#' || p_id);
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.report_create(text, text, text, text), public.report_list(text, text, text), public.report_get(text, bigint),
  public.report_update(text, bigint, text, boolean), public.report_note(text, bigint, text), public.report_delete(text, bigint) from public;
grant execute on function public.report_create(text, text, text, text), public.report_list(text, text, text), public.report_get(text, bigint),
  public.report_update(text, bigint, text, boolean), public.report_note(text, bigint, text), public.report_delete(text, bigint) to anon, authenticated;
drop function if exists public.report_list(text, text);

-- 4) Background pulse: keeps you "online" and tells the dashboard how many unread messages you have, from any page (badges + desktop alerts).
create or replace function public.staff_pulse(staff_key text, p_away boolean default false)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); ch int; mn int; dm int;
begin
  if me is null or rl is null then return null; end if;
  insert into public.staff_profiles (discord_id, username, display_name, access, last_seen)
    select s.discord_id, s.name, s.name, s.role, now() from public.staff_sessions s where s.key_hash = public.code_hash(staff_key)
  on conflict (discord_id) do nothing;
  update public.staff_profiles set last_seen = now(), away = false where discord_id = me;
  select coalesce(sum(x.n), 0), coalesce(sum(x.mn), 0) into ch, mn from (
    select (select count(*) from public.chat_messages m where m.channel_id = c.id and m.thread_id is null and not m.deleted and m.author_id is distinct from me and m.id > coalesce(rd.last_id, 0)) as n,
           (select count(*) from public.chat_messages m where m.channel_id = c.id and m.thread_id is null and not m.deleted and (me = any(m.mentions) or m.mention_all) and m.author_id is distinct from me and m.id > coalesce(rd.last_id, 0)) as mn
    from public.chat_channels c left join public.chat_reads rd on rd.discord_id = me and rd.scope = 'c:' || c.id
    where public.chat_chan_ok(me, rl, c) and not exists (select 1 from public.chat_mutes mu where mu.discord_id = me and mu.scope = 'c:' || c.id)) x;
  select coalesce(sum(g.n), 0) into dm from (
    select count(*) filter (where not m2.deleted and m2.author_id is distinct from me and m2.id > coalesce((select rd.last_id from public.chat_reads rd where rd.discord_id = me and rd.scope = 'd:' || (case when split_part(m2.dm_key, ':', 1) = me then split_part(m2.dm_key, ':', 2) else split_part(m2.dm_key, ':', 1) end)), 0)
           and not exists (select 1 from public.chat_mutes mu where mu.discord_id = me and mu.scope = 'd:' || (case when split_part(m2.dm_key, ':', 1) = me then split_part(m2.dm_key, ':', 2) else split_part(m2.dm_key, ':', 1) end))) as n
    from public.chat_messages m2 where m2.thread_id is null and (m2.dm_key like me || ':%' or m2.dm_key like '%:' || me)
    group by m2.dm_key) g;
  return jsonb_build_object('chat', ch, 'mentions', mn, 'dms', dm);
end $$;
revoke all on function public.staff_pulse(text, boolean) from public;
grant execute on function public.staff_pulse(text, boolean) to anon, authenticated;
