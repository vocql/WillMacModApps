-- v2: at most 10 private servers in total, and short 13-character invite codes (like jhhew83827skj).
create or replace function public.srv_code() returns text language plpgsql volatile set search_path = public as $$
declare chars text := 'abcdefghijklmnopqrstuvwxyz0123456789'; out text := ''; i int;
begin
  for i in 1..13 loop out := out || substr(chars, 1 + floor(random() * 36)::int, 1); end loop;
  return out;
end $$;

create or replace function public.server_invite_create(staff_key text, p_server bigint, p_hours integer default 168, p_max_uses integer default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me text := public.chat_actor(staff_key); v_code text;
begin
  if me is null or public.staff_role(staff_key) is null then return jsonb_build_object('error', 'login'); end if;
  if not (public.srv_can(me, p_server, 'invite') or public.srv_can(me, p_server, 'manage_server')) then return jsonb_build_object('error', 'forbidden'); end if;
  if (select count(*) from public.server_invites where server_id = p_server and revoked_at is null and (expires_at is null or expires_at > now())) >= 20 then return jsonb_build_object('error', 'limit'); end if;
  if p_hours is not null and (p_hours < 0 or p_hours > 24 * 90) then return jsonb_build_object('error', 'hours'); end if;
  loop v_code := public.srv_code(); exit when not exists (select 1 from public.server_invites i where i.code = v_code); end loop;
  insert into public.server_invites (code, server_id, created_by, expires_at, max_uses)
    values (v_code, p_server, me, case when coalesce(p_hours, 0) = 0 then null else now() + make_interval(hours => p_hours) end, nullif(p_max_uses, 0));
  perform public.srv_log(p_server, staff_key, 'invite created', v_code || case when coalesce(p_hours, 0) = 0 then ' (never expires)' else ' (' || p_hours || 'h)' end);
  return jsonb_build_object('ok', true, 'code', v_code);
end $$;
