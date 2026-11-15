-- =====================================================================================================
-- 0004  Feedback: real Discord name + picture on every message, and a status staff can track
--        (new -> reviewing -> resolved / declined), who handled it, and private staff notes.
-- Safe to run again. Never deletes data. Old feedback keeps its text; it just has no picture until the member sends something new.
-- =====================================================================================================

-- Who sent it (so the dashboard and Staff Chat can show their Discord picture and name) + a status staff can track.
alter table public.feedback add column if not exists discord_id text;
alter table public.feedback add column if not exists avatar     text;
alter table public.feedback add column if not exists status     text not null default 'new';
alter table public.feedback add column if not exists handled_by text;
alter table public.feedback add column if not exists handled_at timestamptz;
alter table public.feedback drop constraint if exists feedback_status_check;
alter table public.feedback add constraint feedback_status_check check (status in ('new','reviewing','resolved','declined'));
create table if not exists public.feedback_notes (
  id          bigint generated always as identity primary key,
  feedback_id bigint not null references public.feedback(id) on delete cascade,
  at          timestamptz not null default now(),
  author      text not null,
  note        text not null check (char_length(note) between 1 and 500)
);
alter table public.feedback_notes enable row level security;
revoke all on public.feedback_notes from anon, authenticated;


-- Members (not staff) submit feedback through these. Banned / timed-out members are refused.
create or replace function public.submit_feedback(p_app_id uuid, p_message text, p_anonymous boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare did text; a public.applications; k text; n int; m text;
begin
  did := public.my_discord_id();
  if did is null then return 'login'; end if;
  if public.user_state(did) <> 'active' then return 'banned'; end if;
  m := left(trim(coalesce(p_message, '')), 1000);
  if char_length(m) < 20 then return 'short'; end if;
  select * into a from public.applications where id = p_app_id and discord_id = did;
  if not found then return 'notfound'; end if;
  if a.status not in ('approved','denied') then return 'notdecided'; end if;
  k := encode(sha256(convert_to(did || ':' || p_app_id::text, 'utf8')), 'hex');
  insert into public.feedback (app_type, outcome, message, anonymous, name, limit_key, discord_id, avatar)
  values (a.type, a.status, m, false, left(coalesce(public.my_discord_name(), a.discord_name), 100), k, did, public.my_discord_avatar())
  on conflict (limit_key) do nothing;
  get diagnostics n = row_count;
  return case when n = 0 then 'duplicate' else 'ok' end;
end $$;

create or replace function public.submit_general_feedback(p_message text, p_anonymous boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare did text; m text; r text; nm text; last_at timestamptz; w int; adm boolean;
begin
  did := public.my_discord_id();
  if did is null then return 'login'; end if;
  if public.user_state(did) <> 'active' then return 'banned'; end if;
  m := left(trim(coalesce(p_message, '')), 1000);
  if char_length(m) < 5 then return 'short'; end if;
  r := encode(sha256(convert_to('gen:' || did, 'utf8')), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(r, 0));   -- two taps / two tabs at once can't both get through
  adm := public.feedback_is_admin(did);
  select max(created_at) into last_at from public.feedback where rl_key = r;
  if not adm and last_at is not null and last_at > now() - interval '5 minutes' then
    w := greatest(1, ceil(extract(epoch from (last_at + interval '5 minutes' - now())))::int);
    return 'wait:' || w;
  end if;
  -- Feedback from the home page always shows the member's name (no anonymous option).
  -- Use the member's real Discord display name + picture (not "Member").
  nm := left(coalesce(public.my_discord_name(), (select a.discord_name from public.applications a where a.discord_id = did order by a.created_at desc limit 1), 'Member'), 100);
  insert into public.feedback (app_type, outcome, message, anonymous, name, limit_key, rl_key, discord_id, avatar)
  values ('general', 'general', m, false, nm,
          encode(sha256(convert_to(did || ':' || clock_timestamp()::text || random()::text, 'utf8')), 'hex'), r, did, public.my_discord_avatar());
  return 'ok';
end $$;

drop function if exists public.list_feedback(text);
create or replace function public.list_feedback(staff_key text)
returns table (id bigint, created_at timestamptz, app_type text, outcome text, message text, anonymous boolean, name text,
               discord_id text, avatar text, status text, handled_by text, handled_at timestamptz, note_count bigint)
language sql stable security definer set search_path = public, auth
as $$
  select f.id, f.created_at, f.app_type, f.outcome, f.message, f.anonymous,
         case when f.anonymous then f.name else coalesce(nullif(d.display_name, ''), nullif(d.username, ''), nullif(trim(f.name), ''), 'Member') end,
         f.discord_id,
         case when f.anonymous then null else coalesce(d.avatar, f.avatar) end,
         f.status, f.handled_by, f.handled_at,
         (select count(*) from public.feedback_notes n where n.feedback_id = f.id)
  from public.feedback f
  left join lateral public.discord_user(f.discord_id) d on not f.anonymous and f.discord_id is not null
  where public.staff_role(staff_key) is not null
  order by f.created_at desc limit 500
$$;

-- Older feedback rows were saved before the Discord id was stored: work it out again from the keys they were saved with.
update public.feedback f set discord_id = a.discord_id
  from public.applications a
  where f.discord_id is null and f.limit_key = encode(sha256(convert_to(a.discord_id || ':' || a.id::text, 'utf8')), 'hex');
update public.feedback f set discord_id = i.provider_id
  from auth.identities i
  where f.discord_id is null and i.provider = 'discord' and f.rl_key = encode(sha256(convert_to('gen:' || i.provider_id, 'utf8')), 'hex');


create or replace function public.chat_feedback_status(staff_key text, p_id bigint, p_status text)
returns text language plpgsql security definer set search_path = public
as $$
begin
  if not public.staff_can(staff_key, 'feedback_manage') then return 'forbidden'; end if;
  if p_status not in ('new','reviewing','resolved','declined') then return 'invalid'; end if;
  update public.feedback set status = p_status, handled_by = case when p_status = 'new' then null else coalesce(public.staff_name(staff_key), '?') end,
         handled_at = case when p_status = 'new' then null else now() end where id = p_id;
  if not found then return 'notfound'; end if;
  perform public.log_action(staff_key, 'feedback ' || p_status, 'feedback #' || p_id);
  return 'ok';
end $$;

create or replace function public.chat_feedback_note(staff_key text, p_id bigint, p_note text)
returns text language plpgsql security definer set search_path = public
as $$
declare nt text := left(trim(coalesce(p_note, '')), 500);
begin
  if not public.staff_can(staff_key, 'feedback_manage') then return 'forbidden'; end if;
  if char_length(nt) < 1 then return 'empty'; end if;
  if not exists (select 1 from public.feedback where id = p_id) then return 'notfound'; end if;
  insert into public.feedback_notes (feedback_id, author, note) values (p_id, coalesce(public.staff_name(staff_key), '?'), nt);
  return 'ok';
end $$;

create or replace function public.chat_feedback_notes(staff_key text, p_id bigint)
returns jsonb language sql stable security definer set search_path = public
as $$
  select case when public.staff_role(staff_key) is null then null else coalesce((select jsonb_agg(jsonb_build_object('at', n.at, 'author', n.author, 'note', n.note) order by n.id)
    from public.feedback_notes n where n.feedback_id = p_id), '[]'::jsonb) end
$$;

grant execute on function public.list_feedback(text) to anon, authenticated;
grant execute on function public.chat_feedback_status(text, bigint, text) to anon, authenticated;
grant execute on function public.chat_feedback_note(text, bigint, text) to anon, authenticated;
grant execute on function public.chat_feedback_notes(text, bigint) to anon, authenticated;
notify pgrst, 'reload schema';
