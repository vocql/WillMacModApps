-- 0009: staff user reports queue + staff notices board. Additive only; access is through the functions below (tables have RLS on and no policies).

create table if not exists public.user_reports (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  reporter_id   text not null,
  reporter_name text not null default 'Staff',
  target_id      text not null,
  target_name    text not null default 'Unknown',
  category      text not null default 'other' check (category in ('spam','harassment','inappropriate','cheating','ban_evasion','other')),
  details       text not null check (char_length(details) between 10 and 2000),
  status        text not null default 'open' check (status in ('open','investigating','resolved','dismissed')),
  assigned_id   text,
  assigned_name text,
  handled_by    text,
  handled_at    timestamptz
);
create index if not exists user_reports_status_idx on public.user_reports (status, created_at desc);
create index if not exists user_reports_target_idx on public.user_reports (target_id);
create table if not exists public.user_report_notes (
  id          bigint generated always as identity primary key,
  report_id   bigint not null references public.user_reports(id) on delete cascade,
  author_id   text not null,
  author_name text not null default 'Staff',
  body        text not null check (char_length(body) between 1 and 1000),
  created_at  timestamptz not null default now()
);
alter table public.user_reports enable row level security;
alter table public.user_report_notes enable row level security;

create table if not exists public.staff_notices (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  title       text not null check (char_length(title) between 1 and 120),
  body        text not null check (char_length(body) between 1 and 3000),
  pinned      boolean not null default false,
  author_id   text,
  author_name text not null default 'Staff'
);
alter table public.staff_notices enable row level security;

create or replace function public.rpt_name(staff_key text)
returns text language sql stable security definer set search_path = public
as $$ select coalesce((select nullif(r.display_name, '') from public.chat_roster() r where r.discord_id = public.chat_actor(staff_key)), public.staff_name(staff_key), 'Staff') $$;

create or replace function public.report_create(staff_key text, p_target_id text, p_category text, p_details text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); t text := trim(coalesce(p_target_id, '')); d text := left(trim(coalesce(p_details, '')), 2000); c text := lower(coalesce(p_category, 'other')); tn text; rid bigint; cid bigint;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if t !~ '^[0-9]{5,25}$' then return jsonb_build_object('error', 'badid'); end if;
  if char_length(d) < 10 then return jsonb_build_object('error', 'short'); end if;
  if c not in ('spam','harassment','inappropriate','cheating','ban_evasion','other') then c := 'other'; end if;
  if (select count(*) from public.user_reports where reporter_id = me and created_at > now() - interval '1 hour') >= 20 then return jsonb_build_object('error', 'ratelimit'); end if;
  select coalesce(nullif(x.display_name, ''), x.username) into tn from public.discord_user(t) x;
  insert into public.user_reports (reporter_id, reporter_name, target_id, target_name, category, details)
    values (me, public.rpt_name(staff_key), t, left(coalesce(tn, 'Unknown user'), 100), c, d) returning id into rid;
  select id into cid from public.chat_channels where slug = 'user-reports';
  if cid is not null then
    insert into public.chat_messages (channel_id, author_id, body) values (cid, me, 'Report #' || rid || ' filed against ' || coalesce(tn, t) || ' (' || replace(c, '_', ' ') || '): ' || left(d, 300));
  end if;
  perform public.log_action(staff_key, 'report filed', '#' || rid || ' about ' || t);
  return jsonb_build_object('ok', true, 'id', rid);
end $$;

create or replace function public.report_list(staff_key text, p_status text default 'all')
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare s text := lower(coalesce(p_status, 'all'));
begin
  if public.chat_actor(staff_key) is null or public.staff_role(staff_key) is null then return null; end if;
  return coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc) from (
    select r.id, r.created_at, r.updated_at, r.reporter_id, r.reporter_name, r.target_id, r.target_name, r.category, left(r.details, 200) as preview, r.status, r.assigned_id, r.assigned_name,
           (select count(*) from public.user_report_notes n where n.report_id = r.id) as notes,
           (select d.avatar from public.discord_user(r.target_id) d) as target_avatar,
           (select count(*) from public.user_reports o where o.target_id = r.target_id) as against
    from public.user_reports r where s = 'all' or r.status = s order by r.created_at desc limit 200) q), '[]'::jsonb);
end $$;

create or replace function public.report_get(staff_key text, p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare r public.user_reports;
begin
  if public.chat_actor(staff_key) is null or public.staff_role(staff_key) is null then return null; end if;
  select * into r from public.user_reports where id = p_id; if not found then return null; end if;
  return to_jsonb(r) || jsonb_build_object('target_avatar', (select d.avatar from public.discord_user(r.target_id) d),
    'state', public.user_state(r.target_id),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'author', n.author_name, 'body', n.body, 'at', n.created_at) order by n.id) from public.user_report_notes n where n.report_id = r.id), '[]'::jsonb));
