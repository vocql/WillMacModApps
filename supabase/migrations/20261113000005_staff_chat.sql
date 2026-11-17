-- =====================================================================================================
-- 0005  Staff Chat: categorised channels with stored info panels, DMs, replies, threads, reactions, pins,
--        mentions, slow mode, locked channels, mutes, away status, read receipts, file attachments, polls, search.
-- Privacy: every table is closed to the website (RLS on, no grants). The website can only call the functions below,
-- and each function checks the staff session itself. Attachments live in the database behind those functions
-- (there is no public URL for anything). Safe to run again. Never deletes data.
-- =====================================================================================================

alter table public.applications add column if not exists assigned_id text;
alter table public.applications add column if not exists claimed_at timestamptz;
alter table public.staff_profiles add column if not exists notify text not null default 'all';
alter table public.staff_profiles add column if not exists manual_away boolean not null default false;
alter table public.staff_profiles drop constraint if exists staff_profiles_notify_check;
alter table public.staff_profiles add constraint staff_profiles_notify_check check (notify in ('all','mentions','none'));

create table if not exists public.chat_channels (
  id         bigserial primary key,
  slug       text not null unique check (slug ~ '^[a-z0-9-]{1,30}$'),
  category   text not null default 'GENERAL STAFF' check (char_length(category) between 1 and 40),
  topic      text not null default '' check (char_length(topic) <= 200),
  min_access text not null default 'viewer' check (min_access in ('viewer','reviewer','admin')),
  post_min   text not null default 'viewer' check (post_min in ('viewer','reviewer','admin')),
  no_helpers boolean not null default false,
  sys        text unique check (sys in ('applications','feedback','approved','denied','modlog','announcements')),
  locked     boolean not null default false,
  slow_mode  int not null default 0 check (slow_mode between 0 and 3600),
  info       jsonb not null default '{}'::jsonb,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
alter table public.chat_channels enable row level security;
revoke all on public.chat_channels from anon, authenticated;

-- Default channels + their information panels (kept in the database, editable by administrators in the chat).
insert into public.chat_channels (slug, category, topic, min_access, post_min, no_helpers, sys, sort_order, info) values
 ('staff-chat','GENERAL STAFF','General staff discussions and everyday communication.','viewer','viewer',false,null,10,
  '{"purpose":"Day-to-day conversation for the whole staff team.","belongs":["Everyday questions and quick coordination","Welcoming new staff","Friendly team chat"],"staff_use":["Ask for a second opinion","Say when you are away or back","Share quick tips"],"instructions":["Be professional and kind","Keep serious moderation cases in #moderation","Never share private member information outside staff channels"]}'),
 ('staff-announcements','GENERAL STAFF','Important announcements from administrators.','viewer','admin',false,'announcements',20,
  '{"purpose":"Official announcements from the administrators.","belongs":["Rule or policy changes","Schedule and event notices","Anything every staff member must read"],"staff_use":["Read every announcement","React with a check mark so admins know it was seen"],"instructions":["Only administrators can post here","Ask questions in #staff-chat, not here"]}'),
 ('staff-updates','GENERAL STAFF','Website updates, changes, and new features.','viewer','admin',false,null,30,
  '{"purpose":"What changed on the Will Mac website and dashboard.","belongs":["New features and fixes","Maintenance notices","Changes to how staff tools work"],"staff_use":["Stay current with new tools","Report problems in #staff-chat"],"instructions":["Only administrators post updates","Use /help to see the staff commands"]}'),
 ('applications','APPLICATION MANAGEMENT','New applications appear here for staff review.','viewer','viewer',false,'applications',40,
  '{"purpose":"Every new application and appeal arrives here automatically as a card.","belongs":["Application cards (posted by the website)","Short notes about a card"],"staff_use":["Claim an application before reviewing it","Approve or deny from the card (Senior Moderators and up)","Add a private review note"],"instructions":["Claim first so two people do not review the same application","Never decide an appeal about a punishment you issued","Longer discussion goes in #application-reviews"]}'),
 ('application-reviews','APPLICATION MANAGEMENT','Staff discussions about applicants.','viewer','viewer',true,null,50,
  '{"purpose":"Talk about applicants and decide together.","belongs":["Opinions on an application","Questions about an applicant","Anything that helps a fair decision"],"staff_use":["Link the application with its short ID","Share what you checked"],"instructions":["Keep it fair and respectful","Applicant details stay in staff channels","Moderators and above only"]}'),
 ('approved-applications','APPLICATION MANAGEMENT','Applications that have been approved.','viewer','admin',false,'approved',60,
  '{"purpose":"An automatic record of approved applications.","belongs":["Approval cards posted by the website"],"staff_use":["See who was approved, by whom and when"],"instructions":["Read only. Cards are posted automatically"]}'),
 ('denied-applications','APPLICATION MANAGEMENT','Applications that have been denied.','viewer','admin',false,'denied',70,
  '{"purpose":"An automatic record of denied applications.","belongs":["Denial cards posted by the website"],"staff_use":["See who was denied, by whom, and the reason given"],"instructions":["Read only. Cards are posted automatically"]}'),
 ('moderation','MODERATION','General moderation discussions.','viewer','viewer',true,null,80,
  '{"purpose":"Discuss moderation situations and ask for help.","belongs":["Cases you are unsure about","Evidence and context","Coordinating who handles what"],"staff_use":["Ask before a big action","Hand over cases clearly"],"instructions":["Do not share member private information outside staff channels","Use the moderation commands so every action is logged","Moderators and above only"]}'),
 ('mod-logs','MODERATION','Automatic records of moderation actions.','viewer','admin',true,'modlog',90,
  '{"purpose":"Every ban, timeout, warning and note is recorded here automatically.","belongs":["Moderation log cards posted by the website"],"staff_use":["Check what was done before acting again","Search with /history"],"instructions":["Read only. Cards are posted automatically","Moderators and above only"]}'),
 ('user-reports','MODERATION','Reports involving members.','viewer','viewer',false,null,100,
  '{"purpose":"Collect reports about members for staff to look at.","belongs":["A short description of the report","Message links and screenshots","The member''s Discord ID"],"staff_use":["Say when you take a report","Update the thread when it is handled"],"instructions":["Add evidence, not opinions","Never confront the reported member in chat"]}'),
 ('staff-notes','MODERATION','Internal staff notes and relevant information.','viewer','viewer',true,null,110,
  '{"purpose":"Internal notes that help staff stay consistent.","belongs":["Context about repeat issues","Reminders for the team","Anything staff should know later"],"staff_use":["Keep notes short and factual","Use /note to attach a note to a member"],"instructions":["Private to staff. Moderators and above only"]}'),
 ('feedback','COMMUNITY FEEDBACK','Feedback submitted through the website.','viewer','viewer',false,'feedback',120,
  '{"purpose":"Messages and result reviews from members arrive here automatically.","belongs":["Feedback cards posted by the website"],"staff_use":["Mark feedback Reviewing, Resolved or Declined (Senior Moderators and up)","Add an internal note"],"instructions":["Be honest and fair when replying","Never shame the person who wrote it"]}'),
 ('suggestions','COMMUNITY FEEDBACK','Suggestions for improving the community or website.','viewer','viewer',false,null,130,
  '{"purpose":"Ideas for making the community and the website better.","belongs":["One idea per message","Why it would help"],"staff_use":["React to show support","Discuss in a thread"],"instructions":["Keep it constructive","Admins will move good ideas forward"]}')
on conflict (slug) do nothing;

create table if not exists public.chat_messages (
  id         bigserial primary key,
  channel_id bigint references public.chat_channels(id) on delete cascade,
  dm_key     text,
  author_id  text,
  body       text not null default '' check (char_length(body) <= 2000),
  reply_to   bigint references public.chat_messages(id) on delete set null,
  thread_id  bigint references public.chat_messages(id) on delete cascade,
  kind       text not null default 'user' check (kind in ('user','announcement','application','decision','feedback','modlog','poll','system')),
  ref_id     text,
  poll       jsonb,
  mentions   text[] not null default '{}',
  mention_all boolean not null default false,
  pinned     boolean not null default false,
  pinned_by  text,
  edited_at  timestamptz,
  deleted    boolean not null default false,
  created_at timestamptz not null default now(),
  check ((channel_id is not null) <> (dm_key is not null))
);
create index if not exists chat_messages_channel on public.chat_messages (channel_id, id);
create index if not exists chat_messages_dm on public.chat_messages (dm_key, id);
create index if not exists chat_messages_thread on public.chat_messages (thread_id) where thread_id is not null;
create unique index if not exists chat_messages_ref on public.chat_messages (kind, ref_id) where ref_id is not null;
alter table public.chat_messages enable row level security;
revoke all on public.chat_messages from anon, authenticated;

create table if not exists public.chat_attachments (
  id         bigserial primary key,
  message_id bigint not null references public.chat_messages(id) on delete cascade,
  name       text not null default 'file',
  mime       text not null check (mime in ('image/png','image/jpeg','image/webp','image/gif','application/pdf','text/plain','text/csv','application/zip','application/vnd.openxmlformats-officedocument.wordprocessingml.document')),
  size       int  not null default 0,
  data       text not null check (char_length(data) <= 2000000),
  created_at timestamptz not null default now()
);
create index if not exists chat_attachments_msg on public.chat_attachments (message_id);
alter table public.chat_attachments enable row level security;
revoke all on public.chat_attachments from anon, authenticated;

create table if not exists public.chat_reactions (
  message_id bigint not null references public.chat_messages(id) on delete cascade,
  discord_id text not null,
  emoji      text not null check (char_length(emoji) between 1 and 16),
  primary key (message_id, discord_id, emoji)
);
alter table public.chat_reactions enable row level security;
revoke all on public.chat_reactions from anon, authenticated;

create table if not exists public.chat_reads (
  discord_id text not null,
  scope      text not null,
  last_id    bigint not null default 0,
  primary key (discord_id, scope)
);
alter table public.chat_reads enable row level security;
revoke all on public.chat_reads from anon, authenticated;

create table if not exists public.chat_mutes (
  discord_id text not null,
  scope      text not null,
  primary key (discord_id, scope)
);
alter table public.chat_mutes enable row level security;
revoke all on public.chat_mutes from anon, authenticated;

create table if not exists public.chat_typing (
  discord_id text not null,
  scope      text not null,
  until_at   timestamptz not null,
  primary key (discord_id, scope)
);
alter table public.chat_typing enable row level security;
revoke all on public.chat_typing from anon, authenticated;

create table if not exists public.chat_poll_votes (
  message_id bigint not null references public.chat_messages(id) on delete cascade,
  discord_id text not null,
  opt        int  not null check (opt between 0 and 5),
  primary key (message_id, discord_id)
);
alter table public.chat_poll_votes enable row level security;
revoke all on public.chat_poll_votes from anon, authenticated;

-- ---------- identity, roster, access ----------
-- Chat identity = the real Discord account behind a live Discord staff session. Backup codes can't use chat.
create or replace function public.chat_actor(k text)
returns text language sql stable security definer set search_path = public
as $$ select s.discord_id from public.staff_sessions s where s.key_hash = public.code_hash(k) and s.expires_at > now() $$;

create or replace function public.chat_helper(me text, rl text)
returns boolean language sql stable security definer set search_path = public
as $$ select rl = 'viewer' and public.staff_is_helper(me) $$;

create or replace function public.chat_chan_ok(me text, rl text, c public.chat_channels)
returns boolean language sql stable security definer set search_path = public
as $$ select public.acc_rank(rl) >= public.acc_rank(c.min_access) and (not c.no_helpers or not public.chat_helper(me, rl)) $$;

-- Everyone on the staff team right now, with presence (online / away / offline).
create or replace function public.chat_roster()
returns table (discord_id text, username text, display_name text, avatar text, rank_label text, access text, status text, joined_at timestamptz)
language sql stable security definer set search_path = public
as $$
  select z.id, z.username, z.display_name, z.avatar, z.rank_label, z.access,
         case when z.seen > now() - interval '45 seconds' then (case when z.away or z.manual_away then 'away' else 'online' end)
              when z.seen > now() - interval '5 minutes' then 'away' else 'offline' end,
         z.joined
  from (
    select coalesce(p.discord_id, m.discord_id) as id,
           coalesce(d.username, p.username, m.username, '') as username,
           coalesce(nullif(d.display_name, ''), nullif(p.display_name, ''), nullif(m.display_name, ''), p.username, m.username, 'Staff') as display_name,
           coalesce(d.avatar, p.avatar, m.avatar) as avatar,
           coalesce(m.rank_name, case p.access when 'admin' then 'Administrator' when 'reviewer' then 'Lead Moderator' else 'Moderator' end) as rank_label,
           coalesce(p.access, (select o.access from public.staff_overrides o where o.discord_id = coalesce(p.discord_id, m.discord_id)), public.staff_rank_access(m.rank_name)) as access,
           p.last_seen as seen, coalesce(p.away, false) as away, coalesce(p.manual_away, false) as manual_away,
           coalesce(m.created_at, p.updated_at) as joined
    from public.staff_profiles p
    full join public.staff_members m on m.discord_id = p.discord_id
    left join lateral public.discord_user(coalesce(p.discord_id, m.discord_id)) d on true
    where (m.discord_id is not null or exists (select 1 from public.staff_sessions s where s.discord_id = p.discord_id and s.expires_at > now()))
      and not exists (select 1 from public.staff_blocked b where b.discord_id = coalesce(p.discord_id, m.discord_id))
      and public.user_state(coalesce(p.discord_id, m.discord_id)) <> 'banned'
  ) z
$$;

-- Which conversation is this ("c:<channel id>" or "d:<discord id>") and may I use it?
create or replace function public.chat_resolve(me text, rl text, p_scope text, need_post boolean, out channel_id bigint, out dm_key text, out ok boolean)
language plpgsql stable security definer set search_path = public
as $$
declare c public.chat_channels; other text;
begin
  ok := false;
  if p_scope like 'c:%' and substr(p_scope, 3) ~ '^[0-9]{1,18}$' then
    select * into c from public.chat_channels where id = substr(p_scope, 3)::bigint;
    if found and public.chat_chan_ok(me, rl, c) and (not need_post or public.acc_rank(rl) >= public.acc_rank(c.post_min)) then
      channel_id := c.id; ok := true;
    end if;
  elsif p_scope like 'd:%' then
    other := substr(p_scope, 3);
    if other ~ '^[0-9]{5,25}$' and other <> me and exists (select 1 from public.chat_roster() r where r.discord_id = other) then
      dm_key := least(me, other) || ':' || greatest(me, other); ok := true;
    end if;
  end if;
end $$;

create or replace function public.chat_can_see(me text, rl text, m public.chat_messages)
returns boolean language sql stable security definer set search_path = public
as $$
  select case when m.channel_id is not null then exists (select 1 from public.chat_channels c where c.id = m.channel_id and public.chat_chan_ok(me, rl, c))
              else (split_part(m.dm_key, ':', 1) = me or split_part(m.dm_key, ':', 2) = me) end
$$;

-- Messages as JSON (newest N, older than before_id, one thread, or specific ids). Files are fetched separately so polling stays light.
create or replace function public.chat_msgs_json(me text, p_channel bigint, p_dm text, p_limit integer, p_before bigint, p_thread bigint default null, p_ids bigint[] default null)
returns jsonb language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]'::jsonb) from (
    select m.id, m.author_id, case when m.deleted then '' else m.body end as body, m.reply_to, m.thread_id, m.kind, m.ref_id, m.mentions, m.mention_all, m.pinned, m.edited_at, m.deleted, m.created_at,
      (select jsonb_agg(jsonb_build_object('id', a.id, 'mime', a.mime, 'name', a.name, 'size', a.size) order by a.id) from public.chat_attachments a where a.message_id = m.id) as attachments,
      (select jsonb_agg(jsonb_build_object('emoji', q.emoji, 'users', q.us) order by q.emoji) from
         (select r.emoji, jsonb_agg(r.discord_id) as us from public.chat_reactions r where r.message_id = m.id group by r.emoji) q) as reactions,
      (select jsonb_build_object('id', rm.id, 'author_id', rm.author_id, 'body', left(rm.body, 120), 'deleted', rm.deleted) from public.chat_messages rm where rm.id = m.reply_to) as reply,
      (select count(*) from public.chat_messages t where t.thread_id = m.id and not t.deleted) as thread_count,
      case when m.kind = 'poll' then jsonb_build_object('options', m.poll->'options',
         'counts', coalesce((select jsonb_object_agg(v.opt::text, v.c) from (select pv.opt, count(*) as c from public.chat_poll_votes pv where pv.message_id = m.id group by pv.opt) v), '{}'::jsonb),
         'mine', (select pv.opt from public.chat_poll_votes pv where pv.message_id = m.id and pv.discord_id = me)) end as poll_data,
      case m.kind
        when 'application' then (select jsonb_build_object('id', a.id, 'type', a.type, 'name', a.discord_name, 'discord_id', a.discord_id,
              'username', d.username, 'display_name', d.display_name, 'avatar', coalesce(d.avatar, a.avatar), 'created_at', a.created_at,
              'status', a.status, 'reviewer', a.reviewer, 'assigned_id', a.assigned_id, 'note', a.status_note, 'status_at', a.status_at)
            from public.applications a left join lateral public.discord_user(a.discord_id) d on true where a.id::text = m.ref_id)
        when 'decision' then (select jsonb_build_object('id', a.id, 'type', a.type, 'name', a.discord_name, 'discord_id', a.discord_id,
              'username', d.username, 'display_name', d.display_name, 'avatar', coalesce(d.avatar, a.avatar), 'created_at', a.created_at,
              'status', a.status, 'reviewer', a.reviewer, 'note', a.status_note, 'status_at', a.status_at)
            from public.applications a left join lateral public.discord_user(a.discord_id) d on true where a.id::text = split_part(m.ref_id, ':', 1))
        when 'feedback' then (select jsonb_build_object('id', f.id, 'name', f.name, 'discord_id', f.discord_id, 'username', d.username, 'avatar', coalesce(d.avatar, f.avatar),
              'outcome', f.outcome, 'app_type', f.app_type, 'message', f.message, 'created_at', f.created_at, 'status', f.status, 'handled_by', f.handled_by, 'handled_at', f.handled_at,
              'note_count', (select count(*) from public.feedback_notes n where n.feedback_id = f.id))
            from public.feedback f left join lateral public.discord_user(f.discord_id) d on true where f.id::text = m.ref_id)
        when 'modlog' then (select jsonb_build_object('id', l.id, 'at', l.at, 'actor', l.actor, 'action', l.action, 'target_id', l.target_id, 'target_name', l.target_name,
              'avatar', (select d.avatar from public.discord_user(l.target_id) d), 'reason', l.reason, 'detail', l.detail)
            from public.moderation_log l where l.id::text = m.ref_id)
      end as card
    from public.chat_messages m
    where case when p_ids is not null then m.id = any(p_ids)
               when p_thread is not null then m.thread_id = p_thread
               else ((p_channel is not null and m.channel_id = p_channel) or (p_dm is not null and m.dm_key = p_dm)) and m.thread_id is null end
      and (p_before is null or m.id < p_before)
    order by m.id desc limit least(greatest(coalesce(p_limit, 60), 1), 200)
  ) x
