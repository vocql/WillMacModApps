-- Staff profile: set a custom name and picture for the home page "Our Staff Team" (overrides the Discord name/picture).
alter table public.staff_members add column if not exists custom_name text;
alter table public.staff_members add column if not exists custom_avatar text;

create or replace function public.staff_member_profile(staff_key text, p_discord_id text, p_name text default null, p_avatar text default null, p_clear_avatar boolean default false, p_clear_name boolean default false)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare did text := trim(coalesce(p_discord_id, '')); m public.staff_members; nm text := left(trim(coalesce(p_name, '')), 40); av text := trim(coalesce(p_avatar, ''));
begin
  if not public.staff_can(staff_key, 'staff_manage') then return jsonb_build_object('error', 'forbidden'); end if;
  select * into m from public.staff_members where discord_id = did; if not found then return jsonb_build_object('error', 'notfound'); end if;
  if public.mod_guard(staff_key, did, 'staff_manage') is not null and did is distinct from public.staff_actor_id(staff_key) then return jsonb_build_object('error', 'forbidden'); end if;
  if av <> '' and not (av ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' and char_length(av) <= 250000) and not (av ~ '^https://[^ ]{4,400}$') then return jsonb_build_object('error', 'image'); end if;
  update public.staff_members set
    custom_name = case when coalesce(p_clear_name, false) then null when nm <> '' then nm else custom_name end,
    custom_avatar = case when coalesce(p_clear_avatar, false) then null when av <> '' then av else custom_avatar end,
    updated_at = now()
  where discord_id = did;
  perform public.log_action(staff_key, 'staff profile edited', coalesce(m.display_name, did));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.staff_member_profile(text, text, text, text, boolean, boolean) from public;
grant execute on function public.staff_member_profile(text, text, text, text, boolean, boolean) to anon, authenticated;

create or replace function public.list_staff_members(staff_key text)
returns jsonb language sql stable security definer set search_path = public
as $$
  select case when not public.staff_can(staff_key, 'staff_manage') then null else coalesce((
    select jsonb_agg(jsonb_build_object('discord_id', m.discord_id, 'username', m.username,
      'display_name', coalesce(nullif(m.custom_name, ''), d.display_name, m.display_name),
      'avatar', coalesce(nullif(m.custom_avatar, ''), d.avatar, m.avatar), 'custom_name', m.custom_name, 'has_custom_avatar', coalesce(m.custom_avatar, '') <> '',
      'rank', m.rank_name, 'added_by', m.added_by, 'created_at', m.created_at,
      'access', coalesce((select o.access from public.staff_overrides o where o.discord_id = m.discord_id), 'none'),
      'last_seen', (select p.last_seen from public.staff_profiles p where p.discord_id = m.discord_id),
      'protected', public.mod_guard(staff_key, m.discord_id, 'staff_manage') is not null)
      order by array_position(array['Owner','Co-Owner','Administrator','Senior Moderator','Lead Moderator','Moderator','Helper','Staff'], m.rank_name), lower(m.display_name))
    from public.staff_members m left join lateral public.discord_user(m.discord_id) d on true), '[]'::jsonb) end
$$;

create or replace function public.public_staff()
returns jsonb language sql stable security definer set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('name', coalesce(nullif(m.custom_name, ''), nullif(d.display_name, ''), nullif(m.display_name, ''), m.username),
      'avatar', coalesce(nullif(m.custom_avatar, ''), d.avatar, m.avatar), 'role', m.rank_name)
    order by array_position(array['Owner','Co-Owner','Administrator','Senior Moderator','Lead Moderator','Moderator','Helper','Staff'], m.rank_name), m.sort_order, lower(coalesce(m.display_name, m.username))), '[]'::jsonb)
  from public.staff_members m left join lateral public.discord_user(m.discord_id) d on true
$$;
grant execute on function public.list_staff_members(text) to anon, authenticated;
grant execute on function public.public_staff() to anon, authenticated;
notify pgrst, 'reload schema';
