/* ============================================================
   AI NEWSLETTER FORMATTER — script.js
   All application logic. Sections:
     1.  Element references & app state
     2.  Small utilities (escape, toast, status pill)
     3.  Init: date, char counter, custom-niche toggle, listeners
     4.  Niche voice guidance
     5.  Prompt construction
     6.  Claude call (dual-mode: keyless → x-api-key fallback)
     7.  JSON cleanup & parsing
     8.  Image chain (Pexels → Picsum → inline SVG)
     9.  Render preview
     10. Email-safe HTML builder (inline CSS, 600px)
     11. Plain-text builder
     12. Exports: PDF, Word, Copy HTML, Copy/Download text
     13. Main "Format Newsletter" orchestration
   ============================================================ */

/* ---------- 1. ELEMENT REFERENCES & STATE ---------- */
const $ = (id) => document.getElementById(id);

const els = {
  rawNotes: $("rawNotes"),
  charCount: $("charCount"),
  niche: $("niche"),
  customNicheWrap: $("customNicheWrap"),
  customNiche: $("customNiche"),
  tone: $("tone"),
  nlName: $("nlName"),
  issueDate: $("issueDate"),
  apiKey: $("apiKey"),
  imgApiKey: $("imgApiKey"),
  formatBtn: $("formatBtn"),
  preview: $("preview"),
  statusPill: $("statusPill"),
  statusText: $("statusText"),
  pdfBtn: $("pdfBtn"),
  docBtn: $("docBtn"),
  htmlBtn: $("htmlBtn"),
  txtBtn: $("txtBtn"),
  toastWrap: $("toastWrap"),
};

// Holds the most recently generated newsletter data (for exports).
let currentNewsletter = null;

/* ---------- 2. SMALL UTILITIES ---------- */