$$;

-- One call does everything the chat screen needs: channels + unread, DMs + unread, who is online, the open conversation, pins, typing, read receipts.
create or replace function public.chat_poll(staff_key text, p_scope text default '', p_away boolean default false, p_read boolean default true, p_limit integer default 60)
returns jsonb language plpgsql security definer set search_path = public
as $$
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
        canpost := public.acc_rank(rl) >= public.acc_rank(ch.post_min) and (not ch.locked or public.staff_can(staff_key, 'lock'));
      else
        canpost := true;
        select r.last_id into oread from public.chat_reads r where r.discord_id = substr(p_scope, 3) and r.scope = 'd:' || me;
      end if;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'slug', c.slug, 'category', c.category, 'topic', c.topic, 'sys', c.sys, 'min_access', c.min_access, 'post_min', c.post_min,
      'no_helpers', c.no_helpers, 'locked', c.locked, 'slow_mode', c.slow_mode, 'info', c.info,
      'can_post', public.acc_rank(rl) >= public.acc_rank(c.post_min) and (not c.locked or public.staff_can(staff_key, 'lock')),
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
end $$;

create or replace function public.chat_older(staff_key text, p_scope text, p_before bigint, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record;
begin
  if me is null or rl is null then return null; end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, false);
  if not coalesce(sc.ok, false) then return null; end if;
  return public.chat_msgs_json(me, sc.channel_id, sc.dm_key, p_limit, p_before);
