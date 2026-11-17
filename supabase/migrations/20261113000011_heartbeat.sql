-- Presence heartbeat: the dashboard pings this every ~20s from every page (not only the chat page),
-- so "online" is true while a staff member has the dashboard open. Needs a live Discord staff session.
create or replace function public.staff_heartbeat(staff_key text, p_away boolean default false)
returns boolean language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key);
begin
  if me is null then return false; end if;
  insert into public.staff_profiles (discord_id, username, display_name, access, last_seen)
    select s.discord_id, s.name, s.name, s.role, now() from public.staff_sessions s where s.key_hash = public.code_hash(staff_key)
  on conflict (discord_id) do nothing;
  update public.staff_profiles set last_seen = now(), away = coalesce(p_away, false) where discord_id = me;
  return true;
end $$;
revoke all on function public.staff_heartbeat(text, boolean) from public;
grant execute on function public.staff_heartbeat(text, boolean) to anon, authenticated;
