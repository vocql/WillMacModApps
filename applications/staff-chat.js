/* Will Mac Staff Chat: Discord-style private chat for staff.
   All data lives in Supabase and is only reachable through checked database functions (see supabase/migrations).
   Updates arrive by short polling (every ~3s) and, if Supabase Realtime is reachable, by an instant content-free "nudge". */
(function () {
  "use strict";
  const W = window.WMS, S = W.state, can = W.can, call = W.call, xav = W.xav, errText = W.errText, fmt = W.fmt;
  const EMOJI = ["👍", "❤️", "😂", "🎉", "👀", "✅", "🙏", "😮"];
  const RANK_COL = { Owner: "#ffc857", "Co-Owner": "#ffc857", Administrator: "#ff4fb8", "Senior Moderator": "#b79cff", "Lead Moderator": "#b79cff", Moderator: "#5cc8ff", Helper: "#3ddc97", Staff: "#aab0c4" };
  const LADDER = ["Owner", "Co-Owner", "Administrator", "Senior Moderator", "Lead Moderator", "Moderator", "Helper", "Staff"];
  const MAXRAW = 1400000;
  const CH = { d: null, scope: "", msgs: [], local: [], files: [], reply: null, mentions: new Map(), open: new Set(), cache: { ans: {}, notes: {}, info: {}, fnotes: {}, files: {} },
    stick: true, timer: null, busy: false, ws: null, drafts: {}, lastSig: "", sidesig: "", typingAt: 0, root: null, hits: null, jump: 0, titleBase: "" };
  let mounted = false;
  const $$ = (s, r) => (r || document).querySelector(s);
  const byId = id => (CH.d && CH.d.roster || []).find(r => r.id === id) || (CH.d && CH.d.people || []).find(r => r.id === id);
  const who = id => byId(id) || { id, name: "Former staff", rank: "Staff", status: "offline" };
  const rankCol = r => RANK_COL[r] || "#aab0c4";
  const chan = id => (CH.d && CH.d.channels || []).find(c => c.id === id);
  const curChan = () => CH.scope.startsWith("c:") ? chan(Number(CH.scope.slice(2))) : null;
  const curDM = () => CH.scope.startsWith("d:") ? byId(CH.scope.slice(2)) : null;
  const cx = s => { const m = /^c:(\d+)$/.exec(s || ""); return m ? Number(m[1]) : null; };
  const esc = s => String(s == null ? "" : s);
  const time = t => new Date(t).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const dayKey = t => new Date(t).toDateString();
  const dayLabel = t => { const d = new Date(t), n = new Date(); if (d.toDateString() === n.toDateString()) return "Today"; const y = new Date(n - 864e5); if (d.toDateString() === y.toDateString()) return "Yesterday"; return d.toLocaleDateString([], { weekday: "long", month: "long", day: "numeric", year: "numeric" }); };
  const sizeText = n => n > 1e6 ? (n / 1e6).toFixed(1) + " MB" : Math.max(1, Math.round(n / 1000)) + " KB";

  /* ---------------- realtime nudge (optional) ---------------- */
  const Nudge = {
    ws: null, hb: null, retry: 0, topic: "realtime:wm-staff-chat", ok: false,
    start() {
      if (this.ws || !base || !akey) return;
      let url; try { url = base.replace(/^http/, "ws") + "/realtime/v1/websocket?apikey=" + encodeURIComponent(akey) + "&vsn=1.0.0"; } catch (e) { return; }
      let ws; try { ws = new WebSocket(url); } catch (e) { return; }
      this.ws = ws;
      ws.onopen = () => {
        this.retry = 0;
        ws.send(JSON.stringify({ topic: this.topic, event: "phx_join", payload: { config: { broadcast: { self: false, ack: false }, presence: { key: "" } } }, ref: "1", join_ref: "1" }));
        this.hb = setInterval(() => { try { ws.send(JSON.stringify({ topic: "phoenix", event: "heartbeat", payload: {}, ref: String(Date.now()) })); } catch (e) {} }, 25000);
      };
      ws.onmessage = ev => {
        let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
        if (m.event === "phx_reply" && m.topic === this.topic) this.ok = !!(m.payload && m.payload.status === "ok");
        if (m.event === "broadcast" && m.topic === this.topic && m.payload && m.payload.event === "nudge") tickNow();
      };
      ws.onclose = () => { clearInterval(this.hb); this.ws = null; this.ok = false; if (mounted) { this.retry = Math.min(this.retry + 1, 6); setTimeout(() => mounted && this.start(), 2000 * this.retry); } };
      ws.onerror = () => { try { ws.close(); } catch (e) {} };
    },
    ping() { try { if (this.ws && this.ws.readyState === 1 && this.ok) this.ws.send(JSON.stringify({ topic: this.topic, event: "broadcast", payload: { type: "broadcast", event: "nudge", payload: {} }, ref: String(Date.now()) })); } catch (e) {} },
    stop() { clearInterval(this.hb); const w = this.ws; this.ws = null; this.ok = false; if (w) { w.onclose = null; try { w.close(); } catch (e) {} } }
  };
  W.Nudge = Nudge;

  /* ---------------- page lifecycle ---------------- */
  W.pages.chat = {
    enter(h) {
      if (!(S.me && S.me.discord)) { h.append(el("div", { class: "chatgate" }, el("div", {}, el("b", {}, "Staff Chat needs a Discord login"), "Log out and use “Log in with Discord”. Backup codes can't use chat because messages are tied to a real Discord account."))); return; }
      mounted = true; CH.titleBase = document.title; build(h); CH.stick = true;
      const last = store.get("wm-chat-scope", ""); if (last) CH.scope = last;
      privacyStart(); tick(); Nudge.start(); document.addEventListener("visibilitychange", onVis);
    },
    leave() { stop(); }
  };
  function stop() { privacyStop(); mounted = false; clearTimeout(CH.timer); Nudge.stop(); document.removeEventListener("visibilitychange", onVis); document.title = CH.titleBase || document.title; CH.local = []; CH.files = []; }
  function onVis() { if (!document.hidden) tickNow(); }
  window.addEventListener("beforeunload", () => { try { Nudge.stop(); } catch (e) {} });

  async function tick() {
    clearTimeout(CH.timer); if (!mounted) return;
    if (CH.busy) { CH.timer = setTimeout(tick, 500); return; }
    CH.busy = true; const sc = CH.scope;
    let r = null;
    try { r = await call("chat_poll", { p_scope: sc, p_away: document.hidden, p_read: !document.hidden, p_limit: 60 }); } catch (e) { r = null; }
    CH.busy = false; if (!mounted) return;
    if (r && r.error === "login") { return gate("Your staff session ended", "Log in with Discord again to keep chatting."); }
    if (r && r.channels) apply(r, sc);
    else setBanner("Can't reach the chat right now. Retrying…");
    CH.timer = setTimeout(tick, document.hidden ? 15000 : 3000);
  }
  function tickNow() { if (!mounted) return; clearTimeout(CH.timer); CH.timer = setTimeout(tick, 30); }
  function gate(t, s) { mounted = false; stop(); const h = $("#pages"); if (h) h.replaceChildren(el("div", { class: "chatgate" }, el("div", {}, el("b", {}, t), s))); }
  function setBanner(t) { const b = $$("#chbanner"); if (b) { b.textContent = t || ""; b.style.display = t ? "block" : "none"; } }

  function apply(r, sc) {
    setBanner("");
    const first = !CH.d, prevD = CH.d; CH.d = r;
    if (r.me && r.me.caps) { const was = (S.me.caps || []).join(); S.me.caps = r.me.caps; if (was !== r.me.caps.join()) W.refreshMe(); }
    if (!CH.scope || (!(cx(CH.scope) && chan(cx(CH.scope))) && !(CH.scope.startsWith("d:") && byId(CH.scope.slice(2))))) {
      const g = (r.channels.find(c => c.slug === "staff-chat") || r.channels[0]); CH.scope = g ? "c:" + g.id : ""; if (CH.scope) { tick(); return; }
    }
    if (sc !== CH.scope) { tickNow(); }   // user switched while the request was running
    else {
      const sig = JSON.stringify([r.messages, r.pins, r.other_read]);
      const metaSig = JSON.stringify([r.channels.map(c => [c.id, c.locked, c.slow_mode, c.muted, c.can_post, c.info, c.topic]), r.dms.length]);
      if (sig !== CH.lastSig || first) { notifyNew(prevD, r); CH.lastSig = sig; CH.msgs = r.messages; drawMsgs(); drawPins(); }
      if (metaSig !== CH.metaSig || first) { CH.metaSig = metaSig; drawHeader(); drawComposerState(); }
      drawTyping();
    }
    const sideSig = JSON.stringify([r.channels.map(c => [c.id, c.unread, c.mentions, c.locked, c.muted, c.slug, c.category]), r.dms, r.roster.map(x => [x.id, x.status, x.rank, x.name])]) + CH.scope;
    if (sideSig !== CH.sidesig) { CH.sidesig = sideSig; drawLeft(); drawRight(); }
    const un = r.channels.reduce((n, c) => n + (c.muted ? 0 : c.unread), 0) + r.dms.reduce((n, d) => n + (d.muted ? 0 : d.unread), 0);
    document.title = (un ? "(" + (un > 99 ? "99+" : un) + ") " : "") + CH.titleBase;
    const nb = $("#navChat"); if (nb) { let bd = nb.querySelector(".nbadge"); if (un > 0) { if (!bd) { bd = document.createElement("span"); bd.className = "nbadge"; nb.append(bd); } bd.textContent = un > 99 ? "99+" : un; } else if (bd) bd.remove(); }
  }

  /* desktop / in-app alerts for new messages elsewhere (respects mutes and your notification setting) */
  function notifyNew(prev, r) {
    if (!prev || !r.me) return;
    const mode = r.me.notify || "all"; if (mode === "none") return;
    const pc = {}; prev.channels.forEach(c => pc[c.id] = c);
    let hit = null;
    r.channels.forEach(c => { const p = pc[c.id]; if (!p || c.muted) return; const dm = c.mentions - p.mentions, du = c.unread - p.unread; if (c.id !== cx(CH.scope) || document.hidden) { if (dm > 0) hit = hit || ["#" + c.slug, "You were mentioned"]; else if (du > 0 && mode === "all") hit = hit || ["#" + c.slug, du + " new message" + (du > 1 ? "s" : "")]; } });
    const pd = {}; prev.dms.forEach(d => pd[d.id] = d);
    r.dms.forEach(d => { const p = pd[d.id]; if (d.muted) return; if ((!p && d.unread > 0) || (p && d.unread > p.unread)) { if (d.id !== CH.scope.slice(2) || document.hidden) hit = hit || [(byId(d.id) || {}).name || "Direct message", "New private message"]; } });
    if (!hit) return;
    toast(hit[0] + ": " + hit[1]);
    try { if (window.Notification && Notification.permission === "granted" && document.hidden) new Notification(hit[0], { body: hit[1], silent: true }); } catch (e) {}
  }

  /* ---------------- layout ---------------- */
  function build(h) {
    const root = CH.root = el("div", { class: "chat" });
    const left = el("aside", { class: "cl", id: "chl", "aria-label": "Channels and direct messages" });
    const right = el("aside", { class: "cr", id: "chr", "aria-label": "Staff" });
    const hd = el("div", { class: "chd", id: "chd" });
    const pins = el("div", { class: "pinsbar", id: "chpins", style: "display:none" });
    const msgs = el("div", { class: "msgs", id: "chm", role: "log", "aria-live": "polite" });
    msgs.addEventListener("scroll", () => { CH.stick = msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight < 60; if (msgs.scrollTop < 40 && !CH.loadingOlder && CH.msgs.length >= 60) loadOlder(); });
    const typ = el("div", { class: "typ", id: "chtyp" });
    const banner = el("div", { id: "chbanner", class: "hint", style: "display:none;padding:4px 14px;color:var(--bad)" });
    const cmp = el("div", { class: "cmp", id: "chcmp" });
    const drop = el("div", { class: "drop", id: "chdrop" }, "Drop files to attach");
    const mid = el("section", { class: "cm", id: "chcm" }, hd, pins, banner, msgs, typ, cmp, drop);
    root.append(left, mid, right);
    ["dragenter", "dragover"].forEach(ev => mid.addEventListener(ev, e => { if (e.dataTransfer && [...e.dataTransfer.types].includes("Files")) { e.preventDefault(); drop.classList.add("on"); } }));
    ["dragleave", "drop"].forEach(ev => mid.addEventListener(ev, e => { if (ev === "dragleave" && mid.contains(e.relatedTarget)) return; drop.classList.remove("on"); }));
    mid.addEventListener("drop", e => { if (e.dataTransfer && e.dataTransfer.files.length) { e.preventDefault(); addFiles([...e.dataTransfer.files]); } });
    h.append(root); buildComposer(cmp);
  }

  function drawLeft() {
    const l = $$("#chl"); if (!l || !CH.d) return; const d = CH.d;
    const cats = []; d.channels.forEach(c => { let g = cats.find(x => x[0] === c.category); if (!g) cats.push(g = [c.category, []]); g[1].push(c); });
    const out = [el("div", { class: "cbrand" }, el("span", {}, "#"), "Staff Chat", el("span", { class: "sp", style: "flex:1" }), el("button", { type: "button", class: "nb", title: "Chat settings", style: "padding:3px 8px", onclick: settings }, "⚙"))];
    cats.forEach(([cat, list]) => {
      out.push(el("h4", {}, cat, can("channels") ? el("button", { type: "button", title: "New channel in " + cat, onclick: () => channelForm(null, cat) }, "+") : null));
      list.forEach(c => {
        const on = CH.scope === "c:" + c.id, un = !c.muted && c.unread > 0;
        out.push(el("button", { type: "button", class: "ci" + (on ? " on" : "") + (un ? " un" : ""), style: c.muted ? "opacity:.5" : "", onclick: () => go("c:" + c.id) },
          el("span", { class: "hash" }, "#"), el("span", { class: "nm" }, c.slug), c.locked || !c.can_post ? el("span", { class: "lock", title: c.locked ? "Locked" : "Read only for you" }, "🔒") : null,
          !c.muted && c.mentions > 0 ? el("span", { class: "bdg m", title: "Mentions" }, String(c.mentions)) : (un ? el("span", { class: "bdg" }, c.unread > 99 ? "99+" : String(c.unread)) : null)));
      });
    });
    out.push(el("h4", {}, "Direct messages", el("button", { type: "button", title: "New message", onclick: pickDM }, "+")));
    const dms = d.dms.slice().sort((a, b) => Date.parse(b.last) - Date.parse(a.last));
    dms.forEach(x => { const r = who(x.id); const on = CH.scope === "d:" + x.id;
      out.push(el("button", { type: "button", class: "ci" + (on ? " on" : "") + (x.unread && !x.muted ? " un" : ""), style: x.muted ? "opacity:.5" : "", onclick: () => go("d:" + x.id) }, xav(r.name, r.avatar, 22, r.status), el("span", { class: "nm" }, r.name),
        x.unread && !x.muted ? el("span", { class: "bdg m" }, String(x.unread)) : null)); });
    if (!dms.length) out.push(el("div", { class: "hint", style: "padding:4px 10px" }, "Click a staff member to start a private chat."));
    l.replaceChildren(...out);
  }

  function drawRight() {
    const r = $$("#chr"); if (!r || !CH.d) return; const d = CH.d;
    const unread = {}; d.dms.forEach(x => unread[x.id] = x.unread);
    const groups = {}; d.roster.forEach(m => (groups[m.rank] = groups[m.rank] || []).push(m));
    const order = Object.keys(groups).sort((a, b) => (LADDER.indexOf(a) < 0 ? 99 : LADDER.indexOf(a)) - (LADDER.indexOf(b) < 0 ? 99 : LADDER.indexOf(b)));
    const so = { online: 0, away: 1, offline: 2 };
    const on = d.roster.filter(m => m.status === "online").length;
    const out = [el("h4", {}, "Staff · " + on + " online / " + d.roster.length)];
    order.forEach(rk => {
      out.push(el("h4", { style: "color:" + rankCol(rk) }, rk + " — " + groups[rk].length));
      groups[rk].sort((a, b) => so[a.status] - so[b.status] || a.name.localeCompare(b.name)).forEach(m => {
        out.push(el("button", { type: "button", class: "ci", style: m.status === "offline" ? "opacity:.55" : "", title: m.id === d.me.id ? "That's you" : "Message " + m.name, onclick: () => m.id === d.me.id ? profile(m.id) : go("d:" + m.id) },
          xav(m.name, m.avatar, 28, m.status), el("span", { class: "nm" }, m.name + (m.id === d.me.id ? " (you)" : "")),
          unread[m.id] ? el("span", { class: "bdg m", title: "Unread messages" }, String(unread[m.id])) : el("span", { class: "hint", style: "margin:0;font-size:.66rem", onclick: e => { e.stopPropagation(); profile(m.id); }, title: "View profile" }, "ⓘ")));
      });
    });
    r.replaceChildren(...out);
  }

  function go(scope) {
    if (scope === CH.scope) { closeSide(); return; }
    CH.drafts[CH.scope] = ($$("#chta") || {}).value || ""; CH.scope = scope; store.set("wm-chat-scope", scope);
    CH.msgs = []; CH.local = []; CH.reply = null; CH.lastSig = ""; CH.metaSig = ""; CH.sidesig = ""; CH.stick = true; CH.hits = null;
    const sr = $$(".srch"); if (sr) sr.remove();
    drawMsgs(); drawHeader(); drawComposerState(); const ta = $$("#chta"); if (ta) { ta.value = CH.drafts[scope] || ""; autosize(ta); }
    closeSide(); tickNow();
  }
  function closeSide() { if (CH.root) CH.root.classList.remove("showl", "showr"); }

  function drawHeader() {
    const h = $$("#chd"); if (!h || !CH.d) return; const c = curChan(), dm = curDM();
    const mob = el("button", { type: "button", class: "mob", title: "Channels", onclick: () => CH.root.classList.toggle("showl") }, "☰");
    const mobr = el("button", { type: "button", class: "mob r", title: "Staff", onclick: () => CH.root.classList.toggle("showr") }, "👥");
    const sbtn = el("button", { type: "button", title: "Search messages", onclick: () => searchPanel() }, "🔎");
    const shotb = can("screenshot") ? el("button", { type: "button", id: "chshot", title: "Screenshot this conversation (administrators only, logged)", "aria-label": "Screenshot", onclick: () => shot() }, "📸") : null;
    if (c) {
      h.replaceChildren(mob, el("div", { class: "tt" }, el("b", {}, "# " + c.slug), c.locked ? el("span", { class: "stg timeout", style: "margin-left:8px" }, "Locked") : null, c.slow_mode ? el("span", { class: "stg staff", style: "margin-left:6px" }, "Slow " + c.slow_mode + "s") : null, el("small", {}, c.topic || "")),
        el("button", { type: "button", title: "About this channel", onclick: () => channelInfo(c) }, "ⓘ"),
        el("button", { type: "button", title: c.muted ? "Unmute" : "Mute channel", onclick: async () => { await call("chat_mute", { p_scope: "c:" + c.id, p_muted: !c.muted }); tickNow(); } }, c.muted ? "🔕" : "🔔"), sbtn, shotb, mobr);
    } else if (dm) {
      const mu = (CH.d.dms.find(x => x.id === dm.id) || {}).muted;
      h.replaceChildren(mob, xav(dm.name, dm.avatar, 32, dm.status), el("div", { class: "tt" }, el("b", {}, dm.name), el("small", {}, dm.rank + " · " + dm.status + " · private conversation")),
        el("button", { type: "button", title: "View profile", onclick: () => profile(dm.id) }, "Profile"),
        el("button", { type: "button", title: mu ? "Unmute" : "Mute", onclick: async () => { await call("chat_mute", { p_scope: CH.scope, p_muted: !mu }); tickNow(); } }, mu ? "🔕" : "🔔"), sbtn, shotb, mobr);
    } else h.replaceChildren(mob, el("div", { class: "tt" }, el("b", {}, "Staff Chat")), mobr);
  }

  function drawPins() {
    const p = $$("#chpins"); if (!p) return; const pins = (CH.d && CH.d.pins) || [];
    if (!pins.length) { p.style.display = "none"; return; }
    p.style.display = "flex"; p.replaceChildren(el("b", {}, "📌 " + pins.length + " pinned"), el("span", {}, pins[0].body || "(attachment)"));
    p.onclick = () => W.dlg("Pinned messages", (box, close) => box.append(...pins.map(x => el("button", { type: "button", class: "ci", style: "display:block;height:auto;white-space:normal", onclick: () => { close(null); jumpTo(x.id); } },
      el("b", {}, who(x.author_id).name), el("small", { style: "color:var(--muted)" }, " · " + fmt(x.created_at)), el("div", {}, x.body || "(attachment)"))), el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Close"))));
  }
  function drawTyping() {
    const t = $$("#chtyp"); if (!t) return; const n = ((CH.d && CH.d.typing) || []).map(id => who(id).name);
    t.textContent = !n.length ? "" : n.length === 1 ? n[0] + " is typing…" : n.length === 2 ? n.join(" and ") + " are typing…" : "Several people are typing…";
  }
  function drawComposerState() {
    const cmp = $$("#chcmp"), cbox = $$("#chbox"), np = $$("#chnopost"); if (!cmp || !CH.d) return;
    const c = curChan(), ok = CH.d.can_post !== false;
    if (np) np.remove();
    if (!ok) { cbox.style.display = "none"; cmp.append(el("div", { id: "chnopost", class: "nopost" }, c && c.locked ? "🔒 This channel is locked. Only administrators can post." : "This channel is read only for your rank. Cards and records appear here automatically.")); }
    else cbox.style.display = "";
    const ta = $$("#chta"); if (ta) ta.placeholder = c ? "Message #" + c.slug + "   (type / for commands, @ to mention)" : "Message " + ((curDM() || {}).name || "") ;
  }

  /* ---------------- messages ---------------- */
  function bodyNodes(text, me) {
    const names = (CH.d.roster || []).flatMap(r => [r.name, r.username].filter(x => x && x.length > 1)).sort((a, b) => b.length - a.length).map(x => x.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
    const re = new RegExp("(@everyone|@staff|" + (names.length ? names.map(n => "@" + n).join("|") + "|" : "") + "https?:\\/\\/[^\\s<>\"]+)", "gi");
    const out = []; let last = 0, m;
    while ((m = re.exec(text))) {
      if (m.index > last) out.push(document.createTextNode(text.slice(last, m.index)));
      const t = m[0];
      if (/^https?:/i.test(t)) { const a = el("a", { href: t, target: "_blank", rel: "noopener noreferrer nofollow" }, t); out.push(a); }
      else { const nm = t.slice(1).toLowerCase(), isMe = nm === "everyone" || nm === "staff" || (CH.d.roster.find(r => (r.name || "").toLowerCase() === nm || (r.username || "").toLowerCase() === nm) || {}).id === CH.d.me.id; out.push(el("span", { class: "mn" + (isMe ? " me" : "") }, t)); }
      last = m.index + t.length;
    }
    if (last < text.length) out.push(document.createTextNode(text.slice(last)));
    return out;
  }

  function drawMsgs() {
    const box = $$("#chm"); if (!box || !CH.d) return;
    const prevH = box.scrollHeight, prevTop = box.scrollTop, out = [];
    const c = curChan();
    if (c && c.info && (c.info.purpose || c.info.instructions)) out.push(infoEmbed(c));
    else if (curDM()) out.push(el("div", { class: "card", style: "margin:10px 0" }, el("div", { class: "ct" }, xav(curDM().name, curDM().avatar, 48), el("div", {}, el("b", { class: "n" }, curDM().name), el("div", { class: "hint" }, "This is the start of your private conversation. Only the two of you can read it.")))));
    let prev = null;
    CH.msgs.forEach(m => {
      if (!prev || dayKey(prev.created_at) !== dayKey(m.created_at)) { out.push(el("div", { class: "dsep" }, dayLabel(m.created_at))); prev = null; }
      const sysKind = ["application", "decision", "feedback", "modlog", "system"].includes(m.kind);
      const grouped = prev && !sysKind && prev.author_id === m.author_id && prev.kind === m.kind && !m.reply_to && Date.parse(m.created_at) - Date.parse(prev.created_at) < 5 * 60000 && !prev.deleted;
      out.push(msgEl(m, grouped)); prev = m;
    });
    if (!CH.msgs.length && !(c && c.info && c.info.purpose)) out.push(el("div", { class: "plain" }, el("b", {}, "No messages yet"), "Say hello."));
    CH.local.forEach(n => out.push(n));
    box.replaceChildren(...out);
    if (CH.prepended) { box.scrollTop = prevTop + (box.scrollHeight - prevH); CH.prepended = false; }
    else if (CH.stick) box.scrollTop = box.scrollHeight;
    else box.scrollTop = prevTop;
    if (CH.jump) { const t = box.querySelector('[data-mid="' + CH.jump + '"]'); if (t) { t.scrollIntoView({ block: "center" }); t.classList.add("hit"); setTimeout(() => t.classList.remove("hit"), 2500); CH.jump = 0; } }
  }

  function infoEmbed(c) {
    const i = c.info || {}, list = a => Array.isArray(a) && a.length ? el("ul", { style: "margin:4px 0 8px 18px" }, ...a.map(x => el("li", {}, x))) : null;
    return el("div", { class: "card", style: "margin:10px 0;--fc:var(--violet)" }, el("div", { class: "ct" }, el("b", { class: "n" }, "Welcome to #" + c.slug), el("small", {}, c.category)),
      i.purpose ? el("p", { class: "msgtxt" }, i.purpose) : null,
      i.belongs ? [el("dt", { class: "qa", style: "margin-top:8px;color:var(--pink2);font-weight:700;font-size:.78rem" }, "WHAT BELONGS HERE"), list(i.belongs)] : null,
      i.staff_use ? [el("dt", { style: "color:var(--pink2);font-weight:700;font-size:.78rem" }, "HOW STAFF SHOULD USE IT"), list(i.staff_use)] : null,
      i.instructions ? [el("dt", { style: "color:var(--pink2);font-weight:700;font-size:.78rem" }, "RULES AND INSTRUCTIONS"), list(i.instructions)] : null,
      el("div", { class: "hint" }, "Visible to: " + ({ viewer: "all staff", reviewer: "Senior Moderators and up", admin: "Administrators" }[c.min_access]) + (c.no_helpers ? " (not Helpers)" : "") + " · Posting: " + ({ viewer: "all who can see it", reviewer: "Senior Moderators and up", admin: "Administrators only" }[c.post_min])));
  }

  function msgEl(m, grouped) {
    const a = who(m.author_id), sys = ["application", "decision", "feedback", "modlog"].includes(m.kind) || m.kind === "system";
    const mineMention = (m.mentions || []).includes(CH.d.me.id) || m.mention_all;
    const root = el("div", { class: "msg" + (grouped ? "" : " first") + (mineMention && m.author_id !== CH.d.me.id ? " mine-m" : ""), "data-mid": m.id });
    const gut = el("div", { class: "gut" });
    if (sys) gut.append(el("span", { class: "xav", style: "--s:36px;border-radius:10px" }, el("img", { src: C.logo, alt: "" })));
    else if (grouped) gut.append(el("time", {}, time(m.created_at)));
    else gut.append(xav(a.name, a.avatar, 38, a.status));
    const col = el("div", { class: "mc" });
    if (!grouped) col.append(el("div", { class: "mh" }, el("b", { style: "color:" + (sys ? "var(--pink2)" : "#fff") }, sys ? "Will Mac System" : a.name), sys ? null : el("span", { class: "rk", style: "color:" + rankCol(a.rank) }, a.rank),
      m.kind === "announcement" ? el("span", { class: "stg timeout" }, "Announcement") : null, m.pinned ? el("span", { class: "pinm" }, "📌 pinned") : null, el("time", { title: fmt(m.created_at) }, time(m.created_at))));
    if (m.reply_to && m.reply) col.append(el("div", { class: "rp", onclick: () => jumpTo(m.reply.id) }, el("b", {}, who(m.reply.author_id).name), el("span", {}, m.reply.deleted ? "Original message was deleted" : (m.reply.body || "(attachment)"))));
    if (m.deleted) col.append(el("div", { class: "mb del" }, "This message was deleted."));
    else if (m.kind === "application") col.append(cardApp(m));
    else if (m.kind === "decision") col.append(cardDecision(m));
    else if (m.kind === "feedback") col.append(cardFb(m));
    else if (m.kind === "modlog") col.append(cardMod(m));
    else if (m.kind === "poll") col.append(pollEl(m));
    else {
      if (m.body) col.append(el("div", { class: "mb", style: m.kind === "announcement" ? "border-left:3px solid #ffc857;padding-left:10px" : "" }, ...bodyNodes(esc(m.body)), m.edited_at ? el("span", { class: "ed" }, " (edited)") : null));
      if (m.attachments && m.attachments.length) col.append(attsEl(m));
    }
    if (m.reactions && m.reactions.length && !m.deleted) col.append(el("div", { class: "rxs" }, ...m.reactions.map(r => {
      const mine = r.users.includes(CH.d.me.id);
      return el("button", { type: "button", class: "rx" + (mine ? " me" : ""), title: r.users.map(u => who(u).name).join(", "), onclick: () => react(m.id, r.emoji) }, r.emoji + " ", el("b", {}, String(r.users.length)));
    })));
    if (m.thread_count > 0 && !m.deleted) col.append(el("button", { type: "button", class: "rx", style: "margin-top:5px;color:var(--pink2)", onclick: () => thread(m.id) }, "💬 " + m.thread_count + " repl" + (m.thread_count === 1 ? "y" : "ies")));
    // read receipt on the last message I sent in a DM
    if (CH.scope.startsWith("d:") && m.author_id === CH.d.me.id && !m.deleted && CH.msgs.filter(x => x.author_id === CH.d.me.id && !x.deleted).pop() === m)
      col.append(el("div", { class: "hint", style: "margin:2px 0 0" }, CH.d.other_read && CH.d.other_read >= m.id ? "✓✓ Seen" : "✓ Sent"));
    root.append(gut, col);
    if (!m.deleted && m.kind !== "system") root.append(toolbar(m));
    root.addEventListener("click", e => { if (e.target.closest("button,a,textarea,img,select,input")) return; document.querySelectorAll(".msg.tbo").forEach(x => x !== root && x.classList.remove("tbo")); root.classList.toggle("tbo"); });
    return root;
  }

  function toolbar(m) {
    const tb = el("div", { class: "tb" }), mine = m.author_id === CH.d.me.id, text = ["user", "announcement"].includes(m.kind);
    const b = (t, title, f) => tb.append(el("button", { type: "button", title, "aria-label": title, onclick: e => { e.stopPropagation(); f(e); } }, t));
    b("😀", "React", e => reactPick(m, e.currentTarget));
    if (CH.d.can_post !== false) { b("↩", "Reply", () => { CH.reply = m; drawReply(); const ta = $$("#chta"); if (ta) ta.focus(); }); if (!m.thread_id) b("💬", "Start or open a thread", () => thread(m.id)); }
    if (text && m.body) b("📋", "Copy text", () => { try { navigator.clipboard.writeText(m.body); toast("Copied"); } catch (e) { toast("Couldn't copy"); } });
    if (mine && text) b("✏️", "Edit", () => editMsg(m));
    if (can("pin") && (m.kind !== "announcement" || can("announce"))) b(m.pinned ? "📍" : "📌", m.pinned ? "Unpin" : "Pin", async () => { const r = await call("chat_pin", { p_id: m.id, p_pin: !m.pinned }); if (r !== "ok") toast(errText(r)); tickNow(); });
    if (mine || S.me.role === "admin") b("🗑", "Delete", async () => { if (!await W.ask({ title: "Delete this message?", text: "It is replaced by “This message was deleted.”" + (mine ? "" : " This is logged."), confirm: "Delete", danger: true })) return; const r = await call("chat_delete", { p_id: m.id }); if (r !== "ok") toast(errText(r)); tickNow(); });
    return tb;
  }
  function reactPick(m, anchor) {
    document.querySelectorAll(".pick").forEach(x => x.remove());
    const p = el("div", { class: "pick" }, ...EMOJI.map(e => el("button", { type: "button", onclick: () => { p.remove(); react(m.id, e); } }, e)));
    const row = anchor.closest(".msg"); row.append(p); setTimeout(() => document.addEventListener("click", function f(ev) { if (!p.contains(ev.target)) { p.remove(); document.removeEventListener("click", f); } }), 0);
  }
  async function react(id, e) { const r = await call("chat_react", { p_id: id, p_emoji: e }); if (r !== "ok") toast(errText(r)); tickNow(); }
  function editMsg(m) {
    const row = $$('[data-mid="' + m.id + '"] .mb'); if (!row) return;
    const ta = el("textarea", { maxlength: "2000", "aria-label": "Edit message" }, m.body); ta.value = m.body;
    const save = async () => { const r = await call("chat_edit", { p_id: m.id, p_body: ta.value }); if (r !== "ok") return toast(errText(r)); tickNow(); };
    ta.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); save(); } if (e.key === "Escape") drawMsgs(); });
    row.replaceChildren(el("div", { class: "edbox" }, ta, el("div", { class: "row" }, el("button", { type: "button", onclick: save }, "Save"), el("button", { type: "button", onclick: () => drawMsgs() }, "Cancel"), el("span", { class: "hint" }, "Enter to save · Esc to cancel"))));
    ta.focus();
  }

  /* ---------------- attachments ---------------- */
  function attsEl(m) {
    const w = el("div", { class: "atts" });
    m.attachments.forEach(a => {
      if (/^image\//.test(a.mime)) {
        const ph = el("div", { class: "ph" }, "Loading image…"); w.append(ph);
        getFile(a.id).then(f => { if (!f) return ph.textContent = "Image unavailable"; const img = el("img", { src: f.data, alt: a.name || "image", loading: "lazy", onclick: () => lightbox(f.data, a.name) }); ph.replaceWith(img); });
      } else w.append(el("button", { type: "button", class: "rx", style: "padding:6px 12px", onclick: async () => { const f = await getFile(a.id); if (!f) return toast("File unavailable"); const l = el("a", { href: f.data, download: a.name || "file" }); document.body.append(l); l.click(); l.remove(); } }, "📄 " + (a.name || "file") + " · " + sizeText(a.size)));
    });
    return w;
  }
  async function getFile(id) { if (CH.cache.files[id]) return CH.cache.files[id]; try { const r = await call("chat_file", { p_id: id }); if (r && r.data) CH.cache.files[id] = r; return r; } catch (e) { return null; } }
  function lightbox(src, name) {
    const lb = el("div", { class: "lb", onclick: () => lb.remove() }, el("img", { src, alt: name || "" }), el("a", { href: src, download: name || "image", onclick: e => e.stopPropagation() }, "Download"));
    const k = e => { if (e.key === "Escape") { lb.remove(); document.removeEventListener("keydown", k); } }; document.addEventListener("keydown", k); document.body.append(lb);
  }
  const readURL = f => new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = () => rej(new Error("Couldn't read the file")); r.readAsDataURL(f); });
  async function shrink(f) {
    if (f.type === "image/gif") { if (f.size > MAXRAW) throw new Error("GIFs can be up to 1.4 MB."); return readURL(f); }
    const bmp = await createImageBitmap(f); let s = Math.min(1, 1600 / Math.max(bmp.width, bmp.height)), q = 0.85, out = "";
    for (let i = 0; i < 6; i++) {
      const cv = document.createElement("canvas"); cv.width = Math.max(1, Math.round(bmp.width * s)); cv.height = Math.max(1, Math.round(bmp.height * s));
      const cx2 = cv.getContext("2d"); cx2.drawImage(bmp, 0, 0, cv.width, cv.height);
      out = cv.toDataURL("image/webp", q); if (!out.startsWith("data:image/webp")) out = cv.toDataURL("image/jpeg", q);
      if (out.length * 0.75 < MAXRAW) return out; s *= 0.8; q = Math.max(0.5, q - 0.1);
    }
    throw new Error("That image is too large even after shrinking.");
  }
  const OKF = { "application/pdf": 1, "text/plain": 1, "text/csv": 1, "application/zip": 1, "application/vnd.openxmlformats-officedocument.wordprocessingml.document": 1 };
  async function addFiles(list) {
    for (const f of list) {
      if (CH.files.length >= 4) { toast("Up to 4 files per message"); break; }
      try {
        if (/^image\/(png|jpeg|webp|gif)$/.test(f.type)) CH.files.push({ name: f.name || "image", data: await shrink(f), image: true });
        else if (OKF[f.type]) { if (f.size > MAXRAW) throw new Error("Files can be up to 1.4 MB."); CH.files.push({ name: f.name, data: await readURL(f), image: false }); }
        else throw new Error((f.name || "That file") + " isn't allowed. Use PNG, JPEG, WebP, GIF, PDF, TXT, CSV, ZIP or DOCX.");
      } catch (e) { toast(e.message || "Couldn't add that file", 4500); }
    }
    drawPrevs();
  }
  function drawPrevs() {
    const p = $$("#chprevs"); if (!p) return;
    p.replaceChildren(...CH.files.map((f, i) => el("div", { class: "pv" }, f.image ? el("img", { src: f.data, alt: f.name }) : el("span", { class: "rx" }, "📄 " + f.name), el("button", { type: "button", title: "Remove", onclick: () => { CH.files.splice(i, 1); drawPrevs(); } }, "×"))));
    p.style.display = CH.files.length ? "flex" : "none"; sendState();
  }

  /* ---------------- composer ---------------- */
  function autosize(ta) { ta.style.height = "auto"; ta.style.height = Math.min(160, ta.scrollHeight) + "px"; }
  function drawReply() {
    const r = $$("#chrep"); if (!r) return;
    if (!CH.reply) { r.style.display = "none"; return; }
    r.style.display = "flex"; r.replaceChildren(el("span", {}, "Replying to ", el("b", {}, who(CH.reply.author_id).name), ": " + (CH.reply.body || "(attachment)").slice(0, 80)), el("button", { type: "button", onclick: () => { CH.reply = null; drawReply(); } }, "✕"));
  }
  function sendState() { const b = $$("#chsend"), ta = $$("#chta"); if (b && ta) b.disabled = !(ta.value.trim() || CH.files.length); }
  function buildComposer(cmp) {
    const ta = el("textarea", { id: "chta", rows: "1", maxlength: "2000", "aria-label": "Message", placeholder: "Message" });
    const menu = el("div", { class: "mnl", id: "chmenu", style: "display:none" });
    const fin = el("input", { type: "file", multiple: "true", accept: "image/png,image/jpeg,image/webp,image/gif,application/pdf,text/plain,text/csv,application/zip,.docx", style: "display:none", onchange: e => { addFiles([...e.target.files]); e.target.value = ""; } });
    const send = el("button", { type: "button", class: "send", id: "chsend", disabled: "true", onclick: () => doSend() }, "Send");
    const box = el("div", { class: "cbox", id: "chbox" }, el("button", { type: "button", title: "Attach a file or image", "aria-label": "Attach", onclick: () => fin.click() }, "📎"), ta, el("button", { type: "button", title: "Poll", "aria-label": "Create poll", onclick: pollForm }, "📊"), send, fin);
    cmp.append(el("div", { class: "rbar", id: "chrep", style: "display:none" }), el("div", { class: "prevs", id: "chprevs", style: "display:none" }), menu, box);
    let sel = 0, items = [];
    const hide = () => { menu.style.display = "none"; items = []; };
    const show = list => { items = list; sel = 0; if (!list.length) return hide(); menu.style.display = "block"; menu.replaceChildren(...list.map((x, i) => el("button", { type: "button", class: "ci" + (i === 0 ? " on" : ""), style: "height:auto;display:block;white-space:normal", onmousedown: e => { e.preventDefault(); pick(i); } }, x.node))); };
    const mark = () => [...menu.children].forEach((c, i) => c.classList.toggle("on", i === sel));
    const pick = i => { const it = items[i]; if (!it) return; it.run(); hide(); ta.focus(); autosize(ta); sendState(); };
    const refresh = () => {
      const v = ta.value, pos = ta.selectionStart, head = v.slice(0, pos);
      let m;
      if ((m = /^\/(\w*)$/.exec(head))) {
        const list = COMMANDS.filter(c => (!c.cap || can(c.cap)) && c.name.startsWith(m[1].toLowerCase())).slice(0, 12);
        return show(list.map(c => ({ node: [el("b", {}, "/" + c.name), el("span", { class: "hint", style: "margin-left:6px" }, c.usage), el("div", { class: "hint", style: "margin:0" }, c.desc)], run: () => { ta.value = "/" + c.name + " "; ta.setSelectionRange(ta.value.length, ta.value.length); } })));
      }
      if ((m = /(?:^|\s)@([\w .-]{0,24})$/.exec(head))) {
        const q = m[1].toLowerCase(), list = [];
        if (can("mention_everyone") && "everyone".startsWith(q)) list.push({ label: "everyone", id: "everyone", sub: "Notify all staff" });
        if (can("mention_staff") && "staff".startsWith(q)) list.push({ label: "staff", id: "staff", sub: "Notify all staff" });
        CH.d.roster.filter(r => r.id !== CH.d.me.id && ((r.name || "").toLowerCase().includes(q) || (r.username || "").toLowerCase().includes(q))).slice(0, 6).forEach(r => list.push({ label: r.name, id: r.id, sub: r.rank, r }));
        return show(list.map(x => ({ node: [x.r ? xav(x.label, x.r.avatar, 20) : null, el("b", { style: "margin-left:6px" }, "@" + x.label), el("span", { class: "hint", style: "margin-left:8px" }, x.sub)],
          run: () => { const start = pos - m[1].length - 1; ta.value = v.slice(0, start) + "@" + x.label + " " + v.slice(pos); CH.mentions.set(x.label, x.id); const np = start + x.label.length + 2; ta.setSelectionRange(np, np); } })));
      }
      hide();
    };
    ta.addEventListener("input", () => { autosize(ta); sendState(); refresh(); if (!ta.value.startsWith("/") && Date.now() - CH.typingAt > 3000 && ta.value.trim()) { CH.typingAt = Date.now(); call("chat_typing", { p_scope: CH.scope }).catch(() => {}); } });
    ta.addEventListener("keydown", e => {
      if (items.length) {
        if (e.key === "ArrowDown") { e.preventDefault(); sel = (sel + 1) % items.length; return mark(); }
        if (e.key === "ArrowUp") { e.preventDefault(); sel = (sel - 1 + items.length) % items.length; return mark(); }
        const exact = /^\/(\w+)$/.exec(ta.value), noArgs = exact && COMMANDS.find(c => c.name === exact[1].toLowerCase() && (!c.usage || c.usage.charAt(0) === "["));
        if (e.key === "Tab" || (e.key === "Enter" && !e.shiftKey && !noArgs)) { e.preventDefault(); return pick(sel); }
        if (e.key === "Escape") { e.preventDefault(); return hide(); }
      }
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); doSend(); }
      if (e.key === "Escape" && CH.reply) { CH.reply = null; drawReply(); }
    });
    ta.addEventListener("blur", () => setTimeout(hide, 150));
    ta.addEventListener("paste", e => { const fs = [...(e.clipboardData ? e.clipboardData.files : [])]; if (fs.length) { e.preventDefault(); addFiles(fs); } });
  }

  async function doSend() {
    const ta = $$("#chta"), btn = $$("#chsend"); if (!ta || btn.disabled) return;
    const text = ta.value.trim();
    if (/^\/\w/.test(text) && !CH.files.length) { ta.value = ""; autosize(ta); sendState(); return runCommand(text); }
    btn.disabled = true;
    const ids = []; CH.mentions.forEach((id, name) => { if (text.includes("@" + name)) ids.push(id); }); if (/@everyone\b/.test(text)) ids.push("everyone"); if (/@staff\b/.test(text)) ids.push("staff");
    let r; try { r = await call("chat_send", { p_scope: CH.scope, p_body: text, p_reply_to: CH.reply ? CH.reply.id : null, p_files: CH.files.map(f => ({ name: f.name, data: f.data })), p_mentions: ids, p_thread: null }); } catch (e) { r = { error: "failed" }; }
    if (!r || r.error) { sendState(); if (r && r.error === "slowmode") toast("Slow mode: wait " + (r.wait || "a few") + "s", 3500); else toast(errText(r && r.error), 4500); return; }
    ta.value = ""; CH.drafts[CH.scope] = ""; CH.files = []; CH.reply = null; CH.mentions.clear(); autosize(ta); drawPrevs(); drawReply(); CH.stick = true; CH.local = []; tickNow(); Nudge.ping();
  }

  /* ---------------- older history, jumping, threads ---------------- */
  async function loadOlder() {
    if (CH.loadingOlder || !CH.msgs.length) return; CH.loadingOlder = true;
    try { const r = await call("chat_older", { p_scope: CH.scope, p_before: CH.msgs[0].id, p_limit: 50 }); if (Array.isArray(r) && r.length) { CH.msgs = r.concat(CH.msgs); CH.prepended = true; CH.lastSig = "x"; drawMsgs(); } else CH.noMore = true; } catch (e) {}
    CH.loadingOlder = false;
  }
  async function jumpTo(id, tries) {
    if (CH.msgs.some(m => m.id === id)) { CH.jump = id; CH.stick = false; return drawMsgs(); }
    if ((tries || 0) > 12 || !CH.msgs.length) return toast("That message is too far back");
    const r = await call("chat_older", { p_scope: CH.scope, p_before: CH.msgs[0].id, p_limit: 100 });
    if (!Array.isArray(r) || !r.length) return toast("Couldn't find that message");
    CH.msgs = r.concat(CH.msgs); CH.prepended = false; jumpTo(id, (tries || 0) + 1);
  }
  async function thread(root) {
    let timer = null;
    await W.dlg("Thread", (box, close) => {
      const list = el("div", { style: "max-height:46vh;overflow:auto" }), ta = el("textarea", { maxlength: "2000", placeholder: "Reply in thread…", "aria-label": "Reply in thread" });
      const load = async () => {
        let r; try { r = await call("chat_thread", { p_root: root }); } catch (e) { r = null; } if (!r) { list.replaceChildren(el("div", { class: "hint" }, "Thread unavailable.")); return; }
        const row = m => el("div", { class: "msg first", style: "grid-template-columns:34px 1fr" }, el("div", { class: "gut" }, xav(who(m.author_id).name, who(m.author_id).avatar, 30)),
          el("div", {}, el("div", { class: "mh" }, el("b", {}, who(m.author_id).name), el("time", {}, fmt(m.created_at))), el("div", { class: "mb" }, ...bodyNodes(esc(m.body))), m.attachments && m.attachments.length ? attsEl(m) : null));
        list.replaceChildren(row(r.root), el("div", { class: "dsep" }, r.replies.length + " repl" + (r.replies.length === 1 ? "y" : "ies")), ...r.replies.map(row)); list.scrollTop = list.scrollHeight;
      };
      const send = async () => { const t = ta.value.trim(); if (!t) return; const r = await call("chat_send", { p_scope: CH.scope, p_body: t, p_thread: root }); if (r && r.error) return toast(errText(r.error)); ta.value = ""; load(); tickNow(); Nudge.ping(); };
      ta.addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } });
      box.append(list, ta, el("div", { class: "row" }, el("button", { type: "button", onclick: () => { clearInterval(timer); close(null); } }, "Close"), el("button", { type: "button", class: "go", onclick: send }, "Reply")));
      load(); timer = setInterval(() => { if (!document.body.contains(box)) clearInterval(timer); else load(); }, 4000);
    }); clearInterval(timer);
  }

  /* ---------------- cards ---------------- */
  function toggleKey(key, loader) {
    if (CH.open.has(key)) { CH.open.delete(key); return drawMsgs(); }
    CH.open.add(key); drawMsgs(); loader && loader();
  }
  function ref(id) { return String(id).slice(0, 8); }
  async function guarded(p, ok) { let r; try { r = await p; } catch (e) { return toast("Couldn't reach the server"); } if (r === "ok" || (r && r.ok)) { if (ok) toast(ok); } else toast(errText(r && r.error || r), 4500); tickNow(); Nudge.ping(); return r; }

  function cardApp(m) {
    const c = m.card; if (!c) return el("div", { class: "card" }, "This application was deleted.");
    const done = c.status === "approved" || c.status === "denied", nm = c.display_name || c.name, aKey = "ans:" + c.id, nKey = "notes:" + c.id, iKey = "info:" + c.id;
    const card = el("div", { class: "card", style: "--fc:" + (ST[c.status] || ST.pending)[1] });
    const claimed = c.assigned_id ? who(c.assigned_id).name : null;
    card.append(el("div", { class: "ct" }, xav(nm, c.avatar, 44), el("div", { style: "flex:1;min-width:0" }, el("b", { class: "n" }, nm), el("small", {}, " @" + (c.username || c.name) + " · " + (c.discord_id || "")),
      el("div", { class: "hint", style: "margin:0" }, tOf({ type: c.type }).title + " application · ID " + ref(c.id) + " · " + fmt(c.created_at))), stTag(c.status)));
    card.append(el("div", { class: "res" }, claimed ? [el("b", {}, "Claimed by " + claimed), " · "] : "Unclaimed · ", c.reviewer && done ? "Decided by " : "", c.reviewer && done ? el("b", {}, c.reviewer) : null, done && c.status_at ? " · " + fmt(c.status_at) : "", c.note ? [el("br"), "Reason: ", el("b", {}, c.note)] : null));
    const cb = el("div", { class: "cb" });
    cb.append(el("button", { type: "button", onclick: () => toggleKey(aKey, async () => { if (!CH.cache.ans[c.id]) { CH.cache.ans[c.id] = await call("chat_application_answers", { p_app_id: c.id }); drawMsgs(); } }) }, CH.open.has(aKey) ? "Hide application" : "View application"));
    if (!done && can("claim")) cb.append(!c.assigned_id ? el("button", { type: "button", onclick: () => guarded(call("app_claim", { p_app: c.id }), "Claimed") }, "Claim") : (c.assigned_id === CH.d.me.id || can("assign") ? el("button", { type: "button", onclick: () => guarded(call("app_release", { p_app: c.id }), "Released") }, "Release") : null));
    if (!done && can("decide")) cb.append(
      el("button", { type: "button", class: "ok", style: "color:var(--ok);border-color:rgba(61,220,151,.6)", onclick: () => decide(c, "approved") }, "Approve"),
      el("button", { type: "button", class: "bad", style: "color:var(--bad);border-color:rgba(255,107,139,.6)", onclick: () => decide(c, "denied") }, "Deny"));
    if (can("app_notes")) cb.append(el("button", { type: "button", onclick: () => toggleKey(nKey, async () => { CH.cache.notes[c.id] = await call("app_notes_list", { p_app: c.id }); drawMsgs(); }) }, "Notes"));
    cb.append(el("button", { type: "button", onclick: () => toggleKey(iKey, async () => { CH.cache.info[c.id] = await call("app_applicant_info", { p_app: c.id }); drawMsgs(); }) }, "Applicant"));
    card.append(cb);
    if (CH.open.has(aKey)) { const a = CH.cache.ans[c.id]; card.append(el("div", { class: "cq open" }, a ? el("dl", {}, ...a.map((x, i) => el("div", { class: "qa" }, el("dt", {}, label(i, { type: c.type })), el("dd", {}, String(x == null ? "" : x))))) : el("div", { class: "hint" }, "Loading…"))); }
    if (CH.open.has(iKey)) card.append(applicantBox(CH.cache.info[c.id]));
    if (CH.open.has(nKey)) card.append(notesBox(c));
    return card;
  }
  function applicantBox(i) {
    if (!i) return el("div", { class: "notes" }, "Loading…");
    return el("div", { class: "notes" }, el("div", { class: "nrow" }, el("b", {}, "Applicant: "), (i.display_name || i.name) + " (@" + (i.username || i.name) + ") · registered " + fmt(i.registered) + " · ", W.stg(i.state)),
      i.duplicates && i.duplicates.length ? el("div", { class: "nrow", style: "color:#ffc857" }, "⚠ Duplicate: this person has " + i.duplicates.length + " other open " + i.type + " application" + (i.duplicates.length > 1 ? "s" : "") + " (" + i.duplicates.map(ref).join(", ") + ").") : null,
      el("div", { class: "nrow" }, el("b", {}, "Previous applications (" + i.previous.length + "): "), i.previous.length ? i.previous.map(p => tOf({ type: p.type }).title + " " + stName(p.status) + " (" + fmt(p.at) + ")").join(" · ") : "none"),
      el("div", { class: "nrow" }, el("b", {}, "History: "), i.history.length ? i.history.slice(0, 6).map(h => stName(h.status) + " by " + (h.actor || "?") + " " + rel(h.at)).join(" · ") : "none"));
  }
  const rel = t => W.rel(t);
  function notesBox(c) {
    const list = CH.cache.notes[c.id] || [], inp = el("input", { type: "text", maxlength: "1000", placeholder: "Add a private note", "aria-label": "Add a note" });
    const add = async () => { const t = inp.value.trim(); if (!t) return; const r = await call("app_note_add", { p_app: c.id, p_note: t }); if (r !== "ok") return toast(errText(r)); CH.cache.notes[c.id] = await call("app_notes_list", { p_app: c.id }); drawMsgs(); };
    inp.addEventListener("keydown", e => { if (e.key === "Enter") { e.preventDefault(); add(); } });
    return el("div", { class: "notes" }, ...(list.length ? list.map(n => el("div", { class: "nrow" }, el("b", {}, n.author), " ", el("small", {}, fmt(n.at)), el("div", {}, n.note))) : [el("div", { class: "hint" }, "No notes yet.")]), el("div", { class: "row" }, inp, el("button", { type: "button", onclick: add }, "Add")));
  }
  async function decide(c, status) {
    const nm = c.display_name || c.name, appeal = c.type === "appeal";
    const a = await W.ask({ title: (status === "approved" ? "Approve " : "Deny ") + nm + "'s " + tOf({ type: c.type }).title.toLowerCase() + " application?", text: "This updates the application on the website, tells the applicant on their status page, and is recorded with your name and the time.",
      reason: status === "denied" || appeal ? "required" : "optional", min: appeal ? 15 : 3, confirm: status === "approved" ? "Approve" : "Deny", danger: status === "denied" });
    if (!a) return;
    delete CH.cache.info[c.id];
    guarded(call("chat_decide_application", { p_app_id: c.id, p_status: status, p_reason: a.reason }), status === "approved" ? "Approved" : "Denied");
  }
  function cardDecision(m) {
    const c = m.card; if (!c) return el("div", { class: "card" }, "Record unavailable.");
    const ok = c.status === "approved", nm = c.display_name || c.name;
    return el("div", { class: "card", style: "--fc:" + (ok ? "#3ddc97" : "#ff6b8b") }, el("div", { class: "ct" }, xav(nm, c.avatar, 40), el("div", { style: "flex:1" }, el("b", { class: "n" }, (ok ? "✅ Approved: " : "❌ Denied: ") + nm), el("div", { class: "hint", style: "margin:0" }, tOf({ type: c.type }).title + " application · ID " + ref(c.id))), stTag(c.status)),
      el("div", { class: "res" }, "Decided by ", el("b", {}, c.reviewer || "staff"), " · ", fmt(c.status_at), c.note ? [el("br"), "Reason: ", el("b", {}, c.note)] : null));
  }
  function cardFb(m) {
    const f = m.card; if (!f) return el("div", { class: "card" }, "Feedback was deleted.");
    const col = { new: "#ff8fd4", reviewing: "#5cc8ff", resolved: "#3ddc97", declined: "#ff6b8b" }[f.status] || "#ff8fd4", nm = f.name || "Member", key = "fn:" + f.id;
    const card = el("div", { class: "card", style: "--fc:" + col });
    card.append(el("div", { class: "ct" }, xav(nm, f.avatar, 40), el("div", { style: "flex:1" }, el("b", { class: "n" }, nm), f.username ? el("small", {}, " @" + f.username) : null, el("div", { class: "hint", style: "margin:0" }, (f.outcome === "general" ? "Message" : tOf({ type: f.app_type }).title + " result: " + f.outcome) + " · " + fmt(f.created_at))),
      el("b", { class: "tag", style: "color:" + col + ";border-color:" + col }, f.status)));
    card.append(el("p", { class: "msgtxt" }, f.message || "No text."));
    if (f.handled_by) card.append(el("div", { class: "res" }, "Last handled by ", el("b", {}, f.handled_by), " · ", fmt(f.handled_at)));
    const cb = el("div", { class: "cb" });
    if (can("feedback_manage")) ["reviewing", "resolved", "declined"].forEach(s => { if (f.status !== s) cb.append(el("button", { type: "button", onclick: () => guarded(call("chat_feedback_status", { p_id: f.id, p_status: s }), "Marked " + s) }, s[0].toUpperCase() + s.slice(1))); });
    cb.append(el("button", { type: "button", onclick: () => toggleKey(key, async () => { CH.cache.fnotes[f.id] = await call("chat_feedback_notes", { p_id: f.id }); drawMsgs(); }) }, "Notes" + (f.note_count ? " (" + f.note_count + ")" : "")));
    card.append(cb);
    if (CH.open.has(key)) {
      const list = CH.cache.fnotes[f.id] || [], inp = el("input", { type: "text", maxlength: "500", placeholder: "Add an internal note", "aria-label": "Internal note" });
      const add = async () => { const t = inp.value.trim(); if (!t) return; const r = await call("chat_feedback_note", { p_id: f.id, p_note: t }); if (r !== "ok") return toast(errText(r)); CH.cache.fnotes[f.id] = await call("chat_feedback_notes", { p_id: f.id }); tickNow(); drawMsgs(); };
      inp.addEventListener("keydown", e => { if (e.key === "Enter") { e.preventDefault(); add(); } });
      card.append(el("div", { class: "notes" }, ...(list.length ? list.map(n => el("div", { class: "nrow" }, el("b", {}, n.author || n.by || "Staff"), " ", el("small", {}, fmt(n.at || n.created_at)), el("div", {}, n.note))) : [el("div", { class: "hint" }, "No notes yet.")]), can("feedback_manage") ? el("div", { class: "row" }, inp, el("button", { type: "button", onclick: add }, "Add")) : null));
    }
    return card;
  }
  function cardMod(m) {
    const l = m.card; if (!l) return el("div", { class: "card" }, "Record unavailable.");
    const col = { ban: "#ff6b8b", unban: "#3ddc97", timeout: "#ffc857", untimeout: "#3ddc97", warn: "#ff9d5c", note: "#5cc8ff" }[l.action] || "#b79cff";
    return el("div", { class: "card", style: "--fc:" + col }, el("div", { class: "ct" }, xav(l.target_name, l.avatar, 36), el("div", { style: "flex:1" }, el("b", { class: "n act-" + l.action }, l.action.toUpperCase() + " · " + (l.target_name || l.target_id)), el("div", { class: "hint", style: "margin:0" }, "by " + l.actor + " · " + fmt(l.at) + (l.detail ? " · " + l.detail : "")))),
      l.reason ? el("p", { class: "msgtxt" }, l.reason) : null);
  }
  function pollEl(m) {
    const p = m.poll_data || {}, opts = p.options || [], counts = p.counts || {}, total = Object.values(counts).reduce((a, b) => a + b, 0);
    return el("div", { class: "card", style: "--fc:var(--violet)" }, el("b", { class: "n" }, "📊 " + m.body), ...opts.map((o, i) => { const n = counts[i] || 0, pct = total ? Math.round(n * 100 / total) : 0;
      return el("button", { type: "button", class: "ci", style: "display:block;margin-top:6px;border:1px solid " + (p.mine === i ? "var(--pink)" : "var(--border)") + ";background:linear-gradient(90deg,rgba(255,79,184,.25) " + pct + "%,transparent " + pct + "%)", onclick: async () => { const r = await call("chat_poll_vote", { p_id: m.id, p_opt: i }); if (r !== "ok") toast(errText(r)); tickNow(); } },
        el("span", { class: "nm" }, o), el("b", { style: "float:right" }, n + " · " + pct + "%")); }), el("div", { class: "hint" }, total + " vote" + (total === 1 ? "" : "s") + " · click again to remove your vote"));
  }

  /* ---------------- dialogs: channel info, forms, DM picker, profile, settings, search ---------------- */
  function channelInfo(c) {
    W.dlg("# " + c.slug, (box, close) => {
      const i = c.info || {}, ul = a => Array.isArray(a) && a.length ? el("ul", { style: "margin:2px 0 8px 18px" }, ...a.map(x => el("li", {}, x))) : null;
      const row = el("div", { class: "row", style: "justify-content:flex-start;flex-wrap:wrap" });
      if (can("lock")) row.append(el("button", { type: "button", onclick: async () => { const ok = await W.ask({ title: (c.locked ? "Unlock #" : "Lock #") + c.slug + "?", text: c.locked ? "Everyone who can post will be able to write again." : "Only administrators will be able to post.", confirm: c.locked ? "Unlock" : "Lock" }); if (!ok) return; await guarded(call("chat_channel_set", { p_id: c.id, p_locked: !c.locked }), c.locked ? "Unlocked" : "Locked"); close(null); } }, c.locked ? "Unlock channel" : "Lock channel"));
      if (can("slowmode")) row.append(el("button", { type: "button", onclick: async () => { const v = prompt("Slow mode in seconds (0 = off, max 3600):", String(c.slow_mode || 0)); if (v === null) return; await guarded(call("chat_channel_set", { p_id: c.id, p_slow: Number(v) }), "Slow mode updated"); close(null); } }, "Slow mode"));
      if (can("channels")) { row.append(el("button", { type: "button", onclick: () => { close(null); channelForm(c); } }, "Edit channel & info panel")); if (!c.sys) row.append(el("button", { type: "button", class: "bad", onclick: async () => { if (!await W.ask({ title: "Delete #" + c.slug + "?", text: "All its messages are removed for good.", confirm: "Delete", danger: true })) return; await guarded(call("chat_channel_delete", { p_id: c.id }), "Channel deleted"); close(null); } }, "Delete channel")); }
      box.append(el("div", { class: "hint" }, c.category + (c.topic ? " · " + c.topic : "")), i.purpose ? el("p", {}, i.purpose) : null,
        i.belongs ? [el("h4", {}, "What belongs here"), ul(i.belongs)] : null, i.staff_use ? [el("h4", {}, "How staff should use it"), ul(i.staff_use)] : null, i.instructions ? [el("h4", {}, "Rules and instructions"), ul(i.instructions)] : null,
        el("div", { class: "hint" }, "Visible to " + ({ viewer: "all staff", reviewer: "Senior Moderators and up", admin: "Administrators" }[c.min_access]) + (c.no_helpers ? " (not Helpers)" : "") + " · posting: " + ({ viewer: "everyone who can see it", reviewer: "Senior Moderators and up", admin: "Administrators only" }[c.post_min])), row, el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Close")));
    });
  }
  function channelForm(c, cat) {
    W.dlg(c ? "Edit #" + c.slug : "New channel", (box, close) => {
      const i = (c && c.info) || {}, lines = a => (Array.isArray(a) ? a.join("\n") : "");
      const f = { name: el("input", { type: "text", maxlength: "30", value: c ? c.slug : "", placeholder: "channel-name" }), cat: el("input", { type: "text", maxlength: "40", value: c ? c.category : (cat || "GENERAL STAFF"), list: "chcats" }), topic: el("input", { type: "text", maxlength: "200", value: c ? c.topic : "" }),
        min: el("select", {}, ...[["viewer", "All staff"], ["reviewer", "Senior Moderators and up"], ["admin", "Administrators only"]].map(([v, t]) => el("option", { value: v }, t))), post: el("select", {}, ...[["viewer", "Everyone who can see it"], ["reviewer", "Senior Moderators and up"], ["admin", "Administrators only"]].map(([v, t]) => el("option", { value: v }, t))),
        nh: el("input", { type: "checkbox" }), purpose: el("textarea", {}, i.purpose || ""), belongs: el("textarea", {}, lines(i.belongs)), use: el("textarea", {}, lines(i.staff_use)), rules: el("textarea", {}, lines(i.instructions)) };
      if (c) { f.min.value = c.min_access; f.post.value = c.post_min; f.nh.checked = !!c.no_helpers; }
      f.purpose.value = i.purpose || ""; f.belongs.value = lines(i.belongs); f.use.value = lines(i.staff_use); f.rules.value = lines(i.instructions);
      const err = el("div", { class: "derr" }), L = (t, n) => el("div", { class: "fld" }, el("label", {}, t), n), arr = t => t.value.split("\n").map(x => x.trim()).filter(Boolean).slice(0, 12);
      box.append(el("datalist", { id: "chcats" }, ...[...new Set((CH.d.channels || []).map(x => x.category))].map(x => el("option", { value: x }))),
        L("Name", f.name), L("Category", f.cat), L("Topic", f.topic), L("Who can see it", f.min), L("Who can post", f.post), el("label", {}, f.nh, " Hide from Helpers"),
        L("Purpose", f.purpose), L("What belongs here (one per line)", f.belongs), L("How staff should use it (one per line)", f.use), L("Rules and instructions (one per line)", f.rules), err,
        el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Cancel"), el("button", { type: "button", class: "go", onclick: async () => {
          const r = await call("chat_channel_save", { p_id: c ? c.id : null, p_name: f.name.value, p_topic: f.topic.value, p_min: f.min.value, p_post: f.post.value, p_category: f.cat.value, p_info: { purpose: f.purpose.value.trim(), belongs: arr(f.belongs), staff_use: arr(f.use), instructions: arr(f.rules) }, p_no_helpers: f.nh.checked });
          if (r && r.ok) { toast("Saved"); close(null); CH.metaSig = ""; tickNow(); if (!c) go("c:" + r.id); } else err.textContent = errText(r && r.error);
        } }, "Save")));
    });
  }
  function pickDM() {
    W.dlg("New private message", (box, close) => box.append(...CH.d.roster.filter(r => r.id !== CH.d.me.id).map(r => el("button", { type: "button", class: "ci", onclick: () => { close(null); go("d:" + r.id); } }, xav(r.name, r.avatar, 28, r.status), el("span", { class: "nm" }, r.name), el("span", { class: "hint", style: "margin:0" }, r.rank))), el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Close"))));
  }
  async function profile(id) {
    let p; try { p = await call("staff_profile", { p_discord_id: id }); } catch (e) { p = null; } if (!p) return toast("Profile unavailable");
    W.dlg("Staff profile", (box, close) => {
      const st = p.stats, row = el("div", { class: "row", style: "justify-content:flex-start;flex-wrap:wrap" });
      if (id !== CH.d.me.id) row.append(el("button", { type: "button", class: "go", onclick: () => { close(null); go("d:" + id); } }, "Message"));
      if (can("promote") && id !== CH.d.me.id) { row.append(el("button", { type: "button", onclick: () => rankStep(p, 1, close) }, "Promote"), el("button", { type: "button", onclick: () => rankStep(p, -1, close) }, "Demote")); }
      if (can("userinfo") && id !== CH.d.me.id) row.append(el("button", { type: "button", onclick: () => { close(null); W.viewUser(id); } }, "Moderation view"));
      box.append(el("div", { class: "uprof" }, xav(p.name, p.avatar, 64, p.status), el("div", {}, el("h3", {}, p.name), el("div", { class: "hint" }, "@" + (p.username || "?") + " · " + p.id), el("span", { class: "stg staff" }, p.rank))),
        el("dl", { class: "kv" }, el("dt", {}, "Status"), el("dd", {}, p.status), el("dt", {}, "Last seen"), el("dd", {}, p.last_seen ? rel(p.last_seen) : "never"), el("dt", {}, "On the team since"), el("dd", {}, fmt(p.joined)),
          st ? [el("dt", {}, "Last 30 days"), el("dd", {}, st.decisions + " decisions · " + st.mod_actions + " mod actions · " + st.messages + " messages"), el("dt", {}, "Claimed open"), el("dd", {}, String(st.claimed_open))] : null), row);
    });
  }
  async function rankStep(p, dir, close) {
    const ok = await W.ask({ title: (dir > 0 ? "Promote " : "Demote ") + p.name + "?", text: "Their position changes one step now and their access updates immediately.", confirm: dir > 0 ? "Promote" : "Demote" }); if (!ok) return;
    const r = await call("staff_rank_step", { p_discord_id: p.id, p_dir: dir }); if (r && r.ok) { toast(p.name + ": " + r.from + " → " + r.to); close(null); tickNow(); } else toast(errText(r && r.error), 4500);
  }
  function settings() {
    const me = CH.d.me;
    W.dlg("Chat settings", (box, close) => {
      const n = el("select", { "aria-label": "Notifications" }, ...[["all", "All new messages"], ["mentions", "Only @mentions"], ["none", "Nothing"]].map(([v, t]) => el("option", { value: v }, t))); n.value = me.notify || "all";
      const aw = el("input", { type: "checkbox" }); aw.checked = !!me.manual_away;
      const bf = el("input", { type: "checkbox" }); bf.checked = !!store.get("wm-chat-blurfocus", false);
      box.append(el("label", {}, "Notifications"), n, el("label", {}, aw, " Show me as away"), el("label", {}, bf, " Blur the chat whenever this window loses focus"),
        el("p", { class: "hint" }, "The chat always hides itself when you switch tabs or minimise the browser, and comes back when you return."),
        can("screenshot") ? el("div", { class: "row", style: "justify-content:flex-start" }, el("button", { type: "button", onclick: () => { close(null); shotLog(); } }, "Screenshot audit log")) : null, el("p", { class: "hint" }, "Muted channels and conversations never notify you. Desktop alerts only appear while this tab is in the background."),
        el("div", { class: "row", style: "justify-content:flex-start" }, el("button", { type: "button", onclick: async () => { if (!window.Notification) return toast("This browser has no desktop alerts"); const p = await Notification.requestPermission(); toast(p === "granted" ? "Desktop alerts on" : "Desktop alerts blocked"); } }, "Enable desktop alerts")),
        el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Cancel"), el("button", { type: "button", class: "go", onclick: async () => { store.set("wm-chat-blurfocus", bf.checked); const r = await call("chat_set_prefs", { p_notify: n.value, p_away: aw.checked }); if (r === "ok") { toast("Saved"); close(null); tickNow(); } else toast(errText(r)); } }, "Save")));
    });
  }
  function pollForm() {
    W.dlg("Create a poll", (box, close) => {
      const q = el("input", { type: "text", maxlength: "300", placeholder: "Question" }), opts = [0, 1, 2, 3].map(i => el("input", { type: "text", maxlength: "80", placeholder: "Option " + (i + 1) })), err = el("div", { class: "derr" });
      box.append(el("label", {}, "Question"), q, el("label", {}, "Options (2 to 6, empty ones are ignored)"), ...opts, err, el("div", { class: "row" }, el("button", { type: "button", onclick: () => close(null) }, "Cancel"), el("button", { type: "button", class: "go", onclick: async () => {
        const r = await call("chat_poll_create", { p_scope: CH.scope, p_question: q.value, p_options: opts.map(o => o.value).filter(x => x.trim()) }); if (r && r.ok) { close(null); CH.stick = true; tickNow(); Nudge.ping(); } else err.textContent = errText(r && r.error);
      } }, "Post poll")));
    });
  }
  function searchPanel(pre) {
    const old = $$(".srch"); if (old) { old.remove(); return; }
    const cm = $$("#chcm"), q = el("input", { type: "search", placeholder: "Search messages", value: (pre && pre.q) || "", "aria-label": "Search text" });
    const au = el("select", { "aria-label": "From" }, el("option", { value: "" }, "Anyone"), ...CH.d.roster.map(r => el("option", { value: r.id }, r.name)));
    const sc = el("select", { "aria-label": "Where" }, el("option", { value: CH.scope }, "This conversation"), el("option", { value: "" }, "Everywhere I have access"));
    const d1 = el("input", { type: "date", "aria-label": "From date" }), d2 = el("input", { type: "date", "aria-label": "To date" }), res = el("div", {});
    const run = async () => {
      res.replaceChildren(el("div", { class: "hint" }, "Searching…"));
      let r; try { r = await call("chat_search", { p_q: q.value, p_author: au.value || null, p_scope: sc.value || null, p_from: d1.value ? new Date(d1.value).toISOString() : null, p_to: d2.value ? new Date(new Date(d2.value).getTime() + 864e5).toISOString() : null, p_limit: 40 }); } catch (e) { r = []; }
      if (!r.length) return res.replaceChildren(el("div", { class: "plain" }, "Nothing found (type at least 2 letters, or pick a person or date)."));
      res.replaceChildren(...r.map(h => el("button", { type: "button", class: "hit", onclick: () => { p.remove(); const t = () => jumpTo(h.id); if (h.scope !== CH.scope) { go(h.scope); setTimeout(t, 900); } else t(); } },
        el("small", {}, (h.channel ? "#" + h.channel : "Direct message") + " · " + who(h.author_id).name + " · " + fmt(h.created_at)), h.body)));
    };
    q.addEventListener("keydown", e => { if (e.key === "Enter") run(); });
    const p = el("div", { class: "srch" }, el("div", { class: "row", style: "display:flex;gap:8px;flex-wrap:wrap;margin-bottom:10px" }, q, au, sc, d1, d2, el("button", { type: "button", onclick: run }, "Search"), el("button", { type: "button", onclick: () => p.remove() }, "Close")), res);
    cm.append(p); q.focus(); if (q.value) run();
  }

  /* ---------------- slash commands ---------------- */
  const sayNodes = (nodes, title) => { CH.local.push(el("div", { class: "card", style: "margin:8px 14px 8px 14px;--fc:var(--violet)" }, el("div", { class: "hint", style: "margin:0 0 4px" }, "Only you can see this" + (title ? " · " + title : "")), ...[].concat(nodes))); drawMsgs(); const b = $$("#chm"); if (b) b.scrollTop = b.scrollHeight; };
  const say = (t, title) => sayNodes([el("div", { style: "white-space:pre-wrap;overflow-wrap:anywhere" }, t)], title);
  const kv = rows => el("dl", { class: "kv" }, ...rows.flatMap(([k, v]) => [el("dt", {}, k), el("dd", {}, v == null || v === "" ? "—" : v)]));
  const fail = t => { sayNodes([el("div", { style: "color:var(--bad)" }, "⚠ " + t)]); };
  function toks(s, n) { const out = []; let rest = s.trim(); for (let i = 0; i < n; i++) { const m = /^(\S+)\s*([\s\S]*)$/.exec(rest); if (!m) { out.push(""); rest = ""; continue; } out.push(m[1]); rest = m[2]; } out.push(rest.trim()); return out; }
  async function resolveUser(tok, allowId) {
    if (!tok) throw new Error("Tell me who (a @name or Discord ID).");
    tok = tok.replace(/^<@!?(\d+)>$/, "$1").replace(/^@/, "");
    let r = []; if (tok.length >= 2) r = await call("find_user", { p_q: tok });
    const exact = r.find(x => x.id === tok || (x.username || "").toLowerCase() === tok.toLowerCase() || (x.display_name || "").toLowerCase() === tok.toLowerCase());
    if (r.length > 1 && !exact) throw new Error("Several members match: " + r.map(x => x.username + " (" + x.id + ")").join(", ") + ". Use the Discord ID.");
    const u = exact || r[0];
    if (u) return { discord_id: u.id, display_name: u.display_name, username: u.username, avatar: u.avatar, state: u.state };
    if (allowId && /^\d{5,25}$/.test(tok)) return { discord_id: tok, display_name: tok, username: tok, state: "active", raw: true };
    throw new Error(/^\d{5,25}$/.test(tok) ? "No site member has that Discord ID." : "No member called “" + tok + "”. Try their Discord ID.");
  }
  function resolveStaff(tok) {
    if (!tok) throw new Error("Tell me which staff member.");
    tok = tok.replace(/^<@!?(\d+)>$/, "$1").replace(/^@/, "").toLowerCase();
    const r = CH.d.roster, ex = r.find(x => x.id === tok || (x.name || "").toLowerCase() === tok || (x.username || "").toLowerCase() === tok), part = r.filter(x => (x.name || "").toLowerCase().startsWith(tok) || (x.username || "").toLowerCase().startsWith(tok));
    if (ex) return ex; if (part.length === 1) return part[0];
    throw new Error(part.length ? "Several staff match: " + part.map(x => x.name).join(", ") : "No staff member matches “" + tok + "”.");
  }
  const mins = s => { const m = /^(\d+)\s*(m|min|h|hr|d|day|days|w)?$/i.exec(s || ""); if (!m) return null; const n = Number(m[1]), u = (m[2] || "m").toLowerCase(); return u.startsWith("d") ? n * 1440 : u === "w" ? n * 10080 : u.startsWith("h") ? n * 60 : n; };
  const curId = () => cx(CH.scope);
  const needReason = (t, n) => { if ((t || "").trim().length < (n || 3)) throw new Error("A reason is required."); return t.trim(); };
  async function modCmd(action, a) {
    const [who_, rest] = toks(a, 1);
    const u = await resolveUser(who_, true); let minutes = null, reason = rest;
    if (action === "timeout") { const [d, r2] = toks(rest, 1); minutes = mins(d); if (!minutes || minutes < 1) throw new Error("Usage: /timeout <user> <duration like 30m, 2h, 1d> <reason>"); reason = r2; }
    if (["ban", "timeout", "warn"].includes(action)) reason = needReason(reason);
    const sure = await W.ask({ title: { ban: "Ban ", unban: "Unban ", timeout: "Timeout ", untimeout: "Remove timeout for ", warn: "Warn ", note: "Note about " }[action] + (u.display_name || u.discord_id) + "?", text: (minutes ? "Duration: " + minutes + " minutes. " : "") + (reason ? "Reason: " + reason : "No reason given.") + (u.raw ? " (This Discord ID has not logged in to the site yet.)" : ""), confirm: "Confirm", danger: ["ban", "timeout"].includes(action) });
    if (!sure) return;
    const ok = await W.modAction(u, action, { reason: reason || "", minutes });
    if (ok) say("Done: " + action + " " + (u.display_name || u.discord_id) + ".");
  }
  async function userEmbed(u) {
    const d = await call("mod_user_detail", { p_discord_id: u.discord_id }); if (!d) throw new Error("You can't view that user.");
    return { d, node: el("div", {}, el("div", { class: "uprof" }, xav(d.display_name || d.username, d.avatar, 48), el("div", {}, el("b", {}, d.display_name || d.username || d.discord_id), el("div", { class: "hint" }, "@" + (d.username || "?") + " · " + d.discord_id), W.stg(d.status))),
      kv([["Registered", fmt(d.registered)], ["Last login", fmt(d.last_sign_in)], ["Reason", d.reason], ["Until", d.until ? fmt(d.until) : ""], ["Applications", d.applications.length + " (" + d.applications.map(a => a.type + ":" + a.status).join(", ") + ")"], ["Moderation actions", String(d.history.length)]])) };
  }
  const COMMANDS = [
    { name: "screenshot", usage: "", desc: "Take an audited screenshot of this conversation (administrators only)", cap: "screenshot", run: () => shot() },
    { name: "help", usage: "[command]", desc: "Show the commands you can use", run: async a => {
      const list = COMMANDS.filter(c => !c.cap || can(c.cap)); const one = list.find(c => c.name === a.trim().replace(/^\//, ""));
      if (one) return sayNodes([el("b", {}, "/" + one.name + " " + one.usage), el("div", { class: "hint" }, one.desc)]);
      sayNodes([el("b", {}, "Commands you can use (" + list.length + ")"), el("div", { style: "margin-top:6px" }, ...list.map(c => el("div", {}, el("b", {}, "/" + c.name), " ", el("span", { class: "hint", style: "margin:0" }, c.usage + " — " + c.desc))))], "help"); } },
    { name: "ban", usage: "<user> <reason>", desc: "Ban a member from the website", cap: "ban", run: a => modCmd("ban", a) },
    { name: "unban", usage: "<user> [reason]", desc: "Lift a ban", cap: "ban", run: a => modCmd("unban", a) },
    { name: "timeout", usage: "<user> <30m|2h|1d> <reason>", desc: "Temporarily stop a member applying", cap: "timeout", run: a => modCmd("timeout", a) },
    { name: "untimeout", usage: "<user> [reason]", desc: "Remove a timeout", cap: "timeout", run: a => modCmd("untimeout", a) },
    { name: "warn", usage: "<user> <reason>", desc: "Record a warning", cap: "warn", run: a => modCmd("warn", a) },
    { name: "userinfo", usage: "<user>", desc: "Profile, status and moderation summary", cap: "userinfo", run: async a => { const u = await resolveUser(toks(a, 1)[0], true); const e = await userEmbed(u); sayNodes([e.node], "userinfo"); } },
    { name: "history", usage: "<user>", desc: "Full moderation history of a member", cap: "userinfo", run: async a => { const u = await resolveUser(toks(a, 1)[0], true); const { d } = await userEmbed(u); sayNodes([el("b", {}, "Moderation history · " + (d.display_name || d.discord_id)), ...(d.history.length ? d.history.map(h => el("div", { class: "nrow" }, el("b", { class: "act-" + h.action }, h.action.toUpperCase()), " " + h.actor + " · ", el("small", {}, fmt(h.at)), h.reason ? el("div", {}, h.reason) : null)) : [el("div", { class: "hint" }, "Clean record.")])], "history"); } },
    { name: "modnotes", usage: "<user> [note text]", desc: "Show moderator notes, or add one", cap: "userinfo", run: async a => { const [w, t] = toks(a, 1); const u = await resolveUser(w, true);
        if (t) { if (!can("note")) throw new Error("You can't add notes."); const ok = await W.ask({ title: "Add note about " + (u.display_name || u.discord_id) + "?", text: t, confirm: "Add note" }); if (!ok) return; const r = await call("mod_action", { p_discord_id: u.discord_id, p_action: "note", p_reason: t, p_minutes: null }); return r === "ok" ? say("Note added.") : fail(errText(r)); }
        const { d } = await userEmbed(u); const n = d.history.filter(h => h.action === "note"); sayNodes([el("b", {}, "Moderator notes · " + (d.display_name || d.discord_id)), ...(n.length ? n.map(h => el("div", { class: "nrow" }, el("small", {}, h.actor + " · " + fmt(h.at)), el("div", {}, h.reason))) : [el("div", { class: "hint" }, "No notes.")])], "modnotes"); } },
    { name: "applications", usage: "[status]", desc: "List applications (open by default)", cap: "apps_view", run: async a => { const s = (a.trim() || "open").toLowerCase(); const r = await call("app_list", { p_status: s, p_limit: 20 }); appList(r, "Applications · " + s); } },
    { name: "pending", usage: "", desc: "List applications waiting for a first review", cap: "apps_view", run: async () => appList(await call("app_list", { p_status: "pending", p_limit: 20 }), "Pending applications") },
    { name: "approve", usage: "<application id> [reason]", desc: "Approve an application", cap: "decide", run: a => decideCmd("approved", a) },
    { name: "deny", usage: "<application id> <reason>", desc: "Deny an application", cap: "decide", run: a => decideCmd("denied", a) },
    { name: "review", usage: "<application id>", desc: "Open an application with its answers", cap: "apps_view", run: async a => { const id = toks(a, 1)[0]; if (!id) throw new Error("Usage: /review <application id>"); const [ans, info] = await Promise.all([call("chat_application_answers", { p_app_id: await fullId(id) }), call("app_applicant_info", { p_app: id })]); if (!info) throw new Error("Application not found."); sayNodes([applicantBox(info), el("div", { class: "cq open" }, ...(ans || []).map((x, i) => el("div", { class: "qa" }, el("dt", {}, label(i, { type: info.type })), el("dd", {}, String(x == null ? "" : x)))))], "review " + ref(info.id)); } },
    { name: "claim", usage: "<application id>", desc: "Claim an application so nobody else reviews it", cap: "claim", run: async a => { const r = await call("app_claim", { p_app: toks(a, 1)[0] }); r === "ok" ? say("You claimed it.") : fail(errText(r)); tickNow(); } },
    { name: "release", usage: "<application id>", desc: "Give up a claim", cap: "claim", run: async a => { const r = await call("app_release", { p_app: toks(a, 1)[0] }); r === "ok" ? say("Released.") : fail(errText(r)); tickNow(); } },
    { name: "assign", usage: "<application id> <staff>", desc: "Assign an application to a reviewer", cap: "assign", run: async a => { const [id, w] = toks(a, 1); const s = resolveStaff(w); const ok = await W.ask({ title: "Assign " + ref(id) + " to " + s.name + "?", text: "They become the claimed reviewer.", confirm: "Assign" }); if (!ok) return; const r = await call("app_assign", { p_app: id, p_to: s.id }); r === "ok" ? say("Assigned to " + s.name + ".") : fail(errText(r)); tickNow(); } },
    { name: "applicant", usage: "<application id>", desc: "Applicant history and duplicate check", cap: "apps_view", run: async a => { const i = await call("app_applicant_info", { p_app: toks(a, 1)[0] }); if (!i) throw new Error("Application not found."); sayNodes([applicantBox(i)], "applicant"); } },
    { name: "note", usage: "<application id> <text>", desc: "Add a private review note to an application", cap: "app_notes", run: async a => { const [id, t] = toks(a, 1); if (!t) throw new Error("Usage: /note <application id> <text>"); const r = await call("app_note_add", { p_app: id, p_note: t }); r === "ok" ? say("Note added.") : fail(errText(r)); } },
    { name: "notes", usage: "<application id>", desc: "Show review notes of an application", cap: "app_notes", run: async a => { const r = await call("app_notes_list", { p_app: toks(a, 1)[0] }); sayNodes([el("b", {}, "Review notes"), ...(r.length ? r.map(n => el("div", { class: "nrow" }, el("b", {}, n.author), " ", el("small", {}, fmt(n.at)), el("div", {}, n.note))) : [el("div", { class: "hint" }, "No notes.")])], "notes"); } },
    { name: "closeapps", usage: "<type|all>", desc: "Close applications of a type", cap: "apps_toggle", run: a => toggleCmd(false, a) },
    { name: "openapps", usage: "<type|all>", desc: "Open applications of a type", cap: "apps_toggle", run: a => toggleCmd(true, a) },
    { name: "appstats", usage: "", desc: "Application numbers", cap: "apps_view", run: async () => { const s = await call("app_stats"); if (!s) throw new Error("Not allowed."); sayNodes([el("b", {}, "Application stats"), kv([["Total", s.total], ["Last 24 hours", s.today], ["Last 7 days", s.week], ["Unclaimed open", s.unclaimed_open], ["By status", Object.entries(s.by_status).map(([k, v]) => stName(k) + " " + v).join(" · ")], ["By type", Object.entries(s.by_type).map(([k, v]) => k + " " + v).join(" · ")], ["Closed types", (s.closed_types || []).join(", ") || "none"]])], "appstats"); } },
    { name: "staffinfo", usage: "<staff>", desc: "A staff member's profile", run: async a => { const s = resolveStaff(toks(a, 1)[0]); const p = await call("staff_profile", { p_discord_id: s.id }); if (!p) throw new Error("Not found."); sayNodes([el("div", { class: "uprof" }, xav(p.name, p.avatar, 48, p.status), el("div", {}, el("b", {}, p.name), el("div", { class: "hint" }, p.rank + " · " + p.status))), kv([["Discord ID", p.id], ["Last seen", p.last_seen ? rel(p.last_seen) : "never"], ["On the team since", fmt(p.joined)]])], "staffinfo"); } },
    { name: "stafflist", usage: "", desc: "Everyone on the staff team", run: async () => { const g = {}; CH.d.roster.forEach(r => (g[r.rank] = g[r.rank] || []).push(r)); sayNodes([el("b", {}, "Staff team (" + CH.d.roster.length + ")"), ...Object.keys(g).sort((x, y) => LADDER.indexOf(x) - LADDER.indexOf(y)).map(k => el("div", {}, el("b", { style: "color:" + rankCol(k) }, k + ": "), g[k].map(r => r.name + (r.status === "online" ? " 🟢" : r.status === "away" ? " 🟡" : "")).join(", ")))], "stafflist"); } },
    { name: "promote", usage: "<staff>", desc: "Move a staff member up one rank", cap: "promote", run: a => stepCmd(1, a) },
    { name: "demote", usage: "<staff>", desc: "Move a staff member down one rank", cap: "promote", run: a => stepCmd(-1, a) },
    { name: "staffstats", usage: "[staff]", desc: "Activity numbers for you (or anyone, admins)", run: async a => { const s = a.trim() ? resolveStaff(toks(a, 1)[0]) : CH.d.roster.find(x => x.id === CH.d.me.id); const r = await call("staff_stats", { p_discord_id: s ? s.id : null }); if (!r || r.error) throw new Error(errText(r && r.error)); sayNodes([el("b", {}, "Last 30 days · " + (s ? s.name : "you")), kv([["Decisions", r.decisions], ["Moderation actions", r.mod_actions], ["Messages", r.messages], ["Claimed and open", r.claimed_open]])], "staffstats"); } },
    { name: "serverinfo", usage: "", desc: "Website and team numbers", cap: "userinfo", run: async () => { const s = await call("server_info"); if (!s) throw new Error("Not allowed."); sayNodes([el("b", {}, "Will Mac website"), kv([["Members", s.members], ["Banned / timed out", s.banned + " / " + s.timed_out], ["Staff (online)", s.staff + " (" + s.staff_online + ")"], ["Open applications", s.applications_open + " of " + s.applications_total], ["New feedback", s.feedback_new], ["Chat channels", s.channels], ["Closed types", (s.closed_types || []).join(", ") || "none"]])], "serverinfo"); } },
    { name: "announce", usage: "<text>", desc: "Post to #staff-announcements and notify everyone", cap: "announce", run: async a => { if (a.trim().length < 3) throw new Error("Usage: /announce <text>"); const ok = await W.ask({ title: "Post this announcement?", text: a.trim(), confirm: "Announce" }); if (!ok) return; const r = await call("chat_announce", { p_text: a }); r && r.ok ? (say("Announcement posted."), r.channel && go("c:" + r.channel)) : fail(errText(r && r.error)); } },
    { name: "clear", usage: "<1-100>", desc: "Delete the last N messages here (pinned stay)", cap: "clear", run: async a => { const n = Number(a.trim()); if (!(n >= 1 && n <= 100)) throw new Error("Usage: /clear <1-100>"); if (!curId()) throw new Error("You can only clear channels."); const ok = await W.ask({ title: "Delete the last " + n + " messages?", text: "In #" + curChan().slug + ". Pinned messages stay. This is logged.", confirm: "Delete", danger: true }); if (!ok) return; const r = await call("chat_clear", { p_scope: CH.scope, p_count: n }); r && r.ok ? (say("Cleared " + r.cleared + " messages."), tickNow()) : fail(errText(r && r.error)); } },
    { name: "poll", usage: "Question | option | option …", desc: "Post a poll", run: async a => { const parts = a.split("|").map(x => x.trim()).filter(Boolean); if (parts.length < 3) throw new Error("Usage: /poll Question | option 1 | option 2"); const r = await call("chat_poll_create", { p_scope: CH.scope, p_question: parts[0], p_options: parts.slice(1) }); r && r.ok ? (CH.stick = true, tickNow(), Nudge.ping()) : fail(errText(r && r.error)); } },
    { name: "lockchannel", usage: "", desc: "Lock this channel (admins post only)", cap: "lock", run: a => lockCmd(true) },
    { name: "unlockchannel", usage: "", desc: "Unlock this channel", cap: "lock", run: a => lockCmd(false) },
    { name: "slowmode", usage: "<seconds|off>", desc: "Slow mode for this channel", cap: "slowmode", run: async a => { const c = curChan(); if (!c) throw new Error("Slow mode is for channels."); const v = /^off$/i.test(a.trim()) ? 0 : Number(a.trim()); if (!(v >= 0 && v <= 3600)) throw new Error("Usage: /slowmode <0-3600|off>"); const ok = await W.ask({ title: "Set slow mode in #" + c.slug + "?", text: v ? v + " seconds between messages." : "Slow mode off.", confirm: "Set" }); if (!ok) return; const r = await call("chat_channel_set", { p_id: c.id, p_slow: v }); r === "ok" ? (say("Slow mode " + (v ? v + "s" : "off") + "."), tickNow()) : fail(errText(r)); } },
    { name: "pin", usage: "", desc: "Pin the message you are replying to (or the latest)", cap: "pin", run: async () => { const t = CH.reply || [...CH.msgs].reverse().find(m => ["user", "announcement"].includes(m.kind) && !m.deleted); if (!t) throw new Error("Nothing to pin."); const r = await call("chat_pin", { p_id: t.id, p_pin: true }); r === "ok" ? (say("Pinned."), tickNow()) : fail(errText(r)); } },
    { name: "unpin", usage: "", desc: "Unpin the replied-to message (or the latest pin)", cap: "pin", run: async () => { const p = (CH.d.pins || [])[0]; const t = CH.reply || (p && { id: p.id }); if (!t) throw new Error("Nothing is pinned here."); const r = await call("chat_pin", { p_id: t.id, p_pin: false }); r === "ok" ? (say("Unpinned."), tickNow()) : fail(errText(r)); } }
  ];
  async function fullId(short) { const i = await call("app_applicant_info", { p_app: short }); if (!i) throw new Error("Application not found."); return i.id; }
  function appList(r, title) {
    if (!r) throw new Error("Not allowed.");
    sayNodes([el("b", {}, title + " (" + r.length + ")"), ...(r.length ? r.map(x => el("div", { class: "nrow" }, el("b", {}, x.short), " · " + x.name + " · " + tOf({ type: x.type }).title + " · ", stTag(x.status), el("small", {}, " " + rel(x.at) + (x.assigned ? " · claimed by " + x.assigned : "")))) : [el("div", { class: "hint" }, "Nothing here.")]), el("div", { class: "hint" }, "Use the 8-character ID with /review, /claim, /approve, /deny.")], title);
  }
  async function decideCmd(status, a) {
    const [id, reason] = toks(a, 1); if (!id) throw new Error("Usage: /" + (status === "approved" ? "approve" : "deny") + " <application id>" + (status === "denied" ? " <reason>" : " [reason]"));
    const info = await call("app_applicant_info", { p_app: id }); if (!info) throw new Error("Application not found."); if (status === "denied") needReason(reason);
    const ok = await W.ask({ title: (status === "approved" ? "Approve " : "Deny ") + (info.display_name || info.name) + "'s application?", text: "ID " + ref(info.id) + (reason ? " · Reason: " + reason : ""), confirm: status === "approved" ? "Approve" : "Deny", danger: status === "denied" }); if (!ok) return;
    const r = await call("chat_decide_application", { p_app_id: info.id, p_status: status, p_reason: reason }); r === "ok" ? say("Done: " + status + ".") : fail(errText(r)); tickNow();
  }
  async function toggleCmd(open, a) {
    const t = a.trim().toLowerCase(); if (!t) throw new Error("Usage: /" + (open ? "openapps" : "closeapps") + " <type|all>  (types: " + T.map(x => x.id).join(", ") + ")");
    const ok = await W.ask({ title: (open ? "Open " : "Close ") + (t === "all" ? "ALL" : t) + " applications?", text: open ? "People will be able to apply again." : "People will not be able to submit new applications of this type.", confirm: open ? "Open" : "Close", danger: !open }); if (!ok) return;
    const r = await call("app_toggle", { p_type: t, p_open: open }); String(r).startsWith("ok") ? say("Done.") : fail(errText(r));
  }
  async function stepCmd(dir, a) {
    const s = resolveStaff(toks(a, 1)[0]); const ok = await W.ask({ title: (dir > 0 ? "Promote " : "Demote ") + s.name + "?", text: "Current rank: " + s.rank, confirm: dir > 0 ? "Promote" : "Demote" }); if (!ok) return;
    const r = await call("staff_rank_step", { p_discord_id: s.id, p_dir: dir }); r && r.ok ? say(s.name + ": " + r.from + " → " + r.to) : fail(errText(r && r.error)); tickNow();
  }
  async function lockCmd(lock) {
    const c = curChan(); if (!c) throw new Error("Open a channel first."); const ok = await W.ask({ title: (lock ? "Lock #" : "Unlock #") + c.slug + "?", text: lock ? "Only administrators will be able to post." : "Posting is restored.", confirm: lock ? "Lock" : "Unlock" }); if (!ok) return;
    const r = await call("chat_channel_set", { p_id: c.id, p_locked: lock }); r === "ok" ? (say(lock ? "Locked." : "Unlocked."), tickNow()) : fail(errText(r));
  }
  async function runCommand(text) {
    const m = /^\/(\w+)\s*([\s\S]*)$/.exec(text.trim()); const c = m && COMMANDS.find(x => x.name === m[1].toLowerCase());
    CH.local = []; CH.stick = true;
    if (!c) return fail("Unknown command /" + (m ? m[1] : "") + ". Type /help to see what you can use.");
    if (c.cap && !can(c.cap)) return fail("You don't have permission for /" + c.name + ".");
    try { await c.run(m[2] || ""); } catch (e) { fail(e.message || "That didn't work."); }
  }

  /* ---------------- privacy: watermark, hide-on-leave, screenshot-key detection ---------------- */
  const PV = { wm: null, layer: null, mo: null, iv: null, hold: 0, bound: false, strikes: 0 };
  function wmUri(t) {
    const svg = "<svg xmlns='http://www.w3.org/2000/svg' width='330' height='130'><text x='165' y='65' transform='rotate(-24 165 65)' text-anchor='middle' font-family='Arial,sans-serif' font-size='15' font-weight='700' fill='white' fill-opacity='0.12' stroke='black' stroke-opacity='0.10' stroke-width='0.6'>" + t.replace(/[&<>']/g, "") + "</text></svg>";
    return "url(\"data:image/svg+xml;utf8," + encodeURIComponent(svg) + "\")";
  }
  function mkLayer() {
    const t = PV.wm ? PV.wm.username + " · " + PV.wm.id : "Will Mac staff";
    const l = el("div", { id: "chwm", "aria-hidden": "true" }); l.setAttribute("style", "position:absolute!important;inset:0!important;z-index:25!important;pointer-events:none!important;opacity:1!important;display:block!important;visibility:visible!important;background-image:" + wmUri(t) + "!important;background-repeat:repeat!important;mix-blend-mode:normal!important;transform:none!important");
    return l;
  }
  function ensureWm() { const o = $$("#chwm"); if (o) o.remove(); PV.layer = null; }   // watermark removed on request
  function shield() { let s = $$("#chshield"); if (!s) { s = el("div", { id: "chshield", role: "status" }, el("div", {}, el("b", {}, "🔒 Privacy mode"), el("div", {}, "Staff chat is hidden. Return to this tab to continue."))); (CH.root || document.body).append(s); } return s; }
  function holdShield(ms) { shield().classList.add("on"); PV.hold = Date.now() + ms; setTimeout(() => { if (Date.now() >= PV.hold && !document.hidden && !(PV.blurNow)) unshield(); }, ms + 30); }
  function unshield() { const s = $$("#chshield"); if (s) s.classList.remove("on"); }
  function report(kind) { if (Date.now() - (PV.lastReport || 0) < 4000) return; PV.lastReport = Date.now(); try { call("chat_privacy_event", { p_kind: kind, p_scope: CH.scope }).catch(() => {}); } catch (e) {} }
  function pvVis() { if (document.hidden) { shield().classList.add("on"); } else if (!PV.blurNow && Date.now() >= PV.hold) unshield(); }
  function pvBlur() { if (store.get("wm-chat-blurfocus", false)) { PV.blurNow = true; shield().classList.add("on"); } }
  function pvFocus() { PV.blurNow = false; if (!document.hidden && Date.now() >= PV.hold) unshield(); }
  function pvKey(e) {
    let k = ""; const key = e.key || "";
    if (key === "PrintScreen" || e.code === "PrintScreen") k = "PrintScreen";
    else if ((e.metaKey || e.ctrlKey) && e.shiftKey && /^s$/i.test(key) && e.metaKey) k = "Win+Shift+S";
    else if (e.metaKey && e.shiftKey && /^[345]$/.test(key)) k = "Cmd+Shift+3/4/5";
    else if (e.metaKey && e.shiftKey && /^[#$%]$/.test(key)) k = "Cmd+Shift+3/4/5";
    if (!k) return;
    holdShield(2500); try { const p = navigator.clipboard.writeText("Screenshots of staff chat are logged."); if (p && p.catch) p.catch(() => {}); } catch (err) {} report(k);
  }
  function pvPrint() { holdShield(3000); report("print"); }
  function privacyStart() {
    if (PV.bound) return; PV.bound = true;
    call("chat_watermark").then(w => { PV.wm = w; const o = $$("#chwm"); if (o) o.remove(); PV.layer = null; ensureWm(); }).catch(() => {});
    ensureWm();
    document.addEventListener("visibilitychange", pvVis); window.addEventListener("blur", pvBlur); window.addEventListener("focus", pvFocus);
    document.addEventListener("keydown", pvKey, true); document.addEventListener("keyup", pvKey, true); window.addEventListener("beforeprint", pvPrint);
    document.addEventListener("contextmenu", pvCtx, true);
    try { PV.mo = new MutationObserver(() => ensureWm()); PV.mo.observe(CH.root, { childList: true, subtree: true, attributes: true, attributeFilter: ["style", "class", "id", "hidden"] }); } catch (e) {}
    PV.iv = setInterval(ensureWm, 1500);
    if (document.hidden) shield().classList.add("on");
  }
  function pvCtx(e) { if (e.target.closest && e.target.closest("#chm img")) e.preventDefault(); }
  function privacyStop() {
    if (!PV.bound) return; PV.bound = false; clearInterval(PV.iv); if (PV.mo) PV.mo.disconnect();
    document.removeEventListener("visibilitychange", pvVis); window.removeEventListener("blur", pvBlur); window.removeEventListener("focus", pvFocus);
    document.removeEventListener("keydown", pvKey, true); document.removeEventListener("keyup", pvKey, true); window.removeEventListener("beforeprint", pvPrint); document.removeEventListener("contextmenu", pvCtx, true);
    PV.layer = null; PV.blurNow = false;
  }

  /* ---------------- administrator screenshots ---------------- */
  function loadLib() {
    return new Promise((res, rej) => { if (window.html2canvas) return res(); const s = document.createElement("script"); s.src = "vendor/html2canvas.min.js"; s.onload = () => res(); s.onerror = () => rej(new Error("Screenshot tool failed to load")); document.head.append(s); });
  }
  async function shot() {
    if (!can("screenshot")) { try { call("chat_screenshot", { p_scope: CH.scope }).catch(() => {}); } catch (e) {} return toast("Only administrators can take screenshots. This attempt was logged.", 4000); }
    const sc = CH.scope; if (!sc) return;
    let r; try { r = await call("chat_screenshot", { p_scope: sc }); } catch (e) { r = null; }
    if (!r || !r.ok) return toast(r && r.error === "forbidden" ? "Not allowed. This attempt was logged." : errText(r && r.error), 4500);
    try {
      await loadLib(); ensureWm(); const cm = $$("#chcm"); unshield();
      const canvas = await html2canvas(cm, { backgroundColor: "#14092a", useCORS: true, logging: false, scale: Math.min(2, window.devicePixelRatio || 1),
        ignoreElements: n => n.id === "chshield" || (n.classList && (n.classList.contains("tb") || n.classList.contains("pick"))),
        onclone: d => { const m = d.querySelector("#chm"), c = d.querySelector("#chcm"); if (m) { m.style.overflow = "visible"; m.style.flex = "none"; m.style.height = "auto"; } if (c) { c.style.height = "auto"; c.style.overflow = "visible"; } const ch = d.querySelector(".chat"); if (ch) { ch.style.height = "auto"; ch.style.display = "block"; } } });
      const cx2 = canvas.getContext("2d"), pad = 28 * (canvas.width / Math.max(1, cm.offsetWidth));
      const out = document.createElement("canvas"); out.width = canvas.width; out.height = canvas.height + Math.round(pad * 1.6); const o = out.getContext("2d");
      o.fillStyle = "#14092a"; o.fillRect(0, 0, out.width, out.height); o.drawImage(canvas, 0, 0);
      o.fillStyle = "#ffb3e6"; o.font = "600 " + Math.round(pad * 0.55) + "px sans-serif";
      o.fillText("Will Mac staff chat · " + r.label + " · captured by " + r.username + " (" + r.discord_id + ") · " + new Date(r.at).toLocaleString() + " · log #" + r.id, pad * 0.5, canvas.height + pad * 1.05);
      const a = document.createElement("a"); a.href = out.toDataURL("image/png"); a.download = "willmac-" + r.label.replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "") + "-" + new Date().toISOString().slice(0, 16).replace(/[:T]/g, "") + ".png";
      document.body.append(a); a.click(); a.remove(); toast("Screenshot saved and logged (#" + r.id + ")", 4000);
    } catch (e) { toast("The screenshot was logged but couldn't be rendered: " + (e.message || e), 5000); }
  }
  async function shotLog() {
    let rows; try { rows = await call("list_screenshot_log", { p_limit: 200 }); } catch (e) { rows = null; }
    W.dlg("Screenshot audit log", (box, close) => box.append(el("div", { class: "hint" }, "Every screenshot taken with the built-in tool, every refused attempt, and every screenshot key press noticed by a browser."),
      el("div", { style: "max-height:50vh;overflow:auto" }, ...(rows && rows.length ? rows.map(x => el("div", { class: "mlog", style: "grid-template-columns:1fr" }, el("div", {}, el("b", { class: x.kind === "taken" ? "act-unban" : x.kind === "denied" ? "act-ban" : "act-timeout" }, x.kind === "taken" ? "SCREENSHOT" : x.kind === "denied" ? "REFUSED" : "KEY DETECTED"), " · " + (x.actor_username || x.actor_name) + " (" + x.actor_id + ")"),
        el("div", { class: "t" }, fmt(x.at) + (x.scope_label ? " · " + x.scope_label : "") + (x.detail ? " · " + x.detail : "")))) : [el("div", { class: "plain" }, "Nothing logged yet.")]))));
  }
  W.shot = shot;
  W.chatCommands = COMMANDS;
})();