end $$;

-- The replies in one message's thread (plus the message itself).
create or replace function public.chat_thread(staff_key text, p_root bigint)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages;
begin
  if me is null or rl is null then return null; end if;
  select * into m from public.chat_messages where id = p_root;
  if not found or m.thread_id is not null or not public.chat_can_see(me, rl, m) then return null; end if;
  return jsonb_build_object('root', (public.chat_msgs_json(me, null, null, 1, null, null, array[p_root]))->0, 'replies', public.chat_msgs_json(me, null, null, 200, null, p_root));
end $$;

-- Send a message. Files are checked here (type, size, encoding), never trusted from the website.
create or replace function public.chat_send(staff_key text, p_scope text, p_body text, p_reply_to bigint default null, p_files jsonb default '[]'::jsonb, p_mentions text[] default '{}', p_thread bigint default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record; b text := left(trim(coalesce(p_body, '')), 2000);
        mid bigint; f jsonb; n int := 0; mm text[]; rep public.chat_messages; ch public.chat_channels; last_at timestamptz; everyone boolean := false; staffall boolean := false;
        allowed text[] := array['image/png','image/jpeg','image/webp','image/gif','application/pdf','text/plain','text/csv','application/zip','application/vnd.openxmlformats-officedocument.wordprocessingml.document'];
        mime text; nm text; th public.chat_messages;
begin
  if me is null or rl is null then return jsonb_build_object('error', 'login'); end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, true);
  if not coalesce(sc.ok, false) then return jsonb_build_object('error', 'forbidden'); end if;
  if sc.channel_id is not null then
    select * into ch from public.chat_channels where id = sc.channel_id;
    if ch.locked and not public.staff_can(staff_key, 'lock') then return jsonb_build_object('error', 'locked'); end if;
    if ch.slow_mode > 0 and not public.staff_can(staff_key, 'slowmode') then
      select max(created_at) into last_at from public.chat_messages where channel_id = sc.channel_id and author_id = me and kind in ('user','poll');
      if last_at is not null and last_at > now() - make_interval(secs => ch.slow_mode) then
        return jsonb_build_object('error', 'slowmode', 'wait', ceil(extract(epoch from (last_at + make_interval(secs => ch.slow_mode) - now())))::int);
      end if;
    end if;
  end if;
  if p_files is null or jsonb_typeof(p_files) <> 'array' then p_files := '[]'::jsonb; end if;
  if jsonb_array_length(p_files) > 4 then return jsonb_build_object('error', 'too_many_files'); end if;
  if b = '' and jsonb_array_length(p_files) = 0 then return jsonb_build_object('error', 'empty'); end if;
  if (select count(*) from public.chat_messages where author_id = me and created_at > now() - interval '10 seconds') >= 15 then return jsonb_build_object('error', 'rate'); end if;
  for f in select jsonb_array_elements(p_files) loop
    mime := substring(f->>'data' from '^data:([a-z0-9/+.-]+);base64,');
    if jsonb_typeof(f) <> 'object' or mime is null or not (mime = any(allowed)) or char_length(coalesce(f->>'data', '')) > 2000000
       or (f->>'data') !~ '^data:[a-z0-9/+.-]+;base64,[A-Za-z0-9+/]+={0,2}$' then return jsonb_build_object('error', 'bad_file'); end if;
  end loop;
  if p_reply_to is not null then
    select * into rep from public.chat_messages where id = p_reply_to;
    if not found or not public.chat_can_see(me, rl, rep) or rep.channel_id is distinct from sc.channel_id or rep.dm_key is distinct from sc.dm_key then p_reply_to := null; end if;
  end if;
  if p_thread is not null then
    select * into th from public.chat_messages where id = p_thread;
    if not found or th.thread_id is not null or th.deleted or th.channel_id is distinct from sc.channel_id or th.dm_key is distinct from sc.dm_key then return jsonb_build_object('error', 'bad_thread'); end if;
  end if;
  -- @everyone needs Administrator, @staff needs Senior Moderator. Anyone else's token is ignored. Individual mentions are always allowed.
  everyone := 'everyone' = any(coalesce(p_mentions, '{}')) and public.staff_can(staff_key, 'mention_everyone');
  staffall := 'staff' = any(coalesce(p_mentions, '{}')) and public.staff_can(staff_key, 'mention_staff');
  select coalesce(array_agg(distinct r.discord_id), '{}') into mm from public.chat_roster() r where everyone or staffall or r.discord_id = any(coalesce(p_mentions, '{}'));
  insert into public.chat_messages (channel_id, dm_key, author_id, body, reply_to, thread_id, mentions, mention_all, kind)
  values (sc.channel_id, sc.dm_key, me, b, p_reply_to, p_thread, mm, everyone, case when sc.channel_id is not null and (select sys from public.chat_channels where id = sc.channel_id) = 'announcements' then 'announcement' else 'user' end)
  returning id into mid;
  for f in select jsonb_array_elements(p_files) loop
    nm := left(regexp_replace(coalesce(nullif(trim(f->>'name'), ''), 'file'), '[^A-Za-z0-9._ -]', '_', 'g'), 100);
    insert into public.chat_attachments (message_id, name, mime, size, data)
    values (mid, nm, substring(f->>'data' from '^data:([a-z0-9/+.-]+);base64,'), (char_length(f->>'data') * 3 / 4)::int, f->>'data');
  end loop;
  delete from public.chat_typing where discord_id = me;
  return jsonb_build_object('ok', true, 'id', mid);
