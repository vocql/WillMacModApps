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
    if (p === "apps") { h.replaceChildren(); } else { h.replaceChildren(); pages[p].enter(h); }
    if (W.markNav) W.markNav();
    if (p === "apps" && typeof render === "function") { try { render(); } catch (e) {} }
  }
  W.setPage = setPage;

  function head(title, hint, ...tools) { return el("div", { class: "pgh" }, el("h2", {}, title), ...tools, hint ? el("div", { class: "hint" }, hint) : null); }
  const empty = (t, s) => el("div", { class: "plain" }, el("b", {}, t), s || "");
  function debounce(f, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => f(...a), ms); }; }

  /* ===== User management ===== */
  const U = { q: "", st: "all", rows: [], err: "" };
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
      q.addEventListener("input", debounce(() => { U.q = q.value; load(); }, 250)); st.onchange = () => { U.st = st.value; load(); };
      h.append(head("User management", "Everyone who has logged in to the website with Discord. Bans stop them applying, timeouts do it for a while.", q, st, count, el("button", { type: "button", onclick: load }, "Refresh")), body);
      body.replaceChildren(empty("Loading…")); load();
    },
    leave() {}
  };
  function draw(body) {
    if (U.err) return body.replaceChildren(empty("Couldn't load users", U.err));
    if (!U.rows.length) return body.replaceChildren(empty("No users found", "People appear here after they log in with Discord."));
    body.replaceChildren(...U.rows.map(userRow));
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
          h.reason ? el("div", { class: "why", style: "grid-column:1" }, h.reason) : null, h.detail ? el("div", { class: "t" }, h.detail) : null))) : el("div", { class: "hint" }, "Clean record."),
        el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Close")));
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
  const NAV = { navHome: "apps", navFb: "apps", navUsers: "users", stf: "team", navChat: "chat" };
  const LABEL = { navHome: "Home", navFb: "Feedback", navUsers: "Users", stf: "Team", navChat: "Chat" };
  function markNav() {
    let on = S.page === "apps" ? (typeof view !== "undefined" && view === "feedback" ? "navFb" : "navHome") : Object.keys(NAV).find(k => NAV[k] === S.page);
    document.querySelectorAll("#nvList .nb").forEach(b => { const a = b.id === on || (b.id === "manage" && $("#mng") && !$("#mng").hidden); b.classList.toggle("on", a); if (a) b.setAttribute("aria-current", b.id === on ? "page" : "false"); else b.removeAttribute("aria-current"); });
    const c = $("#nvCur"); if (c) c.textContent = LABEL[on] || "Menu";
  }
  W.markNav = markNav;
  async function refreshMe() {
    try { S.me = await call("staff_me"); } catch (e) { S.me = null; }
    const show = (id, v) => { const b = $("#" + id); if (b) b.hidden = !v; };
    show("navChat", !!(S.me && S.me.discord && can("chat")));
    show("navUsers", can("users") || can("logs")); show("stf", can("staff_manage"));
    if (S.page !== "apps" && !pageAllowed(S.page)) setPage("apps");
    markNav();
  }
  const pageAllowed = p => ({ users: can("users") || can("logs"), team: can("staff_manage") || can("activity"), chat: !!(S.me && S.me.discord) }[p] !== false);
  W.refreshMe = refreshMe;
  const origApply = window.applyRole;
  window.applyRole = function () { origApply(); refreshMe(); };
  const closeMenu = () => { const n = $("#nvList"), t = $("#nvToggle"); if (n) n.classList.remove("open"); if (t) t.setAttribute("aria-expanded", "false"); };
  const tg = $("#nvToggle"); if (tg) tg.addEventListener("click", () => { const n = $("#nvList"), o = n.classList.toggle("open"); tg.setAttribute("aria-expanded", String(o)); });
  document.addEventListener("click", e => { if (e.target.closest && e.target.closest("#nvList .nb")) { closeMenu(); setTimeout(markNav, 0); } });
  const on = (id, f) => { const b = $("#" + id); if (b) b.addEventListener("click", f); };
  on("navHome", () => { try { view = "apps"; sel = null; } catch (e) {} setPage("apps"); });
  on("navFb", () => { if (S.page !== "apps") setPage("apps"); });
  on("navUsers", () => setPage("users")); on("navChat", () => setPage("chat"));
  const stf = $("#stf"); if (stf) { stf.onclick = null; stf.addEventListener("click", () => setPage("team")); }
  on("manage", () => setTimeout(markNav, 0));
  on("logout", () => { S.me = null; setPage("apps"); });
  document.querySelectorAll("#nvList .nb").forEach(b => { if (NAV[b.id]) b.dataset.pg = NAV[b.id]; });
  if (staff && me && me.role) refreshMe(); else markNav();
})();
