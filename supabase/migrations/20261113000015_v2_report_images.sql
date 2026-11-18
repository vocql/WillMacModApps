-- v2: screenshots on anonymous reports (up to 6 small images, stored with the report; only moderators can read them).
alter table public.user_reports add column if not exists images jsonb not null default '[]'::jsonb;

drop function if exists public.report_submit(text, text, text, text, text, text, text);
create or replace function public.report_submit(p_target text, p_category text, p_details text,
                                                p_where text default '', p_evidence text default '', p_contact text default '', p_hp text default '',
                                                p_images jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare t text := left(trim(coalesce(p_target, '')), 100); d text := left(trim(coalesce(p_details, '')), 2000); c text := lower(coalesce(p_category, 'other'));
        tid text; tn text; rid bigint; cid bigint; imgs jsonb := '[]'::jsonb; x jsonb; total int := 0;
begin
  if coalesce(p_hp, '') <> '' then return jsonb_build_object('ok', true, 'ref', 'R-0'); end if;
  if char_length(t) < 2 then return jsonb_build_object('error', 'target'); end if;
  if char_length(d) < 10 then return jsonb_build_object('error', 'short'); end if;
  if c not in ('spam','harassment','inappropriate','cheating','ban_evasion','scam','other') then c := 'other'; end if;
  if jsonb_typeof(coalesce(p_images, '[]'::jsonb)) = 'array' then
    for x in select value from jsonb_array_elements(coalesce(p_images, '[]'::jsonb)) limit 6 loop
      if jsonb_typeof(x) = 'string' and (x #>> '{}') ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' and char_length(x #>> '{}') <= 700000 then
        total := total + char_length(x #>> '{}'); imgs := imgs || x;
      end if;
    end loop;
    if total > 3600000 then return jsonb_build_object('error', 'toobig'); end if;
  end if;
  if (select count(*) from public.user_reports r where r.source = 'public' and r.created_at > now() - interval '10 minutes') >= 40 then return jsonb_build_object('error', 'busy'); end if;
  if exists (select 1 from public.user_reports r where r.source = 'public' and r.details = d and r.created_at > now() - interval '24 hours') then
    return jsonb_build_object('ok', true, 'ref', 'R-dup');
  end if;
  if t ~ '^[0-9]{5,25}$' then tid := t;
  else select u.discord_id into tid from public.discord_users() u where lower(u.username) = lower(t) or lower(u.display_name) = lower(t) limit 1;
  end if;
  if tid is not null then select coalesce(nullif(x2.display_name, ''), x2.username) into tn from public.discord_user(tid) x2; end if;
  insert into public.user_reports (reporter_id, reporter_name, target_id, target_name, target_label, category, details, evidence, contact, where_text, source, images)
    values (null, 'Anonymous', tid, left(coalesce(tn, t), 100), t, c, d, nullif(left(trim(coalesce(p_evidence, '')), 800), ''), nullif(left(trim(coalesce(p_contact, '')), 100), ''),
            nullif(left(trim(coalesce(p_where, '')), 200), ''), 'public', imgs) returning id into rid;
  insert into public.report_audit (report_id, actor_name, action, detail) values (rid, 'Public form', 'submitted', 'No login required' || case when jsonb_array_length(imgs) > 0 then ', ' || jsonb_array_length(imgs) || ' screenshot(s)' else '' end);
  select id into cid from public.chat_channels where slug = 'user-reports' and server_id is null;
  if cid is not null then
    insert into public.chat_messages (channel_id, author_id, kind, body) values (cid, null, 'system', 'New anonymous report #' || rid || ' about ' || coalesce(tn, t) || ' (' || replace(c, '_', ' ') || '). Open the Reports page to review it.');
  end if;
  return jsonb_build_object('ok', true, 'ref', 'R-' || rid);
exception when others then return jsonb_build_object('error', 'failed');
end $$;
revoke all on function public.report_submit(text, text, text, text, text, text, text, jsonb) from public;
grant execute on function public.report_submit(text, text, text, text, text, text, text, jsonb) to anon, authenticated;