end $$;

create or replace function public.chat_edit(staff_key text, p_id bigint, p_body text)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); b text := left(trim(coalesce(p_body, '')), 2000); m public.chat_messages;
begin
  if me is null or public.staff_role(staff_key) is null then return 'login'; end if;
  select * into m from public.chat_messages where id = p_id;
  if not found or m.deleted or m.kind not in ('user','announcement') then return 'notfound'; end if;
  if m.author_id is distinct from me then return 'forbidden'; end if;
  if b = '' then return 'empty'; end if;
  update public.chat_messages set body = b, edited_at = now() where id = p_id;
  return 'ok';
end $$;

create or replace function public.chat_delete(staff_key text, p_id bigint)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages;
begin
  if me is null or rl is null then return 'login'; end if;
  select * into m from public.chat_messages where id = p_id;
  if not found or m.deleted then return 'notfound'; end if;
  if not public.chat_can_see(me, rl, m) then return 'forbidden'; end if;
  if m.author_id is distinct from me and rl <> 'admin' then return 'forbidden'; end if;
  update public.chat_messages set deleted = true, body = '', pinned = false where id = p_id;
  delete from public.chat_attachments where message_id = p_id;
  delete from public.chat_reactions where message_id = p_id;
  if m.author_id is distinct from me then perform public.log_action(staff_key, 'chat message removed', 'message #' || p_id); end if;
  return 'ok';
