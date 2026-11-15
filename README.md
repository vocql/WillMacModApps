# Will Mac Community – upgraded site

Upgrade of the existing site (nothing replaced; original branding, tables, RLS and Discord login kept).

## Layout
```
config.js  index.html  supabase.sql
appeal/  applications/  handbook/
supabase/migrations/   (0001 = your original SQL, 0002–0008 = upgrades, in order)
scripts/build-supabase-sql.py   (rebuilds supabase.sql from the migrations)
docs/screenshots/
```
There are no `.env` files and no secrets in the frontend. Your `.github` folder was not available to me; keep yours as it is.

## Install / upgrade
1. Copy these files over your repository (keep `.github`). Keep your own `config.js` values (Supabase URL + anon key only).
2. In Supabase → SQL Editor, paste and run `supabase.sql` once. It is idempotent: it adds to the existing tables and never drops or resets them. (Or run the files in `supabase/migrations` in order.)
3. Commit/push; GitHub Pages serves it as before.

## What's new
- **Navbar** (one line on desktop, collapsible Menu under 960px): Home, Feedback, Refresh, Open/Close, Review, Users, Team, Chat, Handbook, Logout. Users has tabs Members / Moderation log; Team has tabs Staff / Activity / Access codes (your original access manager).
- **Users**: every Discord login, ban / timeout / unban / remove timeout / warn / notes, confirmations, audit log. Banned or timed-out members see a custom page on the home site and cannot apply (enforced in the database).
- **Team**: add staff by Discord ID or name, ranks Owner / Administrator / Senior Moderator / Moderator / Helper; they appear in "Our Staff Team" on the home page automatically.
- **Chat**: 13 channels in 4 categories, DMs, images, replies, edit/delete, reactions, pins, mentions, search, unread, presence, application and feedback cards (Approve/Deny, claim/release/assign with locking), ~38 slash commands (`/help` lists those you may use).
- **Privacy / screenshots**: see below.

## Permissions
All checks happen in the database (`security definer` functions that verify the staff session on every call); the browser only hides buttons.
Helper: chat, view applications. Moderator+: user info, logs, warn, notes. Senior Moderator/Reviewer: also claim/decide, timeout, pin, slowmode. Administrator: also ban, assign, announce, lock, clear, open/close, promote, activity, users, staff management, screenshots. Owner (`1271246652421701633`) is protected.
Chat needs a Discord staff login; backup codes / the master key cannot use chat.
Discord bot tokens, if you ever add one, go only in `app_secrets` via SQL – never in the frontend.

## Privacy and the built-in screenshot
- Only administrators can use `/screenshot` or the toolbar button (button is not even rendered for others). The server (`chat_screenshot`) re-checks admin rights and channel/DM access on every request and writes an audit row (Discord name, ID, time, channel); refused attempts are logged too. Direct API calls are refused the same way.
- The image is made in the browser from the on-screen chat including the personal watermark, with a footer of who/when/log id.
- Watermark (username + user ID) tiled over every channel and DM; repaired automatically if removed in dev tools.
- Privacy mode: chat is hidden when the tab is hidden or minimised and restores on return; optional blur on window focus loss (Settings). Print is blocked. PrintScreen / Win+Shift+S / Cmd+Shift+3-5 are detected where the browser reports them and logged.
- **Limit:** a browser cannot stop OS-level or external capture (phone camera, capture tools). Watermarks and logging deter and trace it; they do not prevent it.

## Tested
Real PostgreSQL 16 with RLS: fresh install, re-run, upgrade from the original schema, ~300 SQL assertions. Real Chromium (Playwright) against that database: 117 UI checks, no JS errors – navbar one line, every button, users/staff/chat/DMs/commands, helper restrictions and API-bypass attempts, mobile.
**Not tested here:** Discord OAuth login against your live Supabase, live Realtime (chat falls back to ~3s polling), and the header logo image (hosted at the URL in config.js). The home-page ban/timeout screen was tested in a browser with a mocked Discord session. Please check the first three once after deploying.
