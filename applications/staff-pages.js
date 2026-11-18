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
    const avOf = u => (typeof u === "string" && /^data:image\/(jpeg|png|webp);base64,/.test(u)) ? u : window.avOf ? window.avOf(u) : (/^https:\/\//.test(u || "") ? u : "");
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
  /* shrink an uploaded picture to a 256px square JPEG so it stays small */
  const shrinkImg = file => new Promise(res => { const fr = new FileReader(); fr.onload = () => { const im = new Image(); im.onload = () => { const n = 256, c = document.createElement("canvas"); c.width = c.height = n; const k = Math.max(n / im.width, n / im.height), w = im.width * k, h = im.height * k; const x = c.getContext("2d"); x.drawImage(im, (n - w) / 2, (n - h) / 2, w, h); res(c.toDataURL("image/jpeg", .85)); }; im.onerror = () => res(null); im.src = fr.result; }; fr.onerror = () => res(null); fr.readAsDataURL(file); });
  W.shrinkImg = shrinkImg;
  function profileDlg(m, done) {
    W.dlg("Name & photo: " + (m.display_name || m.username), (box, close) => {
      let pic = null, clear = false, clearName = false;
      const nm = el("input", { type: "text", maxlength: "40", placeholder: m.display_name || "Name", value: m.custom_name || "", "aria-label": "Name on the home page" });
      const prev = el("div", { class: "pprev" }), file = el("input", { type: "file", accept: "image/png,image/jpeg,image/webp", "aria-label": "Upload picture" }), err = el("div", { class: "derr" });
      const draw = () => prev.replaceChildren(xav(nm.value || m.display_name || m.username, pic || (clear ? "" : m.avatar), 84));
      file.onchange = async () => { const f = file.files[0]; if (!f) return; const u = await shrinkImg(f); if (!u) { err.textContent = "That file isn't a usable image."; return; } err.textContent = ""; pic = u; clear = false; draw(); };
      nm.oninput = draw; draw();
      box.append(el("p", { class: "hint" }, "This is what shows on the home page under Our Staff Team. Leave it empty to use their Discord name and picture."), prev,
        el("label", {}, "Name shown on the home page"), nm, el("label", {}, "Picture (upload an image)"), file, err,
        el("div", { class: "row", style: "justify-content:flex-start;flex-wrap:wrap" },
          el("button", { type: "button", onclick: () => { pic = null; clear = true; draw(); } }, "Use Discord picture"),
          el("button", { type: "button", onclick: () => { nm.value = ""; clearName = true; draw(); } }, "Use Discord name")),
        el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Cancel"), el("button", { type: "button", class: "go", onclick: async () => {
          const r = await call("staff_member_profile", { p_discord_id: m.discord_id, p_name: nm.value.trim() || null, p_avatar: pic, p_clear_avatar: clear, p_clear_name: clearName && !nm.value.trim() });
          if (r && r.ok) { toast("Saved. The home page updates right away."); close(true); if (done) done(); } else err.textContent = errText(r && r.error);
        } }, "Save")));
    });
  }
  const staffView = {
    enter(h) {
      const q = el("input", { type: "text", placeholder: "Discord ID, @username or name", maxlength: "60", "aria-label": "Find a person", autocomplete: "off" });
      const prev = el("div", { id: "addprev" }), list = el("div", { class: "pgb" });
      let found = null;
      const rank = el("select", { "aria-label": "Position" }, ...RANKS.filter(r => r !== "Owner" || (me.role === "admin" && S.me && S.me.caps.indexOf("owner") >= 0)).map(r => el("option", { value: r }, r)));
      rank.value = "Moderator";
      const addBtn = el("button", { type: "button", class: "tg", disabled: "true" }, "Add to staff");
      const cname = el("input", { type: "text", maxlength: "40", placeholder: "Name on home page (optional)", "aria-label": "Custom name" }), cfile = el("input", { type: "file", accept: "image/png,image/jpeg,image/webp", "aria-label": "Upload picture" }); let cpic = null;
      cfile.onchange = async () => { const f = cfile.files[0]; cpic = f ? await shrinkImg(f) : null; if (!cpic && f) toast("That file isn't a usable image"); };
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
        if (r && r.ok) { if (cname.value.trim() || cpic) await call("staff_member_profile", { p_discord_id: found.discord_id, p_name: cname.value.trim() || null, p_avatar: cpic }); toast("Staff member added"); q.value = ""; cname.value = ""; cfile.value = ""; cpic = null; prev.replaceChildren(); found = null; addBtn.disabled = true; load(); } else toast(errText(r && r.error), 4500);
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
        if (!m.protected || m.discord_id === (S.me && S.me.id)) btns.prepend(el("button", { type: "button", title: "Set the name and picture shown on the home page", onclick: () => profileDlg(m, load) }, "Name & photo"));
        return el("div", { class: "srow2" }, xav(m.display_name || m.username, m.avatar, 40), el("div", {}, el("b", {}, m.display_name || m.username || "Staff"), " ", el("span", { class: "stg staff" }, m.rank),
          el("div", { class: "hint" }, "@" + (m.username || "?") + " · " + m.discord_id + " · last seen " + (m.last_seen ? rel(m.last_seen) : "never") + " · added by " + (m.added_by || "—"))), btns);
      };
      h.append(head("Staff management", "Add people by Discord ID or name. They show on the home page in Our Staff Team automatically."),
        el("div", { class: "addbox" }, el("h3", {}, "Add staff"), el("div", { class: "row" }, q, el("button", { type: "button", onclick: look }, "Find"), rank, addBtn), prev,
          el("div", { class: "row", style: "justify-content:flex-start;flex-wrap:wrap;margin-top:8px" }, el("span", { class: "hint" }, "Optional, for the home page:"), cname, cfile)), list);
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


  /* ===== Reports: anyone can file one without logging in (report/index.html); staff review them here ===== */
  const RC = { spam: "Spam", harassment: "Harassment", inappropriate: "Inappropriate content", cheating: "Cheating / exploiting", ban_evasion: "Ban evasion", scam: "Scam / phishing", other: "Other" };
  const RS = { open: "Open", investigating: "Investigating", reviewed: "Reviewed", resolved: "Resolved", dismissed: "Dismissed" }, RSC = { open: "#ff8fd4", investigating: "#5cc8ff", reviewed: "#ffc857", resolved: "#3ddc97", dismissed: "#aab0c4" };
  const R = { st: "open", q: "", rows: [], page: 1, per: 8 };
  const reportLink = () => { const u = new URL(location.href); u.hash = ""; u.search = ""; u.pathname = u.pathname.replace(/applications\/?[^/]*$/, "") + "report/"; return u.href; };
  const reportsView = {
    enter(h) {
      const tabs = el("div", { class: "pgtabs", role: "tablist" }), q = el("input", { type: "search", placeholder: "Search name, ID or report #", "aria-label": "Search reports", value: R.q }), body = el("div", { class: "pgb", id: "rbody" });
      const load = async () => {
        let r; try { r = await call("report_list", { p_status: "all", p_q: R.q }); } catch (e) { r = null; }
        if (!Array.isArray(r)) return body.replaceChildren(empty("Reports unavailable", can("reports_view") ? "Run the newest supabase.sql in Supabase, then reload. You also need a Discord staff login." : "Moderators and above can review reports."));
        R.rows = r; drawTabs(); draw();
      };
      const drawTabs = () => tabs.replaceChildren(...[["open", "Open"], ["investigating", "Investigating"], ["reviewed", "Reviewed"], ["resolved", "Resolved"], ["dismissed", "Dismissed"], ["all", "All"]].map(([v, t]) => {
        const n = v === "all" ? R.rows.length : R.rows.filter(x => x.status === v).length;
        return el("button", { type: "button", role: "tab", class: "tab" + (R.st === v ? " on" : ""), "aria-selected": String(R.st === v), onclick: () => { R.st = v; R.page = 1; drawTabs(); draw(); } }, t + " ", el("span", { class: "tcount" }, String(n))); }));
      const draw = () => {
        const rows = R.rows.filter(x => R.st === "all" || x.status === R.st);
        if (!rows.length) return body.replaceChildren(empty("No " + (R.st === "all" ? "" : R.st + " ") + "reports", R.q ? "Nothing matches that search." : "New reports from the public form appear here automatically."));
        const pages = Math.max(1, Math.ceil(rows.length / R.per)); if (R.page > pages) R.page = pages;
        const go = n => { R.page = n; draw(); };
        const pager = pages < 2 ? [] : [el("div", { class: "pgtabs pager" }, el("button", { type: "button", disabled: R.page === 1, onclick: () => go(R.page - 1) }, "‹ Prev"), el("span", { class: "hint", style: "align-self:center" }, "Page " + R.page + " of " + pages), el("button", { type: "button", disabled: R.page === pages, onclick: () => go(R.page + 1) }, "Next ›"))];
        body.replaceChildren(...rows.slice((R.page - 1) * R.per, R.page * R.per).map(r => el("button", { type: "button", class: "srow2 rrow", onclick: () => openReport(r.id, load) },
          xav(r.target_name || "?", r.target_avatar, 40), el("div", { style: "flex:1;min-width:0;text-align:left" }, el("b", {}, "#" + r.id + " · " + (r.target_name || "Unknown")), " ", el("span", { class: "stg", style: "color:" + RSC[r.status] }, RS[r.status]), " ",
            r.state === "banned" ? el("span", { class: "stg", style: "color:#ff6b8b" }, "⛔ Banned") : r.state === "timeout" ? el("span", { class: "stg", style: "color:#ffc857" }, "Timed out") : null, " ",
            el("span", { class: "hint", style: "margin:0" }, (RC[r.category] || r.category) + " · " + (r.source === "public" ? "Anonymous" : "Staff")),
            el("div", { class: "hint", style: "margin:2px 0 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis" }, r.preview)),
          el("div", { class: "hint", style: "text-align:right;flex:none" }, rel(r.created_at), el("br"), (r.notes ? r.notes + " note" + (r.notes > 1 ? "s" : "") : "") + (r.against > 1 ? (r.notes ? " · " : "") + r.against + " vs. user" : "")))), ...pager);
      };
      q.addEventListener("input", debounce(() => { R.q = q.value.trim(); R.page = 1; load(); }, 300));
      const share = el("button", { type: "button", title: "Copy the link people use to report without logging in", onclick: async () => { const l = reportLink(); try { await navigator.clipboard.writeText(l); toast("Public report link copied"); } catch (e) { W.dlg("Public report link", (b) => b.append(el("input", { type: "text", readonly: true, value: l, onclick: e => e.target.select() }))); } } }, "Copy public form link");
      h.append(head("Reports", "Anyone can report someone without an account using the public form. Moderators review, add notes and close them here — including reports about people who are already banned.", q, can("reports_update") ? el("button", { type: "button", class: "go", onclick: () => newReport(load) }, "New report") : null, share, el("button", { type: "button", onclick: load }, "Refresh")), tabs, body);
      body.replaceChildren(empty("Loading…")); load();
    }
  };
  function newReport(done) {
    W.dlg("New report", (box, close) => {
      const id = el("input", { type: "text", inputmode: "numeric", placeholder: "Discord ID, e.g. 1271246652421701633", maxlength: "25" }), who = el("div", { class: "hint" });
      const cat = el("select", {}, ...Object.entries(RC).map(([v, t]) => el("option", { value: v }, t))), det = el("textarea", { rows: "5", maxlength: "2000", placeholder: "What happened? Include where and when (10+ characters)." }), err = el("div", { class: "derr" });
      const find = el("button", { type: "button", onclick: async () => { const v = id.value.trim(); if (!v) return; try { const r = await call("find_user", { p_q: v }); const u = Array.isArray(r) ? r[0] : null; who.textContent = u ? "Found: " + (u.display_name || u.username) : "No website member with that name or ID (you can still file the report)."; if (u && u.id) id.value = u.id; } catch (e) { who.textContent = "Lookup failed."; } } }, "Look up");
      box.append(el("label", {}, "Who (Discord ID or username)"), el("div", { style: "display:flex;gap:8px" }, id, find), who, el("label", {}, "Reason"), cat, el("label", {}, "Details"), det, err,
        el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Cancel"), el("button", { type: "button", class: "go", onclick: async () => {
          err.textContent = ""; const r = await call("report_create", { p_target_id: id.value.trim(), p_category: cat.value, p_details: det.value });
          if (r && r.ok) { toast("Report #" + r.id + " filed"); close(null); done && done(); } else err.textContent = ({ badid: "Enter the member's numeric Discord ID (use Look up with their name).", short: "Add a few more details (10+ characters).", ratelimit: "Too many reports this hour.", login: "Log in with Discord to file reports.", forbidden: "Moderators and above can file reports here. Everyone else can use the public form." })[r && r.error] || "Couldn't file the report.";
        } }, "File report")));
    });
  }
  const linkify = t => String(t || "").split(/(https:\/\/[^\s]+)/g).map(x => /^https:\/\//.test(x) ? el("a", { href: x, target: "_blank", rel: "noopener noreferrer nofollow" }, x) : x);
  async function openReport(id, done) {
    let r; try { r = await call("report_get", { p_id: id }); } catch (e) { r = null; } if (!r) return toast("Couldn't load that report");
    W.dlg("Report #" + id, (box, close) => {
      const reload = async () => { close(null); await done(); openReport(id, done); };
      const act = (label, fn, cls) => el("button", { type: "button", class: cls || "", onclick: async () => { const x = await fn(); if (x && x.ok) { toast("Updated"); reload(); } else toast(x && x.error === "forbidden" ? "You don't have permission to update reports" : x && x.error === "claimed" ? "Already claimed by " + x.by : "Couldn't update", 3500); } }, label);
      const row = el("div", { class: "row", style: "justify-content:flex-start;flex-wrap:wrap" });
      if (can("reports_update")) {
        if (!r.assigned_id) row.append(act("Claim", () => call("report_update", { p_id: id, p_claim: true }), "go"));
        [["investigating", "Investigating"], ["reviewed", "Mark reviewed"], ["resolved", "Resolve"], ["dismissed", "Dismiss"], ["open", "Reopen"]].filter(([s]) => s !== r.status).forEach(([s, t]) => row.append(act(t, () => call("report_update", { p_id: id, p_status: s }))));
      }
      if (r.target_id && can("userinfo")) row.append(el("button", { type: "button", onclick: () => { close(null); W.viewUser(r.target_id); } }, r.state === "banned" ? "Open banned user" : "View user"));
      if (can("reports_manage")) row.append(el("button", { type: "button", class: "bad", onclick: async () => { if (!await W.ask({ title: "Delete report #" + id + "?", text: "This removes the report, its notes and its record of actions.", confirm: "Delete", danger: true })) return; const x = await call("report_delete", { p_id: id }); if (x && x.ok) { toast("Report deleted"); close(null); done(); } } }, "Delete"));
      const note = el("textarea", { rows: "2", maxlength: "1000", placeholder: "Internal staff note (never shown to the reporter)" });
      const kv = [el("dt", {}, "Reason"), el("dd", {}, RC[r.category] || r.category), el("dt", {}, "Filed"), el("dd", {}, (r.source === "public" ? "Anonymous (public form)" : "By " + r.reporter_name) + " · " + fmt(r.created_at)),
        r.where_text ? [el("dt", {}, "Where"), el("dd", {}, r.where_text)] : null, r.contact ? [el("dt", {}, "Contact"), el("dd", {}, r.contact)] : null, r.evidence ? [el("dt", {}, "Evidence"), el("dd", {}, ...linkify(r.evidence))] : null, (r.images && r.images.length) ? [el("dt", {}, "Screenshots"), el("dd", { class: "rimgs" }, ...r.images.map((u, i) => el("button", { type: "button", class: "rimg", title: "Open full size", onclick: () => { const o = el("div", { class: "lightbox", onclick: () => o.remove() }, el("img", { src: u, alt: "Screenshot " + (i + 1) })); document.body.append(o); } }, el("img", { src: u, alt: "Screenshot " + (i + 1) }))))] : null,
        el("dt", {}, "Handled by"), el("dd", {}, r.assigned_name || "Nobody yet"), r.handled_by ? [el("dt", {}, "Closed by"), el("dd", {}, r.handled_by + " · " + fmt(r.handled_at))] : null];
      box.append(el("div", { class: "uprof" }, xav(r.target_name || r.target_label || "?", r.target_avatar, 56), el("div", {}, el("h3", {}, r.target_name || r.target_label || "Unknown"), el("div", { class: "hint" }, (r.target_id || "no Discord ID matched") + " · site status: " + (r.state === "banned" ? "⛔ banned" : r.state || "unknown") + (r.against > 1 ? " · " + r.against + " reports about them" : "")), el("span", { class: "stg", style: "color:" + RSC[r.status] }, RS[r.status]))),
        el("dl", { class: "kv" }, ...kv), el("div", { class: "plain", style: "white-space:pre-wrap;text-align:left" }, r.details), row,
        el("h4", { style: "margin:14px 0 6px" }, "Internal notes (" + r.notes.length + ")"), ...(r.notes.length ? r.notes.map(n => el("div", { class: "hint", style: "margin:4px 0" }, el("b", {}, n.author), " · " + fmt(n.at) + " — " + n.body)) : [el("div", { class: "hint" }, "No notes yet.")]),
        ...(can("reports_update") ? [note, el("div", { class: "row" }, el("button", { type: "button", onclick: async () => { const x = await call("report_note", { p_id: id, p_body: note.value }); if (x && x.ok) reload(); else toast("Write a note first"); } }, "Add note"))] : []),
        el("h4", { style: "margin:14px 0 6px" }, "Record of actions"), el("div", { class: "audit" }, ...r.audit.map(a => el("div", {}, el("b", {}, a.actor), " " + a.action + (a.detail ? " · " + a.detail : ""), el("small", {}, " " + fmt(a.at))))));
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

  /* ---------------- Intel: search, risk-scored dossier, radar ---------------- */
  const riskCol = n => n >= 70 ? "#ff6b8b" : n >= 40 ? "#ffc857" : n >= 20 ? "#5cc8ff" : "#3ddc97";
  const riskWord = n => n >= 70 ? "High" : n >= 40 ? "Elevated" : n >= 20 ? "Watch" : "Low";
  function ring(n) {
    const NS = "http://www.w3.org/2000/svg", c = 2 * Math.PI * 34, sv = document.createElementNS(NS, "svg");
    sv.setAttribute("viewBox", "0 0 80 80"); sv.setAttribute("class", "riskring"); sv.setAttribute("role", "img"); sv.setAttribute("aria-label", "Risk " + n + " of 100");
    sv.innerHTML = '<circle cx="40" cy="40" r="34" fill="none" stroke="rgba(255,255,255,.1)" stroke-width="7"/><circle cx="40" cy="40" r="34" fill="none" stroke="' + riskCol(n) + '" stroke-width="7" stroke-linecap="round" stroke-dasharray="' + (c * n / 100).toFixed(1) + " " + c.toFixed(1) + '" transform="rotate(-90 40 40)"/><text x="40" y="46" text-anchor="middle" fill="#fff" font-size="22" font-weight="700">' + n + "</text>";
    return sv;
  }
  function radar(o) {
    const NS = "http://www.w3.org/2000/svg", ax = [["Banned", o.banned], ["Timeouts", o.timeouts], ["Open reports", o.open_reports], ["Actions 7d", o.actions_7d]];
    const mx = Math.max(5, ...ax.map(a => a[1])), cx = 100, cy = 100, R = 70, pt = (i, f) => { const a = -Math.PI / 2 + i * 2 * Math.PI / ax.length; return [cx + Math.cos(a) * R * f, cy + Math.sin(a) * R * f]; };
    const sv = document.createElementNS(NS, "svg"); sv.setAttribute("viewBox", "0 0 200 200"); sv.setAttribute("class", "radar"); sv.setAttribute("role", "img"); sv.setAttribute("aria-label", "Moderation radar");
    let h = [0.33, 0.66, 1].map(f => '<polygon points="' + ax.map((_, i) => pt(i, f).join(",")).join(" ") + '" fill="none" stroke="rgba(255,255,255,.12)"/>').join("");
    h += ax.map((_, i) => '<line x1="100" y1="100" x2="' + pt(i, 1).join('" y2="') + '" stroke="rgba(255,255,255,.12)"/>').join("");
    h += '<polygon points="' + ax.map((a, i) => pt(i, Math.max(0.04, a[1] / mx)).join(",")).join(" ") + '" fill="rgba(255,79,184,.28)" stroke="#ff4fb8" stroke-width="2"/>';
    h += ax.map((a, i) => { const [x, y] = pt(i, 1.2); return '<text x="' + x + '" y="' + y + '" text-anchor="middle" font-size="9" fill="#d9c8f5">' + a[0] + " " + a[1] + "</text>"; }).join("");
    sv.innerHTML = h; return sv;
  }
  const intelView = {
    enter(h) {
      const inp = el("input", { type: "text", placeholder: "Search a Discord username or ID…", "aria-label": "Search members", autocomplete: "off" });
      const out = el("div", { class: "intelgrid" });
      const row = (u, go) => el("button", { type: "button", class: "ci", onclick: () => go(u.id) }, xav(u.name, u.avatar, 30), el("span", { class: "nm" }, u.name), el("span", { class: "hint", style: "margin:0" }, u.state === "active" ? "" : u.state), el("b", { class: "tag", style: "color:" + riskCol(u.risk) + ";border-color:" + riskCol(u.risk) }, "Risk " + u.risk));
      let seq = 0;
      async function overview() {
        const my = ++seq; out.replaceChildren(empty("Loading…"));
        const o = await call("intel_overview").catch(() => null); if (my !== seq) return;
        if (!o || o.error) return out.replaceChildren(empty("Intel unavailable", "Moderators and above can use this, and the newest supabase.sql must be run."));
        const mx = Math.max(1, ...o.by_day.map(d => d.n));
        out.replaceChildren(
          el("div", { class: "plain", style: "text-align:center" }, el("b", {}, "Moderation radar"), radar(o)),
          el("div", { class: "plain", style: "text-align:left" }, el("b", {}, "Watchlist"), ...(o.watch.length ? o.watch.map(u => row(u, dossier)) : [el("div", { class: "hint" }, "Nobody is above the watch threshold right now.")])),
          el("div", { class: "plain", style: "text-align:left;grid-column:1/-1" }, el("b", {}, "Moderation actions, last 7 days"), el("div", { class: "bars7" }, ...o.by_day.map(d => el("div", { class: "b7", title: d.d + ": " + d.n }, el("i", { style: "height:" + Math.max(4, d.n / mx * 70) + "px" }), el("span", {}, d.d.slice(4))))))
        );
      }
      async function dossier(id) {
        const my = ++seq; out.replaceChildren(empty("Loading…"));
        const p = await call("intel_profile", { p_id: id }).catch(() => null); if (my !== seq) return;
        if (!p || p.error) return out.replaceChildren(empty("Couldn't load that member", p && p.error ? String(p.error) : ""));
        const c = p.counts, box = (n, l) => el("div", { class: "stat" }, el("b", {}, String(n)), el("span", {}, l));
        out.replaceChildren(
          el("div", { class: "plain dossier", style: "text-align:left;grid-column:1/-1" },
            el("div", { class: "row", style: "justify-content:flex-start;gap:16px;flex-wrap:wrap" }, xav(p.name, p.avatar, 64), el("div", {}, el("h3", { style: "margin:0" }, p.name), el("div", { class: "hint" }, "@" + (p.username || "?") + " · " + p.id), el("div", { class: "hint" }, "Joined " + (p.joined ? fmt(p.joined) : "unknown") + " · last login " + (p.last_login ? rel(p.last_login) : "never")), el("b", { class: "tag", style: "color:" + riskCol(p.risk) + ";border-color:" + riskCol(p.risk) }, riskWord(p.risk) + " risk" + (p.state !== "active" ? " · " + p.state : ""))), ring(p.risk),
              el("div", { style: "margin-left:auto;display:flex;gap:8px" }, can("users") ? el("button", { type: "button", class: "go", onclick: () => W.viewUser(p.id) }, "Open moderation") : null, el("button", { type: "button", onclick: overview }, "Back"))),
            el("div", { class: "fbstats", style: "margin:12px 0" }, box(c.warns, "Warns"), box(c.timeouts, "Timeouts"), box(c.bans, "Bans"), box(c.notes, "Notes"), box(c.reports, "Reports"), box(c.denied + "/" + c.apps, "Apps denied")),
            el("b", {}, "Timeline"), el("div", { class: "tline" }, ...(p.timeline.length ? p.timeline.map(t => el("div", { class: "ti " + t.kind }, el("i", {}), el("div", {}, el("b", {}, t.title), t.text ? " · " + t.text : "", el("div", { class: "hint", style: "margin:0" }, fmt(t.at) + (t.by ? " · " + t.by : ""))))) : [el("div", { class: "hint" }, "Clean record: nothing logged for this member.")]))));
      }
      const go = debounce(async () => {
        const q = inp.value.trim(); if (q.length < 2) return overview();
        const my = ++seq; const r = await call("intel_search", { p_q: q }).catch(() => null); if (my !== seq) return;
        if (!r || r.error) return out.replaceChildren(empty("Search unavailable"));
        out.replaceChildren(el("div", { class: "plain", style: "text-align:left;grid-column:1/-1" }, ...(r.results.length ? r.results.map(u => row(u, dossier)) : [el("b", {}, "No members found"), "Only people who have logged in with Discord can be found."])));
      }, 250);
      inp.addEventListener("input", go);
      document.addEventListener("keydown", W._intelKey = e => { if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k" && S.page === "intel") { e.preventDefault(); inp.focus(); } });
      h.append(head("Intel", "Search anyone who has logged in. Risk score = bans, timeouts, warns, open reports and denied applications.", inp), out);
      overview();
    },
    leave() { document.removeEventListener("keydown", W._intelKey); }
  };
  pages.intel = intelView;
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
  const NAV = { navHome: "apps", navUsers: "users", navReports: "reports", stf: "team", navChat: "chat", navNotices: "notices", navStats: "stats", navIntel: "intel", navDM: "dm" };
  const LABEL = { navHome: "Home", navUsers: "Users", navReports: "Reports", stf: "Team", navChat: "Chat", navNotices: "Notices", navStats: "Stats", navIntel: "Intel", navDM: "Messages" };
  function markNav() {
    let on = S.page === "apps" ? "navHome" : Object.keys(NAV).find(k => NAV[k] === S.page);
    document.querySelectorAll("#nvList .nb").forEach(b => { const a = b.id === on || (b.id === "manage" && $("#mng") && !$("#mng").hidden); b.classList.toggle("on", a); if (a) b.setAttribute("aria-current", b.id === on ? "page" : "false"); else b.removeAttribute("aria-current"); });
    const c = $("#nvCur"); if (c) c.textContent = LABEL[on] || "Menu";
  }
  W.markNav = markNav;
  W.setBadge = (id, n) => { const b = $("#" + id); if (!b) return; let bd = b.querySelector(".nbadge"); if (n > 0) { if (!bd) { bd = document.createElement("span"); bd.className = "nbadge"; b.append(bd); } bd.textContent = n > 99 ? "99+" : n; } else if (bd) bd.remove(); };
  async function refreshMe() {
    S.meErr = "";
    const prev = S.me; try { const m = await call("staff_me"); if (!m || m.error) { S.meErr = m && m.error ? String(m.error) : "no answer"; S.me = m && m.error === "login" ? null : prev; } else S.me = m; } catch (e) { S.me = prev; S.meErr = (e && e.message) || "request failed"; }   // a hiccup keeps what we already knew
    const show = (id, v) => { const b = $("#" + id); if (b) b.hidden = !v; };
    const adm = typeof me !== "undefined" && me && me.role === "admin", rv = adm || (typeof me !== "undefined" && me && me.role === "reviewer");
    const anyStaff = !!(S.me ? S.me.discord : (typeof me !== "undefined" && me && me.role));
    show("navReports", S.me ? can("reports_view") : !!anyStaff); show("navDM", !!(S.me && S.me.discord && can("chat"))); show("navNotices", anyStaff); show("navStats", S.me ? (can("apps_view") || can("userinfo")) : !!anyStaff);
    if (S.me) { show("navIntel", can("userinfo")); show("navChat", !!(S.me.discord && can("chat"))); show("navUsers", can("users") || can("logs")); show("stf", can("staff_manage") || can("activity")); }
    else { show("navIntel", rv || adm); /* database not updated yet (or lookup failed): still show the buttons by dashboard role so nothing silently disappears */ show("navChat", rv); show("navUsers", adm); show("stf", adm); }
    if (S.page !== "apps" && S.me && !pageAllowed(S.page)) setPage("apps");
    markNav();
  }
  const pageAllowed = p => ({ users: can("users") || can("logs"), team: can("staff_manage") || can("activity"), chat: !!(S.me && S.me.discord), dm: !!(S.me && S.me.discord), reports: can("reports_view"), notices: !!(S.me && S.me.discord), stats: can("apps_view") || can("userinfo"), intel: can("userinfo") }[p] !== false);
  W.refreshMe = refreshMe;
  const origApply = window.applyRole;
  window.applyRole = function () { origApply(); refreshMe().then(() => { pulse(); checkInvite(); }); };
  const closeMenu = () => { const n = $("#nvList"), t = $("#nvToggle"); if (n) n.classList.remove("open"); if (t) t.setAttribute("aria-expanded", "false"); };
  const tg = $("#nvToggle"); if (tg) tg.addEventListener("click", () => { const n = $("#nvList"), o = n.classList.toggle("open"); tg.setAttribute("aria-expanded", String(o)); });
  document.addEventListener("click", e => { if (e.target.closest && e.target.closest("#nvList .nb")) { closeMenu(); setTimeout(markNav, 0); } });
  const on = (id, f) => { const b = $("#" + id); if (b) b.addEventListener("click", f); };
  on("navHome", () => { try { view = "apps"; sel = null; } catch (e) {} setPage("apps"); });
  on("navUsers", () => setPage("users")); on("navChat", () => setPage("chat")); on("navDM", () => setPage("dm")); on("navReports", () => setPage("reports")); on("navNotices", () => setPage("notices")); on("navStats", () => setPage("stats")); on("navIntel", () => setPage("intel"));
  const stf = $("#stf"); if (stf) { stf.onclick = null; stf.addEventListener("click", () => setPage("team")); }
  on("manage", () => setTimeout(markNav, 0));
  on("logout", () => { S.me = null; setPage("apps"); });
  document.querySelectorAll("#nvList .nb").forEach(b => { if (NAV[b.id]) b.dataset.pg = NAV[b.id]; });
  /* presence + unread: every ~20s from every page. Keeps you "online", updates the Chat / Messages badges and (if allowed) shows a desktop alert. */
  let lastTotal = null;
  async function pulse() {
    if (!(S.me && S.me.discord) || typeof staff === "undefined" || !staff) return;
    let r = null; try { r = await call("staff_pulse", { p_away: false }); } catch (e) { return; }
    if (!r) return;
    const onChat = S.page === "chat" || S.page === "dm";
    if (!onChat) { W.setBadge("navChat", r.chat); W.setBadge("navDM", r.dms); }
    const total = (r.chat || 0) + (r.dms || 0);
    if (lastTotal !== null && total > lastTotal && (!onChat || document.hidden)) {
      try { toast("New staff message" + (total - lastTotal > 1 ? "s" : "")); } catch (e) {}
      try { if (window.Notification && Notification.permission === "granted" && document.hidden) new Notification("Will Mac Staff", { body: total + " unread staff message" + (total === 1 ? "" : "s"), silent: true }); } catch (e) {}
    }
    lastTotal = total;
  }
  setInterval(pulse, 20000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) pulse(); });
  /* staff invite links: applications/?invite=CODE. The code waits in this browser while the person logs in with Discord. */
  try { const u = new URL(location.href), c = u.searchParams.get("invite") || (/^\?=/.test(location.search) ? location.search.slice(2).split("&")[0] : ""); if (c && /^[a-z0-9]{10,24}$/i.test(c)) { localStorage.setItem("wm-pending-invite", JSON.stringify({ c: c.toLowerCase(), t: Date.now() })); history.replaceState(null, "", u.pathname + u.hash); } } catch (e) {}
  function checkInvite() { try { const raw = localStorage.getItem("wm-pending-invite"); if (!raw || !(S.me && S.me.discord)) return; localStorage.removeItem("wm-pending-invite"); const p = JSON.parse(raw); if (p && p.c && Date.now() - p.t < 864e5 && W.handleInvite) setTimeout(() => W.handleInvite(p.c), 400); } catch (e) {} }
  W.checkInvite = checkInvite;
  if (staff && me && me.role) refreshMe().then(() => { pulse(); checkInvite(); }); else markNav();
})();