end $$;

create or replace function public.chat_react(staff_key text, p_id bigint, p_emoji text)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages; e text := trim(coalesce(p_emoji, ''));
begin
  if me is null or rl is null then return 'login'; end if;
  if char_length(e) < 1 or char_length(e) > 16 then return 'invalid'; end if;
  select * into m from public.chat_messages where id = p_id;
  if not found or m.deleted or not public.chat_can_see(me, rl, m) then return 'notfound'; end if;
  if exists (select 1 from public.chat_reactions where message_id = p_id and discord_id = me and emoji = e) then
    delete from public.chat_reactions where message_id = p_id and discord_id = me and emoji = e;
  else insert into public.chat_reactions (message_id, discord_id, emoji) values (p_id, me, e); end if;
  return 'ok';
end $$;

create or replace function public.chat_pin(staff_key text, p_id bigint, p_pin boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages;
begin
  if me is null or rl is null then return 'login'; end if;
  if not public.staff_can(staff_key, 'pin') then return 'forbidden'; end if;
  select * into m from public.chat_messages where id = p_id;
  if not found or m.deleted or not public.chat_can_see(me, rl, m) then return 'notfound'; end if;
  -- announcements can only be pinned / unpinned by administrators
  if m.kind = 'announcement' and not public.staff_can(staff_key, 'announce') then return 'forbidden'; end if;
  update public.chat_messages set pinned = coalesce(p_pin, true), pinned_by = case when coalesce(p_pin, true) then me end where id = p_id;
  return 'ok';
end $$;

create or replace function public.chat_typing(staff_key text, p_scope text)
returns void language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record;
begin
  if me is null or rl is null then return; end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, true);
  if not coalesce(sc.ok, false) then return; end if;
  insert into public.chat_typing (discord_id, scope, until_at) values (me, case when sc.dm_key is not null then 'd:' || sc.dm_key else p_scope end, now() + interval '6 seconds')
  on conflict (discord_id, scope) do update set until_at = excluded.until_at;
  delete from public.chat_typing where until_at < now() - interval '1 minute';
