/* =====================================================================
   app.js — Tasked  (vanilla JS, no framework, no build step)
   ---------------------------------------------------------------------
   TABLE OF CONTENTS
     1.  Small utilities (DOM, dates, ids, markdown, debounce)
     2.  Storage layer  (IndexedDB primary + localStorage for settings)
     3.  Global state + defaults + first-run seed
     4.  Natural-language quick-add parser (chrono-node + custom)
     5.  Recurrence helpers (rrule.js)
     6.  Task CRUD, completion, trash + undo, recurrence advance
     7.  Selectors (which tasks are visible for a view + filter + sort)
     8.  Rendering — shell, sidebar, toolbar, badges
     9.  Views — list / today / upcoming / board / calendar / matrix /
                 planner / habits / stats / archive / trash
     10. Drag & drop (SortableJS + native for calendar/planner)
     11. Task detail dialog / project dialog
     12. Command palette + global search
     13. Settings dialog + backup/restore (JSON / ICS / CSV)
     14. Pomodoro timer
     15. Gamification (points, levels, streaks)
     16. Reminders & notifications (in-app + catch-up + OS)
     17. Keyboard shortcuts
     18. Toasts, confetti, sound, haptics
     19. Boot + service-worker registration
   ===================================================================== */

'use strict';

/* ====================== 1. SMALL UTILITIES ====================== */
const $  = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const el = (tag, props = {}, ...kids) => {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'class') node.className = v;
    else if (k === 'html') node.innerHTML = v;
    else if (k === 'dataset') Object.assign(node.dataset, v);
    else if (k.startsWith('on') && typeof v === 'function') node.addEventListener(k.slice(2), v);
    else if (v === true) node.setAttribute(k, '');
    else if (v !== false && v != null) node.setAttribute(k, v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    node.append(kid.nodeType ? kid : document.createTextNode(kid));
  }
  return node;
};
const uid = () => 'id-' + Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);
const clamp = (n, lo, hi) => Math.max(lo, Math.min(hi, n));
const debounce = (fn, ms = 200) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
const escapeHtml = (s = '') => s.replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));

// ----- Dates (all local, no timezone surprises) -----
const pad = n => String(n).padStart(2, '0');
const dateKey = (d = new Date()) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const todayKey = () => dateKey(new Date());
const parseISO = s => (s ? new Date(s) : null);
const startOfDay = d => { const x = new Date(d); x.setHours(0,0,0,0); return x; };
const addDays = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
function fmtDate(iso, withTime) {
  if (!iso) return '';
  const d = new Date(iso);
  const today = startOfDay(new Date());
  const that = startOfDay(d);
  const diff = Math.round((that - today) / 86400000);
  let label;
  if (diff === 0) label = 'Today';
  else if (diff === 1) label = 'Tomorrow';
  else if (diff === -1) label = 'Yesterday';
  else if (diff > 1 && diff < 7) label = d.toLocaleDateString(undefined, { weekday: 'long' });
  else label = d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: that.getFullYear() !== today.getFullYear() ? 'numeric' : undefined });
  if (withTime && hasTime(iso)) label += ', ' + d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  return label;
}
// We mark "time present" by storing ISO with a time component; tasks created
// date-only get T00:00 — track separately via a flag on the task instead.
function hasTime(iso) { return /T(?!00:00:00)/.test(iso) || /T\d\d:\d\d/.test(iso) && !/T00:00/.test(iso); }
const isOverdue = t => t.due && new Date(t.due) < new Date() && (t.hasTime || startOfDay(new Date(t.due)) < startOfDay(new Date()));
const isDueToday = t => t.due && dateKey(new Date(t.due)) === todayKey();

// ----- Tiny Markdown renderer (safe: escapes first) -----
function mdToHtml(src = '') {
  let s = escapeHtml(src);
  s = s.replace(/```([\s\S]*?)```/g, (_, c) => `<pre><code>${c.trim()}</code></pre>`);
  s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/\*([^*]+)\*/g, '<em>$1</em>');
  s = s.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$1" target="_blank" rel="noopener">$1→</a>');
  s = s.replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" target="_blank" rel="noopener">$1</a>');
  // simple unordered lists & line breaks
  s = s.replace(/^\s*[-*] (.+)$/gm, '<li>$1</li>');
  s = s.replace(/(<li>[\s\S]*?<\/li>)/g, m => `<ul>${m}</ul>`).replace(/<\/ul>\s*<ul>/g, '');
  s = s.replace(/\n{2,}/g, '</p><p>').replace(/\n/g, '<br>');
  return `<p>${s}</p>`;
}

/* ====================== 2. STORAGE LAYER ====================== */
/* IndexedDB is the source of truth on disk. We load everything into memory
   on boot for synchronous, spinner-free reads, then write through to IDB on
   every mutation (fire-and-forget). localStorage holds only tiny UI settings
   so theme/last-view apply instantly before IDB opens. */
const DB_NAME = 'tasked-db';
const DB_VERSION = 1;
const STORES = ['tasks', 'projects', 'tags', 'habits', 'kv'];
let _db = null;

