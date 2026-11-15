/* Will Mac staff dashboard: User management, Staff management, Moderation logs, Staff activity.
   Loaded after the main dashboard script and shares its helpers (rpc, el, toast, staff, me ...).
   Nothing here is trusted by the database: every button below is checked again server-side. */
(function () {
  "use strict";
  const W = (window.WMS = window.WMS || {});
  const S = (W.state = { me: null, page: "apps" });
  const can = c => !!(S.me && S.me.caps && S.me.caps.indexOf(c) >= 0);
  const call = (fn, extra) => rpc(fn, staff, extra || {});
  const fmt = t => t ? new Date(t).toLocaleString([], { dateStyle: "medium", timeStyle: "short" }) : "—";
  const rel = t => t ? ago(Date.parse(t)) : "—";
  const ERR = {
    forbidden: "You don't have permission to do that.", protected: "That person is protected and can't be changed.", self: "You can't do that to yourself.",
    invalid: "That input isn't valid.", reason_required: "A clear reason is required (at least 3 characters).", already_banned: "They are already banned.",
    not_banned: "They aren't banned.", not_timed_out: "They aren't timed out.", owner_only: "Only the Owner can do that.", notfound: "Not found.",
    login: "Your session expired. Log in again.", not_found_no_bot: "Not found on the site. Ask the Owner to add the Discord bot token (see README) to look up people who never logged in.",
    not_found: "Discord doesn't know that ID.", not_found_name: "Nobody with that name has logged in to the site. Use their Discord ID instead.",
    discord_unreachable: "Couldn't reach Discord. Try again in a moment.", discord_error: "Discord returned an error. Try again.", limit: "Already at the end of the ladder.",
    already_decided: "That application was already decided.", claimed: "Someone else has claimed it.", own_punishment: "You issued this punishment, so another staff member must decide.",
    locked: "That channel is locked.", slowmode: "Slow mode is on. Wait a moment.", rate: "Slow down a little.", empty: "Write something first.",
    bad_file: "That file isn't allowed or is too big (max about 1.4 MB, images, PDF, text, CSV, ZIP, DOCX).", too_many_files: "Up to 4 files per message.",
    name_taken: "That name is taken.", invalid_name: "Use letters, numbers and dashes.", system: "System channels can't be deleted.", failed: "That didn't work. Try again.",
    "2fa_required": "Two-factor sign-in is required for administrators.", bad_thread: "That thread isn't available.", options: "A poll needs 2 to 6 options."
  };
  const errText = e => ERR[e] || (e ? String(e) : "Something went wrong.");
  W.errText = errText; W.fmt = fmt; W.rel = rel; W.call = call; W.can = can;

  function xav(name, url, size, st) {
    const w = el("span", { class: "avw" }), a = el("span", { class: "xav", style: "--s:" + (size || 36) + "px" }, initial(name || "?"));
    const src = avOf(url);
    if (src) { const i = el("img", { src, alt: "", referrerpolicy: "no-referrer" }); i.onerror = () => i.remove(); a.append(i); }
    w.append(a); if (st) w.append(el("i", { class: "sdot " + st })); return w;
  }
  W.xav = xav;
  const stg = s => el("span", { class: "stg " + (s === "timeout" ? "timeout" : s), title: s }, s === "timeout" ? "Timed out" : s === "banned" ? "Banned" : "Active");
  W.stg = stg;

  /* ---------- confirmation dialogs ---------- */
  function dlg(title, build) {
    return new Promise(resolve => {
      const close = v => { m.remove(); document.removeEventListener("keydown", esc, true); resolve(v); };
      const esc = e => { if (e.key === "Escape") { e.stopPropagation(); close(null); } };
      const box = el("div", { class: "box", role: "dialog", "aria-modal": "true", "aria-label": title });
      const m = el("div", { class: "modal dlg", onclick: e => { if (e.target === m) close(null); } }, box);
      box.append(el("div", { class: "mh" }, el("h3", {}, title), el("button", { type: "button", onclick: () => close(null) }, "Close")));
      build(box, close);
      document.body.append(m); document.addEventListener("keydown", esc, true);
      const f = box.querySelector("textarea,input[type=text],select"); if (f) f.focus();
    });
  }
  W.dlg = dlg;
  /* ask({title,text,reason:'required'|'optional'|null,minutes,confirm,danger}) -> {reason,minutes} or null */
  W.ask = o => dlg(o.title, (box, close) => {
    const err = el("div", { class: "derr" }), why = o.reason ? el("textarea", { maxlength: "300", placeholder: o.reason === "required" ? "Reason (required)" : "Reason (optional)", "aria-label": "Reason" }) : null;
    const dur = o.minutes ? el("select", { "aria-label": "Duration" }, ...[[10, "10 minutes"], [60, "1 hour"], [360, "6 hours"], [1440, "1 day"], [4320, "3 days"], [10080, "7 days"], [20160, "14 days"], [40320, "28 days"]].map(([v, t]) => el("option", { value: v }, t))) : null;
    const go = el("button", { type: "button", class: "go" + (o.danger ? " danger" : ""), onclick: () => {
      const r = why ? why.value.trim() : "";
      if (o.reason === "required" && r.length < (o.min || 3)) { err.textContent = "Please write a clear reason" + (o.min ? " (at least " + o.min + " characters)." : "."); return; }
      close({ reason: r, minutes: dur ? Number(dur.value) : null });
    } }, o.confirm || "Confirm");
    box.append(el("p", {}, o.text || ""), dur ? el("label", {}, "How long") : null, dur, why ? el("label", {}, "Reason") : null, why, err,
      el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Cancel"), go));
  });
  W.notice = (title, ...nodes) => dlg(title, (box, close) => box.append(...nodes, el("div", { class: "row" }, el("button", { type: "button", class: "go", onclick: () => close(true) }, "Done"))));
  const copyId = id => { try { navigator.clipboard.writeText(id); toast("Discord ID copied"); } catch (e) { toast(id); } };
  W.copyId = copyId;

  /* ---------- moderation actions (shared by the buttons and the chat commands) ---------- */
  const VERB = { ban: "Ban from website", unban: "Unban", timeout: "Timeout", untimeout: "Remove timeout", warn: "Warn", note: "Add note" };
  W.modAction = async function (u, action, pre) {
    const nm = u.display_name || u.username || u.discord_id;
    const info = {
      ban: ["Ban " + nm + " from the website?", "They will not be able to apply or send feedback and will see a ban page. This is logged with your name.", "required", false, true],
      unban: ["Unban " + nm + "?", "They will be able to apply again.", "optional", false, false],
      timeout: ["Timeout " + nm + "?", "They can't apply or send feedback until the timeout ends.", "required", true, true],
      untimeout: ["Remove timeout for " + nm + "?", "They will be able to apply again.", "optional", false, false],
      warn: ["Warn " + nm + "?", "A warning is recorded in their moderation history.", "required", false, false],
      note: ["Add a note about " + nm + "?", "Notes are private to staff.", "required", false, false]
    }[action];
    const a = pre || await W.ask({ title: info[0], text: info[1], reason: info[2], minutes: info[3], danger: info[4], confirm: VERB[action] });
    if (!a) return false;
    let r; try { r = await call("mod_action", { p_discord_id: u.discord_id || u.id, p_action: action, p_reason: a.reason, p_minutes: a.minutes }); } catch (e) { toast("Couldn't reach the server"); return false; }
    if (r === "ok") { toast(VERB[action] + ": done"); return true; }
    toast(errText(r), 4500); return false;
  };

  /* ---------- page host ---------- */
  const pages = {};
  W.pages = pages;
  function host() { return $("#pages"); }
  function setPage(p) {
    if (p !== "apps" && !pages[p]) return;
    const leaving = S.page; S.page = p;
    if (leaving && pages[leaving] && pages[leaving].leave && leaving !== p) pages[leaving].leave();
    $("#dashView").classList.toggle("inpage", p !== "apps");
    const h = host(); if (!h) return;
    if (p === "apps") { h.replaceChildren(); }
    else {
      h.replaceChildren();
      if (!S.me) h.append(el("div", { class: "plain" }, el("b", {}, "This section needs the database update"), "Staff Chat, Users and Team run on the new Supabase functions. Open Supabase → SQL Editor, paste the whole supabase.sql from this project and press Run, then reload this page and log in again.", el("div", { class: "hint", style: "margin-top:8px" }, "Details: " + (S.meErr || "not loaded")), el("div", { style: "margin-top:12px" }, el("button", { type: "button", class: "tg", onclick: async () => { await refreshMe(); if (S.me) setPage(p); else toast("Still not available"); } }, "Try again"))));
      else pages[p].enter(h);
    }
    if (W.markNav) W.markNav();
    if (p === "apps" && typeof render === "function") { try { render(); } catch (e) {} }
  }
  W.setPage = setPage;

  function head(title, hint, ...tools) { return el("div", { class: "pgh" }, el("h2", {}, title), ...tools, hint ? el("div", { class: "hint" }, hint) : null); }
  const empty = (t, s) => el("div", { class: "plain" }, el("b", {}, t), s || "");
  function debounce(f, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => f(...a), ms); }; }

  /* ===== User management ===== */
  const U = { q: "", st: "all", rows: [], err: "", page: 1, per: 10 };
  const usersView = {
    enter(h) {
      const q = el("input", { type: "search", placeholder: "Search username, display name or Discord ID", "aria-label": "Search users", value: U.q });
      const st = el("select", { "aria-label": "Filter by status" }, ...[["all", "All users"], ["active", "Active"], ["timeout", "Timed out"], ["banned", "Banned"]].map(([v, t]) => el("option", { value: v }, t)));
      st.value = U.st;
      const body = el("div", { class: "pgb", id: "ubody" });
      const count = el("span", { class: "hint", style: "flex:none;margin:0" });
      const load = async () => {
        try { const r = await call("list_site_users", { p_q: U.q, p_status: U.st, p_limit: 500 }); U.rows = Array.isArray(r) ? r : []; U.err = ""; } catch (e) { U.rows = []; U.err = "User list unavailable. Run the newest files in supabase/migrations."; }
        count.textContent = U.rows.length + " shown"; draw(body);
      };
      q.addEventListener("input", debounce(() => { U.q = q.value; U.page = 1; load(); }, 250)); st.onchange = () => { U.st = st.value; U.page = 1; load(); };
      h.append(head("User management", "Everyone who has logged in to the website with Discord. Bans stop them applying, timeouts do it for a while.", q, st, count, el("button", { type: "button", onclick: load }, "Refresh")), body);
      body.replaceChildren(empty("Loading…")); load();
    },
    leave() {}
  };
  function draw(body) {
    if (U.err) return body.replaceChildren(empty("Couldn't load users", U.err));
    if (!U.rows.length) return body.replaceChildren(empty("No users found", "People appear here after they log in with Discord."));
    const pages = Math.max(1, Math.ceil(U.rows.length / U.per)); if (U.page > pages) U.page = pages; if (U.page < 1) U.page = 1;
    const go = n => { U.page = n; draw(body); };
    const nums = []; for (let i = 1; i <= pages; i++) if (i === 1 || i === pages || Math.abs(i - U.page) <= 1) nums.push(i); else if (nums[nums.length - 1] !== "…") nums.push("…");
    const pager = pages < 2 ? null : el("div", { class: "pgtabs pager", role: "navigation", "aria-label": "Pages" },
      el("button", { type: "button", disabled: U.page === 1, onclick: () => go(U.page - 1) }, "‹ Prev"),
      ...nums.map(n => n === "…" ? el("span", { class: "hint", style: "align-self:center" }, "…") : el("button", { type: "button", class: n === U.page ? "on" : "", "aria-current": n === U.page ? "page" : "false", onclick: () => go(n) }, String(n))),
      el("button", { type: "button", disabled: U.page === pages, onclick: () => go(U.page + 1) }, "Next ›"),
      el("span", { class: "hint", style: "align-self:center;margin:0 0 0 6px" }, "Page " + U.page + " of " + pages));
    body.replaceChildren(...U.rows.slice((U.page - 1) * U.per, U.page * U.per).map(userRow), ...(pager ? [pager] : []));
  }
  function userRow(u) {
    const nm = u.display_name || u.username || "Unknown";
    const acts = el("div", { class: "uact" });
    if (can("userinfo")) acts.append(el("button", { type: "button", onclick: () => viewUser(u.discord_id) }, "View"));
    const done = async ok => { if (ok) { const b = $("#ubody"); try { const r = await call("list_site_users", { p_q: U.q, p_status: U.st, p_limit: 500 }); U.rows = Array.isArray(r) ? r : U.rows; } catch (e) {} if (b) draw(b); } };
    if (u.status === "banned") { if (can("ban")) acts.append(el("button", { type: "button", class: "ok", onclick: async () => done(await W.modAction(u, "unban")) }, "Unban")); }
    else {
      if (u.status === "timeout" && can("timeout")) acts.append(el("button", { type: "button", class: "ok", onclick: async () => done(await W.modAction(u, "untimeout")) }, "Remove timeout"));
      else if (can("timeout")) acts.append(el("button", { type: "button", class: "warn", onclick: async () => done(await W.modAction(u, "timeout")) }, "Timeout"));
      if (can("ban")) acts.append(el("button", { type: "button", class: "bad", onclick: async () => done(await W.modAction(u, "ban")) }, "Ban"));
    }
    return el("div", { class: "urow" },
      xav(nm, u.avatar, 40),
      el("div", {}, el("div", { class: "un" }, nm, " ", u.is_staff ? el("span", { class: "stg staff" }, "Staff") : null),
        el("small", { class: "uid", title: "Click to copy the Discord ID", onclick: () => copyId(u.discord_id) }, "@" + (u.username || "?") + " · " + u.discord_id)),
      el("div", { class: "um" }, el("div", {}, stg(u.status), u.status === "timeout" && u.until_at ? el("small", {}, "until " + fmt(u.until_at)) : null),
        el("small", {}, "Registered " + fmt(u.created_at) + " · " + u.app_count + " application" + (u.app_count === 1 ? "" : "s"))),
      acts);
  }
  async function viewUser(id) {
    let d; try { d = await call("mod_user_detail", { p_discord_id: id }); } catch (e) { d = null; }
    if (!d) return toast("Couldn't load that user");
    const nm = d.display_name || d.username || id;
    const refresh = async ok => { if (ok) { document.querySelectorAll(".dlg").forEach(x => x.remove()); await viewUser(id); const b = $("#ubody"); if (b && S.page === "users") { try { const r = await call("list_site_users", { p_q: U.q, p_status: U.st, p_limit: 500 }); U.rows = r; draw(b); } catch (e) {} } } };
    const btns = el("div", { class: "row", style: "justify-content:flex-start;flex-wrap:wrap" });
    const add = (t, a, cls, cap) => { if (can(cap) && !d.protected) btns.append(el("button", { type: "button", class: cls || "", onclick: async () => refresh(await W.modAction(d, a)) }, t)); };
    if (d.status === "banned") add("Unban", "unban", "ok", "ban");
    else { if (d.status === "timeout") add("Remove timeout", "untimeout", "ok", "timeout"); else add("Timeout", "timeout", "warn", "timeout"); add("Ban from website", "ban", "bad", "ban"); }
    add("Warn", "warn", "", "warn"); add("Add note", "note", "", "note");
    dlg("User profile", (box, close) => {
      box.append(el("div", { class: "uprof" }, xav(nm, d.avatar, 64), el("div", {}, el("h3", {}, nm), el("div", { class: "hint" }, "@" + (d.username || "?") + " · " + d.discord_id), stg(d.status))),
        el("dl", { class: "kv" },
          el("dt", {}, "Registered"), el("dd", {}, fmt(d.registered)), el("dt", {}, "Last login"), el("dd", {}, fmt(d.last_sign_in)),
          d.status !== "active" ? [el("dt", {}, "Reason"), el("dd", {}, d.reason || "—"), el("dt", {}, "By"), el("dd", {}, (d.by || "—") + " · " + fmt(d.since)), d.until ? [el("dt", {}, "Until"), el("dd", {}, fmt(d.until))] : null] : null),
        d.protected ? el("div", { class: "hint" }, d.is_owner ? "This is the Owner. They can't be moderated." : "You can't moderate this person (staff rules).") : null, btns,
        el("h4", { style: "margin-top:12px" }, "Applications (" + d.applications.length + ")"),
        d.applications.length ? el("div", {}, ...d.applications.map(a => el("div", { class: "hint" }, (a.type || "") + " · " + (a.status || "") + " · " + fmt(a.created_at)))) : el("div", { class: "hint" }, "None."),
        el("h4", { style: "margin-top:12px" }, "Moderation history (" + d.history.length + ")"),
        d.history.length ? el("div", { style: "max-height:220px;overflow:auto" }, ...d.history.map(h => el("div", { class: "mlog", style: "grid-template-columns:1fr" },
          el("div", {}, el("b", { class: "act-" + h.action }, h.action.toUpperCase()), " · " + h.actor + " · ", el("span", { class: "t" }, fmt(h.at))),
          h.reason ? el("div", { class: "why", style: "grid-column:1" }, h.reason) : null, h.detail ? el("div", { class: "t" }, h.detail) : null))) : el("div", { class: "hint" }, "Clean record."));
    });
  }
  W.viewUser = viewUser;

  /* ===== Moderation logs ===== */
  const L = { q: "", a: "all" };
  const modlogView = {
    enter(h) {
      const q = el("input", { type: "search", placeholder: "Search member, staff member or reason", value: L.q, "aria-label": "Search logs" });
      const a = el("select", { "aria-label": "Filter by action" }, ...[["all", "All actions"], ["ban", "Bans"], ["unban", "Unbans"], ["timeout", "Timeouts"], ["untimeout", "Timeouts removed"], ["warn", "Warnings"], ["note", "Notes"]].map(([v, t]) => el("option", { value: v }, t)));
      a.value = L.a; const body = el("div", { class: "pgb" });
      const load = async () => {
        let rows; try { rows = await call("list_moderation_log", { p_q: L.q, p_action: L.a, p_limit: 300 }); } catch (e) { return body.replaceChildren(empty("Couldn't load the log")); }
        if (!Array.isArray(rows) || !rows.length) return body.replaceChildren(empty("No moderation actions", "Bans, timeouts, warnings and notes are recorded here."));
        body.replaceChildren(...rows.map(r => el("div", { class: "mlog" },
          el("div", { class: "t" }, fmt(r.at)), el("b", { class: "act-" + r.action }, r.action.toUpperCase()),
          el("div", { class: "who" }, el("b", {}, r.target_name || r.target_id), " ", el("small", {}, r.target_id), el("small", {}, " · by " + r.actor), r.detail ? el("small", {}, " · " + r.detail) : null),
          r.reason ? el("div", { class: "why" }, r.reason) : null)));
      };
      q.addEventListener("input", debounce(() => { L.q = q.value; load(); }, 250)); a.onchange = () => { L.a = a.value; load(); };
      h.append(head("Moderation logs", "Every ban, timeout, warning and note: who did it, to whom, why, and when.", q, a, el("button", { type: "button", onclick: load }, "Refresh")), body);
      body.replaceChildren(empty("Loading…")); load();
    }
  };

  /* ===== Staff management ===== */
  const RANKS = ["Owner", "Co-Owner", "Administrator", "Senior Moderator", "Lead Moderator", "Moderator", "Helper", "Staff"];
  W.RANKS = RANKS;
  const staffView = {
    enter(h) {
      const q = el("input", { type: "text", placeholder: "Discord ID, @username or name", maxlength: "60", "aria-label": "Find a person", autocomplete: "off" });
      const prev = el("div", { id: "addprev" }), list = el("div", { class: "pgb" });
      let found = null;
      const rank = el("select", { "aria-label": "Position" }, ...RANKS.filter(r => r !== "Owner" || (me.role === "admin" && S.me && S.me.caps.indexOf("owner") >= 0)).map(r => el("option", { value: r }, r)));
      rank.value = "Moderator";
      const addBtn = el("button", { type: "button", class: "tg", disabled: "true" }, "Add to staff");
      const look = async () => {
        found = null; addBtn.disabled = true; prev.replaceChildren(el("div", { class: "hint" }, "Looking up…"));
        let r; try { r = await call("lookup_discord_user", { p_query: q.value }); } catch (e) { return prev.replaceChildren(el("div", { class: "derr", style: "color:var(--bad)" }, "Couldn't reach the server")); }
        if (!r || r.error) return prev.replaceChildren(el("div", { class: "hint", style: "color:var(--bad)" }, errText(r && r.error)));
        found = r; addBtn.disabled = false;
        prev.replaceChildren(el("div", { class: "prev" }, xav(r.display_name || r.username, r.avatar, 52), el("div", {}, el("b", {}, r.display_name || r.username || "Unknown"),
          el("div", { class: "hint" }, "@" + (r.username || "?") + " · ID " + r.discord_id + (r.matches > 1 ? " · " + r.matches + " people matched, showing the most recent login" : "")))));
      };
      q.addEventListener("keydown", e => { if (e.key === "Enter") look(); });
      addBtn.onclick = async () => {
        if (!found) return;
        const ok = await W.ask({ title: "Add " + (found.display_name || found.username) + " as " + rank.value + "?", text: "They get staff access to the dashboard and show on the home page under Our Staff Team.", confirm: "Add staff", reason: null });
        if (!ok) return;
        let r; try { r = await call("staff_member_add", { p_discord_id: found.discord_id, p_rank: rank.value }); } catch (e) { return toast("Couldn't reach the server"); }
        if (r && r.ok) { toast("Staff member added"); q.value = ""; prev.replaceChildren(); found = null; addBtn.disabled = true; load(); } else toast(errText(r && r.error), 4500);
      };
      const load = async () => {
        let rows; try { rows = await call("list_staff_members"); } catch (e) { rows = null; }
        if (!Array.isArray(rows)) return list.replaceChildren(empty("Couldn't load staff", "Run the newest files in supabase/migrations."));
        if (!rows.length) return list.replaceChildren(empty("No staff added yet", "Add someone above. They appear on the home page in Our Staff Team."));
        list.replaceChildren(...rows.map(row));
      };
      const row = m => {
        const sel = el("select", { "aria-label": "Position" }, ...RANKS.map(r => el("option", { value: r }, r))); sel.value = m.rank;
        const btns = el("div", { class: "row" });
        if (!m.protected) {
          btns.append(sel,
            el("button", { type: "button", onclick: async () => {
              if (sel.value === m.rank) return toast("That is already their position");
              if (!await W.ask({ title: "Change position?", text: (m.display_name || m.username) + ": " + m.rank + " → " + sel.value, confirm: "Change", reason: null })) return;
              const r = await call("staff_member_update", { p_discord_id: m.discord_id, p_rank: sel.value }); if (r && r.ok) { toast("Position updated"); load(); } else toast(errText(r && r.error), 4500);
            } }, "Save"),
            el("button", { type: "button", title: "Re-read their name and picture from Discord", onclick: async () => { const r = await call("staff_member_update", { p_discord_id: m.discord_id, p_rank: m.rank, p_refresh: true }); if (r && r.ok) { toast("Profile refreshed"); load(); } else toast(errText(r && r.error), 4500); } }, "Refresh"),
            el("button", { type: "button", class: "bad", onclick: async () => {
              if (!await W.ask({ title: "Remove " + (m.display_name || m.username) + " from staff?", text: "Their dashboard access ends immediately and they disappear from the home page.", confirm: "Remove", danger: true, reason: null })) return;
              const r = await call("staff_member_remove", { p_discord_id: m.discord_id }); if (r && r.ok) { toast("Removed"); load(); } else toast(errText(r && (r.error || r)), 4500);
            } }, "Remove"));
        } else btns.append(el("span", { class: "hint" }, "Protected"));
        return el("div", { class: "srow2" }, xav(m.display_name || m.username, m.avatar, 40), el("div", {}, el("b", {}, m.display_name || m.username || "Staff"), " ", el("span", { class: "stg staff" }, m.rank),
          el("div", { class: "hint" }, "@" + (m.username || "?") + " · " + m.discord_id + " · last seen " + (m.last_seen ? rel(m.last_seen) : "never") + " · added by " + (m.added_by || "—"))), btns);
      };
      h.append(head("Staff management", "Add people by Discord ID or name. They show on the home page in Our Staff Team automatically."),
        el("div", { class: "addbox" }, el("h3", {}, "Add staff"), el("div", { class: "row" }, q, el("button", { type: "button", onclick: look }, "Find"), rank, addBtn), prev), list);
      list.replaceChildren(empty("Loading…")); load();
    }
  };

  /* ===== Staff activity (administrators) ===== */
  const A = { days: 30 };
  const activityView = {
    enter(h) {
      const d = el("select", { "aria-label": "Period" }, ...[[7, "Last 7 days"], [30, "Last 30 days"], [90, "Last 90 days"]].map(([v, t]) => el("option", { value: v }, t))); d.value = A.days;
      const body = el("div", { class: "pgb" });
      const load = async () => {
        let r; try { r = await call("staff_activity", { p_days: A.days }); } catch (e) { r = null; }
        if (!r) return body.replaceChildren(empty("Couldn't load activity", "Administrators only. Make sure the newest migration was run."));
        const t = r.totals, box = (n, l) => el("div", { class: "stat" }, el("b", {}, String(n)), el("span", {}, l));
        body.replaceChildren(el("div", { class: "fbstats", style: "margin:8px" }, box(t.applications, "Applications"), box(t.decided, "Decisions"), box(t.mod_actions, "Moderation actions"), box(t.feedback, "Feedback")),
          ...r.staff.map(s => el("div", { class: "srow2" }, xav(s.name, s.avatar, 40, s.status), el("div", {}, el("b", {}, s.name), " ", el("span", { class: "stg staff" }, s.rank),
            el("div", { class: "hint" }, s.status + " · last seen " + (s.last_seen ? rel(s.last_seen) : "never"))),
            el("div", { class: "hint", style: "text-align:right;line-height:1.5" }, s.decisions + " decisions · " + s.mod_actions + " mod actions", el("br"), s.messages + " messages · " + s.claimed_open + " claimed open"))));
      };
      d.onchange = () => { A.days = Number(d.value); load(); };
      h.append(head("Staff activity", "Who is doing what. Administrators only.", d, el("button", { type: "button", onclick: load }, "Refresh")), body);
      body.replaceChildren(empty("Loading…")); load();
    }
  };


  /* ===== Reports (staff file and work user reports) ===== */
  const RC = { spam: "Spam", harassment: "Harassment", inappropriate: "Inappropriate content", cheating: "Cheating / exploiting", ban_evasion: "Ban evasion", other: "Other" };
  const RS = { open: "Open", investigating: "Investigating", resolved: "Resolved", dismissed: "Dismissed" }, RSC = { open: "#ff8fd4", investigating: "#5cc8ff", resolved: "#3ddc97", dismissed: "#aab0c4" };
  const R = { st: "open", rows: [], page: 1, per: 8 };
  const reportsView = {
    enter(h) {
      const st = el("select", { "aria-label": "Filter reports" }, ...[["open", "Open"], ["investigating", "Investigating"], ["resolved", "Resolved"], ["dismissed", "Dismissed"], ["all", "All reports"]].map(([v, t]) => el("option", { value: v }, t)));
      st.value = R.st; const body = el("div", { class: "pgb", id: "rbody" });
      const load = async () => {
        let r; try { r = await call("report_list", { p_status: R.st }); } catch (e) { r = null; }
        if (!Array.isArray(r)) return body.replaceChildren(empty("Reports unavailable", "Run the newest supabase.sql in Supabase, then reload. You also need a Discord staff login."));
        R.rows = r; draw();
      };
      const draw = () => {
        if (!R.rows.length) return body.replaceChildren(empty("No " + (R.st === "all" ? "" : R.st + " ") + "reports", "Use “New report” when a member breaks the rules."));
        const pages = Math.max(1, Math.ceil(R.rows.length / R.per)); if (R.page > pages) R.page = pages;
        const go = n => { R.page = n; draw(); };
        const pager = pages < 2 ? [] : [el("div", { class: "pgtabs pager" }, el("button", { type: "button", disabled: R.page === 1, onclick: () => go(R.page - 1) }, "‹ Prev"), el("span", { class: "hint", style: "align-self:center" }, "Page " + R.page + " of " + pages), el("button", { type: "button", disabled: R.page === pages, onclick: () => go(R.page + 1) }, "Next ›"))];
        body.replaceChildren(...R.rows.slice((R.page - 1) * R.per, R.page * R.per).map(r => el("button", { type: "button", class: "srow2 rrow", onclick: () => openReport(r.id, load) },
          xav(r.target_name, r.target_avatar, 40), el("div", { style: "flex:1;min-width:0;text-align:left" }, el("b", {}, "#" + r.id + " · " + r.target_name), " ", el("span", { class: "stg", style: "color:" + RSC[r.status] }, RS[r.status]), " ", el("span", { class: "hint", style: "margin:0" }, RC[r.category] || r.category),
            el("div", { class: "hint", style: "margin:2px 0 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis" }, r.preview)),
          el("div", { class: "hint", style: "text-align:right;flex:none" }, "by " + r.reporter_name, el("br"), rel(r.created_at) + (r.notes ? " · " + r.notes + " note" + (r.notes > 1 ? "s" : "") : "") + (r.against > 1 ? " · " + r.against + " vs. user" : "")))), ...pager);
      };
      st.onchange = () => { R.st = st.value; R.page = 1; load(); };
      h.append(head("User reports", "Report a member for staff to look into. Everyone on staff can file; Senior Moderators and up work the queue.", st, el("button", { type: "button", class: "go", onclick: () => newReport(load) }, "New report"), el("button", { type: "button", onclick: load }, "Refresh")), body);
      body.replaceChildren(empty("Loading…")); load();
    }
  };
  function newReport(done) {
    W.dlg("New report", (box, close) => {
      const id = el("input", { type: "text", inputmode: "numeric", placeholder: "Discord ID, e.g. 1271246652421701633", maxlength: "25" }), who = el("div", { class: "hint" });
      const cat = el("select", {}, ...Object.entries(RC).map(([v, t]) => el("option", { value: v }, t))), det = el("textarea", { rows: "5", maxlength: "2000", placeholder: "What happened? Include where and when (10+ characters)." }), err = el("div", { class: "derr" });
      const find = el("button", { type: "button", onclick: async () => { const v = id.value.trim(); if (!v) return; try { const r = await call("find_user", { p_q: v }); const u = Array.isArray(r) ? r[0] : null; who.textContent = u ? "Found: " + (u.display_name || u.username) : "No website member with that name or ID (you can still file the report)."; if (u && u.id) id.value = u.id; } catch (e) { who.textContent = "Lookup unavailable."; } } }, "Look up");
      box.append(el("label", {}, "Who (Discord ID or username)"), el("div", { style: "display:flex;gap:8px" }, id, find), who, el("label", {}, "Reason"), cat, el("label", {}, "Details"), det, err,
        el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Cancel"), el("button", { type: "button", class: "go", onclick: async () => {
          err.textContent = ""; const r = await call("report_create", { p_target_id: id.value.trim(), p_category: cat.value, p_details: det.value });
          if (r && r.ok) { toast("Report #" + r.id + " filed"); close(null); done && done(); } else err.textContent = ({ badid: "Enter the member's numeric Discord ID (use Look up with their name).", short: "Add a few more details (10+ characters).", ratelimit: "Too many reports this hour.", login: "Log in with Discord to file reports." })[r && r.error] || "Couldn't file the report.";
        } }, "File report")));
    });
  }
  async function openReport(id, done) {
    let r; try { r = await call("report_get", { p_id: id }); } catch (e) { r = null; } if (!r) return toast("Couldn't load that report");
    W.dlg("Report #" + id, (box, close) => {
      const reload = async () => { close(null); await done(); openReport(id, done); };
      const act = (label, fn, cls) => el("button", { type: "button", class: cls || "", onclick: async () => { const x = await fn(); if (x && x.ok) { toast("Updated"); reload(); } else toast(x && x.error === "forbidden" ? "Senior Moderators and up only" : x && x.error === "claimed" ? "Already claimed by " + x.by : "Couldn't update", 3500); } }, label);
      const row = el("div", { class: "row", style: "justify-content:flex-start;flex-wrap:wrap" });
      if (can("claim")) { if (!r.assigned_id) row.append(act("Claim", () => call("report_update", { p_id: id, p_claim: true }), "go")); ["investigating", "resolved", "dismissed", "open"].filter(s => s !== r.status).forEach(s => row.append(act({ investigating: "Investigating", resolved: "Resolve", dismissed: "Dismiss", open: "Reopen" }[s], () => call("report_update", { p_id: id, p_status: s })))); }
      if (can("userinfo")) row.append(el("button", { type: "button", onclick: () => { close(null); W.viewUser(r.target_id); } }, "View user"));
      const note = el("textarea", { rows: "2", maxlength: "1000", placeholder: "Add a note for staff" });
      box.append(el("div", { class: "uprof" }, xav(r.target_name, r.target_avatar, 56), el("div", {}, el("h3", {}, r.target_name), el("div", { class: "hint" }, r.target_id + " · site status: " + (r.state || "active")), el("span", { class: "stg", style: "color:" + RSC[r.status] }, RS[r.status]))),
        el("dl", { class: "kv" }, el("dt", {}, "Reason"), el("dd", {}, RC[r.category] || r.category), el("dt", {}, "Filed by"), el("dd", {}, r.reporter_name + " · " + fmt(r.created_at)), el("dt", {}, "Handled by"), el("dd", {}, r.assigned_name || "Nobody yet"),
          r.handled_by ? [el("dt", {}, "Closed by"), el("dd", {}, r.handled_by + " · " + fmt(r.handled_at))] : null),
        el("div", { class: "plain", style: "white-space:pre-wrap;text-align:left" }, r.details), row,
        el("h4", { style: "margin:14px 0 6px" }, "Notes (" + r.notes.length + ")"), ...(r.notes.length ? r.notes.map(n => el("div", { class: "hint", style: "margin:4px 0" }, el("b", {}, n.author), " · " + fmt(n.at) + " — " + n.body)) : [el("div", { class: "hint" }, "No notes yet.")]),
        ...(can("note") ? [note, el("div", { class: "row" }, el("button", { type: "button", onclick: async () => { const x = await call("report_note", { p_id: id, p_body: note.value }); if (x && x.ok) reload(); else toast("Write a note first"); } }, "Add note"))] : []));
    });
  }

  /* ===== Notices (staff announcements board) ===== */
  const noticesView = {
    enter(h) {
      const body = el("div", { class: "pgb" });
      const load = async () => {
        let r; try { r = await call("notice_list"); } catch (e) { r = null; }
        if (!Array.isArray(r)) return body.replaceChildren(empty("Notices unavailable", "Run the newest supabase.sql in Supabase, then reload."));
        if (!r.length) return body.replaceChildren(empty("No notices yet", can("announce") ? "Post the first one with “New notice”." : "Administrators post staff notices here."));
        body.replaceChildren(...r.map(n => el("div", { class: "plain", style: "text-align:left;margin:8px" + (n.pinned ? ";border-color:var(--pink)" : "") },
          el("div", { style: "display:flex;gap:10px;align-items:center" }, xav(n.author_name, n.avatar, 32), el("div", { style: "flex:1" }, el("b", {}, (n.pinned ? "📌 " : "") + n.title), el("div", { class: "hint", style: "margin:0" }, n.author_name + " · " + fmt(n.created_at))),
            can("announce") ? [el("button", { type: "button", onclick: async () => { await call("notice_manage", { p_id: n.id, p_action: n.pinned ? "unpin" : "pin" }); load(); } }, n.pinned ? "Unpin" : "Pin"),
              el("button", { type: "button", class: "bad", onclick: async () => { if (await W.ask({ title: "Delete this notice?", text: n.title, confirm: "Delete", danger: true })) { await call("notice_manage", { p_id: n.id, p_action: "delete" }); load(); } } }, "Delete")] : null),
          el("div", { style: "white-space:pre-wrap;margin-top:8px" }, n.body))));
      };
      const tools = can("announce") ? [el("button", { type: "button", class: "go", onclick: () => W.dlg("New notice", (box, close) => {
        const t = el("input", { type: "text", maxlength: "120", placeholder: "Title" }), b = el("textarea", { rows: "6", maxlength: "3000", placeholder: "What should staff know?" }), pin = el("input", { type: "checkbox" }), err = el("div", { class: "derr" });
        box.append(el("label", {}, "Title"), t, el("label", {}, "Message"), b, el("label", {}, pin, " Pin to the top"), err, el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Cancel"), el("button", { type: "button", class: "go", onclick: async () => {
          const x = await call("notice_post", { p_title: t.value, p_body: b.value, p_pinned: pin.checked }); if (x && x.ok) { toast("Notice posted"); close(null); load(); } else err.textContent = "Add a title and a message."; } }, "Post")));
      }) }, "New notice")] : [];
      h.append(head("Staff notices", "Announcements for the whole staff team.", ...tools, el("button", { type: "button", onclick: load }, "Refresh")), body);
      body.replaceChildren(empty("Loading…")); load();
    }
  };

  /* ===== Stats ===== */
  const statsView = {
    enter(h) {
      const body = el("div", { class: "pgb" });
      const load = async () => {
        const [si, as] = await Promise.all([can("userinfo") ? call("server_info").catch(() => null) : null, can("apps_view") ? call("app_stats").catch(() => null) : null]);
        const box = (n, l) => el("div", { class: "stat" }, el("b", {}, String(n)), el("span", {}, l)), out = [];
        if (si) out.push(el("h4", { style: "margin:10px 8px 0" }, "Website"), el("div", { class: "fbstats", style: "margin:8px" }, box(si.members, "Members"), box(si.banned, "Banned"), box(si.timed_out, "Timed out"), box(si.staff + " (" + si.staff_online + " online)", "Staff"), box(si.feedback_new, "New feedback")));
        if (as) {
          const bars = (o, title) => { const e = Object.entries(o || {}), mx = Math.max(1, ...e.map(x => x[1])); return el("div", { class: "plain", style: "text-align:left;margin:8px" }, el("b", {}, title), ...(e.length ? e.map(([k, v]) => el("div", { style: "display:flex;align-items:center;gap:10px;margin-top:8px" }, el("span", { style: "width:120px;flex:none;text-transform:capitalize" }, k), el("div", { style: "flex:1;height:10px;border-radius:99px;background:rgba(255,255,255,.07);overflow:hidden" }, el("div", { style: "height:100%;width:" + Math.round(v / mx * 100) + "%;background:linear-gradient(90deg,#8b5cf6,#ff4fb8)" })), el("b", {}, String(v)))) : [el("div", { class: "hint" }, "Nothing yet.")])); };
          out.push(el("h4", { style: "margin:10px 8px 0" }, "Applications"), el("div", { class: "fbstats", style: "margin:8px" }, box(as.total, "Total"), box(as.today, "Last 24 hours"), box(as.week, "Last 7 days"), box(as.unclaimed_open, "Waiting for a reviewer")), bars(as.by_status, "By status"), bars(as.by_type, "By type"),
            el("div", { class: "hint", style: "margin:8px" }, as.closed_types && as.closed_types.length ? "Closed right now: " + as.closed_types.join(", ") : "All application types are open."));
        }
        body.replaceChildren(...(out.length ? out : [empty("Stats unavailable", "Your rank can't see these numbers, or the newest supabase.sql hasn't been run.")]));
      };
      h.append(head("Stats", "Live numbers for the website and applications.", el("button", { type: "button", onclick: load }, "Refresh")), body);
      body.replaceChildren(empty("Loading…")); load();
    }
  };
  pages.reports = reportsView; pages.notices = noticesView; pages.stats = statsView;

  /* ===== pages with tabs (keeps the navbar to 10 buttons) ===== */
  function tabbed(key, list) {
    return {
      enter(h) {
        const avail = list.filter(t => t.show());
        if (!avail.length) return;
        const st = (tabbed.state = tabbed.state || {}); let cur = avail.find(t => t.id === st[key]) || avail[0];
        const bar = el("div", { class: "pgtabs", role: "tablist" }), body = el("div", {});
        const draw = () => { st[key] = cur.id; body.replaceChildren(); bar.replaceChildren(...avail.map(t => el("button", { type: "button", role: "tab", class: t === cur ? "on" : "", "aria-selected": String(t === cur), onclick: () => { cur = t; draw(); } }, t.label))); if (cur.leave) cur.leave(); cur.view.enter(body); };
        h.append(avail.length > 1 ? bar : el("div"), body); draw();
      },
      leave() { const st = tabbed.state || {}; const t = list.find(x => x.id === st[key]); if (t && t.view.leave) t.view.leave(); }
    };
  }
  pages.users = tabbed("users", [
    { id: "members", label: "Members", show: () => can("users"), view: usersView },
    { id: "log", label: "Moderation log", show: () => can("logs"), view: modlogView }]);
  pages.team = tabbed("team", [
    { id: "roster", label: "Staff", show: () => can("staff_manage"), view: staffView },
    { id: "activity", label: "Activity", show: () => can("activity"), view: activityView },
    { id: "access", label: "Access codes", show: () => can("staff_manage"), view: { enter(h) {
      h.append(head("Access codes and Discord roles", "The original staff access manager: backup codes, role overrides and who has been given access. Open it here."),
        el("div", { class: "plain" }, el("b", {}, "Staff access manager"), "Create or revoke backup codes and change a person's access level.", el("div", { style: "margin-top:12px" }, el("button", { type: "button", class: "tg", onclick: () => { try { $("#stfNew").hidden = true; $("#stfModal").hidden = false; loadStaff(); } catch (e) { toast("Couldn't open the access manager"); } } }, "Open access manager"))));
    } } }]);

  /* ===== nav wiring ===== */
  const NAV = { navHome: "apps", navUsers: "users", navReports: "reports", stf: "team", navChat: "chat", navNotices: "notices", navStats: "stats" };
  const LABEL = { navHome: "Home", navUsers: "Users", navReports: "Reports", stf: "Team", navChat: "Chat", navNotices: "Notices", navStats: "Stats" };
  function markNav() {
    let on = S.page === "apps" ? "navHome" : Object.keys(NAV).find(k => NAV[k] === S.page);
    document.querySelectorAll("#nvList .nb").forEach(b => { const a = b.id === on || (b.id === "manage" && $("#mng") && !$("#mng").hidden); b.classList.toggle("on", a); if (a) b.setAttribute("aria-current", b.id === on ? "page" : "false"); else b.removeAttribute("aria-current"); });
    const c = $("#nvCur"); if (c) c.textContent = LABEL[on] || "Menu";
  }
  W.markNav = markNav;
  async function refreshMe() {
    S.meErr = "";
    try { S.me = await call("staff_me"); if (!S.me || S.me.error) { S.meErr = S.me && S.me.error ? String(S.me.error) : "no answer"; S.me = null; } } catch (e) { S.me = null; S.meErr = (e && e.message) || "request failed"; }
    const show = (id, v) => { const b = $("#" + id); if (b) b.hidden = !v; };
    const adm = typeof me !== "undefined" && me && me.role === "admin", rv = adm || (typeof me !== "undefined" && me && me.role === "reviewer");
    const anyStaff = !!(S.me ? S.me.discord : (typeof me !== "undefined" && me && me.role));
    show("navReports", anyStaff); show("navNotices", anyStaff); show("navStats", S.me ? (can("apps_view") || can("userinfo")) : !!anyStaff);
    if (S.me) { show("navChat", !!(S.me.discord && can("chat"))); show("navUsers", can("users") || can("logs")); show("stf", can("staff_manage") || can("activity")); }
    else { /* database not updated yet (or lookup failed): still show the buttons by dashboard role so nothing silently disappears */ show("navChat", rv); show("navUsers", adm); show("stf", adm); }
    if (S.page !== "apps" && S.me && !pageAllowed(S.page)) setPage("apps");
    markNav();
  }
  const pageAllowed = p => ({ users: can("users") || can("logs"), team: can("staff_manage") || can("activity"), chat: !!(S.me && S.me.discord), reports: !!(S.me && S.me.discord), notices: !!(S.me && S.me.discord), stats: can("apps_view") || can("userinfo") }[p] !== false);
  W.refreshMe = refreshMe;
  const origApply = window.applyRole;
  window.applyRole = function () { origApply(); refreshMe(); };
  const closeMenu = () => { const n = $("#nvList"), t = $("#nvToggle"); if (n) n.classList.remove("open"); if (t) t.setAttribute("aria-expanded", "false"); };
  const tg = $("#nvToggle"); if (tg) tg.addEventListener("click", () => { const n = $("#nvList"), o = n.classList.toggle("open"); tg.setAttribute("aria-expanded", String(o)); });
  document.addEventListener("click", e => { if (e.target.closest && e.target.closest("#nvList .nb")) { closeMenu(); setTimeout(markNav, 0); } });
  const on = (id, f) => { const b = $("#" + id); if (b) b.addEventListener("click", f); };
  on("navHome", () => { try { view = "apps"; sel = null; } catch (e) {} setPage("apps"); });
  on("navUsers", () => setPage("users")); on("navChat", () => setPage("chat")); on("navReports", () => setPage("reports")); on("navNotices", () => setPage("notices")); on("navStats", () => setPage("stats"));
  const stf = $("#stf"); if (stf) { stf.onclick = null; stf.addEventListener("click", () => setPage("team")); }
  on("manage", () => setTimeout(markNav, 0));
  on("logout", () => { S.me = null; setPage("apps"); });
  document.querySelectorAll("#nvList .nb").forEach(b => { if (NAV[b.id]) b.dataset.pg = NAV[b.id]; });
  if (staff && me && me.role) refreshMe(); else markNav();
})();
