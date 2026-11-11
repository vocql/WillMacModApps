// ============ EDIT THIS FILE ============
// Everything on the site comes from here. After editing, commit the change on GitHub.
window.WM_CONFIG = {
  // ---- 1) Saving applications (powers the /applications dashboard) ----
  // Free Supabase project. See README.md, "Step 2". Paste both values from
  // Supabase > Project Settings > API (Project URL and the anon / publishable key).
  supabaseUrl: "",
  supabaseKey: "",

  // ---- 2) Discord alert (optional but recommended) ----
  // Channel settings > Integrations > Webhooks > New Webhook > Copy URL
  discordWebhook: "",

  // ---- 3) Google Form copy (optional) ----
  // entry.XXXX ids in question order (see README). Leave entries empty to skip.
  googleForm: {
    formId: "1FAIpQLSfo13rG_eUvgKL9OgxLlCqfXij4BxSFZz3Qny7CJv8qRTwfww",
    entries: []
  },

  applicationsOpen: true,
  cooldownMinutes: 30,   // how long before the same browser can apply again
  minAnswerLength: 20,   // minimum characters for the long answers

  requirements: [
    "Must be a member of the server for 3+ months.",
    "Must have 2FA enabled on your Discord account.",
    "Must be familiar with how the server runs and is operated."
  ],

  // Same picture links as before
  logo: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/p6IK2p.webp",
  background: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/96kvVB.jpg",
  staff: [
    { name: "Will Mac", role: "Owner", img: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/p6IK2p.webp" },
    { name: "Debug.exe", role: "Co-Owner", img: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/fu02p0.webp" },
    { name: "Voqcl", role: "Admin", img: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/jQl2KH.png" },
    { name: "Kelpie", role: "Lead Moderator", img: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/K1uxkp.webp" },
    { name: "Spizike", role: "Lead Moderator", img: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/1BPOl7.webp" },
    { name: "Myguyvr", role: "Moderator", img: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/3mcWjr.webp" },
    { name: "Dean", role: "Moderator", img: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/uZC5kf.webp" },
    { name: "Khxal", role: "Moderator", img: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/sg4sJp.webp" },
    { name: "Chrxmio", role: "Moderator", img: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/4tUobL.webp" },
    { name: "TyriusTheVA", role: "Moderator", img: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/JPda0S.webp" },
    { name: "LilSkeptrim", role: "Moderator", img: "https://images.guns.lol/637041cec591a6ab27615f0e2db44d08f3ce0c55/iN1Hni.webp" },
  ],

  faq: [
    ["Who can apply?", "Any member who has been in the server for 3+ months, has 2FA enabled, and is familiar with how the server runs and is operated."],
    ["Why do I need 2FA?", "Moderators have powerful permissions. Two-factor authentication keeps staff accounts safe from being hijacked."],
    ["What happens after I apply?", "The staff team reviews every application. If you're shortlisted, we'll contact you on Discord, so keep your DMs open."],
    ["Does applying guarantee I'll be accepted?", "No. We read every application, but spots are limited and we only accept the best fits."]
  ],

  // `short` is the label staff see. `tip` is a small hint shown to applicants.
  questions: [
    { label: "What is your Discord name?", hint: "(e.g. WillMacGTA)", short: "Discord name", type: "text", max: 60,
      tip: "So we know who to contact if you're shortlisted." },
    { label: "Why do you want to be staff?", short: "Why staff?", type: "area", max: 1000,
      tip: "Tell us what drives you. Specific reasons beat generic ones." },
    { label: "Have you had any other experiences on Discord like this? If so, what?", short: "Other experience", type: "area", max: 1000,
      tip: "Servers you've moderated, roles you've held, how long for." },
    { label: "How active are you on Discord every day?", short: "Daily activity", type: "area", max: 1000,
      tip: "Roughly which hours and how many per day." },
    { label: "How would you deal with someone who's spamming?", short: "Dealing with spam", type: "area", max: 1000,
      tip: "Walk us through your steps, from first reaction to final action." },
    { label: "How would you deal with a raider?", short: "Dealing with a raider", type: "area", max: 1000,
      tip: "Think speed: what do you do in the first minute?" },
    { label: "How do you warn, kick and ban people?", short: "Warn, kick and ban", type: "area", max: 1000,
      tip: "When is each one appropriate, and how do you stay fair?" },
    { label: "How would you benefit the server? What would you change, and why?", short: "Benefit to the server", type: "area", max: 1000,
      tip: "One or two concrete ideas are better than a long list." }
  ]
};