// Escape user/AI text before injecting into HTML to avoid breaking markup.
function escapeHtml(str = "") {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// Transient toast message. type ∈ {"", "ok", "warn", "error"}.
function toast(message, type = "") {
  const el = document.createElement("div");
  el.className = "toast" + (type ? " toast-" + type : "");
  el.textContent = message;
  els.toastWrap.appendChild(el);
  // force reflow so the transition runs, then show
  requestAnimationFrame(() => el.classList.add("show"));
  setTimeout(() => {
    el.classList.remove("show");
    setTimeout(() => el.remove(), 250);
  }, 2600);
}

// Update the environment-status pill in the top bar.
function setStatus(state, text) {
  els.statusPill.className =
    "pill " +
    (state === "ok" ? "pill-ok" : state === "warn" ? "pill-warn" : "pill-neutral");
  els.statusText.textContent = text;
}

// Toggle the button's loading state (spinner + disabled).
function setLoading(isLoading) {
  const label = els.formatBtn.querySelector(".btn-label");
  const spinner = els.formatBtn.querySelector(".spinner");
  els.formatBtn.disabled = isLoading;
  label.textContent = isLoading ? "Formatting…" : "Format Newsletter";
  spinner.classList.toggle("hidden", !isLoading);
}

// Enable/disable the export buttons together.
function setExportsEnabled(on) {
  [els.pdfBtn, els.docBtn, els.htmlBtn, els.txtBtn].forEach((b) => (b.disabled = !on));
}

// Resolve the effective niche (preset value or the custom text field).
function getNiche() {
  if (els.niche.value === "__custom") {
    return els.customNiche.value.trim() || "General";
  }
  return els.niche.value;
}

/* ---------- 3. INIT ---------- */
function init() {
  // Auto-fill issue date with today (YYYY-MM-DD for <input type=date>).
  const today = new Date();
  const iso = today.toISOString().slice(0, 10);
  els.issueDate.value = iso;

  // Live character counter for the textarea.
  const updateCount = () => {
    const n = els.rawNotes.value.length;
    els.charCount.textContent = n.toLocaleString() + " character" + (n === 1 ? "" : "s");
  };
  els.rawNotes.addEventListener("input", updateCount);
  updateCount();

  // Reveal the custom-niche input only when "Custom…" is selected.
  els.niche.addEventListener("change", () => {
    els.customNicheWrap.classList.toggle("hidden", els.niche.value !== "__custom");
  });

  // Wire up actions.
  els.formatBtn.addEventListener("click", onFormat);
  els.pdfBtn.addEventListener("click", exportPDF);
  els.docBtn.addEventListener("click", exportWord);
  els.htmlBtn.addEventListener("click", copyRichHtml);
  els.txtBtn.addEventListener("click", copyPlainText);

  // Default status: AI used if available, otherwise offline formatting.
  setStatus("ok", "Ready (AI or offline)");
}

/* ---------- 4. NICHE VOICE GUIDANCE ----------
   A short style note per niche so Claude tunes vocabulary & formality. */
function nicheVoice(niche) {
  const map = {
    Healthcare: "Formal, trust-led, evidence-based. Avoid hype; cite implications carefully.",
    Finance: "Formal, precise, trust-led. Numbers-forward, measured, no exaggeration.",
    Gaming: "Cheeky, casual, playful. Insider slang okay; keep it fun and fast.",
    "B2B SaaS": "Educational and value-first. Practical takeaways, ROI framing, no fluff.",
    Sports: "Energetic and vivid. Momentum-driven language, strong verbs.",
    Lifestyle: "Warm and narrative. Sensory, human, inviting.",
    "Editorial Digest": "Warm and narrative, thoughtful curation, a clear editorial point of view.",
    Technology: "Sharp and forward-looking. Clear on why it matters technically and commercially.",
    Marketing: "Persuasive and snappy. Hooks, frameworks, actionable tactics.",
    "Crypto/Web3": "Fast-moving and savvy. Explain mechanisms plainly, flag risk honestly.",
  };
  return map[niche] || "Clear, engaging, and well-suited to the audience.";
}

/* ---------- 5. PROMPT CONSTRUCTION ---------- */
function buildPrompt(rawNotes, niche, tone) {
  const schema = `{
  "subjectLine": "≤60 chars, ≤1 relevant emoji",
  "previewText": "~90 char preheader",
  "intro": "1–2 sentence hook",
  "leadStory": { "headline": "", "whyItMatters": "", "body": "100–300 words", "cta": "", "imageKeyword": "2–4 words" },
  "secondaryStories": [ { "headline": "", "body": "50–150 words", "link": "", "imageKeyword": "" } ],
  "quickHits": [ "one-line item" ],
  "primaryCta": { "label": "", "url": "#" }
}`;

  return [
    `You are an expert newsletter editor for the "${niche}" niche.`,
    `Write in a ${tone} voice. Niche style guidance: ${nicheVoice(niche)}`,
    ``,
    `Apply inverted-pyramid / Smart Brevity writing:`,
    `- Lead with the single most important point.`,
    `- Short sentences and scannable blocks.`,
    `- Include a bolded "why it matters" for the lead story.`,
    `- Keep the newsletter to 4–6 sections total (lead + secondary + quick hits).`,
    ``,
    `Turn the raw notes below into a polished newsletter.`,
    `Return ONLY valid JSON — no backticks, no commentary — matching exactly this schema:`,
    schema,
    ``,
    `RAW NOTES:`,
    rawNotes,
  ].join("\n");
}

/* ---------- 6. CLAUDE CALL (DUAL-MODE) ----------
   First try the keyless artifact-style call (works inside the
   claude.ai artifact sandbox). If it fails — e.g. opened as a local
   file — reveal/use the API key with direct-browser-access headers. */
async function callClaude(prompt) {
  const model = "claude-sonnet-4-20250514";
  const body = JSON.stringify({
    model,
    max_tokens: 2000,
    messages: [{ role: "user", content: prompt }],
  });

  // --- Attempt 1: keyless ---
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
    });
    if (res.ok) {
      const data = await res.json();
      setStatus("ok", "AI: connected (keyless)");
      return extractText(data);
    }
    throw new Error("Keyless call returned " + res.status);
  } catch (errKeyless) {
    // --- Attempt 2: with API key ---
    const key = els.apiKey.value.trim();
    if (!key) {
      // No key available. Signal onFormat to fall back to the offline
      // local formatter so the app still works (e.g. opened as a file).
      const noKeyErr = new Error("no-key");
      noKeyErr.noKey = true;
      throw noKeyErr;
    }
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
        "anthropic-dangerous-direct-browser-access": "true",
      },
      body,
    });
    if (!res.ok) {
      const txt = await res.text().catch(() => "");
      setStatus("warn", "AI: needs key");
      throw new Error("Claude API error " + res.status + ": " + txt.slice(0, 180));
    }
    const data = await res.json();
    setStatus("ok", "AI: connected (key)");
    return extractText(data);
  }
}