function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      for (const s of STORES) if (!db.objectStoreNames.contains(s)) db.createObjectStore(s, { keyPath: 'id' });
    };
    req.onsuccess = () => { _db = req.result; resolve(_db); };
    req.onerror = () => reject(req.error);
  });
}
function tx(store, mode = 'readonly') { return _db.transaction(store, mode).objectStore(store); }
function idbGetAll(store) {
  return new Promise((res, rej) => { const r = tx(store).getAll(); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
}
function idbPut(store, val) {
  try { tx(store, 'readwrite').put(val); } catch (e) { console.warn('idbPut failed', store, e); }
}
function idbDel(store, id) { try { tx(store, 'readwrite').delete(id); } catch (e) { console.warn(e); } }
function idbClear(store) { try { tx(store, 'readwrite').clear(); } catch (e) { console.warn(e); } }

// kv store holds singletons: settings, gamify, pomodoro, savedSearches, templates
function kvPut(key, value) { idbPut('kv', { id: key, value }); }

// localStorage mirror for instant-apply UI prefs
const LS = {
  get(k, fallback) { try { const v = localStorage.getItem('tasked.' + k); return v == null ? fallback : JSON.parse(v); } catch { return fallback; } },
  set(k, v) { try { localStorage.setItem('tasked.' + k, JSON.stringify(v)); } catch {} }
};

/* ====================== 3. GLOBAL STATE ====================== */
const DEFAULT_SETTINGS = {
  theme: 'system',          // system | light | dark | warm
  density: 'comfortable',
  sound: false,
  haptics: false,
  confetti: true,
  notifications: false,     // becomes true only after permission granted
  backupReminderDays: 7,
  focusN: 5,
  startView: 'today'
};

const state = {
  tasks: [],
  projects: [],
  tags: [],
  habits: [],
  savedSearches: [],
  templates: [],
  settings: { ...DEFAULT_SETTINGS },
  gamify: { points: 0, level: 1, streak: 0, lastCompleteDate: null, vacation: false, milestonesShown: [] },
  pomodoro: { running: false, phase: 'focus', startedAt: null, remaining: 25 * 60, completedToday: 0, totalFocusMin: 0, focusLen: 25, breakLen: 5, lastDay: todayKey() },
  meta: { lastBackup: null, lastOpened: null },
  ui: {
    view: 'today', layout: 'list', projectId: null, sectionFilter: null,
    filters: { tags: [], priority: null, search: '' },
    sort: 'manual', focusMode: false,
    calCursor: dateKey(), savedSearchId: null,
    selectedTaskId: null
  }
};

// Lookups
const taskById = id => state.tasks.find(t => t.id === id);
const projectById = id => state.projects.find(p => p.id === id);
const tagById = id => state.tags.find(t => t.id === id);

/* ----- First-run seed: never show a blank screen ----- */
function seedFirstRun() {
  const area = { id: uid(), name: 'Personal', type: 'area', parentId: null, color: '#6366f1', sections: [], archived: false, position: 0 };
  const work = { id: uid(), name: 'Getting Started', type: 'project', parentId: area.id, color: '#10b981',
    sections: [{ id: uid(), name: 'Learn the basics' }], archived: false, position: 1 };
  state.projects.push(area, work);

  const tagWork = { id: uid(), name: 'work', color: '#3b82f6' };
  const tagHome = { id: uid(), name: 'home', color: '#f59e0b' };
  state.tags.push(tagWork, tagHome);

  const now = Date.now();
  const seed = (over) => ({
    id: uid(), title: '', notes: '', priority: 4, due: null, hasTime: false, start: null,
    duration: null, energy: null, tags: [], favorite: false, flagged: false, pinned: false,
    projectId: work.id, sectionId: null, parentId: null, checklist: [], recurrence: null,
    status: 'active', completedAt: null, createdAt: now, updatedAt: now, position: now,
    actualTime: 0, plannerTime: null, ...over
  });
  state.tasks.push(
    seed({ title: 'Try the quick-add: type a sentence with a date, #tag and !p1', priority: 1, due: new Date().toISOString(), hasTime: false, tags: [tagWork.id], pinned: true, position: 1 }),
    seed({ title: 'Press **N** to add, **/** to search, **Ctrl/⌘K** for the command palette', priority: 2, position: 2 }),
    seed({ title: 'Complete me to earn points 🎉 (click the circle)', priority: 3, position: 3, tags: [tagHome.id] }),
    seed({ title: 'Open Settings → back up your data to a JSON file', priority: 4, position: 4, due: addDays(new Date(), 2).toISOString() })
  );

  state.templates = [
    { id: uid(), name: 'Daily Planning Ritual', tasks: ['Review today\'s priorities', 'Pick 3 most important tasks', 'Time-block the morning', 'Quick inbox triage'] },
    { id: uid(), name: 'Weekly Review', tasks: ['Clear the inbox', 'Review each project', 'Plan next week', 'Celebrate wins'] },
    { id: uid(), name: 'Trip Packing', tasks: ['Passport / ID', 'Chargers', 'Toiletries', 'Clothes', 'Tickets & bookings'] }
  ];
  persistAll();
}

function persistAll() {
  state.tasks.forEach(t => idbPut('tasks', t));
  state.projects.forEach(p => idbPut('projects', p));
  state.tags.forEach(t => idbPut('tags', t));
  state.habits.forEach(h => idbPut('habits', h));
  kvPut('settings', state.settings);
  kvPut('gamify', state.gamify);
  kvPut('pomodoro', state.pomodoro);
  kvPut('savedSearches', state.savedSearches);
  kvPut('templates', state.templates);
  kvPut('meta', state.meta);
}

async function loadAll() {
  const [tasks, projects, tags, habits, kv] = await Promise.all(
    ['tasks', 'projects', 'tags', 'habits', 'kv'].map(idbGetAll)
  );
  state.tasks = tasks || [];
  state.projects = projects || [];
  state.tags = tags || [];
  state.habits = habits || [];
  const kvMap = Object.fromEntries((kv || []).map(r => [r.id, r.value]));
  if (kvMap.settings) state.settings = { ...DEFAULT_SETTINGS, ...kvMap.settings };
  if (kvMap.gamify) state.gamify = { ...state.gamify, ...kvMap.gamify };
  if (kvMap.pomodoro) state.pomodoro = { ...state.pomodoro, ...kvMap.pomodoro };
  if (kvMap.savedSearches) state.savedSearches = kvMap.savedSearches;
  if (kvMap.templates) state.templates = kvMap.templates;
  if (kvMap.meta) state.meta = { ...state.meta, ...kvMap.meta };

  if (state.tasks.length === 0 && state.projects.length === 0) seedFirstRun();
}

/* ====================== 4. NATURAL-LANGUAGE QUICK-ADD PARSER ====================== */
/* Parses one string into a task. Order: priority/tags/recurrence are stripped
   with regex, then chrono-node parses dates from what remains.
   Examples it understands:
     "Submit report next Friday at 3pm every 2 weeks #work !p1"
     "Pay rent on the 1st monthly #home"
*/
function parseQuickAdd(input) {
  let text = input.trim();
  const result = { title: text, priority: 4, tags: [], due: null, hasTime: false, recurrence: null, start: null };
  if (!text) return result;

  // --- priority  !p1..!p4  (or  !1 / !!! shorthand) ---
  const pm = text.match(/(?:^|\s)!(?:p?([1-4])|(!{1,3}))(?=\s|$)/i);
  if (pm) {
    result.priority = pm[1] ? Number(pm[1]) : (4 - pm[2].length); // !!! => p1
    text = text.replace(pm[0], ' ');
  }

  // --- tags  #tag ---
  const tagNames = [];
  text = text.replace(/(?:^|\s)#([\w-]+)/g, (_, name) => { tagNames.push(name.toLowerCase()); return ' '; });
  result.tags = tagNames.map(ensureTag);

  // --- recurrence keywords -> RRULE ---
  const rec = extractRecurrence(text);
  if (rec) { result.recurrence = rec.rrule; text = text.replace(rec.matched, ' '); }

  // --- dates/times via chrono-node ---
  if (window.chrono) {
    try {
      const found = window.chrono.parse(text, new Date(), { forwardDate: true });
      if (found.length) {
        const r = found[0];
        const d = r.start.date();
        result.due = d.toISOString();
        result.hasTime = r.start.isCertain('hour');
        if (!result.hasTime) { d.setHours(0,0,0,0); result.due = d.toISOString(); }
        // a second date is treated as the "start/do" date if it's earlier
        if (found[1]) result.start = found[1].start.date().toISOString();
        text = (text.slice(0, r.index) + ' ' + text.slice(r.index + r.text.length));
      }
    } catch (e) { /* chrono blocked / offline: keep title as-is */ }
  }

  result.title = text.replace(/\s{2,}/g, ' ').trim() || input.trim();
  return result;
}

// Build a live preview of what quick-add will create.
function quickAddPreview(input) {
  const r = parseQuickAdd(input);
  const tokens = [];
  if (r.priority < 4) tokens.push(`Priority P${r.priority}`);
  if (r.due) tokens.push(fmtDate(r.due, r.hasTime));
  if (r.recurrence) tokens.push('↻ ' + recurrenceText(r.recurrence));
  r.tags.forEach(id => { const t = tagById(id); if (t) tokens.push('#' + t.name); });
  return tokens;
}

function ensureTag(name) {
  let t = state.tags.find(x => x.name.toLowerCase() === name.toLowerCase());
  if (!t) {
    const palette = ['#3b82f6','#f59e0b','#10b981','#ef4444','#8b5cf6','#ec4899','#06b6d4'];
    t = { id: uid(), name, color: palette[state.tags.length % palette.length] };
    state.tags.push(t); idbPut('tags', t);
  }
  return t.id;
}

/* ====================== 5. RECURRENCE (rrule.js) ====================== */
// Map common English phrases to an iCalendar RRULE string.
function extractRecurrence(text) {
  const lower = text.toLowerCase();
  const days = { sunday:'SU', monday:'MO', tuesday:'TU', wednesday:'WE', thursday:'TH', friday:'FR', saturday:'SA' };
  const tests = [
    [/every\s+weekday|each\s+weekday/, 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR'],
    [/every\s+day|daily/, 'FREQ=DAILY'],
    [/every\s+(\d+)\s+weeks?/, m => `FREQ=WEEKLY;INTERVAL=${m[1]}`],
    [/every\s+(\d+)\s+days?/, m => `FREQ=DAILY;INTERVAL=${m[1]}`],
    [/every\s+(\d+)\s+months?/, m => `FREQ=MONTHLY;INTERVAL=${m[1]}`],
    [/every\s+other\s+week|biweekly/, 'FREQ=WEEKLY;INTERVAL=2'],
    [/weekly|every\s+week/, 'FREQ=WEEKLY'],
    [/monthly|every\s+month/, 'FREQ=MONTHLY'],
    [/yearly|annually|every\s+year/, 'FREQ=YEARLY'],
    // "every 3rd tuesday"
    [/every\s+(\d)(?:st|nd|rd|th)\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)/,
      m => `FREQ=MONTHLY;BYDAY=${m[1]}${days[m[2]]}`],
    // "every monday", "every monday and thursday"
    [/every\s+((?:sunday|monday|tuesday|wednesday|thursday|friday|saturday)(?:\s*(?:,|and)\s*(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday))*)/,
      m => `FREQ=WEEKLY;BYDAY=${m[1].split(/\s*(?:,|and)\s*/).map(d => days[d.trim()]).join(',')}`]
  ];
  for (const [re, build] of tests) {
    const m = lower.match(re);
    if (m) {
      const rrule = typeof build === 'function' ? build(m) : build;
      // find the matched text in original casing for stripping
      const matched = text.substr(m.index, m[0].length);
      return { rrule, matched };
    }
  }
  return null;
}

function recurrenceText(rrule) {
  if (!rrule) return '';
  if (window.rrule && window.rrule.RRule) {
    try { return window.rrule.RRule.fromString('RRULE:' + rrule.replace(/^RRULE:/, '')).toText(); }
    catch { /* fall through */ }
  }
  return rrule.toLowerCase().replace('freq=', 'every ').replace(/;/g, ' ');
}

// Given a task with a recurrence, return the next occurrence date AFTER `from`.
function nextOccurrence(rrule, from) {
  const base = from ? new Date(from) : new Date();
  if (window.rrule && window.rrule.RRule) {
    try {
      const rule = window.rrule.RRule.fromString(`DTSTART:${toICSDate(base)}\nRRULE:${rrule}`);
      const next = rule.after(base, false);
      if (next) return next;
    } catch (e) { /* fall back below */ }
  }
  // Fallback: simple interval bump
  const m = /INTERVAL=(\d+)/.exec(rrule); const n = m ? Number(m[1]) : 1;
  if (/DAILY/.test(rrule)) return addDays(base, n);
  if (/WEEKLY/.test(rrule)) return addDays(base, 7 * n);
  if (/MONTHLY/.test(rrule)) { const d = new Date(base); d.setMonth(d.getMonth() + n); return d; }
  if (/YEARLY/.test(rrule)) { const d = new Date(base); d.setFullYear(d.getFullYear() + n); return d; }
  return addDays(base, 1);
}

/* ====================== 6. TASK CRUD / COMPLETE / TRASH+UNDO ====================== */
let undoStack = [];

function newTaskFrom(parsed, extra = {}) {
  const now = Date.now();
  const t = {
    id: uid(), title: parsed.title || 'Untitled', notes: '', priority: parsed.priority ?? 4,
    due: parsed.due || null, hasTime: !!parsed.hasTime, start: parsed.start || null,
    duration: null, energy: null, tags: parsed.tags || [], favorite: false, flagged: false, pinned: false,
    projectId: currentProjectId(), sectionId: state.ui.sectionFilter || null, parentId: null,
    checklist: [], recurrence: parsed.recurrence || null,
    status: 'active', completedAt: null, createdAt: now, updatedAt: now, position: now,
    actualTime: 0, plannerTime: null, ...extra
  };
  state.tasks.push(t); idbPut('tasks', t);
  scheduleReminderFor(t);
  return t;
}
function currentProjectId() {
  if (state.ui.view === 'project') return state.ui.projectId;
  return null; // inbox
}
function saveTask(t) { t.updatedAt = Date.now(); idbPut('tasks', t); scheduleReminderFor(t); }

function toggleComplete(id, checkboxEl) {
  const t = taskById(id);
  if (!t) return;
  if (t.status === 'done') { // un-complete
    t.status = 'active'; t.completedAt = null; saveTask(t); render(); return;
  }
  // Recurring? advance instead of finishing.
  if (t.recurrence) {
    const next = nextOccurrence(t.recurrence, t.due || new Date());
    logCompletion(t);
    t.due = next.toISOString();
    t.completedAt = null;
    saveTask(t);
    announce(`Completed — next on ${fmtDate(t.due, t.hasTime)}`);
    awardPoints(t); celebrate(checkboxEl);
    render();
    return;
  }
  // normal completion (optimistic + animation)
  t.status = 'done'; t.completedAt = Date.now(); saveTask(t);
  if (checkboxEl && !reducedMotion()) { checkboxEl.classList.add('completing'); setTimeout(() => render(), 260); }
  else render();
  logCompletion(t);
  awardPoints(t); celebrate(checkboxEl);
  announce('Task completed: ' + stripMd(t.title));
}

// completion log for stats (kept in kv via meta isn't ideal; store on task)
function logCompletion() { /* completions derived from tasks' completedAt; no-op kept for clarity */ }

function trashTask(id, { silent } = {}) {
  const t = taskById(id); if (!t) return;
  const prev = t.status;
  t.status = 'trashed'; t._prevStatus = prev; t.trashedAt = Date.now(); saveTask(t);
  // also trash descendants
  descendants(id).forEach(c => { c._prevStatus = c.status; c.status = 'trashed'; c.trashedAt = Date.now(); saveTask(c); });
  render();
  if (!silent) {
    pushUndo(() => { restoreFromTrash(id); });
    toast(`Deleted “${stripMd(t.title).slice(0, 40)}”`, 'Undo', () => { restoreFromTrash(id); render(); });
  }
}
function restoreFromTrash(id) {
  const t = taskById(id); if (!t) return;
  t.status = t._prevStatus || 'active'; delete t._prevStatus; delete t.trashedAt; saveTask(t);
  descendants(id).forEach(c => { c.status = c._prevStatus || 'active'; delete c._prevStatus; saveTask(c); });
}
function deleteForever(id) {
  descendants(id).forEach(c => { state.tasks = state.tasks.filter(x => x.id !== c.id); idbDel('tasks', c.id); });
  state.tasks = state.tasks.filter(t => t.id !== id); idbDel('tasks', id); render();
}
function emptyTrash() {
  state.tasks.filter(t => t.status === 'trashed').forEach(t => idbDel('tasks', t.id));
  state.tasks = state.tasks.filter(t => t.status !== 'trashed'); render();
}
function descendants(id) {
  const out = [];
  const walk = pid => state.tasks.filter(t => t.parentId === pid).forEach(c => { out.push(c); walk(c.id); });
  walk(id); return out;
}
function pushUndo(fn) { undoStack.push(fn); if (undoStack.length > 20) undoStack.shift(); }
function undoLast() { const fn = undoStack.pop(); if (fn) { fn(); render(); announce('Undone'); } else toast('Nothing to undo'); }

const stripMd = s => (s || '').replace(/[*`_#>]/g, '');

/* ====================== 7. SELECTORS (visible tasks) ====================== */
function baseTasks() { return state.tasks.filter(t => t.status !== 'trashed' && t.status !== 'archived'); }

function tasksForView() {
  const v = state.ui.view;
  let list;
  switch (v) {
    case 'today':    list = baseTasks().filter(t => t.status==='active' && t.due && startOfDay(new Date(t.due)) <= startOfDay(new Date())); break;
    case 'upcoming': list = baseTasks().filter(t => t.status==='active' && t.due && startOfDay(new Date(t.due)) > startOfDay(new Date())); break;
    case 'inbox':    list = baseTasks().filter(t => t.status!=='someday' && !t.projectId && !t.parentId); break;
    case 'all':      list = baseTasks().filter(t => t.status!=='someday'); break;
    case 'flagged':  list = baseTasks().filter(t => t.flagged && t.status!=='someday'); break;
    case 'someday':  list = state.tasks.filter(t => t.status==='someday'); break;
    case 'project':  list = baseTasks().filter(t => t.projectId === state.ui.projectId && t.status!=='someday'); break;
    case 'archive':  list = state.tasks.filter(t => t.status==='archived'); break;
    case 'trash':    list = state.tasks.filter(t => t.status==='trashed'); break;
    case 'search':   list = applySavedSearch(); break;
    default:         list = baseTasks();
  }
  return applyFiltersAndSort(list);
}

function applySavedSearch() {
  const s = state.savedSearches.find(x => x.id === state.ui.savedSearchId);
  if (!s) return [];
  let list = baseTasks().filter(t => t.status !== 'someday');
  if (s.tags?.length) list = list.filter(t => s.tags.every(tag => t.tags.includes(tag)));
  if (s.priority) list = list.filter(t => t.priority === s.priority);
  if (s.due === 'overdue') list = list.filter(isOverdue);
  if (s.text) list = list.filter(t => t.title.toLowerCase().includes(s.text.toLowerCase()));
  return list;
}

function applyFiltersAndSort(list) {
  const f = state.ui.filters;
  if (f.tags.length) list = list.filter(t => f.tags.every(tag => t.tags.includes(tag)));
  if (f.priority) list = list.filter(t => t.priority === f.priority);
  if (f.search) { const q = f.search.toLowerCase(); list = list.filter(t => t.title.toLowerCase().includes(q) || (t.notes||'').toLowerCase().includes(q)); }

  const sorters = {
    manual:   (a,b) => (a.position||0) - (b.position||0),
    due:      (a,b) => (a.due?Date.parse(a.due):Infinity) - (b.due?Date.parse(b.due):Infinity),
    priority: (a,b) => a.priority - b.priority,
    created:  (a,b) => b.createdAt - a.createdAt,
    alpha:    (a,b) => a.title.localeCompare(b.title)
  };
  list = [...list].sort((a,b) => {
    // pinned first always, completed last
    if (!!b.pinned !== !!a.pinned) return b.pinned ? 1 : -1;
    if ((a.status==='done') !== (b.status==='done')) return a.status==='done' ? 1 : -1;
    return (sorters[state.ui.sort] || sorters.manual)(a,b);
  });
  return list;
}

function countFor(key) {
  switch (key) {
    case 'today': return baseTasks().filter(t => t.status==='active' && t.due && startOfDay(new Date(t.due)) <= startOfDay(new Date())).length;
    case 'upcoming': return baseTasks().filter(t => t.status==='active' && t.due && startOfDay(new Date(t.due)) > startOfDay(new Date())).length;
    case 'inbox': return baseTasks().filter(t => t.status==='active' && !t.projectId && !t.parentId).length;
    case 'all': return baseTasks().filter(t => t.status==='active').length;
    case 'flagged': return baseTasks().filter(t => t.flagged && t.status==='active').length;
    case 'trash': return state.tasks.filter(t => t.status==='trashed').length;
    default: return 0;
  }
}

/* ====================== 8. RENDERING — SHELL ====================== */
const VIEW_TITLES = { today:'Today', upcoming:'Upcoming', inbox:'Inbox', all:'All Tasks', flagged:'Flagged',
  someday:'Someday', archive:'Archive', trash:'Trash', habits:'Habits', stats:'Statistics' };
const LAYOUT_VIEWS = ['today','upcoming','inbox','all','flagged','project','search'];

function render() {
  renderSidebar();
  renderTopbar();
  renderToolbar();
  renderView();
  renderGamifyMini();
}

function renderTopbar() {
  let title = VIEW_TITLES[state.ui.view] || 'Tasks';
  let sub = '';
  if (state.ui.view === 'project') { const p = projectById(state.ui.projectId); title = p ? p.name : 'Project'; }
  if (state.ui.view === 'search') { const s = state.savedSearches.find(x=>x.id===state.ui.savedSearchId); title = s ? '🔎 ' + s.name : 'Search'; }
  if (state.ui.view === 'today') sub = new Date().toLocaleDateString(undefined, { weekday:'long', month:'long', day:'numeric' });
  $('#view-title').textContent = title;
  $('#view-subtitle').textContent = sub;

  // layout switch visibility
  const showLayouts = LAYOUT_VIEWS.includes(state.ui.view);
  $('#view-switch').style.display = showLayouts ? '' : 'none';
  $$('#view-switch .vs-btn').forEach(b => b.classList.toggle('active', b.dataset.layout === state.ui.layout));
}

function renderSidebar() {
  $$('.nav-item[data-view]').forEach(b =>
    b.classList.toggle('active', b.dataset.view === state.ui.view && state.ui.view !== 'project'));
  // counts
  $$('.badge[data-count]').forEach(b => { const c = countFor(b.dataset.count); b.textContent = c || ''; b.classList.toggle('warn', b.dataset.count==='today' && c>0 && baseTasks().some(isOverdue)); });

  // projects/areas tree
  const root = $('#projects-list'); root.innerHTML = '';
  const areas = state.projects.filter(p => p.type === 'area' && !p.archived).sort((a,b)=>(a.position||0)-(b.position||0));
  const looseProjects = state.projects.filter(p => p.type !== 'area' && !p.parentId && !p.archived);
  const renderProject = (p) => {
    const open = baseTasks().filter(t => t.projectId === p.id && t.status === 'active').length;
    const total = baseTasks().filter(t => t.projectId === p.id).length;
    const done = total - open;
    const li = el('li', {},
      el('button', { class: 'nav-item' + (state.ui.view==='project'&&state.ui.projectId===p.id?' active':''),
        onclick: () => navProject(p.id), oncontextmenu: (e)=>{ e.preventDefault(); editProject(p.id); } },
        el('span', { class: 'project-dot', style: `background:${p.color||'var(--accent)'}` }),
        p.name,
        el('span', { class: 'badge' }, open ? String(open) : '')),
      total ? el('div', { class:'proj-progress' }, el('i', { style:`width:${total?Math.round(done/total*100):0}%` })) : null
    );
    return li;
  };
  areas.forEach(area => {
    root.append(el('li', {},
      el('div', { class:'nav-section-head', style:'padding-left:10px' },
        el('span', {}, area.name),
        el('button', { class:'icon-btn', title:'Add project here', onclick:()=>addProject(area.id) }, '＋'))));
    const ul = el('ul', { class:'nav-list nav-sub' });
    state.projects.filter(p => p.parentId === area.id && p.type==='project' && !p.archived)
      .sort((a,b)=>(a.position||0)-(b.position||0)).forEach(p => ul.append(renderProject(p)));
    root.append(ul);
  });
  looseProjects.forEach(p => root.append(renderProject(p)));

  // saved searches
  const ss = $('#saved-searches'); ss.innerHTML = '';
  state.savedSearches.forEach(s => ss.append(el('li', {},
    el('button', { class:'nav-item'+(state.ui.view==='search'&&state.ui.savedSearchId===s.id?' active':''),
      onclick:()=>{ state.ui.view='search'; state.ui.savedSearchId=s.id; render(); } },
      el('span',{class:'ico'},'🔎'), s.name,
      el('button',{class:'icon-btn',title:'Delete search',onclick:(e)=>{e.stopPropagation();state.savedSearches=state.savedSearches.filter(x=>x.id!==s.id);kvPut('savedSearches',state.savedSearches);render();}},'✕')))));
}

function renderToolbar() {
  const showToolbar = LAYOUT_VIEWS.includes(state.ui.view) || state.ui.view==='someday';
  $('#toolbar').style.display = showToolbar ? '' : 'none';
  $('#quick-add-form').style.display = ['stats','habits','trash','archive'].includes(state.ui.view) ? 'none' : '';
  if (!showToolbar) return;

  const wrap = $('#filter-chips'); wrap.innerHTML = '';
  // priority filter chips
  [1,2,3,4].forEach(p => {
    wrap.append(el('button', { class:'chip'+(state.ui.filters.priority===p?' active':''),
      onclick:()=>{ state.ui.filters.priority = state.ui.filters.priority===p?null:p; renderView(); renderToolbar(); } }, 'P'+p));
  });
  // tag filter chips
  state.tags.slice(0, 12).forEach(t => {
    const active = state.ui.filters.tags.includes(t.id);
    wrap.append(el('button', { class:'chip'+(active?' active':''),
      onclick:()=>{ const arr=state.ui.filters.tags; const i=arr.indexOf(t.id); i>=0?arr.splice(i,1):arr.push(t.id); renderView(); renderToolbar(); } },
      el('span',{class:'project-dot',style:`background:${t.color}`}), '#'+t.name));
  });
  $('#sort-select').value = state.ui.sort;
  $('#focus-mode-btn').classList.toggle('active', state.ui.focusMode);
}

function renderGamifyMini() {
  const g = state.gamify;
  $('#level-badge').textContent = 'Lv ' + g.level;
  $('#xp-fill').style.width = (g.points % 100) + '%';
  $('#streak-badge').textContent = (g.vacation ? '⏸ ' : '🔥 ') + g.streak;
}

/* ====================== 9. VIEWS ====================== */
function renderView() {
  const root = $('#view-root'); root.innerHTML = '';
  const v = state.ui.view;
  if (v === 'habits') return renderHabits(root);
  if (v === 'stats')  return renderStats(root);
  if (v === 'trash')  return renderTrash(root);
  if (v === 'archive')return renderArchive(root);

  const tasks = tasksForView();
  if (!tasks.length && !['today'].includes(v)) { root.append(emptyState()); return; }

  // layout dispatch for task views
  if (LAYOUT_VIEWS.includes(v)) {
    switch (state.ui.layout) {
      case 'board':    return renderBoard(root, tasks);
      case 'calendar': return renderCalendar(root);
      case 'matrix':   return renderMatrix(root, tasks);
      case 'planner':  return renderPlanner(root, tasks);
      default:         return renderList(root, tasks);
    }
  }
  renderList(root, tasks);
}

// ---- Empty / onboarding states ----
function emptyState() {
  const v = state.ui.view;
  const map = {
    today: { big:'🎉', h:'All caught up!', p:'Nothing due today. Enjoy the calm — or pull something forward from Upcoming.' },
    upcoming: { big:'🗓', h:'Nothing on the horizon', p:'Add a task with a future date to see it here.' },
    inbox: { big:'📥', h:'Inbox zero', p:'Quick-add a task above. Unfiled tasks land here.' },
    flagged: { big:'⚑', h:'No flags', p:'Flag important tasks to find them fast.' },
    someday: { big:'☾', h:'Someday / maybe', p:'Park ideas here without a deadline.' },
    project: { big:'📂', h:'Empty project', p:'Add the first task above.' },
    search: { big:'🔎', h:'No matches', p:'Try a different saved search.' }
  };
  const m = map[v] || { big:'✓', h:'Nothing here yet', p:'Add a task above to get started.' };
  return el('div', { class:'empty-state' },
    el('div',{class:'big'}, m.big), el('h2',{}, m.h), el('p',{}, m.p),
    el('button', { class:'btn primary cta', onclick:()=>$('#quick-add').focus() }, '＋ Add a task'));
}

// ---- LIST VIEW (with sections, subtasks, focus mode) ----
function renderList(root, tasks) {
  let visible = tasks;
  if (state.ui.focusMode) visible = visible.filter(t => t.status==='active').slice(0, state.settings.focusN);

  // group by project section when viewing a project, else flat
  const container = el('div', { class:'task-list' });
  const topLevel = visible.filter(t => !t.parentId || !visible.includes(taskById(t.parentId)));

  if (state.ui.view === 'project' && state.ui.projectId) {
    const p = projectById(state.ui.projectId);
    const sections = [{ id:null, name:'(No section)' }, ...(p?.sections||[])];
    sections.forEach(sec => {
      const inSec = topLevel.filter(t => (t.sectionId||null) === (sec.id||null));
      if (!inSec.length && sec.id===null) return;
      const group = el('div', { class:'section-group' });
      if (sec.id || sections.length>1) group.append(el('div',{class:'section-head'}, sec.name, el('span',{class:'count'},`${inSec.length}`)));
      const ul = el('div', { class:'task-list', dataset:{ section: sec.id||'none' } });
      inSec.forEach(t => appendTaskRow(ul, t, visible));
      group.append(ul); container.append(group);
      makeSortable(ul);
    });
  } else {
    topLevel.forEach(t => appendTaskRow(container, t, visible));
    makeSortable(container);
  }

  root.append(container);
  if (!visible.length) root.append(emptyState());
}

function appendTaskRow(parent, t, pool) {
  parent.append(taskRow(t));
  // nested subtasks
  state.tasks.filter(c => c.parentId === t.id && c.status !== 'trashed' && c.status !== 'archived')
    .sort((a,b)=>(a.position||0)-(b.position||0))
    .forEach(c => { const row = taskRow(c); row.classList.add('subtask'); parent.append(row); });
}

function taskRow(t) {
  const done = t.status === 'done';
  const subs = state.tasks.filter(c => c.parentId === t.id && c.status!=='trashed');
  const subsDone = subs.filter(c => c.status==='done').length;
  const checklistDone = t.checklist.filter(c => c.done).length;

  const cb = el('input', { type:'checkbox', class:'checkbox p'+t.priority, 'aria-label':'Complete task' });
  cb.checked = done;
  cb.addEventListener('change', () => toggleComplete(t.id, cb));

  const meta = el('div', { class:'task-meta' });
  if (t.due) {
    const cls = isOverdue(t) ? 'due overdue' : (isDueToday(t) ? 'due today' : 'due');
    meta.append(el('span', { class:cls }, '📅 ' + fmtDate(t.due, t.hasTime)));
  }
  if (t.start) meta.append(el('span', {}, '▶ ' + fmtDate(t.start)));
  if (t.recurrence) meta.append(el('span', { title:recurrenceText(t.recurrence) }, '↻'));
  if (t.duration) meta.append(el('span', {}, '⏲ ' + t.duration + 'm'));
  if (t.energy) meta.append(el('span', {}, ({high:'⚡high',low:'🌙low',physical:'💪physical'})[t.energy]));
  if (subs.length) meta.append(el('span', { class:'subtask-progress' }, `☑ ${subsDone}/${subs.length}`));
  if (t.checklist.length) meta.append(el('span', { class:'subtask-progress' }, `▣ ${checklistDone}/${t.checklist.length}`));
  t.tags.forEach(id => { const tag = tagById(id); if (tag) meta.append(el('span', { class:'tag-pill', style:`background:${tag.color}` }, '#'+tag.name)); });
  const proj = t.projectId && state.ui.view!=='project' ? projectById(t.projectId) : null;
  if (proj) meta.append(el('span', {}, el('span',{class:'project-dot',style:`background:${proj.color}`}), ' '+proj.name));

  const titleRow = el('div', { class:'task-title-row' });
  if (t.pinned) titleRow.append(el('span',{class:'pin',title:'Pinned'},'📌'));
  if (t.flagged) titleRow.append(el('span',{class:'flag',title:'Flagged'},'⚑'));
  titleRow.append(el('span', { class:'task-title', html: mdInline(t.title) }));

  const main = el('div', { class:'task-main', onclick:()=>openTask(t.id) }, titleRow);
  if (meta.childElementCount) main.append(meta);

  const actions = el('div', { class:'task-actions' },
    el('button', { class:'icon-btn', title:'Flag', onclick:(e)=>{e.stopPropagation();t.flagged=!t.flagged;saveTask(t);render();} }, '⚑'),
    el('button', { class:'icon-btn', title:'Pin', onclick:(e)=>{e.stopPropagation();t.pinned=!t.pinned;saveTask(t);render();} }, '📌'),
    el('button', { class:'icon-btn', title:'Edit', onclick:(e)=>{e.stopPropagation();openTask(t.id);} }, '✎'),
    el('button', { class:'icon-btn', title:'Delete', onclick:(e)=>{e.stopPropagation();trashTask(t.id);} }, '🗑'));

  const row = el('div', {
    class:'task-row'+(done?' done':'')+(state.ui.selectedTaskId===t.id?' selected':''),
    dataset:{ id:t.id }, tabindex:'0', role:'listitem',
    onkeydown:(e)=>taskRowKeys(e, t)
  },
    el('span', { class:'drag-handle', title:'Drag to reorder', 'aria-hidden':'true' }, '⠿'),
    cb, main, actions);
  return row;
}
// inline markdown for titles (bold/italic/code only)
function mdInline(s='') { let x = escapeHtml(s); x = x.replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>').replace(/\*([^*]+)\*/g,'<em>$1</em>').replace(/`([^`]+)`/g,'<code>$1</code>'); return x; }

function taskRowKeys(e, t) {
  if (e.key === 'Enter') { e.preventDefault(); openTask(t.id); }
  else if (e.key === ' ') { e.preventDefault(); toggleComplete(t.id, e.currentTarget.querySelector('.checkbox')); }
  else if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); trashTask(t.id); }
  else if (e.key === 'ArrowDown') { e.preventDefault(); e.currentTarget.nextElementSibling?.focus?.(); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); e.currentTarget.previousElementSibling?.focus?.(); }
  else if (e.key.toLowerCase() === 'f') { t.flagged=!t.flagged; saveTask(t); render(); }
  else if (e.key.toLowerCase() === 'p') { t.pinned=!t.pinned; saveTask(t); render(); }
}

// ---- KANBAN BOARD (columns by status/priority) ----
function renderBoard(root, tasks) {
  const cols = [
    { key:'p1', label:'🔴 Urgent (P1)', test:t=>t.priority===1 && t.status==='active', set:t=>t.priority=1 },
    { key:'p2', label:'🟠 High (P2)', test:t=>t.priority===2 && t.status==='active', set:t=>t.priority=2 },
    { key:'p3', label:'🔵 Medium (P3)', test:t=>t.priority===3 && t.status==='active', set:t=>t.priority=3 },
    { key:'p4', label:'⚪ Low (P4)', test:t=>t.priority===4 && t.status==='active', set:t=>t.priority=4 },
    { key:'done', label:'✓ Done', test:t=>t.status==='done', set:t=>{ t.status='done'; t.completedAt=Date.now(); } }
  ];
  const board = el('div', { class:'board' });
  cols.forEach(col => {
    const body = el('div', { class:'board-col-body', dataset:{ col:col.key } });
    tasks.filter(col.test).forEach(t => body.append(boardCard(t)));
    board.append(el('div', { class:'board-col' },
      el('div', { class:'board-col-head' }, col.label, el('span',{class:'badge'}, String(tasks.filter(col.test).length))),
      body));
    if (window.Sortable) new Sortable(body, {
      group:'board', animation:150, ghostClass:'dragging',
      onAdd: (evt) => {
        const id = evt.item.dataset.id; const t = taskById(id); if (!t) return;
        if (col.key === 'done') { t.status='done'; t.completedAt=Date.now(); awardPoints(t); }
        else { if (t.status==='done'){ t.status='active'; t.completedAt=null; } t.priority = Number(col.key.slice(1)); }
        saveTask(t); render();
      }
    });
  });
  root.append(board);
}
function boardCard(t) {
  return el('div', { class:'board-card'+(t.status==='done'?' done':''), dataset:{ id:t.id }, onclick:(e)=>{ if(!e.target.closest('.drag-handle')) openTask(t.id); } },
    el('div', { class:'card-title', html:mdInline(t.title) }),
    t.due ? el('div', { class:'task-meta' }, el('span',{class:isOverdue(t)?'due overdue':'due'}, fmtDate(t.due,t.hasTime))) : null);
}

// ---- CALENDAR (month grid, drag to schedule) ----
function renderCalendar(root) {
  const cursor = new Date(state.ui.calCursor);
  const y = cursor.getFullYear(), m = cursor.getMonth();
  const head = el('div', { class:'cal-head' },
    el('button', { class:'btn small', onclick:()=>{ const d=new Date(y,m-1,1); state.ui.calCursor=dateKey(d); renderView(); } }, '‹'),
    el('strong', {}, cursor.toLocaleDateString(undefined,{month:'long',year:'numeric'})),
    el('button', { class:'btn small', onclick:()=>{ const d=new Date(y,m+1,1); state.ui.calCursor=dateKey(d); renderView(); } }, '›'),
    el('button', { class:'btn small', onclick:()=>{ state.ui.calCursor=todayKey(); renderView(); } }, 'Today'));
  root.append(head);

  const grid = el('div', { class:'cal-grid' });
  ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'].forEach(d => grid.append(el('div',{class:'cal-dow'},d)));
  const first = new Date(y, m, 1);
  const startPad = first.getDay();
  const start = addDays(first, -startPad);
  const tasks = baseTasks().filter(t => t.due && t.status!=='someday');
  for (let i = 0; i < 42; i++) {
    const day = addDays(start, i);
    const key = dateKey(day);
    const cell = el('div', { class:'cal-cell'+(day.getMonth()!==m?' other-month':'')+(key===todayKey()?' today':''), dataset:{ date:key } },
      el('div', { class:'cal-date' }, String(day.getDate())));
    tasks.filter(t => dateKey(new Date(t.due)) === key).forEach(t =>
      cell.append(el('div', { class:'cal-task'+(t.status==='done'?' done':''), draggable:'true', dataset:{ id:t.id },
        onclick:()=>openTask(t.id),
        ondragstart:(e)=>e.dataTransfer.setData('text/plain', t.id) }, stripMd(t.title))));
    // drop target
    cell.addEventListener('dragover', e => { e.preventDefault(); cell.classList.add('drop-hover'); });
    cell.addEventListener('dragleave', () => cell.classList.remove('drop-hover'));
    cell.addEventListener('drop', e => {
      e.preventDefault(); cell.classList.remove('drop-hover');
      const id = e.dataTransfer.getData('text/plain'); const t = taskById(id); if (!t) return;
      const nd = new Date(key + 'T' + (t.hasTime ? (t.due||'').slice(11,16) || '09:00' : '00:00'));
      t.due = nd.toISOString(); saveTask(t); renderView();
    });
    grid.append(cell);
  }
  root.append(grid);
}

// ---- EISENHOWER MATRIX ----
function renderMatrix(root, tasks) {
  // urgent = due within 2 days or overdue; important = priority 1-2
  const isUrgent = t => isOverdue(t) || (t.due && (new Date(t.due) - new Date()) < 2*86400000);
  const isImportant = t => t.priority <= 2;
  const quads = [
    { key:'q1', label:'Do first — Urgent & Important', cls:'q1', test:t=>isUrgent(t)&&isImportant(t), apply:t=>{t.priority=1; if(!t.due)t.due=new Date().toISOString();} },
    { key:'q2', label:'Schedule — Important, Not urgent', cls:'q2', test:t=>!isUrgent(t)&&isImportant(t), apply:t=>{t.priority=2;} },
    { key:'q3', label:'Delegate — Urgent, Not important', cls:'q3', test:t=>isUrgent(t)&&!isImportant(t), apply:t=>{t.priority=3; if(!t.due)t.due=new Date().toISOString();} },
    { key:'q4', label:'Eliminate — Neither', cls:'q4', test:t=>!isUrgent(t)&&!isImportant(t), apply:t=>{t.priority=4;} }
  ];
  const active = tasks.filter(t => t.status==='active');
  const wrap = el('div', { class:'matrix' });
  quads.forEach(q => {
    const body = el('div', { class:'matrix-q-body', dataset:{ q:q.key } });
    active.filter(q.test).forEach(t => body.append(boardCard(t)));
    wrap.append(el('div', { class:'matrix-q '+q.cls },
      el('div',{class:'matrix-q-head'}, q.label, el('span',{class:'badge'},String(active.filter(q.test).length))),
      body));
    if (window.Sortable) new Sortable(body, { group:'matrix', animation:150, ghostClass:'dragging',
      onAdd:(evt)=>{ const t=taskById(evt.item.dataset.id); if(t){ q.apply(t); saveTask(t); render(); } } });
  });
  root.append(wrap);
}

// ---- TIME-BLOCK / DAILY PLANNER ----
function renderPlanner(root, tasks) {
  const dayTasks = baseTasks().filter(t => t.status==='active' && t.due && isDueToday(t));
  const scheduled = dayTasks.filter(t => t.plannerTime);
  const unscheduled = dayTasks.filter(t => !t.plannerTime);

  const un = el('div', { class:'planner-unscheduled' },
    el('div',{class:'section-head'},'Unscheduled today', el('span',{class:'count'},String(unscheduled.length))),
    el('div',{class:'task-list', dataset:{ plannerslot:'none' }}, ...unscheduled.map(t =>
      el('div', { class:'planner-task', draggable:'true', dataset:{ id:t.id },
        ondragstart:(e)=>e.dataTransfer.setData('text/plain',t.id), onclick:()=>openTask(t.id) },
        stripMd(t.title)))));
  root.append(un);

  const planner = el('div', { class:'planner' });
  for (let h = 6; h <= 22; h++) {
    const label = (h%12===0?12:h%12) + (h<12?'am':'pm');
    const slot = el('div', { class:'planner-slot', dataset:{ hour:h } });
    scheduled.filter(t => Number((t.plannerTime||'').split(':')[0]) === h).forEach(t =>
      slot.append(el('div', { class:'planner-task', draggable:'true', dataset:{ id:t.id },
        ondragstart:(e)=>e.dataTransfer.setData('text/plain',t.id), onclick:()=>openTask(t.id) },
        `${t.plannerTime} · ${stripMd(t.title)}`)));
    slot.addEventListener('dragover', e=>{ e.preventDefault(); slot.classList.add('drop-hover'); });
    slot.addEventListener('dragleave', ()=>slot.classList.remove('drop-hover'));
    slot.addEventListener('drop', e=>{ e.preventDefault(); slot.classList.remove('drop-hover');
      const t = taskById(e.dataTransfer.getData('text/plain')); if(!t) return;
      t.plannerTime = pad(h)+':00'; if(!t.due) t.due=new Date().toISOString(); saveTask(t); renderView(); });
    planner.append(el('div',{class:'planner-time'}, label), slot);
  }
  root.append(planner);
}

// ---- HABITS ----
function renderHabits(root) {
  root.append(el('div',{class:'toolbar'},
    el('button',{class:'btn primary',onclick:addHabit},'＋ New habit')));
  if (!state.habits.length) { root.append(el('div',{class:'empty-state'},el('div',{class:'big'},'♻'),el('h2',{},'Build a habit'),el('p',{},'Track daily habits and watch your streaks grow.'))); return; }
  const grid = el('div',{class:'habit-grid'});
  const last7 = Array.from({length:7},(_,i)=>dateKey(addDays(new Date(),-6+i)));
  state.habits.forEach(h => {
    const streak = habitStreak(h);
    const row = el('div',{class:'habit-row'});
    row.append(el('div',{class:'habit-top'},
      el('strong',{},h.name),
      el('span',{class:'habit-streak'},'🔥 '+streak),
      el('button',{class:'icon-btn',title:'Delete',onclick:()=>{state.habits=state.habits.filter(x=>x.id!==h.id);idbDel('habits',h.id);render();}},'🗑')));
    const dots = el('div',{class:'habit-dots'});
    last7.forEach(d => {
      const done = !!h.history[d];
      dots.append(el('div',{class:'habit-dot'+(done?' done':''), title:d,
        onclick:()=>{ if(done)delete h.history[d]; else h.history[d]=true; idbPut('habits',h); render(); }},
        new Date(d).toLocaleDateString(undefined,{weekday:'short'}).slice(0,1)));
    });
    row.append(dots); grid.append(row);
  });
  root.append(grid);
}
function addHabit() { const name = prompt('Habit name (e.g. "Read 20 min")'); if(!name) return; const h={id:uid(),name,history:{},createdAt:Date.now()}; state.habits.push(h); idbPut('habits',h); render(); }
function habitStreak(h) { let s=0; for(let i=0;;i++){ const d=dateKey(addDays(new Date(),-i)); if(h.history[d])s++; else if(i===0)continue; else break; } return s; }

// ---- STATS ----
function renderStats(root) {
  const done = state.tasks.filter(t => t.completedAt);
  const today = done.filter(t => dateKey(new Date(t.completedAt))===todayKey()).length;
  const week = done.filter(t => (Date.now()-t.completedAt) < 7*86400000).length;
  const active = baseTasks().filter(t=>t.status==='active').length;
  const overdue = baseTasks().filter(isOverdue).length;

  root.append(el('div',{class:'cards'},
    statCard(today,'Completed today'),
    statCard(week,'Completed this week'),
    statCard(active,'Active tasks'),
    statCard(overdue,'Overdue'),
    statCard(state.gamify.points,'Total points'),
    statCard('Lv '+state.gamify.level,'Level'),
    statCard('🔥 '+state.gamify.streak,'Day streak')));

  // last 14 days bar chart
  const days = Array.from({length:14},(_,i)=>addDays(new Date(),-13+i));
  const counts = days.map(d => done.filter(t=>dateKey(new Date(t.completedAt))===dateKey(d)).length);
  const max = Math.max(1, ...counts);
  root.append(el('h3',{style:'margin:18px 0 4px'},'Completions — last 14 days'));
  root.append(el('div',{class:'bar-chart'}, ...counts.map((c,i)=>
    el('div',{class:'bar',style:`height:${Math.round(c/max*100)}%`,title:`${c} on ${dateKey(days[i])}`},
      el('span',{}, days[i].getDate()===1||i===0||i===13 ? `${days[i].getMonth()+1}/${days[i].getDate()}` : '')))));

  // time tracking
  const est = baseTasks().reduce((s,t)=>s+(t.duration||0),0);
  const act = state.tasks.reduce((s,t)=>s+(t.actualTime||0),0);
  root.append(el('h3',{style:'margin:24px 0 8px'},'Time tracking'));
  root.append(el('div',{class:'cards'}, statCard(est+'m','Estimated (open)'), statCard(act+'m','Tracked (total)'),
    statCard(state.pomodoro.totalFocusMin+'m','Pomodoro focus')));
}
function statCard(num,lbl){ return el('div',{class:'stat-card'},el('div',{class:'num'},String(num)),el('div',{class:'lbl'},lbl)); }

// ---- TRASH ----
function renderTrash(root) {
  const items = state.tasks.filter(t=>t.status==='trashed');
  root.append(el('div',{class:'toolbar'},
    el('span',{class:'desc'},`${items.length} item(s) in trash`),
    el('button',{class:'btn danger small',onclick:()=>{ if(confirm('Permanently delete all trashed tasks?')) emptyTrash(); }},'Empty trash')));
  if(!items.length){ root.append(el('div',{class:'empty-state'},el('div',{class:'big'},'🗑'),el('h2',{},'Trash is empty'))); return; }
  const list = el('div',{class:'task-list'});
  items.forEach(t => list.append(el('div',{class:'task-row done'},
    el('span',{class:'task-main'}, stripMd(t.title)),
    el('div',{class:'task-actions',style:'opacity:1'},
      el('button',{class:'btn small',onclick:()=>{restoreFromTrash(t.id);render();}},'Restore'),
      el('button',{class:'btn small danger',onclick:()=>deleteForever(t.id)},'Delete')))));
  root.append(list);
}

// ---- ARCHIVE ----
function renderArchive(root) {
  const items = state.tasks.filter(t=>t.status==='archived');
  if(!items.length){ root.append(el('div',{class:'empty-state'},el('div',{class:'big'},'▣'),el('h2',{},'Nothing archived'),el('p',{},'Archive completed work you want to keep out of the way.'))); return; }
  const list = el('div',{class:'task-list'});
  items.forEach(t => list.append(el('div',{class:'task-row done'},
    el('span',{class:'task-main',onclick:()=>openTask(t.id)}, stripMd(t.title)),
    el('div',{class:'task-actions',style:'opacity:1'},
      el('button',{class:'btn small',onclick:()=>{t.status='active';saveTask(t);render();}},'Unarchive')))));
  root.append(list);
}

/* ====================== 10. DRAG & DROP (Sortable for lists) ====================== */
function makeSortable(listEl) {
  if (!window.Sortable || !listEl) return;
  new Sortable(listEl, {
    animation: 150, handle: '.drag-handle', draggable: '.task-row:not(.subtask)',
    ghostClass: 'dragging', delay: 80, delayOnTouchOnly: true,
    onEnd: () => {
      // rewrite positions from DOM order
      $$('.task-row', listEl).forEach((row, i) => {
        const t = taskById(row.dataset.id);
        if (t) { t.position = i + 1; idbPut('tasks', t); }
      });
      state.ui.sort = 'manual'; $('#sort-select').value = 'manual';
    }
  });
}

/* ====================== 11. TASK DETAIL DIALOG ====================== */
function openTask(id) {
  const t = taskById(id); if (!t) return;
  const dlg = $('#task-dialog'); const form = $('#task-form');
  form.innerHTML = '';

  const titleInput = el('input', { class:'title-input', value:'', 'aria-label':'Task title', placeholder:'Task title' });
  titleInput.value = t.title;
  const cb = el('input', { type:'checkbox', class:'checkbox p'+t.priority }); cb.checked = t.status==='done';
  cb.addEventListener('change', ()=>{ toggleComplete(t.id, cb); dlg.close(); });

  // priority segmented control
  const prioSeg = el('div', { class:'seg' }, ...[1,2,3,4].map(p =>
    el('button', { type:'button', dataset:{ p }, class:(t.priority===p?'active':''),
      onclick:(e)=>{ t.priority=p; $$('.seg button',prioSeg).forEach(b=>b.classList.toggle('active',Number(b.dataset.p)===p)); cb.className='checkbox p'+p; } }, 'P'+p)));

  const notes = el('textarea', { class:'field-area', placeholder:'Notes (Markdown supported)…' }); notes.value = t.notes;

  const dueInput = el('input', { type:'date', class:'field-input', value: t.due ? dateKey(new Date(t.due)) : '' });
  const timeInput = el('input', { type:'time', class:'field-input', value: t.hasTime ? new Date(t.due).toTimeString().slice(0,5) : '' });
  const startInput = el('input', { type:'date', class:'field-input', value: t.start ? dateKey(new Date(t.start)) : '' });
  const durInput = el('input', { type:'number', class:'field-input', min:0, step:5, placeholder:'min', value: t.duration||'' });

  const energySel = el('select', { class:'select' }, ...[['','—'],['high','⚡ High'],['low','🌙 Low'],['physical','💪 Physical']].map(([v,l])=>{ const o=el('option',{value:v},l); if(t.energy===v)o.selected=true; return o; }));

  // project + section
  const projSel = el('select', { class:'select' }, el('option',{value:''},'Inbox (no project)'),
    ...state.projects.filter(p=>p.type==='project'&&!p.archived).map(p=>{ const o=el('option',{value:p.id},p.name); if(t.projectId===p.id)o.selected=true; return o; }));
  const secSel = el('select', { class:'select' });
  const fillSections = () => { secSel.innerHTML=''; secSel.append(el('option',{value:''},'(No section)')); const p=projectById(projSel.value); (p?.sections||[]).forEach(s=>{ const o=el('option',{value:s.id},s.name); if(t.sectionId===s.id)o.selected=true; secSel.append(o); }); };
  fillSections(); projSel.addEventListener('change', fillSections);

  // recurrence
  const recInput = el('input', { type:'text', class:'field-input', placeholder:'e.g. every weekday, every 2 weeks', value: t.recurrence ? recurrenceText(t.recurrence) : '' });
  const recHint = el('div', { class:'desc', style:'font-size:12px;color:var(--text-dim)' }, t.recurrence ? '↻ ' + recurrenceText(t.recurrence) : '');
  recInput.addEventListener('input', ()=>{ const r=extractRecurrence(recInput.value); t.recurrence = r?r.rrule:null; recHint.textContent = r ? '↻ '+recurrenceText(r.rrule) : (recInput.value?'Not recognised':''); });

  // tags editor
  const tagBox = el('div', { class:'filters' });
  const renderTags = () => { tagBox.innerHTML=''; state.tags.forEach(tag => {
    const on = t.tags.includes(tag.id);
    tagBox.append(el('button',{type:'button',class:'chip'+(on?' active':''),onclick:()=>{ const i=t.tags.indexOf(tag.id); i>=0?t.tags.splice(i,1):t.tags.push(tag.id); renderTags(); }}, el('span',{class:'project-dot',style:`background:${tag.color}`}),'#'+tag.name)); });
    tagBox.append(el('button',{type:'button',class:'chip',onclick:()=>{ const n=prompt('New tag name'); if(n){ t.tags.push(ensureTag(n)); renderTags(); } }},'＋ tag'));
  };
  renderTags();

  // subtasks
  const subWrap = el('div', { class:'subtask-list' });
  const renderSubs = () => { subWrap.innerHTML='';
    state.tasks.filter(c=>c.parentId===t.id && c.status!=='trashed').forEach(c => {
      const scb=el('input',{type:'checkbox',class:'checkbox p4'}); scb.checked=c.status==='done';
      scb.addEventListener('change',()=>{ toggleComplete(c.id,scb); });
      const inp=el('input',{type:'text',value:c.title}); inp.addEventListener('change',()=>{ c.title=inp.value; saveTask(c); });
      subWrap.append(el('div',{class:'subtask-item'},scb,inp,el('button',{type:'button',class:'icon-btn',onclick:()=>{trashTask(c.id,{silent:true});renderSubs();}},'✕')));
    });
  };
  renderSubs();
  const addSub = el('button',{type:'button',class:'linkish',onclick:()=>{ const s=newTaskFrom({title:'New subtask',priority:4},{parentId:t.id,projectId:t.projectId}); renderSubs(); }},'＋ Add subtask');

  // checklist
  const clWrap = el('div',{class:'checklist'});
  const renderCl = () => { clWrap.innerHTML=''; t.checklist.forEach(item => {
    const c=el('input',{type:'checkbox',class:'checkbox p4'}); c.checked=item.done; c.addEventListener('change',()=>{ item.done=c.checked; saveTask(t); });
    const inp=el('input',{type:'text',value:item.text}); inp.addEventListener('change',()=>{ item.text=inp.value; saveTask(t); });
    clWrap.append(el('div',{class:'checklist-item'},c,inp,el('button',{type:'button',class:'icon-btn',onclick:()=>{t.checklist=t.checklist.filter(x=>x!==item);saveTask(t);renderCl();}},'✕')));
  }); };
  renderCl();
  const addCl = el('button',{type:'button',class:'linkish',onclick:()=>{ t.checklist.push({id:uid(),text:'',done:false}); saveTask(t); renderCl(); }},'＋ Add checklist item');

  // assemble form
  form.append(
    el('div',{class:'form-head'}, cb, titleInput),
    el('div',{class:'form-body'},
      el('div',{class:'field'}, el('label',{},'Priority'), prioSeg),
      el('div',{class:'field-grid'},
        el('div',{class:'field'},el('label',{},'Due date'),dueInput),
        el('div',{class:'field'},el('label',{},'Due time'),timeInput),
        el('div',{class:'field'},el('label',{},'Start / Do date'),startInput),
        el('div',{class:'field'},el('label',{},'Estimate (min)'),durInput),
        el('div',{class:'field'},el('label',{},'Energy'),energySel),
        el('div',{class:'field'},el('label',{},'Tracked (min)'),el('input',{type:'number',class:'field-input',min:0,value:t.actualTime||0,onchange:(e)=>{t.actualTime=Number(e.target.value)||0;saveTask(t);}}))),
      el('div',{class:'field-grid'},
        el('div',{class:'field'},el('label',{},'Project'),projSel),
        el('div',{class:'field'},el('label',{},'Section'),secSel)),
      el('div',{class:'field'},el('label',{},'Repeat'),recInput,recHint),
      el('div',{class:'field'},el('label',{},'Tags'),tagBox),
      el('div',{class:'field'},el('label',{},'Subtasks'),subWrap,addSub),
      el('div',{class:'field'},el('label',{},'Checklist'),clWrap,addCl),
      el('div',{class:'field'},el('label',{},'Notes'),notes)),
    el('div',{class:'form-foot'},
      el('div',{},
        el('button',{type:'button',class:'btn small',onclick:()=>{t.favorite=!t.favorite;saveTask(t);}},'★ Favorite'),
        el('button',{type:'button',class:'btn small',onclick:()=>{t.status='someday';saveTask(t);dlg.close();render();}},'☾ Someday'),
        el('button',{type:'button',class:'btn small',onclick:()=>{t.status='archived';saveTask(t);dlg.close();render();}},'▣ Archive')),
      el('div',{},
        el('button',{type:'button',class:'btn danger',onclick:()=>{dlg.close();trashTask(t.id);}},'Delete'),
        el('button',{type:'submit',class:'btn primary'},'Save')))
  );

  const commit = () => {
    t.title = titleInput.value.trim() || 'Untitled';
    t.notes = notes.value;
    t.duration = durInput.value ? Number(durInput.value) : null;
    t.energy = energySel.value || null;
    t.projectId = projSel.value || null;
    t.sectionId = secSel.value || null;
    if (dueInput.value) {
      const time = timeInput.value || '00:00';
      t.due = new Date(dueInput.value + 'T' + time).toISOString();
      t.hasTime = !!timeInput.value;
    } else { t.due = null; t.hasTime = false; }
    t.start = startInput.value ? new Date(startInput.value+'T00:00').toISOString() : null;
    saveTask(t); render();
  };
  form.onsubmit = (e) => { commit(); }; // method=dialog closes automatically
  dlg.showModal();
  setTimeout(()=>titleInput.focus(), 30);
  state.ui.selectedTaskId = t.id;
}

/* ----- PROJECT DIALOG ----- */
function addProject(parentAreaId = null) {
  const p = { id: uid(), name: 'New project', type: parentAreaId?'project':'area', parentId: parentAreaId, color:'#6366f1', sections:[], archived:false, position: Date.now() };
  state.projects.push(p); idbPut('projects', p); editProject(p.id);
}
function navProject(id) { state.ui.view='project'; state.ui.projectId=id; state.ui.sectionFilter=null; closeSidebarMobile(); render(); }
function editProject(id) {
  const p = projectById(id); if(!p) return;
  const dlg = $('#project-dialog'); const form = $('#project-form'); form.innerHTML='';
  const name = el('input',{class:'title-input',value:p.name});
  const typeSel = el('select',{class:'select'}, ...[['area','Area (top-level)'],['project','Project'],['folder','Folder']].map(([v,l])=>{const o=el('option',{value:v},l); if(p.type===v)o.selected=true; return o;}));
  const colors=['#6366f1','#10b981','#f59e0b','#ef4444','#8b5cf6','#ec4899','#06b6d4','#64748b'];
  const colorBox=el('div',{class:'theme-swatches'},...colors.map(c=>el('button',{type:'button',class:'swatch'+(p.color===c?' active':''),style:`background:${c}`,onclick:()=>{p.color=c;$$('.swatch',colorBox).forEach(s=>s.classList.toggle('active',s.style.background===c||false));$$('.swatch',colorBox).forEach(s=>s.classList.remove('active'));event.target.classList.add('active');}})));
  // sections editor
  const secWrap=el('div',{class:'subtask-list'});
  const renderSecs=()=>{ secWrap.innerHTML=''; p.sections.forEach(s=>{ const inp=el('input',{type:'text',value:s.name}); inp.addEventListener('change',()=>{s.name=inp.value;}); secWrap.append(el('div',{class:'subtask-item'},inp,el('button',{type:'button',class:'icon-btn',onclick:()=>{p.sections=p.sections.filter(x=>x!==s);renderSecs();}},'✕'))); }); };
  renderSecs();
  const areaSel = el('select',{class:'select'}, el('option',{value:''},'(none)'), ...state.projects.filter(a=>a.type==='area'&&a.id!==p.id).map(a=>{const o=el('option',{value:a.id},a.name); if(p.parentId===a.id)o.selected=true; return o;}));
  form.append(
    el('div',{class:'form-head'}, name),
    el('div',{class:'form-body'},
      el('div',{class:'field'},el('label',{},'Type'),typeSel),
      el('div',{class:'field'},el('label',{},'Parent area'),areaSel),
      el('div',{class:'field'},el('label',{},'Color'),colorBox),
      el('div',{class:'field'},el('label',{},'Sections / headings'),secWrap,el('button',{type:'button',class:'linkish',onclick:()=>{p.sections.push({id:uid(),name:'New section'});renderSecs();}},'＋ Add section'))),
    el('div',{class:'form-foot'},
      el('button',{type:'button',class:'btn danger',onclick:()=>{ if(confirm('Delete this project? Tasks move to Inbox.')){ state.tasks.forEach(t=>{if(t.projectId===p.id){t.projectId=null;idbPut('tasks',t);}}); state.projects=state.projects.filter(x=>x.id!==p.id); idbDel('projects',p.id); dlg.close(); if(state.ui.projectId===p.id){state.ui.view='today';} render(); } }},'Delete'),
      el('button',{type:'submit',class:'btn primary'},'Save')));
  form.onsubmit=()=>{ p.name=name.value.trim()||'Untitled'; p.type=typeSel.value; p.parentId=areaSel.value||null; idbPut('projects',p); render(); };
  dlg.showModal(); setTimeout(()=>name.focus(),30);
}

/* ====================== 12. COMMAND PALETTE + SEARCH ====================== */
const COMMANDS = () => [
  { label:'Add task', hint:'N', run:()=>$('#quick-add').focus() },
  { label:'Go to Today', hint:'g t', run:()=>goView('today') },
  { label:'Go to Upcoming', hint:'g u', run:()=>goView('upcoming') },
  { label:'Go to Inbox', hint:'g i', run:()=>goView('inbox') },
  { label:'Go to All Tasks', run:()=>goView('all') },
  { label:'Go to Stats', run:()=>goView('stats') },
  { label:'Go to Habits', run:()=>goView('habits') },
  { label:'Layout: List', run:()=>setLayout('list') },
  { label:'Layout: Board', run:()=>setLayout('board') },
  { label:'Layout: Calendar', run:()=>setLayout('calendar') },
  { label:'Layout: Eisenhower Matrix', run:()=>setLayout('matrix') },
  { label:'Layout: Time-block Planner', run:()=>setLayout('planner') },
  { label:'Toggle Focus mode', run:()=>{ state.ui.focusMode=!state.ui.focusMode; render(); } },
  { label:'Toggle theme (light/dark)', hint:'', run:()=>cycleTheme() },
  { label:'New project / area', run:()=>addProject(null) },
  { label:'Open Pomodoro timer', run:()=>openPomodoro() },
  { label:'Open Settings', run:()=>openSettings() },
  { label:'Export backup (JSON)', run:()=>exportJSON() },
  { label:'Export calendar (.ics)', run:()=>exportICS() },
  { label:'Export tasks (CSV)', run:()=>exportCSV() },
  { label:'Request notification permission', run:()=>requestNotifications() },
  { label:'Undo last delete', hint:'Ctrl+Z', run:()=>undoLast() },
  ...state.templates.map(tpl => ({ label:'Template: '+tpl.name, run:()=>applyTemplate(tpl.id) }))
];

let paletteItems = [], paletteIndex = 0;
function openPalette() {
  const dlg = $('#palette'); const input = $('#palette-input'); input.value='';
  renderPalette(''); dlg.showModal(); setTimeout(()=>input.focus(),20);
}
function renderPalette(q) {
  const list = $('#palette-list'); list.innerHTML='';
  paletteItems = COMMANDS().filter(c => c.label.toLowerCase().includes(q.toLowerCase()));
  paletteIndex = 0;
  if (!paletteItems.length) { list.append(el('div',{class:'palette-empty'},'No commands')); return; }
  paletteItems.forEach((c,i)=> list.append(el('li',{class:'palette-item'+(i===0?' active':''),role:'option',dataset:{i},
    onclick:()=>{ $('#palette').close(); c.run(); }}, c.label, c.hint?el('span',{class:'hint'},c.hint):null)));
}
function movePalette(d) {
  paletteIndex = clamp(paletteIndex + d, 0, paletteItems.length-1);
  $$('#palette-list .palette-item').forEach((li,i)=>li.classList.toggle('active',i===paletteIndex));
  $$('#palette-list .palette-item')[paletteIndex]?.scrollIntoView({block:'nearest'});
}

function openSearch() {
  const dlg = $('#search-dialog'); const input=$('#search-input'); input.value=''; $('#search-results').innerHTML='';
  dlg.showModal(); setTimeout(()=>input.focus(),20);
}
function renderSearchResults(q) {
  const list=$('#search-results'); list.innerHTML='';
  if(!q.trim()){ return; }
  const res = state.tasks.filter(t=>t.status!=='trashed' && (t.title.toLowerCase().includes(q.toLowerCase()) || (t.notes||'').toLowerCase().includes(q.toLowerCase()))).slice(0,30);
  if(!res.length){ list.append(el('div',{class:'palette-empty'},'No tasks found')); return; }
  res.forEach((t,i)=>list.append(el('li',{class:'palette-item'+(i===0?' active':''),
    onclick:()=>{ $('#search-dialog').close(); openTask(t.id); }},
    el('span',{class:'checkbox p'+t.priority,style:'pointer-events:none'}),
    el('span',{},stripMd(t.title)),
    t.due?el('span',{class:'hint'},fmtDate(t.due)):null)));
}

/* ====================== 13. SETTINGS + BACKUP/RESTORE ====================== */
function openSettings() {
  const dlg=$('#settings-dialog'); const body=$('#settings-body'); body.innerHTML='';
  const s = state.settings;

  // appearance
  body.append(settingsGroup('Appearance',
    settingRow('Theme', el('div',{class:'theme-swatches'},
      ...[['system','◐'],['light','☀'],['dark','🌙'],['warm','🔥']].map(([v,ic])=>
        el('button',{class:'swatch'+(s.theme===v?' active':''),title:v,onclick:(e)=>{ setTheme(v); $$('.theme-swatches .swatch',body).forEach(x=>x.classList.remove('active')); e.target.classList.add('active'); }},ic)))),
    toggleRow('Confetti on milestones', 'confetti'),
    toggleRow('Completion sound', 'sound'),
    toggleRow('Haptic feedback (mobile)', 'haptics')));

  // notifications
  const permState = ('Notification' in window) ? Notification.permission : 'unsupported';
  body.append(settingsGroup('Reminders & notifications',
    el('div',{class:'setting-row'},
      el('div',{}, el('div',{},'OS notifications'), el('div',{class:'desc'},`Status: ${permState}. Only fire while the app/browser is open.`)),
      el('button',{class:'btn small',onclick:()=>requestNotifications()}, permState==='granted'?'Test':'Enable')),
    el('div',{class:'setting-row'},
      el('div',{class:'desc',style:'max-width:100%'},'⚠ Reminders that fire when the app is fully closed are not reliably possible without a server. For critical deadlines, export an .ics and add it to your real calendar.'),
      el('button',{class:'btn small',onclick:()=>exportICS()},'Export .ics'))));

  // focus
  body.append(settingsGroup('Focus & planning',
    el('div',{class:'setting-row'}, el('div',{},'Focus mode — show only N tasks'),
      el('input',{type:'number',class:'field-input',style:'width:80px',min:1,max:25,value:s.focusN,onchange:(e)=>{ s.focusN=clamp(Number(e.target.value)||5,1,25); saveSettings(); render(); }}))));

  // data / storage
  const persistBtn = el('button',{class:'btn small',onclick:async()=>{ if(navigator.storage?.persist){ const ok=await navigator.storage.persist(); toast(ok?'Persistent storage granted ✓':'Browser declined persistence'); updateStorageInfo(); } }},'Request persistent');
  const storageInfo = el('div',{class:'desc',id:'storage-info'},'Calculating…');
  updateStorageInfo();
  body.append(settingsGroup('Data & backup',
    el('div',{class:'setting-row'}, el('div',{}, el('div',{},'Storage'), storageInfo), persistBtn),
    el('div',{class:'setting-row'},
      el('div',{},'Backup'),
      el('div',{style:'display:flex;gap:6px;flex-wrap:wrap'},
        el('button',{class:'btn small primary',onclick:()=>exportJSON()},'⬇ JSON'),
        el('button',{class:'btn small',onclick:()=>exportCSV()},'CSV'),
        el('button',{class:'btn small',onclick:()=>exportICS()},'.ics'))),
    el('div',{class:'setting-row'},
      el('div',{}, el('div',{},'Restore from JSON'), el('div',{class:'desc'},'Merges with current data.')),
      el('label',{class:'btn small'},'⬆ Import', el('input',{type:'file',accept:'.json,application/json',style:'display:none',onchange:(e)=>importJSON(e.target.files[0])}))),
    el('div',{class:'setting-row'},
      el('div',{class:'desc'}, state.meta.lastBackup?('Last backup: '+new Date(state.meta.lastBackup).toLocaleString()):'No backup yet — back up regularly!'),
      el('button',{class:'btn small danger',onclick:()=>{ if(confirm('Erase ALL local data? This cannot be undone (export a backup first).')) wipeEverything(); }},'Erase all'))));

  dlg.showModal();
}
function settingsGroup(title, ...rows){ return el('div',{class:'settings-group'},el('h3',{},title),...rows); }
function settingRow(label, control){ return el('div',{class:'setting-row'},el('div',{},label),control); }
function toggleRow(label, key){
  const input=el('input',{type:'checkbox'}); input.checked=!!state.settings[key];
  input.addEventListener('change',()=>{ state.settings[key]=input.checked; saveSettings(); applySettings(); });
  return el('div',{class:'setting-row'}, el('div',{},label),
    el('label',{class:'switch'}, input, el('span',{class:'track'})));
}
async function updateStorageInfo(){
  const node = $('#storage-info'); if(!node) return;
  if (navigator.storage?.estimate) {
    try { const { usage, quota } = await navigator.storage.estimate();
      const persisted = navigator.storage.persisted ? await navigator.storage.persisted() : false;
      node.textContent = `${(usage/1048576).toFixed(2)} MB used of ${(quota/1048576).toFixed(0)} MB · ${persisted?'persistent ✓':'best-effort'}`;
    } catch { node.textContent='Storage estimate unavailable'; }
  } else node.textContent = 'Storage API unavailable';
}

function saveSettings(){ kvPut('settings', state.settings); LS.set('settings', { theme:state.settings.theme }); }

// ----- Backup / restore -----
function download(filename, content, mime) {
  const blob = new Blob([content], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = el('a', { href:url, download:filename }); document.body.append(a); a.click(); a.remove();
  setTimeout(()=>URL.revokeObjectURL(url), 1000);
}
function exportJSON() {
  const data = { app:'tasked', version:1, exportedAt:new Date().toISOString(),
    tasks:state.tasks, projects:state.projects, tags:state.tags, habits:state.habits,
    savedSearches:state.savedSearches, templates:state.templates, gamify:state.gamify, settings:state.settings };
  download(`tasked-backup-${todayKey()}.json`, JSON.stringify(data,null,2), 'application/json');
  state.meta.lastBackup = Date.now(); kvPut('meta', state.meta);
  toast('Backup downloaded ✓');
}
function importJSON(file) {
  if(!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    try {
      const d = JSON.parse(reader.result);
      const merge = (arr, store) => (d[arr]||[]).forEach(item => { if(!state[arr].find(x=>x.id===item.id)){ state[arr].push(item); idbPut(store,item); } });
      merge('tasks','tasks'); merge('projects','projects'); merge('tags','tags'); merge('habits','habits');
      if(d.savedSearches) { state.savedSearches=d.savedSearches; kvPut('savedSearches',state.savedSearches); }
      if(d.templates) { state.templates=d.templates; kvPut('templates',state.templates); }
      render(); toast('Import complete ✓');
    } catch(e){ toast('Import failed — invalid file'); }
  };
  reader.readAsText(file);
}
function toICSDate(d){ const x=new Date(d); return `${x.getUTCFullYear()}${pad(x.getUTCMonth()+1)}${pad(x.getUTCDate())}T${pad(x.getUTCHours())}${pad(x.getUTCMinutes())}00Z`; }
function exportICS() {
  const lines = ['BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//Tasked//EN','CALSCALE:GREGORIAN'];
  state.tasks.filter(t=>t.due && t.status!=='trashed').forEach(t => {
    lines.push('BEGIN:VEVENT', `UID:${t.id}@tasked`, `DTSTAMP:${toICSDate(new Date())}`,
      `DTSTART:${toICSDate(t.due)}`, `SUMMARY:${stripMd(t.title).replace(/[,;]/g,' ')}`,
      t.notes?`DESCRIPTION:${t.notes.replace(/\n/g,'\\n').replace(/[,;]/g,' ')}`:'',
      t.recurrence?`RRULE:${t.recurrence}`:'',
      'END:VEVENT');
  });
  lines.push('END:VCALENDAR');
  download(`tasked-${todayKey()}.ics`, lines.filter(Boolean).join('\r\n'), 'text/calendar');
  toast('Calendar file exported ✓');
}
function exportCSV() {
  const esc = v => `"${String(v??'').replace(/"/g,'""')}"`;
  const rows = [['Title','Status','Priority','Due','Start','Project','Tags','Notes'].map(esc).join(',')];
  state.tasks.filter(t=>t.status!=='trashed').forEach(t => rows.push([
    stripMd(t.title), t.status, 'P'+t.priority, t.due||'', t.start||'',
    projectById(t.projectId)?.name||'', t.tags.map(id=>tagById(id)?.name).filter(Boolean).join(' '), t.notes||''
  ].map(esc).join(',')));
  download(`tasked-${todayKey()}.csv`, rows.join('\n'), 'text/csv');
  toast('CSV exported ✓');
}
function wipeEverything(){ STORES.forEach(idbClear); localStorage.clear(); location.reload(); }

function applyTemplate(id){
  const tpl = state.templates.find(t=>t.id===id); if(!tpl) return;
  tpl.tasks.forEach((title,i)=> newTaskFrom({ title, priority:3 }, { position: Date.now()+i }));
  render(); toast(`Added ${tpl.tasks.length} tasks from “${tpl.name}”`);
}

/* ====================== 14. POMODORO ====================== */
let pomoInterval = null;
function openPomodoro(){ renderPomodoro(); $('#pomodoro-dialog').showModal(); }
function renderPomodoro(){
  const p = state.pomodoro; const body=$('#pomodoro-body'); body.innerHTML='';
  const display = el('div',{class:'pomo-time'}, fmtClock(p.remaining));
  const phase = el('div',{class:'pomo-phase'}, p.phase==='focus'?'Focus session':'Break');
  const controls = el('div',{class:'pomo-controls'},
    el('button',{class:'btn primary',id:'pomo-toggle',onclick:togglePomo}, p.running?'Pause':'Start'),
    el('button',{class:'btn',onclick:resetPomo},'Reset'),
    el('button',{class:'btn',onclick:skipPomo},'Skip'));
  body.append(el('div',{class:'pomo-timer'}, phase, display, controls,
    el('div',{class:'pomo-stats'},
      el('span',{},'🍅 Today: '+p.completedToday),
      el('span',{},'⏱ Focus min: '+p.totalFocusMin))));
  body._display = display;
}
function fmtClock(s){ s=Math.max(0,Math.round(s)); return pad(Math.floor(s/60))+':'+pad(s%60); }
function togglePomo(){
  const p=state.pomodoro;
  if(p.running){ p.running=false; clearInterval(pomoInterval); kvPut('pomodoro',p); $('#pomo-toggle').textContent='Start'; return; }
  p.running=true; p.startedAt=Date.now() - ( (p.phase==='focus'?p.focusLen:p.breakLen)*60 - p.remaining )*1000;
  $('#pomo-toggle').textContent='Pause';
  pomoInterval=setInterval(tickPomo, 250); kvPut('pomodoro',p);
}
function tickPomo(){
  const p=state.pomodoro; const total=(p.phase==='focus'?p.focusLen:p.breakLen)*60;
  p.remaining = total - Math.floor((Date.now()-p.startedAt)/1000);
  const disp=$('#pomodoro-body')?._display; if(disp) disp.textContent=fmtClock(p.remaining);
  if(p.remaining<=0){ pomoComplete(); }
}
function pomoComplete(){
  const p=state.pomodoro; clearInterval(pomoInterval); p.running=false;
  if(p.phase==='focus'){ p.completedToday++; p.totalFocusMin+=p.focusLen; notify('Pomodoro done 🍅','Time for a break!'); p.phase='break'; p.remaining=p.breakLen*60; }
  else { notify('Break over','Back to focus 💪'); p.phase='focus'; p.remaining=p.focusLen*60; }
  beep(); kvPut('pomodoro',p); renderPomodoro(); renderGamifyMini();
}
function resetPomo(){ const p=state.pomodoro; clearInterval(pomoInterval); p.running=false; p.remaining=(p.phase==='focus'?p.focusLen:p.breakLen)*60; kvPut('pomodoro',p); renderPomodoro(); }
function skipPomo(){ const p=state.pomodoro; clearInterval(pomoInterval); p.running=false; p.remaining=0; pomoComplete(); }
// resume a running timer after refresh
function resumePomo(){ const p=state.pomodoro; if(p.lastDay!==todayKey()){ p.completedToday=0; p.lastDay=todayKey(); } if(p.running && p.startedAt){ pomoInterval=setInterval(tickPomo,250); } }

/* ====================== 15. GAMIFICATION ====================== */
function awardPoints(t){
  const g=state.gamify;
  const pts = { 1:25, 2:15, 3:10, 4:5 }[t.priority] || 5;
  g.points += pts;
  const newLevel = Math.floor(g.points/100)+1;
  // streak
  const today = todayKey();
  if(g.lastCompleteDate !== today){
    const yesterday = dateKey(addDays(new Date(),-1));
    if(g.lastCompleteDate === yesterday) g.streak++;
    else if(!g.vacation) g.streak = 1;
    else g.streak = Math.max(1,g.streak);
    g.lastCompleteDate = today;
  }
  if(newLevel > g.level){ g.level=newLevel; toast(`🎉 Level up! You're now level ${newLevel}`); if(state.settings.confetti) confettiBurst(); }
  if(g.streak>0 && g.streak%7===0 && !g.milestonesShown.includes('streak'+g.streak)){ g.milestonesShown.push('streak'+g.streak); toast(`🔥 ${g.streak}-day streak!`); if(state.settings.confetti) confettiBurst(); }
  kvPut('gamify',g); renderGamifyMini();
}

/* ====================== 16. REMINDERS & NOTIFICATIONS ====================== */
/* Layered, backend-free:
   (1) in-app timers for tasks due while the app is open
   (2) on-load catch-up for overdue/missed items
   (3) OS notifications via SW (only when app/browser alive)
   We do NOT promise notifications when the browser is fully closed. */
const reminderTimers = new Map();
function scheduleReminderFor(t){
  if(reminderTimers.has(t.id)){ clearTimeout(reminderTimers.get(t.id)); reminderTimers.delete(t.id); }
  if(!t.due || t.status!=='active' || !t.hasTime) return;
  const ms = new Date(t.due).getTime() - Date.now();
  if(ms <= 0 || ms > 24*3600*1000) return; // only schedule within 24h (setTimeout limits)
  const handle = setTimeout(()=>{
    notify('⏰ '+stripMd(t.title), 'Due now'); toast('⏰ Due now: '+stripMd(t.title).slice(0,40));
    reminderTimers.delete(t.id);
  }, ms);
  reminderTimers.set(t.id, handle);
}
function scheduleAllReminders(){ baseTasks().forEach(scheduleReminderFor); }
function catchUpReminders(){
  const overdue = baseTasks().filter(t => t.status==='active' && isOverdue(t));
  if(overdue.length){
    announce(`${overdue.length} task(s) overdue`);
    toast(`⚠ ${overdue.length} task(s) overdue`, 'View', ()=>goView('today'));
  }
}
async function requestNotifications(){
  if(!('Notification' in window)){ toast('Notifications not supported here'); return; }
  if(Notification.permission==='granted'){ notify('Tasked','Notifications are on ✓'); return; }
  const perm = await Notification.requestPermission();
  state.settings.notifications = perm==='granted'; saveSettings();
  if(perm==='granted'){ notify('Tasked','Notifications enabled ✓'); } else toast('Permission denied');
  if($('#settings-dialog').open) openSettings();
}
function notify(title, body){
  if(!('Notification' in window) || Notification.permission!=='granted') return;
  // Prefer the service worker (works while browser/SW alive, supports actions)
  if(navigator.serviceWorker?.controller){
    navigator.serviceWorker.controller.postMessage({ type:'SHOW_NOTIFICATION', title, options:{ body, icon:'icons/icon-192.png', badge:'icons/icon-192.png', tag:'tasked' } });
  } else {
    try { new Notification(title, { body, icon:'icons/icon-192.png' }); } catch {}
  }
}

/* ====================== 17. KEYBOARD SHORTCUTS ====================== */
let gPending = false;
function setupKeyboard(){
  document.addEventListener('keydown', (e)=>{
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName) || document.activeElement?.isContentEditable;
    const anyDialogOpen = $$('dialog[open]').length>0;

    // Command palette: Ctrl/Cmd+K
    if((e.ctrlKey||e.metaKey) && e.key.toLowerCase()==='k'){ e.preventDefault(); openPalette(); return; }
    // Undo: Ctrl/Cmd+Z (when not typing)
    if((e.ctrlKey||e.metaKey) && e.key.toLowerCase()==='z' && !typing){ e.preventDefault(); undoLast(); return; }

    // palette navigation
    if($('#palette').open){
      if(e.key==='ArrowDown'){ e.preventDefault(); movePalette(1); }
      else if(e.key==='ArrowUp'){ e.preventDefault(); movePalette(-1); }
      else if(e.key==='Enter'){ e.preventDefault(); const c=paletteItems[paletteIndex]; if(c){ $('#palette').close(); c.run(); } }
      return;
    }
    if($('#search-dialog').open && e.key==='Enter'){ e.preventDefault(); const first=$('#search-results .palette-item'); first?.click(); return; }

    if(typing || anyDialogOpen) return;

    // single-key shortcuts
    if(gPending){
      gPending=false;
      if(e.key==='t') return goView('today');
      if(e.key==='u') return goView('upcoming');
      if(e.key==='i') return goView('inbox');
      if(e.key==='a') return goView('all');
      return;
    }
    switch(e.key){
      case 'n': case 'N': e.preventDefault(); $('#quick-add').focus(); break;
      case '/': e.preventDefault(); openSearch(); break;
      case 'g': gPending=true; setTimeout(()=>gPending=false, 800); break;
      case '1': setLayout('list'); break;
      case '2': setLayout('board'); break;
      case '3': setLayout('calendar'); break;
      case '4': setLayout('matrix'); break;
      case '5': setLayout('planner'); break;
      case '?': openPalette(); break;
      case 'f': if(state.ui.selectedTaskId){ const t=taskById(state.ui.selectedTaskId); if(t){t.flagged=!t.flagged;saveTask(t);render();} } break;
    }
  });
}

/* ====================== 18. TOASTS / CONFETTI / SOUND / HAPTICS ====================== */
function toast(msg, actionLabel, action){
  const stack=$('#toast-stack');
  const t=el('div',{class:'toast'}, msg);
  if(actionLabel){ t.append(el('button',{onclick:()=>{ action?.(); t.remove(); }}, actionLabel)); }
  stack.append(t);
  setTimeout(()=>{ t.classList.add('fade-out'); setTimeout(()=>t.remove(),320); }, action?6000:3000);
}
function announce(msg){ const r=$('#live-region'); r.textContent=''; setTimeout(()=>r.textContent=msg,30); }
function reducedMotion(){ return window.matchMedia('(prefers-reduced-motion: reduce)').matches; }

function celebrate(node){
  if(state.settings.haptics && navigator.vibrate) navigator.vibrate(20);
  if(state.settings.sound) beep();
}
let audioCtx=null;
function beep(){
  if(!state.settings.sound && !state.pomodoro) return;
  try{
    audioCtx = audioCtx || new (window.AudioContext||window.webkitAudioContext)();
    const o=audioCtx.createOscillator(), g=audioCtx.createGain();
    o.connect(g); g.connect(audioCtx.destination); o.type='sine'; o.frequency.value=660;
    g.gain.setValueAtTime(0.001,audioCtx.currentTime); g.gain.exponentialRampToValueAtTime(0.15,audioCtx.currentTime+0.01);
    g.gain.exponentialRampToValueAtTime(0.001,audioCtx.currentTime+0.25);
    o.start(); o.stop(audioCtx.currentTime+0.26);
  }catch{}
}
function confettiBurst(){
  if(reducedMotion()) return;
  const canvas=$('#confetti'); canvas.classList.add('on');
  const ctx=canvas.getContext('2d'); canvas.width=innerWidth; canvas.height=innerHeight;
  const colors=['#6366f1','#10b981','#f59e0b','#ef4444','#ec4899','#06b6d4'];
  const parts=Array.from({length:120},()=>({ x:innerWidth/2, y:innerHeight/3, vx:(Math.random()-0.5)*12, vy:Math.random()*-12-4, c:colors[Math.floor(Math.random()*colors.length)], r:Math.random()*6+2, a:1 }));
  let frame=0;
  (function anim(){
    ctx.clearRect(0,0,canvas.width,canvas.height);
    parts.forEach(p=>{ p.x+=p.vx; p.y+=p.vy; p.vy+=0.35; p.a-=0.012; ctx.globalAlpha=Math.max(0,p.a); ctx.fillStyle=p.c; ctx.fillRect(p.x,p.y,p.r,p.r); });
    frame++;
    if(frame<120) requestAnimationFrame(anim); else { ctx.clearRect(0,0,canvas.width,canvas.height); canvas.classList.remove('on'); }
  })();
}

/* ====================== THEME ====================== */
function setTheme(theme){ state.settings.theme=theme; document.body.dataset.theme=theme; saveSettings(); }
function cycleTheme(){ const order=['system','light','dark','warm']; const i=order.indexOf(state.settings.theme); setTheme(order[(i+1)%order.length]); }
function applySettings(){ document.body.dataset.theme=state.settings.theme; document.body.dataset.density=state.settings.density; }

/* ====================== NAVIGATION HELPERS ====================== */
function goView(v){ state.ui.view=v; state.ui.projectId=null; closeSidebarMobile(); render(); $('#view-root').focus?.(); }
function setLayout(l){ if(!LAYOUT_VIEWS.includes(state.ui.view)) goView('today'); state.ui.layout=l; LS.set('layout',l); render(); }
function closeSidebarMobile(){ $('#app').classList.remove('sidebar-open'); $('#scrim').hidden=true; }

/* ====================== 19. BOOT ====================== */
function wireEvents(){
  // sidebar nav
  $$('.nav-item[data-view]').forEach(b => b.addEventListener('click', ()=>goView(b.dataset.view)));
  $('#add-project').addEventListener('click', ()=>addProject(null));

  // layout switch
  $$('#view-switch .vs-btn').forEach(b => b.addEventListener('click', ()=>setLayout(b.dataset.layout)));

  // quick add
  const qa=$('#quick-add');
  $('#quick-add-form').addEventListener('submit', (e)=>{
    e.preventDefault(); const val=qa.value.trim(); if(!val) return;
    const parsed=parseQuickAdd(val);
    const t=newTaskFrom(parsed);
    if(state.ui.view==='someday') { t.status='someday'; saveTask(t); }
    qa.value=''; $('#quick-add-preview').innerHTML='';
    announce('Task added: '+stripMd(t.title));
    render();
  });
  qa.addEventListener('input', debounce(()=>{
    const tokens=quickAddPreview(qa.value);
    $('#quick-add-preview').innerHTML='';
    tokens.forEach(tok=>$('#quick-add-preview').append(el('span',{class:'qa-token'},tok)));
  }, 120));

  // toolbar
  $('#sort-select').addEventListener('change', e=>{ state.ui.sort=e.target.value; renderView(); });
  $('#focus-mode-btn').addEventListener('click', ()=>{ state.ui.focusMode=!state.ui.focusMode; render(); });
  $('#save-search-btn').addEventListener('click', ()=>{
    const name=prompt('Name this saved search'); if(!name) return;
    const s={ id:uid(), name, tags:[...state.ui.filters.tags], priority:state.ui.filters.priority, text:state.ui.filters.search };
    state.savedSearches.push(s); kvPut('savedSearches',state.savedSearches); render();
  });

  // topbar buttons
  $('#open-search').addEventListener('click', openSearch);
  $('#open-palette').addEventListener('click', openPalette);
  $('#open-settings').addEventListener('click', openSettings);
  $('#toggle-theme').addEventListener('click', cycleTheme);
  $('#open-pomodoro').addEventListener('click', openPomodoro);

  // palette / search inputs
  $('#palette-input').addEventListener('input', e=>renderPalette(e.target.value));
  $('#search-input').addEventListener('input', debounce(e=>renderSearchResults(e.target.value),120));

  // dialog close buttons + click-outside
  $$('[data-close-dialog]').forEach(b=>b.addEventListener('click', ()=>b.closest('dialog').close()));
  $$('dialog.dialog').forEach(d => d.addEventListener('click', (e)=>{ if(e.target===d) d.close(); }));

  // mobile sidebar
  $('#sidebar-open')?.addEventListener('click', ()=>{ $('#app').classList.add('sidebar-open'); $('#scrim').hidden=false; });
  $('#sidebar-close')?.addEventListener('click', closeSidebarMobile);
  $('#scrim').addEventListener('click', closeSidebarMobile);

  // refresh reminders when tab regains focus / day changes
  document.addEventListener('visibilitychange', ()=>{ if(!document.hidden){ catchUpReminders(); render(); } });

  // backup reminder
  maybeBackupReminder();
}

function maybeBackupReminder(){
  const days = state.settings.backupReminderDays;
  if(!days) return;
  const last = state.meta.lastBackup || 0;
  if(Date.now()-last > days*86400000 && state.tasks.length>4){
    setTimeout(()=>toast('💾 Time to back up your data', 'Export', ()=>exportJSON()), 4000);
  }
}

async function boot(){
  // instant theme from localStorage before IDB opens (no flash)
  const lsSettings = LS.get('settings', null);
  if(lsSettings?.theme) document.body.dataset.theme = lsSettings.theme;

  try { await openDB(); await loadAll(); }
  catch(e){ console.error('Storage failed', e); toast('⚠ Local storage unavailable — data will not persist'); }

  applySettings();
  state.ui.view = state.settings.startView || 'today';
  state.ui.layout = LS.get('layout','list');
  state.meta.lastOpened = Date.now(); kvPut('meta', state.meta);

  wireEvents();
  setupKeyboard();
  render();
  resumePomo();
  scheduleAllReminders();
  catchUpReminders();

  // request persistent storage quietly on first boot
  if(navigator.storage?.persist && navigator.storage.persisted){
    const already = await navigator.storage.persisted();
    if(!already) navigator.storage.persist();
  }

  // register service worker (relative scope => works in subfolders)
  if('serviceWorker' in navigator){
    try { await navigator.serviceWorker.register('sw.js', { scope:'./' }); }
    catch(e){ console.warn('SW registration failed', e); }
  }
}

document.addEventListener('DOMContentLoaded', boot);