end $$;

-- Search messages you are allowed to see. Filters: keywords, author, one channel/DM, date range.
create or replace function public.chat_search(staff_key text, p_q text default '', p_author text default null, p_scope text default null, p_from timestamptz default null, p_to timestamptz default null, p_limit integer default 40)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); q text := trim(coalesce(p_q, '')); sc record; ch bigint; dk text;
begin
  if me is null or rl is null then return '[]'::jsonb; end if;
  if char_length(q) < 2 and p_author is null and p_scope is null and p_from is null and p_to is null then return '[]'::jsonb; end if;
  if p_scope is not null and p_scope <> '' then
    select * into sc from public.chat_resolve(me, rl, p_scope, false);
    if not coalesce(sc.ok, false) then return '[]'::jsonb; end if;
    ch := sc.channel_id; dk := sc.dm_key;
  end if;
  q := replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_');
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.id desc) from (
    select m.id, m.author_id, left(m.body, 200) as body, m.created_at,
           case when m.channel_id is not null then 'c:' || m.channel_id
                else 'd:' || (case when split_part(m.dm_key, ':', 1) = me then split_part(m.dm_key, ':', 2) else split_part(m.dm_key, ':', 1) end) end as scope,
           (select c.slug from public.chat_channels c where c.id = m.channel_id) as channel
    from public.chat_messages m
    where not m.deleted and m.kind in ('user','announcement') and m.body <> ''
      and (q = '' or m.body ilike '%' || q || '%')
      and (p_author is null or p_author = '' or m.author_id = p_author)
      and (p_from is null or m.created_at >= p_from) and (p_to is null or m.created_at < p_to)
      and (ch is null and dk is null or m.channel_id = ch or m.dm_key = dk)
      and ((m.channel_id is not null and exists (select 1 from public.chat_channels c where c.id = m.channel_id and public.chat_chan_ok(me, rl, c)))
           or (m.dm_key is not null and (split_part(m.dm_key, ':', 1) = me or split_part(m.dm_key, ':', 2) = me)))
    order by m.id desc limit least(greatest(coalesce(p_limit, 40), 1), 100)) x), '[]'::jsonb);
end $$;

-- A file attached to a message you are allowed to see.
create or replace function public.chat_file(staff_key text, p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); a public.chat_attachments; m public.chat_messages;
begin
  if me is null or rl is null then return null; end if;
  select * into a from public.chat_attachments where id = p_id;
  if not found then return null; end if;
  select * into m from public.chat_messages where id = a.message_id;
  if not public.chat_can_see(me, rl, m) then return null; end if;
  return jsonb_build_object('mime', a.mime, 'data', a.data, 'name', a.name);
end $$;