// Pull the assistant text out of the messages API response shape.
function extractText(data) {
  if (data && Array.isArray(data.content)) {
    return data.content.map((b) => b.text || "").join("");
  }
  // Be forgiving of alternative shapes.
  return (data && (data.completion || data.text)) || "";
}

/* ---------- 7. JSON CLEANUP & PARSING ----------
   Claude is asked for raw JSON, but strip stray backticks / fences and
   isolate the outermost {...} before parsing. Throws on hard failure. */
function parseNewsletterJson(text) {
  let cleaned = String(text).trim();
  // Remove ```json ... ``` fences and stray backticks if present.
  cleaned = cleaned.replace(/```json/gi, "").replace(/```/g, "").trim();
  // Isolate the first '{' to the last '}'.
  const first = cleaned.indexOf("{");
  const last = cleaned.lastIndexOf("}");
  if (first !== -1 && last !== -1 && last > first) {
    cleaned = cleaned.slice(first, last + 1);
  }
  return JSON.parse(cleaned);
}

/* ---------- 8. IMAGE CHAIN (graceful fallback) ----------
   For a keyword, resolve an image source in priority order:
     1. Image API (Pexels preferred — CORS-friendly), if a key exists.
     2. Lorem Picsum seeded URL (no key required).
     3. Inline SVG gradient hero (data: URI) — guaranteed to render.
   NOTE: the inline-SVG fallback exists because the claude.ai Artifact
   CSP can block external images; this keeps the layout intact and the
   app degrades gracefully no matter what. */
async function resolveImage(keyword, headline) {
  const kw = (keyword || headline || "news").trim();

  // 1) Pexels via key
  const imgKey = els.imgApiKey.value.trim();
  if (imgKey) {
    try {
      const res = await fetch(
        "https://api.pexels.com/v1/search?per_page=1&query=" + encodeURIComponent(kw),
        { headers: { Authorization: imgKey } }
      );
      if (res.ok) {
        const data = await res.json();
        const photo = data.photos && data.photos[0];
        if (photo) {
          return {
            url: photo.src.landscape || photo.src.large || photo.src.medium,
            attribution: "Photo: " + (photo.photographer || "Pexels") + " / Pexels",
          };
        }
      }
    } catch (_) {
      /* fall through to keyless options */
    }
  }

  // 2) Lorem Picsum (keyless, seeded so the same keyword is stable)
  //    We optimistically use it; if the network blocks it, the <img>
  //    onerror handler swaps in the SVG fallback at render time.
  return {
    url: "https://picsum.photos/seed/" + encodeURIComponent(kw) + "/800/400",
    attribution: "",
    fallbackSvg: svgHero(kw, headline),
  };
}

