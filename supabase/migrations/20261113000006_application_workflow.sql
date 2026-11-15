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