end $$;

create or replace function public.report_update(staff_key text, p_id bigint, p_status text default null, p_claim boolean default false)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); r public.user_reports; s text := lower(coalesce(p_status, ''));
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'claim') then return jsonb_build_object('error', 'forbidden'); end if;
  select * into r from public.user_reports where id = p_id for update; if not found then return jsonb_build_object('error', 'notfound'); end if;
  if s <> '' and s not in ('open','investigating','resolved','dismissed') then return jsonb_build_object('error', 'badstatus'); end if;
  if p_claim then
    if r.assigned_id is not null and r.assigned_id <> me then return jsonb_build_object('error', 'claimed', 'by', r.assigned_name); end if;
    update public.user_reports set assigned_id = me, assigned_name = public.rpt_name(staff_key), status = case when status = 'open' then 'investigating' else status end, updated_at = now() where id = p_id;
  end if;
  if s <> '' then
    update public.user_reports set status = s, updated_at = now(), handled_by = case when s in ('resolved','dismissed') then public.rpt_name(staff_key) else null end,
      handled_at = case when s in ('resolved','dismissed') then now() else null end where id = p_id;
  end if;
  perform public.log_action(staff_key, 'report update', '#' || p_id || ' ' || coalesce(nullif(s, ''), case when p_claim then 'claimed' else '' end));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.report_note(staff_key text, p_id bigint, p_body text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); b text := left(trim(coalesce(p_body, '')), 1000);
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'note') then return jsonb_build_object('error', 'forbidden'); end if;
  if b = '' then return jsonb_build_object('error', 'empty'); end if;
  if not exists (select 1 from public.user_reports where id = p_id) then return jsonb_build_object('error', 'notfound'); end if;
  insert into public.user_report_notes (report_id, author_id, author_name, body) values (p_id, me, public.rpt_name(staff_key), b);
  update public.user_reports set updated_at = now() where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.notice_list(staff_key text)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
begin
  if public.staff_role(staff_key) is null then return null; end if;
  return coalesce((select jsonb_agg(to_jsonb(n) order by n.pinned desc, n.created_at desc) from (select id, created_at, title, body, pinned, author_id, author_name,
    (select d.avatar from public.discord_user(s.author_id) d) as avatar from public.staff_notices s order by s.pinned desc, s.created_at desc limit 100) n), '[]'::jsonb);
end $$;

create or replace function public.notice_post(staff_key text, p_title text, p_body text, p_pinned boolean default false)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare t text := left(trim(coalesce(p_title, '')), 120); b text := left(trim(coalesce(p_body, '')), 3000); nid bigint;
begin
  if public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'announce') then return jsonb_build_object('error', 'forbidden'); end if;
  if t = '' or b = '' then return jsonb_build_object('error', 'empty'); end if;
  insert into public.staff_notices (title, body, pinned, author_id, author_name) values (t, b, coalesce(p_pinned, false), public.chat_actor(staff_key), public.rpt_name(staff_key)) returning id into nid;
  perform public.log_action(staff_key, 'notice posted', left(t, 100));
  return jsonb_build_object('ok', true, 'id', nid);
end $$;

create or replace function public.notice_manage(staff_key text, p_id bigint, p_action text)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'announce') then return jsonb_build_object('error', 'forbidden'); end if;
  if p_action = 'delete' then delete from public.staff_notices where id = p_id;
  elsif p_action = 'pin' then update public.staff_notices set pinned = true where id = p_id;
  elsif p_action = 'unpin' then update public.staff_notices set pinned = false where id = p_id;
  else return jsonb_build_object('error', 'badaction'); end if;
  perform public.log_action(staff_key, 'notice ' || p_action, '#' || p_id);
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.rpt_name(text) from public, anon, authenticated;
grant execute on function public.report_create(text, text, text, text) to anon, authenticated;
grant execute on function public.report_list(text, text) to anon, authenticated;
grant execute on function public.report_get(text, bigint) to anon, authenticated;
grant execute on function public.report_update(text, bigint, text, boolean) to anon, authenticated;
grant execute on function public.report_note(text, bigint, text) to anon, authenticated;
grant execute on function public.notice_list(text) to anon, authenticated;
grant execute on function public.notice_post(text, text, text, boolean) to anon, authenticated;
grant execute on function public.notice_manage(text, bigint, text) to anon, authenticated;
notify pgrst, 'reload schema';