// 3) Build a seeded SVG gradient banner with the headline as text,
//    returned as a data: URI so it always renders inline.
function svgHero(keyword, headline = "") {
  // Derive two hues deterministically from the keyword string.
  let h = 0;
  for (let i = 0; i < keyword.length; i++) h = (h * 31 + keyword.charCodeAt(i)) % 360;
  const h2 = (h + 40) % 360;
  const title = escapeHtml((headline || keyword).slice(0, 60));
  const svg =
    `<svg xmlns='http://www.w3.org/2000/svg' width='800' height='400' viewBox='0 0 800 400'>` +
    `<defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'>` +
    `<stop offset='0' stop-color='hsl(${h},72%,55%)'/>` +
    `<stop offset='1' stop-color='hsl(${h2},70%,42%)'/>` +
    `</linearGradient></defs>` +
    `<rect width='800' height='400' fill='url(#g)'/>` +
    `<text x='40' y='360' font-family='Segoe UI, Arial, sans-serif' font-size='28' ` +
    `font-weight='700' fill='rgba(255,255,255,0.95)'>${title}</text>` +
    `</svg>`;
  return "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg);
}

/* ---------- 9. RENDER PREVIEW ----------
   Build the on-screen newsletter (modern CSS from style.css).
   Images use an onerror handler to swap to the SVG fallback. */
function renderPreview(nl, heroImg) {
  const brand = escapeHtml(els.nlName.value.trim() || "Your Newsletter");
  const dateStr = formatDateHuman(els.issueDate.value);

  // Hero image markup (with graceful onerror fallback to SVG).
  let heroHtml = "";
  if (heroImg) {
    const fb = heroImg.fallbackSvg
      ? ` onerror="this.onerror=null;this.src='${heroImg.fallbackSvg}'"`
      : "";
    heroHtml =
      `<img class="nl-hero-img" src="${heroImg.url}"${fb} alt="${escapeHtml(nl.leadStory.imageKeyword || "")}" />` +
      (heroImg.attribution ? `<div class="nl-attr">${escapeHtml(heroImg.attribution)}</div>` : "");
  }

  // Secondary stories.
  const secondary = (nl.secondaryStories || [])
    .map((s) => {
      const link = s.link
        ? `<a href="${escapeHtml(s.link)}">Read more →</a>`
        : "";
      return `<div class="nl-secondary">
        <h4>${escapeHtml(s.headline || "")}</h4>
        <p>${escapeHtml(s.body || "")}</p>
        ${link}
      </div>`;
    })
    .join("");

  // Quick hits.
  const quickHits = (nl.quickHits || []).length
    ? `<div class="nl-section-label">Quick hits</div>
       <ul class="nl-quickhits">${nl.quickHits
         .map((q) => `<li>${escapeHtml(q)}</li>`)
         .join("")}</ul>`
    : "";

  const cta = nl.primaryCta && nl.primaryCta.label
    ? `<a class="nl-cta" href="${escapeHtml(nl.primaryCta.url || "#")}">${escapeHtml(nl.primaryCta.label)}</a>`
    : "";

  const leadCta = nl.leadStory && nl.leadStory.cta
    ? `<a class="nl-cta" href="${escapeHtml((nl.primaryCta && nl.primaryCta.url) || "#")}">${escapeHtml(nl.leadStory.cta)}</a>`
    : "";

  els.preview.innerHTML = `
    <div class="nl-wrap">
      <div class="nl-masthead">
        <div class="nl-brand">${brand}</div>
        <div class="nl-meta">${dateStr}</div>
      </div>
      <div class="nl-body">
        <div class="nl-subject">${escapeHtml(nl.subjectLine || "")}</div>
        <div class="nl-preview-text">${escapeHtml(nl.previewText || "")}</div>
        <p class="nl-intro">${escapeHtml(nl.intro || "")}</p>

        ${heroHtml}
        <h2 class="nl-lead-headline">${escapeHtml(nl.leadStory?.headline || "")}</h2>
        ${nl.leadStory?.whyItMatters ? `<div class="nl-why"><strong>Why it matters:</strong> ${escapeHtml(nl.leadStory.whyItMatters)}</div>` : ""}
        ${paragraphs(nl.leadStory?.body)}
        ${leadCta}

        ${secondary ? `<hr class="nl-divider" /><div class="nl-section-label">More stories</div>${secondary}` : ""}
        ${quickHits ? `<hr class="nl-divider" />${quickHits}` : ""}
        ${cta ? `<div style="text-align:center;margin-top:10px;">${cta}</div>` : ""}
      </div>
      <div class="nl-footer">
        ${brand} · ${dateStr}<br/>You're receiving this because you subscribed.
      </div>
    </div>`;
}

