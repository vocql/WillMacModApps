# Will Mac Community – UPDATED DISCORD CHAT VERSION

The full Will Mac site with the **redesigned Discord-style staff chat**, a separate **Direct Messages page**, **Online/Offline** status, **no-login anonymous reports**, **private staff servers with invite links**, and updated staff permissions. Your original branding, Discord login, applications and dashboard are all kept. This ZIP is complete on its own; it does not need the "Current Chat Version".

## Contents
```
config.js  config.example.js  index.html  README.md  supabase.sql
appeal/  applications/  docs/  handbook/  report/  scripts/  supabase/
```
- `applications/` staff dashboard (`index.html`, `staff-chat.js`, `staff-pages.js`)
- `report/` public report form (no login)
- `supabase/migrations/` 0001 = your original SQL, 0002–0011 = earlier upgrades, **0012–0016 = this version** (servers, invites, permissions, reports, Online/Offline, limits)
- `supabase.sql` = all migrations in one file (rebuild with `python3 scripts/build-supabase-sql.py`)
- `docs/screenshots/` screenshots (`v2-*.png`)

## Install / run
1. Copy `config.example.js` to `config.js` and fill in your **Supabase Project URL** and **publishable (anon) key** (see below). Keep your own `config.js` if you already have one.
2. Supabase → SQL Editor → paste and run `supabase.sql` once (safe to re-run; it only adds things).
3. Supabase → Authentication → Providers → enable **Discord** and add your site URL as a redirect URL.
4. Publish on GitHub Pages (or any static host). To test locally: `python3 -m http.server 8000`, then open http://localhost:8000.

## Environment variables / secrets
This is a static site, so there is no build step and no `.env`. The ZIP contains **no secrets**: `config.js` has empty values and `config.example.js` has placeholders named after the variables you would normally use:
| Placeholder | Where it goes |
|---|---|
| `SUPABASE_URL` | `supabaseUrl` in `config.js` |
| `SUPABASE_ANON_KEY` | `supabaseKey` in `config.js` (publishable/anon key only, **never** the service_role key) |
| `DISCORD_WEBHOOK_URL` | optional `discordWebhook` |
If you deploy with GitHub Actions you can write `config.js` from repository secrets with the same names.

## What is new
- **Chat**: server rail, channel sidebar, message area, member list, user panel. Replies, threads, reactions, edit, delete, pins, attachments, typing indicators, sent/seen indicators, timestamps, Discord avatars and names.
- **Messages page** (nav → Messages): recent conversations, avatars, online dots, unread badges, search, "New conversation", replies, reactions, edit/delete, images/files, history after refresh.
- **Status**: Online or Offline only (heartbeat every 20s).
- **Reports (no login)**: a **Report** button in the Home top bar opens the `report/` form (who, category, details, where, evidence link, up to 6 screenshots, optional contact) → `report_submit` (rate-limited, honeypot) → moderators see it on the **Reports** page, including reports about banned people. They can set reviewed/resolved/dismissed, add internal notes; every action is logged. Regular users never see reports or notes.
- **Private staff servers**: staff with the *create server* permission can create one (name, icon, colour). **Maximum 10 servers in total.** Owners/managers can add and edit channels (public or private), invite staff, set per-member permissions, remove members and delete the server. Everything is stored in Supabase behind security-definer functions (RLS closed).
- **Invite links** look like `https://vocql.github.io/WillMacModApps/?=jhhew83827skj` (13 random characters). They can expire (1h–90d or never), be limited to N uses, and be revoked at any time. Opening one forwards to the staff login; joining requires an active staff account linked through Discord, anyone else is refused.
- **Permissions** (extend the existing staff roster): Administrators and Senior Moderators and Moderators can create servers and view/update reports; other staff can join servers they are invited to; regular users get nothing. Server roles: owner, plus per-member permissions *send, invite, manage_channels, manage_members, manage_messages, manage_server*.

- **Staff name & photo**: Team page → *Add staff* has an optional name and picture upload, and every staff row has a **Name & photo** button. What you set shows on Home under Our Staff Team (falls back to the Discord name/picture when empty). Pictures are shrunk to 256px in the browser.

## Database changes
0012 server tables, invites, audit log, permission functions; 0013 presence (`staff_pulse`), public reports, moderator report workflow; 0014 short invite codes and the 10-server cap; 0016 custom staff name/photo for the home page; 0015 screenshots on reports (up to 6 images, shrunk in the browser, readable only by moderators). No existing table is dropped.

## Known limitations
- Static hosting: updates arrive by polling (about every 3s, slower when the tab is hidden) with an optional Realtime nudge.
- Discord status is not read from Discord; Online/Offline means "has the staff dashboard open".
- Invite links work only for people who are active staff in your roster.
- The 10-server cap is site-wide; delete an unused server to free a slot.