-- ---------- channel management ----------
create or replace function public.chat_channel_save(staff_key text, p_id bigint, p_name text, p_topic text, p_min text, p_post text,
                                                    p_category text default null, p_info jsonb default null, p_no_helpers boolean default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare v_slug text := regexp_replace(regexp_replace(lower(trim(coalesce(p_name, ''))), '^#', ''), '[^a-z0-9]+', '-', 'g'); cid bigint; cat text := left(upper(trim(coalesce(p_category, ''))), 40);
begin
  if not public.staff_can(staff_key, 'channels') then return jsonb_build_object('error', 'forbidden'); end if;
  v_slug := trim(both '-' from v_slug);
  if v_slug !~ '^[a-z0-9-]{1,30}$' then return jsonb_build_object('error', 'invalid_name'); end if;
  if p_min not in ('viewer','reviewer','admin') or p_post not in ('viewer','reviewer','admin') then return jsonb_build_object('error', 'invalid'); end if;
  if p_info is not null and (jsonb_typeof(p_info) <> 'object' or length(p_info::text) > 4000) then return jsonb_build_object('error', 'invalid'); end if;
  if p_id is null then
    insert into public.chat_channels (slug, category, topic, min_access, post_min, no_helpers, info, sort_order)
    values (v_slug, coalesce(nullif(cat, ''), 'GENERAL STAFF'), left(coalesce(p_topic, ''), 200), p_min, p_post, coalesce(p_no_helpers, false), coalesce(p_info, '{}'::jsonb),
            coalesce((select max(sort_order) from public.chat_channels), 0) + 10) returning id into cid;
    perform public.log_action(staff_key, 'chat channel created', '#' || v_slug);
  else
    update public.chat_channels set slug = v_slug, topic = left(coalesce(p_topic, ''), 200), min_access = p_min, post_min = p_post,
      category = coalesce(nullif(cat, ''), category), info = coalesce(p_info, info), no_helpers = coalesce(p_no_helpers, no_helpers) where id = p_id returning id into cid;
    if cid is null then return jsonb_build_object('error', 'notfound'); end if;
    perform public.log_action(staff_key, 'chat channel edited', '#' || v_slug);
  end if;
  return jsonb_build_object('ok', true, 'id', cid);
exception when unique_violation then return jsonb_build_object('error', 'name_taken');
end $$;

create or replace function public.chat_channel_delete(staff_key text, p_id bigint)
returns text language plpgsql security definer set search_path = public
as $$
declare c public.chat_channels;
begin
  if not public.staff_can(staff_key, 'channels') then return 'forbidden'; end if;
  select * into c from public.chat_channels where id = p_id;
  if not found then return 'notfound'; end if;
  if c.sys is not null then return 'system'; end if;
  delete from public.chat_channels where id = p_id;
  delete from public.chat_reads where scope = 'c:' || p_id;
  perform public.log_action(staff_key, 'chat channel deleted', '#' || c.slug);
  return 'ok';
end $$;

-- Lock / unlock (Administrators) and slow mode (Senior Moderators and up).
create or replace function public.chat_channel_set(staff_key text, p_id bigint, p_locked boolean default null, p_slow integer default null)
returns text language plpgsql security definer set search_path = public
as $$
declare c public.chat_channels;
begin
  select * into c from public.chat_channels where id = p_id;
  if not found then return 'notfound'; end if;
  if p_locked is not null then
    if not public.staff_can(staff_key, 'lock') then return 'forbidden'; end if;
    update public.chat_channels set locked = p_locked where id = p_id;
    perform public.log_action(staff_key, case when p_locked then 'chat channel locked' else 'chat channel unlocked' end, '#' || c.slug);
  end if;
  if p_slow is not null then
    if not public.staff_can(staff_key, 'slowmode') then return 'forbidden'; end if;
    if p_slow < 0 or p_slow > 3600 then return 'invalid'; end if;
    update public.chat_channels set slow_mode = p_slow where id = p_id;
    perform public.log_action(staff_key, 'chat slow mode', '#' || c.slug || ' = ' || p_slow || 's');
  end if;
  return 'ok';
end $$;

-- ---------- personal settings ----------
create or replace function public.chat_mute(staff_key text, p_scope text, p_muted boolean)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record;
begin
  if me is null or rl is null then return 'login'; end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, false);
  if not coalesce(sc.ok, false) then return 'forbidden'; end if;
  if coalesce(p_muted, true) then insert into public.chat_mutes (discord_id, scope) values (me, p_scope) on conflict do nothing;
  else delete from public.chat_mutes where discord_id = me and scope = p_scope; end if;
  return 'ok';
end $$;

create or replace function public.chat_set_prefs(staff_key text, p_notify text default null, p_away boolean default null)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key);
begin
  if me is null or public.staff_role(staff_key) is null then return 'login'; end if;
  if p_notify is not null and p_notify not in ('all','mentions','none') then return 'invalid'; end if;
  update public.staff_profiles set notify = coalesce(p_notify, notify), manual_away = coalesce(p_away, manual_away), last_seen = now() where discord_id = me;
  return 'ok';
end $$;

-- ---------- polls ----------
create or replace function public.chat_poll_create(staff_key text, p_scope text, p_question text, p_options text[])
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record; q text := left(trim(coalesce(p_question, '')), 300); opts text[]; mid bigint; o text;
begin
  if me is null or rl is null then return jsonb_build_object('error', 'login'); end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, true);
  if not coalesce(sc.ok, false) then return jsonb_build_object('error', 'forbidden'); end if;
  if char_length(q) < 3 then return jsonb_build_object('error', 'invalid'); end if;
  opts := '{}';
  foreach o in array coalesce(p_options, '{}') loop if char_length(trim(o)) > 0 then opts := opts || left(trim(o), 80); end if; end loop;
  if array_length(opts, 1) is null or array_length(opts, 1) < 2 or array_length(opts, 1) > 6 then return jsonb_build_object('error', 'options'); end if;
  insert into public.chat_messages (channel_id, dm_key, author_id, body, kind, poll) values (sc.channel_id, sc.dm_key, me, q, 'poll', jsonb_build_object('options', to_jsonb(opts))) returning id into mid;
  return jsonb_build_object('ok', true, 'id', mid);
end $$;