// Split a body string into <p> paragraphs.
function paragraphs(text = "") {
  return String(text)
    .split(/\n{2,}|\n/)
    .filter((p) => p.trim())
    .map((p) => `<p class="nl-paragraph">${escapeHtml(p.trim())}</p>`)
    .join("");
}

// Human-friendly date from a YYYY-MM-DD string.
function formatDateHuman(iso) {
  if (!iso) return "";
  const d = new Date(iso + "T00:00:00");
  return d.toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
}

/* ---------- 10. EMAIL-SAFE HTML BUILDER ----------
   Separate from the on-screen preview: a 600px container with INLINE
   CSS and web-safe fonts so it survives email clients. Used by the
   "Copy as HTML" and Word exports. heroSrc is a fully-resolved URL or
   data: URI (the SVG fallback) so the export never references a broken
   external image. */
function buildEmailHtml(nl, heroSrc) {
  const brand = escapeHtml(els.nlName.value.trim() || "Your Newsletter");
  const dateStr = formatDateHuman(els.issueDate.value);
  const accent = "#4f46e5";
  const font = "Arial, Helvetica, sans-serif";

  const lead = nl.leadStory || {};
  const heroImg = heroSrc
    ? `<img src="${heroSrc}" width="536" style="width:100%;max-width:536px;border-radius:8px;display:block;margin:0 0 14px;" alt="" />`
    : "";

  const secondary = (nl.secondaryStories || [])
    .map(
      (s) => `
      <tr><td style="padding:0 0 18px;">
        <h3 style="margin:0 0 6px;font:700 18px ${font};color:#1b1f2a;">${escapeHtml(s.headline || "")}</h3>
        <p style="margin:0 0 6px;font:400 15px/1.5 ${font};color:#333;">${escapeHtml(s.body || "")}</p>
        ${s.link ? `<a href="${escapeHtml(s.link)}" style="font:600 14px ${font};color:${accent};text-decoration:none;">Read more &rarr;</a>` : ""}
      </td></tr>`
    )
    .join("");

  const quick = (nl.quickHits || []).length
    ? `<tr><td style="padding:6px 0 18px;">
         <p style="margin:0 0 10px;font:700 12px ${font};letter-spacing:1px;text-transform:uppercase;color:#6a7180;">Quick hits</p>
         ${nl.quickHits
           .map(
             (q) =>
               `<p style="margin:0 0 8px;font:400 15px/1.4 ${font};color:#333;">&rarr; ${escapeHtml(q)}</p>`
           )
           .join("")}
       </td></tr>`
    : "";

  const cta =
    nl.primaryCta && nl.primaryCta.label
      ? `<tr><td align="center" style="padding:8px 0 4px;">
           <a href="${escapeHtml(nl.primaryCta.url || "#")}" style="display:inline-block;background:${accent};color:#fff;font:700 15px ${font};text-decoration:none;padding:12px 24px;border-radius:8px;">${escapeHtml(nl.primaryCta.label)}</a>
         </td></tr>`
      : "";

  // Outer wrapper centers a fixed 600px table — the email standard.
  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f6f7fb;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f6f7fb;padding:24px 0;">
<tr><td align="center">
  <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="width:600px;max-width:600px;background:#ffffff;border-radius:12px;overflow:hidden;">
    <tr><td style="padding:22px 32px;border-bottom:3px solid ${accent};">
      <div style="font:800 22px ${font};color:#1b1f2a;letter-spacing:-0.5px;">${brand}</div>
      <div style="font:400 12px ${font};color:#6a7180;margin-top:2px;">${dateStr}</div>
    </td></tr>
    <tr><td style="padding:24px 32px;">
      <p style="margin:0 0 4px;font:700 11px ${font};letter-spacing:1px;text-transform:uppercase;color:${accent};">${escapeHtml(nl.subjectLine || "")}</p>
      <p style="margin:0 0 18px;font:400 13px ${font};color:#6a7180;">${escapeHtml(nl.previewText || "")}</p>
      <p style="margin:0 0 20px;font:400 16px/1.6 ${font};color:#1b1f2a;">${escapeHtml(nl.intro || "")}</p>
      ${heroImg}
      <h2 style="margin:4px 0 10px;font:800 24px/1.2 ${font};color:#1b1f2a;letter-spacing:-0.5px;">${escapeHtml(lead.headline || "")}</h2>
      ${lead.whyItMatters ? `<p style="margin:0 0 14px;background:#efedff;border-left:3px solid ${accent};padding:10px 14px;border-radius:6px;font:400 15px ${font};color:#1b1f2a;"><strong style="color:${accent};">Why it matters:</strong> ${escapeHtml(lead.whyItMatters)}</p>` : ""}
      <p style="margin:0 0 16px;font:400 15px/1.6 ${font};color:#333;">${escapeHtml(lead.body || "").replace(/\n+/g, "</p><p style='margin:0 0 16px;font:400 15px/1.6 " + font + ";color:#333;'>")}</p>
      ${lead.cta ? `<a href="${escapeHtml((nl.primaryCta && nl.primaryCta.url) || "#")}" style="display:inline-block;background:${accent};color:#fff;font:700 15px ${font};text-decoration:none;padding:11px 20px;border-radius:8px;">${escapeHtml(lead.cta)}</a>` : ""}
      <hr style="border:none;border-top:1px solid #e6e8ef;margin:26px 0;" />
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
        ${secondary}${quick}${cta}
      </table>
    </td></tr>
    <tr><td style="padding:18px 32px 26px;border-top:1px solid #e6e8ef;text-align:center;font:400 12px ${font};color:#6a7180;">
      ${brand} &middot; ${dateStr}<br/>You're receiving this because you subscribed.
    </td></tr>
  </table>
</td></tr>
</table>
</body></html>`;
}

/* ---------- 11. PLAIN-TEXT BUILDER ---------- */
function buildPlainText(nl) {
  const brand = els.nlName.value.trim() || "Your Newsletter";
  const dateStr = formatDateHuman(els.issueDate.value);
  const lines = [];
  lines.push(brand.toUpperCase());
  lines.push(dateStr);
  lines.push("");
  if (nl.subjectLine) lines.push(nl.subjectLine);
  if (nl.intro) { lines.push(""); lines.push(nl.intro); }
  lines.push("");
  lines.push("=".repeat(50));
  if (nl.leadStory) {
    lines.push((nl.leadStory.headline || "").toUpperCase());
    if (nl.leadStory.whyItMatters) lines.push("Why it matters: " + nl.leadStory.whyItMatters);
    lines.push("");
    lines.push(nl.leadStory.body || "");
    if (nl.leadStory.cta) lines.push("→ " + nl.leadStory.cta);
  }
  (nl.secondaryStories || []).forEach((s) => {
    lines.push("");
    lines.push("-".repeat(50));
    lines.push((s.headline || "").toUpperCase());
    lines.push(s.body || "");
    if (s.link) lines.push(s.link);
  });
  if ((nl.quickHits || []).length) {
    lines.push("");
    lines.push("QUICK HITS");
    nl.quickHits.forEach((q) => lines.push("• " + q));
  }
  if (nl.primaryCta && nl.primaryCta.label) {
    lines.push("");
    lines.push(nl.primaryCta.label + ": " + (nl.primaryCta.url || ""));
  }
  return lines.join("\n");
}

/* ---------- 12. EXPORTS ---------- */

// Lazy-load an external script once (used for html2pdf).
function loadScript(src) {
  return new Promise((resolve, reject) => {
    if (document.querySelector(`script[src="${src}"]`)) return resolve();
    const s = document.createElement("script");
    s.src = src;
    s.onload = resolve;
    s.onerror = () => reject(new Error("Failed to load " + src));
    document.head.appendChild(s);
  });
}

// PDF — render the on-screen preview element to A4 via html2pdf.
async function exportPDF() {
  if (!currentNewsletter) return;
  try {
    toast("Building PDF…");
    await loadScript(
      "https://cdnjs.cloudflare.com/ajax/libs/html2pdf.js/0.10.1/html2pdf.bundle.min.js"
    );
    const opt = {
      margin: 10,
      filename: "newsletter.pdf",
      image: { type: "jpeg", quality: 0.98 },
      html2canvas: { scale: 2, useCORS: true },
      jsPDF: { unit: "mm", format: "a4", orientation: "portrait" },
    };
    // eslint-disable-next-line no-undef
    await html2pdf().set(opt).from(els.preview).save();
    toast("PDF downloaded", "ok");
  } catch (e) {
    toast("PDF failed: " + e.message, "error");
  }
}

// Word — dependency-free .doc: wrap email HTML with a Word header.
function exportWord() {
  if (!currentNewsletter) return;
  const inner = buildEmailHtml(currentNewsletter.nl, currentNewsletter.heroSrc);
  // Word opens HTML with an Office XML namespace header happily.
  const header =
    `<html xmlns:o="urn:schemas-microsoft-com:office:office" ` +
    `xmlns:w="urn:schemas-microsoft-com:office:word" xmlns="http://www.w3.org/TR/REC-html40">` +
    `<head><meta charset="utf-8"><style>body{font-family:Arial,sans-serif;}</style></head><body>`;
  const fullHtml = header + inner + `</body></html>`;
  const blob = new Blob(["﻿", fullHtml], { type: "application/msword" });
  downloadBlob(blob, "newsletter.doc");
  toast("Word document downloaded", "ok");
}

// Copy as rich HTML — write both text/html and text/plain to clipboard.
async function copyRichHtml() {
  if (!currentNewsletter) return;
  const html = buildEmailHtml(currentNewsletter.nl, currentNewsletter.heroSrc);
  const plain = buildPlainText(currentNewsletter.nl);
  try {
    if (navigator.clipboard && window.ClipboardItem) {
      await navigator.clipboard.write([
        new ClipboardItem({
          "text/html": new Blob([html], { type: "text/html" }),
          "text/plain": new Blob([plain], { type: "text/plain" }),
        }),
      ]);
      toast("Rich HTML copied — paste into your email tool", "ok");
    } else {
      await navigator.clipboard.writeText(html);
      toast("HTML copied (as text)", "ok");
    }
  } catch (e) {
    // Last-ditch fallback.
    try {
      await navigator.clipboard.writeText(html);
      toast("HTML copied (as text)", "ok");
    } catch (_) {
      toast("Copy failed", "error");
    }
  }
}

// Copy plain text (and offer a .txt download via toast-free direct copy).
async function copyPlainText() {
  if (!currentNewsletter) return;
  const plain = buildPlainText(currentNewsletter.nl);
  try {
    await navigator.clipboard.writeText(plain);
    toast("Plain text copied", "ok");
  } catch (_) {
    // If clipboard is blocked, download a .txt instead.
    const blob = new Blob([plain], { type: "text/plain" });
    downloadBlob(blob, "newsletter.txt");
    toast("Downloaded newsletter.txt", "ok");
  }
}

// Helper: trigger a file download for a Blob.
function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/* ---------- 12b. OFFLINE LOCAL FORMATTER ----------
   Used automatically when no AI key is available (e.g. the page is
   opened as a local file, where the keyless Claude call can't work).
   It turns the raw notes into the same JSON shape the AI returns, using
   simple heuristics — no internet, no key, no cost. Writing won't be as
   polished as Claude's, but the app stays fully functional locally. */
function localFormat(rawNotes, niche, tone) {
  // Split notes into "blocks" separated by blank lines; fall back to lines.
  let blocks = rawNotes
    .split(/\n{2,}/)
    .map((b) => b.trim())
    .filter(Boolean);
  if (blocks.length < 2) {
    blocks = rawNotes.split(/\r?\n/).map((b) => b.replace(/^[-*•]\s*/, "").trim()).filter(Boolean);
  }

  // Turn the first sentence of a block into a short headline.
  const headlineFrom = (text) => {
    const firstSentence = text.split(/(?<=[.!?])\s/)[0] || text;
    const words = firstSentence.split(/\s+/).slice(0, 9).join(" ");
    return words.replace(/[.,;:]+$/, "");
  };

  const lead = blocks[0] || rawNotes;
  // Short one-liners become "quick hits"; longer blocks become stories.
  const rest = blocks.slice(1);
  const quickHits = rest.filter((b) => b.split(/\s+/).length <= 14).slice(0, 5);
  const secondaryBlocks = rest.filter((b) => b.split(/\s+/).length > 14).slice(0, 3);

  return {
    subjectLine: headlineFrom(lead).slice(0, 60),
    previewText: lead.slice(0, 90),
    intro: `Your ${niche} briefing, written in a ${tone.toLowerCase()} voice.`,
    leadStory: {
      headline: headlineFrom(lead),
      whyItMatters: "This is the most important update in your notes.",
      body: lead,
      cta: "Read more",
      imageKeyword: niche,
    },
    secondaryStories: secondaryBlocks.map((b) => ({
      headline: headlineFrom(b),
      body: b,
      link: "",
      imageKeyword: niche,
    })),
    quickHits,
    primaryCta: { label: "See the full issue", url: "#" },
  };
}

/* ---------- 13. MAIN ORCHESTRATION ---------- */
async function onFormat() {
  const raw = els.rawNotes.value.trim();
  if (!raw) {
    toast("Paste some notes first", "warn");
    els.rawNotes.focus();
    return;
  }

  const niche = getNiche();
  const tone = els.tone.value;
  setLoading(true);

  try {
    // 1) Try Claude first; fall back to the offline formatter if there's
    //    no API key (so the app works locally with zero setup).
    let nl;
    try {
      const prompt = buildPrompt(raw, niche, tone);
      const aiText = await callClaude(prompt);
      nl = parseNewsletterJson(aiText);
    } catch (aiErr) {
      if (aiErr.noKey) {
        // Expected when opened locally with no key — format offline.
        nl = localFormat(raw, niche, tone);
        setStatus("warn", "AI: offline (local)");
        toast("Formatted offline (no AI key). Add a key for sharper writing.", "warn");
      } else {
        // A real AI/parse error (bad key, network, malformed JSON).
        throw aiErr;
      }
    }

    // 3) Resolve the lead image (with fallback chain).
    const heroImg = await resolveImage(
      nl.leadStory && nl.leadStory.imageKeyword,
      nl.leadStory && nl.leadStory.headline
    );

    // For exports we need a concrete src that won't 404. If Picsum is
    // used we can't know in advance whether it loaded, so for the
    // email/Word/PDF-safe copies we prefer the SVG fallback when one
    // exists (guaranteed to render); otherwise use the resolved URL.
    const heroSrc = heroImg
      ? heroImg.fallbackSvg || heroImg.url
      : null;

    // 4) Render on-screen preview.
    renderPreview(nl, heroImg);

    // 5) Store state + enable exports.
    currentNewsletter = { nl, heroImg, heroSrc };
    setExportsEnabled(true);
    toast("Newsletter ready", "ok");
  } catch (e) {
    toast(e.message || "Something went wrong", "error");
  } finally {
    setLoading(false);
  }
}

/* ---------- BOOT ---------- */
document.addEventListener("DOMContentLoaded", init);