create or replace function public.chat_poll_vote(staff_key text, p_id bigint, p_opt integer)
returns text language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); m public.chat_messages;
begin
  if me is null or rl is null then return 'login'; end if;
  select * into m from public.chat_messages where id = p_id and kind = 'poll';
  if not found or m.deleted or not public.chat_can_see(me, rl, m) then return 'notfound'; end if;
  if p_opt is null or p_opt < 0 or p_opt >= jsonb_array_length(m.poll->'options') then return 'invalid'; end if;
  if exists (select 1 from public.chat_poll_votes where message_id = p_id and discord_id = me and opt = p_opt) then
    delete from public.chat_poll_votes where message_id = p_id and discord_id = me;   -- clicking your vote again removes it
  else insert into public.chat_poll_votes (message_id, discord_id, opt) values (p_id, me, p_opt) on conflict (message_id, discord_id) do update set opt = excluded.opt; end if;
  return 'ok';
end $$;

-- ---------- announcements + clearing (Administrators) ----------
create or replace function public.chat_announce(staff_key text, p_text text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); t text := left(trim(coalesce(p_text, '')), 2000); cid bigint; mid bigint;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'announce') then return jsonb_build_object('error', 'forbidden'); end if;
  if char_length(t) < 3 then return jsonb_build_object('error', 'empty'); end if;
  select id into cid from public.chat_channels where sys = 'announcements';
  if cid is null then return jsonb_build_object('error', 'notfound'); end if;
  insert into public.chat_messages (channel_id, author_id, body, kind, mention_all) values (cid, me, t, 'announcement', true) returning id into mid;
  perform public.log_action(staff_key, 'announcement', left(t, 120));
  return jsonb_build_object('ok', true, 'id', mid, 'channel', cid);
end $$;

create or replace function public.chat_clear(staff_key text, p_scope text, p_count integer)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); rl text := public.staff_role(staff_key); sc record; n int := 0; ids bigint[];
begin
  if me is null or rl is null then return jsonb_build_object('error', 'login'); end if;
  if not public.staff_can(staff_key, 'clear') then return jsonb_build_object('error', 'forbidden'); end if;
  if p_count is null or p_count < 1 or p_count > 100 then return jsonb_build_object('error', 'invalid'); end if;
  select * into sc from public.chat_resolve(me, rl, p_scope, false);
  if not coalesce(sc.ok, false) or sc.channel_id is null then return jsonb_build_object('error', 'forbidden'); end if;   -- channels only: private DMs can't be cleared by anyone else
  select array_agg(x.id) into ids from (select m.id from public.chat_messages m where m.channel_id = sc.channel_id and not m.deleted and m.kind in ('user','announcement','poll','system') and not m.pinned order by m.id desc limit p_count) x;
  if ids is null then return jsonb_build_object('ok', true, 'cleared', 0); end if;
  update public.chat_messages set deleted = true, body = '', pinned = false where id = any(ids);
  get diagnostics n = row_count;
  delete from public.chat_attachments where message_id = any(ids);
  delete from public.chat_reactions where message_id = any(ids);
  perform public.log_action(staff_key, 'chat clear', n || ' messages in #' || (select slug from public.chat_channels where id = sc.channel_id));
  return jsonb_build_object('ok', true, 'cleared', n);
end $$;

-- ---------- permissions ----------
revoke all on function public.chat_actor(text) from public, anon, authenticated;
revoke all on function public.chat_helper(text, text) from public, anon, authenticated;
revoke all on function public.chat_chan_ok(text, text, public.chat_channels) from public, anon, authenticated;
revoke all on function public.chat_roster() from public, anon, authenticated;
revoke all on function public.chat_resolve(text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.chat_can_see(text, text, public.chat_messages) from public, anon, authenticated;
revoke all on function public.chat_msgs_json(text, bigint, text, integer, bigint, bigint, bigint[]) from public, anon, authenticated;

grant execute on function public.chat_poll(text, text, boolean, boolean, integer) to anon, authenticated;
grant execute on function public.chat_older(text, text, bigint, integer) to anon, authenticated;
grant execute on function public.chat_thread(text, bigint) to anon, authenticated;
grant execute on function public.chat_send(text, text, text, bigint, jsonb, text[], bigint) to anon, authenticated;
grant execute on function public.chat_edit(text, bigint, text) to anon, authenticated;
grant execute on function public.chat_delete(text, bigint) to anon, authenticated;
grant execute on function public.chat_react(text, bigint, text) to anon, authenticated;
grant execute on function public.chat_pin(text, bigint, boolean) to anon, authenticated;
grant execute on function public.chat_typing(text, text) to anon, authenticated;
grant execute on function public.chat_search(text, text, text, text, timestamptz, timestamptz, integer) to anon, authenticated;
grant execute on function public.chat_file(text, bigint) to anon, authenticated;
grant execute on function public.chat_channel_save(text, bigint, text, text, text, text, text, jsonb, boolean) to anon, authenticated;
grant execute on function public.chat_channel_delete(text, bigint) to anon, authenticated;
grant execute on function public.chat_channel_set(text, bigint, boolean, integer) to anon, authenticated;
grant execute on function public.chat_mute(text, text, boolean) to anon, authenticated;
grant execute on function public.chat_set_prefs(text, text, boolean) to anon, authenticated;
grant execute on function public.chat_poll_create(text, text, text, text[]) to anon, authenticated;
grant execute on function public.chat_poll_vote(text, bigint, integer) to anon, authenticated;
grant execute on function public.chat_announce(text, text) to anon, authenticated;
grant execute on function public.chat_clear(text, text, integer) to anon, authenticated;

notify pgrst, 'reload schema';
